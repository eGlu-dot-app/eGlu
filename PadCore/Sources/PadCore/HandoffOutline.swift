import Foundation

extension Handoff {
    /// What the file holds, as the sheet shows it while the file is made
    /// (HandoffGuide): the parts of the page in the order they go, each by
    /// its heading and the words it begins with, what was set aside, and
    /// the person's selection. Read off the composed text itself
    /// (Composed.body), so the sheet never names a part the file does not
    /// hold, and names them in the file's own words.
    public struct Outline: Equatable, Sendable {
        /// What a part begins with, which the sheet's mark for it says.
        public enum Shape: String, Equatable, Sendable {
            case text, list, table, code, quote, picture
        }

        /// A part under one heading. The headings are those of one level:
        /// the highest the page has more than one of, so that a page's
        /// title over its sections is not taken for its only section.
        /// What is under a lower heading goes with the part it is in.
        public struct Section: Equatable, Sendable {
            /// The heading's words, plain. Empty for what comes before the first heading.
            public var heading: String
            /// The words it begins with, plain, on one line. Where it has
            /// nothing but lower headings, those, one after another.
            public var opening: String
            public var shape: Shape
            /// Some of it is only started: the rest is counted in the file, not given.
            public var started: Bool
            /// How many characters of it the file counts and does not give.
            /// Where it is all of it, the opening is empty: the file has its
            /// heading and the count, and none of its words.
            public var left: Int

            public init(heading: String, opening: String, shape: Shape = .text, started: Bool = false, left: Int = 0) {
                self.heading = heading
                self.opening = opening
                self.shape = shape
                self.started = started
                self.left = left
            }
        }

        public var sections: [Section] = []
        /// What was set aside, named with its size (Composed.asides).
        public var asides: [Aside] = []
        /// The person's selection, plain, which goes first.
        public var selection = ""
        /// What a recording says is in the file, as the site's own reader
        /// gave it (PageReading.adding): at the file's end, after the page's
        /// text. Its part is not among the sections, the sheet having a row
        /// of its own for it. A transcript of the page's own is a part of
        /// the page like the others, listed where it is.
        public var transcript = false

        public init() {}

        public var isEmpty: Bool {
            sections.isEmpty && asides.isEmpty && selection.isEmpty && !transcript
        }
    }

    /// How long a part's opening words may be, in characters.
    static let openingRoom = 160
    /// How long the selection may be as the sheet shows it.
    static let selectionRoom = 200

    /// The outline of what is composed. `reading` says whether a site's
    /// transcript was added to it (PageReading.spoken).
    public static func outline(of composed: Composed, reading: PageReading? = nil) -> Outline {
        var outline = Outline()
        outline.asides = composed.asides
        outline.selection = cut(outlinePlain(composed.selection), to: selectionRoom)
        outline.transcript = reading?.spoken != nil

        // What was read in the page's pictures is the picture's, not the page's parts: its big text came
        // as headings, which would be taken for the page's own (PageReading.shown).
        var body = composed.body
        for block in reading?.blocks ?? [] where block.text.hasPrefix(pictureText) {
            if let found = body.range(of: block.text) { body.removeSubrange(found) }
        }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Which lines are in a block of code, fences included, and which are headings, of what level.
        var code = Array(repeating: false, count: lines.count)
        var levels = [Int?](repeating: nil, count: lines.count)
        // The fence a block of code was opened with: it ends at a fence of the same mark, as long or longer.
        var fenced: Substring?
        // The page's title, where it heads the others: not a part of its own.
        var skipped: Int?
        for (index, line) in lines.enumerated() {
            if let fence = fence(of: line) {
                code[index] = true
                if let open = fenced {
                    if fence.first == open.first, fence.count >= open.count { fenced = nil }
                } else {
                    fenced = fence
                }
                continue
            }
            code[index] = fenced != nil
            if fenced == nil { levels[index] = headingLevel(line) }
        }
        // The site's transcript, where there is one: the last heading as its
        // reader writes it, which comes after all of the page's own text. A
        // part of the page's called the same, before it, stays a part. Its
        // heading is the reader's and not the page's: it has no say in which
        // headings part the page (on a page of "###" headings alone, the
        // transcript's "##" was taken for the page's title, its text going
        // into the page's last part).
        let spoken = outline.transcript
            ? lines.indices.last { levels[$0] != nil && lines[$0] == Transcript.heading } : nil
        var found = levels.indices.filter { $0 != spoken }.compactMap { levels[$0] }
        // One heading above all the others, heading the page, is its title, not its only part: it is left out,
        // the card over the outline saying what the page is called. One that comes after other headings
        // ("## Appendix" after "### Intro") is a part.
        if let level = found.min(), found.count(where: { $0 == level }) == 1, found.contains(where: { $0 > level }),
           let title = levels.indices.first(where: { levels[$0] != nil && $0 != spoken }), levels[title] == level {
            levels[title] = nil
            skipped = title
            found.removeAll { $0 == level }
        }
        // The parts are under the highest headings the page has more than one of; one above them all is a part too.
        // Where no level comes twice, under the highest: what is under it goes with it ("### macOS" is a part
        // of "## Installation"), and a heading before the first of them, with none above it to be in, is a part
        // of its own ("### Intro" before "## Appendix"), where it would make a part with no name.
        let repeated = Set(found).sorted().first { level in found.count(where: { $0 == level }) > 1 }
        let top = repeated ?? found.min()
        let firstTop = repeated == nil ? top.flatMap { level in levels.indices.first { levels[$0] == level && $0 != spoken } } : nil
        var heading = ""
        var headed: Int?
        var under: [Int] = []
        func close() {
            guard headed == nil || headed != spoken,
                  let section = section(heading: heading, lines: under, of: lines, code: code, levels: levels) else { return }
            outline.sections.append(section)
        }
        // The transcript is a part of its own whatever the page's headings
        // are (a page parted by its top headings would take it into its last
        // part, its first timed line that part's opening), and what follows
        // it, the notes the page's text points to, another.
        let transcriptLevel = headingLevel(Transcript.heading) ?? 2
        var inSpoken = false
        for index in lines.indices where index != skipped {
            guard let level = levels[index],
                  level <= (top ?? 0) || index == spoken || (inSpoken && level <= transcriptLevel)
                    || (firstTop.map { index < $0 } ?? false) else {
                under.append(index)
                continue
            }
            close()
            heading = headingWords(lines[index])
            headed = index
            inSpoken = index == spoken
            under = []
        }
        close()
        return outline
    }

    /// How a block of what was read in a picture begins (PageReading.shown).
    static let pictureText = "Text in the picture:\n\n"

    /// One part: what it begins with, and whether some of it is only
    /// started. Nil where nothing is under its heading. What comes before
    /// the first heading is said by its first long paragraph, where it has
    /// one: a page's tabs and notes come before its first words there as
    /// often as not ("For other uses, see…").
    private static func section(heading: String, lines indices: [Int], of lines: [String], code: [Bool],
                                levels: [Int?]) -> Outline.Section? {
        var opening: (words: String, shape: Outline.Shape)?
        var sentence: String?
        var prose: String?
        var named: String?
        var lower: [String] = []
        var started = false
        var left = 0
        var position = 0
        while position < indices.count {
            let index = indices[position]
            let line = lines[index]
            // A block of code, fence to fence.
            if code[index] {
                var inside: [String] = []
                var end = position
                while end < indices.count, code[indices[end]] {
                    let inner = lines[indices[end]]
                    if !isFence(inner) { inside.append(inner) }
                    end += 1
                    // The closing fence ends it.
                    if end - 1 > position, isFence(inner) { break }
                }
                if opening == nil, let first = inside.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    opening = (oneLine(first, upTo: openingRoom), .code)
                }
                position = end
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                position += 1
                continue
            }
            if levels[index] != nil {
                lower.append(headingWords(line))
                position += 1
                continue
            }
            // A paragraph: the lines up to the next empty one, a heading, or a block of code.
            var block: [String] = []
            while position < indices.count {
                let next = indices[position]
                guard !code[next], levels[next] == nil, !lines[next].trimmingCharacters(in: .whitespaces).isEmpty else { break }
                block.append(lines[next])
                position += 1
            }
            if block.count == 1, let note = block.first, isNote(note) {
                if let counted = counted(note) {
                    started = true
                    left += counted
                }
                continue
            }
            let begins = beginning(of: block)
            if opening == nil { opening = begins }
            // Words of the page's own, not a picture's caption: a picture comes first as often as not.
            let first = block[0].trimmingCharacters(in: .whitespaces)
            guard begins.shape == .text, !first.hasPrefix("!["), !first.hasPrefix("[![") else { continue }
            let plain = outlinePlain(block.joined(separator: " "))
            if sentence == nil, endsASentence(plain) { sentence = begins.words }
            if heading.isEmpty, plain.count >= PageReading.long {
                if prose == nil { prose = begins.words }
                // What it is about, in bold, first: how an encyclopedia's article opens, after a picture's caption as often as not.
                if named == nil, first.hasPrefix("**") { named = begins.words }
            }
        }
        // A part that begins with a table, a list or code is named by that; one that begins with words, by
        // its first sentence, past a label ("Main article: …") or a caption.
        let wordsFirst = opening?.shape == .text || opening?.shape == .picture
        if let said = (heading.isEmpty ? named ?? prose : nil) ?? (wordsFirst ? sentence : nil) { opening = (said, .text) }
        if let opening, !opening.words.isEmpty {
            return Outline.Section(heading: heading, opening: opening.words, shape: opening.shape, started: started, left: left)
        }
        // A heading with nothing of its own but lower headings: those say what is in it.
        if !lower.isEmpty {
            return Outline.Section(heading: heading, opening: cut(lower.joined(separator: " · "), to: openingRoom), started: started,
                                   left: left)
        }
        // A heading with nothing under it but the count of what is left out: in the file, as its heading and the count.
        guard left > 0, !heading.isEmpty else { return nil }
        return Outline.Section(heading: heading, opening: "", started: true, left: left)
    }

    /// The characters a note of the file's counts and leaves out: "[1,200 more characters here.]" (Handoff.compose).
    private static func counted(_ note: String) -> Int? {
        let line = note.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("["), line.hasSuffix(" more characters here.]") else { return nil }
        return Int(line.dropFirst().prefix { $0.isNumber || $0 == "," }.filter(\.isNumber))
    }

    /// Whether words end as a sentence does, and not as a label ("Main
    /// article: Theory of tides") or a line of links does.
    private static func endsASentence(_ words: String) -> Bool {
        let end = words.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)] "))
        guard let last = end.last else { return false }
        return ".!?:…。！？".contains(last)
    }

    /// What a block begins with, by what it is.
    private static func beginning(of block: [String]) -> (words: String, shape: Outline.Shape) {
        let first = block[0].trimmingCharacters(in: .whitespaces)
        if first.hasPrefix("|") {
            // A table, by the names of its columns.
            let cells = first.split(separator: "|").map { outlinePlain(String($0)) }.filter { !$0.isEmpty }
            return (cut(cells.joined(separator: " · "), to: openingRoom), .table)
        }
        if let item = listItem(first) {
            return (cut(outlinePlain(item), to: openingRoom), .list)
        }
        if first.hasPrefix(">") {
            let said = block.map { $0.trimmingCharacters(in: .whitespaces).drop { $0 == ">" || $0 == " " } }.joined(separator: " ")
            return (cut(outlinePlain(said), to: openingRoom), .quote)
        }
        let words = cut(outlinePlain(block.joined(separator: " ")), to: openingRoom)
        if first.hasPrefix("!["), block.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).hasPrefix("![") }) {
            return (words, .picture)
        }
        return (words, .text)
    }

    /// A list item's words without its mark: "- ", "* ", "+ ", "1. ", "1) ".
    private static func listItem(_ line: String) -> String? {
        for mark in ["- ", "* ", "+ "] where line.hasPrefix(mark) {
            return String(line.dropFirst(mark.count))
        }
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(rest.dropFirst(2))
    }

    /// A line in brackets alone, the file's or its reader's: what is counted
    /// and not given, where the page goes on, where a video was ("[Video]").
    private static func isNote(_ line: String) -> Bool {
        let line = line.trimmingCharacters(in: .whitespaces)
        return line.hasPrefix("[") && !line.hasPrefix("[^") && line.hasSuffix("]") && !line.contains("](")
    }

    private static func isFence(_ line: String) -> Bool {
        fence(of: line) != nil
    }

    /// The run of three or more backticks or tildes a fence of code starts with, past up to three spaces.
    private static func fence(of line: String) -> Substring? {
        let start = line.drop { $0 == " " }
        guard line.count - start.count <= 3, let mark = start.first, mark == "`" || mark == "~" else { return nil }
        let run = start.prefix { $0 == mark }
        return run.count >= 3 ? run : nil
    }

    /// A Markdown heading's level, 1 to 6: its marks and a space after them.
    private static func headingLevel(_ line: String) -> Int? {
        let marks = line.prefix { $0 == "#" }
        guard (1...6).contains(marks.count), line.dropFirst(marks.count).first == " " else { return nil }
        return marks.count
    }

    private static func headingWords(_ line: String) -> String {
        oneLine(outlinePlain(String(line.drop { $0 == "#" })), upTo: 120)
    }

    /// Markdown as plain words on one line: a link's and a picture's words
    /// without their addresses, and no marks of emphasis or code.
    static func outlinePlain(_ text: String) -> String {
        var words = text
        // A linked picture, [![words](picture)](link), takes two goes.
        for _ in 0..<2 {
            words = words.replacingOccurrences(of: #"!?\[([^\]]*)\]\((?:[^()]|\([^()]*\))*\)"#, with: "$1", options: .regularExpression)
        }
        for (pattern, with) in [
            // An address may have parentheses of its own: Wikipedia's Current_(fluid).
            (#"!?\[([^\]]*)\]\((?:[^()]|\([^()]*\))*\)"#, "$1"),
            (#"<(?:https?|mailto):[^>]*>"#, ""),
            // Footnote marks: [^4].
            (#"\[\^[^\]]*\]"#, ""),
            (#"\*\*|__|~~|`"#, ""),
            (#"(?<![\w*])\*(?=\S)|(?<=\S)\*(?![\w*])"#, ""),
        ] {
            words = words.replacingOccurrences(of: pattern, with: with, options: .regularExpression)
        }
        return words.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
