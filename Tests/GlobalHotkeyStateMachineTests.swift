import Foundation
import XCTest
@testable import PulseType

final class GlobalHotkeyStateMachineTests: XCTestCase {
    func testWakeHoldBeginsAtThreshold() {
        var stateMachine = WakeModifierPressStateMachine(
            holdInterval: 0.18,
            tapInterval: 0.7
        )
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

        stateMachine.beginPress(at: t0, hasForeignInput: false)
        assertNoWakeAction(stateMachine.evaluateHold(at: t0.addingTimeInterval(0.179)))
        assertHoldBegan(stateMachine.evaluateHold(at: t0.addingTimeInterval(0.18)))
    }

    func testWakeHoldReleaseEmitsHoldEnded() {
        var stateMachine = WakeModifierPressStateMachine(
            holdInterval: 0.18,
            tapInterval: 0.7
        )
        let t0 = Date(timeIntervalSinceReferenceDate: 1_200)

        stateMachine.beginPress(at: t0, hasForeignInput: false)
        assertHoldBegan(stateMachine.evaluateHold(at: t0.addingTimeInterval(0.2)))
        assertHoldEnded(
            stateMachine.endPress(
                at: t0.addingTimeInterval(0.25),
                hasOtherModifierFamilies: false,
                sameFamilyStillPressed: false
            )
        )
    }

    func testWakeQuickTapRemainsTap() {
        var stateMachine = WakeModifierPressStateMachine(
            holdInterval: 0.18,
            tapInterval: 0.7
        )
        let t0 = Date(timeIntervalSinceReferenceDate: 1_400)

        stateMachine.beginPress(at: t0, hasForeignInput: false)
        assertTap(
            stateMachine.endPress(
                at: t0.addingTimeInterval(0.12),
                hasOtherModifierFamilies: false,
                sameFamilyStillPressed: false
            )
        )
    }

    func testWakeTapSuppressedAfterForeignInput() {
        var stateMachine = WakeModifierPressStateMachine(
            holdInterval: 0.18,
            tapInterval: 0.7
        )
        let t0 = Date(timeIntervalSinceReferenceDate: 1_600)

        stateMachine.beginPress(at: t0, hasForeignInput: false)
        stateMachine.registerForeignInput()
        assertNoWakeAction(
            stateMachine.endPress(
                at: t0.addingTimeInterval(0.1),
                hasOtherModifierFamilies: false,
                sameFamilyStillPressed: false
            )
        )
    }

    func testWakeTapSuppressedWhenOtherModifierFamiliesRemain() {
        var stateMachine = WakeModifierPressStateMachine(
            holdInterval: 0.18,
            tapInterval: 0.7
        )
        let t0 = Date(timeIntervalSinceReferenceDate: 1_800)

        stateMachine.beginPress(at: t0, hasForeignInput: false)
        assertNoWakeAction(
            stateMachine.endPress(
                at: t0.addingTimeInterval(0.1),
                hasOtherModifierFamilies: true,
                sameFamilyStillPressed: false
            )
        )
    }

    private func assertNoWakeAction(
        _ action: WakeModifierPressAction,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch action {
        case .none:
            break
        case .tap, .holdBegan, .holdEnded:
            XCTFail("Expected none, got \(action)", file: file, line: line)
        }
    }

    private func assertTap(
        _ action: WakeModifierPressAction,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch action {
        case .tap:
            break
        case .none, .holdBegan, .holdEnded:
            XCTFail("Expected tap, got \(action)", file: file, line: line)
        }
    }

    private func assertHoldBegan(
        _ action: WakeModifierPressAction,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch action {
        case .holdBegan:
            break
        case .none, .tap, .holdEnded:
            XCTFail("Expected holdBegan, got \(action)", file: file, line: line)
        }
    }

    private func assertHoldEnded(
        _ action: WakeModifierPressAction,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch action {
        case .holdEnded:
            break
        case .none, .tap, .holdBegan:
            XCTFail("Expected holdEnded, got \(action)", file: file, line: line)
        }
    }
}
