import AppKit
import PadCore
import SwiftUI
import UniformTypeIdentifiers

/// Arc's sidebar: the window's buttons and the page's back, forward and
/// reload at the top; the address under them; the space's pinned tabs as
/// tiles; its other tabs as rows, the newest last; and the spaces along the
/// foot, with the space's own tools. It lies on the window's ground, the
/// space's colour, with what holds something in Liquid Glass. Hidden (⌃⌘S),
/// it slides out over the page when the pointer reaches the window's left
/// edge, as a pane of glass of its own.
struct Sidebar: View {
    @ObservedObject var model: WindowModel
    @ObservedObject private var session = Session.shared
    /// Out over the page, the sidebar being hidden.
    var floating = false
    /// What the list's glass draws past its tiles and rows: its rim and its light.
    private static let bleed: CGFloat = 4
    /// The same at the list's sides, where the tab on screen's glass reaches
    /// further than 4 points: as far as the sidebar's own gap on the left, and
    /// under the resize edge on the right, which stays on top for the pointer.
    private static let sideBleed: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let space = session.workspace.space(model.spaceID)
        // One gap between the groups and round the sidebar's edges; on the
        // side by the page, the gap is the page's own (BrowserView.edge).
        VStack(spacing: Metrics.gap) {
            TopRow(model: model)
                .frame(height: Metrics.control)
            HStack(spacing: 2) {
                AddressPill(model: model)
                    .padding(.trailing, Metrics.gap - 2)
                PageActionsButton(model: model)
                // Extensions (ExtensionBar.swift): the puzzle button and its list.
                ExtensionsButton(model: model)
            }
            if let space {
                ZStack(alignment: .top) {
                    VStack(spacing: Metrics.gap) {
                        // The pinned tiles stay put while the tabs under them scroll, as Arc keeps them.
                        PinnedGrid(model: model, space: space)
                        ScrollViewReader { reader in
                            ScrollView {
                                VStack(spacing: 6) {
                                    // The pinned tabs' second tier: the bookmarks bar, a row each.
                                    if let bar = space.bar, !(bar.children ?? []).isEmpty {
                                        BarList(model: model, space: space, bar: bar)
                                    }
                                    BookmarksRow(model: model)
                                    SectionLine()
                                    TabList(model: model, space: space)
                                }
                                // Glass draws a little past its shape: room for it, inside the scroll view.
                                .padding(.vertical, Self.bleed)
                                .padding(.horizontal, Self.sideBleed)
                            }
                            .scrollIndicators(.never)
                            // Feathered before it is let out: the mask takes the frame of what it is
                            // on, and on the column's frame it cut the glass's room off again.
                            .feathered(.vertical)
                            // As much wider than its column as it is padded inside, so what it shows stays put.
                            .padding(.vertical, -Self.bleed)
                            .padding(.horizontal, -Self.sideBleed)
                            // The bookmarks out over the list, from where their row is.
                            .overlay(alignment: .top) {
                                if model.bookmarksOpen {
                                    BookmarksPanel(model: model, space: space)
                                        .transition(reduceMotion ? .opacity : .asymmetric(
                                            insertion: .scale(scale: 0.96, anchor: .top).combined(with: .opacity),
                                            removal: .opacity))
                                }
                            }
                            // The tab on screen is always in view, however it came to be on screen.
                            .onChange(of: model.tabID) { _, tab in
                                withAnimation(.bar) { tab.map { reader.scrollTo($0) } }
                            }
                        }
                    }
                    // The space's tabs come in from the side they are on, as in Arc.
                    .id(space.id)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity))
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .animation(.bar, value: space.id)
            } else {
                Spacer()
            }
            SpaceBar(model: model)
        }
        .padding([.top, .bottom, .leading], Metrics.gap)
        .padding(.trailing, floating ? Metrics.gap : 0)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(BrowserView.place)).maxX } action: { model.sidebarEdge = $0 }
        // Gone, it holds no card away from what it stood beside.
        .onDisappear { model.sidebarEdge = 0 }
    }
}

// MARK: The top row

/// The window's close, minimise and zoom buttons, then the sidebar's own
/// button, and back, forward and reload, plain, as Arc's are.
private struct TopRow: View {
    @ObservedObject var model: WindowModel

    var body: some View {
        HStack(spacing: 0) {
            // The window's own buttons, centred in a cell as high as the row: the
            // first as far from the row's start as from its top.
            WindowButtons()
                .frame(width: WindowButtons.width, height: WindowButtons.side)
                .padding(.leading, (Metrics.control - WindowButtons.side) / 2)
            Spacer(minLength: Metrics.gap)
            HStack(spacing: 2) {
                PlainIcon("sidebar.left", help: model.sidebarShown ? String(localized: "Hide Sidebar (⌃⌘S)") : String(localized: "Keep Sidebar Open (⌃⌘S)")) {
                    model.toggleSidebar()
                }
                PlainIcon("chevron.left", help: String(localized: "Back (⌘[)"), enabled: model.canGoBack) { model.back() }
                PlainIcon("chevron.right", help: String(localized: "Forward (⌘])"), enabled: model.canGoForward) { model.forward() }
                if model.loading {
                    PlainIcon("xmark", help: String(localized: "Stop (⌘.)")) { model.stop() }
                } else {
                    PlainIcon("arrow.clockwise", help: String(localized: "Reload (⌘R)"), enabled: model.tabID != nil) { model.reload() }
                }
            }
        }
        // The row's ground moves the window, as a title bar does; the buttons on it are only buttons.
        .background {
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
        }
    }
}

// MARK: The address

/// The page's site, in glass: a click opens the command bar on its address
/// (⌘L), as Arc's does, and the link at its end, while the pointer is on
/// it, copies the address. A line along its foot while the page loads.
private struct AddressPill: View {
    @ObservedObject var model: WindowModel
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.rowCorner, style: .continuous)
        HStack(spacing: 0) {
            Button {
                model.commandBar = .here
            } label: {
                // The icon in the column the tabs' icons are in, the words where theirs start.
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(label)
                        .font(.system(size: 13, weight: model.url == nil ? .regular : .medium))
                        .foregroundStyle(model.url == nil ? Color.secondary : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                }
                .padding(.leading, 10)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.url?.absoluteString ?? String(localized: "Search or enter an address (⌘L)"))
            .accessibilityLabel("Address")
            .accessibilityValue(model.url?.absoluteString ?? "")
            if hovering, model.url != nil {
                Button {
                    model.copyLink()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "link")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.trailing, 4)
                .help("Copy Link (⇧⌘C)")
                .accessibilityLabel("Copy Link")
                .transition(.opacity)
            }
        }
        .frame(height: Metrics.field)
        // Under the pointer the glass darkens a step, as a field you can click into does.
        .background(Highlight(hovering: hovering, shape: shape))
        .overlay(alignment: .bottomLeading) {
            if model.loading {
                GeometryReader { box in
                    Capsule()
                        .fill(Color.accentColor.opacity(0.8))
                        .frame(width: max(box.size.width * model.progress, 12), height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .animation(.easeOut(duration: 0.2), value: model.progress)
                }
                .padding(.horizontal, 8)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .glassEffect(.regular, in: shape)
        .onHover { inside in withAnimation(.hover) { hovering = inside } }
    }

    private var icon: String {
        guard let url = model.url, model.searchWords == nil else { return "magnifyingglass" }
        if url.scheme == "https" { return model.secure ? "lock.fill" : "lock.open.fill" }
        // Plain http to a local server is where things are made, not a
        // hazard: its own mark instead of the warning sign.
        if url.scheme == "http", let host = url.host(), Address.isLocal(host: host) {
            return "chevron.left.forwardslash.chevron.right"
        }
        return url.scheme == "http" ? "exclamationmark.triangle.fill" : "doc"
    }

    /// The site, as Arc shows it: its host without www., and its port where
    /// the host is local, the part a dev server is told apart by. A search
    /// with the chosen engine says what was searched for, as Safari does.
    private var label: String {
        guard let url = model.url else { return String(localized: "Search or enter address") }
        if let words = model.searchWords { return words }
        guard let host = url.host() else { return Destination.pretty(url) }
        var bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if Address.isLocal(host: host), let port = url.port { bare += ":\(port)" }
        return bare
    }
}

/// The … beside the address, or in the tab on screen along the top: the
/// page's own commands, as the iPhone's page menu (…) has them (PageActions).
struct PageActionsButton: View {
    @ObservedObject var model: WindowModel
    /// In a tab, as small as its ✕ (CloseButton).
    var inTab = false
    @State private var hovering = false

    var body: some View {
        Group {
            if inTab {
                Button { model.pageActionsShown.toggle() } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(hovering ? Color.primary : Color.secondary)
                        .frame(width: 20, height: 20)
                        .background(Highlight(hovering: hovering, shape: Circle()))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
            } else {
                Button { model.pageActionsShown.toggle() } label: {
                    Image(systemName: "ellipsis")
                }
                .buttonStyle(PlainIconStyle())
            }
        }
        .help("Share and More")
        .accessibilityLabel("More")
        .popover(isPresented: $model.pageActionsShown, arrowEdge: .bottom) {
            PageActions(model: model)
        }
    }
}

// MARK: Pinned tabs

/// A tab carried by a drag: within the sidebar to another place, onto the
/// tiles to pin it, onto the bookmarks bar to keep it there, or onto a
/// space's button to move it there. A bookmark of the bar, open or not,
/// is carried as one too, to another place in the bar: then `bookmark` is
/// its id, and `tab` its tab's, or no tab's at all, which every place but
/// the bar finds no tab for and so leaves alone.
struct TabDrag: Codable, Transferable {
    let tab: UUID
    var bookmark: UUID?

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .egluTab)
    }
}

extension UTType {
    static let egluTab = UTType(exportedAs: "net.taehee.safience.tab")
}

/// The space's pinned tabs as tiles of glass, Arc's favourites: the site's
/// icon alone, its title when the pointer rests on it. Those this Mac hides
/// (Settings › Pinned Tabs) are left out.
private struct PinnedGrid: View {
    @ObservedObject var model: WindowModel
    let space: Space
    @ObservedObject private var session = Session.shared

    var body: some View {
        let pinned = space.tabs.filter { $0.isPinned && session.preferences.shows($0) }
        if !pinned.isEmpty {
            GlassEffectContainer(spacing: 2) {
                PinnedRows(spacing: Metrics.gap) {
                    ForEach(pinned) { tab in
                        PinnedTile(model: model, tab: tab)
                    }
                }
            }
            .animation(.bar, value: pinned.map(\.id))
        }
    }
}

/// A pinned tab's tile, in the sidebar or in the top row (`look`). In the
/// sidebar, all tiles one size, as wide as the sidebar's columns let them
/// be (PinnedRows): the one on screen and the one under the pointer on
/// glass, the others a brighter tile with a thin line round it (restGround,
/// restLine). The icon is drawn without
/// its own ground (IconTint), its mark alone, on a soft light of the
/// icon's colours: what the site draws stands on its own colour, with no
/// square of the icon's left to show. Every tile draws it so, its tab on
/// screen, open behind or closed (PinnedIcon); the one on screen takes on
/// its icon besides, its glass tinted lightly with the light's colour, the
/// light drifting while the window is in front. In the top row, the same,
/// smaller, with glass only under the one on screen.
struct PinnedTile: View {
    @ObservedObject var model: WindowModel
    let tab: TabRecord
    var look = Look.sidebar
    @ObservedObject private var icons = SiteIcons.shared
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    @State private var targeted = false
    /// Where the pointer is over the tile, and the tile's size, for the plate to lean toward it.
    @State private var pointer: CGPoint?
    @State private var size = CGSize.zero
    /// Where the tile is in the window, for its card (PinnedCardView).
    @State private var frame = CGRect.zero

    /// What differs between the sidebar's tiles and the top row's.
    struct Look {
        let corner: CGFloat
        let icon: CGFloat
        /// Nil: as wide as its column.
        let width: CGFloat?
        let height: CGFloat
        let glow: CGFloat
        /// How far the plate leans toward the pointer.
        let reach: CGSize
        let plate: (side: CGFloat, corner: CGFloat, blur: CGFloat)
        /// Glass under every tile, not only the one on screen.
        let glassAtRest: Bool
        /// A click on the one on screen opens the command bar on its address, as the tab on screen does.
        let openTypesAddress: Bool
        /// Its card under it, along the top; beside it in the sidebar.
        let cardBelow: Bool
        /// The open dot under the icon (OpenDot).
        let dot: CGFloat

        @MainActor static let sidebar = Look(corner: Metrics.tileCorner, icon: Metrics.tileIcon, width: nil, height: Metrics.tile,
                                             glow: 44, reach: CGSize(width: 13, height: 9), plate: PinnedIcon.tilePlate,
                                             glassAtRest: true, openTypesAddress: false, cardBelow: false, dot: 4)
        /// Glass only on the one on screen: the others are icons on the row, as its tabs are names.
        @MainActor static let topRow = Look(corner: 9, icon: 16, width: Metrics.control + 4, height: Metrics.control,
                                            glow: 28, reach: CGSize(width: 6, height: 4), plate: (side: 18, corner: 6, blur: 6),
                                            glassAtRest: false, openTypesAddress: true, cardBelow: true, dot: 3)
    }

    /// A tile at rest, off screen and not under the pointer: lighter than the
    /// sidebar's ground, in white, and edged in the words' colour, faintly.
    static func restGround(_ scheme: ColorScheme) -> Color {
        Color.white.opacity(scheme == .dark ? 0.08 : 0.4)
    }

    static func restLine(_ scheme: ColorScheme) -> Color {
        Color.primary.opacity(scheme == .dark ? 0.16 : 0.1)
    }

    /// Where the pointer is, or where a debug build was told to put it (`-hoverPinned 0.8,0.3`).
    private var shownPointer: CGPoint? {
        #if DEBUG
        if let spot = PointerGlow.debugSpot, model.tabID == tab.id, size.width > 0 {
            return CGPoint(x: spot.x * size.width, y: spot.y * size.height)
        }
        #endif
        return pointer
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: look.corner, style: .continuous)
        let selected = model.tabID == tab.id
        let url = tab.url ?? tab.pinned
        let colour = model.space?.color ?? .blue
        let ground = selected ? PinnedIcon.tileTint(for: url, colour: colour) : nil
        let open = selected && activeState != .inactive
        // A square icon with no one colour round its edge lights the glass in the label colour, faintly.
        let glass: Glass = selected ? .regular.tint(ground ?? Color.primary.opacity(0.12)) : .regular
        // Glass on the tab on screen's tile and under the pointer; the others
        // are a brighter ground with a line round it, so the one on screen stands out.
        let glassy = selected || hovering
        Button {
            if selected && look.openTypesAddress { model.commandBar = .here } else { model.select(tab.id) }
        } label: {
            let lean = Plate.lean(toward: shownPointer, in: size, reach: look.reach)
            let tile = ZStack {
                PointerGlow(lean: lean, radius: look.glow)
                // No glow on a tile neither on screen nor under the pointer, as no glass.
                PinnedIcon(url: url, open: open, colour: colour, size: look.icon, lean: lean, plate: look.plate, lit: glassy,
                           current: selected)
            }
            .frame(maxWidth: look.width ?? .infinity)
            .frame(width: look.width, height: look.height)
            // Open, as the iPhone's dock marks it: a dot just under the icon.
            .overlay {
                OpenDot(shown: PinnedTile.isOpen(tab), size: look.dot)
                    .offset(y: OpenDot.under(icon: look.icon, size: look.dot))
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .background(Highlight(hovering: hovering && !selected, shape: shape))
            // The plate's softened edge stays inside the tile.
            .clipShape(shape)
            .contentShape(shape)
            Group {
                if look.glassAtRest {
                    tile
                        .background { if !glassy { shape.fill(PinnedTile.restGround(scheme)) } }
                        .overlay { if !glassy { shape.strokeBorder(PinnedTile.restLine(scheme), lineWidth: 1) } }
                        .glassEffect(glassy ? glass : .identity, in: shape)
                } else {
                    tile.background {
                        if selected { shape.fill(.clear).glassEffect(glass, in: shape) }
                    }
                }
            }
            .overlay {
                if targeted { shape.strokeBorder(Color.accentColor, lineWidth: 2) }
            }
        }
        // A press gives a little, inside the tile's own room: the glass's own press grew the
        // tile, and the list cut it off at its top.
        .buttonStyle(TilePress())
        .animation(.bar, value: selected)
        .animation(.bar, value: open)
        .animation(.bar, value: colour)
        // The glass comes and goes with the pointer, as quickly as a highlight does;
        // its card, with its whole name, after a moment (PinnedCardView).
        .onHover { inside in
            withAnimation(.hover) { hovering = inside }
            if inside {
                model.pointer(on: PinnedCard(item: .tab(tab.id), anchor: frame, below: look.cardBelow))
            } else {
                model.pointerOnCard(false)
            }
        }
        .onContinuousHover { phase in
            // Slow enough to read as light following, not a spot jumping to the pointer.
            withAnimation(.spring(duration: 0.6, bounce: 0)) {
                if case .active(let point) = phase { pointer = point } else { pointer = nil }
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(BrowserView.place)) } action: { frame = $0 }
        #if DEBUG
        // `-pinnedCard name`: the card of the tile whose name has it, out at once, for a picture.
        .task(id: frame) {
            guard frame != .zero, let wanted = UserDefaults.standard.string(forKey: "pinnedCard"),
                  tab.label.localizedCaseInsensitiveContains(wanted) else { return }
            model.pointer(on: PinnedCard(item: .tab(tab.id), anchor: frame, below: look.cardBelow))
        }
        #endif
        .draggable(TabDrag(tab: tab.id)) {
            SiteIconView(url: url, size: look.icon)
                .environment(\.spaceColor, colour)
        }
        .dropDestination(for: TabDrag.self) { items, _ in
            guard let item = items.first, item.tab != tab.id else { return false }
            model.place(item.tab, pinned: true, before: tab.id)
            return true
        } isTargeted: { targeted = $0 }
        .contextMenu { TabMenu(model: model, tab: tab) }
        .accessibilityLabel(tab.label)
        .accessibilityValue(PinnedTile.isOpen(tab) ? String(localized: "Open") : "")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// Open, as the iPhone has it (Pinned.isOpen): its page loaded, or gone
    /// on from the address it was pinned with. Closed, it is back there with
    /// its page let go, as closing a pinned tab leaves it.
    static func isOpen(_ tab: TabRecord) -> Bool {
        tab.isPinned && (Session.shared.pages.isLive(tab.id) || tab.isAwayFromPinned)
    }
}


// MARK: The bookmarks bar

/// The pinned tabs' second tier: the bookmarks bar's bookmarks as rows
/// under the tiles, as Arc keeps its pinned tabs under its favourites, a
/// folder in it opening in place, a step in. Each opens in a tab of its own
/// that stands in its row (Workspace.openFromBar), with a dot left of its
/// icon while it is open; an open one stays in sight in a folder that is
/// shut. Along the top, the same rows in the bar button's pane (BarPanel, `chose`).
struct BarList: View {
    @ObservedObject var model: WindowModel
    let space: Space
    let bar: Bookmark
    /// In the pane along the top: a bookmark chosen puts it away.
    var chose: (() -> Void)?
    /// The folders open.
    @State private var open: Set<UUID> = []

    var body: some View {
        let tabs = space.barTabs
        let rows = Bookmarks.rows(of: bar.children ?? [], opening: open, keeping: Set(tabs.keys))
        VStack(spacing: 2) {
            ForEach(rows, id: \.item.id) { row in
                BarRow(model: model, item: row.item, depth: row.depth, tab: tabs[row.item.id], space: space, bar: bar.id,
                       open: open.contains(row.item.id), chose: chose) {
                    withAnimation(.bar) { open.formSymmetricDifference([row.item.id]) }
                }
                .transition(.opacity)
            }
        }
        .animation(.bar, value: rows.map(\.item.id))
    }
}

/// A bookmark of the bar, as a tab's row is: a dot while it is open, its
/// site's icon, its name; gone on from its bookmark, the bookmark's icon, a
/// slash and where it is now, as Arc shows a pinned tab that has. The one
/// on screen raised in glass, a close button on an open one under the
/// pointer, and its card after a moment (PinnedCardView). A folder in the
/// space's colour, turning to show it is open. A tab dropped on a row goes
/// into the bar before it, on a folder into the folder; a row dragged to
/// another moves there.
private struct BarRow: View {
    @ObservedObject var model: WindowModel
    let item: Bookmark
    let depth: Int
    /// Its tab, while it is open.
    let tab: TabRecord?
    let space: Space
    let bar: UUID
    let open: Bool
    let chose: (() -> Void)?
    let toggle: () -> Void
    @State private var hovering = false
    @State private var pressed = false
    @State private var targeted = false
    /// Where the row is in the window, for its card.
    @State private var frame = CGRect.zero

    var body: some View {
        let selected = tab.map { $0.id == model.tabID } ?? false
        let shape = RoundedRectangle(cornerRadius: Metrics.rowCorner, style: .continuous)
        let indent = CGFloat(depth) * 16
        HStack(spacing: 8) {
            Button(action: choose) {
                HStack(spacing: 8) {
                    ZStack {
                        if item.isFolder {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(space.color.color)
                        } else if selected, model.loading, model.page != nil {
                            ProgressView().controlSize(.mini)
                        } else {
                            SiteIconView(url: item.url, size: 16)
                        }
                    }
                    .frame(width: 16, height: 16)
                    if let tab, space.isAwayFromHome(tab) {
                        // The slash closer to the words than the icon is: "where it is now" is one thing.
                        HStack(spacing: 5) {
                            Text(verbatim: "/")
                                .font(.system(size: 13, weight: .light))
                                .foregroundStyle(.tertiary)
                            title(tab.label, selected: selected)
                        }
                    } else {
                        title(item.label, selected: selected)
                    }
                    Spacer(minLength: 0)
                    if item.isFolder {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            // The row's ground darkens the moment it is pressed, not when it is let go.
            .buttonStyle(PressReport(pressed: $pressed))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.isFolder ? String(localized: "\(item.label), folder")
                                : tab.flatMap { space.isAwayFromHome($0) ? $0.label : nil } ?? item.label)
            .accessibilityValue(item.isFolder ? (open ? String(localized: "Open") : String(localized: "Closed"))
                                : tab != nil ? String(localized: "Open") : "")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            // The element made in the button's place has no press of its own.
            .accessibilityAction(.default, choose)
            if hovering, let tab {
                CloseButton { model.closeTab(tab.id) }
                    .transition(.opacity)
            }
        }
        .padding(.leading, 10 + indent)
        .padding(.trailing, 7)
        .frame(height: Metrics.row)
        // Open: a dot left of the icon, nearer it than the row's edge.
        .overlay(alignment: .leading) {
            OpenDot(shown: tab != nil)
                .padding(.leading, OpenDot.before(lead: 10) + indent)
        }
        .background {
            if selected, chose == nil {
                shape.fill(.clear).glassEffect(.regular, in: shape)
            } else {
                // In the bar's pane, already glass, the one on screen a step darker than under the pointer.
                Highlight(hovering: hovering || (targeted && item.isFolder), pressed: selected || pressed, shape: shape)
            }
        }
        .overlay(alignment: .top) { DropLine(shown: targeted && !item.isFolder) }
        .contentShape(shape)
        .onHover { inside in
            withAnimation(.hover) { hovering = inside }
            // Its card beside the sidebar, or beside the bar's pane along the top.
            guard !item.isFolder else { return }
            if inside {
                model.pointer(on: PinnedCard(item: .bookmark(item.id), anchor: frame))
            } else {
                model.pointerOnCard(false)
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(BrowserView.place)) } action: { frame = $0 }
        #if DEBUG
        // `-pinnedCard name`, as for a tile.
        .task(id: frame) {
            guard frame != .zero, !item.isFolder, let wanted = UserDefaults.standard.string(forKey: "pinnedCard"),
                  (tab?.label ?? item.label).localizedCaseInsensitiveContains(wanted) else { return }
            model.pointer(on: PinnedCard(item: .bookmark(item.id), anchor: frame))
        }
        #endif
        .draggable(TabDrag(tab: tab?.id ?? item.id, bookmark: item.id)) {
            HStack(spacing: 6) {
                if item.isFolder {
                    Image(systemName: "folder.fill").foregroundStyle(space.color.color)
                } else {
                    SiteIconView(url: item.url, size: 16)
                }
                Text(item.label).font(.system(size: 13)).lineLimit(1)
            }
            .padding(8)
            .frame(width: 200, alignment: .leading)
        }
        .dropDestination(for: TabDrag.self) { drags, _ in
            guard let drag = drags.first, drag.bookmark != item.id else { return false }
            // On a folder, into it; on a bookmark, before it in its folder.
            let folder = item.isFolder ? item.id : Bookmarks.parent(of: item.id, in: space.bookmarks) ?? bar
            let before = item.isFolder ? nil : item.id
            if let bookmark = drag.bookmark {
                model.moveInBar(bookmark, into: folder, before: before)
            } else {
                model.addToBar(drag.tab, into: folder, before: before)
            }
            return true
        } isTargeted: { targeted = $0 }
        .contextMenu { menu }
    }

    /// A folder opens or shuts; a bookmark opens in its tab.
    private func choose() {
        if item.isFolder {
            toggle()
        } else {
            model.openFromBar(item.id)
            chose?()
        }
    }

    private func title(_ text: String, selected: Bool) -> some View {
        Text(text)
            .font(.system(size: 13, weight: selected ? .medium : .regular))
            .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.85))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder
    private var menu: some View {
        if let tab {
            TabMenu(model: model, tab: tab)
        } else {
            if let url = item.url {
                Button("Open") { model.openFromBar(item.id) }
                Button("Open in New Tab") { model.open(url, newTab: true) }
                Button("Copy Address") { model.copyAddress(url) }
                Divider()
            }
            let folder = item.isFolder ? item.id : Bookmarks.parent(of: item.id, in: space.bookmarks) ?? bar
            Button("New Folder") { model.newFolderInBar(in: folder) }
            Button("Rename…") { model.renameInBar(item.id) }
            Button(item.isFolder ? String(localized: "Remove Folder from Bookmarks Bar") : String(localized: "Remove from Bookmarks Bar")) {
                model.removeFromBar(item.id)
            }
        }
    }
}

/// A plain button that says when it is held, for a row whose ground is drawn
/// outside the button to darken under the press, as RowButtonStyle's does.
private struct PressReport: ButtonStyle {
    @Binding var pressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, now in pressed = now }
    }
}

// MARK: Pinned cards

/// The card beside a pinned tile or a bar bookmark the pointer rests on:
/// which it is, and where.
struct PinnedCard: Equatable {
    enum Item: Equatable {
        /// A pinned tab's tile.
        case tab(UUID)
        /// A bookmark of the bar, open or not.
        case bookmark(UUID)
    }

    let item: Item
    /// The tile's or the row's frame in the window (BrowserView.place).
    let anchor: CGRect
    /// Under it, as along the top; beside it, as in the sidebar.
    var below = false
}

/// A pinned tab's card, as Arc's: its whole name, which a tile has no room
/// for and a row cuts short, and what can be done with it at once: going
/// back to where it was pinned, while it is open, and its page in a split
/// beside the tab on screen, while that is an ordinary tab. In glass, over
/// the page, beside the sidebar or under the row along the top.
struct PinnedCardView: View {
    @ObservedObject var model: WindowModel
    let card: PinnedCard
    @ObservedObject private var session = Session.shared
    @Environment(\.colorScheme) private var scheme

    /// What the card says and offers, as the workspace is now.
    private struct Shown {
        let title: String
        /// Its tab, while it is open.
        let tab: TabRecord?
        /// The page its split would show: where its tab is, else where it was pinned.
        let page: URL?
    }

    var body: some View {
        if let shown {
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            let canSplit = model.canSplitBeside && shown.tab?.id != model.tabID && shown.page != nil
            let actions = shown.tab != nil || canSplit
            VStack(alignment: .leading, spacing: 6) {
                Text(shown.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if actions {
                    HStack(spacing: 2) {
                        if let tab = shown.tab {
                            PlainIcon("arrow.uturn.backward", help: String(localized: "Back to Pinned Address")) {
                                model.backToPinned(tab.id)
                            }
                        }
                        if canSplit, let page = shown.page {
                            PlainIcon("rectangle.split.2x1", help: String(localized: "Open in Split View")) {
                                model.splitBeside(page)
                            }
                        }
                    }
                    // The glyphs, not their cells, in line with the name; the cells' corners
                    // (8) as far in from the card's (18) as the cells are from its edges (10).
                    .padding(.leading, -6)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, actions ? 10 : 14)
            .frame(width: 240)
            // Over whatever the page shows: glass, but nearly as solid as the window, for its words.
            .glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.72)), in: shape)
            .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.12), radius: 18, y: 8)
            .onHover { model.pointerOnCard($0) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(shown.title)
        }
    }

    private var shown: Shown? {
        guard let space = session.workspace.space(model.spaceID) else { return nil }
        switch card.item {
        case .tab(let id):
            guard let tab = space.tabs.first(where: { $0.id == id }), tab.isPinned else { return nil }
            return Shown(title: tab.label, tab: PinnedTile.isOpen(tab) ? tab : nil, page: tab.url ?? tab.pinned)
        case .bookmark(let id):
            guard let bookmark = Bookmarks.find(id, in: space.bookmarks) else { return nil }
            let tab = space.barTabs[id]
            // Gone on from its bookmark, where it is now; else the bookmark's own name.
            let title = tab.flatMap { space.isAwayFromHome($0) ? $0.label : nil } ?? bookmark.label
            return Shown(title: title, tab: tab, page: tab?.url ?? bookmark.url)
        }
    }
}

// MARK: Bookmarks

/// The way to the space's other bookmarks, all but the bar, as Chromium
/// calls them: a row as New Tab is, which brings them out over the list as
/// a popover (BookmarksPanel), so they never read as more tabs.
private struct BookmarksRow: View {
    @ObservedObject var model: WindowModel

    var body: some View {
        Button {
            withAnimation(.bar) { model.bookmarksOpen.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "book")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                Text("Other Bookmarks")
                    .font(.system(size: 13))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: Metrics.row)
        }
        .buttonStyle(RowButtonStyle(corner: Metrics.rowCorner))
        .help("Other Bookmarks")
    }
}

/// The space's other bookmarks, out over the sidebar's list as a popover is, from
/// where their row is: a pane of Liquid Glass, untinted, lifted by a soft
/// shadow, with a name and ✕, so they read as something passing over the
/// sidebar and not as more of its tabs. A click opens one in the tab on screen and puts
/// them away; a ⌘-click opens it in a new tab and leaves them out, for the
/// next; a folder opens in place. ✕, Escape, the space changing or a click
/// anywhere else in the window puts them away.
private struct BookmarksPanel: View {
    @ObservedObject var model: WindowModel
    let space: Space
    /// The folders open, while they are out.
    @State private var open: Set<UUID> = []
    @AccessibilityFocusState private var closeFocused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let card = RoundedRectangle(cornerRadius: Metrics.rowCorner + 6, style: .continuous)
        ZStack(alignment: .top) {
            // Outside them, a click only puts them away, as outside a popover.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { close() }
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("Other Bookmarks")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    CloseButton(label: String(localized: "Close Bookmarks"), help: String(localized: "Close Bookmarks (Esc)")) { close() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityFocused($closeFocused)
                }
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .frame(height: 36)
                // As tall as they are, and no taller than the list: past that they scroll.
                ViewThatFits(in: .vertical) {
                    rows
                    ScrollView { rows }
                        .scrollIndicators(.never)
                }
            }
            .padding(.bottom, 6)
            // Clipped first: rows scrolled to an end would show past the corners.
            .clipShape(card)
            .glassEffect(.regular, in: card)
            .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.14), radius: 24, y: 10)
            // For the window's watch on clicks: one off this puts it away (WindowModel.clickedAway).
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.bookmarksFrame = $0 }
            // The list's own column: its edges those of the address and the tiles above,
            // the sidebar's gap above and below it.
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { close() }
        .onAppear { closeFocused = true }
    }

    private var rows: some View {
        let others = Bookmarks.others(in: space.bookmarks)
        return VStack(spacing: 2) {
            if others.isEmpty {
                Text("Bookmark a page with ⌘D")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            }
            ForEach(Bookmarks.rows(of: others, opening: open), id: \.item.id) { row in
                BookmarkRow(model: model, item: row.item, depth: row.depth, colour: space.color,
                            open: open.contains(row.item.id), chose: chose) {
                    withAnimation(.bar) { open.formSymmetricDifference([row.item.id]) }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 6)
    }

    /// In the tab on screen, and they go; with ⌘, in a new tab, and they stay.
    private func chose(_ url: URL) {
        let newTab = NSEvent.modifierFlags.contains(.command)
        HistoryRecorder.shared.expect(.bookmark, url)
        model.open(url, newTab: newTab)
        if !newTab { close() }
    }

    private func close() {
        withAnimation(.bar) { model.bookmarksOpen = false }
    }
}

/// A bookmark's row, as a tab's is: its site's icon and its name; a folder
/// in the space's colour, turning to show it is open.
private struct BookmarkRow: View {
    @ObservedObject var model: WindowModel
    let item: Bookmark
    let depth: Int
    let colour: SpaceColor
    let open: Bool
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
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if item.isFolder {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
            }
            .padding(.leading, 10 + CGFloat(depth) * 16)
            .padding(.trailing, 10)
            .frame(height: Metrics.row)
        }
        .buttonStyle(RowButtonStyle(corner: Metrics.rowCorner))
        .help(item.url.map(Destination.pretty) ?? item.label)
        .contextMenu {
            if let url = item.url {
                Button("Open in New Tab") { model.open(url, newTab: true) }
                Button("Copy Address") { model.copyAddress(url) }
            }
        }
        .accessibilityLabel(item.isFolder ? String(localized: "\(item.label), folder") : item.label)
        .accessibilityValue(item.isFolder ? (open ? String(localized: "Open") : String(localized: "Closed")) : "")
    }
}

/// The line between the sidebar's sections, as faint as the one between the
/// pinned tabs and the others along the top.
struct SectionLine: View {
    var body: some View {
        Rectangle()
            .fill(Palette.faint)
            .frame(height: 1)
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .accessibilityHidden(true)
    }
}

// MARK: The space's own tabs

/// New Tab, then the space's tabs that aren't pinned.
struct TabList: View {
    @ObservedObject var model: WindowModel
    let space: Space

    var body: some View {
        VStack(spacing: 2) {
            NewTabRow(model: model, unpinned: space.otherTabs.map(\.id))
            ForEach(Self.items(of: space), id: \.first?.id) { item in
                if item.count == 2 {
                    // A split's two, as one place in the list: one under the other on a ground of their own.
                    VStack(spacing: 0) {
                        ForEach(item) { tab in
                            TabRow(model: model, tab: tab).id(tab.id)
                        }
                    }
                    .padding(2)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: Metrics.rowCorner + 2, style: .continuous))
                    .transition(.opacity)
                } else if let tab = item.first {
                    TabRow(model: model, tab: tab)
                        .id(tab.id)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
                }
            }
            // The rest of the list takes a tab dropped below the last.
            TailDrop(model: model)
        }
    }

    /// The space's tabs that aren't pinned or in the bookmarks bar, one at a
    /// time, or a split's two together, as the workspace keeps them: side by
    /// side, left first.
    static func items(of space: Space) -> [[TabRecord]] {
        let tabs = space.otherTabs
        var items: [[TabRecord]] = []
        var index = 0
        while index < tabs.count {
            let tab = tabs[index]
            if index + 1 < tabs.count, space.splits.contains(where: { $0.left == tab.id && $0.right == tabs[index + 1].id }) {
                items.append([tab, tabs[index + 1]])
                index += 2
            } else {
                items.append([tab])
                index += 1
            }
        }
        return items
    }
}

private struct NewTabRow: View {
    @ObservedObject var model: WindowModel
    /// The space's tabs under it, first to last.
    let unpinned: [UUID]
    @State private var targeted = false

    var body: some View {
        Button {
            model.perform(.newTab)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                Text("New Tab")
                    .font(.system(size: 13))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: Metrics.row)
        }
        .buttonStyle(RowButtonStyle(corner: Metrics.rowCorner))
        .overlay(alignment: .bottom) { DropLine(shown: targeted) }
        .help("New Tab (⌘T)")
        .dropDestination(for: TabDrag.self) { items, _ in
            guard let item = items.first else { return false }
            // First of the tabs: before the first of the others.
            model.place(item.tab, pinned: false, before: unpinned.first { $0 != item.tab })
            return true
        } isTargeted: { targeted = $0 }
    }
}

/// A tab's row: its site's icon and its title, a close button while the
/// pointer is on it. The tab on screen is raised in glass.
private struct TabRow: View {
    @ObservedObject var model: WindowModel
    let tab: TabRecord
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        let selected = model.tabID == tab.id
        let shape = RoundedRectangle(cornerRadius: Metrics.rowCorner, style: .continuous)
        HStack(spacing: 8) {
            Button { model.select(tab.id) } label: {
                HStack(spacing: 8) {
                    ZStack {
                        if selected, model.loading, model.page != nil {
                            ProgressView().controlSize(.mini)
                        } else {
                            SiteIconView(url: tab.url, size: 16)
                                .opacity(Session.shared.pages.isLive(tab.id) || selected ? 1 : 0.75)
                        }
                    }
                    .frame(width: 16, height: 16)
                    Text(tab.label)
                        .font(.system(size: 13, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tab.label)
            .accessibilityAddTraits(selected ? .isSelected : [])
            if hovering {
                CloseButton { model.closeTab(tab.id) }
                    .transition(.opacity)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 7)
        .frame(height: Metrics.row)
        .background {
            if selected {
                shape.fill(.clear).glassEffect(.regular, in: shape)
            } else {
                Highlight(hovering: hovering, shape: shape)
            }
        }
        .overlay(alignment: .top) { DropLine(shown: targeted) }
        .contentShape(shape)
        .onHover { inside in withAnimation(.hover) { hovering = inside } }
        .draggable(TabDrag(tab: tab.id)) {
            HStack(spacing: 6) {
                SiteIconView(url: tab.url, size: 16)
                Text(tab.label).font(.system(size: 13)).lineLimit(1)
            }
            .padding(8)
            .frame(width: 200, alignment: .leading)
        }
        .dropDestination(for: TabDrag.self) { items, _ in
            guard let item = items.first, item.tab != tab.id else { return false }
            model.place(item.tab, pinned: false, before: tab.id)
            return true
        } isTargeted: { targeted = $0 }
        .contextMenu { TabMenu(model: model, tab: tab) }
        .help(tab.url?.absoluteString ?? tab.label)
        .accessibilityElement(children: .contain)
    }
}

/// A row's close button: its own highlight, a step stronger than the row's under it.
struct CloseButton: View {
    var label = String(localized: "Close Tab")
    var help = String(localized: "Close Tab (⌘W)")
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Highlight(hovering: hovering, shape: Circle()))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? Color.primary : Color.secondary)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(label)
    }
}

/// Where a dragged tab will land, between two rows.
struct DropLine: View {
    let shown: Bool

    var body: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.horizontal, 6)
            .offset(y: -1)
            .opacity(shown ? 1 : 0)
    }
}

/// Below the last row: a tab dropped here goes to the end.
private struct TailDrop: View {
    @ObservedObject var model: WindowModel
    @State private var targeted = false

    var body: some View {
        Color.clear
            .frame(height: 60)
            .overlay(alignment: .top) { DropLine(shown: targeted) }
            .contentShape(Rectangle())
            .dropDestination(for: TabDrag.self) { items, _ in
                guard let item = items.first else { return false }
                model.place(item.tab, pinned: false, before: nil)
                return true
            } isTargeted: { targeted = $0 }
    }
}

/// A tab's menu, on its row or its tile.
struct TabMenu: View {
    @ObservedObject var model: WindowModel
    let tab: TabRecord

    var body: some View {
        let session = Session.shared
        let space = session.workspace.spaceID(of: tab.id).flatMap(session.workspace.space)
        let inBar = space?.isInBar(tab) == true
        if tab.isPinned {
            // Where it is pinned, and going back there or pinning it here
            // instead, as the iPhone's pinned button has them.
            Section(tab.pinnedAddress.map { String(localized: "Pinned to \($0)") } ?? "") {
                Button("Back to Pinned Address") { model.backToPinned(tab.id) }
                    .disabled(!tab.isAwayFromPinned)
                Button("Replace with Current Page") { model.repin(tab.id) }
                    .disabled(!tab.isAwayFromPinned)
                Button("Unpin Tab") { model.togglePin(tab.id) }
                Button("Move to Bookmarks Bar") { model.addToBar(tab.id) }
                    .disabled(tab.url == nil)
            }
            Divider()
        } else if inBar, let bookmark = tab.bookmark {
            // The bar's own: going back to its bookmark, or taking it out of the bar.
            Section("In the Bookmarks Bar") {
                Button("Back to Bookmarked Address") { model.backToPinned(tab.id) }
                    .disabled(space?.isAwayFromHome(tab) != true)
                Button("Separate from Bookmarks Bar") { model.separateFromBar(tab.id) }
                Button("Pin Tab") { model.togglePin(tab.id) }
                Button("Remove from Bookmarks Bar") { model.removeFromBar(bookmark) }
            }
            Divider()
        } else {
            Button("Pin Tab") { model.togglePin(tab.id) }
                .disabled(tab.url == nil)
            Button("Add to Bookmarks Bar") { model.addToBar(tab.id) }
                .disabled(tab.url == nil)
        }
        Button("Duplicate Tab") { model.duplicate(tab.id) }
            .disabled(tab.url == nil)
        Button("Copy Link") { model.copyLink(tab.id) }
            .disabled(tab.url == nil)
        // Split View: two ordinary tabs of the space, side by side.
        if !tab.isPinned, !inBar {
            if session.workspace.split(containing: tab.id) != nil {
                Button("Separate Tabs") { model.separate(tab.id) }
                Button("Swap Sides") { model.swapSides(tab.id) }
            } else if tab.id == model.tabID {
                Button("Split with New Tab") { model.splitWithNewTab() }
            } else if model.canSplitBeside, model.spaceID == session.workspace.spaceID(of: tab.id) {
                Button("Open in Split View") { model.split(with: tab.id) }
            }
        }
        let others = session.workspace.spaces.filter { $0.id != model.spaceID }
        if !others.isEmpty {
            Menu("Move to Space") {
                ForEach(others) { space in
                    Button {
                        model.move(tab.id, to: space.id)
                    } label: {
                        Label(space.name, systemImage: space.symbol)
                    }
                }
            }
        }
        Divider()
        Button(tab.isPinned ? String(localized: "Close and Unload") : String(localized: "Close Tab")) { model.closeTab(tab.id) }
    }
}

// MARK: The spaces

/// The sidebar's foot: the spaces in one piece of glass, each its icon,
/// the one on screen filled with its colour (a click goes there, a tab
/// dropped on one moves to it); then the space's own tools, plain:
/// downloads while there are any, Clear (every tab that isn't pinned
/// closes, as Arc's does), and Space Settings, where the spaces are put in
/// order, added, changed and removed.
struct SpaceBar: View {
    @ObservedObject var model: WindowModel
    /// In the row along the top: the spaces and Space Settings, no Clear, no room between.
    var inRow = false
    @ObservedObject private var session = Session.shared
    @ObservedObject private var downloads = Downloads.shared
    /// Where each space's button is, for the one disc that marks the space on screen to go to.
    @Namespace private var places

    var body: some View {
        let clearable = model.space?.otherTabs.isEmpty == false
        // With one space there is nowhere to go: its button alone is left out (a phone's bar keeps it).
        let several = session.workspace.spaces.count > 1
        HStack(spacing: 2) {
            if inRow, !downloads.items.isEmpty {
                DownloadsButton(model: model)
                    .transition(.opacity)
            }
            if several {
                // As many as fit at their size, then smaller, then in a row that scrolls.
                ViewThatFits(in: .horizontal) {
                    spaces(compact: false)
                    spaces(compact: true)
                    ScrollView(.horizontal) { spaces(compact: true, glass: false) }
                        .scrollIndicators(.never)
                        .padding(3)
                        .glassEffect(.regular, in: Capsule())
                }
                // In the row, a gap from the plain buttons either side, which are 2 points from each other.
                .padding(.horizontal, inRow ? Metrics.gap - 2 : 0)
                .transition(.opacity)
            }
            if !inRow {
                Spacer(minLength: Metrics.gap)
                if !downloads.items.isEmpty {
                    DownloadsButton(model: model)
                        .transition(.opacity)
                }
                PlainIcon("trash", help: String(localized: "Clear: Close Every Tab That Isn’t Pinned or in the Bookmarks Bar"), enabled: clearable) {
                    model.clearTabs()
                }
            }
            Button {
                model.spacesPanel = model.spacesPanel == nil ? .list : nil
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(PlainIconStyle())
            .help("Space Settings")
            .accessibilityLabel("Space Settings")
            .popover(isPresented: Binding(get: { model.spacesPanel != nil }, set: { if !$0 { model.spacesPanel = nil } }),
                     arrowEdge: .top) {
                SpaceManager(model: model)
            }
        }
        .frame(height: Metrics.field)
        .animation(.bar, value: downloads.items.isEmpty)
    }

    /// The spaces' buttons, and under them one disc in the colour of the
    /// space on screen: going to another space (a click, a sideways sweep,
    /// ⌃1 to ⌃9) slides it there, its colour turning to that space's on the way.
    @ViewBuilder
    private func spaces(compact: Bool, glass: Bool = true) -> some View {
        let row = HStack(spacing: 2) {
            ForEach(session.workspace.spaces) { space in
                SpaceButton(model: model, space: space, compact: compact, places: places)
            }
        }
        .background {
            if let current = model.space {
                Circle()
                    .fill(current.color.color)
                    .matchedGeometryEffect(id: SpaceButton.place(current.id, compact: compact), in: places, isSource: false)
            }
        }
        if glass {
            row.padding(3).glassEffect(.regular, in: Capsule())
        } else {
            row
        }
    }
}

private struct SpaceButton: View {
    @ObservedObject var model: WindowModel
    let space: Space
    let compact: Bool
    let places: Namespace.ID
    @State private var targeted = false
    @State private var hovering = false

    /// A button's place, apart for each size the row may be drawn at.
    static func place(_ space: UUID, compact: Bool) -> String {
        "\(space.uuidString)\(compact ? "-compact" : "")"
    }

    var body: some View {
        let chosen = model.spaceID == space.id
        let side: CGFloat = compact ? 22 : 26
        Button {
            model.showSpace(space.id)
        } label: {
            Image(systemName: space.symbol)
                .font(.system(size: compact ? 10 : 12, weight: .semibold))
                .foregroundStyle(chosen ? space.color.ink : hovering ? Color.primary : Color.secondary)
                .frame(width: side, height: side)
                // The space on screen is marked by the row's one disc, under this button.
                .matchedGeometryEffect(id: Self.place(space.id, compact: compact), in: places, isSource: true)
                .background {
                    if !chosen { Highlight(hovering: hovering || targeted, shape: Circle()) }
                }
                .overlay {
                    if targeted { Circle().strokeBorder(space.color.color, lineWidth: 2) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(TilePress())
        .animation(.bar, value: chosen)
        .onHover { hovering = $0 }
        .dropDestination(for: TabDrag.self) { items, _ in
            guard let item = items.first, Session.shared.workspace.spaceID(of: item.tab) != space.id else { return false }
            model.move(item.tab, to: space.id)
            return true
        } isTargeted: { targeted = $0 }
        .help(space.name)
        .contextMenu {
            Button("Space Settings…") { model.spacesPanel = .edit(space.id) }
        }
        .accessibilityLabel(space.name)
        .accessibilityAddTraits(chosen ? [.isSelected] : [])
    }
}

private struct DownloadsButton: View {
    @ObservedObject var model: WindowModel
    @ObservedObject private var downloads = Downloads.shared

    var body: some View {
        Button {
            model.downloadsShown.toggle()
        } label: {
            Image(systemName: "arrow.down")
                // How much of what is downloading has come, round the arrow.
                .overlay {
                    if downloads.active {
                        Circle()
                            .trim(from: 0, to: downloads.fraction)
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 20, height: 20)
                    }
                }
        }
        .buttonStyle(PlainIconStyle())
        .help("Downloads")
        .accessibilityLabel("Downloads")
        .popover(isPresented: $model.downloadsShown, arrowEdge: .top) { DownloadList(model: model) }
    }
}
