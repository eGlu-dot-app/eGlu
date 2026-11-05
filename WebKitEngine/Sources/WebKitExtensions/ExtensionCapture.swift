#if os(macOS)
import AppKit
import WebKit
import WebEngineAppKit

/// Screen recording for extensions: Loom, Screencastify, Awesome Screenshot.
///
/// Chrome hands an extension a stream id from its own picker
/// (desktopCapture.chooseDesktopMedia) and the stream for it from
/// getUserMedia. WebKit has neither. What it has is getDisplayMedia, which
/// shows the Mac's own picker, and which it refuses unless the call comes
/// from a click being handled in a page that is on screen. So eGlu stands
/// in between. An extension's page asks through a channel that knows who is
/// asking; eGlu asks you, once per extension, whether it may record; brings
/// the page on screen; and calls WebKit's getDisplayMedia in that page
/// itself, which WebKit counts as a click. The Mac's picker follows every
/// time: it is the Mac, not eGlu, that asks what to share. The stream stays
/// in the page and is handed over as the answer to the extension's
/// getUserMedia. While an extension records, a pill says so and stops it
/// (RecordingIndicator).
///
/// Nothing here uses ScreenCaptureKit or looks at other windows: WebKit's
/// picker is the only way in, and it needs no Screen Recording permission.
/// (Search's ExtensionCapture: c0d57c9, 686cf03, 46b4b7b, 605ecff)
@MainActor
public final class ExtensionCaptureRuntime: NSObject, WKScriptMessageHandlerWithReply {
    /// The name the extension's pages post to (window.webkit.messageHandlers).
    public static let channel = "egluCapture"

    private let scheme: String
    private let host: any ExtensionCaptureHost
    private let spaceOf: (WKWebExtensionController?) -> UUID?
    private let contextIn: (String, UUID) -> WKWebExtensionContext?
    private let declaresCapture: (WKWebExtensionContext) -> Bool

    public init(scheme: String, host: any ExtensionCaptureHost,
                space: @escaping (WKWebExtensionController?) -> UUID?,
                context: @escaping (String, UUID) -> WKWebExtensionContext?,
                declares: @escaping (WKWebExtensionContext) -> Bool,
                watchEvents: Bool = true) {
        self.scheme = scheme
        self.host = host
        self.spaceOf = space
        self.contextIn = context
        self.declaresCapture = declares
        super.init()
        host.setExtensionCaptureStop { [weak self] id in self?.stop(id) }
        if watchEvents { watchTouches() }
    }

    public func forget(_ id: String) {
        grants = grants.filter { $0.value.extensionID != id }
    }

    /// When you last clicked or typed in one of each extension's own pages.
    /// Real events only: a page's script can dispatch one, but it never
    /// reaches here.
    private var touched: [String: Date] = [:]
    private var touching: Any?

    private func watchTouches() {
        guard touching == nil else { return }
        touching = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
            var view: NSView? = event.type == .keyDown
                ? event.window?.firstResponder as? NSView
                : event.window?.contentView?.superview?.hitTest(event.locationInWindow)
            while let found = view, !(found is WKWebView) { view = found.superview }
            if let url = (view as? WKWebView)?.url, url.scheme?.lowercased() == self?.scheme, let id = url.host() {
                MainActor.assumeIsolated { self?.touched[id] = Date() }
            }
            return event
        }
    }

    /// Yes from you: now, or before and you have just used this extension
    /// (its button within the last minute, Loom's Start being in its menu
    /// over the page; its popup or its pages within the last five seconds).
    /// Otherwise it is asked again: a remembered yes never lets an
    /// extension take the screen on its own.
    private func consent(_ context: WKWebExtensionContext, in space: UUID) async -> Bool {
        let id = context.uniqueIdentifier
        return await host.requestExtensionCapture(id, in: space,
            used: { self.touched[id].map { Date().timeIntervalSince($0) < 5 } ?? false },
            name: { context.webExtension.displayName ?? String(localized: "An extension") })
    }

    // MARK: Stream ids

    /// A stream id handed to an extension: good once, for a minute, for
    /// that extension in that space only.
    struct Grant {
        let extensionID: String
        let space: UUID
        let made: Date
        /// The sources the worker asked for, for the picker when it is used.
        let sources: [String]
    }

    var grants: [String: Grant] = [:]

    private static func token() -> String? {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// From the extension's worker, which has no page to record in: the id
    /// is given now, and the recording starts when one of its pages hands
    /// it to getUserMedia ("consume").
    public func grant(for context: WKWebExtensionContext, in space: UUID, sources: [String]) async -> String {
        guard declaresCapture(context), await consent(context, in: space), let token = Self.token() else { return "" }
        grants = grants.filter { Date().timeIntervalSince($0.value.made) < 60 }
        grants[token] = Grant(extensionID: context.uniqueIdentifier, space: space, made: Date(), sources: sources)
        return token
    }

    // MARK: The channel

    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        receive(message.body, sender: { self.sender(of: message) }, replyHandler: replyHandler)
    }

    // Tests supply the body and sender because WebKit makes its messages.
    func receive(_ value: Any, sender: () -> (WKWebExtensionContext, UUID, WKWebView)?,
                 replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        guard let body = value as? [String: Any], let op = body["op"] as? String else {
            return replyHandler(nil, "Not a request")
        }
        // Only the top of one of an extension's own pages, in a view of
        // that extension's: not a site framed in it, not its page framed in
        // a site, not another extension.
        guard let (context, space, web) = sender() else {
            return replyHandler(["error": "NotAllowedError", "message": "Not allowed here"], nil)
        }
        // The microphone or camera, from an offscreen document: WebKit holds
        // the request for as long as the page has no window, so one made to
        // record is lent to the pill first, which is up while it listens.
        // Any other extension page just goes on.
        if op == "lend" {
            guard let reasons = ExtensionOffscreen.reasons(of: web) else { return replyHandler(["ok": true], nil) }
            guard !reasons.isDisjoint(with: ["USER_MEDIA", "DISPLAY_MEDIA"]) else {
                return replyHandler(["error": "NotAllowedError", "message": "This offscreen document wasn't made to record"], nil)
            }
            lendAwhile(web)
            return replyHandler(["ok": true], nil)
        }
        Task { @MainActor in
            replyHandler(await self.answer(op, body, context: context, space: space, in: web), nil)
        }
    }

    func sender(of message: WKScriptMessage) -> (WKWebExtensionContext, UUID, WKWebView)? {
        let origin = message.frameInfo.securityOrigin
        return sender(isMainFrame: message.frameInfo.isMainFrame, originProtocol: origin.protocol,
                      originHost: origin.host, web: message.webView)
    }

    // WKScriptMessage and its frame and origin cannot be constructed by tests.
    // Deferred getters keep WebKit's reads in their original guard order.
    func sender(isMainFrame: @autoclosure () -> Bool, originProtocol: @autoclosure () -> String,
                originHost: @autoclosure () -> String, web: @autoclosure () -> WKWebView?) -> (WKWebExtensionContext, UUID, WKWebView)? {
        guard isMainFrame(), let web = web(), originProtocol().lowercased() == scheme,
              let url = web.url, url.scheme?.lowercased() == scheme,
              url.host()?.lowercased() == originHost().lowercased(),
              let space = spaceOf(web.configuration.webExtensionController),
              let context = contextIn(originHost().lowercased(), space) ?? contextIn(originHost(), space)
        else { return nil }
        return (context, space, web)
    }

    func answer(_ op: String, _ body: [String: Any], context: WKWebExtensionContext, space: UUID, in web: WKWebView) async -> [String: Any] {
        guard declaresCapture(context) || op == "display" else {
            return ["error": "NotAllowedError", "message": "It didn't ask to record your screen"]
        }
        // An offscreen document records only if it was made to.
        if let reasons = ExtensionOffscreen.reasons(of: web), reasons.isDisjoint(with: ["USER_MEDIA", "DISPLAY_MEDIA"]) {
            return ["error": "NotAllowedError", "message": "This offscreen document wasn't made to record"]
        }
        let video = body["video"] ?? true
        // Which picker: a screen, or a window. Chrome's sources in order of
        // preference, or getDisplayMedia's displaySurface.
        func window(_ sources: [String]) -> Bool {
            let first = sources.first { $0 == "screen" || $0 == "window" || $0 == "tab" }
            let surface = body["surface"] as? String
            return first == "window" || first == "tab" || surface == "window" || surface == "browser"
        }
        let sources = body["sources"] as? [String] ?? []
        switch op {
        // chooseDesktopMedia from a page, or getDisplayMedia: asked, and
        // recorded right away in that page, so a cancelled picker is an
        // empty id, as in Chrome.
        case "choose", "display":
            guard await consent(context, in: space), let token = Self.token() else {
                return ["error": "NotAllowedError", "message": "Permission denied"]
            }
            let answer = await record(in: web, token: token, video: video, window: window(sources), context: context)
            // chooseDesktopMedia's id may be handed to another of the
            // extension's pages (an offscreen document), as a worker's is:
            // good there once, for a minute, which records afresh. The page
            // that chose keeps its own stream for itself.
            if op == "choose", answer["ok"] as? Bool == true {
                grants[token] = Grant(extensionID: context.uniqueIdentifier, space: space, made: Date(), sources: sources)
            }
            return answer
        // An id the worker was given, handed to getUserMedia in a page: only
        // while the yes it was given on still stands, and with the sources
        // the worker asked for.
        case "consume":
            guard let token = body["token"] as? String, let grant = grants.removeValue(forKey: token),
                  grant.extensionID == context.uniqueIdentifier, grant.space == space, Date().timeIntervalSince(grant.made) < 60,
                  host.extensionCaptureAllowed(context.uniqueIdentifier)
            else { return ["error": "NotAllowedError", "message": "Invalid state"] }
            return await record(in: web, token: token, video: video, window: window(sources.isEmpty ? grant.sources : sources), context: context)
        default:
            return ["error": "NotSupportedError", "message": "Unknown request"]
        }
    }

    /// Pages where eGlu's own call is under way, and the picker it asks for
    /// (1 a screen, 2 a window): WebKit's question about recording, from an
    /// extension's page, is yes only for these (displayDecision).
    private var inFlight: [ObjectIdentifier: Int] = [:]

    /// WebKit asking, for an extension's page, whether it may show the
    /// picker: WKDisplayCapturePermissionDecision, 0 no, 1 a screen, 2 a window.
    public func displayDecision(for view: NSView) -> Int {
        guard let web = view as? WKWebView else { return 0 }
        return inFlight[ObjectIdentifier(web)] ?? 0
    }

    private func record(in web: WKWebView, token: String, video: Any, window: Bool, context: WKWebExtensionContext) async -> [String: Any] {
        // An offscreen document has no window: it is lent to the pill while
        // it records. A page in a tab is brought forward.
        let lend = ExtensionOffscreen.reasons(of: web) != nil
        if lend { await host(web) } else { await bringForward(web) }
        inFlight[ObjectIdentifier(web)] = window ? 2 : 1
        let answer = await force(in: web, token: token, video: video, context: context)
        inFlight[ObjectIdentifier(web)] = nil
        if lend, answer["ok"] as? Bool != true { giveBack(web) }
        return answer
    }

    private func force(in web: WKWebView, token: String, video: Any, context: WKWebExtensionContext) async -> [String: Any] {
        do {
            // Called by the app, so WebKit counts it as a click: the page's
            // own getDisplayMedia, kept by the shim before any of the
            // extension's code ran, is called at once, before any await.
            let result = try await startExtensionRecording(in: web, token: token, video: video)
            guard let reply = result as? [String: Any] else { return ["error": "AbortError", "message": "No answer"] }
            if reply["ok"] as? Bool == true {
                watch(web, id: context.uniqueIdentifier)
                return ["ok": true, "token": token]
            }
            return reply
        } catch {
            return ["error": "AbortError", "message": error.localizedDescription]
        }
    }

    /// Offscreen pages lent to the pill, until their recording ends.
    private var lent: Set<ObjectIdentifier> = []

    /// Lent for a request that may never start: given back if nothing is
    /// recording in it half a minute on.
    private func lendAwhile(_ web: WKWebView) {
        guard !lent.contains(ObjectIdentifier(web)) else { return }
        lent.insert(ObjectIdentifier(web))
        host.lendExtensionCaptureView(web)
        if let id = web.url?.host() { watch(web, id: id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self, weak web] in
            guard let self, let web, !Self.capturing(web) else { return }
            self.giveBack(web)
        }
    }

    private func host(_ web: WKWebView) async {
        lent.insert(ObjectIdentifier(web))
        host.lendExtensionCaptureView(web)
        for _ in 0..<20 {
            if web.window?.isVisible == true, await extensionPageVisible(web) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func giveBack(_ web: WKWebView) {
        guard lent.remove(ObjectIdentifier(web)) != nil else { return }
        host.giveBackExtensionCaptureView(web)
    }

    /// WebKit won't start a recording in a page that isn't on screen: the
    /// tab showing it is selected and its window comes forward. Only after
    /// you said yes or just used the extension.
    private func bringForward(_ web: WKWebView) async {
        host.bringExtensionCaptureForward(web)
        for _ in 0..<20 {
            if web.window?.isVisible == true, web.window?.occlusionState.contains(.visible) == true,
               await extensionPageVisible(web) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: What is recording

    /// Pages of extensions that asked to capture, watched for as long as
    /// they last: whatever the extension's own code does, the pill says it.
    @MainActor
    private final class Watched {
        weak var web: WKWebView?
        let extensionID: String
        /// The space whose extension it is: one turned off there stops
        /// only what it records there.
        let space: UUID?
        var capturing = false
        init(_ web: WKWebView, _ id: String, _ space: UUID?) { self.web = web; self.extensionID = id; self.space = space }
    }

    private var watched: [ObjectIdentifier: Watched] = [:]
    private static let keys = ["cameraCaptureState", "microphoneCaptureState", "_displayCaptureState"]

    /// A camera or microphone question from an extension's page, or a
    /// recording it started: the page is watched.
    public func watch(_ view: NSView, id: String) {
        guard let web = view as? WKWebView else { return }
        let key = ObjectIdentifier(web)
        if let entry = watched[key], entry.web != nil { return changed() }
        watched[key] = Watched(web, id, spaceOf(web.configuration.webExtensionController))
        for path in Self.keys where path != "_displayCaptureState" || web.responds(to: NSSelectorFromString(path)) {
            web.addObserver(self, forKeyPath: path, options: [], context: nil)
        }
        changed()
    }

    /// A watched page going: its observers taken off before its view goes.
    public func unwatch(_ web: WKWebView) {
        guard let entry = watched.removeValue(forKey: ObjectIdentifier(web)) else { return }
        if entry.web === web {
            for path in Self.keys where path != "_displayCaptureState" || web.responds(to: NSSelectorFromString(path)) {
                web.removeObserver(self, forKeyPath: path)
            }
        }
        changed()
    }

    /// An extension's page closed (a tab's, a popup's, a side panel's, an
    /// offscreen document): whatever it records ends, a view lent to the
    /// pill goes back, and it is watched no more.
    public func release(_ view: NSView) {
        guard let web = view as? WKWebView else { return }
        if watched[ObjectIdentifier(web)]?.web === web { end(web) }
        giveBack(web)
        unwatch(web)
    }

    nonisolated public override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                           change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.changed() } }
    }

    public static func screen(_ view: NSView) -> Bool {
        guard let web = view as? WKWebView else { return false }
        guard web.responds(to: NSSelectorFromString("_displayCaptureState")) else { return false }
        return (web.value(forKey: "_displayCaptureState") as? Int ?? 0) != 0
    }

    /// Whether this page is recording anything.
    public static func capturing(_ web: WKWebView) -> Bool {
        screen(web) || web.cameraCaptureState != .none || web.microphoneCaptureState != .none
    }

    private func changed() {
        var lines: [String: (name: String, screen: Bool, camera: Bool, microphone: Bool)] = [:]
        for (key, entry) in watched {
            // A page gone: WebKit's views let their observers go with them.
            guard let web = entry.web else { watched[key] = nil; continue }
            let now = Self.capturing(web)
            // Stopped: an offscreen page lent to the pill goes back.
            if entry.capturing, !now { giveBack(web) }
            entry.capturing = now
            guard now else { continue }
            let before = lines[entry.extensionID]
            let name = host.extensionCaptureName(entry.extensionID)
            lines[entry.extensionID] = (name, (before?.screen ?? false) || Self.screen(web),
                                        (before?.camera ?? false) || web.cameraCaptureState != .none,
                                        (before?.microphone ?? false) || web.microphoneCaptureState != .none)
        }
        host.updateExtensionCapture(lines.map { id, line in
            ExtensionCaptureState(id: id, name: line.name, screen: line.screen, camera: line.camera, microphone: line.microphone)
        })
    }

    private typealias SetDisplay = @convention(c) (AnyObject, Selector, Int, (@convention(block) () -> Void)?) -> Void

    /// Stop: everything the extension is capturing ends, and its pages see
    /// their tracks end.
    public func stop(_ id: String, in space: UUID? = nil) {
        for entry in watched.values where entry.extensionID == id && (space == nil || entry.space == space) {
            guard let web = entry.web else { continue }
            end(web)
        }
    }

    private func end(_ web: WKWebView) {
        let selector = NSSelectorFromString("_setDisplayCaptureState:completionHandler:")
        if web.responds(to: selector), let method = class_getMethodImplementation(type(of: web), selector) {
            unsafeBitCast(method, to: SetDisplay.self)(web, selector, 0, nil)
        }
        web.setCameraCaptureState(.none, completionHandler: nil)
        web.setMicrophoneCaptureState(.none, completionHandler: nil)
    }

    /// The extension went away in a space: what it records there stops,
    /// and its ids there with it.
    public func purge(_ id: String, in space: UUID) {
        stop(id, in: space)
        grants = grants.filter { $0.value.extensionID != id || $0.value.space != space }
    }

    /// Whether an extension's own page is seen, as WebKit counts it; never
    /// asked of a website's.
    func extensionPageVisible(_ web: WKWebView) async -> Bool {
        guard web.url?.scheme?.lowercased() == scheme else { return false }
        return (try? await web.evaluateJavaScript("document.visibilityState")) as? String == "visible"
    }

    /// The shim's recording call in an extension's own page, made by the
    /// app so WebKit counts it as a click (ExtensionCapture.force); never in
    /// a website's.
    func startExtensionRecording(in web: WKWebView, token: String, video: Any) async throws -> Any? {
        guard web.url?.scheme?.lowercased() == scheme else { return nil }
        return try await web.callAsyncJavaScript("return await globalThis[Symbol.for('eglu.capture')](token, video);",
                                                 arguments: ["token": token, "video": video], in: nil, contentWorld: .page)
    }

    // MARK: Test runs

    /// WebKit's pretend camera, microphone and screen, so a test run
    /// records with no hardware and no macOS question (-extensionMockCapture YES).
    public static func mockDevices(_ preferences: WKPreferences, enabled: Bool = true) {
        guard enabled else { return }
        set("_setMockCaptureDevicesEnabled:", true, in: preferences)
        set("_setGetUserMediaRequiresFocus:", false, in: preferences)
    }

    /// One of WebKit's preferences it doesn't make public, if it has it.
    public static func set(_ name: String, _ on: Bool, in preferences: WKPreferences) {
        let selector = NSSelectorFromString(name)
        guard preferences.responds(to: selector), let method = class_getMethodImplementation(type(of: preferences), selector) else { return }
        typealias Set = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method, to: Set.self)(preferences, selector, on)
    }
}

/// The UI delegate of a tab showing one of an extension's pages: WebKit's
/// question about recording the screen is answered here, yes only while
/// eGlu's own call is under way in that page (ExtensionCapture.record), no
/// for anything else, however the extension got hold of getDisplayMedia.
/// Everything else goes on to the page, as for any tab. Websites' pages
/// don't have one, and keep WebKit's own way.
public final class ExtensionPageDelegate: NSObject, WKUIDelegate {
    weak var next: (any WKUIDelegate)?

    private let capture: () -> ExtensionCaptureRuntime

    public init(next: any WKUIDelegate, capture: @escaping () -> ExtensionCaptureRuntime) {
        self.next = next
        self.capture = capture
    }

    public override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (next?.responds(to: selector) ?? false)
    }

    public override func forwardingTarget(for selector: Selector!) -> Any? {
        next
    }

    @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
    public func displayCapture(_ web: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo, systemAudio: Bool,
                        decisionHandler: @escaping (Int) -> Void) {
        MainActor.assumeIsolated { decisionHandler(capture().displayDecision(for: web)) }
    }

    /// The camera or microphone: WebKit's own question, as a website's
    /// page gets; the page is watched, so the pill says it while it lasts.
    public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        MainActor.assumeIsolated {
            if let id = webView.url?.host() { capture().watch(webView, id: id) }
        }
        decisionHandler(.prompt)
    }
}

#endif
