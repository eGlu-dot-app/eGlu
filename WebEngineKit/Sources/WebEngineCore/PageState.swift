import Foundation

/// What WebKit itself reports for a page: the engine's state
/// (Docs/EngineSplitPlan.md 5.2). Page's own members add the product's
/// rules, such as going back past a replaced page, on top.
public struct PageState: Sendable, Equatable {
    public let url: URL?
    public let title: String?
    public let isLoading: Bool
    public let estimatedProgress: Double
    public let canGoBack: Bool
    public let canGoForward: Bool
    public let hasOnlySecureContent: Bool

    public init(url: URL?, title: String?, isLoading: Bool, estimatedProgress: Double,
                canGoBack: Bool, canGoForward: Bool, hasOnlySecureContent: Bool) {
        self.url = url
        self.title = title
        self.isLoading = isLoading
        self.estimatedProgress = estimatedProgress
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.hasOnlySecureContent = hasOnlySecureContent
    }
}
