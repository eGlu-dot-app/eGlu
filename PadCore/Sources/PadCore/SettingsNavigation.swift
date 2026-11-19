import Foundation

/// One route for the sidebar and the narrow Settings stack, including search reveals.
public struct SettingsNavigation: Equatable, Sendable {
    public enum Page: Hashable, Sendable {
        case group(SettingsGroup)
        case acknowledgements
        case spaces, space(UUID), pinnedTabs, writingRules, ownMenuSites, filterLists
    }

    public var path: [Page] = [] {
        didSet {
            if path.first != oldValue.first {
                anchor = nil
                requestID = nil
            }
        }
    }
    public private(set) var anchor: SettingsAnchor?
    public private(set) var requestID: UUID?
    public var selection: Page? { path.first }

    /// The wide detail stack omits the category shown at its root.
    public var detailPath: [Page] {
        get { Array(path.dropFirst()) }
        set { path = Array(path.prefix(1)) + newValue }
    }

    public init() {}

    /// The presented Settings width, not the display's: narrow floating windows stay a stack.
    public static func usesSidebar(pad: Bool, width: CGFloat) -> Bool {
        pad && width >= 800
    }

    public mutating func show(_ page: Page) {
        path = [page]
        anchor = nil
        requestID = UUID()
    }

    public mutating func reveal(_ anchor: SettingsAnchor) {
        path = [.group(anchor.group)]
        self.anchor = anchor
        requestID = UUID()
    }

    public mutating func adapt(sidebar: Bool) {
        if sidebar && path.isEmpty { show(.group(.general)) }
    }
}
