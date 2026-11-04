import WebEngineCore
import WebKit
import WebKitSupport

@MainActor
public final class WebKitMessageChannels: WebMessageChannels {
    private let controller: WKUserContentController
    private let appWorld: WKContentWorld

    public init(controller: WKUserContentController, appWorld: WKContentWorld) {
        self.controller = controller
        self.appWorld = appWorld
    }

    public var bridgeScript: String { WebKitScriptBridge.source }

    public func open(_ channel: String, in world: WebWorld, handler: @escaping WebMessageHandler) {
        controller.add(PostChannel(appWorld: appWorld, world: world, handler: handler),
                       contentWorld: contentWorld(world), name: channel)
    }

    public func open(_ channel: String, in world: WebWorld, replying handler: @escaping WebMessageReplyHandler) {
        controller.addScriptMessageHandler(ReplyChannel(appWorld: appWorld, world: world, handler: handler),
                                           contentWorld: contentWorld(world), name: channel)
    }

    private func contentWorld(_ world: WebWorld) -> WKContentWorld {
        world == .app ? appWorld : .page
    }
}

@MainActor
private func translated(_ message: WKScriptMessage, appWorld: WKContentWorld, world: WebWorld) -> WebMessage? {
    guard message.world == appWorld || message.world == .page else { return nil }
    let securityOrigin = message.frameInfo.securityOrigin
    let origin: WebOrigin
    if !securityOrigin.protocol.isEmpty, !securityOrigin.host.isEmpty {
        origin = .tuple(scheme: securityOrigin.protocol, host: securityOrigin.host, port: securityOrigin.port)
    } else {
        origin = .opaque
    }
    return WebMessage(channel: message.name, world: world, isMainFrame: message.frameInfo.isMainFrame,
                      origin: origin, body: WebJSON(foundation: message.body))
}

@MainActor
private final class PostChannel: NSObject, WKScriptMessageHandler {
    let appWorld: WKContentWorld
    let world: WebWorld
    let handler: WebMessageHandler

    init(appWorld: WKContentWorld, world: WebWorld, handler: @escaping WebMessageHandler) {
        self.appWorld = appWorld
        self.world = world
        self.handler = handler
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let message = translated(message, appWorld: appWorld, world: world) else { return }
            handler(message)
        }
    }
}

@MainActor
private final class ReplyChannel: NSObject, WKScriptMessageHandlerWithReply {
    let appWorld: WKContentWorld
    let world: WebWorld
    let handler: WebMessageReplyHandler

    init(appWorld: WKContentWorld, world: WebWorld, handler: @escaping WebMessageReplyHandler) {
        self.appWorld = appWorld
        self.world = world
        self.handler = handler
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                         replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        MainActor.assumeIsolated {
            guard let message = translated(message, appWorld: appWorld, world: world) else {
                replyHandler(nil, nil)
                return
            }
            var replied = false
            handler(message) { reply in
                guard !replied else { return }
                replied = true
                replyHandler(reply?.foundation, nil)
            }
        }
    }
}
