import AppKit
import WebEngineAppKit
import WebEngineCore
import WebKit

@MainActor
public final class WebKitPageServices: WebFind, WebZoom, WebMediaCapture, WebUserAgent, WebPrinting, WebDeveloperTools, WebBackForward, WebRestoration {
    private weak var view: WKWebView?

    public init(view: WKWebView) { self.view = view }

    public var currentEntry: AnyObject? { view?.backForwardList.currentItem }

    public var restorationData: Any? {
        get { view?.interactionState }
        set { view?.interactionState = newValue }
    }

    public func find(_ text: String, backwards: Bool, caseSensitive: Bool, wraps: Bool,
                     found: @escaping @MainActor (Bool) -> Void) {
        guard let view else { return found(false) }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = caseSensitive
        configuration.wraps = wraps
        view.find(text, configuration: configuration) { result in found(result.matchFound) }
    }

    public var pageZoom: Double {
        get { view.map { Double($0.pageZoom) } ?? 1 }
        set { view?.pageZoom = CGFloat(newValue) }
    }

    public var magnification: Double { view.map { Double($0.magnification) } ?? 1 }

    public var isCapturing: Bool {
        guard let view else { return false }
        return view.cameraCaptureState != .none || view.microphoneCaptureState != .none
    }

    /// WebKit reads back an empty string, not nil, once its own agent is
    /// back: both mean the engine's own here.
    public var customUserAgent: String? {
        get { view?.customUserAgent.flatMap { $0.isEmpty ? nil : $0 } }
        set { view?.customUserAgent = newValue }
    }

    public func printOperation(with info: NSPrintInfo) -> NSPrintOperation {
        guard let view else { return NSPrintOperation(view: NSView(), printInfo: info) }
        let operation = view.printOperation(with: info)
        operation.view?.frame = view.bounds
        return operation
    }

    /// The tool asked for, opened for the page in WebKit's own Web Inspector,
    /// which opens in its own window. A private API (WKWebViewPrivate.h: every
    /// WKWebView keeps an `_inspector`, a _WKInspector with show(), showConsole()
    /// and toggleElementSelection()) gone at behind responds(to:), as the DMG
    /// may and the other private calls in WebKitConfiguration.make do. A WebKit
    /// that takes it away leaves this false, and the host says Safari's Develop
    /// menu is the way instead.
    @discardableResult
    public func show(_ tool: WebDeveloperTool) -> Bool {
        guard let view else { return false }
        guard view.responds(to: Selector(("_inspector"))),
              let inspector = view.value(forKey: "_inspector") as? NSObject
        else { return false }
        let verb: Selector
        switch tool {
        case .inspector: verb = NSSelectorFromString("show")
        case .console: verb = NSSelectorFromString("showConsole")
        case .elementSelection: verb = NSSelectorFromString("toggleElementSelection")
        }
        guard inspector.responds(to: verb) else { return false }
        inspector.perform(verb)
        return true
    }
}
