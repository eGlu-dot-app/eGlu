import AppKit
import PadCore
import SwiftUI
import WebKit

/// A page in a Peek (PadCore's Peek), as in Arc: a pop-up its tab's page
/// asked for at a size of its own, a link that leaves a pinned tab's site,
/// or a link the page's menu sent here; in a pane of glass over the tab's
/// card. It is the tab's (Page.peek): kept while the tab is, and shown
/// whenever the tab is on screen, in whichever window; one at a time.
///
/// It goes with a click beside it, its ×, ⌘W, or its page closing itself
/// (a sign-in done). Open in New Tab (⌃⌥O) gives its page, as it is, a tab of
/// its own beside the tab it came from, the page's ties to its opener and
/// all; Open in Split View puts that tab beside it.
@MainActor
final class PeekPage: ObservableObject, PageHost, Identifiable {
    let id = UUID()
    /// A page of no tab, in its opener's space's store, until Open in New Tab gives it one.
    let page: Page
    private(set) weak var opener: Page?
    /// The size a pop-up asked for; nil for a link's, which is nearly the card's.
    let width: Double?
    let height: Double?
    /// Where it was asked to go, until its page says where it is.
    private let asked: URL?

    // The page as its header shows it.
    @Published private(set) var url: URL?
    @Published private(set) var canGoBack = false
    @Published private(set) var loading = false
    /// Why its page didn't load, shown in its place (FailureView).
    @Published private(set) var failure: String?
    /// Closed, or its page given to a tab: nothing more to do.
    private(set) var isOver = false

    /// `configuration`: WebKit's, for a pop-up, so the page keeps its tie to
    /// the one that opened it; nil for a link, loaded by whoever made it.
    init(opener: Page, configuration: WKWebViewConfiguration?, url: URL?, width: Double?, height: Double?) {
        self.opener = opener
        self.width = width
        self.height = height
        asked = url
        page = Page(tab: UUID(), space: opener.space, configuration: configuration)
        page.openedFrom = opener.tab
        self.url = url
        page.host = self
    }

    /// Put away, with any pop-up its page opened. Its page goes once the
    /// pane has faded, not from under it.
    func close() {
        guard !isOver else { return }
        isOver = true
        opener?.peekDidEnd(self)
        Popup.close(openedBy: page)
        let page = page
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { page.tearDown() }
    }

    /// Its page for a tab of its own: the Peek is over, and the page goes on, as it is.
    func handOver() -> Page? {
        guard !isOver else { return nil }
        isOver = true
        page.host = nil
        opener?.peekDidEnd(self)
        return page
    }

    // What the menu bar's ⌘[, ⌘], ⌘R and ⇧⌘C do while the Peek is up: its page's, not the tab's under it.

    func back() {
        page.goBack()
    }

    func forward() {
        page.goForward()
    }

    /// ⌘R, and Try Again over a page that couldn't load: the address that failed.
    func reload() {
        if page.failure != nil { page.retry() } else { page.reload() }
    }

    /// The address Copy Link copies: where the page is, or was asked to go.
    var address: URL? {
        page.state.url ?? url
    }

    // MARK: PageHost

    var hostWindow: NSWindow? {
        opener?.host?.hostWindow
    }

    func pageDidChange(_ page: Page) {
        let state = page.state
        url = state.url ?? page.committed ?? asked
        canGoBack = state.canGoBack
        loading = state.isLoading
        failure = page.failure
    }

    /// On screen while the tab it stands over is.
    func isShowing(_ page: Page) -> Bool {
        guard !isOver, let opener, let host = opener.host else { return false }
        return host.isShowing(opener)
    }

    /// A pop-up of the Peek's own page stands over the window, as pop-ups did
    /// before Peek; any other window it opens is a tab after the tab the Peek is over.
    func page(_ page: Page, open configuration: WKWebViewConfiguration, for action: WKNavigationAction,
              features: WKWindowFeatures) -> WKWebView? {
        if features.width != nil || features.height != nil {
            return Popup.open(from: page, configuration: configuration, features: features, over: hostWindow)
        }
        guard let opener, let host = opener.host else { return nil }
        return host.page(opener, open: configuration, for: action, features: features)
    }

    /// A ⌘-click in the Peek: a tab after the one it stands over.
    func page(_ page: Page, openInNewTab url: URL, inFront: Bool) -> Bool {
        guard let opener, let host = opener.host else { return false }
        return host.page(opener, openInNewTab: url, inFront: inFront)
    }

    func pageDidClose(_ page: Page) {
        close()
    }
}

// MARK: The pane

/// The Peek over the pages' cards: the cards dimmed under it, and a click
/// there putting it away, as in Arc.
struct PeekLayer: View {
    @ObservedObject var model: WindowModel

    var body: some View {
        ZStack {
            if let peek = model.peek {
                RoundedRectangle(cornerRadius: Metrics.card, style: .continuous)
                    .fill(Color.black.opacity(0.16))
                    .contentShape(Rectangle())
                    .onTapGesture { model.closePeek() }
                    .accessibilityHidden(true)
                    .transition(.opacity)
                GeometryReader { card in
                    PeekPane(peek: peek, model: model, room: card.size)
                        .frame(width: card.size.width, height: card.size.height)
                }
                .id(peek.id)
                // In from a little smaller, as a popover grows from where it stands; out softer.
                .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity),
                                        removal: .scale(scale: 0.98).combined(with: .opacity)))
            }
        }
        .animation(.bar, value: model.peek?.id)
    }
}

/// The Peek as an extension's popup and the picture-in-picture window are
/// drawn (ExtensionPopup.swift, PicturePane): a pane of glass with corners
/// of 20, the site's icon and host over the page, its buttons at the
/// header's end, and the page 10 in from the pane's sides and foot with
/// corners of 10, so the two curves run side by side.
private struct PeekPane: View {
    @ObservedObject var peek: PeekPage
    @ObservedObject var model: WindowModel
    /// The cards' room, which the pane stands in with a margin of its own.
    let room: CGSize

    /// The header's height with the room above and below it, as the popup's.
    static let header: CGFloat = 4 + Metrics.control + 6

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PopupMetrics.corner, style: .continuous)
        let inside = CGSize(width: room.width - 2 * PopupMetrics.inset - 24,
                            height: room.height - Self.header - PopupMetrics.inset - 24)
        let size = Peek.size(width: peek.width, height: peek.height, within: inside)
        VStack(alignment: .leading, spacing: 6) {
            // As wide as the page under it, the host cut short to fit, so a
            // long one never widens the pane past the room it was sized for.
            header
                .frame(width: size.width + 2 * PopupMetrics.inset)
            ZStack {
                PageSurface(page: peek.page)
                if let failure = peek.failure {
                    FailureView(message: failure, url: peek.url) { peek.reload() }
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: PopupMetrics.page, style: .continuous))
            .padding([.horizontal, .bottom], PopupMetrics.inset)
        }
        .fixedSize()
        .clipShape(shape)
        .glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.75)), in: shape)
        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
        .shadow(color: .black.opacity(0.2), radius: 32, y: 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Peek")
        .accessibilityAction(.escape) { model.closePeek() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if peek.canGoBack {
                Button { peek.back() } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(PressedIconStyle())
                .help("Back")
                .accessibilityLabel("Back")
                // The glyph, not its 28-point cell, on the page's left edge.
                .padding(.leading, -6)
                .padding(.trailing, -6)
            }
            SiteIconView(url: peek.url, size: 16)
            Text(host)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                if model.peekCanSplit {
                    Button { model.openPeekInTab(split: true) } label: {
                        Image(systemName: "rectangle.split.2x1")
                    }
                    .help("Open in Split View")
                    .accessibilityLabel("Open in Split View")
                }
                Button { model.openPeekInTab() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help("Open in New Tab (⌃⌥O)")
                .accessibilityLabel("Open in New Tab")
                Button { model.closePeek() } label: {
                    Image(systemName: "xmark")
                }
                .help("Close (⌘W)")
                .accessibilityLabel("Close Peek")
            }
            .buttonStyle(PressedIconStyle())
            // The last glyph, not its 28-point cell, near the page's right edge.
            .padding(.trailing, -6)
        }
        .frame(height: Metrics.control)
        .padding(.top, 4)
        .padding(.horizontal, PopupMetrics.inset)
    }

    /// Where the page is, as a person reads a host: no "www.".
    private var host: String {
        guard let host = peek.url?.host() else { return peek.loading ? String(localized: "Loading…") : "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
