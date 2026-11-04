import Foundation
import os

/// Disposable page state, isolated by space and tab. Every disk operation
/// runs on one serial queue, including synchronous consumption, so a read
/// comes after every write submitted before it. Generations (which token is
/// current) are under a lock of their own: a token, a check or an
/// invalidation never waits for the disk.
public final class PageSnapshotFiles: @unchecked Sendable {
    public enum Kind: String, Sendable { case state, picture }

    public struct Token: Equatable, Sendable {
        public let space: UUID
        public let tab: UUID
        fileprivate let generation: UUID
    }

    private struct Record: Codable {
        let url: URL?
        let data: Data
    }

    private let folder: URL
    private let queue: DispatchQueue
    private let generations = OSAllocatedUnfairLock<[UUID: UUID]>(initialState: [:])
    /// Each tab's files by name, read from the folder once, on the queue
    /// the first time it is wanted, and kept up as files are written and
    /// removed: an invalidation removes its tab's files without going
    /// through every file in the folder. Only used on the queue.
    private var held: [UUID: Set<String>]?

    public convenience init(folder: URL) {
        self.init(folder: folder, queue: DispatchQueue(label: "PageSnapshotFiles", qos: .utility))
    }

    /// The disk's queue given: a test's, to hold it still.
    init(folder: URL, queue: DispatchQueue) {
        self.folder = folder
        self.queue = queue
    }

    public func token(for tab: UUID, in space: UUID) -> Token {
        generations.withLock { generations in
            let generation = generations[tab] ?? UUID()
            generations[tab] = generation
            return Token(space: space, tab: tab, generation: generation)
        }
    }

    public func isCurrent(_ token: Token) -> Bool {
        current(token)
    }

    /// A callback from before a move, close, or navigation cannot recreate data.
    public func save(_ data: Data, kind: Kind, url: URL?, using token: Token) {
        queue.async {
            guard self.current(token),
                  let encoded = try? PropertyListEncoder().encode(Record(url: url, data: data)) else { return }
            try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
            let file = self.file(token, kind)
            guard (try? encoded.write(to: file, options: .atomic)) != nil else { return }
            self.hold(file.lastPathComponent, for: token.tab)
        }
    }

    public func data(kind: Kind, url: URL?, using token: Token) -> Data? {
        queue.sync { read(kind: kind, url: url, using: token) }
    }

    /// A thawed page owns its back/forward state in WebKit. Consuming the disk
    /// copy prevents an earlier frozen navigation from winning after relaunch.
    /// Waiting on the same queue also consumes any write already submitted.
    public func takeState(url: URL?, using token: Token) -> Data? {
        queue.sync {
            guard current(token) else { return nil }
            let state = read(kind: .state, url: url, using: token)
            // Restoring is safe only once its stale disk copy is gone.
            let file = file(token, .state)
            do { try FileManager.default.removeItem(at: file) }
            catch { return nil }
            readHeld()
            held?[token.tab]?.remove(file.lastPathComponent)
            return state
        }
    }

    /// At once, every earlier token stops being current, so a write still
    /// waiting is let go of and a later one fails. The tab's files go on
    /// the queue, after what was written before: any read comes after them.
    public func invalidate(_ tab: UUID) {
        // The removal queued under the lock: a token taken after this one
        // is new, so whatever reads or writes with it is queued after the removal.
        generations.withLock { generations in
            generations[tab] = UUID()
            queue.async {
                self.readHeld()
                for name in self.held?.removeValue(forKey: tab) ?? [] {
                    try? FileManager.default.removeItem(at: self.folder.appendingPathComponent(name))
                }
            }
        }
    }

    /// Legacy tab-only files have no trustworthy space identity and are removed.
    public func prune(keeping tabs: Set<UUID>) {
        queue.async {
            guard let names = self.names() else { return }
            var kept: [UUID: Set<String>] = [:]
            for name in names {
                if let tab = self.tabID(in: name), tabs.contains(tab) {
                    kept[tab, default: []].insert(name)
                    continue
                }
                try? FileManager.default.removeItem(at: self.folder.appendingPathComponent(name))
            }
            self.held = kept
        }
    }

    private func current(_ token: Token) -> Bool {
        generations.withLock { $0[token.tab] == token.generation }
    }

    private func file(_ token: Token, _ kind: Kind) -> URL {
        folder.appendingPathComponent("\(token.space.uuidString).\(token.tab.uuidString).\(kind.rawValue)")
    }

    private func read(kind: Kind, url: URL?, using token: Token) -> Data? {
        guard current(token), let data = try? Data(contentsOf: file(token, kind)),
              let record = try? PropertyListDecoder().decode(Record.self, from: data),
              record.url == url else { return nil }
        return record.data
    }

    /// Each tab's files, the folder read for them the first time. On the
    /// queue only. A folder that couldn't be read (other than one not made
    /// yet) is read again next time, not taken to be empty.
    private func readHeld() {
        guard held == nil, let listed = names() else { return }
        var tabs: [UUID: Set<String>] = [:]
        for name in listed {
            if let tab = tabID(in: name) ?? legacyTabID(in: name) { tabs[tab, default: []].insert(name) }
        }
        held = tabs
    }

    private func hold(_ name: String, for tab: UUID) {
        readHeld()
        held?[tab, default: []].insert(name)
    }

    /// The folder's files; none in a folder not made yet, nil in one that couldn't be read.
    private func names() -> [String]? {
        do { return try FileManager.default.contentsOfDirectory(atPath: folder.path) }
        catch { return FileManager.default.fileExists(atPath: folder.path) ? nil : [] }
    }

    private func tabID(in name: String) -> UUID? {
        let parts = name.split(separator: ".")
        guard parts.count == 3, UUID(uuidString: String(parts[0])) != nil,
              Kind(rawValue: String(parts[2])) != nil else { return nil }
        return UUID(uuidString: String(parts[1]))
    }

    /// A file from before files were kept by space: the tab's state or picture.
    private func legacyTabID(in name: String) -> UUID? {
        let parts = name.split(separator: ".")
        guard parts.count == 2, ["state", "jpg"].contains(String(parts[1])) else { return nil }
        return UUID(uuidString: String(parts[0]))
    }
}
