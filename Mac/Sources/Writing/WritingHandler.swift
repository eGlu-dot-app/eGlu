import WritingServiceKit
import Foundation
import PadCore
import WebEngineCore

/// What writing.js asks of the Mac through "egluWriting": lint the focused
/// field's text with Harper, act on a lint, and say when its card is up;
/// ⌃⌥G works only then. Everything the page sends is checked first: the
/// main frame's own messages, in the app's own world, on a page writing is
/// on for and a person's hands are on.
@MainActor
final class WritingHandler {
    static let name = "egluWriting"

    private weak var page: Page?

    init(page: Page) {
        self.page = page
    }

    func handle(_ message: WebMessage, reply: @escaping @MainActor (WebJSON?) -> Void) {
        guard let page, message.isMainFrame, message.world == .app, !page.isHandsOff,
              let body = message.body.foundation as? [String: Any], let kind = body["kind"] as? String
        else { reply(nil); return }
        // A card going is heard even from a script being stopped, so ⌃⌥G
        // never stays on for a card no longer there.
        if kind == "closed" {
            page.writingCardOpen = false
            reply(.bool(true))
            return
        }
        // Anything else only while Settings › Writing is on, for this site
        // and this document, as the script may outlive a change to them.
        guard page.checksWriting() else { reply(nil); return }
        switch kind {
        case "lint":
            guard let text = body["text"] as? String else { reply(nil); return }
            Task {
                let lints = await WritingChecker.shared.lint(text)
                reply(WebJSON(foundation: lints.map { Self.json(for: $0, in: text) }))
            }
        // A lint chosen to be ignored: Harper's context names it, for as
        // long as the app runs (Decided 14).
        case "ignore":
            if let context = body["context"] as? String {
                WritingChecker.shared.ignore(context: context)
            }
            reply(.bool(true))
        // A word for the personal dictionary (WritingWords), in the linter
        // at once.
        case "addWord":
            if let word = body["word"] as? String, !word.isEmpty {
                WritingChecker.shared.addWord(word)
            }
            reply(.bool(true))
        // A rule turned off in Settings › Writing: written to the
        // preferences the settings screen shows.
        case "disableRule":
            if let rule = body["rule"] as? String, !rule.isEmpty {
                var preferences = Session.shared.preferences
                preferences.writingRules[rule] = false
                Session.shared.preferences = preferences
            }
            reply(.bool(true))
        // The card says when it is up; ⌃⌥G is a command till it goes.
        case "opened":
            page.writingCardOpen = true
            reply(.bool(true))
        default:
            reply(nil)
        }
    }

    /// A lint as writing.js holds it: its span in the text sent, the kind
    /// and rule, the message, Harper's context, the fixes, and the words
    /// flagged (the dictionary's entry, and what Replace removes).
    private static func json(for lint: WritingIssue, in text: String) -> [String: Any] {
        let ns = text as NSString
        let span = NSRange(location: lint.start, length: lint.end - lint.start)
        let word = span.location != NSNotFound && NSMaxRange(span) <= ns.length
            ? ns.substring(with: span) : ""
        return [
            "start": lint.start,
            "end": lint.end,
            "kind": lint.kind,
            "rule": lint.rule,
            "message": lint.message,
            "context": lint.context,
            "word": word,
            "suggestions": lint.suggestions.map { suggestion -> [String: Any] in
                switch suggestion {
                case .replace(let text): return ["replace": text]
                case .insert(let text): return ["insert": text]
                case .remove: return ["remove": true]
                }
            },
        ]
    }
}
