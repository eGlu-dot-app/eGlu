import PadCore
import WebEngineCore
import Foundation

// The half of Page.swift both apps share: the iPad's (App/Sources/Page.swift)
// and the Mac's (Mac/Sources/Page.swift) call into pages the same way here,
// each asking HandsOff first (PolicyTests keeps it that way).

/// A page of a site loaded out of sight, read once by the site's own reader
/// and let go: for what the page on screen does not have and another page
/// of the same site does (Page.transcript).
///
/// It is the site as a computer is served it, in the same store as the
/// page on screen, so the site knows the person as it does there and asks
/// no consent twice. It plays nothing: no media starts without a touch,
/// and none can be given. It goes nowhere but the site: a step to any
/// other host ends it, a hands-off host above all. It gets none of the
/// app's scripts, only the reader's one call, and the content blocker's
/// lists where the page on screen has them. It is asked as soon as it has
/// begun to load, and the reader waits in it for what it
/// looks for: all of a video's page takes seconds longer to come.
@MainActor
final class Unseen {
    /// How long the page on screen is given to show its way to what is looked for, in milliseconds.
    static let patienceHere = 1_500
    /// How long a page out of sight is given to begin (its first bytes, after any redirect), and then to
    /// show the way, in milliseconds. It is asked as soon as it has begun, not when all of it has
    /// loaded: a video's page goes on loading for seconds after what is looked for is there.
    private static let start: Duration = .seconds(6)
    private static let patienceThere = 9_000

    private let hidden: any WebHiddenPage
    /// The site it is a page of, and may not leave.
    private let site: SiteAdapter

    init(beside page: Page, of site: SiteAdapter) {
        self.site = site
        hidden = page.hiddenPage { url in
            ["http", "https"].contains(url?.scheme?.lowercased() ?? "") && site.covers(url) && !HandsOff.covers(url)
        }
    }

    /// Loads the page, has the reader called on it, and lets the page go, whatever came of it.
    func transcript(at url: URL, call: String, limit: Int) async -> Transcript? {
        defer { stop() }
        guard !HandsOff.covers(url), await hidden.begin(url, within: Self.start), !Task.isCancelled else { return nil }
        let said = try? await hidden.callInAppWorld(call, arguments: ["limit": limit, "patience": Self.patienceThere])
        if case .read(let transcript) = Transcript.answer(said) { return transcript }
        return nil
    }

    /// The page goes, and whoever waits on its load hears that nothing came of it.
    func stop() { hidden.stop() }
}

extension Page {
    /// The page as Handoff reads it (PageReading): its blocks as Markdown,
    /// each with what the walk knew of it, what was counted for the kind
    /// of page it is, what it declares, and what the person had selected.
    /// markdown.js, run this once, in the app's own world, reading the
    /// page and changing nothing. Never on a hands-off page, bridge or no
    /// bridge. Says why there is nothing to read as text: a picture, a
    /// page that failed. A PDF is read as the document it is.
    func readingForHandoff(limit: Int, into folder: URL, telling: Handoff.Telling? = nil) async -> Handoff.ReadOutcome {
        // The document of an earlier handoff is not this one's: the tab may have gone on to an article since.
        handoffDocument = nil
        guard !HandsOff.covers(pageURL), !HandsOff.covers(committed) else { return .protectedPage() }
        if let mimeType, let declared = FileFormat(mimeType: mimeType) {
            // A file in the tab is a document — a PDF, or a text, CSV,
            // JSON or XML page: fetched through the tab's own web view
            // into the job's folder (its sign-ins come with it) and read
            // as a DocumentSource would read it, never through markdown.js.
            guard let url = pageURL ?? committed else { return .failed() }
            do {
                let fetched = try await HandoffFetch.fetch(url, with: downloadStarter, into: folder)
                let source = DocumentSource(file: fetched, name: (pageTitle ?? fetched.lastPathComponent),
                                            address: url, format: declared)
                handoffDocument = source
                return await source.reading(limit: limit, into: folder, telling: telling)
            } catch { return .failed(String(localized: "The file could not be fetched.")) }
        }
        do {
            let value = try await callInAppWorld(Scripts.markdownCall, arguments: ["limit": limit])
            guard let said = value as? [String: Any], let reading = PageReading(said) else { return .failed() }
            return reading.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .noReadableContent : .content(reading)
        } catch { return .failed() }
    }

    /// What is said in the page's recording, where the site has a reader
    /// of its own that can get it (SiteAdapter.reader: YouTube's presses
    /// the site's "Show transcript" out of sight). Asked of the page on
    /// screen first. Where that page has no way to it and another of the
    /// site's has (the site as a phone is served it shows no transcript),
    /// that other page is loaded out of sight, read and let go (Unseen).
    /// Never on a hands-off page. Nil when there is none to be had in time.
    func transcript(limit: Int) async -> Transcript? {
        guard !HandsOff.covers(pageURL), !HandsOff.covers(committed), let call = Scripts.readerCall(for: adapter) else { return nil }
        let said = try? await callInAppWorld(call, arguments: ["limit": limit, "patience": Unseen.patienceHere])
        let here = Transcript.answer(said)
        if case .read(let transcript) = here { return transcript }
        guard here.looksElsewhere, !Task.isCancelled, let url = adapter.readerPage(for: pageURL), !HandsOff.covers(url) else { return nil }
        let unseen = Unseen(beside: self, of: adapter)
        return await withTaskCancellationHandler {
            await unseen.transcript(at: url, call: call, limit: limit)
        } onCancel: {
            Task { @MainActor in unseen.stop() }
        }
    }
}

/// The content blocker's lists in one page's controller, by identifier: none
/// on a hands-off page, or where Settings or the site's switch turns it off.
struct PageBlocking {
    private(set) var identifiers: [String] = []

    /// Whether the page has ads and trackers blocked.
    var isOn: Bool {
        !identifiers.isEmpty
    }

    /// The content blocker's lists for a document at `url` (ContentBlocker):
    /// WebKit blocks with them from the next load. Never on a hands-off
    /// host, where nothing of the app's may touch the page.
    @MainActor
    mutating func apply(for url: URL?, to target: any WebRuleListTarget) {
        let on = !HandsOff.covers(url) && Session.shared.preferences.blocksContent(onHost: url?.host)
        let lists = on ? ContentBlocker.shared.lists : []
        let ids = lists.map(\.identifier)
        guard ids != identifiers else { return }
        target.replaceAll(with: lists)
        identifiers = ids
    }

    /// The page is closing: its lists go with it.
    @MainActor
    mutating func remove(from target: any WebRuleListTarget) {
        target.replaceAll(with: [])
        identifiers = []
    }
}

/// The main frame's HTTP status, for the developer bar: the status of the
/// document on screen, not of the last answer. It changes when a document
/// commits, so a download keeps the status of the page it came from and a
/// failed load has none; and it is kept with its history item, since a page
/// WebKit brings back from its back-forward cache commits with no answer.
struct PageStatus {
    /// The status of the document on screen; nil for a file, a failed load or one not answered yet.
    private(set) var code: Int?
    /// The answer to the load under way, until it commits.
    private var pending: Int??
    private let byItem = NSMapTable<AnyObject, NSNumber>.weakToStrongObjects()

    /// The main frame's answer, which WebKit will show.
    mutating func answered(_ response: URLResponse) {
        pending = .some((response as? HTTPURLResponse)?.statusCode)
    }

    /// The answer won't be shown: a download, or a load asked again.
    mutating func dropped() {
        pending = nil
    }

    /// A document committed as `item`: its own answer, or, with none, the
    /// one it had when it was first shown.
    mutating func committed(_ item: AnyObject?) {
        if let answer = pending {
            code = answer
            if let item {
                if let answer { byItem.setObject(NSNumber(value: answer), forKey: item) } else { byItem.removeObject(forKey: item) }
            }
        } else {
            code = item.flatMap { byItem.object(forKey: $0)?.intValue }
        }
        pending = nil
    }

    /// The load failed: what is shown is the failure, which has no status.
    mutating func failed() {
        code = nil
        pending = nil
    }
}
