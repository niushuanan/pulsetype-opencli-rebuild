import AppKit
import Combine
import Foundation
import KeyboardShortcuts

enum WakeModifierPressAction {
    case none
    case tap
    case holdBegan
    case holdEnded
}

struct WakeModifierPressStateMachine {
    let holdInterval: TimeInterval
    let tapInterval: TimeInterval
    private let intervalTolerance: TimeInterval = 0.000_001
    private(set) var isPressed = false
    private(set) var pressedAt: Date?
    private(set) var sawForeignInput = false
    private(set) var holdTriggered = false

    mutating func beginPress(
        at date: Date,
        hasForeignInput: Bool
    ) {
        isPressed = true
        pressedAt = date
        sawForeignInput = hasForeignInput
        holdTriggered = false
    }

    mutating func registerForeignInput() {
        guard isPressed else {
            return
        }
        sawForeignInput = true
    }

    mutating func evaluateHold(at date: Date) -> WakeModifierPressAction {
        guard
            isPressed,
            !holdTriggered,
            !sawForeignInput,
            let pressedAt
        else {
            return .none
        }

        if date.timeIntervalSince(pressedAt) >= holdInterval - intervalTolerance {
            holdTriggered = true
            return .holdBegan
        }
        return .none
    }

    mutating func endPress(
        at date: Date,
        hasOtherModifierFamilies: Bool,
        sameFamilyStillPressed: Bool
    ) -> WakeModifierPressAction {
        guard isPressed else {
            return .none
        }

        defer { reset() }

        if holdTriggered {
            return .holdEnded
        }

        let duration = date.timeIntervalSince(pressedAt ?? date)
        let shouldTap = duration <= tapInterval + intervalTolerance
            && !sawForeignInput
            && !hasOtherModifierFamilies
            && !sameFamilyStillPressed
        return shouldTap ? .tap : .none
    }

    mutating func reset() {
        isPressed = false
        pressedAt = nil
        sawForeignInput = false
        holdTriggered = false
    }
}

@MainActor
final class GlobalHotkeyService {
    private let interactionCoordinator: InteractionCoordinator
    private let hotkeyStateStore: HotkeyStateStore
    private var cancellables = Set<AnyCancellable>()
    private var hasActivated = false
    private var currentSessionPhase: SessionPhase = .idle
    private var currentInputLane: InputLane = .directDictation
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var localKeyDownMonitor: Any?
    private var wakePressStateMachine = WakeModifierPressStateMachine(
        holdInterval: 0.18,
        tapInterval: 0.7
    )
    private var wakeHoldWorkItem: DispatchWorkItem?
    private var wakeHoldSessionActive = false
    private var agentPressStateMachine = WakeModifierPressStateMachine(
        holdInterval: 0.18,
        tapInterval: 0.7
    )
    private var agentHoldWorkItem: DispatchWorkItem?
    private var agentHoldSessionActive = false

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
            guard self.shouldHandleWakeTap else {
                return
            }
            self.interactionCoordinator.handleWakeInput()
        }

        KeyboardShortcuts.onKeyUp(for: .cancelSession) { [weak self] in
            guard let self else {
                return
            }
            guard self.shouldHandleCancelInput else {
                return
            }
            self.interactionCoordinator.handleCancelInput()
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
        if phase != .listening {
            wakeHoldSessionActive = false
            agentHoldSessionActive = false
        }
    }

    func updateInputLane(_ lane: InputLane) {
        currentInputLane = lane
    }

    func refreshRuntimeState() {
        if hotkeyStateStore.wakeTriggerMode != .modifierTap {
            clearWakeHoldCheck()
            wakePressStateMachine.reset()
            wakeHoldSessionActive = false
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
        clearWakeHoldCheck()
        clearAgentHoldCheck()
        wakePressStateMachine.reset()
        agentPressStateMachine.reset()
        wakeHoldSessionActive = false
        agentHoldSessionActive = false
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        if hotkeyStateStore.wakeTriggerMode == .modifierTap {
            processWakeModifierEvent(event)
        } else {
            clearWakeHoldCheck()
            wakePressStateMachine.reset()
            wakeHoldSessionActive = false
        }
        processAgentModifierEvent(event)
    }

    private func processWakeModifierEvent(_ event: NSEvent) {
        let modifier = hotkeyStateStore.wakeModifier
        let trackedFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let activeFlags = event.modifierFlags.intersection(trackedFlags)
        let isTargetKeyEvent = event.keyCode == modifier.keyCode
        let isFamilyPressed = activeFlags.contains(modifier.modifierFlags)
        let hasOtherModifierFamilies = !activeFlags.subtracting(modifier.modifierFlags).isEmpty

        if !isTargetKeyEvent, event.keyCode == 0 {
            let now = Date()
            if isFamilyPressed, !wakePressStateMachine.isPressed {
                wakePressStateMachine.beginPress(
                    at: now,
                    hasForeignInput: hasOtherModifierFamilies
                )
                scheduleWakeHoldCheck()
                return
            }
            if !isFamilyPressed, wakePressStateMachine.isPressed {
                clearWakeHoldCheck()
                let action = wakePressStateMachine.endPress(
                    at: now,
                    hasOtherModifierFamilies: hasOtherModifierFamilies,
                    sameFamilyStillPressed: isFamilyPressed
                )
                handleWakePressAction(action)
                return
            }
        }

        if isTargetKeyEvent {
            let now = Date()
            if !wakePressStateMachine.isPressed {
                wakePressStateMachine.beginPress(
                    at: now,
                    hasForeignInput: hasOtherModifierFamilies
                )
                scheduleWakeHoldCheck()
                return
            }

            clearWakeHoldCheck()
            let action = wakePressStateMachine.endPress(
                at: now,
                hasOtherModifierFamilies: hasOtherModifierFamilies,
                sameFamilyStillPressed: isFamilyPressed
            )
            handleWakePressAction(action)
            return
        }

        guard wakePressStateMachine.isPressed else {
            return
        }

        if HotkeyModifier.from(keyCode: event.keyCode) != nil {
            wakePressStateMachine.registerForeignInput()
        }

        if !activeFlags.contains(modifier.modifierFlags) {
            clearWakeHoldCheck()
            wakePressStateMachine.reset()
            wakeHoldSessionActive = false
        }
    }

    private func scheduleWakeHoldCheck() {
        clearWakeHoldCheck()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.wakeHoldWorkItem = nil
            let action = self.wakePressStateMachine.evaluateHold(at: Date())
            self.handleWakePressAction(action)
        }
        wakeHoldWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + wakePressStateMachine.holdInterval,
            execute: workItem
        )
    }

    private func clearWakeHoldCheck() {
        wakeHoldWorkItem?.cancel()
        wakeHoldWorkItem = nil
    }

    private func scheduleAgentHoldCheck() {
        clearAgentHoldCheck()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.agentHoldWorkItem = nil
            let action = self.agentPressStateMachine.evaluateHold(at: Date())
            self.handleAgentPressAction(action)
        }
        agentHoldWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + agentPressStateMachine.holdInterval,
            execute: workItem
        )
    }

    private func clearAgentHoldCheck() {
        agentHoldWorkItem?.cancel()
        agentHoldWorkItem = nil
    }

    private func handleWakePressAction(_ action: WakeModifierPressAction) {
        switch action {
        case .none:
            break
        case .tap:
            handleWakeModifierTap()
        case .holdBegan:
            handleWakeModifierHoldBegan()
        case .holdEnded:
            handleWakeModifierHoldEnded()
        }
    }

    private func handleWakeModifierTap() {
        guard shouldHandleWakeTap else {
            return
        }
        interactionCoordinator.handleWakeInput(context: .dictation)
    }

    private func handleWakeModifierHoldBegan() {
        guard canStartWakeHoldSession else {
            return
        }
        wakeHoldSessionActive = true
        interactionCoordinator.handleWakeInput(context: .dictationHold)
    }

    private func handleWakeModifierHoldEnded() {
        guard wakeHoldSessionActive else {
            return
        }
        wakeHoldSessionActive = false

        guard currentSessionPhase == .listening else {
            return
        }
        interactionCoordinator.handleStopInput()
    }

    private func registerForeignInput() {
        if wakePressStateMachine.isPressed {
            wakePressStateMachine.registerForeignInput()
        }
        if agentPressStateMachine.isPressed {
            agentPressStateMachine.registerForeignInput()
        }
    }

    private var canStartWakeHoldSession: Bool {
        switch currentSessionPhase {
        case .idle, .cancelled, .error:
            return true
        case .listening, .transcribing, .textProcessing, .inserting:
            return false
        }
    }

    private var shouldHandleWakeTap: Bool {
        switch currentSessionPhase {
        case .idle, .listening, .cancelled, .error:
            return true
        case .transcribing, .textProcessing, .inserting:
            return false
        }
    }

    private var shouldHandleCancelInput: Bool {
        switch currentSessionPhase {
        case .listening, .transcribing, .textProcessing, .inserting:
            return true
        case .idle, .cancelled, .error:
            return false
        }
    }

    private func processAgentModifierEvent(_ event: NSEvent) {
        let modifier = hotkeyStateStore.agentModifier
        let trackedFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let activeFlags = event.modifierFlags.intersection(trackedFlags)
        let isTargetKeyEvent = event.keyCode == modifier.keyCode
        let isFamilyPressed = activeFlags.contains(modifier.modifierFlags)
        let hasOtherModifierFamilies = !activeFlags.subtracting(modifier.modifierFlags).isEmpty

        if !isTargetKeyEvent, event.keyCode == 0 {
            let now = Date()
            if isFamilyPressed, !agentPressStateMachine.isPressed {
                agentPressStateMachine.beginPress(
                    at: now,
                    hasForeignInput: hasOtherModifierFamilies
                )
                scheduleAgentHoldCheck()
                return
            }
            if !isFamilyPressed, agentPressStateMachine.isPressed {
                clearAgentHoldCheck()
                let action = agentPressStateMachine.endPress(
                    at: now,
                    hasOtherModifierFamilies: hasOtherModifierFamilies,
                    sameFamilyStillPressed: isFamilyPressed
                )
                handleAgentPressAction(action)
                return
            }
        }

        if isTargetKeyEvent {
            let now = Date()
            if !agentPressStateMachine.isPressed {
                agentPressStateMachine.beginPress(
                    at: now,
                    hasForeignInput: hasOtherModifierFamilies
                )
                scheduleAgentHoldCheck()
                return
            }

            clearAgentHoldCheck()
            let action = agentPressStateMachine.endPress(
                at: now,
                hasOtherModifierFamilies: hasOtherModifierFamilies,
                sameFamilyStillPressed: isFamilyPressed
            )
            handleAgentPressAction(action)
            return
        }

        guard agentPressStateMachine.isPressed else {
            return
        }

        if HotkeyModifier.from(keyCode: event.keyCode) != nil {
            agentPressStateMachine.registerForeignInput()
        }

        if !activeFlags.contains(modifier.modifierFlags) {
            clearAgentHoldCheck()
            agentPressStateMachine.reset()
            agentHoldSessionActive = false
        }
    }

    private func handleAgentPressAction(_ action: WakeModifierPressAction) {
        switch action {
        case .none, .tap:
            break
        case .holdBegan:
            handleAgentModifierHoldBegan()
        case .holdEnded:
            handleAgentModifierHoldEnded()
        }
    }

    private func handleAgentModifierHoldBegan() {
        guard canStartAgentHoldSession else {
            return
        }
        agentHoldSessionActive = true
        interactionCoordinator.handleWakeInput(context: .agentHold)
    }

    private func handleAgentModifierHoldEnded() {
        guard agentHoldSessionActive else {
            return
        }
        agentHoldSessionActive = false
        guard currentSessionPhase == .listening, currentInputLane == .agentMusic else {
            return
        }
        interactionCoordinator.handleStopInput()
    }

    private var canStartAgentHoldSession: Bool {
        switch currentSessionPhase {
        case .idle, .cancelled, .error:
            return true
        case .listening, .transcribing, .textProcessing, .inserting:
            return false
        }
    }
}
