import Foundation
import Speech
import AVFoundation

/// 语音转文字（边说边出字）
///
/// 用系统 Speech 框架 + 麦克风做**实时识别**，识别结果直接回填输入框。
/// 注意：TrollStore 装的是未签名包，首次点麦克风会弹系统权限（麦克风 + 语音识别），
/// 必须在弹窗里点"允许"，否则只能走键盘自带的听写。
@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published var isRecording = false
    @Published var errorText: String?
    /// 识别中的实时文本；每次更新由 ChatView 追加到输入框
    @Published var transcript = ""

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()

    init() {
        // 中文优先；不可用时退回系统当前语言
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
            ?? SFSpeechRecognizer(locale: Locale.current)
    }

    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    /// 点一次开始、再点一次结束
    func toggle() {
        if isRecording {
            stop()
        } else {
            Task { await start() }
        }
    }

    func start() async {
        errorText = nil
        transcript = ""

        guard let recognizer else {
            errorText = "当前设备不支持语音识别"
            return
        }

        // 1) 权限：麦克风
        let micOK = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
        }
        guard micOK else {
            errorText = "没有麦克风权限：设置 → 在线客服 → 麦克风，打开后重试"
            return
        }

        // 2) 权限：语音识别
        let speechOK = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard speechOK == .authorized else {
            errorText = "没有语音识别权限：设置 → 在线客服 → 语音识别，打开后重试"
            return
        }

        guard recognizer.isAvailable else {
            errorText = "语音识别暂不可用（可能无网络），稍后再试"
            return
        }

        do {
            // 3) 录音会话：允许播放 + 录音，避免把正在播的提示音掐断
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            // 能离线就离线，省流量也更稳
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
            self.request = request

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()

            isRecording = true
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                    }
                    if error != nil || (result?.isFinal ?? false) {
                        self.stop()
                    }
                }
            }
        } catch {
            errorText = "启动录音失败：\(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false,
                                                       options: .notifyOthersOnDeactivation)
    }
}
