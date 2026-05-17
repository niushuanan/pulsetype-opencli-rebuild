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
            VStack(alignment: .leading, spacing: 18) {
                pageTitleText("设置", subtitle: "只保留快捷键、模型设置和自定义提示词。")
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
                title: "历史对话时长",
                value: HomeStatsFormatter.durationText(controlCenterState.homeStatsSnapshot.totalDialogueDurationSeconds),
                subtitle: "仅统计成功听写"
            )
            HomeMetricCard(
                title: "历史输入字数",
                value: HomeStatsFormatter.integerText(controlCenterState.homeStatsSnapshot.totalInputCharacters),
                subtitle: "累计写入字符"
            )
            HomeMetricCard(
                title: "平均速度",
                value: HomeStatsFormatter.speedText(snapshot: controlCenterState.homeStatsSnapshot),
                subtitle: "字/分钟（真实时长）"
            )
            HomeMetricCard(
                title: "总计节省时间",
                value: HomeStatsFormatter.durationText(controlCenterState.homeStatsSnapshot.savedTypingSeconds),
                subtitle: "相对打字效率估算"
            )
        }
    }

    private var homeMetricColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 12, alignment: .top)]
    }

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("快捷键")
                .font(PulseUI.Typography.sectionTitle)

            Picker("开始方式", selection: wakeTriggerModeBinding) {
                ForEach(HotkeyTriggerMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)

            if hotkeyStateStore.wakeTriggerMode == .modifierTap {
                HStack(spacing: 10) {
                    Text("单键")
                        .font(PulseUI.Typography.captionStrong)
                    Picker("单键", selection: wakeModifierBinding) {
                        ForEach(HotkeyModifier.allCases) { modifier in
                            Text(modifier.displayName).tag(modifier)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180, alignment: .leading)
                    .pickerStyle(.menu)
                }
            } else {
                HStack {
                    Text("组合键")
                        .font(PulseUI.Typography.captionStrong)
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

            Text(hotkeySectionSubtitle)
                .font(PulseUI.Typography.caption)
                .pulseSecondaryText()
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
            Text("模型设置")
                .font(PulseUI.Typography.sectionTitle)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 360), spacing: 12, alignment: .top)],
                spacing: 12
            ) {
                modelEditor(
                    title: "语音识别 ASR",
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
                modelEditor(
                    title: "文字处理模型",
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

            VStack(alignment: .leading, spacing: 10) {
                Text("自定义提示词")
                    .font(PulseUI.Typography.sectionTitle)
                Text("这里修改后，下一次文字整理会直接生效。")
                    .font(PulseUI.Typography.caption)
                    .pulseSecondaryText()

                TextEditor(text: $providerSettingsStore.textProcessingPrompt)
                    .font(PulseUI.Typography.body)
                    .frame(minHeight: 160)
                    .scrollContentBackground(.hidden)
                    .padding(10)
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
            .padding(16)
            .controlCenterSectionGroup()
        }
    }

    private func modelEditor(
        title: String,
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
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(PulseUI.Typography.bodyStrong)

            TextField("接口地址（Base URL）", text: baseURL)
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

            Button(isTesting ? "测试中" : "测试连接") {
                testAction()
            }
            .controlCenterPrimaryActionButton()
            .disabled(isTesting || validationMessage != nil)

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(PulseUI.Typography.caption)
                    .foregroundStyle(PulseUI.ColorTokens.warning)
            }

            if let latestResult {
                connectionResultCompactView(latestResult)
            }

            if credentialState == .saved {
                Text("密钥已保存")
                    .font(PulseUI.Typography.caption)
                    .foregroundStyle(PulseUI.ColorTokens.success)
            }
        }
        .padding(14)
        .controlCenterSectionGroup(cornerRadius: 12)
    }

    private func connectionResultCompactView(_ result: ConnectionTestResult) -> some View {
        HStack(spacing: 6) {
            Label(
                result.message,
                systemImage: result.status == .success ? "checkmark.circle.fill" : "xmark.octagon.fill"
            )
            .font(PulseUI.Typography.caption)
            .foregroundStyle(result.status == .success ? PulseUI.ColorTokens.success : PulseUI.ColorTokens.danger)
        }
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
