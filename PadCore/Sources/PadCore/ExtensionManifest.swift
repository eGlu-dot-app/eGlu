import Foundation

/// What an extension's manifest.json says, as far as eGlu needs it
/// before WebKit loads the extension: what it asks for, how its background
/// runs, where its scripts go and which pages it has. WebKit reads the
/// manifest again itself; this is for the install sheet and the checks.
public struct ExtensionManifest: Equatable, Sendable {
    public enum Background: Equatable, Sendable {
        /// Manifest V3's worker; `module` when it is an ES module.
        case worker(String, module: Bool)
        /// Manifest V2's background scripts, run in a page of WebKit's.
        case scripts([String], persistent: Bool)
        case page(String, persistent: Bool)
    }

    public struct ContentScript: Equatable, Sendable {
        public var matches: [String]
        public var scripts: [String]
        public var styles: [String]
        public var allFrames: Bool
        /// "ISOLATED", WebKit's and Chrome's default, or "MAIN".
        public var world: String
    }

    public var manifestVersion: Int
    public var name: String
    public var defaultLocale: String?
    public var version: String
    /// API permissions: "storage", "tabs", "sidePanel".
    public var permissions: [String]
    public var optionalPermissions: [String]
    /// Sites: match patterns and "<all_urls>". Manifest V2 lists them among
    /// its permissions; they are taken out of those and put here.
    public var hostPermissions: [String]
    public var optionalHostPermissions: [String]
    public var background: Background?
    public var contentScripts: [ContentScript]
    public var popup: String?
    public var optionsPage: String?
    public var sidePanel: String?
    /// The manifest's `oauth2` section, which Chrome's sign-in
    /// (`identity.getAuthToken`) reads.
    public var usesChromeSignIn: Bool
    public var minimumChromeVersion: String?
    public var keys: Set<String>
    /// Its icon's file, the largest it lists: its `icons`, or its button's
    /// when it lists none. Shown where it is asked about and listed.
    public var icon: String?

    /// Every page and script the manifest names, for the scan.
    public var files: [String] {
        var files: [String] = []
        switch background {
        case .worker(let path, _): files.append(path)
        case .scripts(let paths, _): files += paths
        case .page(let path, _): files.append(path)
        case nil: break
        }
        files += contentScripts.flatMap(\.scripts)
        files += [popup, optionsPage, sidePanel].compactMap { $0 }
        return files
    }

    public enum Problem: Error, Equatable, Sendable {
        case notJSON
        case noVersion
    }

    /// Chrome reads manifests leniently: comments are allowed, and a byte
    /// order mark at the start. So are they here.
    public init(json data: Data) throws {
        let text = Self.withoutComments(String(decoding: data, as: UTF8.self))
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw Problem.notJSON
        }
        guard let version = object["version"] as? String else { throw Problem.noVersion }
        func strings(_ value: Any?) -> [String] { (value as? [Any])?.compactMap { $0 as? String } ?? [] }
        func isSite(_ entry: String) -> Bool { entry == "<all_urls>" || entry.contains("://") }

        keys = Set(object.keys)
        manifestVersion = object["manifest_version"] as? Int ?? 2
        name = object["name"] as? String ?? ""
        defaultLocale = object["default_locale"] as? String
        self.version = version
        let listed = strings(object["permissions"])
        let optional = strings(object["optional_permissions"])
        permissions = listed.filter { !isSite($0) }
        optionalPermissions = optional.filter { !isSite($0) }
        hostPermissions = strings(object["host_permissions"]) + listed.filter(isSite)
        optionalHostPermissions = strings(object["optional_host_permissions"]) + optional.filter(isSite)

        let background = object["background"] as? [String: Any]
        let persistent = background?["persistent"] as? Bool ?? true
        if let worker = background?["service_worker"] as? String {
            self.background = .worker(worker, module: background?["type"] as? String == "module")
        } else if let page = background?["page"] as? String {
            self.background = .page(page, persistent: persistent)
        } else if let scripts = background?["scripts"] as? [Any] {
            self.background = .scripts(scripts.compactMap { $0 as? String }, persistent: persistent)
        } else {
            self.background = nil
        }

        contentScripts = ((object["content_scripts"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }.map {
            ContentScript(matches: strings($0["matches"]), scripts: strings($0["js"]), styles: strings($0["css"]),
                          allFrames: $0["all_frames"] as? Bool ?? false, world: $0["world"] as? String ?? "ISOLATED")
        }
        let action = (object["action"] ?? object["browser_action"] ?? object["page_action"]) as? [String: Any]
        popup = action?["default_popup"] as? String
        optionsPage = (object["options_ui"] as? [String: Any])?["page"] as? String ?? object["options_page"] as? String
        sidePanel = (object["side_panel"] as? [String: Any])?["default_path"] as? String
        usesChromeSignIn = object["oauth2"] != nil
        minimumChromeVersion = object["minimum_chrome_version"] as? String
        let icons = (object["icons"] as? [String: Any]) ?? (action?["default_icon"] as? [String: Any]) ?? [:]
        let largest = icons.compactMap { size, path in Int(size).flatMap { size in (path as? String).map { (size, $0) } } }
            .max { $0.0 < $1.0 }?.1 ?? action?["default_icon"] as? String
        icon = largest.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
    }

    /// Chrome manifest messages use the UI locale, its base language, then
    /// default_locale, with fallback for each individual message. Resolve
    /// names from the retained original archive, without changing its bytes.
    public func displayName(in archive: Data, fallback: String,
                            locale: String = Locale.preferredLanguages.first ?? "en") -> String {
        guard let resolved = localizedName(in: archive, locale: locale) else {
            return Self.usableName(fallback) ?? BrowserText.localized("Extension")
        }
        return resolved
    }

    /// A manifest's command (chrome.commands): its name, its description
    /// in the person's language, and the key it suggests on a Mac.
    public struct Command: Identifiable, Equatable {
        public let id: String
        public let title: String
        public let suggested: ExtensionKey?
        public init(id: String, title: String, suggested: ExtensionKey? = nil) {
            self.id = id
            self.title = title
            self.suggested = suggested
        }
    }

    /// The commands a manifest declares, for Settings to list while WebKit
    /// hasn't loaded the extension anywhere; in their names' order. One
    /// with no description is titled `untitled`.
    public static func commands(json data: Data, in archive: Data, untitled: String,
                                locale: String = Locale.preferredLanguages.first ?? "en") -> [Command] {
        guard let manifest = try? ExtensionManifest(json: data),
              let object = try? JSONSerialization.jsonObject(with: Data(withoutComments(String(decoding: data, as: UTF8.self)).utf8)) as? [String: Any],
              let commands = object["commands"] as? [String: Any] else { return [] }
        return commands.keys.sorted().map { id in
            let entry = commands[id] as? [String: Any] ?? [:]
            let title = (entry["description"] as? String).flatMap { manifest.localized($0, in: archive, locale: locale) } ?? untitled
            return Command(id: id, title: title, suggested: ExtensionKey(suggestedKey: entry["suggested_key"]))
        }
    }

    private func localizedName(in archive: Data, locale: String) -> String? {
        localized(name, in: archive, locale: locale)
    }

    /// Manifest text with its __MSG_…__ messages put in, as the name is.
    private func localized(_ name: String, in archive: Data, locale: String) -> String? {
        guard name.contains("__MSG_") else { return Self.usableName(name) }
        let pattern = try! NSRegularExpression(pattern: "__MSG_([A-Za-z0-9_@]+)__")
        let matches = pattern.matches(in: name, range: NSRange(name.startIndex..., in: name))
        guard !matches.isEmpty else { return nil }
        func safeLocale(_ value: String) -> String? {
            let value = value.replacingOccurrences(of: "-", with: "_")
            let parts = value.split(separator: "_", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
            } }) else { return nil }
            return value
        }
        var locales: [String] = []
        if let preferred = safeLocale(locale) {
            locales.append(preferred)
            if let base = preferred.split(separator: "_").first { locales.append(String(base)) }
        }
        if let defaultLocale = defaultLocale.flatMap(safeLocale) { locales.append(defaultLocale) }
        var messages: [String: String] = [:]
        for locale in locales.reversed() {
            let path = "_locales/\(locale)/messages.json"
            guard let data = ZipFile.file(in: archive, matching: { $0.caseInsensitiveCompare(path) == .orderedSame }),
                  let entries = try? JSONSerialization.jsonObject(with: Data(Self.withoutComments(String(decoding: data, as: UTF8.self)).utf8)) as? [String: Any]
            else { continue }
            for (key, entry) in entries {
                guard let entry = entry as? [String: Any], let value = Self.staticMessage(entry),
                      let value = Self.usableName(value) else { continue }
                messages[key.lowercased()] = value
            }
        }
        var resolved = name
        for match in matches.reversed() {
            guard let keyRange = Range(match.range(at: 1), in: name),
                  let value = messages[String(name[keyRange]).lowercased()],
                  let range = Range(match.range, in: resolved) else { return nil }
            resolved.replaceSubrange(range, with: value)
        }
        return Self.usableName(resolved)
    }

    /// Manifest names have no runtime substitution arguments. Named static
    /// placeholders and escaped dollars work; positional arguments cannot
    /// be supplied here, so the default catalog or retained name must win.
    private static func staticMessage(_ entry: [String: Any]) -> String? {
        guard let message = entry["message"] as? String else { return nil }
        let pattern = try! NSRegularExpression(pattern: #"\$\$|\$([A-Za-z0-9_@]+)\$|\$[1-9]"#)
        let substitutions = (entry["placeholders"] as? [String: Any] ?? [:]).reduce(into: [String: String]()) { found, item in
            if let placeholder = item.value as? [String: Any], let content = placeholder["content"] as? String {
                found[item.key.lowercased()] = content
            }
        }
        var result = ""
        var cursor = message.startIndex
        for match in pattern.matches(in: message, range: NSRange(message.startIndex..., in: message)) {
            guard let range = Range(match.range, in: message) else { return nil }
            result += message[cursor..<range.lowerBound]
            if message[range] == "$$" {
                result += "$"
            } else if let keyRange = Range(match.range(at: 1), in: message),
                      let content = substitutions[String(message[keyRange]).lowercased()] {
                let tokens = pattern.matches(in: content, range: NSRange(content.startIndex..., in: content))
                guard tokens.allSatisfy({ Range($0.range, in: content).map { content[$0] == "$$" } ?? false }) else { return nil }
                result += content.replacingOccurrences(of: "$$", with: "$")
            } else {
                return nil
            }
            cursor = range.upperBound
        }
        result += message[cursor...]
        return result
    }

    private static func usableName(_ value: String) -> String? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty || clean.contains("__MSG_") ? nil : clean
    }

    /// The text without its // and /* */ comments, strings left as they
    /// are; and without a byte order mark.
    static func withoutComments(_ text: String) -> String {
        var out = ""
        var chars = Array(text.unicodeScalars)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var at = 0
        var inString = false
        while at < chars.count {
            let c = chars[at]
            let next = at + 1 < chars.count ? chars[at + 1] : nil
            if inString {
                out.unicodeScalars.append(c)
                if c == "\\", let next {
                    out.unicodeScalars.append(next)
                    at += 2
                    continue
                }
                if c == "\"" { inString = false }
                at += 1
            } else if c == "\"" {
                inString = true
                out.unicodeScalars.append(c)
                at += 1
            } else if c == "/", next == "/" {
                while at < chars.count, chars[at] != "\n" { at += 1 }
            } else if c == "/", next == "*" {
                at += 2
                while at < chars.count, !(chars[at] == "*" && at + 1 < chars.count && chars[at + 1] == "/") { at += 1 }
                at += 2
            } else {
                out.unicodeScalars.append(c)
                at += 1
            }
        }
        return out
    }
}

/// What WebKit and eGlu answer, which every compatibility check
/// compares an extension against.
///
/// Neither half is written by hand from WebKit's documentation, which goes
/// stale: WebKit's half is what the Mac's own WebKit gave a test extension
/// that asked for everything (namespaces and their members), and eGlu's
/// half is the list of what its shims answer.
public struct ExtensionAPITable: Equatable, Sendable {
    public enum Answer: Equatable, Sendable {
        /// WebKit answers it.
        case native
        /// eGlu's shim answers it.
        case shim
        /// eGlu's shim answers some of it, as `identity`, whose
        /// launchWebAuthFlow works and getAuthToken is refused.
        case part
        /// Answered, and nothing happens.
        case stub
        /// Asked for, and refused with an error.
        case refused
    }

    /// Paths, "tabs" or "tabs.move", and their answers. A member with no
    /// entry of its own takes its namespace's.
    public var answers: [String: Answer]

    /// What eGlu's shims answer that WebKit lacks (Scripts/extension-shim.js,
    /// ExtensionAnswers.swift): kept beside them, read on top of what this
    /// Mac's WebKit has.
    public static let shims: [String: Answer] = [
        "sidePanel": .shim,
        "offscreen": .shim,
        "management": .part,
        "management.getSelf": .shim,
        "management.get": .shim,
        "runtime.getContexts": .shim,
        "i18n.detectLanguage": .shim,
        // Read as eGlu has them; a change is refused.
        "privacy": .part,
        // There to listen to and to ask; nothing is shown.
        "notifications": .stub,
        "webNavigation.onCreatedNavigationTarget": .stub,
        "webNavigation.onHistoryStateUpdated": .stub,
        "webNavigation.onReferenceFragmentUpdated": .stub,
        "webNavigation.onTabReplaced": .stub,
        "webNavigation.TransitionType": .shim,
        "webNavigation.TransitionQualifier": .shim,
        // eGlu sets no policies: it holds nothing, as Chrome's does then.
        "storage.managed": .shim,
        "scripting.ExecutionWorld": .shim,
        "scripting.StyleOrigin": .shim,
        // Search's list of what WebKit leaves out: events that never fire,
        // and what eGlu doesn't do, refused.
        "windows.onBoundsChanged": .stub,
        "tabs.onZoomChange": .stub,
        "tabs.setZoomSettings": .refused,
        "runtime.getPackageDirectoryEntry": .refused,
        "declarativeNetRequest.updateStaticRules": .refused,
        "declarativeNetRequest.testMatchOutcome": .refused,
        // The Mac's own (ExtensionAnswers).
        "idle": .shim,
        "power": .shim,
        // An extension's sign-in through its provider's page works
        // (ExtensionAuth); Chrome's own Google sign-in is refused.
        "identity": .part,
        "identity.launchWebAuthFlow": .shim,
        "identity.getRedirectURL": .shim,
        "identity.getAuthToken": .refused,
        // Through WebKit's registered content scripts (ExtensionAnswers).
        "userScripts": .shim,
    ]

    public init(answers: [String: Answer]) {
        self.answers = answers
    }

    /// The table for this Mac: what WebKit gave the test extension, then
    /// the shims' list on top for everything WebKit lacks.
    public init(webKit: [String: Set<String>], shims: [String: Answer]) {
        var answers: [String: Answer] = [:]
        for (namespace, members) in webKit {
            answers[namespace] = .native
            for member in members { answers["\(namespace).\(member)"] = .native }
        }
        for (path, answer) in shims where answers[path] == nil { answers[path] = answer }
        self.answers = answers
    }

    public func answer(for path: String) -> Answer? {
        if let answer = answers[path] { return answer }
        guard let dot = path.firstIndex(of: ".") else { return nil }
        let namespace = String(path[..<dot])
        // A member of a namespace WebKit has natively, not in its list, is
        // missing; a member of a shim's namespace is the shim's to answer.
        guard let whole = answers[namespace], whole != .native else { return nil }
        return whole
    }

    /// Whether a call to `path` does what it says: nothing answering it, a
    /// stub that does nothing, or a refusal all count as not.
    public func works(_ path: String) -> Bool {
        switch answer(for: path) {
        case .native, .shim, .part: return true
        case .stub, .refused, nil: return false
        }
    }

    /// The namespace a permission opens, where it isn't the permission's
    /// own name; nil for one that opens none (it changes what others may do).
    static let namespaces: [String: String?] = [
        "declarativeNetRequestWithHostAccess": "declarativeNetRequest",
        "declarativeNetRequestFeedback": "declarativeNetRequest",
        "activeTab": nil, "background": nil, "clipboardRead": nil, "clipboardWrite": nil,
        "favicon": nil, "geolocation": nil, "nativeMessaging": nil, "unlimitedStorage": nil,
        "webRequestBlocking": nil, "webRequestAuthProvider": nil,
    ]

    public static func namespace(of permission: String) -> String? {
        if let known = namespaces[permission] { return known }
        return permission
    }

    /// What an extension asks for that nothing on this Mac answers, by
    /// namespace, or by permission for one that opens none: a namespace
    /// neither this Mac's WebKit gave the test extension nor a shim
    /// answers, though WebKit may have kept its permission (it keeps
    /// `notifications` and gives no `chrome.notifications` on 27.0.1); and
    /// a permission of no namespace WebKit dropped. `cookies` is left to
    /// the person, who may allow it for the extension (heldPermissions).
    public func missing(asked: [String], kept: Set<String>) -> Set<String> {
        var out = Set<String>()
        for permission in asked where permission != "cookies" {
            if let namespace = Self.namespace(of: permission) {
                if !works(namespace) { out.insert(namespace) }
            } else if !kept.contains(permission), Self.shims[permission] == nil {
                out.insert(permission)
            }
        }
        return out
    }
}

extension ExtensionManifest {
    /// The permissions it asked for that WebKit didn't take. WebKit keeps
    /// those it supports and drops the rest without a word, so after
    /// loading, what the context requests is all that is left: `kept` is
    /// its requested and optional permissions.
    public func dropped(kept: Set<String>) -> [String] {
        (permissions + optionalPermissions).filter { !kept.contains($0) }
    }

    /// What installing it allows it, as written down and compared on each
    /// update: its API permissions, and its sites as "site:<pattern>", those
    /// its content scripts run on included. An update that asks for one not
    /// among them is asked about again, as Search does.
    public var grants: [String] {
        var out = Set(permissions)
        out.formUnion((hostPermissions + contentScripts.flatMap(\.matches)).map { "site:" + $0 })
        return out.sorted()
    }
}
