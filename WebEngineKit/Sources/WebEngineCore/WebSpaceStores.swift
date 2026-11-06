import Foundation

/// The engine's website data, one store per space, kept on disk until the
/// app has it removed (Stores, which keeps the list of stores to remove).
@MainActor public protocol WebSpaceStores: AnyObject, Sendable {
    /// Whether the space's store was made this run.
    func isMade(_ space: UUID) -> Bool
    /// Lets go of the space's store, emptying what it holds now.
    func forget(_ space: UUID)
    /// Readies the engine for removals.
    func prepareForRemoval()
    /// Removes the space's store from disk; `removed` hears true once it is gone.
    func remove(_ space: UUID, removed: @escaping @MainActor (Bool) -> Void)
}
