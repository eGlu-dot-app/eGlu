import WebEngineCore
import WebKit

/// The app's Downloads still keeps WebKit's own object until its step (step 9).
@MainActor
public final class WebKitDownload: WebEngineCore.WebDownload {
    public let download: WKDownload

    public init(_ download: WKDownload) { self.download = download }

    public var originalURL: URL? { download.originalRequest?.url }
}
