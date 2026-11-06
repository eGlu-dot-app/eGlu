import Foundation

/// Durable deletion, composed into the runtime by the last hub slice.
/// The app calls removal only after its catalog permits the deletion.
@MainActor public protocol WebExtensionCleanup: AnyObject {
    func remove(_ id: String, from space: UUID)
    func removePackages(_ id: String, afterClearing spaces: [UUID])
    @discardableResult func forget(_ id: String, in space: UUID) -> Task<Void, Never>
    func forgetLeftOver()
    @discardableResult func cleared(_ id: String, in space: UUID) async -> Bool
    func removeSpace(_ space: UUID)
    func closePages(of id: String, in space: UUID)
}
