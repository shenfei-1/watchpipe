//  Outbox.swift — 心率管道两段式队列（珩 2026-09-11，1.3 build 242，从 WatchPipe 搬来）
//  pending.jsonl（新样本）→ batches/<id>.json（发送中，HTTP 2xx 才删）。全部在主线程串行，不需要锁。

import Foundation

/// 一条要上报的样本。服务端按 (start,end,value) 去重，重传安全。
nonisolated struct HealthSample: Codable {
    let type: String
    let start: String
    let end: String
    let value: String   // 数值型是数字字符串，睡眠是 InBed/Core/Deep/REM/Awake
    let unit: String?
}

@MainActor
final class Outbox {
    static let shared = Outbox()
    static let batchLimit = 500
    private let pending: URL

    private init() { pending = HealthPaths.support.appendingPathComponent("pending.jsonl") }

    func append(_ samples: [HealthSample]) {
        guard !samples.isEmpty else { return }
        let enc = JSONEncoder()
        var text = ""
        for s in samples {
            if let d = try? enc.encode(s), let l = String(data: d, encoding: .utf8) { text += l + "\n" }
        }
        if let h = try? FileHandle(forWritingTo: pending) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? text.write(to: pending, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: pending.path)
        }
    }

    var pendingCount: Int {
        ((try? String(contentsOf: pending, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    var inflightFiles: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: HealthPaths.batches, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 把最多 batchLimit 条从 pending 挪进一个 batch 文件；没有就 nil。
    func makeBatch() -> URL? {
        guard let text = try? String(contentsOf: pending, encoding: .utf8) else { return nil }
        var lines = text.split(separator: "\n").map(String.init)
        guard !lines.isEmpty else { return nil }
        let take = Array(lines.prefix(Self.batchLimit)); lines.removeFirst(take.count)
        let body = "{\"samples\":[" + take.joined(separator: ",") + "]}"
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8)).json"
        let url = HealthPaths.batches.appendingPathComponent(name)
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            try (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: pending, atomically: true, encoding: .utf8)
            return url
        } catch {
            HealthLog.shared.add("写 batch 失败: \(error.localizedDescription)")
            return nil
        }
    }

    func batchDone(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}
