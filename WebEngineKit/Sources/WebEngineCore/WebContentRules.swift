import Foundation

/// A compiled list, kept as the engine's own object.
@MainActor public protocol WebRuleList: AnyObject, Sendable {
    var identifier: String { get }
}

/// The engine's compiled lists, kept on disk until removed.
@MainActor public protocol WebRuleListStore: AnyObject {
    /// Answers on the engine's callback thread, without a hop to another actor.
    func lookUp(forIdentifier identifier: String,
                completionHandler: @escaping ((any WebRuleList)?, (any Error)?) -> Void)
    func compile(forIdentifier identifier: String, encodedRules: String,
                 completionHandler: @escaping ((any WebRuleList)?, (any Error)?) -> Void)
    /// Lists compiled from older versions, gone from the disk. The engine
    /// lists them and starts each removal in its own callback, without waiting.
    func removeOld(withPrefix prefix: String, keeping: Set<String>)
}

/// Where a page's compiled lists go, in the order given.
@MainActor public protocol WebRuleListTarget: AnyObject {
    /// Removes all lists, then adds each one. With none, only the removal.
    func replaceAll(with lists: [any WebRuleList])
}
