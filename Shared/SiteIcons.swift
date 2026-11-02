import PadCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A picture as each platform draws one.
#if os(macOS)
typealias SiteImage = NSImage
#else
typealias SiteImage = UIImage
#endif

/// Sites' icons, for pinned tabs, tabs and bookmark tiles.
///
/// A page names its icons (bridge.js siteIcons()), the site's own first, as
/// browsers show it; the first of them that loads as a picture is kept, once
/// for the whole site, in the app's data folder (Session.folder), and a
/// bookmarks file's own icons (Chrome's) are kept the same way. Files are
/// written and removed away from the main thread, one at a time and in
/// order, and an icon is announced once its file is written. An icon drawn as SVG is drawn into a
/// picture by WebKit (SVGRaster), and a second time in its dark look where
/// it has one, which a dark screen shows. The app fetches them itself, not
/// the page, with no cookies and nothing kept by the system, and only ever
/// takes a picture back. A site without one shows its first letter
/// (SiteIconView).
///
/// Icons kept before the site's own came first (Apple's touch icons did,
/// and SVG was passed over) are in a folder of their own: one shows until
/// its site is next opened, and that site's icon is then chosen again.
@MainActor
final class SiteIcons: ObservableObject {
    // The app's own store (`shared`) is made where the app's data folder is
    // known: each platform's Session.swift.

    /// Moves on each time an icon arrives, so the views showing it look again.
    @Published private(set) var revision = 0
    private var known: [String: SiteImage] = [:]
    /// Chosen the way icons are chosen now: found in today's folder, or
    /// kept this run. The others came from the former folder.
    private var current: Set<String> = []
    /// Looked for on disk and not there: not looked for again this run.
    private var absent: Set<String> = []
    private var fetching: Set<String> = []
    /// Sites none of whose icons loaded this run: not tried again until the next.
    private var failed: Set<String> = []
    /// Whether each site's icon is a dark shape on clear (darkShape), read once a picture.
    private var darkShapes: [String: Bool] = [:]

    /// After a site's key, the name its dark look is kept under.
    nonisolated private static let darkMark = "~dark"

    /// The pixel size kept: sharp at 48 points, the largest the app draws.
    nonisolated private static let side: CGFloat = 96

    private let folder: URL
    private let formerFolder: URL
    /// Where icons were kept before, in the Caches folder, which the system
    /// may empty: read, and copied into the data folder, as they are found.
    private let cachedFolders: (current: URL, former: URL)?

    /// `data` is the app's data folder; `caches` the Caches folder icons
    /// were kept in before, or nil to leave it alone (a Mac test copy's,
    /// whose Caches folder is the real app's).
    init(data: URL, caches: URL?) {
        folder = data.appendingPathComponent("Icons", isDirectory: true)
        formerFolder = data.appendingPathComponent("SiteIcons", isDirectory: true)
        cachedFolders = caches.map {
            ($0.appendingPathComponent("Safience/Icons", isDirectory: true),
             $0.appendingPathComponent("Safience/SiteIcons", isDirectory: true))
        }
    }

    private var locations: [(folder: URL, current: Bool)] {
        var locations = [(folder, true)]
        if let cachedFolders { locations.append((cachedFolders.current, true)) }
        locations.append((formerFolder, false))
        if let cachedFolders { locations.append((cachedFolders.former, false)) }
        return locations
    }

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        let name = Identity.applicationName(for: ProcessInfo.processInfo.operatingSystemVersion)
        configuration.httpAdditionalHeaders = ["User-Agent": Identity.macUserAgent(applicationName: name)]
        return URLSession(configuration: configuration)
    }()

    /// The site's icon, if it has one yet: on a dark screen, its dark look
    /// where it drew one.
    func image(for url: URL?, dark: Bool = false) -> SiteImage? {
        guard let key = IconKey.of(url) else { return nil }
        if dark, let image = stored(key + Self.darkMark) { return image }
        return stored(key)
    }

    /// Whether the site's icon is still to be chosen: it has none, or one
    /// chosen the former way.
    func needs(_ url: URL?) -> Bool {
        guard let key = IconKey.of(url) else { return false }
        _ = stored(key)
        return !current.contains(key)
    }

    /// Whether the site's icon would be lost on a dark screen and is shown
    /// there on a light ground, as Safari shows one: a dark shape on clear
    /// (GitHub's drawn cat), with no dark look of its own.
    func needsLightGround(_ url: URL?, dark: Bool) -> Bool {
        guard dark, let key = IconKey.of(url), stored(key + Self.darkMark) == nil, let image = stored(key) else { return false }
        if let read = darkShapes[key] { return read }
        let read = Self.isDarkShape(image)
        darkShapes[key] = read
        return read
    }

    /// Most of the picture's outer edge clear, and what is drawn dark: under
    /// a third of the way to white on average.
    nonisolated private static func isDarkShape(_ image: SiteImage) -> Bool {
        #if os(macOS)
        guard let picture = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        #else
        guard let picture = image.cgImage else { return false }
        #endif
        let side = 32
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(picture, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return false }
        var ring = 0, edge = 0, solid = 0, light = 0.0
        for y in 0..<side {
            for x in 0..<side {
                let i = (y * side + x) * 4
                let alpha = Double(bytes[i + 3]) / 255
                let onEdge = x < 2 || x >= side - 2 || y < 2 || y >= side - 2
                if onEdge { ring += 1 }
                guard alpha >= 0.5 else { continue }
                if onEdge { edge += 1 }
                solid += 1
                // Premultiplied: divided back out.
                let r = Double(bytes[i]) / 255 / alpha, g = Double(bytes[i + 1]) / 255 / alpha, b = Double(bytes[i + 2]) / 255 / alpha
                light += 0.2126 * r + 0.7152 * g + 0.0722 * b
            }
        }
        guard solid > 0 else { return false }
        return Double(edge) / Double(ring) < 0.5 && light / Double(solid) < 0.33
    }

    private func stored(_ name: String) -> SiteImage? {
        if let image = known[name] { return image }
        guard !absent.contains(name) else { return nil }
        for (location, now) in locations {
            guard let file = Self.file(for: name, in: location), let data = try? Data(contentsOf: file),
                  let image = SiteImage(data: data)
            else { continue }
            // Found where it was kept before: copied over, without waiting for the disk.
            let destination = now ? folder : formerFolder
            if location != destination, let copy = Self.file(for: name, in: destination) {
                Self.disk.async { Self.write(data, to: copy) }
            }
            known[name] = image
            if now { current.insert(name) }
            return image
        }
        absent.insert(name)
        return nil
    }

    /// The icons a page named, best first: the first that loads as a picture
    /// is kept, unless the site has one chosen as icons are now.
    func learn(_ candidates: [URL], for page: URL?) {
        guard let key = IconKey.of(page), needs(page), !fetching.contains(key), !failed.contains(key), !candidates.isEmpty
        else { return }
        fetching.insert(key)
        Task {
            defer { fetching.remove(key) }
            for candidate in candidates.prefix(6) {
                if let fetched = await fetch(candidate) {
                    var changes = [keep(fetched.light, as: key)]
                    if let dark = fetched.dark { changes.append(keep(dark, as: key + Self.darkMark)) }
                    await Self.save(changes)
                    revision += 1
                    return
                }
            }
            failed.insert(key)
        }
    }

    /// The icons a bookmarks file carried, for the sites that have none yet.
    ///
    /// Decoded and squared away from the main thread, then taken in
    /// together: a file can carry hundreds, and each used to be decoded,
    /// drawn and announced one at a time on it.
    func adopt(_ icons: [String: Data]) {
        let wanted = icons.filter { _ = stored($0.key); return !current.contains($0.key) }
        guard !wanted.isEmpty else { return }
        Task {
            let shaped = await Task.detached(priority: .utility) {
                wanted.compactMap { key, data in
                    SiteImage(data: data).flatMap(Self.prepared).map { (key: key, picture: $0) }
                }
            }.value
            let changes = shaped.filter { !current.contains($0.key) }.map { keep($0.picture, as: $0.key) }
            guard !changes.isEmpty else { return }
            await Self.save(changes)
            revision += 1
        }
    }

    private struct Picture {
        let image: SiteImage
        let png: Data
    }

    /// An icon as a picture, and its dark look where it is a drawing with one.
    private struct Fetched {
        let light: Picture
        let dark: Picture?
    }

    private func fetch(_ url: URL) async -> Fetched? {
        let data: Data
        var declaredSVG = false
        if url.scheme?.lowercased() == "data" {
            guard let bytes = try? Data(contentsOf: url) else { return nil }
            data = bytes
            declaredSVG = url.absoluteString.lowercased().hasPrefix("data:image/svg")
        } else {
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            var request = URLRequest(url: url)
            request.httpShouldHandleCookies = false
            guard let (bytes, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200, bytes.count < 2_000_000
            else { return nil }
            data = bytes
            declaredSVG = response.mimeType?.lowercased().contains("svg") == true
        }
        // A drawing goes to WebKit, never to NSImage, which would draw it without its dark look.
        if declaredSVG || Self.looksLikeSVG(data) {
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            let raster = SVGRaster.shared
            guard let light = await raster.picture(of: text, side: Int(Self.side), dark: false)
            else { return nil }
            let dark = SVGRaster.hasDarkLook(text)
                ? await raster.picture(of: text, side: Int(Self.side), dark: true) : nil
            return await Task.detached(priority: .utility) {
                guard let light = Self.prepared(light) else { return nil as Fetched? }
                return Fetched(light: light, dark: dark.flatMap(Self.prepared))
            }.value
        }
        return await Task.detached(priority: .utility) {
            guard let picture = SiteImage(data: data).flatMap(Self.prepared) else { return nil as Fetched? }
            return Fetched(light: picture, dark: nil)
        }.value
    }

    /// An SVG file whatever its server called it: `<svg` near its start.
    nonisolated private static func looksLikeSVG(_ data: Data) -> Bool {
        guard let head = String(data: data.prefix(1024), encoding: .utf8) ?? String(data: data.prefix(1023), encoding: .utf8)
        else { return false }
        return head.range(of: "<svg", options: .caseInsensitive) != nil
    }

    /// What the disk is told for an icon taken in: its file written, and
    /// the files of a dark look it replaces removed.
    nonisolated private struct Change: Sendable {
        let png: Data
        let file: URL?
        let removed: [URL]
    }

    /// The icon taken in for this run at once; its file is left to `save`.
    private func keep(_ picture: Picture, as key: String) -> Change {
        known[key] = picture.image
        darkShapes[key] = nil
        current.insert(key)
        absent.remove(key)
        // A site's new icon puts away the dark look of its last, if it had one.
        var removed: [URL] = []
        if !key.hasSuffix(Self.darkMark) {
            let dark = key + Self.darkMark
            known[dark] = nil
            current.remove(dark)
            absent.insert(dark)
            removed = locations.compactMap { Self.file(for: dark, in: $0.folder) }
        }
        return Change(png: picture.png, file: Self.file(for: key, in: folder), removed: removed)
    }

    /// The disk's work, in the order it was asked for, away from the main
    /// thread: a bookmarks file can bring hundreds of icons at once.
    nonisolated private static let disk = DispatchQueue(label: "SiteIcons.disk", qos: .utility)

    /// The changes' files written and removed, in order; back once they are.
    private static func save(_ changes: [Change]) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            disk.async {
                for change in changes {
                    for file in change.removed { try? FileManager.default.removeItem(at: file) }
                    if let file = change.file { write(change.png, to: file) }
                }
                done.resume()
            }
        }
    }

    /// Back once everything asked of the disk so far is done: for the tests.
    func settled() async {
        await Self.save([])
    }

    nonisolated private static func write(_ data: Data, to file: URL) {
        let folder = file.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Re-creatable, but not purgeable: icons survive restarts without enlarging device backups.
            var marked = folder
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? marked.setResourceValues(values)
            try data.write(to: file, options: .atomic)
        } catch {
            // An unwritable disk must not stop a loaded icon from showing this run.
        }
    }

    nonisolated private static func prepared(_ picture: SiteImage) -> Picture? {
        guard let image = shaped(picture), let png = png(image) else { return nil }
        return Picture(image: image, png: png)
    }

    /// Squared and scaled to the size kept; nil for a picture too small to
    /// be anything but a speck.
    nonisolated private static func shaped(_ picture: SiteImage) -> SiteImage? {
        let size = picture.size
        guard size.width >= 16, size.height >= 16 else { return nil }
        let scale = min(side / size.width, side / size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        let place = CGRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2, width: drawn.width, height: drawn.height)
        #if os(macOS)
        // Drawn into pixels of its own, one to a point: an NSImage made by
        // drawing would be drawn again, at the screen's scale, each time it shows.
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        picture.draw(in: place)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: CGSize(width: side, height: side))
        image.addRepresentation(bitmap)
        return image
        #else
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            picture.draw(in: place)
        }
        #endif
    }

    /// The picture as a PNG file's bytes, to keep.
    nonisolated private static func png(_ picture: SiteImage) -> Data? {
        #if os(macOS)
        guard let image = picture.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        #else
        picture.pngData()
        #endif
    }

    /// A host only ever becomes a file name of letters, digits, dots and
    /// dashes, and a dark look's has its mark after it.
    nonisolated private static func file(for key: String, in folder: URL) -> URL? {
        let host = key.hasSuffix(darkMark) ? String(key.dropLast(darkMark.count)) : key
        guard !host.isEmpty, host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
        else { return nil }
        return folder.appendingPathComponent(key + ".png")
    }
}
