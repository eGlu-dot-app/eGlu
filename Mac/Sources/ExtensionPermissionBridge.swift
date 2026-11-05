import AppKit
import SwiftUI
import WebKit
import WebKitExtensions

extension Extensions {
    /// Kept until the optional-native caller and the debug previews use
    /// values too. The permission runtime itself passes only values.
    func askForMore(title: String, from context: WKWebExtensionContext, in space: UUID, window: WindowModel?,
                    host: NSWindow? = nil, note: String? = nil, @ViewBuilder content: () -> some View) async -> Bool {
        let image = WebKitExtensionMetadata.icon(of: context.webExtension, size: CGSize(width: 96, height: 96))
        return await askForMore(title: title, image: image, in: space, window: window, host: host, note: note, content: content)
    }
}
