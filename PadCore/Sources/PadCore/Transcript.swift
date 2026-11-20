import Foundation

/// What is said in a recording, line by line, as a site's own reader gave
/// it (SiteAdapter.reader, youtube.js): the site keeps it out of the page's
/// text, in a panel the person has to ask for.
///
/// Everything in it comes from the page, by way of a script of the app's
/// own, and is read leniently and within limits like the rest of a page
/// (PageReading): a line that is no line is passed over.
public struct Transcript: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        /// When it is said, as the site writes it: "0:11", "1:02:03". Empty where the site gave none.
        public var time: String
        public var words: String

        public init(time: String = "", words: String) {
            self.time = time
            self.words = words
        }
    }

    public var lines: [Line]
    /// It went on past what was asked for.
    public var cut: Bool
    /// Every caption the page has for the recording was made by speech
    /// recognition: names and words may be wrong, and the file says so.
    public var generated: Bool

    public init(lines: [Line], cut: Bool = false, generated: Bool = false) {
        self.lines = lines
        self.cut = cut
        self.generated = generated
    }

    /// How a site's reader left the page.
    public enum Answer: Equatable, Sendable {
        case read(Transcript)
        /// Nothing to be had: not a recording's page, or a recording with no transcript.
        case none
        /// Not to be had on this page, though another of the site's may
        /// have it (the site as a phone is served it shows no transcript).
        /// `captions` is false where the page says the recording has none
        /// at all, and nil where it could not tell.
        case absent(captions: Bool?)

        /// Whether another of the site's pages is worth asking.
        public var looksElsewhere: Bool {
            if case .absent(let captions) = self { return captions != false }
            return false
        }
    }

    /// The most lines kept, and the most characters of one.
    public static let mostLines = 20_000
    public static let longestLine = 2_000

    /// From what the script gave back. Anything that is not an answer is none.
    public static func answer(_ said: Any?) -> Answer {
        guard let said = said as? [String: Any] else { return .none }
        switch said["state"] as? String {
        case "absent":
            return .absent(captions: said["captions"] as? Bool)
        case "read":
            var lines: [Line] = []
            for one in (said["lines"] as? [Any] ?? []).prefix(mostLines) {
                guard let pair = one as? [Any], pair.count == 2, let words = pair[1] as? String else { continue }
                let plain = words.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                guard !plain.isEmpty else { continue }
                lines.append(Line(time: clock(pair[0] as? String ?? ""), words: String(plain.prefix(longestLine))))
            }
            guard !lines.isEmpty else { return .none }
            return .read(Transcript(lines: lines, cut: said["cut"] as? Bool ?? false, generated: said["generated"] as? Bool ?? false))
        default:
            return .none
        }
    }

    /// A time as a clock shows one, or nothing: what the page gave is the page's, and goes into the file.
    static func clock(_ time: String) -> String {
        let parts = time.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts[0].count <= 3, parts.dropFirst().allSatisfy({ $0.count == 2 }),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return "" }
        return time
    }

    /// About how long a paragraph of the transcript is, in characters: a minute or so of speech.
    public static let paragraph = 600

    /// As blocks of a page: a heading, then the lines run together into
    /// paragraphs of about 600 characters, each begun with the time its
    /// first line is said at. A line a block would make a file of a
    /// thousand lines of a few words each, and an hour's talk in one block
    /// could not be found in. No more than `room` characters: where that
    /// is not all of it, the last block says so.
    /// The heading the transcript goes under, which the sheet's outline knows it by (Handoff.outline).
    static let heading = "## Transcript"

    public func blocks(room: Int) -> [PageBlock] {
        var blocks = [PageBlock(kind: .heading, level: 2, text: Self.heading, hint: .transcript, start: "Transcript")]
        var used = blocks[0].characters + 2
        var current = ""
        var stopped = cut
        func close() {
            guard !current.isEmpty else { return }
            blocks.append(PageBlock(text: current, hint: .transcript))
            used += current.count + 2
            current = ""
        }
        for line in lines {
            if !current.isEmpty, current.count + line.words.count + 1 > Self.paragraph { close() }
            let piece = current.isEmpty ? (line.time.isEmpty ? "" : line.time + " ") + line.words : " " + line.words
            if used + current.count + piece.count + 2 > room {
                stopped = true
                break
            }
            current += piece
        }
        close()
        guard blocks.count > 1 else { return [] }
        if stopped { blocks.append(PageBlock(text: "[The transcript goes on past here.]", hint: .transcript, note: true)) }
        return blocks
    }
}

extension PageReading {
    /// What the file says of a transcript that was added to the page's text.
    public struct Spoken: Equatable, Sendable {
        public var lines: Int
        public var generated: Bool
        public var cut: Bool

        public init(lines: Int, generated: Bool = false, cut: Bool = false) {
            self.lines = lines
            self.generated = generated
            self.cut = cut
        }
    }

    /// The page with what is said in its recording added, under a heading
    /// of its own after the page's text and before the notes the text
    /// points to. What the reader's own walk took of a transcript that
    /// stood open on the page goes: the same lines, each a block of a few
    /// words with its time read out as "11 seconds". Within `limit`
    /// characters for the page and the transcript together.
    public func adding(_ transcript: Transcript, limit: Int = Handoff.limit) -> PageReading {
        var reading = self
        let hints = Handoff.hints(in: self)
        reading.blocks = zip(blocks, hints).filter { $0.1 != .transcript }.map(\.0)
        let used = reading.blocks.reduce(0) { $0 + $1.characters + 2 }
        let more = transcript.blocks(room: max(0, limit - used))
        guard !more.isEmpty, !reading.blocks.isEmpty else { return self }
        let end = reading.blocks.lastIndex { $0.hint != .footnotes }.map { $0 + 1 } ?? 0
        reading.blocks.insert(contentsOf: more, at: end)
        reading.spoken = Spoken(lines: transcript.lines.count, generated: transcript.generated, cut: more.last?.note ?? false)
        return reading
    }
}
