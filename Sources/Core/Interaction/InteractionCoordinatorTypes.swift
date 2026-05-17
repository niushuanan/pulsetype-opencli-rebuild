import AppKit
import Foundation

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
            return AgentMusicExecutionOutcome(
                status: .failed,
                message: "Music 执行失败，请确认应用可用后重试。",
                outputText: nil,
                evidenceSummary: baseEvidence + "|error=osascript_failed"
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
                    "set shuffle enabled to false",
                    "set libraryPlaylist to library playlist 1",
                    "set matchedTrack to missing value",
                    "try",
                    "set matchedTracks to (every track of libraryPlaylist whose (name contains requestedQuery) or (artist contains requestedQuery) or (album contains requestedQuery))",
                    "if (count of matchedTracks) > 0 then",
                    "set matchedTrack to item 1 of matchedTracks",
                    "end if",
                    "on error",
                    "set matchedTrack to missing value",
                    "end try",
                    "if matchedTrack is missing value then",
                    "return \"track_not_found|requested_track=\" & requestedQuery",
                    "end if",
                    "set matchedPersistentID to persistent ID of matchedTrack",
                    "play libraryPlaylist",
                    "delay 0.08",
                    "set queueTrack to first track of libraryPlaylist whose persistent ID is matchedPersistentID",
                    "play queueTrack",
                    "delay 0.12",
                    "set finalState to (player state as string)",
                    "set nowTrack to current track",
                    "return \"requested_track=\" & requestedQuery & \"|selection_source=library\" & \"|queue_anchor=library_order\" & \"|shuffle=false\" & \"|track=\" & (name of nowTrack as string) & \"|artist=\" & (artist of nowTrack as string) & \"|state=\" & finalState",
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
                "next track",
                "delay 0.10",
                "set finalState to (player state as string)",
                "set nowTrack to current track",
                "return \"track=\" & (name of nowTrack as string) & \"|artist=\" & (artist of nowTrack as string) & \"|state=\" & finalState",
                "end tell"
            ]
        )
    }

    private func runPrevious() async -> OsaScriptResult {
        await runAppleScript(
            lines: [
                "tell application \"Music\"",
                "activate",
                "previous track",
                "delay 0.10",
                "set finalState to (player state as string)",
                "set nowTrack to current track",
                "return \"track=\" & (name of nowTrack as string) & \"|artist=\" & (artist of nowTrack as string) & \"|state=\" & finalState",
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
        var fields = [
            "apple.music.control",
            "fast_path=true",
            "trace_id=\(traceID)",
            "action=\(action.rawValue)"
        ]
        if let query = normalizedNonEmpty(query) {
            fields.append("requested_track=\(sanitizeEvidenceValue(query))")
        }
        let trimmed = rawEvidence.trimmingCharacters(in: .whitespacesAndNewlines)
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
            evidenceField("requested_track", in: evidence),
            evidence
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
