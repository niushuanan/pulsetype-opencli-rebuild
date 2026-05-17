import AppKit
import Combine
import Foundation
import KeyboardShortcuts

enum HotkeyTriggerMode: String, CaseIterable, Identifiable {
    case shortcut
    case modifierTap

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .shortcut:
            return "组合键"
        case .modifierTap:
            return "单键触发"
        }
    }
}

enum HotkeyModifier: String, CaseIterable, Identifiable {
    case leftCommand
    case rightCommand
    case leftOption
    case rightOption
    case leftControl
    case rightControl
    case leftShift
    case rightShift

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .leftCommand:
            return "左 Command"
        case .rightCommand:
            return "右 Command"
        case .leftOption:
            return "左 Option"
        case .rightOption:
            return "右 Option"
        case .leftControl:
            return "左 Control"
        case .rightControl:
            return "右 Control"
        case .leftShift:
            return "左 Shift"
        case .rightShift:
            return "右 Shift"
        }
    }

    var modifierFlags: NSEvent.ModifierFlags {
        switch self {
        case .leftCommand, .rightCommand:
            return .command
        case .leftOption, .rightOption:
            return .option
        case .leftControl, .rightControl:
            return .control
        case .leftShift, .rightShift:
            return .shift
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .leftCommand:
            return 55
        case .rightCommand:
            return 54
        case .leftShift:
            return 56
        case .rightShift:
            return 60
        case .leftOption:
            return 58
        case .rightOption:
            return 61
        case .leftControl:
            return 59
        case .rightControl:
            return 62
        }
    }

    static func from(keyCode: UInt16) -> HotkeyModifier? {
        switch keyCode {
        case 55:
            return .leftCommand
        case 54:
            return .rightCommand
        case 56:
            return .leftShift
        case 60:
            return .rightShift
        case 58:
            return .leftOption
        case 61:
            return .rightOption
        case 59:
            return .leftControl
        case 62:
            return .rightControl
        default:
            return nil
        }
    }

    static func migrate(fromLegacyRawValue rawValue: String) -> HotkeyModifier? {
        switch rawValue {
        case "command":
            return .leftCommand
        case "option":
            return .leftOption
        case "control":
            return .leftControl
        case "shift":
            return .rightShift
        default:
            return nil
        }
    }
}

@MainActor
final class HotkeyStateStore: ObservableObject {
    private static let shortcutDidChangeNotification = Notification.Name("KeyboardShortcuts_shortcutByNameDidChange")

    @Published private(set) var wakeShortcutText: String
    @Published private(set) var cancelShortcutText: String
    @Published private(set) var hasConflict: Bool
    @Published private(set) var conflictMessage: String?
    @Published private(set) var wakeShortcutRegistered: Bool
    @Published private(set) var cancelShortcutRegistered: Bool
    @Published private(set) var lastUpdatedAt: Date
    @Published private(set) var latestChangeMessage: String?
    @Published private(set) var wakeTriggerMode: HotkeyTriggerMode
    @Published private(set) var cancelTriggerMode: HotkeyTriggerMode
    @Published private(set) var wakeModifier: HotkeyModifier
    @Published private(set) var cancelModifier: HotkeyModifier
    @Published private(set) var agentModifier: HotkeyModifier

    private let notificationCenter: NotificationCenter
    private let defaults: UserDefaults
    private let now: () -> Date
    private var cancellables = Set<AnyCancellable>()
    private var isApplyingFixedCancelShortcut = false

    private let wakeModeStorageKey = "hotkeys.wake.mode.v1"
    private let cancelModeStorageKey = "hotkeys.cancel.mode.v1"
    private let wakeModifierStorageKey = "hotkeys.wake.modifier.v1"
    private let cancelModifierStorageKey = "hotkeys.cancel.modifier.v1"
    private let agentModifierStorageKey = "hotkeys.agent.modifier.v1"
    private let fixedCancelShortcut = KeyboardShortcuts.Shortcut(.escape)

    init(
        notificationCenter: NotificationCenter = .default,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.notificationCenter = notificationCenter
        self.defaults = defaults
        self.now = now

        self.wakeTriggerMode = HotkeyTriggerMode(rawValue: defaults.string(forKey: wakeModeStorageKey) ?? "") ?? .modifierTap
        self.cancelTriggerMode = .shortcut
        self.wakeModifier = Self.loadModifier(defaults: defaults, key: wakeModifierStorageKey, fallback: .rightShift)
        self.cancelModifier = Self.loadModifier(defaults: defaults, key: cancelModifierStorageKey, fallback: .leftOption)
        self.agentModifier = Self.loadModifier(defaults: defaults, key: agentModifierStorageKey, fallback: .rightCommand)
        self.wakeShortcutText = "未设置"
        self.cancelShortcutText = "未设置"
        self.hasConflict = false
        self.conflictMessage = nil
        self.wakeShortcutRegistered = false
        self.cancelShortcutRegistered = false
        self.lastUpdatedAt = now()

        enforceFixedCancelShortcut()
        refresh()

        notificationCenter.publisher(for: Self.shortcutDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self else {
                    return
                }
                if
                    let name = notification.userInfo?["name"] as? KeyboardShortcuts.Name,
                    name != .wakeSession,
                    name != .cancelSession
                {
                    return
                }
                if self.isApplyingFixedCancelShortcut {
                    return
                }
                self.refresh()
            }
            .store(in: &cancellables)
    }

    @discardableResult
    func setTriggerMode(_ mode: HotkeyTriggerMode, for name: KeyboardShortcuts.Name) -> Bool {
        switch name {
        case .wakeSession:
            wakeTriggerMode = mode
            defaults.set(mode.rawValue, forKey: wakeModeStorageKey)
        case .cancelSession:
            _ = mode
            enforceFixedCancelShortcut()
        default:
            return false
        }
        refresh(changeMessage: "快捷键设置已更新。")
        return true
    }

    @discardableResult
    func setModifier(_ modifier: HotkeyModifier, for name: KeyboardShortcuts.Name) -> Bool {
        switch name {
        case .wakeSession:
            wakeModifier = modifier
            defaults.set(modifier.rawValue, forKey: wakeModifierStorageKey)
        case .cancelSession:
            cancelModifier = modifier
            defaults.set(modifier.rawValue, forKey: cancelModifierStorageKey)
        default:
            return false
        }
        refresh(changeMessage: "触发键已更新。")
        return true
    }

    @discardableResult
    func setAgentModifier(_ modifier: HotkeyModifier) -> Bool {
        agentModifier = modifier
        defaults.set(modifier.rawValue, forKey: agentModifierStorageKey)
        refresh(changeMessage: "Agent 触发键已更新。")
        return true
    }

    func refresh(changeMessage: String? = nil) {
        wakeShortcutRegistered = KeyboardShortcuts.getShortcut(for: .wakeSession) != nil
        cancelShortcutRegistered = KeyboardShortcuts.getShortcut(for: .cancelSession) != nil
        wakeShortcutText = resolvedWakeShortcutText()
        cancelShortcutText = "Esc"
        resolveConflict()
        if let changeMessage {
            latestChangeMessage = changeMessage
        }
        lastUpdatedAt = now()
    }

    func clearLatestChangeMessage() {
        latestChangeMessage = nil
    }

    private func resolvedWakeShortcutText() -> String {
        switch wakeTriggerMode {
        case .modifierTap:
            return wakeModifier.displayName
        case .shortcut:
            return KeyboardShortcuts.getShortcut(for: .wakeSession)?.description ?? "未设置"
        }
    }

    private func resolveConflict() {
        if wakeTriggerMode == .modifierTap, wakeModifier == agentModifier {
            hasConflict = true
            conflictMessage = "开始/结束说话 与 开启Agent 不能使用同一个修饰键。"
        } else if wakeTriggerMode == .modifierTap, cancelTriggerMode == .modifierTap, wakeModifier == cancelModifier {
            hasConflict = true
            conflictMessage = "开始键和取消键不能使用同一个修饰键。"
        } else {
            hasConflict = false
            conflictMessage = nil
        }
    }

    private func enforceFixedCancelShortcut() {
        cancelTriggerMode = .shortcut
        defaults.set(HotkeyTriggerMode.shortcut.rawValue, forKey: cancelModeStorageKey)
        isApplyingFixedCancelShortcut = true
        KeyboardShortcuts.setShortcut(fixedCancelShortcut, for: .cancelSession)
        isApplyingFixedCancelShortcut = false
    }

    private static func loadModifier(defaults: UserDefaults, key: String, fallback: HotkeyModifier) -> HotkeyModifier {
        if let raw = defaults.string(forKey: key) {
            if let modifier = HotkeyModifier(rawValue: raw) {
                return modifier
            }
            if let modifier = HotkeyModifier.migrate(fromLegacyRawValue: raw) {
                return modifier
            }
        }
        return fallback
    }
}
