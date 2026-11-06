import WritingServiceKit
import Foundation
import NaturalLanguage
import PadCore
import os

/// The one Harper linter the app keeps: the page's words go to it through
/// writing.js's messages (WritingHandler on the Mac), and Settings ›
/// Writing shapes it. It is made when checking is turned on and dropped
/// when it is turned off, so nothing of Harper's stays in memory for a
/// person who never asked for it.
///
/// What is linted is the person's own typing, sent in the open by the
/// page's script; nothing it answers is kept and nothing leaves the Mac.
@MainActor
final class WritingChecker {
    static let shared = WritingChecker()

    private static let log = Logger(subsystem: "net.taehee.safience", category: "Writing")

    private var grammar: (any GrammarService)?
    /// The settings the linter was made with, to keep a change that makes
    /// no difference from rebuilding its dictionaries.
    private var made: WritingConfiguration?
    /// The last change on its way to the linter (settings, words, a lint
    /// ignored): a lint waits for it, so a word just added or a rule just
    /// turned off already counts in the answer the card's action asks for.
    private var changing: Task<Void, Never>?

    /// A paragraph under this many characters is sent whether its language
    /// can be told or not: short text fools the recognizer.
    private static let languageMinimum = 20

    /// After a change to the settings (SessionPreferences): the linter is
    /// made, remade or dropped, and its first lint's dictionary build is
    /// warmed away from the main actor.
    func preferencesChanged(_ preferences: Preferences) {
        guard preferences.writing else {
            grammar = nil
            made = nil
            changing = nil
            return
        }
        let settings = WritingConfiguration(
            dialect: WritingDialect(rawValue: preferences.writingDialect) ?? .american,
            rules: preferences.writingRules,
            words: WritingWords.load())
        guard settings != made else { return }
        made = settings
        if grammar != nil {
            configure(settings)
            return
        }
        do {
            grammar = try Self.engine.makeService(settings)
        } catch {
            Self.log.error("grammar engine would not start: \(String(describing: error))")
            return
        }
        let grammar = self.grammar
        // warmUp is slow (the dictionary's search structure) and runs on the
        // engine's own actor, so the wait never touches the main one.
        Task {
            do { try await grammar?.warmUp() } catch {
                Self.log.error("grammar engine would not warm up: \(String(describing: error))")
            }
        }
    }

    /// The lints for a field's text, each an English paragraph at a time:
    /// text between line breaks whose dominant language Apple's recognizer
    /// says is not English (a guess surer than 0.6) is not sent, so a
    /// paragraph of Korean draws no English underlines. Offsets in what
    /// comes back are for the text as given.
    func lint(_ text: String) async -> [WritingIssue] {
        await changing?.value
        guard let grammar else { return [] }
        var lints: [WritingIssue] = []
        var offset = 0
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // Checking turned off while the paragraphs before were linted:
            // the rest go to no engine, and the field gets no answer.
            guard self.grammar === grammar else { return [] }
            let piece = String(paragraph)
            let span = paragraph.utf16.count
            if isEnglish(piece) {
                do {
                    for var lint in try await grammar.lint(piece) {
                        lint.start += offset
                        lint.end += offset
                        lints.append(lint)
                    }
                } catch {
                    Self.log.error("grammar lint failed: \(String(describing: error))")
                    return []
                }
            }
            // The line break itself.
            offset += span + 1
        }
        // Turned off while the last paragraph was with Harper: no answer.
        guard self.grammar === grammar else { return [] }
        return lints.sorted { $0.start < $1.start }
    }

    /// Whether the recognizer calls the paragraph English, or can't call it
    /// either way (too short or too unsure to keep it back).
    private func isEnglish(_ text: String) -> Bool {
        guard text.count >= Self.languageMinimum else { return true }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first else { return true }
        return language == .english || confidence < 0.6
    }

    /// A word for the personal dictionary, saved and in the linter at once.
    func addWord(_ word: String) {
        WritingWords.add(word)
        wordsChanged()
    }

    /// The personal dictionary changed (Settings › Writing added, removed
    /// or brought in words): the linter takes the file as it is now, so a
    /// word added stops being flagged and one removed is flagged again.
    func wordsChanged() {
        guard var made else { return }
        made.words = WritingWords.load()
        guard made != self.made else { return }
        self.made = made
        configure(made)
    }

    /// New settings for the linter there is, after any still on their way.
    private func configure(_ settings: WritingConfiguration) {
        change { grammar in
            do { try await grammar.configure(settings) } catch {
                Self.log.error("grammar engine would not take the settings: \(String(describing: error))")
            }
        }
    }

    /// A change to the linter there is, made after the ones before it.
    private func change(_ make: @escaping @MainActor @Sendable (any GrammarService) async -> Void) {
        guard let grammar else { return }
        let before = changing
        changing = Task {
            await before?.value
            await make(grammar)
        }
    }

    /// This lint never shown again, for as long as the app runs: Harper
    /// knows it by the context string the answer carried.
    func ignore(context: String) {
        change { grammar in
            do { try await grammar.ignore(context: context) } catch {
                Self.log.error("grammar engine would not ignore a lint: \(String(describing: error))")
            }
        }
    }

    /// Harper's rules, for Settings › Writing; empty if the engine can't say.
    /// Harper builds every rule to list them, so this is for a screen that
    /// shows them, not for a check made at launch.
    nonisolated static func rules() -> [WritingRule] {
        (try? engine.rules()) ?? []
    }

    /// Whether this device can check at all: the engine is linked and takes
    /// its default settings. Quick, as making a Grammar is: its dictionary
    /// and rules wait for a first lint, which this never asks for.
    nonisolated static var canCheck: Bool {
        engine.canCheck
    }
}
