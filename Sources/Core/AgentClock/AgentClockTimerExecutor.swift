import Foundation

struct AgentClockParameterExtractionRequest: Equatable {
    let command: String
    let referenceDate: Date
    let timeZone: TimeZone
}

struct AgentClockTimerParameters: Equatable {
    let action: String
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
        let action: String?
        let title: String?
        let fireAt: String?
        let notes: String?

        enum CodingKeys: String, CodingKey {
            case action
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

        let action = oneShotAction(from: payload.action)
        let title = try await oneShotTitle(
            from: payload.title,
            command: normalizedCommand,
            request: request,
            configuration: configuration,
            apiKey: apiKey
        )
        let fireAt = oneShotFireAt(from: payload.fireAt, request: request)
        let notes = oneShotNotes(from: payload.notes, title: title, command: normalizedCommand)

        return AgentClockTimerParameters(action: action, title: title, fireAtISO8601: fireAt, notes: notes)
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
        2. 输出字段必须包含 action、title、fire_at、notes。
        3. fire_at 必须是 ISO-8601，例如 2026-05-23T09:00:00+08:00。
        4. 这是一次性路径，不追问、不确认。
        5. 如果缺少标题，你要基于语义生成短标题。
        6. 如果缺少具体日期或时间，你要结合当前参考时间推理一个未来时间。
        7. notes 要补成一句简短备注，说明提醒目的。
        8. action 只能是 create_one_shot_alarm。
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

    private func oneShotTitle(
        from value: String?,
        command: String,
        request: AgentClockParameterExtractionRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> String {
        let normalized = trimmed(value)
        guard normalized.isEmpty else {
            return normalized
        }
        let fallback = try await summarizeTitleByModel(
            command: command,
            referenceDate: request.referenceDate,
            timeZone: request.timeZone,
            configuration: configuration,
            apiKey: apiKey
        )
        return fallback.isEmpty ? "闹钟提醒" : fallback
    }

    private func oneShotAction(from value: String?) -> String {
        let normalized = trimmed(value).lowercased()
        return normalized == "create_one_shot_alarm" ? normalized : "create_one_shot_alarm"
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

    private func summarizeTitleByModel(
        command: String,
        referenceDate: Date,
        timeZone: TimeZone,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> String {
        let referenceText = AgentClockDateFormatter.iso8601.string(from: referenceDate)
        let titleRequest = TextGenerationRequest(
            systemPrompt: """
            你是闹钟标题概括器。请把用户口令概括成一个简短闹钟标题。
            规则：
            1. 只输出标题纯文本，不要 JSON、解释、引号、代码块。
            2. 标题控制在 4 到 12 个中文字符，信息清晰。
            """,
            userPrompt: """
            当前参考时间：\(referenceText)
            当前时区：\(timeZone.identifier)
            用户口令：\(command)
            """,
            temperature: 0,
            maxOutputTokens: 32
        )
        let generation = try await generationProvider.generateText(
            request: titleRequest,
            configuration: configuration,
            apiKey: apiKey
        )
        return sanitizeModelTitle(generation.outputText)
    }

    private func sanitizeModelTitle(_ raw: String) -> String {
        var normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("\""), normalized.hasSuffix("\""), normalized.count >= 2 {
            normalized = String(normalized.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if normalized.hasPrefix("“"), normalized.hasSuffix("”"), normalized.count >= 2 {
            normalized = String(normalized.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if normalized.count > 20 {
            normalized = String(normalized.prefix(20))
        }
        return normalized
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
    let action: String
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

        self.action = parameters.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "create_one_shot_alarm"
            : parameters.action
        let normalizedTitle = parameters.title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = normalizedTitle.isEmpty ? "闹钟提醒" : normalizedTitle
        self.notes = parameters.notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct AgentClockExecutionResult: Equatable {
    let success: Bool
    let identifier: String
    let detail: String
}

protocol AgentClockScriptRunning: Sendable {
    func execute(_ spec: AgentClockTimerSpec) async -> AgentClockExecutionResult
}

struct AppleScriptAgentClockRunner: AgentClockScriptRunning {
    func execute(_ spec: AgentClockTimerSpec) async -> AgentClockExecutionResult {
        let calendar = Calendar(identifier: .gregorian)
        let comps = calendar.dateComponents(in: spec.timeZone, from: spec.fireAt)
        let minute = comps.minute ?? 0
        let hour24 = comps.hour ?? 0
        let timeText = String(format: "%02d:%02d", hour24, minute)
        let identifier = UUID().uuidString

        let lines = [
            "on run argv",
            "set targetLabel to item 1 of argv",
            "set timeText to item 2 of argv",
            "set alarmID to item 3 of argv",
            "tell application \"Clock\" to activate",
            "delay 0.35",
            "tell application \"System Events\"",
            "if UI elements enabled is false then return \"clock_error|detail=accessibility_denied\"",
            "tell process \"Clock\"",
            "set frontmost to true",
            "set beforeCount to 0",
            "set beforeIDs to \"\"",
            "try",
            "set allButtonsBefore to every button of entire contents of window 1",
            "repeat with b in allButtonsBefore",
            "set bIdentifier to \"\"",
            "set bDescription to \"\"",
            "try",
            "set bIdentifier to (identifier of b) as string",
            "end try",
            "try",
            "set bDescription to (description of b) as string",
            "end try",
            "if bIdentifier starts with \"Alarm-\" then",
            "set beforeCount to beforeCount + 1",
            "set beforeIDs to beforeIDs & \"|\" & bIdentifier",
            "else if bDescription contains \", 打开\" or bDescription contains \", Open\" then",
            "set beforeCount to beforeCount + 1",
            "end if",
            "end repeat",
            "end try",
            "set switchedToAlarmTab to false",
            "try",
            "click menu item \"闹钟\" of menu 1 of menu bar item \"显示\" of menu bar 1",
            "set switchedToAlarmTab to true",
            "end try",
            "if switchedToAlarmTab is false then",
            "try",
            "click menu item \"Alarm\" of menu 1 of menu bar item \"View\" of menu bar 1",
            "set switchedToAlarmTab to true",
            "end try",
            "end if",
            "if switchedToAlarmTab is false then return \"clock_error|detail=alarm_tab_not_found\"",
            "set openedEditor to false",
            "try",
            "click menu button 1 of toolbar 1 of window 1",
            "set openedEditor to true",
            "end try",
            "if openedEditor is false then return \"clock_error|detail=add_alarm_button_not_found\"",
            "delay 0.2",
            "set didSetTime to false",
            "try",
            "click UI element 1 of sheet 1 of window 1",
            "keystroke \"a\" using command down",
            "keystroke timeText",
            "key code 36",
            "set didSetTime to true",
            "end try",
            "if didSetTime is false then",
            "try",
            "click UI element 1 of window 1",
            "keystroke \"a\" using command down",
            "keystroke timeText",
            "key code 36",
            "set didSetTime to true",
            "end try",
            "end if",
            "if didSetTime is false then",
            "return \"clock_error|detail=set_time_failed\"",
            "end if",
            "delay 0.2",
            "if targetLabel is not \"\" then",
            "set didSetLabel to false",
            "try",
            "click text field 1 of sheet 1 of window 1",
            "keystroke \"a\" using command down",
            "keystroke targetLabel",
            "set didSetLabel to true",
            "end try",
            "if didSetLabel is false then",
            "try",
            "click text field 1 of window 1",
            "keystroke \"a\" using command down",
            "keystroke targetLabel",
            "set didSetLabel to true",
            "end try",
            "end if",
            "end if",
            "set savedAlarm to false",
            "try",
            "repeat with bt in (every button of sheet 1 of window 1)",
            "set btName to \"\"",
            "set btDescription to \"\"",
            "try",
            "set btName to (name of bt) as string",
            "end try",
            "try",
            "set btDescription to (description of bt) as string",
            "end try",
            "if btName is \"保存\" or btName is \"Save\" or btDescription is \"保存\" or btDescription is \"Save\" then",
            "click bt",
            "set savedAlarm to true",
            "exit repeat",
            "end if",
            "end repeat",
            "end try",
            "if savedAlarm is false then",
            "try",
            "click button \"保存\" of window 1",
            "set savedAlarm to true",
            "end try",
            "end if",
            "if savedAlarm is false then",
            "try",
            "click button 1 of sheet 1 of window 1",
            "set savedAlarm to true",
            "end try",
            "end if",
            "if savedAlarm is false then",
            "try",
            "click button 1 of window 1",
            "set savedAlarm to true",
            "end try",
            "end if",
            "if savedAlarm is false then return \"clock_error|detail=save_button_not_found\"",
            "delay 0.35",
            "set afterCount to 0",
            "set newAlarmIdentifier to \"\"",
            "try",
            "set allButtonsAfter to every button of entire contents of window 1",
            "repeat with b in allButtonsAfter",
            "set bIdentifier to \"\"",
            "set bDescription to \"\"",
            "try",
            "set bIdentifier to (identifier of b) as string",
            "end try",
            "try",
            "set bDescription to (description of b) as string",
            "end try",
            "if bIdentifier starts with \"Alarm-\" then",
            "set afterCount to afterCount + 1",
            "if beforeIDs does not contain (\"|\" & bIdentifier) and newAlarmIdentifier is \"\" then set newAlarmIdentifier to bIdentifier",
            "else if bDescription contains \", 打开\" or bDescription contains \", Open\" then",
            "set afterCount to afterCount + 1",
            "end if",
            "end repeat",
            "end try",
            "if newAlarmIdentifier is not \"\" then return \"alarm_created|clock_app=true|once=true|time=\" & timeText & \"|alarm_id=\" & newAlarmIdentifier & \"|before=\" & beforeCount & \"|after=\" & afterCount",
            "if afterCount > beforeCount then return \"alarm_created|clock_app=true|once=true|time=\" & timeText & \"|alarm_id=\" & alarmID & \"|before=\" & beforeCount & \"|after=\" & afterCount",
            "return \"clock_error|detail=verification_failed|before=\" & beforeCount & \"|after=\" & afterCount",
            "end tell",
            "end tell",
            "end run"
        ]

        let result = runClockAppleScript(lines: lines, arguments: [spec.title, timeText, identifier])
        guard result.exitCode == 0 else {
            return AgentClockExecutionResult(success: false, identifier: "", detail: "osascript_failed:\(result.stderr)")
        }
        guard result.stdout.contains("alarm_created") else {
            return AgentClockExecutionResult(success: false, identifier: "", detail: result.stdout.isEmpty ? "verification_failed" : result.stdout)
        }
        return AgentClockExecutionResult(success: true, identifier: identifier, detail: result.stdout)
    }
}

@MainActor
final class AgentClockTimerExecutor: AgentClockTimerControlling {
    private let parameterExtractor: any AgentClockParameterExtracting
    private let runner: any AgentClockScriptRunning

    init(
        parameterExtractor: any AgentClockParameterExtracting = LLMAgentClockParameterExtractor(),
        runner: any AgentClockScriptRunning = AppleScriptAgentClockRunner()
    ) {
        self.parameterExtractor = parameterExtractor
        self.runner = runner
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
            let executionResult = await runner.execute(spec)
            let evidence = composeEvidence(traceID: request.traceID, spec: spec, result: executionResult)

            guard executionResult.success else {
                return failure(message: AgentClockError.scheduleFailed(executionResult.detail).localizedDescription, evidence: evidence)
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
        result: AgentClockExecutionResult
    ) -> String {
        [
            "apple.clock.timer",
            "trace_id=\(sanitizeClockEvidenceValue(traceID))",
            "action=\(sanitizeClockEvidenceValue(spec.action))",
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

private struct ClockAppleScriptExecution {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

private func runClockAppleScript(lines: [String], arguments: [String]) -> ClockAppleScriptExecution {
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
        return ClockAppleScriptExecution(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            stderr: String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    } catch {
        return ClockAppleScriptExecution(exitCode: 1, stdout: "", stderr: error.localizedDescription)
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
