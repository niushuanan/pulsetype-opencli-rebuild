import AppKit
import ApplicationServices
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
        let title = oneShotTitle(from: payload.title, command: normalizedCommand)
        let fireAt = try requiredFireAt(from: payload.fireAt, rawOutput: generation.outputText)
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
        5. title 必须是你概括后的短标题，禁止留空、禁止照抄整句口令。
        6. title 禁止使用“闹钟”“提醒”“闹钟提醒”等空泛词作为完整标题。
        7. 如果缺少具体日期或时间，你要结合当前参考时间推理一个未来时间。
        8. notes 要补成一句简短备注，说明提醒目的。
        9. action 只能是 create_one_shot_alarm。
        10. 你输出前必须自检：fire_at 不允许为空，不允许 null，不允许省略。
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
            maxOutputTokens: 320
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
        if normalized.isEmpty || isGenericTitle(normalized) {
            let heuristic = heuristicTitle(from: command)
            return heuristic.isEmpty ? "闹钟提醒" : heuristic
        }
        return normalized
    }

    private func isGenericTitle(_ value: String) -> Bool {
        let normalized = value.replacingOccurrences(of: " ", with: "").lowercased()
        return ["闹钟", "提醒", "闹钟提醒", "alarm", "reminder"].contains(normalized)
    }

    private func heuristicTitle(from command: String) -> String {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        let dropTokens = ["帮我定一个", "帮我定", "设置一个", "设置", "定一个", "定", "闹钟", "提醒我", "提醒", "今天", "下午", "上午", "晚上", "中午", "明天", "后天"]
        var candidate = text
        for token in dropTokens {
            candidate = candidate.replacingOccurrences(of: token, with: "")
        }
        candidate = candidate.replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "，", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.count > 12 {
            candidate = String(candidate.prefix(12))
        }
        return candidate
    }

    private func oneShotAction(from value: String?) -> String {
        let normalized = trimmed(value).lowercased()
        return normalized == "create_one_shot_alarm" ? normalized : "create_one_shot_alarm"
    }

    private func requiredFireAt(from value: String?, rawOutput: String) throws -> String {
        let normalized = trimmed(value)
        guard !normalized.isEmpty else {
            throw AgentClockError.modelReturnedInvalidJSON("missing_fire_at|\(rawOutput)")
        }
        guard AgentClockDateFormatter.iso8601.date(from: normalized) != nil else {
            throw AgentClockError.modelReturnedInvalidJSON("invalid_fire_at|\(rawOutput)")
        }
        return normalized
    }

    private func oneShotNotes(from value: String?, title: String, command: String) -> String {
        let normalized = trimmed(value)
        guard normalized.isEmpty else {
            return normalized
        }
        return "提醒：\(title)。来源口令：\(command)"
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
        return ClockAccessibilityAlarmCreator().createAlarm(
            title: spec.title,
            timeText: timeText,
            identifier: identifier
        )
    }
}

private struct ClockAccessibilityAlarmCreator {
    func createAlarm(title: String, timeText: String, identifier: String) -> AgentClockExecutionResult {
        guard AXIsProcessTrusted() else {
            return AgentClockExecutionResult(success: false, identifier: "", detail: "clock_error|detail=accessibility_denied")
        }
        guard let app = launchClock() else {
            return AgentClockExecutionResult(success: false, identifier: "", detail: "clock_error|detail=clock_launch_failed")
        }

        app.activate(options: [.activateIgnoringOtherApps])
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard waitForElement(in: axApp, matching: { role(of: $0) == kAXWindowRole as String }) != nil else {
            return AgentClockExecutionResult(success: false, identifier: "", detail: "clock_error|detail=window_not_found")
        }

        pressAlarmTab(in: axApp)
        let beforeIDs = Set(alarmIdentifiers(in: axApp))
        guard openAlarmEditor(in: axApp) else {
            return AgentClockExecutionResult(success: false, identifier: "", detail: "clock_error|detail=add_alarm_button_not_found")
        }
        guard let sheet = waitForElement(in: axApp, matching: { role(of: $0) == kAXSheetRole as String }) else {
            return AgentClockExecutionResult(success: false, identifier: "", detail: "clock_error|detail=alarm_editor_not_opened")
        }
        guard setTime(timeText, in: sheet) else {
            return AgentClockExecutionResult(success: false, identifier: "", detail: "clock_error|detail=set_time_failed")
        }
        guard setLabel(title, in: sheet) else {
            return AgentClockExecutionResult(success: false, identifier: "", detail: "clock_error|detail=set_label_failed")
        }
        guard pressSave(in: sheet) else {
            return AgentClockExecutionResult(success: false, identifier: "", detail: "clock_error|detail=save_button_not_found")
        }
        guard let matchedID = waitForCreatedAlarm(in: axApp, beforeIDs: beforeIDs, timeText: timeText, title: title) else {
            let afterIDs = alarmIdentifiers(in: axApp)
            return AgentClockExecutionResult(
                success: false,
                identifier: "",
                detail: "clock_error|detail=verification_failed|expected_time=\(timeText)|expected_title=\(title)|before=\(beforeIDs.count)|after=\(afterIDs.count)"
            )
        }

        return AgentClockExecutionResult(
            success: true,
            identifier: matchedID,
            detail: "alarm_created|clock_app=true|once=true|time=\(timeText)|alarm_id=\(matchedID)|verification=time_and_title_matched|before=\(beforeIDs.count)"
        )
    }

    private func launchClock() -> NSRunningApplication? {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.clock").first {
            return running
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.clock") else {
            return nil
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return waitForRunningClock()
    }

    private func waitForRunningClock() -> NSRunningApplication? {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.clock").first {
                return running
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    private func pressAlarmTab(in app: AXUIElement) {
        guard let tab = findFirst(in: app, matching: { element in
            role(of: element) == kAXRadioButtonRole as String
                && textSnapshot(for: element).containsAny(["闹钟", "Alarm"])
        }) else {
            return
        }
        _ = AXUIElementPerformAction(tab, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 0.15)
    }

    private func openAlarmEditor(in app: AXUIElement) -> Bool {
        guard let button = findFirst(in: app, matching: { element in
            let roleName = role(of: element)
            return (roleName == kAXMenuButtonRole as String || roleName == kAXButtonRole as String)
                && textSnapshot(for: element).containsAny(["添加闹钟", "Add Alarm"])
        }) else {
            return false
        }
        _ = AXUIElementPerformAction(button, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 0.2)
        if findFirst(in: app, matching: { role(of: $0) == kAXSheetRole as String }) != nil {
            return true
        }
        clickCenter(of: button)
        return waitForElement(in: app, matching: { role(of: $0) == kAXSheetRole as String }) != nil
    }

    private func setTime(_ timeText: String, in sheet: AXUIElement) -> Bool {
        let candidates = allElements(in: sheet).filter { element in
            role(of: element) == "AXDateTimeArea"
        }
        for candidate in candidates {
            if let timeValue = clockDateValue(for: candidate, timeText: timeText),
               setValueAndVerify(timeValue, expectedText: timeText, on: candidate) {
                return true
            }
            if clickCenter(of: candidate), clearFocusedText(usingDelete: false) {
                typeText(timeText)
                Thread.sleep(forTimeInterval: 0.15)
                if textSnapshot(for: candidate).contains(timeText) {
                    return true
                }
            }
        }
        return false
    }

    private func setLabel(_ title: String, in sheet: AXUIElement) -> Bool {
        let candidates = allElements(in: sheet).filter { element in
            role(of: element) == kAXTextFieldRole as String
        }
        for candidate in candidates {
            if setValueAndVerify(title as CFTypeRef, expectedText: title, on: candidate) {
                return true
            }
            if clickCenter(of: candidate), clearFocusedText(usingDelete: true) {
                typeText(title)
                Thread.sleep(forTimeInterval: 0.1)
                if textSnapshot(for: candidate).contains(title) {
                    return true
                }
            }
        }
        return false
    }

    private func pressSave(in sheet: AXUIElement) -> Bool {
        guard let save = findFirst(in: sheet, matching: { element in
            role(of: element) == kAXButtonRole as String
                && textSnapshot(for: element).containsAny(["保存", "Save"])
        }) else {
            return false
        }
        let status = AXUIElementPerformAction(save, kAXPressAction as CFString)
        if status != .success {
            clickCenter(of: save)
        }
        Thread.sleep(forTimeInterval: 0.25)
        return true
    }

    private func waitForCreatedAlarm(
        in app: AXUIElement,
        beforeIDs: Set<String>,
        timeText: String,
        title: String
    ) -> String? {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            for alarm in alarmElements(in: app) {
                let alarmID = stringAttribute(kAXIdentifierAttribute as String, on: alarm) ?? ""
                let snapshot = textSnapshot(for: alarm)
                guard !beforeIDs.contains(alarmID) else {
                    continue
                }
                if snapshot.contains(timeText), snapshot.contains(title) {
                    return alarmID.isEmpty ? "matched-by-content" : alarmID
                }
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return nil
    }

    private func alarmIdentifiers(in app: AXUIElement) -> [String] {
        alarmElements(in: app).compactMap { element in
            let identifier = stringAttribute(kAXIdentifierAttribute as String, on: element) ?? ""
            return identifier.hasPrefix("Alarm-") ? identifier : nil
        }
    }

    private func alarmElements(in app: AXUIElement) -> [AXUIElement] {
        allElements(in: app).filter { element in
            let identifier = stringAttribute(kAXIdentifierAttribute as String, on: element) ?? ""
            return identifier.hasPrefix("Alarm-")
        }
    }

    private func waitForElement(in root: AXUIElement, matching predicate: (AXUIElement) -> Bool) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let element = findFirst(in: root, matching: predicate) {
                return element
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    private func findFirst(in root: AXUIElement, matching predicate: (AXUIElement) -> Bool) -> AXUIElement? {
        allElements(in: root).first(where: predicate)
    }

    private func allElements(in root: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        while let (element, depth) = stack.popLast() {
            result.append(element)
            guard depth < 8 else { continue }
            stack.append(contentsOf: children(of: element).map { ($0, depth + 1) })
        }
        return result
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        guard status == .success, let array = value as? [AXUIElement] else {
            return []
        }
        return array
    }

    private func role(of element: AXUIElement) -> String {
        stringAttribute(kAXRoleAttribute as String, on: element) ?? ""
    }

    private func textSnapshot(for element: AXUIElement) -> String {
        var parts: [String] = []
        for attribute in [
            kAXIdentifierAttribute as String,
            kAXDescriptionAttribute as String,
            kAXTitleAttribute as String,
            kAXValueAttribute as String,
            "AXRoleDescription"
        ] {
            if let value = stringAttribute(attribute, on: element), !value.isEmpty {
                parts.append(value)
            }
        }
        for child in children(of: element) {
            let childText = textSnapshot(for: child)
            if !childText.isEmpty {
                parts.append(childText)
            }
        }
        return parts.joined(separator: " ")
    }

    private func stringAttribute(_ attribute: String, on element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success else {
            return nil
        }
        return value as? String
    }

    @discardableResult
    private func clickCenter(of element: AXUIElement) -> Bool {
        guard let frame = frame(of: element) else {
            return false
        }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.15)
        return true
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
            let positionAX = positionValue,
            let sizeAX = sizeValue
        else {
            return nil
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(unsafeBitCast(positionAX, to: AXValue.self), .cgPoint, &point),
            AXValueGetValue(unsafeBitCast(sizeAX, to: AXValue.self), .cgSize, &size)
        else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }

    private func setValueAndVerify(_ value: CFTypeRef, expectedText: String, on element: AXUIElement) -> Bool {
        let status = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value)
        guard status == .success else {
            return false
        }
        Thread.sleep(forTimeInterval: 0.15)
        return textSnapshot(for: element).containsAny(clockDisplayVariants(for: expectedText))
    }

    private func clearFocusedText(usingDelete: Bool) -> Bool {
        pressKeyCG(55, down: true)
        pressKeyCG(0, down: true)
        pressKeyCG(0, down: false)
        pressKeyCG(55, down: false)
        Thread.sleep(forTimeInterval: 0.05)

        let deleteKey: CGKeyCode = usingDelete ? 51 : 117
        pressKeyCG(deleteKey, down: true)
        pressKeyCG(deleteKey, down: false)
        Thread.sleep(forTimeInterval: 0.05)
        return true
    }

    private func typeText(_ text: String) {
        for scalar in text.unicodeScalars {
            guard let source = CGEventSource(stateID: .combinedSessionState) else {
                continue
            }
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: [UniChar(scalar.value)])
            up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: [UniChar(scalar.value)])
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    private func pressKeyCG(_ keyCode: CGKeyCode, down: Bool) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else {
            return
        }
        event.post(tap: .cghidEventTap)
    }

    private func clockDateValue(for element: AXUIElement, timeText: String) -> CFTypeRef? {
        let parts = timeText.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]) else {
            return nil
        }

        var currentValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &currentValue) == .success,
              let currentDate = currentValue as? Date else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = calendar.dateComponents([.year, .month, .day], from: currentDate)
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard let targetDate = calendar.date(from: components) else {
            return nil
        }
        return targetDate as CFDate
    }

    private func clockDisplayVariants(for timeText: String) -> [String] {
        let parts = timeText.split(separator: ":")
        guard parts.count == 2,
              let hour24 = Int(parts[0]),
              let minute = Int(parts[1]) else {
            return [timeText]
        }

        let minuteText = String(format: "%02d", minute)
        let hour12Raw = hour24 % 12
        let hour12 = hour12Raw == 0 ? 12 : hour12Raw
        let periodCN = hour24 < 12 ? "上午" : "下午"
        let periodEN = hour24 < 12 ? "AM" : "PM"

        return [
            timeText,
            "\(periodCN)\(hour12):\(minuteText)",
            "\(periodCN) \(hour12):\(minuteText)",
            "\(hour12):\(minuteText) \(periodEN)",
            "\(hour12):\(minuteText)\(periodEN)"
        ]
    }
}

private extension String {
    func containsAny(_ values: [String]) -> Bool {
        values.contains { self.localizedCaseInsensitiveContains($0) }
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
