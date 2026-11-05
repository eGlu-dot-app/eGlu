#if os(macOS)
import AppKit
import IOKit.pwr_mgt
import PadCore
import WebEngineAppKit
import WebKit

/// The shim's runtime-only answers and native delegate dispatch. This keeps
/// the original hub's actor and owns its assertions for the same lifetime.
@MainActor
public final class WebKitExtensionRuntimeAnswers: WebExtensionRuntimeAnswers {
    public static let applicationIdentifier = "eglu"
    private let host: any ExtensionRuntimeAnswerHost
    private let evidence: () -> any WebExtensionEvidenceRuntime
    private let contexts: () -> [UUID: [String: WKWebExtensionContext]]
    private let space: (WKWebExtensionController) -> UUID?
    private let revive: (String, UUID, String) -> Bool
    private let answer: @MainActor (String, [Any], WKWebExtensionContext, UUID) async throws -> Any?
    private let unanswered: (String) -> any Error
    private let scheme: String
    private let shimApplication: String
    private let services: any ExtensionRuntimeServices
    private let transports: any ExtensionRuntimeTransports
    private var keptAwake: [String: IOPMAssertionID] = [:]

    public convenience init(host: any ExtensionRuntimeAnswerHost, evidence: @escaping () -> any WebExtensionEvidenceRuntime,
                            contexts: @escaping () -> [UUID: [String: WKWebExtensionContext]],
                            space: @escaping (WKWebExtensionController) -> UUID?, revive: @escaping (String, UUID, String) -> Bool,
                            answer: @escaping @MainActor (String, [Any], WKWebExtensionContext, UUID) async throws -> Any?,
                            unanswered: @escaping (String) -> any Error, scheme: String, shimApplication: String) {
        self.init(host: host, evidence: evidence, contexts: contexts, space: space, revive: revive, answer: answer,
                  unanswered: unanswered, scheme: scheme, shimApplication: shimApplication,
                  services: RuntimeServices(), transports: RuntimeTransports())
    }

    init(host: any ExtensionRuntimeAnswerHost, evidence: @escaping () -> any WebExtensionEvidenceRuntime,
         contexts: @escaping () -> [UUID: [String: WKWebExtensionContext]],
         space: @escaping (WKWebExtensionController) -> UUID?, revive: @escaping (String, UUID, String) -> Bool,
         answer: @escaping @MainActor (String, [Any], WKWebExtensionContext, UUID) async throws -> Any?,
         unanswered: @escaping (String) -> any Error, scheme: String, shimApplication: String,
         services: any ExtensionRuntimeServices, transports: any ExtensionRuntimeTransports) {
        self.host = host; self.evidence = evidence; self.contexts = contexts; self.space = space
        self.revive = revive; self.answer = answer; self.unanswered = unanswered
        self.scheme = scheme; self.shimApplication = shimApplication
        self.services = services; self.transports = transports
    }

    public func releaseKeepAwake(_ key: String) {
        if let assertion = keptAwake.removeValue(forKey: key) { services.release(assertion) }
    }

    /// The original context is retained across awaits, even if it unloads.
    /// Delegate entry, rather than each answer, checks registry identity.
    public func answer(_ api: String, _ args: [Any], id: String, context: WKWebExtensionContext, in space: UUID) async throws -> Any? {
        let first = args.first
        switch api {
        case "report":
            // An error nobody caught: [kind, its words, file, line]. Only
            // the API it names is kept, as for WebKit's own errors.
            let problem = args.count > 1 ? (args[1] as? String).flatMap { ExtensionError.problem(in: $0, missing: evidence().lacking[id] ?? []) } : nil
            host.noteExtensionRuntimeReport(problem?.api, words: { args.count > 1 ? args[1] as? String : nil })
            if let problem {
                host.updateExtensionRuntimeAnswer(id, in: space, event: .problem(Self.problem(problem)))
                // Into the records once, as WebKit's own errors go (errorsChanged).
                if let item = host.extensionRuntimeInstallation(id),
                   evidence().recordOnce("\(space.uuidString)/\(id)", (args[1] as? String) ?? "") {
                    evidence().note(Self.problem(problem), file: args.count > 2 ? args[2] as? String : nil, of: item)
                }
            }
            return nil

        // MARK: the worker, up before a page talks to it (Search's)
        case "background.wake":
            guard context.webExtension.hasBackgroundContent else { return nil }
            // WebKit sometimes fails to start a worker again after unloading
            // it, and then never tries again: every message waits for ever.
            // Tried twice more, then the extension is taken up afresh.
            for attempt in 0..<3 {
                // WebKit never calls back after some failed starts; eight
                // seconds without an answer counts as a failure.
                let error: Error? = await withCheckedContinuation { done in
                    var finished = false
                    let finish: (Error?) -> Void = { result in
                        guard !finished else { return }
                        finished = true
                        done.resume(returning: result)
                    }
                    services.loadBackground(context) { error in MainActor.assumeIsolated { finish(error) } }
                    services.after(8) { [unanswered] in finish(unanswered("no answer from WebKit")) }
                }
                guard error != nil else { return nil }
                if attempt < 2 { try? await services.pause() }
            }
            _ = revive(id, space, "its worker wouldn't start")
            return nil
        case "background.revive":
            // A page found the worker gone though WebKit believes it runs.
            return revive(id, space, "its worker stopped answering")

        // MARK: offscreen, a page with a DOM for a worker that has none
        case "offscreen.createDocument":
            guard let path = (first as? [String: Any])?["url"] as? String
            else { throw unanswered("No page for the offscreen document") }
            let reasons = Set(((first as? [String: Any])?["reasons"] as? [Any] ?? []).compactMap { $0 as? String })
            try await services.createOffscreen(path, reasons: reasons, for: context, in: space,
                                                scheme: scheme, host: host)
            return nil
        case "offscreen.closeDocument":
            services.closeOffscreen(id, in: space)
            return nil
        case "offscreen.hasDocument":
            return services.hasOffscreen(id, in: space)

        // Supplied text only. This endpoint never reads a tab or grants access.
        case "i18n.detectLanguage":
            guard let text = first as? String else { throw unanswered("Language detection requires text.") }
            return host.detectExtensionLanguage(text)

        // WebKit has no EyeDropper: the Mac's own colour sampler answers,
        // and a cancel answers an AbortError, as Chrome's picker does.
        case "eyeDropper.open":
            let colour = await host.sampleExtensionColour()
            guard let colour, let srgb = colour.usingColorSpace(.sRGB) else { throw unanswered("AbortError") }
            return String(format: "#%02x%02x%02x",
                          Int((srgb.redComponent * 255).rounded()),
                          Int((srgb.greenComponent * 255).rounded()),
                          Int((srgb.blueComponent * 255).rounded()))

        // MARK: native messaging, asked for as Chrome asks
        case "permissions.native":
            // Only for an extension that asked for it as optional; one that
            // asked for it outright had it at install.
            guard host.extensionNativeIsOptional(id) else { return host.extensionReachesApps(id) }
            switch first as? String {
            case "has":
                return host.extensionReachesApps(id)
            case "remove":
                host.setExtensionNativeConsent(id, false)
                return true
            default:
                if host.extensionReachesApps(id) { return true }
                let title = String(localized: "\u{201C}\(WebKitExtensionMetadata.name(of: context.webExtension) ?? id)\u{201D} wants to talk to apps on this Mac")
                let yes = await host.requestExtensionNative(title: title, in: space) {
                    WebKitExtensionMetadata.icon(of: context.webExtension, size: CGSize(width: 96, height: 96))
                }
                if yes { host.setExtensionNativeConsent(id, true) }
                return yes
            }

        // MARK: idle and power, the Mac's own (Search's)
        case "idle.queryState" where Self.asks(context, for: "idle"), "idle.getAutoLockDelay" where Self.asks(context, for: "idle"),
             "power.requestKeepAwake" where Self.asks(context, for: "power"), "power.releaseKeepAwake" where Self.asks(context, for: "power"),
             "power.reportActivity" where Self.asks(context, for: "power"):
            return try idleOrPower(api, first: first, id: id, context: context, in: space)
        default:
            throw unanswered("eGlu doesn't answer \(api).")
        }
    }

    public static func asks(_ context: WKWebExtensionContext, for permission: String) -> Bool {
        let manifest = context.webExtension.manifest
        if (manifest["permissions"] as? [String] ?? []).contains(permission) { return true }
        return (manifest["optional_permissions"] as? [String] ?? []).contains(permission)
            && context.permissionStatus(for: WKWebExtension.Permission(rawValue: permission)) == .grantedExplicitly
    }

    private func idleOrPower(_ api: String, first: Any?, id: String, context: WKWebExtensionContext, in space: UUID) throws -> Any? {
        switch api {
        case "idle.queryState":
            // Locked when the Mac's screen is; idle once no key or pointer
            // has moved for the seconds asked (15 at least, as Chrome);
            // active otherwise. A password manager locks its vault by it.
            let threshold = max(15, (first as? Double) ?? 60)
            if let session = services.session(),
               session["CGSSessionScreenIsLocked"] as? Bool == true { return "locked" }
            let quiet = services.quiet()
            return quiet >= threshold ? "idle" : "active"
        case "idle.getAutoLockDelay":
            // Chrome's is ChromeOS's alone: zero, for a screen that locks when the Mac says.
            return 0
        case "power.requestKeepAwake":
            let key = "\(space.uuidString)/\(id)"
            if let old = keptAwake.removeValue(forKey: key) { services.release(old) }
            let kind = ((first as? String) == "display" ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep) as CFString
            let why = String(localized: "An extension in eGlu: \(WebKitExtensionMetadata.name(of: context.webExtension) ?? id)") as CFString
            if let assertion = services.createAssertion(kind, why: why) {
                keptAwake[key] = assertion
            }
            return nil
        case "power.releaseKeepAwake":
            if let old = keptAwake.removeValue(forKey: "\(space.uuidString)/\(id)") { services.release(old) }
            return nil
        case "power.reportActivity":
            services.activity()
            return nil
        default:
            throw unanswered("eGlu doesn't answer \(api).")
        }
    }

    private static func problem(_ value: ExtensionError.Problem) -> WebExtensionEvidence.Problem {
        let kind: WebExtensionEvidence.Problem.Kind
        switch value.kind {
        case .missing: kind = .missing
        case .notAFunction: kind = .notAFunction
        case .wrongArguments: kind = .wrongArguments
        }
        return .init(kind: kind, api: value.api)
    }

    /// A desktop app a host stands for, in the words a person knows it by.
    public static func appName(ofHost host: String) -> String {
        let known = ["com.8bit.bitwarden": "Bitwarden", "com.1password": "1Password", "com.apple.passwordmanager": String(localized: "iCloud Passwords"),
                     "com.dashlane": "Dashlane", "com.lastpass": "LastPass", "com.keepassxc": "KeePassXC", "org.keepassxc": "KeePassXC"]
        return known.first { host.hasPrefix($0.key) }?.value ?? host
    }

    /// Native messaging: to "eglu", the shim's questions
    /// (ExtensionAnswers); to any other name, the desktop app that
    /// registered it with Chrome (ExtensionNative), sent one and answered.
    public func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?,
                                for extensionContext: WKWebExtensionContext, replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        let id = extensionContext.uniqueIdentifier
        guard let space = space(controller), contexts()[space]?[id] === extensionContext, let name = applicationIdentifier else {
            return replyHandler(nil, unanswered("Specified native messaging host not found."))
        }
        if name == shimApplication {
            guard let call = message as? [String: Any], let api = call["api"] as? String else {
                return replyHandler(nil, unanswered("Not a question eGlu knows."))
            }
            Task {
                do {
                    let value = try await answer(api, call["args"] as? [Any] ?? [], extensionContext, space)
                    replyHandler(["value": value ?? NSNull()], nil)
                } catch {
                    replyHandler(["error": error.localizedDescription], nil)
                }
            }
            return
        }
        guard host.extensionReachesApps(id) else { return replyHandler(nil, unanswered("Specified native messaging host not found.")) }
        Task {
            do {
                replyHandler(try await transports.send(message, to: name, from: id), nil)
            } catch {
                host.updateExtensionRuntimeAnswer(id, in: space, event: .unreachableApp(Self.appName(ofHost: name)))
                replyHandler(nil, error)
            }
        }
    }

    /// A port: to "eglu.socket", a worker's WebSocket made here
    /// (ExtensionSocket); to any other name, a desktop app's host, kept
    /// talking until either end lets go.
    public func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        connect(controller, port: RuntimeMessagePort(port), context: extensionContext, completionHandler: completionHandler)
    }

    func connect(_ controller: WKWebExtensionController, port: any ExtensionRuntimePort,
                 context extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        let id = extensionContext.uniqueIdentifier
        guard let space = space(controller), contexts()[space]?[id] === extensionContext else {
            return completionHandler(unanswered("Specified native messaging host not found."))
        }
        if port.applicationIdentifier == ExtensionSocket.name(shimApplication: shimApplication) {
            let security = extensionContext.webExtension.manifest["content_security_policy"]
            let policy = (security as? [String: Any])?["extension_pages"] as? String ?? security as? String
            transports.connectSocket(port, from: id, in: space, policy: policy, scheme: scheme)
            return completionHandler(nil)
        }
        // The shim's own, opened only to find what WebKit's ports are
        // made of, and let go at once.
        if port.applicationIdentifier == shimApplication { return completionHandler(nil) }
        guard host.extensionReachesApps(id) else { return completionHandler(unanswered("Specified native messaging host not found.")) }
        do {
            try transports.connectNative(port, from: id)
            completionHandler(nil)
        } catch {
            host.updateExtensionRuntimeAnswer(id, in: space, event: .unreachableApp(Self.appName(ofHost: port.applicationIdentifier ?? "")))
            completionHandler(error)
        }
    }
}
#endif
