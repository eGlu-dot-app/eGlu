import Foundation
import WebKit
import WebEngineCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A site's icon drawn as SVG, made into a picture (SiteIcons). Neither
/// UIImage nor ImageIO reads SVG, and NSImage draws one without its dark
/// look, so WebKit draws it: in a page of the app's own, with no script of
/// any site's, no data kept and no network (a drawing shown as an image
/// loads nothing), onto a canvas, read back as a PNG with its transparency.
/// One web view, made at the first icon that needs it; it needs no window.
@MainActor
public final class WebKitSVGRaster: NSObject, WKNavigationDelegate, WebSVGRasterizer {
    public static let shared = WebKitSVGRaster()

    private var view: WKWebView?
    private var loaded = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Whether the drawing has a look of its own for a dark screen
    /// (`prefers-color-scheme`), to be drawn a second time for it.
    nonisolated static func hasDarkLook(_ svg: String) -> Bool {
        svg.range(of: "prefers-color-scheme", options: .caseInsensitive) != nil
    }

    /// The drawing with its light or its dark look chosen for it: each
    /// `(prefers-color-scheme: …)` it asks is made true or false outright.
    /// A drawing on a canvas is drawn in its light look whatever the page's.
    nonisolated public static func forcing(_ svg: String, dark: Bool) -> String {
        guard hasDarkLook(svg) else { return svg }
        let always = "(min-width: 0px)", never = "(max-width: 0px)"
        var text = svg
        for (scheme, holds) in [("dark", dark), ("light", !dark)] {
            text = text.replacingOccurrences(of: #"\(\s*prefers-color-scheme\s*:\s*\#(scheme)\s*\)"#,
                                             with: holds ? always : never,
                                             options: [.regularExpression, .caseInsensitive])
        }
        return text
    }

    /// The drawing at `side` pixels a side, whole and centred; nil when it
    /// isn't one WebKit can draw, or it takes over three seconds.
    public func png(of svg: String, side: Int, dark: Bool) async -> Data? {
        await ready()
        guard let view else { return nil }
        let text = Self.forcing(svg, dark: dark)
        // The drawing's data URL, read as text before it leaves WebKit's callback.
        let result: String? = await withCheckedContinuation { continuation in
            view.callAsyncJavaScript(Self.draw, arguments: ["text": text, "side": side], in: nil, in: .defaultClient) {
                continuation.resume(returning: (try? $0.get()) as? String)
            }
        }
        guard let url = result, let comma = url.firstIndex(of: ","),
              let png = Data(base64Encoded: String(url[url.index(after: comma)...]))
        else { return nil }
        return png
    }

    /// Sized to the canvas before it is drawn: a drawing that gives only
    /// its width and height gets a viewBox of them, and every one fills the
    /// square, its proportions kept (SVG's own preserveAspectRatio).
    private static let draw = """
        const doc = new DOMParser().parseFromString(text, 'image/svg+xml');
        const root = doc.documentElement;
        if (!root || root.localName !== 'svg' || doc.getElementsByTagName('parsererror').length) return null;
        if (!root.hasAttribute('viewBox')) {
          const width = parseFloat(root.getAttribute('width')), height = parseFloat(root.getAttribute('height'));
          if (width > 0 && height > 0) root.setAttribute('viewBox', `0 0 ${width} ${height}`);
        }
        root.setAttribute('width', side);
        root.setAttribute('height', side);
        const source = new XMLSerializer().serializeToString(root);
        const image = new Image();
        image.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(source);
        await Promise.race([image.decode(), new Promise((_, fail) => setTimeout(() => fail(new Error('slow')), 3000))]);
        const canvas = document.createElement('canvas');
        canvas.width = canvas.height = side;
        canvas.getContext('2d').drawImage(image, 0, 0, side, side);
        return canvas.toDataURL('image/png');
        """

    /// The web view and its empty page, made the first time and kept.
    private func ready() async {
        if loaded { return }
        if view == nil {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            // The page has no script; the drawing is done from the app's own world.
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 96, height: 96), configuration: configuration)
            view.navigationDelegate = self
            view.loadHTMLString("<!doctype html><title>Icons</title>", baseURL: nil)
            self.view = view
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    nonisolated public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { settle() }
    }

    nonisolated public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { settle(failed: true) }
    }

    nonisolated public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Made again at the next icon; any icon waiting for it goes without.
        MainActor.assumeIsolated { settle(failed: true) }
    }

    private func settle(failed: Bool = false) {
        loaded = !failed
        if failed { view = nil }
        let resumed = waiting
        waiting = []
        resumed.forEach { $0.resume() }
    }
}
