#if os(macOS)
import AppKit
import WebKit

/// An empty page of the app's own at an extension's address, never a
/// site's, from a stand-in context with no scripts or pages of the
/// extension's: what a removed extension's pages kept there (localStorage,
/// IndexedDB, caches) cleared from it, as Search does (its forgetData).
/// WebKit's removeData doesn't reach those.
@MainActor
public final class ExtensionBlankPage: NSObject, WKNavigationDelegate {
    let view: WKWebView
    private var loaded: CheckedContinuation<Bool, Never>?

    private let scheme: String

    public init(_ configuration: WKWebViewConfiguration, scheme: String) {
        self.scheme = scheme
        view = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        view.navigationDelegate = self
    }

    /// Whether it loaded at `base`, an extension's own address, and was cleared.
    public func clear(at base: URL) async throws -> Bool {
        guard base.scheme == scheme else { return false }
        let ready = await withCheckedContinuation { done in
            loaded = done
            view.loadHTMLString("<!doctype html>", baseURL: base)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                MainActor.assumeIsolated { self?.finish(false) }
            }
        }
        guard ready else { return false }
        // Within half a minute, or it is tried again another time.
        let view = view
        let scheme = scheme
        return try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                _ = try await view.callAsyncJavaScript(Self.clearing, arguments: ["origin": "\(scheme)://\(base.host() ?? "")"],
                                                       contentWorld: .defaultClient)
                return true
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                return false
            }
            let first = try await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// Fails, so the removal is kept to be tried again, unless every
    /// database is gone: one still open elsewhere is waited for a moment.
    static let clearing = """
        // Only at the extension's own address.
        if (location.origin !== origin) throw new Error("not the extension's own page: " + location.origin);
        localStorage.clear();
        for (const db of await indexedDB.databases()) {
            if (!db.name) continue;
            await new Promise((done, failed) => {
                const q = indexedDB.deleteDatabase(db.name);
                const late = setTimeout(() => failed(new Error("still open: " + db.name)), 5000);
                q.onsuccess = () => { clearTimeout(late); done(); };
                q.onerror = () => { clearTimeout(late); failed(q.error || new Error("not deleted: " + db.name)); };
            });
        }
        for (const key of await caches.keys()) await caches.delete(key);
        """

    private func finish(_ ok: Bool) {
        loaded?.resume(returning: ok)
        loaded = nil
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(false) }
}
#endif
