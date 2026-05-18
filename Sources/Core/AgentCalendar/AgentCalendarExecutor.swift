import Foundation

struct AgentCalendarParameterExtractionRequest: Equatable {
    let command: String
    let referenceDate: Date
    let timeZone: TimeZone
}

struct AgentCalendarParameters: Equatable {
    let title: String
    let startAtISO8601: String
    let endAtISO8601: String?
    let calendarName: String?
    let location: String
    let notes: String
    let alarmMinutesBefore: Int?
    let needsConfirmation: Bool
    let confirmationQuestion: String?
}

enum AgentCalendarError: LocalizedError, Equatable {
    case emptyCommand
    case modelReturnedInvalidJSON(String)
    case missingTitle
    case missingStartTime
    case invalidStartTime(String)
    case invalidEndTime(String)
    case endBeforeStart
    case needsConfirmation(String)
    case scriptFailed(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyCommand:
            return "没有识别到可创建日程的指令。"
        case let .modelReturnedInvalidJSON(output):
            let normalized = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? "日历工具没有返回可用参数。" : "日历工具返回格式不正确：\(normalized)"
        case .missingTitle:
            return "没有识别到日程标题。"
        case .missingStartTime:
            return "没有识别到日程开始时间。"
        case let .invalidStartTime(value):
            return "日程开始时间格式不正确：\(value)。"
        case let .invalidEndTime(value):
            return "日程结束时间格式不正确：\(value)。"
        case .endBeforeStart:
            return "日程结束时间不能早于开始时间。"
        case let .needsConfirmation(question):
            return question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "创建日程前还需要补充时间信息。"
                : question
        case let .scriptFailed(reason):
            return "Calendar 执行失败：\(reason)"
        case let .verificationFailed(reason):
            return "Calendar 创建结果验证失败：\(reason)"
        }
    }
}

protocol AgentCalendarParameterExtracting: Sendable {
    func extract(
        request: AgentCalendarParameterExtractionRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> AgentCalendarParameters
}

struct LLMAgentCalendarParameterExtractor: AgentCalendarParameterExtracting {
    private struct ModelPayload: Decodable {
        let title: String?
        let startAt: String?
        let endAt: String?
        let calendar: String?
        let location: String?
        let notes: String?
        let alarmMinutesBefore: Int?
        let needsConfirmation: Bool?
        let confirmationQuestion: String?

        enum CodingKeys: String, CodingKey {
            case title
            case startAt = "start_at"
            case endAt = "end_at"
            case calendar
            case location
            case notes
            case alarmMinutesBefore = "alarm_minutes_before"
            case needsConfirmation = "needs_confirmation"
            case confirmationQuestion = "confirmation_question"
        }
    }

    private let generationProvider: any TextGenerationProvider

    init(generationProvider: any TextGenerationProvider = OpenAITextGenerationProvider()) {
        self.generationProvider = generationProvider
    }

    func extract(
        request: AgentCalendarParameterExtractionRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> AgentCalendarParameters {
        let normalizedCommand = request.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCommand.isEmpty else {
            throw AgentCalendarError.emptyCommand
        }

        let generation = try await generationProvider.generateText(
            request: buildGenerationRequest(request: request, command: normalizedCommand),
            configuration: configuration,
            apiKey: apiKey
        )
        let payload = try parsePayload(from: generation.outputText)
        let needsConfirmation = payload.needsConfirmation ?? false
        if needsConfirmation {
            throw AgentCalendarError.needsConfirmation(payload.confirmationQuestion ?? "")
        }

        let title = trimmed(payload.title)
        guard !title.isEmpty else {
            throw AgentCalendarError.missingTitle
        }

        let startAt = trimmed(payload.startAt)
        guard !startAt.isEmpty else {
            throw AgentCalendarError.missingStartTime
        }

        return AgentCalendarParameters(
            title: title,
            startAtISO8601: startAt,
            endAtISO8601: normalizedOptional(payload.endAt),
            calendarName: normalizedOptional(payload.calendar),
            location: trimmed(payload.location),
            notes: trimmed(payload.notes),
            alarmMinutesBefore: payload.alarmMinutesBefore,
            needsConfirmation: false,
            confirmationQuestion: normalizedOptional(payload.confirmationQuestion)
        )
    }

    private func buildGenerationRequest(
        request: AgentCalendarParameterExtractionRequest,
        command: String
    ) -> TextGenerationRequest {
        let referenceText = AgentCalendarDateFormatter.iso8601.string(from: request.referenceDate)
        let systemPrompt = """
        你是 PulseType 的日历日程参数提取器。你只负责把用户的日程口令转成 JSON 参数，不执行任何动作。

        严格规则：
        1. 只输出 JSON，不要输出解释、Markdown、代码块或 AppleScript。
        2. 这是 Calendar 日程，不是提醒事项；默认要创建日历事件。
        3. 输出字段必须包含 title、start_at、end_at、calendar、location、notes、alarm_minutes_before、needs_confirmation、confirmation_question。
        4. start_at 和 end_at 必须是 ISO-8601，例如 2026-05-23T09:00:00+08:00。
        5. 如果用户没有说结束时间，end_at 默认等于 start_at 后 1 小时。
        6. 如果用户只说“九点”这类时间，若今天该时间未过，默认今天；若已过，默认明天。
        7. 如果无法判断具体日期或时间，设置 needs_confirmation=true，并给出一句简短 confirmation_question。
        8. 不要编造地点、备注和日历名；没说就返回空字符串或 null。
        """

        let userPrompt = """
        当前参考时间：\(referenceText)
        当前时区：\(request.timeZone.identifier)

        用户日程口令：
        <<<COMMAND
        \(command)
        COMMAND>>>
        """

        return TextGenerationRequest(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            temperature: 0,
            maxOutputTokens: 220
        )
    }

    private func parsePayload(from output: String) throws -> ModelPayload {
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let startIndex = trimmedOutput.firstIndex(of: "{"),
            let endIndex = trimmedOutput.lastIndex(of: "}"),
            startIndex <= endIndex
        else {
            throw AgentCalendarError.modelReturnedInvalidJSON(output)
        }

        let jsonText = String(trimmedOutput[startIndex...endIndex])
        guard
            let data = jsonText.data(using: .utf8),
            let payload = try? JSONDecoder().decode(ModelPayload.self, from: data)
        else {
            throw AgentCalendarError.modelReturnedInvalidJSON(output)
        }
        return payload
    }

    private func trimmed(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func normalizedOptional(_ value: String?) -> String? {
        let normalized = trimmed(value)
        return normalized.isEmpty ? nil : normalized
    }
}

struct AgentCalendarExecutionRequest {
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

struct AgentCalendarExecutionOutcome {
    let status: SessionHistoryStatus
    let message: String
    let outputText: String?
    let evidenceSummary: String
}

@MainActor
protocol AgentCalendarControlling {
    func execute(
        _ request: AgentCalendarExecutionRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async -> AgentCalendarExecutionOutcome
}

@MainActor
final class AgentCalendarCreateEventExecutor: AgentCalendarControlling {
    private let parameterExtractor: any AgentCalendarParameterExtracting
    private let scriptRunner: any AgentCalendarScriptRunning

    init(
        parameterExtractor: any AgentCalendarParameterExtracting = LLMAgentCalendarParameterExtractor(),
        scriptRunner: any AgentCalendarScriptRunning = AppleScriptAgentCalendarRunner()
    ) {
        self.parameterExtractor = parameterExtractor
        self.scriptRunner = scriptRunner
    }

    func execute(
        _ request: AgentCalendarExecutionRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async -> AgentCalendarExecutionOutcome {
        do {
            let parameters = try await parameterExtractor.extract(
                request: AgentCalendarParameterExtractionRequest(
                    command: request.command,
                    referenceDate: request.referenceDate,
                    timeZone: request.timeZone
                ),
                configuration: configuration,
                apiKey: apiKey
            )
            let spec = try AgentCalendarEventSpec(parameters: parameters, timeZone: request.timeZone)
            let scriptResult = await scriptRunner.createEvent(spec)
            let baseEvidence = composeEvidence(traceID: request.traceID, spec: spec, rawEvidence: scriptResult.stdout)

            guard scriptResult.exitCode == 0 else {
                return failure(
                    message: "Calendar 执行失败，请确认日历权限后重试。",
                    evidence: baseEvidence + "|error=osascript_failed|stderr=\(sanitizeCalendarEvidenceValue(scriptResult.stderr))"
                )
            }
            guard scriptResult.stdout.contains("event_created") else {
                return failure(
                    message: AgentCalendarError.verificationFailed(scriptResult.stdout).localizedDescription,
                    evidence: baseEvidence + "|error=verification_failed"
                )
            }

            let output = "已创建日程：\(spec.title)。"
            return AgentCalendarExecutionOutcome(
                status: .success,
                message: output,
                outputText: output,
                evidenceSummary: baseEvidence + "|verification=created"
            )
        } catch let calendarError as AgentCalendarError {
            return failure(
                message: calendarError.localizedDescription,
                evidence: "apple.calendar.create_event|trace_id=\(request.traceID)|error=\(sanitizeCalendarEvidenceValue(String(describing: calendarError)))"
            )
        } catch {
            return failure(
                message: "日历日程创建失败：\(error.localizedDescription)",
                evidence: "apple.calendar.create_event|trace_id=\(request.traceID)|error=unexpected|detail=\(sanitizeCalendarEvidenceValue(error.localizedDescription))"
            )
        }
    }

    private func failure(message: String, evidence: String) -> AgentCalendarExecutionOutcome {
        AgentCalendarExecutionOutcome(
            status: .failed,
            message: message,
            outputText: nil,
            evidenceSummary: evidence
        )
    }

    private func composeEvidence(
        traceID: String,
        spec: AgentCalendarEventSpec,
        rawEvidence: String
    ) -> String {
        [
            "apple.calendar.create_event",
            "trace_id=\(sanitizeCalendarEvidenceValue(traceID))",
            "title=\(sanitizeCalendarEvidenceValue(spec.title))",
            "start_at=\(AgentCalendarDateFormatter.iso8601.string(from: spec.startAt))",
            "end_at=\(AgentCalendarDateFormatter.iso8601.string(from: spec.endAt))",
            "calendar=\(sanitizeCalendarEvidenceValue(spec.calendarName ?? ""))",
            rawEvidence.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "|")
    }
}

struct AgentCalendarEventSpec: Equatable {
    let title: String
    let startAt: Date
    let endAt: Date
    let calendarName: String?
    let location: String
    let notes: String
    let alarmMinutesBefore: Int?
    let timeZone: TimeZone

    init(parameters: AgentCalendarParameters, timeZone: TimeZone) throws {
        let title = parameters.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw AgentCalendarError.missingTitle
        }
        guard let startAt = AgentCalendarDateFormatter.iso8601.date(from: parameters.startAtISO8601) else {
            throw AgentCalendarError.invalidStartTime(parameters.startAtISO8601)
        }
        let endAt: Date
        if let endAtISO8601 = parameters.endAtISO8601 {
            guard let parsedEndAt = AgentCalendarDateFormatter.iso8601.date(from: endAtISO8601) else {
                throw AgentCalendarError.invalidEndTime(endAtISO8601)
            }
            endAt = parsedEndAt
        } else {
            endAt = startAt.addingTimeInterval(60 * 60)
        }
        guard endAt >= startAt else {
            throw AgentCalendarError.endBeforeStart
        }

        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.calendarName = Self.normalizedOptional(parameters.calendarName)
        self.location = parameters.location.trimmingCharacters(in: .whitespacesAndNewlines)
        self.notes = parameters.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        self.alarmMinutesBefore = parameters.alarmMinutesBefore
        self.timeZone = timeZone
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }
}

struct AgentCalendarScriptResult: Equatable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

protocol AgentCalendarScriptRunning: Sendable {
    func createEvent(_ spec: AgentCalendarEventSpec) async -> AgentCalendarScriptResult
}

struct AppleScriptAgentCalendarRunner: AgentCalendarScriptRunning {
    func createEvent(_ spec: AgentCalendarEventSpec) async -> AgentCalendarScriptResult {
        let start = components(for: spec.startAt, timeZone: spec.timeZone)
        let end = components(for: spec.endAt, timeZone: spec.timeZone)
        let startYear = String(required(start.year))
        let startMonth = String(required(start.month))
        let startDay = String(required(start.day))
        let startHour = String(required(start.hour))
        let startMinute = String(required(start.minute))
        let startSecond = String(required(start.second))
        let endYear = String(required(end.year))
        let endMonth = String(required(end.month))
        let endDay = String(required(end.day))
        let endHour = String(required(end.hour))
        let endMinute = String(required(end.minute))
        let endSecond = String(required(end.second))

        let arguments: [String] = [
            spec.title,
            spec.calendarName ?? "",
            spec.location,
            spec.notes,
            spec.alarmMinutesBefore.map(String.init) ?? "",
            startYear,
            startMonth,
            startDay,
            startHour,
            startMinute,
            startSecond,
            endYear,
            endMonth,
            endDay,
            endHour,
            endMinute,
            endSecond
        ]

        return await runCalendarAppleScript(lines: Self.createEventScriptLines, arguments: arguments)
    }

    private func components(for date: Date, timeZone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }

    private func required(_ value: Int?) -> Int {
        value ?? 0
    }

    private static let createEventScriptLines = [
        "on run argv",
        "set eventTitle to item 1 of argv",
        "set requestedCalendarName to item 2 of argv",
        "set eventLocation to item 3 of argv",
        "set eventNotes to item 4 of argv",
        "set alarmText to item 5 of argv",
        "set startDate to current date",
        "set year of startDate to ((item 6 of argv) as integer)",
        "set month of startDate to ((item 7 of argv) as integer)",
        "set day of startDate to ((item 8 of argv) as integer)",
        "set hours of startDate to ((item 9 of argv) as integer)",
        "set minutes of startDate to ((item 10 of argv) as integer)",
        "set seconds of startDate to ((item 11 of argv) as integer)",
        "set endDate to current date",
        "set year of endDate to ((item 12 of argv) as integer)",
        "set month of endDate to ((item 13 of argv) as integer)",
        "set day of endDate to ((item 14 of argv) as integer)",
        "set hours of endDate to ((item 15 of argv) as integer)",
        "set minutes of endDate to ((item 16 of argv) as integer)",
        "set seconds of endDate to ((item 17 of argv) as integer)",
        "tell application \"Calendar\"",
        "try",
        "set targetCalendar to missing value",
        "if requestedCalendarName is not \"\" then",
        "repeat with candidateCalendar in calendars",
        "try",
        "if ((name of candidateCalendar) as string) is requestedCalendarName and (writable of candidateCalendar) is true then",
        "set targetCalendar to candidateCalendar",
        "exit repeat",
        "end if",
        "end try",
        "end repeat",
        "end if",
        "if targetCalendar is missing value then",
        "repeat with candidateCalendar in calendars",
        "try",
        "set candidateName to (name of candidateCalendar) as string",
        "if (writable of candidateCalendar) is true and candidateName does not contain \"节假日\" and candidateName does not contain \"生日\" then",
        "set targetCalendar to candidateCalendar",
        "exit repeat",
        "end if",
        "end try",
        "end repeat",
        "end if",
        "if targetCalendar is missing value then return \"calendar_not_found\"",
        "set newEvent to make new event at end of events of targetCalendar with properties {summary:eventTitle, start date:startDate, end date:endDate}",
        "if eventLocation is not \"\" then set location of newEvent to eventLocation",
        "if eventNotes is not \"\" then set description of newEvent to eventNotes",
        "if alarmText is not \"\" then",
        "set alarmMinutes to alarmText as integer",
        "make new display alarm at end of display alarms of newEvent with properties {trigger interval:(0 - alarmMinutes)}",
        "end if",
        "return \"event_created|calendar=\" & ((name of targetCalendar) as string) & \"|uid=\" & ((uid of newEvent) as string) & \"|summary=\" & ((summary of newEvent) as string)",
        "on error errMsg number errNum",
        "return \"calendar_error|number=\" & errNum & \"|message=\" & errMsg",
        "end try",
        "end tell",
        "end run"
    ]
}

private enum AgentCalendarDateFormatter {
    static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private func runCalendarAppleScript(
    lines: [String],
    arguments: [String]
) async -> AgentCalendarScriptResult {
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
            return AgentCalendarScriptResult(
                exitCode: process.terminationStatus,
                stdout: String(data: stdoutData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                stderr: String(data: stderrData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        } catch {
            return AgentCalendarScriptResult(
                exitCode: 1,
                stdout: "",
                stderr: error.localizedDescription
            )
        }
    }.value
}

private func sanitizeCalendarEvidenceValue(_ value: String) -> String {
    value
        .replacingOccurrences(of: "|", with: "/")
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
