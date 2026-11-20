import Combine
import PadCore
import SwiftUI
import UIKit

/// The space's tabs as a grid, on the sheet the phone bar turns into
/// (TabSheet), as Safari and Comet show theirs: each tab as a picture of its
/// page with its name under it. The pinned tabs sit apart, in a dock at the bottom as the iPhone's apps do,
/// their icons scrolling sideways when there are more than fit. A tap goes to a tab; a swipe sideways
/// throws it away and closes it; a long press has Safari's menu (copy,
/// share, pin, move, arrange, close others, close all). New Tab and Done
/// are at the bottom, where the thumb already is.
///
/// UIKit, because a card that follows a finger sideways inside a list that
/// scrolls up and down is a matter of which gesture gets the touch, and
/// UIKit lets each one say.
@MainActor
final class TabOverviewController: UIViewController, UICollectionViewDelegate {
    private struct InitialPosition {
        let spaceID: UUID
        let tabID: UUID?
        var snapshotApplied = false
    }

    // The data source compares these off the main actor.
    nonisolated private enum Section: Hashable {
        case tabs
    }

    nonisolated private enum Item: Hashable {
        case tab(UUID)
    }

    private let session: Session
    private let window: WindowModel
    private let act: (BarAction) -> Void
    private let done: (BarAction?) -> Void

    private let header = UIView()
    /// The space's button, with its name, in the middle of the header (SpaceHeading).
    private var heading: UIHostingController<SpaceHeading>!
    private lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: layout())
    private var source: UICollectionViewDiffableDataSource<Section, Item>!
    private let dock = PinnedDock()
    private let newTab = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)

    private var previews: [UUID: UIImage] = [:]
    private var asked: Set<UUID> = []
    /// The tab whose picture is being asked for, while preview(for:) has
    /// yet to return: one that comes back by then is this card's to show.
    private var asking: UUID?
    private var watching: Set<AnyCancellable> = []
    private var applying = false
    private var shown = false
    private var gridSpaceID: UUID?
    private var snapshotGeneration = 0
    private var initialPosition: InitialPosition?

    private static var headerHeight: CGFloat { max(52, UIFont.preferredFont(forTextStyle: .headline).lineHeight + 20) }
    private static var barHeight: CGFloat { max(64, UIFont.preferredFont(forTextStyle: .body).lineHeight + 30) }
    /// The grid fades out under the heading and at the sheet's foot, where
    /// more of it is past them, rather than being cut off there; whole
    /// where it ends.
    private let fade = CAGradientLayer()
    private static let fadeTop: CGFloat = 24
    private static let fadeBottom: CGFloat = 44

    init(session: Session, window: WindowModel, act: @escaping (BarAction) -> Void, done: @escaping (BarAction?) -> Void) {
        self.session = session
        self.window = window
        self.act = act
        self.done = done
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.UI.tray

        // Another space chosen there: its tabs, here. What opens a window
        // of its own (naming a new space, the space's settings) has the
        // sheet go first, as a tab chosen does.
        let heading = UIHostingController(rootView: SpaceHeading(session: session, window: window) { [weak self] action in
            switch action {
            case .switchSpace, .removeSpace: self?.act(action)
            default: self?.done(action)
            }
        })
        heading.view.backgroundColor = .clear
        heading.sizingOptions = [.intrinsicContentSize]
        addChild(heading)
        header.addSubview(heading.view)
        heading.didMove(toParent: self)
        self.heading = heading

        collection.backgroundColor = .clear
        collection.contentInsetAdjustmentBehavior = .never
        collection.alwaysBounceVertical = true
        collection.delegate = self
        // Touch and hold a card, then move it: the tabs' order, as the iPad's row and sidebar drag them.
        collection.dragInteractionEnabled = true
        collection.dragDelegate = self
        collection.dropDelegate = self
        fade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.black.cgColor, UIColor.black.cgColor]
        collection.layer.mask = fade
        view.addSubview(collection)
        view.addSubview(header)

        newTab.configuration = Self.glass(symbol: "plus")
        newTab.accessibilityLabel = String(localized: "New Tab")
        newTab.addAction(UIAction { [weak self] _ in self?.done(.command(.newTab)) }, for: .primaryActionTriggered)
        // Held, as Safari's: the tab closed last, when there is one, reopened as the sheet goes.
        newTab.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] answer in
            guard let self, !self.session.workspace.closed.isEmpty else { return answer([]) }
            answer([UIAction(title: String(localized: "Reopen Closed Tab"), image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in
                self?.done(.command(.reopenTab))
            }])
        }])
        doneButton.configuration = Self.glass(title: String(localized: "Done"))
        doneButton.addAction(UIAction { [weak self] _ in self?.done(nil) }, for: .primaryActionTriggered)
        dock.chosen = { [weak self] id in self?.done(.select(id)) }
        dock.menu = { [weak self] tab, source in self?.menu(for: tab, from: source) }
        view.addSubview(dock)
        view.addSubview(newTab)
        view.addSubview(doneButton)

        makeSource()
        apply()
        session.$workspace.sink { [weak self] _ in self?.applySoon() }.store(in: &watching)
        // A pinned tab hidden or shown again in Settings.
        session.$preferences.map(\.hiddenPinnedTabs).removeDuplicates().sink { [weak self] _ in self?.applySoon() }
            .store(in: &watching)
        watch(self, read: { _ = $0.window.tabID; _ = $0.window.spaceID }, changed: { $0.applySoon() })
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: TabOverviewController, _) in
            self.collection.collectionViewLayout.invalidateLayout()
            self.view.setNeedsLayout()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Clear of a side the system keeps: the iPhone Duo's strip, whose
        // tools stand over the sheet, or a small iPhone's edges turned.
        let safe = view.safeAreaInsets
        let bounds = view.bounds.inset(by: UIEdgeInsets(top: 0, left: safe.left, bottom: 0, right: safe.right))
        header.frame = CGRect(x: bounds.minX, y: 0, width: bounds.width, height: Self.headerHeight)
        let face = heading.view.intrinsicContentSize
        let width = min(face.width, bounds.width - 32)
        heading.view.frame = CGRect(x: ((bounds.width - width) / 2).rounded(), y: ((Self.headerHeight - face.height) / 2).rounded(),
                                    width: width, height: face.height)
        collection.frame = CGRect(x: bounds.minX, y: Self.headerHeight, width: bounds.width, height: max(0, bounds.height - Self.headerHeight))
        let y = bounds.height - Self.barHeight + 10
        let docked = !dock.isHidden
        // As wide as the bar's buttons reach, and as far above them as they are apart from its own edge.
        dock.frame = CGRect(x: bounds.minX + 16, y: bounds.height - Self.barHeight - PinnedDock.height, width: bounds.width - 32,
                            height: PinnedDock.height)
        // The grid's last row clears the dock, which floats over the grid
        // as it scrolls, with room to spare.
        let below = Self.barHeight + (docked ? PinnedDock.height + 20 : 8)
        collection.contentInset.bottom = below
        collection.verticalScrollIndicatorInsets.bottom = below
        fadeEdges()
        newTab.frame = CGRect(x: bounds.minX + 16, y: y, width: 44, height: 44)
        let controlHeight = Self.barHeight - 20
        let fits = doneButton.sizeThatFits(CGSize(width: bounds.width - 100, height: controlHeight))
        doneButton.frame = CGRect(x: bounds.maxX - 16 - max(fits.width, 72), y: y, width: max(fits.width, 72), height: controlHeight)
        positionAtInitialTabIfReady()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        initialPosition = nil
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        fadeEdges()
    }

    /// Each edge's fade as long as the grid goes past it, up to its full
    /// length: none at the top of the grid, growing as it scrolls under.
    private func fadeEdges() {
        let height = max(collection.bounds.height, 1)
        let offset = collection.contentOffset.y + collection.adjustedContentInset.top
        let past = collection.contentSize.height - (collection.contentOffset.y + height)
        let top = min(Self.fadeTop, max(offset, 0)) / height
        let bottom = min(Self.fadeBottom, max(past, 0)) / height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The mask is in the grid's own bounds, which move as it scrolls.
        fade.frame = collection.bounds
        fade.colors = [UIColor.black.withAlphaComponent(top > 0 ? 0 : 1).cgColor, UIColor.black.cgColor,
                       UIColor.black.cgColor, UIColor.black.withAlphaComponent(bottom > 0 ? 0 : 1).cgColor]
        fade.locations = [0, NSNumber(value: Double(top)), NSNumber(value: Double(1 - bottom)), 1]
        CATransaction.commit()
    }

    private static func glass(symbol: String? = nil, title: String? = nil) -> UIButton.Configuration {
        var style: UIButton.Configuration
        if #available(iOS 26.0, *) {
            style = .glass()
        } else {
            style = .gray()
        }
        style.cornerStyle = .capsule
        style.baseForegroundColor = Palette.UI.ink
        if let symbol {
            style.image = UIImage(systemName: symbol)
            style.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
            style.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
        }
        if let title {
            style.title = title
            style.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
                return attributes
            }
            style.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 18)
        }
        return style
    }

    // MARK: The grid

    private func layout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            let width = environment.container.effectiveContentSize.width
            let inner = width - 32
            let columns = max(2, Int((inner + 14) / (150 + 14)))
            let cardWidth = ((inner - CGFloat(columns - 1) * 14) / CGFloat(columns)).rounded(.down)
            let height = TabCardCell.height(forWidth: cardWidth)
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(cardWidth), heightDimension: .absolute(height)))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1),
                                                                             heightDimension: .absolute(height)),
                                                           repeatingSubitem: item, count: columns)
            group.interItemSpacing = .fixed(14)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 18
            section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
            return section
        }
    }

    private func makeSource() {
        let card = UICollectionView.CellRegistration<TabCardCell, UUID> { [weak self] cell, _, id in
            self?.configure(cell, id)
        }
        source = UICollectionViewDiffableDataSource(collectionView: collection) { view, path, item in
            switch item {
            case .tab(let id): return view.dequeueConfiguredReusableCell(using: card, for: path, item: id)
            }
        }
    }

    private var space: Space? {
        session.workspace.space(window.spaceID)
    }

    private var spaceColor: UIColor {
        space?.color.uiColor ?? Palette.UI.ink
    }

    private func configure(_ cell: TabCardCell, _ id: UUID) {
        guard let tab = session.workspace.tab(id) else { return }
        // As each card comes into view, so a space of many tabs never holds every picture.
        if previews[id] == nil, tab.url != nil, !asked.contains(id) {
            asked.insert(id)
            // A picture already in memory comes back before preview returns,
            // often while a snapshot is being applied: this card takes it
            // below, as applying another snapshot inside that one crashes.
            asking = id
            session.pages.preview(for: id, width: Pages.previewWidth) { [weak self] image in
                guard let self, let image else { return }
                previews[id] = image
                guard asking != id else { return }
                var snapshot = source.snapshot()
                if snapshot.itemIdentifiers.contains(.tab(id)) {
                    snapshot.reconfigureItems([.tab(id)])
                    applySnapshot(snapshot, animatingDifferences: false, in: gridSpaceID ?? window.spaceID)
                }
            }
            asking = nil
        }
        cell.configure(tab: tab, image: previews[id], current: id == window.tabID, color: spaceColor)
        cell.closed = { [weak self] in self?.act(.close(id)) }
        cell.menu = menu(for: tab, from: cell)
    }

    private func applySoon() {
        guard !applying else { return }
        applying = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            applying = false
            apply()
        }
    }

    private func apply() {
        guard source != nil else { return }
        let spaceID = window.spaceID
        if gridSpaceID != spaceID {
            gridSpaceID = spaceID
            initialPosition = InitialPosition(spaceID: spaceID, tabID: window.tabID)
        }
        // A pinned tab hidden on this device in Settings › Pinned Tabs stays
        // out of the dock, as out of the pinned list and the swipe, unless
        // it is the tab on screen (PageSlide).
        let tabs = space?.tabs ?? []
        let pinned = tabs.filter { $0.isPinned && ($0.id == window.tabID || session.preferences.shows($0)) }
        let others = tabs.filter { !$0.isPinned }
        // The space's name, and so its button's width, may have changed.
        view.setNeedsLayout()

        dock.isHidden = pinned.isEmpty
        dock.show(pinned, current: window.tabID, color: spaceColor)

        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.tabs])
        snapshot.appendItems(others.map { .tab($0.id) }, toSection: .tabs)
        // What a card says (its name, the ring of the tab on screen) can
        // change without the card coming or going.
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        applySnapshot(snapshot, animatingDifferences: shown && !UIAccessibility.isReduceMotionEnabled, in: spaceID)
        shown = true
    }

    private func applySnapshot(_ snapshot: NSDiffableDataSourceSnapshot<Section, Item>, animatingDifferences: Bool, in spaceID: UUID) {
        snapshotGeneration += 1
        let generation = snapshotGeneration
        initialPosition?.snapshotApplied = false
        source.apply(snapshot, animatingDifferences: animatingDifferences) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, snapshotGeneration == generation, window.spaceID == spaceID,
                      var initialPosition, initialPosition.spaceID == spaceID else { return }
                initialPosition.snapshotApplied = true
                self.initialPosition = initialPosition
                view.setNeedsLayout()
                view.layoutIfNeeded()
                positionAtInitialTabIfReady()
            }
        }
    }

    private func positionAtInitialTabIfReady() {
        guard let initialPosition, initialPosition.snapshotApplied,
              initialPosition.spaceID == window.spaceID,
              collection.bounds.width > 0, collection.bounds.height > 0 else { return }
        collection.layoutIfNeeded()
        let path = initialPosition.tabID.flatMap { source.indexPath(for: .tab($0)) }
        self.initialPosition = nil
        if let path {
            collection.scrollToItem(at: path, at: .centeredVertically, animated: false)
        } else {
            collection.setContentOffset(.zero, animated: false)
        }
    }

    // MARK: Taps and menus

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt path: IndexPath) {
        collectionView.deselectItem(at: path, animated: false)
        switch source.itemIdentifier(for: path) {
        case .tab(let id):
            done(.select(id))
        case nil:
            break
        }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt paths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let path = paths.first, case .tab(let id) = source.itemIdentifier(for: path) else { return nil }
        guard let tab = session.workspace.tab(id), let cell = collectionView.cellForItem(at: path) else { return nil }
        return UIContextMenuConfiguration(identifier: id.uuidString as NSString, previewProvider: nil) { [weak self] _ in
            self?.menu(for: tab, from: cell)
        }
    }

    /// The card lifts in its own rounded shape, not the box around it.
    func collectionView(_ collectionView: UICollectionView,
                        contextMenuConfiguration configuration: UIContextMenuConfiguration,
                        highlightPreviewForItemAt path: IndexPath) -> UITargetedPreview? {
        (collectionView.cellForItem(at: path) as? TabCardCell)?.preview()
    }

    func collectionView(_ collectionView: UICollectionView,
                        contextMenuConfiguration configuration: UIContextMenuConfiguration,
                        dismissalPreviewForItemAt path: IndexPath) -> UITargetedPreview? {
        self.collectionView(collectionView, contextMenuConfiguration: configuration, highlightPreviewForItemAt: path)
    }

    /// Safari's menu for a tab in its overview: its link, where it is kept,
    /// the order of them all, and closing it, the others or every one.
    private func menu(for tab: TabRecord, from source: UIView) -> UIMenu {
        var sections: [UIMenuElement] = []
        let address = tab.isPinned ? tab.url ?? tab.pinned : tab.url
        if let address {
            sections.append(UIMenu(options: .displayInline, children: [
                UIAction(title: String(localized: "Copy Link"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.act(.copy(address)) },
                // Weakly: a dock icon keeps its menu, which would otherwise keep the icon.
                UIAction(title: String(localized: "Share…"), image: UIImage(systemName: "square.and.arrow.up")) { [weak self, weak source] _ in
                    guard let source else { return }
                    self?.share(address, from: source)
                },
            ]))
        }
        var keep: [UIMenuElement] = []
        if tab.isPinned {
            // Where it is pinned, and going back there or pinning it here
            // instead, as the pinned button on the bar has them.
            let away: UIMenuElement.Attributes = tab.isAwayFromPinned ? [] : .disabled
            sections.append(UIMenu(title: tab.pinnedAddress.map { String(localized: "Pinned to \($0)") } ?? "", options: .displayInline, children: [
                UIAction(title: String(localized: "Back to Pinned Address"), image: UIImage(systemName: "arrow.uturn.backward"), attributes: away) { [weak self] _ in
                    self?.act(.backToPinned(tab.id))
                },
                UIAction(title: String(localized: "Replace with Current Page"), image: UIImage(systemName: "pin"), attributes: away) { [weak self] _ in
                    self?.act(.repin(tab.id))
                },
                UIAction(title: String(localized: "Unpin Tab"), image: UIImage(systemName: "pin.slash")) { [weak self] _ in
                    self?.act(.unpin(tab.id))
                },
            ]))
        } else if tab.url != nil {
            keep.append(UIAction(title: String(localized: "Pin Tab"), image: UIImage(systemName: "pin")) { [weak self] _ in self?.act(.pin(tab.id)) })
        }
        // A split made while the window was wide shows one pane here: the way out of it.
        if session.workspace.split(containing: tab.id) != nil {
            keep.append(UIAction(title: String(localized: "Separate Tabs"), image: UIImage(systemName: "rectangle")) { [weak self] _ in
                self?.act(.separate(tab.id))
            })
        }
        let others = session.workspace.spaces.filter { $0.id != window.spaceID }
        if !others.isEmpty {
            keep.append(UIMenu(title: String(localized: "Move to Space"), image: UIImage(systemName: "arrow.right.square"), children: others.map { space in
                UIAction(title: space.name, image: UIImage(systemName: space.symbol)) { [weak self] _ in
                    self?.act(.moveTab(tab.id, space.id))
                }
            }))
        }
        let ordinary = (space?.tabs ?? []).filter { !$0.isPinned }
        if ordinary.count > 1 {
            keep.append(UIMenu(title: String(localized: "Arrange Tabs By"), image: UIImage(systemName: "arrow.up.arrow.down"), children: [
                UIAction(title: String(localized: "Title"), image: UIImage(systemName: "textformat")) { [weak self] _ in self?.act(.arrangeTabs(.title)) },
                UIAction(title: String(localized: "Website"), image: UIImage(systemName: "globe")) { [weak self] _ in self?.act(.arrangeTabs(.website)) },
            ]))
        }
        if !keep.isEmpty { sections.append(UIMenu(options: .displayInline, children: keep)) }
        var close: [UIMenuElement] = []
        if !tab.isPinned {
            let rest = ordinary.filter { $0.id != tab.id }.map(\.id)
            if !rest.isEmpty {
                close.append(UIAction(title: String(localized: "Close Other Tabs"), image: UIImage(systemName: "xmark.square"),
                                      attributes: .destructive) { [weak self] _ in self?.act(.closeTabs(rest)) })
            }
            if ordinary.count > 1 {
                close.append(UIAction(title: String(localized: "Close All \(ordinary.count) Tabs"), image: UIImage(systemName: "xmark.square.fill"),
                                      attributes: .destructive) { [weak self] _ in
                    self?.done(.closeTabs(ordinary.map(\.id)))
                })
            }
        }
        close.append(UIAction(title: String(localized: "Close Tab"), image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in
            self?.act(.close(tab.id))
        })
        sections.append(UIMenu(options: .displayInline, children: close))
        return UIMenu(children: sections)
    }

    /// Without the tags that follow whoever opens it (Tracking.clean), as every address the app gives away.
    private func share(_ url: URL, from source: UIView) {
        let sheet = UIActivityViewController(activityItems: [Tracking.clean(url)], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = source
            popover.sourceRect = source.bounds
        }
        present(sheet, animated: true)
    }
}

// MARK: A tab's card

/// A tab in the overview: a picture of its page (or its site's icon, before
/// there is one), its name under it, and a close button on the picture; the
/// tab on screen ringed in the space's colour, the ring's corners following
/// the picture's. A swipe sideways throws it off and closes it.
@MainActor
final class TabCardCell: UICollectionViewCell, UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate {
    var closed: (() -> Void)?
    /// The tab's menu, for a long press on the close button: the grid's own
    /// never begins on a button. The card lifts as it does from anywhere else on it.
    var menu: UIMenu?

    private let card = UIView()
    private let shadow = UIView()
    private let picture = UIView()
    private let image = UIImageView()
    private let placeholder = SiteIconUIView()
    private let ring = UIView()
    private let icon = SiteIconUIView()
    private let name = UILabel()
    private let close = WideButton(type: .system)
    private var aspect: CGFloat = 0
    private var ticked = false
    private var closing = false
    private let tick = UIImpactFeedbackGenerator(style: .medium)

    private static let radius: CGFloat = 18
    /// Between the picture and the ring around the tab on screen.
    private static let gap: CGFloat = 4
    private static let ratio: CGFloat = 0.78
    private static var label: CGFloat { UIFontMetrics(forTextStyle: .subheadline).scaledValue(for: 18) * 2 }

    /// How tall a card is for its width: the picture, the ring's room, the name.
    static func height(forWidth width: CGFloat) -> CGFloat {
        ((width - gap * 2) / ratio).rounded() + gap * 2 + 6 + label
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(card)
        ring.layer.borderWidth = 2.5
        ring.layer.cornerRadius = Self.radius + Self.gap
        ring.layer.cornerCurve = .continuous
        card.addSubview(ring)
        shadow.layer.shadowColor = UIColor.black.cgColor
        shadow.layer.shadowOffset = CGSize(width: 0, height: 3)
        shadow.layer.shadowRadius = 10
        card.addSubview(shadow)
        picture.clipsToBounds = true
        picture.layer.cornerRadius = Self.radius
        picture.layer.cornerCurve = .continuous
        picture.layer.borderWidth = 1
        picture.backgroundColor = Palette.UI.card
        shadow.addSubview(picture)
        placeholder.size = 36
        picture.addSubview(placeholder)
        image.contentMode = .scaleToFill
        picture.addSubview(image)
        icon.size = 16
        card.addSubview(icon)
        name.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 13, weight: .medium))
        name.adjustsFontForContentSizeCategory = true
        name.numberOfLines = 2
        name.textColor = Palette.UI.ink
        card.addSubview(name)

        var style: UIButton.Configuration
        if #available(iOS 26.0, *) {
            style = .glass()
        } else {
            style = .gray()
        }
        style.cornerStyle = .capsule
        style.image = UIImage(systemName: "xmark")
        style.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        style.baseForegroundColor = Palette.UI.ink
        style.contentInsets = .zero
        close.configuration = style
        close.addAction(UIAction { [weak self] _ in self?.closed?() }, for: .primaryActionTriggered)
        close.addInteraction(UIContextMenuInteraction(delegate: self))
        card.addSubview(close)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(swiped(_:)))
        // A second finger doesn't join a card already moving.
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        contentView.addGestureRecognizer(pan)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: String(localized: "Close Tab")) { [weak self] _ in
            self?.closed?()
            return true
        }]
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: TabCardCell, _) in self.colours() }
        colours()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(tab: TabRecord, image found: UIImage?, current: Bool, color: UIColor) {
        image.image = found
        image.isHidden = found == nil
        aspect = found.map { $0.size.height / max($0.size.width, 1) } ?? 0
        placeholder.url = tab.url
        placeholder.isHidden = found != nil
        icon.url = tab.url
        name.text = tab.label
        name.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 13, weight: current ? .semibold : .medium))
        ring.layer.borderColor = color.cgColor
        ring.isHidden = !current
        close.accessibilityLabel = String(localized: "Close \(tab.label)")
        accessibilityLabel = tab.label
        accessibilityTraits = current ? [.button, .selected] : .button
        setNeedsLayout()
    }

    private func colours() {
        let dark = traitCollection.userInterfaceStyle == .dark
        picture.layer.borderColor = UIColor(white: dark ? 1 : 0, alpha: 0.1).cgColor
        shadow.layer.shadowOpacity = dark ? 0.3 : 0.08
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        card.frame = contentView.bounds
        let width = contentView.bounds.width
        let pictureWidth = width - Self.gap * 2
        let pictureHeight = (pictureWidth / Self.ratio).rounded()
        ring.frame = CGRect(x: 0, y: 0, width: width, height: pictureHeight + Self.gap * 2)
        shadow.frame = CGRect(x: Self.gap, y: Self.gap, width: pictureWidth, height: pictureHeight)
        shadow.layer.shadowPath = UIBezierPath(roundedRect: shadow.bounds, cornerRadius: Self.radius).cgPath
        picture.frame = shadow.bounds
        placeholder.frame = CGRect(x: pictureWidth / 2 - 18, y: pictureHeight / 2 - 18, width: 36, height: 36)
        // The top of the page, where what it is shows. A picture wider than
        // the card (a desktop page's) fills its height and shows its left
        // side: cut, never stretched.
        if aspect == 0 || pictureWidth * aspect >= pictureHeight {
            image.frame = CGRect(x: 0, y: 0, width: pictureWidth, height: max(pictureHeight, pictureWidth * aspect))
        } else {
            image.frame = CGRect(x: 0, y: 0, width: pictureHeight / aspect, height: pictureHeight)
        }
        close.frame = CGRect(x: width - Self.gap - 9 - 26, y: Self.gap + 9, width: 26, height: 26)
        let row = ring.frame.maxY + 6
        // The name from the top of its room, a line or two of it, and the
        // icon level with its first line: a label centres its words in its
        // frame, which left a name of one line half a line under its icon.
        let room = CGSize(width: max(0, width - Self.gap - 2 - 16 - 6 - Self.gap), height: Self.label)
        icon.frame = CGRect(x: Self.gap + 2, y: (row + (name.font.lineHeight - 16) / 2).rounded(), width: 16, height: 16)
        name.frame = CGRect(x: icon.frame.maxX + 6, y: row, width: room.width,
                            height: min(room.height, name.sizeThatFits(room).height.rounded(.up)))
    }

    override var isHighlighted: Bool {
        didSet {
            guard !closing, card.transform.tx == 0 else { return }
            let still = UIAccessibility.isReduceMotionEnabled
            let press = {
                self.card.transform = self.isHighlighted && !still ? CGAffineTransform(scaleX: 0.96, y: 0.96) : .identity
                self.card.alpha = self.isHighlighted && still ? 0.85 : 1
            }
            if still {
                UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut],
                               animations: press)
            } else {
                UIView.animate(springDuration: 0.3, bounce: 0, options: [.beginFromCurrentState, .allowUserInteraction],
                               animations: press)
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // A throw still flying belongs to the tab this cell showed, not the next one.
        contentView.layer.removeAllAnimations()
        card.layer.removeAllAnimations()
        card.transform = .identity
        card.alpha = 1
        layer.zPosition = 0
        ticked = false
        closing = false
        isUserInteractionEnabled = true
        closed = nil
        menu = nil
    }

    /// The picture alone, in its corners, as it is lifted to be moved.
    func dragParameters() -> UIDragPreviewParameters {
        let parameters = UIDragPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: picture.convert(picture.bounds, to: self), cornerRadius: Self.radius)
        parameters.backgroundColor = .clear
        return parameters
    }

    /// The picture alone, in its corners, for the menu to lift.
    func preview() -> UITargetedPreview {
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: picture.bounds, cornerRadius: Self.radius)
        parameters.backgroundColor = .clear
        return UITargetedPreview(view: picture, parameters: parameters)
    }

    // MARK: The menu from the close button

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let menu else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configuration: UIContextMenuConfiguration,
                                highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        preview()
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configuration: UIContextMenuConfiguration,
                                dismissalPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        preview()
    }

    // MARK: Throwing it away

    /// Sideways and more sideways than up or down; up and down is the
    /// grid's scroll. UIKit asks a view this for its ancestors' gestures
    /// too, the grid's scroll among them: those it leaves alone.
    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture.view === contentView, let pan = gesture as? UIPanGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(gesture)
        }
        // A card held a moment before it moves is being lifted to move it
        // (the overview's drag), not thrown away.
        guard !closing, ProcessInfo.processInfo.systemUptime - touchedAt < 0.3 else { return false }
        let velocity = pan.velocity(in: contentView)
        return abs(velocity.x) > abs(velocity.y) * 1.2
    }

    /// When the finger came down on the card, as the swipe heard it: a
    /// scroll view hands its cells their touches late, its gestures not.
    private var touchedAt: TimeInterval = 0

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gesture.view === contentView { touchedAt = touch.timestamp }
        return true
    }

    /// The grid's own scroll waits for this one to say it isn't a sideways swipe.
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        other.view is UICollectionView && other is UIPanGestureRecognizer
    }

    @objc private func swiped(_ pan: UIPanGestureRecognizer) {
        let width = max(contentView.bounds.width, 1)
        let moved = pan.translation(in: contentView)
        let x = moved.x
        let line = width * 0.45
        switch pan.state {
        case .began:
            ticked = false
            tick.prepare()
            // Over the cards beside it while it is held, not under them.
            layer.zPosition = 1
        case .changed:
            // Held, not slid on a rail: it goes where the finger takes it,
            // up and down too, leaning a little the way it is going.
            card.transform = Self.held(moved, width: width)
            card.alpha = 1 - min(abs(x) / (width * 1.4), 0.6)
            // A firm tap where letting go will close it, and again if it comes back.
            let past = abs(x) > line
            if past != ticked {
                ticked = past
                tick.impactOccurred(intensity: past ? 1 : 0.6)
            }
        case .ended, .cancelled, .failed:
            let speed = pan.velocity(in: contentView)
            let thrown = pan.state == .ended && Throw.cardThrown(x: x, speed: speed.x, width: width, line: line)
            if thrown, let close = closed {
                if !ticked { tick.impactOccurred(intensity: 1) }
                closing = true
                isUserInteractionEnabled = false
                if UIAccessibility.isReduceMotionEnabled {
                    // Keep the card where the finger left it, then remove it
                    // after a short fade instead of carrying it across the screen.
                    UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
                        self.card.alpha = 0
                    } completion: { _ in close() }
                    ticked = false
                    return
                }
                // Off the way the throw would carry it, as a scroll's flick
                // does, on the line the finger was taking it.
                let away = (x + Throw.carry(speed.x) >= 0 ? 1 : -1) * (window?.bounds.width ?? width * 3)
                let rise = moved.y + Throw.carry(speed.y) * 0.5
                let velocity = abs(speed.x) / max(abs(away - x), 1)
                // The tab thrown is this one: a scroll meanwhile may give the cell to another.
                UIView.animate(springDuration: 0.35, bounce: 0, initialSpringVelocity: velocity,
                               options: [.beginFromCurrentState]) {
                    self.card.transform = Self.held(CGPoint(x: away, y: rise), width: width)
                    self.card.alpha = 0
                } completion: { _ in
                    close()
                }
            } else {
                // Back where it was, from wherever the finger left it.
                let restore = {
                    self.card.transform = .identity
                    self.card.alpha = 1
                }
                let restored: (Bool) -> Void = { _ in
                    if self.card.transform == .identity { self.layer.zPosition = 0 }
                }
                if UIAccessibility.isReduceMotionEnabled {
                    // Cross-fade between the released and resting positions;
                    // the finger's direct movement does not become a spring.
                    UIView.transition(with: contentView, duration: 0.15,
                                      options: [.transitionCrossDissolve, .beginFromCurrentState, .allowUserInteraction],
                                      animations: restore, completion: restored)
                } else {
                    UIView.animate(springDuration: 0.35, bounce: 0.2, options: [.beginFromCurrentState, .allowUserInteraction],
                                   animations: restore, completion: restored)
                }
            }
            ticked = false
        default:
            break
        }
    }

    /// The card where a finger has moved it by `moved`: there, turned a
    /// little with the sideways part, up to about 8 degrees a card's width out.
    private static func held(_ moved: CGPoint, width: CGFloat) -> CGAffineTransform {
        let lean = max(-1, min(moved.x / width, 1)) * (.pi / 22)
        return CGAffineTransform(translationX: moved.x, y: moved.y).rotated(by: UIAccessibility.isReduceMotionEnabled ? 0 : lean)
    }
}

extension TabOverviewController: SheetContent {
    var scroller: UIScrollView? { collection }
}

// MARK: Moving a tab

extension TabOverviewController: UICollectionViewDragDelegate, UICollectionViewDropDelegate {
    /// A tab's card, lifted from its menu's hold (another device's tabs stay where they are).
    func collectionView(_ collectionView: UICollectionView, itemsForBeginning drag: UIDragSession,
                        at path: IndexPath) -> [UIDragItem] {
        guard case .tab(let id) = source.itemIdentifier(for: path) else { return [] }
        let item = UIDragItem(itemProvider: NSItemProvider())
        item.localObject = id
        return [item]
    }

    func collectionView(_ collectionView: UICollectionView, dragPreviewParametersForItemAt path: IndexPath) -> UIDragPreviewParameters? {
        (collectionView.cellForItem(at: path) as? TabCardCell)?.dragParameters()
    }

    /// Among this space's tabs only, and only a card from this sheet.
    func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate drop: UIDropSession,
                        withDestinationIndexPath path: IndexPath?) -> UICollectionViewDropProposal {
        guard drop.localDragSession != nil, let id = drop.items.first?.localObject as? UUID,
              session.workspace.spaceID(of: id) != nil,
              let path, case .tabs = source.sectionIdentifier(for: path.section) else {
            return UICollectionViewDropProposal(operation: .cancel)
        }
        return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    /// The tab to its new place among the space's others, after its pinned
    /// tabs, a split's two panes together (Workspace.dropIndex); the cards
    /// follow the workspace, as for any other change. A drop that changes
    /// nothing (a pane within its own pair) is let go where it was.
    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        guard let destination = coordinator.destinationIndexPath, let item = coordinator.items.first,
              let id = item.dragItem.localObject as? UUID,
              let origin = session.workspace.spaceID(of: id) else { return }
        if origin != window.spaceID {
            if case .tab(let target) = source.itemIdentifier(for: destination) {
                act(.placeTab(id, before: target))
            } else {
                act(.moveTab(id, window.spaceID))
            }
            coordinator.drop(item.dragItem, toItemAt: destination)
            return
        }
        guard let index = session.workspace.dropIndex(of: id, at: destination.item) else { return }
        session.change { $0.moveTab(id, toIndex: index) }
        coordinator.drop(item.dragItem, toItemAt: destination)
    }
}

/// A button whose touch reaches past what it draws, to 44 points.
final class WideButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let dx = max(0, (44 - bounds.width) / 2)
        let dy = max(0, (44 - bounds.height) / 2)
        return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
    }
}

// MARK: The dock

/// The pinned tabs as the iPhone's dock has its apps: their icons on a capsule
/// of glass at the bottom, floating over the grid as it scrolls, only as wide
/// as the icons need and centred, scrolling sideways when there are more than
/// fit: then the pinned tab on screen is in the middle, as near as the row's
/// ends allow, and with none on screen the row starts at its first. The tab
/// on screen is ringed in the space's colour, as its card is. A tap goes to
/// it; a long press has its menu.
@MainActor
final class PinnedDock: UIView {
    static let height: CGFloat = slot + inset * 2
    private static let slot: CGFloat = 44
    private static let spacing: CGFloat = 4
    /// The same all round, so the capsule's corners follow the slots' circles:
    /// 22 for a slot and 6 around it make the capsule's 28.
    private static let inset: CGFloat = 6

    var chosen: ((UUID) -> Void)?
    var menu: ((TabRecord, UIView) -> UIMenu?)?

    private let platter: UIVisualEffectView
    private let scroller = UIScrollView()
    private var icons: [DockIcon] = []
    private var current: UUID?
    /// The tab on screen has changed and the row is still to be put round it (place).
    private var placing = false

    override init(frame: CGRect) {
        if #available(iOS 26.0, *) {
            platter = UIVisualEffectView(effect: UIGlassEffect())
            platter.cornerConfiguration = .corners(radius: .fixed(Self.height / 2))
        } else {
            platter = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
            platter.layer.cornerRadius = Self.height / 2
            platter.layer.cornerCurve = .continuous
            platter.clipsToBounds = true
        }
        super.init(frame: frame)
        addSubview(platter)
        scroller.showsHorizontalScrollIndicator = false
        scroller.alwaysBounceHorizontal = false
        // The glass draws its capsule but doesn't clip what is on it, so the
        // scroller clips to the same capsule: an icon scrolled to either end
        // goes under the curve, not out past it.
        if #available(iOS 26.0, *) {
            scroller.cornerConfiguration = .corners(radius: .fixed(Self.height / 2))
        }
        scroller.clipsToBounds = true
        platter.contentView.addSubview(scroller)
        accessibilityLabel = String(localized: "Pinned tabs")
        shouldGroupAccessibilityChildren = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// The pinned tabs as they are now, the one on screen marked.
    func show(_ tabs: [TabRecord], current: UUID?, color: UIColor) {
        while icons.count < tabs.count {
            let icon = DockIcon()
            icon.addAction(UIAction { [weak self, weak icon] _ in
                guard let id = icon?.tab?.id else { return }
                self?.chosen?(id)
            }, for: .primaryActionTriggered)
            scroller.addSubview(icon)
            icons.append(icon)
        }
        while icons.count > tabs.count {
            icons.removeLast().removeFromSuperview()
        }
        for (icon, tab) in zip(icons, tabs) {
            icon.configure(tab: tab, current: tab.id == current, color: color)
            icon.menu = menu?(tab, icon)
        }
        if self.current != current { placing = true }
        self.current = current
        setNeedsLayout()
    }

    /// A row longer than the capsule: the tab on screen in its middle, as
    /// near as the row's ends allow, with nothing past either end; with no
    /// pinned tab on screen, from its start. Once the capsule has its width.
    private func place() {
        let room = max(scroller.contentSize.width - scroller.bounds.width, 0)
        let middle = icons.first(where: { $0.tab?.id == current }).map { $0.frame.midX - scroller.bounds.width / 2 } ?? 0
        scroller.contentOffset.x = min(max(middle, 0), room)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let count = CGFloat(icons.count)
        let row = count * Self.slot + max(count - 1, 0) * Self.spacing + Self.inset * 2
        let width = min(row, bounds.width)
        platter.frame = CGRect(x: ((bounds.width - width) / 2).rounded(), y: 0, width: width, height: Self.height)
        scroller.frame = platter.bounds
        for (index, icon) in icons.enumerated() {
            icon.frame = CGRect(x: Self.inset + CGFloat(index) * (Self.slot + Self.spacing), y: Self.inset,
                                width: Self.slot, height: Self.slot)
        }
        scroller.contentSize = CGSize(width: row, height: Self.height)
        if placing, scroller.bounds.width > 0 {
            placing = false
            place()
        }
    }

    /// Only the capsule takes touches: on either side of it the grid under it gets them.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        platter.frame.contains(point)
    }
}

/// One pinned tab in the dock: its site's icon as the site draws it, with no
/// tile or outline of the app's around it, and a ring in the space's colour
/// while it is the tab on screen, its circle following the capsule's corners.
@MainActor
final class DockIcon: UIButton {
    private(set) var tab: TabRecord?
    private let icon = SiteIconUIView()
    private let ring = UIView()
    private let ringStroke = CAShapeLayer()
    /// Under the icon while the tab is open (Pinned.isOpen), as the Mac's
    /// Dock marks an app that is running.
    private let dot = UIView()
    private var color: UIColor = .clear

    override init(frame: CGRect) {
        super.init(frame: frame)
        var plain = UIButton.Configuration.plain()
        plain.contentInsets = .zero
        configuration = plain
        ring.isUserInteractionEnabled = false
        ring.layer.addSublayer(ringStroke)
        addSubview(ring)
        dot.isUserInteractionEnabled = false
        dot.backgroundColor = Palette.UI.ink.withAlphaComponent(0.55)
        dot.layer.cornerRadius = 2
        addSubview(dot)
        icon.size = 28
        icon.isUserInteractionEnabled = false
        addSubview(icon)
        showsMenuAsPrimaryAction = false
        configurationUpdateHandler = { button in
            let still = UIAccessibility.isReduceMotionEnabled
            let pressed = button.isHighlighted && button.isEnabled
            let press = {
                button.transform = pressed && !still ? CGAffineTransform(scaleX: 0.96, y: 0.96) : .identity
                button.alpha = pressed && still ? 0.85 : 1
            }
            if still {
                UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut],
                               animations: press)
            } else {
                UIView.animate(springDuration: 0.3, bounce: 0, options: [.beginFromCurrentState, .allowUserInteraction],
                               animations: press)
            }
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: DockIcon, _) in self.colours() }
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(tab: TabRecord, current: Bool, color: UIColor) {
        self.tab = tab
        self.color = color
        icon.url = tab.url ?? tab.pinned
        ring.isHidden = !current
        let open = Pinned.isOpen(tab)
        dot.isHidden = !open
        setNeedsLayout()
        colours()
        accessibilityLabel = String(localized: "\(tab.label), pinned")
        accessibilityValue = open ? String(localized: "Open") : nil
        accessibilityTraits = current ? [.button, .selected] : .button
    }

    private func colours() {
        ringStroke.strokeColor = color.resolvedColor(with: traitCollection).cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        ring.frame = bounds
        icon.frame = bounds.insetBy(dx: (bounds.width - 28) / 2, dy: (bounds.height - 28) / 2)
        // In the gap under the icon, where the ring runs: the ring stops
        // short of it on either side, its ends rounded, so the two never touch.
        dot.frame = CGRect(x: bounds.midX - 2, y: icon.frame.maxY + 2, width: 4, height: 4)
        drawRing()
    }

    /// The ring as a stroke of its own: whole, or open at the foot round the dot.
    private func drawRing() {
        let width: CGFloat = 2
        let radius = (min(bounds.width, bounds.height) - width) / 2
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        // Half the dot and some air either side, and the rounded end's own half width.
        let half = dot.isHidden ? 0 : (dot.bounds.width / 2 + 4 + width / 2) / radius
        let down = CGFloat.pi / 2
        ringStroke.path = UIBezierPath(arcCenter: centre, radius: radius, startAngle: down + half,
                                       endAngle: down - half + 2 * .pi, clockwise: true).cgPath
        ringStroke.lineWidth = width
        ringStroke.lineCap = .round
        ringStroke.fillColor = nil
        ringStroke.frame = ring.bounds
    }

    /// The menu lifts the icon on a disc of its own, not the glass around it.
    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                         previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(ovalIn: bounds)
        parameters.backgroundColor = Palette.UI.card
        return UITargetedPreview(view: self, parameters: parameters)
    }
}

/// The space's button at the top of the phone's tabs, with its name, as
/// the bars have it for a thumb: its menu goes to the other spaces, whose
/// tabs the sheet then shows, and has New Space and the space's settings.
private struct SpaceHeading: View {
    @ObservedObject var session: Session
    let window: WindowModel
    let act: (BarAction) -> Void

    var body: some View {
        SpaceButton(session: session, window: window, act: act, nameRoom: 220)
            .fixedSize()
            .environment(\.barScale, .thumb)
    }
}
