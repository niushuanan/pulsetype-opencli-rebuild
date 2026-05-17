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

        XCTAssertEqual(ProviderType.allCases, [.openAI, .openAICompatible, .dashScopeQwenASR])
        XCTAssertEqual(store.asrConfig.providerType, .dashScopeQwenASR)
        XCTAssertEqual(store.asrConfig.modelName, "qwen3-asr-flash")
        XCTAssertEqual(store.textConfig.providerType, .openAICompatible)
        XCTAssertEqual(store.textConfig.baseURLString, "https://api.deepseek.com")
        XCTAssertEqual(store.textConfig.modelName, "deepseek-v4-flash")
        XCTAssertFalse(ProviderType.dashScopeQwenASR.supportsTextProcessing)
    }

    func testHistoryStoreKeepsOnlyOrdinaryDictationRowsFromOldFiles() throws {
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

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.inputText, "asr raw")
        XCTAssertEqual(store.entries.first?.outputText, "final text")
        XCTAssertEqual(store.lifetimeSnapshot.totalInputCharacters, "final text".count)
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
            appScenePolicyStore: AppScenePolicyStore(defaults: makeDefaults()),
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
