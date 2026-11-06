import AppKit
import PadCore
import SwiftUI
import WebKit

/// Apple Passwords under the sign-in box, the way Safari offers them,
/// without the iCloud Passwords extension.
///
/// There is no public way for a browser to ask the Mac's Passwords app for a
/// site's accounts: AuthenticationServices hands an app only its own
/// associated domains' passwords, and WebKit's AutoFill is Safari's. What
/// Apple gives other browsers is a helper its Chrome extension talks to.
/// eGlu runs that helper itself, as Chrome would, and speaks the
/// extension's protocol (PadCore's ApplePasswordsProtocol and
/// ApplePasswordsSession):
///
/// - The helper answers only Apple's extension's id, which eGlu gives. That
///   is the unofficial part, and why this is off unless turned on in
///   Settings › General › Passwords.
/// - macOS starts the helper only for a browser it names or one signed with
///   Apple's passkey entitlement for browsers
///   (com.apple.developer.web-browser.public-key-credential): in any other
///   build, nothing here is offered, no script goes into a page and the
///   helper is never run.
/// - Pairing is the person's doing: Connect starts it, the helper shows its
///   own six-digit code, typed into a card under the sign-in box. The key
///   lives in memory and dies with the helper; the next launch asks again.
/// - Only names are asked for, when the caret is in a sign-in box on an
///   https page; a password once its account is picked (macOS may ask for
///   Touch ID then), and it goes into the page's own fields, checked again
///   to be the same host, and is not kept. Never in a frame, never over
///   plain http, never on Google's sign-in (HandsOff), and only accounts
///   kept for the page's own site.
///
/// Search's (github.com/driceroland/Search, MIT: cf538b8, 764d54f, 53b92d5,
/// e38bc87), with eGlu's own cards.
@MainActor
enum ApplePasswords {
    static let entitlement = "com.apple.developer.web-browser.public-key-credential"
    static let switchKey = "applePasswords"

    /// Whether the running app is signed with Apple's passkey entitlement
    /// for browsers, without which macOS kills the helper as it starts.
    static let entitled: Bool = {
        #if DEBUG
        // A test copy, with a stand-in helper (-applePasswordsTest YES).
        if UserDefaults.standard.bool(forKey: "applePasswordsTest") { return true }
        #endif
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil)
        else { return false }
        return (value as? Bool) == true
    }()

    /// The helper's program: Apple's, on the system volume and signed by
    /// Apple; in a DEBUG test copy, a stand-in (-applePasswordsHelper).
    static func program() -> URL? {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "applePasswordsTest") {
            return UserDefaults.standard.string(forKey: "applePasswordsHelper").map { URL(fileURLWithPath: $0) }
        }
        #endif
        return AppleHelper.program()
    }

    /// Whether this Mac can run a helper at all, read once.
    static let helperHere: Bool = entitled && program() != nil

    /// Turned on in Settings, in a build that may run the helper.
    static var on: Bool {
        entitled && UserDefaults.standard.bool(forKey: switchKey)
    }

    /// The one pairing, for the whole app.
    static let session: ApplePasswordsSession = {
        let session = ApplePasswordsSession {
            guard entitled else { throw ApplePasswordsSession.Unavailable(errorDescription: String(localized: "This copy of eGlu can't run Apple's Passwords helper")) }
            guard let program = program() else {
                throw ApplePasswordsSession.Unavailable(errorDescription: String(localized: "Apple's Passwords helper isn't on this Mac"))
            }
            return HelperLink(program: program)
        }
        // Off, or eGlu quitting: the helper is told goodbye and stopped,
        // and the key goes with it.
        switchWatch = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if !on, session.state != .idle { session.disconnect() } }
        }
        quitWatch = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { session.disconnect() }
        }
        return session
    }()

    private static var switchWatch: NSObjectProtocol?
    private static var quitWatch: NSObjectProtocol?

    /// Whether a page's sign-in boxes get the script: an https page (an
    /// http one of this Mac's in a test copy), not Google's sign-in, not an
    /// extension's page, where the switch is on or it may be offered.
    static func serves(_ url: URL?) -> Bool {
        _ = watching
        guard entitled, helperHere, ApplePasswordsSession.offers(on: url) != nil || testPage(url) else { return false }
        return on || !ApplePasswordsOffer(store: .standard).retired
    }

    /// The switch as last seen, to tell the pages open now when it turns on.
    private static var wasOn = on
    private static let watching: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { _ in
        MainActor.assumeIsolated {
            let now = on
            defer { wasOn = now }
            guard now, !wasOn else { return }
            // Turned on in Settings: sign-in boxes on the pages open now
            // get the script too, not only those loaded from now on.
            for page in Session.shared.pages.live.values { page.applePasswordsTurnedOn() }
        }
    }

    private static func testPage(_ url: URL?) -> Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "applePasswordsTest") && url?.scheme == "http" && url?.host() == "127.0.0.1"
        #else
        return false
        #endif
    }

    /// The host a page's accounts are asked for.
    static func host(of url: URL?) -> String? {
        ApplePasswordsSession.offers(on: url) ?? (testPage(url) ? url?.host() : nil)
    }
}

/// Apple's helper, run over Chrome's framing (HostPipe).
@MainActor
final class HelperLink: AppleLink {
    var onMessage: (([String: Any]) -> Void)?
    var onEnd: (() -> Void)?
    private let pipe: HostPipe

    init(program: URL) {
        pipe = HostPipe(program: program, origin: AppleHelper.origin)
        pipe.onMessage = { [weak self] message in
            guard let message = message as? [String: Any] else { return }
            nonisolated(unsafe) let sent = message
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onMessage?(sent) } }
        }
        pipe.onExit = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onEnd?() } }
        }
    }

    func start() throws { try pipe.start() }
    func send(_ message: [String: Any]) throws { try pipe.write(message) }
    func stop() { pipe.stop() }
}

// MARK: The sign-in box

/// The page's sign-in boxes, in the app's own world, the main frame only:
/// where the caret is (a name or a password box of a form with a password),
/// and the fill, which checks again that the page is still the host it was
/// asked for (764d54f).
enum ApplePasswordsForm {
    static let name = "egluApplePasswords"

    static let script = """
    (() => {
      if (window.top !== window) return;
      const post = (body) => { try { window.webkit.messageHandlers.\(name).postMessage(body); } catch (e) {} };
      const kindOf = (el) => {
        if (!(el instanceof HTMLInputElement) || el.disabled || el.readOnly) return null;
        const type = (el.type || "text").toLowerCase();
        if (type === "password") return "password";
        const scope = el.form || document;
        const auto = (el.autocomplete || "").toLowerCase();
        if (auto.includes("username")) return "user";
        if (["text", "email", "tel"].includes(type) && scope.querySelector('input[type="password" i]')) return "user";
        return null;
      };
      let field = null;
      const tell = () => {
        if (!field || !field.isConnected) return;
        const r = field.getBoundingClientRect();
        post({ kind: "focus", field: kindOf(field), x: r.left, y: r.top, width: r.width, height: r.height });
      };
      document.addEventListener("focusin", (e) => {
        if (!kindOf(e.target)) return;
        field = e.target;
        tell();
      }, true);
      document.addEventListener("focusout", (e) => {
        if (e.target !== field) return;
        setTimeout(() => { if (document.activeElement !== field) { field = null; post({ kind: "blur" }); } }, 150);
      }, true);
      window.addEventListener("scroll", () => { if (field) tell(); }, { passive: true, capture: true });
      window.addEventListener("resize", () => { if (field) tell(); });
      window.addEventListener("focus", () => { if (field && document.activeElement === field) tell(); });
      // focusin doesn't fire again for a box that already had the caret
      // before this script ran (autofocused, or the switch just turned on).
      if (kindOf(document.activeElement)) { field = document.activeElement; tell(); }
      const set = (el, value) => {
        Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set.call(el, value);
        el.dispatchEvent(new Event("input", { bubbles: true }));
        el.dispatchEvent(new Event("change", { bubbles: true }));
      };
      globalThis.__egluApplePasswordsFill = (host, user, password) => {
        if (location.hostname !== host || !field || !field.isConnected) return false;
        const scope = field.form || document;
        const boxes = [...scope.querySelectorAll("input")];
        const secret = kindOf(field) === "password" ? field : boxes.find((b) => kindOf(b) === "password");
        const before = secret ? boxes.slice(0, boxes.indexOf(secret)) : boxes;
        const name = kindOf(field) === "user" ? field : before.filter((b) => kindOf(b) === "user").pop();
        if (name && user) set(name, user);
        if (secret && password) set(secret, password);
        return true;
      };
    })();
    """
}

/// What the sign-in box script tells the Mac: the main frame's own
/// messages, in the app's own world, on a page Apple Passwords serves.
@MainActor
final class ApplePasswordsHandler: NSObject, WKScriptMessageHandler {
    private weak var page: Page?

    init(page: Page) {
        self.page = page
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            // From the document shown now: one being left as the page goes
            // elsewhere speaks for its own site, not the new one's.
            let origin = message.frameInfo.securityOrigin
            guard let page, message.frameInfo.isMainFrame, message.world == Page.world, !page.isHandsOff,
                  ApplePasswords.serves(page.view.url), origin.host.lowercased() == page.view.url?.host()?.lowercased(),
                  origin.protocol.lowercased() == page.view.url?.scheme?.lowercased(),
                  let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
            switch kind {
            case "focus":
                let number = { (key: String) in (body[key] as? NSNumber)?.doubleValue ?? 0 }
                let rect = CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height"))
                ApplePasswordsCard.shared.focused(page, field: rect, password: body["field"] as? String == "password")
            case "blur":
                ApplePasswordsCard.shared.left(page)
            default:
                break
            }
        }
    }
}

// MARK: The cards

/// What comes up under a sign-in box: the accounts the Passwords app keeps
/// for the site; Connect Apple Passwords… while it isn't paired; or, with
/// the switch off, once per site, "Use your Apple passwords?". And the card
/// the helper's code is typed into, where the list was (53b92d5).
@MainActor
final class ApplePasswordsCard: ObservableObject {
    static let shared = ApplePasswordsCard()

    enum Showing: Equatable {
        case none
        case asking
        case accounts([AppleLogin])
        case connect
        case offer(site: String)
        case pairing
    }

    @Published private(set) var showing: Showing = .none
    @Published var code = ""

    private weak var page: Page?
    private var host = ""
    /// The field's place on screen, AppKit's coordinates.
    private var anchor: CGRect = .zero
    /// The field as the page said it, to show its accounts again once paired.
    private var field: (rect: CGRect, password: Bool)?
    private let panel = PopupPanel()
    private let keyPanel = KeyPanel()
    private var offerShown: String?
    private var asking: Task<Void, Never>?
    private var pairing: Task<Void, Never>?
    /// The box that had the card when eGlu went behind another app, to bring
    /// its card back if the same page and box are still in front on return.
    private struct Resigned {
        weak var page: Page?
        let host: String
        let field: (rect: CGRect, password: Bool)
    }
    private var resigned: Resigned?

    private var session: ApplePasswordsSession { ApplePasswords.session }

    /// A sign-in box has the caret: what to show under it.
    func focused(_ page: Page, field: CGRect, password: Bool) {
        guard page.host?.isShowing(page) == true, let host = ApplePasswords.host(of: page.view.url),
              let screen = Self.screenRect(of: field, in: page.view)
        else { return }
        if showing == .pairing { return }
        let same = self.page === page && self.host == host
        self.page = page
        self.host = host
        anchor = screen
        self.field = (field, password)
        resigned = nil
        _ = resigning
        _ = activating
        // The same box, moved as the page scrolled or resized: the list, or
        // the question on its way, moves with it, not asked again.
        if same, ApplePasswords.on, session.state == .paired {
            switch showing {
            case .asking, .accounts: return show(showing)
            default: break
            }
        }
        asking?.cancel()
        if ApplePasswords.on {
            guard session.state == .paired else { return show(.connect) }
            show(.asking)
            let tab = page.tab
            asking = Task { [weak self] in
                // Asked only if still wanted when its turn comes: one
                // given up is never sent to the helper.
                let names = await ApplePasswords.session.logins(for: host, tab: tab) {
                    !Task.isCancelled && self?.page === page && self?.host == host
                        && page.host?.isShowing(page) == true && page.surface.view.window != nil
                }
                guard let self, !Task.isCancelled, self.page === page, self.host == host,
                      page.host?.isShowing(page) == true, page.surface.view.window != nil,
                      ApplePasswords.host(of: page.view.url) == host
                else { return }
                let mine = names.filter { ApplePasswordsSession.belongs($0.sites.isEmpty ? [host] : $0.sites, to: host, wide: true) }
                self.show(mine.isEmpty ? .none : .accounts(mine))
            }
        } else {
            // The offer up for this field already: the page scrolled or
            // resized, and it moves with the field.
            if same, case .offer(let site) = showing, offerShown == site { return show(.offer(site: site)) }
            let offer = ApplePasswordsOffer(store: .standard)
            let field = ApplePasswordsOffer.Field(page: page.view.url)
            guard let site = offer.site(for: field, .init(appleOn: false, helper: ApplePasswords.helperHere)) ?? testSite(page) else {
                return show(.none)
            }
            if offerShown != site { offer.shown(on: site) }
            offerShown = site
            show(.offer(site: site))
        }
    }

    private func testSite(_ page: Page) -> String? {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "applePasswordsTest"), page.view.url?.host() == "127.0.0.1" { return "127.0.0.1" }
        #endif
        return nil
    }

    /// The caret left the box, or its page left the screen.
    func left(_ page: Page) {
        if resigned?.page === page { resigned = nil }
        guard self.page === page else { return }
        if showing == .pairing {
            self.page = nil
            self.field = nil
            return
        }
        dismiss()
    }

    /// eGlu no longer in front: the card goes, so a site's account names
    /// don't float over another app. The pairing card stays, as its code
    /// is read from the helper's own window.
    private lazy var resigning: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
        MainActor.assumeIsolated {
            guard let self, self.showing != .none, self.showing != .pairing else { return }
            if let page = self.page, let field = self.field {
                self.resigned = Resigned(page: page, host: self.host, field: field)
            }
            self.dismiss(unansweredOffer: false)
        }
    }

    /// eGlu in front again: if the sign-in box that had the card is still
    /// the one on screen, its card comes back without waiting for a scroll
    /// or another click in the box.
    private lazy var activating: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
        MainActor.assumeIsolated {
            guard let self, let resigned = self.resigned else { return }
            self.resigned = nil
            guard self.showing == .none, let page = resigned.page,
                  page.host?.isShowing(page) == true, page.surface.view.window != nil,
                  ApplePasswords.host(of: page.view.url) == resigned.host
            else { return }
            self.focused(page, field: resigned.field.rect, password: resigned.field.password)
        }
    }

    private func dismiss(unansweredOffer: Bool = true) {
        guard showing != .pairing else { return }
        if unansweredOffer, case .offer = showing { ApplePasswordsOffer(store: .standard).unanswered() }
        if unansweredOffer { offerShown = nil }
        // A list still on its way is not to come up after the caret left.
        asking?.cancel()
        asking = nil
        self.page = nil
        if showing != .none { show(.none) }
    }

    // MARK: What the rows do

    /// An account picked: its password asked for, then put in the page's
    /// own fields if it is still the same host.
    func pick(_ login: AppleLogin) {
        guard let page else { return }
        let host = self.host
        show(.none)
        Task {
            guard let found = await session.password(for: login.user, host: host, tab: page.tab),
                  // Only a password kept for this site: an answer meant for
                  // another question (one that ran out of time) is not used.
                  ApplePasswordsSession.belongs(found.sites.isEmpty ? [host] : found.sites, to: host, wide: true)
            else { return }
            await page.fillApplePassword(host: host, user: login.user, password: found.password)
        }
    }

    /// The offer taken: the switch on, and the pairing started.
    func takeOffer() {
        offerShown = nil
        UserDefaults.standard.set(true, forKey: ApplePasswords.switchKey)
        connect()
    }

    /// The offer's ✕: not offered again, anywhere.
    func declineOffer() {
        ApplePasswordsOffer(store: .standard).dismissed()
        offerShown = nil
        show(.none)
    }

    /// Connect: the helper runs and shows its code; the code card comes up
    /// where the list was.
    func connect() {
        pairing?.cancel()
        code = ""
        show(.pairing)
        pairing = Task { [weak self] in
            guard let self else { return }
            await self.session.connect()
            guard !Task.isCancelled, self.showing == .pairing else { return }
            if self.session.state != .code { self.finishPairing() }
            #if DEBUG
            // A test copy's stand-in helper's code (-applePasswordsCode).
            if let code = UserDefaults.standard.string(forKey: "applePasswordsCode"), self.session.state == .code { self.typed(code) }
            #endif
        }
    }

    /// The code, as it is typed: sent once it has six digits.
    func typed(_ text: String) {
        let digits = String(text.filter(\.isNumber).prefix(6))
        if digits != code { code = digits }
        guard digits.count == 6, session.state == .code else { return }
        pairing?.cancel()
        pairing = Task { [weak self] in
            guard let self else { return }
            await self.session.enter(digits)
            guard !Task.isCancelled, self.showing == .pairing else { return }
            if self.session.state == .paired { self.finishPairing() } else {
                self.code = ""
                // A wrong code ends the helper's handshake: Connect again,
                // from the card, starts a new one.
                if self.session.state != .code { self.show(.connect) }
            }
        }
    }

    /// Cancel or Esc: the helper stops, unless a pairing was already made.
    func cancelPairing() {
        pairing?.cancel()
        pairing = nil
        if session.state != .paired { session.disconnect() }
        finishPairing()
    }

    /// The card goes, and the page has the keys again, with its box's
    /// accounts up once paired.
    private func finishPairing() {
        show(.none)
        guard let page, let window = page.surface.view.window else { return }
        window.makeKeyAndOrderFront(nil)
        page.surface.focus()
        if session.state == .paired, let field { focused(page, field: field.rect, password: field.password) }
    }

    // MARK: On screen

    private func show(_ next: Showing) {
        showing = next
        #if DEBUG
        // A test copy pairs and picks by itself (-applePasswordsCode, -applePasswordsPick YES).
        if next == .connect, UserDefaults.standard.string(forKey: "applePasswordsCode") != nil {
            DispatchQueue.main.async { self.connect() }
        }
        if case .accounts(let logins) = next, UserDefaults.standard.bool(forKey: "applePasswordsPick"), let first = logins.first {
            DispatchQueue.main.async { self.pick(first) }
        }
        #endif
        switch next {
        case .none, .asking:
            panel.orderOut(nil)
            keyPanel.orderOut(nil)
        case .pairing:
            panel.orderOut(nil)
            place(keyPanel, view: ApplePasswordsPairingView(card: self), key: true)
        default:
            keyPanel.orderOut(nil)
            place(panel, view: ApplePasswordsListView(card: self), key: false)
        }
    }

    private func place<V: View>(_ window: NSPanel, view: V, key: Bool) {
        let hosting = FirstClickHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - 4 - size.height)
        if origin.y < screen.minY { origin.y = anchor.maxY + 4 }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        if key {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    /// A rect of the page's (CSS pixels from its top left), on screen.
    private static func screenRect(of rect: CGRect, in view: WKWebView) -> CGRect? {
        guard let window = view.window else { return nil }
        let zoom = view.pageZoom * view.magnification
        let scaled = CGRect(x: rect.minX * zoom, y: rect.minY * zoom, width: rect.width * zoom, height: rect.height * zoom)
        let local = view.isFlipped ? scaled : CGRect(x: scaled.minX, y: view.bounds.height - scaled.maxY, width: scaled.width, height: scaled.height)
        return window.convertToScreen(view.convert(local, to: nil))
    }
}

/// The pairing card's panel: it takes the keys, for the code.
private final class KeyPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { ApplePasswordsCard.shared.cancelPairing() }
    }
}

/// The list under the box.
private struct ApplePasswordsListView: View {
    @ObservedObject var card: ApplePasswordsCard

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch card.showing {
            case .accounts(let logins):
                Text("Apple Passwords").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 6)
                ForEach(logins) { login in
                    Button { card.pick(login) } label: {
                        Label(login.user, systemImage: "key.fill").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                }
            case .connect:
                Button { card.connect() } label: {
                    Label("Connect Apple Passwords\u{2026}", systemImage: "key.fill").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(10)
                if let trouble = ApplePasswords.session.trouble {
                    Text(trouble).font(.caption).foregroundStyle(.secondary).padding([.horizontal, .bottom], 10)
                }
            case .offer:
                HStack {
                    Button { card.takeOffer() } label: {
                        Label("Use your Apple passwords?", systemImage: "key.fill")
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 12)
                    Button { card.declineOffer() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "Don't Offer Again"))
                }
                .padding(10)
            default:
                EmptyView()
            }
        }
        .frame(minWidth: 240)
        .padding(.bottom, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .fixedSize()
    }
}

/// The card the helper's code is typed into.
private struct ApplePasswordsPairingView: View {
    @ObservedObject var card: ApplePasswordsCard
    @ObservedObject private var session = ApplePasswords.session
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect Apple Passwords").font(.headline)
            Text(session.state == .starting ? String(localized: "Starting Apple's Passwords helper\u{2026}")
                 : String(localized: "Type the six-digit code the Passwords helper shows."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(String(localized: "Code"), text: Binding(get: { card.code }, set: { card.typed($0) }))
                .textFieldStyle(.roundedBorder)
                .font(.title3.monospacedDigit())
                .focused($typing)
                .disabled(session.state != .code)
            if let trouble = session.trouble {
                Text(trouble).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { card.cancelPairing() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(14)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear { typing = true }
        .onChange(of: session.state) { _, state in if state == .code { typing = true } }
    }
}

/// Settings › General › Passwords: the switch, and the pairing as it stands.
struct ApplePasswordsSettings: View {
    @AppStorage(ApplePasswords.switchKey) private var on = false
    @ObservedObject private var session = ApplePasswords.session

    var body: some View {
        Section {
            Toggle("Apple Passwords under sign-in boxes", isOn: $on)
                .disabled(!ApplePasswords.helperHere)
            if on {
                LabeledContent("Apple's Passwords helper") {
                    if session.state == .paired {
                        Button("Disconnect") { session.disconnect() }
                    } else {
                        Text("Connects from a sign-in box").foregroundStyle(.secondary)
                    }
                }
            }
            if let trouble = session.trouble {
                Text(trouble).foregroundStyle(.secondary)
            }
        } header: {
            Text("Passwords")
        } footer: {
            Text("Your accounts from the Passwords app come up under a site's sign-in box, through Apple's own helper. It asks for a six-digit code once each time eGlu opens. A password is filled only when you pick its account, and is not kept.")
        }
    }
}
