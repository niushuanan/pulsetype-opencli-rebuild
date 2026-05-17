import Foundation

enum SessionHistoryMode: String, Codable, Equatable {
    case dictation
    case agent
}

enum SessionHistoryStatus: String, Codable, Equatable {
    case success
    case failed
    case cancelled
}

enum LocalHistoryFilter: String, CaseIterable, Identifiable {
    case all
    case dictation
    case agent
    case failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "全部"
        case .dictation:
            return "普通听写"
        case .agent:
            return "Agent 调用"
        case .failed:
            return "失败"
        }
    }
}

struct SessionHistoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let mode: SessionHistoryMode
    let appName: String
    let bundleID: String
    let inputText: String
    let outputText: String?
    let transcriptionProvider: String?
    let transcriptionModel: String?
    let textProcessingProvider: String?
    let textProcessingModel: String?
    let agentEvidenceSummary: String?
    let outputPath: TextOutputPath?
    let status: SessionHistoryStatus
    let errorMessage: String?
    let audioDurationSeconds: Double?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        mode: SessionHistoryMode = .dictation,
        appName: String,
        bundleID: String,
        inputText: String,
        outputText: String?,
        transcriptionProvider: String? = nil,
        transcriptionModel: String? = nil,
        textProcessingProvider: String? = nil,
        textProcessingModel: String? = nil,
        agentEvidenceSummary: String? = nil,
        outputPath: TextOutputPath? = nil,
        status: SessionHistoryStatus,
        errorMessage: String? = nil,
        audioDurationSeconds: Double? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.mode = mode
        self.appName = appName
        self.bundleID = bundleID
        self.inputText = inputText
        self.outputText = outputText
        self.transcriptionProvider = transcriptionProvider
        self.transcriptionModel = transcriptionModel
        self.textProcessingProvider = textProcessingProvider
        self.textProcessingModel = textProcessingModel
        self.agentEvidenceSummary = agentEvidenceSummary
        self.outputPath = outputPath
        self.status = status
        self.errorMessage = errorMessage
        self.audioDurationSeconds = audioDurationSeconds
    }

    enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case mode
        case appName
        case bundleID
        case inputText
        case outputText
        case transcriptionProvider
        case transcriptionModel
        case textProcessingProvider
        case textProcessingModel
        case agentEvidenceSummary
        case outputPath
        case status
        case errorMessage
        case audioDurationSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        mode = try container.decodeIfPresent(SessionHistoryMode.self, forKey: .mode) ?? .dictation
        appName = try container.decodeIfPresent(String.self, forKey: .appName) ?? "未知应用"
        bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID) ?? "unknown.bundle"
        inputText = try container.decodeIfPresent(String.self, forKey: .inputText) ?? ""
        outputText = try container.decodeIfPresent(String.self, forKey: .outputText)
        transcriptionProvider = try container.decodeIfPresent(String.self, forKey: .transcriptionProvider)
        transcriptionModel = try container.decodeIfPresent(String.self, forKey: .transcriptionModel)
        textProcessingProvider = try container.decodeIfPresent(String.self, forKey: .textProcessingProvider)
        textProcessingModel = try container.decodeIfPresent(String.self, forKey: .textProcessingModel)
        agentEvidenceSummary = try container.decodeIfPresent(String.self, forKey: .agentEvidenceSummary)
        outputPath = try container.decodeIfPresent(TextOutputPath.self, forKey: .outputPath)
        status = try container.decodeIfPresent(SessionHistoryStatus.self, forKey: .status) ?? .success
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        audioDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .audioDurationSeconds)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(mode, forKey: .mode)
        try container.encode(appName, forKey: .appName)
        try container.encode(bundleID, forKey: .bundleID)
        try container.encode(inputText, forKey: .inputText)
        try container.encodeIfPresent(outputText, forKey: .outputText)
        try container.encodeIfPresent(transcriptionProvider, forKey: .transcriptionProvider)
        try container.encodeIfPresent(transcriptionModel, forKey: .transcriptionModel)
        try container.encodeIfPresent(textProcessingProvider, forKey: .textProcessingProvider)
        try container.encodeIfPresent(textProcessingModel, forKey: .textProcessingModel)
        try container.encodeIfPresent(agentEvidenceSummary, forKey: .agentEvidenceSummary)
        try container.encodeIfPresent(outputPath, forKey: .outputPath)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try container.encodeIfPresent(audioDurationSeconds, forKey: .audioDurationSeconds)
    }
}

struct HistoryLifetimeSnapshot: Codable, Equatable {
    let totalDialogueDurationSeconds: Double
    let totalInputCharacters: Int
    let averageCharactersPerMinute: Double
    let savedTypingSeconds: Double
    let speedSampleCount: Int

    init(
        totalDialogueDurationSeconds: Double,
        totalInputCharacters: Int,
        averageCharactersPerMinute: Double,
        savedTypingSeconds: Double,
        speedSampleCount: Int = 0
    ) {
        self.totalDialogueDurationSeconds = totalDialogueDurationSeconds
        self.totalInputCharacters = totalInputCharacters
        self.averageCharactersPerMinute = averageCharactersPerMinute
        self.savedTypingSeconds = savedTypingSeconds
        self.speedSampleCount = speedSampleCount
    }

    static let zero = HistoryLifetimeSnapshot(
        totalDialogueDurationSeconds: 0,
        totalInputCharacters: 0,
        averageCharactersPerMinute: 0,
        savedTypingSeconds: 0
    )
}

@MainActor
final class LocalHistoryStore: ObservableObject {
    static let manualTypingCharactersPerMinute: Double = 80

    @Published private(set) var entries: [SessionHistoryEntry] = []
    @Published private(set) var lifetimeSnapshot: HistoryLifetimeSnapshot = .zero

    private let entriesFileURL: URL
    private let legacyEntriesFileURL: URL
    private let lifetimeFileURL: URL
    private let fileManager: FileManager
    private let jsonDecoder: JSONDecoder
    private let jsonEncoder: JSONEncoder
    private let maxEntries: Int

    init(
        historyDirectory: URL,
        fileManager: FileManager = .default,
        maxEntries: Int = 300
    ) {
        self.fileManager = fileManager
        self.maxEntries = max(20, maxEntries)
        self.entriesFileURL = historyDirectory.appendingPathComponent("session-history-v2.json", isDirectory: false)
        self.legacyEntriesFileURL = historyDirectory.appendingPathComponent("session-history-v1.json", isDirectory: false)
        self.lifetimeFileURL = historyDirectory.appendingPathComponent("lifetime-stats-v1.json", isDirectory: false)
        self.jsonDecoder = JSONDecoder()
        self.jsonDecoder.dateDecodingStrategy = .iso8601
        self.jsonEncoder = JSONEncoder()
        self.jsonEncoder.dateEncodingStrategy = .iso8601
        self.jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        try? fileManager.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        load()
    }

    func append(_ entry: SessionHistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        persistEntries()
        recalculateAndPersistLifetime()
    }

    func entries(matching filter: LocalHistoryFilter) -> [SessionHistoryEntry] {
        switch filter {
        case .all:
            return entries
        case .dictation:
            return entries.filter { $0.mode == .dictation }
        case .agent:
            return entries.filter { $0.mode == .agent }
        case .failed:
            return entries.filter { $0.status == .failed }
        }
    }

    func delete(entryID: UUID) {
        entries.removeAll { $0.id == entryID }
        persistEntries()
        recalculateAndPersistLifetime()
    }

    func clearAll() {
        entries = []
        lifetimeSnapshot = .zero
        persistEntries()
        persistLifetime()
    }

    func lifetimeStatistics() -> HistoryLifetimeSnapshot {
        lifetimeSnapshot
    }

    private func load() {
        let loadedEntries = loadEntries(from: entriesFileURL) ?? loadEntries(from: legacyEntriesFileURL) ?? []
        entries = loadedEntries.sorted { $0.timestamp > $1.timestamp }
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }

        if fileManager.fileExists(atPath: legacyEntriesFileURL.path) {
            try? fileManager.removeItem(at: legacyEntriesFileURL)
            persistEntries()
        }

        recalculateAndPersistLifetime()
    }

    private func loadEntries(from url: URL) -> [SessionHistoryEntry]? {
        guard
            fileManager.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url)
        else {
            return nil
        }

        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array.compactMap { raw in
                if let mode = raw["mode"] as? String {
                    let normalized = mode.trimmingCharacters(in: .whitespacesAndNewlines)
                    if normalized != SessionHistoryMode.dictation.rawValue,
                       normalized != SessionHistoryMode.agent.rawValue
                    {
                        return nil
                    }
                }
                guard let itemData = try? JSONSerialization.data(withJSONObject: raw) else {
                    return nil
                }
                return try? jsonDecoder.decode(SessionHistoryEntry.self, from: itemData)
            }
        }

        return try? jsonDecoder.decode([SessionHistoryEntry].self, from: data)
    }

    private func persistEntries() {
        guard let data = try? jsonEncoder.encode(entries) else {
            return
        }
        try? data.write(to: entriesFileURL, options: .atomic)
    }

    private func recalculateAndPersistLifetime() {
        var totalDuration: Double = 0
        var totalCharacters = 0
        var timedCharacters = 0
        var speedSamples = 0

        for entry in entries where entry.status == .success && entry.mode == .dictation {
            let text = (entry.outputText ?? entry.inputText).trimmingCharacters(in: .whitespacesAndNewlines)
            totalCharacters += text.count
            if let duration = entry.audioDurationSeconds, duration > 0 {
                totalDuration += duration
                timedCharacters += text.count
                speedSamples += 1
            }
        }

        let averageCharactersPerMinute = totalDuration > 0 ? Double(timedCharacters) / (totalDuration / 60.0) : 0
        let manualTypingSeconds = Double(timedCharacters) / Self.manualTypingCharactersPerMinute * 60.0
        let savedTypingSeconds = max(0, manualTypingSeconds - totalDuration)
        lifetimeSnapshot = HistoryLifetimeSnapshot(
            totalDialogueDurationSeconds: totalDuration,
            totalInputCharacters: totalCharacters,
            averageCharactersPerMinute: averageCharactersPerMinute,
            savedTypingSeconds: savedTypingSeconds,
            speedSampleCount: speedSamples
        )
        persistLifetime()
    }

    private func persistLifetime() {
        guard let data = try? jsonEncoder.encode(lifetimeSnapshot) else {
            return
        }
        try? data.write(to: lifetimeFileURL, options: .atomic)
    }
}
