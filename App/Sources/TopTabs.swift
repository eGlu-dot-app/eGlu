import PadCore
import SwiftUI

/// The tabs along the top on iPad, drawn as the Mac's row is (TopTabBar)
/// and with the sidebar's pieces (SideTabs.swift): back, forward, reload
/// and the bookmarks bar's button; the space's pinned tabs as small tiles,
/// in glass only on screen; its other tabs sharing what room there is
/// (TabWidths), the one on screen raised in glass, wider, and the address,
/// as Safari's compact tabs are: where the page is, a tap on it typing a new
/// one in the command bar, and its … and ✕. Then New Tab, the spaces and
/// Space Settings, each plain button 2 points from the next and the spaces'
/// glass a gap from both.
struct TopTabs: View {
    @ObservedObject var session: Session
    let window: WindowModel
    let act: (BarAction) -> Void
    /// The row's width, of which the pinned tiles take their share (PinnedOverflow);
    /// the spaces' buttons' width comes off it first, so more spaces put more of
    /// the pinned tabs behind their button instead of crowding the other tabs.
    @State private var width: CGFloat = 1000
    @State private var spacesWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let space = session.workspace.space(window.spaceID)
        let barTabs = space?.barTabs ?? [:]
        // Without the pinned tabs this device hides (Settings › Pinned Tabs).
        let row = TabRow(tabs: (space?.tabs ?? []).filter(session.preferences.shows), splits: space?.splits ?? [],
                         current: window.tabID, barTabs: Set(barTabs.values.map(\.id)))
        let others = session.workspace.spaces.filter { $0.id != window.spaceID }
        HStack(spacing: Side.gap) {
            HStack(spacing: 2) {
                SidePlainIcon("chevron.left", label: String(localized: "Back"), enabled: window.canGoBack) { act(.back) }
                SidePlainIcon("chevron.right", label: String(localized: "Forward"), enabled: window.canGoForward) { act(.forward) }
                if window.loading {
                    SidePlainIcon("xmark", label: String(localized: "Stop")) { act(.stop) }
                } else {
                    SidePlainIcon("arrow.clockwise", label: String(localized: "Reload"), enabled: window.url != nil) { act(.reload) }
                }
                let barShown = session.preferences.bookmarksBar
                SidePlainIcon(barShown ? "star.square.on.square.fill" : "star.square.on.square",
                              label: barShown ? String(localized: "Hide Bookmarks Bar") : String(localized: "Show Bookmarks Bar")) {
                    session.preferences.bookmarksBar.toggle()
                }
            }
            // The pinned tabs stay put while the others scroll beside them, spaced as the Mac's
            // are: each 4 points wider than a button, 4 apart, a step more open than the buttons.
            if !row.pinned.isEmpty {
                // Past their share of the row, the unopened and the longest unseen go behind a button.
                let split = PinnedOverflow.split(row.pinned, current: window.tabID,
                                                 live: Set(row.pinned.map(\.id).filter(session.pages.isLive)),
                                                 room: max(width - spacesWidth, 0), tile: Side.control + 4, gap: 4)
                HStack(spacing: 4) {
                    ForEach(split.shown) { tab in
                        TopPinnedTab(window: window, tab: tab, row: row, others: others, act: act)
                    }
                    if !split.hidden.isEmpty {
                        PinnedOverflowTile(tabs: split.hidden, act: act)
                    }
                }
                .animation(.bar, value: split.shown.map(\.id))
            }
            if let space, space.bar?.children?.isEmpty == false {
                TopBarBookmarks(window: window, space: space, act: act)
            }
            if !row.others.isEmpty, !row.pinned.isEmpty || space?.bar?.children?.isEmpty == false {
                Rectangle()
                    .fill(Side.secondary.opacity(0.3))
                    .frame(width: 1, height: 16)
            }
            GeometryReader { box in
                // A pinned or bookmarks bar tab on screen has the address too, first in the
                // row: where the page is, and its …, whichever kind of tab it is.
                let pinnedOnScreen = row.pinned.first { $0.id == window.tabID }
                    ?? barTabs.values.first { $0.id == window.tabID }
                let address = pinnedOnScreen != nil || row.others.contains { $0.id == window.tabID }
                let widths = TabWidths.widths(count: row.others.count + (pinnedOnScreen == nil ? 0 : 1), room: box.size.width,
                                              gap: 4, address: address)
                ScrollViewReader { reader in
                    ScrollView(.horizontal) {
                        HStack(spacing: 4) {
                            if let pinnedOnScreen {
                                TopTab(window: window, tab: pinnedOnScreen, row: row, others: others, address: true,
                                       width: widths.current, act: act)
                                    .id(pinnedOnScreen.id)
                                    .transition(.opacity)
                            }
                            ForEach(row.items) { item in
                                // A split's two side by side on a ground of their own, as one place in the row.
                                HStack(spacing: 0) {
                                    ForEach(item.tabs) { tab in
                                        let current = tab.id == window.tabID
                                        TopTab(window: window, tab: tab, row: row, others: others, address: address && current,
                                               width: current ? widths.current : widths.each, act: act)
                                            .id(tab.id)
                                    }
                                }
                                .background {
                                    if item.tabs.count > 1 {
                                        RoundedRectangle(cornerRadius: TopTab.corner, style: .continuous).fill(Side.wash)
                                    }
                                }
                            }
                        }
                        // Room inside the scroll view, which clips, for the tab on screen's
                        // glass: its rim at the ends, and its rim and shadow above and below,
                        // as far as the bar's own edges (Metrics.bar).
                        .padding(.horizontal, 3)
                        .padding(.vertical, (Metrics.bar - Side.control) / 2)
                        .animation(.bar, value: row.others.map(\.id))
                        .animation(.bar, value: pinnedOnScreen?.id)
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(TopTabs.space)).minX } action: { _ in
                            act(.hideTabHover)
                        }
                    }
                    .scrollIndicators(.never)
                    .padding(.horizontal, -3)
                    .padding(.vertical, -(Metrics.bar - Side.control) / 2)
                    .feathered(.horizontal)
                    // The tab on screen is always in view, however it came to be on screen.
                    .onAppear {
                        DispatchQueue.main.async { window.tabID.map { reader.scrollTo($0, anchor: .center) } }
                    }
                    .onChange(of: window.tabID) { _, tab in
                        withAnimation(reduceMotion ? nil : .bar) { tab.map { reader.scrollTo($0) } }
                    }
                }
            }
            .frame(height: Side.control)
            HStack(spacing: 2) {
                AllTabsButton(count: space?.tabs.count ?? 0) { act(.showTabs) }
                DownloadActivityButton { act(.downloads) }
                SidePlainIcon("plus", label: String(localized: "New Tab")) { act(.command(.newTab)) }
                    .contextMenu {
                        if space?.otherTabs.contains(where: { $0.id == window.tabID }) == true {
                            Button("New Tab in Split View", systemImage: "rectangle.split.2x1") { act(.splitWithNewTab) }
                        }
                    }
                SideSpaces(session: session, window: window, act: act, inRow: true)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { spacesWidth = $0 }
            }
        }
        .padding(.horizontal, Side.gap)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: window.spaceID) { _, _ in act(.hideTabHover) }
        .onDisappear { act(.hideTabHover) }
    }

    /// The top row's own coordinates, for the window's hover card.
    nonisolated static let space = "top-tabs"
}

/// The bookmarks bar beside the pinned tiles, its open tabs kept in view
/// under folders that are shut, as they are in the sidebar.
private struct TopBarBookmarks: View {
    let window: WindowModel
    let space: Space
    let act: (BarAction) -> Void
    @State private var showing = false
    @State private var open: Set<UUID> = []
    @State private var hovering = false

    var body: some View {
        // The bar's tabs once for the button and all the rows in its popover, not by each.
        let map = space.barMap
        let selected = map.tabs.values.contains { $0.id == window.tabID }
        let shape = RoundedRectangle(cornerRadius: TopTab.corner, style: .continuous)
        Button {
            act(.hideTabHover)
            showing.toggle()
        } label: {
            Image(systemName: "bookmark")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.ink)
                .frame(width: Side.control + 4, height: Side.control)
                // As under the pinned tiles beside it: the glyph is as tall as their icons.
                .overlay {
                    OpenDot(shown: !map.tabs.isEmpty, size: 3)
                        .offset(y: OpenDot.under(icon: 16, size: 3))
                }
                .background {
                    if selected {
                        Color.clear.liquidGlass(reacting: false, in: shape, otherwise: Palette.card)
                    } else {
                        shape.fill(hovering ? Side.hover : .clear)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(PressScale())
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .accessibilityLabel("Bookmarks Bar")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .popover(isPresented: $showing, arrowEdge: .top) {
            let canSplit = BarBookmarkRow.canSplit(window, in: space, map: map)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Bookmarks.rows(of: space.bar?.children ?? [], opening: open,
                                           keeping: Set(map.tabs.keys)), id: \.item.id) { row in
                        BarBookmarkRow(window: window, space: space, map: map, canSplit: canSplit, item: row.item,
                                       depth: row.depth, open: open.contains(row.item.id), source: .window, toggle: {
                            withAnimation(.bar) {
                                if !open.insert(row.item.id).inserted { open.remove(row.item.id) }
                            }
                        }, act: { action in
                            if case .openFromBar = action { showing = false }
                            act(action)
                        })
                    }
                }
                .padding(8)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.coordinates)).minY } action: { _ in
                    act(.hideTabHover)
                }
            }
            .scrollIndicators(.never)
            .coordinateSpace(.named(Self.coordinates))
            .frame(width: 288)
            .frame(maxHeight: 420)
            .presentationCompactAdaptation(.popover)
        }
        .onChange(of: showing) { _, _ in act(.hideTabHover) }
        .onChange(of: window.spaceID) { _, _ in
            showing = false
            open = []
        }
    }

    nonisolated private static let coordinates = "top-bar-bookmarks"
}

/// The pinned tabs past their share of the row (PinnedOverflow), behind a
/// tile that says how many: each in its menu, by its icon and name.
private struct PinnedOverflowTile: View {
    let tabs: [TabRecord]
    let act: (BarAction) -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TopTab.corner, style: .continuous)
        Menu {
            ForEach(tabs) { tab in
                Button { act(.select(tab.id)) } label: {
                    Label {
                        Text(tab.label)
                    } icon: {
                        if let image = SiteIcons.shared.image(for: tab.pinned ?? tab.url, dark: scheme == .dark) {
                            Image(uiImage: image)
                        } else {
                            Image(systemName: "pin")
                        }
                    }
                }
            }
        } label: {
            Text("\(tabs.count)")
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .dynamicTypeSize(...DynamicTypeSize.xLarge)
                .monospacedDigit()
                .foregroundStyle(Palette.ink.opacity(0.8))
                .frame(width: Side.control + 4, height: Side.control)
                .background(shape.fill(hovering ? Side.hover : Side.wash))
                .contentShape(shape)
        }
        .buttonStyle(PressScale())
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .accessibilityLabel("\(tabs.count) more pinned tabs")
    }
}

/// A tab in the row, as the Mac's: its site's icon and its name, a close
/// button under the pointer and on the one on screen, which is raised in
/// glass; where it is the address, where the page is and the page's menu.
private struct TopTab: View {
    let window: WindowModel
    let tab: TabRecord
    let row: TabRow
    let others: [Space]
    /// The tab on screen, standing for the address.
    let address: Bool
    let width: CGFloat
    let act: (BarAction) -> Void
    @State private var hovering = false

    static let corner: CGFloat = 10

    var body: some View {
        let selected = tab.id == window.tabID
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        // Half of a split stands inside the pair's ground with room round it,
        // as a segmented control's thumb does, so its glass's rim and shadow
        // show on the ground rather than meeting its edge.
        let inset: CGFloat = row.paired.contains(tab.id) ? 3 : 0
        let mark = RoundedRectangle(cornerRadius: Self.corner - inset, style: .continuous)
        HStack(spacing: 7) {
            Button { act(address ? .editAddress : .select(tab.id)) } label: {
                HStack(spacing: 7) {
                    ZStack {
                        if selected, window.loading {
                            ProgressView().controlSize(.mini)
                        } else if address, window.showsAddress, window.insecure {
                            // Not private: said where the address is, as before.
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.unsafe)
                        } else {
                            SiteIconView(url: tab.url, size: 16)
                                // A page let go of until it is opened again is a little quieter, as the Mac's.
                                .opacity(selected || Session.shared.pages.isLive(tab.id) ? 1 : 0.75)
                        }
                    }
                    .frame(width: 16, height: 16)
                    if address {
                        shownAddress
                            .font(.subheadline)
                            .lineLimit(1)
                            // The end of the host is who you are talking to: it is the part kept.
                            .truncationMode(.head)
                    } else {
                        Text(tab.label)
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Palette.ink : Palette.ink.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityRepresentation {
                Button {
                    act(address ? .editAddress : .select(tab.id))
                } label: {
                    let shown = window.url.map(Destination.pretty) ?? String(localized: "none")
                    Text(address ? (window.insecure ? String(localized: "Address, \(shown), Not secure") : String(localized: "Address, \(shown)")) : tab.label)
                }
                .accessibilityHint(address ? "Type a new address or a search" : "")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            // Always there, for a finger, which has no pointer to bring them out.
            if address {
                SidePageMenu(window: window, act: act, inTab: true)
            }
            // A pinned tab's address has no ✕: the tab stays, as its tile does.
            if selected || hovering, !tab.isPinned {
                SideClose { act(.close(tab.id)) }
                    .transition(.opacity)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(width: width, height: Side.control)
        .background {
            if selected {
                Color.clear.liquidGlass(reacting: false, in: mark, otherwise: Palette.card).padding(inset)
            } else {
                mark.fill(hovering ? Side.hover : .clear).padding(inset)
            }
        }
        .contentShape(shape)
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .contextMenu { TabMenuItems(window: window, tab: tab, row: row, others: others, act: act) }
        .draggable(TabDrop(id: tab.id)) {
            HStack(spacing: 8) {
                SiteIconView(url: tab.url, size: 16)
                Text(tab.title).font(.system(size: 13)).lineLimit(1)
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

    /// Where the page on screen is, as the address said it before
    /// (addressText); its title where Settings has the address shown only
    /// when it must be; what to do before it has been anywhere.
    @ViewBuilder
    private var shownAddress: some View {
        if let url = window.url {
            if window.showsAddress {
                addressText(url, engine: Session.shared.preferences.engine, quiet: Side.secondary)
                    .foregroundStyle(Palette.ink)
            } else {
                Text(window.title.isEmpty ? tab.label : window.title)
                    .fontWeight(.medium)
                    .foregroundStyle(Palette.ink)
            }
        } else {
            Text(AddressEditor.placeholder)
                .foregroundStyle(Side.secondary)
        }
    }
}

/// A pinned tab in the row, as the Mac's: its icon, shading under the
/// pointer; the one on screen on a small tile of glass tinted with its
/// icon's ground, as the sidebar's tile is, and standing for the address.
private struct TopPinnedTab: View {
    let window: WindowModel
    let tab: TabRecord
    let row: TabRow
    let others: [Space]
    let act: (BarAction) -> Void
    @ObservedObject private var icons = SiteIcons.shared
    @State private var pointer: CGPoint?
    @State private var size = CGSize.zero
    @State private var hovering = false

    var body: some View {
        let selected = tab.id == window.tabID
        let shape = RoundedRectangle(cornerRadius: TopTab.corner, style: .continuous)
        let url = tab.url ?? tab.pinned
        let colour = Session.shared.workspace.space(window.spaceID)?.color ?? .blue
        let ground = selected ? PinnedIcon.tileTint(for: url, colour: colour) : nil
        Button {
            act(.hideTabHover)
            act(selected ? .editAddress : .select(tab.id))
        } label: {
            ZStack {
                let lean = Plate.lean(toward: pointer, in: size, reach: CGSize(width: 6, height: 4))
                PointerGlow(lean: lean, radius: 28)
                PinnedIcon(url: url, open: selected, colour: colour, size: 16, lean: lean, plate: (side: 18, corner: 6, blur: 6))
            }
            .frame(width: Side.control + 4, height: Side.control)
            // Open, as the phone's dock marks it: a dot just under the icon.
            .overlay {
                OpenDot(shown: Pinned.isOpen(tab), size: 3)
                    .offset(y: OpenDot.under(icon: 16, size: 3))
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .background(shape.fill(hovering && !selected ? Side.hover : .clear))
            .clipShape(shape)
            .contentShape(shape)
            // Glass only on the one on screen: the others are icons on the row, as its tabs are names.
            .background {
                if selected {
                    Color.clear.liquidGlass(.regular, tint: ground ?? Palette.ink.opacity(0.12),
                                            reacting: false, in: shape, otherwise: Palette.card)
                }
            }
        }
        .buttonStyle(PressScale())
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .modifier(TabHoverModifier(id: tab.id, tab: tab.id, title: tab.label, url: url,
                                   isOpen: Pinned.isOpen(tab), source: .top, act: act))
        .onContinuousHover { phase in
            withAnimation(.spring(duration: 0.6, bounce: 0)) {
                if case .active(let point) = phase { pointer = point } else { pointer = nil }
            }
        }
        .contextMenu { TabMenuItems(window: window, tab: tab, row: row, others: others, act: act) }
        .draggable(TabDrop(id: tab.id)) { SiteIconView(url: url, size: 24).environment(\.spaceColor, colour) }
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
