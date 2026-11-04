import AppKit
import PadCore
import SwiftUI
import WebKit

/// An extension's own page beside a website's: its popup or its side panel,
/// each in a view made from the extension's configuration, as Search's are
/// (its ExtensionPopup.swift): WebKit's own popup loses messages to the
/// worker for some extensions. To WebKit each is a tab of the space's
/// window at no place in its row, as Chrome puts a popup, since WebKit
/// carries a page's messages only when it can name the tab it is in.
@MainActor
final class ExtensionSurface: NSObject, WKWebExtensionTab, WKUIDelegate, WKNavigationDelegate {
    let extensionID: String
    let space: UUID
    let web: WKWebView
    weak var context: WKWebExtensionContext?
    /// The controller it was opened with, told when it closes even after
    /// the extension's context has been unloaded from it.
    private weak var controller: WKWebExtensionController?
    private var closed = false
    /// The page asked to go: window.close(), or a link out of it.
    var onClose: (() -> Void)?

    /// Nil unless `url` is the extension's own: no site is ever loaded here.
    init?(_ url: URL, for context: WKWebExtensionContext, in space: UUID) {
        guard url.scheme == Extensions.scheme, url.host() == context.uniqueIdentifier,
              let configuration = context.webViewConfiguration else { return nil }
        extensionID = context.uniqueIdentifier
        self.space = space
        self.context = context
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 25, height: 25), configuration: configuration)
        super.init()
        web.uiDelegate = self
        web.navigationDelegate = self
        web.isInspectable = true
        // White behind the page, as Chrome paints a popup: many leave their
        // background unset, and their dark text over glass would vanish.
        web.underPageBackgroundColor = .white
        controller = context.webExtensionController
        controller?.didOpenTab(self)
        web.load(URLRequest(url: url))
    }

    /// Put away for good: WebKit told, and nothing left that holds it.
    func close() {
        guard !closed else { return }
        closed = true
        onClose = nil
        controller?.didCloseTab(self, windowIsClosing: false)
        ExtensionCapture.shared.release(web)
        web.navigationDelegate = nil
        web.uiDelegate = nil
        web.stopLoading()
    }

    /// Whether the keys go to its page now.
    var hasFocus: Bool {
        (web.window?.firstResponder as? NSView)?.isDescendant(of: web) == true
    }

    // MARK: Chrome's measure of a popup (Search's)

    /// The size Chrome would give the popup (Blink's auto-size, between
    /// 25 × 25 and 800 × 600), worked out in the page while its view is
    /// still the 25-point square: the width the page names for itself if it
    /// names one, else its narrowest (min-content), else, for a page with
    /// next to no width of its own, what its content spans; then, laid out
    /// at that width, the height it names or spans. Widths are the content's,
    /// without a scrollbar shown always (Settings › Appearance), which is
    /// added back. Nothing of it is left on the page. The third number is 1
    /// when the page named its width, which is then followed both ways.
    static let preferred = """
    (() => {
      const d = document.documentElement, v = document.compatMode === "BackCompat" ? document.body : d;
      if (!d || !v) return null;
      const m = window.__egluSizing || (window.__egluSizing = {});
      const saved = d.getAttribute("style");
      const back = () => saved === null ? d.removeAttribute("style") : d.setAttribute("style", saved);
      const gutter = innerWidth - v.clientWidth;
      const box = d.getBoundingClientRect();
      let w, named = 1;
      if (Math.abs(box.width - v.clientWidth) > 1) w = m.w = box.width;
      else if (m.w && Math.abs(m.w - v.clientWidth) <= 1) w = m.w;
      else {
        named = 0;
        d.style.setProperty("width", "min-content", "important");
        const narrowest = d.getBoundingClientRect().width;
        back();
        w = narrowest >= 100 ? narrowest : Math.max(narrowest, d.scrollWidth);
      }
      w = Math.min(800, Math.max(25, Math.ceil(w + gutter)));
      d.style.setProperty("width", (w - gutter) + "px", "important");
      let h = d.getBoundingClientRect().height;
      if (Math.abs(h - innerHeight) > 1) m.h = h;
      else if (m.h && Math.abs(m.h - innerHeight) <= 1) h = m.h;
      else {
        d.style.setProperty("height", "auto", "important");
        d.style.setProperty("min-height", "0", "important");
        h = d.getBoundingClientRect().height;
      }
      back();
      return [w, Math.min(600, Math.max(25, Math.ceil(h + innerHeight - v.clientHeight))), named];
    })()
    """

    /// The page's own measure of itself, nil until it has one, and whether
    /// it named its width.
    func measure() async -> (size: NSSize, named: Bool)? {
        guard let found = try? await web.evaluateJavaScript(Self.preferred) as? [Double], found.count == 3 else { return nil }
        return (NSSize(width: found[0], height: found[1]), found[2] == 1)
    }

    // MARK: The page asking

    func webViewDidClose(_ webView: WKWebView) { onClose?() }

    /// A link that asks for a new window becomes a tab, and the surface
    /// goes, as a popup does in Chrome when you follow a link out of it.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, ["http", "https"].contains(url.scheme ?? ""), let context {
            _ = Extensions.shared.tabs.open(url, in: space, active: true, pinned: false, context: context)
        }
        onClose?()
        return nil
    }

    // Its page stays the extension's: a site loaded here would run with the
    // extension's configuration.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.targetFrame?.isMainFrame != false else { return decisionHandler(.allow) }
        let to = navigationAction.request.url
        if to?.scheme == Extensions.scheme, to?.host() == extensionID { return decisionHandler(.allow) }
        if let to, ["http", "https"].contains(to.scheme ?? ""), let context {
            _ = Extensions.shared.tabs.open(to, in: space, active: true, pinned: false, context: context)
        }
        decisionHandler(.cancel)
    }

    // No camera or microphone from a popup or a panel yet.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    /// The screen: yes only while eGlu's own recording call is under way in
    /// this page (ExtensionCapture), no otherwise.
    @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
    func displayCapture(_ web: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo, systemAudio: Bool,
                        decisionHandler: @escaping (Int) -> Void) {
        MainActor.assumeIsolated { decisionHandler(ExtensionCapture.shared.displayDecision(for: web)) }
    }

    // MARK: As WebKit's tab

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { Extensions.shared.tabs.window(for: space) }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { NSNotFound }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { web }
    func title(for context: WKWebExtensionContext) -> String? { web.title }
    func url(for context: WKWebExtensionContext) -> URL? { web.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !web.isLoading }
    func isSelected(for context: WKWebExtensionContext) -> Bool { false }
    func close(for context: WKWebExtensionContext) async throws { onClose?() }
}

/// The popups up, one a window at most, as Chrome has one at a time.
@MainActor
final class ExtensionPopups: ObservableObject {
    static let shared = ExtensionPopups()

    @MainActor final class Popup: ObservableObject, Identifiable {
        let id = UUID()
        let surface: ExtensionSurface
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

        init(surface: ExtensionSurface, name: String, icon: NSImage?, window: WindowModel) {
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

    func show(_ url: URL, for context: WKWebExtensionContext, in window: WindowModel) {
        close(in: window)
        guard let surface = ExtensionSurface(url, for: context, in: window.spaceID) else { return }
        let key = ObjectIdentifier(window)
        let package = context.webExtension
        let popup = Popup(surface: surface, name: package.displayName ?? context.uniqueIdentifier,
                          icon: package.icon(for: CGSize(width: 32, height: 32)), window: window)
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
        let id = context.uniqueIdentifier
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
                        popup.window?.window?.makeFirstResponder(popup.surface.web)
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
                  let self, let (key, _) = self.shown.first(where: { $0.value.surface.hasFocus && $0.value.surface.web.window === event.window })
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
            SurfaceView(web: popup.surface.web)
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
    let web: WKWebView

    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
