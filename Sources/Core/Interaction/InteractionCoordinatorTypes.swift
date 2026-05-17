import Foundation

struct WakeInvocationContext: Equatable {
    static let dictation = WakeInvocationContext()
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
