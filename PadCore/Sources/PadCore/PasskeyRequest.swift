import Foundation

/// A page's request for a passkey, as eGlu's page script (passkeys.js) hands
/// it to the Mac app, and the checks it passes before macOS is asked.
///
/// The ceremony is carried by the app rather than left to WebKit, as Search
/// carries it (Mac/Sources/Passkeys.swift says why): the page's own
/// `navigator.credentials` is replaced in its world and sends the request
/// here as JSON. Nothing the page states about where it is counts: the
/// origin in the client data is the one WebKit reports for the frame, and
/// the relying party must be that frame's host or a site above it. Taken
/// from Search (github.com/driceroland/Search, MIT, its Passkeys.swift),
/// with the checks pulled out of the AppKit code so they can be tested.
public struct PasskeyRequest {
    public enum Kind: String, Sendable {
        case get, create
    }

    /// A credential the request names: one to sign in with
    /// (allowCredentials) or one the authenticator must not already hold
    /// (excludeCredentials). Transports as the page wrote them: usb, nfc,
    /// ble, hybrid, internal.
    public struct Descriptor: Equatable, Sendable {
        public let id: Data
        public let transports: [String]
    }

    /// The account a new passkey is for.
    public struct User: Equatable, Sendable {
        public let id: Data
        public let name: String
        public let displayName: String
    }

    /// One or two salts for the PRF extension, or what a passkey derived
    /// from them.
    public struct PRFValues: Equatable, Sendable {
        public let first: Data
        public let second: Data?
    }

    /// The page's `prf.eval` and `prf.evalByCredential`.
    public struct PRF: Equatable, Sendable {
        public let eval: PRFValues?
        public let byCredential: [Data: PRFValues]
    }

    public let kind: Kind
    /// The page's name for this request, for its answer and for calling it off.
    public let token: String?
    /// Asked from under the sign-in field (mediation: "conditional"):
    /// nothing comes up until a passkey is picked there.
    public let conditional: Bool
    /// Nil when the page sent none, or none that is base64url.
    public let challenge: Data?
    /// The relying party the page named: `rpId` to sign in, `rp.id` to make
    /// one. Nil or empty means the frame's own host.
    public let named: String?
    public let allowed: [Descriptor]
    public let excluded: [Descriptor]
    public let userVerification: String
    /// Nil when the page named no user, or one the standard refuses (an id
    /// of no bytes or of more than 64).
    public let user: User?
    /// COSE algorithms the site takes, in its order: -7 is ES256, -257 RS256.
    public let algorithms: [Int]
    /// "platform", "cross-platform", or nil for either.
    public let attachment: String?
    public let residentKey: String
    public let attestation: String
    public let prf: PRF?
    /// The one-time P-256 public key the page's script made for this
    /// request's PRF results, as X9.63 bytes (PasskeyReply.prf).
    public let prfKey: Data?

    /// Read from the page's message; nil when it is no request for a passkey.
    public init?(_ body: [String: Any]) {
        guard let kind = (body["kind"] as? String).flatMap(Kind.init(rawValue:)) else { return nil }
        self.kind = kind
        token = body["token"] as? String
        conditional = kind == .get && body["conditional"] as? Bool == true
        challenge = Base64URL.decode(body["challenge"])
        named = kind == .create ? (body["rp"] as? [String: Any])?["id"] as? String : body["rpId"] as? String
        allowed = Self.descriptors(body["allowCredentials"])
        excluded = Self.descriptors(body["excludeCredentials"])
        userVerification = body["userVerification"] as? String ?? "preferred"
        if let user = body["user"] as? [String: Any], let id = Base64URL.decode(user["id"]), (1...64).contains(id.count),
           let name = user["name"] as? String {
            let display = user["displayName"] as? String ?? ""
            self.user = User(id: id, name: name, displayName: display.isEmpty ? name : display)
        } else {
            user = nil
        }
        // No list means ES256 or RS256, as the standard has it.
        let algorithms = body["algorithms"] as? [Int] ?? []
        self.algorithms = algorithms.isEmpty ? [-7, -257] : algorithms
        attachment = body["authenticatorAttachment"] as? String
        residentKey = body["residentKey"] as? String ?? "discouraged"
        attestation = body["attestation"] as? String ?? "none"
        prf = Self.prf(body["prf"], allowed: Set(allowed.map(\.id)))
        prfKey = Base64URL.decode(body["prfKey"])
    }

    /// Whether a passkey on this Mac (or a phone nearby) may answer. One
    /// from the Mac is always ES256, so it is offered only to a site that
    /// takes that.
    public var offersPlatform: Bool {
        kind == .get || (attachment != "cross-platform" && algorithms.contains(-7))
    }

    /// Whether a security key may answer.
    public var offersSecurityKey: Bool {
        kind == .get || attachment != "platform"
    }

    static func descriptors(_ value: Any?) -> [Descriptor] {
        (value as? [[String: Any]] ?? []).compactMap { item in
            guard let id = Base64URL.decode(item["id"]) else { return nil }
            return Descriptor(id: id, transports: item["transports"] as? [String] ?? [])
        }
    }

    /// The page's PRF input. Salts for a passkey the request doesn't allow
    /// are for nobody: the page's script refuses them, and they are left out
    /// here too.
    static func prf(_ value: Any?, allowed: Set<Data>) -> PRF? {
        guard let prf = value as? [String: Any] else { return nil }
        var byCredential: [Data: PRFValues] = [:]
        for (id, values) in prf["byCredential"] as? [String: Any] ?? [:] {
            if let id = Base64URL.decode(id), allowed.contains(id), let values = prfValues(values) { byCredential[id] = values }
        }
        return PRF(eval: prfValues(prf["eval"]), byCredential: byCredential)
    }

    static func prfValues(_ value: Any?) -> PRFValues? {
        guard let values = value as? [String: Any], let first = Base64URL.decode(values["first"]) else { return nil }
        return PRFValues(first: first, second: Base64URL.decode(values["second"]))
    }
}

/// The frame a request came from, as WebKit knows it rather than as the
/// page says: its security origin, whether it is the page itself, the
/// address of the page it is in, as the tab committed it, and the origins of
/// the frames it is in.
public struct PasskeyFrame: Sendable {
    public let scheme: String
    public let host: String
    /// 0 for the scheme's own port, as WKSecurityOrigin gives it.
    public let port: Int
    public let isMain: Bool
    public let page: URL?
    /// The frame's location.ancestorOrigins, its parent first and the page
    /// last, read by passkeys-bridge.js in eGlu's world, where the page can't
    /// change them; empty for the page itself, nil when unknown.
    public let ancestors: [String]?
    /// The page's frame elements that carry an allow attribute, read in the
    /// page by passkeys-bridge.js: what the page lets its frames do
    /// (PasskeyCheck.delegates). Nil when unknown.
    public let delegations: [Delegation]?
    /// Whether the frame had just been clicked or typed in when it asked
    /// (navigator.userActivation, read by passkeys-bridge.js in eGlu's world).
    public let activated: Bool

    /// A frame element's allow attribute, and the origin of its src.
    public struct Delegation: Equatable, Sendable {
        public let allow: String
        public let src: String?

        public init(allow: String, src: String?) {
            self.allow = allow
            self.src = src
        }
    }

    public init(scheme: String, host: String, port: Int, isMain: Bool, page: URL?, ancestors: [String]? = nil,
                delegations: [Delegation]? = nil, activated: Bool = false) {
        self.scheme = scheme.lowercased()
        self.host = host.lowercased()
        self.port = port
        self.isMain = isMain
        self.page = page
        self.ancestors = ancestors
        self.delegations = delegations
        self.activated = activated
    }
}

/// Why a request was refused, as the page's promise is rejected: a
/// DOMException's name (or TypeError) and its message.
public struct PasskeyFailure: Error, Equatable, Sendable {
    public let name: String
    public let message: String

    public init(_ name: String, _ message: String) {
        self.name = name
        self.message = message
    }

    /// What the page's script reads.
    public var reply: [String: Any] {
        ["error": name, "message": message]
    }

    /// Anything the page may not tell apart: no, the sheet closed, the time ran out.
    public static let notAllowed = PasskeyFailure("NotAllowedError", "The operation either timed out or was not allowed.")
    public static let aborted = PasskeyFailure("AbortError", "The operation was aborted.")
    public static let replaced = PasskeyFailure("NotAllowedError", "A newer request took its place.")
    /// A credential the authenticator already holds, which a site is told.
    public static let alreadyHeld = PasskeyFailure("InvalidStateError", "The authenticator already holds a credential for this account.")
    /// Not an error: a request from under the field with nothing to offer
    /// keeps waiting, as one does while nobody picks a passkey, until the
    /// page lets it go. The page's script never settles its promise for it.
    public static let wait = PasskeyFailure("Wait", "")
}

public enum PasskeyCheck {
    /// What a request that passes is asked of macOS with.
    public struct Passed: Equatable, Sendable {
        /// The relying party, lowercased.
        public let rp: String
        /// The frame's origin, for the client data.
        public let origin: String
        /// The page's origin, for a frame that is not of the same origin as
        /// every frame it is in (the client data's crossOrigin); nil otherwise.
        public let topOrigin: String?
        /// Asked from under the sign-in field: kept waiting, not shown.
        public let underField: Bool
    }

    public enum Verdict: Equatable, Sendable {
        case passed(Passed)
        case refused(PasskeyFailure)
        /// From under the field where nothing can be offered: the page waits.
        case wait
    }

    /// Search's checks, in Search's order. `focused`: the request's page is
    /// the one in front of you, in the key window of the app in front; a
    /// page behind doesn't get to bring up the Mac's sheet over what you are
    /// looking at. `hasView`: the request came with the page's view, to hang
    /// a request from under the field on. `isSuffix` says which names are
    /// public suffixes (com, co.uk, github.io); without it a frame's own host
    /// is the only relying party it gets.
    public static func verdict(for request: PasskeyRequest, from frame: PasskeyFrame, focused: Bool, hasView: Bool,
                               isSuffix: ((String) -> Bool)?) -> Verdict {
        guard isSecure(scheme: frame.scheme, host: frame.host) else {
            return .refused(PasskeyFailure("NotAllowedError", "Passkeys need a secure page."))
        }
        // From under the field: nothing comes up until you pick, so a page
        // still loading, or behind, may ask. Its own page only: a frame's
        // request waits, offered nothing, as does any with no view to hang on.
        let underField = request.conditional
        if underField, !frame.isMain || !hasView { return .wait }
        guard underField || focused else {
            return .refused(PasskeyFailure("NotAllowedError", "The document is not focused."))
        }
        // A frame from another site can't ask on the page's behalf. One of
        // the page's own site can, as in Safari: Apple's sign-in is a frame
        // from idmsa.apple.com in account.apple.com. Every frame it is in
        // must be of that site too, so another site's frame between them
        // can't carry one in; and the outermost must be the page the tab
        // committed.
        let ancestors = frame.isMain ? [] : (frame.ancestors ?? []).map(Self.originParts)
        let pageOrigin = Self.origin(of: frame.page)
        let ofTheSite = !ancestors.isEmpty && ancestors.allSatisfy { parts in
            guard let parts else { return false }
            return parts.scheme == frame.scheme && Registrable.sameSite(parts.host, frame.host, isSuffix: isSuffix)
        }
        let outermost = frame.ancestors?.last.flatMap(Self.normalized)
        guard frame.isMain || (ofTheSite && outermost != nil && outermost == pageOrigin) else {
            return .refused(PasskeyFailure("NotAllowedError", "Passkeys can't be asked for from another site's frame."))
        }
        let origin = origin(scheme: frame.scheme, host: frame.host, port: frame.port)
        // A frame not of the same origin as all it is in asks only where the
        // page lets it, as the standard's permissions policy has it:
        // publickey-credentials-get (or -create) in the allow attribute of the
        // page's frame element for it, which WebKit would have held it to.
        // Only the page's own frame elements can be read, so one of another
        // origin nested deeper is refused.
        let crossOrigin = !frame.isMain && (frame.ancestors ?? []).contains { Self.normalized($0) != origin }
        if crossOrigin {
            let feature = request.kind == .get ? "publickey-credentials-get" : "publickey-credentials-create"
            guard frame.ancestors?.count == 1, let pageOrigin,
                  delegates(frame.delegations ?? [], feature, to: origin, page: pageOrigin)
            else {
                return .refused(PasskeyFailure("NotAllowedError", "The page doesn't let this frame ask for passkeys."))
            }
            // And makes one only from a click in it, as the standard has it.
            guard request.kind == .get || frame.activated else {
                return .refused(PasskeyFailure("NotAllowedError", "A frame of another origin makes a passkey only when it is clicked."))
            }
        }
        let rp = (request.named.flatMap { $0.isEmpty ? nil : $0 } ?? frame.host).lowercased()
        guard fits(rp, frame.host, isSuffix: isSuffix) else {
            return .refused(PasskeyFailure("SecurityError",
                                           "The relying party ID is not a registrable domain suffix of, nor equal to the current domain."))
        }
        guard let challenge = request.challenge, !challenge.isEmpty else {
            return .refused(PasskeyFailure("TypeError", "A challenge is required."))
        }
        if request.kind == .create, request.user == nil {
            return .refused(PasskeyFailure("TypeError", "The request names no user, or one too long."))
        }
        guard request.offersPlatform || request.offersSecurityKey else {
            return .refused(PasskeyFailure("NotSupportedError", "No authenticator here can make that kind of key."))
        }
        // From a frame not of the same origin as all it is in, the page is
        // named too, as the standard has it, so the site can tell (Safari's
        // clientDataJSON does the same).
        return .passed(Passed(rp: rp, origin: origin, topOrigin: crossOrigin ? pageOrigin : nil, underField: underField))
    }

    /// Whether one of the page's frame elements lets `origin` use `feature`
    /// by its allow attribute: features separated by semicolons, each
    /// followed by whom it is for. None named means the frame's src, `*` any
    /// origin, 'self' the page's own, 'src' the frame's src, 'none' nobody,
    /// and an origin itself. Told by origin, not by element: frames of one
    /// origin can reach into each other, so what one of them is let do,
    /// another could have it do.
    public static func delegates(_ delegations: [PasskeyFrame.Delegation], _ feature: String, to origin: String,
                                 page: String) -> Bool {
        delegations.contains { delegation in
            let src = delegation.src.flatMap(normalized)
            return delegation.allow.split(separator: ";").contains { directive in
                let tokens = directive.split(whereSeparator: \.isWhitespace).map(String.init)
                guard let name = tokens.first, name.lowercased() == feature else { return false }
                let named = tokens.dropFirst()
                if named.isEmpty { return src == origin }
                return named.contains { token in
                    switch token.lowercased() {
                    case "*": return true
                    case "'self'": return page == origin
                    case "'src'": return src == origin
                    case "'none'": return false
                    default: return normalized(token) == origin
                    }
                }
            }
        }
    }

    /// https anywhere, http only on this Mac's own loopback names, as for
    /// any secure context.
    public static func isSecure(scheme: String, host: String) -> Bool {
        let scheme = scheme.lowercased(), host = host.lowercased()
        let local = host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1"
        return !host.isEmpty && (scheme == "https" || (scheme == "http" && local))
    }

    /// The relying party is the page's own host, or a domain above it that is
    /// still a site of its own: never another site, never an address, and
    /// never a suffix anyone can register under (com, co.uk, github.io).
    /// As the HTML standard's "is a registrable domain suffix of or is equal
    /// to": the relying party may not be above the host's public suffix
    /// either, so a page of attacker.compute.amazonaws.com can't name
    /// amazonaws.com.
    public static func fits(_ rp: String, _ host: String, isSuffix: ((String) -> Bool)?) -> Bool {
        let rp = rp.lowercased(), host = host.lowercased()
        if rp == host { return true }
        let address = host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
        guard !address, host.hasSuffix("." + rp), rp.contains("."), let isSuffix, !isSuffix(rp) else { return false }
        return Registrable.sameSite(rp, host, isSuffix: isSuffix)
    }

    /// "scheme://host[:port]", as an origin is serialized: an IPv6 address in
    /// brackets, the scheme's own port left out.
    public static func origin(scheme: String, host: String, port: Int) -> String {
        let scheme = scheme.lowercased(), host = host.lowercased()
        let named = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let ownPort = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        return "\(scheme)://\(named)" + (port == 0 || ownPort ? "" : ":\(port)")
    }

    /// The origin of an address, as `origin(scheme:host:port:)` writes it; nil
    /// for one without a scheme and a host.
    public static func origin(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme, let host = url.host() else { return nil }
        return origin(scheme: scheme, host: host, port: url.port ?? 0)
    }

    /// An origin as a frame's ancestorOrigins gives it, in pieces; nil for an
    /// opaque one ("null"), a sandboxed frame's.
    static func originParts(_ text: String) -> (scheme: String, host: String)? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased(),
              !host.isEmpty
        else { return nil }
        return (scheme, host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
    }

    /// An origin as an ancestor gives it, written as `origin(of:)` writes one.
    static func normalized(_ text: String) -> String? {
        origin(of: URL(string: text))
    }
}

/// Bytes as the page's script writes them: base64url without padding.
public enum Base64URL {
    public static func decode(_ value: Any?) -> Data? {
        guard var text = value as? String else { return nil }
        text = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        return Data(base64Encoded: text)
    }

    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
