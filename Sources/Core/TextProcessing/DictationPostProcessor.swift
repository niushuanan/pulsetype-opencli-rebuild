import Foundation

struct DictationPostProcessRequest: Equatable {
    let transcript: String
    let focusContext: FocusedAppContext
    let appPrompt: String?
    let userSystemPrompt: String
}

struct DictationPostProcessResult: Equatable {
    let outputText: String
    let providerName: String
    let modelName: String
}

enum TextProcessingProviderError: LocalizedError {
    case generationFailed(description: String)
    case invalidGeneratedText

    var errorDescription: String? {
        switch self {
        case let .generationFailed(description):
            return "文本生成失败：\(description)"
        case .invalidGeneratedText:
            return "模型没有返回可用文本。"
        }
    }
}

struct TextGenerationRequest {
    let systemPrompt: String
    let userPrompt: String
    let temperature: Double
    let maxOutputTokens: Int?
}

struct TextGenerationResult: Equatable {
    let providerType: ProviderType
    let providerName: String
    let modelName: String
    let outputText: String
}

protocol StreamingTextGenerationProvider: TextGenerationProvider {
    func generateTextStream(
        request: TextGenerationRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> AsyncThrowingStream<String, Error>
}

protocol TextGenerationProvider: Sendable {
    var supportedProviderTypes: [ProviderType] { get }
    func generateText(
        request: TextGenerationRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> TextGenerationResult
}

protocol DictationPostProcessor {
    func process(
        request: DictationPostProcessRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> DictationPostProcessResult
}

protocol StreamingDictationPostProcessor: DictationPostProcessor {
    func processStreaming(
        request: DictationPostProcessRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String,
        onPartialText: @escaping @Sendable (String) async -> Void
    ) async throws -> DictationPostProcessResult
}

struct DictationPostProcessPromptTemplate: Equatable {
    let systemPrompt: String
    let userPrompt: String
}

struct DictationPostProcessPromptBuilder {
    func build(request: DictationPostProcessRequest) -> DictationPostProcessPromptTemplate {
        let appPrompt = request.appPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let userSystemPrompt = request.userSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        let systemPrompt = """
        你是 PulseType 的普通听写整理助手。你的任务是把 ASR 语音识别文本整理成可以直接写入输入框的最终文本。

        规则：
        1. 只输出最终文本，不要解释，不要加标题，不要加 Markdown 围栏。
        2. 修正 ASR 噪声、口误、重复字、明显错别字和标点。
        3. 保留原意、语气和信息量，不要擅自扩写事实。
        4. 如果用户说的是口语短句，就整理成自然短句；如果用户说的是较长内容，就按原意补好标点和段落。
        5. 遇到应用要求时优先遵守应用要求；遇到用户固定要求时在不违背原意的前提下遵守。

        当前应用：\(request.focusContext.appName)
        Bundle ID：\(request.focusContext.bundleID)

        应用要求：\(appPrompt.isEmpty ? "无" : appPrompt)
        用户固定要求：\(userSystemPrompt.isEmpty ? "无" : userSystemPrompt)
        """

        let userPrompt = """
        请整理下面这段 ASR 结果，并只返回最终要写入输入框的文本：

        <<<ASR_TEXT
        \(request.transcript)
        ASR_TEXT>>>
        """

        return DictationPostProcessPromptTemplate(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt
        )
    }
}

struct LLMDictationPostProcessor: DictationPostProcessor {
    private let generationProvider: any TextGenerationProvider
    private let promptBuilder: DictationPostProcessPromptBuilder

    init(
        generationProvider: any TextGenerationProvider = OpenAITextGenerationProvider(),
        promptBuilder: DictationPostProcessPromptBuilder = DictationPostProcessPromptBuilder()
    ) {
        self.generationProvider = generationProvider
        self.promptBuilder = promptBuilder
    }

    func process(
        request: DictationPostProcessRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> DictationPostProcessResult {
        let normalizedTranscript = request.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTranscript.isEmpty else {
            throw TextProcessingProviderError.invalidGeneratedText
        }

        let template = promptBuilder.build(
            request: DictationPostProcessRequest(
                transcript: normalizedTranscript,
                focusContext: request.focusContext,
                appPrompt: request.appPrompt,
                userSystemPrompt: request.userSystemPrompt
            )
        )

        let generation = try await generationProvider.generateText(
            request: TextGenerationRequest(
                systemPrompt: template.systemPrompt,
                userPrompt: template.userPrompt,
                temperature: 0.2,
                maxOutputTokens: Self.tokenBudget(for: normalizedTranscript)
            ),
            configuration: configuration,
            apiKey: apiKey
        )

        let output = generation.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            throw TextProcessingProviderError.invalidGeneratedText
        }

        return DictationPostProcessResult(
            outputText: output,
            providerName: generation.providerName,
            modelName: generation.modelName
        )
    }

    private static func tokenBudget(for transcript: String) -> Int {
        max(120, min(700, transcript.count * 3))
    }
}

extension LLMDictationPostProcessor: StreamingDictationPostProcessor {
    func processStreaming(
        request: DictationPostProcessRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String,
        onPartialText: @escaping @Sendable (String) async -> Void
    ) async throws -> DictationPostProcessResult {
        let normalizedTranscript = request.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTranscript.isEmpty else {
            throw TextProcessingProviderError.invalidGeneratedText
        }

        guard let streamingProvider = generationProvider as? any StreamingTextGenerationProvider else {
            return try await process(
                request: request,
                configuration: configuration,
                apiKey: apiKey
            )
        }

        let template = promptBuilder.build(
            request: DictationPostProcessRequest(
                transcript: normalizedTranscript,
                focusContext: request.focusContext,
                appPrompt: request.appPrompt,
                userSystemPrompt: request.userSystemPrompt
            )
        )

        let stream = try await streamingProvider.generateTextStream(
            request: TextGenerationRequest(
                systemPrompt: template.systemPrompt,
                userPrompt: template.userPrompt,
                temperature: 0.2,
                maxOutputTokens: LLMDictationPostProcessor.tokenBudget(for: normalizedTranscript)
            ),
            configuration: configuration,
            apiKey: apiKey
        )

        var latestOutput = ""
        for try await partialText in stream {
            let normalized = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                continue
            }
            latestOutput = normalized
            await onPartialText(normalized)
        }

        guard !latestOutput.isEmpty else {
            throw TextProcessingProviderError.invalidGeneratedText
        }

        return DictationPostProcessResult(
            outputText: latestOutput,
            providerName: configuration.providerName,
            modelName: configuration.modelName
        )
    }
}
