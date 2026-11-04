import Foundation

/// Each call is synchronous, on the main actor, where the observation fires.
@MainActor public protocol WebPageStateEvents: AnyObject {
    func titleOrAddressChanged()
    func loadingChanged()
    func progressChanged()
    func backOrForwardChanged()
    func secureContentChanged()
}

public enum WebInjection: Sendable { case atDocumentStart, atDocumentEnd }

/// App scripts, separate from the extension runtime's scripts. Evaluations
/// target the main frame (WebKit's nil frame). Values and errors pass unchanged.
/// The app checks HandsOff before each operation it guards today.
@MainActor public protocol WebPageScripting: AnyObject {
    func removeAllUserScripts()
    func addUserScript(source: String, injectionTime: WebInjection,
                       forMainFrameOnly: Bool, world: WebWorld)
    func addFilterScripts(blocker: String?, scriptlets: String?)
    func evaluateJavaScript(_ source: String, world: WebWorld,
                            completionHandler: (@MainActor (Result<Any, any Error>) -> Void)?)
    func callAsyncJavaScript(_ body: String, arguments: [String: Any], world: WebWorld,
                             completionHandler: (@MainActor (Result<Any, any Error>) -> Void)?)
    func callAsyncJavaScript(_ body: String, arguments: [String: Any], world: WebWorld) async throws -> Any?
}

extension WebPageScripting {
    public func evaluateJavaScript(_ source: String, world: WebWorld) {
        evaluateJavaScript(source, world: world, completionHandler: nil)
    }
    public func callAsyncJavaScript(_ body: String, world: WebWorld) async throws -> Any? {
        try await callAsyncJavaScript(body, arguments: [:], world: world)
    }
}
