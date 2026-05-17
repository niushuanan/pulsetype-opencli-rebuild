import AppKit
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    let model: AppModel

    @ObservedObject private var controlCenterState: ControlCenterState
    @ObservedObject private var hotkeyStateStore: HotkeyStateStore
    @ObservedObject private var providerSettingsStore: ProviderSettingsStore
    @ObservedObject private var localHistoryStore: LocalHistoryStore
    @ObservedObject private var toastPresenter: ToastPresenter

    @State private var asrTesting = false
    @State private var textTesting = false
    @State private var showClearHistoryConfirmation = false
    @State private var appPromptDraft = ""
    @State private var appPromptTarget: FocusedAppContext?

    init(model: AppModel) {
        self.model = model
        _controlCenterState = ObservedObject(wrappedValue: model.controlCenterState)
        _hotkeyStateStore = ObservedObject(wrappedValue: model.hotkeyStateStore)
        _providerSettingsStore = ObservedObject(wrappedValue: model.providerSettingsStore)
        _localHistoryStore = ObservedObject(wrappedValue: model.localHistoryStore)
        _toastPresenter = ObservedObject(wrappedValue: model.toastPresenter)
    }

    var body: some View {
        NavigationSplitView {
            List(DesktopSection.allCases, selection: $controlCenterState.selectedSection) { section in
                Label(section.title, systemImage: section.symbolName)
                    .font(PulseUI.Typography.bodyStrong)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(.clear)
            .environment(\.defaultMinListRowHeight, 28)
            .navigationSplitViewColumnWidth(min: 188, ideal: 210, max: 230)
            .navigationTitle("PulseType")
        } detail: {
            ZStack {
                ControlCenterDetailBackground()
                    .ignoresSafeArea()

                selectedDetailPage
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                if let toast = toastPresenter.message {
                    VStack {
                        Spacer()
                        PulseToastView(text: toast.text)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .padding(.bottom, 20)
                    }
                    .padding(.horizontal, PulseUI.Spacing.pageHorizontal)
                    .animation(.spring(response: 0.28, dampingFraction: 0.86), value: toast.id)
                }
            }
        }
        .onReceive(hotkeyStateStore.$latestChangeMessage.compactMap { $0 }) { message in
            showToast(message)
            hotkeyStateStore.clearLatestChangeMessage()
        }
    }

    @ViewBuilder
    private var selectedDetailPage: some View {
        switch controlCenterState.selectedSection {
        case .home:
            homePage
        case .history:
            historyPage
        case .settings:
            settingsPage
        }
    }

    private var homePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                pageTitleText(
                    "语音输入概览",
                    subtitle: "按 \(hotkeyStateStore.wakeShortcutText) 开始或停止，ASR 识别后由 DeepSeek 整理并写入当前应用。"
                )
                metricsGrid
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PulseUI.Spacing.pageHorizontal)
            .padding(.vertical, PulseUI.Spacing.pageVertical)
        }
    }

    private var historyPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                pageTitleText("历史", subtitle: "这里只保存普通听写结果，旧的高级能力记录不会展示。")
                HStack(spacing: 10) {
                    Picker("筛选", selection: $controlCenterState.historyFilter) {
                        ForEach(LocalHistoryFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)

                    Spacer()

                    Button("清空历史", role: .destructive) {
                        showClearHistoryConfirmation = true
                    }
                    .controlCenterSecondaryActionButton()
                    .disabled(localHistoryStore.entries.isEmpty)
                }
                .padding(12)
                .controlCenterSectionGroup()

                if filteredHistoryEntries.isEmpty {
                    emptyHistoryCard
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(filteredHistoryEntries) { entry in
                            HistoryRowView(
                                entry: entry,
                                onCopyPrimary: { copyText(entry.outputText ?? entry.inputText, toast: "结果已复制。") },
                                onCopyRaw: { copyText(entry.inputText, toast: "ASR 原文已复制。") },
                                onDelete: {
                                    localHistoryStore.delete(entryID: entry.id)
                                    showToast("已删除一条历史。")
                                }
                            )
                            .padding(12)
                            .controlCenterListRow()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PulseUI.Spacing.pageHorizontal)
            .padding(.vertical, PulseUI.Spacing.pageVertical)
        }
        .confirmationDialog(
            "确认清空普通听写历史？",
            isPresented: $showClearHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) {
                localHistoryStore.clearAll()
                showToast("历史已清空。")
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var settingsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                pageTitleText("设置", subtitle: "ASR 和 DeepSeek 参数都在这里，旧的引擎页已经合并到设置。")
                hotkeySection
                providerSection
                appPromptSection
                dataSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PulseUI.Spacing.pageHorizontal)
            .padding(.vertical, PulseUI.Spacing.pageVertical)
        }
        .onAppear {
            hotkeyStateStore.refresh()
            refreshAppPromptDraft()
        }
    }

    private var metricsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            HomeMetricCard(
                title: "累计语音",
                value: HomeStatsFormatter.durationText(controlCenterState.homeStatsSnapshot.totalDialogueDurationSeconds),
                subtitle: "已完成写入的录音时长",
                symbolName: "waveform"
            )
            HomeMetricCard(
                title: "成稿字数",
                value: HomeStatsFormatter.integerText(controlCenterState.homeStatsSnapshot.totalInputCharacters),
                subtitle: "DeepSeek 处理后的最终文本",
                symbolName: "text.alignleft"
            )
            HomeMetricCard(
                title: "语音速度",
                value: HomeStatsFormatter.speedText(snapshot: controlCenterState.homeStatsSnapshot),
                subtitle: "按带时长的成功记录计算",
                symbolName: "speedometer"
            )
            HomeMetricCard(
                title: "少打键盘",
                value: HomeStatsFormatter.durationText(controlCenterState.homeStatsSnapshot.savedTypingSeconds),
                subtitle: "按中文手打 \(Int(LocalHistoryStore.manualTypingCharactersPerMinute)) 字/分估算",
                symbolName: "keyboard.chevron.compact.down"
            )
        }
    }

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("快捷键", subtitle: "只保留开始/停止听写和取消会话。")

            Picker("开始方式", selection: wakeTriggerModeBinding) {
                ForEach(HotkeyTriggerMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)

            if hotkeyStateStore.wakeTriggerMode == .modifierTap {
                Picker("单键", selection: wakeModifierBinding) {
                    ForEach(HotkeyModifier.allCases) { modifier in
                        Text(modifier.displayName).tag(modifier)
                    }
                }
                .pickerStyle(.menu)
            } else {
                HStack {
                    Text("组合键")
                    KeyboardShortcuts.Recorder("", name: .wakeSession)
                        .frame(width: 220)
                }
            }

            HStack {
                Text("取消会话")
                    .font(PulseUI.Typography.bodyStrong)
                Spacer()
                Text("Esc")
                    .font(PulseUI.Typography.monospacedMeta)
                    .pulseSecondaryText()
            }

            if let conflict = hotkeyStateStore.conflictMessage {
                Label(conflict, systemImage: "exclamationmark.triangle.fill")
                    .font(PulseUI.Typography.caption)
                    .foregroundStyle(PulseUI.ColorTokens.warning)
            }
        }
        .padding(16)
        .controlCenterSectionGroup()
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("ASR 与 DeepSeek", subtitle: "语音识别和文本整理都在这里配置。")
            providerEditor(
                title: "语音识别 ASR",
                providerTypes: ProviderType.allCases.filter(\.supportsTranscription),
                selectedProvider: asrProviderBinding,
                baseURL: Binding(
                    get: { providerSettingsStore.asrConfig.baseURLString },
                    set: { providerSettingsStore.updateASRBaseURL($0) }
                ),
                modelName: Binding(
                    get: { providerSettingsStore.asrConfig.modelName },
                    set: { providerSettingsStore.updateASRModel($0) }
                ),
                apiKeyDraft: $providerSettingsStore.asrAPIKeyDraft,
                credentialState: providerSettingsStore.asrCredentialState,
                validationMessage: providerSettingsStore.asrConfigurationValidationMessage,
                latestResult: providerSettingsStore.latestASRTestResult,
                isTesting: asrTesting,
                saveAction: { _ = providerSettingsStore.saveASRAPIKeyDraft() },
                clearAction: { _ = providerSettingsStore.clearASRAPIKey() },
                testAction: testASRConnection
            )

            Divider()

            providerEditor(
                title: "DeepSeek 文本整理",
                providerTypes: ProviderType.allCases.filter(\.supportsTextProcessing),
                selectedProvider: textProviderBinding,
                baseURL: Binding(
                    get: { providerSettingsStore.textConfig.baseURLString },
                    set: { providerSettingsStore.updateTextBaseURL($0) }
                ),
                modelName: Binding(
                    get: { providerSettingsStore.textConfig.modelName },
                    set: { providerSettingsStore.updateTextModel($0) }
                ),
                apiKeyDraft: $providerSettingsStore.textAPIKeyDraft,
                credentialState: providerSettingsStore.textCredentialState,
                validationMessage: providerSettingsStore.textConfigurationValidationMessage,
                latestResult: providerSettingsStore.latestTextTestResult,
                isTesting: textTesting,
                saveAction: { _ = providerSettingsStore.saveTextAPIKeyDraft() },
                clearAction: { _ = providerSettingsStore.clearTextAPIKey() },
                testAction: testTextConnection
            )
        }
        .padding(16)
        .controlCenterSectionGroup()
    }

    private var appPromptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("当前应用处理要求", subtitle: "可选。比如在微信里更口语，在邮件里更正式。")

            HStack {
                Text(appPromptTarget?.appName ?? "当前应用")
                    .font(PulseUI.Typography.bodyStrong)
                Spacer()
                Button("刷新当前应用") {
                    refreshAppPromptDraft()
                    showToast("已读取当前前台应用。")
                }
                .controlCenterSecondaryActionButton()
            }

            TextEditor(text: $appPromptDraft)
                .font(PulseUI.Typography.body)
                .frame(minHeight: 82)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: PulseUI.Radius.card, style: .continuous)
                        .fill(Color.white.opacity(0.45))
                        .overlay(
                            RoundedRectangle(cornerRadius: PulseUI.Radius.card, style: .continuous)
                                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                        )
                )

            HStack {
                Spacer()
                Button("保存要求") {
                    saveAppPromptDraft()
                }
                .controlCenterPrimaryActionButton()
                .disabled(appPromptTarget == nil)

                Button("清除") {
                    clearAppPromptDraft()
                }
                .controlCenterSecondaryActionButton()
                .disabled(appPromptTarget == nil)
            }
        }
        .padding(16)
        .controlCenterSectionGroup()
    }

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("数据", subtitle: "只保留普通听写历史、诊断日志和临时录音。")
            Button("清理本地使用数据", role: .destructive) {
                model.purgeAllUsageData()
                showToast("本地使用数据已清理。")
            }
            .controlCenterSecondaryActionButton()
        }
        .padding(16)
        .controlCenterSectionGroup()
    }

    private func providerEditor(
        title: String,
        providerTypes: [ProviderType],
        selectedProvider: Binding<ProviderType>,
        baseURL: Binding<String>,
        modelName: Binding<String>,
        apiKeyDraft: Binding<String>,
        credentialState: ProviderSettingsStore.CredentialState,
        validationMessage: String?,
        latestResult: ConnectionTestResult?,
        isTesting: Bool,
        saveAction: @escaping () -> Void,
        clearAction: @escaping () -> Void,
        testAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(PulseUI.Typography.sectionTitle)

            Picker("服务", selection: selectedProvider) {
                ForEach(providerTypes) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.menu)

            if selectedProvider.wrappedValue.allowsCustomBaseURL {
                TextField("Base URL", text: baseURL)
                    .textFieldStyle(.roundedBorder)
            } else {
                LabeledContent("Base URL") {
                    Text(selectedProvider.wrappedValue.recommendedBaseURLString)
                        .font(PulseUI.Typography.monospacedMeta)
                        .pulseSecondaryText()
                }
            }

            TextField("模型名", text: modelName)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                SecureField(apiKeyPlaceholder(for: credentialState), text: apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                Button("保存密钥") {
                    saveAction()
                }
                .controlCenterSecondaryActionButton()
                Button("删除密钥", role: .destructive) {
                    clearAction()
                }
                .controlCenterSecondaryActionButton()
            }

            HStack {
                credentialStateLabel(credentialState)
                Spacer()
                Button(isTesting ? "测试中" : "测试连接") {
                    testAction()
                }
                .controlCenterPrimaryActionButton()
                .disabled(isTesting || validationMessage != nil)
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(PulseUI.Typography.caption)
                    .foregroundStyle(PulseUI.ColorTokens.warning)
            }

            if let latestResult {
                connectionResultView(latestResult)
            }
        }
    }

    private func connectionResultView(_ result: ConnectionTestResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                result.message,
                systemImage: result.status == .success ? "checkmark.circle.fill" : "xmark.octagon.fill"
            )
            .font(PulseUI.Typography.captionStrong)
            .foregroundStyle(result.status == .success ? PulseUI.ColorTokens.success : PulseUI.ColorTokens.danger)

            Text(result.status == .success ? result.hint : ConnectionFailureAdvisor.suggestion(for: result))
                .font(PulseUI.Typography.caption)
                .pulseSecondaryText()
        }
        .padding(10)
        .controlCenterInsetPanel()
    }

    private func credentialStateLabel(_ state: ProviderSettingsStore.CredentialState) -> some View {
        let text: String
        let color: Color
        switch state {
        case .unknown:
            text = "密钥状态未知"
            color = PulseUI.ColorTokens.textSecondary
        case .missing:
            text = "未保存密钥"
            color = PulseUI.ColorTokens.warning
        case .saving:
            text = "正在保存"
            color = PulseUI.ColorTokens.warning
        case .saved:
            text = "密钥已保存"
            color = PulseUI.ColorTokens.success
        case .inaccessible:
            text = "密钥不可读取"
            color = PulseUI.ColorTokens.danger
        case .failed:
            text = "密钥状态异常"
            color = PulseUI.ColorTokens.danger
        }
        return Label(text, systemImage: "key")
            .font(PulseUI.Typography.caption)
            .foregroundStyle(color)
    }

    private func pageTitleText(_ title: String, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(PulseUI.Typography.pageTitle)
                .tracking(0.16)
                .pulsePrimaryText()
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(PulseUI.Typography.caption)
                    .pulseSecondaryText()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(PulseUI.Typography.sectionTitle)
            Text(subtitle)
                .font(PulseUI.Typography.body)
                .pulseSecondaryText()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyHistoryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("当前还没有普通听写历史。", systemImage: "tray")
                .font(PulseUI.Typography.bodyStrong)
            Text("完成一次听写后，ASR 原文、DeepSeek 结果和写入目标会显示在这里。")
                .font(PulseUI.Typography.caption)
                .pulseSecondaryText()
        }
        .padding(16)
        .controlCenterSectionGroup()
    }

    private var filteredHistoryEntries: [SessionHistoryEntry] {
        localHistoryStore.entries(matching: controlCenterState.historyFilter)
    }

    private var wakeTriggerModeBinding: Binding<HotkeyTriggerMode> {
        Binding(
            get: { hotkeyStateStore.wakeTriggerMode },
            set: { _ = hotkeyStateStore.setTriggerMode($0, for: .wakeSession) }
        )
    }

    private var wakeModifierBinding: Binding<HotkeyModifier> {
        Binding(
            get: { hotkeyStateStore.wakeModifier },
            set: { _ = hotkeyStateStore.setModifier($0, for: .wakeSession) }
        )
    }

    private var asrProviderBinding: Binding<ProviderType> {
        Binding(
            get: { providerSettingsStore.asrConfig.providerType },
            set: { providerSettingsStore.updateASRProviderType($0) }
        )
    }

    private var textProviderBinding: Binding<ProviderType> {
        Binding(
            get: { providerSettingsStore.textConfig.providerType },
            set: { providerSettingsStore.updateTextProviderType($0) }
        )
    }

    private func testASRConnection() {
        asrTesting = true
        Task {
            _ = await providerSettingsStore.testASRConnection()
            asrTesting = false
        }
    }

    private func testTextConnection() {
        textTesting = true
        Task {
            _ = await providerSettingsStore.testTextConnection()
            textTesting = false
        }
    }

    private func refreshAppPromptDraft() {
        let context = model.contextDetector.focusedAppContext()
        appPromptTarget = context
        appPromptDraft = model.appScenePolicyStore.policy(for: context).appPrompt
    }

    private func saveAppPromptDraft() {
        guard let appPromptTarget else {
            return
        }
        model.appScenePolicyStore.upsertPolicy(for: appPromptTarget, appPrompt: appPromptDraft)
        showToast("当前应用处理要求已保存。")
    }

    private func clearAppPromptDraft() {
        guard let appPromptTarget else {
            return
        }
        appPromptDraft = ""
        model.appScenePolicyStore.removePolicy(bundleID: appPromptTarget.bundleID)
        showToast("当前应用处理要求已清除。")
    }

    private func copyText(_ text: String, toast: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(normalized, forType: .string)
        showToast(toast)
    }

    private func showToast(_ text: String) {
        toastPresenter.show(text)
    }

    private func apiKeyPlaceholder(for state: ProviderSettingsStore.CredentialState) -> String {
        switch state {
        case .saved:
            return "已保存，输入新密钥可覆盖"
        default:
            return "API Key"
        }
    }
}
