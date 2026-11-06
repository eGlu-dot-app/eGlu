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
    }

    /// Where no address is to be had: a file on the device has none.
    private static let fileAddress = URL(fileURLWithPath: "/")

    func retry() {
        guard case .failed = stage else { return }
        stage = .reading
        drafting = Task { [weak source] in
            await self.draft(of: source)
        }
    }
    func shareAddressOnly() {
        asksModel = false
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
        case .noReadableContent: asksModel = false; stage = .wordsOnly; return
        case .protectedPage(let reason):
            asksModel = false
            modelNote = reason ?? String(localized: "This page is protected from reading. Only its address can be shared.")
            stage = .addressOnly
            return
        case .failed(let reason):
            asksModel = false
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
        let text = Handoff.document(title: title, url: address, composed: Handoff.compose(reading, kind: counted), reading: reading,
                                    file: facts, read: read)
        let written = await Self.write(text, to: file, in: folder, emptying: Self.shelf, but: Self.live)
        guard stage.isReading else { return }
        guard written else {
            asksModel = false
            stage = .failed(.writing)
            return
        }
        // With next to nothing read the model has nothing to go by: what it wrote of such a page was the
        // page's description over again, or a guess, and it took its seconds over it.
        let mind = reading.facts.characters >= Handoff.leastToSum ? sourceMind : nil
        asksModel = mind != nil
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
            self.asksModel = false
            self.modelNote = String(localized: "Apple Intelligence or the site's reader did not finish in time. The file uses eGlu's local format without a model summary.")
            // What the page's pictures gave in their time goes, though the model's answer did not come.
            if let looked = self.looked, looked.count > 0 {
                let text = Handoff.document(title: title, url: address, composed: Handoff.compose(looked.reading, kind: counted),
                                            reading: looked.reading, file: facts, pictures: looked.count,
                                            described: looked.described, read: self.read)
                _ = await Self.rewrite(text, at: self.file, unless: self.given)
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
            answer = await mind.read(question, looks: reading.facts.characters < Self.littleText) { [weak source] in
                await source?.picture(pixels: 512)
            }
        }
        let transcript = await said
        let (shown, picturesRead, described) = await seen
        // Called off or out of time meanwhile: whichever it was has set the stage.
        guard !Task.isCancelled, stage.isOrganising else { return }
        deadline?.cancel()
        if mind != nil, answer == nil {
            asksModel = false
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

/// What Handoff does, said while it does it: a sheet over the page while
/// the page is read and, where Apple Intelligence's model is there, while
/// the model reads it (HandoffJob), which is seconds, so the wait is spent
/// on something worth reading.
///
/// The sheet's three points are the handoff's three steps (Handoff.Step),
/// and how far the handoff is shows on them: a step done has a tick, the
/// one at work its own symbol in colour and moving, and a line down the
/// side fills as they go. Under the step that organises, a card says what is
/// going on with this page and how long it takes, then what the page turned
/// out to be and what of it will be shared.
///
/// The share sheet comes at the sheet's button and not by itself: what is
/// shared is the person's to send. The button is to be had once the file
/// is as it will go, which the card says; until then it is there and
/// dimmed, so that nothing moves when it can be pressed. Where the model is
/// not asked (Low Power Mode, a hot device, a page with next to nothing to
/// read) the second step says the app organises the page, and the button
/// is to be had as soon as the page is read. A device without Apple
/// Intelligence has no Handoff at all (Session.hasIntelligence).
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
    private static let indent: CGFloat = 8

    /// Whether the sheet has come up: its parts arrive one after another.
    @State private var arrived = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Whether there is something to share as it will go: the file, or for
    /// a page with nothing to read the words alone.
    private var canShare: Bool {
        job?.stage.progress(of: .choose) == .working
    }

    var body: some View {
        // As high as what it says. Where that is more than the screen has
        // (large text), it scrolls, the button with it.
        ViewThatFits(in: .vertical) {
            content
            ScrollView {
                content
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .tint(colour.color)
        .animation(.bar, value: job?.stage)
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

    @ViewBuilder private var content: some View {
        if let job { jobContent(job) } else { chooseContent }
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
            .padding(.bottom, 24)
            .arriving(0, arrived, plainly: reduceMotion)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Handoff.Step.allCases, id: \.self) { step in
                    StepRow(step: step, asksModel: job.asksModel, progress: job.stage.progress(of: step),
                            stage: step == .organise ? job.stage : nil, selected: job.selected, transcribed: job.transcribed,
                            file: job.isFile, named: job.named, colour: colour, lively: !reduceMotion)
                        .arriving(step.rawValue + 1, arrived, plainly: reduceMotion)
                }
            }
            .padding(.horizontal, Self.indent)
            .padding(.bottom, 22)
            if case .failed(let failure) = job.stage {
                Text(failure.message(ofFile: job.isFile)).foregroundStyle(.red).padding(.bottom, 8)
                Button("Try Again") { job.retry() }.padding(.bottom, 8)
                // A file on the device goes with its name, there being no address to share.
                Button(job.named ? String(localized: "Share Name Only") : String(localized: "Share Address Only")) {
                    job.shareAddressOnly()
                }
                .padding(.bottom, 12)
            }
            if let note = job.modelNote {
                Text(note).font(.callout).foregroundStyle(Palette.muted).padding(.bottom, 12)
            }
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
            .arriving(4, arrived, plainly: reduceMotion)
            Text("Nothing is sent until you pick an app.")
                .font(.footnote)
                .foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                .arriving(5, arrived, plainly: reduceMotion)
        }
        .padding(.horizontal, corners.edge)
        .padding(.top, 30)
        .padding(.bottom, foot)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What the sheet says of each step. Every line is long enough to fill its
/// last line on every iPhone's width, so none ends on a word alone.
private extension Handoff.Step {
    /// `asksModel`: whether Apple Intelligence's model is asked about the
    /// page (HandoffJob.asksModel). Its sparkles are Apple Intelligence's
    /// own mark, and stand only where it is at work.
    func symbol(asksModel: Bool) -> String {
        switch self {
        case .file: "doc.text"
        case .organise: asksModel ? "sparkles" : "list.bullet.indent"
        case .choose: "square.and.arrow.up"
        }
    }

    /// How far up the symbol is moved on its round mark, as a part of the
    /// mark's size. A symbol is set by its outline's middle, and the share
    /// symbol's weight is its box, under a thin arrow: set that way it
    /// sits a point and a half low to the eye, where the tick and the
    /// sparkles sit half a point low (measured on the screen). A point up
    /// puts its weight where theirs is.
    var lift: CGFloat {
        switch self {
        case .choose: 1.0 / 28
        case .file, .organise: 0
        }
    }

    func title(asksModel: Bool) -> String {
        switch self {
        case .file: String(localized: "The context is one file")
        // Who works out what the page is: the model where it is there, the app's own counting where it is not.
        case .organise: asksModel ? String(localized: "Apple Intelligence organises it") : String(localized: "eGlu organises it")
        case .choose: String(localized: "You ask in the app you choose")
        }
    }

    /// `file`: whether what is handed off is a file and not a page,
    /// which the words say.
    func text(file: Bool) -> String {
        switch self {
        case .file:
            file ? String(localized: "eGlu writes the file's text into a Markdown file.")
                : String(localized: "eGlu writes the page's text and its address into a Markdown file.")
        // So with the model and without it: both are on the device.
        case .organise:
            file ? String(localized: "On this device, it works out what kind of file this is and how much of it to send.")
                : String(localized: "On this device, it works out what kind of page this is and how much of it to send.")
        // The question is the person's to ask, there: what goes with the file is the address and a line for it (Handoff.prompt).
        // A Mac shares from a menu, not a sheet.
        case .choose:
            #if os(macOS)
            String(localized: "Pick an assistant in the share menu and ask your question there.")
            #else
            String(localized: "Pick an assistant in the share sheet and ask your question there.")
            #endif
        }
    }
}

/// One step of the handoff: how far it is, on a mark at its side with a
/// line down to the next step, and what the sheet says of it.
private struct StepRow: View {
    let step: Handoff.Step
    /// Whether Apple Intelligence's model is asked, which the step that organises says.
    let asksModel: Bool
    let progress: Handoff.Progress
    /// How far the handoff is, for the step that says so of the page at
    /// hand (StageCard), under what it says of every page.
    let stage: Handoff.Stage?
    /// Whether the person has something selected on the page (Handoff.Stage.detail).
    let selected: Bool
    /// Whether a recording's transcript is in the file (Handoff.Stage.detail).
    let transcribed: Bool
    /// Whether what is handed off is a file and not a page.
    let file: Bool
    /// Whether it goes with its name and no address (HandoffJob.named).
    let named: Bool
    let colour: SpaceColor
    /// Whether the step at work moves (not under Reduce Motion).
    let lively: Bool

    private var isLast: Bool {
        step == Handoff.Step.allCases.last
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 4) {
                StepMark(symbol: step.symbol(asksModel: asksModel), lift: step.lift, progress: progress, colour: colour, lively: lively)
                if !isLast {
                    // In the colour once this step is done: the way to the next is open.
                    Capsule()
                        .fill(progress == .done ? colour.color : Palette.faint)
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title(asksModel: asksModel))
                    .font(.headline)
                Text(step.text(file: file))
                    .font(.subheadline)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let stage {
                    StageCard(stage: stage, selected: selected, transcribed: transcribed, file: file, named: named, colour: colour)
                        .padding(.top, 8)
                }
            }
            // The title's line stands at the middle of the mark, which is the higher of the two.
            .padding(.top, 3)
            .padding(.bottom, isLast ? 0 : 18)
        }
        // As high as its words, which is what the line down the side takes its length from.
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityValue(spoken)
    }

    private var spoken: String {
        switch progress {
        case .done: String(localized: "Done")
        case .working: String(localized: "In progress")
        case .waiting: String(localized: "Next")
        }
    }
}

/// What is going on with the page at hand, or what it turned out to be, and
/// what that means for what is shared (Handoff.Stage.headline, detail): the
/// part of the sheet that changes, set apart on a ground of its own so the
/// eye finds it. A symbol says the same at a glance: a page being looked
/// through, then the kind of page it is, in the space's colour.
private struct StageCard: View {
    let stage: Handoff.Stage
    let selected: Bool
    let transcribed: Bool
    /// Whether what is handed off is a file and not a page.
    let file: Bool
    /// Whether it goes with its name and no address (HandoffJob.named).
    let named: Bool
    let colour: SpaceColor

    private var found: Bool {
        if case .ready = stage { true } else { false }
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Image(systemName: stage.symbol)
                    .font(.body.weight(.medium))
                    .foregroundStyle(found ? colour.color : Palette.muted)
                    .id(stage.symbol)
                    .transition(.swap)
            }
            .frame(minWidth: 24)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(stage.headline(ofFile: file, named: named))
                    .font(.subheadline.weight(.semibold))
                    .contentTransition(.opacity)
                Text(stage.detail(selected: selected, transcribed: transcribed, ofFile: file, named: named))
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                    .contentTransition(.opacity)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

private extension Handoff.Stage {
    /// A symbol for what the card says: a page looked through while it is
    /// read, then the kind of page it turned out to be.
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

/// A step's mark: its symbol on a round ground while it waits, in the
/// space's colour and moving while it is at work, a tick on the colour once
/// it is done.
private struct StepMark: View {
    let symbol: String
    /// How far up the symbol is moved to look centred, as a part of the mark's size (Handoff.Step.lift).
    let lift: CGFloat
    let progress: Handoff.Progress
    let colour: SpaceColor
    let lively: Bool

    @ScaledMetric(relativeTo: .headline) private var size: CGFloat = 28

    var body: some View {
        ZStack {
            Circle()
                .fill(ground)
            if progress == .done {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.46, weight: .bold))
                    .foregroundStyle(colour.ink)
                    .transition(.swap)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(progress == .working ? colour.color : Palette.muted)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: progress == .working && lively)
                    .offset(y: -size * lift)
                    .transition(.swap)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var ground: Color {
        switch progress {
        case .done: colour.color
        case .working: colour.color.opacity(0.16)
        case .waiting: Palette.wash
        }
    }
}

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
}
