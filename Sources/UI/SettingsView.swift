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
    @AppStorage(AgentCapabilitySettings.musicControlEnabledKey) private var isAgentMusicControlEnabled = true

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
        case .agent:
            agentPage
        case .settings:
            settingsPage
        }
    }

    private var homePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                pageTitleText(
                    "首页",
                    subtitle: "单键开口即写，长按可触发 Agent 音乐执行，语音转写与动作结果都能快速回传。"
                )
                homeProductIntroCard
                metricsGrid
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PulseUI.Spacing.pageHorizontal)
            .padding(.vertical, PulseUI.Spacing.pageVertical)
        }
    }

    private var homeProductIntroCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("核心特点")
                .font(PulseUI.Typography.sectionTitle)

            Label("单键开始/结束说话：轻点触发，按住说话，松开后自动结束。", systemImage: "keyboard")
                .font(PulseUI.Typography.body)
            Label("长按 Agent 键：直接触发 Music 控制，支持播放、暂停、继续与切歌。", systemImage: "music.note")
                .font(PulseUI.Typography.body)
            Label("ASR + 文本整理双模型：先转写，再把口述整理成可直接发送的成稿。", systemImage: "waveform.and.magnifyingglass")
                .font(PulseUI.Typography.body)
            Label("可切换模型与接口：ASR 和文本处理都能单独配置 Base URL、模型名、密钥。", systemImage: "slider.horizontal.3")
                .font(PulseUI.Typography.body)
            Label("历史与统计可追踪：听写和 Agent 调用结果都可复制、可删除。", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                .font(PulseUI.Typography.body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .pulseCard(cornerRadius: PulseUI.Radius.sectionGroup)
    }

    private var historyPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                pageTitleText("历史", subtitle: "这里会保存普通听写和 Agent 音乐调用结果。")
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
                                onCopyPrimary: { copyText(entry.outputText ?? entry.errorMessage ?? entry.inputText, toast: "结果已复制。") },
                                onCopyRaw: {
                                    let toast = entry.mode == .agent ? "Agent 指令已复制。" : "ASR 原文已复制。"
                                    copyText(entry.inputText, toast: toast)
                                },
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
            "确认清空听写与 Agent 历史？",
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

    private var agentPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                pageTitleText(
                    "Agent",
                    subtitle: "长按快捷键触发。下面可以直接开关每个 Agent 功能。"
                )
                agentCapabilityCard
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PulseUI.Spacing.pageHorizontal)
            .padding(.vertical, PulseUI.Spacing.pageVertical)
        }
    }

    private var agentCapabilityCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("音乐控制")
                        .font(PulseUI.Typography.bodyStrong)
                    Text("播放、暂停、继续、上一首、下一首")
                        .font(PulseUI.Typography.caption)
                        .pulseSecondaryText()
                }
                Spacer()
                Toggle("音乐控制", isOn: $isAgentMusicControlEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel("音乐控制")
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
        }
        .controlCenterSectionGroup()
    }

    private var settingsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                pageTitleText("设置")
                hotkeySection
                providerSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PulseUI.Spacing.pageHorizontal)
            .padding(.vertical, PulseUI.Spacing.pageVertical)
        }
        .onAppear {
            enforceSingleKeyWakeMode()
            hotkeyStateStore.refresh()
        }
    }

    private var agentEntryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("当前入口", subtitle: "按住即可触发 Agent，松开后马上执行。")
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("触发按键")
                        .font(PulseUI.Typography.caption)
                        .pulseSecondaryText()
                    Text(agentTriggerDisplayText)
                        .font(PulseUI.Typography.bodyStrong)
                }
                Spacer()
                Button("去快捷键设置") {
                    controlCenterState.selectedSection = .settings
                }
                .controlCenterSecondaryActionButton()
            }
            Text("默认路径是音乐控制；后续会先判断你的意图，再自动调用对应能力。")
                .font(PulseUI.Typography.caption)
                .pulseSecondaryText()
        }
        .padding(16)
        .controlCenterSectionGroup()
    }

    private var agentCurrentCapabilityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("当前可用能力", subtitle: "先把这条链路做到最快、最稳。")
            Label("播放指定歌曲（从资料库里找）", systemImage: "play.circle")
                .font(PulseUI.Typography.body)
            Label("下一首 / 上一首（按资料库顺序）", systemImage: "forward.end")
                .font(PulseUI.Typography.body)
            Label("暂停 / 继续", systemImage: "pause.circle")
                .font(PulseUI.Typography.body)
            Label("Music 未打开时自动拉起", systemImage: "app.badge")
                .font(PulseUI.Typography.body)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(agentCommandExamples, id: \.self) { command in
                        agentCommandChip(command)
                    }
                }
            }
        }
        .padding(16)
        .controlCenterSectionGroup()
    }

    private var agentRecentRunsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("最近执行")
                    .font(PulseUI.Typography.sectionTitle)
                Text("只看 Agent 调用，方便快速复盘。")
                    .font(PulseUI.Typography.body)
                    .pulseSecondaryText()
            }

            HStack {
                Spacer()
                Button("查看全部") {
                    controlCenterState.historyFilter = .agent
                    controlCenterState.selectedSection = .history
                }
                .controlCenterSecondaryActionButton()
            }

            if agentRecentEntries.isEmpty {
                Text("还没有 Agent 调用记录。你可以先试一句：播放稻香。")
                    .font(PulseUI.Typography.caption)
                    .pulseSecondaryText()
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(agentRecentEntries) { entry in
                        agentRecentRunRow(entry)
                    }
                }
            }
        }
        .padding(16)
        .controlCenterSectionGroup()
    }

    private var agentRoadmapCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("后续能力", subtitle: "这块会持续加，但页面会保持简洁。")
            agentRoadmapItem(
                title: "智能意图判断",
                subtitle: "先判断你是要听歌、改系统，还是做别的任务。",
                status: "准备中"
            )
            agentRoadmapItem(
                title: "多能力工具箱",
                subtitle: "同一个入口，逐步扩展到更多高频场景。",
                status: "准备中"
            )
            agentRoadmapItem(
                title: "跨应用自动执行",
                subtitle: "一句话触发多步动作，减少手动点选。",
                status: "规划中"
            )
        }
        .padding(16)
        .controlCenterSectionGroup()
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
        VStack(alignment: .leading, spacing: 0) {
            Text("快捷键")
                .font(PulseUI.Typography.sectionTitle)
                .padding(.bottom, 10)

            HStack(spacing: 10) {
                Text("开始/结束说话")
                    .font(PulseUI.Typography.body)
                Spacer()
                Picker("开始/结束说话", selection: wakeModifierBinding) {
                    ForEach(HotkeyModifier.allCases) { modifier in
                        Text(modifier.displayName).tag(modifier)
                    }
                }
                .labelsHidden()
                .frame(width: 180, alignment: .trailing)
                .pickerStyle(.menu)
            }
            .padding(.vertical, 10)

            Divider()

            HStack(spacing: 10) {
                Text("开启Agent")
                    .font(PulseUI.Typography.body)
                Spacer()
                Picker("开启Agent", selection: agentModifierBinding) {
                    ForEach(HotkeyModifier.allCases) { modifier in
                        Text(modifier.displayName).tag(modifier)
                    }
                }
                .labelsHidden()
                .frame(width: 180, alignment: .trailing)
                .pickerStyle(.menu)
            }
            .padding(.top, 10)
            .padding(.bottom, 4)

            HStack {
                Spacer()
                Text("长按触发，松开后执行 Music 指令；可与开始/结束说话共用同一键位（轻点/长按自动区分）。")
                    .font(PulseUI.Typography.caption)
                    .pulseSecondaryText()
            }
            .padding(.bottom, 8)

            Divider()

            HStack {
                Text("退出输入")
                    .font(PulseUI.Typography.body)
                Spacer()
                fixedHotkeyValue("Esc")
            }
            .padding(.vertical, 10)

            if let conflict = hotkeyStateStore.conflictMessage {
                Divider()
                Label(conflict, systemImage: "exclamationmark.triangle.fill")
                    .font(PulseUI.Typography.caption)
                    .foregroundStyle(PulseUI.ColorTokens.warning)
                    .padding(.top, 10)
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
            Text("模型设置")
                .font(PulseUI.Typography.sectionTitle)

            VStack(alignment: .leading, spacing: 12) {
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
                    feedbackMessage: providerSettingsStore.asrFeedbackMessage,
                    validationMessage: providerSettingsStore.asrConfigurationValidationMessage,
                    latestResult: providerSettingsStore.latestASRTestResult,
                    isTesting: asrTesting,
                    saveAction: { _ = providerSettingsStore.saveASRAPIKeyDraft() },
                    clearAction: { _ = providerSettingsStore.clearASRAPIKey() },
                    testAction: testASRConnection
                )
                modelEditor(
                    title: "文字处理模型 / Agent 执行模型",
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
                    feedbackMessage: providerSettingsStore.textFeedbackMessage,
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
                Text("修改后下一次文字整理会直接生效。")
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
                .settingsBlueActionButton()
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
        feedbackMessage: String?,
        validationMessage: String?,
        latestResult: ConnectionTestResult?,
        isTesting: Bool,
        saveAction: @escaping () -> Void,
        clearAction: @escaping () -> Void,
        testAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(PulseUI.Typography.body)
                .padding(.bottom, 10)

            TextField("接口地址（Base URL）", text: baseURL)
                .textFieldStyle(.roundedBorder)
                .padding(.bottom, 10)

            TextField("模型名", text: modelName)
                .textFieldStyle(.roundedBorder)
                .padding(.bottom, 10)

            HStack(spacing: 8) {
                SecureField(apiKeyPlaceholder(for: credentialState), text: apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                Button("保存密钥") {
                    saveAction()
                }
                .settingsBlueActionButton()
                Button("删除密钥") {
                    clearAction()
                }
                .settingsBlueActionButton()
                Button(isTesting ? "测试中" : "测试连接") {
                    testAction()
                }
                .settingsBlueActionButton()
                .disabled(isTesting || validationMessage != nil)
            }
            .padding(.bottom, 10)
            .padding(.top, 2)

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(PulseUI.Typography.caption)
                    .foregroundStyle(PulseUI.ColorTokens.warning)
                    .padding(.bottom, 6)
            }

            if let latestResult {
                connectionResultCompactView(latestResult)
                    .padding(.bottom, 6)
            }

            if let feedbackMessage {
                Label(feedbackMessage, systemImage: feedbackIconName(for: credentialState))
                    .font(PulseUI.Typography.caption)
                    .foregroundStyle(feedbackColor(for: credentialState))
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
            .foregroundStyle(result.status == .success ? PulseUI.ColorTokens.textSecondary : PulseUI.ColorTokens.danger)
        }
    }

    private func feedbackIconName(for state: ProviderSettingsStore.CredentialState) -> String {
        switch state {
        case .failed, .inaccessible, .missing:
            return "exclamationmark.circle.fill"
        default:
            return "checkmark.circle.fill"
        }
    }

    private func feedbackColor(for state: ProviderSettingsStore.CredentialState) -> Color {
        switch state {
        case .failed, .inaccessible, .missing:
            return PulseUI.ColorTokens.danger
        default:
            return PulseUI.ColorTokens.textSecondary
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
            Label("当前还没有历史记录。", systemImage: "tray")
                .font(PulseUI.Typography.bodyStrong)
            Text("完成一次听写或 Agent 调用后，原始指令、执行结果和状态会显示在这里。")
                .font(PulseUI.Typography.caption)
                .pulseSecondaryText()
        }
        .padding(16)
        .controlCenterSectionGroup()
    }

    private var filteredHistoryEntries: [SessionHistoryEntry] {
        localHistoryStore.entries(matching: controlCenterState.historyFilter)
    }

    private var agentRecentEntries: [SessionHistoryEntry] {
        Array(localHistoryStore.entries(matching: .agent).prefix(5))
    }

    private var agentTriggerDisplayText: String {
        "\(hotkeyStateStore.agentModifier.displayName)（长按）"
    }

    private var agentCommandExamples: [String] {
        [
            "播放稻香",
            "下一首",
            "上一首",
            "暂停播放"
        ]
    }

    private func agentRecentRunRow(_ entry: SessionHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(PulseUI.Typography.caption)
                    .pulseSecondaryText()
                Spacer()
                Text(agentStatusText(entry.status))
                    .font(PulseUI.Typography.captionStrong)
                    .foregroundStyle(agentStatusColor(entry.status))
            }

            Text(agentRecentRunSummary(entry))
                .font(PulseUI.Typography.body)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("命令：\(entry.inputText)")
                .font(PulseUI.Typography.caption)
                .pulseSecondaryText()
                .lineLimit(1)
        }
        .padding(10)
        .controlCenterInsetPanel()
    }

    private func agentRecentRunSummary(_ entry: SessionHistoryEntry) -> String {
        if let output = entry.outputText?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
            return output
        }
        if let error = entry.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            return error
        }
        return "已执行，等待结果同步。"
    }

    private func agentStatusText(_ status: SessionHistoryStatus) -> String {
        switch status {
        case .success:
            return "成功"
        case .failed:
            return "失败"
        case .cancelled:
            return "已取消"
        }
    }

    private func agentStatusColor(_ status: SessionHistoryStatus) -> Color {
        switch status {
        case .success:
            return PulseUI.ColorTokens.success
        case .failed:
            return PulseUI.ColorTokens.danger
        case .cancelled:
            return PulseUI.ColorTokens.warning
        }
    }

    private func agentRoadmapItem(title: String, subtitle: String, status: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(PulseUI.Typography.bodyStrong)
                Text(subtitle)
                    .font(PulseUI.Typography.caption)
                    .pulseSecondaryText()
            }
            Spacer()
            Text(status)
                .font(PulseUI.Typography.captionStrong)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                )
        }
        .padding(10)
        .controlCenterInsetPanel()
    }

    private func agentCommandChip(_ text: String) -> some View {
        Text(text)
            .font(PulseUI.Typography.captionStrong)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.08))
            )
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
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

    private var agentModifierBinding: Binding<HotkeyModifier> {
        Binding(
            get: { hotkeyStateStore.agentModifier },
            set: { _ = hotkeyStateStore.setAgentModifier($0) }
        )
    }

    private func fixedHotkeyValue(_ text: String) -> some View {
        Text(text)
            .font(PulseUI.Typography.bodyStrong)
            .pulseSecondaryText()
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: PulseUI.Radius.compactCard, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: PulseUI.Radius.compactCard, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }

    private func enforceSingleKeyWakeMode() {
        if hotkeyStateStore.wakeTriggerMode != .modifierTap {
            _ = hotkeyStateStore.setTriggerMode(.modifierTap, for: .wakeSession)
        }
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

private extension View {
    @ViewBuilder
    func settingsBlueActionButton() -> some View {
        self
            .buttonStyle(SettingsSidebarSelectionButtonStyle())
    }
}

private struct SettingsSidebarSelectionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlActiveState) private var controlActiveState

    func makeBody(configuration: Configuration) -> some View {
        let isActive = controlActiveState == .key || controlActiveState == .active
        let fillColor: Color
        let textColor: Color

        if isEnabled {
            fillColor = Color(
                nsColor: isActive
                    ? .selectedContentBackgroundColor
                    : .unemphasizedSelectedContentBackgroundColor
            )
            textColor = Color(
                nsColor: isActive
                    ? .alternateSelectedControlTextColor
                    : .labelColor
            )
        } else {
            fillColor = Color(nsColor: .quaternaryLabelColor)
            textColor = Color(nsColor: .secondaryLabelColor)
        }

        return configuration.label
            .font(PulseUI.Typography.bodyStrong)
            .foregroundStyle(textColor)
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: PulseUI.Radius.compactCard, style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PulseUI.Radius.compactCard, style: .continuous)
                    .stroke(Color.black.opacity(isEnabled ? 0.06 : 0.03), lineWidth: 1)
            )
            .opacity(configuration.isPressed && isEnabled ? 0.90 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
