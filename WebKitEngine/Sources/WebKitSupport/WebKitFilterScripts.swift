import WebKit

extension WKUserContentController {
    /// What a site's filters ask for that WebKit's rules can't do
    /// (ScriptedFilters): the hiding in the app's own world, where the page
    /// can't reach it; the scriptlets in the page's, since what they change
    /// is the page's own. Only for a page prepare() has found is not hands-off.
    @MainActor
    public func addFilterScripts(blocker: String?, scriptlets: String?, appWorld: WKContentWorld) {
        if let script = blocker {
            addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                       forMainFrameOnly: true, in: appWorld))
        }
        if let script = scriptlets {
            addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                       forMainFrameOnly: true, in: .page))
        }
    }
}
