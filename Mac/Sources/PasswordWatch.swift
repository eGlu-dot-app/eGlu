import Foundation
import WebEngineCore

/// Whether the page on screen has a password field, as the iPad's bridge.js
/// tells its page (SignIn.swift): such a page is a sign-in page wherever it
/// is, so its visit is taken back from history before it can go to iCloud
/// (PageHistory.signInFound). The Mac runs no bridge.js, so this script,
/// in the app's own world where the page can't reach it, does that part.
@MainActor
final class PasswordWatch {
    static let name = "egluPassword"

    /// Looks again a little after the page changes; off screen only for the
    /// page's first 30 seconds, past the time before its visit may go to
    /// iCloud (a tab opened behind may draw its sign-in form late), as a tab
    /// kept live may go on changing for hours after. Says only
    /// whether the field is there, as bridge.js does: the page's address may
    /// change under it (pushState) and is no reason to let the word go.
    static let script = """
    (() => {
      let password = null;
      let pending = 0;
      function check() {
        pending = 0;
        const present = !!document.querySelector('input[type="password" i]');
        if (present === password) return;
        password = present;
        globalThis.egluBridge.post("\(name)", { present });
      }
      const loaded = Date.now();
      function soon() {
        if (pending || (document.hidden && Date.now() - loaded > 30000)) return;
        pending = setTimeout(check, 400);
      }
      check();
      new MutationObserver(soon).observe(document.documentElement, {
        childList: true, subtree: true, attributes: true, attributeFilter: ['type'],
      });
      document.addEventListener('visibilitychange', soon);
    })();
    """

    private weak var page: Page?

    init(page: Page) {
        self.page = page
    }

    func received(_ message: WebMessage) {
        guard let page, message.isMainFrame, message.world == .app,
              let body = message.body.foundation as? [String: Any], let present = body["present"] as? Bool else { return }
        page.password(present)
    }
}
