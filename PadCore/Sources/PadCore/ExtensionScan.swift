import Foundation

/// Reading an extension's code at install for what it reaches for and this
/// Mac doesn't have, so the person hears "may not work" before finding out.
///
/// It reads, it doesn't run, so what it finds is a note and never a
/// verdict. Code is minified and bundled: `chrome` is often renamed (to
/// `e`, `t`), so a namespace is looked for after any dot, by its name, which
/// is distinctive enough; a name that is also the web's or a common word
/// (`history`, `search`) counts only after `chrome.` or `browser.`, or
/// beside one of its own members. A use the code tests first (`typeof`,
/// `if (…)`, `&&`, `?.`, `"x" in`) is the extension asking, and makes every
/// use of that name in the file count as tested: the test usually guards
/// the uses that follow. What reading misses: names made at run time
/// (`chrome[name]`), `eval`, code fetched from a server.
public enum ExtensionScan {
    public struct Use: Equatable, Sendable {
        /// "sidePanel", or "identity.getAuthToken" when a member was what
        /// was looked for.
        public var path: String
        public var file: String
        public var line: Int
        /// The code tests for it before, or instead of, using it.
        public var tested: Bool
    }

    /// Names that are the web's own, or common words, with the members that
    /// make them Chrome's.
    static let commonNames: [String: Set<String>] = [
        "history": ["search", "getVisits", "addUrl", "deleteUrl", "deleteRange", "deleteAll", "onVisited", "onVisitRemoved"],
        "search": ["query"],
        "sessions": ["getRecentlyClosed", "getDevices", "restore", "onChanged", "MAX_SESSION_RESULTS"],
        "proxy": ["settings", "onProxyError"],
        "privacy": ["network", "services", "websites"],
        "power": ["requestKeepAwake", "releaseKeepAwake"],
        "system": ["cpu", "memory", "storage", "display"],
        "idle": ["queryState", "setDetectionInterval", "getAutoLockDelay", "onStateChanged"],
        "debugger": ["attach", "detach", "sendCommand", "getTargets", "onEvent", "onDetach"],
        "management": ["getAll", "get", "getSelf", "setEnabled", "uninstall", "uninstallSelf", "launchApp", "onInstalled", "onUninstalled", "onEnabled", "onDisabled"],
        "notifications": ["create", "update", "clear", "getAll", "getPermissionLevel", "onClicked", "onClosed", "onButtonClicked"],
        "downloads": ["download", "search", "pause", "resume", "cancel", "open", "show", "showDefaultFolder", "erase", "removeFile", "getFileIcon", "setUiOptions", "onCreated", "onChanged", "onErased", "onDeterminingFilename"],
        "bookmarks": ["getTree", "getChildren", "get", "getRecent", "getSubTree", "search", "create", "move", "update", "remove", "removeTree", "onCreated", "onChanged", "onRemoved", "onMoved", "onChildrenReordered"],
        "identity": ["getAuthToken", "launchWebAuthFlow", "getRedirectURL", "getProfileUserInfo", "removeCachedAuthToken", "clearAllCachedAuthTokens", "onSignInChanged"],
        "storage": ["local", "sync", "session", "managed", "onChanged"],
    ]

    /// Web API names, not Chrome's: an extension reads them off the page's
    /// window (`new EyeDropper()`, `w.EyeDropper`), so a bare use counts too,
    /// not only a member of some object.
    static let webAPIs: Set<String> = ["EyeDropper"]

    /// Every use in `source` of the paths in `missing`: namespaces
    /// ("sidePanel"), members ("identity.getAuthToken") or web APIs
    /// ("EyeDropper").
    public static func uses(in source: String, file: String, of missing: Set<String>) -> [Use] {
        // Nothing missing, nothing to find: every use found is of something missing.
        guard !missing.isEmpty else { return [] }
        let tokens = Lexer.tokens(source)
        var found: [Use] = []
        var testedNames: Set<String> = []
        for (index, token) in tokens.enumerated() {
            switch token.kind {
            case .name(let name):
                guard isAccess(index, in: tokens)
                   || (webAPIs.contains(name) && missing.contains(name) && isBareUse(index, in: tokens))
                else { continue }
                let member = member(after: index, in: tokens)
                let path: String
                var last = index
                if let member, missing.contains("\(name).\(member)") {
                    path = "\(name).\(member)"
                    last = index + 2
                } else if missing.contains(name) {
                    path = name
                } else {
                    continue
                }
                if let members = commonNames[name], !isAfterChrome(index, in: tokens),
                   !(member.map(members.contains) ?? false) {
                    continue
                }
                let tested = isTested(index, through: last, in: tokens)
                if tested { testedNames.insert(path) }
                found.append(Use(path: path, file: file, line: token.line, tested: tested))
            case .string(let text) where missing.contains(text):
                // chrome["sidePanel"], and "sidePanel" in chrome.
                let before = index > 0 ? tokens[index - 1].kind : nil
                let after = index + 1 < tokens.count ? tokens[index + 1].kind : nil
                // x["sidePanel"] is a member; ["sidePanel"] on its own is an array.
                let object = index > 1 ? tokens[index - 2].kind : nil
                let hasMembers: Bool
                switch object {
                case .name?, .punct(")")?, .punct("]")?: hasMembers = true
                default: hasMembers = false
                }
                if before == .punct("["), after == .punct("]"), hasMembers {
                    let tested = isTested(index, through: index + 1, in: tokens)
                    if tested { testedNames.insert(text) }
                    found.append(Use(path: text, file: file, line: token.line, tested: tested))
                } else if after == .word("in") {
                    testedNames.insert(text)
                    found.append(Use(path: text, file: file, line: token.line, tested: true))
                }
            default:
                continue
            }
        }
        // In the order they are in the code.
        return found.map { use in
            var use = use
            if testedNames.contains(use.path) { use.tested = true }
            return use
        }
    }

    /// The member right after a name: `sidePanel.open`.
    static func member(after index: Int, in tokens: [Lexer.Token]) -> String? {
        guard index + 2 < tokens.count,
              tokens[index + 1].kind == .punct(".") || tokens[index + 1].kind == .punct("?."),
              case .name(let member) = tokens[index + 2].kind
        else { return nil }
        return member
    }

    /// A name read as a member (`x.sidePanel`), not one declared or used on
    /// its own: a variable called `history` is not Chrome's.
    static func isAccess(_ index: Int, in tokens: [Lexer.Token]) -> Bool {
        guard index > 0 else { return false }
        let before = tokens[index - 1].kind
        return before == .punct(".") || before == .punct("?.")
    }

    /// A web API's name used as a global (`new EyeDropper()`, `typeof
    /// EyeDropper`), not declared (`let EyeDropper`) or an object's key
    /// (`EyeDropper: value`).
    static func isBareUse(_ index: Int, in tokens: [Lexer.Token]) -> Bool {
        if index > 0 {
            switch tokens[index - 1].kind {
            case .name("var"), .name("let"), .name("const"), .name("function"), .name("class"),
                 .name("import"), .name("export"), .name("default"):
                return false
            default: break
            }
        }
        if index + 1 < tokens.count, tokens[index + 1].kind == .punct(":") { return false }
        return true
    }

    static func isAfterChrome(_ index: Int, in tokens: [Lexer.Token]) -> Bool {
        guard index >= 2 else { return false }
        return tokens[index - 2].kind == .name("chrome") || tokens[index - 2].kind == .name("browser")
    }

    /// The use is a test: `typeof x.sidePanel`, `!x.sidePanel`,
    /// `x.sidePanel?.open`, `x.sidePanel && …`, `if (x.sidePanel)`. `index`
    /// is the name's token, `last` the chain's last token looked at: the
    /// name, its member, or the closing bracket.
    static func isTested(_ index: Int, through last: Int, in tokens: [Lexer.Token]) -> Bool {
        // Back to the start of the chain: chrome.sidePanel, e.sidePanel,
        // chrome["sidePanel"].
        var start = index
        while start >= 2 {
            let before = tokens[start - 1].kind
            if before == .punct(".") || before == .punct("?.") || before == .punct("[") {
                start -= 2
            } else {
                break
            }
        }
        let end = last + 1
        // typeof and ! test the value itself: `typeof x.sidePanel`. Before
        // more of the chain, `!x.sidePanel.open()`, they test nothing, and
        // the call throws all the same.
        let chainGoesOn = end < tokens.count && [.punct("."), .punct("?."), .punct("("), .punct("[")].contains(tokens[end].kind)
        if start > 0, !chainGoesOn {
            switch tokens[start - 1].kind {
            case .word("typeof"), .punct("!"): return true
            default: break
            }
        }
        guard end < tokens.count else { return false }
        switch tokens[end].kind {
        case .punct("?."), .punct("&&"), .punct("||"), .punct("??"), .punct("?"),
             .punct("=="), .punct("!="), .punct("==="), .punct("!=="):
            return true
        case .punct(")"):
            // if (x.sidePanel) … and while (…)
            var depth = 0
            var at = start - 1
            while at >= 0 {
                switch tokens[at].kind {
                case .punct(")"): depth += 1
                case .punct("("):
                    if depth == 0 { return at > 0 && [.word("if"), .word("while")].contains(tokens[at - 1].kind) }
                    depth -= 1
                default: break
                }
                at -= 1
            }
            return false
        default:
            return false
        }
    }
}

/// Just enough of JavaScript's syntax to find names in code: strings,
/// template literals, comments and regular expressions are stepped over,
/// so a name in a message or a comment isn't taken for code. The code in a
/// template's `${…}` is code, and is read.
enum Lexer {
    struct Token: Equatable {
        enum Kind: Equatable {
            case name(String)
            /// A keyword that matters to the scan: typeof, if, while, in.
            case word(String)
            case string(String)
            case punct(String)
        }
        var kind: Kind
        var line: Int
    }

    static let words: Set<String> = ["typeof", "if", "while", "for", "with", "in", "void", "return", "case", "delete", "instanceof", "new", "throw", "else", "do", "yield", "await"]
    /// Longest first, so === is read before == and = .
    static let puncts: [(text: String, scalars: [Unicode.Scalar])] = [
        "===", "!==", "?.", "&&", "||", "??", "==", "!=", "=>",
        "(", ")", "[", "]", "{", "}", ".", ",", ";", ":", "?", "!", "=", "+", "-", "*", "%", "<", ">", "&", "|", "^", "~",
    ].map { ($0, Array($0.unicodeScalars)) }

    static func tokens(_ source: String) -> [Token] {
        let reader = Reader(Array(source.unicodeScalars))
        reader.read(untilClosingBrace: false)
        return reader.tokens
    }

    final class Reader {
        let chars: [Unicode.Scalar]
        var at = 0
        var line = 1
        var tokens: [Token] = []
        /// For each parenthesis still open, whether it holds a condition:
        /// if (, while (, for (, with (.
        var parens: [Bool] = []
        /// The last token closed a condition, so a slash next starts a
        /// regular expression: `if (x) /re/.test(y)`.
        var afterCondition = false

        init(_ chars: [Unicode.Scalar]) {
            self.chars = chars
        }

        func add(_ kind: Token.Kind, line: Int? = nil) {
            var closesCondition = false
            switch kind {
            case .punct("("):
                if case .word(let word)? = tokens.last?.kind { parens.append(["if", "while", "for", "with"].contains(word)) } else { parens.append(false) }
            case .punct(")"):
                closesCondition = parens.popLast() ?? false
            default:
                break
            }
            tokens.append(Token(kind: kind, line: line ?? self.line))
            afterCondition = closesCondition
        }

        func isNameStart(_ c: Unicode.Scalar) -> Bool { c == "_" || c == "$" || CharacterSet.letters.contains(c) }
        func isName(_ c: Unicode.Scalar) -> Bool { isNameStart(c) || CharacterSet.decimalDigits.contains(c) }

        /// A slash here starts a regular expression rather than dividing.
        func regexAllowed() -> Bool {
            if afterCondition { return true }
            guard let last = tokens.last else { return true }
            switch last.kind {
            case .name, .string: return false
            case .word: return true
            case .punct(let p): return ![")", "]", "}"].contains(p)
            }
        }

        /// Reads to the end, or, in a template's `${…}`, to its closing brace.
        func read(untilClosingBrace: Bool) {
            var braces = 0
            while at < chars.count {
                let c = chars[at]
                let next = at + 1 < chars.count ? chars[at + 1] : nil
                if c == "\n" { line += 1; at += 1; continue }
                if CharacterSet.whitespaces.contains(c) { at += 1; continue }
                if c == "/", next == "/" {
                    while at < chars.count, chars[at] != "\n" { at += 1 }
                    continue
                }
                if c == "/", next == "*" {
                    at += 2
                    while at < chars.count, !(chars[at] == "*" && at + 1 < chars.count && chars[at + 1] == "/") {
                        if chars[at] == "\n" { line += 1 }
                        at += 1
                    }
                    at += 2
                    continue
                }
                if c == "\"" || c == "'" {
                    readString(closing: c)
                    continue
                }
                if c == "`" {
                    readTemplate()
                    continue
                }
                if c == "/", regexAllowed() {
                    at += 1
                    var inClass = false
                    while at < chars.count, chars[at] != "\n" {
                        if chars[at] == "\\" { at += 2; continue }
                        if chars[at] == "[" { inClass = true } else if chars[at] == "]" { inClass = false }
                        if chars[at] == "/", !inClass { break }
                        at += 1
                    }
                    at += 1
                    while at < chars.count, isName(chars[at]) { at += 1 }
                    add(.string(""))
                    continue
                }
                if isNameStart(c) {
                    var name = String.UnicodeScalarView()
                    while at < chars.count, isName(chars[at]) { name.append(chars[at]); at += 1 }
                    let text = String(name)
                    add(Lexer.words.contains(text) ? .word(text) : .name(text))
                    continue
                }
                if CharacterSet.decimalDigits.contains(c) {
                    while at < chars.count, isName(chars[at]) || chars[at] == "." { at += 1 }
                    add(.string(""))
                    continue
                }
                let matched = Lexer.puncts.first { p in
                    at + p.scalars.count <= chars.count && p.scalars.indices.allSatisfy { chars[at + $0] == p.scalars[$0] }
                }
                if let p = matched {
                    if p.text == "{" { braces += 1 }
                    if p.text == "}" {
                        if untilClosingBrace, braces == 0 {
                            at += 1
                            return
                        }
                        braces -= 1
                    }
                    // ?. before a digit is a ternary and a number: a?.5:1.
                    if p.text == "?.", at + 2 < chars.count, CharacterSet.decimalDigits.contains(chars[at + 2]) {
                        add(.punct("?"))
                        at += 1
                    } else {
                        add(.punct(p.text))
                        at += p.scalars.count
                    }
                    continue
                }
                at += 1
            }
        }

        func readString(closing: Unicode.Scalar) {
            let startLine = line
            var text = String.UnicodeScalarView()
            at += 1
            while at < chars.count, chars[at] != closing {
                if chars[at] == "\\", at + 1 < chars.count { at += 1 }
                if chars[at] == "\n" { line += 1 }
                text.append(chars[at])
                at += 1
            }
            at += 1
            add(.string(String(text)), line: startLine)
        }

        /// A template's text is a string; its `${…}` is code.
        func readTemplate() {
            var startLine = line
            var text = String.UnicodeScalarView()
            at += 1
            while at < chars.count, chars[at] != "`" {
                if chars[at] == "\\", at + 1 < chars.count {
                    at += 1
                } else if chars[at] == "$", at + 1 < chars.count, chars[at + 1] == "{" {
                    add(.string(String(text)), line: startLine)
                    text = String.UnicodeScalarView()
                    at += 2
                    read(untilClosingBrace: true)
                    startLine = line
                    continue
                }
                if chars[at] == "\n" { line += 1 }
                text.append(chars[at])
                at += 1
            }
            at += 1
            add(.string(String(text)), line: startLine)
        }
    }
}
