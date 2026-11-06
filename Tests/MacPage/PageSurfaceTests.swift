import AppKit
import XCTest
@testable import eGluMac

/// `Page.surface` is the page's own view as a plain NSView, for hosts to
/// place, size, move and give the keys (Docs/EngineSplitPlan.md, step 3).
/// It is the same view, never a wrapper, so a host that shows it shows the
/// page as before.
@MainActor
final class PageSurfaceTests: PageTestCase {
    func testTheSurfaceIsThePagesOwnView() {
        let page = makePage()
        XCTAssertTrue(page.surface.view === page.view)
        XCTAssertTrue(page.surface === page.surface, "one surface for the page's life")
    }

    /// A card holds the page's view and sizes it to itself, as before.
    func testAHolderShowsAndSizesTheView() {
        let page = makePage()
        let holder = PageHolder()
        holder.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        holder.show(page.surface.view)
        XCTAssertTrue(page.view.superview === holder)
        XCTAssertEqual(page.view.frame, holder.bounds)

        holder.frame = NSRect(x: 0, y: 0, width: 500, height: 320)
        holder.layout()
        XCTAssertEqual(page.view.frame, holder.bounds)
    }

    /// The page moves to another card (another window, or split view): the
    /// first card lets go of it, and showing nothing again there leaves it be.
    func testTheViewMovesBetweenHolders() {
        let page = makePage()
        let first = PageHolder()
        let second = PageHolder()
        first.show(page.surface.view)
        second.show(page.surface.view)
        XCTAssertTrue(page.view.superview === second)
        XCTAssertTrue(first.subviews.isEmpty)

        first.show(nil)
        XCTAssertTrue(page.view.superview === second, "the first card no longer holds it")
    }

    /// `focus()` gives the keys to the page in its own window.
    func testFocusGivesTheKeysToThePage() {
        let page = makePage()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let holder = PageHolder()
        holder.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(holder)
        holder.show(page.surface.view)

        page.surface.focus()
        XCTAssertTrue(window.firstResponder === page.view)
        holder.show(nil)
        window.close()
    }

    /// Without a window there is nowhere to give the keys: nothing happens.
    func testFocusWithoutAWindowDoesNothing() {
        let page = makePage()
        page.surface.focus()
        XCTAssertNil(page.view.window)
    }
}
