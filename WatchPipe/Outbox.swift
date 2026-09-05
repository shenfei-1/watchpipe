import Foundation

/// 一条要上报的样本。服务端按 (start,end,value) 去重，重传安全。
struct Sample: Codable {
    let type: String
    let start: String
    let end: String
    let value: String   // 数值型是数字字符串，睡眠是 InBed/Core/Deep/REM/Awake
    let unit: String?
}

/// 两段式队列：pending.jsonl（新样本）→ batches/<id>.json（发送中，HTTP 2xx 才删）
final class Outbox {
    static let shared = Outbox()
    static let batchLimit = 500
    private let q = DispatchQueue(label: "watchpipe.outbox")
    private let pending = Paths.support.appendingPathComponent("pending.jsonl")

    func append(_ samples: [Sample]) {
        guard !samples.isEmpty else { return }
        q.sync {
            let enc = JSONEncoder()
            var text = ""
            for s in samples { if let d = try? enc.encode(s), let l = String(data: d, encoding: .utf8) { text += l + "\n" } }
            if let h = try? FileHandle(forWritingTo: pending) {
                h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
            } else {
                try? text.write(to: pending, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: pending.path)
            }
        }
    }

    var pendingCount: Int {
        q.sync { ((try? String(contentsOf: pending)) ?? "").split(separator: "\n").count }
    }

    var inflightFiles: [URL] {
        q.sync { ((try? FileManager.default.contentsOfDirectory(at: Paths.batches, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent } }
    }

    /// 把最多 batchLimit 条从 pending 挪进一个 batch 文件，返回文件；没有就 nil
    func makeBatch() -> URL? {
        q.sync {
            guard let text = try? String(contentsOf: pending) else { return nil }
            var lines = text.split(separator: "\n").map(String.init)
            guard !lines.isEmpty else { return nil }
            let take = Array(lines.prefix(Self.batchLimit)); lines.removeFirst(take.count)
            let body = "{\"samples\":[" + take.joined(separator: ",") + "]}"
            let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8)).json"
            let url = Paths.batches.appendingPathComponent(name)
            do {
                try body.write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
                try (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: pending, atomically: true, encoding: .utf8)
                return url
            } catch {
                Log.shared.add("写 batch 失败: \(error.localizedDescription)"); return nil
            }
        }
    }

    func batchDone(_ url: URL) { q.sync { try? FileManager.default.removeItem(at: url) } }
}
