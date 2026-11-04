import WebEngineCore
import WebKit

/// WebKit's compiled list, kept as it is.
@MainActor
public final class WebKitRuleList: WebRuleList {
    let list: WKContentRuleList

    public init(_ list: WKContentRuleList) { self.list = list }

    public var identifier: String { list.identifier }
}

/// WebKit's compiled lists, in its own store on disk.
@MainActor
public final class WebKitRuleListStore: WebRuleListStore {
    private let store: WKContentRuleListStore

    public init(store: WKContentRuleListStore) { self.store = store }

    public static func makeDefault() -> WebKitRuleListStore? {
        guard let store = WKContentRuleListStore.default() else { return nil }
        return WebKitRuleListStore(store: store)
    }

    public func lookUp(forIdentifier identifier: String,
                       completionHandler: @escaping ((any WebRuleList)?, (any Error)?) -> Void) {
        store.lookUpContentRuleList(forIdentifier: identifier) { list, error in
            completionHandler(list.map { WebKitRuleList($0) }, error)
        }
    }

    public func compile(forIdentifier identifier: String, encodedRules: String,
                        completionHandler: @escaping ((any WebRuleList)?, (any Error)?) -> Void) {
        store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: encodedRules) { list, error in
            completionHandler(list.map { WebKitRuleList($0) }, error)
        }
    }

    /// Lists compiled from older versions, gone from the disk.
    public func removeOld(withPrefix prefix: String, keeping: Set<String>) {
        let store = store
        store.getAvailableContentRuleListIdentifiers { identifiers in
            for id in identifiers ?? [] where id.hasPrefix(prefix) && !keeping.contains(id) {
                store.removeContentRuleList(forIdentifier: id) { _ in }
            }
        }
    }
}

/// The compiled lists in one page's controller.
@MainActor
public final class WebKitRuleListTarget: WebRuleListTarget {
    private let controller: WKUserContentController

    public init(controller: WKUserContentController) { self.controller = controller }

    public func replaceAll(with lists: [any WebRuleList]) {
        controller.removeAllContentRuleLists()
        for list in lists {
            guard let list = list as? WebKitRuleList else {
                preconditionFailure("WebKitRuleListTarget requires a WebKitRuleList")
            }
            controller.add(list.list)
        }
    }
}
