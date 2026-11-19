import UIKit
import XCTest

final class CommandBarMotionTests: XCTestCase {
    @MainActor
    func testKeyboardOpeningIsImmediatelyVisibleAndHittable() {
        let motion = CommandBarMotion(reducesMotion: { false })
        let bar = hiddenBar()
        motion.change(usingKeyboard: true) { motion.setShown(true, in: bar) }
        XCTAssertTrue(motion.shown)
        XCTAssertFalse(bar.isHidden)
        XCTAssertEqual(bar.alpha, 1)
        XCTAssertEqual(bar.transform, .identity)
        XCTAssertTrue(bar.hitTest(CGPoint(x: 20, y: 20), with: nil) === bar)
        XCTAssertTrue(bar.layer.animationKeys()?.isEmpty ?? true)
    }

    @MainActor
    func testKeyboardDismissalDoesNotWaitForACompletion() {
        let motion = CommandBarMotion(reducesMotion: { false })
        let bar = hiddenBar()
        motion.change(usingKeyboard: true) {
            motion.setShown(true, in: bar)
            motion.setShown(false, in: bar)
        }
        XCTAssertFalse(motion.shown)
        XCTAssertTrue(bar.isHidden)
        XCTAssertEqual(bar.alpha, 0)
        XCTAssertFalse(bar.isUserInteractionEnabled)
    }

    @MainActor
    func testKeyboardFinishesAnAlreadyOpenTouchAnimation() {
        let motion = CommandBarMotion(reducesMotion: { false })
        let bar = hiddenBar()
        motion.setShown(true, in: bar)
        // Reproduce an in-flight touch fade without relying on frame timing.
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 10
        bar.layer.add(fade, forKey: "opacity")
        XCTAssertFalse(bar.layer.animationKeys()?.isEmpty ?? true)
        motion.change(usingKeyboard: true) { motion.setShown(true, in: bar) }
        XCTAssertTrue(bar.layer.animationKeys()?.isEmpty ?? true)
        XCTAssertEqual(bar.alpha, 1)
        XCTAssertEqual(bar.transform, .identity)
        XCTAssertFalse(bar.isHidden)
    }

    @MainActor
    func testReduceMotionMakesBothTouchTransitionsImmediate() {
        let motion = CommandBarMotion(reducesMotion: { true })
        let bar = hiddenBar()
        motion.change {
            XCTAssertFalse(UIView.areAnimationsEnabled)
            motion.setShown(true, in: bar)
        }
        XCTAssertEqual(bar.alpha, 1)
        XCTAssertEqual(bar.transform, .identity)
        XCTAssertTrue(bar.hitTest(CGPoint(x: 20, y: 20), with: nil) === bar)
        motion.change { motion.setShown(false, in: bar) }
        XCTAssertTrue(bar.isHidden)
        XCTAssertNil(bar.hitTest(CGPoint(x: 20, y: 20), with: nil))
        XCTAssertTrue(bar.layer.animationKeys()?.isEmpty ?? true)
    }

    @MainActor
    func testKeyboardTransactionDoesNotLeakIntoTheNextTouch() {
        let wasEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(true)
        defer { UIView.setAnimationsEnabled(wasEnabled) }
        let motion = CommandBarMotion(reducesMotion: { false })
        motion.change(usingKeyboard: true) {
            XCTAssertFalse(UIView.areAnimationsEnabled)
            // Nested actions keep the original input source.
            motion.change { XCTAssertFalse(UIView.areAnimationsEnabled) }
        }
        XCTAssertTrue(UIView.areAnimationsEnabled)
        motion.change { XCTAssertTrue(UIView.areAnimationsEnabled) }
    }

    @MainActor
    func testReduceMotionIsReadForEachTransaction() {
        let wasEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(true)
        defer { UIView.setAnimationsEnabled(wasEnabled) }
        var reduced = false
        let motion = CommandBarMotion(reducesMotion: { reduced })
        motion.change { XCTAssertTrue(UIView.areAnimationsEnabled) }
        reduced = true
        motion.change { XCTAssertFalse(UIView.areAnimationsEnabled) }
        reduced = false
        motion.change { XCTAssertTrue(UIView.areAnimationsEnabled) }
    }

    @MainActor
    func testReopeningSurvivesTheOldTouchDismissal() async throws {
        let motion = CommandBarMotion(reducesMotion: { false })
        let bar = hiddenBar()
        motion.change(usingKeyboard: true) { motion.setShown(true, in: bar) }
        motion.setShown(false, in: bar)
        motion.change(usingKeyboard: true) { motion.setShown(true, in: bar) }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(motion.shown)
        XCTAssertFalse(bar.isHidden)
        XCTAssertEqual(bar.alpha, 1)
        XCTAssertTrue(bar.isUserInteractionEnabled)
    }

    @MainActor
    private func hiddenBar() -> UIView {
        let bar = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        bar.isHidden = true
        bar.alpha = 0
        return bar
    }
}
