import AppKit
import KeyboardShortcuts
import SwiftUI

struct MenuBarMenuView: View {
    let model: AppModel
    @ObservedObject private var permissionsCenter: PermissionsCenter
    @ObservedObject private var providerSettingsStore: ProviderSettingsStore
    @ObservedObject private var hotkeyStateStore: HotkeyStateStore

    @Environment(\.openWindow) private var openWindow

    init(model: AppModel) {
        self.model = model
        _permissionsCenter = ObservedObject(wrappedValue: model.permissionsCenter)
        _providerSettingsStore = ObservedObject(wrappedValue: model.providerSettingsStore)
        _hotkeyStateStore = ObservedObject(wrappedValue: model.hotkeyStateStore)
    }

    var body: some View {
        Text("当前状态：\(model.sessionStore.phase.title)")
            .font(PulseUI.Typography.captionStrong)
        Text(model.sessionStore.phase == .listening ? "正在听写" : "点击下面按钮开始语音输入")
            .font(PulseUI.Typography.caption)
            .pulseSecondaryText()

        if permissionsCenter.snapshot.hasBlockingIssue {
            Divider()
            Label("开始前需要麦克风权限。", systemImage: "exclamationmark.triangle.fill")
                .font(PulseUI.Typography.caption)
                .foregroundStyle(PulseUI.ColorTokens.warning)
            Button("打开隐私设置") {
                permissionsCenter.openSystemSettings(for: .microphone)
            }
        }

        Divider()

        Menu("诊断信息") {
            Text("通道：普通听写")
            Text("语音识别：\(providerSettingsStore.selectedTranscriptionProviderName)")
            Text("文本整理：\(providerSettingsStore.selectedTextProcessingProviderName)")
            Text("开始键：\(hotkeyStateStore.wakeShortcutText)")
            Text("取消键：Esc")
        }

        Divider()

        Button(primaryToggleTitle) {
            model.interactionCoordinator.handleWakeInput()
        }
        .disabled(!canToggleSession)
        .globalKeyboardShortcut(.wakeSession)

        Button("取消会话") {
            model.interactionCoordinator.handleCancelInput()
        }
        .disabled(!canCancelSession)
        .globalKeyboardShortcut(.cancelSession)

        Divider()

        Button("打开主界面") {
            openWindow(id: "control-center")
        }

        Button("退出 PulseType") {
            NSApplication.shared.terminate(nil)
        }
        .onAppear {
            permissionsCenter.refreshStatuses()
            hotkeyStateStore.refresh()
        }
    }

    private var canToggleSession: Bool {
        switch model.sessionStore.phase {
        case .idle, .cancelled, .error, .listening:
            return true
        case .transcribing, .textProcessing, .inserting:
            return false
        }
    }

    private var primaryToggleTitle: String {
        model.sessionStore.phase == .listening ? "停止并处理" : "开始听写"
    }

    private var canCancelSession: Bool {
        switch model.sessionStore.phase {
        case .listening, .transcribing, .textProcessing, .inserting:
            return true
        case .idle, .cancelled, .error:
            return false
        }
    }
}
