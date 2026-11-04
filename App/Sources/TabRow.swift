import Combine
import PadCore
import UIKit

// What the tabs along the top (TopTabs) and the sidebar (SideTabs) share
// of a space's row: its tabs as they stand, pinned and not, a split's two
// as one place (TabRow), their widths being TabWidths'; and a site's icon for UIKit's views (the tab
// overview's cards, a page's stand-in), as SiteIconView draws it.

/// A site's icon as SiteIcons has it, or its first letter on the space's
/// colour until it does: SiteIconView, for UIKit.
@MainActor
final class SiteIconUIView: UIView {
    var url: URL? {
        didSet { if url != oldValue { refresh() } }
    }

    var size: CGFloat = 16 {
        didSet { if size != oldValue { setNeedsLayout() } }
    }

    private let image = UIImageView()
    private let letter = UILabel()
    private var watching: AnyCancellable?
    private var lightGround = false {
        didSet { if lightGround != oldValue { setNeedsLayout() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        layer.cornerCurve = .continuous
        // No outline: a site's icon already has its own shape, often a
        // rounded square or a mark on nothing, and a second edge around it
        // reads as a frame.
        image.contentMode = .scaleAspectFit
        addSubview(image)
        letter.textAlignment = .center
        addSubview(letter)
        isAccessibilityElement = false
        watching = SiteIcons.shared.$revision.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }
        // A drawn icon's dark look, as the screen turns dark, and back; a
        // letter's colour, as the window shows another space.
        registerForTraitChanges([UITraitUserInterfaceStyle.self, SpaceColorTrait.self]) { (self: Self, _: UITraitCollection) in
            self.refresh()
        }
        refresh()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = size * 0.225
        image.frame = lightGround ? bounds.insetBy(dx: size * 0.14, dy: size * 0.14) : bounds
        letter.frame = bounds
        letter.font = .systemFont(ofSize: size * 0.56, weight: .semibold).rounded
    }

    private func refresh() {
        let dark = traitCollection.userInterfaceStyle == .dark
        if let found = SiteIcons.shared.image(for: url, dark: dark) {
            image.image = found
            image.isHidden = false
            letter.isHidden = true
            // A dark shape on clear, on a dark screen: on a light ground, as Safari shows it.
            lightGround = SiteIcons.shared.needsLightGround(url, dark: dark)
            backgroundColor = lightGround ? UIColor.white.withAlphaComponent(0.92) : .clear
        } else {
            lightGround = false
            image.isHidden = true
            letter.isHidden = false
            letter.text = host.first.map { String($0).uppercased() } ?? "•"
            let space = traitCollection.spaceColor
            letter.textColor = UIColor(space.ink)
            backgroundColor = space.uiColor
        }
    }

    private var host: String {
        guard let host = url?.host() else { return "" }
        return Destination.registrable(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
    }
}

private extension UIFont {
    var rounded: UIFont {
        fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: pointSize) } ?? self
    }
}

// MARK: The row

/// A space's tabs as a row shows them: the pinned ones, then the others,
/// one at a time or a split's two together.
struct TabRow {
    let pinned: [TabRecord]
    let others: [TabRecord]
    let splits: [Split]
    /// The ordinary tabs as the row shows them: one at a time, or a split's
    /// two together.
    let items: [TabItem]
    /// The tabs in a split.
    let paired: Set<UUID>
    let current: TabRecord?

    init(tabs: [TabRecord], splits: [Split], current id: UUID?, barTabs: Set<UUID> = []) {
        let ordinary = tabs.filter { !$0.isPinned && !barTabs.contains($0.id) }
        pinned = tabs.filter(\.isPinned)
        others = ordinary
        self.splits = splits
        paired = Set(splits.flatMap { [$0.left, $0.right] })
        var items: [TabItem] = []
        var index = 0
        while index < ordinary.count {
            let tab = ordinary[index]
            let next = index + 1 < ordinary.count ? ordinary[index + 1].id : nil
            if let next, splits.contains(where: { $0.left == tab.id && $0.right == next }) {
                items.append(TabItem(tabs: [tab, ordinary[index + 1]]))
                index += 2
            } else {
                items.append(TabItem(tabs: [tab]))
                index += 1
            }
        }
        self.items = items
        current = tabs.first { $0.id == id }
    }
}

/// One tab of the row, or a split's two shown as one.
struct TabItem: Identifiable {
    let tabs: [TabRecord]

    var id: UUID {
        tabs.first?.id ?? UUID()
    }
}
