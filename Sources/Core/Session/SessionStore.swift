import Combine
import Foundation

enum SessionHUDProgressHint {
    static let idle = 0.0
    static let transcribing = 0.18
    static let textTransform = 0.62
    static let inserting = 0.90
    static let done = 1.0
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var phase: SessionPhase = .idle
    @Published private(set) var activeLane: InputLane = .directDictation
    @Published private(set) var statusMessage: String = "已准备，可开始普通听写或 Agent 执行。"
    @Published private(set) var hudProgressHint: Double = SessionHUDProgressHint.idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var listeningLevel: Double = 0
    @Published private(set) var pendingClip: RecordedAudioClip?
    @Published private(set) var latestTranscription: SpeechTranscriptionResult?
    @Published private(set) var latestFocusContext: FocusedAppContext?
    @Published private(set) var latestOutputResult: TextOutputResult?
    @Published private(set) var liveOutputPreview: String?

    private let allowedTransitions: [SessionPhase: Set<SessionPhase>] = [
        .idle: [.listening],
        .listening: [.transcribing, .cancelled, .error],
        .transcribing: [.idle, .textProcessing, .inserting, .cancelled, .error],
        .textProcessing: [.idle, .inserting, .cancelled, .error],
        .inserting: [.idle, .cancelled, .error],
        .cancelled: [.idle, .listening],
        .error: [.idle, .listening]
    ]

    func startDictation() {
        startSession(lane: .directDictation)
    }

    func startAgentMusic() {
        startSession(lane: .agentMusic)
    }

    func markAgentRouting(
        providerName: String,
        modelName: String
    ) {
        transition(
            to: .textProcessing,
            statusMessage: "Agent 正在用 \(providerName) · \(modelName) 判断要使用哪个功能。",
            hudProgressHint: SessionHUDProgressHint.textTransform
        )
    }

    func markAgentExecuting(toolName: String = "音乐控制") {
        transition(
            to: .textProcessing,
            statusMessage: "Agent 正在执行\(toolName)。",
            hudProgressHint: SessionHUDProgressHint.textTransform
        )
    }

    func completeAgentExecution(message: String) {
        pendingClip = nil
        listeningLevel = 0
        transition(
            to: .idle,
            statusMessage: message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Agent 执行已完成。"
                : message,
            hudProgressHint: SessionHUDProgressHint.done
        )
    }

    private func startSession(lane: InputLane) {
        clearRuntimeArtifactsForNewSession()
        activeLane = lane
        transition(
            to: .listening,
            statusMessage: lane.listeningStatusMessage,
            hudProgressHint: SessionHUDProgressHint.idle
        )
    }

    func markTranscribing(audioSummary: String? = nil) {
        if let audioSummary {
            transition(
                to: .transcribing,
                statusMessage: "录音已完成：\(audioSummary)",
                hudProgressHint: SessionHUDProgressHint.transcribing
            )
        } else {
            transition(
                to: .transcribing,
                statusMessage: "正在把语音转成文字。",
                hudProgressHint: SessionHUDProgressHint.transcribing
            )
        }
    }

    func markTranscribing(
        audioSummary: String,
        providerName: String,
        modelName: String
    ) {
        transition(
            to: .transcribing,
            statusMessage: "正在用 \(providerName) · \(modelName) 转写（\(audioSummary)）。",
            hudProgressHint: SessionHUDProgressHint.transcribing
        )
    }

    func completeTranscription(result: SpeechTranscriptionResult) {
        latestTranscription = result
    }

    func markDictationPostProcessing(
        providerName: String,
        modelName: String
    ) {
        liveOutputPreview = nil
        transition(
            to: .textProcessing,
            statusMessage: "正在用 \(providerName) · \(modelName) 整理听写。",
            hudProgressHint: SessionHUDProgressHint.textTransform
        )
    }

    func updateDictationPostProcessingPreview(_ previewText: String) {
        let normalized = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return
        }

        liveOutputPreview = normalized
        transition(
            to: .textProcessing,
            statusMessage: "听写整理中：\(normalized)",
            hudProgressHint: livePreviewProgressHint(for: normalized)
        )
    }

    func markInserting(
        transcription result: SpeechTranscriptionResult,
        focusContext: FocusedAppContext
    ) {
        latestTranscription = result
        latestFocusContext = focusContext
        transition(
            to: .inserting,
            statusMessage: "正在把文本写入 \(focusContext.appName)。",
            hudProgressHint: SessionHUDProgressHint.inserting
        )
    }

    func completeInsertion(
        outputResult: TextOutputResult,
        note: String? = nil
    ) {
        latestOutputResult = outputResult
        pendingClip = nil
        listeningLevel = 0
        liveOutputPreview = nil

        let baseMessage: String
        switch outputResult.path {
        case .accessibilitySelectionReplacement:
            baseMessage = "文本已写入 \(outputResult.appName)（AX 直写路径）。"
        case .pasteFallbackCommandV:
            baseMessage = "文本已写入 \(outputResult.appName)（粘贴兜底路径）。"
        case .clipboardOnly:
            baseMessage = "当前没有可直接写入的输入框，文本已复制到剪贴板。"
        }

        transition(
            to: .idle,
            statusMessage: [baseMessage, note].compactMap { value in
                let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return normalized.isEmpty ? nil : normalized
            }.joined(separator: " "),
            hudProgressHint: SessionHUDProgressHint.done
        )
    }

    func cancel() {
        let lane = activeLane
        clearRuntimeArtifactsForNewSession()
        phase = .cancelled
        statusMessage = lane == .agentMusic
            ? "本次 Agent 执行已取消，对应功能不会再继续处理。"
            : "本次听写已取消，目标应用内容未变化。"
        hudProgressHint = SessionHUDProgressHint.idle
    }

    func fail(message: String) {
        clearRuntimeArtifactsForNewSession()
        phase = .error
        errorMessage = message
        statusMessage = message
        hudProgressHint = SessionHUDProgressHint.idle
    }

    func reset() {
        clearRuntimeArtifactsForNewSession()
        phase = .idle
        statusMessage = "已准备，可开始普通听写或 Agent 执行。"
        hudProgressHint = SessionHUDProgressHint.idle
    }

    func updateListeningLevel(_ level: Double) {
        listeningLevel = max(0, min(1, level))
    }

    func attachPendingClip(_ clip: RecordedAudioClip) {
        pendingClip = clip
    }

    func clearPendingClipReference() {
        pendingClip = nil
    }

    private func clearRuntimeArtifactsForNewSession() {
        pendingClip = nil
        latestTranscription = nil
        latestFocusContext = nil
        latestOutputResult = nil
        liveOutputPreview = nil
        errorMessage = nil
        listeningLevel = 0
    }

    private func transition(
        to next: SessionPhase,
        statusMessage: String,
        hudProgressHint: Double
    ) {
        guard allowedTransitions[phase]?.contains(next) == true || phase == next else {
            return
        }
        phase = next
        self.statusMessage = statusMessage
        self.hudProgressHint = hudProgressHint
        if next != .error {
            errorMessage = nil
        }
    }

    private func livePreviewProgressHint(for text: String) -> Double {
        let count = text.count
        if count < 12 {
            return 0.48
        }
        if count < 40 {
            return 0.62
        }
        if count < 90 {
            return 0.74
        }
        return 0.82
    }
}
