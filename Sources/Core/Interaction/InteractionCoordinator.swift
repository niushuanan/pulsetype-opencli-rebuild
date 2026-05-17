import AppKit
import Combine
import Foundation

@MainActor
final class InteractionCoordinator {
    private let sessionStore: SessionStore
    private let permissionsCenter: PermissionsCenter
    private let audioCaptureService: AudioCaptureService
    private let providerSettingsStore: ProviderSettingsStore
    private let providerRegistry: SpeechProviderRegistry
    private let textOutputCoordinator: TextOutputCoordinator
    private let contextDetector: ContextDetector
    private let localHistoryStore: LocalHistoryStore
    private let speechPipelineLogger: SpeechPipelineLogger
    private let toastPresenter: ToastPresenter?
    private let dictationPostProcessor: DictationPostProcessor

    private var cancellables = Set<AnyCancellable>()
    private var transcriptionTask: Task<Void, Never>?
    private var currentDictationTarget: DictationWritebackTarget?
    private var lastExternalDictationTarget: DictationWritebackTarget?
    private var currentTraceID: String?

    init(
        sessionStore: SessionStore,
        permissionsCenter: PermissionsCenter,
        audioCaptureService: AudioCaptureService,
        providerSettingsStore: ProviderSettingsStore,
        providerRegistry: SpeechProviderRegistry,
        textOutputCoordinator: TextOutputCoordinator,
        contextDetector: ContextDetector,
        localHistoryStore: LocalHistoryStore,
        speechPipelineLogger: SpeechPipelineLogger,
        toastPresenter: ToastPresenter? = nil,
        dictationPostProcessor: DictationPostProcessor = LLMDictationPostProcessor()
    ) {
        self.sessionStore = sessionStore
        self.permissionsCenter = permissionsCenter
        self.audioCaptureService = audioCaptureService
        self.providerSettingsStore = providerSettingsStore
        self.providerRegistry = providerRegistry
        self.textOutputCoordinator = textOutputCoordinator
        self.contextDetector = contextDetector
        self.localHistoryStore = localHistoryStore
        self.speechPipelineLogger = speechPipelineLogger
        self.toastPresenter = toastPresenter
        self.dictationPostProcessor = dictationPostProcessor
        bindListeningLevel()
        bindExternalAppTracking()
    }

    func handleWakeInput(context _: WakeInvocationContext = .dictation) {
        permissionsCenter.refreshStatuses()

        switch sessionStore.phase {
        case .idle, .cancelled, .error:
            discardPendingClipIfNeeded()
            guard permissionsCenter.snapshot.canStartVoiceSession else {
                sessionStore.fail(message: "开始听写前，需要先允许麦克风权限。")
                return
            }
            startRecording()
        case .listening:
            handleStopInput()
        case .transcribing, .textProcessing, .inserting:
            break
        }
    }

    func handleStopInput() {
        guard sessionStore.phase == .listening else {
            return
        }
        let configuration = providerSettingsStore.configuration
        let traceID = ensureTraceID()
        sessionStore.markTranscribing()

        do {
            let clip = try audioCaptureService.stopRecording()
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .directDictation,
                provider: configuration.providerName,
                model: configuration.modelName,
                httpStatus: nil,
                stage: "recording.stop",
                audioDuration: clip.duration
            )
            discardPendingClipIfNeeded()
            sessionStore.attachPendingClip(clip)
            sessionStore.updateListeningLevel(0)
            sessionStore.markTranscribing(
                audioSummary: clip.displaySummary,
                providerName: configuration.providerName,
                modelName: configuration.modelName
            )
            startTranscription(for: clip)
        } catch {
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .directDictation,
                provider: configuration.providerName,
                model: configuration.modelName,
                httpStatus: nil,
                stage: "recording.stop.failed",
                errorType: "audioStopFailed",
                detail: error.localizedDescription
            )
            sessionStore.fail(message: "停止录音失败：\(error.localizedDescription)")
            currentTraceID = nil
        }
    }

    func handleCancelInput() {
        guard isCancellablePhase(sessionStore.phase) else {
            return
        }

        let focusContext = contextDetector.focusedAppContext()
        let latestInput = sessionStore.latestTranscription?.transcript ?? ""
        let clipDuration = sessionStore.pendingClip?.duration
        let traceID = ensureTraceID()

        transcriptionTask?.cancel()
        transcriptionTask = nil
        currentDictationTarget = nil

        if audioCaptureService.isRecording {
            audioCaptureService.cancelRecording()
        }
        discardPendingClipIfNeeded()
        sessionStore.cancel()

        localHistoryStore.append(
            SessionHistoryEntry(
                appName: focusContext.appName,
                bundleID: focusContext.bundleID,
                inputText: latestInput,
                outputText: nil,
                status: .cancelled,
                errorMessage: "用户取消了当前听写。",
                audioDurationSeconds: clipDuration
            )
        )
        speechPipelineLogger.log(
            traceID: traceID,
            lane: .directDictation,
            provider: nil,
            model: nil,
            httpStatus: nil,
            stage: "history.cancelled",
            audioDuration: clipDuration
        )
        currentTraceID = nil
    }

    func handleResetInput() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        currentDictationTarget = nil

        if audioCaptureService.isRecording {
            audioCaptureService.cancelRecording()
        }
        discardPendingClipIfNeeded()
        sessionStore.reset()
        currentTraceID = nil
    }

    private func startRecording() {
        let configuration = providerSettingsStore.configuration
        let traceID = UUID().uuidString
        currentTraceID = traceID
        currentDictationTarget = resolveDictationWritebackTarget()

        do {
            try audioCaptureService.startRecording()
            sessionStore.startDictation()
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .directDictation,
                provider: configuration.providerName,
                model: configuration.modelName,
                httpStatus: nil,
                stage: "session.start"
            )
        } catch {
            currentDictationTarget = nil
            sessionStore.fail(message: "无法开始录音：\(error.localizedDescription)")
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .directDictation,
                provider: configuration.providerName,
                model: configuration.modelName,
                httpStatus: nil,
                stage: "session.start.failed",
                errorType: "audioStartFailed",
                detail: error.localizedDescription
            )
            currentTraceID = nil
        }
    }

    private func isCancellablePhase(_ phase: SessionPhase) -> Bool {
        switch phase {
        case .listening, .transcribing, .textProcessing, .inserting:
            return true
        case .idle, .cancelled, .error:
            return false
        }
    }

    private func startTranscription(for clip: RecordedAudioClip) {
        transcriptionTask?.cancel()
        transcriptionTask = Task { [weak self] in
            guard let self else {
                return
            }

            var resolvedConfiguration: SpeechProviderConfiguration?
            let traceID = ensureTraceID()

            do {
                guard providerSettingsStore.isConfigurationValid else {
                    throw SpeechTranscriptionError.providerFailure(
                        description: providerSettingsStore.configurationValidationMessage ?? "服务商配置无效。"
                    )
                }

                let configuration = providerSettingsStore.configuration
                resolvedConfiguration = configuration
                guard let provider = providerRegistry.provider(for: configuration.providerType) else {
                    throw SpeechTranscriptionError.providerFailure(description: "当前构建不含所选 ASR provider。")
                }

                guard
                    let loaded = try providerSettingsStore.loadAPIKeyForTranscriptionProvider(),
                    !loaded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    throw SpeechTranscriptionError.missingAPIKey(providerName: configuration.providerName)
                }

                let request = SpeechTranscriptionRequest(
                    clip: clip,
                    lane: .directDictation,
                    contextSummary: "lane=directDictation"
                )

                let outcome = try await transcribeWithRetryOnInvalidResponse(
                    provider: provider,
                    request: request,
                    configuration: configuration,
                    apiKey: loaded,
                    traceID: traceID
                )
                guard !Task.isCancelled else {
                    return
                }

                audioCaptureService.removeClip(at: clip.fileURL)
                sessionStore.clearPendingClipReference()
                sessionStore.completeTranscription(result: outcome.result)
                speechPipelineLogger.log(
                    traceID: traceID,
                    lane: .directDictation,
                    provider: outcome.result.providerName,
                    model: outcome.result.modelName,
                    httpStatus: nil,
                    stage: "asr.success",
                    detail: "attempts=\(outcome.attempts)",
                    audioDuration: clip.duration,
                    transcriptLength: outcome.result.transcript.count
                )
                await outputDictationTranscript(outcome.result, audioDurationSeconds: clip.duration)
            } catch let failure as ASRTranscriptionFailure {
                guard !Task.isCancelled else {
                    return
                }
                handleTranscriptionFailure(
                    failure.error,
                    attempts: failure.attempts,
                    clip: clip,
                    configuration: resolvedConfiguration,
                    traceID: traceID
                )
            } catch is CancellationError {
                return
            } catch let speechError as SpeechTranscriptionError {
                guard !Task.isCancelled else {
                    return
                }
                handleTranscriptionFailure(
                    speechError,
                    attempts: 1,
                    clip: clip,
                    configuration: resolvedConfiguration,
                    traceID: traceID
                )
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                handleTranscriptionFailure(
                    .providerFailure(description: error.localizedDescription),
                    attempts: 1,
                    clip: clip,
                    configuration: resolvedConfiguration,
                    traceID: traceID
                )
            }
        }
    }

    private func transcribeWithRetryOnInvalidResponse(
        provider: any SpeechTranscriptionProvider,
        request: SpeechTranscriptionRequest,
        configuration: SpeechProviderConfiguration,
        apiKey: String,
        traceID: String
    ) async throws -> ASRTranscriptionOutcome {
        for attempt in 1...2 {
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .directDictation,
                provider: configuration.providerName,
                model: configuration.modelName,
                httpStatus: nil,
                stage: "asr.attempt.start",
                detail: "attempt=\(attempt)",
                audioDuration: request.clip.duration
            )

            do {
                let result = try await provider.transcribe(
                    request: request,
                    configuration: configuration,
                    apiKey: apiKey
                )
                return ASRTranscriptionOutcome(result: result, attempts: attempt)
            } catch let speechError as SpeechTranscriptionError {
                speechPipelineLogger.log(
                    traceID: traceID,
                    lane: .directDictation,
                    provider: configuration.providerName,
                    model: configuration.modelName,
                    httpStatus: SpeechTranscriptionErrorPresentation.httpStatus(from: speechError),
                    stage: "asr.attempt.failed",
                    errorType: SpeechTranscriptionErrorPresentation.errorType(for: speechError),
                    detail: SpeechTranscriptionErrorPresentation.actionableMessage(for: speechError),
                    audioDuration: request.clip.duration
                )
                if case .invalidResponse = speechError, attempt == 1 {
                    speechPipelineLogger.log(
                        traceID: traceID,
                        lane: .directDictation,
                        provider: configuration.providerName,
                        model: configuration.modelName,
                        httpStatus: nil,
                        stage: "asr.retry",
                        errorType: "invalidResponse",
                        detail: "retry-with-original-params",
                        audioDuration: request.clip.duration
                    )
                    continue
                }
                throw ASRTranscriptionFailure(error: speechError, attempts: attempt)
            } catch {
                let wrapped = SpeechTranscriptionError.providerFailure(description: error.localizedDescription)
                speechPipelineLogger.log(
                    traceID: traceID,
                    lane: .directDictation,
                    provider: configuration.providerName,
                    model: configuration.modelName,
                    httpStatus: SpeechTranscriptionErrorPresentation.httpStatus(from: wrapped),
                    stage: "asr.attempt.failed",
                    errorType: SpeechTranscriptionErrorPresentation.errorType(for: wrapped),
                    detail: SpeechTranscriptionErrorPresentation.actionableMessage(for: wrapped),
                    audioDuration: request.clip.duration
                )
                throw ASRTranscriptionFailure(error: wrapped, attempts: attempt)
            }
        }

        throw ASRTranscriptionFailure(error: .invalidResponse, attempts: 2)
    }

    private func handleTranscriptionFailure(
        _ error: SpeechTranscriptionError,
        attempts: Int,
        clip: RecordedAudioClip,
        configuration: SpeechProviderConfiguration?,
        traceID: String
    ) {
        currentDictationTarget = nil
        audioCaptureService.removeClip(at: clip.fileURL)
        sessionStore.clearPendingClipReference()
        let message = SpeechTranscriptionErrorPresentation.finalErrorMessage(
            for: error,
            traceID: traceID,
            attempts: attempts
        )
        let focusContext = contextDetector.focusedAppContext()
        localHistoryStore.append(
            SessionHistoryEntry(
                appName: focusContext.appName,
                bundleID: focusContext.bundleID,
                inputText: "",
                outputText: nil,
                transcriptionProvider: configuration?.providerName,
                transcriptionModel: configuration?.modelName,
                status: .failed,
                errorMessage: message,
                audioDurationSeconds: clip.duration
            )
        )
        speechPipelineLogger.log(
            traceID: traceID,
            lane: .directDictation,
            provider: configuration?.providerName,
            model: configuration?.modelName,
            httpStatus: SpeechTranscriptionErrorPresentation.httpStatus(from: error),
            stage: "asr.failed",
            errorType: SpeechTranscriptionErrorPresentation.errorType(for: error),
            detail: message,
            audioDuration: clip.duration
        )
        sessionStore.fail(message: message)
        currentTraceID = nil
    }

    private func outputDictationTranscript(
        _ transcription: SpeechTranscriptionResult,
        audioDurationSeconds: TimeInterval
    ) async {
        let traceID = ensureTraceID()
        let writebackTarget = currentDictationTarget
        let focusContext = writebackTarget?.focusContext ?? contextDetector.focusedAppContext()
        let writebackWarmupTask = Task { [weak self] in
            guard
                let self,
                let warmableCoordinator = self.textOutputCoordinator as? AccessibilityTextOutputCoordinator
            else {
                return
            }
            await warmableCoordinator.prepareForWrite(
                preferredTarget: writebackTarget?.snapshot,
                fallbackFocusContext: focusContext
            )
        }

        let postProcessResult = await postProcessDictationIfNeeded(
            text: transcription.transcript,
            focusContext: focusContext,
            writebackTarget: writebackTarget
        )
        _ = await writebackWarmupTask.value

        let finalText = postProcessResult.text
        let finalTranscription = SpeechTranscriptionResult(
            providerType: transcription.providerType,
            providerName: transcription.providerName,
            modelName: transcription.modelName,
            transcript: finalText
        )

        do {
            let outputResult: TextOutputResult
            if postProcessResult.finalWritebackText.isEmpty,
               let priorStreamingWriteResult = postProcessResult.priorStreamingWriteResult {
                if postProcessResult.nonBlockingNotice?.contains("完整结果已放入剪贴板") == true {
                    _ = persistTextToClipboard(finalTranscription.transcript)
                }
                outputResult = priorStreamingWriteResult
            } else {
                let request = TextOutputRequest(
                    text: postProcessResult.finalWritebackText,
                    operation: .insertText,
                    focusContext: focusContext,
                    preferredTarget: writebackTarget?.snapshot
                )
                sessionStore.markInserting(
                    transcription: finalTranscription,
                    focusContext: focusContext
                )
                outputResult = try await textOutputCoordinator.write(request: request)
            }

            sessionStore.completeInsertion(
                outputResult: outputResult,
                note: postProcessResult.nonBlockingNotice
            )
            localHistoryStore.append(
                SessionHistoryEntry(
                    appName: focusContext.appName,
                    bundleID: focusContext.bundleID,
                    inputText: transcription.transcript,
                    outputText: finalTranscription.transcript,
                    transcriptionProvider: transcription.providerName,
                    transcriptionModel: transcription.modelName,
                    textProcessingProvider: postProcessResult.route == .asrAndTextProcessing ? providerSettingsStore.textProcessingConfiguration.providerName : nil,
                    textProcessingModel: postProcessResult.route == .asrAndTextProcessing ? providerSettingsStore.textProcessingConfiguration.modelName : nil,
                    outputPath: outputResult.path,
                    status: .success,
                    audioDurationSeconds: audioDurationSeconds
                )
            )
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .directDictation,
                provider: finalTranscription.providerName,
                model: finalTranscription.modelName,
                httpStatus: nil,
                stage: "write.success",
                detail: "path=\(outputResult.path.rawValue)",
                audioDuration: audioDurationSeconds,
                transcriptLength: finalTranscription.transcript.count
            )
            currentDictationTarget = nil
            currentTraceID = nil
        } catch let outputError as TextOutputError {
            handleWriteFailure(
                outputError,
                focusContext: focusContext,
                transcription: transcription,
                finalText: finalText,
                audioDurationSeconds: audioDurationSeconds,
                traceID: traceID
            )
        } catch {
            handleWriteFailure(
                .accessibilityPathFailed(reason: error.localizedDescription),
                focusContext: focusContext,
                transcription: transcription,
                finalText: finalText,
                audioDurationSeconds: audioDurationSeconds,
                traceID: traceID
            )
        }
    }

    private func postProcessDictationIfNeeded(
        text: String,
        focusContext: FocusedAppContext,
        writebackTarget: DictationWritebackTarget?
    ) async -> DictationPostProcessOutcome {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DictationTextProcessingPolicy.shouldUseModel(text: normalized) else {
            return DictationPostProcessOutcome(
                route: .asrOnly,
                text: normalized,
                finalWritebackText: normalized,
                priorStreamingWriteResult: nil,
                nonBlockingNotice: nil
            )
        }

        guard providerSettingsStore.isTextProcessingConfigurationValid else {
            return DictationPostProcessOutcome(
                route: .asrOnly,
                text: normalized,
                finalWritebackText: normalized,
                priorStreamingWriteResult: nil,
                nonBlockingNotice: "文字处理模型配置无效，已直接使用 ASR 原文。"
            )
        }

        let configuration = providerSettingsStore.textProcessingConfiguration
        let apiKey: String
        do {
            guard
                let loaded = try providerSettingsStore.loadAPIKeyForTextProcessing(),
                !loaded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return DictationPostProcessOutcome(
                    route: .asrOnly,
                    text: normalized,
                    finalWritebackText: normalized,
                    priorStreamingWriteResult: nil,
                    nonBlockingNotice: "缺少文字处理模型 API 密钥，已直接使用 ASR 原文。"
                )
            }
            apiKey = loaded
        } catch {
            return DictationPostProcessOutcome(
                route: .asrOnly,
                text: normalized,
                finalWritebackText: normalized,
                priorStreamingWriteResult: nil,
                nonBlockingNotice: "文字处理模型 API 密钥读取失败，已直接使用 ASR 原文。"
            )
        }

        let request = DictationPostProcessRequest(
            transcript: normalized,
            focusContext: focusContext,
            userSystemPrompt: providerSettingsStore.textProcessingPrompt
        )
        sessionStore.markDictationPostProcessing(
            providerName: configuration.providerName,
            modelName: configuration.modelName
        )

        do {
            let result: DictationPostProcessResult
            var streamingController: DictationStreamingWritebackController?
            if let streamingProcessor = dictationPostProcessor as? StreamingDictationPostProcessor {
                let controller = DictationStreamingWritebackController(
                    textOutputCoordinator: textOutputCoordinator,
                    focusContext: focusContext,
                    preferredTarget: writebackTarget?.snapshot
                )
                let sessionStore = self.sessionStore
                streamingController = controller
                result = try await streamingProcessor.processStreaming(
                    request: request,
                    configuration: configuration,
                    apiKey: apiKey,
                    onPartialText: { previewText in
                        await MainActor.run {
                            sessionStore.updateDictationPostProcessingPreview(previewText)
                        }
                        await controller.handlePartialText(previewText)
                    }
                )
            } else {
                result = try await dictationPostProcessor.process(
                    request: request,
                    configuration: configuration,
                    apiKey: apiKey
                )
            }

            let finalization = streamingController?.finalize(with: result.outputText)
            return DictationPostProcessOutcome(
                route: .asrAndTextProcessing,
                text: result.outputText,
                finalWritebackText: finalization?.finalWritebackText ?? result.outputText,
                priorStreamingWriteResult: finalization?.priorStreamingWriteResult,
                nonBlockingNotice: finalization?.note
            )
        } catch {
            return DictationPostProcessOutcome(
                route: .asrOnly,
                text: normalized,
                finalWritebackText: normalized,
                priorStreamingWriteResult: nil,
                nonBlockingNotice: "文字处理模型处理失败，已直接使用 ASR 原文。"
            )
        }
    }

    private func handleWriteFailure(
        _ error: TextOutputError,
        focusContext: FocusedAppContext,
        transcription: SpeechTranscriptionResult,
        finalText: String,
        audioDurationSeconds: TimeInterval,
        traceID: String
    ) {
        let message = actionableOutputMessage(for: error, focusContext: focusContext)
        localHistoryStore.append(
            SessionHistoryEntry(
                appName: focusContext.appName,
                bundleID: focusContext.bundleID,
                inputText: transcription.transcript,
                outputText: nil,
                transcriptionProvider: transcription.providerName,
                transcriptionModel: transcription.modelName,
                status: .failed,
                errorMessage: message,
                audioDurationSeconds: audioDurationSeconds
            )
        )
        speechPipelineLogger.log(
            traceID: traceID,
            lane: .directDictation,
            provider: transcription.providerName,
            model: transcription.modelName,
            httpStatus: nil,
            stage: "write.failed",
            errorType: "textOutput",
            detail: message,
            audioDuration: audioDurationSeconds,
            transcriptLength: finalText.count
        )
        currentDictationTarget = nil
        sessionStore.fail(message: message)
        currentTraceID = nil
    }

    private func actionableOutputMessage(
        for error: TextOutputError,
        focusContext: FocusedAppContext
    ) -> String {
        switch error {
        case .accessibilityPermissionMissing:
            return "需要辅助功能权限，才能把文本写入 \(focusContext.appName)。"
        case .noFocusedElement, .noEditableTarget:
            return "当前没有可写入输入框，文本没有写入目标应用。"
        case .emptyText:
            return "没有可写入文本。"
        case .pasteboardUnavailable:
            return "剪贴板不可用，无法执行粘贴兜底。"
        case .pasteShortcutInjectionFailed:
            return "粘贴兜底失败，无法触发 Command+V。"
        case let .accessibilityPathFailed(reason):
            return "写入失败：\(reason)"
        case let .fallbackFailed(primaryReason):
            return "AX 与粘贴兜底都失败。AX 原因：\(primaryReason)"
        }
    }

    private func resolveDictationWritebackTarget() -> DictationWritebackTarget? {
        let focusContext = contextDetector.focusedAppContext()
        if focusContext.bundleID == Bundle.main.bundleIdentifier {
            return lastExternalDictationTarget ?? DictationWritebackTarget(
                focusContext: focusContext,
                processIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
            )
        }

        let target = DictationWritebackTarget(
            focusContext: focusContext,
            processIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
        )
        lastExternalDictationTarget = target
        return target
    }

    private func ensureTraceID() -> String {
        if let currentTraceID {
            return currentTraceID
        }
        let traceID = UUID().uuidString
        currentTraceID = traceID
        return traceID
    }

    private func persistTextToClipboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    private func discardPendingClipIfNeeded() {
        guard let clip = sessionStore.pendingClip else {
            return
        }
        audioCaptureService.removeClip(at: clip.fileURL)
        sessionStore.clearPendingClipReference()
    }

    private func bindListeningLevel() {
        audioCaptureService.levelPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] level in
                self?.sessionStore.updateListeningLevel(level)
            }
            .store(in: &cancellables)
    }

    private func bindExternalAppTracking() {
        NotificationCenter.default.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] notification in
                guard let self else {
                    return
                }
                guard
                    let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                    app.bundleIdentifier != Bundle.main.bundleIdentifier
                else {
                    return
                }
                self.lastExternalDictationTarget = DictationWritebackTarget(
                    focusContext: FocusedAppContext(
                        appName: app.localizedName ?? "未知应用",
                        bundleID: app.bundleIdentifier ?? "unknown.bundle",
                        focusedRole: nil,
                        hasEditableTarget: true,
                        strategyHint: "来自最近一次前台应用。"
                    ),
                    processIdentifier: app.processIdentifier
                )
            }
            .store(in: &cancellables)
    }
}
