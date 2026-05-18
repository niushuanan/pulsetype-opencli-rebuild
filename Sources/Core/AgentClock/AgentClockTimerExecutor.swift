import Foundation
import UserNotifications

struct AgentClockParameterExtractionRequest: Equatable {
    let command: String
    let referenceDate: Date
    let timeZone: TimeZone
}

struct AgentClockTimerParameters: Equatable {
    let title: String
    let fireAtISO8601: String
    let notes: String
}

enum AgentClockError: LocalizedError, Equatable {
    case emptyCommand
    case modelReturnedInvalidJSON(String)
    case invalidFireTime(String)
    case scheduleFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyCommand:
            return "没有识别到可设置闹钟的指令。"
        case let .modelReturnedInvalidJSON(output):
            let normalized = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? "闹钟工具没有返回可用参数。" : "闹钟工具返回格式不正确：\(normalized)"
        case let .invalidFireTime(value):
            return "闹钟时间格式不正确：\(value)。"
        case let .scheduleFailed(reason):
            return "闹钟创建失败：\(reason)"
        }
    }
}

protocol AgentClockParameterExtracting: Sendable {
    func extract(
        request: AgentClockParameterExtractionRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> AgentClockTimerParameters
}

struct LLMAgentClockParameterExtractor: AgentClockParameterExtracting {
    private struct ModelPayload: Decodable {
        let title: String?
        let fireAt: String?
        let notes: String?

        enum CodingKeys: String, CodingKey {
            case title
            case fireAt = "fire_at"
            case notes
        }
    }

    private let generationProvider: any TextGenerationProvider

    init(generationProvider: any TextGenerationProvider = OpenAITextGenerationProvider()) {
        self.generationProvider = generationProvider
    }

    func extract(
        request: AgentClockParameterExtractionRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> AgentClockTimerParameters {
        let normalizedCommand = request.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCommand.isEmpty else {
            throw AgentClockError.emptyCommand
        }

        let generation = try await generationProvider.generateText(
            request: buildGenerationRequest(request: request, command: normalizedCommand),
            configuration: configuration,
            apiKey: apiKey
        )
        let payload = try parsePayload(from: generation.outputText)

        let title = oneShotTitle(from: payload.title, command: normalizedCommand)
        let fireAt = oneShotFireAt(from: payload.fireAt, request: request)
        let notes = oneShotNotes(from: payload.notes, title: title, command: normalizedCommand)

        return AgentClockTimerParameters(title: title, fireAtISO8601: fireAt, notes: notes)
    }

    private func buildGenerationRequest(
        request: AgentClockParameterExtractionRequest,
        command: String
    ) -> TextGenerationRequest {
        let referenceText = AgentClockDateFormatter.iso8601.string(from: request.referenceDate)
        let systemPrompt = """
        你是 PulseType 的闹钟参数提取器。你只负责把用户口令转成 JSON 参数。

        规则：
        1. 只输出 JSON，不要输出解释、Markdown、代码块。
        2. 输出字段必须包含 title、fire_at、notes。
        3. fire_at 必须是 ISO-8601，例如 2026-05-23T09:00:00+08:00。
        4. 这是一次性路径，不追问、不确认。
        5. 如果缺少标题，你要基于语义生成短标题。
        6. 如果缺少具体日期或时间，你要结合当前参考时间推理一个未来时间。
        7. notes 要补成一句简短备注，说明提醒目的。
        """

        let userPrompt = """
        当前参考时间：\(referenceText)
        当前时区：\(request.timeZone.identifier)

        用户闹钟口令：
        <<<COMMAND
        \(command)
        COMMAND>>>
        """

        return TextGenerationRequest(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            temperature: 0,
            maxOutputTokens: 180
        )
    }

    private func parsePayload(from output: String) throws -> ModelPayload {
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let startIndex = trimmedOutput.firstIndex(of: "{"),
            let endIndex = trimmedOutput.lastIndex(of: "}"),
            startIndex <= endIndex
        else {
            throw AgentClockError.modelReturnedInvalidJSON(output)
        }

        let jsonText = String(trimmedOutput[startIndex...endIndex])
        guard
            let data = jsonText.data(using: .utf8),
            let payload = try? JSONDecoder().decode(ModelPayload.self, from: data)
        else {
            throw AgentClockError.modelReturnedInvalidJSON(output)
        }
        return payload
    }

    private func trimmed(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func oneShotTitle(from value: String?, command: String) -> String {
        let normalized = trimmed(value)
        return normalized.isEmpty ? "闹钟：\(command)" : normalized
    }

    private func oneShotFireAt(
        from value: String?,
        request: AgentClockParameterExtractionRequest
    ) -> String {
        let normalized = trimmed(value)
        guard normalized.isEmpty else {
            return normalized
        }
        let fallback = Self.nextFullMinute(after: request.referenceDate)
        return AgentClockDateFormatter.string(from: fallback, timeZone: request.timeZone)
    }

    private func oneShotNotes(from value: String?, title: String, command: String) -> String {
        let normalized = trimmed(value)
        guard normalized.isEmpty else {
            return normalized
        }
        return "提醒：\(title)。来源口令：\(command)"
    }

    private static func nextFullMinute(after date: Date) -> Date {
        let epoch = date.timeIntervalSince1970
        let rounded = floor(epoch / 60.0) * 60.0 + 60.0
        return Date(timeIntervalSince1970: rounded)
    }
}

struct AgentClockTimerExecutionRequest {
    let traceID: String
    let command: String
    let referenceDate: Date
    let timeZone: TimeZone

    init(
        traceID: String,
        command: String,
        referenceDate: Date = Date(),
        timeZone: TimeZone = .current
    ) {
        self.traceID = traceID
        self.command = command
        self.referenceDate = referenceDate
        self.timeZone = timeZone
    }
}

struct AgentClockTimerExecutionOutcome {
    let status: SessionHistoryStatus
    let message: String
    let outputText: String?
    let evidenceSummary: String
}

@MainActor
protocol AgentClockTimerControlling {
    func execute(
        _ request: AgentClockTimerExecutionRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async -> AgentClockTimerExecutionOutcome
}

struct AgentClockTimerSpec: Equatable {
    let title: String
    let notes: String
    let fireAt: Date
    let timeZone: TimeZone

    init(parameters: AgentClockTimerParameters, timeZone: TimeZone) throws {
        guard let fireAt = AgentClockDateFormatter.iso8601.date(from: parameters.fireAtISO8601) else {
            throw AgentClockError.invalidFireTime(parameters.fireAtISO8601)
        }
        self.fireAt = fireAt
        self.timeZone = timeZone

        let normalizedTitle = parameters.title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = normalizedTitle.isEmpty ? "闹钟提醒" : normalizedTitle
        self.notes = parameters.notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct AgentClockScheduleResult: Equatable {
    let success: Bool
    let identifier: String
    let detail: String
}

protocol AgentClockTimerScheduling: Sendable {
    func scheduleTimer(_ spec: AgentClockTimerSpec) async -> AgentClockScheduleResult
}

struct UserNotificationAgentClockScheduler: AgentClockTimerScheduling {
    func scheduleTimer(_ spec: AgentClockTimerSpec) async -> AgentClockScheduleResult {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await requestAuthorization(center: center)
            guard granted else {
                return AgentClockScheduleResult(success: false, identifier: "", detail: "notification_permission_denied")
            }

            let content = UNMutableNotificationContent()
            content.title = spec.title
            content.body = spec.notes.isEmpty ? "到点了" : spec.notes
            content.sound = .default

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = spec.timeZone
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: spec.fireAt)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let identifier = "pulsetype.clock.timer.\(UUID().uuidString)"
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
            try await addNotification(center: center, request: request)

            return AgentClockScheduleResult(
                success: true,
                identifier: identifier,
                detail: "scheduled"
            )
        } catch {
            return AgentClockScheduleResult(success: false, identifier: "", detail: error.localizedDescription)
        }
    }

    private func requestAuthorization(center: UNUserNotificationCenter) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func addNotification(center: UNUserNotificationCenter, request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}

@MainActor
final class AgentClockTimerExecutor: AgentClockTimerControlling {
    private let parameterExtractor: any AgentClockParameterExtracting
    private let scheduler: any AgentClockTimerScheduling

    init(
        parameterExtractor: any AgentClockParameterExtracting = LLMAgentClockParameterExtractor(),
        scheduler: any AgentClockTimerScheduling = UserNotificationAgentClockScheduler()
    ) {
        self.parameterExtractor = parameterExtractor
        self.scheduler = scheduler
    }

    func execute(
        _ request: AgentClockTimerExecutionRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async -> AgentClockTimerExecutionOutcome {
        do {
            let parameters = try await parameterExtractor.extract(
                request: AgentClockParameterExtractionRequest(
                    command: request.command,
                    referenceDate: request.referenceDate,
                    timeZone: request.timeZone
                ),
                configuration: configuration,
                apiKey: apiKey
            )
            let spec = try AgentClockTimerSpec(parameters: parameters, timeZone: request.timeZone)
            let scheduleResult = await scheduler.scheduleTimer(spec)
            let evidence = composeEvidence(traceID: request.traceID, spec: spec, result: scheduleResult)

            guard scheduleResult.success else {
                return failure(message: AgentClockError.scheduleFailed(scheduleResult.detail).localizedDescription, evidence: evidence)
            }

            let output = "已设置闹钟：\(spec.title)。"
            return AgentClockTimerExecutionOutcome(
                status: .success,
                message: output,
                outputText: output,
                evidenceSummary: evidence
            )
        } catch let clockError as AgentClockError {
            return failure(
                message: clockError.localizedDescription,
                evidence: "apple.clock.timer|trace_id=\(sanitizeClockEvidenceValue(request.traceID))|error=\(sanitizeClockEvidenceValue(String(describing: clockError)))"
            )
        } catch {
            return failure(
                message: "闹钟设置失败：\(error.localizedDescription)",
                evidence: "apple.clock.timer|trace_id=\(sanitizeClockEvidenceValue(request.traceID))|error=unexpected|detail=\(sanitizeClockEvidenceValue(error.localizedDescription))"
            )
        }
    }

    private func composeEvidence(
        traceID: String,
        spec: AgentClockTimerSpec,
        result: AgentClockScheduleResult
    ) -> String {
        [
            "apple.clock.timer",
            "trace_id=\(sanitizeClockEvidenceValue(traceID))",
            "title=\(sanitizeClockEvidenceValue(spec.title))",
            "fire_at=\(AgentClockDateFormatter.iso8601.string(from: spec.fireAt))",
            "identifier=\(sanitizeClockEvidenceValue(result.identifier))",
            "result=\(sanitizeClockEvidenceValue(result.detail))"
        ].joined(separator: "|")
    }

    private func failure(message: String, evidence: String) -> AgentClockTimerExecutionOutcome {
        AgentClockTimerExecutionOutcome(
            status: .failed,
            message: message,
            outputText: nil,
            evidenceSummary: evidence
        )
    }
}

private enum AgentClockDateFormatter {
    static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func string(from date: Date, timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}

private func sanitizeClockEvidenceValue(_ value: String) -> String {
    value
        .replacingOccurrences(of: "|", with: "/")
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
