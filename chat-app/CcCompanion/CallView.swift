//
//  CallView.swift
//  CcCompanion (Lamp)
//
//  珩 2026-09-11 打电话 —— 对讲机式语音通话页（1.3 build 241）。
//  进来就一直听：SFSpeechRecognizer 实时转文字，一句话稳定 0.9 秒没新字就自动发出去
//  （前面加 "🎤 "，metadata 带 {"call":true,"call_id":…}），server 把我的回复经 speech_proxy
//  转成 mp3 填进 audio_zh；这里收到新回复就播（外放），播的时候暂停听，播完接着听。
//  挂断发一条 "📞 [call_end]"。
//

import SwiftUI
import AVFoundation
import Combine
import UIKit

// MARK: - Controller

@MainActor
final class CallController: ObservableObject {
    enum Phase { case listening, thinking, speaking }

    struct Line: Identifiable, Equatable {
        let id: String
        let isUser: Bool
        let text: String
    }

    @Published var phase: Phase = .listening
    @Published var lines: [Line] = []
    @Published var liveTranscript: String = ""
    @Published var isMuted: Bool = false
    @Published var elapsed: Int = 0
    @Published var errorText: String? = nil
    @Published private(set) var isActive: Bool = false

    let callId: String
    let speech = SpeechRecognizer()

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

    init(vm: ChatViewModel) {
        self.vm = vm
        self.callId = String(UUID().uuidString.prefix(8)).lowercased()
    }

    // MARK: lifecycle

    func start() {
        guard !isActive, !torndown, let vm else { return }
        isActive = true
        seenIds = Set(vm.messages.map(\.id))
        speech.managesAudioSession = false
        // SFSpeech 单次任务约 60 秒到头 / 出错自己结束 → 还在通话就立刻重开，不等看门狗那 1 秒
        speech.onTaskEnded = { [weak self] _ in
            guard let self, self.isActive else { return }
            Task { await self.resumeListeningIfNeeded() }
        }
        configureAudioSession()
        UIApplication.shared.isIdleTimerDisabled = true

        // 一句话说完（0.9 秒没新字）→ 发出去
        speech.$transcript
            .receive(on: DispatchQueue.main)
            .handleEvents(receiveOutput: { [weak self] t in self?.liveTranscript = t })
            .debounce(for: .seconds(0.9), scheduler: DispatchQueue.main)
            .sink { [weak self] t in self?.commitIfStable(t) }
            .store(in: &cancellables)

        // 珩的新回复
        vm.$messages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] msgs in self?.ingest(msgs) }
            .store(in: &cancellables)

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

    /// 挂断：停一切 + 发 call_end。
    func hangUp() {
        guard isActive else { return }
        let vm = self.vm
        let cid = callId
        teardown()
        Task { await vm?.send(text: "📞 [call_end]", meta: ["call": false, "call_end": true, "call_id": cid]) }
    }

    /// 只收尾不发消息（页面被别的方式关掉时兜底）。幂等。
    func teardown() {
        guard !torndown else { return }
        torndown = true
        isActive = false
        tickTask?.cancel()
        tickTask = nil
        cancellables.removeAll()
        speech.onTaskEnded = nil
        speech.stop()
        player?.delegate = nil
        player?.stop()
        player = nil
        playbackWaiter?.cancel()
        playbackWaiter = nil
        queue.removeAll()
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func setForeground(_ fg: Bool) {
        inForeground = fg
        if !fg {
            speech.stop()
            liveTranscript = ""
        } else if isActive {
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
            try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
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
    private func resumeListeningIfNeeded() async {
        guard isActive, inForeground, !isMuted, phase != .speaking, !restarting else { return }
        if speech.isRecording && speech.isEngineRunning { return }
        guard micRetryCount < maxMicRetries else { return }
        restarting = true
        defer { restarting = false }
        if speech.isRecording { speech.stop() }
        // 播完 mp3 / 路由变化之后 session 可能已经不是 playAndRecord+外放，先摆回来再建 engine
        configureAudioSession()
        await speech.start()
        guard isActive else { return }
        if speech.isRecording && speech.isEngineRunning {
            micRetryCount = 0
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

    private func commitIfStable(_ raw: String) {
        guard isActive, !isMuted, phase != .speaking, speech.isRecording else { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // 识别任务 stop 后可能再吐一次 final 结果，5 秒内同一句不重发
        if text == lastCommitted, Date().timeIntervalSince(lastCommitAt) < 5 { return }
        lastCommitted = text
        lastCommitAt = Date()
        liveTranscript = ""
        speech.stop()   // 结束这段识别；看门狗 1 秒内重开
        appendLine(Line(id: "u-\(lastCommitAt.timeIntervalSince1970)", isUser: true, text: text))
        phase = .thinking
        thinkingSince = Date()
        let cid = callId
        Task { [weak vm] in
            await vm?.send(text: "🎤 " + text, meta: ["call": true, "call_id": cid])
        }
    }

    private func appendLine(_ line: Line) {
        lines.append(line)
        if lines.count > 6 { lines.removeFirst(lines.count - 6) }
    }

    // MARK: receiving

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

    // MARK: playback

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
        case .speaking: return "\(aiName)在说"
        case .thinking: return "\(aiName)在想…"
        case .listening:
            if call.isMuted { return "已静音" }
            if vm.isCcTyping { return "\(aiName)在想…" }
            return "我在听"
        }
    }

    private var durationText: String {
        let m = call.elapsed / 60, s = call.elapsed % 60
        return String(format: "%02d:%02d", m, s)
    }

    private var ringColor: Color {
        switch call.phase {
        case .speaking: return Color.ccAccent
        case .thinking: return Color.ccTextDim
        case .listening: return call.isMuted ? Color.ccTextDim.opacity(0.4) : Color.ccAssistant
        }
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

                // 字幕：最近两句 + 正在听到的
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(call.lines.suffix(2)) { line in
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
                    if call.lines.isEmpty && call.liveTranscript.isEmpty {
                        Text(call.isMuted ? "点一下麦克风继续说" : "直接说话就行，停一下我就发出去")
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
                .padding(.bottom, 48)
            }
        }
        .onAppear { call.start() }
        .onDisappear { call.teardown() }
        .onChange(of: scenePhase) { _, phase in
            call.setForeground(phase == .active)
        }
        .interactiveDismissDisabled(true)
    }
}
