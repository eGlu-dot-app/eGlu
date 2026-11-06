import Foundation

/// Page notifications and popup membership without exposing adapter types.
@MainActor public protocol WebExtensionAdapters: AnyObject {
    func addressChanged(_ page: any WebMacPage, tab: UUID, in space: UUID)
    func loadingChanged(tab: UUID, in space: UUID)
    func popupShows(_ page: any WebMacPage) -> Bool
}
