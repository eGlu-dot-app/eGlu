import os
import PadCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One handoff being made ready (Handoff.swift): the page read, its kind
/// told, the file written. How far it is is one value (Handoff.Stage),
/// which the browser acts on and the sheet shown meanwhile draws.
///
/// The file is written twice at the most. First as soon as the page has
/// been read, with its kind told by counting (Handoff.kind), which takes no
/// time to speak of: the share sheet can show from then on. Then again if
/// Apple Intelligence's model, asked meanwhile, says more: the kind as it
/// reads the page, a sentence on what the page is, and which of the parts
/// that were only started say the most. The model takes
/// seconds: they are spent on a sheet that says what Handoff does
/// (HandoffGuide), which goes on to the share sheet when the model has
/// answered. Whoever goes on sooner is choosing an app while it works, and
/// gets the file as it stands when the app is picked (HandoffFile).
///
/// Each of the two is one task, run in order on the main actor, with only
/// the writing itself away from it. The model is also given a time: a task
/// group would wait for the model to notice it was called off, which takes
/// it seconds, so the time is a task of its own that sets the stage and
/// leaves the model to wind down behind it.
@MainActor
@Observable
final class HandoffJob {
    private(set) var stage: Handoff.Stage = .reading
    /// The words that go beside the file: a question to start from, and the page's address.
    let prompt: String
    let file: URL
    /// The page handed off, and what it was called: what the Mac's pane says
    /// it is about, another tab being free to be on screen meanwhile. Nil
    /// for a file on the device, which has no address.
    let page: URL?
    let pageTitle: String
    /// Whether what is handed off is a file and not a page, which the
    /// guide's words say.
    let isFile: Bool
    /// Whether it goes with its name and no address: a file on the device
    /// (Handoff.prompt(file:)), which the guide's words say too.
    var named: Bool { isFile && page == nil }
    /// The space it was asked for in, whose History keeps it once an app has taken it.
    let space: UUID

    /// This handoff's own folder, so that taking it away takes nothing of the next one's.
    private let folder: URL
    /// Whether the person had something selected on the page: it goes first, and the sheet says so.
    private(set) var selected = false
    /// Whether what is said in the page's recording was got from its site and is in the file, which the sheet says too.
    private(set) var transcribed = false
    /// Whether Apple Intelligence's model is asked about the page, which
    /// the sheet says: where it is not there, the app organises the page
    /// alone, by counting. Nor is it asked of a page with next to nothing
    /// to read (Handoff.leastToSum), which is known once the page is read.
    private(set) var asksModel: Bool
    private(set) var modelNote: String?
    /// What the file holds, for the sheet to list as it is made (Handoff.Outline):
    /// nil until the page is read, and told again when the file is written again.
    private(set) var outline: Handoff.Outline?
    /// The model's summary as the sheet shows it, word by word as it is written.
    private(set) var summary: HandoffSummary
    /// How many of the page's pictures were read on the device so far.
    private(set) var picturesRead = 0
    /// The page as it showed when it was handed off, small, for the sheet's
    /// card. Nil for a file, and until the picture comes.
    private(set) var preview: CGImage?
    @ObservationIgnored private var source: (any HandoffSource)?
    @ObservationIgnored private var sourceMind: PageMind?
    @ObservationIgnored private var drafting: Task<Void, Never>?
    @ObservationIgnored private var organising: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    /// Whether an app has been given the file, after which it is not
    /// written again. Asked from the thread that writes and set from the
    /// one the share sheet prepares its items on, hence the lock. It is
    /// held while the file is written again (rewrite): an app picked just
    /// then waits the moment that takes, and is given the file as it will
    /// stay, never one that is swapped for another under it.
    private let given = OSAllocatedUnfairLock(initialState: false)

    /// Where the files of handoffs are kept.
    private static let shelf = FileManager.default.temporaryDirectory.appendingPathComponent("Handoff", isDirectory: true)
    /// The folders of handoffs not yet over, by name: another window's may
    /// be at its share sheet when this one writes. Behind a lock, and asked
    /// as each old folder is looked at, away from the main thread: one
    /// begun after this write set out is one of them too, and stays.
    private static let live = OSAllocatedUnfairLock(initialState: Set<String>())
    /// How long the model is given. A page it has not read by then goes as counted.
    private static let patience: Duration = .seconds(8)
    /// How long there is where a site's own reader is asked as well, which
    /// may have a page to load out of sight (a video's transcript on a phone).
    private static let longPatience: Duration = .seconds(14)
    /// A page with less text than this, in characters, is looked at as
    /// well as read, where the model looks at pictures: its words say too
    /// little, and a picture costs the model about as long again as the
    /// words do.
    private static let littleText = 1_500

    init(source: any HandoffSource, mind: PageMind?, space: UUID) {
        self.space = space
        let address = source.address
        let title = source.title
        isFile = source.isFile
        prompt = address.map { Handoff.prompt(url: $0) } ?? Handoff.prompt(file: title)
        page = address
        pageTitle = title.isEmpty ? (address.map(Destination.pretty) ?? title) : title
        folder = Self.shelf.appendingPathComponent(UUID().uuidString, isDirectory: true)
        file = folder.appendingPathComponent(
            source.isFile ? Handoff.fileName(file: title)
                : Handoff.fileName(title: title, url: address ?? Self.fileAddress))
        // A file's kind is told by its format, never asked of the model.
        asksModel = mind != nil && !source.isFile
        summary = mind != nil && !source.isFile ? .waiting : .none
        self.source = source
        sourceMind = source.isFile ? nil : mind
        if !asksModel, !source.isFile {
            modelNote = ProcessInfo.processInfo.isLowPowerModeEnabled
                ? String(localized: "Apple Intelligence is paused in Low Power Mode. eGlu formats the file locally.")
                : String(localized: "Apple Intelligence is unavailable for this page. eGlu formats the file locally.")
        }
        let name = folder.lastPathComponent
        Self.live.withLock { _ = $0.insert(name) }
        drafting = Task { [weak source] in
            await self.draft(of: source)
        }
        // The page's picture for the card, beside the reading: one look, while the page is still.
        if !source.isFile {
            Task { [weak self, weak source] in
                let picture = await source?.picture(pixels: Self.previewPixels)
                self?.preview = picture
            }
        }
    }

    /// How wide the card's picture of the page is, in pixels.
    private static let previewPixels = 240

    /// Where no address is to be had: a file on the device has none.
    private static let fileAddress = URL(fileURLWithPath: "/")

    func retry() {
        guard case .failed = stage else { return }
        // Asked again once the page is read, as the first time (draft).
        asksModel = sourceMind != nil
        summary = sourceMind != nil ? .waiting : .none
        stage = .reading
        drafting = Task { [weak source] in
            await self.draft(of: source)
        }
    }
    func shareAddressOnly() {
        asksModel = false
        summary = .none
        modelNote = !isFile ? String(localized: "You chose to share only the page's address. Its content is not included.")
            : named ? String(localized: "You chose to share only the file's name. Its content is not included.")
            : String(localized: "You chose to share only the file's address. Its content is not included.")
        stage = .addressOnly
    }

    /// Waits until there is a first file to give, or it is known there is none.
    func drafted() async {
        await drafting?.value
    }

    /// The handoff is over: its share sheet has closed, its guide was put
    /// away, or another handoff has taken its place. What is still under
    /// way is called off, and a file no app took is removed, once nothing
    /// is writing it any more. A file an app took is kept in the space's
    /// History (HistoryRecorder.keep); its folder stays live until it is
    /// copied there, so the next handoff's first write can't empty it from
    /// the shelf before. Words that went alone, with no file, are not kept.
    func finish(taken: Bool) {
        let name = folder.lastPathComponent
        let keeps = taken && stage.hasFile
        if !keeps { Self.live.withLock { _ = $0.remove(name) } }
        // A file still fetched or read (a PDF's pages by Vision) stops too, and is not waited out.
        drafting?.cancel()
        organising?.cancel()
        deadline?.cancel()
        if !stage.isSettled { stage = .stopped }
        // Nothing is written any more: no place is held for it.
        if summary == .waiting { summary = .none }
        if case .writing = summary { summary = .none }
        if keeps {
            // Kept as it went: nothing writes it again from now on.
            give()
            let (file, space, title, address) = (file, space, pageTitle, page)
            Task {
                await HistoryRecorder.shared.keep(handoff: file, space: space, title: title, address: address)
                Self.live.withLock { _ = $0.remove(name) }
            }
        }
        guard !taken else { return }
        let writers = [drafting, organising]
        let folder = folder
        Task {
            for writer in writers { await writer?.value }
            await Self.remove(folder)
        }
    }

    /// The file is being given to an app, on the thread its share is
    /// prepared on: from now on it stays as it is.
    nonisolated func give() {
        given.withLock { $0 = true }
    }

    // MARK: The two steps

    /// When the page was read, which the file says.
    @ObservationIgnored private var read = Date()

    /// Reads the source — the page, or the file — and writes the first
    /// file, organised for the kind the count tells or the file's format
    /// gave, then has the model asked where there is one to ask.
    private func draft(of source: (any HandoffSource)?) async {
        // A recording's transcription says how far it is as it goes, the guide's line under the file step,
        // in a tab as from a file: the page passes it to the document it reads. Never once the job is called off.
        let telling: Handoff.Telling = { [weak self] said in
            guard let self, self.stage.isReading else { return }
            self.stage = said
        }
        let outcome = await source?.reading(limit: Handoff.limit, into: folder, telling: telling) ?? .failed(nil)
        read = Date()
        // Called off while the page was read: nothing is written.
        guard stage.isReading else { return }
        let reading: PageReading
        switch outcome {
        case .content(let content): reading = content
        case .noReadableContent: asksModel = false; summary = .none; stage = .wordsOnly; return
        case .protectedPage(let reason):
            asksModel = false
            summary = .none
            modelNote = reason ?? String(localized: "This page is protected from reading. Only its address can be shared.")
            stage = .addressOnly
            return
        case .failed(let reason):
            asksModel = false
            summary = .none
            modelNote = reason
            stage = .failed(.reading)
            return
        }
        selected = reading.hasSelection
        // A file on the device has no address: its file says "File:" and its name, not "Source:".
        let address = source?.address
        let url = address ?? Self.fileAddress
        let title = pageTitle
        let facts = source?.file
        let counted = facts?.format.kind ?? Handoff.kind(of: reading, url: url)
        let composed = Handoff.compose(reading, kind: counted)
        let text = Handoff.document(title: title, url: address, composed: composed, reading: reading,
                                    file: facts, read: read)
        let written = await Self.write(text, to: file, in: folder, emptying: Self.shelf, but: Self.live)
        guard stage.isReading else { return }
        guard written else {
            asksModel = false
            summary = .none
            stage = .failed(.writing)
            return
        }
        outline = Handoff.outline(of: composed, reading: reading)
        // With next to nothing read the model has nothing to go by: what it wrote of such a page was the
        // page's description over again, or a guess, and it took its seconds over it.
        let mind = reading.facts.characters >= Handoff.leastToSum ? sourceMind : nil
        asksModel = mind != nil
        summary = mind != nil ? .waiting : .none
        if mind == nil, sourceMind != nil { modelNote = String(localized: "This page has too little text for Apple Intelligence. eGlu formatted it locally.") }
        // What is still to come: the model's answer, what the site's own reader can add (a video's transcript),
        // and the page's large pictures with nothing said of them, whose text is read with or without the model.
        let adds = (source as? Page)?.adapter.reader.isEmpty == false
        let looks = source is Page && !reading.pictures.isEmpty
        guard mind != nil || adds || looks else {
            stage = .ready(counted)
            return
        }
        stage = .organising(counted: counted)
        looked = nil
        let patience = adds ? Self.longPatience : Self.patience
        // The pictures' own time ends a moment before the job's, so what they gave is there when it ends.
        let pictureTime = ContinuousClock.now + patience - .seconds(1)
        organising = Task { [weak source] in
            await self.organise(reading, counted: counted, with: mind, adding: adds, looking: source, at: url, titled: title,
                                pictures: pictureTime)
        }
        deadline = Task {
            try? await Task.sleep(for: patience)
            guard !Task.isCancelled, self.stage.isOrganising else { return }
            self.organising?.cancel()
            if self.asksModel { self.summary = .dropped }
            self.asksModel = false
            self.modelNote = String(localized: "Apple Intelligence or the site's reader did not finish in time. The file uses eGlu's local format without a model summary.")
            // What the page's pictures gave in their time goes, though the model's answer did not come.
            if let looked = self.looked, looked.count > 0 {
                let composed = Handoff.compose(looked.reading, kind: counted)
                let text = Handoff.document(title: title, url: address, composed: composed,
                                            reading: looked.reading, file: facts, pictures: looked.count,
                                            described: looked.described, read: self.read)
                if await Self.rewrite(text, at: self.file, unless: self.given) {
                    self.outline = Handoff.outline(of: composed, reading: looked.reading)
                }
            }
            self.stage = .ready(counted)
        }
    }

    /// The page's pictures as read in their time (pictures), for the file
    /// the job's time writes where the model's answer did not come.
    @ObservationIgnored private var looked: (reading: PageReading, count: Int, described: Int)?

    /// Asks the model what the page is and, where it is asked that too
    /// (Handoff.asksForPicks), which of the parts that would only be
    /// started say the most; and has the site's own reader asked for what
    /// it can add, a video's transcript (Page.transcript). Side by side:
    /// neither waits for the other, and the model is shown the page as it
    /// was read, without the transcript, which made its summaries worse.
    /// If either says anything, the file is written again: for the kind
    /// as settled between the count and the model, with the parts it
    /// picked whole and its summary, and with the transcript at the end.
    ///
    /// The page's pictures are read beside both (pictures), by `time`.
    private func organise(_ reading: PageReading, counted: PageKind, with mind: PageMind?, adding: Bool,
                          looking source: (any HandoffSource)?, at url: URL, titled title: String,
                          pictures time: ContinuousClock.Instant) async {
        let candidates = Handoff.asksForPicks ? Handoff.candidates(in: reading, kind: counted) : []
        // Only a page has a site's reader to ask, and a page can be sent to the task the question waits in.
        let page = source as? Page
        async let said = adding ? page?.transcript(limit: Handoff.limit) : nil
        async let seen = pictures(reading, on: page, by: time)
        var answer: PageAnswer?
        if let mind {
            let briefs = Handoff.briefs(title: title, url: url, reading: reading, candidates: candidates)
            let question = PageQuestion(briefs: briefs, picks: !candidates.isEmpty)
            answer = await mind.read(question, looks: reading.facts.characters < Self.littleText, picture: { [weak source] in
                await source?.picture(pixels: 512)
            }, writing: { [weak self] said in
                // As it would go: plain words on one line. Not once the job is out of time or called off.
                guard let self, self.stage.isOrganising, self.asksModel else { return }
                let line = Handoff.hardened(said)
                self.summary = line.isEmpty ? .waiting : .writing(line)
            })
        }
        let transcript = await said
        let (shown, picturesRead, described) = await seen
        // Called off or out of time meanwhile: whichever it was has set the stage.
        guard !Task.isCancelled, stage.isOrganising else { return }
        deadline?.cancel()
        if mind != nil, answer == nil {
            asksModel = false
            summary = .dropped
            modelNote = String(localized: "Apple Intelligence did not return a result. The file uses eGlu's local format without a model summary.")
        }
        guard answer != nil || transcript != nil || picturesRead > 0 else {
            stage = .ready(counted)
            return
        }
        let whole = transcript.map { shown.adding($0) } ?? shown
        let kind = Handoff.settled(counted: counted, answer: answer, facts: reading.facts, url: url)
        let composed = Handoff.compose(whole, kind: kind, promoted: Handoff.promoted(answer?.picks ?? [], among: candidates))
        let text = Handoff.document(title: title, url: source?.address, composed: composed, reading: whole,
                                    file: source?.file, summary: answer?.about, pictures: picturesRead, described: described, read: read)
        let written = await Self.rewrite(text, at: file, unless: given)
        // Asked again after the wait: it may have been called off while the file was written.
        guard stage.isOrganising else { return }
        transcribed = written && whole.spoken != nil
        if written { outline = Handoff.outline(of: composed, reading: whole) }
        // As the file has it, where the file has it: what the page bears out of what the model wrote.
        if let about = answer?.about {
            let made = written ? Handoff.fileSummary(about, reading: whole, title: title) : ""
            summary = made.isEmpty ? .dropped : .written(made)
        }
        if !written {
            asksModel = false
            modelNote = String(localized: "Additional context could not be saved. The original context file is still ready to share.")
        }
        stage = .ready(written ? kind : counted)
    }

    /// The page's largest pictures with no words of their own, read on
    /// the device (Decided 6): the first four fetched from the site
    /// (HandoffFetch) and thumbnailed, the text in all of them read at
    /// once (HandoffVision), then what they show described one at a time
    /// (PageMind.describe), all by `time`: what is not done by then is
    /// not waited for, and what is done is kept (looked). The reading
    /// comes back with what was read written into its blocks
    /// (PageReading.shown), and how many pictures were read.
    private func pictures(_ reading: PageReading, on page: Page?, by time: ContinuousClock.Instant) async -> (PageReading, Int, Int) {
        guard !reading.pictures.isEmpty, let page else { return (reading, 0, 0) }
        let folder = folder
        var found: [(read: PagePicture.Read, image: CGImage)] = []
        await withTaskGroup(of: (PagePicture.Read, CGImage)?.self) { group in
            for picture in reading.pictures.prefix(4) {
                group.addTask { await Self.read(picture, on: page, into: folder, by: time) }
            }
            for await one in group {
                if let one { found.append(one) }
            }
        }
        guard !Task.isCancelled, !found.isEmpty else { return (reading, 0, 0) }
        var described = 0
        // Only a picture something was read of counts as read: one with no text and no description adds nothing to the file.
        func read() -> Int { found.filter { !$0.read.text.isEmpty || !$0.read.description.isEmpty }.count }
        looked = (reading.shown(found.map(\.read)), read(), 0)
        picturesRead = read()
        for index in found.indices {
            guard !Task.isCancelled, ContinuousClock.now < time else { break }
            let image = found[index].image
            let said = await HandoffTime.value(by: time) { @MainActor [weak self] () -> String? in
                await self?.sourceMind?.describe(image)
            }
            guard let said, !said.isEmpty else { continue }
            found[index].read.description = said
            described += 1
            looked = (reading.shown(found.map(\.read)), read(), described)
            picturesRead = read()
        }
        return (reading.shown(found.map(\.read)), read(), described)
    }

    /// One of a page's pictures fetched through its tab, its thumbnail
    /// made and the text in it read, by `time`: nil where it isn't.
    private static func read(_ picture: PagePicture, on page: Page, into folder: URL,
                             by time: ContinuousClock.Instant) async -> (PagePicture.Read, CGImage)? {
        await HandoffTime.value(by: time) { @MainActor () -> (PagePicture.Read, CGImage)? in
            guard let file = try? await HandoffFetch.fetch(picture.address, with: page.downloadStarter, into: folder),
                  let image = await thumbnail(of: file) else { return nil }
            let text = (try? await HandoffVision.read(image)) ?? ""
            return (PagePicture.Read(address: picture.address, text: text, block: picture.block), image)
        }
    }

    /// A page's picture as a file in the job's folder is no bigger than this to be read: it is
    /// read whole before its thumbnail is made, and four of them at once.
    nonisolated private static let pictureLimit = 20_000_000

    /// The picture's thumbnail (HandoffPicture), away from the main thread, where it is not too large to read.
    @concurrent
    private static func thumbnail(of file: URL) async -> CGImage? {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int.max
        guard size <= pictureLimit, let data = try? Data(contentsOf: file) else { return nil }
        return HandoffPicture.thumbnail(data)
    }

    // MARK: Writing, away from the main thread

    /// The first file, in a folder of its own. The shelf is emptied before
    /// it of every handoff that is over: the file of the handoff before
    /// stays until now, since the app it went to may still have been
    /// reading it when the sheet closed. Those of handoffs still under
    /// way (`live`) stay: another window's share sheet may be open.
    @concurrent
    private static func write(_ text: String, to file: URL, in folder: URL, emptying shelf: URL,
                              but live: OSAllocatedUnfairLock<Set<String>>) async -> Bool {
        let files = FileManager.default
        for old in (try? files.contentsOfDirectory(at: shelf, includingPropertiesForKeys: nil)) ?? [] {
            let name = old.lastPathComponent
            // A handoff is live before its folder is made, so a folder seen here that was made since is seen live.
            guard !live.withLock({ $0.contains(name) }) else { continue }
            try? files.removeItem(at: old)
        }
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// The file again, unless an app has it by now: asked and written
    /// under the lock, so that it can't be given between the two.
    @concurrent
    private static func rewrite(_ text: String, at file: URL, unless given: OSAllocatedUnfairLock<Bool>) async -> Bool {
        let data = Data(text.utf8)
        return given.withLock { given in
            guard !given else { return false }
            return (try? data.write(to: file, options: .atomic)) != nil
        }
    }

    @concurrent
    private static func remove(_ folder: URL) async {
        try? FileManager.default.removeItem(at: folder)
    }
}

#if canImport(UIKit)
/// The file of a handoff, for the share sheet. It is asked for when an app
/// is picked, which is how the job hears that the file is given
/// (HandoffJob.give): while the share sheet is open the model may still be
/// reading, and the file may still be written again; under the app that
/// reads it, it may not.
///
/// An operation, which the share sheet runs on a thread of its own: what it
/// keeps is set once and never changed.
nonisolated final class HandoffFile: UIActivityItemProvider, @unchecked Sendable {
    private let file: URL
    private let give: @Sendable () -> Void

    @MainActor
    init(_ job: HandoffJob) {
        file = job.file
        give = { job.give() }
        super.init(placeholderItem: job.file)
    }

    override var item: Any {
        // Asked by an app that was picked, not for the sheet's own look at the file.
        if activityType != nil { give() }
        return file
    }
}
#endif

/// The model's summary as the sheet shows it (HandoffGuide): the words as
/// the model writes them, then as they go in the file.
enum HandoffSummary: Equatable {
    /// The model is not asked: the sheet has no place for a summary.
    case none
    /// Asked, and nothing written yet.
    case waiting
    /// What the model has written so far, as it would go: plain, on one line.
    case writing(String)
    /// As it goes in the file (Handoff.fileSummary).
    case written(String)
    /// None goes: the model did not answer, or not in time, or nothing it
    /// wrote was borne out by the page. The job's note says which.
    case dropped
}

/// What Handoff does, said while it does it: a sheet over the page while
/// the page is read and, where Apple Intelligence's model is there, while
/// the model reads it (HandoffJob), which is seconds. The wait is spent on
/// what is handed off, shown as it is made, the way Arc Search shows a page
/// it sums up: the page on a card that says how far the handoff is, the
/// model's summary as the model writes it, then what the file holds, part
/// by part, in the page's own words (Handoff.Outline).
///
/// Every place is held from the start, a part not there yet drawn as a
/// shape where it will be, so what comes fills it and the rest stays put.
/// The share sheet comes at the sheet's button and not by itself: what is
/// shared is the person's to send. The button stands at the sheet's foot,
/// under what scrolls, to be had once the file is as it will go; until
/// then it is there and dimmed. Where the model is not asked (Low Power
/// Mode, a hot device, a page with next to nothing to read) there is no
/// summary, and the button is to be had as soon as the page is read. A
/// device without Apple Intelligence has no Handoff at all
/// (Session.hasIntelligence).
struct HandoffGuide: View {
    /// Nil while a file is only being chosen: the guide then offers
    /// "Choose File…" and, on the Mac, a file dropped on it.
    let job: HandoffJob?
    let colour: SpaceColor
    /// The room under what the sheet ends with: `edge`, as beside it, or
    /// none where the sheet stands on the screen's own room for the home
    /// indicator, which is about as much.
    let foot: CGFloat
    /// Its corners: the sheet's on iPad and iPhone, the Mac pane's there.
    var corners: Corners = .sheet
    /// Opens the file picker, when no job is shown (chosen-file mode).
    var pick: (() -> Void)? = nil
    /// On to the share sheet.
    let go: () -> Void

    /// The corner of what it stands in. What is drawn as a surface near its
    /// edge stands `edge` in from it with a corner of `inner`, so the two
    /// curves run side by side: the corner inside and the room around it
    /// come to the corner outside.
    struct Corners: Sendable {
        let outer: CGFloat
        let edge: CGFloat
        var inner: CGFloat { outer - edge }

        /// The iPad's and iPhone's sheet.
        static let sheet = Corners(outer: 32, edge: 16)
    }

    static let corner = Corners.sheet.outer
    static let edge = Corners.sheet.edge
    /// Words stand further in than surfaces do.
    fileprivate static let indent: CGFloat = 8
    /// How high the Mac's pane is while a handoff is shown: what the
    /// handoff holds scrolls in it, so the pane stays the size it came up.
    private static let paneHeight: CGFloat = 540

    /// Whether the sheet has come up: its parts arrive one after another.
    @State private var arrived = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Whether there is something to share as it will go: the file, or for
    /// a page with nothing to read the words alone.
    private var canShare: Bool {
        job?.stage.progress(of: .choose) == .working
    }

    var body: some View {
        Group {
            if let job {
                jobContent(job)
            } else {
                // As high as what it says. Where that is more than the screen has (large text), it scrolls.
                ViewThatFits(in: .vertical) {
                    chooseContent
                    ScrollView {
                        chooseContent
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
        }
        .tint(colour.color)
        .animation(.bar, value: job?.stage)
        .animation(.bar, value: job?.outline)
        .sensoryFeedback(.success, trigger: job?.stage) { _, now in
            if case .ready = now { true } else { false }
        }
        .onAppear {
            arrived = true
        }
        .onChange(of: canShare) { _, can in
            // The person's own step is all that is left: said, for whoever does not see the card change.
            guard can, let job else { return }
            AccessibilityNotification.Announcement(job.stage.headline(ofFile: job.isFile, named: job.named) + ". "
                + job.stage.detail(selected: job.selected, transcribed: job.transcribed, ofFile: job.isFile, named: job.named)).post()
        }
    }

    /// The chooser, while no job is shown: a file to hand off instead.
    private var chooseContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Handoff File"))
                    .font(.title2.bold())
                    .tracking(-0.3)
                Text(String(localized: "Give an assistant this file's context."))
                    .font(.body)
                    .foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, Self.indent)
            .padding(.bottom, 24)
            .arriving(0, arrived, plainly: reduceMotion)
            Button { pick?() } label: {
                Text(String(localized: "Choose File…"))
                    .font(.headline)
                    .foregroundStyle(colour.ink)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(colour.color, in: RoundedRectangle(cornerRadius: corners.inner, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
            .keyboardShortcut(.defaultAction)
            .arriving(1, arrived, plainly: reduceMotion)
            Text("Nothing is sent until you pick an app.")
                .font(.footnote)
        }
    }

    private func jobContent(_ job: HandoffJob) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.isFile ? String(localized: "Handoff File") : String(localized: "Handoff"))
                            .font(.title2.bold())
                            .tracking(-0.3)
                        Text(job.isFile ? String(localized: "Give an assistant this file's context.")
                             : String(localized: "Give an assistant this page's context."))
                            .font(.body)
                            .foregroundStyle(Palette.muted)
                    }
                    .padding(.horizontal, Self.indent)
                    .padding(.bottom, 20)
                    .arriving(0, arrived, plainly: reduceMotion)
                    SourceCard(job: job, colour: colour, corner: corners.inner, lively: !reduceMotion)
                        .arriving(1, arrived, plainly: reduceMotion)
                    if job.summary != .none {
                        SummaryView(summary: job.summary, note: job.modelNote, colour: colour, lively: !reduceMotion)
                            .padding(.horizontal, Self.indent)
                            .padding(.top, 24)
                            .transition(.opacity)
                            .arriving(2, arrived, plainly: reduceMotion)
                    }
                    if job.outline != nil || job.stage.isReading {
                        ContentsView(job: job, colour: colour, lively: !reduceMotion)
                            .padding(.top, 28)
                            .transition(.opacity)
                            .arriving(3, arrived, plainly: reduceMotion)
                    }
                    if case .failed(let failure) = job.stage {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(failure.message(ofFile: job.isFile)).foregroundStyle(.red)
                            Button("Try Again") { job.retry() }
                            // A file on the device goes with its name, there being no address to share.
                            Button(job.named ? String(localized: "Share Name Only") : String(localized: "Share Address Only")) {
                                job.shareAddressOnly()
                            }
                        }
                        .padding(.horizontal, Self.indent)
                        .padding(.top, 20)
                    }
                    // Where there is a summary, its place says why none came (SummaryView).
                    if let note = job.modelNote, job.summary == .none {
                        Text(note)
                            .font(.callout)
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, Self.indent)
                            .padding(.top, 20)
                    }
                }
                .padding(.horizontal, corners.edge)
                .padding(.top, 30)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            // What scrolls on under the button fades out there rather than being cut off.
            .mask {
                VStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 20)
                }
            }
            VStack(spacing: 10) {
                Button(action: go) {
                    Text("Handoff")
                        .font(.headline)
                        .foregroundStyle(colour.ink)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(colour.color, in: RoundedRectangle(cornerRadius: corners.inner, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScale())
                .keyboardShortcut(.defaultAction)
                .disabled(!canShare)
                // Dimmed until there is something to share: in its place from the start, so nothing moves when it is.
                .opacity(canShare ? 1 : 0.35)
                Text("Nothing is sent until you pick an app.")
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, corners.edge)
            .padding(.top, 4)
            .padding(.bottom, foot)
            .arriving(4, arrived, plainly: reduceMotion)
        }
        #if os(macOS)
        .frame(height: Self.paneHeight)
        #endif
    }
}

// MARK: The page, and how far it is

/// The page handed off, as Arc Search shows the page it sums up: a small
/// picture of it beside where it is from and what it is called, and under
/// those how far the handoff is (StatusLine). A file has its kind's mark
/// where a page has its picture.
private struct SourceCard: View {
    let job: HandoffJob
    let colour: SpaceColor
    let corner: CGFloat
    let lively: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            PageThumbnail(preview: job.preview, file: job.isFile)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if job.page != nil {
                        SiteIconView(url: job.page, size: 14)
                            .accessibilityHidden(true)
                    }
                    Text(whereFrom)
                        .font(.footnote)
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
                Text(job.pageTitle)
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                StatusLine(job: job, colour: colour, lively: lively)
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
    }

    /// The site, without its "www.", or for a file on the device, that it is on the device.
    private var whereFrom: String {
        guard let page = job.page, let host = page.host(percentEncoded: false), !host.isEmpty else {
            return String(localized: "On this device")
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// A small picture of the page, its top: the part a person knows it by.
/// Outlined by a hairline of black or white, so a white page keeps its
/// edge on the card. Until the picture comes, or for a file, a mark.
private struct PageThumbnail: View {
    let preview: CGImage?
    let file: Bool

    private static let size = CGSize(width: 56, height: 74)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        ZStack {
            Color.primary.opacity(0.06)
            if let preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
                    .transition(.opacity)
            } else {
                Image(systemName: file ? "doc.text" : "globe")
                    .font(.title3)
                    .foregroundStyle(Palette.muted)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        .animation(.easeOut(duration: 0.3), value: preview != nil)
        .accessibilityHidden(true)
    }
}

/// How far the handoff is, in a line and a second line under it: what is
/// going on, then what the page turned out to be and what of it is shared
/// (Handoff.Stage.headline, detail). The mark beside them is the step at
/// work, in the space's colour and moving, then the kind of page.
private struct StatusLine: View {
    let job: HandoffJob
    let colour: SpaceColor
    let lively: Bool

    var body: some View {
        let stage = job.stage
        let working = !stage.isSettled
        let found = if case .ready = stage { true } else { false }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ZStack {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(working || found ? colour.color : Palette.muted)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: working && lively)
                    .id(symbol)
                    .transition(.swap)
            }
            .frame(minWidth: 18)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(headline)
                    .font(.subheadline.weight(.semibold))
                    .contentTransition(.opacity)
                Text(stage.detail(selected: job.selected, transcribed: job.transcribed, ofFile: job.isFile, named: job.named))
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                    .contentTransition(.opacity)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// While the model reads the page, who is at it, and once its words
    /// come, that it is writing; else what the stage says.
    private var headline: String {
        guard job.stage.isOrganising else { return job.stage.headline(ofFile: job.isFile, named: job.named) }
        guard job.asksModel else { return String(localized: "eGlu is organising it…") }
        if case .writing = job.summary { return String(localized: "Apple Intelligence is writing…") }
        return String(localized: "Apple Intelligence is reading it…")
    }

    /// The step at work, then the kind of page it turned out to be. Its
    /// sparkles are Apple Intelligence's own mark, and stand only where it is at work.
    private var symbol: String {
        switch job.stage {
        case .organising: job.asksModel ? "sparkles" : "list.bullet.indent"
        case .reading, .speechModel, .transcribing, .stopped: "doc.text"
        default: job.stage.symbol
        }
    }
}

private extension Handoff.Stage {
    /// What the page turned out to be, by a symbol.
    var symbol: String {
        switch self {
        case .reading, .organising, .stopped, .speechModel, .transcribing: "doc.text.magnifyingglass"
        case .ready(.article): "newspaper"
        case .ready(.landing): "megaphone"
        case .ready(.app): "macwindow"
        case .ready(.product): "tag"
        case .ready(.thread): "bubble.left.and.bubble.right"
        case .ready(.listing): "list.bullet"
        case .ready(.media): "play.rectangle"
        case .ready(.job): "briefcase"
        case .ready(.document): "doc.richtext"
        case .ready(.picture): "photo"
        case .ready(.recording): "waveform"
        case .ready(.slides): "rectangle.on.rectangle"
        case .ready(.spreadsheet): "tablecells"
        case .ready(.data): "curlybraces"
        case .ready(.archive): "archivebox"
        case .ready(.other): "globe"
        case .wordsOnly, .addressOnly: "link"
        case .failed: "exclamationmark.triangle"
        }
    }
}

// MARK: The summary

/// The model's summary as it is written, as Arc Search writes the summary
/// of a page under it: three lines' room held from the start, shapes in it
/// until the first words come, the words as they come with a sparkle where
/// the next will go, then the summary as the file has it. Where none goes,
/// why, in its place.
private struct SummaryView: View {
    let summary: HandoffSummary
    let note: String?
    let colour: SpaceColor
    let lively: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .foregroundStyle(colour.color)
                Text("Summary by Apple Intelligence")
                    .foregroundStyle(Palette.muted)
            }
            .font(.footnote.weight(.semibold))
            ZStack(alignment: .topLeading) {
                if holdsRoom {
                    // Three lines of the summary's own size, so that what is written fills them and nothing under them moves.
                    Text(verbatim: "\n\n")
                        .font(.body)
                        .hidden()
                }
                switch summary {
                case .waiting:
                    SkeletonLines(lively: lively)
                        .transition(.opacity)
                case .writing(let said):
                    Text("\(said) \(Text(Image(systemName: "sparkle")).foregroundStyle(colour.color))")
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                case .written(let said):
                    Text(said)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .transition(.opacity)
                case .dropped:
                    Text(note ?? String(localized: "No summary goes with this file."))
                        .font(.callout)
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                case .none:
                    EmptyView()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Summary by Apple Intelligence"))
        .accessibilityValue(spoken)
    }

    private var holdsRoom: Bool {
        switch summary {
        case .waiting, .writing: true
        case .none, .written, .dropped: false
        }
    }

    /// Not read out word by word while it is written: that it is, then the whole of it.
    private var spoken: String {
        switch summary {
        case .waiting, .writing: String(localized: "Being written")
        case .written(let said): said
        case .dropped: note ?? String(localized: "No summary goes with this file.")
        case .none: ""
        }
    }
}

/// Where words will be, as shapes: three lines of a paragraph, the last short.
private struct SkeletonLines: View {
    let lively: Bool
    @ScaledMetric(relativeTo: .body) private var line: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: line - 12) {
            Capsule().frame(maxWidth: .infinity)
            Capsule().frame(maxWidth: .infinity).padding(.trailing, 24)
            Capsule().frame(maxWidth: .infinity).padding(.trailing, 120)
        }
        .frame(height: line * 3 - (line - 12), alignment: .top)
        .foregroundStyle(Palette.wash)
        .padding(.top, (line - 12) / 2)
        .modifier(Pulsing(lively: lively))
        .accessibilityHidden(true)
    }
}

// MARK: What the file holds

/// What goes in the file, part by part, as Arc Search lists the points of
/// a page it sums up: a mark in the space's colour on a light ground of it, the part's heading,
/// and the words it begins with. The person's selection first, then the
/// page's parts in their order, what was read of its pictures and its
/// transcript, and last, greyed, what was set aside: named in the file
/// with its size, and not in it. Shapes stand where the parts will be
/// while the page is read.
private struct ContentsView: View {
    let job: HandoffJob
    let colour: SpaceColor
    let lively: Bool

    /// How many of the page's parts are listed; the rest are counted.
    private static let listed = 5
    /// How many of what was set aside are named.
    private static let asides = 3

    struct Row: Identifiable, Equatable {
        let id: String
        let symbol: String
        let title: String
        var detail = ""
        var tag: String?
        /// Greyed: set aside, named in the file and not in it, or parts only counted.
        var quiet = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("In the file")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, HandoffGuide.indent)
            if let outline = job.outline {
                ForEach(Array(rows(of: outline).enumerated()), id: \.element.id) { order, row in
                    OutlineRow(row: row, colour: colour)
                        .transition(.rising(order: order, lively: lively))
                }
            } else {
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonRow(lively: lively)
                        .transition(.opacity)
                }
            }
        }
    }

    private func rows(of outline: Handoff.Outline) -> [Row] {
        var rows: [Row] = []
        if !outline.selection.isEmpty {
            rows.append(Row(id: "selection", symbol: "text.quote", title: String(localized: "Your selection"),
                            detail: outline.selection, tag: String(localized: "Goes first")))
        }
        let sections = outline.sections
        let alone = sections.count == 1 && sections[0].heading.isEmpty
        for (index, section) in sections.prefix(Self.listed).enumerated() {
            let title = !section.heading.isEmpty ? section.heading
                : alone ? (job.isFile ? String(localized: "The file's text") : String(localized: "The page's text"))
                : String(localized: "Introduction")
            rows.append(Row(id: "part-\(index)", symbol: section.shape.symbol, title: title, detail: section.opening,
                            tag: section.started ? String(localized: "Beginning only") : nil))
        }
        if sections.count > Self.listed {
            rows.append(Row(id: "more", symbol: "ellipsis", title: String(localized: "\(sections.count - Self.listed) more parts"), quiet: true))
        }
        if job.picturesRead > 0 {
            rows.append(Row(id: "pictures", symbol: "photo", title: String(localized: "Pictures"),
                            detail: String(localized: "\(job.picturesRead) read on this device")))
        }
        if outline.transcript || job.transcribed {
            rows.append(Row(id: "transcript", symbol: "captions.bubble", title: String(localized: "Transcript"),
                            detail: String(localized: "What the recording says, at the end of the file")))
        }
        for (index, aside) in outline.asides.prefix(Self.asides).enumerated() {
            rows.append(Row(id: "aside-\(index)", symbol: "eye.slash", title: Self.name(of: aside),
                            detail: String(localized: "Set aside, \(aside.characters.formatted()) characters"), quiet: true))
        }
        return rows
    }

    /// What the reader calls a part it set aside, in the person's language;
    /// a heading of the page's own as the page has it.
    private static func name(of aside: Handoff.Aside) -> String {
        switch aside.name {
        case "Comments": String(localized: "Comments")
        case "Related": String(localized: "Related")
        case "Legal": String(localized: "Legal")
        case "Footer": String(localized: "Footer")
        case "A list of links": String(localized: "A list of links")
        default: aside.name
        }
    }
}

private extension Handoff.Outline.Shape {
    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .list: "list.bullet"
        case .table: "tablecells"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .quote: "quote.opening"
        case .picture: "photo"
        }
    }
}

/// One part of what the file holds: its mark, its heading with what is
/// said of it at the side, and the words it begins with.
private struct OutlineRow: View {
    let row: ContentsView.Row
    let colour: SpaceColor

    @ScaledMetric(relativeTo: .headline) private var size: CGFloat = 28

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // The space's colour on a light ground of the same colour, as the sheet's other marks at work had it:
            // light enough that a list of them does not outweigh the words beside it.
            ZStack {
                Circle()
                    .fill(row.quiet ? Palette.wash : colour.color.opacity(0.16))
                Image(systemName: row.symbol)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(row.quiet ? Palette.muted : colour.color)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.title)
                        .font(.headline)
                        .foregroundStyle(row.quiet ? Palette.muted : Color.primary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if let tag = row.tag {
                        Text(tag)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Palette.muted)
                            .fixedSize()
                            .transition(.opacity)
                    }
                }
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(.subheadline)
                        .foregroundStyle(Palette.muted)
                        .lineLimit(2)
                }
            }
            // The title's line stands at the middle of the mark.
            .padding(.top, (size - 22) / 2)
        }
        .padding(.horizontal, HandoffGuide.indent)
        .accessibilityElement(children: .combine)
    }
}

/// Where a part will be listed, as shapes, while the page is read.
private struct SkeletonRow: View {
    let lively: Bool
    @ScaledMetric(relativeTo: .headline) private var size: CGFloat = 28

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .frame(width: size, height: size)
            VStack(alignment: .leading, spacing: 9) {
                Capsule().frame(width: 120, height: 13)
                Capsule().frame(maxWidth: .infinity).frame(height: 11)
            }
            .padding(.top, 6)
        }
        .foregroundStyle(Palette.wash)
        .padding(.horizontal, HandoffGuide.indent)
        .modifier(Pulsing(lively: lively))
        .accessibilityHidden(true)
    }
}

/// Shapes standing for what is still to come, breathing: lighter and back.
/// Still under Reduce Motion.
private struct Pulsing: ViewModifier {
    let lively: Bool

    func body(content: Content) -> some View {
        if lively {
            content.phaseAnimator([1.0, 0.45]) { shown, opacity in
                shown.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 0.9)
            }
        } else {
            content
        }
    }
}

// MARK: Motion

/// A part of the sheet as it arrives: a little lower, clear and soft, then
/// in place, each part a moment after the one above it. Only a fade under
/// Reduce Motion.
private struct Arriving: ViewModifier {
    let order: Int
    let arrived: Bool
    let plainly: Bool

    func body(content: Content) -> some View {
        content
            .opacity(arrived ? 1 : 0)
            .offset(y: arrived || plainly ? 0 : 10)
            .blur(radius: arrived || plainly ? 0 : 4)
            .animation(.spring(duration: 0.45, bounce: 0).delay(0.08 + Double(order) * 0.08), value: arrived)
    }
}

private extension View {
    func arriving(_ order: Int, _ arrived: Bool, plainly: Bool) -> some View {
        modifier(Arriving(order: order, arrived: arrived, plainly: plainly))
    }
}

/// A row of what the file holds as it comes: as the sheet's parts arrive,
/// a little lower, clear and soft, each a moment after the one above.
private struct Rising: ViewModifier {
    let away: Bool

    func body(content: Content) -> some View {
        content
            .opacity(away ? 0 : 1)
            .offset(y: away ? 10 : 0)
            .blur(radius: away ? 4 : 0)
    }
}

/// A symbol as it takes another's place: from small, clear and soft.
private struct Swapping: ViewModifier {
    let away: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(away ? 0.25 : 1)
            .opacity(away ? 0 : 1)
            .blur(radius: away ? 4 : 0)
    }
}

private extension AnyTransition {
    static var swap: AnyTransition {
        .modifier(active: Swapping(away: true), identity: Swapping(away: false))
    }

    /// In by `order`, 60 milliseconds apart; out at once, by a quick fade.
    /// Only a fade under Reduce Motion.
    static func rising(order: Int, lively: Bool) -> AnyTransition {
        let coming: AnyTransition = lively ? .modifier(active: Rising(away: true), identity: Rising(away: false)) : .opacity
        return .asymmetric(insertion: coming.animation(.spring(duration: 0.35, bounce: 0).delay(Double(order) * 0.06)),
                           removal: .opacity.animation(.easeOut(duration: 0.15)))
    }
}
