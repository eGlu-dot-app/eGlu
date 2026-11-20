import XCTest
@testable import PadCore
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The checks a page's request for a passkey passes before macOS is asked
/// (PasskeyCheck), the request as passkeys.js sends it (PasskeyRequest), and
/// what goes back (PasskeyReply). Search's rules, as Mac/Sources/Passkeys.swift
/// carries them out.
final class PasskeyTests: XCTestCase {
    /// A stand-in for the public suffix list: com, io, uk and co.uk,
    /// github.io, and compute.amazonaws.com (whose parent is not one).
    let isSuffix: (String) -> Bool = { ["com", "io", "uk", "co.uk", "github.io", "app", "compute.amazonaws.com"].contains($0) }

    func request(_ body: [String: Any]) throws -> PasskeyRequest {
        var full: [String: Any] = ["kind": "get", "challenge": "AAECAw", "token": "t1"]
        full.merge(body) { $1 }
        return try XCTUnwrap(PasskeyRequest(full))
    }

    /// A frame at `origin` in `page`; one not the page itself is directly in
    /// the page unless `ancestors` says otherwise, and the page's frame
    /// element for it allows passkeys unless `delegations` says otherwise.
    func frame(_ origin: String, main: Bool = true, page: String? = nil, ancestors: [String]? = nil,
               delegations: [PasskeyFrame.Delegation]? = nil, activated: Bool = true) -> PasskeyFrame {
        let url = URL(string: origin)!
        let page = URL(string: page ?? origin)
        let allowed = PasskeyFrame.Delegation(allow: "publickey-credentials-get; publickey-credentials-create", src: origin)
        return PasskeyFrame(scheme: url.scheme!, host: url.host()!, port: url.port ?? 0, isMain: main, page: page,
                            ancestors: main ? [] : ancestors ?? [PasskeyCheck.origin(of: page)!],
                            delegations: delegations ?? [allowed], activated: activated)
    }

    func verdict(_ request: PasskeyRequest, _ frame: PasskeyFrame, focused: Bool = true, hasView: Bool = true,
                 suffixes: Bool = true) -> PasskeyCheck.Verdict {
        PasskeyCheck.verdict(for: request, from: frame, focused: focused, hasView: hasView, isSuffix: suffixes ? isSuffix : nil)
    }

    func passed(_ verdict: PasskeyCheck.Verdict) -> PasskeyCheck.Passed? {
        if case .passed(let passed) = verdict { return passed }
        return nil
    }

    func refusal(_ verdict: PasskeyCheck.Verdict) -> String? {
        if case .refused(let failure) = verdict { return failure.name }
        return nil
    }

    // MARK: The request

    func testARequestIsReadAsThePageWroteIt() throws {
        let get = try request([
            "rpId": "example.com", "userVerification": "required", "conditional": true,
            "allowCredentials": [["id": "AQID", "transports": ["usb", "hybrid"]], ["id": 7]],
        ])
        XCTAssertEqual(get.kind, .get)
        XCTAssertEqual(get.token, "t1")
        XCTAssertTrue(get.conditional)
        XCTAssertEqual(get.challenge, Data([0, 1, 2, 3]))
        XCTAssertEqual(get.named, "example.com")
        XCTAssertEqual(get.userVerification, "required")
        XCTAssertEqual(get.allowed, [PasskeyRequest.Descriptor(id: Data([1, 2, 3]), transports: ["usb", "hybrid"])],
                       "a descriptor without base64url bytes is left out")

        let create = try request([
            "kind": "create", "rp": ["id": "example.com"], "rpId": "ignored.com", "conditional": true,
            "user": ["id": "AQ", "name": "ann", "displayName": ""], "algorithms": [-8, -7],
            "authenticatorAttachment": "platform", "residentKey": "required", "attestation": "direct",
        ])
        XCTAssertEqual(create.named, "example.com", "a registration names its relying party under rp")
        XCTAssertFalse(create.conditional, "only a sign-in waits under the field")
        XCTAssertEqual(create.user, PasskeyRequest.User(id: Data([1]), name: "ann", displayName: "ann"),
                       "no display name means the account's name")
        XCTAssertEqual(create.algorithms, [-8, -7])
        XCTAssertEqual(create.residentKey, "required")
        XCTAssertEqual(create.attestation, "direct")
    }

    func testDefaultsAreTheStandards() throws {
        let create = try request(["kind": "create", "user": ["id": "AQ", "name": "ann"]])
        XCTAssertEqual(create.algorithms, [-7, -257], "no list means ES256 or RS256")
        XCTAssertEqual(create.userVerification, "preferred")
        XCTAssertEqual(create.residentKey, "discouraged")
        XCTAssertEqual(create.attestation, "none")
        XCTAssertNil(PasskeyRequest(["kind": "store", "challenge": "AA"]), "not a passkey request")
        XCTAssertNil(PasskeyRequest(["challenge": "AA"]))
    }

    func testAUserIdOfNoBytesOrMoreThan64IsNoUser() throws {
        XCTAssertNil(try request(["kind": "create", "user": ["id": "", "name": "ann"]]).user)
        let long = Base64URL.encode(Data(count: 65))
        XCTAssertNil(try request(["kind": "create", "user": ["id": long, "name": "ann"]]).user)
        XCTAssertNotNil(try request(["kind": "create", "user": ["id": Base64URL.encode(Data(count: 64)), "name": "ann"]]).user)
        XCTAssertNil(try request(["kind": "create", "user": ["id": "AQ"]]).user, "a user needs a name")
    }

    func testWhichAuthenticatorsMayAnswer() throws {
        let user: [String: Any] = ["id": "AQ", "name": "ann"]
        let either = try request(["kind": "create", "user": user])
        XCTAssertTrue(either.offersPlatform && either.offersSecurityKey)
        let key = try request(["kind": "create", "user": user, "authenticatorAttachment": "cross-platform"])
        XCTAssertFalse(key.offersPlatform)
        XCTAssertTrue(key.offersSecurityKey)
        // A passkey from the Mac is ES256, never offered to a site that doesn't take it.
        let rsa = try request(["kind": "create", "user": user, "algorithms": [-257], "authenticatorAttachment": "platform"])
        XCTAssertFalse(rsa.offersPlatform || rsa.offersSecurityKey)
        XCTAssertEqual(refusal(verdict(rsa, frame("https://example.com"))), "NotSupportedError")
        let get = try request(["authenticatorAttachment": "platform"])
        XCTAssertTrue(get.offersPlatform && get.offersSecurityKey, "a sign-in asks both")
    }

    func testPRFSaltsForAPasskeyNotAllowedAreLeftOut() throws {
        let get = try request([
            "allowCredentials": [["id": "AQ"]],
            "prf": ["eval": ["first": "AAAA", "second": NSNull()],
                    "byCredential": ["AQ": ["first": "AQEB"], "Ag": ["first": "AgIC"]]],
            "prfKey": "BAQE",
        ])
        let prf = try XCTUnwrap(get.prf)
        XCTAssertEqual(prf.eval, PasskeyRequest.PRFValues(first: Data([0, 0, 0]), second: nil))
        XCTAssertEqual(prf.byCredential, [Data([1]): PasskeyRequest.PRFValues(first: Data([1, 1, 1]), second: nil)])
        XCTAssertEqual(get.prfKey, Data([4, 4, 4]))
        XCTAssertNil(try request([:]).prf)
    }

    // MARK: The checks

    func testOnlyASecurePageMayAsk() throws {
        let get = try request([:])
        XCTAssertNotNil(passed(verdict(get, frame("https://example.com"))))
        XCTAssertEqual(refusal(verdict(get, frame("http://example.com"))), "NotAllowedError")
        for local in ["http://localhost:8000", "http://app.localhost", "http://127.0.0.1:5000"] {
            XCTAssertNotNil(passed(verdict(get, frame(local))), local)
        }
        XCTAssertTrue(PasskeyCheck.isSecure(scheme: "http", host: "::1"))
        XCTAssertFalse(PasskeyCheck.isSecure(scheme: "file", host: ""))
        XCTAssertFalse(PasskeyCheck.isSecure(scheme: "https", host: ""))
    }

    func testAPageBehindIsRefusedButOneWaitingUnderTheFieldMayAsk() throws {
        XCTAssertEqual(refusal(verdict(try request([:]), frame("https://example.com"), focused: false)), "NotAllowedError")
        let underField = try request(["conditional": true])
        XCTAssertEqual(passed(verdict(underField, frame("https://example.com"), focused: false))?.underField, true)
        // From a frame, or with no view to hang on, it waits, offered nothing.
        XCTAssertEqual(verdict(underField, frame("https://login.example.com", main: false, page: "https://example.com")), .wait)
        XCTAssertEqual(verdict(underField, frame("https://example.com"), hasView: false), .wait)
        // Insecure is refused before anything waits.
        XCTAssertEqual(refusal(verdict(underField, frame("http://example.com", main: false))), "NotAllowedError")
    }

    func testTheRelyingPartyIsTheHostOrASiteAboveIt() throws {
        let host = frame("https://login.example.co.uk")
        XCTAssertEqual(passed(verdict(try request([:]), host))?.rp, "login.example.co.uk", "none named is the frame's host")
        XCTAssertEqual(passed(verdict(try request(["rpId": ""]), host))?.rp, "login.example.co.uk")
        XCTAssertEqual(passed(verdict(try request(["rpId": "Example.CO.uk"]), host))?.rp, "example.co.uk")
        for refused in ["co.uk", "uk", "other.co.uk", "ample.co.uk", "evil-example.co.uk", "login.example.co.uk.evil.com"] {
            XCTAssertEqual(refusal(verdict(try request(["rpId": refused]), host)), "SecurityError", refused)
        }
        // A public suffix anyone can register under.
        XCTAssertEqual(refusal(verdict(try request(["rpId": "github.io"]), frame("https://ann.github.io"))), "SecurityError")
        // Without the public suffix list a page's own host is the only one.
        XCTAssertEqual(refusal(verdict(try request(["rpId": "example.co.uk"]), host, suffixes: false)), "SecurityError")
        XCTAssertNotNil(passed(verdict(try request(["rpId": "login.example.co.uk"]), host, suffixes: false)))
        // Nor above the host's public suffix, though not one itself: a tenant
        // of compute.amazonaws.com can't name amazonaws.com.
        let tenant = frame("https://attacker.compute.amazonaws.com")
        XCTAssertEqual(refusal(verdict(try request(["rpId": "amazonaws.com"]), tenant)), "SecurityError")
        XCTAssertEqual(refusal(verdict(try request(["rpId": "compute.amazonaws.com"]), tenant)), "SecurityError")
        XCTAssertNotNil(passed(verdict(try request(["rpId": "attacker.compute.amazonaws.com"]), tenant)))
        XCTAssertEqual(passed(verdict(try request(["rpId": "attacker.compute.amazonaws.com"]),
                                      frame("https://login.attacker.compute.amazonaws.com")))?.rp, "attacker.compute.amazonaws.com")
        // Never a domain above an address.
        XCTAssertFalse(PasskeyCheck.fits("0.1", "127.0.0.1", isSuffix: isSuffix))
        XCTAssertTrue(PasskeyCheck.fits("127.0.0.1", "127.0.0.1", isSuffix: isSuffix))
    }

    func testAChallengeAndForARegistrationAUserAreNeeded() throws {
        let page = frame("https://example.com")
        XCTAssertEqual(refusal(verdict(try request(["challenge": ""]), page)), "TypeError")
        XCTAssertEqual(refusal(verdict(try request(["challenge": NSNull()]), page)), "TypeError")
        XCTAssertEqual(refusal(verdict(try request(["kind": "create"]), page)), "TypeError")
        XCTAssertNotNil(passed(verdict(try request(["kind": "create", "user": ["id": "AQ", "name": "ann"]]), page)))
    }

    func testAFrameOfThePagesOwnSiteMayAskAndNamesThePage() throws {
        // Apple's sign-in: a frame from idmsa.apple.com in account.apple.com.
        let apple = frame("https://idmsa.apple.com", main: false, page: "https://account.apple.com/sign-in")
        let checked = try XCTUnwrap(passed(verdict(try request([:]), apple)))
        XCTAssertEqual(checked.origin, "https://idmsa.apple.com")
        XCTAssertEqual(checked.topOrigin, "https://account.apple.com")
        XCTAssertEqual(checked.rp, "idmsa.apple.com")
        // The page's own origin in a frame of it: nothing to name.
        let same = frame("https://example.com", main: false, page: "https://example.com/a")
        XCTAssertNil(passed(verdict(try request([:]), same))?.topOrigin)
        // The same host on another port is the same site and another origin.
        let port = frame("http://127.0.0.1:9001", main: false, page: "http://127.0.0.1:9000/top")
        XCTAssertEqual(passed(verdict(try request([:]), port))?.topOrigin, "http://127.0.0.1:9000")
    }

    func testAFrameOfAnotherSiteIsRefused() throws {
        let get = try request([:])
        XCTAssertEqual(refusal(verdict(get, frame("https://evil.com", main: false, page: "https://example.com"))), "NotAllowedError")
        // The same registrable domain, but the page is http.
        XCTAssertEqual(refusal(verdict(get, frame("https://a.example.com", main: false, page: "http://example.com"))), "NotAllowedError")
        // Without the public suffix list only the page's own host is its site.
        XCTAssertEqual(refusal(verdict(get, frame("https://idmsa.apple.com", main: false, page: "https://account.apple.com"),
                                       suffixes: false)), "NotAllowedError")
        // A frame whose page isn't known.
        let unknown = PasskeyFrame(scheme: "https", host: "example.com", port: 0, isMain: false, page: nil)
        XCTAssertEqual(refusal(verdict(get, unknown)), "NotAllowedError")
        // Two sites under one public suffix are two sites.
        XCTAssertEqual(refusal(verdict(get, frame("https://bob.github.io", main: false, page: "https://ann.github.io"))), "NotAllowedError")
    }

    func testEveryFrameBetweenMustBeOfTheSite() throws {
        let get = try request([:])
        // Another site's frame between the page and a frame of the page's site.
        let carried = frame("https://login.example.com", main: false, page: "https://account.example.com",
                            ancestors: ["https://ads.evil.com", "https://account.example.com"])
        XCTAssertEqual(refusal(verdict(get, carried)), "NotAllowedError")
        // A sandboxed frame between: its origin is opaque.
        let sandboxed = frame("https://login.example.com", main: false, page: "https://example.com",
                              ancestors: ["null", "https://example.com"])
        XCTAssertEqual(refusal(verdict(get, sandboxed)), "NotAllowedError")
        // No ancestors known, or none at all for a frame.
        XCTAssertEqual(refusal(verdict(get, PasskeyFrame(scheme: "https", host: "login.example.com", port: 0, isMain: false,
                                                         page: URL(string: "https://example.com"), ancestors: nil))), "NotAllowedError")
        XCTAssertEqual(refusal(verdict(get, frame("https://login.example.com", main: false, page: "https://example.com",
                                                  ancestors: []))), "NotAllowedError")
        // The outermost frame isn't the page the tab committed (a pop-up its
        // opener writes into before its first page is there).
        let elsewhere = frame("https://idmsa.apple.com", main: false, page: "https://account.apple.com",
                              ancestors: ["https://appleid.apple.com"])
        XCTAssertEqual(refusal(verdict(get, elsewhere)), "NotAllowedError")
        // Two frames of the site deep, of other origins: the frame element
        // between can't be read, so whether it allows passkeys isn't known.
        let deep = frame("https://idmsa.apple.com", main: false, page: "https://account.apple.com",
                         ancestors: ["https://appleid.apple.com", "https://account.apple.com"])
        XCTAssertEqual(refusal(verdict(get, deep)), "NotAllowedError")
        // Of the page's own origin all the way: allowed without asking, as the
        // permissions policy's default ('self') has it.
        let own = frame("https://example.com", main: false, page: "https://example.com/top",
                        ancestors: ["https://example.com", "https://example.com"], delegations: [])
        XCTAssertNotNil(passed(verdict(get, own)))
        XCTAssertNil(passed(verdict(get, own))?.topOrigin)
    }

    func testAFrameOfAnotherOriginAsksOnlyWhereThePageLetsIt() throws {
        let get = try request([:])
        let create = try request(["kind": "create", "user": ["id": "AQ", "name": "ann"]])
        let page = "https://account.apple.com", idmsa = "https://idmsa.apple.com"
        func from(_ allow: String?, src: String? = "https://idmsa.apple.com/sign-in") -> PasskeyFrame {
            frame(idmsa, main: false, page: page, delegations: allow.map { [PasskeyFrame.Delegation(allow: $0, src: src)] } ?? [])
        }
        // Not delegated at all, or delegations not known.
        XCTAssertEqual(refusal(verdict(get, from(nil))), "NotAllowedError")
        XCTAssertEqual(refusal(verdict(get, PasskeyFrame(scheme: "https", host: "idmsa.apple.com", port: 0, isMain: false,
                                                         page: URL(string: page), ancestors: [page], delegations: nil))), "NotAllowedError")
        // Named alone: for the frame's src.
        XCTAssertNotNil(passed(verdict(get, from("publickey-credentials-get"))))
        XCTAssertEqual(refusal(verdict(get, from("publickey-credentials-get", src: "https://other.apple.com"))), "NotAllowedError",
                       "a frame element for another origin")
        // Sign-in and making one are delegated apart.
        XCTAssertEqual(refusal(verdict(create, from("publickey-credentials-get"))), "NotAllowedError")
        XCTAssertNotNil(passed(verdict(create, from("camera; publickey-credentials-create"))))
        // Whom it is for.
        XCTAssertNotNil(passed(verdict(get, from("publickey-credentials-get *"))))
        XCTAssertNotNil(passed(verdict(get, from("publickey-credentials-get 'src'"))))
        XCTAssertNotNil(passed(verdict(get, from("publickey-credentials-get https://IDMSA.apple.com:443"))))
        XCTAssertEqual(refusal(verdict(get, from("publickey-credentials-get https://appleid.apple.com"))), "NotAllowedError")
        XCTAssertEqual(refusal(verdict(get, from("publickey-credentials-get 'none'"))), "NotAllowedError")
        XCTAssertEqual(refusal(verdict(get, from("publickey-credentials-get 'self'"))), "NotAllowedError",
                       "'self' is the page's own origin, not the frame's")
        XCTAssertEqual(refusal(verdict(get, from("publickey-credentials-getx"))), "NotAllowedError")
    }

    func testAFrameOfAnotherOriginMakesAPasskeyOnlyWhenClicked() throws {
        let create = try request(["kind": "create", "user": ["id": "AQ", "name": "ann"]])
        let page = "https://account.apple.com", idmsa = "https://idmsa.apple.com"
        XCTAssertEqual(refusal(verdict(create, frame(idmsa, main: false, page: page, activated: false))), "NotAllowedError")
        XCTAssertNotNil(passed(verdict(create, frame(idmsa, main: false, page: page, activated: true))))
        // Signing in needs no click there, nor making one on the page itself
        // or in a frame of its own origin.
        XCTAssertNotNil(passed(verdict(try request([:]), frame(idmsa, main: false, page: page, activated: false))))
        XCTAssertNotNil(passed(verdict(create, frame(page, activated: false))))
        XCTAssertNotNil(passed(verdict(create, frame(page, main: false, page: page + "/top", delegations: [], activated: false))))
    }

    func testAFrameOfThePagesOriginInAnotherIsCrossOrigin() throws {
        // example.com in sub.example.com in example.com: the standard's
        // sameOriginWithAncestors is false, and the frame element between
        // the two can't be read, so whether it allows passkeys isn't known.
        let bounced = frame("https://example.com", main: false, page: "https://example.com/top",
                            ancestors: ["https://sub.example.com", "https://example.com"])
        XCTAssertEqual(refusal(verdict(try request([:]), bounced)), "NotAllowedError")
    }

    func testOriginsAreWrittenAsTheStandardSerializesThem() {
        XCTAssertEqual(PasskeyCheck.origin(scheme: "HTTPS", host: "Example.com", port: 0), "https://example.com")
        XCTAssertEqual(PasskeyCheck.origin(scheme: "https", host: "example.com", port: 443), "https://example.com")
        XCTAssertEqual(PasskeyCheck.origin(scheme: "http", host: "localhost", port: 80), "http://localhost")
        XCTAssertEqual(PasskeyCheck.origin(scheme: "https", host: "example.com", port: 8443), "https://example.com:8443")
        XCTAssertEqual(PasskeyCheck.origin(scheme: "http", host: "::1", port: 8000), "http://[::1]:8000")
        XCTAssertEqual(PasskeyCheck.origin(of: URL(string: "https://example.com:443/path?q")), "https://example.com")
        XCTAssertNil(PasskeyCheck.origin(of: URL(string: "about:blank")))
        XCTAssertTrue(Registrable.sameSite("idmsa.apple.com", "account.apple.com", isSuffix: isSuffix))
        XCTAssertFalse(Registrable.sameSite("10.0.0.1", "10.0.0.2", isSuffix: isSuffix))
        XCTAssertTrue(Registrable.sameSite("10.0.0.1", "10.0.0.1", isSuffix: isSuffix))
    }

    // MARK: The answers

    func testBytesAreBase64URLWithoutPadding() {
        XCTAssertEqual(Base64URL.encode(Data([0xfb, 0xff])), "-_8")
        XCTAssertEqual(Base64URL.decode("-_8"), Data([0xfb, 0xff]))
        XCTAssertEqual(Base64URL.decode(""), Data())
        XCTAssertNil(Base64URL.decode(7))
        XCTAssertNil(Base64URL.decode("a"), "a single character is no bytes")
    }

    func testASecurityKeyMayLeaveOutTheUserHandle() throws {
        // Search's #646.
        let reply = PasskeyReply.assertion(id: Data([1]), clientData: Data([2]), authenticatorData: Data([3]), signature: Data([4]),
                                           user: nil, attachment: "cross-platform")
        XCTAssertTrue(reply["userHandle"] is NSNull)
        XCTAssertEqual(reply["id"] as? String, "AQ")
        XCTAssertEqual(reply["signature"] as? String, "BA")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: reply))
        let kept = PasskeyReply.assertion(id: Data([1]), clientData: Data([2]), authenticatorData: Data([3]), signature: Data([4]),
                                          user: Data([0xfb, 0xff]), attachment: "platform")
        XCTAssertEqual(kept["userHandle"] as? String, "-_8")
    }

    func testARegistrationCarriesItsAuthenticatorDataAndPublicKey() throws {
        let challenge = Data([9, 9])
        let reply = PasskeyReply.rehearsal(.create, origin: "https://example.com", challenge: challenge)
        XCTAssertEqual(reply["kind"] as? String, "create")
        XCTAssertEqual(reply["publicKeyAlgorithm"] as? Int, -7)
        let der = try XCTUnwrap(Base64URL.decode(reply["publicKey"]))
        XCTAssertEqual(der.count, 91, "a P-256 key as SubjectPublicKeyInfo")
        XCTAssertEqual(der.suffix(64), Data(repeating: 1, count: 32) + Data(repeating: 2, count: 32))
        let auth = try XCTUnwrap(Base64URL.decode(reply["authenticatorData"]))
        XCTAssertEqual(auth[32] & 0x40, 0x40, "a credential in it")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: reply))
        let client = try XCTUnwrap(Base64URL.decode(reply["clientDataJSON"]))
        let data = try XCTUnwrap(JSONSerialization.jsonObject(with: client) as? [String: Any])
        XCTAssertEqual(data["type"] as? String, "webauthn.create")
        XCTAssertEqual(data["challenge"] as? String, "CQk")
        XCTAssertEqual(data["crossOrigin"] as? Bool, false)
        XCTAssertNil(data["topOrigin"])
    }

    func testARehearsalFromAFrameNamesItsPage() throws {
        let reply = PasskeyReply.rehearsal(.get, origin: "https://idmsa.apple.com", topOrigin: "https://account.apple.com", challenge: Data([1]))
        let client = try XCTUnwrap(Base64URL.decode(reply["clientDataJSON"]))
        let data = try XCTUnwrap(JSONSerialization.jsonObject(with: client) as? [String: Any])
        XCTAssertEqual(data["crossOrigin"] as? Bool, true)
        XCTAssertEqual(data["topOrigin"] as? String, "https://account.apple.com")
        XCTAssertNil(reply["publicKey"], "an assertion has none")
    }

    func testAnEd25519KeyAndAnOtherKind() {
        func authData(_ key: [UInt8]) -> Data {
            Data(count: 32) + Data([0x41]) + Data(count: 4) + Data(count: 16) + Data([0, 1, 7]) + Data(key)
        }
        // {1: 1, 3: -8, -1: 6, -2: 32 bytes}
        let ed = [0xA4, 0x01, 0x01, 0x03, 0x27, 0x20, 0x06, 0x21, 0x58, 0x20] + [UInt8](repeating: 5, count: 32)
        let key = PasskeyReply.publicKey(inAuthenticatorData: authData(ed))
        XCTAssertEqual(key?.algorithm, -8)
        XCTAssertEqual(key?.der?.count, 44)
        // RSA: {1: 3, 3: -257}, left for the site to read from the attestation.
        let rsa = PasskeyReply.publicKey(inAuthenticatorData: authData([0xA2, 0x01, 0x03, 0x03, 0x39, 0x01, 0x00]))
        XCTAssertEqual(rsa?.algorithm, -257)
        XCTAssertNil(rsa?.der)
        // No credential in it, or cut short.
        XCTAssertNil(PasskeyReply.publicKey(inAuthenticatorData: Data(count: 37)))
        XCTAssertNil(PasskeyReply.publicKey(inAuthenticatorData: authData([0xA4, 0x01])))
    }

    func testAnAttestationObjectThatIsNoMapGivesNothing() {
        XCTAssertNil(PasskeyReply.authenticatorData(inAttestation: Data()))
        XCTAssertNil(PasskeyReply.authenticatorData(inAttestation: Data([0x83, 1, 2, 3])))
        // {"fmt": "none"} with no authData.
        XCTAssertNil(PasskeyReply.authenticatorData(inAttestation: Data([0xA1, 0x63]) + Data("fmt".utf8) + Data([0x64]) + Data("none".utf8)))
        // A byte string longer than the object.
        XCTAssertNil(PasskeyReply.authenticatorData(inAttestation: Data([0xA1, 0x68]) + Data("authData".utf8) + Data([0x59, 0xFF, 0xFF, 1])))
    }

    func testFailuresAreWhatThePageReads() {
        XCTAssertEqual(PasskeyFailure.notAllowed.reply["error"] as? String, "NotAllowedError")
        XCTAssertEqual(PasskeyFailure.wait.reply["error"] as? String, "Wait", "passkeys.js keeps waiting on this name")
        XCTAssertEqual(PasskeyFailure.alreadyHeld.name, "InvalidStateError")
    }

    #if canImport(CryptoKit)
    /// The page's side of the PRF results, done here as passkeys.js does it
    /// with WebCrypto: its one-time key, ECDH with the app's, HKDF with
    /// "eglu-prf", AES-GCM with the nonce first.
    func testPRFResultsGoSealedForThePagesKeyAlone() throws {
        let page = P256.KeyAgreement.PrivateKey()
        let get = try request(["prf": ["eval": ["first": "AA"]], "prfKey": Base64URL.encode(page.publicKey.x963Representation)])
        let pageKey = try XCTUnwrap(PasskeyReply.pageKey(get))
        let first = Data(repeating: 7, count: 32), second = Data(repeating: 8, count: 32)
        let reply = PasskeyReply.prf(enabled: true, first: first, second: second, for: pageKey)
        XCTAssertEqual(reply["enabled"] as? Bool, true)
        XCTAssertNil(reply["first"], "never in the clear")
        let sealed = try XCTUnwrap(reply["sealed"] as? [String: String])
        let theirs = try P256.KeyAgreement.PublicKey(x963Representation: try XCTUnwrap(Base64URL.decode(sealed["key"])))
        let shared = try page.sharedSecretFromKeyAgreement(with: theirs)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("eglu-prf".utf8), outputByteCount: 32)
        let box = try XCTUnwrap(Base64URL.decode(sealed["box"]))
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: box), using: key)
        let results = try XCTUnwrap(JSONSerialization.jsonObject(with: plain) as? [String: String])
        XCTAssertEqual(results["first"], Base64URL.encode(first))
        XCTAssertEqual(results["second"], Base64URL.encode(second))
        // Another key can't open it.
        let other = try P256.KeyAgreement.PrivateKey().sharedSecretFromKeyAgreement(with: theirs)
        let wrong = other.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("eglu-prf".utf8), outputByteCount: 32)
        XCTAssertThrowsError(try AES.GCM.open(AES.GCM.SealedBox(combined: box), using: wrong))
    }

    func testWithoutThePagesKeyNoPRFResultsGo() throws {
        let reply = PasskeyReply.prf(enabled: false, first: Data([1]), second: nil, for: nil)
        XCTAssertEqual(reply["enabled"] as? Bool, false)
        XCTAssertNil(reply["sealed"])
        XCTAssertNil(PasskeyReply.pageKey(try request(["prfKey": "AQID"])), "not a P-256 key")
        XCTAssertTrue(PasskeyReply.prf(enabled: nil, first: nil, second: nil, for: P256.KeyAgreement.PrivateKey().publicKey).isEmpty)
    }
    #endif

    // MARK: The scripts

    func testTheScriptsShipAndNameEachOther() {
        XCTAssertTrue(Scripts.passkeys.contains("Symbol.for('eglu.passkeys')"))
        XCTAssertTrue(Scripts.passkeysBridge.contains("globalThis.egluBridge") && Scripts.passkeysBridge.contains("'egluPasskeys'"),
                      "the bridge asks through egluBridge, on the channel Mac/Sources/Passkeys.swift opens")
        XCTAssertFalse(Scripts.passkeysBridge.contains("messageHandlers"), "never window.webkit itself")
        for name in ["eglu-passkeys-ask", "eglu-passkeys-answer"] {
            XCTAssertTrue(Scripts.passkeys.contains(name) && Scripts.passkeysBridge.contains(name), name)
        }
        XCTAssertTrue(Scripts.passkeys.contains("'eglu-prf'"), "the same HKDF info as PasskeyReply.sealingKey")
        XCTAssertFalse(Scripts.passkeys.contains("messageHandlers"), "nothing of the app's in the page's own world")
        // Both go into every frame: each is given the hands-off hosts to
        // leave alone, first thing.
        for script in [Scripts.passkeys, Scripts.passkeysBridge] {
            XCTAssertFalse(script.contains(Scripts.handsOffMark))
            XCTAssertTrue(HandsOff.hosts.allSatisfy { script.contains("\"\($0)\"") })
        }
    }
}
