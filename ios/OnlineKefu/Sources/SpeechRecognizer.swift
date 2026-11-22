import Foundation
import Speech
import AVFoundation

/// 语音转文字（边说边出字）——**安全版**
///
/// 1.6.0 的第一版把 `AVAudioEngine` 的初始化与 `installTap` 直接放在主线程，
/// 一旦音频设备初始化慢 / 权限异常 / 采样率为 0，就会**卡死整个界面**（2026-11-23 用户反馈）。
/// 这一版的原则：
///   1. 所有音频与识别操作都在**独立串行队列**，主线程只负责拿结果；
///   2. 启动前先做三道检查（权限 / 识别可用 / 输入格式采样率），任一不满足立刻返回并给提示；
///   3. 全流程有超时（20 秒）与异常兜底，任何一步失败都复位状态，不留残骸；
///   4. `@Published` 只在主线程更新，且识别文本更新做节流，避免高频重绘。
@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var errorText: String?
    @Published private(set) var transcript = ""

    private let queue = DispatchQueue(label: "xy.speech.engine", qos: .userInitiated)
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()
    private var timeoutWork: DispatchWorkItem?
    private var lastEmit = Date.distantPast

    init() {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
            ?? SFSpeechRecognizer(locale: Locale.current)
    }

    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    func toggle() {
        if isRecording { stop() } else { Task { await start() } }
    }

    func start() async {
        guard !isRecording else { return }
        errorText = nil
        transcript = ""

        guard let recognizer else {
            errorText = "当前设备不支持语音识别"
            return
        }

        // 1) 麦克风权限
        let micOK = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) }
        }
        guard micOK else {
            errorText = "没有麦克风权限：设置 → 在线客服 → 麦克风"
            return
        }

        // 2) 语音识别权限
        let speechStatus = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speechStatus == .authorized else {
            errorText = "没有语音识别权限：设置 → 在线客服 → 语音识别"
            return
        }

        guard recognizer.isAvailable else {
            errorText = "语音识别暂不可用，稍后再试"
            return
        }

        // 3) 音频会话（在主线程设置是安全的，但不做任何引擎操作）
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            errorText = "音频初始化失败：\(error.localizedDescription)"
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        // 4) 引擎与识别全部丢到后台队列，主线程不等
        isRecording = true
        queue.async { [weak self] in
            guard let self else { return }
            let input = self.engine.inputNode
            let format = input.outputFormat(forBus: 0)
            // 采样率 0 = 没有可用输入设备（模拟器 / 被占用 / 权限异常），
            // 此时 installTap 会直接抛异常 → 过去就是这里把 App 卡死的
            guard format.sampleRate > 0, format.channelCount > 0 else {
                Task { @MainActor in
                    self.fail("麦克风不可用（采样率为 0）")
                }
                return
            }
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            self.engine.prepare()
            do {
                try self.engine.start()
            } catch {
                Task { @MainActor in self.fail("录音启动失败：\(error.localizedDescription)") }
                return
            }
            // 识别任务
            let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    // 节流：最多每 250ms 推一次，避免 SwiftUI 高频重绘卡顿
                    let now = Date()
                    if now.timeIntervalSince(self.lastEmit) > 0.25 || result.isFinal {
                        self.lastEmit = now
                        Task { @MainActor in self.transcript = text }
                    }
                    if result.isFinal {
                        Task { @MainActor in self.stop() }
                    }
                }
                if error != nil {
                    Task { @MainActor in self.stop() }
                }
            }
            Task { @MainActor in self.task = task }
        }

        // 5) 超时保护：20 秒自动停
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.stop() }
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    func stop() {
        timeoutWork?.cancel()
        timeoutWork = nil
        isRecording = false
        // 停止动作也放后台，避免 audio session 反激活卡主线程
        let req = request
        let t = task
        request = nil
        task = nil
        queue.async { [weak self] in
            guard let self else { return }
            if self.engine.isRunning { self.engine.stop() }
            self.engine.inputNode.removeTap(onBus: 0)
            req?.endAudio()
            t?.cancel()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func fail(_ message: String) {
        errorText = message
        stop()
    }
}
