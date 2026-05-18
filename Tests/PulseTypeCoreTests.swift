import Combine
import Foundation
import XCTest
@testable import PulseType

@MainActor
final class PulseTypeCoreTests: XCTestCase {
    func testProviderDefaultsKeepOnlyASRAndDeepSeekTextProcessing() {
        let store = ProviderSettingsStore(
            defaults: makeDefaults(),
            credentialStore: MemoryCredentialStore()
        )

        XCTAssertEqual(ProviderType.allCases, [.openAI, .openAICompatible, .anthropic, .dashScopeQwenASR])
        XCTAssertEqual(store.asrConfig.providerType, .dashScopeQwenASR)
        XCTAssertEqual(store.asrConfig.modelName, "qwen3-asr-flash")
        XCTAssertEqual(store.textConfig.providerType, .openAICompatible)
        XCTAssertEqual(store.textConfig.baseURLString, "https://api.deepseek.com")
        XCTAssertEqual(store.textConfig.modelName, "deepseek-v4-flash")
        XCTAssertEqual(store.textProcessingPrompt, ProviderSettingsStore.defaultTextProcessingPrompt)
        XCTAssertFalse(ProviderType.dashScopeQwenASR.supportsTextProcessing)
    }

    func testTextProviderInferenceSupportsAnthropicURL() {
        let store = ProviderSettingsStore(
            defaults: makeDefaults(),
            credentialStore: MemoryCredentialStore()
        )

        store.updateTextBaseURL("https://api.anthropic.com")
        store.updateTextModel("claude-3-5-sonnet-latest")

        XCTAssertEqual(store.textConfig.providerType, .anthropic)
        XCTAssertEqual(store.textConfig.baseURLString, "https://api.anthropic.com")
        XCTAssertEqual(store.textConfig.modelName, "claude-3-5-sonnet-latest")
    }

    func testHotkeyStoreAllowsWakeAndAgentUsingSameModifier() {
        let defaults = makeDefaults()
        let store = HotkeyStateStore(defaults: defaults)

        _ = store.setTriggerMode(.modifierTap, for: .wakeSession)
        _ = store.setModifier(.rightShift, for: .wakeSession)
        _ = store.setAgentModifier(.rightShift)

        XCTAssertFalse(store.hasConflict)
        XCTAssertNil(store.conflictMessage)
    }

    func testAgentMusicCapabilityDefaultsToEnabledAndCanBeTurnedOff() {
        let defaults = makeDefaults()

        XCTAssertTrue(AgentCapabilitySettings.isMusicControlEnabled(defaults: defaults))

        defaults.set(false, forKey: AgentCapabilitySettings.musicControlEnabledKey)
        XCTAssertFalse(AgentCapabilitySettings.isMusicControlEnabled(defaults: defaults))
    }

    func testAgentCalendarCapabilityDefaultsToEnabledAndCanBeTurnedOff() {
        let defaults = makeDefaults()

        XCTAssertTrue(AgentCapabilitySettings.isCalendarCreateEventEnabled(defaults: defaults))

        defaults.set(false, forKey: AgentCapabilitySettings.calendarCreateEventEnabledKey)
        XCTAssertFalse(AgentCapabilitySettings.isCalendarCreateEventEnabled(defaults: defaults))
    }

    func testAgentClockCapabilityDefaultsToEnabledAndCanBeTurnedOff() {
        let defaults = makeDefaults()

        XCTAssertTrue(AgentCapabilitySettings.isClockTimerEnabled(defaults: defaults))

        defaults.set(false, forKey: AgentCapabilitySettings.clockTimerEnabledKey)
        XCTAssertFalse(AgentCapabilitySettings.isClockTimerEnabled(defaults: defaults))
    }

    func testHistoryStoreKeepsSupportedModesFromOldFiles() throws {
        let directory = makeTemporaryDirectory()
        let file = directory.appendingPathComponent("session-history-v2.json")
        let payload = """
        [
          {
            "id": "11111111-1111-1111-1111-111111111111",
            "timestamp": "2026-05-17T09:00:00Z",
            "mode": "dictation",
            "appName": "Notes",
            "bundleID": "com.apple.Notes",
            "inputText": "asr raw",
            "outputText": "final text",
            "status": "success",
            "audioDurationSeconds": 2.5
          },
          {
            "id": "22222222-2222-2222-2222-222222222222",
            "timestamp": "2026-05-17T09:00:30Z",
            "mode": "agent",
            "appName": "Music",
            "bundleID": "com.apple.Music",
            "inputText": "播放稻香",
            "outputText": "已开始播放：周杰伦 - 稻香。",
            "status": "success",
            "agentEvidenceSummary": "apple.music.control|fast_path=true|state=play"
          },
          {
            "id": "33333333-3333-3333-3333-333333333333",
            "timestamp": "2026-05-17T09:01:00Z",
            "mode": "brainstorm",
            "appName": "Old",
            "bundleID": "old.bundle",
            "inputText": "old row",
            "outputText": "old output",
            "status": "success"
          }
        ]
        """
        try payload.data(using: .utf8)?.write(to: file)

        let store = LocalHistoryStore(historyDirectory: directory)

        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.entries.map(\.mode), [.agent, .dictation])
        XCTAssertEqual(store.entries.last?.inputText, "asr raw")
        XCTAssertEqual(store.entries.last?.outputText, "final text")
        XCTAssertEqual(store.lifetimeSnapshot.totalInputCharacters, "final text".count)
    }

    func testHistoryLifetimeStatsEstimateManualTypingTimeFromTimedEntriesOnly() {
        let directory = makeTemporaryDirectory()
        let store = LocalHistoryStore(historyDirectory: directory)

        store.append(
            SessionHistoryEntry(
                appName: "Notes",
                bundleID: "com.apple.Notes",
                inputText: "",
                outputText: String(repeating: "字", count: 120),
                status: .success,
                audioDurationSeconds: 60
            )
        )
        store.append(
            SessionHistoryEntry(
                appName: "Legacy",
                bundleID: "legacy.bundle",
                inputText: "",
                outputText: String(repeating: "旧", count: 80),
                status: .success,
                audioDurationSeconds: nil
            )
        )

        XCTAssertEqual(store.lifetimeSnapshot.totalInputCharacters, 200)
        XCTAssertEqual(store.lifetimeSnapshot.averageCharactersPerMinute, 120, accuracy: 0.01)
        XCTAssertEqual(store.lifetimeSnapshot.savedTypingSeconds, 30, accuracy: 0.01)
    }

    func testSessionStoreRunsOrdinaryDictationPhasesOnly() {
        let store = SessionStore()
        let transcription = SpeechTranscriptionResult(
            providerType: .dashScopeQwenASR,
            providerName: "Qwen",
            modelName: "qwen3-asr-flash",
            transcript: "原始文本"
        )
        let focusContext = FocusedAppContext(
            appName: "Notes",
            bundleID: "com.apple.Notes",
            focusedRole: nil,
            hasEditableTarget: true,
            strategyHint: "test"
        )
        let output = TextOutputResult(
            appName: "Notes",
            bundleID: "com.apple.Notes",
            path: .accessibilitySelectionReplacement,
            usedFallback: false,
            didInsertIntoEditor: true,
            operation: .insertText
        )

        store.startDictation()
        XCTAssertEqual(store.phase, .listening)
        XCTAssertEqual(store.activeLane, .directDictation)

        store.markTranscribing(audioSummary: "1.0 秒，16000Hz")
        XCTAssertEqual(store.phase, .transcribing)

        store.completeTranscription(result: transcription)
        store.markDictationPostProcessing(providerName: "DeepSeek", modelName: "deepseek-v4-flash")
        XCTAssertEqual(store.phase, .textProcessing)

        store.markInserting(transcription: transcription, focusContext: focusContext)
        XCTAssertEqual(store.phase, .inserting)

        store.completeInsertion(outputResult: output)
        XCTAssertEqual(store.phase, .idle)
        XCTAssertEqual(store.latestTranscription?.transcript, "原始文本")
    }

    func testStableStreamingPrefixAccumulatorOnlyWritesStableText() {
        var accumulator = StableStreamingPrefixAccumulator()

        XCTAssertNil(accumulator.ingest("今天我们"))
        XCTAssertNil(accumulator.ingest("今天我们要测试"))
        XCTAssertNil(accumulator.ingest("今天我们要测试，后续继续"))
        let delta = accumulator.ingest("今天我们要测试，后续继续。")

        XCTAssertEqual(delta, "今天我们要测试，")
        let finalization = accumulator.finalize(with: "今天我们要测试，后续继续。")
        XCTAssertEqual(finalization.finalWritebackText, "后续继续。")
    }

    func testInteractionCoordinatorRunsASRThenDeepSeekThenWriteHistory() async throws {
        let directory = makeTemporaryDirectory()
        let credentials = MemoryCredentialStore()
        try credentials.saveAPIKey("asr-key-123456", for: defaultASRCredentialKeyRef)
        try credentials.saveAPIKey("text-key-123456", for: defaultTextCredentialKeyRef)

        let sessionStore = SessionStore()
        let audioCaptureService = FakeAudioCaptureService(directory: directory)
        let outputCoordinator = FakeTextOutputCoordinator()
        let historyStore = LocalHistoryStore(historyDirectory: directory.appendingPathComponent("History"))
        let providerSettingsStore = ProviderSettingsStore(
            defaults: makeDefaults(),
            credentialStore: credentials
        )
        let coordinator = InteractionCoordinator(
            sessionStore: sessionStore,
            permissionsCenter: PermissionsCenter(
                microphoneStateResolver: { .granted },
                accessibilityStateResolver: { .granted }
            ),
            audioCaptureService: audioCaptureService,
            providerSettingsStore: providerSettingsStore,
            providerRegistry: SpeechProviderRegistry(providers: [FakeTranscriptionProvider()]),
            textOutputCoordinator: outputCoordinator,
            contextDetector: FixedContextDetector(),
            localHistoryStore: historyStore,
            speechPipelineLogger: SpeechPipelineLogger(diagnosticsDirectory: directory.appendingPathComponent("Diagnostics")),
            dictationPostProcessor: FakeDictationPostProcessor(output: "DeepSeek 整理后文本")
        )

        coordinator.handleWakeInput()
        XCTAssertEqual(sessionStore.phase, .listening)
        coordinator.handleWakeInput()

        try await waitUntil { outputCoordinator.requests.count == 1 }
        XCTAssertEqual(outputCoordinator.requests.first?.text, "DeepSeek 整理后文本")
        XCTAssertEqual(historyStore.entries.first?.inputText, "ASR 原文")
        XCTAssertEqual(historyStore.entries.first?.outputText, "DeepSeek 整理后文本")
        XCTAssertEqual(historyStore.entries.first?.textProcessingModel, "deepseek-v4-flash")
        XCTAssertEqual(sessionStore.phase, .idle)
    }

    func testLLMAgentRouterParsesSelectedToolIDFromModelJSON() async throws {
        let router = LLMAgentToolRouter(
            generationProvider: FakeTextGenerationProvider(
                output: "{\"tool_id\":\"\(AgentCapabilitySettings.musicControlToolID)\"}"
            )
        )

        let outcome = try await router.route(
            request: AgentRouteRequest(
                traceID: "trace-1",
                command: "播放稻香",
                tools: [Self.musicToolManifest]
            ),
            configuration: makeTextGenerationConfiguration(),
            apiKey: "text-key-123456"
        )

        XCTAssertEqual(outcome.toolID, AgentCapabilitySettings.musicControlToolID)
        XCTAssertEqual(outcome.providerName, "OpenAI 兼容")
        XCTAssertEqual(outcome.modelName, "deepseek-v4-flash")
        XCTAssertTrue(outcome.evidenceSummary.contains("agent.route"))
    }

    func testCalendarParameterExtractorParsesModelJSON() async throws {
        let extractor = LLMAgentCalendarParameterExtractor(
            generationProvider: FakeTextGenerationProvider(
                output: """
                {
                  "title": "项目会议",
                  "start_at": "2026-05-23T09:00:00+08:00",
                  "end_at": "2026-05-23T10:00:00+08:00",
                  "calendar": null,
                  "location": "",
                  "notes": "",
                  "alarm_minutes_before": 10
                }
                """
            )
        )

        let result = try await extractor.extract(
            request: AgentCalendarParameterExtractionRequest(
                command: "我下周六九点有个会",
                referenceDate: Date(timeIntervalSince1970: 1_779_029_200),
                timeZone: TimeZone(identifier: "Asia/Shanghai")!
            ),
            configuration: makeTextGenerationConfiguration(),
            apiKey: "text-key-123456"
        )

        XCTAssertEqual(result.title, "项目会议")
        XCTAssertEqual(result.startAtISO8601, "2026-05-23T09:00:00+08:00")
        XCTAssertEqual(result.endAtISO8601, "2026-05-23T10:00:00+08:00")
        XCTAssertEqual(result.alarmMinutesBefore, 10)
    }

    func testCalendarParameterExtractorIgnoresConfirmationFlagAndKeepsOneShotPath() async throws {
        let extractor = LLMAgentCalendarParameterExtractor(
            generationProvider: FakeTextGenerationProvider(
                output: """
                {
                  "title": "会议",
                  "start_at": "2026-05-23T09:00:00+08:00",
                  "end_at": "2026-05-23T10:00:00+08:00",
                  "calendar": null,
                  "location": "",
                  "notes": "",
                  "alarm_minutes_before": null,
                  "needs_confirmation": true,
                  "confirmation_question": "你想定几点？"
                }
                """
            )
        )

        let result = try await extractor.extract(
            request: AgentCalendarParameterExtractionRequest(
                command: "有个会，帮我定一下",
                referenceDate: Date(timeIntervalSince1970: 1_779_029_200),
                timeZone: TimeZone(identifier: "Asia/Shanghai")!
            ),
            configuration: makeTextGenerationConfiguration(),
            apiKey: "text-key-123456"
        )

        XCTAssertEqual(result.title, "会议")
        XCTAssertEqual(result.startAtISO8601, "2026-05-23T09:00:00+08:00")
    }

    func testCalendarParameterExtractorBackfillsSparseModelOutputWithoutAsking() async throws {
        let extractor = LLMAgentCalendarParameterExtractor(
            generationProvider: FakeTextGenerationProvider(
                output: """
                {
                  "title": "",
                  "start_at": "",
                  "end_at": null,
                  "calendar": null,
                  "location": "",
                  "notes": "",
                  "alarm_minutes_before": null
                }
                """
            )
        )

        let result = try await extractor.extract(
            request: AgentCalendarParameterExtractionRequest(
                command: "九点有个会",
                referenceDate: Date(timeIntervalSince1970: 1_779_029_200),
                timeZone: TimeZone(identifier: "Asia/Shanghai")!
            ),
            configuration: makeTextGenerationConfiguration(),
            apiKey: "text-key-123456"
        )

        XCTAssertEqual(result.title, "九点有个会")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        XCTAssertNotNil(formatter.date(from: result.startAtISO8601))
    }

    func testCalendarExecutorCreatesEventAfterModelParameterExtraction() async throws {
        let scriptRunner = FakeAgentCalendarScriptRunner(
            result: AgentCalendarScriptResult(
                exitCode: 0,
                stdout: "event_created|calendar=工作|uid=event-1|summary=项目会议",
                stderr: ""
            )
        )
        let executor = AgentCalendarCreateEventExecutor(
            parameterExtractor: LLMAgentCalendarParameterExtractor(
                generationProvider: FakeTextGenerationProvider(
                    output: """
                    {
                      "title": "项目会议",
                      "start_at": "2026-05-23T09:00:00+08:00",
                      "end_at": "2026-05-23T10:00:00+08:00",
                      "calendar": "工作",
                      "location": "会议室 A",
                      "notes": "讨论排期",
                      "alarm_minutes_before": 10
                    }
                    """
                )
            ),
            scriptRunner: scriptRunner
        )

        let outcome = await executor.execute(
            AgentCalendarExecutionRequest(
                traceID: "trace-calendar",
                command: "我下周六九点有个项目会议",
                referenceDate: Date(timeIntervalSince1970: 1_779_029_200),
                timeZone: TimeZone(identifier: "Asia/Shanghai")!
            ),
            configuration: makeTextGenerationConfiguration(),
            apiKey: "text-key-123456"
        )

        XCTAssertEqual(outcome.status, .success)
        XCTAssertEqual(outcome.outputText, "已创建日程：项目会议。")
        XCTAssertEqual(scriptRunner.createdSpecs.first?.title, "项目会议")
        XCTAssertEqual(scriptRunner.createdSpecs.first?.calendarName, "工作")
        XCTAssertEqual(scriptRunner.createdSpecs.first?.location, "会议室 A")
        XCTAssertEqual(scriptRunner.createdSpecs.first?.notes, "讨论排期")
        XCTAssertEqual(scriptRunner.createdSpecs.first?.alarmMinutesBefore, 10)
        XCTAssertTrue(outcome.evidenceSummary.contains("apple.calendar.create_event"))
        XCTAssertTrue(outcome.evidenceSummary.contains("verification=created"))
    }

    func testClockParameterExtractorParsesModelJSON() async throws {
        let extractor = LLMAgentClockParameterExtractor(
            generationProvider: FakeTextGenerationProvider(
                output: """
                {
                  "title": "起床闹钟",
                  "fire_at": "2026-05-23T07:00:00+08:00",
                  "notes": "提醒起床"
                }
                """
            )
        )

        let result = try await extractor.extract(
            request: AgentClockParameterExtractionRequest(
                command: "明早七点叫我起床",
                referenceDate: Date(timeIntervalSince1970: 1_779_029_200),
                timeZone: TimeZone(identifier: "Asia/Shanghai")!
            ),
            configuration: makeTextGenerationConfiguration(),
            apiKey: "text-key-123456"
        )

        XCTAssertEqual(result.title, "起床闹钟")
        XCTAssertEqual(result.fireAtISO8601, "2026-05-23T07:00:00+08:00")
        XCTAssertEqual(result.notes, "提醒起床")
    }

    func testClockParameterExtractorBuildsHeuristicTitleWhenPrimaryTitleIsEmpty() async throws {
        let extractor = LLMAgentClockParameterExtractor(
            generationProvider: FakeTextGenerationProvider(
                output: """
                {
                  "action": "create_one_shot_alarm",
                  "title": "",
                  "fire_at": "2026-05-23T07:00:00+08:00",
                  "notes": "提醒起床"
                }
                """
            )
        )

        let result = try await extractor.extract(
            request: AgentClockParameterExtractionRequest(
                command: "明早七点提醒我上课",
                referenceDate: Date(timeIntervalSince1970: 1_779_029_200),
                timeZone: TimeZone(identifier: "Asia/Shanghai")!
            ),
            configuration: makeTextGenerationConfiguration(),
            apiKey: "text-key-123456"
        )

        XCTAssertFalse(result.title.isEmpty)
        XCTAssertNotEqual(result.title, "闹钟")
        XCTAssertNotEqual(result.title, "提醒")
        XCTAssertNotEqual(result.title, "闹钟提醒")
    }

    func testClockParameterExtractorParsesChineseTimeWhenFireAtMissing() async throws {
        let extractor = LLMAgentClockParameterExtractor(
            generationProvider: FakeTextGenerationProvider(
                output: """
                {
                  "action": "create_one_shot_alarm",
                  "title": "帮班主任干活",
                  "fire_at": "",
                  "notes": "提醒办事"
                }
                """
            )
        )

        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        let referenceDate = Date(timeIntervalSince1970: 1_779_029_200)
        let result = try await extractor.extract(
            request: AgentClockParameterExtractionRequest(
                command: "定一个今天下午五点二十的闹钟",
                referenceDate: referenceDate,
                timeZone: shanghai
            ),
            configuration: makeTextGenerationConfiguration(),
            apiKey: "text-key-123456"
        )

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsedWithFraction = formatter.date(from: result.fireAtISO8601)
        formatter.formatOptions = [.withInternetDateTime]
        guard let fireDate = parsedWithFraction ?? formatter.date(from: result.fireAtISO8601) else {
            XCTFail("fire_at 不是合法 ISO8601: \(result.fireAtISO8601)")
            return
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghai
        let fireComponents = calendar.dateComponents([.hour, .minute], from: fireDate)
        XCTAssertEqual(fireComponents.hour, 17)
        XCTAssertEqual(fireComponents.minute, 20)
        XCTAssertTrue(calendar.isDate(fireDate, equalTo: referenceDate, toGranularity: .day))
    }

    func testClockExecutorRunsClockAppleScriptAfterModelExtraction() async throws {
        let runner = FakeAgentClockRunner(
            result: AgentClockExecutionResult(success: true, identifier: "clock-1", detail: "alarm_created")
        )
        let executor = AgentClockTimerExecutor(
            parameterExtractor: LLMAgentClockParameterExtractor(
                generationProvider: FakeTextGenerationProvider(
                    output: """
                    {
                      "action": "create_one_shot_alarm",
                      "title": "会议提醒",
                      "fire_at": "2026-05-23T20:30:00+08:00",
                      "notes": "提醒开会"
                    }
                    """
                )
            ),
            runner: runner
        )

        let outcome = await executor.execute(
            AgentClockTimerExecutionRequest(
                traceID: "trace-clock",
                command: "今晚八点半提醒我开会",
                referenceDate: Date(timeIntervalSince1970: 1_779_029_200),
                timeZone: TimeZone(identifier: "Asia/Shanghai")!
            ),
            configuration: makeTextGenerationConfiguration(),
            apiKey: "text-key-123456"
        )

        XCTAssertEqual(outcome.status, .success)
        XCTAssertEqual(outcome.outputText, "已设置闹钟：会议提醒。")
        XCTAssertEqual(runner.executedSpecs.first?.title, "会议提醒")
        XCTAssertEqual(runner.executedSpecs.first?.notes, "提醒开会")
        XCTAssertEqual(runner.executedSpecs.first?.action, "create_one_shot_alarm")
        XCTAssertTrue(outcome.evidenceSummary.contains("apple.clock.timer"))
    }

    func testInteractionCoordinatorRoutesAgentCommandBeforeExecutingMusicTool() async throws {
        let directory = makeTemporaryDirectory()
        let credentials = MemoryCredentialStore()
        try credentials.saveAPIKey("asr-key-123456", for: defaultASRCredentialKeyRef)
        try credentials.saveAPIKey("text-key-123456", for: defaultTextCredentialKeyRef)

        let sessionStore = SessionStore()
        let historyStore = LocalHistoryStore(historyDirectory: directory.appendingPathComponent("History"))
        let router = FakeAgentToolRouter(toolID: AgentCapabilitySettings.musicControlToolID)
        let musicExecutor = FakeAgentMusicExecutor(
            outcome: AgentMusicExecutionOutcome(
                status: .success,
                message: "已执行音乐。",
                outputText: "已执行音乐。",
                evidenceSummary: "apple.music.control|fake=true"
            )
        )
        let coordinator = InteractionCoordinator(
            sessionStore: sessionStore,
            permissionsCenter: PermissionsCenter(
                microphoneStateResolver: { .granted },
                accessibilityStateResolver: { .granted }
            ),
            audioCaptureService: FakeAudioCaptureService(directory: directory),
            providerSettingsStore: ProviderSettingsStore(
                defaults: makeDefaults(),
                credentialStore: credentials
            ),
            providerRegistry: SpeechProviderRegistry(providers: [FakeTranscriptionProvider()]),
            textOutputCoordinator: FakeTextOutputCoordinator(),
            contextDetector: FixedContextDetector(),
            localHistoryStore: historyStore,
            speechPipelineLogger: SpeechPipelineLogger(diagnosticsDirectory: directory.appendingPathComponent("Diagnostics")),
            dictationPostProcessor: FakeDictationPostProcessor(output: "不会走普通听写整理"),
            agentRouter: router,
            agentToolCatalog: FakeAgentToolCatalog(tools: [Self.musicToolManifest]),
            agentMusicExecutor: musicExecutor
        )

        coordinator.handleWakeInput(context: .agentHold)
        XCTAssertEqual(sessionStore.phase, .listening)
        coordinator.handleWakeInput(context: .agentHold)

        try await waitUntil { historyStore.entries.count == 1 }
        XCTAssertEqual(router.requests.first?.command, "ASR 原文")
        XCTAssertEqual(musicExecutor.requests.first?.command, "ASR 原文")
        XCTAssertEqual(historyStore.entries.first?.mode, .agent)
        XCTAssertEqual(historyStore.entries.first?.status, .success)
        XCTAssertEqual(historyStore.entries.first?.outputText, "已执行音乐。")
        XCTAssertEqual(historyStore.entries.first?.textProcessingModel, "deepseek-v4-flash")
        XCTAssertTrue(historyStore.entries.first?.agentEvidenceSummary?.contains("agent.route") == true)
        XCTAssertTrue(historyStore.entries.first?.agentEvidenceSummary?.contains("apple.music.control|fake=true") == true)
        XCTAssertEqual(sessionStore.phase, .idle)
    }

    func testInteractionCoordinatorRoutesCalendarCommandBeforeExecutingCalendarTool() async throws {
        let directory = makeTemporaryDirectory()
        let credentials = MemoryCredentialStore()
        try credentials.saveAPIKey("asr-key-123456", for: defaultASRCredentialKeyRef)
        try credentials.saveAPIKey("text-key-123456", for: defaultTextCredentialKeyRef)

        let sessionStore = SessionStore()
        let historyStore = LocalHistoryStore(historyDirectory: directory.appendingPathComponent("History"))
        let router = FakeAgentToolRouter(toolID: AgentCapabilitySettings.calendarCreateEventToolID)
        let calendarExecutor = FakeAgentCalendarExecutor(
            outcome: AgentCalendarExecutionOutcome(
                status: .success,
                message: "已创建日程：项目会议。",
                outputText: "已创建日程：项目会议。",
                evidenceSummary: "apple.calendar.create_event|fake=true"
            )
        )
        let coordinator = InteractionCoordinator(
            sessionStore: sessionStore,
            permissionsCenter: PermissionsCenter(
                microphoneStateResolver: { .granted },
                accessibilityStateResolver: { .granted }
            ),
            audioCaptureService: FakeAudioCaptureService(directory: directory),
            providerSettingsStore: ProviderSettingsStore(
                defaults: makeDefaults(),
                credentialStore: credentials
            ),
            providerRegistry: SpeechProviderRegistry(providers: [FakeTranscriptionProvider()]),
            textOutputCoordinator: FakeTextOutputCoordinator(),
            contextDetector: FixedContextDetector(),
            localHistoryStore: historyStore,
            speechPipelineLogger: SpeechPipelineLogger(diagnosticsDirectory: directory.appendingPathComponent("Diagnostics")),
            dictationPostProcessor: FakeDictationPostProcessor(output: "不会走普通听写整理"),
            agentRouter: router,
            agentToolCatalog: FakeAgentToolCatalog(tools: [Self.calendarToolManifest]),
            agentCalendarExecutor: calendarExecutor
        )

        coordinator.handleWakeInput(context: .agentHold)
        coordinator.handleWakeInput(context: .agentHold)

        try await waitUntil { historyStore.entries.count == 1 }
        XCTAssertEqual(router.requests.first?.command, "ASR 原文")
        XCTAssertEqual(calendarExecutor.requests.first?.command, "ASR 原文")
        XCTAssertEqual(historyStore.entries.first?.mode, .agent)
        XCTAssertEqual(historyStore.entries.first?.status, .success)
        XCTAssertEqual(historyStore.entries.first?.outputText, "已创建日程：项目会议。")
        XCTAssertEqual(historyStore.entries.first?.textProcessingModel, "deepseek-v4-flash")
        XCTAssertTrue(historyStore.entries.first?.agentEvidenceSummary?.contains("agent.route") == true)
        XCTAssertTrue(historyStore.entries.first?.agentEvidenceSummary?.contains("apple.calendar.create_event|fake=true") == true)
        XCTAssertEqual(sessionStore.phase, .idle)
    }

    func testInteractionCoordinatorRoutesClockCommandBeforeExecutingClockTool() async throws {
        let directory = makeTemporaryDirectory()
        let credentials = MemoryCredentialStore()
        try credentials.saveAPIKey("asr-key-123456", for: defaultASRCredentialKeyRef)
        try credentials.saveAPIKey("text-key-123456", for: defaultTextCredentialKeyRef)

        let sessionStore = SessionStore()
        let historyStore = LocalHistoryStore(historyDirectory: directory.appendingPathComponent("History"))
        let router = FakeAgentToolRouter(toolID: AgentCapabilitySettings.clockTimerToolID)
        let clockExecutor = FakeAgentClockExecutor(
            outcome: AgentClockTimerExecutionOutcome(
                status: .success,
                message: "已设置闹钟：起床闹钟。",
                outputText: "已设置闹钟：起床闹钟。",
                evidenceSummary: "apple.clock.timer|fake=true"
            )
        )
        let coordinator = InteractionCoordinator(
            sessionStore: sessionStore,
            permissionsCenter: PermissionsCenter(
                microphoneStateResolver: { .granted },
                accessibilityStateResolver: { .granted }
            ),
            audioCaptureService: FakeAudioCaptureService(directory: directory),
            providerSettingsStore: ProviderSettingsStore(
                defaults: makeDefaults(),
                credentialStore: credentials
            ),
            providerRegistry: SpeechProviderRegistry(providers: [FakeTranscriptionProvider()]),
            textOutputCoordinator: FakeTextOutputCoordinator(),
            contextDetector: FixedContextDetector(),
            localHistoryStore: historyStore,
            speechPipelineLogger: SpeechPipelineLogger(diagnosticsDirectory: directory.appendingPathComponent("Diagnostics")),
            dictationPostProcessor: FakeDictationPostProcessor(output: "不会走普通听写整理"),
            agentRouter: router,
            agentToolCatalog: FakeAgentToolCatalog(tools: [Self.clockToolManifest]),
            agentClockExecutor: clockExecutor
        )

        coordinator.handleWakeInput(context: .agentHold)
        coordinator.handleWakeInput(context: .agentHold)

        try await waitUntil { historyStore.entries.count == 1 }
        XCTAssertEqual(router.requests.first?.command, "ASR 原文")
        XCTAssertEqual(clockExecutor.requests.first?.command, "ASR 原文")
        XCTAssertEqual(historyStore.entries.first?.mode, .agent)
        XCTAssertEqual(historyStore.entries.first?.status, .success)
        XCTAssertEqual(historyStore.entries.first?.outputText, "已设置闹钟：起床闹钟。")
        XCTAssertTrue(historyStore.entries.first?.agentEvidenceSummary?.contains("agent.route") == true)
        XCTAssertTrue(historyStore.entries.first?.agentEvidenceSummary?.contains("apple.clock.timer|fake=true") == true)
        XCTAssertEqual(sessionStore.phase, .idle)
    }

    func testInteractionCoordinatorFailsAgentWhenNoToolsAreEnabled() async throws {
        let directory = makeTemporaryDirectory()
        let credentials = MemoryCredentialStore()
        try credentials.saveAPIKey("asr-key-123456", for: defaultASRCredentialKeyRef)

        let sessionStore = SessionStore()
        let historyStore = LocalHistoryStore(historyDirectory: directory.appendingPathComponent("History"))
        let router = FakeAgentToolRouter(toolID: AgentCapabilitySettings.musicControlToolID)
        let coordinator = InteractionCoordinator(
            sessionStore: sessionStore,
            permissionsCenter: PermissionsCenter(
                microphoneStateResolver: { .granted },
                accessibilityStateResolver: { .granted }
            ),
            audioCaptureService: FakeAudioCaptureService(directory: directory),
            providerSettingsStore: ProviderSettingsStore(
                defaults: makeDefaults(),
                credentialStore: credentials
            ),
            providerRegistry: SpeechProviderRegistry(providers: [FakeTranscriptionProvider()]),
            textOutputCoordinator: FakeTextOutputCoordinator(),
            contextDetector: FixedContextDetector(),
            localHistoryStore: historyStore,
            speechPipelineLogger: SpeechPipelineLogger(diagnosticsDirectory: directory.appendingPathComponent("Diagnostics")),
            dictationPostProcessor: FakeDictationPostProcessor(output: "不会走普通听写整理"),
            agentRouter: router,
            agentToolCatalog: FakeAgentToolCatalog(tools: []),
            agentMusicExecutor: FakeAgentMusicExecutor()
        )

        coordinator.handleWakeInput(context: .agentHold)
        coordinator.handleWakeInput(context: .agentHold)

        try await waitUntil { historyStore.entries.count == 1 }
        XCTAssertTrue(router.requests.isEmpty)
        XCTAssertEqual(historyStore.entries.first?.mode, .agent)
        XCTAssertEqual(historyStore.entries.first?.status, .failed)
        XCTAssertEqual(historyStore.entries.first?.errorMessage, AgentRouteError.noCandidateTools.localizedDescription)
        XCTAssertTrue(historyStore.entries.first?.agentEvidenceSummary?.contains("error=no_enabled_tools") == true)
        XCTAssertEqual(sessionStore.phase, .error)
    }

    func testCancelIgnoredAfterSessionAlreadyCancelled() {
        let directory = makeTemporaryDirectory()
        let sessionStore = SessionStore()
        let historyStore = LocalHistoryStore(historyDirectory: directory.appendingPathComponent("History"))
        let coordinator = InteractionCoordinator(
            sessionStore: sessionStore,
            permissionsCenter: PermissionsCenter(
                microphoneStateResolver: { .granted },
                accessibilityStateResolver: { .granted }
            ),
            audioCaptureService: FakeAudioCaptureService(directory: directory),
            providerSettingsStore: ProviderSettingsStore(
                defaults: makeDefaults(),
                credentialStore: MemoryCredentialStore()
            ),
            providerRegistry: SpeechProviderRegistry(providers: [FakeTranscriptionProvider()]),
            textOutputCoordinator: FakeTextOutputCoordinator(),
            contextDetector: FixedContextDetector(),
            localHistoryStore: historyStore,
            speechPipelineLogger: SpeechPipelineLogger(diagnosticsDirectory: directory.appendingPathComponent("Diagnostics")),
            dictationPostProcessor: FakeDictationPostProcessor(output: "整理后文本")
        )

        sessionStore.startDictation()
        coordinator.handleCancelInput()
        XCTAssertEqual(historyStore.entries.count, 1)

        coordinator.handleCancelInput()
        XCTAssertEqual(historyStore.entries.count, 1)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "PulseTypeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PulseTypeTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeTextGenerationConfiguration() -> TextGenerationProviderConfiguration {
        TextGenerationProviderConfiguration(
            profileID: defaultTextCredentialKeyRef,
            providerType: .openAICompatible,
            providerName: "OpenAI 兼容",
            modelName: "deepseek-v4-flash",
            baseURL: URL(string: "https://api.deepseek.com")!
        )
    }

    private static let musicToolManifest = AgentToolManifest(
        toolID: AgentCapabilitySettings.musicControlToolID,
        displayName: "音乐控制",
        description: "控制 Apple Music 播放、暂停、继续和切歌。",
        examples: ["播放稻香", "下一首"]
    )

    private static let calendarToolManifest = AgentToolManifest(
        toolID: AgentCapabilitySettings.calendarCreateEventToolID,
        displayName: "日历日程",
        description: "在 Calendar 创建会议、约会、行程等日程。",
        examples: ["我下周六九点有个会", "明天下午三点安排项目讨论"]
    )

    private static let clockToolManifest = AgentToolManifest(
        toolID: AgentCapabilitySettings.clockTimerToolID,
        displayName: "闹钟提醒",
        description: "创建一次性闹钟提醒。",
        examples: ["明早七点叫我起床", "今晚九点半提醒我开会"]
    )

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for condition.")
    }
}

final class MemoryCredentialStore: ProviderCredentialStore {
    private var values: [String: String] = [:]

    func loadAPIKey(for profileID: String) throws -> String? {
        values[profileID]
    }

    func saveAPIKey(_ value: String, for profileID: String) throws {
        values[profileID] = value
    }

    func deleteAPIKey(for profileID: String) throws {
        values.removeValue(forKey: profileID)
    }

    func containsAPIKey(for profileID: String, allowUserInteraction _: Bool) throws -> Bool {
        values[profileID]?.isEmpty == false
    }
}

@MainActor
final class FakeAudioCaptureService: AudioCaptureService {
    let preferredSampleRate: Double = 16_000
    let audioFormatDescription = "fake wav"
    let levelSubject = CurrentValueSubject<Double, Never>(0)
    private let directory: URL
    private var activeFileURL: URL?
    private(set) var isRecording = false

    init(directory: URL) {
        self.directory = directory
    }

    var levelPublisher: AnyPublisher<Double, Never> {
        levelSubject.eraseToAnyPublisher()
    }

    func startRecording() throws {
        isRecording = true
        let url = directory.appendingPathComponent("clip.wav")
        try Data("fake".utf8).write(to: url)
        activeFileURL = url
    }

    func stopRecording() throws -> RecordedAudioClip {
        guard let activeFileURL else {
            throw AudioCaptureError.noClipAvailable
        }
        isRecording = false
        self.activeFileURL = nil
        return RecordedAudioClip(
            id: UUID(),
            fileURL: activeFileURL,
            duration: 1.2,
            sampleRate: preferredSampleRate,
            createdAt: Date()
        )
    }

    func cancelRecording() {
        isRecording = false
        if let activeFileURL {
            try? FileManager.default.removeItem(at: activeFileURL)
        }
        activeFileURL = nil
    }

    func removeClip(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func purgeStaleTemporaryFiles(olderThan _: TimeInterval) -> Int {
        0
    }
}

struct FakeTranscriptionProvider: SpeechTranscriptionProvider {
    let supportedProviderTypes: [ProviderType] = [.dashScopeQwenASR]

    func transcribe(
        request _: SpeechTranscriptionRequest,
        configuration: SpeechProviderConfiguration,
        apiKey _: String
    ) async throws -> SpeechTranscriptionResult {
        SpeechTranscriptionResult(
            providerType: configuration.providerType,
            providerName: configuration.providerName,
            modelName: configuration.modelName,
            transcript: "ASR 原文"
        )
    }
}

@MainActor
final class FakeTextOutputCoordinator: TextOutputCoordinator {
    let insertionStrategy = "fake"
    private(set) var requests: [TextOutputRequest] = []

    func currentSelectionSnapshot() -> FocusedSelectionSnapshot? {
        nil
    }

    func captureSelectionSnapshot() async -> FocusedSelectionSnapshot? {
        nil
    }

    func captureSelectionSnapshot(preferredTarget _: WritebackTargetSnapshot?) async -> FocusedSelectionSnapshot? {
        nil
    }

    func write(request: TextOutputRequest) async throws -> TextOutputResult {
        requests.append(request)
        return TextOutputResult(
            appName: request.focusContext.appName,
            bundleID: request.focusContext.bundleID,
            path: .accessibilitySelectionReplacement,
            usedFallback: false,
            didInsertIntoEditor: true,
            operation: request.operation
        )
    }
}

struct FixedContextDetector: ContextDetector {
    func focusedAppContext() -> FocusedAppContext {
        FocusedAppContext(
            appName: "Notes",
            bundleID: "com.apple.Notes",
            focusedRole: nil,
            hasEditableTarget: true,
            strategyHint: "test"
        )
    }
}

struct FakeDictationPostProcessor: DictationPostProcessor {
    let output: String

    func process(
        request _: DictationPostProcessRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey _: String
    ) async throws -> DictationPostProcessResult {
        DictationPostProcessResult(
            outputText: output,
            providerName: configuration.providerName,
            modelName: configuration.modelName
        )
    }
}

final class FakeTextGenerationProvider: TextGenerationProvider, @unchecked Sendable {
    let supportedProviderTypes: [ProviderType] = [.openAICompatible]
    private let outputs: [String]
    private let lock = NSLock()
    private var index = 0

    init(output: String) {
        self.outputs = [output]
    }

    init(outputs: [String]) {
        self.outputs = outputs.isEmpty ? [""] : outputs
    }

    func generateText(
        request _: TextGenerationRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey _: String
    ) async throws -> TextGenerationResult {
        let selectedOutput: String = {
            lock.lock()
            defer { lock.unlock() }
            let bounded = min(index, outputs.count - 1)
            let value = outputs[bounded]
            index += 1
            return value
        }()
        return TextGenerationResult(
            providerType: configuration.providerType,
            providerName: configuration.providerName,
            modelName: configuration.modelName,
            outputText: selectedOutput
        )
    }
}

final class FakeAgentCalendarScriptRunner: AgentCalendarScriptRunning, @unchecked Sendable {
    private(set) var createdSpecs: [AgentCalendarEventSpec] = []
    private let result: AgentCalendarScriptResult

    init(result: AgentCalendarScriptResult) {
        self.result = result
    }

    func createEvent(_ spec: AgentCalendarEventSpec) async -> AgentCalendarScriptResult {
        createdSpecs.append(spec)
        return result
    }
}

final class FakeAgentClockRunner: AgentClockScriptRunning, @unchecked Sendable {
    private(set) var executedSpecs: [AgentClockTimerSpec] = []
    private let result: AgentClockExecutionResult

    init(result: AgentClockExecutionResult) {
        self.result = result
    }

    func execute(_ spec: AgentClockTimerSpec) async -> AgentClockExecutionResult {
        executedSpecs.append(spec)
        return result
    }
}

@MainActor
final class FakeAgentToolCatalog: AgentToolCatalogProviding {
    private let tools: [AgentToolManifest]

    init(tools: [AgentToolManifest]) {
        self.tools = tools
    }

    func loadEnabledTools() -> [AgentToolManifest] {
        tools
    }
}

@MainActor
final class FakeAgentToolRouter: AgentToolRouting {
    private(set) var requests: [AgentRouteRequest] = []
    private let toolID: String

    init(toolID: String) {
        self.toolID = toolID
    }

    func route(
        request: AgentRouteRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey _: String
    ) async throws -> AgentRouteOutcome {
        requests.append(request)
        return AgentRouteOutcome(
            traceID: request.traceID,
            toolID: toolID,
            providerName: configuration.providerName,
            modelName: configuration.modelName,
            rawOutput: "{\"tool_id\":\"\(toolID)\"}",
            latencyMilliseconds: 1
        )
    }
}

@MainActor
final class FakeAgentMusicExecutor: AgentMusicControlling {
    private(set) var requests: [AgentMusicExecutionRequest] = []
    private let outcome: AgentMusicExecutionOutcome

    init(
        outcome: AgentMusicExecutionOutcome = AgentMusicExecutionOutcome(
            status: .success,
            message: "已执行音乐。",
            outputText: "已执行音乐。",
            evidenceSummary: "apple.music.control|fake=true"
        )
    ) {
        self.outcome = outcome
    }

    func execute(_ request: AgentMusicExecutionRequest) async -> AgentMusicExecutionOutcome {
        requests.append(request)
        return outcome
    }
}

@MainActor
final class FakeAgentCalendarExecutor: AgentCalendarControlling {
    private(set) var requests: [AgentCalendarExecutionRequest] = []
    private let outcome: AgentCalendarExecutionOutcome

    init(
        outcome: AgentCalendarExecutionOutcome = AgentCalendarExecutionOutcome(
            status: .success,
            message: "已创建日程。",
            outputText: "已创建日程。",
            evidenceSummary: "apple.calendar.create_event|fake=true"
        )
    ) {
        self.outcome = outcome
    }

    func execute(
        _ request: AgentCalendarExecutionRequest,
        configuration _: TextGenerationProviderConfiguration,
        apiKey _: String
    ) async -> AgentCalendarExecutionOutcome {
        requests.append(request)
        return outcome
    }
}

@MainActor
final class FakeAgentClockExecutor: AgentClockTimerControlling {
    private(set) var requests: [AgentClockTimerExecutionRequest] = []
    private let outcome: AgentClockTimerExecutionOutcome

    init(
        outcome: AgentClockTimerExecutionOutcome = AgentClockTimerExecutionOutcome(
            status: .success,
            message: "已设置闹钟。",
            outputText: "已设置闹钟。",
            evidenceSummary: "apple.clock.timer|fake=true"
        )
    ) {
        self.outcome = outcome
    }

    func execute(
        _ request: AgentClockTimerExecutionRequest,
        configuration _: TextGenerationProviderConfiguration,
        apiKey _: String
    ) async -> AgentClockTimerExecutionOutcome {
        requests.append(request)
        return outcome
    }
}
