#if os(macOS)
import AppKit
import PadCore
import WebEngineAppKit
import WebKit
import WebKitMacPlugin

/// These reads stay separate so the verdict callback is heard between
/// isLoaded and errors, just as in the app's report. Tests need no WebKit
/// context, installed extension or persistent data store.
@MainActor
protocol ExtensionDiagnosticContext {
    var isLoaded: Bool { get }
    var errors: [any Error] { get }
    var cookies: Int { get }
    var permissions: [String] { get }
    var commands: [(id: String, key: String?, modifiers: UInt)] { get }
    func permission(for url: URL) -> Int
}

@MainActor
private struct DiagnosticContext: ExtensionDiagnosticContext {
    let context: WKWebExtensionContext
    var isLoaded: Bool { context.isLoaded }
    var errors: [any Error] { context.errors }
    var cookies: Int { context.permissionStatus(for: .cookies).rawValue }
    var permissions: [String] { context.grantedPermissions.keys.map(\.rawValue) }
    var commands: [(id: String, key: String?, modifiers: UInt)] {
        context.commands.map { ($0.id, $0.activationKey, $0.modifierFlags.rawValue) }
    }
    func permission(for url: URL) -> Int { context.permissionStatus(for: url).rawValue }
}

@MainActor
public final class WebKitExtensionDiagnostics: WebExtensionDiagnostics {
    private let host: any ExtensionDiagnosticHost
    private let table: () -> ExtensionAPITable?
    private let context: (UUID, String) -> (any ExtensionDiagnosticContext)?
    private let prepared: (String, String) -> URL
    private let records: (String) -> [WebExtensionErrorRecord]
    private let scheme: String

    public convenience init(host: any ExtensionDiagnosticHost, table: @escaping () -> ExtensionAPITable?,
                contexts: @escaping () -> [UUID: [String: WKWebExtensionContext]],
                prepared: @escaping (String, String) -> URL, records: @escaping (String) -> [WebExtensionErrorRecord],
                scheme: String) {
        self.init(host: host, table: table, context: { space, id in
            contexts()[space]?[id].map { DiagnosticContext(context: $0) }
        }, prepared: prepared, records: records, scheme: scheme)
    }

    init(host: any ExtensionDiagnosticHost, table: @escaping () -> ExtensionAPITable?,
         context: @escaping (UUID, String) -> (any ExtensionDiagnosticContext)?,
         prepared: @escaping (String, String) -> URL, records: @escaping (String) -> [WebExtensionErrorRecord],
         scheme: String) {
        self.host = host
        self.table = table
        self.context = context
        self.prepared = prepared
        self.records = records
        self.scheme = scheme
    }

    public func diagnosticTableLines() -> [String] {
        var lines: [String] = []
        // This Mac's table, once measured: its namespaces, WebKit's own.
        if let table = table() {
            let namespaces = table.answers.filter { !$0.key.contains(".") && $0.value == .native }.keys.sorted()
            lines.append("table \(namespaces.count): \(namespaces.joined(separator: " "))")
            lines.append("table tabs: \(table.answers.keys.filter { $0.hasPrefix("tabs.") }.count) members")
        }
        return lines
    }

    public func diagnosticLines(id: String, name: String, version: String, in space: UUID,
                                number: Int, otherExtension: () -> String) -> [String] {
        var lines: [String] = []
        let context = context(space, id)
        lines.append("space \(number) extension \(name) loaded=\(context?.isLoaded ?? false)")
        lines += host.extensionDiagnosticVerdictLines(id, in: space, number: number)
        lines += (context?.errors ?? []).map { "space \(number) error \(($0 as NSError).code) \($0.localizedDescription)" }
        lines.append("space \(number) cookies \(context?.cookies ?? 99)")
        lines.append("space \(number) permissions " + (context?.permissions.sorted() ?? []).joined(separator: " "))
        lines += (context?.commands ?? []).map { "space \(number) command \($0.id) key \($0.key ?? "-") \($0.modifiers)" }
        // What it may reach, as WebKit answers for one address
        // of each kind (a status's raw value: granted 2 or 3,
        // unknown 0, denied -2 or -3).
        let other = otherExtension()
        let reaches = ["https://example.com/", "https://accounts.google.com/", "\(scheme)://\(other)/page.html", "file:///tmp/page.html"]
        lines.append("space \(number) reaches " + reaches.map { "\($0)=\(context?.permission(for: URL(string: $0)!) ?? 99)" }.joined(separator: " "))
        let stamp = prepared(id, version).appendingPathComponent(ExtensionPreparation.stampFile)
        lines.append("space \(number) prepared \((try? String(contentsOf: stamp, encoding: .utf8)) ?? "-")")
        lines += records(id).map { "space \(number) record \($0.place) \($0.api) \($0.kind) x\($0.count)" }
        return lines
    }

    public func diagnosticPageLine(_ page: (any WebMacPage)?, number: Int) -> String {
        guard let page else { return "space \(number) page -: -" }
        guard let page = page as? WebKitMacPage else {
            preconditionFailure("Page.view requires a WebKitMacPage")
        }
        return "space \(number) page \(page.webView.url?.host() ?? "-"): \(page.webView.title ?? "-")"
    }

    /// An error's own words for the steps file, only when the app asks for
    /// them: they may hold what a page or an account said, which the records
    /// never keep.
    public static func words(_ text: String?, enabled: Bool) -> String {
        guard enabled, let text else { return "" }
        return ": " + text.prefix(240)
    }

    /// A line in the check's steps file, beside its report.
    public static func note(_ line: String, outputPath: String?) {
        guard let out = outputPath else { return }
        let text = ((try? String(contentsOfFile: out + ".steps", encoding: .utf8)) ?? "") + line + "\n"
        try? text.write(toFile: out + ".steps", atomically: true, encoding: .utf8)
    }
}
#endif
