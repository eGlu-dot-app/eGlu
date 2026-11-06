import AppKit
import ApplicationServices
import Combine
import WritingServiceKit
import PadCore

/// Checking what is typed in other apps' fields (Docs/Tasks/03): the
/// orchestrator between the Accessibility reads (`FrontField`,
/// `FieldGeometry`), the linter (`WritingChecker`), the underlines and the
/// panel. All of it on the main actor; each Accessibility read waits a
/// quarter of a second at most (`AX`).
///
/// Nothing typed is logged or kept: the field's text lives only in this
/// object and is sent nowhere (Decided 9).
@MainActor
final class ElsewhereChecker {
    static let shared = ElsewhereChecker()

    private var started = false
    /// Whether fields are watched: the settings on and Accessibility allowed.
    private var running = false
    private var field: AXUIElement?
    /// The field's text as last read, and the caret inside it.
    private var text = ""
    private var caret: Int?
    /// The lints of the last run, in the field's UTF-16 offsets, moved
    /// along with the text when it changes elsewhere.
    private var lints: [WritingIssue] = []
    private var caretSettle = CaretSettle()
    /// What the panel is showing: the lint's index and its word.
    private var shown: (index: Int, word: String)?
    /// The panel was up when something moved: it comes back with the underlines.
    private var reopen = false
    /// The field's visible range and frame as last read, to tell a scroll.
    private var looks: FrontField.Looks?
    /// When the text or its place last changed: nothing is drawn until
    /// `CaretSettle.settle` after it (Decided 10).
    private var changedAt: TimeInterval = 0
    /// A redraw a hung app put off: done on the first beat it answers again.
    private var owed = false
    /// The lints left undrawn as the word being typed: drawn once the
    /// caret moves on.
    private var typing: [Range<Int>] = []
    /// Counts the fields watched, so a beat that found a new one stops.
    private var arrivals = 0
    /// The part of a long field the last run checked (Decided 7): a caret
    /// that leaves it asks for a run where it is now.
    private var checked: Range<Int>?

    /// The clock all the settles read, seconds since start.
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var tickTimer: Timer?
    private var lintWork: DispatchWorkItem?
    private var redrawWork: DispatchWorkItem?
    /// Bumped on every text change so a late lint answer is dropped.
    private var generation = 0
    private var trust: AnyCancellable?

    private var preferences: Preferences { Session.shared.preferences }

    private init() {}

    /// Called once from Session's start. Nothing is watched until the
    /// settings and Accessibility allow it.
    func start() {
        guard !started else { return }
        started = true
        let front = FrontField.shared
        front.configure { [weak self] in self?.preferences ?? Preferences() }
        front.onEvent = { [weak self] event in self?.hear(event) }
        AcceptKey.shared.onAccept = { [weak self] in self?.acceptFirst() }
        // Allowed, or taken back, in System Settings while eGlu runs:
        // checking starts or stops without a relaunch.
        trust = AccessibilityAccess.shared.$isTrusted
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] trusted in self?.update(trusted: trusted) }
        update(trusted: AccessibilityAccess.shared.isTrusted)
    }

    /// A setting changed: checking may have to start or stop at once, and
    /// an app turned off or a rule changed shows on the field now.
    /// Called from SessionPreferences' macOS half.
    func preferencesChanged() {
        update(trusted: AccessibilityAccess.shared.isTrusted)
        if field != nil { scheduleLint() }
    }

    /// `trusted` is passed in: the published value arrives before the
    /// property holds it.
    private func update(trusted: Bool) {
        guard started else { return }
        let on = preferences.writing && preferences.writingOtherApps
        if on {
            AccessibilityAccess.shared.watch()
        } else {
            AccessibilityAccess.shared.stopWatching()
        }
        guard on, trusted else {
            if running {
                running = false
                FrontField.shared.stop()
                drop()
            }
            return
        }
        if running {
            FrontField.shared.refreshFront()
        } else {
            running = true
            FrontField.shared.start()
        }
    }

    // MARK: - The field's events

    private func hear(_ event: FrontField.Event) {
        switch event {
        case .field(let element):
            fieldChanged(element)
        case .text(let text):
            textChanged(to: text)
        case .selection:
            selectionChanged(to: FrontField.shared.readCaret())
        case .geometry:
            staleMarks()
        }
    }

    /// The 4 Hz beat while a field is watched (Decided 2): what
    /// notifications miss — another field without a focus notification,
    /// text from an app that posts no value change, and scrolling, which
    /// posts nothing — is caught here.
    private func tick() {
        let arrivals = self.arrivals
        FrontField.shared.refreshFront()
        // A new field was just read whole on arrival; a hung app's reads
        // answer nothing, which is no change.
        guard field != nil, arrivals == self.arrivals, !AX.isPaused else { return }
        if let text = FrontField.shared.readText(), text != self.text { textChanged(to: text) }
        let caret = FrontField.shared.readCaret()
        guard !AX.isPaused else { return }
        if caret != self.caret { selectionChanged(to: caret) }
        let looks = FrontField.shared.readLooks()
        guard !AX.isPaused else { return }
        if looks != self.looks {
            self.looks = looks
            staleMarks()
        }
        if let event = caretSettle.tick(at: now) { hearSettle(event) }
        if owed, now - changedAt >= CaretSettle.settle { settled() }
    }

    private func startTicking() {
        guard tickTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func fieldChanged(_ element: AXUIElement?) {
        field = element
        arrivals += 1
        generation += 1
        lints = []
        shown = nil
        reopen = false
        owed = false
        typing = []
        checked = nil
        lintWork?.cancel()
        redrawWork?.cancel()
        WritingPanel.shared.hide()
        Underlines.shared.clear()
        guard element != nil else {
            text = ""
            caret = nil
            looks = nil
            caretSettle = CaretSettle()
            stopTicking()
            return
        }
        text = FrontField.shared.readText() ?? ""
        caret = FrontField.shared.readCaret()
        // An arrival: the field's lints show, and nothing opens by itself.
        caretSettle = CaretSettle(caret: caret)
        looks = FrontField.shared.readLooks()
        startTicking()
        scheduleLint()
    }

    private func textChanged(to text: String) {
        guard field != nil, text != self.text else { return }
        let edit = WritingSpan.edit(from: self.text, to: text)
        generation += 1
        self.text = text
        // Lints the edit left alone move with their words; the ones it
        // touched wait for the next run, so no underline is ever drawn
        // from an offset the text no longer has.
        lints = lints.compactMap { lint in
            guard let moved = WritingSpan.shift(lint.start..<lint.end, by: edit) else { return nil }
            var lint = lint
            lint.start = moved.lowerBound
            lint.end = moved.upperBound
            return lint
        }
        caret = FrontField.shared.readCaret()
        if let event = caretSettle.moved(to: caret, at: now, textChanged: true) { hearSettle(event) }
        caretSettle.set(lints: lints.map { $0.start..<$0.end }, at: now)
        // Typing grows the visible range and can grow the field: that is
        // this change, not another one for the beat to find.
        looks = FrontField.shared.readLooks()
        staleMarks()
        scheduleLint()
    }

    private func selectionChanged(to caret: Int?) {
        guard field != nil else { return }
        self.caret = caret
        if let event = caretSettle.moved(to: caret, at: now, textChanged: false) {
            hearSettle(event)
        }
        if let checked, let caret,
           !WritingSpan.covers(checked, caret: caret, length: text.utf16.count) {
            self.checked = nil
            scheduleLint()
        }
        // The caret moved off the word it was typing: its underline shows.
        if typing.contains(where: { !caretSettle.isTyping(in: $0) }),
           now - changedAt >= CaretSettle.settle {
            redraw()
        }
    }

    /// Underlines and panel vanish while anything moves; they return
    /// 150 ms after stillness, drawn from rectangles read again then.
    private func staleMarks() {
        changedAt = now
        reopen = reopen || shown != nil
        Underlines.shared.clear()
        WritingPanel.shared.hide()
        shown = nil
        redrawWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settled() }
        redrawWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + CaretSettle.settle, execute: work)
    }

    private func settled() {
        // The baseline the beat compares with is what the marks are drawn for.
        looks = FrontField.shared.readLooks()
        redraw()
        // A hung app keeps the panel to reopen for the beat that redraws.
        guard !AX.isPaused else { return }
        if reopen, let index = caretSettle.visited { open(lintAt: index) }
        reopen = false
    }

    // MARK: - Linting

    private func scheduleLint() {
        lintWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.lintNow() }
        lintWork = work
        // 300 ms of quiet first, so a run never splits a word being typed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func lintNow() {
        guard let field else { return }
        let text = self.text
        let region = WritingSpan.region(of: text, caret: caret ?? 0)
        checked = region
        let piece = (text as NSString).substring(
            with: NSRange(location: region.lowerBound, length: region.count))
        let generation = self.generation
        Task { [weak self] in
            var found = await WritingChecker.shared.lint(piece)
            // Checking stopped, another field came, or the text moved on
            // while Harper ran: the answer is for nothing on screen now.
            guard let self, self.running, self.generation == generation, self.text == text,
                  let current = self.field, CFEqual(current, field) else { return }
            for index in found.indices {
                found[index].start += region.lowerBound
                found[index].end += region.lowerBound
            }
            self.lints = found
            if let event = self.caretSettle.set(lints: found.map { $0.start..<$0.end }, at: self.now) {
                self.hearSettle(event)
            }
            // Drawn at once only when nothing has moved for a beat; the
            // pending redraw does it otherwise.
            if self.now - self.changedAt >= CaretSettle.settle { self.redraw() }
        }
    }

    /// Read the lint rectangles again and put the underlines back: not the
    /// word being typed, and only where the field shows its text.
    private func redraw() {
        guard let field else { return }
        guard !AX.isPaused else {
            owed = true
            return
        }
        owed = false
        let visible = FieldGeometry.visibleFrame(of: field)
        typing = lints.map { $0.start..<$0.end }.filter { caretSettle.isTyping(in: $0) }
        let marks = lints.compactMap { lint -> Underlines.Marks? in
            guard !caretSettle.isTyping(in: lint.start..<lint.end) else { return nil }
            let rects = FieldGeometry.rects(
                for: NSRange(location: lint.start, length: lint.end - lint.start), in: field)
                .compactMap { FieldGeometry.clip($0, to: visible) }
            return rects.isEmpty ? nil : Underlines.Marks(rects: rects, color: WritingColors.color(for: lint.kind))
        }
        Underlines.shared.show(marks)
    }

    // MARK: - The panel

    private func hearSettle(_ event: CaretSettle.Event) {
        switch event {
        case .visit(let index):
            visit(lintAt: index)
        case .leave:
            WritingPanel.shared.hide()
            shown = nil
            reopen = false
        }
    }

    /// The caret rested in a lint: its panel opens, or, while the text is
    /// still moving, once the underlines come back.
    private func visit(lintAt index: Int) {
        guard now - changedAt >= CaretSettle.settle else {
            reopen = true
            return
        }
        open(lintAt: index)
    }

    private func open(lintAt index: Int) {
        guard let field, lints.indices.contains(index), !AX.isPaused else { return }
        let lint = lints[index]
        let range = NSRange(location: lint.start, length: lint.end - lint.start)
        let whole = text as NSString
        guard NSMaxRange(range) <= whole.length else { return }
        let word = whole.substring(with: range)
        let visible = FieldGeometry.visibleFrame(of: field)
        let rects = FieldGeometry.rects(for: range, in: field).compactMap { FieldGeometry.clip($0, to: visible) }
        guard let first = rects.first else { return }
        let anchor = rects.dropFirst().reduce(first) { $0.union($1) }
        shown = (index, word)
        WritingPanel.shared.show(
            lint: lint, at: anchor,
            suggestions: lint.suggestions.prefix(5).map { Self.label(for: $0) },
            canAddToDictionary: lint.kind == "Spelling" || lint.kind == "Typo"
        ) { [weak self] action, suggestion in
            self?.act(action, on: lint, word: word, suggestion: suggestion)
        }
    }

    /// A suggestion's button text: the answer itself, "Remove" for a word
    /// to delete, Insert “x” for one to add. Harper's suggestion type, not
    /// the command bar's Suggestion that PadCore also has.
    private static func label(for suggestion: WritingSuggestion) -> String {
        switch suggestion {
        case .replace(let text): return text
        case .insert(let text): return String(localized: "Insert “\(text)”")
        case .remove: return String(localized: "Remove")
        }
    }

    /// ⌃⌥G: the panel's first suggestion, only while one is up.
    private func acceptFirst() {
        guard let shown, lints.indices.contains(shown.index) else { return }
        let lint = lints[shown.index]
        guard let first = lint.suggestions.first else { return }
        WritingPanel.shared.hide()
        self.shown = nil
        reopen = false
        apply(first, to: lint, word: shown.word)
    }

    /// A panel button, and for a suggestion which of them.
    private func act(_ action: PopupAction, on lint: WritingIssue,
                     word: String, suggestion: Int) {
        // The panel closed itself: it opens again only when the caret moves.
        shown = nil
        reopen = false
        switch action {
        case .close:
            return
        case .ignoreLint:
            WritingChecker.shared.ignore(context: lint.context)
            lints.removeAll { $0 == lint }
        case .addToDictionary:
            WritingChecker.shared.addWord(word)
            lints.removeAll { $0 == lint }
        case .disableRule:
            Session.shared.preferences.writingRules[lint.rule] = false
            lints.removeAll { $0.rule == lint.rule }
        case .applySuggestion:
            if lint.suggestions.indices.contains(suggestion) {
                apply(lint.suggestions[suggestion], to: lint, word: word)
            }
            return
        }
        // Its underline goes at once; the run after confirms the rest.
        caretSettle.set(lints: lints.map { $0.start..<$0.end }, at: now)
        if now - changedAt >= CaretSettle.settle { redraw() }
        scheduleLint()
    }

    /// Write the suggestion into the field through the app's own text
    /// setting or typing, so its Undo takes it back (FieldWriter), then
    /// lint again (B1 step 5): the text changed, or the lint was stale.
    private func apply(_ suggestion: WritingSuggestion, to lint: WritingIssue, word: String) {
        guard let field, let app = FrontField.shared.app else { return }
        let replacement: String
        switch suggestion {
        case .replace(let text): replacement = text
        case .insert(let text): replacement = word + text
        case .remove: replacement = ""
        }
        let range = NSRange(location: lint.start, length: lint.end - lint.start)
        // Its underline goes now: the word under it is being replaced.
        lints.removeAll { $0 == lint }
        caretSettle.set(lints: lints.map { $0.start..<$0.end }, at: now)
        staleMarks()
        Task { [weak self] in
            _ = await FieldWriter.replace(range: range, expected: word, with: replacement,
                                          in: field, app: app)
            guard let self, let current = self.field, CFEqual(current, field) else { return }
            // Read back at once rather than wait for the app's notification
            // or the beat, so the run lints the text as it is now.
            if let text = FrontField.shared.readText(), text != self.text {
                self.textChanged(to: text)
            } else {
                self.scheduleLint()
            }
        }
    }

    /// Checking stops: every mark gone, nothing read further.
    private func drop() {
        field = nil
        text = ""
        caret = nil
        looks = nil
        lints = []
        generation += 1
        caretSettle = CaretSettle()
        shown = nil
        reopen = false
        owed = false
        typing = []
        checked = nil
        lintWork?.cancel()
        redrawWork?.cancel()
        stopTicking()
        WritingPanel.shared.hide()
        Underlines.shared.clear()
    }
}
