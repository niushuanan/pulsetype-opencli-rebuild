import AppKit
import Foundation

enum AgentCapabilitySettings {
    static let musicControlEnabledKey = "agent.capability.music.enabled.v1"
    static let calendarCreateEventEnabledKey = "agent.capability.calendar.create_event.enabled.v1"
    static let musicControlToolID = "apple.music.control"
    static let calendarCreateEventToolID = "apple.calendar.create_event"

    static func isMusicControlEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: musicControlEnabledKey) != nil else {
            return true
        }
        return defaults.bool(forKey: musicControlEnabledKey)
    }

    static func isCalendarCreateEventEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: calendarCreateEventEnabledKey) != nil else {
            return true
        }
        return defaults.bool(forKey: calendarCreateEventEnabledKey)
    }
}

struct AgentToolManifest: Codable, Equatable, Identifiable {
    let toolID: String
    let displayName: String
    let description: String
    let examples: [String]

    var id: String { toolID }

    enum CodingKeys: String, CodingKey {
        case toolID = "tool_id"
        case displayName = "display_name"
        case description
        case examples
    }
}

@MainActor
protocol AgentToolCatalogProviding {
    func loadEnabledTools() -> [AgentToolManifest]
}

@MainActor
final class AgentToolCatalogStore: AgentToolCatalogProviding {
    private let toolsDirectory: URL
    private let defaults: UserDefaults
    private let fileManager: FileManager

    init(
        toolsDirectory: URL? = nil,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.toolsDirectory = toolsDirectory ?? Self.defaultToolsDirectory(fileManager: fileManager)
        self.defaults = defaults
        self.fileManager = fileManager
    }

    func loadEnabledTools() -> [AgentToolManifest] {
        bootstrapBuiltInToolsIfNeeded()

        var manifestsByID: [String: AgentToolManifest] = [
            Self.musicManifest.toolID: Self.musicManifest,
            Self.calendarCreateEventManifest.toolID: Self.calendarCreateEventManifest
        ]

        let toolDirectories = (try? fileManager.contentsOfDirectory(
            at: toolsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for directory in toolDirectories {
            guard isDirectory(directory) else {
                continue
            }
            let manifestURL = directory.appendingPathComponent("manifest.json", isDirectory: false)
            guard
                let data = try? Data(contentsOf: manifestURL),
                let manifest = try? JSONDecoder().decode(AgentToolManifest.self, from: data),
                !manifest.toolID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                continue
            }
            manifestsByID[manifest.toolID] = manifest
        }

        return manifestsByID.values
            .filter { isEnabled(toolID: $0.toolID) }
            .sorted { $0.toolID < $1.toolID }
    }

    private func bootstrapBuiltInToolsIfNeeded() {
        try? fileManager.createDirectory(at: toolsDirectory, withIntermediateDirectories: true)

        for manifest in Self.builtInManifests {
            let toolDirectory = toolsDirectory.appendingPathComponent(manifest.toolID, isDirectory: true)
            let manifestURL = toolDirectory.appendingPathComponent("manifest.json", isDirectory: false)
            guard !fileManager.fileExists(atPath: manifestURL.path) else {
                continue
            }

            do {
                try fileManager.createDirectory(at: toolDirectory, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(manifest)
                try data.write(to: manifestURL, options: [.atomic])
            } catch {
                // 写入失败不影响运行，内置 manifest 会作为内存兜底继续参与路由。
            }
        }
    }

    private func isEnabled(toolID: String) -> Bool {
        switch toolID {
        case AgentCapabilitySettings.musicControlToolID:
            return AgentCapabilitySettings.isMusicControlEnabled(defaults: defaults)
        case AgentCapabilitySettings.calendarCreateEventToolID:
            return AgentCapabilitySettings.isCalendarCreateEventEnabled(defaults: defaults)
        default:
            return true
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func defaultToolsDirectory(fileManager: FileManager) -> URL {
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return baseDirectory
            .appendingPathComponent("PulseType", isDirectory: true)
            .appendingPathComponent("AgentTools", isDirectory: true)
    }

    private static let musicManifest = AgentToolManifest(
        toolID: AgentCapabilitySettings.musicControlToolID,
        displayName: "音乐控制",
        description: "控制 Apple Music。适合播放指定歌曲、打开音乐、暂停、继续、上一首、下一首，并尽量从用户资料库执行。",
        examples: [
            "播放稻香",
            "暂停音乐",
            "下一首"
        ]
    )

    private static let calendarCreateEventManifest = AgentToolManifest(
        toolID: AgentCapabilitySettings.calendarCreateEventToolID,
        displayName: "日历日程",
        description: "在 Calendar 创建会议、约会、行程等日程。适合“我下周六九点有个会”“明天下午三点安排项目讨论”。",
        examples: [
            "我下周六九点有个会",
            "明天下午三点安排项目讨论",
            "九点有个会，帮我放到日历里"
        ]
    )

    private static let builtInManifests = [
        musicManifest,
        calendarCreateEventManifest
    ]
}

struct AgentRouteRequest: Equatable {
    let traceID: String
    let command: String
    let tools: [AgentToolManifest]
}

struct AgentRouteOutcome: Equatable {
    let traceID: String
    let toolID: String
    let providerName: String
    let modelName: String
    let rawOutput: String
    let latencyMilliseconds: Int

    var evidenceSummary: String {
        [
            "agent.route",
            "trace_id=\(sanitizeAgentEvidenceValue(traceID))",
            "tool_id=\(sanitizeAgentEvidenceValue(toolID))",
            "provider=\(sanitizeAgentEvidenceValue(providerName))",
            "model=\(sanitizeAgentEvidenceValue(modelName))",
            "latency_ms=\(latencyMilliseconds)"
        ].joined(separator: "|")
    }
}

enum AgentRouteError: LocalizedError, Equatable {
    case emptyCommand
    case noCandidateTools
    case invalidModelOutput(String)
    case unknownToolID(String)

    var errorDescription: String? {
        switch self {
        case .emptyCommand:
            return "没有识别到可执行的 Agent 指令。"
        case .noCandidateTools:
            return "当前没有可用 Agent 功能，请先到 Agent 页面打开功能。"
        case let .invalidModelOutput(output):
            let normalized = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.isEmpty {
                return "Agent Router 没有返回可用工具。"
            }
            return "Agent Router 返回格式不正确：\(normalized)"
        case let .unknownToolID(toolID):
            return "Agent Router 选择了当前版本不支持的工具：\(toolID)。"
        }
    }
}

@MainActor
protocol AgentToolRouting {
    func route(
        request: AgentRouteRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> AgentRouteOutcome
}

struct AgentRoutePromptBuilder {
    func build(request: AgentRouteRequest) -> TextGenerationRequest {
        let systemPrompt = """
        你是 PulseType 的 Agent Router。你的唯一任务是把用户语音命令分配给一个工具。

        软约束推理规则：
        1. 先理解用户真实意图，再从候选工具里选最匹配的一项。
        2. 可以做必要推理，但不能编造不存在的工具能力。
        3. “会议、行程、约会、日程安排、提醒我某个时间参加某件事”这类更偏向 calendar。
        4. 如果语义有交叉，优先选择用户最终想要的结果：是“到点响铃提醒”还是“写入日程”。
        5. 只做分流，不做参数提取和执行决策。

        输出规则：
        1. 只能从候选工具的 tool_id 中选择一个。
        2. 只输出一行 JSON，格式必须是 {"tool_id":"候选工具ID"}。
        3. 不要输出解释、Markdown、代码块、自然语言或工具参数。
        4. 不要改写用户命令，不要生成执行步骤。
        5. 如果候选工具不完全匹配，也必须选择最接近的候选工具。
        """

        let toolLines = request.tools.map { tool in
            let examples = tool.examples.isEmpty ? "无" : tool.examples.joined(separator: "；")
            return """
            - tool_id: \(tool.toolID)
              name: \(tool.displayName)
              description: \(tool.description)
              examples: \(examples)
            """
        }.joined(separator: "\n")

        let userPrompt = """
        用户命令：
        <<<COMMAND
        \(request.command)
        COMMAND>>>

        候选工具：
        \(toolLines)
        """

        return TextGenerationRequest(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            temperature: 0,
            maxOutputTokens: 80
        )
    }
}

struct LLMAgentToolRouter: AgentToolRouting {
    private let generationProvider: any TextGenerationProvider
    private let promptBuilder: AgentRoutePromptBuilder

    init(
        generationProvider: any TextGenerationProvider = OpenAITextGenerationProvider(),
        promptBuilder: AgentRoutePromptBuilder = AgentRoutePromptBuilder()
    ) {
        self.generationProvider = generationProvider
        self.promptBuilder = promptBuilder
    }

    func route(
        request: AgentRouteRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> AgentRouteOutcome {
        let normalizedCommand = request.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCommand.isEmpty else {
            throw AgentRouteError.emptyCommand
        }
        guard !request.tools.isEmpty else {
            throw AgentRouteError.noCandidateTools
        }

        let startedAt = Date()
        let generation = try await generationProvider.generateText(
            request: promptBuilder.build(
                request: AgentRouteRequest(
                    traceID: request.traceID,
                    command: normalizedCommand,
                    tools: request.tools
                )
            ),
            configuration: configuration,
            apiKey: apiKey
        )
        let latencyMilliseconds = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
        let toolID = try parseToolID(from: generation.outputText)

        guard request.tools.contains(where: { $0.toolID == toolID }) else {
            throw AgentRouteError.unknownToolID(toolID)
        }

        return AgentRouteOutcome(
            traceID: request.traceID,
            toolID: toolID,
            providerName: generation.providerName,
            modelName: generation.modelName,
            rawOutput: generation.outputText,
            latencyMilliseconds: latencyMilliseconds
        )
    }

    private func parseToolID(from output: String) throws -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentRouteError.invalidModelOutput(output)
        }

        let direct = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        if !direct.contains("{"), !direct.contains(" "), !direct.contains("\n"), direct.contains(".") {
            return direct
        }

        guard
            let startIndex = trimmed.firstIndex(of: "{"),
            let endIndex = trimmed.lastIndex(of: "}"),
            startIndex <= endIndex
        else {
            throw AgentRouteError.invalidModelOutput(output)
        }

        let jsonText = String(trimmed[startIndex...endIndex])
        guard
            let data = jsonText.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawToolID = (object["tool_id"] as? String) ?? (object["toolID"] as? String)
        else {
            throw AgentRouteError.invalidModelOutput(output)
        }

        let toolID = rawToolID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !toolID.isEmpty else {
            throw AgentRouteError.invalidModelOutput(output)
        }
        return toolID
    }
}

private func sanitizeAgentEvidenceValue(_ value: String) -> String {
    value
        .replacingOccurrences(of: "|", with: "/")
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

struct WakeInvocationContext: Equatable {
    enum Source: String, Equatable {
        case dictationTap
        case dictationHold
        case agentHold
    }

    let source: Source

    var lane: InputLane {
        switch source {
        case .agentHold:
            return .agentMusic
        case .dictationTap, .dictationHold:
            return .directDictation
        }
    }

    static let dictation = WakeInvocationContext(source: .dictationTap)
    static let dictationHold = WakeInvocationContext(source: .dictationHold)
    static let agentHold = WakeInvocationContext(source: .agentHold)
}

struct DictationWritebackTarget: Equatable {
    let focusContext: FocusedAppContext
    let processIdentifier: pid_t?

    var snapshot: WritebackTargetSnapshot {
        WritebackTargetSnapshot(
            appName: focusContext.appName,
            bundleID: focusContext.bundleID,
            processIdentifier: processIdentifier
        )
    }
}

struct DictationTextProcessingPolicy {
    static func shouldUseModel(text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct ASRTranscriptionOutcome {
    let result: SpeechTranscriptionResult
    let attempts: Int
}

struct ASRTranscriptionFailure: Error {
    let error: SpeechTranscriptionError
    let attempts: Int
}

enum DictationRoute {
    case asrOnly
    case asrAndTextProcessing
}

struct DictationPostProcessOutcome {
    let route: DictationRoute
    let text: String
    let finalWritebackText: String
    let priorStreamingWriteResult: TextOutputResult?
    let nonBlockingNotice: String?
}

struct DictationStreamingWritebackFinalization {
    let finalWritebackText: String
    let priorStreamingWriteResult: TextOutputResult?
    let note: String?
    let shouldPersistFinalTextToClipboard: Bool
}

struct DictationStreamingWritebackPolicy {
    static func supportsExternalStreaming(
        focusContext: FocusedAppContext,
        preferredTarget: WritebackTargetSnapshot?
    ) -> Bool {
        let bundleID = preferredTarget?.bundleID ?? focusContext.bundleID
        guard
            !bundleID.isEmpty,
            bundleID != "unknown.bundle",
            bundleID != Bundle.main.bundleIdentifier
        else {
            return false
        }

        if blockedBundleIDs.contains(bundleID) {
            return false
        }

        let lowercasedBundleID = bundleID.lowercased()
        let blockedFragments = [
            "com.openai.codex",
            "slack",
            "discord",
            "code",
            "cursor"
        ]
        return !blockedFragments.contains { lowercasedBundleID.contains($0) }
    }

    private static let blockedBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.microsoft.rdc.macos",
        "com.citrix.receiver.icaviewer.mac",
        "com.teamviewer.TeamViewer",
        "com.parallels.desktop.console"
    ]
}

struct StableStreamingPrefixAccumulator {
    private(set) var committedPrefix: String = ""
    private var previousPreview: String?

    private let minimumBoundaryChunkLength = 3
    private let forcedCommitThreshold = 22
    private let forcedCommitTailReserve = 6
    private let boundaryCharacters = CharacterSet(charactersIn: "，。！？；：、,.!?;: \n")

    mutating func ingest(_ previewText: String) -> String? {
        let normalized = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return nil
        }

        defer {
            previousPreview = normalized
        }

        guard let previousPreview, !previousPreview.isEmpty else {
            return nil
        }

        let stablePrefix = longestCommonPrefix(previousPreview, normalized)
        return commitDelta(fromStablePrefix: stablePrefix)
    }

    mutating func finalize(with finalText: String) -> DictationStreamingWritebackFinalization {
        let normalizedFinal = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !committedPrefix.isEmpty else {
            return DictationStreamingWritebackFinalization(
                finalWritebackText: normalizedFinal,
                priorStreamingWriteResult: nil,
                note: nil,
                shouldPersistFinalTextToClipboard: false
            )
        }

        if normalizedFinal.hasPrefix(committedPrefix) {
            let suffix = String(normalizedFinal.dropFirst(committedPrefix.count))
            return DictationStreamingWritebackFinalization(
                finalWritebackText: suffix,
                priorStreamingWriteResult: nil,
                note: nil,
                shouldPersistFinalTextToClipboard: false
            )
        }

        return DictationStreamingWritebackFinalization(
            finalWritebackText: "",
            priorStreamingWriteResult: nil,
            note: "流式阶段已写入前半段，最终全文已放入剪贴板，请以完整结果为准。",
            shouldPersistFinalTextToClipboard: true
        )
    }

    private mutating func commitDelta(fromStablePrefix stablePrefix: String) -> String? {
        guard stablePrefix.count > committedPrefix.count else {
            return nil
        }

        let committedCount = committedPrefix.count
        let commitEndIndex = preferredCommitEnd(in: stablePrefix, committedCount: committedCount)
        let committedIndex = stablePrefix.index(
            stablePrefix.startIndex,
            offsetBy: committedCount,
            limitedBy: stablePrefix.endIndex
        ) ?? stablePrefix.startIndex
        guard commitEndIndex > committedIndex else {
            return nil
        }

        let delta = String(stablePrefix[committedIndex..<commitEndIndex])
        committedPrefix = String(stablePrefix[..<commitEndIndex])
        return delta
    }

    private func preferredCommitEnd(in stablePrefix: String, committedCount: Int) -> String.Index {
        let startIndex = stablePrefix.index(
            stablePrefix.startIndex,
            offsetBy: committedCount,
            limitedBy: stablePrefix.endIndex
        ) ?? stablePrefix.startIndex
        guard startIndex < stablePrefix.endIndex else {
            return startIndex
        }

        var currentIndex = startIndex
        var boundaryIndex: String.Index?
        var advancedCount = 0
        while currentIndex < stablePrefix.endIndex {
            let nextIndex = stablePrefix.index(after: currentIndex)
            advancedCount += 1
            let scalarView = String(stablePrefix[currentIndex]).unicodeScalars
            if scalarView.allSatisfy(boundaryCharacters.contains), advancedCount >= minimumBoundaryChunkLength {
                boundaryIndex = nextIndex
            }
            currentIndex = nextIndex
        }

        if let boundaryIndex {
            return boundaryIndex
        }

        guard advancedCount >= forcedCommitThreshold else {
            return startIndex
        }

        let commitCount = max(minimumBoundaryChunkLength, advancedCount - forcedCommitTailReserve)
        return stablePrefix.index(startIndex, offsetBy: commitCount, limitedBy: stablePrefix.endIndex) ?? startIndex
    }

    private func longestCommonPrefix(_ lhs: String, _ rhs: String) -> String {
        var leftIndex = lhs.startIndex
        var rightIndex = rhs.startIndex
        var prefixEnd = lhs.startIndex

        while leftIndex < lhs.endIndex, rightIndex < rhs.endIndex, lhs[leftIndex] == rhs[rightIndex] {
            prefixEnd = lhs.index(after: leftIndex)
            leftIndex = lhs.index(after: leftIndex)
            rightIndex = rhs.index(after: rightIndex)
        }

        return String(lhs[..<prefixEnd])
    }
}

@MainActor
final class DictationStreamingWritebackController {
    private let textOutputCoordinator: any TextOutputCoordinator
    private let focusContext: FocusedAppContext
    private let preferredTarget: WritebackTargetSnapshot?
    private var accumulator = StableStreamingPrefixAccumulator()
    private var latestWriteResult: TextOutputResult?
    private var didDisableStreaming = false

    init(
        textOutputCoordinator: any TextOutputCoordinator,
        focusContext: FocusedAppContext,
        preferredTarget: WritebackTargetSnapshot?
    ) {
        self.textOutputCoordinator = textOutputCoordinator
        self.focusContext = focusContext
        self.preferredTarget = preferredTarget
    }

    func handlePartialText(_ previewText: String) async {
        guard !didDisableStreaming else {
            return
        }
        guard
            DictationStreamingWritebackPolicy.supportsExternalStreaming(
                focusContext: focusContext,
                preferredTarget: preferredTarget
            )
        else {
            return
        }
        guard let delta = accumulator.ingest(previewText), !delta.isEmpty else {
            return
        }

        let request = TextOutputRequest(
            text: delta,
            operation: .insertText,
            focusContext: focusContext,
            preferredTarget: preferredTarget,
            writeMode: .streamingChunk
        )
        do {
            latestWriteResult = try await textOutputCoordinator.write(request: request)
        } catch {
            didDisableStreaming = true
        }
    }

    func finalize(with finalText: String) -> DictationStreamingWritebackFinalization {
        let finalization = accumulator.finalize(with: finalText)
        let priorResult = latestWriteResult
        if finalization.finalWritebackText.isEmpty, let priorResult {
            return DictationStreamingWritebackFinalization(
                finalWritebackText: "",
                priorStreamingWriteResult: priorResult,
                note: finalization.note,
                shouldPersistFinalTextToClipboard: finalization.shouldPersistFinalTextToClipboard
            )
        }
        return finalization
    }
}

struct AgentMusicExecutionRequest {
    let traceID: String
    let command: String
}

struct AgentMusicExecutionOutcome {
    let status: SessionHistoryStatus
    let message: String
    let outputText: String?
    let evidenceSummary: String
}

@MainActor
protocol AgentMusicControlling {
    func execute(_ request: AgentMusicExecutionRequest) async -> AgentMusicExecutionOutcome
}

@MainActor
final class AgentMusicControlExecutor: AgentMusicControlling {
    private enum Action: String {
        case open
        case play
        case pause
        case resume
        case next
        case previous
    }

    private struct ParsedCommand {
        let action: Action
        let query: String?
    }

    func execute(_ request: AgentMusicExecutionRequest) async -> AgentMusicExecutionOutcome {
        guard isMusicAppAvailable else {
            return AgentMusicExecutionOutcome(
                status: .failed,
                message: "Music 不可用，请先打开 Music 应用。",
                outputText: nil,
                evidenceSummary: "apple.music.control|fast_path=true|trace_id=\(request.traceID)|error=music_app_unavailable"
            )
        }
        guard await ensureMusicAppRunning() else {
            return AgentMusicExecutionOutcome(
                status: .failed,
                message: "Music 启动失败，请手动打开后重试。",
                outputText: nil,
                evidenceSummary: "apple.music.control|fast_path=true|trace_id=\(request.traceID)|error=music_app_launch_failed"
            )
        }

        let parsed = parseCommand(from: request.command)
        let scriptResult: OsaScriptResult = await {
            switch parsed.action {
            case .open:
                return await runOpenMusic()
            case .pause:
                return await runPause()
            case .resume:
                return await runResume()
            case .next:
                return await runNext()
            case .previous:
                return await runPrevious()
            case .play:
                return await runPlay(query: parsed.query)
            }
        }()

        let baseEvidence = composeEvidence(
            traceID: request.traceID,
            action: parsed.action,
            rawEvidence: scriptResult.stdout,
            query: parsed.query
        )

        guard scriptResult.exitCode == 0 else {
            let stderr = scriptResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let stderrField: String
            if stderr.isEmpty {
                stderrField = ""
            } else {
                stderrField = "|osascript_stderr=\(sanitizeEvidenceValue(stderr))"
            }
            return AgentMusicExecutionOutcome(
                status: .failed,
                message: "Music 执行失败，请确认应用可用后重试。",
                outputText: nil,
                evidenceSummary: baseEvidence + "|error=osascript_failed" + stderrField
            )
        }

        if scriptResult.stdout.contains("track_not_found") {
            return AgentMusicExecutionOutcome(
                status: .failed,
                message: "没找到匹配歌曲，请补充更明确的歌名或歌手。",
                outputText: nil,
                evidenceSummary: baseEvidence + "|verification=track_not_found"
            )
        }

        let playbackState = evidenceField("state", in: scriptResult.stdout) ?? ""
        let track = evidenceField("track", in: scriptResult.stdout)
        let artist = evidenceField("artist", in: scriptResult.stdout)
        let exactMatch = matchesRequestedTrack(query: parsed.query, evidence: scriptResult.stdout)
        let confidence = (parsed.action == .play && (parsed.query?.isEmpty == false))
            ? (exactMatch ? "high" : "low")
            : "medium"
        let enrichedEvidence = baseEvidence
            + "|playback_state=\(sanitizeEvidenceValue(playbackState))"
            + "|exact_match=\(exactMatch ? "true" : "false")"
            + "|evidence_confidence=\(confidence)"

        if parsed.action == .play, !isPlaybackActive(playbackState) {
            return AgentMusicExecutionOutcome(
                status: .failed,
                message: "已执行播放指令，但当前没有进入播放状态，请重试。",
                outputText: nil,
                evidenceSummary: enrichedEvidence + "|verification=playback_inactive"
            )
        }

        if parsed.action != .play, playbackState.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AgentMusicExecutionOutcome(
                status: .failed,
                message: "Music 状态读取失败，请重试。",
                outputText: nil,
                evidenceSummary: enrichedEvidence + "|verification=state_missing"
            )
        }

        let outputText = composeOutputText(
            action: parsed.action,
            track: track,
            artist: artist,
            exactMatch: exactMatch
        )
        return AgentMusicExecutionOutcome(
            status: .success,
            message: outputText,
            outputText: outputText,
            evidenceSummary: enrichedEvidence
        )
    }

    private var isMusicAppAvailable: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") != nil
            || FileManager.default.fileExists(atPath: "/System/Applications/Music.app")
    }

    private var isMusicAppRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    }

    private func ensureMusicAppRunning() async -> Bool {
        if isMusicAppRunning {
            return true
        }

        let knownAppURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music")
            ?? URL(fileURLWithPath: "/System/Applications/Music.app")
        guard FileManager.default.fileExists(atPath: knownAppURL.path) else {
            return false
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        let launched = await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: knownAppURL, configuration: config) { app, error in
                continuation.resume(returning: app != nil && error == nil)
            }
        }

        guard launched else {
            return false
        }

        for _ in 0..<12 {
            if isMusicAppRunning {
                return true
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return isMusicAppRunning
    }

    private func parseCommand(from rawCommand: String) -> ParsedCommand {
        let trimmed = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()

        if lowered.contains("暂停") || lowered.contains("pause") {
            return ParsedCommand(action: .pause, query: nil)
        }
        if lowered.contains("继续") || lowered.contains("恢复") || lowered.contains("resume") {
            return ParsedCommand(action: .resume, query: nil)
        }
        if lowered.contains("下一首") || lowered.contains("下首") || lowered.contains("next") {
            return ParsedCommand(action: .next, query: nil)
        }
        if lowered.contains("上一首") || lowered.contains("上首") || lowered.contains("previous") {
            return ParsedCommand(action: .previous, query: nil)
        }
        if lowered.contains("打开音乐") || lowered.contains("open music") {
            return ParsedCommand(action: .open, query: nil)
        }
        if lowered.contains("播放") || lowered.contains("来一首") || lowered.contains("放首") || lowered.contains("play") {
            let query = extractPlayQuery(from: trimmed)
            return ParsedCommand(action: .play, query: query)
        }
        return ParsedCommand(action: .play, query: trimmed.isEmpty ? nil : trimmed)
    }

    private func extractPlayQuery(from command: String) -> String? {
        let prefixes = [
            "播放一下", "播放一首", "播放首", "播放", "来一首", "放首", "放一首", "放"
        ]

        var candidate = command
        for prefix in prefixes {
            if candidate.hasPrefix(prefix) {
                candidate.removeFirst(prefix.count)
                break
            }
        }

        let cleaned = candidate
            .replacingOccurrences(of: "《", with: "")
            .replacingOccurrences(of: "》", with: "")
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "？", with: "")
            .replacingOccurrences(of: "！", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? nil : cleaned
    }

    private func runOpenMusic() async -> OsaScriptResult {
        await runAppleScript(
            lines: [
                "tell application \"Music\"",
                "activate",
                "return \"state=open\"",
                "end tell"
            ]
        )
    }

    private func runPlay(query: String?) async -> OsaScriptResult {
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return await runAppleScript(
                lines: [
                    "on run argv",
                    "set requestedQuery to item 1 of argv",
                    "tell application \"Music\"",
                    "activate",
                    "try",
                    "set fixed indexing to true",
                    "end try",
                    "try",
                    "set shuffle enabled to false",
                    "end try",
                    "try",
                    "set song repeat to off",
                    "end try",
                    "set libraryPlaylist to library playlist 1",
                    "set allTracks to tracks of libraryPlaylist",
                    "set totalCount to count of allTracks",
                    "set targetTrack to missing value",
                    "set targetIndex to 0",
                    "repeat with idx from 1 to totalCount",
                    "set t to item idx of allTracks",
                    "try",
                    "if (((name of t) as string) contains requestedQuery) or (((artist of t) as string) contains requestedQuery) or (((album of t) as string) contains requestedQuery) then",
                    "set targetTrack to t",
                    "set targetIndex to idx",
                    "exit repeat",
                    "end if",
                    "on error",
                    "end try",
                    "end repeat",
                    "if targetTrack is missing value then",
                    "return \"track_not_found|requested_track=\" & requestedQuery",
                    "end if",
                    "set targetID to (persistent ID of targetTrack) as string",
                    "set targetName to (name of targetTrack) as string",
                    "set targetArtist to (artist of targetTrack) as string",
                    "set targetAlbum to (album of targetTrack) as string",
                    "set finalState to \"unknown\"",
                    "set lastNowName to \"\"",
                    "set lastNowArtist to \"\"",
                    "set lastNowAlbum to \"\"",
                    "set lastNowID to \"\"",
                    "set matchedTargetButInactive to false",
                    "play targetTrack",
                    "repeat with attemptIndex from 1 to 8",
                    "delay 0.18",
                    "set finalState to (player state as string)",
                    "try",
                    "set nowTrack to current track",
                    "set lastNowName to (name of nowTrack) as string",
                    "set lastNowArtist to (artist of nowTrack) as string",
                    "set lastNowAlbum to (album of nowTrack) as string",
                    "set lastNowID to (persistent ID of nowTrack) as string",
                    "if lastNowID is targetID then",
                    "if finalState is \"playing\" or finalState is \"play\" then",
                    "return \"requested_track=\" & requestedQuery & \"|selection_source=library\" & \"|queue_anchor=library_order\" & \"|queue_mode=library_direct\" & \"|shuffle=false\" & \"|track=\" & lastNowName & \"|artist=\" & lastNowArtist & \"|album=\" & lastNowAlbum & \"|state=\" & finalState",
                    "else",
                    "set matchedTargetButInactive to true",
                    "end if",
                    "end if",
                    "end try",
                    "if attemptIndex is 4 then",
                    "try",
                    "play targetTrack",
                    "end try",
                    "end if",
                    "end repeat",
                    "if lastNowName is not \"\" then",
                    "if matchedTargetButInactive then",
                    "return \"requested_track=\" & requestedQuery & \"|selection_source=library\" & \"|queue_anchor=library_order\" & \"|queue_mode=library_direct\" & \"|shuffle=false\" & \"|track=\" & lastNowName & \"|artist=\" & lastNowArtist & \"|album=\" & lastNowAlbum & \"|state=\" & finalState & \"|target_matched_but_inactive=true\"",
                    "end if",
                    "return \"requested_track=\" & requestedQuery & \"|selection_source=library\" & \"|queue_anchor=library_order\" & \"|queue_mode=library_direct\" & \"|shuffle=false\" & \"|track=\" & lastNowName & \"|artist=\" & lastNowArtist & \"|album=\" & lastNowAlbum & \"|state=\" & finalState & \"|play_mismatch=true|target_track=\" & targetName & \"|target_artist=\" & targetArtist & \"|target_album=\" & targetAlbum",
                    "end if",
                    "return \"play_mismatch|requested_track=\" & requestedQuery & \"|target_track=\" & targetName & \"|target_artist=\" & targetArtist & \"|target_album=\" & targetAlbum & \"|state=\" & finalState",
                    "end tell",
                    "end run"
                ],
                arguments: [query]
            )
        }

        return await runAppleScript(
            lines: [
                "tell application \"Music\"",
                "activate",
                "set shuffle enabled to false",
                "play",
                "set finalState to (player state as string)",
                "set nowTrack to missing value",
                "try",
                "set nowTrack to current track",
                "end try",
                "if nowTrack is missing value then",
                "return \"selection_source=current_context|shuffle=false|state=\" & finalState",
                "end if",
                "return \"selection_source=current_context|shuffle=false|track=\" & (name of nowTrack as string) & \"|artist=\" & (artist of nowTrack as string) & \"|state=\" & finalState",
                "end tell"
            ]
        )
    }

    private func runPause() async -> OsaScriptResult {
        await runAppleScript(
            lines: [
                "tell application \"Music\"",
                "activate",
                "pause",
                "set finalState to (player state as string)",
                "return \"state=\" & finalState",
                "end tell"
            ]
        )
    }

    private func runResume() async -> OsaScriptResult {
        await runAppleScript(
            lines: [
                "tell application \"Music\"",
                "activate",
                "play",
                "set finalState to (player state as string)",
                "set nowTrack to missing value",
                "try",
                "set nowTrack to current track",
                "end try",
                "if nowTrack is missing value then",
                "return \"state=\" & finalState",
                "end if",
                "return \"track=\" & (name of nowTrack as string) & \"|artist=\" & (artist of nowTrack as string) & \"|state=\" & finalState",
                "end tell"
            ]
        )
    }

    private func runNext() async -> OsaScriptResult {
        await runAppleScript(
            lines: [
                "tell application \"Music\"",
                "activate",
                "try",
                "set fixed indexing to true",
                "end try",
                "try",
                "set shuffle enabled to false",
                "end try",
                "try",
                "set song repeat to off",
                "end try",
                "set libraryPlaylist to library playlist 1",
                "set allTracks to tracks of libraryPlaylist",
                "set totalCount to count of allTracks",
                "if totalCount is 0 then",
                "return \"library_empty|step=next\"",
                "end if",
                "set nowTrack to missing value",
                "try",
                "set nowTrack to current track",
                "end try",
                "set sourceID to \"\"",
                "set targetIndex to 1",
                "if nowTrack is not missing value then",
                "set sourceID to (persistent ID of nowTrack) as string",
                "set currentIndex to 0",
                "repeat with idx from 1 to totalCount",
                "try",
                "if ((persistent ID of (item idx of allTracks)) as string) is sourceID then",
                "set currentIndex to idx",
                "exit repeat",
                "end if",
                "end try",
                "end repeat",
                "if currentIndex is not 0 then",
                "set targetIndex to currentIndex + 1",
                "if targetIndex > totalCount then set targetIndex to 1",
                "end if",
                "end if",
                "set targetTrack to item targetIndex of allTracks",
                "play targetTrack",
                "delay 0.18",
                "set finalState to (player state as string)",
                "set currentNow to current track",
                "return \"selection_source=library|queue_anchor=library_order|step=next|track=\" & (name of currentNow as string) & \"|artist=\" & (artist of currentNow as string) & \"|album=\" & (album of currentNow as string) & \"|state=\" & finalState",
                "end tell"
            ]
        )
    }

    private func runPrevious() async -> OsaScriptResult {
        await runAppleScript(
            lines: [
                "tell application \"Music\"",
                "activate",
                "try",
                "set fixed indexing to true",
                "end try",
                "try",
                "set shuffle enabled to false",
                "end try",
                "try",
                "set song repeat to off",
                "end try",
                "set libraryPlaylist to library playlist 1",
                "set allTracks to tracks of libraryPlaylist",
                "set totalCount to count of allTracks",
                "if totalCount is 0 then",
                "return \"library_empty|step=previous\"",
                "end if",
                "set nowTrack to missing value",
                "try",
                "set nowTrack to current track",
                "end try",
                "set sourceID to \"\"",
                "set targetIndex to totalCount",
                "if nowTrack is not missing value then",
                "set sourceID to (persistent ID of nowTrack) as string",
                "set currentIndex to 0",
                "repeat with idx from 1 to totalCount",
                "try",
                "if ((persistent ID of (item idx of allTracks)) as string) is sourceID then",
                "set currentIndex to idx",
                "exit repeat",
                "end if",
                "end try",
                "end repeat",
                "if currentIndex is not 0 then",
                "set targetIndex to currentIndex - 1",
                "if targetIndex < 1 then set targetIndex to totalCount",
                "end if",
                "end if",
                "set targetTrack to item targetIndex of allTracks",
                "play targetTrack",
                "delay 0.18",
                "set finalState to (player state as string)",
                "set currentNow to current track",
                "return \"selection_source=library|queue_anchor=library_order|step=previous|track=\" & (name of currentNow as string) & \"|artist=\" & (artist of currentNow as string) & \"|album=\" & (album of currentNow as string) & \"|state=\" & finalState",
                "end tell"
            ]
        )
    }

    private func composeOutputText(
        action: Action,
        track: String?,
        artist: String?,
        exactMatch: Bool
    ) -> String {
        switch action {
        case .open:
            return "已打开 Music。"
        case .pause:
            return "已暂停播放。"
        case .resume:
            if let track = normalizedNonEmpty(track), let artist = normalizedNonEmpty(artist) {
                return "已继续播放：\(artist) - \(track)。"
            }
            return "已继续播放。"
        case .next:
            if let track = normalizedNonEmpty(track), let artist = normalizedNonEmpty(artist) {
                return "已切到下一首：\(artist) - \(track)。"
            }
            return "已切到下一首。"
        case .previous:
            if let track = normalizedNonEmpty(track), let artist = normalizedNonEmpty(artist) {
                return "已切到上一首：\(artist) - \(track)。"
            }
            return "已切到上一首。"
        case .play:
            if let track = normalizedNonEmpty(track), let artist = normalizedNonEmpty(artist) {
                if exactMatch {
                    return "已开始播放：\(artist) - \(track)。"
                }
                return "已开始播放：\(artist) - \(track)。请确认是否符合你的指令。"
            }
            return "已执行播放。"
        }
    }

    private func composeEvidence(
        traceID: String,
        action: Action,
        rawEvidence: String,
        query: String?
    ) -> String {
        let trimmed = rawEvidence.trimmingCharacters(in: .whitespacesAndNewlines)
        var fields = [
            "apple.music.control",
            "fast_path=true",
            "trace_id=\(traceID)",
            "action=\(action.rawValue)"
        ]
        if
            let query = normalizedNonEmpty(query),
            !trimmed.contains("requested_track=")
        {
            fields.append("requested_track=\(sanitizeEvidenceValue(query))")
        }
        if !trimmed.isEmpty {
            fields.append(trimmed)
        }
        return fields.joined(separator: "|")
    }

    private func matchesRequestedTrack(query: String?, evidence: String) -> Bool {
        guard let query = normalizedNonEmpty(query) else {
            return true
        }
        let normalizedQuery = normalizedMatchText(query)
        guard !normalizedQuery.isEmpty else {
            return true
        }

        let normalizedPayload = normalizedMatchText([
            evidenceField("track", in: evidence),
            evidenceField("artist", in: evidence),
            evidenceField("album", in: evidence)
        ]
        .compactMap { $0 }
        .joined(separator: " "))

        if normalizedPayload.contains(normalizedQuery) {
            return true
        }

        let tokenized = query
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .map(normalizedMatchText)
            .filter { !$0.isEmpty }
        guard !tokenized.isEmpty else {
            return false
        }
        return tokenized.allSatisfy { normalizedPayload.contains($0) }
    }

    private func isPlaybackActive(_ state: String?) -> Bool {
        guard let state else {
            return false
        }
        let normalized = state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "play" || normalized == "playing"
    }

    private func evidenceField(_ key: String, in evidence: String) -> String? {
        for part in evidence.split(separator: "|") {
            let segment = String(part)
            guard segment.hasPrefix("\(key)=") else {
                continue
            }
            return String(segment.dropFirst(key.count + 1))
        }
        return nil
    }

    private func normalizedNonEmpty(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func sanitizeEvidenceValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "|", with: "/")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedMatchText(_ value: String) -> String {
        value
            .lowercased()
            .filter { character in
                character.isLetter || character.isNumber
            }
    }
}

private struct OsaScriptResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

private func runAppleScript(
    lines: [String],
    arguments: [String] = []
) async -> OsaScriptResult {
    await Task.detached(priority: .userInitiated) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = lines.flatMap { ["-e", $0] } + arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: stdoutData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return OsaScriptResult(
                exitCode: process.terminationStatus,
                stdout: stdout,
                stderr: stderr
            )
        } catch {
            return OsaScriptResult(
                exitCode: 1,
                stdout: "",
                stderr: error.localizedDescription
            )
        }
    }.value
}
