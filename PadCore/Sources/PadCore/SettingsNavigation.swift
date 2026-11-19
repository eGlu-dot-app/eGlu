import Foundation

/// One route for the sidebar and the narrow Settings stack, including search reveals.
public struct SettingsNavigation: Equatable, Sendable {
    public enum Page: Hashable, Sendable {
        case group(SettingsGroup)
        case acknowledgements
    }

    public var path: [Page] = [] {
        didSet {
            if path != oldValue {
                anchor = nil
                revealID = nil
            }
        }
    }
    public private(set) var anchor: SettingsAnchor?
    public private(set) var revealID: UUID?
    public var selection: Page? { path.last }

    public init() {}

    /// The presented Settings width, not the display's: narrow floating windows stay a stack.
    public static func usesSidebar(pad: Bool, width: CGFloat) -> Bool {
        pad && width >= 800
    }

    public mutating func show(_ page: Page) {
        path = [page]
        anchor = nil
        revealID = nil
    }

    public mutating func reveal(_ anchor: SettingsAnchor) {
        path = [.group(anchor.group)]
        self.anchor = anchor
        revealID = UUID()
    }

    public mutating func adapt(sidebar: Bool) {
        if sidebar && path.isEmpty { show(.group(.general)) }
    }
}
