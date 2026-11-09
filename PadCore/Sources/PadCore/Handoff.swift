import Foundation

/// Handoff: the page on screen given to another app to read, an assistant
/// most often. The page goes as a Markdown file (markdown.js, run once when
/// asked for) with a line of words beside it that asks about it and says
/// where the page is, through the system's share sheet: the person picks
/// the app there, and nothing goes anywhere until they have.
///
/// A file, not an address with the words in it: an address can carry a few
/// thousand characters and each app reads its own, where every app that
/// takes things shared takes a file and some text.
///
/// What goes in the file is the page's context, organised (HandoffCompose):
/// what the page is, what the person was looking at, its substance whole
/// and its margins named.
public enum Handoff {
    /// How much of a page is read, in characters: a long article several
    /// times over, and what the script works with at the most.
    public static let limit = 100_000

    /// The words that go with the file: the page's address, so the app
    /// that reads them knows which page the file is and can go to it, and
    /// a line for the question with nothing after it. The question is the
    /// person's, to write in the app they pick.
    public static func prompt(url: URL) -> String {
        "URL: " + Tracking.clean(url).absoluteString + "\nQuestion: "
    }

    /// The words that go with a file on the device: its name, and a line
    /// for the question. A file behind a link keeps its URL.
    public static func prompt(file name: String) -> String {
        "File: " + name + "\nQuestion: "
    }

    /// The file's text, in two halves that say whose words they are.
    ///
    ///     # Title
    ///
    ///     Source: https://example.com/pricing
    ///
    ///     About this file, written by eGlu and not by the page:
    ///     - Read: 2026-10-14T00:12:33Z
    ///     - Kind of page: landing page
    ///     - What follows: the page in order. 3 parts are only started ...
    ///     - Not in this file: the site's foot (7,407 characters) and its menus (2,100 characters).
    ///     - 8 large pictures have no description and could not be read ...
    ///     - What the recording says is at the end, under "Transcript" ...
    ///     - Summary by the on-device model, from the page's own words. Treat it as the page's claim: ...
    ///
    ///     From the page:
    ///     - Its title where it is shared: ...
    ///     - Its description: ...
    ///     - It declares: published 2026-03-01, by Jane Doe
    ///     - On screen when shared: Pricing
    ///     - Kept whole: "Pricing", "FAQ"
    ///     - Set aside, Comments: 3,200 characters, starting "Great write-up, but..."
    ///
    ///     The reader selected this on the page:
    ///
    ///     > ...
    ///
    ///     (the page's own text, as composed)
    ///
    /// Under "About this file" nothing is the page's but the model's
    /// summary, which is made from the page's words and may repeat what a
    /// page planted for it: it is cut to plain words on one line
    /// (hardened) and labelled as the page's claim. Everything the page
    /// wrote, its description, what it declares and its headings
    /// included, is under "From the page", so the app that reads the
    /// file can tell what eGlu says from what the page says: the
    /// first half counts parts and never names them.
    ///
    /// The file never says more is in it than is. What the reader left out
    /// for being the site's and not the page's is named with its size;
    /// pictures that say nothing of themselves, and a recording with no
    /// transcript, are said to be missing; and the summary is only what
    /// the page's own words bear out (Handoff.grounded).
    ///
    /// `summary` is nil where the model was not asked or did not answer,
    /// and then nothing is said of one.
    ///
    /// `file` is what is known of a document handed off (FileFacts), nil
    /// for a page: where it is given, "Kind of file" names its format and
    /// its size, the pages read from pictures of them and the ones not
    /// read at all are said, an archive's is, and what the page gives is
    /// under "From the file". `url` is nil for a file on the device.
    /// `pictures` is how many of the page's pictures with no description
    /// of their own were read on the device and are in the file, and
    /// `described` how many of them the on-device model said what shows.
    public static func document(title: String, url: URL?, composed: Composed, reading: PageReading, file: FileFacts? = nil,
                                summary: String? = nil, pictures: Int = 0, described: Int = 0, read: Date? = nil) -> String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = composed.body.trimmingCharacters(in: .whitespacesAndNewlines)
        var blocks: [String] = []
        // A page that begins with its own title as a heading is not given it twice.
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let headed = first.hasPrefix("# ") && plain(String(first.dropFirst(2))) == plain(name)
        if !name.isEmpty, !headed { blocks.append("# " + oneLine(name, upTo: 200)) }
        if let url {
            blocks.append("Source: " + Tracking.clean(url).absoluteString)
        } else if let file {
            blocks.append("File: " + file.name)
        }

        let facts = reading.facts
        var about: [String] = []
        if let read { about.append("- Read: " + stamp(read)) }
        if let file {
            about.append("- Kind of file: " + file.format.name + (file.counts.isEmpty ? "" : ", " + file.counts))
        } else if composed.kind != .other {
            about.append("- Kind of page: " + composed.kind.name)
        }
        // A page that draws what it shows (a document or a sheet in an editor, a map, a board) has little to read, and the file says so.
        let drawn = facts.canvas >= drawnShare && facts.characters < drawnText
        about.append("- What follows: " + follows(composed, left: facts.left, drawn: drawn, ofFile: file != nil))
        if drawn {
            about.append("- Most of what this page shows is drawn by the page and is not text: it could not be read. What follows is the text the page has around it.")
        }
        if facts.covered { about.append("- The page had a sheet over it when it was read (a notice, a prompt): what follows is the page under it.") }
        if facts.busy { about.append("- The page said it was still loading when it was read: some of it may be missing.") }
        let missing = leftOut(facts.left, notes: reading.blocks.contains { $0.hint == .footnotes })
        if !missing.isEmpty { about.append("- Not in this file: " + missing) }
        if let file, !file.notRead.isEmpty {
            about.append("- Not in this file: " + file.missed + ".")
        } else if file != nil, reading.truncated {
            // Cut where a part ends (HandoffDocument.fitted): what was left out is named by its headings, which are the file's words.
            about.append("- Not in this file: the rest of the file, past what one file holds."
                + (file?.unread.isEmpty == false
                   ? (composed.kind == .spreadsheet ? " The sheets left out are named under \"From the file\"."
                      : composed.kind == .archive ? " The files left out are named under \"From the file\"."
                      : " The headings of the parts left out are named under \"From the file\".") : ""))
        }
        if let file, file.readFromPictures.count == 1 {
            about.append(String(format: BrowserText.localized("- Read from a picture of the page, on this device: page %@. Its words may be wrong in places."),
                                FileFacts.listed(file.readFromPictures)))
        } else if let file, !file.readFromPictures.isEmpty {
            about.append(String(format: BrowserText.localized("- Read from pictures of the pages, on this device: pages %@. Their words may be wrong in places."),
                                FileFacts.listed(file.readFromPictures)))
        }
        if let file, !file.skipped.isEmpty {
            about.append("- In the archive, not read: " + file.skipped.joined(separator: ", ") + ".")
        }
        if let file, file.described {
            about.append("- What it shows was described by the on-device model, which can be wrong.")
        }
        if let file, let transcribed = file.transcribed, let language = file.language {
            let whole = file.duration == nil || transcribed >= file.duration ?? 0
            about.append("- Transcribed on this device, in " + language + ": "
                + (whole ? "all of it"
                   : "the first " + grouped(max(1, (transcribed + 30) / 60)) + " minutes")
                + "; its words may be wrong in places.")
        }
        // What is said of a file on its own is said of one read from an archive, by its name.
        for inner in file?.within ?? [] {
            let named = "- In " + oneLine(inner.name, upTo: 100) + ": "
            if !inner.notRead.isEmpty { about.append(named + "not in this file: " + inner.missed + ".") }
            if inner.readFromPictures.count == 1 {
                about.append(named + String(format: BrowserText.localized("read from a picture of the page, on this device: page %@. Its words may be wrong in places."),
                                            FileFacts.listed(inner.readFromPictures)))
            } else if !inner.readFromPictures.isEmpty {
                about.append(named + String(format: BrowserText.localized("read from pictures of the pages, on this device: pages %@. Their words may be wrong in places."),
                                            FileFacts.listed(inner.readFromPictures)))
            }
        }
        if facts.unnamed > 0 {
            // Much of the page, where they are three or more, or two windows' height of them.
            let much = facts.unnamed >= 3 || (facts.tall > 0 && facts.unnamedTall >= facts.tall * 2)
            if pictures > 0 {
                let left = facts.unnamed - pictures
                about.append("- \(grouped(facts.unnamed)) large \(facts.unnamed == 1 ? "picture has" : "pictures have") no description of their own; "
                    // The model is spoken of only where it said what one shows: in Low Power Mode it is not asked.
                    + (described > 0
                       ? "eGlu read \(pictures == 1 ? "one" : grouped(pictures)) of them on this device: the text in them, "
                         + "and what the on-device model saw, which can be wrong."
                       : "eGlu read the text in \(pictures == 1 ? "one" : grouped(pictures)) of them on this device.")
                    + (much && left > 0 ? " Much of what this page says may be in the rest." : ""))
            } else {
                about.append("- \(grouped(facts.unnamed)) large \(facts.unnamed == 1 ? "picture has" : "pictures have") no description and could not be read"
                    + (much ? ". Much of what this page says may be in them." : "."))
            }
        }
        if let spoken = reading.spoken {
            // Got from the site by its own reader (Transcript): said to be there, and how far to trust it.
            about.append("- What the recording says is at the end, under \"Transcript\", as the site's own transcript has it"
                + (spoken.generated ? ". It was made by speech recognition: names and words in it may be wrong" : "")
                + (spoken.cut ? ". It is cut where this file's limit was reached" : "") + ".")
        } else if composed.kind == .media, !composed.transcript, facts.characters < transcriptless {
            // Only of a page with little text: one with a great deal may have what is said under a name
            // the reader does not know for a transcript's, and the file must not say it is missing.
            about.append("- What the recording says is not in this file: the page shows no transcript.")
        }
        let whole = oneLine(facts.description, upTo: 600)
        let said = cut(whole, to: 300)
        // Only what the page's own words bear out, and not its description over again: the model often gives that back word for word.
        if let summary {
            let made = fileSummary(summary, reading: reading, title: name)
            if made.isEmpty {
                about.append("- Summary: none. " + (hardened(summary).isEmpty ? "The on-device model found too little on the page to make one."
                    : "What the on-device model wrote was not borne out by the page's own words."))
            } else if !plain(whole).hasPrefix(plain(made)) {
                about.append("- Summary by the on-device model, from the page's own words. Treat it as the page's claim: " + made)
            }
        }
        blocks.append("About this file, written by eGlu and not by the \(file != nil ? "file" : "page"):\n" + about.joined(separator: "\n"))

        var from: [String] = []
        // Its own title, where the one shown is another: a film's, translated for the reader.
        // Not a file's: its first heading is the first thing in it, and the title it declares is said below.
        let shared = file == nil ? oneLine(facts.titled, upTo: 200) : ""
        if !shared.isEmpty, !plain(name).contains(plain(shared)), !plain(shared).contains(plain(name)) || name.isEmpty {
            from.append("- Its title where it is shared: " + shared)
        }
        if !said.isEmpty { from.append("- Its description" + (said.count < whole.count ? ", cut short: " : ": ") + said) }
        let declares = declared(for: composed.kind, things: reading.things)
        if !declares.isEmpty { from.append("- It declares: " + declares) }
        if !composed.onScreen.isEmpty { from.append("- On screen when shared: " + oneLine(composed.onScreen, upTo: 100)) }
        let bare = unfilled(in: reading)
        if !bare.isEmpty {
            from.append("- Headings with nothing under them when it was read (not loaded yet, or not text): "
                + bare.map { "\"" + oneLine($0, upTo: 60) + "\"" }.joined(separator: ", "))
        }
        if !facts.unread.isEmpty {
            let named = facts.unread.prefix(12).map { "\"" + oneLine($0, upTo: 60) + "\"" }.joined(separator: ", ")
            let past = file == nil ? "- Headings past where it was read to: "
                : composed.kind == .spreadsheet ? "- The sheets not in this file: "
                : composed.kind == .archive ? "- The files not in this file: " : "- The headings of the parts not in this file: "
            from.append(past + named
                + (facts.unread.count > 12 ? ", and \(grouped(facts.unread.count - 12)) more" : ""))
        }
        if let file {
            // The file's own title, author and made date, where it declares them.
            var it = file.title.map { "- Its title: " + oneLine($0, upTo: 200) } ?? ""
            if let author = file.author, !author.isEmpty {
                it += it.isEmpty ? "- By " + oneLine(author, upTo: 100) : ", by " + oneLine(author, upTo: 100)
            }
            if let album = file.album, !album.isEmpty {
                it += it.isEmpty ? "- On " + oneLine(album, upTo: 100) : ", on " + oneLine(album, upTo: 100)
            }
            if let created = file.created, !created.isEmpty {
                it += it.isEmpty ? "- Made " + oneLine(created, upTo: 40) : ", made " + oneLine(created, upTo: 40)
            }
            if !it.isEmpty { from.append(it) }
        }
        if !composed.whole.isEmpty {
            from.append("- Kept whole: " + composed.whole.prefix(6).map { "\"" + oneLine($0, upTo: 60) + "\"" }.joined(separator: ", "))
        }
        for aside in composed.asides.prefix(12) {
            var line = "- Set aside, \(oneLine(aside.name, upTo: 60)): \(grouped(aside.characters)) characters"
            if aside.links > 0 { line += ", \(grouped(aside.links)) \(aside.links == 1 ? "link" : "links")" }
            if !aside.start.isEmpty { line += ", starting \"\(oneLine(aside.start, upTo: asideStart + 1))\"" }
            from.append(line)
        }
        blocks.append(([file != nil ? "From the file:" : "From the page:"] + from).joined(separator: "\n"))

        if !composed.selection.isEmpty {
            blocks.append("The reader selected this on the page:")
            blocks.append(quoted(composed.selection))
            if !composed.excerpt.isEmpty {
                blocks.append("It is in a part of the page that is not below. Around it:")
                blocks.append(quoted(composed.excerpt))
            }
        } else if !composed.excerpt.isEmpty {
            blocks.append("On screen when shared, past where the page was read to:")
            blocks.append(quoted(composed.excerpt))
        }
        if !text.isEmpty { blocks.append(text) }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// Under this many characters read, the model is not asked about the page: with next to nothing
    /// to go by, its summary is the page's description over again, or a guess (HandoffJob).
    public static let leastToSum = 300

    /// How much of the window a page draws on, in hundredths, and how
    /// little text it has, to be taken for one whose words are drawn.
    static let drawnShare = 50
    static let drawnText = 3_000

    /// The headings of the first two levels that the page ends on with
    /// nothing under any of them: what a shop's page heads "Reviews" and
    /// "Questions" and loads when it is come to. Only those at the page's
    /// end: two headings in a row further up are the names of two tabs as
    /// often, with what the first heads under the second. None where
    /// there are more than five, or on a page that is nothing but
    /// headings: that is how such a page is written, and nothing is missing.
    static func unfilled(in reading: PageReading) -> [String] {
        var bare: [String] = []
        for block in reading.blocks.reversed() {
            guard block.kind == .heading else { break }
            let title = block.title
            if block.level <= 2, !title.isEmpty, !bare.contains(title) { bare.insert(title, at: 0) }
        }
        let headed = reading.blocks.contains { $0.kind != .heading }
        return headed && bare.count <= 5 ? bare : []
    }

    /// A summary without what it says over again: a sentence given twice,
    /// and past the second the sentences that begin as two before them did
    /// ("The rating is 4.2." five times, of five things).
    static func unrepeated(_ summary: String) -> String {
        var seen = Set<String>()
        var begun: [String: Int] = [:]
        var kept: [String] = []
        for sentence in sentences(of: summary) {
            let words = Vocabulary.words(of: sentence)
            guard seen.insert(words.joined(separator: " ")).inserted else { continue }
            if words.count >= 4 {
                let start = words.prefix(3).joined(separator: " ")
                begun[start, default: 0] += 1
                if begun[start, default: 0] > 2 { continue }
            }
            kept.append(sentence)
        }
        return kept.joined(separator: " ")
    }

    /// A moment as the web writes one, by Greenwich's clock: 2026-10-14T00:12:33Z.
    /// Not by the device's own: the file goes to another app, and the hour
    /// the reader's clock is set to says where they are.
    static func stamp(_ moment: Date) -> String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        format.timeZone = TimeZone(secondsFromGMT: 0)
        return format.string(from: moment)
    }

    /// What the reader left out for being the site's and not the page's,
    /// each with how much it says, so that the file claims no more than it
    /// holds. Parts of under 20 characters are not worth the saying. The
    /// notes the text points to are read out of the foot (markdown.js) and
    /// are in the file: where there are some, the foot is said to be
    /// without them, so that it is not read as saying they are missing.
    static func leftOut(_ left: PageFacts.Left, notes: Bool = false) -> String {
        let foot = notes ? "the site's foot but for the notes the text points to, which are at the end" : "the site's foot"
        let parts = [(foot, left.foot), ("the site's top", left.top), ("its menus", left.menus), ("what stands beside the page", left.beside)]
            .filter { $0.1 >= 20 }
            .map { "\($0.0) (\(grouped($0.1)) characters)" }
        guard let last = parts.last else { return "" }
        return (parts.count == 1 ? last : parts.dropLast().joined(separator: ", ") + " and " + last) + "."
    }

    /// What the file says follows, in eGlu's words: how the page was put together.
    static func follows(_ composed: Composed, left: PageFacts.Left = PageFacts.Left(), drawn: Bool = false, ofFile file: Bool = false) -> String {
        var says: [String] = []
        // "The whole page" only where it is: nothing started, set aside or left out, by the file or by the reader, and all of it read.
        let touched = composed.started > 0 || !composed.asides.isEmpty || composed.dropped > 0 || composed.listed > 0
            || !leftOut(left).isEmpty || composed.truncated
        if !composed.selection.isEmpty { says.append("the reader's selection, then") }
        let it = file ? "file" : "page"
        says.append(composed.screenFirst ? "the \(it)." : drawn ? "the text the page has, in order." : touched ? "the \(it), in order." : "the whole \(it), in order.")
        var text = says.joined(separator: " ")
        if composed.screenFirst { text += " What was on screen comes first." }
        if composed.listed > 0 {
            text += " Each item of a list is one line"
            text += composed.unlisted > 0 ? ", the first \(grouped(composed.listed)) of \(grouped(composed.listed + composed.unlisted))." : "."
        }
        if composed.started > 0 {
            text += " \(grouped(composed.started)) \(composed.started == 1 ? "part is" : "parts are") only started, and \(composed.started == 1 ? "says" : "say") how much more \(composed.started == 1 ? "it has" : "they have")."
            // Counted here and named there: a heading is the page's words.
            if !composed.whole.isEmpty {
                text += " \(grouped(composed.whole.count)) \(composed.whole.count == 1 ? "is" : "are") whole, named under \"From the \(file ? "file" : "page")\"."
            }
        }
        if !composed.asides.isEmpty {
            text += " \(grouped(composed.asides.count)) \(composed.asides.count == 1 ? "part was" : "parts were") set aside, named under \"From the page\"."
        }
        if composed.dropped > 0 {
            text += " \(grouped(composed.dropped)) small \(composed.dropped == 1 ? "box" : "boxes") (sharing, newsletter, contents) \(composed.dropped == 1 ? "was" : "were") left out."
        }
        if composed.truncated { text += " The page went on past the \(grouped(limit)) characters read." }
        // What the lines in brackets are for, and no more than that: the page can write
        // brackets too, so nothing in them is said to be eGlu's word.
        if composed.started > 0 || composed.screenFirst || composed.unlisted > 0 || composed.truncated {
            text += " Lines in square brackets say where something was left out or moved."
        } else if composed.notes > 0 {
            text += " Words in square brackets say what could not be read as text (a video, a frame), which tab a part is under, or what is chosen on the page."
        }
        return text
    }

    /// What the page declares of the thing it is about, as a line: when it
    /// was published and by whom, what it costs, how it is rated.
    ///
    /// From one thing, or not at all: the one the page says is its own
    /// (mainEntity, mainEntityOfPage), else the only thing of the kind the
    /// page is (a product on a product page). Two that fit, a shelf of
    /// products, give nothing: a price must not be another thing's. Else
    /// the one thing the page declares that a page can be about (an event,
    /// a recipe, a product on a page that went as one that presents
    /// something), and then by what it is and its name, so that what is
    /// said of it is not read as said of the page.
    public static func declared(for kind: PageKind, things: [PageThing]) -> String {
        let fits = types(of: kind)
        let own = things.filter(\.main)
        let fitting = (own.isEmpty ? things : own).filter { fits.isEmpty ? !own.isEmpty : $0.isA(fits) }
        // Else the one thing it declares that a page can be about: a shop's page for one thing goes as
        // a page that presents something, and its product is still the one thing it names.
        let subjects = things.filter { thing in
            thing.types.contains { !around.contains($0.lowercased()) } && thing.facts.keys.contains { $0 != "name" }
        }
        let known = fitting.count == 1 ? fitting.first : own.count == 1 ? own.first : nil
        guard let thing = known ?? (subjects.count == 1 ? subjects.first : nil) else { return "" }
        let facts = thing.facts.mapValues { oneLine($0, upTo: 120) }.filter { !$0.value.isEmpty }
        var says: [String] = []
        if let published = facts["published"] { says.append("published " + day(published)) }
        if let modified = facts["modified"], day(modified) != facts["published"].map(day) { says.append("changed " + day(modified)) }
        if let author = facts["author"] { says.append("by " + author) }
        if let publisher = facts["publisher"], publisher != facts["author"] { says.append("from " + publisher) }
        if let journal = facts["journal"] { says.append("in " + journal) }
        if let doi = facts["doi"] { says.append("DOI " + doi) }
        if let starts = facts["starts"] { says.append("starts " + moment(starts)) }
        if let ends = facts["ends"], ends != facts["starts"] { says.append("ends " + moment(ends)) }
        if let place = facts["place"] { says.append("at " + place) }
        if let address = facts["address"] { says.append("address " + address) }
        if let phone = facts["phone"] { says.append("phone " + phone) }
        if let brand = facts["brand"] { says.append("brand " + brand) }
        if let price = facts["price"] { says.append("price " + price) }
        if let range = facts["priceRange"], facts["price"] == nil { says.append("price range " + range) }
        if let availability = facts["availability"] { says.append(availability) }
        if let rating = facts["rating"] {
            says.append("rated " + rating + (facts["ratings"].map { " by " + $0 } ?? ""))
        }
        if let duration = facts["duration"] { says.append("length " + length(duration)) }
        if let total = facts["total"] {
            says.append("takes " + length(total))
        } else {
            if let prep = facts["prep"] { says.append("preparing takes " + length(prep)) }
            if let cook = facts["cook"] { says.append("cooking takes " + length(cook)) }
        }
        if let yield = facts["yield"] {
            // As the page has it where it says so itself ("Makes 12", "Serves 4").
            let own = ["makes", "serves", "yield"].contains { yield.lowercased().hasPrefix($0) }
            says.append(own ? yield : "makes " + yield)
        }
        if let calories = facts["calories"] { says.append(calories) }
        if let isbn = facts["isbn"] { says.append("ISBN " + isbn) }
        if let pages = facts["pages"] { says.append(pages + " pages") }
        if let employer = facts["employer"] { says.append("employer " + employer) }
        if let employment = facts["employment"] { says.append(employment) }
        if let salary = facts["salary"] { says.append("pay " + salary) }
        if let closes = facts["closes"] { says.append("closes " + day(closes)) }
        guard known == nil, !says.isEmpty else { return says.joined(separator: ", ") }
        // What kind of thing, in words ("JobPosting" as "job posting"), and its name.
        let type = (thing.types.first { !around.contains($0.lowercased()) } ?? thing.types.first ?? "thing")
            .replacingOccurrences(of: #"([a-z])([A-Z])"#, with: "$1 $2", options: .regularExpression).lowercased()
        let article = "aeiou".contains(type.prefix(1)) ? "an " : "a "
        return article + oneLine(type, upTo: 40) + (facts["name"].map { ", \"" + $0 + "\"" } ?? "") + ": " + says.joined(separator: ", ")
    }

    /// What a page declares around the thing it is about and is not that
    /// thing: the site, the page, who publishes it, where it is in the
    /// site, its pictures, and what a thing is made of (an offer, a rating).
    private static let around: Set<String> = [
        "website", "webpage", "organization", "corporation", "newsmediaorganization", "person", "breadcrumblist", "listitem",
        "imageobject", "searchaction", "sitenavigationelement", "wpheader", "wpfooter", "wpsidebar", "brand", "offer",
        "aggregateoffer", "aggregaterating", "review", "rating", "postaladdress", "place", "collectionpage", "itemlist",
        "searchresultspage", "faqpage", "question", "answer", "howtostep", "readaction", "contactpoint", "country", "thing",
    ]

    /// A day and an hour as they are read, where they are written the way the web writes them
    /// (2026-11-02T19:00:00-05:00): the day, the hour, and whose clock it is by.
    private static func moment(_ date: String) -> String {
        let whole = day(date)
        let rest = date.dropFirst(10)
        guard whole != date, rest.hasPrefix("T"), rest.count >= 6 else { return whole }
        let hour = rest.dropFirst().prefix(5)
        guard hour.count == 5, hour.allSatisfy({ $0.isNumber || $0 == ":" }) else { return whole }
        let zone = rest.dropFirst().drop { $0.isNumber || $0 == ":" || $0 == "." }
        let by = zone == "Z" ? " UTC" : zone.isEmpty ? "" : " (" + zone + ")"
        return whole + " " + hour + by
    }

    /// A length of time as it is read, where it is written the way the web writes one (PT1H4M12S).
    private static func length(_ duration: String) -> String {
        guard duration.hasPrefix("PT") else { return duration }
        var parts: [String] = []
        var digits = ""
        for character in duration.dropFirst(2) {
            if character.isNumber {
                digits.append(character)
            } else if let unit = ["H": "h", "M": "min", "S": "s"][character], !digits.isEmpty {
                parts.append(digits + " " + unit)
                digits = ""
            } else {
                return duration
            }
        }
        return parts.isEmpty || !digits.isEmpty ? duration : parts.joined(separator: " ")
    }

    /// A date as its day, where it is written the way the web writes one (2026-03-01T09:00:00Z).
    private static func day(_ date: String) -> String {
        let head = date.prefix(10)
        let dated = head.count == 10 && head.enumerated().allSatisfy { index, character in
            index == 4 || index == 7 ? character == "-" : character.isNumber
        }
        return dated ? String(head) : date
    }

    /// The model's summary as it may go in the file: its first line, in
    /// plain words. Addresses and Markdown are taken out, so a line a page
    /// planted for the model cannot bring a link or a heading with it.
    /// What it cannot take out is a false statement in plain words, which
    /// is why the file says whose claim the summary is.
    public static func hardened(_ summary: String) -> String {
        var line = summary.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        for (pattern, with) in [
            (#"!?\[([^\]]*)\]\([^)]*\)"#, "$1"),
            (#"(?i)\b(?:https?://|www\.)\S+"#, ""),
            (#"[*_`#>|\[\]<>]"#, ""),
        ] {
            line = line.replacingOccurrences(of: pattern, with: with, options: .regularExpression)
        }
        return oneLine(line, upTo: 700)
    }

    /// What the model said a picture shows, as it may go in the file:
    /// hardened to one line of at most 400 characters. It is written next
    /// to a note that says the model's words can be wrong.
    public static func described(_ said: String) -> String {
        oneLine(hardened(said), upTo: 400)
    }

    /// Under this many characters of text a recording's page is taken to show no transcript, where it calls nothing one.
    public static let transcriptless = 5_000

    /// How long a summary may be in the file.
    public static let summaryRoom = 500

    /// The model's summary as it goes in the file: plain words on one line
    /// (hardened), only the sentences the page's own words bear out
    /// (grounded), none said twice, within the room a summary has. Empty
    /// where nothing of it is left. What the sheet shows once the model
    /// is done (HandoffGuide) is this, so it shows what the file says.
    public static func fileSummary(_ summary: String, reading: PageReading, title: String) -> String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return sentences(of: unrepeated(grounded(hardened(summary), in: reading, title: name)), upTo: summaryRoom)
    }

    /// A summary within `room` characters, by whole sentences: one that
    /// does not fit is left out with those after it, so that it never
    /// stops in the middle of a word. A first sentence longer than the
    /// room is cut at a word, and says so.
    static func sentences(of summary: String, upTo room: Int) -> String {
        guard summary.count > room else { return summary }
        var kept: [String] = []
        var size = 0
        for sentence in sentences(of: summary) {
            let more = sentence.count + (kept.isEmpty ? 0 : 1)
            if size + more > room { break }
            kept.append(sentence)
            size += more
        }
        return kept.isEmpty ? cut(summary, to: room) : kept.joined(separator: " ")
    }

    // MARK: The summary held against the page

    /// The model's summary as far as the page's own words bear it out: the
    /// sentences of it whose words are the page's. A small model, asked
    /// what a page is, writes a sentence that reads well and may not be
    /// so: it called a humidifier an air purifier, and said of a film with
    /// one line of text that it was "humorous commentary and clips". A
    /// sentence goes only if half or more of its words of substance are on
    /// the page (in its text, its title or its description), and every
    /// number in it is. Words that only frame a summary ("this page
    /// describes", "이 페이지는 소개합니다") are not of substance: with them
    /// counted, a true sentence of one fact failed and a false one of two
    /// framing words and a made-up name could pass. A word counts as there when the page has it or a
    /// longer form of it ("prototype" for "prototypes", "가습기" for
    /// "가습기를").
    ///
    /// By words, so only in a language that parts its words with spaces
    /// and that the page is also in: a summary in English of a page in
    /// Korean has none of the page's words, and does not go. Japanese and
    /// Chinese, which do not part words, are let through unheld.
    public static func grounded(_ summary: String, in reading: PageReading, title: String) -> String {
        guard !summary.isEmpty else { return "" }
        let unparted = summary.unicodeScalars.filter { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }.count
        if unparted * 4 >= summary.unicodeScalars.count { return summary }
        let page = Vocabulary(of: reading, title: title)
        return sentences(of: summary).filter { page.bearsOut($0) }.joined(separator: " ")
    }

    /// A text's sentences, each with the mark it ends on.
    static func sentences(of text: String) -> [String] {
        var found: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            current.append(character)
            let ends = ".!?。！？".contains(character)
            let last = index + 1 == characters.count
            // A full stop inside a number or a name (4.2, example.org) ends nothing. The marks of
            // Japanese and Chinese end a sentence with nothing after them: no space is written there.
            if ends, last || characters[index + 1].isWhitespace || "。！？".contains(character) {
                found.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { found.append(rest) }
        return found.filter { !$0.isEmpty }
    }

    /// The words a page has, to hold a sentence against.
    struct Vocabulary {
        /// Every word of the page, and every way one of them starts, from two letters on.
        private var starts = Set<String>()
        /// Every number on the page as its digits, without what parts them ("499000" for
        /// "499,000"), and every run of digits in it (499, and 0 for 000), without zeros in front.
        private var numbers = Set<String>()

        /// Words that frame a summary and say nothing of the page: "this page describes".
        private static let framing: Set<String> = [
            "this", "that", "these", "those", "with", "from", "which", "also", "their", "there", "into", "more", "most", "your",
            "about", "page", "pages", "site", "website", "article", "video", "post", "titled", "called", "named", "describes",
            "explains", "shows", "presents", "offers", "features", "provides", "includes", "including", "such", "what", "when",
            "where", "they", "them", "have", "been", "will", "over", "than", "then", "each", "some", "many", "other",
        ]

        /// The same in Korean, where a word carries its particle or its ending: by how the word starts
        /// ("페이지는", "소개합니다", "판매하고").
        private static let framingStarts = ["페이지", "사이트", "웹사이트", "홈페이지", "소개", "설명", "제공", "판매", "보여", "포함", "관련", "정보",
                                            "내용", "있습니다", "입니다", "합니다", "됩니다", "대한", "위한", "통해"]

        init(of reading: PageReading, title: String) {
            var text = title + " " + reading.facts.description + " " + reading.facts.titled + " " + reading.facts.site
            for block in reading.blocks { text += " " + Handoff.spoken(block) }
            for figure in Self.figures(in: text) {
                numbers.insert(figure.whole)
                numbers.formUnion(figure.runs)
            }
            for word in Self.words(of: text) {
                guard starts.insert(word).inserted else { continue }
                var start = word
                while start.count > 2 {
                    start.removeLast()
                    starts.insert(start)
                }
            }
        }

        static func words(of text: String) -> [String] {
            text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
        }

        /// Whether a word has a digit in it: such a word is held as a number, not as a word.
        static func hasDigits(_ word: String) -> Bool {
            word.contains { $0.isASCII && $0.isNumber }
        }

        /// The numbers in a text: each as all of its digits ("499000" for
        /// "499,000" and for "499000"), and as its runs of digits (499, 0).
        /// Zeros in front are not part of a number: "06" is 6.
        static func figures(in text: String) -> [(whole: String, runs: [String])] {
            var found: [(whole: String, runs: [String])] = []
            var runs: [String] = []
            var run = ""
            func plain(_ digits: String) -> String {
                let cut = digits.drop { $0 == "0" }
                return cut.isEmpty ? "0" : String(cut)
            }
            func close() {
                if !run.isEmpty { runs.append(run) }
                run = ""
                if !runs.isEmpty { found.append((plain(runs.joined()), runs.map(plain))) }
                runs = []
            }
            let characters = Array(text)
            for (index, character) in characters.enumerated() {
                if character.isASCII, character.isNumber {
                    run.append(character)
                } else if character == "," || character == ".", !run.isEmpty, index + 1 < characters.count,
                          characters[index + 1].isASCII, characters[index + 1].isNumber {
                    // A mark between two digits parts one number.
                    runs.append(run)
                    run = ""
                } else {
                    close()
                }
            }
            close()
            return found
        }

        /// Whether half or more of a sentence's words of substance are the page's, and all of its numbers.
        func bearsOut(_ sentence: String) -> Bool {
            var asked = 0
            var there = 0
            // A number the page does not have is a fact the model made. As the page has it, however it is
            // parted ("499000" for the page's "499,000"), or in parts the page has ("2026", "10", "6" for "2026.10.06").
            for figure in Self.figures(in: sentence) {
                guard numbers.contains(figure.whole) || figure.runs.allSatisfy(numbers.contains) else { return false }
            }
            for word in Self.words(of: sentence) {
                if Self.hasDigits(word) { continue }
                let latin = word.unicodeScalars.allSatisfy { $0.value < 0x250 }
                guard word.count >= (latin ? 4 : 2), !Self.framing.contains(word) else { continue }
                if !latin, Self.framingStarts.contains(where: word.hasPrefix) { continue }
                asked += 1
                // The page's word, or one the page has a longer form of, or a longer form of one the page has.
                var form = word
                let least = max(latin ? 4 : 2, word.count - (latin ? 3 : 2))
                var found = starts.contains(form)
                while !found, form.count > least {
                    form.removeLast()
                    found = starts.contains(form)
                }
                if found { there += 1 }
            }
            return asked > 0 && there * 2 >= asked
        }
    }

    /// The file's name: the page's title, or its host, without what a file
    /// name can't hold, short enough to read in the share sheet.
    public static func fileName(title: String, url: URL) -> String {
        // The system's control characters take in the joiners as well, which
        // hold an emoji of several together (a family) and some scripts'
        // letters: those stay. The rest go, the marks that turn text
        // backwards among them, by which a name can pass for another.
        let joiners = CharacterSet(charactersIn: "\u{200C}\u{200D}")
        let barred = CharacterSet(charactersIn: "/\\:*?\"<>|\u{0}").union(.newlines).union(.controlCharacters).subtracting(joiners)
        var name = title.components(separatedBy: barred).joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        // A name that begins with a dot is a hidden file.
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = url.host ?? BrowserText.localized("Page") }
        if name.count > 80 { name = String(name.prefix(80)) }
        // A file system's limit on a name is in bytes (255 of UTF-8 on
        // Apple's), and 80 characters can be well past it: emoji, letters
        // with marks on them. The file could not be written at all, and
        // the page would go without it. Cut by whole characters, with room
        // for the extension and for a number an app adds to a copy.
        while name.utf8.count > maxNameBytes { name.removeLast() }
        name = name.trimmingCharacters(in: .whitespaces)
        return (name.isEmpty ? BrowserText.localized("Page") : name) + ".md"
    }

    /// The file's name for a document handed off: the file's own name
    /// without its extension, cleaned as a page's title is.
    public static func fileName(file name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return fileName(title: base.isEmpty ? name : base, url: URL(fileURLWithPath: "/"))
    }

    /// A name's bytes at the most, before its extension: 80 characters of Hangul, three bytes each, and no more.
    static let maxNameBytes = 240

    /// Words on one line.
    static func oneLine(_ text: String, upTo limit: Int) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.count > limit ? String(words.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" : words
    }

    /// Text as a quotation, line for line.
    private static func quoted(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
    }

    /// A heading and a title compared as words: without emphasis marks, in one case.
    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "`", with: "")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ").lowercased()
    }
}
