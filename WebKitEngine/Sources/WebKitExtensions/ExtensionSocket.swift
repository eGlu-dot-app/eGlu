#if os(macOS)
import Foundation
import PadCore
import WebKit

// A WebSocket for an extension's worker. Copied from Search
// (github.com/driceroland/Search, MIT, its ExtensionSocket.swift), with
// eGlu's names, and held to what the extension's own connections are:
// never Google's sign-in, and only where its connect-src lets it. It
// carries no cookies, as Search's doesn't: eGlu never reads them.
//
// WebKit runs an extension's service worker on the main thread of its web
// process, and a worker's WebSocket waits there, synchronously, for the main
// thread to set up its channel: the worker waits on itself, for ever, and
// every page of the extension freezes with it. 1Password opens one the moment
// a sign-in succeeds, the account was never added, the popup stopped
// answering, and nothing was offered on any page again.
//
// So in a worker the shim's WebSocket is made here instead, with URLSession,
// and its frames carried over a native port: text as it is, binary as
// base64. The Origin and the user agent are the ones Chrome would send.

@MainActor
public enum ExtensionSocket {
    /// The native application the shim connects to for a socket.
    public static func name(shimApplication: String) -> String { shimApplication + ".socket" }

    /// One session for every socket; each task has its connection as its
    /// own delegate. No cookie jar: none are sent, and none it is sent are
    /// kept, so nothing passes from one space or extension to another.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration, delegate: nil, delegateQueue: .main)
    }()
    /// Held from the port's opening until either end lets go, or the
    /// extension or its space goes.
    private static var open: [ObjectIdentifier: Connection] = [:]

    public static func connect(_ port: WKWebExtension.MessagePort, from extensionID: String, in space: UUID, policy: String?, scheme: String) {
        let connection = Connection(port: port, origin: "\(scheme)://\(extensionID)", extensionID: extensionID,
                                    space: space, policy: policy)
        let key = ObjectIdentifier(connection)
        open[key] = connection
        connection.onEnd = { open[key] = nil }
    }

    /// Every socket of an extension in a space, or of a space, closed:
    /// WebKit doesn't always tell its ports' ends when it unloads one.
    public static func close(_ extensionID: String? = nil, in space: UUID) {
        for connection in open.values where connection.space == space && (extensionID == nil || connection.extensionID == extensionID) {
            connection.close()
        }
    }

    static func allowed(_ url: URL?, policy: String?) -> Bool {
        guard let url, ["ws", "wss", "http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return ExtensionPolicy.mayTouchData(ofDomain: url.host() ?? "") && ExtensionPolicy.allowsConnection(to: url, policy: policy)
    }

    static func request(_ address: String, protocols: [String], userAgent: String?, origin: String, policy: String?) -> URLRequest? {
        guard let url = URL(string: address), ["ws", "wss"].contains(url.scheme?.lowercased()), allowed(url, policy: policy) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(origin, forHTTPHeaderField: "Origin")
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        if !protocols.isEmpty {
            request.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }
        return request
    }

    @MainActor
    final class Connection: NSObject, URLSessionWebSocketDelegate {
        private let port: WKWebExtension.MessagePort
        private let origin: String
        let extensionID: String
        let space: UUID
        private let policy: String?
        private var task: URLSessionWebSocketTask?
        private var ended = false
        var onEnd: (() -> Void)?

        init(port: WKWebExtension.MessagePort, origin: String, extensionID: String, space: UUID, policy: String?) {
            self.port = port
            self.origin = origin
            self.extensionID = extensionID
            self.space = space
            self.policy = policy
            super.init()
            port.messageHandler = { [weak self] message, _ in
                MainActor.assumeIsolated { self?.take(message) }
            }
            port.disconnectHandler = { [weak self] _ in
                MainActor.assumeIsolated { self?.end(tellingPort: false) }
            }
            // WebKit loses a port a worker opens in its first moments; the
            // shim takes this for the sign that this one arrived.
            post(["ready": true])
        }

        private func take(_ message: Any?) {
            guard let message = message as? [String: Any] else { return }
            // The worker's shim asks every port to an app whether it has
            // arrived before sending on it (see ExtensionNative): this one
            // answers too, so the socket is never held waiting.
            if let word = message["__egluNative"] {
                if (word as? String) == "here?" { post(["__egluNative": "here"]) }
                return
            }
            if let address = message["open"] as? String {
                // Said again now that the worker is surely listening: the
                // first one, sent as the port opened, is often lost. The
                // worker says "open" until it hears back, so a repeat is
                // only answered.
                post(["ready": true])
                guard task == nil else { return }
                start(address, protocols: message["protocols"] as? [String] ?? [], userAgent: message["userAgent"] as? String)
            } else if let text = message["send"] as? String {
                task?.send(.string(text)) { _ in }
            } else if let encoded = message["sendBinary"] as? String, let data = Data(base64Encoded: encoded) {
                task?.send(.data(data)) { _ in }
            } else if message["close"] != nil {
                let code = (message["close"] as? Int).flatMap(URLSessionWebSocketTask.CloseCode.init(rawValue:)) ?? .normalClosure
                let reason = (message["reason"] as? String).map { Data($0.utf8) }
                task?.cancel(with: code, reason: reason)
            }
        }

        /// Where a socket may go: ws or wss, never Google's sign-in
        /// (ExtensionPolicy), as the extension's own requests can't, and only
        /// where its connect-src lets it.
        private func allowed(_ url: URL?) -> Bool {
            ExtensionSocket.allowed(url, policy: policy)
        }

        private func start(_ address: String, protocols: [String], userAgent: String?) {
            guard task == nil else { return }
            guard let request = ExtensionSocket.request(address, protocols: protocols, userAgent: userAgent, origin: origin, policy: policy) else {
                fail()
                return
            }
            let task = ExtensionSocket.session.webSocketTask(with: request)
            task.delegate = self
            self.task = task
            task.resume()
        }

        /// Closed from outside: the extension unloaded, or its space gone.
        func close() {
            post(["closed": 1001, "reason": "", "clean": false])
            end(tellingPort: true)
        }

        // A handshake sent elsewhere goes only where it could have gone itself.
        nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            MainActor.assumeIsolated {
                if allowed(request.url) {
                    completionHandler(request)
                } else {
                    completionHandler(nil)
                    fail()
                }
            }
        }

        /// Frames as they come, until the socket ends; how it ended is the
        /// delegate's to say.
        private func receive(from task: URLSessionWebSocketTask) {
            Task { [weak self] in
                while let message = try? await task.receive() {
                    guard let self, !self.ended else { return }
                    switch message {
                    case .string(let text): self.post(["text": text])
                    case .data(let data): self.post(["binary": data.base64EncodedString()])
                    @unknown default: break
                    }
                }
            }
        }

        private func post(_ message: [String: Any]) {
            guard !port.isDisconnected else { return }
            port.sendMessage(message, completionHandler: nil)
        }

        private func fail() {
            post(["failed": true])
            post(["closed": 1006, "reason": "", "clean": false])
            end(tellingPort: true)
        }

        private func end(tellingPort: Bool) {
            guard !ended else { return }
            ended = true
            task?.cancel(with: .goingAway, reason: nil)
            if tellingPort, !port.isDisconnected { port.disconnect() }
            onEnd?()
        }

        nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol chosen: String?) {
            MainActor.assumeIsolated {
                post(["opened": chosen ?? ""])
                receive(from: webSocketTask)
            }
        }

        nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
            MainActor.assumeIsolated {
                post(["closed": closeCode.rawValue, "reason": reason.map { String(decoding: $0, as: UTF8.self) } ?? "", "clean": true])
                end(tellingPort: true)
            }
        }

        nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            MainActor.assumeIsolated {
                guard !ended else { return }
                if error != nil {
                    fail()
                } else {
                    post(["closed": 1005, "reason": "", "clean": true])
                    end(tellingPort: true)
                }
            }
        }
    }
}
#endif
