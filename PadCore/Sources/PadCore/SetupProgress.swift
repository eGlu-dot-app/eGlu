import Foundation

/// Local first-run progress, separate from the synced workspace. Step names
/// are stable on disk; adding an optional step must not renumber saved ones.
public struct SetupProgress: Codable, Equatable, Sendable {
    public enum Step: String, Codable, CaseIterable, Sendable {
        case hello, space, bookmarks, writing, finish

        public static func offered(asksWriting: Bool) -> [Self] {
            allCases.filter { $0 != .writing || asksWriting }
        }
    }

    public enum Completion: String, Codable, Sendable {
        case completed, skipped
    }

    public let version: Int
    public private(set) var step: Step
    public private(set) var spaceID: UUID?
    public private(set) var completion: Completion?

    public var isPending: Bool { completion == nil }

    public init(step: Step = .hello, spaceID: UUID? = nil, completion: Completion? = nil) {
        version = 1
        self.step = step
        self.spaceID = spaceID
        self.completion = completion
    }

    /// An old completed welcome must never reopen, including after a
    /// downgrade wrote only the legacy marker. No marker means an existing
    /// workspace, not a new person to onboard.
    public static func restore(data: Data?, legacyState: String?) -> Self? {
        if let data, let saved = try? JSONDecoder().decode(Self.self, from: data), saved.version == 1 {
            if legacyState == "done", saved.isPending { return Self(completion: .completed) }
            return saved
        }
        switch legacyState {
        case "pending": return Self()
        case "done": return Self(completion: .completed)
        default: return nil
        }
    }

    /// Keep the original Space even when a different window takes over.
    /// If it was deleted, use a live destination rather than editing nothing.
    /// An unavailable optional step falls forward, never back to Hello.
    public func resuming(spaceIDs: [UUID], preferredSpaceID: UUID, asksWriting: Bool) -> Self? {
        guard isPending else { return nil }
        var next = self
        if !spaceIDs.contains(where: { $0 == spaceID }) {
            next.spaceID = spaceIDs.contains(preferredSpaceID) ? preferredSpaceID : spaceIDs.first
        }
        guard next.spaceID != nil else { return nil }
        let offered = Step.offered(asksWriting: asksWriting)
        if !offered.contains(step) {
            next.step = Step.allCases.drop(while: { $0 != step }).first(where: offered.contains) ?? .finish
        }
        return next
    }

    public mutating func visit(_ step: Step) {
        guard isPending else { return }
        self.step = step
    }

    /// The owner calls this only after the workspace has been saved.
    public mutating func complete(_ reason: Completion) {
        guard isPending else { return }
        completion = reason
    }
}
