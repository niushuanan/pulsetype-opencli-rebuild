import Combine
import Foundation

@MainActor
final class ProviderSettingsStore: ObservableObject {
    enum CredentialState: Equatable {
        case unknown
        case missing
        case saving
        case saved
        case inaccessible
        case failed(OSStatus?)
    }

    @Published var asrConfig: ASRConfig {
        didSet {
            persistASRConfig()
            if asrConfig != oldValue {
                clearASRTestResult()
            }
        }
    }

    @Published var textConfig: TextConfig {
        didSet {
            persistTextConfig()
            if textConfig != oldValue {
                clearTextTestResult()
            }
        }
    }

    @Published var textProcessingPrompt: String {
        didSet {
            persistTextProcessingPrompt()
        }
    }

    @Published var asrAPIKeyDraft: String = ""
    @Published var textAPIKeyDraft: String = ""

    @Published private(set) var asrCredentialState: CredentialState = .unknown
    @Published private(set) var textCredentialState: CredentialState = .unknown
    @Published private(set) var asrFeedbackMessage: String?
    @Published private(set) var textFeedbackMessage: String?
    @Published private(set) var latestASRTestResult: ConnectionTestResult?
    @Published private(set) var latestTextTestResult: ConnectionTestResult?

    private let defaults: UserDefaults
    private let credentialStore: ProviderCredentialStore
    private let defaultsASRConfigKey = "providers.asr.config.v2"
    private let defaultsTextConfigKey = "providers.text.config.v2"
    private let defaultsTextPromptKey = "providers.text.prompt.v1"
    private let defaultsLatestASRTestResultKey = "providers.asr.test.result.v1"
    private let defaultsLatestTextTestResultKey = "providers.text.test.result.v1"

    init(
        defaults: UserDefaults = .standard,
        credentialStore: ProviderCredentialStore
    ) {
        self.defaults = defaults
        self.credentialStore = credentialStore
        self.asrConfig = Self.sanitizeASRConfig(
            Self.decodeASRConfig(from: defaults.data(forKey: defaultsASRConfigKey)) ?? ASRConfig()
        )
        self.textConfig = Self.sanitizeTextConfig(
            Self.decodeTextConfig(from: defaults.data(forKey: defaultsTextConfigKey)) ?? TextConfig()
        )
        self.textProcessingPrompt = Self.decodeTextProcessingPrompt(
            from: defaults.string(forKey: defaultsTextPromptKey)
        )
        self.latestASRTestResult = Self.decodeConnectionTestResult(
            from: defaults.data(forKey: defaultsLatestASRTestResultKey)
        )
        self.latestTextTestResult = Self.decodeConnectionTestResult(
            from: defaults.data(forKey: defaultsLatestTextTestResultKey)
        )

        persistASRConfig()
        persistTextConfig()
        persistTextProcessingPrompt()
        refreshCredentialState(allowUserInteraction: false)
    }

    var feedbackMessage: String? {
        textFeedbackMessage ?? asrFeedbackMessage
    }

    var selectedTranscriptionProviderName: String {
        asrConfig.providerType.displayName
    }

    var selectedTextProcessingProviderName: String {
        textConfig.providerType.displayName
    }

    var selectedProviderName: String {
        selectedTranscriptionProviderName
    }

    var modelName: String {
        asrConfig.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var textProcessingModelName: String {
        textConfig.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var asrConfigurationValidationMessage: String? {
        ProviderConfigurationValidator.validationMessage(
            providerType: asrConfig.providerType,
            baseURLString: asrConfig.baseURLString,
            modelName: asrConfig.modelName
        )
    }

    var textConfigurationValidationMessage: String? {
        ProviderConfigurationValidator.validationMessage(
            providerType: textConfig.providerType,
            baseURLString: textConfig.baseURLString,
            modelName: textConfig.modelName
        )
    }

    var configurationValidationMessage: String? {
        asrConfigurationValidationMessage
    }

    var isConfigurationValid: Bool {
        asrConfigurationValidationMessage == nil
    }

    var isTextProcessingConfigurationValid: Bool {
        textConfigurationValidationMessage == nil
    }

    var configuration: SpeechProviderConfiguration {
        resolvedTranscriptionConfiguration() ?? fallbackTranscriptionConfiguration()
    }

    var textProcessingConfiguration: TextGenerationProviderConfiguration {
        resolvedTextProcessingConfiguration() ?? fallbackTextProcessingConfiguration()
    }

    var transcriptionConfiguration: SpeechProviderConfiguration? {
        resolvedTranscriptionConfiguration()
    }

    var credentialState: CredentialState {
        asrCredentialState
    }

    func refreshCredentialState(allowUserInteraction: Bool = false) {
        asrCredentialState = resolveCredentialState(
            keyRef: asrConfig.keyRef,
            roleName: "语音识别",
            allowUserInteraction: allowUserInteraction
        ) { [weak self] message in
            self?.asrFeedbackMessage = message
        }
        textCredentialState = resolveCredentialState(
            keyRef: textConfig.keyRef,
            roleName: "文字处理模型",
            allowUserInteraction: allowUserInteraction
        ) { [weak self] message in
            self?.textFeedbackMessage = message
        }
    }

    @discardableResult
    func saveASRAPIKeyDraft() -> Bool {
        saveAPIKey(
            draft: asrAPIKeyDraft,
            keyRef: asrConfig.keyRef,
            roleName: "语音识别",
            onSaving: { [weak self] in self?.asrCredentialState = .saving },
            onSuccess: { [weak self] in
                self?.asrAPIKeyDraft = ""
                self?.asrCredentialState = .saved
                self?.asrFeedbackMessage = "语音识别 API 密钥已保存。"
                self?.clearASRTestResult()
            },
            onFailure: { [weak self] state, message in
                self?.asrCredentialState = state
                self?.asrFeedbackMessage = message
            }
        )
    }

    @discardableResult
    func saveTextAPIKeyDraft() -> Bool {
        saveAPIKey(
            draft: textAPIKeyDraft,
            keyRef: textConfig.keyRef,
            roleName: "文字处理模型",
            onSaving: { [weak self] in self?.textCredentialState = .saving },
            onSuccess: { [weak self] in
                self?.textAPIKeyDraft = ""
                self?.textCredentialState = .saved
                self?.textFeedbackMessage = "文字处理模型 API 密钥已保存。"
                self?.clearTextTestResult()
            },
            onFailure: { [weak self] state, message in
                self?.textCredentialState = state
                self?.textFeedbackMessage = message
            }
        )
    }

    @discardableResult
    func clearASRAPIKey() -> Bool {
        clearAPIKey(
            keyRef: asrConfig.keyRef,
            roleName: "语音识别",
            onSuccess: { [weak self] in
                self?.asrCredentialState = .missing
                self?.asrFeedbackMessage = "语音识别 API 密钥已删除。"
                self?.clearASRTestResult()
            },
            onFailure: { [weak self] message in self?.asrFeedbackMessage = message }
        )
    }

    @discardableResult
    func clearTextAPIKey() -> Bool {
        clearAPIKey(
            keyRef: textConfig.keyRef,
            roleName: "文字处理模型",
            onSuccess: { [weak self] in
                self?.textCredentialState = .missing
                self?.textFeedbackMessage = "文字处理模型 API 密钥已删除。"
                self?.clearTextTestResult()
            },
            onFailure: { [weak self] message in self?.textFeedbackMessage = message }
        )
    }

    func loadAPIKeyForTranscriptionProvider() throws -> String? {
        try credentialStore.loadAPIKey(for: asrConfig.keyRef)
    }

    func loadAPIKeyForTextProcessing() throws -> String? {
        try credentialStore.loadAPIKey(for: textConfig.keyRef)
    }

    func loadAPIKeyForActiveProvider() throws -> String? {
        try loadAPIKeyForTranscriptionProvider()
    }

    func updateASRProviderType(_ type: ProviderType) {
        guard type.supportsTranscription else {
            return
        }
        var updated = asrConfig
        updated.providerType = type
        updated.baseURLString = type.recommendedBaseURLString
        updated.modelName = type.defaultTranscriptionModelName
        asrConfig = updated
    }

    func updateTextProviderType(_ type: ProviderType) {
        guard type.supportsTextProcessing else {
            return
        }
        var updated = textConfig
        updated.providerType = type
        updated.baseURLString = type.recommendedBaseURLString
        updated.modelName = type.defaultTextProcessingModelName
        textConfig = updated
    }

    func updateASRBaseURL(_ value: String) {
        asrConfig.baseURLString = value
        asrConfig.providerType = Self.inferredASRProviderType(from: value)
    }

    func updateTextBaseURL(_ value: String) {
        textConfig.baseURLString = value
        textConfig.providerType = Self.inferredTextProviderType(from: value)
    }

    func updateASRModel(_ value: String) {
        asrConfig.modelName = value
    }

    func updateTextModel(_ value: String) {
        textConfig.modelName = value
    }

    func testASRConnection() async -> ConnectionTestResult {
        let tester = ASRConnectionTester(credentialStore: credentialStore)
        let result = await tester.test(config: asrConfig)
        recordASRTestResult(result)
        return result
    }

    func testTextConnection() async -> ConnectionTestResult {
        let tester = TextConnectionTester(credentialStore: credentialStore)
        let result = await tester.test(config: textConfig)
        recordTextTestResult(result)
        return result
    }

    func recordASRTestResult(_ result: ConnectionTestResult) {
        latestASRTestResult = result
        persistLatestASRTestResult()
    }

    func recordTextTestResult(_ result: ConnectionTestResult) {
        latestTextTestResult = result
        persistLatestTextTestResult()
    }

    private func resolvedTranscriptionConfiguration() -> SpeechProviderConfiguration? {
        guard asrConfigurationValidationMessage == nil else {
            return nil
        }
        guard let baseURL = ProviderConfigurationValidator.resolvedBaseURL(
            providerType: asrConfig.providerType,
            baseURLString: asrConfig.baseURLString
        ) else {
            return nil
        }
        return SpeechProviderConfiguration(
            profileID: asrConfig.keyRef,
            providerType: asrConfig.providerType,
            providerName: asrConfig.providerType.displayName,
            modelName: modelName,
            baseURL: baseURL
        )
    }

    private func resolvedTextProcessingConfiguration() -> TextGenerationProviderConfiguration? {
        guard textConfigurationValidationMessage == nil else {
            return nil
        }
        guard let baseURL = ProviderConfigurationValidator.resolvedBaseURL(
            providerType: textConfig.providerType,
            baseURLString: textConfig.baseURLString
        ) else {
            return nil
        }
        return TextGenerationProviderConfiguration(
            profileID: textConfig.keyRef,
            providerType: textConfig.providerType,
            providerName: textConfig.providerType.displayName,
            modelName: textProcessingModelName,
            baseURL: baseURL
        )
    }

    private func fallbackTranscriptionConfiguration() -> SpeechProviderConfiguration {
        SpeechProviderConfiguration(
            profileID: asrConfig.keyRef,
            providerType: asrConfig.providerType,
            providerName: asrConfig.providerType.displayName,
            modelName: asrConfig.providerType.defaultTranscriptionModelName,
            baseURL: asrConfig.providerType.fixedBaseURL ?? URL(string: "https://api.openai.com")!
        )
    }

    private func fallbackTextProcessingConfiguration() -> TextGenerationProviderConfiguration {
        TextGenerationProviderConfiguration(
            profileID: textConfig.keyRef,
            providerType: textConfig.providerType,
            providerName: textConfig.providerType.displayName,
            modelName: textConfig.providerType.defaultTextProcessingModelName,
            baseURL: URL(string: textConfig.providerType.recommendedBaseURLString) ?? URL(string: "https://api.deepseek.com")!
        )
    }

    private func persistASRConfig() {
        if let data = try? JSONEncoder().encode(asrConfig) {
            defaults.set(data, forKey: defaultsASRConfigKey)
        }
    }

    private func persistTextConfig() {
        if let data = try? JSONEncoder().encode(textConfig) {
            defaults.set(data, forKey: defaultsTextConfigKey)
        }
    }

    private func persistTextProcessingPrompt() {
        defaults.set(
            Self.normalizedPrompt(textProcessingPrompt),
            forKey: defaultsTextPromptKey
        )
    }

    private func persistLatestASRTestResult() {
        guard let latestASRTestResult else {
            defaults.removeObject(forKey: defaultsLatestASRTestResultKey)
            return
        }
        if let data = try? JSONEncoder().encode(latestASRTestResult) {
            defaults.set(data, forKey: defaultsLatestASRTestResultKey)
        }
    }

    private func persistLatestTextTestResult() {
        guard let latestTextTestResult else {
            defaults.removeObject(forKey: defaultsLatestTextTestResultKey)
            return
        }
        if let data = try? JSONEncoder().encode(latestTextTestResult) {
            defaults.set(data, forKey: defaultsLatestTextTestResultKey)
        }
    }

    private func clearASRTestResult() {
        guard latestASRTestResult != nil else {
            return
        }
        latestASRTestResult = nil
        persistLatestASRTestResult()
    }

    private func clearTextTestResult() {
        guard latestTextTestResult != nil else {
            return
        }
        latestTextTestResult = nil
        persistLatestTextTestResult()
    }

    private func saveAPIKey(
        draft: String,
        keyRef: String,
        roleName: String,
        onSaving: () -> Void = {},
        onSuccess: () -> Void,
        onFailure: (CredentialState, String) -> Void
    ) -> Bool {
        let normalized = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            onFailure(.missing, "\(roleName) API 密钥不能为空。")
            return false
        }

        guard normalized.count >= 12 else {
            onFailure(.failed(nil), "\(roleName) API 密钥长度看起来太短。")
            return false
        }

        do {
            onSaving()
            try credentialStore.saveAPIKey(normalized, for: keyRef)
            let readBack = (try credentialStore.loadAPIKey(for: keyRef) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard readBack == normalized else {
                onFailure(.failed(nil), "\(roleName) API 密钥保存后校验失败，请重试。")
                return false
            }
            onSuccess()
            return true
        } catch ProviderCredentialStoreError.interactionRequired {
            onFailure(.inaccessible, "当前密钥存储不可直接访问，请删除后重新保存。")
            return false
        } catch ProviderCredentialStoreError.invalidCredentialEncoding {
            onFailure(.failed(nil), "已保存的 \(roleName) API 密钥无法解析，请删除后重新保存。")
            return false
        } catch let ProviderCredentialStoreError.unexpectedStatus(status) {
            onFailure(.failed(status), "无法保存 \(roleName) API 密钥（OSStatus \(status)）。")
            return false
        } catch {
            onFailure(.failed(nil), "无法保存 \(roleName) API 密钥：\(error.localizedDescription)")
            return false
        }
    }

    private func clearAPIKey(
        keyRef: String,
        roleName: String,
        onSuccess: () -> Void,
        onFailure: (String) -> Void
    ) -> Bool {
        do {
            try credentialStore.deleteAPIKey(for: keyRef)
            onSuccess()
            return true
        } catch {
            onFailure("无法删除 \(roleName) API 密钥。")
            return false
        }
    }

    private func resolveCredentialState(
        keyRef: String,
        roleName: String,
        allowUserInteraction: Bool,
        onFeedback: (String?) -> Void
    ) -> CredentialState {
        do {
            let contains = try credentialStore.containsAPIKey(
                for: keyRef,
                allowUserInteraction: allowUserInteraction
            )
            onFeedback(nil)
            return contains ? .saved : .missing
        } catch let error as ProviderCredentialStoreError {
            switch error {
            case .interactionRequired:
                onFeedback("当前密钥存储不可直接访问，请在 App 内重新保存一次密钥。")
                return .inaccessible
            case let .unexpectedStatus(status):
                onFeedback("读取\(roleName) API 密钥失败（OSStatus \(status)）。")
                return .failed(status)
            case .invalidCredentialEncoding:
                onFeedback("已保存的\(roleName) API 密钥无法解析，请删除后重新保存。")
                return .failed(nil)
            }
        } catch {
            onFeedback("读取\(roleName) API 密钥失败：\(error.localizedDescription)")
            return .failed(nil)
        }
    }

    private static func decodeASRConfig(from data: Data?) -> ASRConfig? {
        guard let data else {
            return nil
        }
        return try? JSONDecoder().decode(ASRConfig.self, from: data)
    }

    private static func decodeTextConfig(from data: Data?) -> TextConfig? {
        guard let data else {
            return nil
        }
        return try? JSONDecoder().decode(TextConfig.self, from: data)
    }

    private static func decodeTextProcessingPrompt(from value: String?) -> String {
        let normalized = normalizedPrompt(value ?? "")
        return normalized.isEmpty ? defaultTextProcessingPrompt : normalized
    }

    private static func decodeConnectionTestResult(from data: Data?) -> ConnectionTestResult? {
        guard let data else {
            return nil
        }
        return try? JSONDecoder().decode(ConnectionTestResult.self, from: data)
    }

    private static func sanitizeASRConfig(_ config: ASRConfig) -> ASRConfig {
        var sanitized = config
        sanitized.providerType = inferredASRProviderType(from: sanitized.baseURLString)
        sanitized.modelName = sanitized.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.modelName.isEmpty {
            sanitized.modelName = sanitized.providerType.defaultTranscriptionModelName
        }
        sanitized.baseURLString = sanitized.baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.baseURLString.isEmpty {
            sanitized.baseURLString = sanitized.providerType.recommendedBaseURLString
        }
        if sanitized.keyRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sanitized.keyRef = defaultASRCredentialKeyRef
        }
        return sanitized
    }

    private static func sanitizeTextConfig(_ config: TextConfig) -> TextConfig {
        var sanitized = config
        sanitized.providerType = inferredTextProviderType(from: sanitized.baseURLString)
        sanitized.modelName = sanitized.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.modelName.isEmpty {
            sanitized.modelName = sanitized.providerType.defaultTextProcessingModelName
        }
        sanitized.baseURLString = sanitized.baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.baseURLString.isEmpty {
            sanitized.baseURLString = sanitized.providerType.recommendedBaseURLString
        }
        if sanitized.keyRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sanitized.keyRef = defaultTextCredentialKeyRef
        }
        return sanitized
    }

    private static func inferredASRProviderType(from baseURLString: String) -> ProviderType {
        let host = normalizedHost(from: baseURLString)
        if host.contains("dashscope.aliyuncs.com") {
            return .dashScopeQwenASR
        }
        if host.contains("api.openai.com") {
            return .openAI
        }
        return .openAICompatible
    }

    private static func inferredTextProviderType(from baseURLString: String) -> ProviderType {
        let host = normalizedHost(from: baseURLString)
        if host.contains("anthropic.com") {
            return .anthropic
        }
        if host.contains("api.openai.com") {
            return .openAI
        }
        return .openAICompatible
    }

    private static func normalizedHost(from baseURLString: String) -> String {
        let normalized = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: normalized) else {
            return ""
        }
        return url.host?.lowercased() ?? ""
    }

    private static func normalizedPrompt(_ prompt: String) -> String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let defaultTextProcessingPrompt = """
请把 ASR 原文整理成可以直接写入输入框的简体中文成稿：
1. 删掉口头禅、重复词和明显识别噪声。
2. 修正明显错别字，补齐标点和必要分段。
3. 不扩写，不编造，不改变事实和语气。
4. 专有名词、数字、时间、英文、代码、文件名尽量保留原样。
5. 只输出最终文本，不要解释。
"""
}
