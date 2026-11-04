// From harperSwift's harper-desktop/macos-popup (Apache-2.0), changed for eGlu.

import AppKit
import WritingServiceKit
import SwiftUI

/// Borderless panel that never activates eGlu and never becomes the key
/// window, so the app being typed in keeps keyboard focus, its caret, and
/// its active title bar.
final class PopupPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        // eGlu is not the active app while it shows, so the default (hide
        // on deactivate) would hide it at once.
        hidesOnDeactivate = false
        // Above the underlines' windows.
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets SwiftUI buttons react to the first click even though the panel is
/// never key.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// eGlu's name for Harper Desktop's PopupController: the panel's owner,
/// showing one lint over another app's field (Docs/Tasks/03, step A5).
@MainActor
final class WritingPanel {
    static let shared = WritingPanel()

    private let panel = PopupPanel()
    /// The card's chrome: Liquid Glass, as the system's popovers.
    private let glass = NSGlassEffectView()
    private var hosting: FirstClickHostingView<PopupView>?
    private var actions: ((PopupAction, Int) -> Void)?
    private var observers: [NSObjectProtocol] = []
    /// The lint's screen rect, top-left origin, the card is placed beside.
    private var anchor: CGRect = .zero
    private(set) var isVisible = false

    private init() {
        glass.style = .regular
        glass.cornerRadius = 12
        glass.wantsLayer = true
        panel.contentView = glass
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isVisible else { return }
                self.reposition()
            }
        })
        // Another app in front (⌘⇥, the Dock, a click on another window)
        // leaves the old lint behind: hide.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        })
    }

    /// Show the panel for `lint` beside `rect` on screen (top-left origin,
    /// as Accessibility gives it). `actions` hears what the person clicks.
    func show(lint: WritingIssue, at rect: CGRect,
              suggestions: [String], canAddToDictionary: Bool,
              actions: @escaping (PopupAction, Int) -> Void) {
        self.actions = actions
        self.anchor = rect

        let data = PopupData(
            kindName: lint.kind,
            kindColor: WritingColors.rgb(for: lint.kind),
            message: lint.message,
            suggestions: suggestions,
            canAddToDictionary: canAddToDictionary
        )
        let view = PopupView(data: data) { [weak self] action, index in
            self?.dispatch(action, index)
        }
        if let hosting {
            hosting.rootView = view
        } else {
            let hosting = FirstClickHostingView(rootView: view)
            glass.contentView = hosting
            self.hosting = hosting
        }
        reposition()

        let wasVisible = isVisible
        panel.orderFrontRegardless()
        isVisible = true
        announce(lint: lint)
        if !wasVisible { Motion.reveal(glass) }
        // ⌃⌥G is a hot key only while a suggestion is up to take
        // (Decided 8): the keys are the other app's otherwise, also when
        // the panel moves on to a lint with none.
        if suggestions.isEmpty {
            AcceptKey.shared.disable()
        } else {
            AcceptKey.shared.enable()
        }
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        actions = nil
        AcceptKey.shared.disable()
        panel.orderOut(nil)
    }

    private func dispatch(_ action: PopupAction, _ index: Int) {
        let handler = actions
        hide()
        handler?(action, index)
    }

    /// Measures the card and places the panel on the screen that shows the
    /// word: below it, else above, inside the screen's visible frame.
    private func reposition() {
        guard let hosting else { return }
        let screens = NSScreen.screens
        let primaryHeight = screens.first?.frame.maxY ?? 0
        let anchor = PopupGeometry.appKitRect(fromTopLeft: self.anchor, primaryScreenHeight: primaryHeight)
        guard let index = PopupGeometry.screenIndex(for: anchor, screenFrames: screens.map(\.frame)) else {
            return
        }
        let placement = PopupGeometry.place(
            anchor: anchor,
            popupSize: hosting.fittingSize,
            visibleFrame: screens[index].visibleFrame
        )
        panel.setFrame(placement.frame, display: true)
        hosting.frame = glass.bounds
        panel.invalidateShadow()
    }

    /// VoiceOver hears what lint the panel is for when it opens, since the
    /// panel never takes the keyboard focus.
    private func announce(lint: WritingIssue) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: String(localized: "\(lint.kind): \(lint.message)"),
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}

/// Small window moves, reduced when the person asks for less motion.
enum Motion {
    static func reveal(_ view: NSView) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        view.layer?.removeAllAnimations()
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.94
        grow.toValue = 1.0
        grow.duration = 0.12
        grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        view.wantsLayer = true
        view.layer?.add(grow, forKey: "reveal")
    }
}
