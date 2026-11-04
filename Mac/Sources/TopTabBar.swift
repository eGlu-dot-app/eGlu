import AppKit
import PadCore
import SwiftUI

/// The tabs along the top, for whoever chose them there over the sidebar
/// (Settings › General › Tabs): one row on the window's ground, level with
/// the window's own buttons, as the iPad's row is (TopTabs). Back, forward,
/// reload and the other bookmarks' button; the space's pinned tabs as small tiles, and its
/// bookmarks bar behind a button beside them (BarButton); its other tabs,
/// sharing what room there is (TabWidths), the one on screen raised in
/// glass, wider, and the address, as Safari's compact tabs are: where the
/// page is, a click on it opening the command bar on its address, and its …
/// and ✕ under the pointer. Then New Tab, the spaces and Space Settings, each plain button 2 points from the
/// next and the spaces' glass a gap from both.
struct TopTabBar: View {
    @ObservedObject var model: WindowModel
    @ObservedObject private var session = Session.shared
    /// The row's width, of which the pinned tiles take their share (PinnedOverflow).
    @State private var width: CGFloat = 1200

    /// What a tab's glass draws past its shape.
    private static let rim: CGFloat = 3

    var body: some View {
        let space = session.workspace.space(model.spaceID)
        let pinned = space?.tabs.filter { $0.isPinned && session.preferences.shows($0) } ?? []
        let others = space?.otherTabs ?? []
        let bar = space?.bar.flatMap { ($0.children ?? []).isEmpty ? nil : $0 }
        HStack(spacing: Metrics.gap) {
            WindowButtons()
                .frame(width: WindowButtons.width, height: WindowButtons.side)
                .padding(.leading, (Metrics.control - WindowButtons.side) / 2)
            HStack(spacing: 2) {
                PlainIcon("chevron.left", help: String(localized: "Back (⌘[)"), enabled: model.canGoBack) { model.back() }
                PlainIcon("chevron.right", help: String(localized: "Forward (⌘])"), enabled: model.canGoForward) { model.forward() }
                if model.loading {
                    PlainIcon("xmark", help: String(localized: "Stop (⌘.)")) { model.stop() }
                } else {
                    PlainIcon("arrow.clockwise", help: String(localized: "Reload (⌘R)"), enabled: model.tabID != nil) { model.reload() }
                }
                let barShown = session.preferences.bookmarksBar
                PlainIcon(barShown ? "star.square.on.square.fill" : "star.square.on.square",
                          help: barShown ? String(localized: "Hide Other Bookmarks (⇧⌘B)") : String(localized: "Show Other Bookmarks (⇧⌘B)")) {
                    withAnimation(.bar) { session.preferences.bookmarksBar.toggle() }
                }
            }
            // The pinned tabs stay put while the others scroll beside them, the bar's behind its button.
            if !pinned.isEmpty || bar != nil {
                // Past their share of the row, the unopened and the longest unseen go behind a button.
                let split = PinnedOverflow.split(pinned, current: model.tabID,
                                                 live: Set(pinned.map(\.id).filter(session.pages.isLive)),
                                                 room: width - (bar == nil ? 0 : Metrics.control + 8), tile: Metrics.control + 4, gap: 4)
                HStack(spacing: 4) {
                    ForEach(split.shown) { tab in
                        PinnedTile(model: model, tab: tab, look: .topRow)
                    }
                    if !split.hidden.isEmpty {
                        PinnedOverflowTile(model: model, tabs: split.hidden)
                    }
                    if let space, let bar {
                        BarButton(model: model, space: space, bar: bar)
                    }
                }
                .animation(.bar, value: split.shown.map(\.id))
                if !others.isEmpty {
                    Rectangle()
                        .fill(Palette.faint)
                        .frame(width: 1, height: 16)
                }
            }
            GeometryReader { box in
                let widths = TabWidths.widths(count: others.count, room: box.size.width, gap: 4,
                                              address: others.contains { $0.id == model.tabID })
                ScrollViewReader { reader in
                    ScrollView(.horizontal) {
                        HStack(spacing: 4) {
                            ForEach(space.map(TabList.items(of:)) ?? [], id: \.first?.id) { item in
                                // A split's two side by side on a ground of their own, as one place in the row.
                                HStack(spacing: 0) {
                                    ForEach(item) { tab in
                                        TopTab(model: model, tab: tab, width: tab.id == model.tabID ? widths.current : widths.each)
                                            .id(tab.id)
                                    }
                                }
                                .background {
                                    if item.count == 2 {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.wash)
                                    }
                                }
                            }
                        }
                        // Room for the glass's rim inside the scroll view, all round.
                        .padding(Self.rim)
                        .animation(.bar, value: others.map(\.id))
                    }
                    .scrollIndicators(.never)
                    // Feathered before it is let out, as the sidebar's list is: on the
                    // row's frame the mask cut the rim's room off again.
                    .feathered(.horizontal)
                    .padding(-Self.rim)
                    // The tab on screen is always in view, however it came to be on screen.
                    .onAppear {
                        DispatchQueue.main.async { model.tabID.map { reader.scrollTo($0, anchor: .center) } }
                    }
                    .onChange(of: model.tabID) { _, tab in
                        withAnimation(.bar) { tab.map { reader.scrollTo($0) } }
                    }
                }
            }
            .frame(height: Metrics.control)
            HStack(spacing: 2) {
                PlainIcon("plus", help: String(localized: "New Tab (⌘T)")) { model.perform(.newTab) }
                SpaceBar(model: model, inRow: true)
                    .fixedSize()
                // Extensions (ExtensionBar.swift): the puzzle button and its list.
                ExtensionsButton(model: model)
            }
        }
        // The row's ground moves the window, as a title bar does; what is on it are only buttons.
        .background {
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// The bookmarks bar along the top: a bookmark beside the pinned tiles, on
/// glass while one of the bar's tabs is on screen, with a dot under it
/// while any is open, which brings out the bar's rows under it (BarPanel).
private struct BarButton: View {
    @ObservedObject var model: WindowModel
    let space: Space
    let bar: Bookmark
    @State private var hovering = false
    /// Where the button is in the window, for the rows to come out under it.
    @State private var frame = CGRect.zero

    var body: some View {
        let tabs = space.barTabs
        let current = tabs.values.contains { $0.id == model.tabID }
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Button {
            withAnimation(.bar) { model.barPanelButton = model.barPanelButton == nil ? frame : nil }
        } label: {
            Image(systemName: current ? "bookmark.fill" : "bookmark")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.8))
                .frame(width: Metrics.control + 4, height: Metrics.control)
                // As under the pinned tiles beside it: the glyph is as tall as their icons.
                .overlay {
                    OpenDot(shown: !tabs.isEmpty, size: 3)
                        .offset(y: OpenDot.under(icon: 16, size: 3))
                }
                .background {
                    if current {
                        shape.fill(.clear).glassEffect(.regular, in: shape)
                    } else {
                        Highlight(hovering: hovering, shape: shape)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(TilePress())
        .onHover { hovering = $0 }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(BrowserView.place)) } action: { frame = $0 }
        .help("Bookmarks Bar")
        .accessibilityLabel("Bookmarks Bar")
        .accessibilityValue(tabs.isEmpty ? "" : String(localized: "\(tabs.count) open"))
        #if DEBUG
        // `-barPopover YES`: the bar's rows out at once, for a picture.
        .task(id: frame) {
            guard frame != .zero, UserDefaults.standard.bool(forKey: "barPopover"), model.barPanelButton == nil else { return }
            try? await Task.sleep(for: .seconds(1))
            model.barPanelButton = frame
        }
        #endif
    }
}

/// The bookmarks bar's rows along the top, out under its button over the
/// page: a pane of Liquid Glass lifted by a soft shadow, as the sidebar's
/// other bookmarks are (BookmarksPanel), its corners as far from the rows'
/// as the rows are from its edge, and the rows as the sidebar has them
/// (BarList). A bookmark chosen, a click anywhere else, Escape or another
/// space puts it away.
struct BarPanel: View {
    @ObservedObject var model: WindowModel
    @ObservedObject private var session = Session.shared
    @Environment(\.colorScheme) private var scheme

    /// From the pane's edge to its rows.
    static let inset: CGFloat = 6

    var body: some View {
        let card = RoundedRectangle(cornerRadius: Metrics.rowCorner + Self.inset, style: .continuous)
        if let space = session.workspace.space(model.spaceID), let bar = space.bar {
            // As tall as its rows, and no taller than the window gives it: past that they scroll.
            ViewThatFits(in: .vertical) {
                rows(space, bar)
                ScrollView { rows(space, bar) }
                    .scrollIndicators(.never)
            }
            .frame(width: 280)
            // Clipped first: rows scrolled to an end would show past the corners.
            .clipShape(card)
            .glassEffect(.regular, in: card)
            .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.14), radius: 24, y: 10)
            // For the window's watch on clicks: one off this puts it away (WindowModel.clickedAway).
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(BrowserView.place)) } action: { model.barPanelFrame = $0 }
            .background {
                Button("Close Bookmarks Bar") { close() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Bookmarks Bar")
            .accessibilityAction(.escape) { close() }
        }
    }

    private func rows(_ space: Space, _ bar: Bookmark) -> some View {
        BarList(model: model, space: space, bar: bar, chose: close)
            .padding(Self.inset)
    }

    private func close() {
        withAnimation(.bar) { model.barPanelButton = nil }
    }
}

/// The pinned tabs past their share of the row (PinnedOverflow), behind a
/// tile that says how many: each in its menu, by its icon and name.
private struct PinnedOverflowTile: View {
    @ObservedObject var model: WindowModel
    let tabs: [TabRecord]
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Menu {
            ForEach(tabs) { tab in
                Button { model.select(tab.id) } label: {
                    Label {
                        Text(tab.label)
                    } icon: {
                        if let image = SiteIcons.shared.image(for: tab.pinned ?? tab.url, dark: scheme == .dark) {
                            Image(nsImage: image)
                        } else {
                            Image(systemName: "pin")
                        }
                    }
                }
            }
        } label: {
            Text("\(tabs.count)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: Metrics.control + 4, height: Metrics.control)
                .background(Highlight(hovering: hovering, shape: shape))
                .contentShape(shape)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("\(tabs.count) more pinned tabs")
        .accessibilityLabel("\(tabs.count) more pinned tabs")
    }
}

/// The space's other bookmarks, all but the bar, in a row under the tabs,
/// for whoever keeps the tabs along the top and turned it on
/// (Preferences.bookmarksBar): each its icon and name; a folder, a menu of
/// what it holds. A click opens one here, a ⌘-click in a new tab. The bar's
/// own are behind its button beside the pinned tiles (BarButton).
struct BookmarksBar: View {
    @ObservedObject var model: WindowModel
    @ObservedObject private var session = Session.shared

    var body: some View {
        let bookmarks = Bookmarks.others(in: session.workspace.space(model.spaceID)?.bookmarks ?? [])
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                if bookmarks.isEmpty {
                    Text("No bookmarks in this space yet. Bookmark a page with ⌘D.")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                }
                ForEach(bookmarks) { item in
                    BarBookmark(model: model, item: item)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .scrollIndicators(.never)
        .feathered(.horizontal)
    }
}

/// A bookmark in the bar: its icon and name, as narrow as they let it be.
private struct BarBookmark: View {
    @ObservedObject var model: WindowModel
    let item: Bookmark

    var body: some View {
        if item.isFolder {
            Menu {
                FolderMenu(model: model, items: item.children ?? [])
            } label: {
                label
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(RowButtonStyle(corner: 8))
            .fixedSize()
            .help(item.label)
        } else if let url = item.url {
            Button { model.open(bookmark: url) } label: { label }
                .buttonStyle(RowButtonStyle(corner: 8))
                .fixedSize()
                .help(Destination.pretty(url))
                .contextMenu {
                    Button("Open in New Tab") { model.open(url, newTab: true) }
                    Button("Copy Address") { model.copyAddress(url) }
                }
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            if item.isFolder {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                SiteIconView(url: item.url, size: 14)
            }
            Text(item.label)
                .font(.system(size: 12))
                .lineLimit(1)
                .frame(maxWidth: 160, alignment: .leading)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
    }
}

/// What a folder in the bar holds, as a menu: its bookmarks, its folders as menus of their own.
private struct FolderMenu: View {
    @ObservedObject var model: WindowModel
    let items: [Bookmark]

    var body: some View {
        if items.isEmpty {
            Text("Empty")
        }
        ForEach(items) { item in
            if item.isFolder {
                Menu(item.label) { FolderMenu(model: model, items: item.children ?? []) }
            } else if let url = item.url {
                Button(item.label) { model.open(bookmark: url) }
            }
        }
    }
}

/// A tab in the row: its site's icon and its name, a close button while the
/// pointer is on it. The one on screen is raised in glass and is the
/// address: where it is, a click on it opening the command bar there (⌘L),
/// and under the pointer the page's … beside the ✕.
private struct TopTab: View {
    @ObservedObject var model: WindowModel
    let tab: TabRecord
    let width: CGFloat
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        let selected = model.tabID == tab.id
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        HStack(spacing: 7) {
            Button {
                if selected { model.commandBar = .here } else { model.select(tab.id) }
            } label: {
                HStack(spacing: 7) {
                    ZStack {
                        if selected, model.loading, model.page != nil {
                            ProgressView().controlSize(.mini)
                        } else {
                            SiteIconView(url: tab.url, size: 16)
                        }
                    }
                    .frame(width: 16, height: 16)
                    if selected {
                        Group {
                            if let url = model.url {
                                addressText(url, engine: Session.shared.preferences.engine, quiet: .secondary)
                                    .foregroundStyle(Color.primary)
                            } else {
                                Text("Search or enter address")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                        // The end of the host is who you are talking to: it is the part kept.
                        .truncationMode(.head)
                    } else {
                        Text(tab.label)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.primary.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(selected ? String(localized: "Address, \(model.url.map(Destination.pretty) ?? tab.label)") : tab.label)
            .accessibilityAddTraits(selected ? .isSelected : [])
            // Kept while its popover is open, which it stands under, and for Share… from the menu bar.
            if selected, hovering || model.pageActionsShown {
                PageActionsButton(model: model, inTab: true)
                    .transition(.opacity)
            }
            if hovering {
                CloseButton { model.closeTab(tab.id) }
                    .transition(.opacity)
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .frame(width: width, height: Metrics.control)
        .background {
            if selected {
                shape.fill(.clear).glassEffect(.regular, in: shape)
            } else {
                Highlight(hovering: hovering, shape: shape)
            }
        }
        .overlay(alignment: .leading) {
            Capsule().fill(Color.accentColor).frame(width: 2, height: 18).offset(x: -3).opacity(targeted ? 1 : 0)
        }
        .contentShape(shape)
        .onHover { inside in withAnimation(.hover) { hovering = inside } }
        .draggable(TabDrag(tab: tab.id)) {
            HStack(spacing: 6) {
                SiteIconView(url: tab.url, size: 16)
                Text(tab.label).font(.system(size: 12.5)).lineLimit(1)
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
        .help(selected ? String(localized: "\(tab.url?.absoluteString ?? tab.label): click to type an address (⌘L)") : tab.url?.absoluteString ?? tab.label)
        .accessibilityElement(children: .contain)
    }

}
