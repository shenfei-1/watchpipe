import Foundation

/// 后台 URLSession：app 不活着系统也会替我们把请求发完
final class Uploader: NSObject, URLSessionDelegate, URLSessionTaskDelegate, URLSessionDataDelegate {
    static let shared = Uploader()
    var backgroundCompletionHandler: (() -> Void)?
    private var responses: [Int: Data] = [:]
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: "top.bingk.watchpipe.upload")
        c.isDiscretionary = false
        c.sessionSendsLaunchEvents = true
        c.waitsForConnectivity = true
        c.timeoutIntervalForResource = 6 * 3600
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    /// 先把 pending 切成 batch，再把所有还没发成功的 batch 交给系统
    func flush(reason: String) {
        while Outbox.shared.makeBatch() != nil {}
        let files = Outbox.shared.inflightFiles
        guard !files.isEmpty else { return }
        let secret = Settings.secret
        guard !secret.isEmpty, var comps = URLComponents(string: Settings.serverURL) else {
            Log.shared.add("没填服务器地址或令牌，\(files.count) 个 batch 先攒着"); return
        }
        var items = comps.queryItems ?? []; items.append(URLQueryItem(name: "secret", value: secret)); comps.queryItems = items
        guard let url = comps.url else { return }
        session.getAllTasks { tasks in
            let running = Set(tasks.compactMap { $0.taskDescription })
            var n = 0
            for f in files where !running.contains(f.lastPathComponent) {
                var req = URLRequest(url: url); req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let t = self.session.uploadTask(with: req, fromFile: f)
                t.taskDescription = f.lastPathComponent
                t.resume(); n += 1
            }
            if n > 0 { Log.shared.add("上传 \(n) 个 batch（\(reason)）") }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responses[dataTask.taskIdentifier, default: Data()].append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let name = task.taskDescription ?? "?"
        let body = String(data: responses.removeValue(forKey: task.taskIdentifier) ?? Data(), encoding: .utf8) ?? ""
        let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if error == nil, (200..<300).contains(code) {
            Outbox.shared.batchDone(Paths.batches.appendingPathComponent(name))
            Log.shared.add("上传成功（HTTP \(code)）\(body.prefix(120))")
        } else {
            // 失败：batch 文件原地留着，下次 flush 再发；服务端幂等，重传安全
            Log.shared.add("上传失败 HTTP \(code) \(error?.localizedDescription ?? body.prefix(120).description)，留待重试")
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { self.backgroundCompletionHandler?(); self.backgroundCompletionHandler = nil }
    }
}
