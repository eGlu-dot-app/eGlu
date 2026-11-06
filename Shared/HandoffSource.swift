import CoreGraphics
import Foundation
import PadCore

/// What a handoff is of. A file is a source like a page: the page on
/// screen is one kind of source (Page), a document another
/// (DocumentSource). Everything after the reading, compose, the document,
/// the file, the model, the guide and the share sheet, is one path for
/// both (HandoffJob).
@MainActor
protocol HandoffSource: AnyObject {
    /// Its address for "Source:" and the prompt (Handoff.prompt); nil for
    /// a file on the device.
    var address: URL? { get }
    /// What it is called, which the file's heading and name say.
    var title: String { get }
    /// Whether what is handed off is a file and not a page, which the
    /// guide's words say.
    var isFile: Bool { get }
    /// What is known of the file (FileFacts); nil for a page.
    var file: FileFacts? { get }
    /// Its text and how it is organised, as a page's reader gives them.
    /// `folder`: the job's, for a file fetched to be read (HandoffFetch);
    /// `telling` hears how far a long read is, a recording's transcript.
    func reading(limit: Int, into folder: URL, telling: Handoff.Telling?) async -> Handoff.ReadOutcome
    /// What its site's own reader can add, a video's transcript; nil for a file.
    func transcript(limit: Int) async -> Transcript?
    /// A picture of it for the model to look at; nil for a file, which is read.
    func picture(pixels: Int) async -> CGImage?
}

extension Handoff {
    /// How far a long read has got, for the guide (HandoffJob): a
    /// recording's speech model fetched, the minutes of it transcribed.
    typealias Telling = @MainActor @Sendable (Handoff.Stage) -> Void
}

extension Page: HandoffSource {
    #if os(macOS)
    // The engine page's own address and title (WebKit's, read through the plugin).
    var address: URL? { state.url }
    var title: String { state.title ?? "" }
    #else
    var address: URL? { view.url }
    var title: String { view.title ?? "" }
    #endif
    var isFile: Bool { false }
    /// A PDF read as a document is a file's facts (handoffDocument).
    var file: FileFacts? { handoffDocument?.file }

    /// The page as its own reader gives it (PageShared.readingForHandoff).
    func reading(limit: Int, into folder: URL, telling: Handoff.Telling?) async -> Handoff.ReadOutcome {
        await readingForHandoff(limit: limit, into: folder, telling: telling)
    }

    /// The page as it shows, for the model to look at (HandoffJob).
    func picture(pixels: Int) async -> CGImage? {
        #if os(macOS)
        return await picture(pixels: CGFloat(pixels))
        #else
        return await preview(width: CGFloat(pixels) / max(1, view.traitCollection.displayScale))?.cgImage
        #endif
    }
}
