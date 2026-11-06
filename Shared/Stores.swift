import Foundation
import ImageIO
import PadCore
import WebEngineCore
#if canImport(UIKit)
import UIKit
#endif

/// Records removed spaces' stores until the engine can remove them from disk.
@MainActor
enum Stores {
    private static let erasingKey = "stores.erasing"

    /// A removed space's store, and everything in it, gone. What it holds is
    /// emptied at once; the store itself WebKit won't remove while a view
    /// still holds it, so it is written down and tried again at each launch
    /// until it goes.
    static func erase(_ space: UUID, in stores: any WebSpaceStores) {
        stores.forget(space)
        var pending = Set(UserDefaults.standard.stringArray(forKey: erasingKey) ?? [])
        pending.insert(space.uuidString)
        UserDefaults.standard.set(pending.sorted(), forKey: erasingKey)
        // A moment later, once the space's views have let go.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { sweep(in: stores) }
    }

    /// Removes the stores written down for removal. At launch, before any
    /// view holds one, and after an erase.
    static func sweep(in stores: any WebSpaceStores) {
        let pending = UserDefaults.standard.stringArray(forKey: erasingKey) ?? []
        guard !pending.isEmpty else { return }
        stores.prepareForRemoval()
        for text in pending {
            guard let id = UUID(uuidString: text), !stores.isMade(id) else { continue }
            stores.remove(id) { removed in
                guard removed else { return }
                Task { @MainActor in
                    let left = (UserDefaults.standard.stringArray(forKey: erasingKey) ?? []).filter { $0 != text }
                    UserDefaults.standard.set(left, forKey: erasingKey)
                }
            }
        }
    }
}

/// Pictures of frozen tabs, and what it takes to bring their page back where
/// it was (the engine's restoration data, WebKit's interaction state: the
/// back and forward list and the scroll position). Kept in Caches: the system may empty it, and then a
/// tab comes back without its picture, at its address. Files only, read and
/// written on its own queue: no actor's.
nonisolated enum Snapshots {
    static var folder: URL {
        var caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        #if os(macOS)
        // Outside the sandbox the Mac's Caches folder is every app's:
        // eGlu's go in a folder of its own.
        caches.appendPathComponent(Bundle.main.bundleIdentifier ?? "Safience", isDirectory: true)
        #endif
        return caches.appendingPathComponent("Snapshots", isDirectory: true)
    }

    private static let files = PageSnapshotFiles(folder: folder)
    private static let pictures = DispatchQueue(label: "SnapshotPictures", qos: .utility)

    static func token(for tab: UUID, in space: UUID) -> PageSnapshotFiles.Token {
        files.token(for: tab, in: space)
    }

    static func isCurrent(_ token: PageSnapshotFiles.Token) -> Bool { files.isCurrent(token) }

    #if canImport(UIKit)
    static func save(_ picture: UIImage, url: URL?, using token: PageSnapshotFiles.Token) {
        pictures.async {
            guard files.isCurrent(token), let data = picture.jpegData(compressionQuality: 0.7) else { return }
            files.save(data, kind: .picture, url: url, using: token)
        }
    }

    static func picture(url: URL?, using token: PageSnapshotFiles.Token) -> UIImage? {
        files.data(kind: .picture, url: url, using: token).flatMap(UIImage.init(data:))
    }

    static func picture(url: URL?, using token: PageSnapshotFiles.Token,
                        _ done: @escaping @MainActor @Sendable (UIImage?) -> Void) {
        pictures.async {
            let image = picture(url: url, using: token)?.preparingForDisplay()
            DispatchQueue.main.async { done(files.isCurrent(token) ? image : nil) }
        }
    }

    static func thumbnail(url: URL?, using token: PageSnapshotFiles.Token, pixels: Int,
                          _ done: @escaping @MainActor @Sendable (UIImage?) -> Void) {
        pictures.async {
            var image: UIImage?
            if let data = files.data(kind: .picture, url: url, using: token),
               let source = CGImageSourceCreateWithData(data as CFData, nil) {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixels,
                ]
                image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
            }
            let made = image
            DispatchQueue.main.async { done(files.isCurrent(token) ? made : nil) }
        }
    }
    #endif

    static func save(state: Any?, url: URL?, using token: PageSnapshotFiles.Token) {
        guard let data = state as? Data else { return }
        files.save(data, kind: .state, url: url, using: token)
    }

    static func takeState(url: URL?, using token: PageSnapshotFiles.Token) -> Data? {
        files.takeState(url: url, using: token)
    }

    static func remove(_ tab: UUID) { files.invalidate(tab) }
    static func prune(keeping tabs: Set<UUID>) { files.prune(keeping: tabs) }
}
