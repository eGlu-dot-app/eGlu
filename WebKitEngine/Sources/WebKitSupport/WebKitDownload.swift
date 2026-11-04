import WebEngineCore
import WebKit

/// WebKit's download, kept until its owner has finished with it.
@MainActor
public final class WebKitDownload: NSObject, WebEngineCore.WebDownload, WKDownloadDelegate {
    private let download: WKDownload
    public weak var delegate: (any WebEngineCore.WebDownloadDelegate)?

    public init(_ download: WKDownload) {
        self.download = download
        super.init()
        download.delegate = self
    }

    public var originalURL: URL? { download.originalRequest?.url }
    public var originalRequest: URLRequest? { download.originalRequest }
    public var progress: Progress { download.progress }

    public func cancel(_ done: @escaping @MainActor @Sendable (Data?) -> Void) {
        download.cancel(done)
    }

    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                         suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        guard let delegate else { return completionHandler(nil) }
        delegate.download(self, decideDestinationUsing: response, suggestedFilename: suggestedFilename,
                          completionHandler: completionHandler)
    }

    public func downloadDidFinish(_ download: WKDownload) {
        delegate?.downloadDidFinish(self)
    }

    public func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        delegate?.download(self, didFailWithError: error, resumeData: resumeData)
    }
}
