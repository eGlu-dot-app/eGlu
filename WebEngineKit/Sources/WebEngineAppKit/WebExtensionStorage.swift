import Foundation

/// App-owned locations. Prepared folders are made beside their destination,
/// not under the temporary root, so the final move stays on the same volume.
public struct WebExtensionStorageEnvironment: Sendable {
    public let root: URL
    public let temporaryRoot: URL

    public init(root: URL, temporaryRoot: URL) {
        self.root = root
        self.temporaryRoot = temporaryRoot
    }
}

/// The storage part of the extension runtime. Catalog persistence stays in
/// the app. Path queries stay on its main actor; preparation is synchronous
/// and nonisolated, called on the app's existing detached tasks.
public protocol WebExtensionStorage: AnyObject, Sendable {
    @MainActor func package(_ id: String, _ version: String) -> URL
    @MainActor func prepared(_ id: String, _ version: String) -> URL
    @MainActor var recordsFile: URL { get }
    nonisolated func prepare(_ package: URL, into folder: URL) throws
}
