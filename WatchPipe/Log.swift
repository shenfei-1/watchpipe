import Foundation
import Combine

final class Log: ObservableObject {
    static let shared = Log()
    @Published private(set) var lines: [String] = []
    private let url = Paths.support.appendingPathComponent("log.txt")
    private let q = DispatchQueue(label: "watchpipe.log")
    private let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; return f }()

    private init() {
        if let s = try? String(contentsOf: url) { lines = s.split(separator: "\n").map(String.init).suffix(300).map { $0 } }
    }
    func add(_ s: String) {
        let line = "\(fmt.string(from: Date())) \(s)"
        DispatchQueue.main.async {
            self.lines.append(line); if self.lines.count > 300 { self.lines.removeFirst(self.lines.count - 300) }
            let text = self.lines.joined(separator: "\n")
            self.q.async { try? text.write(to: self.url, atomically: true, encoding: .utf8) }
        }
    }
    func clear() { DispatchQueue.main.async { self.lines = []; try? FileManager.default.removeItem(at: self.url) } }
}

enum Paths {
    static let support: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WatchPipe")
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
