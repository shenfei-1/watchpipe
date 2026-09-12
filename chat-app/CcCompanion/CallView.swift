//
//  CallView.swift
//  CcCompanion (Lamp)
//
//  珩 2026-09-11 打电话 —— 对讲机式语音通话页（1.3 build 241）。
//  进来就一直听：SFSpeechRecognizer 实时转文字，一句话稳定 0.9 秒没新字就自动发出去。
//
//  珩 2026-09-12（1.3 build 244）「轻装的我」语音道，默认引擎（设置 → FEATURES → 通话引擎 可切回完整对讲机）：
//  - 进页 POST /voicelane/call/start（call_id = lamp_时间戳_随机）；一句话稳定后 POST /call/turn，
//    用 URLSession.bytes 逐行读 SSE：text_delta 逐字上屏，sentence 的 mp3 按 generation/seq 排队播（预取），
//    只播当前 generation；收到 cancelled 或发出新 turn 时立刻停播清队列。
//  - 抢话：播放期间麦克风不关（playAndRecord + 外放 + 混音，输入节点开系统回声消除）；
//    她一开口（partial ≥3 字且 0.4 秒内还在长）就停播、清队列，下一句发出去时服务端自然打断旧的。
//  - 回声兜底：转写开头与最近 12 秒播过的句子重合的部分剥掉，整段都是回声就丢。
//  - 她的话不再发 "🎤 …" 进主会话（避免双份注入）；挂断 POST /call/end，服务端写通话摘要。退后台超过 2 分钟也 end。
//  - 页面底部小字：首句 x.x s（turn 发出 → 第一句音频开播）。
//  完整引擎（旧路）：发 "🎤 文本" 到 ccc /chat/send，等回复，轮询 /call/audio 拿 mp3 播；播时暂停听。
//

import SwiftUI
import AVFoundation
import Combine
import UIKit

// MARK: - Controller

@MainActor
final class CallController: ObservableObject {
    enum Phase { case connecting, listening, thinking, speaking }

    struct Line: Identifiable, Equatable {
        let id: String
        let isUser: Bool
        let text: String
    }

    static let engineLiteKey = "call_engine_lite"

    @Published var phase: Phase = .listening
    @Published var lines: [Line] = []
    @Published var liveTranscript: String = ""
    /// 轻装：我正在说的话（text_delta 逐字），done 后并入 lines
    @Published var aiLive: String = ""
    @Published var isMuted: Bool = false
    @Published var elapsed: Int = 0
    @Published var errorText: String? = nil
    @Published private(set) var isActive: Bool = false
    /// 轻装：本通电话最近一轮的首句延迟（turn 发出 → 第一句开播）
    @Published var firstSentenceLatency: Double? = nil
    /// 通话被系统性结束（后台超时 / 语音道进程没了）→ 页面自动退出
    @Published private(set) var ended: Bool = false

    let callId: String
    let speech = SpeechRecognizer()
    /// 轻装引擎（voicelane）。/call/start 失败会当场回退成完整引擎。
    private(set) var useLane: Bool

    private weak var vm: ChatViewModel?
    private var cancellables = Set<AnyCancellable>()
    private var seenIds: Set<String> = []
    private var queue: [ChatMessage] = []
    private var player: AVAudioPlayer? = nil
    private var tickTask: Task<Void, Never>? = nil
    private var thinkingSince: Date? = nil
    private var draining = false
    private var restarting = false
    private var inForeground = true
    private var lastCommitted: String = ""
    private var lastCommitAt: Date = .distantPast
    private var torndown = false
    // 珩 2026-09-12 build 243：麦克风重开看门狗——连续失败计数，满 3 次停手并在页面提示
    private var micRetryCount: Int = 0
    private let maxMicRetries = 3
    static let micFailedText = "麦克风重开失败，点静音键两下"
    // 播放结束用 AVAudioPlayerDelegate 通知，不再靠 isPlaying 轮询
    private var playbackWaiter: PlaybackWaiter? = nil

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg)
    }()

    // MARK: 轻装（voicelane）状态

    private let laneBase: URL
    private var laneReady = false
    private var pendingTurn: String? = nil
    private var turnTask: Task<Void, Never>? = nil
    private var currentGen: String? = nil
    /// 被抢话打断的 generation：后面再来的 sentence / text_delta 一律丢
    private var droppedGen: String? = nil
    private struct Clip {
        let gen: String
        let seq: Int
        let text: String
        let fetch: Task<Data?, Never>
    }
    private var clips: [Clip] = []
    private var drainingClips = false
    /// 最近播过的句子（回声过滤用）
    private var spokenRecent: [(text: String, at: Date)] = []
    private var lastPlaybackEnd: Date = .distantPast
    private var echoSeenThisSegment = false
    private var turnSentAt: Date? = nil
    /// 这一轮的 SSE 还开着（done / cancelled / error / 断流 之前）：句子还在路上，队列空了也别急着切回"在听"
    private var turnOpen = false
    private var turnSerial = 0
    private var firstAudioMarked = false
    private var lastPartialLen: Int = 0
    private var lastPartialAt: Date = .distantPast
    private var backgroundEndTask: Task<Void, Never>? = nil
    private let laneSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 90      // SSE 两个字节之间最长等 90 秒
        cfg.timeoutIntervalForResource = 600
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    init(vm: ChatViewModel) {
        self.vm = vm
        let lite = UserDefaults.standard.object(forKey: Self.engineLiteKey) as? Bool ?? true
        self.useLane = lite
        if lite {
            let ts = Int(Date().timeIntervalSince1970)
            let rnd = String(UUID().uuidString.prefix(6)).lowercased()
            self.callId = "lamp_\(ts)_\(rnd)"
        } else {
            self.callId = String(UUID().uuidString.prefix(8)).lowercased()
        }
        self.laneBase = Self.laneBaseURL()
    }

    /// https://bing-k.top/ccc → https://bing-k.top/voicelane
    static func laneBaseURL() -> URL {
        var c = URLComponents(url: CcServerConfig.serverURL, resolvingAgainstBaseURL: false)
        c?.path = "/voicelane"
        c?.query = nil
        return c?.url ?? URL(string: "https://bing-k.top/voicelane")!
    }

    // MARK: lifecycle

    func start() {
        guard !isActive, !torndown, vm != nil else { return }
        isActive = true
        speech.managesAudioSession = false
        speech.voiceProcessing = useLane
        // SFSpeech 单次任务约 60 秒到头 / 出错自己结束 → 还在通话就立刻重开，不等看门狗那 1 秒
        speech.onTaskEnded = { [weak self] _ in
            guard let self, self.isActive else { return }
            Task { await self.resumeListeningIfNeeded() }
        }
        configureAudioSession()
        UIApplication.shared.isIdleTimerDisabled = true

        // 正在听到的：字幕 + 抢话判断 + 回声过滤
        speech.$transcript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] t in self?.onPartial(t) }
            .store(in: &cancellables)

        // 一句话说完（0.9 秒没新字）→ 发出去
        speech.$transcript
            .receive(on: DispatchQueue.main)
            .debounce(for: .seconds(0.9), scheduler: DispatchQueue.main)
            .sink { [weak self] t in self?.commitIfStable(t) }
            .store(in: &cancellables)

        if useLane {
            phase = .connecting
            Task { await laneStart() }
        } else {
            subscribeFullEngine()
        }

        // 每秒：计时 + 看门狗（识别任务自己结束了就重开；想太久就回到听）
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.isActive else { return }
                self.elapsed += 1
                if self.phase == .thinking, let since = self.thinkingSince, Date().timeIntervalSince(since) > 90 {
                    self.phase = .listening
                    self.thinkingSince = nil
                }
                await self.resumeListeningIfNeeded()
            }
        }
        Task { await resumeListeningIfNeeded() }
    }

    /// 完整引擎：珩的新回复从主会话来
    private func subscribeFullEngine() {
        guard let vm else { return }
        seenIds = Set(vm.messages.map(\.id))
        vm.$messages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] msgs in self?.ingest(msgs) }
            .store(in: &cancellables)
    }

    /// 挂断：停一切 + 通知服务端。
    func hangUp() {
        guard isActive else { return }
        if useLane {
            let req = laneRequest("call/end", json: ["call_id": callId])
            let s = laneSession
            teardown()
            Task.detached { _ = try? await s.data(for: req) }
        } else {
            let vm = self.vm
            let cid = callId
            teardown()
            Task { await vm?.send(text: "📞 [call_end]", meta: ["call": false, "call_end": true, "call_id": cid]) }
        }
    }

    /// 只收尾不发消息（页面被别的方式关掉时兜底）。幂等。
    func teardown() {
        guard !torndown else { return }
        torndown = true
        isActive = false
        tickTask?.cancel()
        tickTask = nil
        backgroundEndTask?.cancel()
        backgroundEndTask = nil
        turnTask?.cancel()
        turnTask = nil
        cancellables.removeAll()
        speech.onTaskEnded = nil
        speech.stop()
        stopPlayback(clearQueue: true)
        queue.removeAll()
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func setForeground(_ fg: Bool) {
        inForeground = fg
        if !fg {
            speech.stop()
            liveTranscript = ""
            if useLane {
                // 退后台：先停播；超过 2 分钟没回来就结束这通电话
                stopPlayback(clearQueue: true)
                if phase == .speaking { phase = .listening }
                backgroundEndTask?.cancel()
                backgroundEndTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 120_000_000_000)
                    guard let self, !Task.isCancelled, self.isActive, !self.inForeground else { return }
                    self.errorText = "后台太久，电话挂了"
                    self.hangUp()
                    self.ended = true
                }
            }
        } else if isActive {
            backgroundEndTask?.cancel()
            backgroundEndTask = nil
            configureAudioSession()
            Task { await resumeListeningIfNeeded() }
        }
    }

    func toggleMute() {
        isMuted.toggle()
        if isMuted {
            speech.stop()
            liveTranscript = ""
        } else {
            // 静音再取消 = 手动重置看门狗的失败计数，重新试
            micRetryCount = 0
            if errorText == Self.micFailedText { errorText = nil }
            Task { await resumeListeningIfNeeded() }
        }
    }

    // MARK: audio session

    private func configureAudioSession() {
        let s = AVAudioSession.sharedInstance()
        do {
            // 轻装：播放时麦克风照开，允许混音；完整：播放/收音轮流
            let opts: AVAudioSession.CategoryOptions = useLane ? [.defaultToSpeaker, .mixWithOthers] : [.defaultToSpeaker]
            try s.setCategory(.playAndRecord, mode: .default, options: opts)
            try s.setActive(true)
            if let builtin = s.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? s.setPreferredInput(builtin)
            }
        } catch {
            errorText = "音频通道没打开: \(error.localizedDescription)"
        }
    }

    // MARK: listening

    /// 看门狗 / 各处唤起：phase 在听、麦克风却没在跑 → 重开一次。
    /// "isRecording 为真但 audioEngine 没在跑" 也算坏了（旧 engine 挂着老格式的 tap 就是这种半截状态）。
    /// 连续失败满 maxMicRetries 次就停手，页面提示；静音键点两下重置计数再试。
    /// 轻装引擎：播放期间也开着（抢话靠它）。
    private func resumeListeningIfNeeded() async {
        guard isActive, inForeground, !isMuted, !restarting else { return }
        if !useLane && phase == .speaking { return }
        if speech.isRecording && speech.isEngineRunning { return }
        guard micRetryCount < maxMicRetries else { return }
        restarting = true
        defer { restarting = false }
        if speech.isRecording { speech.stop() }
        // 播完 mp3 / 路由变化之后 session 可能已经不是 playAndRecord+外放，先摆回来再建 engine
        if !useLane || player == nil { configureAudioSession() }
        await speech.start()
        guard isActive else { return }
        if speech.isRecording && speech.isEngineRunning {
            micRetryCount = 0
            echoSeenThisSegment = false
            lastPartialLen = 0
            lastPartialAt = .distantPast
            if errorText == Self.micFailedText || (speech.lastError ?? "").isEmpty { errorText = nil }
        } else {
            micRetryCount += 1
            if micRetryCount >= maxMicRetries {
                errorText = Self.micFailedText
            } else if let e = speech.lastError, !e.isEmpty {
                errorText = e
            }
        }
    }

    /// 每次 partial：字幕 +（轻装）回声过滤 + 抢话判断
    private func onPartial(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard useLane else { liveTranscript = t; return }
        var shown = t
        switch filterEcho(t) {
        case .echo:
            echoSeenThisSegment = true
            liveTranscript = ""
            return
        case .partialEcho(let rest):
            echoSeenThisSegment = true
            shown = rest
        case .clean:
            break
        }
        liveTranscript = shown
        let n = shown.count
        let now = Date()
        if phase == .speaking, n >= 3, n > lastPartialLen, now.timeIntervalSince(lastPartialAt) < 0.4 {
            bargeIn()
        }
        if n != lastPartialLen {
            lastPartialLen = n
            lastPartialAt = now
        }
    }

    private func commitIfStable(_ raw: String) {
        guard isActive, !isMuted, speech.isRecording else { return }
        if !useLane && phase == .speaking { return }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if useLane {
            switch filterEcho(text) {
            case .echo:
                // 整段都是回声：清掉这段识别，重新开听
                liveTranscript = ""
                speech.stop()
                Task { await resumeListeningIfNeeded() }
                return
            case .partialEcho(let rest):
                text = rest
            case .clean:
                break
            }
            guard !text.isEmpty else { return }
        }
        // 识别任务 stop 后可能再吐一次 final 结果，5 秒内同一句不重发
        if text == lastCommitted, Date().timeIntervalSince(lastCommitAt) < 5 { return }
        lastCommitted = text
        lastCommitAt = Date()
        liveTranscript = ""
        speech.stop()   // 结束这段识别；轻装立刻重开，完整由看门狗 1 秒内重开
        appendLine(Line(id: "u-\(lastCommitAt.timeIntervalSince1970)", isUser: true, text: text))
        phase = .thinking
        thinkingSince = Date()
        if useLane {
            Task { await resumeListeningIfNeeded() }
            if laneReady {
                sendTurn(text)
            } else {
                pendingTurn = text
            }
        } else {
            let cid = callId
            Task { [weak vm] in
                await vm?.send(text: "🎤 " + text, meta: ["call": true, "call_id": cid])
            }
        }
    }

    private func appendLine(_ line: Line) {
        lines.append(line)
        if lines.count > 6 { lines.removeFirst(lines.count - 6) }
    }

    // MARK: 回声过滤

    private static func normalize(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars where CharacterSet.alphanumerics.contains(u) { out.append(u) }
        return String(out)
    }

    private enum EchoVerdict { case clean, partialEcho(String), echo }

    /// 转写开头与最近 12 秒播过的句子重合 → 剥掉重合的整句；剩下太短就整段当回声。
    /// 剥不掉但开头 6 个字出现在播过的句子里 → 整段当回声。
    private func filterEcho(_ t: String) -> EchoVerdict {
        let norm = Self.normalize(t)
        guard norm.count >= 3 else { return .clean }
        let cutoff = Date().addingTimeInterval(-12)
        let recent = spokenRecent.filter { $0.at > cutoff }.map { Self.normalize($0.text) }.filter { $0.count >= 2 }
        guard !recent.isEmpty else { return .clean }
        var rest = Substring(norm)
        var stripped = false
        var again = true
        while again && !rest.isEmpty {
            again = false
            for s in recent where rest.hasPrefix(s) {
                rest = rest.dropFirst(s.count)
                stripped = true
                again = true
            }
        }
        if stripped {
            return rest.count >= 2 ? .partialEcho(String(rest)) : .echo
        }
        let key = String(norm.prefix(6))
        if recent.contains(where: { $0.contains(key) }) { return .echo }
        return .clean
    }

    // MARK: 轻装：语音道

    private func laneURL(_ path: String) -> URL {
        let p = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return laneBase.appendingPathComponent(p)
    }

    private func laneRequest(_ path: String, json: [String: Any]) -> URLRequest {
        var req = CcServerConfig.authenticatedRequest(url: laneURL(path), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        return req
    }

    private func laneStart() async {
        let req = laneRequest("call/start", json: ["call_id": callId])
        var ok = false
        var why = ""
        do {
            let (data, resp) = try await laneSession.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            ok = code == 200
            if !ok { why = "HTTP \(code) \(String(data: data.prefix(80), encoding: .utf8) ?? "")" }
        } catch {
            why = error.localizedDescription
        }
        guard isActive else { return }
        if ok {
            laneReady = true
            if phase == .connecting { phase = .listening }
            if let p = pendingTurn {
                pendingTurn = nil
                phase = .thinking
                thinkingSince = Date()
                sendTurn(p)
            }
        } else {
            // 语音道没接通 → 当场回退完整引擎（旧路）
            useLane = false
            speech.voiceProcessing = false
            errorText = "轻装通道没接通（\(why)），改走完整通话"
            subscribeFullEngine()
            if phase == .connecting { phase = .listening }
            if let p = pendingTurn {
                pendingTurn = nil
                let cid = callId
                Task { [weak vm] in await vm?.send(text: "🎤 " + p, meta: ["call": true, "call_id": cid]) }
            }
        }
    }

    private func sendTurn(_ text: String) {
        turnTask?.cancel()
        turnTask = nil
        stopPlayback(clearQueue: true)
        droppedGen = nil
        currentGen = nil
        aiLive = ""
        phase = .thinking
        thinkingSince = Date()
        turnSentAt = Date()
        firstAudioMarked = false
        turnOpen = true
        turnSerial += 1
        let serial = turnSerial
        let req = laneRequest("call/turn", json: ["call_id": callId, "text": text])
        turnTask = Task { [weak self] in
            await self?.readTurnStream(req)
            self?.turnClosed(serial)
        }
    }

    /// 这一轮的流结束了（不管怎么结束的）：句子都播完了就回到"在听"。旧轮的收尾（被新轮 cancel 的）不动新轮。
    private func turnClosed(_ serial: Int) {
        guard serial == turnSerial else { return }
        turnOpen = false
        guard isActive else { return }
        if clips.isEmpty && !drainingClips && phase != .connecting {
            settleToListening()
        }
    }

    /// 回到"在听"；这段识别里混进过回声就换一段干净的
    private func settleToListening() {
        phase = .listening
        thinkingSince = nil
        if echoSeenThisSegment {
            speech.stop()
            liveTranscript = ""
            Task { await resumeListeningIfNeeded() }
        }
    }

    private func readTurnStream(_ req: URLRequest) async {
        var gen: String? = nil
        do {
            let (bytes, resp) = try await laneSession.bytes(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                guard isActive, !Task.isCancelled else { return }
                if code == 404 || code == 410 {
                    errorText = "语音道断了（\(code)），重新接…"
                    laneReady = false
                    if phase == .thinking { phase = .listening }
                    await laneStart()
                } else {
                    errorText = "语音道 HTTP \(code)"
                    if phase == .thinking { phase = .listening }
                }
                return
            }
            for try await line in bytes.lines {
                guard !Task.isCancelled, isActive else { return }
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let d = payload.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let type = obj["type"] as? String else { continue }
                if type == "start" {
                    gen = obj["generation_id"] as? String
                    currentGen = gen
                    droppedGen = nil
                    continue
                }
                guard let g = gen, g == currentGen, g != droppedGen else { continue }
                switch type {
                case "text_delta":
                    if let t = obj["text"] as? String { aiLive += t }
                case "sentence":
                    guard let seq = obj["seq"] as? Int, let text = obj["text"] as? String else { continue }
                    guard let path = obj["audio_url"] as? String, !path.isEmpty else { continue }   // 这句合成失败：只上字幕
                    let url = laneURL(path)
                    let s = laneSession
                    let fetch = Task<Data?, Never>.detached {
                        guard let (data, resp) = try? await s.data(for: CcServerConfig.authenticatedRequest(url: url)),
                              (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 100 else { return nil }
                        return data
                    }
                    clips.append(Clip(gen: g, seq: seq, text: text, fetch: fetch))
                    drainClips()
                case "cancelled":
                    stopPlayback(clearQueue: true)
                    if phase != .connecting { phase = .listening }
                    return
                case "done":
                    let full = (obj["text"] as? String ?? aiLive).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !full.isEmpty { appendLine(Line(id: "a-\(g)-\(Date().timeIntervalSince1970)", isUser: false, text: full)) }
                    aiLive = ""
                    thinkingSince = nil
                    return
                case "error":
                    errorText = obj["message"] as? String ?? "语音道出错"
                    if phase == .thinking { phase = .listening }
                default:
                    break
                }
            }
        } catch {
            guard !Task.isCancelled, isActive else { return }
            errorText = "语音道断了: \(error.localizedDescription)"
            if phase == .thinking { phase = .listening }
        }
    }

    /// 抢话：她一开口就停播、清队列；这一轮的后续句子全丢。下一句发出去时服务端会打断旧的。
    private func bargeIn() {
        guard phase == .speaking else { return }
        droppedGen = currentGen
        turnTask?.cancel()
        turnTask = nil
        stopPlayback(clearQueue: true)
        if !aiLive.isEmpty {
            appendLine(Line(id: "a-cut-\(Date().timeIntervalSince1970)", isUser: false, text: aiLive + "…"))
            aiLive = ""
        }
        phase = .listening
    }

    private func stopPlayback(clearQueue: Bool) {
        if clearQueue {
            for c in clips { c.fetch.cancel() }
            clips.removeAll()
        }
        if let p = player {
            p.delegate = nil
            p.stop()
            player = nil
            lastPlaybackEnd = Date()
        }
        playbackWaiter?.cancel()
        playbackWaiter = nil
    }

    private func drainClips() {
        guard isActive, !drainingClips else { return }
        guard !clips.isEmpty else {
            // 流还开着 → 下一句在路上，保持"在说"；流关了才回到"在听"
            if phase == .speaking && !turnOpen { settleToListening() }
            return
        }
        let clip = clips.removeFirst()
        guard clip.gen == currentGen, clip.gen != droppedGen else {
            clip.fetch.cancel()
            drainClips()
            return
        }
        drainingClips = true
        Task {
            let data = await clip.fetch.value
            if let data, isActive, clip.gen == currentGen, clip.gen != droppedGen {
                if !firstAudioMarked, let t0 = turnSentAt {
                    firstAudioMarked = true
                    firstSentenceLatency = Date().timeIntervalSince(t0)
                }
                spokenRecent.append((text: clip.text, at: Date()))
                if spokenRecent.count > 40 { spokenRecent.removeFirst(spokenRecent.count - 40) }
                phase = .speaking
                thinkingSince = nil
                await playClip(data)
            }
            drainingClips = false
            drainClips()
        }
    }

    /// 轻装：播一句；麦克风保持开着。
    private func playClip(_ data: Data) async {
        do {
            let s = AVAudioSession.sharedInstance()
            if s.category != .playAndRecord { configureAudioSession() }
            let p = try AVAudioPlayer(data: data)
            p.volume = 1.0
            let waiter = PlaybackWaiter()
            p.delegate = waiter
            playbackWaiter = waiter
            p.prepareToPlay()
            player = p
            let duration = p.duration
            if p.play() {
                await waiter.wait(timeout: max(1.0, duration + 3.0))
            }
            p.delegate = nil
        } catch {
            errorText = "播放失败: \(error.localizedDescription)"
        }
        playbackWaiter = nil
        player = nil
        lastPlaybackEnd = Date()
    }

    // MARK: 完整引擎：receiving

    private func ingest(_ msgs: [ChatMessage]) {
        guard isActive else { return }
        var fresh: [ChatMessage] = []
        for m in msgs where !seenIds.contains(m.id) {
            seenIds.insert(m.id)
            guard m.role == "assistant", m.localId == nil else { continue }
            let t = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            fresh.append(m)
        }
        guard !fresh.isEmpty else { return }
        for m in fresh {
            appendLine(Line(id: m.id, isUser: false, text: m.text))
            queue.append(m)
        }
        thinkingSince = nil
        drainIfNeeded()
    }

    private func drainIfNeeded() {
        guard isActive, !draining else { return }
        guard !queue.isEmpty else {
            if phase == .speaking { phase = .listening }
            return
        }
        draining = true
        let next = queue.removeFirst()
        Task {
            await speakOrShow(next)
            draining = false
            drainIfNeeded()
        }
    }

    private func speakOrShow(_ m: ChatMessage) async {
        var url = m.multiLangAudios()["zh"]
        if url == nil { url = await waitForAudio(ts: m.ts) }
        guard isActive else { return }
        guard let url else {
            // 没音频：只显示字幕，回到听
            if phase != .speaking { phase = .listening }
            return
        }
        await play(url)
    }

    nonisolated private struct CallAudioResponse: Decodable {
        let ok: Bool?
        let pending: Bool?
        let audio_zh: String?
    }

    /// 轮询 GET /call/audio?ts= 直到 mp3 生成好（最多 45 秒）。
    private func waitForAudio(ts: String) async -> URL? {
        let base = CcServerConfig.serverURL.appendingPathComponent("call/audio")
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "ts", value: ts)]
        guard let url = comps?.ccPlusSafeURL else { return nil }
        let deadline = Date().addingTimeInterval(45)
        var notPendingStreak = 0
        while isActive, Date() < deadline {
            if let (data, _) = try? await session.data(for: CcServerConfig.authenticatedRequest(url: url)),
               let r = try? JSONDecoder().decode(CallAudioResponse.self, from: data) {
                if let a = r.audio_zh, !a.isEmpty {
                    return a.hasPrefix("http") ? URL(string: a) : URL(string: CcServerConfig.serverURL.absoluteString + a)
                }
                if r.pending != true {
                    // server 没在生成（不在通话态 / 失败）。多确认一次防止刚落库还没登记
                    notPendingStreak += 1
                    if notPendingStreak >= 2 { return nil }
                } else {
                    notPendingStreak = 0
                }
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        return nil
    }

    // MARK: 完整引擎：playback

    private func play(_ url: URL) async {
        speech.stop()
        liveTranscript = ""
        phase = .speaking
        guard let (data, _) = try? await session.data(for: CcServerConfig.authenticatedRequest(url: url)),
              isActive else {
            if isActive { phase = .listening }
            return
        }
        do {
            // 播放前：麦克风先停干净，session 设 playAndRecord + 外放
            configureAudioSession()
            let p = try AVAudioPlayer(data: data)
            p.volume = 1.0
            let waiter = PlaybackWaiter()
            p.delegate = waiter
            playbackWaiter = waiter
            p.prepareToPlay()
            player = p
            let duration = p.duration
            if p.play() {
                // 等 AVAudioPlayerDelegate 的 didFinishPlaying；兜底：时长 + 3 秒没回调也放行
                await waiter.wait(timeout: max(1.0, duration + 3.0))
            }
            p.delegate = nil
        } catch {
            errorText = "播放失败: \(error.localizedDescription)"
        }
        playbackWaiter = nil
        if player != nil { player = nil }
        guard isActive else { return }
        // 播完：重新激活 session、重建 engine/tap/request/task 再开听
        configureAudioSession()
        if queue.isEmpty { phase = .listening }
        await resumeListeningIfNeeded()
    }
}

/// AVAudioPlayer 播完 / 解码失败 → 唤醒等在 wait() 上的那个 continuation（只唤一次）。
private final class PlaybackWaiter: NSObject, AVAudioPlayerDelegate {
    private var continuation: CheckedContinuation<Void, Never>? = nil
    private var finished = false
    private var timeoutTask: Task<Void, Never>? = nil

    func wait(timeout: TimeInterval) async {
        if finished { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finish()
            }
        }
    }

    func cancel() { finish() }

    private func finish() {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation?.resume()
        continuation = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.finish() }
    }
}

// MARK: - View

struct CallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var vm: ChatViewModel
    @StateObject private var call: CallController
    @AppStorage("ai_name") private var aiName: String = CcDefaultAIName
    @State private var pulse: Bool = false

    init(vm: ChatViewModel) {
        self._vm = ObservedObject(wrappedValue: vm)
        self._call = StateObject(wrappedValue: CallController(vm: vm))
    }

    private var statusText: String {
        switch call.phase {
        case .connecting: return "接通中…"
        case .speaking: return "\(aiName)在说"
        case .thinking: return "\(aiName)在想…"
        case .listening:
            if call.isMuted { return "已静音" }
            if !call.useLane && vm.isCcTyping { return "\(aiName)在想…" }
            return "我在听"
        }
    }

    private var durationText: String {
        let m = call.elapsed / 60, s = call.elapsed % 60
        return String(format: "%02d:%02d", m, s)
    }

    private var ringColor: Color {
        switch call.phase {
        case .connecting: return Color.ccTextDim.opacity(0.6)
        case .speaking: return Color.ccAccent
        case .thinking: return Color.ccTextDim
        case .listening: return call.isMuted ? Color.ccTextDim.opacity(0.4) : Color.ccAssistant
        }
    }

    private var hintText: String {
        if call.isMuted { return "点一下麦克风继续说" }
        if call.useLane { return "直接说话就行，停一下我就接；我说的时候你也可以插嘴" }
        return "直接说话就行，停一下我就发出去"
    }

    var body: some View {
        ZStack {
            Color.ccBg.ignoresSafeArea()
            VStack(spacing: 0) {
                // 顶部：名字 + 时长
                VStack(spacing: 6) {
                    Text(aiName)
                        .font(.ccSerifAdaptive(size: 30, weight: .semibold))
                        .foregroundStyle(Color.ccText)
                    Text(durationText)
                        .font(.system(size: 16, design: .monospaced))
                        .foregroundStyle(Color.ccTextDim)
                }
                .padding(.top, 56)

                Spacer(minLength: 24)

                // 头像 + 呼吸圈
                ZStack {
                    Circle()
                        .stroke(ringColor.opacity(0.35), lineWidth: 2)
                        .frame(width: 176, height: 176)
                        .scaleEffect(pulse && call.phase != .listening ? 1.12 : 1.0)
                    Circle()
                        .stroke(ringColor.opacity(0.7), lineWidth: 3)
                        .frame(width: 148, height: 148)
                        .scaleEffect(pulse && call.phase == .speaking ? 1.06 : 1.0)
                    CcAvatarView(role: .ai, size: 128)
                        .frame(width: 128, height: 128)
                        .clipShape(Circle())
                        .shadow(color: Color.ccAccent.opacity(0.25), radius: 18, y: 6)
                }
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }

                Text(statusText)
                    .font(.ccSerifAdaptive(size: 18, weight: .semibold))
                    .foregroundStyle(call.phase == .listening && !call.isMuted ? Color.ccAccent : Color.ccTextDim)
                    .padding(.top, 22)
                    .animation(.easeInOut(duration: 0.2), value: statusText)

                // 字幕：最近两句 + 我正在说的（逐字）+ 正在听到的
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(call.lines.suffix(call.aiLive.isEmpty ? 2 : 1)) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Text(line.isUser ? "你" : aiName)
                                .font(.ccSerifAdaptive(size: 13, weight: .semibold))
                                .foregroundStyle(line.isUser ? Color.ccTextDim : Color.ccAccent)
                                .frame(width: 34, alignment: .trailing)
                            Text(line.text)
                                .font(.system(size: 16))
                                .foregroundStyle(Color.ccText)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if !call.aiLive.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Text(aiName)
                                .font(.ccSerifAdaptive(size: 13, weight: .semibold))
                                .foregroundStyle(Color.ccAccent)
                                .frame(width: 34, alignment: .trailing)
                            Text(call.aiLive)
                                .font(.system(size: 16))
                                .foregroundStyle(Color.ccText)
                                .lineLimit(4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if !call.liveTranscript.isEmpty, !call.isMuted {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "waveform")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.ccAccent)
                                .frame(width: 34, alignment: .trailing)
                            Text(call.liveTranscript)
                                .font(.system(size: 16))
                                .foregroundStyle(Color.ccTextDim)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if call.lines.isEmpty && call.liveTranscript.isEmpty && call.aiLive.isEmpty {
                        Text(hintText)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.ccTextDim)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    if let err = call.errorText, !err.isEmpty {
                        Text(err)
                            .font(.system(size: 12))
                            .foregroundStyle(.red.opacity(0.8))
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                .background(Color.ccCard.opacity(0.9))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 20)
                .padding(.top, 26)

                Spacer(minLength: 24)

                // 底部：静音 + 挂断
                HStack(spacing: 56) {
                    VStack(spacing: 8) {
                        Button(action: { call.toggleMute() }) {
                            Image(systemName: call.isMuted ? "mic.slash.fill" : "mic.fill")
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(call.isMuted ? Color.ccBg : Color.ccAccent)
                                .frame(width: 68, height: 68)
                                .background(call.isMuted ? Color.ccAccent : Color.ccCard)
                                .clipShape(Circle())
                        }
                        .accessibilityLabel(call.isMuted ? "取消静音" : "静音")
                        Text(call.isMuted ? "已静音" : "静音")
                            .font(.ccSerifAdaptive(size: 12))
                            .foregroundStyle(Color.ccTextDim)
                    }
                    VStack(spacing: 8) {
                        Button(action: {
                            call.hangUp()
                            dismiss()
                        }) {
                            Image(systemName: "phone.down.fill")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 76, height: 76)
                                .background(Color(red: 0.93, green: 0.33, blue: 0.40))
                                .clipShape(Circle())
                                .shadow(color: Color.black.opacity(0.15), radius: 10, y: 4)
                        }
                        .accessibilityLabel("挂断")
                        Text("挂断")
                            .font(.ccSerifAdaptive(size: 12))
                            .foregroundStyle(Color.ccTextDim)
                    }
                }
                .padding(.bottom, 16)

                // 底部小字：引擎 + 首句延迟
                HStack(spacing: 6) {
                    Text(call.useLane ? "轻装" : "完整")
                    if let l = call.firstSentenceLatency {
                        Text("·")
                        Text(String(format: "首句 %.1f s", l))
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.ccTextDim.opacity(0.7))
                .padding(.bottom, 24)
            }
        }
        .onAppear { call.start() }
        .onDisappear { call.teardown() }
        .onChange(of: scenePhase) { _, phase in
            call.setForeground(phase == .active)
        }
        .onChange(of: call.ended) { _, e in
            if e { dismiss() }
        }
        .interactiveDismissDisabled(true)
    }
}
