import Foundation

/// Making an extension's verified package into the folder WebKit loads:
/// the shim (Scripts/extension-shim.js) put first in its worker, its
/// background scripts, its content scripts and its pages.
///
/// The verified original is kept as it came; this works on a fresh copy of
/// it, made again whenever the shim changes, so nothing is ever patched
/// twice and nothing the extension ships is lost.
public enum ExtensionPreparation {
    /// Where the shim goes in the folder. A package that brings a file of
    /// its own there isn't taken.
    public static let shimFile = "_eglu/shim.js"
    /// What the folder was made from, the shim and the package: one made
    /// from others, or by an older preparation, is made again.
    public static let stampFile = "_eglu/stamp"

    /// Raised when this file changes what it makes.
    static let version = 5

    static let shimMarks = ("/* eGlu's shim, before the extension's own code (ExtensionPreparation) */",
                            "/* The extension's own code */")

    public enum Problem: Error, Equatable, Sendable {
        /// A name that leads out of the folder, or into eGlu's part of it.
        case unsafeName(String)
        case tooLarge
        /// A file the archive holds that can't be unpacked here: encrypted,
        /// or packed in a way other than stored or deflated.
        case unreadable(String)
        case noManifest
        /// Two names that are one file on a Mac's disk, the second of which
        /// would be written over the first.
        case sameFile(String)
        /// A symbolic link: what it leads to isn't the package's.
        case link(String)
    }

    /// Every file of the folder, one at a time, as `write` takes them: the
    /// package's own, the manifest and the scripts and pages edited, then
    /// the shim, and `stamp` last. Throws before writing anything when a
    /// name or a size is wrong.
    public static func prepare(_ archive: Data, shim: String, stamp: String,
                               write: (_ path: String, _ data: Data) throws -> Void) throws {
        let bytes = [UInt8](archive)
        let entries = ZipFile.entries(in: bytes)
        try check(entries)
        guard let manifestEntry = entries.first(where: { $0.name == "manifest.json" }),
              let manifestData = ZipFile.unpack(manifestEntry, from: bytes)
        else { throw Problem.noManifest }
        let edited = try manifest(manifestData)
        let worker = edited.worker.map { normalized($0.path) }
        let shim = filled(shim, scripts: scriptList(entries, in: bytes), added: edited.added, events: eventList(entries, in: bytes))
        let rulesets = Set(ruleFiles(manifestData).map(normalized))
        let hashed = hashedScripts(entries, in: bytes)
        for entry in entries where !entry.name.hasSuffix("/") {
            guard var data = ZipFile.unpack(entry, from: bytes) else { throw Problem.unreadable(entry.name) }
            if entry.name == "manifest.json" {
                data = edited.manifest
            } else if entry.name == worker {
                data = Self.worker(data, shim: shim, module: edited.worker?.module == true)
            } else if isPage(entry.name), var html = String(data: data, encoding: .utf8) {
                if let chained = chainModules(html, page: entry.name, read: { name in
                    entries.first { normalized($0.name) == name }.flatMap { ZipFile.unpack($0, from: bytes) }
                }) {
                    html = chained.html
                    try write(chained.file, Data(chained.module.utf8))
                }
                data = Data(page(html).utf8)
            } else if isScript(entry.name), !hashed.contains(normalized(entry.name)) {
                data = Self.signed(data)
            } else if rulesets.contains(normalized(entry.name)), let kept = Self.withoutMisreadRules(data) {
                data = kept
            }
            try write(entry.name, data)
        }
        try write(shimFile, Data(shim.utf8))
        try write(stampFile, Data(stamp.utf8))
    }

    /// The shim with what it is told of this extension written in: its
    /// scripts, for the worker's importScripts (an empty one marked "-"),
    /// the permissions the preparation added to its manifest, the events
    /// its code mentions, and the Chrome it says it is.
    static func filled(_ shim: String, scripts: [String], added: [String] = [], events: [String] = []) -> String {
        func json(_ list: [String]) -> String {
            (try? JSONSerialization.data(withJSONObject: list, options: [.withoutEscapingSlashes]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        }
        return shim.replacingOccurrences(of: "/*__EGLU_SCRIPTS__*/null", with: json(scripts))
            .replacingOccurrences(of: "/*__EGLU_ADDED__*/[]", with: json(added))
            .replacingOccurrences(of: "/*__EGLU_EVENTS__*/[]", with: json(events))
            .replacingOccurrences(of: "__EGLU_CHROME__", with: ExtensionStore.chromeVersion)
    }

    /// The events the package's scripts name, as "tabs.onUpdated" (from
    /// `chrome.tabs.onUpdated` or a bundler's `e.tabs.onUpdated`), so its
    /// worker can hold a listener for each from its first moment (the
    /// shim's late listeners). A name it reads another way is missed, and
    /// its listener only has to come in time, as without this. (Search)
    static func eventList(_ entries: [ZipFile.Entry], in bytes: [UInt8]) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"\.([a-zA-Z]+)\.(on[A-Z][A-Za-z]+)\b"#)
        var found = Set<String>()
        for entry in entries {
            let lower = entry.name.lowercased()
            guard !entry.name.hasSuffix("/"), lower.hasSuffix(".js") || lower.hasSuffix(".mjs"),
                  let data = ZipFile.unpack(entry, from: bytes) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let space = Range(match.range(at: 1), in: text), let event = Range(match.range(at: 2), in: text) else { continue }
                found.insert("\(text[space]).\(text[event])")
            }
        }
        return found.sorted()
    }

    /// The scripts a page names with an integrity hash: left as they are,
    /// since a signature in front (signed) would change their hash and the
    /// page would refuse them.
    static func hashedScripts(_ entries: [ZipFile.Entry], in bytes: [UInt8]) -> Set<String> {
        let tags = try! NSRegularExpression(pattern: #"<script\b([^>]*)>"#, options: [.caseInsensitive])
        let integrity = try! NSRegularExpression(pattern: #"(^|\s)integrity\s*="#, options: [.caseInsensitive])
        let source = try! NSRegularExpression(pattern: #"(?:^|\s)src\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#, options: [.caseInsensitive])
        var found = Set<String>()
        for entry in entries where isPage(entry.name) {
            guard let data = ZipFile.unpack(entry, from: bytes), let html = String(data: data, encoding: .utf8) else { continue }
            let folder = (entry.name as NSString).deletingLastPathComponent
            for match in liveTags(tags, in: html) {
                guard let inner = Range(match.range(at: 1), in: html) else { continue }
                let attributes = String(html[inner])
                let span = NSRange(attributes.startIndex..., in: attributes)
                guard integrity.firstMatch(in: attributes, range: span) != nil, let named = source.firstMatch(in: attributes, range: span),
                      let src = (1...3).lazy.compactMap({ Range(named.range(at: $0), in: attributes) }).first.map({ String(attributes[$0]) }),
                      !src.isEmpty, !src.contains(":"), !src.hasPrefix("//")
                else { continue }
                let address = src.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? src
                let path = address.removingPercentEncoding ?? address
                // As the page's address reads it: ".." taken off the folder.
                var parts: [Substring] = path.hasPrefix("/") ? [] : folder.split(separator: "/")
                for part in path.split(separator: "/") where part != "." {
                    if part == ".." { _ = parts.popLast() } else { parts.append(part) }
                }
                found.insert(parts.joined(separator: "/"))
            }
        }
        return found
    }

    /// The matches of `pattern` that a browser reads as markup: none in a
    /// comment, nor in what a script, a style, a title or a text box holds,
    /// which is text whatever it says ("<!--" in a script's string, a tag
    /// shown in a text box, "<script>" in a comment).
    static func liveTags(_ pattern: NSRegularExpression, in html: String) -> [NSTextCheckingResult] {
        let texts = textRanges(html)
        return pattern.matches(in: html, range: NSRange(html.startIndex..., in: html)).filter { match in
            !texts.contains { NSLocationInRange(match.range.location, $0) }
        }
    }

    /// Where a page holds text rather than markup, read from its start as a
    /// browser's tokenizer reads it, whichever comes first: a comment, to
    /// its "-->", or a script's, a style's, a title's or a text box's
    /// content, to its own closing tag.
    static func textRanges(_ html: String) -> [NSRange] {
        let text = html as NSString
        let opener = try! NSRegularExpression(pattern: #"<(script|style|textarea|title)\b[^>]*>"#, options: [.caseInsensitive])
        var ranges: [NSRange] = []
        var at = 0
        while at < text.length {
            let rest = NSRange(location: at, length: text.length - at)
            let comment = text.range(of: "<!--", range: rest).location
            let raw = opener.firstMatch(in: html, range: rest)
            if comment != NSNotFound, comment < (raw?.range.location ?? .max) {
                let end = text.range(of: "-->", range: NSRange(location: comment + 4, length: text.length - comment - 4))
                let stop = end.location == NSNotFound ? text.length : end.location + 3
                ranges.append(NSRange(location: comment, length: stop - comment))
                at = stop
            } else if let raw {
                let after = raw.range.location + raw.range.length
                // Its own closing tag: the name, then a space, "/" or ">"
                // ("</textareax>" closes nothing).
                let closer = try! NSRegularExpression(pattern: "</" + NSRegularExpression.escapedPattern(for: text.substring(with: raw.range(at: 1))) + #"(?=[\s/>])"#,
                                                      options: [.caseInsensitive])
                let close = closer.firstMatch(in: html, range: NSRange(location: after, length: text.length - after))
                let stop = close?.range.location ?? text.length
                if stop > after { ranges.append(NSRange(location: after, length: stop - after)) }
                at = max(stop, after)
            } else {
                break
            }
        }
        return ranges
    }

    static func isScript(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".js") || lower.hasSuffix(".mjs")
    }

    /// A script that a content script may put into a website is read in the
    /// site's encoding unless it says otherwise: an extension's non-ASCII
    /// text, Unicode in its regular expressions, came out garbled on a page
    /// in EUC-KR, Shift_JIS or windows-1252. A UTF-8 signature in front says
    /// so, without touching the page's encoding. Not on one that is ASCII,
    /// isn't UTF-8, has one already, or starts with a hashbang, which must
    /// stay first. (Search's d829ed7)
    static func signed(_ data: Data) -> Data {
        let signature = Data([0xEF, 0xBB, 0xBF])
        guard !data.starts(with: signature), !data.starts(with: [0x23, 0x21]),
              data.contains(where: { $0 >= 0x80 }), String(data: data, encoding: .utf8) != nil
        else { return data }
        return signature + data
    }

    /// Every script in the package, as an address path: "/bg.js". One with
    /// nothing in it but space is "-/test.js".
    static func scriptList(_ entries: [ZipFile.Entry], in bytes: [UInt8]) -> [String] {
        entries.compactMap { entry -> String? in
            let lower = entry.name.lowercased()
            guard !entry.name.hasSuffix("/"), lower.hasSuffix(".js") || lower.hasSuffix(".mjs") else { return nil }
            // Only a small one can be empty of all but space.
            let blank = entry.size < 256 && (ZipFile.unpack(entry, from: bytes).map {
                String(decoding: $0, as: UTF8.self).allSatisfy(\.isWhitespace)
            } ?? false)
            return (blank ? "-/" : "/") + entry.name
        }
    }

    /// Larger unpacked than any store extension measured (Bitwarden, 25 MB
    /// packed) by far.
    static let largestUnpacked = 512 * 1024 * 1024

    static func check(_ entries: [ZipFile.Entry]) throws {
        if let bad = entries.first(where: { !isSafe(name: $0.name) }) { throw Problem.unsafeName(bad.name) }
        if let same = sameFile(in: entries.map(\.name)) { throw Problem.sameFile(same) }
        if let link = entries.first(where: \.isLink) { throw Problem.link(link.name) }
        // What is written is what each entry says it holds: a stored one
        // that says less than it has isn't unpacked (ZipFile.unpack).
        guard entries.reduce(0, { $0 + $1.size }) <= largestUnpacked,
              entries.allSatisfy({ $0.size <= ZipFile.largest })
        else { throw Problem.tooLarge }
    }

    /// A name that is, on a Mac's disk, one already given: its disks by
    /// default take neither case nor Unicode's ways of writing an accent
    /// apart, so "Manifest.json" would be written over the manifest.json
    /// that was read and shown. A file where a folder is counts too.
    static func sameFile(in names: [String]) -> String? {
        func key<S: StringProtocol>(_ path: S) -> String {
            String(path).decomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil)
        }
        var files = Set<String>()
        var folders = Set<String>()
        for name in names {
            let parts = name.split(separator: "/")
            for end in parts.indices.dropFirst() { folders.insert(key(parts[..<end].joined(separator: "/"))) }
            if name.hasSuffix("/") {
                folders.insert(key(name.dropLast()))
            } else if !files.insert(key(name)).inserted {
                return name
            }
        }
        return files.first(where: folders.contains)
    }

    /// Whether a name stays inside the folder it is unpacked into: not
    /// absolute, no "." or ".." or empty part, no backslash, and not in
    /// eGlu's own folder.
    static func isSafe(name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0") else { return false }
        var parts = name.split(separator: "/", omittingEmptySubsequences: false)
        // A folder's own entry ends in "/".
        if name.hasSuffix("/") { parts.removeLast() }
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        return parts[0].lowercased() != "_eglu"
    }

    /// How a manifest names a file, as the archive does: "/bg.js" and
    /// "./bg.js" are "bg.js".
    public static func normalized(_ path: String) -> String {
        var path = Substring(path)
        while path.hasPrefix("./") || path.hasPrefix("/") { path = path.dropFirst(path.hasPrefix("/") ? 1 : 2) }
        return String(path)
    }

    /// A page's module scripts, two or more with one that awaits at its
    /// top, made one module that imports them in their order: the page's
    /// new HTML, and that module's name and text; nil when there is nothing
    /// to do. Chrome waits for a module still at a top-level await before it
    /// runs a later tag's module that imports it; WebKit runs the later one
    /// at once, which then reads the first one's exports before they exist
    /// ("Cannot access 'd' before initialization"): Vimium C's options page
    /// lists five, the second awaiting its translations, and stayed blank.
    /// Inside one module's imports WebKit waits, so the tags become one, in a
    /// file of eGlu's beside the page. Only plain tags of the package's own
    /// files: one marked async, or another's, leaves the page as it is.
    /// (Search's caf91e5)
    static func chainModules(_ html: String, page: String, read: (String) -> Data?) -> (html: String, file: String, module: String)? {
        let tags = try! NSRegularExpression(pattern: #"<script\b([^>]*)>\s*</script>"#, options: [.caseInsensitive])
        let module = try! NSRegularExpression(pattern: #"\btype\s*=\s*["']?module\b"#, options: [.caseInsensitive])
        let source = try! NSRegularExpression(pattern: #"(?:^|\s)src\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#, options: [.caseInsensitive])
        let async = try! NSRegularExpression(pattern: #"(^|\s)async(\s|=|$)"#, options: [.caseInsensitive])
        let integrity = try! NSRegularExpression(pattern: #"(^|\s)integrity\s*="#, options: [.caseInsensitive])
        // A page with a <base> reads relative addresses from it, not from its
        // own folder, where the module would be written: left as it is.
        let base = try! NSRegularExpression(pattern: #"<base\b[^>]*?[\s/]href\s*="#, options: [.caseInsensitive])
        guard liveTags(base, in: html).isEmpty else { return nil }
        var found: [(range: Range<String.Index>, attributes: String, src: String)] = []
        for match in liveTags(tags, in: html) {
            guard let range = Range(match.range, in: html), let inner = Range(match.range(at: 1), in: html) else { continue }
            let attributes = String(html[inner])
            let span = NSRange(attributes.startIndex..., in: attributes)
            guard module.firstMatch(in: attributes, range: span) != nil else { continue }
            // A tag checked against its file's hash would refuse the
            // module that imports the rest.
            guard async.firstMatch(in: attributes, range: span) == nil, integrity.firstMatch(in: attributes, range: span) == nil,
                  let named = source.firstMatch(in: attributes, range: span),
                  let src = (1...3).lazy.compactMap({ Range(named.range(at: $0), in: attributes) }).first.map({ String(attributes[$0]) }),
                  !src.isEmpty, !src.contains(":"), !src.hasPrefix("//"), !src.contains(where: \.isNewline)
            else { return nil }
            found.append((range, attributes, src))
        }
        guard found.count >= 2 else { return nil }
        // An inline module among them runs in its place in the order: one
        // chain of the others would run some before it. Left as it is.
        let openers = try! NSRegularExpression(pattern: #"<script\b([^>]*)>"#, options: [.caseInsensitive])
        let modules = liveTags(openers, in: html).filter { match in
            guard let inner = Range(match.range(at: 1), in: html) else { return false }
            let attributes = String(html[inner])
            return module.firstMatch(in: attributes, range: NSRange(attributes.startIndex..., in: attributes)) != nil
        }
        guard modules.count == found.count else { return nil }
        // The package's own files, and one of them awaiting at all: without
        // an await, every module has run by the time the next tag's does.
        let folder = (page as NSString).deletingLastPathComponent
        var awaits = false
        for entry in found {
            let path = entry.src.split(separator: "?").first.map(String.init) ?? entry.src
            let name = path.hasPrefix("/") ? normalized(path) : normalized(((folder as NSString).appendingPathComponent(path) as NSString).standardizingPath)
            guard isSafe(name: name), let data = read(name) else { return nil }
            if String(decoding: data, as: UTF8.self).range(of: #"\bawait\b"#, options: .regularExpression) != nil { awaits = true }
        }
        guard awaits else { return nil }
        // A name of its own: the page's whole path in it (options.html and
        // options.htm apart), and none of the package's files taken.
        let stem = "eglu-modules-" + ((page as NSString).lastPathComponent as NSString).deletingPathExtension
            + "-" + shortHash(page)
        var name = stem + ".js"
        var tries = 2
        while read(folder.isEmpty ? name : folder + "/" + name) != nil {
            name = stem + "-\(tries).js"
            tries += 1
        }
        let imports = found.map { entry -> String in
            let spec = entry.src.hasPrefix("/") || entry.src.hasPrefix("./") || entry.src.hasPrefix("../") ? entry.src : "./" + entry.src
            return "import \"\(spec.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\";"
        }
        // The first tag, its other attributes kept, now naming the one
        // module; the others gone.
        var out = html
        for (index, entry) in found.enumerated().reversed() {
            if index == 0 {
                let span = NSRange(entry.attributes.startIndex..., in: entry.attributes)
                let attributes = source.stringByReplacingMatches(in: entry.attributes, range: span, withTemplate: NSRegularExpression.escapedTemplate(for: " src=\"\(name)\""))
                out.replaceSubrange(entry.range, with: "<script\(attributes)></script>")
            } else {
                out.removeSubrange(entry.range)
            }
        }
        let file = folder.isEmpty ? name : folder + "/" + name
        return (out, file, "// eGlu: this page's module scripts, in their order (ExtensionPreparation.chainModules).\n" + imports.joined(separator: "\n") + "\n")
    }

    /// The rule files a manifest declares (declarative_net_request).
    static func ruleFiles(_ manifest: Data) -> [String] {
        let text = ExtensionManifest.withoutComments(String(decoding: manifest, as: UTF8.self))
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let dnr = object["declarative_net_request"] as? [String: Any],
              let resources = dnr["rule_resources"] as? [[String: Any]] else { return [] }
        return resources.compactMap { $0["path"] as? String }
    }

    /// A redirect or header rule with a pattern (regexFilter) beside a list
    /// of sites (requestDomains): WebKit drops the list from such a rule and
    /// carries it out on every address the pattern matches. uBlock Origin
    /// Lite's strict blocking, `^https?://.*` beside thousands of named
    /// sites, sent every page to its warning once WebKit carried out
    /// redirects. Such a rule is left out: nothing rewritten, nothing done
    /// beyond what it named. Blocks and allows of that shape stay as WebKit
    /// reads them. (Search's 072c4dd)
    public static func misreadByWebKit(_ rule: [String: Any]) -> Bool {
        guard let condition = rule["condition"] as? [String: Any],
              condition["regexFilter"] is String, condition["requestDomains"] != nil,
              let type = (rule["action"] as? [String: Any])?["type"] as? String
        else { return false }
        return type == "redirect" || type == "modifyHeaders"
    }

    /// A rule file without the rules WebKit would misread; nil when it has
    /// none, or isn't rules. Only a file with both words in it is read: a
    /// blocker ships tens of megabytes of rules.
    static func withoutMisreadRules(_ data: Data) -> Data? {
        guard data.range(of: Data("regexFilter".utf8)) != nil, data.range(of: Data("requestDomains".utf8)) != nil,
              let rules = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return nil }
        let kept = rules.filter { !(($0 as? [String: Any]).map(misreadByWebKit) ?? false) }
        guard kept.count < rules.count else { return nil }
        return try? JSONSerialization.data(withJSONObject: kept, options: [.withoutEscapingSlashes])
    }

    /// A function's source as an expression: a method's (`inject() {…}`,
    /// `async inject() {…}`, `*gen() {…}`), which an object's function
    /// prints as, is read back out of an object literal, where that syntax
    /// is allowed whatever the name.
    public static func expression(of function: String) -> String {
        let text = function.trimmingCharacters(in: .whitespacesAndNewlines)
        let method = try! NSRegularExpression(pattern: #"^(async\s+)?(\*\s*)?([A-Za-z_$][\w$]*)\s*\("#)
        guard let match = method.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 3), in: text)
        else { return text }
        let name = String(text[range])
        // `function (…)`, and `async (…) => …`, an arrow function.
        if name == "function" || name == "async" && match.range(at: 1).location == NSNotFound { return text }
        return "({\(text)})[\"\(name)\"]"
    }

    static func isPage(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".html") || lower.hasSuffix(".htm")
    }

    /// The manifest with the shim first wherever scripts are listed, and
    /// native messaging added for the shim's way to eGlu; what was
    /// added; and the worker file, which the shim goes in front of, and
    /// whether it is a module. The checks read the manifest as it came, so
    /// what was added here isn't counted as the extension's own asking.
    public static func manifest(_ data: Data) throws -> (manifest: Data, added: [String], worker: (path: String, module: Bool)?) {
        let text = ExtensionManifest.withoutComments(String(decoding: data, as: UTF8.self))
        guard var object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw ExtensionManifest.Problem.notJSON
        }
        var added: [String] = []
        var permissions = object["permissions"] as? [Any] ?? []
        if !permissions.contains(where: { $0 as? String == "nativeMessaging" }) {
            permissions.append("nativeMessaging")
            added.append("nativeMessaging")
        }
        // User scripts are carried out through WebKit's registered content
        // scripts, which need scripting (the shim's chrome.userScripts).
        let optional = object["optional_permissions"] as? [Any] ?? []
        if (permissions + optional).contains(where: { $0 as? String == "userScripts" }),
           !permissions.contains(where: { $0 as? String == "scripting" }) {
            permissions.append("scripting")
            added.append("scripting")
        }
        object["permissions"] = permissions

        var worker: (path: String, module: Bool)?
        if var background = object["background"] as? [String: Any] {
            // A manifest for Chrome and Firefox at once names both; whichever
            // WebKit takes (the scripts, as Search found) has the shim.
            worker = (background["service_worker"] as? String).map { ($0, background["type"] as? String == "module") }
            if let scripts = background["scripts"] as? [Any], !scripts.isEmpty {
                background["scripts"] = [shimFile] + scripts
            }
            object["background"] = background
        }
        // The shim runs once in a world (__egluShim), but every entry that
        // lists it has the whole file read again in each frame it runs in.
        // An entry an earlier one already gave it to does without.
        var shimmed: [[String: Any]] = []
        if let scripts = object["content_scripts"] as? [Any] {
            object["content_scripts"] = scripts.map { entry -> Any in
                guard var entry = entry as? [String: Any], let js = entry["js"] as? [Any], !js.isEmpty,
                      // The page's own world has no extension APIs to mend,
                      // and the page would see the shim there.
                      entry["world"] as? String != "MAIN"
                else { return entry }
                guard !shimmed.contains(where: { covers($0, entry) }) else { return entry }
                entry["js"] = [shimFile] + js
                shimmed.append(entry)
                return entry
            }
        }
        // Files injected through chrome.scripting run in the world a
        // content_scripts entry's would have used, but none is declared for
        // an extension that only injects (Mesurer), so nothing puts the
        // shim there. Its own entry does, where the extension asked to
        // read already, and requests nothing more. Where it meets one of
        // the extension's own entries, the shim runs once (__egluShim).
        if permissions.contains(where: { $0 as? String == "scripting" }),
           let hosts = object["host_permissions"] as? [Any], !hosts.isEmpty {
            let entry: [String: Any] = ["js": [shimFile], "matches": hosts, "run_at": "document_start"]
            if !shimmed.contains(where: { covers($0, entry) }) {
                var scripts = object["content_scripts"] as? [Any] ?? []
                scripts.append(entry)
                object["content_scripts"] = scripts
            }
        }
        let out = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
        return (out, added, worker)
    }

    /// Whether `earlier`, a content_scripts entry the shim goes first in,
    /// has run it in `later`'s world in every frame `later` runs in, by the
    /// time `later` runs: as early or earlier, in the same world, in every
    /// frame and on every address of `later`'s, with nothing left out.
    static func covers(_ earlier: [String: Any], _ later: [String: Any]) -> Bool {
        let stages = ["document_start", "document_end", "document_idle"]
        func stage(_ entry: [String: Any]) -> Int? { stages.firstIndex(of: entry["run_at"] as? String ?? "document_idle") }
        func world(_ entry: [String: Any]) -> String { entry["world"] as? String ?? "ISOLATED" }
        func flag(_ entry: [String: Any], _ key: String) -> Bool { entry[key] as? Bool ?? false }
        func list(_ entry: [String: Any], _ key: String) -> [String] { (entry[key] as? [Any] ?? []).compactMap { $0 as? String } }
        guard let first = stage(earlier), let then = stage(later), first <= then, world(earlier) == world(later),
              ["exclude_matches", "include_globs", "exclude_globs"].allSatisfy({ list(earlier, $0).isEmpty }),
              ["all_frames", "match_about_blank", "match_origin_as_fallback"].allSatisfy({ !flag(later, $0) || flag(earlier, $0) })
        else { return false }
        let reached = Set(list(earlier, "matches")), wanted = list(later, "matches")
        return !wanted.isEmpty && (reached.contains("<all_urls>") || wanted.allSatisfy(reached.contains))
    }

    /// An extension page with the shim first: right after its head's
    /// opening tag, not one in a comment; or after the doctype, or before
    /// everything, when it has none. As a file of the extension's own, so
    /// its default content security policy, which takes no inline script,
    /// takes it.
    public static func page(_ html: String) -> String {
        let tag = "<script src=\"/\(shimFile)\"></script>"
        var search = html.startIndex
        while let head = html.range(of: "<head", options: [.caseInsensitive], range: search..<html.endIndex) {
            if let comment = html.range(of: "<!--", range: search..<head.lowerBound) {
                search = html.range(of: "-->", range: comment.upperBound..<html.endIndex)?.upperBound ?? html.endIndex
                continue
            }
            // Not <header>.
            if let next = html[head.upperBound...].first, next == ">" || next.isWhitespace || next == "/",
               let close = html[head.upperBound...].firstIndex(of: ">") {
                var out = html
                out.insert(contentsOf: tag, at: out.index(after: close))
                return out
            }
            search = head.upperBound
        }
        if html.range(of: "<!doctype", options: [.caseInsensitive, .anchored],
                      range: html.drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" }).startIndex..<html.endIndex) != nil,
           let end = html.firstIndex(of: ">") {
            var out = html
            out.insert(contentsOf: tag, at: out.index(after: end))
            return out
        }
        return tag + html
    }

    /// The worker with the shim first, and otherwise byte for byte as it
    /// came. A module imports it, on its first line: a module's imports run
    /// before anything written in it, the shim's text too, and its lines
    /// stay where they were. A classic worker has the shim's text in front,
    /// between marks, as Search does, and its errors' line numbers grow by
    /// the lines put there; after the "use strict" it starts with, if it
    /// does, so it stays strict.
    public static func worker(_ source: Data, shim: String, module: Bool) -> Data {
        let bytes = [UInt8](source)
        let start = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        if module {
            return Data(bytes[..<start]) + Data("import \"/\(shimFile)\";".utf8) + Data(bytes[start...])
        }
        let block = "\(shimMarks.0)\n\(shim)\n\(shimMarks.1)\n"
        guard let strict = strictness(of: bytes, from: start) else {
            return Data(bytes[..<start]) + Data(block.utf8) + Data(bytes[start...])
        }
        // A directive with no semicolon ends where the shim begins only
        // with one: a string followed by "(" is a call.
        return Data(bytes[..<strict.end]) + Data(((strict.ended ? "" : ";") + "\n" + block).utf8) + Data(bytes[strict.end...])
    }

    /// Where a script's directives end, when one of them is "use strict":
    /// the strings it starts with, each a statement of its own, past the
    /// space and comments around them; and whether a semicolon ends the
    /// last. A string that goes on into an expression ("use strict".length)
    /// is no directive, and ends them.
    static func strictness(of bytes: [UInt8], from start: Int) -> (end: Int, ended: Bool)? {
        func skipped(_ from: Int) -> Int {
            var at = from
            while at < bytes.count {
                if [0x20, 0x09, 0x0A, 0x0D].contains(bytes[at]) {
                    at += 1
                } else if bytes[at...].starts(with: Array("//".utf8)) {
                    while at < bytes.count, bytes[at] != 0x0A { at += 1 }
                } else if bytes[at...].starts(with: Array("/*".utf8)) {
                    at += 2
                    while at < bytes.count, !bytes[at...].starts(with: Array("*/".utf8)) { at += 1 }
                    at = min(at + 2, bytes.count)
                } else {
                    break
                }
            }
            return at
        }
        var at = skipped(start)
        var strict = false
        var last: (end: Int, ended: Bool)?
        while at < bytes.count, bytes[at] == UInt8(ascii: "\"") || bytes[at] == UInt8(ascii: "'") {
            let quote = bytes[at]
            var close = at + 1
            while close < bytes.count, bytes[close] != quote, bytes[close] != 0x0A {
                close += bytes[close] == UInt8(ascii: "\\") ? 2 : 1
            }
            guard close < bytes.count, bytes[close] == quote else { break }
            var next = close + 1
            while next < bytes.count, bytes[next] == 0x20 || bytes[next] == 0x09 { next += 1 }
            let end: (end: Int, ended: Bool)
            if next < bytes.count, bytes[next] == UInt8(ascii: ";") {
                end = (next + 1, true)
            } else if next >= bytes.count || [0x0A, 0x0D].contains(bytes[next])
                        || bytes[next...].starts(with: Array("//".utf8)) || bytes[next...].starts(with: Array("/*".utf8)) {
                end = (close + 1, false)
            } else {
                break
            }
            // Written out exactly: "use\x20strict" is no directive.
            if Array(bytes[(at + 1)..<close]) == Array("use strict".utf8) { strict = true }
            last = end
            at = skipped(end.end)
        }
        return strict ? last : nil
    }

    /// A short, steady name for a path: its 64-bit FNV-1a, in base 36.
    static func shortHash(_ text: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 36)
    }

    /// A short fingerprint of the shim and of this preparation (64-bit
    /// FNV-1a), the stamp file's start; the package's own follows it.
    public static func stamp(for shim: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in shim.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return "\(version)-\(String(hash, radix: 16))"
    }
}
