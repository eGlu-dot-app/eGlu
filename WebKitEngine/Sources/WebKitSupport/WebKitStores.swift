import Foundation
import WebKit

/// Each space's cookies, sign-ins and site data, in a WebKit store of its own.
///
/// Made with `WKWebsiteDataStore(forIdentifier:)` and the space's id, so a
/// space's sign-ins survive relaunches and never mix with another space's:
/// two Figma accounts, one per space, both signed in. One object per space
/// for as long as the app runs, because WebKit shares processes and caches
/// between views that are given the same store object.
@MainActor
public enum WebKitStores {
    private static var made: [UUID: WKWebsiteDataStore] = [:]

    /// The space's store, one object per space for as long as the app runs.
    public static func store(for space: UUID) -> WKWebsiteDataStore {
        if let store = made[space] { return store }
        let store = WKWebsiteDataStore(forIdentifier: space)
        made[space] = store
        return store
    }

    /// Whether the space's store was made this run.
    public static func isMade(_ space: UUID) -> Bool { made[space] != nil }

    /// Lets go of the space's store, emptying what it holds now (no-op if it was never made).
    public static func forget(_ space: UUID) {
        if let store = made.removeValue(forKey: space) {
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        }
    }

    /// WebKit is set up first, by making a store of its own that keeps
    /// nothing: `remove(forIdentifier:)` doesn't do that itself, and called
    /// before anything else of WebKit's at launch, it answered on a run loop
    /// WebKit hadn't made yet and stopped the app, at every launch while the
    /// removal stayed written down (iOS 27.1).
    public static func prepareForRemoval() {
        _ = WKWebsiteDataStore.nonPersistent()
    }

    /// Removes the space's store from disk; `removed` hears true once it is gone.
    public static func remove(_ space: UUID, removed: @escaping @MainActor (Bool) -> Void) {
        WKWebsiteDataStore.remove(forIdentifier: space) { error in
            guard error == nil else { return removed(false) }
            removed(true)
        }
    }
}
