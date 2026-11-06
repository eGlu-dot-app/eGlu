import PadCore
import SwiftUI
import UIKit

/// Everything a bar, the start page or the empty space can ask
/// a window to do.
enum BarAction {
    case select(UUID)
    case close(UUID)
    /// Several at once: Close Other Tabs, Close All Tabs.
    case closeTabs([UUID])
    case arrangeTabs(Workspace.Arrangement)
    case command(Command)
    case switchSpace(UUID)
    case spaceInNewWindow(UUID)
    case spaceSettings(UUID)
    case removeSpace(UUID)
    case moveTab(UUID, UUID)
    /// A tab dragged before another in the sidebar (SideTabs).
    case placeTab(UUID, before: UUID)
    case tabInNewWindow(UUID)
    case pin(UUID)
    case unpin(UUID)
    case backToPinned(UUID)
    /// A pinned tab pinned anew at the page it is on.
    case repin(UUID)
    case editAddress
    case cancelAddress
    case go(String)
    /// An explicit Go/Search button uses the text rather than the keyboard selection.
    case goDirect(String)
    case switchPane
    case reviewPageDialog
    case reviewExternalRequest
    /// A row the address bar offered (Suggestions).
    case suggestion(Suggestion)
    case open(URL)
    case openInNewTab(URL)
    case openFromBar(UUID)
    case addToBar(UUID, into: UUID?, before: UUID?)
    /// A pointer over a pinned tile or a bookmarks bar row, in its host's coordinates.
    case hoverTab(TabHover)
    case leaveTab(UUID)
    case hideTabHover
    case back
    case forward
    case reload
    case stop
    case toggleBookmark
    case removeBookmark(UUID)
    /// A folder, named, inside another (nil: at the top level).
    case newFolder(String, in: UUID?)
    case renameBookmark(UUID, String)
    /// Into a folder, or nil for the top level.
    case moveBookmark(UUID, into: UUID?)
    case importBookmarks
    case dismissBanner
    /// A tab beside the one on screen; a new one; apart again; sides swapped.
    case splitWith(UUID)
    case splitWithNewTab
    case splitWithPage(URL)
    case separate(UUID)
    /// An address to the clipboard, with a toast to say so (ActionToast).
    case copy(URL)
    case swapSides(UUID)
    /// The space's tabs as a grid, from the phone bar.
    case showTabs
    case downloads
    /// The iPhone's desktop view, in or out (DesktopPad).
    case desktopView
    /// Grammar checking on or off for the site on screen (Settings ›
    /// Writing › Sites).
    case writingSite
    /// The developer bar's Raw and its note on inspecting from a Mac, from
    /// the page's menu where a phone-width bar has no buttons.
    case rawJSON
    case inspectFromMac
}

/// Where a pinned tile or bar row was measured for the window's hover card.
enum TabHoverSource: Equatable {
    case sidebar, top, window
}

/// The page under the pointer and the row or tile the card opens beside.
struct TabHover: Equatable {
    let id: UUID
    let tab: UUID?
    let title: String
    let url: URL?
    let isOpen: Bool
    let anchor: CGRect
    let source: TabHoverSource
}

/// A pinned page's full title and the actions available from its hover card.
struct TabHoverCard: View {
    let item: TabHover
    let canSplit: Bool
    let hovering: (Bool) -> Void
    let act: (BarAction) -> Void

    var body: some View {
        let actions = (item.isOpen && item.tab != nil) || (canSplit && item.url != nil)
        // The glyphs' 32-point cells carry 8 points of air round them: the gaps
        // above and below the row are drawn smaller by that, so what shows is even.
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if actions {
                HStack(spacing: 0) {
                    if item.isOpen, let tab = item.tab {
                        button("arrow.uturn.backward", label: String(localized: "Back to Pinned Address")) {
                            act(.backToPinned(tab))
                        }
                    }
                    if canSplit, let url = item.url {
                        button("rectangle.split.2x1", label: String(localized: "Open in Split View")) {
                            act(.splitWithPage(url))
                        }
                    }
                }
                // The glyphs, not their 32-point cells, in line with the title.
                .padding(.leading, -8)
            }
        }
        .padding([.horizontal, .top], 14)
        .padding(.bottom, actions ? 6 : 14)
        .frame(width: 260, alignment: .leading)
        .floatingGlass(cornerRadius: 18, tint: nil)
        .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
        .onHover(perform: hovering)
    }

    private func button(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Palette.ink)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The row along the top, as the Mac's (TopTabs), as Safari's compact
/// layout: back, forward and reload, the pinned tabs as tiles and the other
/// tabs sharing the row, the one on screen the address; a tap on it types a
/// new one.
///
/// Only the tab on screen is in Liquid Glass; every other tab is flat, so
/// the eye finds it at once.
struct TopBar: View {
    @ObservedObject var session: Session
    let window: WindowModel
    let act: (BarAction) -> Void

    var body: some View {
        TopTabs(session: session, window: window, act: act)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .coordinateSpace(.named(TopTabs.space))
            .overlay(alignment: .bottom) { LoadingLine(window: window) }
            .ignoresSafeArea(.keyboard)
    }
}

// MARK: Bookmarks

/// The space's bookmarks in a bar under the others, for tabs along the top
/// when the button beside New Tab turns it on (Preferences.bookmarksBar), as
/// the Mac's: each its icon and name; a folder, a menu of what it holds.
struct BookmarksStrip: View {
    @ObservedObject var session: Session
    let window: WindowModel
    let act: (BarAction) -> Void

    static let height: CGFloat = 40

    var body: some View {
        let bookmarks = Bookmarks.others(in: session.workspace.space(window.spaceID)?.bookmarks ?? [])
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                if bookmarks.isEmpty {
                    Text("No bookmarks in this space yet. Star a page to keep it here.")
                        .font(.subheadline)
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 10)
                }
                ForEach(bookmarks) { item in
                    StripBookmark(item: item, act: act)
                }
            }
            .padding(.horizontal, 6)
            .frame(maxHeight: .infinity)
        }
        .scrollIndicators(.never)
        .feathered(.horizontal)
        .ignoresSafeArea(.keyboard)
    }
}

/// A bookmark in the bar: its icon and its name, as narrow as they let it be.
private struct StripBookmark: View {
    let item: Bookmark
    let act: (BarAction) -> Void

    var body: some View {
        if item.isFolder {
            Menu {
                StripFolder(items: item.children ?? [], act: act)
            } label: {
                label
            }
            .hoverEffect(.highlight)
        } else if let url = item.url {
            Button {
                HistoryRecorder.shared.expect(.bookmark, url)
                act(.open(url))
            } label: { label }
                .buttonStyle(PressScale())
                .hoverEffect(.highlight)
                .contextMenu {
                    Button("Open in New Tab", systemImage: "plus.square.on.square") { act(.openInNewTab(url)) }
                    Button("Copy Address", systemImage: "doc.on.doc") { act(.copy(url)) }
                }
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            if item.isFolder {
                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            } else {
                SiteIconView(url: item.url, size: 16)
            }
            Text(item.label)
                .font(.subheadline)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .frame(maxWidth: 170, alignment: .leading)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .contentShape(Capsule())
        .contentShape(.hoverEffect, Capsule())
    }
}

/// What a folder in the bar holds, as a menu: its bookmarks, its folders as menus of their own.
private struct StripFolder: View {
    let items: [Bookmark]
    let act: (BarAction) -> Void

    var body: some View {
        if items.isEmpty {
            Text("Empty")
        }
        ForEach(items) { item in
            if item.isFolder {
                Menu(item.label, systemImage: "folder") { StripFolder(items: item.children ?? [], act: act) }
            } else if let url = item.url {
                Button(item.label) { act(.open(url)) }
            }
        }
    }
}

// MARK: The space

/// The space's own button, filled with its colour, so a window says which
/// space it is in at a glance; its menu goes to the others.
struct SpaceButton: View {
    @ObservedObject var session: Session
    let window: WindowModel
    let act: (BarAction) -> Void
    /// Beside the address, as the bar beside the iPhone Duo's strip has it
    /// (SpaceFace.besideAddress).
    var besideAddress = false
    /// How wide the name may be among a thumb's tools (SpaceFace.nameRoom).
    var nameRoom: CGFloat = 100

    var body: some View {
        let space = session.workspace.space(window.spaceID)
        Menu {
            Section {
                ForEach(session.workspace.spaces) { other in
                    Button {
                        act(.switchSpace(other.id))
                    } label: {
                        if other.id == window.spaceID {
                            Label(other.name, systemImage: "checkmark")
                        } else {
                            Label(other.name, systemImage: other.symbol)
                        }
                    }
                }
            }
            Section {
                Button("New Space…", systemImage: "plus") { act(.command(.newSpace)) }
                Button("Space Settings…", systemImage: "slider.horizontal.3") { act(.spaceSettings(window.spaceID)) }
                // Only where this window can open another: never on an iPhone (Device.makesWindows).
                if window.makesWindows {
                    Button("Open in New Window", systemImage: "macwindow.badge.plus") { act(.spaceInNewWindow(window.spaceID)) }
                }
                if session.workspace.spaces.count > 1 {
                    Button("Remove Space…", systemImage: "trash", role: .destructive) { act(.removeSpace(window.spaceID)) }
                }
            }
        } label: {
            SpaceFace(space: space, besideAddress: besideAddress, nameRoom: nameRoom)
        }
        .accessibilityLabel("Space: \(space?.name ?? "")")
    }
}

/// What the space button shows: the space's mark and name on its colour.
/// Drawn alone too, in the row a sideways swipe brings in (ComingAddress).
struct SpaceFace: View {
    let space: Space?
    /// In one row with the address, as beside the iPhone Duo's strip: the
    /// space's mark alone on a disc of its colour, as tall as the address,
    /// the name left to the menu, so the address keeps its room.
    var besideAddress = false
    /// How wide the name may be among a thumb's tools before it gives way:
    /// wider at the top of the phone's tabs, where it is alone.
    var nameRoom: CGFloat = 100
    @Environment(\.barScale) private var scale

    var body: some View {
        let color = space?.color ?? .blue
        if besideAddress {
            Image(systemName: space?.symbol ?? "square.grid.2x2")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(color.ink)
                .frame(width: scale.control, height: scale.control)
                .liquidGlass(tint: color.color, in: Circle(), otherwise: color.color)
                .contentShape(Circle())
                .animation(.bar, value: color)
        } else {
            face(color)
        }
    }

    /// The mark, the name and the menu's chevron on the space's colour.
    @ViewBuilder
    private func face(_ color: SpaceColor) -> some View {
        // On the phone bar, among icons for a thumb: a little larger, and
        // a long name gives way before the icons do.
        let thumb = scale == .thumb
        HStack(spacing: thumb ? 6 : 5) {
            Image(systemName: space?.symbol ?? "square.grid.2x2")
                .font(.system(size: thumb ? 14 : 12, weight: .semibold))
            // The text styles of the same sizes, so a larger text size reaches it, as far as the capsule holds.
            let name = Text(space?.name ?? "")
                .font(.system(thumb ? .subheadline : .footnote, weight: .semibold))
                .lineLimit(1)
            if thumb { name.frame(maxWidth: nameRoom) } else { name }
            Image(systemName: "chevron.down")
                .font(.system(size: thumb ? 9 : 8, weight: .bold))
                .opacity(0.75)
                // The chevron's weight sits low; up a point, it lines up with the text.
                .offset(y: 0.5)
        }
        .foregroundStyle(color.ink)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .padding(.horizontal, thumb ? 14 : 12)
        .frame(height: thumb ? 36 : Metrics.control)
        .liquidGlass(tint: color.color, in: Capsule(), otherwise: color.color)
        .frame(height: thumb ? 44 : Metrics.target)
        .contentShape(Rectangle())
        .contentShape(.hoverEffect, Capsule().inset(by: Metrics.ring))
        .animation(.bar, value: color)
    }
}

// MARK: Tabs

/// Where things sit in a tab and in the address field, so that what the tab
/// says and the address being typed start at the same place, and one fades
/// into the other without moving: a 28-point slot for the icon or the close
/// button, 2 points in, and the words 4 points after it.
enum TabFace {
    static let lead: CGFloat = 2
    static let slot: CGFloat = 28
    static let gap: CGFloat = 4
    /// Where the words start in the phone's capsule with no icon before
    /// them, as far in as its rounded end lets them.
    static let bare: CGFloat = 16
}

/// The page's own commands on the phone's page menu (…). The three that
/// act on the page as it is, finding in it, sharing it and handing it off,
/// sit side by side in one row, as the system sets cut, copy and paste: a
/// control group in a menu is that row. They come first, which in this menu
/// is nearest the button and so at its foot, under the thumb. Copy Link is
/// next to them, and copies the address as Share sends it, without the tags
/// that follow whoever opens it (Tracking.clean).
struct PageItems: View {
    let window: WindowModel
    let act: (BarAction) -> Void

    var body: some View {
        let row = MenuEntry.pageRow(window, act: act)
        if !row.isEmpty {
            ControlGroup { MenuButtons(entries: row) }
        }
        MenuButtons(entries: MenuEntry.page(window, act: act))
    }
}

/// The way to everything else, at the end of the tab on screen's menu, as
/// at the end of the phone's page menu.
struct AppItems: View {
    let act: (BarAction) -> Void
    /// So Downloads' row says how many are under way as that changes.
    @ObservedObject private var downloads = Downloads.shared

    var body: some View {
        MenuButtons(entries: MenuEntry.app(act: act))
    }
}

/// A command on the page's menu, said once for the two forms that menu
/// takes: SwiftUI's buttons (PageItems, AppItems, the phone's …) and
/// UIKit's actions, for the overflow menu of the iPhone Duo's strip,
/// which takes menu elements (MenuEntry.overflow).
@MainActor
struct MenuEntry {
    let title: String
    let symbol: String
    var destructive = false
    var enabled = true
    let run: () -> Void

    /// Find, Share and Handoff, which act on the page as it is: side by side in one row.
    static func pageRow(_ window: WindowModel, act: @escaping (BarAction) -> Void) -> [MenuEntry] {
        guard window.url != nil else { return [] }
        var row = [
            MenuEntry(title: BrowserText.localized("Find"), symbol: "text.magnifyingglass") { act(.command(.find)) },
            MenuEntry(title: BrowserText.localized("Share"), symbol: "square.and.arrow.up") { act(.command(.share)) },
        ]
        if window.canHandoff {
            row.append(MenuEntry(title: BrowserText.localized("Handoff"), symbol: Command.handoff.symbol) { act(.command(.handoff)) })
        }
        return row
    }

    /// The rest of the page's own: its address, its bookmark, its ads, its desktop view.
    static func page(_ window: WindowModel, act: @escaping (BarAction) -> Void) -> [MenuEntry] {
        var entries: [MenuEntry] = []
        if !Session.shared.workspace.closed.isEmpty {
            entries.append(MenuEntry(title: BrowserText.localized("Reopen Closed Tab"), symbol: "arrow.uturn.backward") { act(.command(.reopenTab)) })
        }
        if window.pendingPageDialog {
            entries.append(MenuEntry(title: BrowserText.localized("Review Waiting Page Dialog"), symbol: "text.bubble") { act(.reviewPageDialog) })
        }
        if window.refusedExternalLink {
            entries.append(MenuEntry(title: BrowserText.localized("Review Link to Another App"), symbol: "arrow.up.forward.app") { act(.reviewExternalRequest) })
        }
        if window.url != nil {
            entries.append(MenuEntry(title: BrowserText.localized("Copy Link"), symbol: "doc.on.doc") { act(.command(.copyLink)) })
            entries.append(MenuEntry(title: window.bookmarked ? String(localized: "Remove Bookmark") : String(localized: "Bookmark This Page"),
                                     symbol: window.bookmarked ? "star.slash" : "star") { act(.toggleBookmark) })
        }
        if let blocking = window.blocking {
            entries.append(MenuEntry(title: blocking ? String(localized: "Allow Ads on This Site") : String(localized: "Block Ads on This Site"),
                                     symbol: blocking ? "shield.slash" : "shield") { act(.command(.contentBlocking)) })
            if !blocking {
                entries.append(MenuEntry(title: BrowserText.localized("Blocking Off for This Site"), symbol: "shield.slash", enabled: false) {})
            }
        } else if window.url != nil {
            entries.append(MenuEntry(title: Session.shared.preferences.blocksContent ? String(localized: "Blocking Unavailable on Protected Sign-in Pages") : String(localized: "Content Blocking Off in Settings"),
                                     symbol: "shield.slash", enabled: false) {})
        }
        if let writing = window.writing {
            entries.append(MenuEntry(title: writing ? String(localized: "Turn Grammar Checking Off for This Site") : String(localized: "Check Grammar on This Site"),
                                     symbol: "character.cursor.ibeam") { act(.writingSite) })
        }
        if window.canDesktopView || window.desktopView {
            // The page at an iPad's size, with a cursor the finger moves as on
            // a trackpad: a phone's, whichever bars its window has.
            entries.append(MenuEntry(title: window.desktopView ? String(localized: "Exit Trackpad View") : String(localized: "Use Trackpad View"),
                                     symbol: window.desktopView ? "iphone" : "cursorarrow.rays") { act(.desktopView) })
        }
        // Developer mode, on or off for the site, and its tools where the
        // page's own bar has only the address and status (Decided 2 and 3).
        // The Mac's and the iPad's: none on an iPhone.
        if window.url != nil, !Device.phone {
            entries.append(MenuEntry(title: window.title(for: .developerMode), symbol: Command.developerMode.symbol) { act(.command(.developerMode)) })
            let preferences = Session.shared.preferences
            if DeveloperMode.isOn(window.url, choices: preferences.developerSites, local: preferences.developerLocal) {
                entries.append(MenuEntry(title: Command.elementPicture.title, symbol: Command.elementPicture.symbol) { act(.command(.elementPicture)) })
                entries.append(MenuEntry(title: Command.reloadOrigin.title, symbol: Command.reloadOrigin.symbol) { act(.command(.reloadOrigin)) })
                // The rest of the bar's buttons, which a phone-width bar leaves out.
                if window.phone {
                    entries.append(MenuEntry(title: window.title(for: .measure), symbol: Command.measure.symbol) { act(.command(.measure)) })
                    if let drawn = window.jsonView {
                        entries.append(MenuEntry(title: drawn ? String(localized: "Show Raw JSON") : String(localized: "Show Formatted JSON"),
                                                 symbol: "curlybraces") { act(.rawJSON) })
                    }
                    entries.append(MenuEntry(title: String(localized: "Inspect from Safari on a Mac"), symbol: "info.circle") { act(.inspectFromMac) })
                }
            }
        }
        return entries
    }

    /// The tab on screen's own, on a phone's page menu, where no tab shows
    /// to have a menu of its own: Separate Tabs, and Pin or Unpin.
    static func tab(_ session: Session, _ window: WindowModel, act: @escaping (BarAction) -> Void) -> [MenuEntry] {
        guard let tab = window.tabID.flatMap({ session.workspace.tab($0) }) else { return [] }
        var entries: [MenuEntry] = []
        // A split made while the window was wide, one pane showing now (Browser.layoutPanes).
        if session.workspace.split(containing: tab.id) != nil {
            entries.append(MenuEntry(title: BrowserText.localized("Switch Pane"), symbol: "rectangle.2.swap") { act(.switchPane) })
            entries.append(MenuEntry(title: BrowserText.localized("Separate Tabs"), symbol: "rectangle") { act(.separate(tab.id)) })
        }
        if tab.isPinned {
            entries.append(MenuEntry(title: BrowserText.localized("Unpin Tab"), symbol: "pin.slash") { act(.unpin(tab.id)) })
        } else if tab.url != nil {
            entries.append(MenuEntry(title: BrowserText.localized("Pin Tab"), symbol: "pin") { act(.pin(tab.id)) })
        }
        return entries
    }

    /// The way to everything else. A file to hand off is among it, beside
    /// Downloads: it is no part of the page, and is there on a new tab too.
    static func app(act: @escaping (BarAction) -> Void) -> [MenuEntry] {
        var entries = [
            MenuEntry(title: Command.everything.title, symbol: "command") { act(.command(.everything)) },
            MenuEntry(title: BrowserText.localized("All Tabs"), symbol: "square.on.square") { act(.showTabs) },
            // How many are under way, where the phone has no downloads button to show it.
            MenuEntry(title: Downloads.shared.active ? String(localized: "Downloads (\(Downloads.shared.activeCount))") : BrowserText.localized("Downloads"),
                      symbol: Downloads.shared.active ? "arrow.down.circle.fill" : "arrow.down.circle") { act(.downloads) },
        ]
        if Session.shared.preferences.handoff, Session.shared.hasIntelligence {
            entries.append(MenuEntry(title: BrowserText.localized("Handoff File"), symbol: Command.handoffFile.symbol) {
                act(.command(.handoffFile))
            })
        }
        entries += [
            MenuEntry(title: BrowserText.localized("History"), symbol: Command.history.symbol) { act(.command(.history)) },
            MenuEntry(title: BrowserText.localized("Bookmarks"), symbol: Command.bookmarkManager.symbol) { act(.command(.bookmarkManager)) },
            MenuEntry(title: BrowserText.localized("Settings"), symbol: "gearshape") { act(.command(.settings)) },
        ]
        return entries
    }

    /// The phone's page menu as UIKit's elements, in the order the phone's
    /// … has it: the page's row, the page's own, the tab's, then the app's.
    static func overflow(_ session: Session, _ window: WindowModel, act: @escaping (BarAction) -> Void) -> [UIMenuElement] {
        let row = UIMenu(options: .displayInline, children: actions(pageRow(window, act: act)))
        row.preferredElementSize = .medium
        return [row]
            + actions(page(window, act: act) + tab(session, window, act: act))
            + [UIMenu(options: .displayInline, children: actions(app(act: act)))]
    }

    private static func actions(_ entries: [MenuEntry]) -> [UIAction] {
        entries.map { entry in
            UIAction(title: entry.title, image: UIImage(systemName: entry.symbol),
                     attributes: entry.destructive ? .destructive : entry.enabled ? [] : .disabled) { _ in entry.run() }
        }
    }
}

/// A menu's entries as SwiftUI's buttons.
struct MenuButtons: View {
    let entries: [MenuEntry]

    var body: some View {
        ForEach(entries, id: \.title) { entry in
            Button(entry.title, systemImage: entry.symbol, role: entry.destructive ? .destructive : nil, action: entry.run)
                .disabled(!entry.enabled)
        }
    }
}

// MARK: The address

/// The address as it reads when nobody is typing; a tap types a new one.
private struct AddressSummary: View {
    let window: WindowModel
    /// What the page is called rather than where it is, as Settings › The
    /// tab you are on shows has it; never on a sign-in page (showsAddress).
    var titled = false
    /// The site's icon before the address; not beside a pinned tab's button,
    /// which shows it already. A warning, or a search's glass, stays.
    var siteIcon = true
    let act: (BarAction) -> Void
    @Environment(\.barScale) private var scale

    var body: some View {
        // A page's title carries no warning, as the iPad's tab doesn't:
        // the address does, and every sign-in page shows its address.
        let warns = !(titled && !window.title.isEmpty)
        let slot = siteIcon || (warns && window.insecure) || window.url == nil || window.searchWords != nil
        HStack(spacing: 0) {
            if slot {
                SecurityIcon(window: window, warns: warns)
                    .frame(width: TabFace.slot, height: scale.control)
                    .padding(.leading, scale.lead)
                    .transition(.opacity)
            }
            Group {
                if let words = window.searchWords {
                    // A search with the chosen engine says what was searched for, as Safari does.
                    Text(words)
                        .foregroundStyle(Palette.ink)
                } else if titled, window.url != nil, !window.title.isEmpty {
                    Text(window.title)
                        .fontWeight(.medium)
                        .foregroundStyle(Palette.ink)
                } else {
                    // On the phone, the host alone, cut from its start when
                    // long, as Safari does: what is left is who you are
                    // talking to (the registrable domain), never the middle
                    // of it.
                    AddressLine(url: window.url, hostOnly: scale == .thumb)
                        // The host from its start; with none, the placeholder from its end.
                        .truncationMode(scale != .thumb ? .middle : window.url != nil ? .head : .tail)
                }
            }
            .font(scale == .thumb ? .body : .subheadline)
            // As large as the bar holds: an accessibility size would spill out of it.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.leading, slot ? TabFace.gap : TabFace.bare)
            // Ads allowed on this site, for as long as they are: the page's
            // menu turned it on, and only there does it say so otherwise.
            if window.blocking == false {
                Image(systemName: "shield.slash")
                    .font(.system(size: scale == .thumb ? 13 : 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .padding(.leading, 6)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        .onTapGesture { act(.editAddress) }
        .accessibilityElement(children: .ignore)
        // The warning the icon shows, said too: the icon's own label is folded in here.
        .accessibilityLabel(window.url.map {
            window.insecure ? String(localized: "Address, \(Destination.pretty($0)), Not secure") : String(localized: "Address, \(Destination.pretty($0))")
        } ?? String(localized: "Address"))
        .accessibilityValue(window.blocking == false ? String(localized: "Ads allowed on this site") : "")
        .accessibilityHint("Type a new address or a search")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { act(.editAddress) }
    }
}

/// A tab's address as AddressCapsule shows the one on screen, for a tab that
/// isn't: its site's icon and its name or its address, in the same capsule
/// (PhoneBar's sideways drag).
struct NeighbourAddress: View {
    let tab: TabRecord
    let titled: Bool
    /// As the bar will have it (AddressSummary.siteIcon).
    var siteIcon = true
    @Environment(\.barScale) private var scale

    var body: some View {
        let slot = siteIcon || tab.url == nil
        HStack(spacing: 0) {
            if slot {
                Group {
                    if tab.url != nil {
                        SiteIconView(url: tab.url, size: scale.icon)
                    } else {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: scale.icon * 0.75, weight: .medium))
                            .foregroundStyle(Palette.muted)
                            .frame(width: scale.icon, height: scale.icon)
                    }
                }
                .frame(width: TabFace.slot, height: scale.control)
                .padding(.leading, scale.lead)
            }
            Group {
                if titled, tab.url != nil, !tab.title.isEmpty {
                    Text(tab.title)
                        .fontWeight(.medium)
                        .foregroundStyle(Palette.ink)
                } else {
                    AddressLine(url: tab.url)
                }
            }
            // As the address on screen has it (AddressSummary), so the two read alike as one slides in.
            .font(scale == .thumb ? .body : .subheadline)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.leading, slot ? TabFace.gap : TabFace.bare)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: scale.control)
        .liquidGlass(reacting: false, in: Capsule(), otherwise: Palette.wash)
        .frame(height: scale.target)
    }
}

/// The site's icon, or a warning when the page or something on it came
/// over a connection anyone on the way can read.
private struct SecurityIcon: View {
    let window: WindowModel
    var warns = true
    @Environment(\.barScale) private var scale

    var body: some View {
        if warns && window.insecure {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: scale.icon * 0.75))
                .foregroundStyle(Palette.unsafe)
                .frame(width: scale.icon, height: scale.icon)
                .accessibilityLabel("Not secure")
        } else if window.url != nil, window.searchWords == nil {
            SiteIconView(url: window.url, size: scale.icon)
        } else {
            Image(systemName: "magnifyingglass")
                .font(.system(size: scale.icon * 0.75, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: scale.icon, height: scale.icon)
        }
    }
}

/// "accounts." muted, "google.com" in bold, "/v3/signin" muted: the part of
/// the host that says who you are talking to stands out.
struct AddressLine: View {
    let url: URL?
    /// The host alone, as a tab says where it is.
    var hostOnly = false

    var body: some View {
        text
    }

    private var text: Text {
        guard let url, let host = url.host() else {
            return Text(AddressEditor.placeholder).foregroundStyle(Palette.muted)
        }
        let bare = host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let full = Destination.pretty(url)
        let pretty = hostOnly && full.hasPrefix(bare) ? bare : full
        let name = Destination.registrable(bare)
        guard pretty.hasPrefix(bare), bare.hasSuffix(name) else {
            return Text(pretty).foregroundStyle(Palette.ink)
        }
        let sub = String(bare.dropLast(name.count))
        let rest = String(pretty.dropFirst(bare.count))
        return Text(sub).foregroundStyle(Palette.muted)
            + Text(name).foregroundStyle(Palette.ink).fontWeight(.semibold)
            + Text(rest).foregroundStyle(Palette.muted)
    }
}

private struct SignInBadge: View {
    var body: some View {
        Image(systemName: "key.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Palette.muted)
            .frame(width: 24, height: 22)
            .background(Palette.wash, in: Capsule())
            .help("Sign-in page")
            .accessibilityLabel("Sign-in page")
            .transition(.opacity)
    }
}

/// The star: this page among the space's bookmarks, or not; a tap adds or
/// takes it away.
private struct BookmarkStar: View {
    let window: WindowModel
    let act: (BarAction) -> Void
    @Environment(\.barScale) private var scale

    var body: some View {
        Button {
            act(.toggleBookmark)
        } label: {
            // The system's own swap of one symbol for another, which follows Reduce Motion.
            Image(systemName: window.bookmarked ? "star.fill" : "star")
                .foregroundStyle(window.bookmarked ? Palette.ink : Palette.muted)
                .contentTransition(.symbolEffect(.replace))
            .font(.system(size: scale.text, weight: .medium))
            // A star's centre of weight sits below its middle.
            .offset(y: -0.5)
            .frame(width: scale.button, height: scale.control)
            .contentShape(Rectangle())
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).inset(by: 3))
            .animation(.bar, value: window.bookmarked)
        }
        .buttonStyle(PressScale())
        .hoverEffect(.highlight)
        .accessibilityLabel(window.bookmarked ? "Remove Bookmark" : "Bookmark This Page")
    }
}

private struct ReloadButton: View {
    let window: WindowModel
    let act: (BarAction) -> Void
    @Environment(\.barScale) private var scale

    var body: some View {
        Button {
            act(window.loading ? .stop : .reload)
        } label: {
            // Swapped at every load's start and end: the system's own replace, quiet and Reduce Motion's.
            Image(systemName: window.loading ? "xmark" : "arrow.clockwise")
                .contentTransition(.symbolEffect(.replace))
            .font(.system(size: scale.text - 1, weight: .semibold))
            .foregroundStyle(Palette.ink)
            .frame(width: scale.button, height: scale.control)
            .contentShape(Rectangle())
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).inset(by: 3))
            .animation(.bar, value: window.loading)
        }
        .buttonStyle(PressScale())
        .hoverEffect(.highlight)
        .accessibilityLabel(window.loading ? "Stop" : "Reload")
    }
}

/// The address being typed, in a phone's bar (an iPad's is typed in the
/// command bar, CommandBar). It opens with the address selected, so typing
/// replaces it, as Safari's does; Return goes, Cancel or a touch on the page
/// leaves it as it was. Its icon and its words sit where a tab's do
/// (TabFace), so the address's words fade into the field in place. It has
/// no glass of its own: it is drawn on the capsule's.
struct AddressEditor: View {
    let window: WindowModel
    let act: (BarAction) -> Void
    @State private var text = ""
    @State private var focused = false
    /// The text came over from the other field (WindowModel.carriedAddress):
    /// kept as typed, the cursor after it, not all selected to type over.
    @State private var carried = false
    @Environment(\.barScale) private var scale

    /// What an empty field says it takes: commands and settings too, now
    /// that it is the one place they are found.
    static var placeholder: String { BrowserText.localized("Address, search or command") }

    var body: some View {
        HStack(spacing: 0) {
            SecurityIcon(window: window)
                .frame(width: TabFace.slot, height: scale.control)
                .padding(.leading, scale.lead)
            TypingField(text: $text, placeholder: Self.placeholder, fontSize: scale.text, focused: $focused,
                        selectsAll: !carried) { typed in act(.go(typed)) }
                .padding(.leading, TabFace.gap)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: scale.text + 1))
                        // Muted, not faint: it is a control that works, and faint is 1.5:1 on a light page.
                        .foregroundStyle(Palette.muted)
                        .frame(width: scale.button, height: scale.control)
                        .contentShape(Rectangle())
                        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).inset(by: 3))
                }
                .buttonStyle(PressScale())
                .hoverEffect(.highlight)
                .accessibilityLabel("Clear")
                .transition(.opacity)
            }
        }
        .padding(.trailing, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.bar, value: text.isEmpty)
        // Drawn before it is typed in, in the compact layout, so it starts
        // when typing does as well as when it appears.
        .onAppear { if window.editingAddress { begin() } }
        // Each turn at the field starts it over, one asked for while it is
        // already typed in included (WindowModel.addressTurn).
        .onChange(of: window.addressTurn) { _, _ in if window.editingAddress { begin() } }
        .onChange(of: text) { _, now in window.suggestions.typed(now, in: window) }
        .onChange(of: focused) { _, now in
            // Not as the window widens and the command bar takes the typing over.
            if !now && window.editingAddress && window.phone { act(.cancelAddress) }
        }
    }

    /// The tab's address, all of it selected (TypingField.selectsAll), with
    /// the keys; or nothing, when everything is listed under the field; or
    /// what was typed in the command bar before the window narrowed.
    private func begin() {
        window.suggestions.begin(in: window)
        if let typed = window.carriedAddress {
            window.carriedAddress = nil
            carried = true
            text = typed
        } else {
            carried = false
            text = window.listsEverything ? "" : window.url.map { Destination.editable($0, engine: Session.shared.preferences.engine) } ?? ""
        }
        focused = true
    }
}

/// Back and forward, in one piece of glass, as Safari has them.
struct HistoryButtons: View {
    let window: WindowModel
    let act: (BarAction) -> Void

    var body: some View {
        HStack(spacing: 0) {
            button("chevron.left", String(localized: "Back"), enabled: window.canGoBack) { act(.back) }
            button("chevron.right", String(localized: "Forward"), enabled: window.canGoForward) { act(.forward) }
        }
        .background {
            Color.clear
                .liquidGlass(reacting: false, in: Capsule(), otherwise: .clear)
                .frame(height: Metrics.control)
        }
        .padding(.trailing, 4)
    }

    private func button(_ symbol: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(enabled ? Palette.ink : Palette.faint)
                // A chevron's point sits off its box; nudged toward the way it points.
                .offset(x: symbol == "chevron.left" ? -0.5 : 0.5)
                .frame(width: Metrics.target, height: Metrics.target)
                .contentShape(Rectangle())
                .contentShape(.hoverEffect, Circle().inset(by: Metrics.ring))
        }
        .buttonStyle(PressScale())
        .disabled(!enabled)
        .hoverEffect(.highlight)
        .accessibilityLabel(label)
    }
}

/// A round glass button on a bar: 32 points drawn, 40 that answer.
struct BarButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.ink)
                .frame(width: Metrics.control, height: Metrics.control)
                .liquidGlass(in: Circle(), otherwise: .clear)
                .frame(width: Metrics.target, height: Metrics.target)
                .contentShape(Rectangle())
                // The pointer's highlight takes the circle's shape, not the box's.
                .contentShape(.hoverEffect, Circle().inset(by: Metrics.ring))
        }
        .buttonStyle(PressScale())
        .hoverEffect(.highlight)
        .accessibilityLabel(label)
    }
}

/// A hairline at the bottom of a bar that fills while the page loads.
struct LoadingLine: View {
    let window: WindowModel
    @ObservedObject private var load: LoadProgress

    init(window: WindowModel) {
        self.window = window
        load = window.load
    }

    var body: some View {
        // Scaled from its start, not resized: nothing is laid out again as it fills.
        Rectangle()
            .fill(Palette.muted)
            .frame(height: 2)
            .scaleEffect(x: window.loading ? max(0.08, load.fraction) : 1, y: 1, anchor: .leading)
            .animation(.easeOut(duration: 0.2), value: load.fraction)
            // Done: it reaches the end, then fades, so the load is seen to finish.
            .opacity(window.loading ? 1 : 0)
            .animation(.easeOut(duration: 0.25).delay(0.15), value: window.loading)
            // A new load starts it over at once, short and showing, without shrinking from the end.
            .transaction(value: window.loading) { transaction in
                if window.loading { transaction.animation = nil }
            }
    }
}

/// The address bar while the sidebar is put away: the way back to it, back,
/// forward and reload, and the address.
struct AddressBar: View {
    @ObservedObject var session: Session
    let window: WindowModel
    let act: (BarAction) -> Void

    var body: some View {
        HStack(spacing: 4) {
            // The sidebar put away: the way back to it.
            BarButton(symbol: session.preferences.tabsPlacement == .sidebar ? "sidebar.left" : "menubar.rectangle",
                      label: session.preferences.tabsPlacement == .sidebar ? String(localized: "Show Sidebar") : String(localized: "Show Tabs")) { act(.command(.tabBar)) }
            HistoryButtons(window: window, act: act)
            // Never typed in here: a click on it opens the command bar,
            // holding the address.
            AddressCapsule(window: window, editable: false, act: act)
            DownloadActivityButton { act(.downloads) }
            // With one space there is nowhere to go: no button for it, as in the row and the sidebar (SideSpaces).
            if session.workspace.spaces.count > 1 {
                SpaceButton(session: session, window: window, act: act, besideAddress: true)
            }
            AllTabsButton(count: session.workspace.space(window.spaceID)?.tabs.count ?? 0) { act(.showTabs) }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { LoadingLine(window: window) }
        .animation(.bar, value: window.editingAddress)
        .ignoresSafeArea(.keyboard)
    }
}

struct AllTabsButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Image(systemName: "square.on.square").font(.system(size: 14))
                Text(count.formatted()).font(.caption2).monospacedDigit()
            }
            .foregroundStyle(Palette.ink)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .accessibilityLabel("All Tabs, \(count) tabs")
    }
}

struct NarrowSplitControls: View {
    let window: WindowModel
    let act: (BarAction) -> Void

    var body: some View {
        if window.narrowSplit {
            VStack(alignment: .leading, spacing: 4) {
                Text("Split View: One Pane Visible").font(.caption).foregroundStyle(Palette.muted)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { actions }
                    VStack(alignment: .leading, spacing: 8) { actions }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(Palette.ground)
        }
    }

    private var actions: some View {
        Group {
            Button("Switch Pane", systemImage: "rectangle.2.swap") { act(.switchPane) }
            Button("Exit Split", systemImage: "rectangle") {
                if let tab = window.tabID { act(.separate(tab)) }
            }
        }
        .font(.body)
        .frame(minHeight: 44)
    }
}

/// The address in one piece of glass: where the page is, its key badge on a
/// sign-in page, the star and reload; a tap types a new address, and the
/// address and the address being typed fade into each other on it, in place.
/// The address bar's, while the sidebar is put away, and the phone bar's.
struct AddressCapsule: View {
    let window: WindowModel
    /// This capsule is the one typed in; otherwise another field is.
    let editable: Bool
    /// The site's icon before the address (AddressSummary.siteIcon).
    var siteIcon = true
    let act: (BarAction) -> Void
    @Environment(\.barScale) private var scale

    var body: some View {
        ZStack {
            if window.editingAddress && editable {
                AddressEditor(window: window, act: act)
                    .id(window.tabID)
                    .transition(.opacity)
            } else {
                HStack(spacing: 2) {
                    // On a phone, the bar's address follows the setting the iPad's tab does.
                    AddressSummary(window: window, titled: window.phone && !window.showsAddress, siteIcon: siteIcon, act: act)
                    if window.signIn { SignInBadge() }
                    // Not on a phone's bar, whose address needs the room: its page menu bookmarks.
                    if window.url != nil, scale != .thumb { BookmarkStar(window: window, act: act) }
                    // Nothing to reload on a new tab, as nothing to star.
                    if window.url != nil { ReloadButton(window: window, act: act) }
                }
                .padding(.trailing, 2)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: scale.control)
        .liquidGlass(reacting: false, in: Capsule(), otherwise: Palette.wash)
        .frame(height: scale.target)
        .animation(.bar, value: window.editingAddress)
    }
}

/// A line under the address bar: Google refusing to sign in, a page that
/// ran out of memory again and again, a page that didn't load.
struct BannerBar: View {
    let window: WindowModel
    let act: (BarAction) -> Void

    var body: some View {
        if let banner = window.banner {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: banner == .googleRefused ? "person.badge.key" : "exclamationmark.triangle")
                    .foregroundStyle(Palette.unsafe)
                Text(message(banner))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                switch banner {
                case .googleRefused:
                    Button("Go Back") { act(.back) }
                case .exhausted, .failed:
                    Button("Reload") { act(.reload) }
                    Button("Edit Address") { act(.editAddress) }
                }
                Button {
                    act(.dismissBanner)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        // 44 points to the finger, 28 to the line's layout.
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .padding(-8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.muted)
                .accessibilityLabel("Dismiss")
            }
            .font(.footnote)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.wash)
            .onAppear { announce(banner) }
            .onChange(of: banner) { _, value in announce(value) }
        }
    }

    private func announce(_ banner: Banner) {
        UIAccessibility.post(notification: .announcement, argument: message(banner))
    }

    private func message(_ banner: Banner) -> String {
        switch banner {
        case .googleRefused:
            return SignIn.fallback
        case .exhausted:
            return String(localized: "This page stopped because it ran out of memory, more than once. Close a heavy tab, then reload.")
        case .failed(let reason):
            return reason
        }
    }
}

/// A space with no tab in this window.
struct EmptySpace: View {
    @ObservedObject var session: Session
    let window: WindowModel
    let act: (BarAction) -> Void

    var body: some View {
        let space = session.workspace.space(window.spaceID)
        VStack(spacing: 14) {
            Image(systemName: space?.symbol ?? "square.grid.2x2")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(space?.color.color ?? Palette.faint)
            Text(space.map { String(localized: "Nothing open in \($0.name)") } ?? String(localized: "Nothing open"))
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(Palette.muted)
            HStack(spacing: 10) {
                // Keys only where there are keys to press (Device.keys): not on a phone without a keyboard.
                Button(Device.keys(for: .newTab).map { String(localized: "New Tab  \($0)") } ?? String(localized: "New Tab")) { act(.command(.newTab)) }
                Button(Device.keys(for: .everything).map { "\(Command.everything.title)  \($0)" } ?? Command.everything.title) {
                    act(.command(.everything))
                }
            }
            .buttonStyle(.bordered)
            .font(.footnote)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
