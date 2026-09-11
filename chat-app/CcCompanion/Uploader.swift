//  Uploader.swift — 心率管道后台投递（珩 2026-09-11，1.3 build 242，从 WatchPipe 搬来）
//  后台 URLSession：app 不活着系统也会替我们把请求发完。POST {serverURL}?secret=… body 是一个 batch 文件。

import Foundation

@MainActor
final class Uploader: NSObject, URLSessionDelegate, URLSessionTaskDelegate, URLSessionDataDelegate {
    static let shared = Uploader()
    static let sessionID = "top.bingk.liudeng.chat.upload"

    var backgroundCompletionHandler: (() -> Void)?
    private var responses: [Int: Data] = [:]

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        c.isDiscretionary = false
        c.sessionSendsLaunchEvents = true
        c.waitsForConnectivity = true
        c.timeoutIntervalForResource = 6 * 3600
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    /// 被系统为后台 session 事件拉起时先把 session 建起来，delegate 才收得到回调。
    func wake() { _ = session }

    /// 先把 pending 切成 batch，再把所有还没发成功的 batch 交给系统。
    func flush(reason: String) {
        while Outbox.shared.makeBatch() != nil {}
        let files = Outbox.shared.inflightFiles
        guard !files.isEmpty else { return }
        let secret = HealthSettings.secret
        guard !secret.isEmpty, var comps = URLComponents(string: HealthSettings.serverURL) else {
            HealthLog.shared.add("还没填 secret，\(files.count) 个 batch 先攒着"); return
        }
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "secret", value: secret))
        comps.queryItems = items
        guard let url = comps.url else { return }
        session.getAllTasks { tasks in
            let running = Set(tasks.compactMap { $0.taskDescription })
            let todo = files.filter { !running.contains($0.lastPathComponent) }
            Task { @MainActor in self.start(files: todo, url: url, reason: reason) }
        }
    }

    private func start(files: [URL], url: URL, reason: String) {
        guard !files.isEmpty else { return }
        for f in files {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let t = session.uploadTask(with: req, fromFile: f)
            t.taskDescription = f.lastPathComponent
            t.resume()
        }
        HealthLog.shared.add("上传 \(files.count) 个 batch（\(reason)）")
    }

    // MARK: URLSession delegate（后台线程进来，先把值取成 Sendable 再回主线程）

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let id = dataTask.taskIdentifier
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.responses[id, default: Data()].append(data) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        let name = task.taskDescription ?? "?"
        let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let errText = error?.localizedDescription
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.finish(id: id, name: name, code: code, errText: errText) }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.backgroundCompletionHandler?()
                self.backgroundCompletionHandler = nil
            }
        }
    }

    private func finish(id: Int, name: String, code: Int, errText: String?) {
        let body = String(data: responses.removeValue(forKey: id) ?? Data(), encoding: .utf8) ?? ""
        if errText == nil, (200..<300).contains(code) {
            Outbox.shared.batchDone(HealthPaths.batches.appendingPathComponent(name))
            let n = Self.receivedCount(in: body)
            HealthStatus.recordUpload(count: n)
            if let n {
                HealthLog.shared.add("上传成功（HTTP \(code)）服务器收到 \(n) 条")
            } else {
                HealthLog.shared.add("上传成功（HTTP \(code)）\(body.prefix(120))")
            }
        } else {
            // 失败：batch 文件原地留着，下次 flush 再发；服务端幂等，重传安全
            HealthLog.shared.add("上传失败 HTTP \(code) \(errText ?? String(body.prefix(120)))，留待重试")
        }
    }

    /// 服务器回 {"ok":true,"report":{"heart_rate":{"added":n,"received":m},…}}，把 received 加总。
    private static func receivedCount(in body: String) -> Int? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let report = obj["report"] as? [String: Any] else { return nil }
        var total = 0
        for (_, v) in report {
            if let d = v as? [String: Any], let r = d["received"] as? Int { total += r }
        }
        return total
    }
}
