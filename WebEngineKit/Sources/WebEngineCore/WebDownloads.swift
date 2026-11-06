import Foundation

/// A download a navigation became, or one started in a page's or space's session.
@MainActor public protocol WebDownload: AnyObject, Sendable {
    var originalURL: URL? { get }
    var originalRequest: URLRequest? { get }
    /// The engine's progress.
    var progress: Progress { get }
    /// Held weakly, as WebKit holds its own.
    var delegate: (any WebDownloadDelegate)? { get set }
    /// Stops it; `done` hears what it can be resumed from, if anything.
    func cancel(_ done: @escaping @MainActor @Sendable (Data?) -> Void)
}

@MainActor public protocol WebDownloadDelegate: AnyObject {
    func download(_ download: any WebDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void)
    func downloadDidFinish(_ download: any WebDownload)
    func download(_ download: any WebDownload, didFailWithError error: any Error, resumeData: Data?)
}

/// Starts downloads in a session: a page's own (its sign-ins), or a space's.
@MainActor public protocol WebDownloadStarting: AnyObject {
    /// False once the page whose session it is has gone. A space's is always true.
    var canStartDownloads: Bool { get }
    /// Keeps the session for one asynchronous call, as passing the page's view did.
    /// The stored starter stays weak; this makes no new page.
    func keepingSessionAlive() -> any WebDownloadStarting
    func startDownload(using request: URLRequest,
                       completionHandler: @escaping @MainActor @Sendable (any WebDownload) -> Void)
    func resumeDownload(fromResumeData data: Data,
                        completionHandler: @escaping @MainActor @Sendable (any WebDownload) -> Void)
}
