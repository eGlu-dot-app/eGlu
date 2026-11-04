import AVFoundation
import CoreGraphics
import Engines
import Foundation
import PadCore
import PDFKit
import UniformTypeIdentifiers
import WebEngineCore

/// A document handed off: a file chosen or dropped, a download, or a file
/// behind a link, fetched through the tab's own web view (HandoffFetch).
/// The engines turn its bytes into Markdown (Documents), the Markdown
/// becomes a reading like a page's (HandoffDocument), and from there on
/// it is a handoff like any other (HandoffJob). Its kind is told by the
/// file's format, never counted and never asked of the model.
@MainActor
final class DocumentSource: HandoffSource {
    /// Where the file came from, for "Source:" and the prompt; nil for a
    /// file on the device (a local file has no address).
    let address: URL?
    /// The file's name, which the file's heading and its prompt say.
    let title: String
    let isFile = true
    /// What is known of the file, once read (FileFacts).
    private(set) var file: FileFacts?

    /// The file's bytes, or where they are read from. A `link` is fetched
    /// through the tab's own web view (HandoffFetch) when the file is read.
    private let data: Data?
    private let url: URL?
    private let link: URL?
    private let downloads: (any WebDownloadStarting)?
    /// The format the tab's kind declared, where bytes and extension don't.
    private let hint: FileFormat?

    /// From bytes in hand: a file fetched through a tab (HandoffFetch).
    init(data: Data, name: String, address: URL? = nil) {
        self.data = data
        url = nil
        link = nil
        downloads = nil
        title = name
        self.address = address
        hint = nil
    }

    /// From where the file is: a chosen or dropped file, or a download.
    init(file url: URL, name: String? = nil, address: URL? = nil, format hint: FileFormat? = nil) {
        data = nil
        self.url = url
        link = nil
        downloads = nil
        title = name ?? url.lastPathComponent
        self.address = address
        self.hint = hint
    }

    /// From a link to fetch through the tab's own web view, into the
    /// job's folder, when the file is read; its `address` the link's.
    init(link url: URL, downloads: any WebDownloadStarting) {
        data = nil
        self.url = nil
        link = url
        self.downloads = downloads
        title = url.lastPathComponent
        address = url
        hint = nil
    }

    /// A file over this many bytes is not read.
    nonisolated static let sizeLimit = 200_000_000
    /// A PDF's pages read at the most.
    nonisolated static let pageLimit = 300
    /// Extensions a link's menu offers Handoff for.
    static let linkExtensions: Set<String> = ["pdf", "doc", "docx", "docm", "ppt", "pptx", "xls", "xlsx",
                                             "xlsm", "odt", "ods", "odp", "rtf", "epub", "csv", "json",
                                             "xml", "txt", "zip", "jpg", "jpeg", "png", "heic", "heif",
                                             "gif", "webp", "tif", "tiff",
                                             // Recordings, as FileFormat(ext:) reads them: a link's, and the choosers'.
                                             "mp3", "m4a", "aac", "wav", "aif", "aiff", "ogg", "oga", "flac", "caf",
                                             "opus", "mp4", "mov", "m4v", "webm", "mkv", "avi"]
    /// The kinds a file picker offers.
    static let contentTypes: [UTType] = linkExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
    /// Pages that are only pictures read by Vision at the most.
    nonisolated static let visionLimit = 30
    /// A PDF's seconds of reading at the most, from when it is opened:
    /// what is read by then goes, and the rest is named as not read.
    nonisolated static let readingLimit = Duration.seconds(20)

    func reading(limit: Int, into folder: URL, telling: Handoff.Telling?) async -> Handoff.ReadOutcome {
        do {
            let opened = try await Self.open(data: data, url: url, link: link, downloads: downloads?.keepingSessionAlive(), name: title,
                                             hint: hint, into: folder)
            let (reading, facts) = try await Self.convert(opened.data, facts: opened.facts, engine: opened.engine, room: limit,
                                                          into: folder, telling: telling)
            file = facts
            return reading.blocks.isEmpty ? .noReadableContent : .content(reading)
        } catch let problem as DocumentProblem {
            return .failed(problem.message)
        } catch let problem as EngineError {
            return problem.kind == .encrypted
                ? .protectedPage(Self.words(for: problem.kind))
                : .failed(Self.words(for: problem.kind))
        } catch {
            return .failed(String(localized: "The file could not be read."))
        }
    }

    func transcript(limit: Int) async -> Transcript? { nil }
    func picture(pixels: Int) async -> CGImage? { nil }

    /// The file's bytes and what it is, told from the bytes themselves
    /// (Documents.detect) or, where they carry no signature, from the
    /// file's extension: CSV, JSON, XML, plain text and ZIP, or from what
    /// the tab said it holds (`hint`). `engine` is the engines' own name
    /// for it, which says more than its kind does: a .doc is Word's as a
    /// .docx is, and needs another reader.
    private static func open(data: Data?, url: URL?, link: URL?, downloads: (any WebDownloadStarting)?, name: String, hint: FileFormat?,
                             into folder: URL) async throws -> (data: Data, facts: FileFacts, engine: DocumentFormat?) {
        var given = data
        if let link {
            guard let downloads, downloads.canStartDownloads else { throw DocumentProblem(message: String(localized: "The tab it was on is gone.")) }
            let fetched = try await HandoffFetch.fetch(link, with: downloads, into: folder)
            given = try await bytes(of: nil, url: fetched)
        }
        let data = try await bytes(of: given, url: url)
        guard data.count <= sizeLimit else {
            throw DocumentProblem(message: String(localized: "Too large to read: \(FileFacts.size(data.count))."))
        }
        let ext = url?.pathExtension ?? (name as NSString).pathExtension
        let engine = (try? await detect(data)) ?? DocumentFormat(ext: ext)
        var format = engine.flatMap(FileFormat.init) ?? FileFormat(ext: ext)
        if format == nil, HandoffPicture.isPicture(data) {
            format = .picture
        }
        guard let format = format ?? hint else {
            throw DocumentProblem(message: String(localized: "eGlu can't read this kind of file."))
        }
        return (data, FileFacts(format: format, name: name, bytes: data.count), engine)
    }

    /// The file's bytes, from where it is on the device: a dropped or
    /// chosen file's scope is the read's own.
    @concurrent
    private static func bytes(of data: Data?, url: URL?) async throws -> Data {
        if let data { return data }
        guard let url else { throw DocumentProblem(message: String(localized: "The file could not be read.")) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// What the bytes are, away from the main thread.
    @concurrent
    private static func detect(_ data: Data) async throws -> DocumentFormat? {
        try Documents.detect(data)
    }

    /// The document's bytes read, away from the main thread: the engines'
    /// synchronous work, and the reading made of their Markdown, cut at
    /// `room` where a page, a sheet or a part of the file ends.
    @concurrent
    private static func convert(_ data: Data, facts: FileFacts, engine: DocumentFormat?, room: Int,
                                into folder: URL, telling: Handoff.Telling? = nil) async throws
        -> (PageReading, FileFacts) {
        let (markdown, facts, truncated) = try await markdown(data, facts: facts, engine: engine, room: room,
                                                              into: folder, telling: telling)
        return (HandoffDocument.reading(markdown: markdown, facts: facts, truncated: truncated), facts)
    }

    /// The document's Markdown and what is known of it, the third value
    /// `truncated`: true where it was cut to fit `room`, or a PDF's time ran out.
    @concurrent
    private static func markdown(_ data: Data, facts: FileFacts, engine: DocumentFormat?, room: Int,
                                 into folder: URL, telling: Handoff.Telling? = nil) async throws
        -> (String, FileFacts, Bool) {
        var facts = facts
        switch facts.format {
        case .pdf:
            // The time from here: the engines' reading of the pages counts too.
            return try await pdf(data, facts: facts, room: room, by: .now + readingLimit)
        case .word, .openText, .rtf, .epub, .powerPoint, .openPresentation, .excel, .openSpreadsheet, .csv:
            guard let format = engine ?? DocumentFormat(facts.format) else {
                throw DocumentProblem(message: String(localized: "eGlu can't read this kind of file."))
            }
            let whole = try Documents.markdown(data, format: format).markdown
            // What an Office file says of itself; the engines give its words alone.
            let declared = HandoffDocument.declared(in: data)
            if facts.format == .word { facts.pages = declared.pages }
            if facts.format == .powerPoint { facts.slides = declared.slides }
            if facts.format == .excel || facts.format == .openSpreadsheet { facts.sheets = HandoffDocument.sheets(in: whole) }
            facts.title = declared.title
            facts.author = declared.author
            facts.created = declared.created
            let fitted = HandoffDocument.fitted(whole, room: room)
            facts.unread = fitted.unread
            return (fitted.markdown, facts, fitted.truncated)
        case .text:
            let fitted = HandoffDocument.fitted(String(decoding: data, as: UTF8.self), room: room)
            facts.unread = fitted.unread
            return (fitted.markdown, facts, fitted.truncated)
        case .json, .xml:
            // Cut at a line's end, its block closed again, as long text is: a JSON file can be megabytes.
            let block = facts.format == .json ? HandoffDocument.json(data)
                : "```xml\n" + String(decoding: data, as: UTF8.self) + "\n```"
            let fitted = HandoffDocument.fitted(block, room: room)
            return (fitted.markdown, facts, fitted.truncated)
        case .zip:
            return try await archive(data, facts: facts, room: room, into: folder)
        case .picture:
            let (markdown, made) = try await picture(data, facts: facts)
            let fitted = HandoffDocument.fitted(markdown, room: room)
            return (fitted.markdown, made, fitted.truncated)
        case .audio, .video:
            return try await recording(data, facts: facts, room: room, into: folder, telling: telling)
        }
    }

    /// The picture read on the device: its own facts and its thumbnail,
    /// away from the main thread, the text in it by Vision, then what it
    /// shows by the model where the model looks at pictures (iOS 27), for
    /// as long as a page's model is given (HandoffJob's patience). Past
    /// that, or called off, the file has the text and the facts alone:
    /// the first file is not kept from the person for the model's sake.
    private static func picture(_ data: Data, facts: FileFacts) async throws -> (String, FileFacts) {
        guard let decoded = await decoded(data, facts: facts) else {
            throw DocumentProblem(message: String(localized: "The file could not be read."))
        }
        let image = decoded.image
        var facts = decoded.facts
        // Nil where Vision failed: the file says its text could not be read, not that it has none.
        let text = try? await HandoffVision.read(image)
        var description = ""
        let said = await HandoffTime.value(by: .now + describing) { @MainActor () -> String? in
            await PageMinds.mind()?.describe(image)
        }
        if let said, !said.isEmpty {
            description = String(localized: "Described by the on-device model, which can be wrong: \(said)")
            facts.described = true
        }
        return (HandoffPicture.markdown(name: facts.name, description: description, text: text), facts)
    }

    /// How long the model is given to say what a picture shows: as long as
    /// HandoffJob gives it for a page.
    nonisolated static let describing = Duration.seconds(8)

    /// A picture's thumbnail and its own facts, away from the main thread.
    @concurrent
    private static func decoded(_ data: Data, facts: FileFacts) async -> (image: CGImage, facts: FileFacts)? {
        guard let image = HandoffPicture.thumbnail(data), let facts = HandoffPicture.facts(data, into: facts) else { return nil }
        return (image, facts)
    }

    /// The recording read on the device: its duration, its title,
    /// artist and album where the file names them, a video's size, and
    /// the first 15 minutes of its words (HandoffSpeech), written as a
    /// site's transcript is (HandoffDocument.recording). The bytes are
    /// written to the job's folder for AVFoundation to read, away from
    /// the main thread, and the guide is told how far it is (`telling`).
    @concurrent
    private static func recording(_ data: Data, facts: FileFacts, room: Int,
                                  into folder: URL, telling: Handoff.Telling?) async throws -> (String, FileFacts, Bool) {
        var facts = facts
        let ext = (facts.name as NSString).pathExtension
        // A file chosen, dropped or downloaded comes before the job's folder is made, which only a fetch makes.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("recording-\(UUID().uuidString)." + (ext.isEmpty ? "m4a" : ext))
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let asset = AVURLAsset(url: file)
        let seconds = Int(((try? await asset.load(.duration))?.seconds ?? 0).rounded())
        facts.duration = seconds > 0 ? seconds : nil
        for item in (try? await asset.load(.commonMetadata)) ?? [] {
            let value = try? await item.load(.stringValue)
            guard let value, !value.isEmpty else { continue }
            switch item.commonKey {
            case .commonKeyTitle: facts.title = value
            case .commonKeyArtist: facts.author = value
            case .commonKeyAlbumName: facts.album = value
            default: continue
            }
        }
        if facts.format == .video,
           let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize), size.width > 0, size.height > 0 {
            facts.width = Int(size.width)
            facts.height = Int(size.height)
        }
        let heard = await HandoffSpeech.transcribe(file, seconds: TimeInterval(seconds), in: folder) { progress in
            switch progress {
            case .model: telling?(.speechModel)
            case .minutes(let done, let of): telling?(.transcribing(done: done, of: of))
            }
        }
        var transcript: Transcript?
        var unheard: HandoffDocument.Unheard?
        switch heard {
        case .success(let said):
            facts.transcribed = seconds > 0 ? min(said.seconds, seconds) : said.seconds
            facts.language = said.language
            // What was not heard, past 15 minutes or past the time, is said at the transcript's end.
            transcript = Transcript(lines: said.lines, cut: said.seconds + 30 < seconds, generated: true)
        case .failure(.language): unheard = .language
        case .failure(.permission): unheard = .permission
        case .failure(.silence): unheard = .silence
        }
        let markdown = HandoffDocument.recording(name: facts.name, transcript: transcript, unheard: unheard, room: room)
        // Not cut to fit: the minutes not heard are said in the first half (Handoff.document) and at the transcript's end.
        return (markdown, facts, false)
    }

    /// The archive's files, each read as its kind under a heading with
    /// its name, in what room is left; the rest in skipped with why
    /// (HandoffArchive.walk), or named as left out where the room runs
    /// out. What is known of each file read goes in `within`, so a PDF's
    /// pages read from pictures are said of it as of a PDF on its own.
    /// Encrypted or ZIP64: "eGlu can't open this archive."
    @concurrent
    private static func archive(_ data: Data, facts: FileFacts, room: Int,
                                into folder: URL) async throws -> (String, FileFacts, Bool) {
        var facts = facts
        guard HandoffArchive.opens(data) else {
            throw DocumentProblem(message: String(localized: "eGlu can't open this archive."))
        }
        let (read, skipped) = HandoffArchive.walk(ZipFile.contents(of: data)) {
            FileFormat(ext: ($0 as NSString).pathExtension) != nil
        }
        facts.skipped = skipped
        var parts: [String] = [], size = 0
        var cut = false
        for (index, name) in read.enumerated() {
            // A heading's room and a little: past that, the files left are named as not in this file.
            let left = room - size - name.count - 8
            guard left > 200, !Task.isCancelled else {
                facts.unread += read[index...]
                break
            }
            guard let inside = ZipFile.file(in: data, matching: { $0 == name }) else {
                facts.skipped.append("\(name) (could not be read)")
                continue
            }
            // Detected first, as for the file itself (a .docx's own mark).
            let engine = (try? await detect(inside)) ?? DocumentFormat(ext: (name as NSString).pathExtension)
            let inner = FileFacts(format: engine.flatMap(FileFormat.init)
                                      ?? FileFormat(ext: (name as NSString).pathExtension) ?? .text,
                                  name: name, bytes: inside.count)
            guard let got = try? await markdown(inside, facts: inner, engine: engine, room: left, into: folder) else {
                facts.skipped.append("\(name) (could not be read)")
                continue
            }
            facts.entries.append(name)
            facts.within.append(got.1)
            cut = cut || got.2
            // A picture's own heading is its name again: the entry's heading stands for it.
            var body = got.0
            if body.hasPrefix("# \(name)\n") { body = String(body.dropFirst(name.count + 3)) }
            let part = "## \(name)\n\n" + body
            parts.append(part)
            size += part.count + 2
        }
        let fitted = HandoffDocument.fitted(parts.joined(separator: "\n\n"), room: room)
        facts.unread = fitted.unread + facts.unread
        return (fitted.markdown, facts, fitted.truncated || cut || !facts.unread.isEmpty)
    }

    /// A PDF's first pages, each's Markdown in order, and the first 30
    /// that are only pictures read on the device by Vision (Decided 6
    /// and 7). Nothing is begun past `deadline`, nor waited for past it,
    /// nor once the handoff is called off: the pages from there are named
    /// as not read, as those past the first 300 and past `room` are.
    @concurrent
    private static func pdf(_ data: Data, facts: FileFacts, room: Int, by deadline: ContinuousClock.Instant) async throws
        -> (String, FileFacts, Bool) {
        var facts = facts
        let whole = try Documents.pdfPages(data, pages: Array(0..<pageLimit))
        facts.pages = whole.pageCount
        facts.title = whole.title
        facts.author = whole.author
        facts.created = whole.created
        let last = min(whole.pageCount, pageLimit)
        var notRead = whole.pageCount > pageLimit ? Array(pageLimit + 1...whole.pageCount) : []
        var truncated = !notRead.isEmpty
        var parts: [String] = []
        var size = 0
        var pictures = 0
        var document: PDFDocument?
        for page in whole.pages {
            let number = page.page + 1
            guard ContinuousClock.now < deadline, !Task.isCancelled else {
                truncated = true
                notRead += Array(number...max(number, last))
                break
            }
            var markdown = page.markdown
            if page.needsOCR {
                pictures += 1
                markdown = ""
                if pictures <= visionLimit {
                    if document == nil { document = PDFDocument(data: data) }
                    if let image = document.flatMap({ HandoffVision.draw($0, page: page.page) }) {
                        markdown = await HandoffTime.value(by: deadline) { (try? await HandoffVision.read(image)) ?? "" } ?? ""
                    }
                }
                guard !markdown.isEmpty else {
                    notRead.append(number)
                    continue
                }
            }
            if size + markdown.count > room {
                truncated = true
                notRead += Array(number...max(number, last))
                break
            }
            if page.needsOCR { facts.readFromPictures.append(number) }
            if !markdown.isEmpty { parts.append(markdown) }
            size += markdown.count + 2
        }
        facts.notRead = Array(Set(notRead)).sorted()
        return (parts.joined(separator: "\n\n"), facts, truncated)
    }

    /// What the guide can say, by what went wrong.
    private static func words(for kind: EngineError.Kind) -> String {
        switch kind {
        case .encrypted: return String(localized: "This file is protected by a password.")
        case .unsupported: return String(localized: "eGlu can't read this kind of file.")
        case .tooLarge: return String(localized: "This file is too large to read.")
        default: return String(localized: "The file could not be read.")
        }
    }

    /// Why a file was not read: the engines', or the limit's.
    struct DocumentProblem: Error {
        let message: String
    }
}

extension FileFormat {
    /// The file's kind from the kind the tab said it holds: a PDF, a
    /// text, CSV, JSON, XML or picture page ("application/ld+json" is JSON
    /// too; SVG is not read — the web view draws it and Vision can't).
    init?(mimeType: String) {
        switch mimeType {
        case "application/pdf": self = .pdf
        case "text/plain": self = .text
        case "text/csv": self = .csv
        case "application/json": self = .json
        case "application/xml", "text/xml": self = .xml
        default:
            if mimeType.hasSuffix("+json") { self = .json }
            else if mimeType.hasSuffix("+xml") { self = .xml }
            else if mimeType.hasPrefix("image/"), mimeType != "image/svg+xml" { self = .picture }
            else if mimeType.hasPrefix("audio/") { self = .audio }
            else if mimeType.hasPrefix("video/") { self = .video }
            else { return nil }
        }
    }

    /// The file's kind from the format the engines detected.
    nonisolated init?(_ format: DocumentFormat) {
        switch format {
        case .doc, .docx: self = .word
        case .odt: self = .openText
        case .pdf: self = .pdf
        case .ppt, .pptx: self = .powerPoint
        case .rtf: self = .rtf
        case .epub: self = .epub
        case .excel: self = .excel
        case .ods: self = .openSpreadsheet
        case .odp: self = .openPresentation
        case .csv: self = .csv
        }
    }

    /// The format by the file's extension, where the bytes say nothing:
    /// CSV, JSON, XML, plain text and ZIP, and the engines' own.
    nonisolated init?(ext: String) {
        switch ext.lowercased() {
        case "pdf": self = .pdf
        case "doc", "docx", "docm": self = .word
        case "odt": self = .openText
        case "rtf": self = .rtf
        case "epub": self = .epub
        case "ppt", "pptx": self = .powerPoint
        case "odp": self = .openPresentation
        case "xls", "xlsx", "xlsm": self = .excel
        case "ods": self = .openSpreadsheet
        case "csv": self = .csv
        case "json": self = .json
        case "xml": self = .xml
        case "txt", "text", "md", "markdown": self = .text
        case "zip": self = .zip
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tif", "tiff": self = .picture
        case "mp3", "m4a", "aac", "wav", "aif", "aiff", "ogg", "oga", "flac", "caf", "opus": self = .audio
        case "mp4", "mov", "m4v", "webm", "mkv", "avi": self = .video
        default: return nil
        }
    }
}

extension DocumentFormat {
    /// The engines' format by the file's extension, where the bytes say
    /// nothing the engines know: CSV always, and a file too short or
    /// damaged to tell.
    nonisolated init?(ext: String) {
        switch ext.lowercased() {
        case "pdf": self = .pdf
        case "doc": self = .doc
        case "docx", "docm": self = .docx
        case "odt": self = .odt
        case "rtf": self = .rtf
        case "epub": self = .epub
        case "ppt": self = .ppt
        case "pptx": self = .pptx
        case "odp": self = .odp
        case "xls", "xlsx", "xlsm": self = .excel
        case "ods": self = .ods
        case "csv": self = .csv
        default: return nil
        }
    }

    /// The engines' format for a file format, where they read one. It is
    /// never detected from bytes for CSV, and never asked for the rest.
    nonisolated init?(_ format: FileFormat) {
        switch format {
        case .word: self = .docx
        case .openText: self = .odt
        case .pdf: self = .pdf
        case .powerPoint: self = .pptx
        case .rtf: self = .rtf
        case .epub: self = .epub
        case .excel: self = .excel
        case .openSpreadsheet: self = .ods
        case .openPresentation: self = .odp
        case .csv: self = .csv
        case .json, .xml, .text, .zip, .picture, .audio, .video: return nil
        }
    }
}
