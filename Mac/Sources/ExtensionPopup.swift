import AppKit
import PadCore
import SwiftUI
import WebEngineAppKit

/// Keeps the runtime context for one synchronous opening, including while
/// the previous panel closes. Only the runtime interprets it.
struct ExtensionPaneSource {
    let entry: (String) -> URL?
    let makePage: (URL, UUID) -> ExtensionPanePage?
}

/// The popups up, one a window at most, as Chrome has one at a time.
@MainActor
final class ExtensionPopups: ObservableObject {
    static let shared = ExtensionPopups()

    @MainActor final class Popup: ObservableObject, Identifiable {
        let id = UUID()
        let surface: any WebExtensionSurface
        let name: String
        let icon: NSImage?
        weak var window: WindowModel?
        /// Its size, as the page measures itself; nil until it has.
        @Published var size: NSSize?
        /// Unseen until it has a size, as Chrome shows a popup.
        @Published var isShown = false
        /// How often it has been measured.
        var ticks = 0
        /// Its last measure before it is shown: shown when the next agrees.
        var lastFound: NSSize?
        var timer: Timer?

        init(surface: any WebExtensionSurface, name: String, icon: NSImage?, window: WindowModel) {
            self.surface = surface
            self.name = name
            self.icon = icon
            self.window = window
        }
    }

    @Published private(set) var shown: [ObjectIdentifier: Popup] = [:]
    /// Each extension's last size, so the next opening starts there.
    private var lastSize: [String: NSSize] = [:]
    /// Esc pressed in a popup's page puts it away, as in Chrome.
    private var escape: Any?

    func popup(in window: WindowModel) -> Popup? { shown[ObjectIdentifier(window)] }

    /// Whether `id`'s popup is up in the window: a click on its button then closes it.
    func isUp(_ id: String, in window: WindowModel) -> Bool { popup(in: window)?.surface.extensionID == id }

    func show(in window: WindowModel, makePage: () -> ExtensionPanePage?) {
        close(in: window)
        guard let page = makePage() else { return }
        let surface = page.surface
        let key = ObjectIdentifier(window)
        let popup = Popup(surface: surface, name: page.name, icon: page.icon, window: window)
        surface.onClose = { [weak self, weak popup] in
            guard let self, let popup, self.shown[key] === popup else { return }
            self.close(key)
        }
        withAnimation(.bar) { shown[key] = popup }
        watchEscape()
        // Measured as it loads, then for as long as it is up (once a second
        // after its first six): for its first two seconds it follows the
        // page either way, then it only grows, so a page that settles
        // doesn't set it rocking; a width the page names it follows both
        // ways. Shown when two measures agree, so not before its script has
        // filled it in, or after three seconds regardless. (Search's)
        let id = surface.extensionID
        popup.timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self, weak popup] _ in
            MainActor.assumeIsolated {
                guard let self, let popup else { return }
                popup.ticks += 1
                let ticks = popup.ticks
                if ticks > 24, ticks % 4 != 0 { return }
                Task {
                    let measured = await popup.surface.measure()
                    let near = { (a: NSSize, b: NSSize) in abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2 }
                    let now = popup.size
                    if now == nil, ticks < 12 {
                        // Not yet: until two measures agree.
                        guard let found = measured?.size else { return }
                        defer { popup.lastFound = found }
                        guard let last = popup.lastFound, near(last, found) else { return }
                    }
                    guard let found = measured?.size ?? (now == nil ? popup.lastFound ?? self.lastSize[id] ?? NSSize(width: 360, height: 240) : nil)
                    else { return }
                    let named = measured?.named == true
                    let size = now.map { now in
                        ticks <= 8 ? found : NSSize(width: named ? found.width : max(now.width, found.width), height: max(now.height, found.height))
                    } ?? found
                    guard now.map({ !near($0, size) }) ?? true else { return }
                    self.lastSize[id] = size
                    guard now == nil else { popup.size = size; return }
                    // Its first size taken as it is, not grown into; then
                    // it comes in, with the keys, as Chrome's does.
                    var quiet = Transaction()
                    quiet.disablesAnimations = true
                    withTransaction(quiet) { popup.size = size }
                    DispatchQueue.main.async {
                        guard self.shown[key] === popup else { return }
                        popup.isShown = true
                        popup.window?.window?.makeFirstResponder(popup.surface.view)
                    }
                }
            }
        }
    }

    func close(in window: WindowModel) { close(ObjectIdentifier(window)) }

    private func close(_ key: ObjectIdentifier) {
        guard let popup = shown[key] else { return }
        popup.timer?.invalidate()
        popup.timer = nil
        // The keys back to the page, if they were in the popup.
        let focused = popup.surface.hasFocus
        withAnimation(.bar) { _ = shown.removeValue(forKey: key) }
        popup.surface.close()
        if focused { popup.window?.focusPage() }
        if shown.isEmpty, let escape {
            NSEvent.removeMonitor(escape)
            self.escape = nil
        }
    }

    /// Every popup of an extension, when it unloads, or of a space; or
    /// every one of a window as it closes.
    func closeAll(of id: String? = nil, in space: UUID? = nil) {
        for (key, popup) in shown where (id == nil || popup.surface.extensionID == id) && (space == nil || popup.surface.space == space) {
            close(key)
        }
    }

    private func watchEscape() {
        guard escape == nil else { return }
        escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                  let self, let (key, _) = self.shown.first(where: { $0.value.surface.hasFocus && $0.value.surface.view.window === event.window })
            else { return event }
            self.close(key)
            return nil
        }
    }
}

/// The popup as a pane of glass at the page's corner, as Handoff's stands
/// (HandoffPanel): the extension's icon and name over it, and its × to put
/// it away; Esc, another tab or another space puts it away too. Its header
/// moves it (MovablePane).
///
/// The page inside keeps its own corners (10) and sits 10 in from the
/// pane's sides and foot, so the pane's corners (20) run beside the page's,
/// and the header starts on the same line as the page.
enum PopupMetrics {
    static let page: CGFloat = 10
    static let inset: CGFloat = 10
    static let corner = page + inset
}

// MARK: Moved by its title

/// A pane of glass over the pages (an extension's popup, Handoff) moves as
/// a window does by its title bar: held by its title row
/// (`paneTitle()`) and dragged, it follows the pointer. Its title row stays
/// wholly in the pages' room (PageArea), so it can always be taken hold of
/// again: the pane goes no further than the room's sides and top, and down
/// only until its title row is at the room's foot. A room grown smaller
/// keeps it in too. Put away, it comes back where it first stands: the
/// place it was moved to is the pane's, and goes with it.
struct MovablePane: ViewModifier {
    /// The pages' room, which the panes stand in.
    static let room = "panes"

    /// How far it was moved from where it stands of itself.
    @State private var moved = CGSize.zero
    /// Where it was as the drag under way began.
    @State private var start: CGSize?
    /// Where it stands of itself in the room, the room's size, and its title row's height.
    @State private var place = CGRect.zero
    @State private var size = CGSize.zero
    @State private var title: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .environment(\.paneMove, PaneMove(
                changed: { translation in
                    let from = start ?? kept(moved)
                    start = from
                    moved = kept(CGSize(width: from.width + translation.width, height: from.height + translation.height))
                },
                ended: { start = nil },
                title: { title = $0 }))
            .offset(kept(moved))
            // Where it stands of itself: what is round an offset sees the frame it had.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.room)) } action: { place = $0 }
            .onGeometryChange(for: CGSize.self) { $0.bounds(of: .named(Self.room))?.size ?? .zero } action: { size = $0 }
    }

    /// `wanted`, as near as the title row can come to it and stay wholly in
    /// the room. A pane wider than the room goes as far as shows either side.
    private func kept(_ wanted: CGSize) -> CGSize {
        guard size != .zero else { return .zero }
        func clamp(_ value: CGFloat, _ one: CGFloat, _ other: CGFloat) -> CGFloat {
            min(max(value, min(one, other)), max(one, other))
        }
        return CGSize(width: clamp(wanted.width, -place.minX, size.width - place.maxX),
                      height: clamp(wanted.height, -place.minY, size.height - place.minY - title))
    }
}

/// What a pane's title row does with a drag: moves the pane it is in
/// (MovablePane). Outside one, nothing.
struct PaneMove {
    var changed: (CGSize) -> Void = { _ in }
    var ended: () -> Void = {}
    var title: (CGFloat) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var paneMove = PaneMove()
}

/// A pane's title row: its ground, held and dragged, moves the pane
/// (MovablePane). Its buttons take their clicks as before.
private struct PaneTitle: ViewModifier {
    @Environment(\.paneMove) private var move
    /// While a drag is under way: false again whether it ended or was cut short.
    @GestureState private var held = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            // Measured across the window, which stays put, and not across the row, which moves with the pane.
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($held) { _, held, _ in held = true }
                    .onChanged { move.changed($0.translation) }
                    .onEnded { _ in move.ended() }
            )
            // Cut short as well as ended, so the next drag starts from where the pane is.
            .onChange(of: held) { _, now in if !now { move.ended() } }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { move.title($0) }
    }
}

extension View {
    /// A pane of glass over the pages that its title row moves (MovablePane).
    func movablePane() -> some View {
        modifier(MovablePane())
    }

    /// The row that moves the pane it is in (MovablePane).
    func paneTitle() -> some View {
        modifier(PaneTitle())
    }
}

struct ExtensionPopupPane: View {
    @ObservedObject var model: WindowModel
    @ObservedObject private var popups = ExtensionPopups.shared
    /// Where the tabs are, read as it changes: the pane is at the corner nearest the buttons.
    @ObservedObject private var session = Session.shared

    var body: some View {
        if let popup = popups.popup(in: model) {
            let corner: Alignment = model.tabsInSidebar ? .topLeading : .topTrailing
            // Under the developer bar where the card at that corner has it, off its buttons.
            let bar = DeveloperBar.isOn(at: model.tabsInSidebar ? .leading : .trailing, in: model) ? DeveloperBar.height : 0
            // Never bigger than the page's card: a page asking for Chrome's
            // most (800 × 600) in a small window scrolls inside it instead.
            GeometryReader { card in
                PopupPaneBody(popup: popup, room: CGSize(width: card.size.width - 24, height: card.size.height - 24 - bar)) {
                    popups.close(in: model)
                }
                .padding(12)
                .padding(.top, bar)
                .frame(width: card.size.width, height: card.size.height, alignment: corner)
            }
            .id(popup.id)
            .onChange(of: model.tabID) { _, _ in popups.close(in: model) }
            .onChange(of: model.spaceID) { _, _ in popups.close(in: model) }
            // Out softer than it comes in, by less.
            .transition(.asymmetric(insertion: .identity, removal: .offset(y: -4).combined(with: .opacity)))
        }
    }
}

private struct PopupPaneBody: View {
    @ObservedObject var popup: ExtensionPopups.Popup
    /// The most it may take up.
    let room: CGSize
    let close: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PopupMetrics.corner, style: .continuous)
        let header = 4 + Metrics.control + 6
        let wanted = popup.size ?? NSSize(width: 360, height: 160)
        let size = CGSize(width: max(25, min(wanted.width, room.width - 2 * PopupMetrics.inset)),
                          height: max(25, min(wanted.height, room.height - header - PopupMetrics.inset)))
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Group {
                    if let icon = popup.icon {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "puzzlepiece.extension").resizable().scaledToFit().foregroundStyle(.secondary)
                    }
                }
                .frame(width: 16, height: 16)
                Text(popup.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button(action: close) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(PressedIconStyle())
                .keyboardShortcut(.cancelAction)
                .help("Close")
                .accessibilityLabel("Close \(popup.name)")
                // The glyph, not its 28-point cell, near the page's right edge.
                .padding(.trailing, -6)
            }
            .frame(height: Metrics.control)
            .padding(.top, 4)
            .padding(.horizontal, PopupMetrics.inset)
            .paneTitle()
            SurfaceView(surface: popup.surface)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: PopupMetrics.page, style: .continuous))
                .padding([.horizontal, .bottom], PopupMetrics.inset)
                // In a beat behind the pane and its header.
                .opacity(popup.isShown ? 1 : 0)
                .animation(.bar.delay(0.08), value: popup.isShown)
                .overlay {
                    if !popup.isShown {
                        VStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Preparing \(popup.name)…").font(.callout)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
        }
        // As wide as the page, down to what its header needs: a long name
        // is cut short in the header, and never widens the pane past its
        // page (Grammarly's left a band of empty glass beside it).
        .frame(width: max(240, size.width + 2 * PopupMetrics.inset), alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(shape)
        .glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.75)), in: shape)
        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
        .shadow(color: .black.opacity(0.16), radius: 24, y: 10)
        .animation(.bar, value: popup.size)
        .movablePane()
        // The header, cancel button, and preparation status are visible at once.
    }
}

/// An extension's page view, as it is: the surface owns it.
struct SurfaceView: NSViewRepresentable {
    let surface: any WebExtensionSurface

    func makeNSView(context: Context) -> NSView { surface.view }
    func updateNSView(_ view: NSView, context: Context) {}
}
