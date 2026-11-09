import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// What goes back to the page's script once macOS has answered (or a test
/// run has made up an answer): the credential's bytes as base64url, in the
/// shape passkeys.js turns into the PublicKeyCredential WebKit would have
/// made. From Search (github.com/driceroland/Search, MIT, its Passkeys.swift).
public enum PasskeyReply {
    /// A passkey or a security key signed in. `user` is the account's
    /// handle, which a security key may leave out (Search's #646).
    public static func assertion(id: Data, clientData: Data, authenticatorData: Data, signature: Data, user: Data?,
                                 attachment: String) -> [String: Any] {
        [
            "kind": "get", "id": Base64URL.encode(id), "clientDataJSON": Base64URL.encode(clientData),
            "authenticatorData": Base64URL.encode(authenticatorData), "signature": Base64URL.encode(signature),
            "userHandle": user.map(Base64URL.encode) ?? NSNull(), "attachment": attachment,
        ]
    }

    /// A new passkey or security key credential, with what the page may ask
    /// of it directly: its authenticator data, and its public key and algorithm.
    public static func registration(id: Data, clientData: Data, attestation: Data, transports: [String],
                                    attachment: String) -> [String: Any] {
        var reply: [String: Any] = [
            "kind": "create", "id": Base64URL.encode(id), "clientDataJSON": Base64URL.encode(clientData),
            "attestationObject": Base64URL.encode(attestation), "transports": transports, "attachment": attachment,
        ]
        if let data = authenticatorData(inAttestation: attestation) {
            reply["authenticatorData"] = Base64URL.encode(data)
            if let key = publicKey(inAuthenticatorData: data) {
                reply["publicKeyAlgorithm"] = key.algorithm
                if let der = key.der { reply["publicKey"] = Base64URL.encode(der) }
            }
        }
        return reply
    }

    /// The credential id of a test run's made-up passkey.
    public static let rehearsalID = Data((0..<16).map { UInt8($0) })

    /// For a test run, which never shows the Mac's sheet: a credential in the
    /// shape the sheet gives, made up from the request, a P-256 key and all,
    /// with nothing signed, and the client data the Mac would be given. The
    /// checks before it and the page's side are what they are for real.
    public static func rehearsal(_ kind: PasskeyRequest.Kind, origin: String, topOrigin: String? = nil, challenge: Data) -> [String: Any] {
        let top = topOrigin.map { #","topOrigin":"\#($0)""# } ?? ""
        let client = Data((#"{"type":"webauthn.\#(kind.rawValue)","challenge":"\#(Base64URL.encode(challenge))","origin":"\#(origin)","crossOrigin":\#(topOrigin != nil)"#
            + top + "}").utf8)
        let id = rehearsalID
        // Where the relying party's hash would be, then the flags and the count.
        var auth = Data(count: 32) + Data([kind == .get ? 0x05 : 0x45]) + Data(count: 4)
        guard kind == .create else {
            return assertion(id: id, clientData: client, authenticatorData: auth, signature: Data([0x30, 0]),
                             user: Data("user".utf8), attachment: "platform")
        }
        auth += Data(count: 16) + Data([0, UInt8(id.count)]) + id
        auth += Data([0xA5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20]) + Data(repeating: 1, count: 32)
        auth += Data([0x22, 0x58, 0x20]) + Data(repeating: 2, count: 32)
        var object = Data([0xA3, 0x63]) + Data("fmt".utf8) + Data([0x64]) + Data("none".utf8)
        object += Data([0x67]) + Data("attStmt".utf8) + Data([0xA0])
        object += Data([0x68]) + Data("authData".utf8) + Data([0x59, UInt8(auth.count >> 8), UInt8(auth.count & 0xFF)]) + auth
        return registration(id: id, clientData: client, attestation: object, transports: ["hybrid", "internal"],
                            attachment: "platform")
    }

    // MARK: Keys derived from a passkey

    #if canImport(CryptoKit)
    /// The one-time public key the page's script made for a request.
    public static func pageKey(_ request: PasskeyRequest) -> P256.KeyAgreement.PublicKey? {
        request.prfKey.flatMap { try? P256.KeyAgreement.PublicKey(x963Representation: $0) }
    }

    /// What the passkey derived, for the page: `enabled` only answers a
    /// registration. The results are keys only the page's own call may see,
    /// and the way back to it is an event any script on the page can listen
    /// to: so they go sealed, for the one-time key the call made and kept to
    /// itself (ECDH P-256, HKDF-SHA256, AES-GCM, the nonce first and the tag
    /// last). Without that key, none go.
    public static func prf(enabled: Bool?, first: Data?, second: Data?, for page: P256.KeyAgreement.PublicKey?) -> [String: Any] {
        var reply: [String: Any] = [:]
        if let enabled { reply["enabled"] = enabled }
        guard let first, let page else { return reply }
        var results = ["first": Base64URL.encode(first)]
        if let second { results["second"] = Base64URL.encode(second) }
        let mine = P256.KeyAgreement.PrivateKey()
        guard let shared = try? mine.sharedSecretFromKeyAgreement(with: page),
              let plain = try? JSONSerialization.data(withJSONObject: results),
              let box = try? AES.GCM.seal(plain, using: sealingKey(shared)).combined
        else { return reply }
        reply["sealed"] = ["key": Base64URL.encode(mine.publicKey.x963Representation), "box": Base64URL.encode(box)]
        return reply
    }

    /// The key both sides derive from their shared secret. "eglu-prf" binds
    /// it to this use, as passkeys.js does.
    static func sealingKey(_ shared: SharedSecret) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("eglu-prf".utf8), outputByteCount: 32)
    }

    /// A test run's made-up PRF output, sealed the way a real one is.
    public static func rehearsalPRF(enabled: Bool?, for page: P256.KeyAgreement.PublicKey?) -> [String: Any] {
        prf(enabled: enabled, first: Data(SHA256.hash(data: Data("rehearsal".utf8))), second: nil, for: page)
    }
    #endif

    // MARK: Inside an attestation object

    /// The authenticator data inside an attestation object (a CBOR map with
    /// it under "authData"), for the pages that ask for it directly.
    public static func authenticatorData(inAttestation object: Data) -> Data? {
        var reader = CBOR(bytes: [UInt8](object))
        guard let pairs = reader.mapCount() else { return nil }
        for _ in 0..<pairs {
            guard let key = reader.text() else { return nil }
            if key == "authData" { return reader.blob().map { Data($0) } }
            guard reader.skip() else { return nil }
        }
        return nil
    }

    /// The new credential's public key, from its authenticator data: the
    /// algorithm, and the key as getPublicKey() hands it over, DER, for the
    /// two kinds passkeys and security keys make, P-256 and Ed25519. For any
    /// other the site reads it out of the attestation object itself.
    public static func publicKey(inAuthenticatorData data: Data) -> (algorithm: Int, der: Data?)? {
        let bytes = [UInt8](data)
        // The relying party's hash, the flags (with a credential in them),
        // the count, the model's id, and the credential id's length.
        guard bytes.count > 55, bytes[32] & 0x40 != 0 else { return nil }
        let start = 55 + (Int(bytes[53]) << 8 | Int(bytes[54]))
        guard start < bytes.count else { return nil }
        var reader = CBOR(bytes: Array(bytes[start...]))
        guard let pairs = reader.mapCount() else { return nil }
        var fields: [Int: Any] = [:]
        for _ in 0..<pairs {
            guard let key = reader.int() else { return nil }
            switch reader.major {
            case 0, 1: fields[key] = reader.int()
            case 2: fields[key] = reader.blob()
            default: guard reader.skip() else { return nil }
            }
        }
        guard let algorithm = fields[3] as? Int else { return nil }
        let x = fields[-2] as? [UInt8]
        switch (fields[1] as? Int, fields[-1] as? Int) {
        case (2, 1):
            guard let x, x.count == 32, let y = fields[-3] as? [UInt8], y.count == 32 else { return (algorithm, nil) }
            let head: [UInt8] = [
                0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
                0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00, 0x04,
            ]
            return (algorithm, Data(head + x + y))
        case (1, 6):
            guard let x, x.count == 32 else { return (algorithm, nil) }
            return (algorithm, Data([0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00] + x))
        default:
            return (algorithm, nil)
        }
    }
}

/// Just enough CBOR to read an attestation object: maps, numbers, text and
/// byte strings, and a step over anything else.
struct CBOR {
    let bytes: [UInt8]
    var at = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    var major: UInt8? { at < bytes.count ? bytes[at] >> 5 : nil }

    private mutating func head() -> (major: UInt8, value: UInt64)? {
        guard at < bytes.count else { return nil }
        let first = bytes[at]
        at += 1
        let info = first & 0x1F
        switch info {
        case 0..<24:
            return (first >> 5, UInt64(info))
        case 24...27:
            let size = 1 << Int(info - 24)
            guard at + size <= bytes.count else { return nil }
            let value = bytes[at..<(at + size)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            at += size
            return (first >> 5, value)
        default:
            return nil
        }
    }

    mutating func mapCount() -> Int? {
        guard let (major, value) = head(), major == 5, value < 1024 else { return nil }
        return Int(value)
    }

    mutating func int() -> Int? {
        guard let (major, value) = head(), value < UInt64(Int.max) else { return nil }
        switch major {
        case 0: return Int(value)
        case 1: return -1 - Int(value)
        default: return nil
        }
    }

    mutating func text() -> String? {
        guard let (major, value) = head(), major == 3, value <= UInt64(bytes.count - at) else { return nil }
        defer { at += Int(value) }
        return String(bytes: bytes[at..<(at + Int(value))], encoding: .utf8)
    }

    mutating func blob() -> [UInt8]? {
        guard let (major, value) = head(), major == 2, value <= UInt64(bytes.count - at) else { return nil }
        defer { at += Int(value) }
        return Array(bytes[at..<(at + Int(value))])
    }

    mutating func skip(depth: Int = 0) -> Bool {
        guard depth < 16, let (major, value) = head() else { return false }
        switch major {
        case 0, 1, 7:
            return true
        case 2, 3:
            guard value <= UInt64(bytes.count - at) else { return false }
            at += Int(value)
            return true
        case 4:
            guard value < 1024 else { return false }
            return (0..<value).allSatisfy { _ in skip(depth: depth + 1) }
        case 5:
            guard value < 1024 else { return false }
            return (0..<value).allSatisfy { _ in skip(depth: depth + 1) && skip(depth: depth + 1) }
        case 6:
            return skip(depth: depth + 1)
        default:
            return false
        }
    }
}
