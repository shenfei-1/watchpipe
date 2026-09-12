//
//  SpeechRecognizer.swift
//  CcCompanion
//
//  v0.5 语音转文字 — iOS 原生 SFSpeechRecognizer 实时转 不依赖 server Whisper
//
//  Info.plist 必须加:
//    NSSpeechRecognitionUsageDescription = "用语音跟 Cc 说话"
//    NSMicrophoneUsageDescription = "录音转文字"
//
//  珩 2026-09-12（1.3 build 243）打电话页麦克风重开修复：
//  - 每次 start() 都新建 AVAudioEngine / SFSpeechAudioBufferRecognitionRequest / recognitionTask，
//    旧的先 end 掉。之前复用同一个 engine：外放一段 mp3 之后 inputNode 的硬件格式变了，
//    旧 engine 的 tap 还挂着老格式，start() 表面成功但一个 buffer 都进不来 → 通话页"听不见"。
//  - 识别任务自己结束（isFinal / error / SFSpeech 单次约 60 秒上限）时回调 onTaskEnded，
//    通话页据此立刻重开，不用等看门狗。
//  - isEngineRunning 暴露给看门狗："isRecording 为真但 engine 没在跑"也算坏了。
//

import Foundation
import Speech
import AVFoundation
import Combine

@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published var transcript: String = ""
    @Published var isRecording: Bool = false
    @Published var lastError: String? = nil
    /// 珩 2026-09-11 打电话：通话页自己管 AVAudioSession（playAndRecord + 外放），
    /// 置 false 后 start/stop 不再碰 category / active。
    var managesAudioSession: Bool = true
    /// 识别任务不是被 stop() 结束、而是自己结束（final / error / 60 秒上限）时回调。
    /// 通话页用它立刻重开收音。回调在主线程。
    var onTaskEnded: ((_ error: Error?) -> Void)? = nil
    /// 珩 2026-09-12（1.3 build 244）轻装电话：播放时麦克风不关，输入节点开系统回声消除
    /// （setVoiceProcessingEnabled）。开失败（格式无效 / engine 起不来）自动退回普通输入，之后不再试。
    var voiceProcessing: Bool = false
    private var voiceProcessingFailed = false

    private let recognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine? = nil
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// 每次 start 加一；旧任务的回调带着旧 generation 进来直接忽略，防止"上一段的 final 结果"污染新一段。
    private var generation: Int = 0
    private var stoppingManually = false

    /// audioEngine 真的在跑（有 tap、有 buffer 进来）。
    var isEngineRunning: Bool { audioEngine?.isRunning ?? false }

    init() {
        // 默认中文 想用别的 locale 改这里 (eg "en-US")
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    func toggle() async {
        if isRecording {
            stop()
        } else {
            await start()
        }
    }

    func start() async {
        // 申请权限
        let speechAuth = await requestSpeechAuth()
        guard speechAuth == .authorized else {
            self.lastError = "语音识别没权限 设置 → 隐私 → 语音识别"
            return
        }
        let micAuth = await requestMicAuth()
        guard micAuth else {
            self.lastError = "麦克风没权限 设置 → 隐私 → 麦克风"
            return
        }

        guard let recognizer = recognizer, recognizer.isAvailable else {
            self.lastError = "语音识别不可用"
            return
        }

        // 先把上一段彻底收掉（engine / tap / request / task 全部丢弃）
        tearDownEngine()

        // 设置 audio session — iOS 18 用最简 .record + .default 兼容性最好
        if managesAudioSession {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.record, mode: .default, options: [])
                try session.setActive(true, options: .notifyOthersOnDeactivation)
                // 强制走默认 builtin mic (避免 stuck 在 stale ble device)
                if let builtin = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                    try? session.setPreferredInput(builtin)
                }
            } catch {
                self.lastError = "audio session 失败: \(error.localizedDescription)"
                return
            }
        }

        generation &+= 1
        let gen = generation

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if #available(iOS 16.0, *) {
            req.addsPunctuation = true
        }
        self.request = req

        // 每次都是全新的 engine：inputNode 会按当前 AVAudioSession 的硬件格式初始化
        let engine = AVAudioEngine()
        self.audioEngine = engine
        let inputNode = engine.inputNode
        let wantVP = voiceProcessing && !voiceProcessingFailed
        if wantVP {
            do { try inputNode.setVoiceProcessingEnabled(true) } catch { voiceProcessingFailed = true }
        }
        var format = inputNode.outputFormat(forBus: 0)
        if (format.sampleRate <= 0 || format.channelCount == 0), inputNode.isVoiceProcessingEnabled {
            voiceProcessingFailed = true
            try? inputNode.setVoiceProcessingEnabled(false)
            format = inputNode.outputFormat(forBus: 0)
        }
        guard format.sampleRate > 0, format.channelCount > 0 else {
            self.lastError = "麦克风格式无效（\(Int(format.sampleRate))Hz）"
            tearDownEngine()
            return
        }
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buffer, _ in
            req?.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            self.lastError = "录音启动失败: \(error.localizedDescription)"
            tearDownEngine()
            // 开着回声消除起不来 → 记下，下一次（看门狗 1 秒内）用普通输入再试
            if inputNode.isVoiceProcessingEnabled { voiceProcessingFailed = true }
            return
        }

        self.transcript = ""
        self.isRecording = true
        self.lastError = nil
        self.stoppingManually = false

        self.task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self = self, self.generation == gen else { return }
                if let result = result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil || (result?.isFinal ?? false) {
                    let manual = self.stoppingManually
                    self.cleanup()
                    if !manual {
                        self.onTaskEnded?(error)
                    }
                }
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        stoppingManually = true
        task?.finish()
        request?.endAudio()
        cleanup()
    }

    private func tearDownEngine() {
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
        }
        audioEngine = nil
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
    }

    private func cleanup() {
        tearDownEngine()
        isRecording = false
        if managesAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func requestSpeechAuth() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }

    private func requestMicAuth() async -> Bool {
        await withCheckedContinuation { cont in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            }
        }
    }
}
