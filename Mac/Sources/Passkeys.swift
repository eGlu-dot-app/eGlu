import AppKit
import AuthenticationServices
import CryptoKit
import OSLog
import PadCore
import Security
import SwiftUI
import WebEngineAppKit
import WebEngineCore

// Passkeys and security keys, for a browser that isn't Safari. Copied from
// Search (github.com/driceroland/Search, MIT, its Passkeys.swift), with
// eGlu's names, its checks moved to PadCore (PasskeyRequest.swift) where
// they are tested, and the list under the sign-in field made for eGlu,
// which has no password list of its own for it to join.
//
// Only in a build signed with Apple's passkey entitlement for browsers
// (com.apple.developer.web-browser.public-key-credential), which Apple grants
// on request and which only a build signed with a provisioning profile that
// carries it may have (Release/mac.sh, PASSKEYS=1). Without it nothing here
// runs: no script goes into a page, no channel is opened, and pages see the
// engine's own navigator.credentials as they always have. Nor on a
// hands-off host (HandsOff), which gets no script of eGlu's in any build:
// Google's sign-in keeps the engine's own, so its passkeys are left out.
//
// It talks to pages only through the engine's contracts (WebEngineCore): a
// channel in the app's world, scripts in either world, and the origin and
// frame the engine records for each message, never one its body states.
//
// Left to WebKit, a site's request fails: WebKit answers navigator.credentials
// itself only for the app's own associated domains, and hands any other
// site's to AuthenticationServices in a way it refuses before any sheet, the
// entitlement notwithstanding (Search, 24 September 2026). And a sign-in page
// that offers your passkey under its name field (conditional mediation) has
// WebKit open an AutoFill operation with macOS's AuthenticationServicesAgent,
// held for as long as the page waits. If the app dies meanwhile (quit, crash,
// killed) the agent never lets go of it, and refuses every passkey request
// the app makes after that, before any sheet, until the Mac restarts: Search
// found that the same day.
//
// So eGlu carries the ceremony itself, as Chrome and Firefox do on the Mac,
// and never opens that operation: it takes the request from the page
// (passkeys.js), checks it against the frame it came from, and hands it to
// AuthenticationServices through the API made for browsers, with client data
// it writes: the origin in it is the one the engine reports for the frame,
// never one the page states. The Mac's own sheet answers, with Touch ID and the
// passkeys in iCloud Keychain or a password app, an iPhone nearby over the QR
// code, or a security key, and what comes back goes to the page as the
// credential WebKit would have made.
//
// A sign-in page that offers your passkey under its name field gets the
// same, carried the same way: the request is checked and kept, waiting, and
// the Mac is asked only which passkeys it holds for the site, a question with
// no sheet and no operation left open. They are listed under the field while
// it has the keyboard (PasskeyList), and nothing reaches the page until you
// pick one: then the Mac's sheet, for that passkey alone, and the page's
// waiting request is answered with it. A new page, the page letting it go,
// or the page asking again ends the wait.
@MainActor
final class Passkeys: NSObject {
    static let shared = Passkeys()

    static let log = Logger(subsystem: "net.taehee.safience", category: "Passkeys")

    // MARK: Whether this build has them

    static let entitlement = "com.apple.developer.web-browser.public-key-credential"

    /// Whether the running app is signed with Apple's passkey entitlement for
    /// browsers. Asked of the process's own signature, as Session.canSync asks
    /// about iCloud: that is the only thing that decides it, and a profile in
    /// the bundle proves nothing on its own.
    static let entitled: Bool = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil)
        else { return false }
        return (value as? Bool) == true
    }()

    /// A test build's run with made-up passkeys, from the shell or Xcode:
    /// `-passkeyRehearsal YES`. Pages get eGlu's passkeys without the
    /// entitlement, every check is made as for real, and the answer is a
    /// credential made up on the spot (PasskeyReply.rehearsal), so neither
    /// macOS's question nor its sheet ever comes up and no real passkey is
    /// listed. Never in a release build.
    static let rehearsal: Bool = {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "passkeyRehearsal")
        #else
        false
        #endif
    }()

    /// Whether pages get eGlu's passkeys: in a build with the entitlement, and
    /// in a rehearsal. `defaults write net.taehee.safience passkeyRelay -bool
    /// NO` leaves an entitled build's pages with the engine's own instead, to tell
    /// a fault of eGlu's from one of macOS's; sites' passkeys then fail as
    /// they do without the entitlement. Read once at launch: a page's scripts
    /// go in before it loads.
    static let relayed: Bool = {
        if rehearsal { return true }
        guard entitled else { return false }
        return UserDefaults.standard.object(forKey: "passkeyRelay") as? Bool ?? true
    }()

    // MARK: The Mac's permission

    /// Whether this Mac lets eGlu use its passkeys at all: a question macOS
    /// puts once to a browser other than Safari, the answer kept in System
    /// Settings › Privacy & Security.
    private static var access: ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState {
        ASAuthorizationWebBrowserPublicKeyCredentialManager().authorizationStateForPlatformCredentials
    }

    /// Everyone waiting on that question while it is on screen.
    private static var asking: [() -> Void]?

    /// Asked before the first ceremony, where it makes sense (a site has just
    /// asked for a passkey), and then never again.
    private static func ensure(_ then: @escaping () -> Void) {
        guard entitled, access == .notDetermined else { return then() }
        if asking != nil {
            asking?.append(then)
            return
        }
        asking = [then]
        ASAuthorizationWebBrowserPublicKeyCredentialManager().requestAuthorizationForPublicKeyCredentials { _ in
            DispatchQueue.main.async {
                let everyone = asking ?? []
                asking = nil
                everyone.forEach { $0() }
            }
        }
    }

    // MARK: A ceremony

    /// The one on screen, and whom to answer when it ends. A new request ends
    /// the one before, as a page asking twice gets in any browser.
    private var controller: ASAuthorizationController?
    /// The page's one-time key for this request's PRF results (PasskeyReply.prf).
    private var prfKey: P256.KeyAgreement.PublicKey?
    /// Whether the request asked for PRF at all.
    private var wantedPRF = false
    private var token: String?
    private var answer: (([String: Any]) -> Void)?
    private weak var anchor: NSWindow?
    /// The page whose request it is: a new document there, or the tab
    /// closing, ends it, so its sheet never stays over another site.
    private weak var asker: Page?
    /// Called off by their pages before they could start.
    private var withdrawn: Set<String> = []
    /// Requests waiting on macOS's question, each with its page: a new
    /// document there (forget) lets that page's go, though it be of the
    /// same site.
    private var awaiting: [UUID: ObjectIdentifier] = [:]

    /// Where a request came from, as the engine knows it rather than as the page says.
    struct Caller {
        let frame: PasskeyFrame
        /// The page, for a request that waits under its field.
        weak var page: Page?
    }

    func cancel(token: String?) {
        guard let token else { return }
        if let (key, waiting) = conditional.first(where: { $0.value.token == token }) {
            conditional[key] = nil
            waiting.answer(PasskeyFailure.aborted.reply)
            list.close(for: waiting.page)
            return
        }
        if token == self.token {
            let running = controller
            finish(PasskeyFailure.aborted.reply)
            running?.cancel()
        } else {
            withdrawn.insert(token)
        }
    }

    func perform(_ body: [String: Any], from caller: Caller, answer: @escaping ([String: Any]) -> Void) {
        guard let request = PasskeyRequest(body) else {
            return refuse(answer, PasskeyFailure("NotSupportedError", "Not a passkey request."))
        }
        // The page in front of you only (inFront). A rehearsal from the shell
        // is always behind.
        let focused = Self.rehearsal || Self.inFront(caller.page)
        let passed: PasskeyCheck.Passed
        switch PasskeyCheck.verdict(for: request, from: caller.frame, focused: focused, hasView: caller.page != nil,
                                    isSuffix: Self.isSuffix) {
        case .wait:
            return answer(PasskeyFailure.wait.reply)
        case .refused(let failure):
            return refuse(answer, failure)
        case .passed(let checked):
            passed = checked
        }
        // The verdict passes no request without a challenge.
        guard let challenge = request.challenge else { return refuse(answer, PasskeyFailure.notAllowed) }
        var clientData = ASPublicKeyCredentialClientData(challenge: challenge, origin: passed.origin)
        if let top = passed.topOrigin {
            clientData.topOrigin = top
            clientData.crossOrigin = .crossOrigin
        }

        if passed.underField, let page = caller.page {
            return wait(request, passed: passed, clientData: clientData, in: page, answer: answer)
        }
        // A request of the page's own, with a sheet: the one waiting under the
        // field is over, as in any browser. One from a frame leaves it, but
        // not its list over the sheet.
        if let page = caller.page {
            list.close(for: page)
            if caller.frame.isMain, let waiting = conditional.removeValue(forKey: ObjectIdentifier(page)) {
                waiting.answer(PasskeyFailure.replaced.reply)
            }
        }

        Self.log.notice("\(request.kind.rawValue, privacy: .public) for \(passed.rp, privacy: .public) from \(passed.origin, privacy: .public)")
        if Self.rehearsal {
            var reply = PasskeyReply.rehearsal(request.kind, origin: passed.origin, topOrigin: passed.topOrigin, challenge: challenge)
            if request.prf != nil {
                reply["prf"] = PasskeyReply.rehearsalPRF(enabled: request.kind == .create ? true : nil, for: PasskeyReply.pageKey(request))
            }
            return answer(reply)
        }
        let requests = request.kind == .get
            ? Self.assertion(request, rp: passed.rp, clientData: clientData)
            : Self.registration(request, rp: passed.rp, clientData: clientData)
        let pageOrigin = PasskeyCheck.origin(of: Self.committed(caller.page))
        let ticket = UUID()
        if let page = caller.page { awaiting[ticket] = ObjectIdentifier(page) }
        Self.ensure { [weak self, weak page = caller.page] in
            guard let self else { return }
            let current = self.awaiting.removeValue(forKey: ticket) != nil
            if let token = request.token, self.withdrawn.remove(token) != nil {
                return answer(PasskeyFailure.aborted.reply)
            }
            // macOS's question may have been on screen a while: the document
            // must still be there, the same site's, and in front.
            guard current, let page, PasskeyCheck.origin(of: Self.committed(page)) == pageOrigin, Self.inFront(page) else {
                return answer(PasskeyFailure.notAllowed.reply)
            }
            self.begin(requests, token: request.token, from: page, answer: answer)
            self.prfKey = PasskeyReply.pageKey(request)
            self.wantedPRF = request.prf != nil
        }
    }

    private func begin(_ requests: [ASAuthorizationRequest], token: String?, from page: Page,
                       answer: @escaping ([String: Any]) -> Void) {
        if let running = controller {
            let previous = self.answer
            clear()
            running.cancel()
            previous?(PasskeyFailure.replaced.reply)
        }
        let controller = ASAuthorizationController(authorizationRequests: requests)
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        self.token = token
        self.answer = answer
        anchor = page.surface.view.window
        asker = page
        controller.performRequests()
    }

    // MARK: Offered under the field

    /// A passkey the Mac holds for the site whose page is waiting for one.
    struct Offered: Identifiable, Equatable {
        let id: Data
        /// The account's name, as the site made it.
        let name: String
        /// Where it is kept: iCloud Keychain, a password app.
        let provider: String?
    }

    /// A page's request for a passkey from under its field, checked and
    /// waiting: what the Mac is asked with once you have picked one.
    private struct Waiting {
        let request: PasskeyRequest
        let rp: String
        let origin: String
        let clientData: ASPublicKeyCredentialClientData
        let answer: ([String: Any]) -> Void
        weak var page: Page?
        var offered: [Offered] = []
        var token: String? { request.token }
    }

    /// One per page.
    private var conditional: [ObjectIdentifier: Waiting] = [:]
    private let list = PasskeyList()

    /// The passkeys to offer under the fields of this page; none when the
    /// page isn't waiting for one, or has gone to another site since.
    func offered(in page: Page?) -> [Offered] {
        guard let page, let waiting = conditional[ObjectIdentifier(page)], waiting.page === page,
              waiting.origin == PasskeyCheck.origin(of: Self.committed(page))
        else { return [] }
        return waiting.offered
    }

    /// The page is gone (a new document, or the tab) and its request with
    /// it. The answer asks the page to keep waiting, which a page that is
    /// gone never hears.
    func forget(_ page: Page) {
        if let running = controller, asker === page {
            finish(PasskeyFailure.wait.reply)
            running.cancel()
        }
        awaiting = awaiting.filter { $0.value != ObjectIdentifier(page) }
        conditional[ObjectIdentifier(page)].map { $0.answer(PasskeyFailure.wait.reply) }
        conditional[ObjectIdentifier(page)] = nil
        list.close(for: page)
        for (key, waiting) in conditional where waiting.page == nil {
            waiting.answer(PasskeyFailure.wait.reply)
            conditional[key] = nil
        }
    }

    private func wait(_ request: PasskeyRequest, passed: PasskeyCheck.Passed, clientData: ASPublicKeyCredentialClientData,
                      in page: Page, answer: @escaping ([String: Any]) -> Void) {
        let key = ObjectIdentifier(page)
        // Asked again: the one before is over, as in any browser, and its list.
        conditional[key].map { $0.answer(PasskeyFailure.replaced.reply) }
        list.close(for: page)
        conditional[key] = Waiting(request: request, rp: passed.rp, origin: passed.origin, clientData: clientData,
                                   answer: answer, page: page)
        // A rehearsal never asks the Mac: it would list the passkeys of
        // whoever is working beside it. One made up, for the site.
        if Self.rehearsal {
            return settle(key, token: request.token,
                          [Offered(id: PasskeyReply.rehearsalID, name: "probe@\(passed.rp)", provider: "Rehearsal")])
        }
        // Not asked for here: a site loading is no time for macOS's question.
        // Until it has been answered, the field offers none; a click in the
        // field asks it (field).
        guard Self.access == .authorized else { return }
        lookUp(key)
    }

    /// The Mac's passkeys for the waiting request's site, those it allows.
    private func lookUp(_ key: ObjectIdentifier) {
        guard let waiting = conditional[key] else { return }
        let allowed = Set(waiting.request.allowed.map(\.id))
        let rp = waiting.rp, token = waiting.token
        Task { @MainActor in
            let found = await ASAuthorizationWebBrowserPublicKeyCredentialManager().platformCredentials(forRelyingParty: rp)
            let offered = found
                .filter { allowed.isEmpty || allowed.contains($0.credentialID) }
                .prefix(8)
                .map { found in
                    Offered(id: found.credentialID, name: found.name.isEmpty ? String(localized: "Passkey") : String(found.name.prefix(200)),
                            provider: found.providerName.isEmpty ? nil : found.providerName)
                }
            self.settle(key, token: token, Array(offered))
        }
    }

    /// What the Mac holds, for the request that is still the page's; shown at
    /// once if the field already has the keyboard.
    private func settle(_ key: ObjectIdentifier, token: String?, _ offered: [Offered]) {
        guard var waiting = conditional[key], waiting.token == token else { return }
        waiting.offered = offered
        conditional[key] = waiting
        Self.log.notice("\(offered.count, privacy: .public) offered under the field for \(waiting.rp, privacy: .public)")
        guard !offered.isEmpty, let page = waiting.page else { return list.close(for: waiting.page) }
        Task { @MainActor [weak page] in
            guard let page else { return }
            let rect = await page.passkeyField()
            self.field(rect, in: page)
        }
    }

    /// Where the page's sign-in field is while it has the keyboard, from
    /// passkeys-bridge.js, in the page's points; nil once it has let go.
    /// `clicked`: the field was clicked. Before macOS has been asked whether
    /// eGlu may use passkeys, that is when it is asked, for a page waiting
    /// for one, and the site's passkeys are looked for once it is answered.
    func field(_ rect: CGRect?, in page: Page, clicked: Bool = false) {
        let key = ObjectIdentifier(page)
        if clicked, Self.entitled, !Self.rehearsal, let waiting = conditional[key], waiting.page === page, waiting.offered.isEmpty,
           waiting.origin == PasskeyCheck.origin(of: Self.committed(page)), Self.inFront(page), Self.access == .notDetermined {
            let token = waiting.token
            Self.ensure { [weak self] in
                guard let self, Self.access == .authorized, self.conditional[key]?.token == token else { return }
                self.lookUp(key)
            }
        }
        let offered = offered(in: page)
        // Shown only for the page in front; once shown, it follows the field
        // even while a click on it has its own window in front.
        let allowed = Self.rehearsal || Self.inFront(page) || (NSApp.isActive && list.isShown(for: page))
        guard let rect, !offered.isEmpty, page.surface.view.window != nil, allowed else {
            return list.close(for: page)
        }
        list.show(offered, under: rect, in: page) { [weak self, weak page] picked in
            guard let self, let page else { return }
            self.sign(in: page, with: picked.id)
        }
    }

    /// One of the passkeys under the field, picked from its list (which only
    /// the page in front is shown): the Mac's sheet for it alone, and the
    /// page's waiting request answered with what it gives.
    func sign(in page: Page, with id: Data) {
        let key = ObjectIdentifier(page)
        guard let waiting = conditional[key], waiting.page === page,
              waiting.offered.contains(where: { $0.id == id }),
              waiting.origin == PasskeyCheck.origin(of: Self.committed(page)),
              Self.rehearsal || (NSApp.isActive && list.isShown(for: page))
        else { return }
        conditional[key] = nil
        list.close(for: page)
        Self.log.notice("picked under the field for \(waiting.rp, privacy: .public)")
        if Self.rehearsal {
            var reply = PasskeyReply.rehearsal(.get, origin: waiting.origin, challenge: waiting.clientData.challenge)
            if waiting.request.prf != nil {
                reply["prf"] = PasskeyReply.rehearsalPRF(enabled: nil, for: PasskeyReply.pageKey(waiting.request))
            }
            return waiting.answer(reply)
        }
        let request = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: waiting.rp)
            .createCredentialAssertionRequest(clientData: waiting.clientData)
        request.allowedCredentials = [ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: id)]
        request.userVerificationPreference = Self.verification(waiting.request.userVerification)
        request.prf = Self.prfAssertion(waiting.request.prf, only: id)
        let ticket = UUID()
        awaiting[ticket] = key
        Self.ensure { [weak self, weak page] in
            guard let self else { return }
            let current = self.awaiting.removeValue(forKey: ticket) != nil
            if let token = waiting.token, self.withdrawn.remove(token) != nil {
                return waiting.answer(PasskeyFailure.aborted.reply)
            }
            guard current, let page, waiting.origin == PasskeyCheck.origin(of: Self.committed(page)), NSApp.isActive,
                  page.surface.view.window != nil
            else {
                return waiting.answer(PasskeyFailure.notAllowed.reply)
            }
            self.begin([request], token: waiting.token, from: page, answer: waiting.answer)
            self.prfKey = PasskeyReply.pageKey(waiting.request)
            self.wantedPRF = waiting.request.prf != nil
        }
    }

    // MARK: Requests

    private static func assertion(_ request: PasskeyRequest, rp: String, clientData: ASPublicKeyCredentialClientData) -> [ASAuthorizationRequest] {
        let verification = verification(request.userVerification)
        let platform = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rp)
            .createCredentialAssertionRequest(clientData: clientData)
        platform.allowedCredentials = request.allowed.map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0.id) }
        platform.userVerificationPreference = verification
        platform.prf = prfAssertion(request.prf, only: nil)
        let key = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: rp)
            .createCredentialAssertionRequest(clientData: clientData)
        key.allowedCredentials = request.allowed.map {
            ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(credentialID: $0.id, transports: transports($0.transports))
        }
        key.userVerificationPreference = verification
        return [platform, key]
    }

    private static func registration(_ request: PasskeyRequest, rp: String, clientData: ASPublicKeyCredentialClientData) -> [ASAuthorizationRequest] {
        // The verdict passes no registration without a user.
        guard let user = request.user else { return [] }
        let verification = verification(request.userVerification)
        let attestation = attestation(request.attestation)
        var requests: [ASAuthorizationRequest] = []
        if request.offersPlatform {
            let platform = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rp)
                .createCredentialRegistrationRequest(clientData: clientData, name: user.name, userID: user.id)
            platform.displayName = user.displayName
            platform.userVerificationPreference = verification
            platform.attestationPreference = attestation
            platform.excludedCredentials = request.excluded.map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0.id) }
            if let prf = request.prf {
                platform.prf = prf.eval.map { .inputValues(.saltInput1($0.first, saltInput2: $0.second)) } ?? .checkForSupport
            }
            requests.append(platform)
        }
        if request.offersSecurityKey {
            let key = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: rp)
                .createCredentialRegistrationRequest(clientData: clientData, displayName: user.displayName, name: user.name, userID: user.id)
            key.credentialParameters = request.algorithms.map {
                ASAuthorizationPublicKeyCredentialParameters(algorithm: ASCOSEAlgorithmIdentifier(rawValue: $0))
            }
            key.userVerificationPreference = verification
            key.attestationPreference = attestation
            switch request.residentKey {
            case "required": key.residentKeyPreference = .required
            case "preferred": key.residentKeyPreference = .preferred
            default: key.residentKeyPreference = .discouraged
            }
            key.excludedCredentials = request.excluded.map {
                ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(credentialID: $0.id, transports: transports($0.transports))
            }
            requests.append(key)
        }
        return requests
    }

    /// The page's PRF salts, as AuthenticationServices takes them; `only`, a
    /// passkey picked under the field, keeps its own salts and no one else's.
    /// The salts go through untouched: macOS hashes them as the standard
    /// says, the way it does for Safari.
    private static func prfAssertion(_ prf: PasskeyRequest.PRF?, only: Data?) -> ASAuthorizationPublicKeyCredentialPRFAssertionInput? {
        guard let prf else { return nil }
        typealias Values = ASAuthorizationPublicKeyCredentialPRFAssertionInput.InputValues
        var byCredential: [Data: Values] = [:]
        for (id, values) in prf.byCredential where only == nil || only == id {
            byCredential[id] = .saltInput1(values.first, saltInput2: values.second)
        }
        if let values = prf.eval {
            return .inputValues(.saltInput1(values.first, saltInput2: values.second),
                                perCredentialInputValues: byCredential.isEmpty ? nil : byCredential)
        }
        return byCredential.isEmpty ? nil : .perCredentialInputValues(byCredential)
    }

    private static func transports(_ named: [String]) -> [ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport] {
        let known = named.compactMap { name -> ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport? in
            switch name {
            case "usb": return .usb
            case "nfc": return .nfc
            case "ble": return .bluetooth
            default: return nil
            }
        }
        return known.isEmpty ? ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport.allSupported : known
    }

    private static func verification(_ value: String) -> ASAuthorizationPublicKeyCredentialUserVerificationPreference {
        switch value {
        case "required": return .required
        case "discouraged": return .discouraged
        default: return .preferred
        }
    }

    private static func attestation(_ value: String) -> ASAuthorizationPublicKeyCredentialAttestationKind {
        switch value {
        case "direct": return .direct
        case "indirect": return .indirect
        case "enterprise": return .enterprise
        default: return .none
        }
    }

    // MARK: Answers

    private func finish(_ value: [String: Any]) {
        let answer = self.answer
        clear()
        answer?(value)
    }

    private func clear() {
        controller = nil
        token = nil
        answer = nil
        prfKey = nil
        wantedPRF = false
        asker = nil
    }

    private func refuse(_ answer: ([String: Any]) -> Void, _ failure: PasskeyFailure) {
        Self.log.notice("refused: \(failure.message, privacy: .public)")
        answer(failure.reply)
    }

    // MARK: Checks

    /// The address of the document a page shows, once it is that document's:
    /// the committed address. The engine's own moves as soon as a navigation
    /// starts, while the page before and its frames can still ask; and before
    /// a pop-up's first page commits, its opener can still write into it.
    static func committed(_ page: Page?) -> URL? {
        page?.committed
    }

    /// Whether a page is the one in front of you: eGlu in front, the page's
    /// window the key one with no sheet over it, and the page's view holding
    /// the keyboard, as a page does once it has been clicked. A tab behind, a
    /// window behind, the pane beside the one with the keys, or a tab under a
    /// Peek doesn't get to bring up the Mac's sheet over what you are looking at.
    static func inFront(_ page: Page?) -> Bool {
        guard let view = page?.surface.view, let window = view.window, NSApp.isActive, window.isKeyWindow,
              window.attachedSheet == nil, let holder = window.firstResponder as? NSView
        else { return false }
        return holder.isDescendant(of: view)
    }

    /// macOS's own test for a public suffix, from the list it keeps.
    /// Private to CFNetwork, as Search uses it: without it, a page's own host
    /// is the only relying party it gets and a frame only its page's host.
    nonisolated static let publicSuffix: (@convention(c) (CFString) -> Bool)? = {
        guard let symbol = dlsym(dlopen("/System/Library/Frameworks/CFNetwork.framework/CFNetwork", RTLD_NOW), "_CFHostIsDomainTopLevel")
        else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (CFString) -> Bool).self)
    }()

    static var isSuffix: ((String) -> Bool)? {
        publicSuffix.map { test in { name in test(name as CFString) } }
    }
}

extension Passkeys: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            anchor ?? NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        MainActor.assumeIsolated {
            guard controller === self.controller else { return }
            let credential = authorization.credential
            if let got = credential as? ASAuthorizationPublicKeyCredentialAssertion {
                let platform = credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion
                Self.log.notice("signed in")
                var reply = PasskeyReply.assertion(
                    id: got.credentialID, clientData: got.rawClientDataJSON, authenticatorData: got.rawAuthenticatorData,
                    signature: got.signature, user: got.userID,
                    attachment: platform?.attachment == .platform ? "platform" : "cross-platform"
                )
                if let prf = platform?.prf {
                    reply["prf"] = PasskeyReply.prf(enabled: nil, first: Self.bytes(prf.first), second: prf.second.map(Self.bytes), for: prfKey)
                }
                finish(reply)
            } else if let made = credential as? ASAuthorizationPublicKeyCredentialRegistration {
                let platform = credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration
                Self.log.notice("made one")
                var reply = PasskeyReply.registration(
                    id: made.credentialID, clientData: made.rawClientDataJSON, attestation: made.rawAttestationObject ?? Data(),
                    transports: platform == nil ? ["usb"] : ["hybrid", "internal"],
                    attachment: platform?.attachment == .platform ? "platform" : "cross-platform"
                )
                if let prf = platform?.prf {
                    reply["prf"] = PasskeyReply.prf(enabled: prf.isSupported, first: prf.first.map(Self.bytes),
                                                    second: prf.second.map(Self.bytes), for: prfKey)
                } else if wantedPRF {
                    // A security key, which can't: the site is told so.
                    reply["prf"] = ["enabled": false]
                }
                finish(reply)
            } else {
                finish(PasskeyFailure("NotAllowedError", "The authenticator answered with something else.").reply)
            }
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        MainActor.assumeIsolated {
            guard controller === self.controller else { return }
            Self.log.notice("failed: \(String(describing: error), privacy: .public)")
            // A credential it already holds is what a site is told; anything
            // else (no, the sheet closed, the time ran out) a site may not
            // tell apart.
            let error = error as NSError
            if error.domain == ASAuthorizationError.errorDomain, error.code == ASAuthorizationError.Code.matchedExcludedCredential.rawValue {
                finish(PasskeyFailure.alreadyHeld.reply)
            } else {
                finish(PasskeyFailure.notAllowed.reply)
            }
        }
    }

    private static func bytes(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }
}

/// The page's side: requests handed over, answers handed back, and where the
/// sign-in field is while it has the keyboard. One for each page, on the
/// channel it opens in the app's world (Page.setUp).
@MainActor
final class PasskeyRelay {
    /// As passkeys-bridge.js names it.
    static let name = "egluPasskeys"

    private weak var page: Page?

    init(page: Page) {
        self.page = page
    }

    func handle(_ message: WebMessage, reply: @escaping @MainActor (WebJSON?) -> Void) {
        let answer = { (value: Any) in reply(WebJSON(foundation: value)) }
        guard message.world == .app, let body = message.body.foundation as? [String: Any] else {
            return reply(nil)
        }
        switch body["kind"] as? String {
        case "cancel":
            Passkeys.shared.cancel(token: body["token"] as? String)
            return answer(true)
        case "field":
            if message.isMainFrame, let page {
                let rect = (body["rect"] as? [String: Any]).flatMap(Self.rect)
                Passkeys.shared.field(rect, in: page, clicked: body["clicked"] as? Bool == true)
            }
            return answer(true)
        default:
            // The origin the engine recorded for the frame; one it can't
            // name (a sandboxed frame's) has no host, and is no secure page.
            let (scheme, host, port): (String, String, Int)
            switch message.origin {
            case let .tuple(tupleScheme, tupleHost, tuplePort): (scheme, host, port) = (tupleScheme, tupleHost, tuplePort)
            case .opaque: (scheme, host, port) = ("", "", 0)
            }
            let isMain = message.isMainFrame
            let ancestors = body["ancestors"] as? [String]
            let ask = { [weak page] (delegations: [PasskeyFrame.Delegation]?) in
                let caller = Passkeys.Caller(
                    frame: PasskeyFrame(scheme: scheme, host: host, port: port, isMain: isMain,
                                        page: Passkeys.committed(page), ancestors: ancestors, delegations: delegations,
                                        activated: body["activated"] as? Bool ?? false),
                    page: page
                )
                Passkeys.shared.perform(body, from: caller) { answer($0) }
            }
            // A frame's page says first what it lets its frames do.
            guard !isMain, let page else { return ask(nil) }
            Task { @MainActor in ask(await page.passkeyDelegations()) }
        }
    }

    private static func rect(_ value: [String: Any]) -> CGRect? {
        guard let x = value["x"] as? Double, let y = value["y"] as? Double,
              let width = value["width"] as? Double, let height = value["height"] as? Double,
              width > 0, height > 0
        else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// The passkeys the Mac holds for a site, listed under its sign-in field
/// while the field has the keyboard: a popover from the field, which leaves
/// the keyboard where it is, so typing a name goes on as before. A row picked
/// brings up the Mac's sheet for that passkey alone; a click anywhere else
/// puts the list away until the field is clicked again.
@MainActor
final class PasskeyList: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private weak var page: Page?

    func show(_ offered: [Passkeys.Offered], under rect: CGRect, in page: Page, pick: @escaping (Passkeys.Offered) -> Void) {
        let view = page.surface.view
        guard let spot = Self.spot(rect, in: page) else { return close(for: page) }
        // Already there for this page and these passkeys: it follows the field.
        if let popover, popover.isShown, self.page === page,
           (popover.contentViewController as? NSHostingController<PasskeyRows>)?.rootView.offered == offered {
            popover.positioningRect = spot
            return
        }
        close(for: self.page)
        let rows = PasskeyRows(offered: offered, site: Passkeys.committed(page)?.host() ?? "") { [weak self, weak page] picked in
            // Picked while the list is still up, which is what lets it count.
            pick(picked)
            self?.close(for: page)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: rows)
        popover.delegate = self
        self.popover = popover
        self.page = page
        popover.show(relativeTo: spot, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
        // The keyboard stays in the field.
        if let window = view.window, !window.isKeyWindow { window.makeKey() }
        Passkeys.log.notice("\(offered.count, privacy: .public) listed under the field")
        #if DEBUG
        // A rehearsal from the shell picks the first, as a click on it would
        // (`-passkeyRehearsalPick YES`, Tests/passkeys-rehearsal.py).
        if Passkeys.rehearsal, UserDefaults.standard.bool(forKey: "passkeyRehearsalPick"), let first = offered.first {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard self?.popover === popover else { return }
                rows.pick(first)
            }
        }
        #endif
    }

    func isShown(for page: Page) -> Bool {
        popover?.isShown == true && self.page === page
    }

    func close(for page: Page?) {
        guard let popover, page == nil || self.page === page || self.page == nil else { return }
        self.popover = nil
        self.page = nil
        popover.close()
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            if (notification.object as? NSPopover) === popover {
                popover = nil
                page = nil
            }
        }
    }

    /// The field's place in the page's view: the page's points, zoomed as
    /// the page is, placed on the screen by the engine as Apple Passwords'
    /// card is (WebPageCoordinates), and brought back into the view; nil
    /// while the view is in no window.
    private static func spot(_ rect: CGRect, in page: Page) -> CGRect? {
        let view = page.surface.view
        guard let window = view.window,
              let screen = page.enginePage.coordinates?.screenRect(of: rect, zoom: CGFloat(page.pageZoom * page.magnification))
        else { return nil }
        let spot = view.convert(window.convertFromScreen(screen), from: nil)
        return spot.intersection(view.bounds).isNull
            ? CGRect(x: spot.minX, y: view.isFlipped ? 0 : view.bounds.maxY - 1, width: max(spot.width, 1), height: 1) : spot
    }
}

/// The rows of PasskeyList: each passkey's account, and where it is kept.
struct PasskeyRows: View {
    let offered: [Passkeys.Offered]
    let site: String
    let pick: (Passkeys.Offered) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(offered) { passkey in
                Button {
                    pick(passkey)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "person.badge.key.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(passkey.name)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(passkey.provider.map { "\(String(localized: "Passkey")) · \($0)" } ?? String(localized: "Passkey"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PasskeyRowStyle())
            }
        }
        .padding(6)
        .frame(width: 280)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Passkeys for \(site)"))
    }
}

private struct PasskeyRowStyle: ButtonStyle {
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(configuration.isPressed ? 0.3 : hovered ? 0.18 : 0)))
            .onHover { hovered = $0 }
    }
}
