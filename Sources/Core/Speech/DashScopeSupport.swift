import Foundation

struct DashScopeASRPayload: Encodable {
    struct Input: Encodable {
        let messages: [Message]
    }

    struct Message: Encodable {
        let role: String
        let content: [Content]
    }

    struct Content: Encodable {
        let text: String?
        let audio: String?

        static func text(_ value: String) -> Content {
            Content(text: value, audio: nil)
        }

        static func audio(_ value: String) -> Content {
            Content(text: nil, audio: value)
        }
    }

    struct Parameters: Encodable {
        let resultFormat: String

        struct ASROptions: Encodable {
            let language: String?
            let enableITN: Bool

            enum CodingKeys: String, CodingKey {
                case language
                case enableITN = "enable_itn"
            }
        }

        let asrOptions: ASROptions

        enum CodingKeys: String, CodingKey {
            case resultFormat = "result_format"
            case asrOptions = "asr_options"
        }
    }

    let model: String
    let input: Input
    let parameters: Parameters
}

struct DashScopeASRResponse: Decodable {
    let output: DashScopeASROutput?
    let choices: [DashScopeASRChoice]?

    struct DashScopeASROutput: Decodable {
        let choices: [DashScopeASRChoice]?
        let text: String?
    }

    struct DashScopeASRChoice: Decodable {
        let message: DashScopeASRMessage?
        let text: String?
    }

    struct DashScopeASRMessage: Decodable {
        let content: DashScopeASRContent
    }

    enum DashScopeASRContent: Decodable {
        case string(String)
        case items([DashScopeASRContentItem])
        case empty

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                self = .string(string)
                return
            }
            if let items = try? container.decode([DashScopeASRContentItem].self) {
                self = .items(items)
                return
            }
            self = .empty
        }
    }

    struct DashScopeASRContentItem: Decodable {
        let text: String?
    }
}

struct DashScopeBusinessError: Equatable {
    let code: String?
    let message: String

    var displayMessage: String {
        if let code, !code.isEmpty {
            return "\(code)：\(message)"
        }
        return message
    }
}

enum DashScopeResponseParser {
    private static let ignoredTranscriptEchoes: Set<String> = [
        "请把音频转写成简体中文文本，只返回转写结果。"
    ]

    static func transcript(from data: Data) -> String {
        if
            let payload = try? JSONDecoder().decode(DashScopeASRResponse.self, from: data),
            let parsed = transcript(from: payload),
            !parsed.isEmpty
        {
            return parsed
        }

        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let json = object as? [String: Any]
        else {
            return ""
        }

        let fromOutputChoices = parseChoices(
            from: (json["output"] as? [String: Any])?["choices"]
        )
        if !fromOutputChoices.isEmpty {
            return fromOutputChoices.joined(separator: "\n")
        }

        let fromTopChoices = parseChoices(from: json["choices"])
        if !fromTopChoices.isEmpty {
            return fromTopChoices.joined(separator: "\n")
        }

        if
            let output = json["output"] as? [String: Any],
            let outputText = normalizeText(output["text"])
        {
            return outputText
        }

        if let text = normalizeText(json["text"]) {
            return text
        }

        return ""
    }

    static func businessError(from data: Data) -> DashScopeBusinessError? {
        if
            let object = try? JSONSerialization.jsonObject(with: data),
            let json = object as? [String: Any]
        {
            let directMessage = normalizeText(json["message"])
            let directCode = normalizeText(json["code"])

            if
                let errorObject = json["error"] as? [String: Any],
                let nestedMessage = normalizeText(errorObject["message"])
            {
                let nestedCode = normalizeText(errorObject["code"]) ?? directCode
                return DashScopeBusinessError(code: nestedCode, message: nestedMessage)
            }

            if let directMessage {
                return DashScopeBusinessError(code: directCode, message: directMessage)
            }
        }

        return nil
    }

    private static func transcript(from payload: DashScopeASRResponse) -> String? {
        let outputChoiceText = collectChoiceText(from: payload.output?.choices)
        if !outputChoiceText.isEmpty {
            return outputChoiceText.joined(separator: "\n")
        }

        let topChoiceText = collectChoiceText(from: payload.choices)
        if !topChoiceText.isEmpty {
            return topChoiceText.joined(separator: "\n")
        }

        if let outputText = payload.output?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !outputText.isEmpty {
            return outputText
        }
        return nil
    }

    private static func collectChoiceText(from choices: [DashScopeASRResponse.DashScopeASRChoice]?) -> [String] {
        guard let choices else {
            return []
        }
        return uniqueNonEmpty(
            choices.compactMap { choice in
                if let content = choice.message?.content {
                    switch content {
                    case let .string(text):
                        return normalizeTranscriptCandidate(text)
                    case let .items(items):
                        let fragments = items.compactMap(\.text).compactMap(normalizeTranscriptCandidate)
                        return fragments.isEmpty ? nil : fragments.joined(separator: "\n")
                    case .empty:
                        return normalizeTranscriptCandidate(choice.text)
                    }
                }
                return normalizeTranscriptCandidate(choice.text)
            }
        )
    }

    private static func parseChoices(from value: Any?) -> [String] {
        guard let choices = value as? [[String: Any]] else {
            return []
        }

        var fragments: [String] = []
        for choice in choices {
            if
                let message = choice["message"] as? [String: Any],
                let content = message["content"]
            {
                fragments.append(contentsOf: parseContent(content))
            }
            if let text = normalizeText(choice["text"]) {
                fragments.append(text)
            }
        }
        return uniqueNonEmpty(fragments)
    }

    private static func parseContent(_ value: Any) -> [String] {
        if let text = normalizeText(value) {
            return [text]
        }
        if let items = value as? [[String: Any]] {
            return uniqueNonEmpty(items.compactMap { normalizeText($0["text"]) })
        }
        if let strings = value as? [String] {
            return uniqueNonEmpty(strings)
        }
        return []
    }

    private static func uniqueNonEmpty(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values
            .compactMap(normalizeTranscriptCandidate)
            .filter { seen.insert($0).inserted }
    }

    private static func normalizeTranscriptCandidate(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard !ignoredTranscriptEchoes.contains(trimmed) else {
            return nil
        }
        return trimmed
    }

    private static func normalizeText(_ value: Any?) -> String? {
        guard let value else {
            return nil
        }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }
}

enum DashScopeTranscriptGuard {
    private static let lowSignalPhrases: Set<String> = [
        "嗯",
        "嗯。",
        "啊",
        "啊。",
        "哦",
        "哦。",
        "呃",
        "呃。",
        "thank you",
        "thank you.",
        "thanks",
        "thanks.",
        "ok",
        "ok.",
        "okay",
        "okay."
    ]

    static func shouldRetryWithChineseHint(
        transcript: String,
        audioDuration: TimeInterval
    ) -> Bool {
        let normalized = normalize(transcript)
        guard !normalized.isEmpty else {
            return false
        }

        if audioDuration >= 20, normalized.count <= 30 {
            return true
        }

        guard audioDuration >= 2.5 else {
            return false
        }

        if normalized.count <= 2 {
            return true
        }

        if lowSignalPhrases.contains(normalized.lowercased()) {
            return true
        }

        if containsOnlyBasicLatinText(normalized), normalized.count <= 20 {
            return true
        }

        return false
    }

    static func shouldRejectAfterChineseHintRetry(
        transcript: String,
        audioDuration: TimeInterval
    ) -> Bool {
        let normalized = normalize(transcript)
        guard !normalized.isEmpty else {
            return true
        }

        if audioDuration >= 20, normalized.count <= 30 {
            return true
        }

        guard audioDuration >= 2.5 else {
            return false
        }

        if normalized.count <= 2 {
            return true
        }

        if lowSignalPhrases.contains(normalized.lowercased()) {
            return true
        }

        return false
    }

    static func suspiciousTranscriptFailureMessage(
        originalTranscript: String,
        retriedTranscript: String?,
        audioDuration: TimeInterval
    ) -> String {
        let originalPreview = preview(originalTranscript)
        let retriedPreview = preview(retriedTranscript ?? "")
        let duration = String(format: "%.1f", audioDuration)
        return "识别结果异常：\(duration) 秒录音返回了明显不可信的短结果。首次结果「\(originalPreview)」；中文重试结果「\(retriedPreview)」。"
    }

    private static func normalize(_ transcript: String) -> String {
        transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsOnlyBasicLatinText(_ text: String) -> Bool {
        let letters = CharacterSet.letters
        let decimals = CharacterSet.decimalDigits
        let allowedPunctuation = CharacterSet(charactersIn: " .,!?;:'\"-()[]{}")

        var sawLetter = false
        for scalar in text.unicodeScalars {
            if letters.contains(scalar) {
                sawLetter = true
                guard scalar.isASCII else {
                    return false
                }
                continue
            }
            if decimals.contains(scalar) || allowedPunctuation.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                continue
            }
            return false
        }
        return sawLetter
    }

    private static func preview(_ transcript: String) -> String {
        let compact = normalize(transcript).replacingOccurrences(of: "\n", with: " ")
        guard !compact.isEmpty else {
            return "空"
        }
        if compact.count <= 24 {
            return compact
        }
        let endIndex = compact.index(compact.startIndex, offsetBy: 24)
        return String(compact[..<endIndex]) + "…"
    }
}

enum DashScopeEndpointResolver {
    static func generationURL(baseURL: URL) -> URL {
        let normalized = baseURL.absoluteURL
        let rawPath = normalized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if rawPath.hasSuffix("api/v1/services/aigc/multimodal-generation/generation") {
            return normalized
        }

        var url = normalized
        if rawPath.hasSuffix("api/v1") {
            url.appendPathComponent("services")
            url.appendPathComponent("aigc")
            url.appendPathComponent("multimodal-generation")
            url.appendPathComponent("generation")
            return url
        }

        url.appendPathComponent("api")
        url.appendPathComponent("v1")
        url.appendPathComponent("services")
        url.appendPathComponent("aigc")
        url.appendPathComponent("multimodal-generation")
        url.appendPathComponent("generation")
        return url
    }
}
