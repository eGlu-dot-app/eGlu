import AppKit
import PadCore
import SwiftUI

/// A window as SwiftUI keeps it between launches: an identity of its own,
/// so ⌘N always makes another, and the space it showed last.
struct WindowSeed: Codable, Hashable {
    var id = UUID()
    var space: UUID?
}

/// A window: the space's colour as its ground, the sidebar down its left,
/// the page as a card beside it, and the command bar over both when asked for.
struct BrowserView: View {
    /// What SwiftUI keeps of the window, to bring it back as it was at the next launch.
    @Binding var seed: WindowSeed?
    @StateObject private var model: WindowModel
    @ObservedObject private var session = Session.shared
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var scheme
    /// The sidebar's width as a drag on its edge began.
    @State private var widthAtStart: CGFloat?
    /// The width the page's card shares with an extension's side panel.
    @State private var cardsWidth: CGFloat = 0
    /// The writing question's sheet (task 05).
    @State private var askingWriting = false
    /// A launch asks the writing question on the first window only.
    private static var writingAskShown = false

    init(seed: Binding<WindowSeed?>) {
        _seed = seed
        _model = StateObject(wrappedValue: WindowModel(space: seed.wrappedValue?.space))
    }

    var body: some View {
        let colour = session.workspace.space(model.spaceID)?.color ?? .blue
        ZStack(alignment: .topLeading) {
            SpaceWash(color: colour)
                .accessibilityHidden(true)
            // The page's card stays one view whichever way the tabs are, so
            // its page isn't handed from one card to another as they change.
            let side = model.tabsInSidebar && model.sidebarShown
            HStack(spacing: 0) {
                if side {
                    Sidebar(model: model)
                        .frame(width: model.sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    edge
                }
                VStack(spacing: Metrics.gap) {
                    // The tabs along the top (Settings › General › Tabs): one row over the page.
                    if !model.tabsInSidebar {
                        TopTabBar(model: model)
                            .frame(height: Metrics.control)
                            .transition(.opacity)
                        if session.preferences.bookmarksBar {
                            BookmarksBar(model: model)
                                .frame(height: Metrics.control)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    // An extension's side panel beside the pages (ExtensionSidePanel.swift).
                    HStack(spacing: Metrics.gap) {
                        PageArea(model: model)
                            // What a command did that leaves nothing to see, at the page's top
                            // right, under the developer bar's buttons where the page has it.
                            .overlay(alignment: .topTrailing) {
                                ToastView(toast: model.toast)
                                    .padding(12)
                                    .padding(.top, DeveloperBar.isOn(at: .trailing, in: model) ? DeveloperBar.height : 0)
                            }
                        ExtensionSidePanelView(model: model, room: cardsWidth)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { cardsWidth = $0 }
                    // The panel follows the tab on screen; another space puts it away.
                    .onChange(of: model.tabID) { _, _ in ExtensionSidePanels.shared.tabChanged(in: model) }
                    .onChange(of: model.spaceID) { _, _ in ExtensionSidePanels.shared.close(in: model) }
                }
                .padding(.vertical, Metrics.bezel)
                .padding(.trailing, Metrics.bezel)
                .padding(.leading, side ? 0 : Metrics.bezel)
            }
            .accessibilityHidden(model.commandBar != nil)
            if model.tabsInSidebar, !model.sidebarShown {
                peek
                    .accessibilityHidden(model.commandBar != nil)
            }
            if let purpose = model.commandBar {
                commandBar(purpose)
            }
        }
        .ignoresSafeArea()
        // A site's letter, until its icon comes, on the space's colour (SiteIconView).
        .environment(\.spaceColor, colour)
        .background(WindowReader(model: model))
        .frame(minWidth: 640, minHeight: 420)
        .focusedSceneObject(model)
        .overlay(alignment: .bottom) {
            WorkspaceSaveStatusView()
                .frame(maxWidth: 600)
                .padding(12)
                .accessibilityHidden(model.commandBar != nil)
        }
        .sheet(isPresented: $model.historyShown) {
            HistoryView(spaceID: model.spaceID) { url, newTab in
                model.open(url, newTab: newTab)
            } done: {
                model.historyShown = false
            }
            .frame(width: 600, height: 640)
        }
        .sheet(isPresented: $model.historyClearing) {
            ClearHistoryView(spaceID: model.spaceID) { model.historyClearing = false }
        }
        .sheet(isPresented: $askingWriting) {
            WritingQuestion(offersOtherApps: true,
                            check: { otherApps in
                                session.preferences.writing = true
                                // Checking outside eGlu takes Accessibility;
                                // asking the moment it is chosen (task 03's
                                // part of the question).
                                if otherApps {
                                    session.preferences.writingOtherApps = true
                                    AccessibilityAccess.shared.ask()
                                }
                                askingWriting = false
                            },
                            notNow: { askingWriting = false })
                .padding(28)
                .frame(width: 440)
        }
        .onAppear {
            session.openSettings = { openSettings() }
            model.appear()
            // The writing question asks once, on the launch's first window,
            // and only where Harper's engine is there to answer it. Asked
            // already, Harper is never touched: the flag is read first, and
            // canCheck builds no rules.
            if !Self.writingAskShown,
               WritingAsk.decision(welcomePending: false, asked: WritingAsked.wasAsked) == .sheet,
               WritingChecker.canCheck {
                Self.writingAskShown = true
                askingWriting = true
            }
        }
        .onDisappear { model.disappear() }

        .onChange(of: model.spaceID) { _, space in seed = WindowSeed(id: seed?.id ?? UUID(), space: space) }
    }

    /// The sidebar's edge, beside the card: dragged, it makes the sidebar wider or narrower.
    private var edge: some View {
        Color.clear
            .frame(width: Metrics.bezel)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                // The edge moves as the width changes; measure outside its moving coordinates.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = widthAtStart ?? model.sidebarWidth
                        widthAtStart = start
                        let width = start + drag.translation.width
                        model.sidebarWidth = min(max(width, WindowModel.widths.lowerBound), WindowModel.widths.upperBound)
                    }
                    .onEnded { _ in widthAtStart = nil }
            )
    }

    /// The hidden sidebar: a strip along the window's left edge that brings
    /// it out over the page, as a pane of glass, until the pointer has left
    /// the strip and the pane together for a moment.
    private var peek: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: Metrics.gap + 2)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            if model.peeking {
                let shape = RoundedRectangle(cornerRadius: Metrics.pane, style: .continuous)
                let colour = session.workspace.space(model.spaceID)?.color ?? .blue
                // As wide inside as the sidebar it stands for, with a gap of its own on the page's side;
                // its glass tinted with the space's colour, as the window's ground is where it stays open.
                Sidebar(model: model, floating: true)
                    .frame(width: model.sidebarWidth + Metrics.gap)
                    .clipShape(shape)
                    .glassEffect(.regular.tint(colour.color.opacity(scheme == .dark ? 0.3 : 0.24)), in: shape)
                    .animation(.easeInOut(duration: 0.35), value: colour)
                    .padding(Metrics.gap)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .onHover { model.peek($0) }
    }

    private func commandBar(_ purpose: CommandBarPurpose) -> some View {
        GeometryReader { box in
            ZStack(alignment: .top) {
                // A click anywhere else puts the bar away.
                Color.black.opacity(0.14)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismissCommandBar)
                    .accessibilityHidden(true)
                let top = max(box.size.height * 0.16, 48)
                // The rows have what is left under the field, down to a margin at the window's foot.
                CommandBar(model: model, purpose: purpose, room: max(box.size.height - top - 56 - 24, 120))
                    .id(purpose)
                    .frame(width: min(660, box.size.width - 48))
                    .padding(.top, top)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command bar")
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, dismissCommandBar)
        .accessibilityAction(named: "Close Command Bar", dismissCommandBar)
        .onExitCommand(perform: dismissCommandBar)
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }

    private func dismissCommandBar() {
        guard model.commandBar != nil else { return }
        model.commandBar = nil
        model.focusPage()
    }
}

// MARK: The page's card

/// Where the pages go: the tab on screen's, as a card; or, while it is in a
/// split, its two pages side by side, each a card, in the split's order,
/// with the divider between them (Split View, the iPad's, laid out as the
/// Mac's Search lays out its pair). A window too narrow for two keeps the
/// page with the keys alone on screen until there is room again, and the
/// pair stays a pair.
private struct PageArea: View {
    @ObservedObject var model: WindowModel
    /// The left page's share while the divider is held; nil otherwise.
    @State private var held: Double?
    /// The divider stays at even once brought to it, until pulled well away.
    @State private var snapped = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The measuring tool's panel: the page on screen's, or the page
    /// beside's, measured from its own bar.
    private var measuring: MeasureModel? {
        model.page?.measure ?? (model.split != nil ? model.partner?.measure : nil)
    }

    /// Between the pages: room for the divider.
    static let gutter: CGFloat = 7
    /// Narrower than this, a page is no use.
    static let narrowest: CGFloat = 250
    /// How close to even the divider comes before it settles there, and how
    /// far past even it is pulled before it lets go.
    static let snap: CGFloat = 15
    static let unsnap: CGFloat = 20

    var body: some View {
        GeometryReader { box in
            let room = box.size.width - Self.gutter
            if let split = model.split, let partner = model.partner, room >= 2 * Self.narrowest {
                let left = leftWidth(share: held ?? split.ratio, room: room)
                HStack(spacing: 0) {
                    pane(split.left, partner: partner)
                        .frame(width: left)
                    SplitDivider(width: Self.gutter, model: model,
                                 moved: { x in drag(to: x, room: room) },
                                 ended: { if let held { model.setSplitRatio(held) }; held = nil },
                                 even: { model.setSplitRatio(0.5) })
                    pane(split.right, partner: partner)
                        .frame(width: room - left)
                }
                .coordinateSpace(.named(SplitDivider.space))
            } else {
                PaneCard(model: model, tab: model.tabID, page: model.page, focused: true, paired: false)
            }
        }
        // A Peek over the pages, its tab's (Peek.swift), under an extension's popup.
        .overlay {
            PeekLayer(model: model)
        }
        // An extension's popup, in a pane as Handoff's, at the corner nearest its button (ExtensionPopup.swift).
        .overlay(alignment: .top) {
            ExtensionPopupPane(model: model)
        }
        // A handoff being made ready, and the measuring tool's panel, stand
        // at the page's corner and hold nothing up (HandoffPanel,
        // MeasurePanel): one above the other while both are up.
        .overlay(alignment: .bottomTrailing) {
            let arrive: AnyTransition = reduceMotion ? .opacity : .offset(y: 16).combined(with: .opacity)
            VStack(alignment: .trailing, spacing: 12) {
                if let measure = measuring {
                    MeasurePanel(model: measure)
                        .transition(arrive)
                }
                if let job = model.handoff {
                    HandoffPanel(model: model, job: job)
                        .transition(arrive)
                } else if model.handoffChoosing {
                    // "Handoff File…" before a file is picked: the same pane asks for one.
                    HandoffPanel(model: model, job: nil)
                        .transition(arrive)
                }
            }
            .padding(16)
        }
        .animation(.bar, value: model.handoff == nil)
        .animation(.bar, value: model.handoffChoosing)
        .animation(.bar, value: measuring == nil)
        .animation(.bar, value: model.split)
        .animation(.bar, value: model.tabID)
        // The room the panes over the pages are moved in (MovablePane).
        .coordinateSpace(.named(MovablePane.room))
    }

    private func pane(_ tab: UUID, partner: Page) -> some View {
        let focused = tab == model.tabID
        return PaneCard(model: model, tab: tab, page: focused ? model.page : partner, focused: focused, paired: true)
    }

    /// The left page's width for a share of the room: neither page narrower than `narrowest`.
    private func leftWidth(share: Double, room: CGFloat) -> CGFloat {
        min(max(room * CGFloat(share), Self.narrowest), room - Self.narrowest)
    }

    /// The divider held at `x` across the pages: the pages follow it, and
    /// even takes it, with a tap of the trackpad, when it comes near.
    private func drag(to x: CGFloat, room: CGFloat) {
        var left = leftWidth(share: Double((x - Self.gutter / 2) / room), room: room)
        let even = room / 2
        if snapped {
            if abs(left - even) > Self.unsnap { snapped = false } else { left = even }
        } else if abs(left - even) <= Self.snap {
            snapped = true
            left = even
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        held = Double(left / room)
    }
}

/// The line between a split's two pages, as Search's divider: a short
/// grip on the window's ground that grows under the pointer and while held;
/// dragged, the pages follow it; double-clicked, they are made even. Its
/// menu has the rest. It never takes the keys: the page keeps them.
private struct SplitDivider: View {
    let width: CGFloat
    @ObservedObject var model: WindowModel
    let moved: (CGFloat) -> Void
    let ended: () -> Void
    let even: () -> Void
    @State private var hovering = false
    @State private var held = false

    /// The pages' row, as the divider's drag measures across it.
    static let space = "split"

    var body: some View {
        let active = hovering || held
        ZStack {
            Color.clear
            Capsule()
                .fill(active ? Palette.muted : Palette.faint)
                .frame(width: 3, height: held ? 80 : active ? 64 : 44)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .pointerStyle(.columnResize)
        .onHover { inside in withAnimation(.hover) { hovering = inside } }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                .onChanged { drag in
                    if !held { withAnimation(.bar) { held = true } }
                    moved(drag.location.x)
                }
                .onEnded { _ in
                    withAnimation(.bar) { held = false }
                    ended()
                }
        )
        .onTapGesture(count: 2, perform: even)
        .contextMenu {
            Button("Make Even") { even() }
            Button("Swap Sides") { model.swapSides() }
            Button("Separate Tabs") { model.separate() }
            Divider()
            Button("Close Both Tabs") { model.closeSplit() }
        }
        .animation(.bar, value: held)
        .help("Drag to make one page wider; double-click to make them even")
        .accessibilityElement()
        .accessibilityLabel("Split divider")
        .accessibilityHint("Double-click to make the two pages even")
        .accessibilityAction(named: "Make Even", even)
    }
}

/// A page as a card with round corners standing on the window's ground: the
/// space's start where the tab has gone nowhere yet, and what went wrong
/// where the page couldn't load. With two pages up, the one with the keys
/// has a line of the space's colour round it (the iPad's line along its
/// top, Search's hairline round it), and the other says whose it is while
/// the pointer is on it.
private struct PaneCard: View {
    @ObservedObject var model: WindowModel
    let tab: UUID?
    let page: Page?
    let focused: Bool
    let paired: Bool
    @State private var hovering = false

    /// The developer bar across the page's top, where the site has it on.
    private var barred: Bool {
        guard let page, page.view.url != nil || focused && model.url != nil else { return false }
        return DeveloperBar.isOn(page, url: focused ? model.url : nil)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.card, style: .continuous)
        // The page beside draws again as it says something new.
        let _ = paired && !focused ? model.partnerRevision : 0
        // What stands at the card's top goes below the bar, off its buttons.
        let below = barred ? DeveloperBar.height : 0
        ZStack(alignment: .topTrailing) {
            shape
                .fill(Color(nsColor: .textBackgroundColor))
                .shadow(color: .black.opacity(0.16), radius: 1, y: 0.5)
                .shadow(color: .black.opacity(0.08), radius: 14, y: 6)
            if let page, page.view.url != nil || focused && model.url != nil {
                VStack(spacing: 0) {
                    if barred {
                        DeveloperBar(model: model, tab: tab, page: page, focused: focused)
                    }
                    // A size from the bar's Size menu has the page centred
                    // in the card's colour, no bigger than the card, so a
                    // short window keeps the page's top; Full is the whole card.
                    ZStack {
                        PageSurface(page: page)
                            .frame(maxWidth: page.deviceSize?.width ?? .infinity,
                                   maxHeight: page.deviceSize?.height ?? .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .clipShape(shape)
                if let failure = focused ? model.failure : page.failure {
                    FailureView(message: failure, url: focused ? model.url : page.view.url) {
                        if focused { model.reload() } else { page.reload() }
                    }
                    .clipShape(shape)
                }
            } else if focused {
                StartView(model: model)
                    .clipShape(shape)
            } else {
                EmptyPane(model: model, tab: tab)
                    .clipShape(shape)
            }
            if focused, model.finding {
                FindBar(model: model)
                    .padding(Metrics.gap)
                    .padding(.top, below)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if paired, !focused, hovering, let host = page?.view.url?.host() {
                Text(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .glassEffect(.regular, in: Capsule())
                    .padding(10)
                    .padding(.top, below)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .overlay {
            if paired, focused {
                shape.strokeBorder(model.space?.color.color ?? .accentColor, lineWidth: 1.5)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .onHover { inside in withAnimation(.hover) { hovering = inside } }
        .animation(.bar, value: model.finding)
        .animation(.bar, value: focused)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Focus Page") { if let tab, !focused { model.focus(pane: tab) } }
    }
}

/// The page beside that has gone nowhere yet: a click on it gives it the
/// keys, and the command bar for its address.
private struct EmptyPane: View {
    @ObservedObject var model: WindowModel
    let tab: UUID?

    var body: some View {
        Button {
            guard let tab else { return }
            model.focus(pane: tab)
            model.commandBar = .newTab
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 22, weight: .medium))
                Text("Search or enter an address")
                    .font(.system(size: 13))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A tab that has gone nowhere yet: the space's mark and name, a field
/// that is the command bar's, the space's bookmarks as tiles, a folder
/// opening in place, and the pages last gone to here and on the other
/// devices; each part on or off from Customize at the foot (StartTiles.swift,
/// the iPad's page too).
private struct StartView: View {
    @ObservedObject var model: WindowModel
    @ObservedObject private var session = Session.shared
    /// The folders opened, outermost first.
    @State private var path: [UUID] = []
    @State private var shown = false

    var body: some View {
        let space = session.workspace.space(model.spaceID)
        let hidden = session.preferences.hiddenStartSections
        let folders = Bookmarks.folders(along: path, in: space?.bookmarks ?? [])
        let items = folders.last?.children ?? space?.bookmarks ?? []
        GeometryReader { box in
            ScrollView {
                VStack(spacing: 0) {
                    if let space {
                        SpaceMark(space: space)
                            .arriving(shown, after: 0)
                    }
                    field
                        .padding(.top, 28)
                        .arriving(shown, after: 0.08)
                    if !hidden.contains(.bookmarks) {
                        bookmarks(space, folders: folders, items: items)
                    }
                    if let space {
                        ForEach([Preferences.StartSection.history, .otherDevices].filter { !hidden.contains($0) }, id: \.self) { section in
                            RecentPages(section: section, space: space.id, headingHeight: Metrics.control, shown: shown, delay: 0.24,
                                        showAll: { model.historyShown = true }, open: { model.open($0, newTab: false) },
                                        openInNewTab: { model.open($0, newTab: true) }, copy: { model.copyAddress($0) })
                                .padding(.top, 36)
                        }
                    }
                    StartCustomize(hidden: $session.preferences.hiddenStartSections)
                        .padding(.top, 36)
                        .arriving(shown, after: 0.3)
                }
                .frame(width: max(StartMetrics.square, min(StartMetrics.column, box.size.width - StartMetrics.margin * 2)))
                .padding(.top, StartMetrics.top(in: box.size.height))
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { shown = true }
        .onChange(of: model.spaceID) { _, _ in path = [] }
    }

    /// The space's bookmarks: their heading, and the tiles of the folder open, or why there are none.
    @ViewBuilder
    private func bookmarks(_ space: Space?, folders: [Bookmark], items: [Bookmark]) -> some View {
        heading(folders)
            .padding(.top, 36)
            .arriving(shown, after: 0.16)
        if items.isEmpty {
            empty(space, inFolder: !folders.isEmpty)
                .padding(.top, 6)
                .arriving(shown, after: 0.2)
        } else {
            TileGrid {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    StartTile(model: model, item: item, colour: space?.color ?? .blue) {
                        withAnimation(.bar) { path.append(item.id) }
                    }
                    // In one after another, as the eye reads them.
                    .arriving(shown, after: 0.2 + min(Double(index) * 0.02, 0.2))
                }
            }
            .padding(.top, 14)
        }
    }

    /// The command bar's field as it stands until clicked: on this tab's
    /// address (⌘L), or a new tab's where there is no tab (⌘T).
    private var field: some View {
        Button {
            model.commandBar = model.tabID == nil ? .newTab : .here
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                Text("Search or enter address")
                Spacer(minLength: 8)
                Text(model.tabID == nil ? "⌘T" : "⌘L")
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: StartMetrics.field)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityLabel("Search or enter address")
    }

    /// "Bookmarks", or the folder open, with the way back out of it.
    private func heading(_ folders: [Bookmark]) -> some View {
        HStack(spacing: 2) {
            if !folders.isEmpty {
                PlainIcon("chevron.left", help: String(localized: "Back to \(folders.dropLast().last?.label ?? String(localized: "Bookmarks"))")) {
                    withAnimation(.bar) { _ = path.popLast() }
                }
                // The chevron's own edge on the column's, as the tiles' squares are.
                .padding(.leading, -9)
            }
            Text(folders.last?.label ?? String(localized: "Bookmarks"))
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        // As high in a folder, where the back button is, as at the top: the tiles don't move as one opens.
        .frame(height: Metrics.control)
    }

    private func empty(_ space: Space?, inFolder: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(inFolder ? String(localized: "Nothing in this folder yet.")
                          : String(localized: "No bookmarks in \(space?.name ?? String(localized: "this space")) yet. Import bookmarks from Chrome, Firefox or Safari, or bookmark the current page from the Bookmarks menu."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !inFolder {
                Button("Import Bookmarks…") {
                    guard let owner = model.window else { return }
                    session.chooseBookmarksFile(into: model.spaceID, in: owner)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A bookmark's tile on a new tab: its page here, or the folder opened in
/// place; a new tab or its address from its menu.
private struct StartTile: View {
    @ObservedObject var model: WindowModel
    let item: Bookmark
    let colour: SpaceColor
    let openFolder: () -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            if let url = item.url { model.open(bookmark: url) } else { openFolder() }
        } label: {
            BookmarkFace(item: item, colour: colour, hovering: hovering)
        }
        .buttonStyle(PressScale())
        .onHover { inside in withAnimation(.hover) { hovering = inside } }
        .help(item.url.map(Destination.pretty) ?? item.label)
        .contextMenu {
            if let url = item.url {
                Button("Open in New Tab") { model.open(url, newTab: true) }
                Button("Copy Address") { model.copyAddress(url) }
            }
        }
        .accessibilityLabel(item.isFolder ? String(localized: "\(item.label), folder") : item.label)
    }
}

/// Why the page didn't load, and a way to try again.
struct FailureView: View {
    let message: String
    let url: URL?
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.secondary)
            Text("eGlu Can’t Open This Page")
                .font(.system(size: 17, weight: .semibold))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let url {
                Text(Destination.pretty(url))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 380)
            }
            Button("Try Again", action: retry)
                .buttonStyle(.glass)
                .controlSize(.large)
                .padding(.top, 4)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// Find on the page: a field in glass at the card's top corner. Return and
/// ⌘G go to the next place, ⇧Return and ⇧⌘G to the one before, Escape ends it.
private struct FindBar: View {
    @ObservedObject var model: WindowModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Find on Page", text: $model.findText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(width: 180)
                .focused($focused)
                .onSubmit { model.find(backwards: NSEvent.modifierFlags.contains(.shift)) }
                .onChange(of: model.findText) { _, _ in model.find() }
                .onExitCommand { model.endFinding() }
            if model.findMissed {
                Text("Not found")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Button { model.find(backwards: true) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .help("Previous (⇧⌘G)")
            Button { model.find() } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .help("Next (⌘G)")
            Button { model.endFinding() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Done")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .glassEffect(.regular, in: Capsule())
        .onAppear { focused = true }
        .onChange(of: model.findRequests) { _, _ in focused = true }
    }
}
