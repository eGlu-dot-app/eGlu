import Combine
import PadCore
import SwiftUI
import UIKit

/// The bars on a phone-width window (an iPhone, the iPhone Duo folded, a
/// narrow iPad window), at the bottom where a thumb reaches, as Safari and
/// Comet have them: the address across the width with the page's menu beside
/// it, and under it one row of tools around a new tab's button in the
/// middle, as Arc Search has them (PhoneTools). While an address is typed
/// only the address shows, over the keyboard, with Cancel. A swipe up on the bar
/// shows the space's tabs (Browser.swipedBar); a swipe sideways goes to the
/// tab beside, the address going with the finger and the next tab's coming
/// in next to it (Browser.slidBar).
///
/// Beside the iPhone Duo's strip (WindowModel.strip) the bar is one row:
/// the space, then the address. The tools and the page's menu are the
/// strip's there (StripItems), as Docs/iPhoneDuoDesign.md §3 has them.
struct PhoneBar: View {
    @ObservedObject var session: Session
    let window: WindowModel
    let act: (BarAction) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The address over a row of tools, each 44 points, with room between
    /// so the two rows read apart.
    static let height: CGFloat = 6 + 44 + rowGap + 44
    private static let rowGap: CGFloat = 10
    /// The address alone, over the keyboard.
    static let typingHeight: CGFloat = 6 + 44 + 6
    /// The one row beside the iPhone Duo's strip, typing or not.
    static let stripHeight: CGFloat = 6 + 44 + 6

    /// The bar's height when nothing is typed, which is how much of the
    /// page it covers: one row beside a strip, two anywhere else.
    static func resting(strip: Bool) -> CGFloat {
        strip ? stripHeight : height
    }

    var body: some View {
        let typing = window.editingAddress
        // The tools go when the bar has made room for the keyboard, which
        // the first time is when the keyboard comes and not at the tap.
        let riding = window.barRidesKeyboard
        // Beside a strip too, the spaces are in the tabs' sheet, as on any
        // iPhone (TabOverview's SpaceHeading): the bar is the address alone.
        let strip = window.strip != nil
        // While the tab on screen is pinned: before the address.
        let pinned = typing ? nil : window.tabID.flatMap { session.workspace.tab($0) }.flatMap { $0.isPinned ? $0 : nil }
        VStack(spacing: Self.rowGap) {
            SlidingRow(slide: window.slide, typing: typing, strip: strip) {
                HStack(spacing: 8) {
                    if let pinned {
                        PinnedButton(tab: pinned, window: window, act: act)
                            .transition(appearing)
                    }
                    // Beside a pinned tab's button, which shows its icon, the address has none.
                    AddressCapsule(window: window, editable: window.phone, siteIcon: pinned == nil, act: act)
                    if typing {
                        Button("Cancel") { act(.cancelAddress) }
                            .font(.body)
                            .foregroundStyle(Palette.ink)
                            .padding(.horizontal, 4)
                            .frame(height: 44)
                            .contentShape(Rectangle())
                            .transition(beside)
                    } else if !strip {
                        // Downloads are in it (MenuEntry.app): the address keeps the room.
                        PageMenu(session: session, window: window, act: act)
                            .transition(beside)
                    }
                }
                .padding(.horizontal, 12)
            }
            if !riding && !strip {
                PhoneTools(session: session, window: window, act: act)
                    .frame(height: 44)
                    .transition(.opacity)
            }
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.barScale, .thumb)
        // Loading shows along the top edge here, next to the page.
        .overlay(alignment: .top) { LoadingLine(window: window) }
        .animation(.bar, value: typing)
        .animation(.bar, value: riding)
        .animation(.spring(duration: 0.3, bounce: 0), value: pinned?.id)
        .ignoresSafeArea(.keyboard)
    }

    /// Cancel and the page's menu trade places beside the address: sliding
    /// in from the edge, or only fading under Reduce Motion.
    private var beside: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity)
    }

    /// The pinned button comes into being where it stands, from a little
    /// smaller and soft, as the address makes room; it never grows from nothing.
    private var appearing: AnyTransition {
        reduceMotion ? .opacity : AnyTransition(.blurReplace).combined(with: .scale(scale: 0.8))
    }
}

/// The address row as a sideways drag moves it, with the next tab's row
/// coming in beside it. It watches the slide alone, so a drag moves this row
/// and draws nothing else of the bar again.
private struct SlidingRow<Row: View>: View {
    @ObservedObject var slide: BarSlide
    let typing: Bool
    /// Beside a strip, where the page's menu is in the strip and not at the row's end.
    let strip: Bool
    @ViewBuilder let row: Row

    var body: some View {
        let moving = row
            .offset(x: slide.offset)
            .overlay {
                if let coming = slide.coming, !typing {
                    GeometryReader { row in
                        ComingAddress(coming: coming, strip: strip)
                            .padding(.horizontal, 12)
                            // A row's width and the pages' gap along: where it will be once it is in.
                            .offset(x: slide.offset + coming.side * (row.size.width + 16))
                    }
                    .accessibilityHidden(true)
                }
            }
        if strip {
            // Beside a strip the rows come and go at its edge, as the pages
            // do, rather than under it; the glass's edges still show above and below.
            moving.mask { Rectangle().padding(.vertical, -12) }
        } else {
            moving
        }
    }
}

/// The address row of the tab a sideways drag is going to, drawn as the bar
/// will draw it once that tab is on screen: a pinned tab's button before
/// it, its capsule with the site's icon and its name or address, and the
/// menu's button beside it, which beside a strip is in the strip instead.
/// It only shows; the real row takes its place when the drag has gone through.
private struct ComingAddress: View {
    let coming: SlideNeighbour
    let strip: Bool

    var body: some View {
        HStack(spacing: 8) {
            if coming.tab.isPinned {
                PinnedDisc(tab: coming.tab)
            }
            NeighbourAddress(tab: coming.tab, titled: coming.titled, siteIcon: !coming.tab.isPinned)
            if !strip {
                MoreDisc()
            }
        }
    }
}

/// The phone bar's row of tools, as Arc Search has its: a new tab in the
/// middle, the largest thing on the row, where a thumb finds it without
/// looking, faintly in the space's colour; back and forward as one pair on
/// the left; the tabs on the right, whose sheet has the space's button
/// (TabOverviewController). The two sides have the same room, so the new
/// tab stays in the middle: tighter in a window as narrow as an iPad's
/// third (320 points), and in one narrower still, side by side as they fit.
private struct PhoneTools: View {
    @ObservedObject var session: Session
    let window: WindowModel
    let act: (BarAction) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            CentredRow {
                GoingPair(window: window, act: act)
                newTab(tight: false)
                tabs
            }
            .padding(.horizontal, 12)
            CentredRow {
                GoingPair(window: window, act: act, width: 30)
                newTab(tight: true)
                tabs
            }
            .padding(.horizontal, 8)
            HStack(spacing: 0) {
                GoingPair(window: window, act: act, width: 30)
                Spacer(minLength: 4)
                newTab(tight: true)
                Spacer(minLength: 4)
                tabs
            }
            .padding(.horizontal, 8)
        }
    }

    private var tabs: some View {
        TabsButton(tabs: session.workspace.space(window.spaceID)?.tabs ?? [], current: window.tabID, act: act)
    }

    private func newTab(tight: Bool) -> some View {
        NewTabButton(width: tight ? 56 : 64, colour: session.workspace.space(window.spaceID)?.color ?? .blue) {
            // Felt as the tab is made: the page under the bar is another
            // one at once, and the keyboard only comes a moment after.
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            act(.command(.newTab))
        }
    }
}

/// Three views in a row, the second at the centre and the others at the
/// ends: as wide, at its ideal, as twice its wider end and the middle, so
/// that a ViewThatFits takes another row where the ends would reach the middle.
private struct CentredRow: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 3 else { return .zero }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let ideal = 2 * max(sizes[0].width, sizes[2].width) + sizes[1].width
        return CGSize(width: proposal.width.map { max($0, ideal) } ?? ideal, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let anchors: [(CGFloat, UnitPoint)] = [(bounds.minX, .leading), (bounds.midX, .center), (bounds.maxX, .trailing)]
        for (subview, (x, anchor)) in zip(subviews, anchors) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: anchor, proposal: .unspecified)
        }
    }
}

/// Back and forward as one control: side by side on one capsule of glass,
/// as the system groups a pair of a bar's items, so a thumb that knows the
/// one finds the other beside it. Drawn as high as the space's capsule on
/// the row; each half answers all 44 points.
private struct GoingPair: View {
    let window: WindowModel
    let act: (BarAction) -> Void
    /// Each half's: 40 points, 30 in a narrow window.
    var width: CGFloat = 40

    var body: some View {
        HStack(spacing: 0) {
            ToolIcon(symbol: "chevron.left", label: String(localized: "Back"), enabled: window.canGoBack, width: width) { act(.back) }
            ToolIcon(symbol: "chevron.right", label: String(localized: "Forward"), enabled: window.canGoForward, width: width) { act(.forward) }
        }
        .background {
            Color.clear
                .liquidGlass(reacting: false, in: Capsule(), otherwise: Palette.wash)
                .padding(.vertical, 4)
        }
    }
}

/// One of back and forward (GoingPair): a symbol alone, 40 points wide (or
/// as the pair has it) and 44 high answering a touch.
private struct ToolIcon: View {
    let symbol: String
    let label: String
    var enabled = true
    var width: CGFloat = 40
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                // Dimmed by opacity, not a solid grey: the page shows through the
                // bar, and a light grey vanishes over a light one.
                .foregroundStyle(enabled ? Palette.ink : Palette.ink.opacity(0.3))
                // A chevron's point sits off its box; nudged toward the way it points.
                .offset(x: symbol == "chevron.left" ? -0.5 : 0.5)
                .frame(width: width, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// A new tab: a capsule of glass of its own in the middle of the row,
/// larger than the tools around it, as Arc Search's, since a new tab is
/// what the bar is most often reached for; tinted with the space's colour,
/// half as much as the iPad's command bar, the new tab being the space's.
private struct NewTabButton: View {
    /// 64 points, 56 in a narrow window.
    var width: CGFloat = 64
    let colour: SpaceColor
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: width, height: 40)
                .liquidGlass(tint: colour.color.opacity(scheme == .dark ? 0.18 : 0.15), in: Capsule(), otherwise: Palette.wash)
                .animation(.bar, value: colour)
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(String(localized: "New Tab"))
    }
}

/// The tabs, drawn as the iPhone Duo strip's are (StripItems): the system's
/// two squares with how many tabs the space has open on a badge in ink at
/// their corner; its pinned tabs aren't counted, since they don't close and
/// sit apart in the dock. A tap shows them; a long press has Safari's menu:
/// a new tab, closing this one, closing them all.
private struct TabsButton: View {
    let tabs: [TabRecord]
    let current: UUID?
    let act: (BarAction) -> Void

    var body: some View {
        let ordinary = tabs.filter { !$0.isPinned }
        Menu {
            Button("New Tab", systemImage: "plus.square.on.square") { act(.command(.newTab)) }
            if !Session.shared.workspace.closed.isEmpty {
                Button("Reopen Closed Tab", systemImage: "arrow.uturn.backward") { act(.command(.reopenTab)) }
            }
            if let current, ordinary.contains(where: { $0.id == current }) {
                Button("Close This Tab", systemImage: "xmark", role: .destructive) { act(.close(current)) }
            }
            if ordinary.count > 1 {
                Button("Close All \(ordinary.count) Tabs", systemImage: "xmark.square.fill", role: .destructive) {
                    act(.closeTabs(ordinary.map(\.id)))
                }
            }
        } label: {
            Image(systemName: "square.on.square")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Palette.ink)
                .overlay(alignment: .topTrailing) {
                    if !ordinary.isEmpty { TabCountBadge(count: ordinary.count) }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        } primaryAction: {
            act(.showTabs)
        }
        .accessibilityLabel("Tabs, \(ordinary.count)")
        .accessibilityHint("Or swipe up on the bar")
    }
}

/// A count on a badge as the system draws a bar button item's: white on ink,
/// round for one digit and longer for more, its centre a point past the
/// symbol's corner and six above it.
private struct TabCountBadge: View {
    let count: Int
    /// From where it is placed: the tabs' symbol's corner, or the … disc's.
    var offset = CGSize(width: 7, height: -12)

    var body: some View {
        Text("\(count)")
            .font(.system(.caption2, weight: .semibold))
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            .monospacedDigit()
            .foregroundStyle(Palette.ground)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Capsule().fill(Palette.ink))
            .fixedSize()
            // From the image's corner, which stands a little out from the
            // squares it draws, to over the squares' own corner, as the strip's.
            .offset(offset)
    }
}

/// The page's own commands, which the iPad has on its tabs' menus and on ⌃⌥:
/// a round glass button beside the address, as high as it.
private struct PageMenu: View {
    @ObservedObject var session: Session
    let window: WindowModel
    let act: (BarAction) -> Void
    /// So the count said to VoiceOver changes with the disc's badge.
    @ObservedObject private var downloads = Downloads.shared

    var body: some View {
        // In the order the strip's overflow has them too (MenuEntry.overflow).
        Menu {
            PageItems(window: window, act: act)
            MenuButtons(entries: MenuEntry.tab(session, window, act: act))
            Section { AppItems(act: act) }
        } label: {
            MoreDisc()
                .contentShape(Circle())
        }
        .accessibilityLabel("More")
        .accessibilityValue(downloads.activeCount > 0 ? String(localized: "Downloads under way: \(downloads.activeCount)") : "")
    }
}

/// The page menu's button as it is drawn: a round glass disc beside the
/// address, as high as it, with an ellipsis. Drawn alone too, in the row a
/// sideways swipe brings in (ComingAddress).
private struct MoreDisc: View {
    @ObservedObject private var downloads = Downloads.shared

    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Palette.ink)
            .frame(width: 44, height: 44)
            .liquidGlass(in: Circle(), otherwise: Palette.wash)
            // The phone bar has no downloads button: while one is under way,
            // how many are, on the menu that has Downloads.
            .overlay(alignment: .topTrailing) {
                if downloads.activeCount > 0 {
                    TabCountBadge(count: downloads.activeCount, offset: CGSize(width: 4, height: -4))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.bar, value: downloads.activeCount)
    }
}

/// The iPhone Duo's strip, the system's vertical bar beside the window, closed
/// or open (Docs/iPhoneDuoDesign.md §3): Back and Forward at its top, the
/// system's overflow (…) under them with the page's menu, New Tab and the
/// tabs at its foot, the count of tabs as the item's badge. The system puts
/// them there from the navigation item and the toolbar's items, which show
/// only while the window has a strip (Browser.showStrip). Beside a
/// phone-width window the phone bar is one row, the space and the address;
/// beside a wide one the iPad's bars stay along the top.
@MainActor
final class StripItems {
    private let session: Session
    private let window: WindowModel
    private let back: UIBarButtonItem
    private let forward: UIBarButtonItem
    private let tabs: UIBarButtonItem
    private var subscriptions: Set<AnyCancellable> = []
    /// Where the items stand, and the strip's foot: New Tab, and the tabs'
    /// item while it shows (showsTabs).
    private weak var controller: UIViewController?
    private let foot: (newTab: UIBarButtonItem, tabs: UIBarButtonItem)
    private var tabsShown = true

    init(in controller: UIViewController, session: Session, window: WindowModel, act: @escaping (BarAction) -> Void) {
        func item(_ title: String, _ symbol: String, menu: UIMenu? = nil, _ action: @escaping () -> Void) -> UIBarButtonItem {
            let item = UIBarButtonItem(title: title, image: UIImage(systemName: symbol),
                                       primaryAction: UIAction { _ in action() }, menu: menu)
            if #available(iOS 27.1, *) { item.axisBehavior = .verticalPreferred }
            return item
        }
        let back = item(String(localized: "Back"), "chevron.left") { act(.back) }
        let forward = item(String(localized: "Forward"), "chevron.right") { act(.forward) }
        let newTab = item(String(localized: "New Tab"), "plus") {
            // As the phone bar's: felt as the tab is made.
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            act(.command(.newTab))
        }
        // A tap shows them; a hold has the phone bar's tabs menu (TabsButton).
        let tabsMenu = UIMenu(children: [UIDeferredMenuElement.uncached { done in
            let ordinary = (session.workspace.space(window.spaceID)?.tabs ?? []).filter { !$0.isPinned }
            var items = [UIAction(title: String(localized: "New Tab"), image: UIImage(systemName: "plus.square.on.square")) { _ in
                act(.command(.newTab))
            }]
            if !session.workspace.closed.isEmpty {
                items.append(UIAction(title: String(localized: "Reopen Closed Tab"), image: UIImage(systemName: "arrow.uturn.backward")) { _ in act(.command(.reopenTab)) })
            }
            if let current = window.tabID, ordinary.contains(where: { $0.id == current }) {
                items.append(UIAction(title: String(localized: "Close This Tab"), image: UIImage(systemName: "xmark"), attributes: .destructive) { _ in
                    act(.close(current))
                })
            }
            if ordinary.count > 1 {
                items.append(UIAction(title: String(localized: "Close All \(ordinary.count) Tabs"), image: UIImage(systemName: "xmark.square.fill"),
                                      attributes: .destructive) { _ in act(.closeTabs(ordinary.map(\.id))) })
            }
            done(items)
        }])
        let tabs = item(String(localized: "Tabs"), "square.on.square", menu: tabsMenu) { act(.showTabs) }
        // The last to go into the overflow when the strip is short: the landscape strip, the keyboard's.
        if #available(iOS 27.0, *) {
            back.visibilityPriority = .high
            tabs.visibilityPriority = .high
        }
        controller.navigationItem.leadingItemGroups = [UIBarButtonItemGroup(barButtonItems: [back, forward], representativeItem: nil)]
        controller.navigationItem.additionalOverflowItems = UIDeferredMenuElement.uncached { done in
            done(MenuEntry.overflow(session, window, act: act))
        }
        controller.toolbarItems = [newTab, tabs]
        self.controller = controller
        foot = (newTab, tabs)

        self.session = session
        self.window = window
        self.back = back
        self.forward = forward
        self.tabs = tabs
        showGoing()
        showCount(in: session.workspace)
        // Through the owner, never the window itself: the window keeps what
        // watches it until its next change, and must not be kept by it.
        watch(self, read: { _ = $0.window.canGoBack; _ = $0.window.canGoForward }, changed: { $0.showGoing() })
        watch(self, read: { _ = $0.window.spaceID }, changed: { $0.showCount(in: $0.session.workspace) })
        // The workspace as it is about to be, as @Published tells it.
        session.$workspace.sink { [weak self] in self?.showCount(in: $0) }.store(in: &subscriptions)
    }

    private func showGoing() {
        back.isEnabled = window.canGoBack
        forward.isEnabled = window.canGoForward
    }

    /// How many tabs the space has open: its pinned tabs aren't counted, as
    /// on the phone bar's square.
    private func showCount(in workspace: Workspace) {
        let count = (workspace.space(window.spaceID)?.tabs ?? []).filter { !$0.isPinned }.count
        if #available(iOS 26.0, *) {
            // A count, not an alert: in the ink the phone bar's square is drawn in, rather than red.
            var badge = UIBarButtonItem.Badge.count(count)
            badge.backgroundColor = Palette.UI.ink
            badge.foregroundColor = Palette.UI.ground
            tabs.badge = count > 0 ? badge : nil
        }
        tabs.accessibilityLabel = String(localized: "Tabs, \(count)")
    }

    /// Where the items the system shows stand, in `view`'s points: the
    /// strip's bands come from them (Browser.stripCover). The system draws
    /// the strip outside the app's windows, and no API places its overflow
    /// (…) under Back and Forward: it is taken as one more item, its own
    /// capsule's gap under Forward, as measured on the iOS 27.2 simulator.
    func frames(in view: UIView) -> [CGRect] {
        var frames = [back, forward, foot.newTab, tabs].compactMap { $0.frame(in: view) }.filter { !$0.isEmpty }
        if let last = forward.frame(in: view), !last.isEmpty {
            frames.append(last.offsetBy(dx: 0, dy: last.height + Self.overflowGap))
        }
        return frames
    }

    /// From Forward's foot to the overflow's top, between the two capsules.
    private static let overflowGap: CGFloat = 23

    /// The tabs' item, only where the tabs aren't on screen already: none
    /// beside a sidebar of tabs (Settings › Tabs › Vertical).
    func showsTabs(_ shown: Bool) {
        guard shown != tabsShown else { return }
        tabsShown = shown
        controller?.setToolbarItems(shown ? [foot.newTab, foot.tabs] : [foot.newTab], animated: false)
    }
}
