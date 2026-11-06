import Foundation

/// What goes into a page at document start, put together for one site.
///
/// The app swaps a tab's scripts before each page it loads (Page.swift),
/// because an adapter belongs to a site and a tab goes from site to site.
/// On a hands-off host it installs none at all.
public enum Scripts {
    /// Read-only draft inspection, shared by both platforms.
    public static let draft = load("draft", "js")
    /// Runs once in the app's content world, with handsOff as its argument.
    /// It requires no installed input bridge and leaves no listeners or globals.
    public static let draftCall = draft + "\nreturn egluHasDraft(handsOff);"
    /// The iPad input bridge, with the shared probe inside its guarded closure.
    public static let bridge = load("bridge", "js").replacingOccurrences(of: "/*DRAFT_PROBE*/", with: draft)
    /// The app's own stylesheet, base.css.
    public static let style = load("base", "css")
    /// No long-press callout, for a site that keeps its own context menus
    /// (OwnMenus): WebKit then never asks the app for a link's menu there.
    /// It goes in by itself, apart from the rest of the style, so a page
    /// that is up can be given it or have it taken away (bridge.js callouts()).
    public static let noCallout = "html, html * { -webkit-touch-callout: none !important; }"

    /// The settings bridge.js starts with, as JSON.
    struct Settings: Encodable {
        var adapter: String
        var css: String
        var callouts: String
        var handsOff: [String]
        var wheel: String
        var keys: [String]
        var cursor: Bool
    }

    /// For the app's own content world: the bridge, told which site it is on
    /// and what to add to the page, then the adapter's own script.
    public static func ours(for adapter: SiteAdapter, bridges: Bridges, ownMenus: Bool = false) -> String {
        let settings = Settings(
            adapter: adapter.id,
            css: [style, adapter.css].filter { !$0.isEmpty }.joined(separator: "\n"),
            callouts: ownMenus ? noCallout : "",
            handsOff: HandsOff.hosts,
            wheel: bridges.wheel.rawValue,
            keys: bridges.keys.map(\.rawValue).sorted(),
            cursor: bridges.cursors
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(settings)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        var parts = ["window.__egluConfig = \(json);", bridge]
        if !adapter.script.isEmpty { parts.append(isolated(adapter.script)) }
        return parts.joined(separator: "\n")
    }

    /// For the page's own world, or nil when the adapter has nothing there.
    public static func page(for adapter: SiteAdapter) -> String? {
        adapter.pageScript.isEmpty ? nil : isolated(adapter.pageScript)
    }

    /// The scripts for what a site's filters ask that WebKit's rules can't
    /// do (ScriptedFilters.swift), as shipped: blocker.js hides, from the
    /// app's own world; scriptlets.js, in the page's world, takes away what
    /// an "ad blocker detected" script looks for.
    public static let blocker = load("blocker", "js")
    public static let scriptlets = load("scriptlets", "js")
    /// Document Picture-in-Picture (DocumentPicture.swift), for the page's
    /// own world on the sites it lists, on the Mac: picture.js as shipped.
    public static let picture = load("picture", "js")
    /// Where each has its rules written in.
    static let rulesMark = "/*RULES*/null"

    /// For the app's own content world, or nil when the site has nothing to hide this way.
    public static func blocker(for rules: PageRules) -> String? {
        guard rules.hides, blocker.contains(rulesMark) else { return nil }
        return blocker.replacingOccurrences(of: rulesMark, with: rules.hidingJSON)
    }

    /// For the page's own world, or nil when the site has no scriptlets.
    /// The rules go in as data, never as code: a list names a scriptlet
    /// that ships with the app and what to give it, and nothing a list says
    /// is ever run.
    public static func scriptlets(for rules: PageRules) -> String? {
        guard !rules.run.isEmpty, scriptlets.contains(rulesMark) else { return nil }
        return scriptlets.replacingOccurrences(of: rulesMark, with: rules.scriptletsJSON)
    }

    /// The page as Markdown, for Handoff (Handoff.swift): markdown.js as
    /// shipped, one function that takes how many characters to read at most.
    public static let markdown = load("markdown", "js")
    /// The body the app runs once when Handoff is asked for, with `limit`
    /// as its one argument (Page.markdown). The function is given a name
    /// and then called: "return" straight before the file would end at the
    /// file's first line, which is a comment.
    public static let markdownCall = "const run = " + markdown + ";\nreturn run(limit);"

    /// What YouTube needs when Handoff reads one of its pages (Adapters.youtube): youtube.js as shipped.
    public static let youtube = load("youtube", "js")

    /// An element picked on the page (element-pick.js), run once in the
    /// app's own world: the rectangle it resolves with, or null on Escape.
    public static let elementPick = load("element-pick", "js")

    /// The measuring tool (measure.js), run once in the app's own world with
    /// `guides` (the guide and ruler settings) as its argument. It resolves
    /// when the tool ends, and while it runs it talks through egluBridge on the
    /// egluMeasure channel.
    public static let measure = load("measure", "js")

    /// The JSON view over a page that is JSON (json-view.js), injected at
    /// document end in the app's own world where the MIME type says JSON
    /// and Settings formats it (Preferences.formatJSON), with its button's
    /// word in the person's language.
    public static let jsonView = load("json-view", "js").replacingOccurrences(
        of: wordsMark, with: jsonText(["raw": BrowserText.localized("Raw")]))
    /// Where a script has the app's words for what it shows written in.
    static let wordsMark = "/*WORDS*/null"

    /// Words as a JavaScript object literal: JSON, which can't break out of it.
    static func jsonText(_ words: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: words, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }

    /// What goes first in a Chrome extension's worker, scripts and pages
    /// (ExtensionPreparation).
    public static let extensionShim = load("extension-shim", "js")

    /// The Chrome Web Store's "Add to eGlu" button (StoreButton.swift).
    public static let extensionStore = load("extension-store", "js")

    /// The body the app runs for a site's own reader (SiteAdapter.reader),
    /// with `limit` and `patience` as its arguments (Page.transcript): the
    /// function is given a name and called, and what it promises is waited for.
    public static func readerCall(for adapter: SiteAdapter) -> String? {
        adapter.reader.isEmpty ? nil : "const run = " + adapter.reader + ";\nreturn await run(limit, patience);"
    }

    /// Grammar checking in a page's own fields, for the app's own content
    /// world (writing.js; Mac's WritingHandler answers its egluWriting
    /// messages): a closed root's boxes and card beside the checked word.
    public static let writing = load("writing", "js")
    /// Where writing.js keeps what it is configured with, swapped for JSON.
    static let writingMark = "/*__EGLU_WRITING__*/{}"

    /// The script with its settings written in as data: the card's strings,
    /// from the String Catalog, so the script reads no locale of its own,
    /// and the keys the card shows (keys.accept, keys.acceptShortcut).
    public static func writing(strings: [String: String], keys: [String: String] = [:]) -> String {
        let json = (try? JSONEncoder().encode(["strings": strings, "keys": keys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return writing.replacingOccurrences(of: writingMark, with: json)
    }

    /// The page under the iPhone Duo's strip (strip.js), for the app's own
    /// content world: what can be pressed moved out from under the strip's
    /// items, as Page.strip says where they are.
    public static let strip = load("strip", "js")

    /// The call that tells strip.js where the strip is, or that the page no
    /// longer runs under one: the strip as JSON, which can't break out of it.
    public static func strip(set strip: DuoLayout.Strip?) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = strip.flatMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? "null"
        return "if (window.__egluStrip) window.__egluStrip.set(\(json));"
    }

    /// A script that can fail without taking anything else down with it.
    static func isolated(_ script: String) -> String {
        "try {\n\(script)\n} catch (_) {}"
    }

    static func load(_ name: String, _ type: String) -> String {
        guard let file = Bundle.module.url(forResource: name, withExtension: type, subdirectory: "Scripts"),
              let text = try? String(contentsOf: file, encoding: .utf8)
        else { return "" }
        return text
    }
}
