import XCTest
@testable import PulseType

final class HUDProgressStateMachineTests: XCTestCase {
    func testTranscribingStartsFromHintAndCap() {
        var machine = HUDProgressStateMachine()

        let frame = machine.transition(
            to: .transcribing,
            progressHint: SessionHUDProgressHint.transcribing,
            message: "正在用 OpenAI 转写。"
        )

        XCTAssertEqual(frame.progress, 0.18, accuracy: 0.0001)
        XCTAssertEqual(machine.cap, 0.42, accuracy: 0.0001)
        XCTAssertEqual(machine.targetProgress, 0.26, accuracy: 0.0001)
        XCTAssertTrue(frame.visibility.keepVisible)

        guard case let .processing(title) = frame.style else {
            return XCTFail("expected processing style")
        }
        XCTAssertEqual(title, "转写中")
    }

    func testTextProcessingUsesPreviewTitleWhenStreamingTextExists() {
        var machine = HUDProgressStateMachine()

        let frame = machine.transition(
            to: .textProcessing,
            progressHint: SessionHUDProgressHint.textTransform,
            message: "听写整理中：这是一个很长的整理预览文本，需要截断显示。"
        )

        guard case let .processing(title) = frame.style else {
            return XCTFail("expected processing style")
        }
        XCTAssertEqual(title, "这是一个很长的整理预览文本，需要截断...")
        XCTAssertEqual(machine.cap, 0.84, accuracy: 0.0001)
    }

    func testPhaseJumpToInsertingRaisesProgressBaseline() {
        var machine = HUDProgressStateMachine()
        _ = machine.transition(
            to: .transcribing,
            progressHint: SessionHUDProgressHint.transcribing,
            message: "正在用 OpenAI 转写。"
        )
        _ = machine.tick()

        let frame = machine.transition(
            to: .inserting,
            progressHint: SessionHUDProgressHint.inserting,
            message: "正在把文本写入 TextEdit。"
        )

        XCTAssertGreaterThanOrEqual(frame.progress, 0.90)
        XCTAssertEqual(machine.cap, 0.97, accuracy: 0.0001)
        guard case let .processing(title) = frame.style else {
            return XCTFail("expected processing style")
        }
        XCTAssertEqual(title, "写入中")
    }

    func testIdleAfterBusyEntersCompletionAndSchedulesQuickHide() {
        var machine = HUDProgressStateMachine()
        _ = machine.transition(
            to: .transcribing,
            progressHint: SessionHUDProgressHint.transcribing,
            message: "正在用 OpenAI 转写。"
        )
        _ = machine.transition(
            to: .inserting,
            progressHint: SessionHUDProgressHint.inserting,
            message: "正在把文本写入 TextEdit。"
        )

        let frame = machine.transition(
            to: .idle,
            progressHint: SessionHUDProgressHint.done,
            message: "文本已写入。"
        )

        XCTAssertEqual(frame.style, .completion)
        XCTAssertEqual(frame.progress, 1.0, accuracy: 0.0001)
        XCTAssertFalse(frame.visibility.keepVisible)
        XCTAssertEqual(frame.visibility.hideDelay, 0.26, accuracy: 0.0001)
        XCTAssertEqual(frame.visibility.fadeDuration, 0.12, accuracy: 0.0001)
    }

    func testCancelledAndErrorUseExpectedHideDurations() {
        var machine = HUDProgressStateMachine()
        _ = machine.transition(to: .listening, progressHint: 0, message: "正在听写。")

        let cancelled = machine.transition(to: .cancelled, progressHint: 0, message: "已取消。")
        XCTAssertEqual(cancelled.style, .cancelled)
        XCTAssertEqual(cancelled.visibility.hideDelay, 0.46, accuracy: 0.0001)
        XCTAssertEqual(cancelled.visibility.fadeDuration, 0.12, accuracy: 0.0001)

        let error = machine.transition(to: .error, progressHint: 0, message: "执行失败。")
        XCTAssertEqual(error.style, .error)
        XCTAssertEqual(error.visibility.hideDelay, 0.90, accuracy: 0.0001)
        XCTAssertEqual(error.visibility.fadeDuration, 0.12, accuracy: 0.0001)
    }

    func testTickContinuesClimbingUntilCeiling() {
        var machine = HUDProgressStateMachine()
        _ = machine.transition(
            to: .textProcessing,
            progressHint: SessionHUDProgressHint.textTransform,
            message: "正在用 DeepSeek 整理听写。"
        )

        let first = machine.progress
        let second = machine.tick()
        XCTAssertGreaterThan(second, first)
        XCTAssertLessThanOrEqual(second, machine.targetProgress)

        for _ in 0..<100 {
            _ = machine.tick()
        }

        XCTAssertLessThanOrEqual(machine.progress, machine.cap)
        XCTAssertEqual(machine.cap, 0.84, accuracy: 0.0001)
    }

    func testCompletionAndErrorResolversHideImplementationDetails() {
        XCTAssertEqual(
            StatusPulseHUDMessageResolver.completionTitle(for: "文本已写入 TextEdit（AX 直写路径）。"),
            "已写入"
        )
        XCTAssertEqual(
            StatusPulseHUDMessageResolver.errorTitle(for: "TextEdit 写回失败。AX 路径原因：目标控件失效。"),
            "写入失败"
        )
    }
}
