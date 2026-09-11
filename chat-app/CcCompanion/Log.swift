//  Log.swift — 心率管道的日志 + 存储路径（珩 2026-09-11，1.3 build 242，从 WatchPipe 搬来）
//  这个工程默认全 MainActor：日志状态只在主线程改，add() 可以从任何线程喊。

import Foundation
import Combine

@MainActor
final class HealthLog: ObservableObject {
    static let shared = HealthLog()
    @Published private(set) var lines: [String] = []
    private let url: URL
    private let writeQueue = DispatchQueue(label: "lamp.health.log")
    private let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; return f }()

    private init() {
        url = HealthPaths.support.appendingPathComponent("log.txt")
        if let s = try? String(contentsOf: url, encoding: .utf8) {
            lines = Array(s.split(separator: "\n").map(String.init).suffix(300))
        }
    }

    /// 任意线程可调；顺序保持先到先写（走 main queue FIFO，不用 Task）。
    nonisolated func add(_ s: String) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.append(s) }
        }
    }

    private func append(_ s: String) {
        let line = "\(fmt.string(from: Date())) \(s)"
        lines.append(line)
        if lines.count > 300 { lines.removeFirst(lines.count - 300) }
        let text = lines.joined(separator: "\n")
        let u = url
        writeQueue.async { try? text.write(to: u, atomically: true, encoding: .utf8) }
    }

    func clear() {
        lines = []
        try? FileManager.default.removeItem(at: url)
    }
}

@MainActor
enum HealthPaths {
    static let support: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HealthPipe")
        try? fm.createDirectory(at: base, withIntermediateDirectories: true,
                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return base
    }()
    static let batches: URL = {
        let u = support.appendingPathComponent("batches")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return u
    }()
}
