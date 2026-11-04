import Foundation

public enum WebKitScriptBridge {
    /// The script that defines globalThis.egluBridge for WebKit, where it runs.
    public static let source: String = {
        guard let file = Bundle.module.url(forResource: "eglu-bridge", withExtension: "js", subdirectory: "Scripts"),
              let text = try? String(contentsOf: file, encoding: .utf8)
        else { return "" }
        return text
    }()
}
