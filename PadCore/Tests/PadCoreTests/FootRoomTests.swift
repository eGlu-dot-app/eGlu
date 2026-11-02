import XCTest
@testable import PadCore

/// Whether a page stands clear of the phone's bar or runs on under it
/// (FootRoom). The sizes are an iPhone 17 Pro Max's: 894 points of window
/// for the page, of which the bar and the home indicator cover 138.
final class FootRoomTests: XCTestCase {
    private let room = CGRect(x: 0, y: 0, width: 430, height: 894)

    func testADockedKeyboardShortensTheNativeViewport() {
        let keyboard = CGRect(x: 0, y: 550, width: 430, height: 344)
        XCTAssertEqual(FootRoom.aboveKeyboard(room, keyboard: keyboard, bottomSafeArea: 34),
                       CGRect(x: 0, y: 0, width: 430, height: 550))
    }

    func testTheHiddenKeyboardGuideLeavesTheHomeIndicatorUnderThePage() {
        let hidden = CGRect(x: 0, y: 860, width: 430, height: 34)
        XCTAssertEqual(FootRoom.aboveKeyboard(room, keyboard: hidden, bottomSafeArea: 34), room)
        XCTAssertEqual(FootRoom.aboveKeyboard(room, keyboard: .zero, bottomSafeArea: 0), room)
    }

    func testTypingAnAddressOrUsingTheDesktopPadCanLeaveThePageAlone() {
        let keyboard = CGRect(x: 0, y: 550, width: 430, height: 344)
        XCTAssertEqual(FootRoom.aboveKeyboard(room, keyboard: keyboard, bottomSafeArea: 34, avoiding: false), room)
    }

    func testFloatingAndPartialWidthKeyboardsDoNotShortenThePage() {
        let floating = CGRect(x: 100, y: 400, width: 280, height: 200)
        let partial = CGRect(x: 100, y: 550, width: 330, height: 344)
        let undocked = CGRect(x: 0, y: 400, width: 430, height: 200)
        for keyboard in [floating, partial, undocked] {
            XCTAssertEqual(FootRoom.aboveKeyboard(room, keyboard: keyboard, bottomSafeArea: 34), room)
        }
    }

    func testKeyboardMovementAndDismissalRestoreThePageRoom() {
        for top in [550.0, 650, 800, 860, 894] {
            let keyboard = CGRect(x: 0, y: top, width: 430, height: 894 - top)
            let expected = top < 860 ? top : 894
            XCTAssertEqual(FootRoom.aboveKeyboard(room, keyboard: keyboard, bottomSafeArea: 34).height, expected)
        }
    }

    func testTheKeyboardCanCoverAStageInsetFromTheWindow() {
        let pane = CGRect(x: 16, y: 44, width: 398, height: 834)
        let keyboard = CGRect(x: 0, y: 550, width: 430, height: 344)
        XCTAssertEqual(FootRoom.aboveKeyboard(pane, keyboard: keyboard, bottomSafeArea: 34),
                       CGRect(x: 16, y: 44, width: 398, height: 506))
    }

    func testAKeyboardAboveTheStageStillLeavesAValidWebViewHeight() {
        let keyboard = CGRect(x: 0, y: -20, width: 430, height: 914)
        XCTAssertEqual(FootRoom.aboveKeyboard(room, keyboard: keyboard, bottomSafeArea: 34).height, 1)
    }

    private func clear(_ content: Double, standing: Bool = false, window: Double = 894, covered: Double = 138) -> Bool {
        FootRoom.standsClear(content: content, window: window, covered: covered, standing: standing)
    }

    func testAPageToScrollRunsUnderTheBar() {
        // Taller than the window: its end comes up over the bar as it is scrolled.
        XCTAssertFalse(clear(2_682))
        XCTAssertFalse(clear(896))
        // And one that stood clear runs under again once it has grown past the window.
        XCTAssertFalse(clear(2_682, standing: true))
        XCTAssertFalse(clear(896, standing: true))
    }

    func testAPageThatOnlyFillsTheWindowStandsClear() {
        // Built to the window's height (100vh), which is the whole view's.
        XCTAssertTrue(clear(894))
        // A little shorter than the window, with its foot under the bar and nothing to scroll by.
        XCTAssertTrue(clear(800))
        XCTAssertTrue(clear(758))
        // Within a point of the window's height either way is the window's height.
        XCTAssertTrue(clear(894.6))
    }

    func testAPageThatShowsWholeAboveTheBarIsLeftAsItIs() {
        // All of it shows above the bar: nothing is gained by moving it.
        XCTAssertFalse(clear(756))
        XCTAssertFalse(clear(756.5))
        XCTAssertFalse(clear(300))
    }

    func testOnceClearItStaysSoWhileItWouldFitTheWindow() {
        // Standing clear it is laid out in the window less the bar, and fills that: it does not go back for it.
        XCTAssertTrue(clear(756, standing: true))
        XCTAssertTrue(clear(300, standing: true))
        // Nor when it has a little to scroll by in the smaller window.
        XCTAssertTrue(clear(850, standing: true))
        XCTAssertTrue(clear(894, standing: true))
    }

    func testThereIsNoStandingClearWithoutABar() {
        // An iPad's window, or a phone's while its bar is put away.
        XCTAssertFalse(clear(894, covered: 0))
        XCTAssertFalse(clear(894, standing: true, covered: 0))
        // Nor before the window has a size, or the page a height.
        XCTAssertFalse(clear(100, window: 0))
        XCTAssertFalse(clear(100, window: 100, covered: 138))
        XCTAssertFalse(clear(0))
    }
}
