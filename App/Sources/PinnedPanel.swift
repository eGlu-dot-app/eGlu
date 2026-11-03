import PadCore
import SwiftUI
import UIKit

// A pinned tab on the phone: its button on the phone bar, before the address
// or, beside the iPhone Duo's strip, after it, while the tab on screen is
// pinned; and what it opens. A tap has the tab's options, in the system's
// menu. Held a moment, or moved up at once, it has the space's pinned tabs
// in a panel of its own (PinnedPanel), the tab on screen under the finger
// and the others above it, a highlight following the finger from one to the
// next and letting go going there, as a menu held open is used. Lifted
// without going anywhere, the list stays for a tap.
//
// Motion: the button becomes the list. Its rounded square of glass grows
// into the card (corners 17 to 30) on a critically damped spring of 0.32
// seconds, the window behind dimming and blurring with it; the tab on
// screen's row is where the button was, its icon on the button's, and the
// others rise into place over it, nearest first, 25 ms apart, easing out
// strongly. Going, faster: the other rows fade in 0.1 seconds and the card
// goes back into the button on a spring of 0.24, the button coming back
// over it. The highlight moves between rows on a 0.2 second spring; the
// button gives to 0.96 under the finger. Under Reduce Motion nothing grows
// or moves: the dim, the card and the rows fade.
//
// Felt: a medium tap as the list opens, a selection tick at each row the
// finger reaches, a soft tap as it leaves the rows (letting go there does
// nothing), and a light one as letting go goes to a tab.

/// What the phone shows of a pinned tab.
@MainActor
enum Pinned {
    /// Open: its page is loaded, or it has gone on from the address it was
    /// pinned with. Closed: back at that address with its page let go, as
    /// closing a pinned tab leaves it (Workspace.closeTab).
    static func isOpen(_ tab: TabRecord) -> Bool {
        tab.isPinned && (Session.shared.pages.isLive(tab.id) || (tab.url != nil && tab.url != tab.pinned))
    }

    /// The space's pinned tabs as the dock has them: without those this device hides.
    static func tabs(in space: UUID) -> [TabRecord] {
        let session = Session.shared
        return (session.workspace.space(space)?.tabs ?? []).filter { $0.isPinned && session.preferences.shows($0) }
    }
}

// MARK: The press

/// A press on a pinned tab's button. A tap; or, held a moment or moved up
/// or down at once, the list of pinned tabs, which then follows the finger
/// until it lifts. Moved sideways first, it lets go, and the phone bar's
/// swipe to the tab beside has the touch.
final class PinnedPress: UIGestureRecognizer {
    enum Event {
        case down
        case tap
        /// The list opens, the finger where it is, in the window.
        case hold(CGPoint)
        case move(CGPoint)
        case lift(CGPoint)
        case cancel
    }

    var handle: ((Event) -> Void)?
    /// The list is open and follows the finger.
    private(set) var holding = false
    private var start = CGPoint.zero
    private var timer: Timer?
    /// UIKit can fail recognition without delivering touchesCancelled.
    private var activePress = false

    /// How long a press is held before the list opens: less than a context
    /// menu's half second, as the keyboard's accents are, for a list used
    /// several times a day.
    static let hold: TimeInterval = 0.35
    /// How far a finger goes before it means to.
    static let slop: CGFloat = 10

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard numberOfTouches == 1, let touch = touches.first else {
            if holding { return }
            state = .failed
            return
        }
        start = touch.location(in: nil)
        activePress = true
        handle?(.down)
        let timer = Timer(timeInterval: Self.hold, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.open(at: nil) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let point = touches.first?.location(in: nil) else { return }
        if holding {
            state = .changed
            handle?(.move(point))
            return
        }
        let (dx, dy) = (point.x - start.x, point.y - start.y)
        guard hypot(dx, dy) > Self.slop, state == .possible else { return }
        if abs(dy) > abs(dx) {
            // Up or down at once: the list, without waiting for the hold.
            open(at: point)
        } else {
            timer?.invalidate()
            activePress = false
            state = .failed
            handle?(.cancel)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        timer?.invalidate()
        activePress = false
        let point = touches.first?.location(in: nil) ?? start
        if holding {
            state = .ended
            handle?(.lift(point))
        } else if state == .possible {
            state = .ended
            handle?(.tap)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        timer?.invalidate()
        activePress = false
        state = holding ? .cancelled : .failed
        handle?(.cancel)
    }

    override func reset() {
        super.reset()
        timer?.invalidate()
        timer = nil
        holding = false
        if activePress {
            activePress = false
            handle?(.cancel)
        }
    }

    private func open(at point: CGPoint?) {
        guard state == .possible, !holding else { return }
        timer?.invalidate()
        holding = true
        state = .began
        handle?(.hold(point ?? start))
    }
}

/// Where the phone bar's pinned button (PinnedButton) takes its touches,
/// and says when it is pressed. The tab's options are the system's menu,
/// on a button under the touches that a tap opens (PinnedControl.showOptions):
/// the button itself takes none, or its menu would have the hold too.
final class PinnedTouchView: UIView {
    weak var control: PinnedControl? {
        didSet { if control !== oldValue { control?.button = self } }
    }
    var pressed: ((Bool) -> Void)?
    /// The button has become the list (true) or come back from it (false).
    var lifted: ((Bool) -> Void)?
    let press = PinnedPress()
    let menuButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        press.handle = { [weak self] in self?.handle($0) }
        addGestureRecognizer(press)
        menuButton.frame = bounds
        menuButton.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        menuButton.isUserInteractionEnabled = false
        menuButton.isAccessibilityElement = false
        menuButton.showsMenuAsPrimaryAction = true
        // Made as it opens, so it says where the tab is pinned now.
        menuButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            done(MainActor.assumeIsolated { self?.control?.options() } ?? [])
        }])
        addSubview(menuButton)
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func handle(_ event: PinnedPress.Event) {
        switch event {
        case .down:
            pressed?(true)
            control?.prepare()
        case .tap:
            pressed?(false)
            control?.showOptions(from: self)
        case .hold(let point):
            control?.showList(from: self, at: point)
        case .move(let point):
            control?.scrub(to: point)
        case .lift(let point):
            pressed?(false)
            control?.release(at: point)
        case .cancel:
            pressed?(false)
            control?.pressCancelled()
        }
    }
}

/// The phone bar's pinned button: the tab's site icon on a disc of glass,
/// as the page's menu (…) is drawn at the other end.
struct PinnedButton: View {
    let tab: TabRecord
    let window: WindowModel
    let act: (BarAction) -> Void
    @State private var pressed = false
    /// Become the list of pinned tabs, which stands where it was.
    @State private var lifted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PinnedDisc(tab: tab)
            .opacity(lifted ? 0 : 1)
            .animation(.easeOut(duration: 0.1), value: lifted)
            .scaleEffect(pressed && !reduceMotion ? 0.96 : 1)
            .animation(.spring(duration: 0.2, bounce: 0), value: pressed)
            .overlay { PinnedTouch(control: window.pinned, pressed: { pressed = $0 }, lifted: { lifted = $0 }) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Pinned Tab, \(tab.label)")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Shows its options. Its actions go to the other pinned tabs.")
            .accessibilityAction { window.pinned?.showOptions(from: nil) }
            .accessibilityActions {
                ForEach(Pinned.tabs(in: window.spaceID).filter { $0.id != tab.id }) { other in
                    Button("Go to \(other.label)") { act(.select(other.id)) }
                }
            }
    }
}

/// A pinned tab's icon on its tile, drawn as the iPad's and the Mac's
/// pinned tile on screen is: a rounded square, as theirs, among the bar's
/// round buttons, the glass tinted with the icon's colour, the icon on a
/// soft glow of it (PinnedIcon), so it reads as the pinned tab it is. The
/// button, and the same drawn alone in the row a sideways drag brings in.
struct PinnedDisc: View {
    let tab: TabRecord
    private let shape = RoundedRectangle(cornerRadius: Side.tileCorner, style: .continuous)
    /// Larger than the iPad tile's (Side.tileIcon), as the button is: every
    /// icon is drawn as large to the eye as a square icon this size (IconOptics).
    private static let icon: CGFloat = 24
    /// The light under it, grown with it from the tile's (PinnedIcon.tilePlate,
    /// 26 points softened by 9): as soft for its size.
    private static let plate = (side: CGFloat(34), corner: CGFloat(10), blur: CGFloat(12))

    var body: some View {
        let url = tab.url ?? tab.pinned
        let workspace = Session.shared.workspace
        let colour = workspace.spaceID(of: tab.id).flatMap { workspace.space($0)?.color } ?? .blue
        // The glow and the icon over it, as the iPad's tile stacks them.
        ZStack {
            PinnedIcon(url: url, open: true, colour: colour, size: Self.icon, lean: nil, plate: Self.plate, fills: true)
        }
        .frame(width: 44, height: 44)
        .clipShape(shape)
        .background {
            Color.clear.liquidGlass(.regular, tint: PinnedIcon.tileTint(for: url, colour: colour) ?? Palette.ink.opacity(0.12),
                                    reacting: false, in: shape, otherwise: Palette.card)
        }
        .contentShape(shape)
    }
}

private struct PinnedTouch: UIViewRepresentable {
    let control: PinnedControl?
    let pressed: (Bool) -> Void
    let lifted: (Bool) -> Void

    func makeUIView(context: Context) -> PinnedTouchView {
        let view = PinnedTouchView()
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: PinnedTouchView, context: Context) {
        view.control = control
        view.pressed = pressed
        view.lifted = lifted
    }
}

// MARK: The control

/// A window's pinned button and its panel: which panel opens, where, and
/// what letting go of it does. One a window, whichever button pressed it.
@MainActor
final class PinnedControl {
    private let window: WindowModel
    private let act: (BarAction) -> Void
    /// Where the panel is put: over everything of the window, the strip too.
    private let host: () -> UIView?
    private var panel: PinnedPanel?
    /// The last button that took a touch, for VoiceOver's activation, which has no touch to go by.
    weak var button: UIView?
    private let opening = UIImpactFeedbackGenerator(style: .medium)
    private let ticking = UISelectionFeedbackGenerator()
    /// Off the rows: letting go there does nothing.
    private let leaving = UIImpactFeedbackGenerator(style: .soft)
    /// Letting go on a tab, or an option chosen.
    private let landing = UIImpactFeedbackGenerator(style: .light)
    /// The button the list grew out of, hidden under it until it goes back.
    private weak var lifted: PinnedTouchView?
    private var lastTick: CFTimeInterval = 0

    init(window: WindowModel, host: @escaping () -> UIView?, act: @escaping (BarAction) -> Void) {
        self.window = window
        self.host = host
        self.act = act
    }

    var isOpen: Bool {
        panel != nil
    }

    /// Ready, at the touch, for what a hold will feel like.
    func prepare() {
        opening.prepare()
        ticking.prepare()
        leaving.prepare()
        landing.prepare()
    }

    private var tab: TabRecord? {
        guard let id = window.tabID, let tab = Session.shared.workspace.tab(id), tab.isPinned else { return nil }
        return tab
    }

    /// The tab's options, the system's menu at the button: under where it
    /// is pinned, back to that address and this page pinned instead, which do
    /// nothing while it is there, and unpinning it.
    func showOptions(from source: UIView?) {
        close()
        guard let touch = (source ?? button) as? PinnedTouchView else { return }
        if #available(iOS 17.4, *) {
            touch.menuButton.performPrimaryAction()
        } else {
            showSheet(from: touch)
        }
    }

    func options() -> [UIMenuElement] {
        guard let tab else { return [] }
        let away: UIMenuElement.Attributes = tab.isAwayFromPinned ? [] : .disabled
        let act = act
        return [UIMenu(title: tab.pinnedAddress.map { String(localized: "Pinned to \($0)") } ?? "", options: .displayInline, children: [
            UIAction(title: String(localized: "Back to Pinned Address"), image: UIImage(systemName: "arrow.uturn.backward"), attributes: away) { _ in
                act(.backToPinned(tab.id))
            },
            UIAction(title: String(localized: "Replace with Current Page"), image: UIImage(systemName: "pin"), attributes: away) { _ in
                act(.repin(tab.id))
            },
            UIAction(title: String(localized: "Unpin Tab"), image: UIImage(systemName: "pin.slash")) { _ in act(.unpin(tab.id)) },
        ])]
    }

    /// The options as a sheet, where a button can't be told to open its menu (before iOS 17.4).
    private func showSheet(from source: UIView) {
        guard let tab, var top = source.window?.rootViewController else { return }
        while let shown = top.presentedViewController { top = shown }
        let sheet = UIAlertController(title: tab.pinnedAddress.map { String(localized: "Pinned to \($0)") }, message: nil, preferredStyle: .actionSheet)
        let back = UIAlertAction(title: String(localized: "Back to Pinned Address"), style: .default) { [act] _ in act(.backToPinned(tab.id)) }
        let replace = UIAlertAction(title: String(localized: "Replace with Current Page"), style: .default) { [act] _ in act(.repin(tab.id)) }
        back.isEnabled = tab.isAwayFromPinned
        replace.isEnabled = tab.isAwayFromPinned
        sheet.addAction(back)
        sheet.addAction(replace)
        sheet.addAction(UIAlertAction(title: String(localized: "Unpin Tab"), style: .default) { [act] _ in act(.unpin(tab.id)) })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = source
        top.present(sheet, animated: true)
    }

    /// The space's pinned tabs, held open by the finger at `point` (in the window).
    func showList(from source: UIView, at point: CGPoint) {
        let tabs = Pinned.tabs(in: window.spaceID)
        guard !tabs.isEmpty else { return }
        close(animated: false)
        // The tab on screen at the foot, under the finger; above it the
        // others, the one last on screen nearest, then the one before, as
        // going back a page at a time goes.
        let current = tabs.filter { $0.id == window.tabID }
        let others = tabs.filter { $0.id != window.tabID }.sorted { $0.shown > $1.shown }
        let rows = (others.reversed() + current).map { tab in
            PinnedPanel.Row(title: tab.label, site: tab.url ?? tab.pinned, current: tab.id == window.tabID,
                            open: Pinned.isOpen(tab)) { [act] in act(.select(tab.id)) }
        }
        guard let host = host() else { return }
        let colour = Session.shared.workspace.space(window.spaceID)?.color ?? .blue
        open(PinnedPanel(rows: rows, colour: colour), beside: source.convert(source.bounds, to: host), scrubbing: point)
        // The button is the card now, growing from where it was.
        lifted = source as? PinnedTouchView
        lifted?.lifted?(true)
        // On the frame the list comes in.
        opening.impactOccurred(intensity: 0.7)
    }

    /// The finger, at `point` in the window, moved while it holds the list open.
    func scrub(to point: CGPoint) {
        guard let panel, let host = host() else { return }
        feel(panel.follow(host.convert(point, from: nil)))
    }

    /// A tick at each row the highlight or the scroll reaches, no closer
    /// together than the taptic engine can tell apart; a soft tap off the rows.
    private func feel(_ followed: PinnedPanel.Followed) {
        switch followed {
        case .row, .passed:
            let now = CACurrentMediaTime()
            guard now - lastTick > 0.035 else { return }
            lastTick = now
            ticking.selectionChanged()
            ticking.prepare()
        case .off:
            leaving.impactOccurred(intensity: 0.6)
            leaving.prepare()
        case .same:
            break
        }
    }

    /// The finger lifted at `point`: on a row, to it; where it held the list
    /// open, the list stays for a tap; anywhere else, away.
    func release(at point: CGPoint) {
        guard let panel, let host = host() else { return }
        let point = host.convert(point, from: nil)
        if let row = panel.row(at: point), panel.moved {
            // Lifted on the tab on screen: nothing to go to.
            if row.current { close() } else { choose(row) }
        } else if panel.moved {
            close()
        } else {
            panel.stopFollowing()
        }
    }

    /// The press ended without a lift of its own (the system took it): a list it held goes.
    func pressCancelled() {
        if panel?.following == true { close() }
    }

    /// `leaving`: the tab on screen is being left for another, whose
    /// button the card goes back into; its row goes with the others.
    func close(animated: Bool = true, leaving: Bool = false) {
        guard let panel else { return }
        self.panel = nil
        let button = lifted
        lifted = nil
        // The button comes back as the card, gone back into its shape, reaches it.
        panel.dismiss(animated: animated, keepingCurrent: !leaving) { button?.lifted?(false) }
    }

    private func choose(_ row: PinnedPanel.Row) {
        landing.impactOccurred(intensity: 0.8)
        close(leaving: !row.current)
        row.action()
    }

    private func open(_ panel: PinnedPanel, beside anchor: CGRect, scrubbing start: CGPoint) {
        guard let host = host() else { return }
        panel.frame = host.bounds
        panel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        panel.chosen = { [weak self] row in self?.choose(row) }
        panel.scrolled = { [weak self] in self?.feel($0) }
        panel.dismissed = { [weak self, weak panel] in
            if self?.panel === panel { self?.close() }
        }
        host.addSubview(panel)
        panel.place(from: anchor, following: host.convert(start, from: nil))
        self.panel = panel
        panel.present()
    }
}

// MARK: The panel

/// The space's pinned tabs, held open from the pinned button, as the
/// Messages app's menu of apps is drawn: a large card of glass with tall
/// rows, over a dimmed and blurred window that takes a tap anywhere else to
/// put it away. Held open
/// by a finger, it stands with the tab on screen under the finger and the
/// others above it, nearest the one last on screen, as Dia's back history
/// steps back a page at a time; the row level with the finger is highlighted
/// (follow), and the finger lifting goes to it (PinnedControl.release).
final class PinnedPanel: UIView, UIScrollViewDelegate {
    struct Row {
        var title: String
        var site: URL?
        var current = false
        var open = false
        var action: () -> Void
    }

    var chosen: ((Row) -> Void)?
    var dismissed: (() -> Void)?
    /// What the rows scrolling under a still finger came to (autoScroll).
    var scrolled: ((Followed) -> Void)?
    /// A finger holds it open: the highlight follows it.
    private(set) var following = false
    /// The finger has gone somewhere since it opened the list.
    private(set) var moved = false

    private let rows: [Row]
    /// Over the window behind the card, so the card stands out from the
    /// page: the page blurred and darkened; darkened alone where Reduce
    /// Transparency is on.
    private let dim = UIVisualEffectView(effect: nil)
    private let shade = UIView()
    private let plate = UIView()
    private let glass: UIVisualEffectView
    /// The rows, over the glass where they stand open, seen through a
    /// shape that grows with the card: they hold still as it opens over them.
    private let rowsHost = UIView()
    private let rowsShape = UIView()
    private let scroller = UIScrollView()
    private let highlight = UIView()
    private var rowViews: [PinnedRowView] = []
    /// The button's frame here, which the card grows out of and goes back into.
    private var anchor = CGRect.zero
    /// The card's own frame, open.
    private var card = CGRect.zero
    /// The window's size it was laid out for: another (the phone turned) puts it away.
    private var laidOutFor = CGSize.zero
    private var start = CGPoint.zero
    private var highlighted: Int?
    /// Scrolling the rows while the finger is at or past an edge of them.
    private var scrollLink: CADisplayLink?
    private var finger = CGPoint.zero
    private var lastStep: CFTimeInterval = 0
    /// The rows fade out at an edge with more past it.
    private let fade = CAGradientLayer()

    static let width: CGFloat = 320
    /// Tall, as the Messages menu's rows are: easy to land on with a finger moving.
    static let rowHeight: CGFloat = 60
    /// Round the rows, inside the card: the card's corners are the rows' and this, concentric.
    static let inset: CGFloat = 8
    static let corner: CGFloat = 30
    /// The most of the screen's height the card takes; the rest of the rows scroll.
    static let most: CGFloat = 0.5
    /// From an edge of the rows, inward, where a finger starts them scrolling.
    static let edge: CGFloat = 20
    /// How long the rows fade at an edge with more past it.
    static let fadeLength: CGFloat = 24

    init(rows: [Row], colour: SpaceColor) {
        self.rows = rows
        glass = UIVisualEffectView(effect: nil)
        if #available(iOS 26.0, *) {
            glass.cornerConfiguration = .corners(radius: .fixed(Self.corner))
        } else {
            glass.layer.cornerRadius = Self.corner
            glass.layer.cornerCurve = .continuous
            glass.clipsToBounds = true
        }
        super.init(frame: .zero)
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        shade.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0.4) : UIColor(white: 0, alpha: 0.22) }
        shade.alpha = 0
        shade.frame = dim.contentView.bounds
        shade.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dim.contentView.addSubview(shade)
        addSubview(dim)
        // Depth from a soft shadow, not an outline: it reads on any page.
        plate.layer.shadowColor = UIColor.black.cgColor
        plate.layer.shadowOpacity = 0.18
        plate.layer.shadowRadius = 24
        plate.layer.shadowOffset = CGSize(width: 0, height: 8)
        addSubview(plate)
        plate.addSubview(glass)
        highlight.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.14) : UIColor(white: 0, alpha: 0.07) }
        highlight.layer.cornerRadius = Self.corner - Self.inset
        highlight.layer.cornerCurve = .continuous
        highlight.alpha = 0
        scroller.showsVerticalScrollIndicator = false
        scroller.alwaysBounceVertical = false
        scroller.delegate = self
        fade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.black.cgColor, UIColor.black.cgColor]
        scroller.layer.mask = fade
        scroller.addSubview(highlight)
        rowsHost.addSubview(scroller)
        rowsShape.backgroundColor = .black
        rowsShape.layer.cornerCurve = .continuous
        rowsHost.mask = rowsShape
        addSubview(rowsHost)
        for (index, row) in rows.enumerated() {
            let view = PinnedRowView(row: row, colour: colour)
            view.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.chosen?(self.rows[index])
            }, for: .touchUpInside)
            view.addAction(UIAction { [weak self] _ in self?.light(index) }, for: .touchDown)
            view.addAction(UIAction { [weak self] _ in self?.light(nil) }, for: [.touchCancel, .touchDragExit])
            scroller.addSubview(view)
            rowViews.append(view)
        }
        let away = UITapGestureRecognizer(target: self, action: #selector(tappedAway(_:)))
        away.cancelsTouchesInView = false
        addGestureRecognizer(away)
        accessibilityViewIsModal = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func accessibilityPerformEscape() -> Bool {
        dismissed?()
        return true
    }

    /// The window turned or resized under it: the card, the button and the
    /// finger are elsewhere now, so it goes, as the system's menus do.
    override func layoutSubviews() {
        super.layoutSubviews()
        guard laidOutFor != .zero, bounds.size != laidOutFor else { return }
        laidOutFor = .zero
        DispatchQueue.main.async { [weak self] in self?.dismissed?() }
    }

    @objc private func tappedAway(_ tap: UITapGestureRecognizer) {
        guard !plate.frame.contains(tap.location(in: self)) else { return }
        dismissed?()
    }

    // MARK: Where it stands

    /// By `anchor`, the button's frame here, held open by a finger at
    /// `finger`: the last row, the tab on screen, under the finger, the rest
    /// above it; on the button's side of the window, its edge by the button's.
    func place(from anchor: CGRect, following finger: CGPoint) {
        self.anchor = anchor
        laidOutFor = bounds.size
        dim.frame = bounds
        let width = min(Self.width, bounds.width - 16)
        let safe = bounds.inset(by: safeAreaInsets)
        let leading = anchor.midX < bounds.midX
        // Every row while they take half the screen or less; past that,
        // half the screen, or less where there is less room above the
        // finger, the rest scrolling, the top row cut through to say so.
        let bottom = finger.y + Self.rowHeight / 2 + Self.inset
        let content = CGFloat(rows.count) * Self.rowHeight
        let room = min(bounds.height * Self.most, bottom - safe.minY - 8) - Self.inset * 2
        let shown = max(Self.rowHeight, min(content, room))
        var frame = CGRect(x: 0, y: 0, width: width, height: Self.inset * 2 + shown)
        frame.origin.y = bottom - frame.height
        // The row's icon over the button, where the finger is.
        let iconCentre = Self.inset + PinnedRowView.iconCentre
        frame.origin.x = leading ? max(safe.minX + 8, anchor.midX - iconCentre) : min(safe.maxX - 8, anchor.maxX + Self.inset) - width
        card = frame
        plate.frame = frame
        glass.frame = plate.bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        rowsHost.frame = frame
        rowsShape.frame = rowsHost.bounds
        rowsShape.layer.cornerRadius = Self.corner
        scroller.frame = CGRect(x: Self.inset, y: Self.inset, width: width - Self.inset * 2, height: shown)
        scroller.contentSize = CGSize(width: scroller.bounds.width, height: content)
        for (index, view) in rowViews.enumerated() {
            view.frame = CGRect(x: 0, y: CGFloat(index) * Self.rowHeight, width: scroller.bounds.width, height: Self.rowHeight)
        }
        // The tab on screen in view, where the rows scroll: at the foot, under the finger.
        if let current = rows.firstIndex(where: \.current) {
            scroller.contentOffset.y = max(0, min(CGFloat(current + 1) * Self.rowHeight - shown, content - shown))
        }
        shadeEdges()
        following = true
        start = finger
        moved = false
        // Where it starts: on the tab on screen, the finger on it.
        if let current = rows.firstIndex(where: \.current) {
            highlighted = current
            highlight.frame = rowViews[current].frame
            highlight.alpha = 1
            shine(current)
        }
    }

    // MARK: Coming and going

    /// The button becomes the card: its glass grows from the button's
    /// square to the card, the rows the card opens over standing still, the
    /// tab on screen's where the button was; the others rise into place,
    /// nearest first. Under Reduce Motion the card and the rows only fade.
    func present() {
        let still = UIAccessibility.isReduceMotionEnabled
        let current = rows.firstIndex(where: \.current)
        glass.effect = Self.material
        plate.layer.shadowOpacity = 0
        if still {
            plate.alpha = 0
            rowsHost.alpha = 0
        } else {
            plate.frame = anchor
            round(Side.tileCorner)
            rowsShape.frame = rowsHost.convert(anchor, from: self)
            rowsShape.layer.cornerRadius = Side.tileCorner
            for (index, view) in rowViews.enumerated() where index != current {
                view.alpha = 0
                view.transform = CGAffineTransform(translationX: 0, y: 6)
            }
        }
        UIView.animate(springDuration: 0.32, bounce: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.dim.effect = Self.backdrop
            self.shade.alpha = 1
            self.plate.alpha = 1
            self.rowsHost.alpha = 1
            self.plate.frame = self.card
            self.round(Self.corner)
            self.rowsShape.frame = self.rowsHost.bounds
            self.rowsShape.layer.cornerRadius = Self.corner
        } completion: { _ in
            self.plate.layer.shadowPath = UIBezierPath(roundedRect: self.plate.bounds, cornerRadius: Self.corner).cgPath
        }
        if !still {
            // Nearest the thumb first, upward, a beat after the card starts.
            let order = rowViews.indices.filter { $0 != current }.sorted { abs($0 - (current ?? 0)) < abs($1 - (current ?? 0)) }
            for (step, index) in order.enumerated() {
                let view = rowViews[index]
                let rise = UIViewPropertyAnimator(duration: 0.22, controlPoint1: CGPoint(x: 0.23, y: 1), controlPoint2: CGPoint(x: 0.32, y: 1)) {
                    view.alpha = 1
                    view.transform = .identity
                }
                rise.isUserInteractionEnabled = true
                rise.startAnimation(afterDelay: 0.05 + Double(min(step, 6)) * 0.025)
            }
        }
        // Depth once it is out, not while it grows.
        let shadow = CABasicAnimation(keyPath: "shadowOpacity")
        shadow.fromValue = 0
        shadow.toValue = 0.18
        shadow.beginTime = CACurrentMediaTime() + 0.14
        shadow.duration = 0.18
        shadow.fillMode = .backwards
        plate.layer.add(shadow, forKey: "shadow")
        plate.layer.shadowOpacity = 0.18
        UIAccessibility.post(notification: .screenChanged, argument: rowViews.first(where: { $0.row.current }) ?? rowViews.first)
    }

    /// Back into the button, faster than it came: the other rows go first,
    /// the tab on screen's too where another was chosen, then the card
    /// shrinks into the button's square, `landed` as it gets there, for the
    /// button to come back over it.
    func dismiss(animated: Bool, keepingCurrent: Bool = true, landed: (() -> Void)? = nil) {
        isUserInteractionEnabled = false
        stopScrolling()
        guard animated else {
            removeFromSuperview()
            landed?()
            return
        }
        let still = UIAccessibility.isReduceMotionEnabled
        plate.layer.removeAnimation(forKey: "shadow")
        plate.layer.shadowOpacity = 0
        plate.layer.shadowPath = nil
        UIViewPropertyAnimator(duration: 0.1, curve: .easeOut) {
            for view in self.rowViews where !(keepingCurrent && view.row.current) { view.alpha = 0 }
            if !keepingCurrent { self.highlight.alpha = 0 }
        }.startAnimation()
        UIView.animate(springDuration: 0.24, bounce: 0, options: [.beginFromCurrentState]) {
            self.dim.effect = nil
            self.shade.alpha = 0
            if still {
                self.plate.alpha = 0
                self.rowsHost.alpha = 0
            } else {
                self.plate.frame = self.anchor
                self.round(Side.tileCorner)
                self.rowsShape.frame = self.rowsHost.convert(self.anchor, from: self)
                self.rowsShape.layer.cornerRadius = Side.tileCorner
            }
        } completion: { _ in
            self.removeFromSuperview()
        }
        // The button comes back over the card as the card reaches it, and the card goes under it.
        DispatchQueue.main.asyncAfter(deadline: .now() + (still ? 0.05 : 0.13)) { landed?() }
        UIView.animate(withDuration: 0.1, delay: still ? 0 : 0.14, options: [.curveEaseOut]) {
            self.plate.alpha = 0
            self.rowsHost.alpha = 0
        }
    }

    /// The card's corners: the button's square's as it grows out of it, its own open.
    private func round(_ radius: CGFloat) {
        if #available(iOS 26.0, *) {
            glass.cornerConfiguration = .corners(radius: .fixed(radius))
        } else {
            glass.layer.cornerRadius = radius
        }
    }

    /// The page behind, softened rather than hidden: still there to go back to.
    private static var backdrop: UIVisualEffect? {
        UIAccessibility.isReduceTransparencyEnabled ? nil : UIBlurEffect(style: .systemUltraThinMaterialDark)
    }

    private static var material: UIVisualEffect {
        if #available(iOS 26.0, *) { return UIGlassEffect() }
        return UIBlurEffect(style: .systemThickMaterial)
    }

    // MARK: Following a finger

    /// What following the finger came to: onto another row, off the rows, or no change.
    enum Followed {
        case row
        case off
        /// A row went by the edge while the finger was past it.
        case passed
        case same
    }

    /// The finger at `point` here: the row level with it highlighted,
    /// wherever across the window the finger is.
    func follow(_ point: CGPoint) -> Followed {
        guard following else { return .same }
        if hypot(point.x - start.x, point.y - start.y) > PinnedPress.slop { moved = true }
        finger = point
        if speed(at: point) == 0 { stopScrolling() } else { startScrolling() }
        return track()
    }

    /// The row under the finger highlighted, as the finger or the rows move.
    private func track() -> Followed {
        let index = rowIndex(level: finger)
        guard index != highlighted else { return .same }
        light(index)
        return index == nil ? .off : .row
    }

    // MARK: Scrolling at an edge

    /// How fast the rows scroll for a finger at `point`, in points a second:
    /// up (less than nothing) for a finger within `edge` of their top or
    /// above it, down for one at their foot or below it, faster the further
    /// out, as a list being dragged through does; nothing where there is no
    /// more that way, or the finger is among the rows.
    private func speed(at point: CGPoint) -> CGFloat {
        let rows = scroller.convert(scroller.bounds, to: self)
        let offset = scroller.contentOffset.y
        let end = scroller.contentSize.height - scroller.bounds.height
        func pace(_ past: CGFloat) -> CGFloat {
            // Slow at the edge, for one row at a time; quick a thumb's
            // length past it, for a long list.
            let reach = min(max(past, 0), 140) / 140
            return 90 + 1300 * reach * reach
        }
        if point.y < rows.minY + Self.edge, offset > 0 {
            return -pace(rows.minY + Self.edge - point.y)
        }
        if point.y > rows.maxY - Self.edge, offset < end {
            return pace(point.y - (rows.maxY - Self.edge))
        }
        return 0
    }

    private func startScrolling() {
        guard scrollLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(stepScrolling(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        scrollLink = link
        lastStep = CACurrentMediaTime()
    }

    private func stopScrolling() {
        scrollLink?.invalidate()
        scrollLink = nil
    }

    @objc private func stepScrolling(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = CGFloat(min(max(now - lastStep, 0), 1.0 / 30))
        lastStep = now
        let speed = speed(at: finger)
        guard following, speed != 0 else {
            stopScrolling()
            return
        }
        let end = scroller.contentSize.height - scroller.bounds.height
        let was = scroller.contentOffset.y
        let offset = min(max(was + speed * dt, 0), end)
        scroller.contentOffset.y = offset
        // A row under a still finger is a new row; off the rows, a row going by.
        let followed = track()
        if followed != .same {
            scrolled?(followed)
        } else if highlighted == nil, Int(offset / Self.rowHeight) != Int(was / Self.rowHeight) {
            scrolled?(.passed)
        }
    }

    // MARK: The edges

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        shadeEdges()
    }

    /// The rows fading out at an edge with more of them past it, rather
    /// than cut off by the card; whole where they end.
    private func shadeEdges() {
        let height = max(scroller.bounds.height, 1)
        let offset = scroller.contentOffset.y
        let end = scroller.contentSize.height - height
        let top = offset > 0.5 ? min(Self.fadeLength, offset) / height : 0
        let bottom = offset < end - 0.5 ? min(Self.fadeLength, end - offset) / height : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = scroller.bounds
        fade.colors = [UIColor.black.withAlphaComponent(top > 0 ? 0 : 1).cgColor, UIColor.black.cgColor,
                       UIColor.black.cgColor, UIColor.black.withAlphaComponent(bottom > 0 ? 0 : 1).cgColor]
        fade.locations = [0, NSNumber(value: Double(top)), NSNumber(value: Double(1 - bottom)), 1]
        CATransaction.commit()
    }

    /// The finger lifted: what stays is for a tap.
    func stopFollowing() {
        following = false
        stopScrolling()
        light(nil)
    }

    /// The row the finger lifted on, while it held the list open.
    func row(at point: CGPoint) -> Row? {
        guard following, let index = rowIndex(level: point) else { return nil }
        return rows[index]
    }

    /// The row level with `point`: only its height counts, so a thumb going
    /// up need not keep to the card's column.
    private func rowIndex(level point: CGPoint) -> Int? {
        let inRows = scroller.convert(point, from: self)
        guard scroller.bounds.minY...scroller.bounds.maxY ~= inRows.y, inRows.y >= 0 else { return nil }
        let index = Int(inRows.y / Self.rowHeight)
        return rows.indices.contains(index) ? index : nil
    }

    /// The highlight on a row: moved there on a spring from the row it was
    /// on; shown in place where there was none; faded where there is none.
    private func light(_ index: Int?) {
        let was = highlighted
        highlighted = index
        shine(index ?? rows.firstIndex(where: \.current))
        guard let index else {
            UIView.animate(withDuration: 0.1, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) { self.highlight.alpha = 0 }
            return
        }
        let target = rowViews[index].frame
        if was == nil || highlight.alpha == 0 || UIAccessibility.isReduceMotionEnabled {
            highlight.layer.removeAllAnimations()
            highlight.frame = target
            UIView.animate(withDuration: 0.1, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) { self.highlight.alpha = 1 }
        } else {
            UIView.animate(springDuration: 0.2, bounce: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.highlight.frame = target
                self.highlight.alpha = 1
            }
        }
    }

    /// One row lit with its icon's light, as its pinned tile on screen is:
    /// the one the finger is on, or, where it is on none, the tab on
    /// screen's, which letting go there leaves on screen.
    private func shine(_ index: Int?) {
        for (place, view) in rowViews.enumerated() { view.setLit(place == index) }
    }
}

/// One row of the panel: a pinned tab's icon and name, a check by the one on
/// screen and a dot by one that is open. Large, as the Messages menu's are.
/// The icon is drawn as the pinned button draws it, in every row, whether
/// its tab is on screen, open or closed (PinnedIcon): its mark on a soft
/// light of its own colours. Drawn whole here, the tab on screen's icon
/// changed as the button became its row. Lit (PinnedPanel.shine), the row
/// glows as its pinned tile on screen does: its icon's own colours spread
/// soft and further, or the space's for an icon of none, and the row's
/// block tinted as the tile's glass is.
private final class PinnedRowView: UIControl {
    let row: PinnedPanel.Row
    private let colour: SpaceColor
    private let lit = UIView()
    /// The tile's tint, strongest by the icon and thinning out across the
    /// row, as light from it would: one even tint read as a duller block.
    private let wash = CAGradientLayer()
    private let glow = UIImageView()
    /// The space's light, for an icon of no colour of its own.
    private let spaceGlow = CAGradientLayer()
    private var isLit = false
    /// The icon and its light, which a row cuts off at its rounded edge as a tile does.
    private let iconRoom = UIView()
    private let iconHost: UIHostingController<ZStack<PinnedIcon>>
    private let title = UILabel()
    private let mark = UIImageView()
    private let dot = UIView()

    static let icon: CGFloat = 34
    static let lead: CGFloat = 12
    /// The icon's centre from the row's leading edge.
    static var iconCentre: CGFloat { lead + icon / 2 }

    init(row: PinnedPanel.Row, colour: SpaceColor) {
        self.row = row
        self.colour = colour
        // The button's plate is for its smaller icon: as much larger here, so the mark stands on as much of it.
        let scale = Self.icon / Side.tileIcon
        let plate = PinnedIcon.tilePlate
        iconHost = UIHostingController(rootView: ZStack {
            PinnedIcon(url: row.site, open: row.current, colour: colour, size: Self.icon, lean: nil,
                       plate: (side: (plate.side * scale).rounded(), corner: (plate.corner * scale).rounded(),
                               blur: (plate.blur * scale).rounded()))
        })
        super.init(frame: .zero)
        lit.isUserInteractionEnabled = false
        lit.alpha = 0
        lit.clipsToBounds = true
        lit.layer.cornerRadius = PinnedPanel.corner - PinnedPanel.inset
        lit.layer.cornerCurve = .continuous
        wash.startPoint = CGPoint(x: 0, y: 0.5)
        wash.endPoint = CGPoint(x: 1, y: 0.5)
        lit.layer.addSublayer(wash)
        spaceGlow.type = .radial
        spaceGlow.startPoint = CGPoint(x: 0.5, y: 0.5)
        spaceGlow.endPoint = CGPoint(x: 1, y: 1)
        lit.layer.addSublayer(spaceGlow)
        lit.addSubview(glow)
        addSubview(lit)
        iconRoom.isUserInteractionEnabled = false
        iconRoom.clipsToBounds = true
        iconRoom.layer.cornerRadius = PinnedPanel.corner - PinnedPanel.inset
        iconRoom.layer.cornerCurve = .continuous
        iconHost.view.backgroundColor = .clear
        iconHost.view.isUserInteractionEnabled = false
        iconHost.safeAreaRegions = []
        iconRoom.addSubview(iconHost.view)
        addSubview(iconRoom)
        title.text = row.title
        title.font = .systemFont(ofSize: 19)
        title.textColor = .label
        addSubview(title)
        mark.image = UIImage(systemName: "checkmark",
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        mark.tintColor = .label
        mark.isHidden = !row.current
        addSubview(mark)
        dot.backgroundColor = Palette.UI.ink.withAlphaComponent(0.55)
        dot.layer.cornerRadius = 3
        dot.isHidden = row.current || !row.open
        addSubview(dot)
        isAccessibilityElement = true
        accessibilityLabel = row.title
        accessibilityValue = row.current ? String(localized: "Current") : row.open ? String(localized: "Open") : nil
        accessibilityTraits = row.current ? [.button, .selected] : .button
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let mid = bounds.midY
        let site = CGRect(x: Self.lead, y: mid - Self.icon / 2, width: Self.icon, height: Self.icon)
        iconRoom.frame = bounds
        // Room for the icon's light, which spreads past it (PinnedIcon.light).
        let room = Self.icon * 2.5
        iconHost.view.frame = CGRect(x: site.midX - room / 2, y: mid - room / 2, width: room, height: room)
        lit.frame = bounds
        // Further past the icon than the tile's light (PinnedIcon.light): the row has the room.
        let span = (IconTint.glow(for: row.site)?.span ?? 40.0 / 24) * 1.4 * Self.icon
        glow.frame = CGRect(x: site.midX - span / 2, y: mid - span / 2, width: span, height: span)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wash.frame = lit.bounds
        spaceGlow.frame = glow.frame
        CATransaction.commit()
        mark.frame = CGRect(x: bounds.width - 36, y: mid - 10, width: 20, height: 20)
        dot.frame = CGRect(x: bounds.width - 29, y: mid - 3, width: 6, height: 6)
        let words = site.maxX + 16
        title.frame = CGRect(x: words, y: 0, width: bounds.width - words - 44, height: bounds.height)
    }

    /// Lit, fading in as the highlight reaches it; out a little faster.
    func setLit(_ on: Bool) {
        guard on != isLit else { return }
        isLit = on
        if on { readLight() }
        UIView.animate(withDuration: on ? 0.15 : 0.1, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]) {
            self.lit.alpha = on ? 1 : 0
        }
    }

    /// The icon's light and the tile's tint, read as the row is lit: its icon has come by then.
    private func readLight() {
        let light = IconTint.glow(for: row.site)
        glow.image = light?.picture
        let space = colour.uiColor.resolvedColor(with: traitCollection)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spaceGlow.colors = light == nil ? [space.withAlphaComponent(traitCollection.userInterfaceStyle == .dark ? 0.45 : 0.35).cgColor,
                                           space.withAlphaComponent(0).cgColor] : nil
        if let tint = PinnedIcon.tileTint(for: row.site, colour: colour).map({ UIColor($0).resolvedColor(with: traitCollection) }) {
            let alpha = tint.cgColor.alpha
            wash.colors = [tint.withAlphaComponent(min(alpha * 1.6, 1)).cgColor, tint.withAlphaComponent(alpha * 0.2).cgColor]
        } else {
            wash.colors = nil
        }
        CATransaction.commit()
        // On dark glass the light adds to it, as the tile's does (PinnedIcon.light),
        // rather than mixing with its grey into brown where it thins out.
        lit.layer.compositingFilter = traitCollection.userInterfaceStyle == .dark ? "plusL" : nil
        setNeedsLayout()
    }
}
