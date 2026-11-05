import AppKit
import WebKitExtensions

/// chrome.identity.launchWebAuthFlow: an extension's sign-in through its
/// provider's page, in the space the extension asked from. The moment the
/// page heads for the extension's own https://<id>.chromiumapp.org/, that
/// address is the answer; nothing is ever loaded from chromiumapp.org.
/// A flow that says it is interactive gets a tab in front; the plugin
/// owns the flow out of sight. (Search's ExtensionAuth)
@MainActor
enum ExtensionAuth {
    /// A sign-in waiting for its answer, by space and extension: one at a
    /// time for each, a new one ending the last, as in Chrome.
    private struct Flow {
        let tab: UUID
        let finish: (Result<URL, Error>) -> Void
        let watch: Timer
    }

    private static var waiting: [String: Flow] = [:]

    private static func key(_ id: String, _ space: UUID) -> String {
        "\(space.uuidString)/\(id.lowercased())"
    }

    /// Chrome's words for each way a flow ends without an answer.
    static let declined = "The user did not approve access."
    static let notLoaded = WebKitExtensionAuth.notLoaded

    /// The runtime owns the shared address check.
    static func owner(of url: URL?) -> String? { WebKitExtensionAuth.owner(of: url) }

    // MARK: In a tab

    /// The provider's page in a tab in front. Closing the tab is saying no;
    /// so is ten minutes with nobody finishing. A page that can't load ends
    /// it at once (loadFailed). The hub opens the runtime's tab with the
    /// context it already has, only when this flow asks for it.
    static func run(_ url: URL, extension id: String, in space: UUID, openTab: () -> ExtensionTab?) async throws -> URL {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw Extensions.Unanswered(why: notLoaded) }
        let key = key(id, space)
        return try await withCheckedThrowingContinuation { continuation in
            // The last one's tab goes with it: its page can't finish anything now.
            let superseded = waiting[key]?.tab
            end(key, .failure(Extensions.Unanswered(why: declined)))
            if let superseded, Session.shared.workspace.tab(superseded) != nil { Session.shared.closeTab(superseded) }
            guard let tab = openTab() else {
                return continuation.resume(throwing: Extensions.Unanswered(why: notLoaded))
            }
            inFront(tab.id, in: space)
            let started = Date()
            let watch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard let flow = waiting[key], flow.tab == tab.id else { return }
                    if Session.shared.workspace.tab(flow.tab) == nil || Date().timeIntervalSince(started) > 600 {
                        end(key, .failure(Extensions.Unanswered(why: declined)))
                    }
                }
            }
            waiting[key] = Flow(tab: tab.id, finish: { continuation.resume(with: $0) }, watch: watch)
        }
    }

    /// The sign-in's tab where the person can see it: in a window on its
    /// space, brought forward, or in a new one when none shows the space.
    private static func inFront(_ tab: UUID, in space: UUID) {
        let session = Session.shared
        if let window = session.allWindows.first(where: { $0.shows(tab) }) ?? session.allWindows.first(where: { $0.spaceID == space }) {
            window.select(tab)
            window.window?.makeKeyAndOrderFront(nil)
        } else {
            session.openWindow?(space)
        }
    }

    /// The flow's tab couldn't load its page: the flow ends now, as
    /// Chrome's does, not ten minutes on.
    static func loadFailed(_ page: Page) {
        guard let (key, _) = waiting.first(where: { $0.value.tab == page.tab && Session.shared.workspace.spaceID(of: page.tab) == page.space })
        else { return }
        end(key, .failure(Extensions.Unanswered(why: notLoaded)))
    }

    private static func end(_ key: String, _ result: Result<URL, Error>) {
        guard let flow = waiting.removeValue(forKey: key) else { return }
        flow.watch.invalidate()
        flow.finish(result)
    }

    /// Whether `url`, on an extension's chromiumapp.org, is the answer a
    /// flow waits for: arriving in the tab the flow began in, or in a
    /// window that tab's page opened, since some providers finish in a
    /// pop-up. Any page can head for such an address, and what it carries
    /// would be taken for the answer: only those two may finish it. The
    /// tab goes, and the pop-up with it.
    static func intercept(_ url: URL, page: Page) -> Bool {
        guard let id = owner(of: url) else { return false }
        let key = key(id, page.space)
        guard let flow = waiting[key], page.tab == flow.tab || page.openedFrom == flow.tab else { return false }
        end(key, .success(url))
        DispatchQueue.main.async {
            if page.tab != flow.tab { page.host?.pageDidClose(page) }
            if Session.shared.workspace.tab(flow.tab) != nil { Session.shared.closeTab(flow.tab) }
        }
        return true
    }

    /// The same address with no flow waiting for it. Some extensions open
    /// the provider's page with tabs.create and watch that tab until it
    /// reaches their chromiumapp.org address, then close it (Figma's). In
    /// Chrome the load fails onto an error page that still carries the
    /// address, which tabs.onUpdated reports; in WebKit a failed load never
    /// commits, so nothing would. The tab takes the address without loading
    /// anything (Page.hold), for an extension on in the space that asked
    /// for identity; what each extension sees of it is WebKit's call, as
    /// for any address.
    static func handOver(_ url: URL, page: Page) -> Bool {
        // A tab's page, or an extension's popup window's (windows.create).
        let shown = Session.shared.workspace.spaceID(of: page.tab) == page.space || Extensions.shared.popupShows(page)
        guard let id = owner(of: url), shown,
              let context = Extensions.shared.context(id, in: page.space), Extensions.asks(context, for: "identity")
        else { return false }
        page.hold(url)
        return true
    }
}
