#if os(macOS)
import AppKit
import PadCore
import WebEngineAppKit
import WebKit

/// Permission conversion and grants, on the original hub's main actor.
/// The app captures a target before each original asynchronous boundary.
@MainActor
public final class WebKitExtensionPermissions: WebExtensionPermissions {
    private let host: any ExtensionPermissionHost
    private let space: (WKWebExtensionController) -> UUID?
    private let unanswered: (String) -> any Error
    private let fence: @MainActor (WKWebExtensionContext) -> Void
    private let now: () -> Date

    public init(host: any ExtensionPermissionHost, space: @escaping (WKWebExtensionController) -> UUID?,
                unanswered: @escaping (String) -> any Error,
                fence: @escaping @MainActor (WKWebExtensionContext) -> Void = WebKitExtensionControllers.fence) {
        self.host = host
        self.space = space
        self.unanswered = unanswered
        self.fence = fence
        self.now = { Date() }
    }

    // Fixtures advance a clock without waiting ten seconds.
    init(host: any ExtensionPermissionHost, space: @escaping (WKWebExtensionController) -> UUID?,
         unanswered: @escaping (String) -> any Error, fence: @escaping @MainActor (WKWebExtensionContext) -> Void,
         now: @escaping () -> Date) {
        self.host = host
        self.space = space
        self.unanswered = unanswered
        self.fence = fence
        self.now = now
    }

    /// When each extension's button was last pressed, by space and id:
    /// a permissions.request made from that press is one the person asked
    /// for, even once WebKit no longer counts the press (an extension that
    /// awaits something first, Figma's).
    public static var pressed: [String: Date] = [:]
    public var permissionPresses: [String: Date] {
        get { Self.pressed }
        set { Self.pressed = newValue }
    }

    public func promptForPermissions(_ permissions: Set<WKWebExtension.Permission>, controller: WKWebExtensionController,
                                     tab: (any WKWebExtensionTab)?, context: WKWebExtensionContext,
                                     completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        // Cookies too, as Chrome asks for them: a yes is the person's
        // choice for the extension, in every space (setReadsCookies).
        let asked = permissions
        guard !asked.isEmpty else { return completionHandler([], nil) }
        guard let sourceSpace = space(controller) else { return completionHandler([], nil) }
        let tabID = (tab as? ExtensionTab)?.id
        guard let owner = host.extensionPermissionTarget(in: sourceSpace, tab: tabID, kind: .permissions) else { return completionHandler([], nil) }
        let names = asked.map(\.rawValue)
        let cookies = ExtensionAccessSummary(permissions: names, sites: []).cookies
        let name = WebKitExtensionMetadata.name(of: context.webExtension)
        let title = host.extensionPermissionTitle(name: name, kind: .permissions)
        let id = context.uniqueIdentifier
        Task {
            let image = WebKitExtensionMetadata.icon(of: context.webExtension, size: CGSize(width: 96, height: 96))
            let request = ExtensionPermissionRequest(extensionID: id, space: sourceSpace, tab: tabID, name: name, image: image,
                                                     permissions: names, sites: [], kind: .permissions, title: title)
            let yes = await host.requestExtensionPermission(request, target: owner)
            completionHandler(yes ? asked : [], nil)
            if yes, cookies { host.allowExtensionPermissionCookies(id) }
        }
    }

    /// Chrome never asks site by site; a site the extension wants comes
    /// with its install, or with a click on its button.
    public func promptForPermissionToAccess(_ urls: Set<URL>, completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        completionHandler([], nil)
    }

    public func promptForPermissionMatchPatterns(_ matchPatterns: Set<WKWebExtension.MatchPattern>, controller: WKWebExtensionController,
                                                tab: (any WKWebExtensionTab)?, context: WKWebExtensionContext,
                                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        // Extension pages, files and the hands-off sites are never given,
        // so never asked about.
        let wanted = matchPatterns.filter { !WebKitExtensionControllers.withheld($0) && !HandsOff.covers(host: $0.host.map { $0.hasPrefix("*.") ? String($0.dropFirst(2)) : $0 }) }
        guard !wanted.isEmpty, let sourceSpace = space(controller) else { return completionHandler([], nil) }
        let tabID = (tab as? ExtensionTab)?.id
        guard let owner = host.extensionPermissionTarget(in: sourceSpace, tab: tabID, kind: .matchPatterns) else { return completionHandler([], nil) }
        let sites = wanted.map(\.string)
        let name = WebKitExtensionMetadata.name(of: context.webExtension)
        let title = host.extensionPermissionTitle(name: name, kind: .matchPatterns)
        Task {
            let image = WebKitExtensionMetadata.icon(of: context.webExtension, size: CGSize(width: 96, height: 96))
            let request = ExtensionPermissionRequest(extensionID: context.uniqueIdentifier, space: sourceSpace, tab: tabID,
                name: name, image: image, permissions: [], sites: sites, kind: .matchPatterns, title: title)
            let yes = await host.requestExtensionPermission(request, target: owner)
            completionHandler(yes ? wanted : [], nil)
            // Given only once this has returned: fenced again after.
            if yes {
                let fence = self.fence
                DispatchQueue.main.async { fence(context) }
            }
        }
    }

    /// permissions.request for what WebKit grants, refused by WebKit for
    /// want of a click, within ten seconds of a press on the extension's
    /// button, once, and only for permissions and sites its manifest names
    /// (optional ones included): asked as WebKit's own question would be.
    /// Extension pages, files and Google's sign-in are never given, so
    /// never asked about. Cookies are asked about as what they are: a yes
    /// lets the extension read them in every space (setReadsCookies).
    public func requestAfterClick(_ names: [String], origins: [String], context: WKWebExtensionContext, in space: UUID) async throws -> Bool {
        let id = context.uniqueIdentifier
        let key = "\(space.uuidString)/\(id)"
        guard let when = Self.pressed[key], now().timeIntervalSince(when) < 10 else {
            throw unanswered("Invalid call to permissions.request(). Must be called during a user gesture.")
        }
        Self.pressed[key] = nil
        let package = context.webExtension
        let wanted = names.map { WKWebExtension.Permission(rawValue: $0) }
        let patterns = origins.compactMap { try? WKWebExtension.MatchPattern(string: $0) }
        // One that can't be read is refused, as Chrome refuses it, never dropped.
        guard patterns.count == origins.count else { throw unanswered("Invalid value for origin pattern.") }
        let named = package.requestedPermissions.union(package.optionalPermissions)
        // A site the manifest's own patterns cover, as Chrome lets an
        // extension ask for part of what it declared (one site of https://*/*).
        let declared = package.allRequestedMatchPatterns.union(package.optionalPermissionMatchPatterns)
        guard wanted.allSatisfy(named.contains), patterns.allSatisfy({ asked in declared.contains { $0.matches(asked) } }) else {
            throw unanswered("Only permissions specified in the manifest may be requested.")
        }
        // What eGlu never gives (files, Google's sign-in) makes the whole
        // request a no, as Chrome answers one it can't grant whole.
        let blocked = { (pattern: WKWebExtension.MatchPattern) in
            WebKitExtensionControllers.withheld(pattern) || HandsOff.covers(host: pattern.host.map { $0.hasPrefix("*.") ? String($0.dropFirst(2)) : $0 })
        }
        guard !patterns.contains(where: blocked) else { return false }
        let missing = wanted.filter { context.permissionStatus(for: $0) != .grantedExplicitly }
        let unreached = patterns.filter { context.permissionStatus(for: $0) != .grantedExplicitly }
        guard !missing.isEmpty || !unreached.isEmpty else { return true }
        guard let owner = host.extensionPermissionTarget(in: space, tab: nil, kind: .afterClick) else { return false }
        let request = ExtensionPermissionRequest(extensionID: id, space: space, tab: nil,
            name: WebKitExtensionMetadata.name(of: package), image: nil,
            permissions: missing.map(\.rawValue), sites: unreached.map(\.string), kind: .afterClick)
        let cookies = missing.contains(.cookies)
        guard await host.requestExtensionPermission(request, target: owner) else { return false }
        for permission in missing { context.setPermissionStatus(.grantedExplicitly, for: permission) }
        for pattern in unreached { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
        fence(context)
        if cookies { host.allowExtensionPermissionCookies(context.uniqueIdentifier) }
        return true
    }

}
#endif
