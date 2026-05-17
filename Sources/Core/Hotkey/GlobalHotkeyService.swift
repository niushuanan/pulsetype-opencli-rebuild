import AppKit
import Combine
import Foundation
import KeyboardShortcuts

enum ModifierDoubleTapAction {
    case waitingSecondTap
    case trigger
}

struct ModifierDoubleTapStateMachine {
    let interval: TimeInterval
    private let intervalTolerance: TimeInterval = 0.000_001
    private(set) var firstTapAt: Date?

    mutating func registerTap(at date: Date) -> ModifierDoubleTapAction {
        if let firstTapAt, date.timeIntervalSince(firstTapAt) <= interval + intervalTolerance {
            self.firstTapAt = nil
            return .trigger
        }
        firstTapAt = date
        return .waitingSecondTap
    }

    mutating func clearIfExpired(at date: Date) -> Bool {
        guard let firstTapAt else {
            return false
        }
        guard date.timeIntervalSince(firstTapAt) >= interval - intervalTolerance else {
            return false
        }
        self.firstTapAt = nil
        return true
    }

    mutating func reset() {
        firstTapAt = nil
    }
}

@MainActor
final class GlobalHotkeyService {
    private struct ModifierTapState {
        var isPressed = false
        var pressedAt: Date?
        var sawForeignInput = false

        mutating func reset() {
            isPressed = false
            pressedAt = nil
            sawForeignInput = false
        }
    }

    private let interactionCoordinator: InteractionCoordinator
    private let hotkeyStateStore: HotkeyStateStore
    private var cancellables = Set<AnyCancellable>()
    private var hasActivated = false
    private var currentSessionPhase: SessionPhase = .idle
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var localKeyDownMonitor: Any?
    private var wakeTapState = ModifierTapState()
    private let tapInterval: TimeInterval = 0.7

    init(
        interactionCoordinator: InteractionCoordinator,
        hotkeyStateStore: HotkeyStateStore
    ) {
        self.interactionCoordinator = interactionCoordinator
        self.hotkeyStateStore = hotkeyStateStore
    }

    func activate() {
        guard !hasActivated else {
            return
        }
        hasActivated = true

        KeyboardShortcuts.onKeyUp(for: .wakeSession) { [weak self] in
            guard let self else {
                return
            }
            guard self.hotkeyStateStore.wakeTriggerMode == .shortcut else {
                return
            }
            self.interactionCoordinator.handleWakeInput()
        }

        KeyboardShortcuts.onKeyUp(for: .cancelSession) { [weak self] in
            self?.interactionCoordinator.handleCancelInput()
        }

        hotkeyStateStore.$lastUpdatedAt
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.refreshRuntimeState()
            }
            .store(in: &cancellables)

        installModifierMonitors()
        refreshRuntimeState()
    }

    func updateSessionPhase(_ phase: SessionPhase) {
        currentSessionPhase = phase
    }

    func refreshRuntimeState() {
        if hotkeyStateStore.wakeTriggerMode != .modifierTap {
            wakeTapState.reset()
        }
    }

    private func installModifierMonitors() {
        removeModifierMonitors()

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
        }

        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
            return event
        }

        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            Task { @MainActor in
                self?.registerForeignInput()
            }
        }

        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.registerForeignInput()
            }
            return event
        }
    }

    private func removeModifierMonitors() {
        if let globalFlagsMonitor {
            NSEvent.removeMonitor(globalFlagsMonitor)
            self.globalFlagsMonitor = nil
        }
        if let localFlagsMonitor {
            NSEvent.removeMonitor(localFlagsMonitor)
            self.localFlagsMonitor = nil
        }
        if let globalKeyDownMonitor {
            NSEvent.removeMonitor(globalKeyDownMonitor)
            self.globalKeyDownMonitor = nil
        }
        if let localKeyDownMonitor {
            NSEvent.removeMonitor(localKeyDownMonitor)
            self.localKeyDownMonitor = nil
        }
        wakeTapState.reset()
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard hotkeyStateStore.wakeTriggerMode == .modifierTap else {
            wakeTapState.reset()
            return
        }
        processModifierEvent(event, modifier: hotkeyStateStore.wakeModifier, state: &wakeTapState) { [weak self] in
            self?.interactionCoordinator.handleWakeInput()
        }
    }

    private func processModifierEvent(
        _ event: NSEvent,
        modifier: HotkeyModifier,
        state: inout ModifierTapState,
        action: @escaping () -> Void
    ) {
        guard HotkeyModifier.from(keyCode: event.keyCode) == modifier else {
            if state.isPressed, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                state.reset()
            }
            return
        }

        let isDown = event.modifierFlags.contains(modifier.modifierFlags)
        let now = Date()
        if isDown, !state.isPressed {
            state.isPressed = true
            state.pressedAt = now
            state.sawForeignInput = false
            return
        }

        if !isDown, state.isPressed {
            let duration = now.timeIntervalSince(state.pressedAt ?? now)
            let shouldTrigger = duration <= tapInterval && !state.sawForeignInput && shouldHandleWakeInput
            state.reset()
            if shouldTrigger {
                action()
            }
        }
    }

    private func registerForeignInput() {
        if wakeTapState.isPressed {
            wakeTapState.sawForeignInput = true
        }
    }

    private var shouldHandleWakeInput: Bool {
        switch currentSessionPhase {
        case .idle, .listening, .cancelled, .error:
            return true
        case .transcribing, .textProcessing, .inserting:
            return false
        }
    }
}
