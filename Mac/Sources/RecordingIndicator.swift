import AppKit
import SwiftUI

/// "● Loom is recording your screen  Stop": a small pill of eGlu's own,
/// floating at the foot of the screen for as long as an extension records
/// anything (the screen, a window, the camera or the microphone), beside
/// macOS's own sharing item and dots, with its own Stop. It never takes the
/// keys or the focus. What is recording is ExtensionCapture's to say; this
/// only shows it.
///
/// An offscreen document that records has nowhere WebKit counts as seen,
/// and WebKit won't start a capture from a page nobody sees. While it
/// records, its page is lent to the pill (a 2×2 point view behind the
/// pill's content) and given back after: what lets it record is what says
/// it is recording. (Search's RecordingIndicator, 313c731 and 46b4b7b)
struct RecordingLine: Identifiable, Equatable {
    let id: String
    /// The extension's name.
    let name: String
    /// "is recording your screen", "is using your camera and microphone"…
    let what: String
}

@MainActor
final class RecordingIndicator: ObservableObject {
    static let shared = RecordingIndicator()

    /// What the pill says, one line per extension recording.
    @Published private(set) var lines: [RecordingLine] = []
    /// What Stop does, for a line's extension.
    var onStop: ((String) -> Void)?

    private var panel: PillPanel?
    /// Offscreen pages lent to the pill while they record, with where each
    /// came from, to be given back.
    private var hosted: [(web: NSView, home: NSView?)] = []

    /// The lines as they are now: shown when there are any, or a page is
    /// lent to the pill; gone when there are none.
    func update(_ lines: [RecordingLine]) {
        if self.lines != lines { self.lines = lines }
        settle()
    }

    /// A line's Stop.
    func stop(_ id: String) {
        onStop?(id)
    }

    /// An offscreen document's page, lent to the pill so that WebKit counts
    /// it as seen while it records. Asked again for the same page, nothing
    /// more happens.
    func host(_ web: NSView) {
        guard !hosted.contains(where: { $0.web === web }) else { return }
        hosted.append((web, web.superview))
        let panel = ownPanel()
        web.removeFromSuperview()
        panel.lend(web)
        settle()
    }

    /// Given back to where it was, or to nowhere if it had no home.
    func release(_ web: NSView) {
        guard let index = hosted.firstIndex(where: { $0.web === web }) else { return }
        let home = hosted.remove(at: index).home
        web.removeFromSuperview()
        if let home { home.addSubview(web) }
        settle()
    }

    /// Up while anything records or a page is lent to it; down otherwise.
    private func settle() {
        hosted.removeAll { $0.web.superview == nil && $0.web.window == nil && panel?.holds($0.web) != true }
        guard !lines.isEmpty || !hosted.isEmpty else {
            panel?.orderOut(nil)
            return
        }
        let panel = ownPanel()
        panel.fit()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func ownPanel() -> PillPanel {
        if let panel { return panel }
        let made = PillPanel(indicator: self)
        panel = made
        return made
    }
}

/// The panel: borderless, never key or main, over every space and
/// full-screen app, at the foot of the screen eGlu is on.
private final class PillPanel: NSPanel {
    private let content: NSHostingView<PillView>
    /// Where lent pages go: behind the pill's own content, 2×2 points.
    private let lending = NSView(frame: NSRect(x: 2, y: 2, width: 2, height: 2))

    init(indicator: RecordingIndicator) {
        content = NSHostingView(rootView: PillView(indicator: indicator))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 40),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        let root = NSView(frame: .zero)
        root.addSubview(lending)
        root.addSubview(content)
        contentView = root
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func lend(_ web: NSView) {
        web.frame = lending.bounds
        lending.addSubview(web)
    }

    func holds(_ web: NSView) -> Bool {
        web.superview === lending
    }

    /// Its size for what it says, at the foot of the screen, centred.
    func fit() {
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: area.midX - size.width / 2, y: area.minY + 24, width: size.width, height: size.height)
        content.frame = NSRect(origin: .zero, size: size)
        if isVisible { setFrame(NSRect(origin: self.frame.origin, size: size), display: true) } else { setFrame(frame, display: false) }
    }
}

/// What the pill draws: a line per extension recording, each with Stop.
private struct PillView: View {
    @ObservedObject var indicator: RecordingIndicator

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(indicator.lines) { line in
                HStack(spacing: 8) {
                    // A recording is known at a glance by its red dot, as in Chrome and Loom.
                    Circle()
                        .fill(Color(nsColor: .systemRed))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text("\(Text(line.name).fontWeight(.semibold)) \(line.what)")
                        .font(.callout)
                        .lineLimit(1)
                        .fixedSize()
                    Spacer(minLength: 12)
                    Button("Stop") { indicator.stop(line.id) }
                        .controlSize(.small)
                        .accessibilityLabel(String(localized: "Stop \(line.name)"))
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Recording"))
    }
}
