import Foundation

public enum WebNavigationKind: Sendable, Equatable {
    case link, form, formResubmission, history, reload, other
    case unknown(Int)
}

public struct WebModifiers: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = Self(rawValue: 1 << 0)
    public static let shift = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let control = Self(rawValue: 1 << 3)
}

/// Where a navigation came from. In `tuple`, a port of 0 is the scheme's
/// default, as WebKit gives it.
public enum WebOrigin: Sendable, Equatable {
    case tuple(scheme: String, host: String, port: Int)
    case opaque
}

public struct WebContentRuleRedirect: Sendable {
    /// nil means marked redirect: the policy must consult its pending site.
    public let originalSite: URL?

    public init(originalSite: URL?) { self.originalSite = originalSite }
}

public struct WebNavigation: Sendable {
    public let request: URLRequest
    public let sourceOrigin: WebOrigin
    public let targetIsMainFrame: Bool?
    public let kind: WebNavigationKind
    public let modifiers: WebModifiers
    public let buttonNumber: Int
    public let requestsDownload: Bool
    public let isServerRedirect: Bool
    public let contentRuleRedirect: WebContentRuleRedirect?

    public init(request: URLRequest, sourceOrigin: WebOrigin, targetIsMainFrame: Bool?,
                kind: WebNavigationKind, modifiers: WebModifiers, buttonNumber: Int,
                requestsDownload: Bool, isServerRedirect: Bool,
                contentRuleRedirect: WebContentRuleRedirect?) {
        self.request = request
        self.sourceOrigin = sourceOrigin
        self.targetIsMainFrame = targetIsMainFrame
        self.kind = kind
        self.modifiers = modifiers
        self.buttonNumber = buttonNumber
        self.requestsDownload = requestsDownload
        self.isServerRedirect = isServerRedirect
        self.contentRuleRedirect = contentRuleRedirect
    }
}

public enum WebNavigationDecision: Sendable {
    case allow, cancel, download
}

@MainActor
public protocol WebNavigationPolicy: AnyObject {
    /// Reply exactly once, before returning. No suspension.
    func decideNavigation(_ navigation: WebNavigation,
                          reply: @MainActor (WebNavigationDecision) -> Void)
}

@MainActor
public protocol WebRequestLoading: AnyObject {
    func load(_ request: URLRequest)
}
