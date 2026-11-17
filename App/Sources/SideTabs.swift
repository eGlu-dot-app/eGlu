import PadCore
import SwiftUI
import UIKit

/// The tabs down the window's side (Settings › Tabs › In a Sidebar), drawn
/// as the Mac's sidebar is (Mac/Sources/Sidebar.swift), and standing on the
/// same ground, the space's colour (Browser's window ground): the sidebar's
/// button and back, forward and reload along the top, plain; the address
/// in glass, a tap on which types a new one in the command bar, and the
/// page's menu beside it; the space's pinned tabs as tiles that stay put,
/// each as the Mac draws it (PinnedIcon); New Tab and the space's other
/// tabs as rows that scroll, a split's two on a ground of their own; and
/// along the foot the spaces, the one you are in a disc of its colour that
/// slides to another, then Clear and Space Settings. While it shows, the
/// row along the top and the address bar go; put away (its button, or Show
/// or Hide Tab Bar), the address bar comes back with the button at its
/// start. Its rows are a little taller than the Mac's, for a finger.
struct SideTabs: View {
    @ObservedObject var session: Session
    let window: WindowModel
    let act: (BarAction) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var openBar: Set<UUID> = []

    /// The Mac sidebar's own width, as it first opens; wider only to an
    /// iPhone Duo's fold (Browser.placeSidebar).
    static let width: CGFloat = 248

    var body: some View {
        let space = session.workspace.space(window.spaceID)
        // The bar's tabs once for all its rows, not by each.
        let map = space?.barMap
        // Without the pinned tabs this device hides (Settings › Pinned Tabs).
        let row = TabRow(tabs: (space?.tabs ?? []).filter(session.preferences.shows), splits: space?.splits ?? [],
                         current: window.tabID, barTabs: Set(map?.tabs.values.map(\.id) ?? []))
        let others = session.workspace.spaces.filter { $0.id != window.spaceID }
        VStack(spacing: Side.gap) {
            HStack(spacing: 2) {
                // At the row's start, where the Mac has its window's buttons and the iPad none.
                SidePlainIcon("sidebar.left", label: String(localized: "Hide Sidebar")) { act(.command(.tabBar)) }
                Spacer(minLength: Side.gap)
                SidePlainIcon("chevron.left", label: String(localized: "Back"), enabled: window.canGoBack) { act(.back) }
                SidePlainIcon("chevron.right", label: String(localized: "Forward"), enabled: window.canGoForward) { act(.forward) }
                if window.loading {
                    SidePlainIcon("xmark", label: String(localized: "Stop")) { act(.stop) }
                } else {
                    SidePlainIcon("arrow.clockwise", label: String(localized: "Reload"), enabled: window.url != nil) { act(.reload) }
                }
            }
            .frame(height: Side.control)
            HStack(spacing: 2) {
                SideAddress(window: window, act: act)
                    .padding(.trailing, Side.gap - 2)
                SidePageMenu(window: window, act: act)
            }
            ZStack(alignment: .top) {
                VStack(spacing: Side.gap) {
                    spaceTabs(space: space, map: map, row: row, others: others)
                }
                // The space's tabs come in from its side of the row of spaces.
                .id(window.spaceID)
                .transition(spaceTurn)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .animation(.bar, value: window.spaceID)
            SideSpaces(session: session, window: window, act: act)
        }
        .padding([.top, .bottom, .leading], Side.gap)
        // As wide as the window gives it: its own width, or half an iPhone Duo folded like a book.
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity)
        .ignoresSafeArea(.keyboard)
        .coordinateSpace(.named(Self.space))
        .onChange(of: window.spaceID) { _, _ in
            openBar.removeAll()
            act(.hideTabHover)
        }
    }

    /// As the Mac's (and Arc's), the tabs of a space chosen come in from
    /// the side it is on in the row, a little way, as the space left fades
    /// where it is. Not out the other way: a view gone keeps the transition
    /// it was last drawn with, which is the way of the switch before this
    /// one. Fading alone under Reduce Motion, and where there is no way
    /// between the two (the space left is gone).
    private var spaceTurn: AnyTransition {
        // Offsets aren't mirrored: from the left, right to left, is toward the row's end.
        let side = CGFloat(window.spaceSide) * (layoutDirection == .rightToLeft ? -1 : 1)
        guard !reduceMotion, side != 0 else { return .opacity }
        return .asymmetric(insertion: .opacity.combined(with: .offset(x: 24 * side)), removal: .opacity)
    }

    /// The space's own, under its address: its pinned tiles, and the list of its tabs.
    @ViewBuilder
    private func spaceTabs(space: Space?, map: Space.BarMap?, row: TabRow, others: [Space]) -> some View {
        // The pinned tiles stay put while the tabs under them scroll, as the Mac's do.
        if !row.pinned.isEmpty {
            PinnedRows(spacing: Side.gap) {
                ForEach(row.pinned) { tab in
                    SidePinnedTab(window: window, tab: tab, row: row, others: others, act: act)
                }
            }
            .animation(.bar, value: row.pinned.map(\.id))
        }
        ScrollView {
            VStack(spacing: 2) {
                if let space, let map, let bar = space.bar, !(bar.children ?? []).isEmpty {
                    let canSplit = BarBookmarkRow.canSplit(window, in: space, map: map)
                    // The bar's rows a group of their own, as far from the rows under them as the Mac's.
                    VStack(spacing: 2) {
                        ForEach(Bookmarks.rows(of: bar.children ?? [], opening: openBar, keeping: Set(map.tabs.keys)), id: \.item.id) { entry in
                            BarBookmarkRow(window: window, space: space, map: map, canSplit: canSplit, item: entry.item,
                                           depth: entry.depth, open: openBar.contains(entry.item.id), source: .sidebar, toggle: {
                                withAnimation(.bar) { openBar.formSymmetricDifference([entry.item.id]) }
                            }, act: act)
                        }
                    }
                    .padding(.bottom, 4)
                }
                Button { act(.showTabs) } label: {
                    Label("All Tabs (\(space?.tabs.count ?? 0))", systemImage: "square.on.square")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, minHeight: Side.row, alignment: .leading)
                        .padding(.horizontal, 10)
                }
                .buttonStyle(SideRowStyle())
                SideBookmarksButton(window: window)
                SideLine()
                    .padding(.vertical, 4)
                SideNewTab { act(.command(.newTab)) }
                ForEach(row.items) { item in
                    VStack(spacing: 0) {
                        ForEach(item.tabs) { tab in
                            SideTab(window: window, tab: tab, row: row, others: others, act: act)
                        }
                    }
                    // A split's two on a ground of their own, as the Mac's sidebar has them.
                    .padding(item.tabs.count > 1 ? 2 : 0)
                    .background {
                        if item.tabs.count > 1 {
                            RoundedRectangle(cornerRadius: Side.rowCorner + 2, style: .continuous).fill(Side.wash)
                        }
                    }
                }
            }
            .padding(Side.bleed)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.space)).minY } action: { _ in act(.hideTabHover) }
            .animation(.bar, value: row.others.map(\.id))
        }
        .scrollIndicators(.never)
        .padding(-Side.bleed)
        .feathered(.vertical)
        // The bookmarks out over the list, from where their row is.
        .overlay(alignment: .top) {
            if window.bookmarksOpen {
                SideBookmarksPanel(session: session, window: window, act: act)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .scale(scale: 0.96, anchor: .top).combined(with: .opacity), removal: .opacity))
            }
        }
    }

    /// The sidebar's own coordinates, its hosting view's: where the
    /// bookmarks' frame is measured, for a touch in the window to be compared.
    nonisolated static let space = "sidebar"
}

/// The Mac sidebar's measures (Mac/Sources/Design.swift, Metrics), with
/// rows and buttons a little taller, for a finger.
enum Side {
    static let gap: CGFloat = 8
    static let control: CGFloat = 32
    static let field: CGFloat = 34
    static let row: CGFloat = 36
    static let rowCorner: CGFloat = 12
    static let tile: CGFloat = 44
    static let tileIcon: CGFloat = 18
    static let tileCorner: CGFloat = 17
    /// What the list's glass draws past its rows: room for it inside the scroll view.
    static let bleed: CGFloat = 4
    /// The window's ground round the page's card, and the card's corners, as the Mac's.
    static let bezel: CGFloat = 5
    static let card: CGFloat = 11
    /// What is quieter than the words: the words' own colour, see-through,
    /// never a grey of its own, which stands on the space's colour as a patch.
    static let secondary = Palette.ink.opacity(0.5)
    /// Under what the pointer is on, and under what is held down, as the
    /// Mac's (Palette.hover, .press): black in the light, white in the dark.
    static let hover = shade(light: 0.09, dark: 0.13)
    static let press = shade(light: 0.16, dark: 0.22)
    /// A split's two tabs' ground, as the Mac's (Palette.wash): see-through black.
    static let wash = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0.22) : UIColor(white: 0, alpha: 0.05) })

    private static func shade(light: CGFloat, dark: CGFloat) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: dark) : UIColor(white: 0, alpha: light)
        })
    }
}

/// The window's ground while the tabs are in a sidebar: the space's colour,
/// as the Mac's window is (SpaceWash), deeper at the top left.
struct WindowGround: View {
    @ObservedObject var session: Session
    let window: WindowModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let colour = (session.workspace.space(window.spaceID)?.color ?? .blue).color
        let strength = scheme == .dark ? 0.26 : 0.34
        LinearGradient(colors: [colour.opacity(strength), colour.opacity(strength * 0.45)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .background(Palette.ground)
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.35), value: colour)
    }
}

/// A plain symbol button, as the Mac sidebar's are: the label colour,
/// dimmed when it can't be pressed, on a see-through shade under the
/// pointer and while held.
struct SidePlainIcon: View {
    let symbol: String
    let label: String
    var enabled = true
    let action: () -> Void

    init(_ symbol: String, label: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(SidePlainStyle())
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

struct SidePlainStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SidePlainBody(configuration: configuration)
    }
}

private struct SidePlainBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(enabled ? Palette.ink.opacity(0.8) : Palette.ink.opacity(0.25))
            .frame(width: Side.control, height: Side.control)
            .background(shape.fill(configuration.isPressed && enabled ? Side.press : hovering && enabled ? Side.hover : .clear))
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// The address in glass, as the Mac's: where the page is, or what was
/// searched for; a tap types a new one in the command bar. A line along its
/// foot fills while the page loads.
private struct SideAddress: View {
    let window: WindowModel
    let act: (BarAction) -> Void
    @ObservedObject private var load: LoadProgress
    @State private var hovering = false

    init(window: WindowModel, act: @escaping (BarAction) -> Void) {
        self.window = window
        self.act = act
        load = window.load
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Side.rowCorner, style: .continuous)
        Button { act(.editAddress) } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Side.secondary)
                    .frame(width: 16)
                Text(label)
                    .font(.subheadline.weight(window.url == nil ? .regular : .medium))
                    .foregroundStyle(window.url == nil ? Side.secondary : Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
            }
            .padding(.leading, 10)
            .frame(minHeight: Side.field)
            .contentShape(shape)
        }
        .buttonStyle(PressScale())
        .overlay(alignment: .bottomLeading) {
            if window.loading {
                GeometryReader { box in
                    Capsule()
                        .fill(Palette.ink.opacity(0.35))
                        .frame(width: max(box.size.width * load.fraction, 12), height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .animation(.easeOut(duration: 0.2), value: load.fraction)
                }
                .padding(.horizontal, 8)
                .allowsHitTesting(false)
            }
        }
        .background(shape.fill(hovering ? Side.hover : .clear))
        .liquidGlass(reacting: false, in: shape, otherwise: Palette.wash)
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .accessibilityLabel("Address")
        .accessibilityValue(window.url?.absoluteString ?? "")
        .accessibilityHint("Type a new address or a search")
    }

    private var icon: String {
        guard let url = window.url, window.searchWords == nil else { return "magnifyingglass" }
        if window.insecure { return "exclamationmark.triangle.fill" }
        return url.scheme == "https" ? "lock.fill" : "doc"
    }

    /// The site, as Arc shows it: its host without www.; a search's words.
    private var label: String {
        guard let url = window.url else { return AddressEditor.placeholder }
        if let words = window.searchWords { return words }
        guard let host = url.host() else { return Destination.pretty(url) }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// The page's own commands, beside the sidebar's address or in the tab on
/// screen along the top (TopTabs): Find, Share and Handoff, the link, the
/// bookmark, the site's switches; then everything else. Plain, as the Mac's … is.
struct SidePageMenu: View {
    let window: WindowModel
    let act: (BarAction) -> Void
    /// In a tab, as small as its ✕ (SideClose).
    var inTab = false
    @State private var hovering = false

    var body: some View {
        Group {
            if inTab {
                Menu { items } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(hovering ? Palette.ink : Side.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(hovering ? Side.hover : .clear))
                        .contentShape(Circle().inset(by: -6))
                }
                .buttonStyle(PressScale())
                .onHover { hovering = $0 }
            } else {
                Menu { items } label: {
                    Image(systemName: "ellipsis")
                }
                .buttonStyle(SidePlainStyle())
            }
        }
        .accessibilityLabel("Page Menu")
    }

    @ViewBuilder
    private var items: some View {
        PageItems(window: window, act: act)
        Section { AppItems(act: act) }
    }
}

/// A pinned tab's tile, as the Mac's: the one on screen and the one under
/// the pointer on glass and lit (PinnedIcon), the one on screen's glass
/// tinted with its icon's colour and its light filling it, its icon's
/// colour at the core and the space's at the edge (CoreLight); the others
/// at rest, a lighter ground with a thin line round it and the icon as it
/// is (PinnedRest), as the Mac's are (asked for on 3 November 2026).
private struct SidePinnedTab: View {
    let window: WindowModel
    let tab: TabRecord
    let row: TabRow
    let others: [Space]
    let act: (BarAction) -> Void
    @ObservedObject private var icons = SiteIcons.shared
    @State private var pointer: CGPoint?
    @State private var size = CGSize.zero
    @State private var hovering = false
    @Environment(\.spaceColor) private var space
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let selected = tab.id == window.tabID
        let glassy = selected || hovering
        let shape = RoundedRectangle(cornerRadius: Side.tileCorner, style: .continuous)
        let url = tab.url ?? tab.pinned
        let colour = Session.shared.workspace.space(window.spaceID)?.color ?? .blue
        let ground = selected ? PinnedIcon.tileTint(for: url, colour: colour) : nil
        Button {
            act(.select(tab.id))
        } label: {
            ZStack {
                let lean = Plate.lean(toward: pointer, in: size, reach: CGSize(width: 13, height: 9))
                PointerGlow(lean: lean)
                PinnedIcon(url: url, open: selected, colour: colour, size: Side.tileIcon, lean: lean, lit: glassy,
                           current: selected, fills: true)
                // Open, as the phone's dock marks it: a dot just under the icon.
                OpenDot(shown: Pinned.isOpen(tab))
                    .offset(y: OpenDot.under(icon: Side.tileIcon))
            }
            .frame(maxWidth: .infinity)
            .frame(height: Side.tile)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .background(shape.fill(hovering && !selected ? Side.hover : .clear))
            .clipShape(shape)
            .contentShape(shape)
            .background {
                if glassy {
                    Color.clear.liquidGlass(.regular, tint: selected ? (ground ?? Palette.ink.opacity(0.12)) : nil,
                                            reacting: false, in: shape, otherwise: selected ? Palette.card : Palette.wash)
                } else {
                    shape.fill(PinnedRest.ground(scheme))
                }
            }
            .overlay { if !glassy { shape.strokeBorder(PinnedRest.line(scheme), lineWidth: 1) } }
        }
        // A press gives a little, as the Mac's tile does.
        .buttonStyle(PressScale())
        .modifier(TabHoverModifier(id: tab.id, tab: tab.id, title: tab.label, url: tab.url ?? tab.pinned,
                                   isOpen: Pinned.isOpen(tab), source: .sidebar, act: act))
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .onContinuousHover { phase in
            withAnimation(.spring(duration: 0.6, bounce: 0)) {
                if case .active(let point) = phase { pointer = point } else { pointer = nil }
            }
        }
        .contextMenu { TabMenuItems(window: window, tab: tab, row: row, others: others, act: act) }
        .draggable(TabDrop(id: tab.id)) { SiteIconView(url: url, size: 24).environment(\.spaceColor, space) }
        .dropDestination(for: TabDrop.self) { drops, _ in
            guard let drop = drops.first, drop.id != tab.id else { return false }
            act(.placeTab(drop.id, before: tab.id))
            return true
        }
        .animation(.bar, value: selected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.title.isEmpty ? String(localized: "Pinned Tab") : tab.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The way to the space's bookmarks, where they used to lie over the tabs:
/// a row as New Tab is, which brings them out over the list as a popover
/// (SideBookmarksPanel), so they never read as more tabs.
private struct SideBookmarksButton: View {
    let window: WindowModel

    var body: some View {
        Button {
            withAnimation(.bar) { window.bookmarksOpen.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "book")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                Text("Other Bookmarks")
                    .font(.subheadline)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Side.secondary)
            .padding(.horizontal, 10)
            .frame(minHeight: Side.row)
            .contentShape(RoundedRectangle(cornerRadius: Side.rowCorner, style: .continuous))
        }
        .buttonStyle(SideRowStyle())
        .accessibilityHint("Shows the space's bookmarks")
    }
}

/// The space's bookmarks, out over the sidebar's list as a popover is, from
/// where their row is: a pane of Liquid Glass, untinted, lifted by a soft
/// shadow, with a name and ✕, so they read as something passing over the
/// sidebar, not as more of its tabs.
/// A tap opens one in the tab on screen and puts them away; a ⌘-click opens
/// it in a new tab and leaves them out, for the next; a folder opens in
/// place. ✕, Escape, another space, or a touch anywhere else in the window
/// (Browser.pressed) puts them away.
private struct SideBookmarksPanel: View {
    @ObservedObject var session: Session
    let window: WindowModel
    let act: (BarAction) -> Void
    /// The folders open, while they are out.
    @State private var open: Set<UUID> = []
    @AccessibilityFocusState private var closeFocused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let space = session.workspace.space(window.spaceID)
        let colour = space?.color ?? .blue
        ZStack(alignment: .top) {
            // Outside them, a tap only puts them away, as outside a popover.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { close() }
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("Other Bookmarks")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                    Spacer(minLength: 0)
                    SideClose(label: String(localized: "Close Other Bookmarks")) { close() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityFocused($closeFocused)
                }
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .frame(height: 40)
                // As tall as they are, and no taller than the list: past that they scroll.
                ViewThatFits(in: .vertical) {
                    rows(Bookmarks.others(in: space?.bookmarks ?? []), colour: colour)
                    ScrollView { rows(Bookmarks.others(in: space?.bookmarks ?? []), colour: colour) }
                        .scrollIndicators(.never)
                }
            }
            .padding(.bottom, 6)
            .floatingGlass(cornerRadius: Side.rowCorner + 6, tint: nil)
            .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.14), radius: 24, y: 10)
            // For the window's watch on touches: one off this puts it away (Browser.pressed).
            // In the sidebar's own space, which the touch is brought into: `.global` is
            // the hosting view's, which stands below the status bar, not the window's.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SideTabs.space)) } action: { window.bookmarksFrame = $0 }
            // The list's own column: its edges those of the address and the tiles above,
            // the sidebar's gap above and below it.
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { close() }
        .onAppear { closeFocused = true }
    }

    private func rows(_ bookmarks: [Bookmark], colour: SpaceColor) -> some View {
        VStack(spacing: 2) {
            if bookmarks.isEmpty {
                Text(Device.keys(for: .bookmark).map { String(localized: "Star a page (\($0)) to keep it here") } ?? String(localized: "Star a page to keep it here"))
                    .font(.caption)
                    .foregroundStyle(Side.secondary)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            }
            ForEach(Bookmarks.rows(of: bookmarks, opening: open), id: \.item.id) { row in
                SideBookmark(item: row.item, depth: row.depth, colour: colour, open: open.contains(row.item.id), act: act,
                             chose: chose) {
                    withAnimation(.bar) { open.formSymmetricDifference([row.item.id]) }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 6)
    }

    /// In the tab on screen, and they go; with ⌘, in a new tab, and they stay.
    private func chose(_ url: URL) {
        HistoryRecorder.shared.expect(.bookmark, url)
        if window.commandClick {
            act(.openInNewTab(url))
        } else {
            act(.open(url))
            close()
        }
    }

    private func close() {
        withAnimation(.bar) { window.bookmarksOpen = false }
    }
}

/// A bookmark's row, as a tab's is: its site's icon and its name; a folder
/// in the space's colour, turning to show it is open.
private struct SideBookmark: View {
    let item: Bookmark
    let depth: Int
    let colour: SpaceColor
    let open: Bool
    let act: (BarAction) -> Void
    let chose: (URL) -> Void
    let toggle: () -> Void

    var body: some View {
        Button {
            if let url = item.url { chose(url) } else { toggle() }
        } label: {
            HStack(spacing: 8) {
                Group {
                    if item.isFolder {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(colour.color)
                    } else {
                        SiteIconView(url: item.url, size: 16)
                    }
                }
                .frame(width: 16, height: 16)
                Text(item.label)
                    .font(.subheadline)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if item.isFolder {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Side.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
            }
            .padding(.leading, 10 + CGFloat(depth) * 16)
            .padding(.trailing, 10)
            .frame(minHeight: Side.row)
            .contentShape(RoundedRectangle(cornerRadius: Side.rowCorner, style: .continuous))
        }
        .buttonStyle(SideRowStyle())
        .contextMenu {
            if let url = item.url {
                Button("Open in New Tab", systemImage: "plus.square.on.square") { act(.openInNewTab(url)) }
                Button("Copy Address", systemImage: "doc.on.doc") { act(.copy(url)) }
            }
        }
        .accessibilityLabel(item.isFolder ? String(localized: "\(item.label), folder") : item.label)
        .accessibilityValue(item.isFolder ? (open ? "Open" : "Closed") : "")
    }
}

/// A bookmark of the bookmarks bar, as the Mac's (BarRow): a dot left of its
/// icon while it is open, its icon and name; gone on from its bookmark, a
/// slash and where it is now. The one on screen raised in glass, a close
/// button on an open one under the pointer, its card after a moment
/// (TabHoverCard). A folder in the space's colour, turning to show it is
/// open. A tab dropped on a row goes into the bar before it, on a folder
/// into the folder.
struct BarBookmarkRow: View {
    let window: WindowModel
    let space: Space
    /// The space's bar tabs, worked out once by the list for all its rows.
    let map: Space.BarMap
    /// Whether the tab on screen is one of the others, for Open in Split
    /// View: the same for every row (`canSplit(_:in:map:)`).
    let canSplit: Bool
    let item: Bookmark
    let depth: Int
    let open: Bool
    let source: TabHoverSource
    let toggle: () -> Void
    let act: (BarAction) -> Void
    @State private var hovering = false

    /// Whether the tab on screen is one of the others, which a bookmark can
    /// open beside in a split, for a list to work out once for its rows.
    static func canSplit(_ window: WindowModel, in space: Space, map: Space.BarMap) -> Bool {
        space.tabs.contains { $0.id == window.tabID && !$0.isPinned && !space.isInBar($0, in: map) }
    }

    var body: some View {
        let tab = map.tabs[item.id]
        let away = tab.map { space.isAwayFromHome($0, in: map) } ?? false
        let selected = tab?.id == window.tabID && tab != nil
        let inPopover = source == .window
        let shape = inPopover ? Self.popoverRow : AnyShape(RoundedRectangle(cornerRadius: Side.rowCorner, style: .continuous))
        HStack(spacing: 8) {
            Button {
                act(.hideTabHover)
                if item.isFolder {
                    toggle()
                } else {
                    act(.openFromBar(item.id))
                }
            } label: {
                HStack(spacing: 8) {
                    Group {
                        if item.isFolder {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(space.color.color)
                        } else {
                            SiteIconView(url: item.url, size: 16)
                        }
                    }
                    .frame(width: 16, height: 16)
                    if let tab, away {
                        // The slash closer to the words than the icon is: "where it is now" is one thing.
                        HStack(spacing: 5) {
                            Text(verbatim: "/")
                                .foregroundStyle(Side.secondary)
                            Text(tab.label)
                                .lineLimit(1)
                        }
                    } else {
                        Text(item.label)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if item.isFolder {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Side.secondary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                }
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Palette.ink : Palette.ink.opacity(0.85))
                .frame(maxWidth: .infinity, minHeight: Side.row, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            if let tab, hovering {
                SideClose { act(.close(tab.id)) }
                    .transition(.opacity)
            }
        }
        .padding(.leading, 10 + CGFloat(depth) * 16)
        .padding(.trailing, 6)
        .frame(minHeight: Side.row)
        // Open: a dot left of the icon, nearer it than the row's edge.
        .overlay(alignment: .leading) {
            OpenDot(shown: tab != nil)
                .padding(.leading, OpenDot.before(lead: 10) + CGFloat(depth) * 16)
        }
        .background {
            if selected, !inPopover {
                Color.clear.liquidGlass(reacting: false, in: shape, otherwise: Palette.card)
            } else {
                // In the popover, already glass, the one on screen shaded as a menu's chosen row.
                shape.fill(selected ? Side.press : hovering ? Side.hover : .clear)
            }
        }
        .contentShape(shape)
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .modifier(TabHoverModifier(id: item.id, tab: tab?.id, title: tab?.label ?? item.label,
                                   url: tab?.url ?? item.url, isOpen: tab != nil, source: source, act: act))
        .contextMenu {
            if let url = item.url {
                Button("Open in New Tab", systemImage: "plus.square.on.square") { act(.openInNewTab(url)) }
                Button("Copy Address", systemImage: "doc.on.doc") { act(.copy(url)) }
            }
            if let tab {
                Button("Back to Pinned Address", systemImage: "arrow.uturn.backward") { act(.backToPinned(tab.id)) }
                    .disabled(!away)
                Button("Close", systemImage: "xmark") { act(.close(tab.id)) }
            }
            // The tab on screen, when it is one of the others, is never this row's: that one is the bar's.
            if let url = tab?.url ?? item.url, canSplit {
                Button("Open in Split View", systemImage: "rectangle.split.2x1") { act(.splitWithPage(url)) }
            }
            Button("Remove from Bookmarks Bar", systemImage: "bookmark.slash", role: .destructive) {
                act(.removeBookmark(item.id))
            }
        }
        .dropDestination(for: TabDrop.self) { drops, _ in
            guard let drop = drops.first, drop.id != tab?.id else { return false }
            let folder = item.isFolder ? item.id : Bookmarks.parent(of: item.id, in: space.bookmarks) ?? space.bar?.id
            act(.addToBar(drop.id, into: folder, before: item.isFolder ? nil : item.id))
            return true
        }
        .animation(.bar, value: selected)
        .accessibilityElement(children: .contain)
        .accessibilityValue(item.isFolder ? (open ? "Open" : "Closed") : "")
    }
}

extension BarBookmarkRow {
    /// A row's shape in the popover along the top: its corners as far in
    /// from the popover's as the row is from its edge, as the system's own
    /// menus have them, and the sidebar's corners at least.
    static var popoverRow: AnyShape {
        if #available(iOS 26.0, *) {
            return AnyShape(ConcentricRectangle(corners: .concentric(minimum: .fixed(Side.rowCorner)), isUniform: true))
        }
        return AnyShape(RoundedRectangle(cornerRadius: Side.rowCorner, style: .continuous))
    }
}

/// Reports pointer entry and the item's frame to the window that hosts its card.
struct TabHoverModifier: ViewModifier {
    let id: UUID
    let tab: UUID?
    let title: String
    let url: URL?
    let isOpen: Bool
    let source: TabHoverSource
    let act: (BarAction) -> Void
    @State private var frame = CGRect.zero
    @State private var anchor = TabHoverAnchor()

    func body(content: Content) -> some View {
        content
            .background(TabHoverAnchorView(anchor: anchor).allowsHitTesting(false))
            .onGeometryChange(for: CGRect.self) { proxy in
                switch source {
                case .sidebar: proxy.frame(in: .named(SideTabs.space))
                case .top: proxy.frame(in: .named(TopTabs.space))
                case .window: .zero
                }
            } action: { frame = $0 }
            .onHover { inside in
                if inside {
                    let rect = source == .window ? anchor.view.map { $0.convert($0.bounds, to: nil) } ?? frame : frame
                    act(.hoverTab(TabHover(id: id, tab: tab, title: title, url: url, isOpen: isOpen, anchor: rect, source: source)))
                } else {
                    act(.leaveTab(id))
                }
            }
            // A touch anywhere puts the card away (Browser.pressed).
            .onDisappear { act(.leaveTab(id)) }
    }
}

/// The view that measures a row inside a system popover in window coordinates.
private final class TabHoverAnchor {
    weak var view: UIView?
}

private struct TabHoverAnchorView: UIViewRepresentable {
    let anchor: TabHoverAnchor

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        anchor.view = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        anchor.view = uiView
    }
}

/// The line between the sidebar's sections, as the Mac's.
private struct SideLine: View {
    var body: some View {
        Rectangle()
            .fill(Side.secondary.opacity(0.25))
            .frame(height: 1)
            .padding(.horizontal, 10)
            .accessibilityHidden(true)
    }
}

/// New Tab, at the head of the tabs, as the Mac's sidebar has it.
private struct SideNewTab: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                Text("New Tab")
                    .font(.subheadline)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Side.secondary)
            .padding(.horizontal, 10)
            .frame(minHeight: Side.row)
            .contentShape(RoundedRectangle(cornerRadius: Side.rowCorner, style: .continuous))
        }
        .buttonStyle(SideRowStyle())
    }
}

/// A row's press and hover, as the Mac's: a see-through shade.
private struct SideRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SideRowBody(configuration: configuration)
    }
}

private struct SideRowBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: Side.rowCorner, style: .continuous)
                .fill(configuration.isPressed ? Side.press : hovering ? Side.hover : .clear))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A tab in the list, as the Mac's row: its icon and its name, and a close
/// button under the pointer and on the one on screen, which is raised in
/// glass; the others shade under the pointer.
private struct SideTab: View {
    let window: WindowModel
    let tab: TabRecord
    let row: TabRow
    let others: [Space]
    let act: (BarAction) -> Void
    @State private var hovering = false

    static let corner = Side.rowCorner

    var body: some View {
        let selected = tab.id == window.tabID
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        HStack(spacing: 8) {
            Button { act(.select(tab.id)) } label: {
                HStack(spacing: 8) {
                    ZStack {
                        if selected, window.loading {
                            ProgressView().controlSize(.mini)
                        } else {
                            SiteIconView(url: tab.url, size: 16)
                                // A page let go of until it is opened again is a little quieter, as the Mac's.
                                .opacity(selected || Session.shared.pages.isLive(tab.id) ? 1 : 0.75)
                        }
                    }
                    .frame(width: 16, height: 16)
                    Text(tab.label)
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Palette.ink : Palette.ink.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: Side.row, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tab.label)
            .accessibilityAddTraits(selected ? .isSelected : [])
            // Under the pointer, as the Mac's; on the tab on screen too, for a finger, which has no pointer.
            if selected || hovering {
                SideClose { act(.close(tab.id)) }
                    .transition(.opacity)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(minHeight: Side.row)
        .background {
            if selected {
                Color.clear.liquidGlass(reacting: false, in: shape, otherwise: Palette.card)
            } else {
                shape.fill(hovering ? Side.hover : .clear)
            }
        }
        .contentShape(shape)
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .contextMenu { TabMenuItems(window: window, tab: tab, row: row, others: others, act: act) }
        .draggable(TabDrop(id: tab.id)) {
            HStack(spacing: 8) {
                SiteIconView(url: tab.url, size: 16)
                Text(tab.title).font(.subheadline).lineLimit(1)
            }
            .padding(10)
        }
        .tellsDrag(of: tab.id, to: window)
        .dropDestination(for: TabDrop.self) { drops, _ in
            guard let drop = drops.first, drop.id != tab.id else { return false }
            act(.placeTab(drop.id, before: tab.id))
            return true
        }
        .animation(.bar, value: selected)
        .accessibilityElement(children: .contain)
    }
}

/// A row's close button, as the Mac's: a cross on a circle that shades
/// under the pointer, quiet until it is pointed at.
struct SideClose: View {
    var label = String(localized: "Close Tab")
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(hovering ? Side.hover : .clear))
                .contentShape(Circle().inset(by: -6))
        }
        .buttonStyle(PressScale())
        .foregroundStyle(hovering ? Palette.ink : Side.secondary)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
    }
}

/// The sidebar's foot, as the Mac's: the spaces in one piece of glass, each
/// its icon, the one you are in marked by one disc of its colour that
/// slides to another as you go there; then Clear (every tab that isn't
/// pinned or in the bookmarks bar closes) and Space Settings. The end of the row along the top too
/// (TopTabs): the spaces and Space Settings, no Clear, with no room between
/// them but the spaces' gap.
struct SideSpaces: View {
    @ObservedObject var session: Session
    let window: WindowModel
    let act: (BarAction) -> Void
    /// In the row along the top.
    var inRow = false
    @Namespace private var places
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let space = session.workspace.space(window.spaceID)
        let unpinned = space?.otherTabs.map(\.id) ?? []
        HStack(spacing: 2) {
            // With one space there is nowhere to go: its buttons are left out, as on the Mac (a phone's bar keeps them).
            if session.workspace.spaces.count > 1 {
                ViewThatFits(in: .horizontal) {
                    spaces(compact: false)
                    spaces(compact: true)
                    // More than the room there is: they scroll, with the one you are in
                    // in the middle, wherever it was chosen from, as far as the row's ends let it.
                    ScrollViewReader { reader in
                        ScrollView(.horizontal) { spaces(compact: true, glass: false) }
                            .scrollIndicators(.never)
                            .feathered(.horizontal, length: 12)
                            .onAppear { reader.scrollTo(window.spaceID, anchor: .center) }
                            .onChange(of: window.spaceID) { _, space in
                                withAnimation(reduceMotion ? nil : .bar) { reader.scrollTo(space, anchor: .center) }
                            }
                    }
                    .padding(3)
                    .liquidGlass(reacting: false, in: Capsule(), otherwise: Palette.wash)
                }
                // In the row, a gap from the plain buttons either side, which are 2 points from each other.
                .padding(.horizontal, inRow ? Side.gap - 2 : 0)
            }
            if !inRow {
                Spacer(minLength: Side.gap)
                SidePlainIcon("trash", label: String(localized: "Clear: Close Every Tab That Isn’t Pinned or in the Bookmarks Bar"), enabled: !unpinned.isEmpty) {
                    act(.closeTabs(unpinned))
                }
            }
            // The app's Settings, from where the tabs are; a space's own are in its menu and in Settings › Spaces.
            if !inRow { DownloadActivityButton { act(.downloads) } }
            SidePlainIcon("gearshape", label: String(localized: "Settings")) { act(.command(.settings)) }
        }
        .frame(height: Side.field)
    }

    @ViewBuilder
    private func spaces(compact: Bool, glass: Bool = true) -> some View {
        let current = session.workspace.space(window.spaceID)
        let row = HStack(spacing: 2) {
            ForEach(session.workspace.spaces) { space in
                SideSpaceButton(window: window, space: space, compact: compact, places: places, act: act)
                    // What the row scrolls to.
                    .id(space.id)
            }
        }
        .background {
            if let current {
                Circle()
                    .fill(current.color.color)
                    .matchedGeometryEffect(id: SideSpaceButton.place(current.id, compact: compact), in: places, isSource: false)
            }
        }
        // Under Reduce Motion the disc is at the chosen space at once, not slid there.
        .animation(reduceMotion ? nil : .bar, value: window.spaceID)
        if glass {
            row.padding(3).liquidGlass(reacting: false, in: Capsule(), otherwise: Palette.wash)
        } else {
            row
        }
    }
}

/// A space in the sidebar's foot and the row along the top: its icon, on the
/// disc of its colour while it is the one you are in; its menu has the rest.
private struct SideSpaceButton: View {
    let window: WindowModel
    let space: Space
    let compact: Bool
    let places: Namespace.ID
    let act: (BarAction) -> Void
    @State private var hovering = false

    static func place(_ space: UUID, compact: Bool) -> String {
        "\(space.uuidString)\(compact ? "-compact" : "")"
    }

    var body: some View {
        let chosen = window.spaceID == space.id
        let side: CGFloat = compact ? 24 : 28
        Button {
            act(.switchSpace(space.id))
        } label: {
            Image(systemName: space.symbol)
                .font(.system(size: compact ? 10 : 12, weight: .semibold))
                .foregroundStyle(chosen ? space.color.ink : hovering ? Palette.ink : Side.secondary)
                .frame(width: side, height: side)
                .matchedGeometryEffect(id: Self.place(space.id, compact: compact), in: places, isSource: true)
                .background { if !chosen { Circle().fill(hovering ? Side.hover : .clear) } }
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .contextMenu {
            Button("Space Settings…", systemImage: "slider.horizontal.3") { act(.spaceSettings(space.id)) }
            if window.makesWindows {
                Button("Open in New Window", systemImage: "macwindow.badge.plus") { act(.spaceInNewWindow(space.id)) }
            }
            // As the phone's space menu has them: without a keyboard these were only command rows here.
            Button("New Space…", systemImage: "plus") { act(.command(.newSpace)) }
            if Session.shared.workspace.spaces.count > 1 {
                Button("Remove Space…", systemImage: "trash", role: .destructive) { act(.removeSpace(space.id)) }
            }
        }
        .accessibilityLabel(space.name)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }
}

/// A tab dragged to another place in the sidebar.
struct TabDrop: Codable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

extension View {
    /// Tells the window while this tab is dragged, so the page can show
    /// where it would open beside it (SplitDrop). iOS 27 says how a drag
    /// goes; before it the page offers nothing, and the tab's menu splits.
    @ViewBuilder
    func tellsDrag(of tab: UUID, to window: WindowModel) -> some View {
        if #available(iOS 27.0, *) {
            onDragSessionUpdated { session in
                switch session.phase {
                case .ended, .dataTransferCompleted:
                    if window.draggedTab == tab { window.draggedTab = nil }
                default:
                    if window.draggedTab != tab { window.draggedTab = tab }
                }
            }
        } else {
            self
        }
    }
}

/// A tab's menu, in the sidebar and in the row along the top (TopTabs).
struct TabMenuItems: View {
    let window: WindowModel
    let tab: TabRecord
    let row: TabRow
    let others: [Space]
    let act: (BarAction) -> Void

    var body: some View {
        let selected = tab.id == window.tabID
        let paired = row.paired.contains(tab.id)
        let space = Session.shared.workspace.space(window.spaceID)
        let ordinary = space?.otherTabs ?? []
        let inBar = space?.isInBar(tab) == true
        if selected {
            Section { PageItems(window: window, act: act) }
        } else if let url = tab.isPinned ? tab.url ?? tab.pinned : tab.url {
            // A tab not on screen: its address to copy or send, as the phone's tab card has.
            Section {
                Button("Copy Link", systemImage: "doc.on.doc") { act(.copy(url)) }
                ShareLink("Share…", item: Tracking.clean(url))
            }
        }
        if tab.isPinned {
            // Where it is pinned, and going back there or pinning it here
            // instead, as the phone's pinned button has them.
            Section(tab.pinnedAddress.map { String(localized: "Pinned to \($0)") } ?? "") {
                Button("Back to Pinned Address", systemImage: "arrow.uturn.backward") { act(.backToPinned(tab.id)) }
                    .disabled(!tab.isAwayFromPinned)
                Button("Replace with Current Page", systemImage: "pin") { act(.repin(tab.id)) }
                    .disabled(!tab.isAwayFromPinned)
                Button("Unpin Tab", systemImage: "pin.slash") { act(.unpin(tab.id)) }
                if let url = tab.url ?? tab.pinned,
                   ordinary.contains(where: { $0.id == window.tabID && $0.id != tab.id }) {
                    Button("Open in Split View", systemImage: "rectangle.split.2x1") { act(.splitWithPage(url)) }
                }
            }
        } else if inBar, let bookmark = tab.bookmark {
            Section {
                Button("Back to Pinned Address", systemImage: "arrow.uturn.backward") { act(.backToPinned(tab.id)) }
                    .disabled(space?.isAwayFromHome(tab) != true)
                Button("Remove from Bookmarks Bar", systemImage: "bookmark.slash") { act(.removeBookmark(bookmark)) }
            }
        } else {
            Section {
                if tab.url != nil {
                    Button("Add to Bookmarks Bar", systemImage: "bookmark") { act(.addToBar(tab.id, into: nil, before: nil)) }
                }
                Button("Pin Tab", systemImage: "pin") { act(.pin(tab.id)) }
                    .disabled(tab.url == nil)
                if paired {
                    Button("Separate Tabs", systemImage: "rectangle") { act(.separate(tab.id)) }
                    Button("Swap Sides", systemImage: "arrow.left.arrow.right") { act(.swapSides(tab.id)) }
                } else if selected {
                    Button("Split with New Tab", systemImage: "rectangle.split.2x1") { act(.splitWithNewTab) }
                } else if row.current.map({ current in ordinary.contains { $0.id == current.id } }) == true {
                    Button("Open in Split View", systemImage: "rectangle.split.2x1") { act(.splitWith(tab.id)) }
                }
            }
        }
        if ordinary.count > 1 {
            Menu("Arrange Tabs By", systemImage: "arrow.up.arrow.down") {
                Button("Title", systemImage: "textformat") { act(.arrangeTabs(.title)) }
                Button("Website", systemImage: "globe") { act(.arrangeTabs(.website)) }
            }
        }
        Section {
            Button("Close Tab", systemImage: "xmark") { act(.close(tab.id)) }
            if !tab.isPinned, !inBar, ordinary.count > 1 {
                Button("Close Other Tabs", systemImage: "xmark.square", role: .destructive) {
                    act(.closeTabs(ordinary.map(\.id).filter { $0 != tab.id }))
                }
            }
            if window.makesWindows {
                Button("Open in New Window", systemImage: "macwindow.badge.plus") { act(.tabInNewWindow(tab.id)) }
            }
            if !others.isEmpty {
                Menu("Move to Space", systemImage: "arrow.right.square") {
                    ForEach(others) { space in
                        Button(space.name, systemImage: space.symbol) { act(.moveTab(tab.id, space.id)) }
                    }
                }
            }
        }
        if selected {
            Section { AppItems(act: act) }
        }
    }
}
