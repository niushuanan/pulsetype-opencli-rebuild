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
                    subtitle: homeInstructionText
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
                    Picker("", selection: $controlCenterState.historyFilter) {
                        ForEach(LocalHistoryFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize(horizontal: true, vertical: false)

                    Spacer()

                    Button("清空历史", role: .destructive) {
                        showClearHistoryConfirmation = true
                    }
                    .controlCenterSecondaryActionButton()
                    .disabled(localHistoryStore.entries.isEmpty)
                }

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
                pageTitleText("设置", subtitle: "这里只保留快捷键、ASR 和文字处理模型。")
                hotkeySection
                providerSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PulseUI.Spacing.pageHorizontal)
            .padding(.vertical, PulseUI.Spacing.pageVertical)
        }
        .onAppear {
            hotkeyStateStore.refresh()
        }
    }

    private var metricsGrid: some View {
        LazyVGrid(columns: homeMetricColumns, spacing: 12) {
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

    private var homeMetricColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 12, alignment: .top)]
    }

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("快捷键", subtitle: hotkeySectionSubtitle)

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

    private var homeInstructionText: String {
        switch hotkeyStateStore.wakeTriggerMode {
        case .modifierTap:
            return "轻点 \(hotkeyStateStore.wakeModifier.displayName) 开始或停止；按住说话，松开后会自动结束并继续处理。"
        case .shortcut:
            return "按 \(hotkeyStateStore.wakeShortcutText) 开始或停止，ASR 识别后由文字模型整理并写入当前应用。"
        }
    }

    private var hotkeySectionSubtitle: String {
        switch hotkeyStateStore.wakeTriggerMode {
        case .modifierTap:
            return "轻点开始或停止；按住说话，松开后自动结束。取消仍然是 Esc。"
        case .shortcut:
            return "只保留开始/停止听写和取消会话。"
        }
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("模型设置", subtitle: "接口地址、模型名和密钥都在这里。")
            modelEditor(
                title: "语音识别 ASR",
                subtitle: "按接口地址自动适配 OpenAI compatible 与 Qwen ASR。",
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

            VStack(alignment: .leading, spacing: 14) {
                modelEditor(
                    title: "文字处理模型",
                    subtitle: "按接口地址自动适配 OpenAI、Anthropic 与其他 compatible gateway。",
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

                VStack(alignment: .leading, spacing: 8) {
                    Text("文字处理提示词")
                        .font(PulseUI.Typography.bodyStrong)
                    Text("这里改完后，下一次文字整理会直接用新提示词。")
                        .font(PulseUI.Typography.caption)
                        .pulseSecondaryText()

                    TextEditor(text: $providerSettingsStore.textProcessingPrompt)
                        .font(PulseUI.Typography.body)
                        .frame(minHeight: 124)
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
                        Button("恢复默认提示词") {
                            providerSettingsStore.textProcessingPrompt = ProviderSettingsStore.defaultTextProcessingPrompt
                            showToast("默认提示词已恢复。")
                        }
                        .controlCenterSecondaryActionButton()
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding(16)
        .controlCenterSectionGroup()
    }

    private func modelEditor(
        title: String,
        subtitle: String,
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
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(PulseUI.Typography.sectionTitle)
                Text(subtitle)
                    .font(PulseUI.Typography.caption)
                    .pulseSecondaryText()
            }

            TextField("Base URL", text: baseURL)
                .textFieldStyle(.roundedBorder)

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
            Text("完成一次听写后，ASR 原文、整理后的成稿和写入目标会显示在这里。")
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
