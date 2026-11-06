import CoreGraphics
import Foundation
import FoundationModels
import PadCore

/// What the model is asked about a page for a handoff: what it reads
/// (Handoff.brief), from the fullest to the shortest, the shorter ones for
/// a prompt that turned out too long, and whether it is also to pick parts
/// of the page.
struct PageQuestion {
    let briefs: [String]
    let picks: Bool
}

/// Apple Intelligence's on-device model, asked once for a handoff what the
/// page on screen is: its kind, a sentence or two on it, and which of its
/// parts say the most (Handoff.kindInstructions, pickInstructions). The
/// model is on the device, and nothing it reads leaves it.
///
/// A thing of Handoff's own, apart from the address bar's use of the model
/// (Intelligence.swift): another question, another answer, and a session
/// for each handoff with nothing kept between them.
///
/// Only on iOS and iPadOS 26 and later, on a device with Apple Intelligence
/// turned on, and Handoff is offered only there (Session.hasIntelligence).
/// While the model is spared, a handoff tells the page's kind by counting.
@MainActor
protocol PageMind: AnyObject {
    /// Whether the model is there to be asked now: the device has Apple
    /// Intelligence, it is turned on, and its model has come.
    func isThere() async -> Bool

    /// `picture` is asked for a small picture of the page only where the
    /// model looks at pictures (iOS 27) and `looks` says this page is worth
    /// one. Nil when it couldn't say: a refusal, a language it doesn't
    /// have, a handoff called off.
    ///
    /// `writing` hears the summary as the model writes it, word by word,
    /// for the sheet to show (HandoffGuide); empty again where a try is
    /// given up and the next begins.
    func read(_ question: PageQuestion, looks: Bool, picture: @MainActor () async -> CGImage?,
              writing: @escaping @MainActor (String) -> Void) async -> PageAnswer?

    /// What the model sees in a picture handed off, for someone who can't
    /// see it. Nil where the model doesn't look at pictures (before iOS
    /// 27, or a device without the capability): a picture file is still
    /// read, of its text and its own facts.
    func describe(_ picture: CGImage) async -> String?
}

enum PageMinds {
    /// The one way to the model, kept for the app's life: looking the
    /// model up takes a moment the first time and none after.
    @MainActor private static var kept: PageMind?

    /// The model, where it is there to be asked for this handoff. Nil
    /// before iOS 26, on a device without Apple Intelligence or with it
    /// turned off, while its model is still coming, and while the model is
    /// spared. Asked before the sheet comes up, which says who organises
    /// the page: Apple Intelligence where this is not nil, the app alone
    /// where it is.
    ///
    /// The first look is the system's and takes as long as it takes, so it
    /// is waited for a second and a half and no longer: a tap on Handoff
    /// must bring its sheet. Past that the handoff goes without the model,
    /// and the next one finds what the look came to.
    @MainActor static func mind() async -> PageMind? {
        guard #available(iOS 26.0, *), !spares else { return nil }
        let mind = kept ?? OnDevicePageMind()
        kept = mind
        let there = await first(within: patience) { await mind.isThere() }
        return there ? mind : nil
    }

    private static let patience: Duration = .milliseconds(1_500)

    /// Whether the device has Apple Intelligence to ask: iOS 26 or later,
    /// a device that has it, turned on, and its model come. Handoff is
    /// offered only where it has (Session.hasIntelligence). Low Power Mode
    /// and a hot device are not counted: Handoff stays, and the model is
    /// left alone for the while (spares).
    ///
    /// Asked away from the main thread and at a low priority: the
    /// framework's first use reads what the device can do and loads
    /// libraries of its own. The model itself is not loaded.
    static func intelligence() async -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        return await Task.detached(priority: .utility) { SystemLanguageModel.default.isAvailable }.value
    }

    /// What `asked` comes to, or false if it has not come to anything in
    /// time. `asked` is left to finish by itself: it is not ours to stop.
    @MainActor private static func first(within patience: Duration, _ asked: @escaping @MainActor () async -> Bool) async -> Bool {
        let once = Once()
        return await withCheckedContinuation { continuation in
            once.answer = { continuation.resume(returning: $0) }
            Task { @MainActor in once.give(await asked()) }
            Task { @MainActor in
                try? await Task.sleep(for: patience)
                once.give(false)
            }
        }
    }

    /// An answer given once, by whichever of two comes first. On the main actor, so no two give at once.
    @MainActor private final class Once {
        var answer: ((Bool) -> Void)?

        func give(_ value: Bool) {
            answer?(value)
            answer = nil
        }
    }

    /// Whether the model is left alone for now: in Low Power Mode, and
    /// while the device says it is hot. Running a language model is the
    /// most the app ever asks of the device, and what it adds to a handoff
    /// is an extra: the page's kind is still told by counting.
    static var spares: Bool {
        let process = ProcessInfo.processInfo
        return process.isLowPowerModeEnabled || process.thermalState == .serious || process.thermalState == .critical
    }
}

@available(iOS 26.0, *)
@MainActor
private final class OnDevicePageMind: PageMind {
    /// The system's model, once it has been looked up, away from the main
    /// thread: the framework's first use reads what the device can do and
    /// loads libraries of its own.
    private var model: SystemLanguageModel?

    /// How many tokens the brief may be: the model reads 4,096 at once,
    /// its instructions, the shape of its answer, a picture and the answer
    /// itself among them.
    private static let room = 2_400

    private func found() async -> SystemLanguageModel? {
        if model == nil {
            model = await Task.detached(priority: .userInitiated) { SystemLanguageModel.default }.value
        }
        guard let model, model.isAvailable else { return nil }
        return model
    }

    func isThere() async -> Bool {
        await found() != nil
    }

    func read(_ question: PageQuestion, looks: Bool, picture: @MainActor () async -> CGImage?,
              writing: @escaping @MainActor (String) -> Void) async -> PageAnswer? {
        guard let model = await found() else { return nil }
        var briefs = question.briefs
        // Counted where the system counts, so that no try is spent on
        // finding out: the fullest that fits and those shorter, or the
        // shortest where none is known to.
        if #available(iOS 26.4, macOS 26.4, *) {
            var fitting: [String] = []
            for brief in briefs {
                if let tokens = try? await model.tokenCount(for: brief), tokens > Self.room { continue }
                fitting.append(brief)
            }
            briefs = fitting.isEmpty ? Array(briefs.suffix(1)) : fitting
        }
        guard let first = briefs.first, !Task.isCancelled else { return nil }
        var shown: CGImage?
        if #available(iOS 27.0, macOS 27.0, *), looks, model.capabilities.contains(.vision) { shown = await picture() }

        // With the picture, then without it, then with less to read: the
        // first that answers. A session each, since one that failed keeps
        // what it was asked.
        var tries: [(brief: String, picture: CGImage?)] = shown.map { [(first, $0)] } ?? []
        tries += briefs.map { ($0, nil) }
        for attempt in tries {
            guard !Task.isCancelled else { return nil }
            writing("")
            if let answer = await ask(model, attempt.brief, picture: attempt.picture, picks: question.picks, writing: writing) {
                return answer
            }
        }
        writing("")
        return nil
    }

    /// Streamed, so the summary can be shown as it is written: the answer
    /// is the same as the whole of it at once, the sampling being greedy.
    /// The summary comes first in the answer's shape, ahead of the kind
    /// and the picks, so it is what is written first.
    private func ask(_ model: SystemLanguageModel, _ brief: String, picture: CGImage?, picks: Bool,
                     writing: @escaping @MainActor (String) -> Void) async -> PageAnswer? {
        let instructions = Handoff.kindInstructions + (picks ? Handoff.pickInstructions : "")
        let session = LanguageModelSession(model: model, instructions: instructions)
        let options = GenerationOptions(samplingMode: .greedy)
        if picks {
            let stream: LanguageModelSession.ResponseStream<PageReadWithPicks>
            if #available(iOS 27.0, macOS 27.0, *), let picture {
                stream = session.streamResponse(generating: PageReadWithPicks.self, options: options) {
                    brief
                    Attachment(picture)
                }
            } else {
                stream = session.streamResponse(to: brief, generating: PageReadWithPicks.self, options: options)
            }
            guard let reply = await Self.follow(stream, saying: { $0.about }, to: writing), !Task.isCancelled else { return nil }
            return PageAnswer(kind: reply.kind.kind, about: reply.about,
                              picks: reply.picks.map { PageAnswer.Pick(number: $0.number, name: $0.name) })
        }
        let stream: LanguageModelSession.ResponseStream<PageRead>
        if #available(iOS 27.0, macOS 27.0, *), let picture {
            stream = session.streamResponse(generating: PageRead.self, options: options) {
                brief
                Attachment(picture)
            }
        } else {
            stream = session.streamResponse(to: brief, generating: PageRead.self, options: options)
        }
        guard let reply = await Self.follow(stream, saying: { $0.about }, to: writing), !Task.isCancelled else { return nil }
        return PageAnswer(kind: reply.kind.kind, about: reply.about)
    }

    /// An answer as it is written: what it says so far of the page to
    /// `writing`, as each part of it comes, and the whole of it at the
    /// end. Nil where it stops short: a refusal, a handoff called off.
    private static func follow<Content: Generable>(_ stream: LanguageModelSession.ResponseStream<Content>,
                                                   saying about: (Content.PartiallyGenerated) -> String?,
                                                   to writing: @MainActor (String) -> Void) async -> Content? {
        var last: GeneratedContent?
        do {
            for try await snapshot in stream {
                guard !Task.isCancelled else { return nil }
                last = snapshot.rawContent
                if let said = about(snapshot.content) { writing(said) }
            }
        } catch {
            return nil
        }
        guard let last else { return nil }
        return try? Content(last)
    }

    func describe(_ picture: CGImage) async -> String? {
        guard #available(iOS 27.0, macOS 27.0, *), let model = await found(),
              model.capabilities.contains(.vision), !Task.isCancelled else { return nil }
        let session = LanguageModelSession(model: model, instructions: Handoff.pictureInstructions)
        let options = GenerationOptions(samplingMode: .greedy)
        let reply = try? await session.respond(generating: PictureRead.self, options: options) {
            Attachment(picture)
        }.content
        guard let reply, !Task.isCancelled else { return nil }
        return Handoff.described(reply.shown)
    }
}

/// What the model sees in a picture handed off (PageMind.describe): plain
/// words, no Markdown.
@available(iOS 26.0, *)
@Generable
struct PictureRead {
    @Guide(description: "What the picture shows, in two or three plain sentences")
    var shown: String
}

/// What the model makes of a page for a handoff. What it is comes first:
/// having said that, the model picks the kind that fits its own words.
@available(iOS 26.0, *)
@Generable
struct PageRead {
    /// Four kinds, though Handoff knows eight: the model is right less
    /// often the more it has to choose from, and the other four are told
    /// by how a page is built (Handoff.kind).
    @Generable
    enum Kind {
        case article
        case landing
        case app
        case other

        var kind: PageKind {
            switch self {
            case .article: return .article
            case .landing: return .landing
            case .app: return .app
            case .other: return .other
            }
        }
    }

    @Guide(description: "Two or three plain sentences, in the language the page is written in: what the page is for, then its main points with the names, numbers and prices it gives. Only what is given. No Markdown")
    var about: String

    @Guide(description: "The kind of page: article, landing, app or other")
    var kind: Kind
}

/// A part the model picks from the list it was given: its name first,
/// which is what makes it look for the line, then the line's number.
@available(iOS 26.0, *)
@Generable
struct PagePick {
    @Guide(description: "The part's name, copied from the list")
    var name: String

    @Guide(description: "The part's number in the list")
    var number: Int
}

/// The same answer with the parts picked, on a page where parts would
/// otherwise only be started (Handoff.candidates).
@available(iOS 26.0, *)
@Generable
struct PageReadWithPicks {
    @Guide(description: "Two or three plain sentences, in the language the page is written in: what the page is for, then its main points with the names, numbers and prices it gives. Only what is given. No Markdown")
    var about: String

    @Guide(description: "The kind of page: article, landing, app or other")
    var kind: PageRead.Kind

    @Guide(description: "Up to three parts from the list that say the most about what the page offers. Empty when none stands out",
           .maximumCount(3))
    var picks: [PagePick]
}
