import AppKit
import WebEngineAppKit
import XCTest

final class WebEngineSurfaceTests: XCTestCase {
    @MainActor
    func testFocusMakesTheViewItsWindowsFirstResponder() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(view)
        let surface: any WebEngineSurface = FakeSurface(view: view)
        XCTAssertTrue(surface.view === view)
        XCTAssertFalse(window.firstResponder === view)

        surface.focus()

        XCTAssertTrue(window.firstResponder === view)
    }
}

@MainActor
private final class FakeSurface: WebEngineSurface {
    let view: NSView

    init(view: NSView) {
        self.view = view
    }

    func focus() {
        view.window?.makeFirstResponder(view)
    }
}
