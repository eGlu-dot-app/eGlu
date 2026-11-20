import PadCore
import SwiftUI
import UIKit

/// What the address bar offers as an address is typed: the space's tabs,
/// pinned tabs and bookmarks, the other spaces and their tabs, tabs open on
/// other devices, the browser's commands, the parts of Settings, and the
/// search engine's suggestions (Autocomplete), each row saying which it is.
/// Where Apple Intelligence is on, its on-device model adds what the words
/// mean once typing pauses (Intelligence.swift). ↑ and ↓ choose a row and
/// Return takes it; with none chosen, Return sends what was typed, as before.
///
/// Asked for everything (a new tab, or Command.everything, ⌃⌥K), the field
/// opens empty with all of them listed under headings, each command with
/// its keys, and what is typed narrows the list: the command palette's work
/// and a cheat sheet of the shortcuts, in the one field. On iPad the field
/// and its rows are the command bar, floating over the page (CommandBar);
/// on a phone the field is in the bar at the bottom and the rows are over it.
@MainActor
final class Suggestions: ObservableObject {
    @Published private(set) var rows: [Suggestion] = []
    /// The row ↑ and ↓ have chosen; nil for the text as typed.
    @Published private(set) var selection: Int?
    /// The rows are everything there is, nothing typed yet: they show under
    /// headings, a kind each.
    @Published private(set) var listing = false
    /// What the field held as typing began: the page's address, not a query.
    private var start = ""
    private var query = ""
    /// What the field holds, as it last said (typed(_:in:)).
    var lastTyped: String { query }
    /// Everything is listed (Command.everything): all of it before anything
    /// is typed, and the device's rows before the searches after.
    private var wide = false
    private var local: [Suggestion] = []
    /// The engine's suggestions, the space's history and the model's
    /// answers for what is typed (SuggestionSources).
    private lazy var sources = SuggestionSources(
        query: { [unowned self] in self.query },
        rows: { [unowned self] in self.rows },
        space: { [unowned self] in self.index?.space },
        changed: { [unowned self] in self.show() }
    )
    /// The candidates for this turn at the field, ready to be searched, and
    /// what they were made from: made again only when the spaces, their
    /// tabs or bookmarks are other ones, or the window's width is, not for
    /// every letter.
    private var index: (made: Autocomplete.Index, space: UUID, tab: UUID?, phone: Bool, windows: Bool, canHandoff: Bool, spaces: [Space])?

    var selected: Suggestion? {
        selection.flatMap { rows.indices.contains($0) ? rows[$0] : nil }
    }

    /// Typing starts, in a field holding the page's address; or, with
    /// everything listed, in an empty one over all there is to choose.
    func begin(in window: WindowModel) {
        end()
        wide = window.listsEverything
        // What the field starts with (AddressEditor.begin): a search's words, for a search with the chosen engine.
        start = wide ? "" : window.url.map { Destination.editable($0, engine: Session.shared.preferences.engine) } ?? ""
        if wide {
            local = index(for: window).everything
            listing = true
            show()
        }
    }

    /// What the field holds now, the letters still being composed included.
    func typed(_ text: String, in window: WindowModel) {
        // The field says what it holds once more as Return sends it; by
        // then typing is over.
        guard window.editingAddress, text != query else { return }
        query = text
        selection = nil
        let nothing = text.trimmingCharacters(in: .whitespaces).isEmpty
        if listing != (wide && nothing) { listing = wide && nothing }
        // The page's own address is no query, and nor is nothing, unless
        // everything is listed: then nothing typed lists it all again.
        guard wide || (text != start && !nothing) else {
            sources.quiet()
            local = []
            if !rows.isEmpty { rows = [] }
            return
        }
        let offered = index(for: window)
        local = offered.local(query: text, wide: wide)
        if nothing {
            sources.quiet()
        } else {
            let preferences = Session.shared.preferences
            sources.ask(text, preferences: preferences)
            sources.recall(text, in: window.spaceID)
            sources.think(text, about: offered, allowed: preferences.intelligence)
        }
        show()
    }

    /// Typing is over, sent or not.
    func end() {
        sources.end()
        index = nil
        wide = false
        if listing { listing = false }
        start = ""
        query = ""
        local = []
        selection = nil
        if !rows.isEmpty { rows = [] }
    }

    /// ↓ from the field goes to the first row, ↑ from the first row back to the field.
    func move(_ by: Int) {
        guard !rows.isEmpty else { return }
        let previous = selection
        if let index = selection {
            let next = index + by
            selection = next < 0 ? nil : min(next, rows.count - 1)
        } else if by > 0 {
            selection = 0
        }
        guard selection != previous, let selected else { return }
        KeyboardSelectionEvent(row: selected).announce()
    }

    /// Only a deliberate keyboard move creates this event. Result refreshes
    /// and pointer hover leave VoiceOver and the address field's focus alone.
    private struct KeyboardSelectionEvent {
        let row: Suggestion

        func announce() {
            guard UIAccessibility.isVoiceOverRunning else { return }
            let message = [row.phrase, row.detail].filter { !$0.isEmpty }.joined(separator: ", ")
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }

    private func show() {
        // The engine's words for a few letters fewer stay while they still
        // fit, so the rows don't empty and fill again with every letter.
        let typed = query.trimmingCharacters(in: .whitespaces).lowercased()
        let approved = Session.shared.preferences.allowsRemoteSuggestions(for: sources.answerProvider ?? "")
        let words = !approved ? [] : sources.answer.query == query ? sources.answer.words
            : sources.answer.words.filter { $0.lowercased().hasPrefix(typed) }
        var engine = Autocomplete.engine(words, query: query,
                                         engine: Autocomplete.engineName(Session.shared.preferences.engine))
        // The model's answer to a few letters fewer stays too, while the
        // words run on from them, until it answers again.
        let current = sources.thought.query == query || (!sources.thought.query.isEmpty && query.hasPrefix(sources.thought.query))
        let meant = current ? sources.thought.meant.filter { row in !local.contains { $0.id == row.id } } : []
        // Its searches only where the engine isn't asked: Settings has the
        // engine's off, or the engine has none.
        if current, !sources.asksEngine {
            engine = sources.thought.query == query ? sources.thought.searches
                : sources.thought.searches.filter { $0.phrase.lowercased().hasPrefix(typed) }
        }
        // History's answer to a few letters fewer stays too, the rows the letters still fit.
        let recalled = sources.remembered.query == query
        let history = sources.remembered.space == index?.space && (recalled || (!sources.remembered.query.isEmpty && query.hasPrefix(sources.remembered.query)))
            ? Autocomplete.history(sources.remembered.pages, query: query, shown: local, tabs: index?.made.tabs ?? [:], stale: !recalled) : []
        // The row ↑ and ↓ chose stays chosen as rows come in around it.
        let chosen = selected?.id
        rows = Autocomplete.rows(local: local, history: history, meant: meant, engine: engine, wide: wide)
        if let chosen { selection = rows.firstIndex { $0.id == chosen } }
    }

    private func index(for window: WindowModel) -> Autocomplete.Index {
        let spaces = Session.shared.workspace.spaces
        // The commands and Settings' parts a window has go with its width.
        if let kept = index, kept.space == window.spaceID, kept.tab == window.tabID, kept.phone == window.phone,
           kept.windows == window.makesWindows, kept.canHandoff == window.canHandoff, kept.spaces == spaces {
            return kept.made
        }
        let made = Autocomplete.Index(candidates(for: window))
        index = (made, window.spaceID, window.tabID, window.phone, window.makesWindows, window.canHandoff, spaces)
        return made
    }

    /// Everything there is to find from this window, in the order it is
    /// listed with nothing typed (the typed letters rank it otherwise): the
    /// space's tabs that have somewhere to go, the last seen first; the
    /// other spaces, to go to, but nothing in them: a search finds only
    /// this space's tabs, history and bookmarks; the commands this device
    /// has and the parts of Settings; the space's tabs on other devices;
    /// and its bookmarks, which a new tab shows anyway.
    private func candidates(for window: WindowModel) -> [Autocomplete.Candidate] {
        let workspace = Session.shared.workspace
        let here = workspace.space(window.spaceID)
        let others = workspace.spaces.filter { $0.id != window.spaceID }
        var list: [Autocomplete.Candidate] = []
        for tab in (here?.tabs ?? []).sorted(by: { $0.shown > $1.shown }) where tab.id != window.tabID {
            guard let url = tab.url ?? tab.pinned else { continue }
            list.append(Autocomplete.Candidate(
                id: "tab-\(tab.id)", source: tab.isPinned ? .pinnedTab : .tab, action: .tab(tab.id),
                title: tab.label, url: url, shown: tab.shown
            ))
        }
        for space in others {
            list.append(Autocomplete.Candidate(
                id: "space-\(space.id)", source: .space, action: .space(space.id), title: space.name,
                keywords: ["space", "switch space"],
                detail: BrowserText.tabCount(space.tabs.count), symbol: space.symbol
            ))
        }
        // By the menu each is in, as a cheat sheet would have them. Not Open
        // Address or Commands: the field is open already.
        for command in ShortcutGroup.allCases.flatMap(\.commands)
        where command != .everything && command != .address && Device.offers(command, in: window) {
            list.append(Autocomplete.Candidate(
                id: "command-\(command.rawValue)", source: .command, action: .command(command), title: window.title(for: command),
                keywords: command.keywords, detail: Device.keys(for: command) ?? "", symbol: command.symbol
            ))
        }
        for anchor in SettingsAnchor.allCases where Device.offers(anchor, compact: window.phone) {
            list.append(Autocomplete.Candidate(
                id: "setting-\(anchor.rawValue)", source: .setting, action: .setting(anchor), title: anchor.title,
                keywords: anchor.keywords, detail: anchor.detail
            ))
        }
        for bookmark in here?.bookmarks.flatMap(\.links) ?? [] {
            guard let url = bookmark.url else { continue }
            list.append(Autocomplete.Candidate(
                id: "bookmark-\(bookmark.id)", source: .bookmark, action: .open(url), title: bookmark.label, url: url
            ))
        }
        return list
    }
}

/// The rows over the phone's bar, in a see-through material. The browser
/// sizes it to its rows (Browser.placeSuggestions); it scrolls when the
/// room is less. (On iPad the rows are part of the command bar.)
struct SuggestionList: View {
    let window: WindowModel
    @ObservedObject var suggestions: Suggestions
    let choose: (Suggestion) -> Void

    init(window: WindowModel, choose: @escaping (Suggestion) -> Void) {
        self.window = window
        suggestions = window.suggestions
        self.choose = choose
    }

    var body: some View {
        SuggestionRows(suggestions: suggestions, choose: choose)
        // In Liquid Glass with no colour of its own, as the bar under it is
        // while an address is typed: risen over the keyboard, the bar shows
        // the page where it now is, not the colour at the page's foot it
        // had below. What is drawn on it is the label colour at an opacity,
        // not the system's vibrant .secondary: inside the scrolling list
        // that drew nothing at all (iPadOS 27).
        .floatingGlass(cornerRadius: 16, tint: nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggestions")
    }
}

/// The rows themselves, scrolling: for the list over the phone's bar and
/// for the command bar. With everything listed and nothing typed yet, each
/// kind is under a heading.
struct SuggestionRows: View {
    @ObservedObject var suggestions: Suggestions
    let choose: (Suggestion) -> Void

    static let rowHeight: CGFloat = 44
    static let headingHeight: CGFloat = 28
    static let inset: CGFloat = 6

    /// The rows' height, headings included, before the room they have is counted.
    @MainActor static func height(of suggestions: Suggestions) -> CGFloat {
        let rows = suggestions.rows
        guard !rows.isEmpty else { return 0 }
        let headings = suggestions.listing ? Self.headings(rows).count : 0
        return CGFloat(rows.count) * rowHeight + CGFloat(headings) * headingHeight + 2 * inset
    }

    /// The heading over each row that starts another kind, by the row's place.
    static func headings(_ rows: [Suggestion]) -> [Int: String] {
        var headings: [Int: String] = [:]
        var last: String?
        for (index, row) in rows.enumerated() {
            let kind = Self.kind(row.source)
            if kind != last { headings[index] = kind }
            last = kind
        }
        return headings
    }

    private static func kind(_ source: Suggestion.Source) -> String {
        switch source {
        case .tab, .pinnedTab: return String(localized: "Open Tabs")
        case .space: return String(localized: "Spaces")
        case .command: return String(localized: "Commands")
        case .setting: return String(localized: "Settings")
        case .device: return String(localized: "From Other Devices")
        case .bookmark: return String(localized: "Bookmarks")
        case .history: return String(localized: "History")
        case .localServer: return String(localized: "Local Servers")
        case .searched, .engine, .intelligence: return String(localized: "Searches")
        }
    }

    var body: some View {
        let rows = suggestions.rows
        let listing = suggestions.listing
        let headings = listing ? Self.headings(rows) : [:]
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if let heading = headings[index] {
                            Text(heading)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.bottom, 4)
                                .frame(minHeight: Self.headingHeight, alignment: .bottomLeading)
                                .accessibilityAddTraits(.isHeader)
                        }
                        // Under a heading that says what the row is, it says
                        // only what the heading can't: which space, which device.
                        // The search engine is named on the first of its rows only: four
                        // tags saying "Google" one under another say it no better than one.
                        let again = index > 0 && Self.searches(row) && Self.searches(rows[index - 1])
                        Button {
                            choose(row)
                        } label: {
                            SuggestionRow(row: row, selected: index == suggestions.selection, named: !listing && !again)
                        }
                        .buttonStyle(RowPress())
                        .id(row.id)
                    }
                }
                .padding(Self.inset)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: suggestions.selection) { _, index in
                if let index, rows.indices.contains(index) { scroller.scrollTo(rows[index].id) }
            }
        }
    }

    /// A search with the engine, as a row's source says.
    private static func searches(_ row: Suggestion) -> Bool {
        if case .engine = row.source { return true }
        return false
    }
}

/// A row that shows the touch on it: filled at once as the finger lands,
/// fading quickly as it lifts.
private struct RowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.1) : Color.clear,
                        in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
            .animation(configuration.isPressed ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// A row: the page's icon, a space's or a command's own symbol, or a
/// setting's or a search's; the phrase,
/// what was typed in the label colour and what the row completes in bold;
/// what else there is to say under it; and at the end where it came from,
/// or a command's keys where there is a keyboard to press them on.
private struct SuggestionRow: View {
    let row: Suggestion
    let selected: Bool
    /// The row says where it came from; not under a heading that does.
    var named = true

    /// A command's keys, each to draw as a key: the cheat sheet. None where
    /// none work: a phone with no keyboard attached (Device.keys).
    private var keys: [String]? {
        guard case .command(let command) = row.action, Device.keys(for: command) != nil else { return nil }
        return Menus.keyCaps(for: command)
    }

    /// Where the row came from, when the heading over it doesn't already
    /// say: a device's name is the row's own.
    private var showsSource: Bool {
        if named { return true }
        switch row.source {
        case .device: return true
        default: return false
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                phrase
                    .font(.subheadline)
                    .lineLimit(2)
                // A command's second line is its keys, which are drawn at the end.
                if !row.detail.isEmpty, keys == nil {
                    Text(row.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let keys {
                // Its keys take the tag's place, so the sparkles that say the
                // model found it by meaning are shown before them.
                if row.byMeaning {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.6))
                        .accessibilityHidden(true)
                }
                KeyCaps(keys: keys)
            } else if showsSource {
                SourceTag(source: row.source, byMeaning: row.byMeaning)
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: SuggestionRows.rowHeight)
        .padding(.vertical, 4)
        .background(selected ? Color.primary.opacity(0.1) : Color.clear,
                    in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                    .strokeBorder(Color.primary, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.byMeaning ? "\(row.phrase), \(row.source.label), found by Apple Intelligence"
                                          : "\(row.phrase), \(row.source.label)")
        .accessibilityValue(row.detail)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var icon: some View {
        switch row.source {
        case .tab, .pinnedTab, .device, .bookmark, .history, .localServer:
            SiteIconView(url: row.url, size: 18)
        case .searched:
            symbol("clock.arrow.circlepath")
        case .space:
            symbol(row.symbol ?? "square.stack")
        case .command:
            symbol(row.symbol ?? "command")
        case .setting:
            symbol("gearshape")
        case .engine, .intelligence:
            symbol("magnifyingglass")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.primary.opacity(0.6))
    }

    /// The typed letters plain, the rest of the phrase in bold: what the row
    /// adds to what was typed.
    private var phrase: Text {
        let letters = Array(row.phrase)
        let typed = row.typed
            .map { $0.clamped(to: 0..<letters.count) }
            .filter { !$0.isEmpty }
            .sorted { $0.lowerBound < $1.lowerBound }
        var parts: [Text] = []
        var at = 0
        for range in typed where range.lowerBound >= at {
            parts.append(part(letters[at..<range.lowerBound], typed: false))
            parts.append(part(letters[range], typed: true))
            at = range.upperBound
        }
        parts.append(part(letters[at...], typed: false))
        return parts.reduce(Text(verbatim: "")) { Text("\($0)\($1)") }
    }

    private func part(_ letters: ArraySlice<Character>, typed: Bool) -> Text {
        Text(verbatim: String(letters))
            .fontWeight(typed ? .regular : .semibold)
            .foregroundStyle(typed ? Color.primary.opacity(0.7) : Color.primary)
    }
}

/// Where a row came from, in a small capsule at its end; with sparkles
/// before it when Apple Intelligence found the row by what the words mean.
private struct SourceTag: View {
    let source: Suggestion.Source
    var byMeaning = false

    var body: some View {
        HStack(spacing: 3) {
            if byMeaning {
                Image(systemName: "sparkles")
                    .font(.system(size: 9, weight: .semibold))
            }
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
            Text(source.label)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(Color.primary.opacity(0.6))
        .lineLimit(1)
        .padding(.horizontal, 7)
        .frame(minHeight: 20)
        .background(Color.primary.opacity(0.07), in: Capsule())
        .fixedSize()
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch source {
        case .tab: return "square.on.square"
        case .pinnedTab: return "pin.fill"
        case .device: return "laptopcomputer.and.iphone"
        case .bookmark: return "star.fill"
        case .history: return "clock"
        case .searched: return "clock.arrow.circlepath"
        case .space: return "square.stack"
        case .command: return "command"
        case .setting: return "gearshape.fill"
        case .engine: return "magnifyingglass"
        case .intelligence: return "sparkles"
        case .localServer: return "network"
        }
    }
}

/// A shortcut's keys, each drawn as a key on the keyboard: its sign on a
/// small raised square. Beside every command in the command bar, which is
/// how the bar is also the cheat sheet of the shortcuts.
struct KeyCaps: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys.indices, id: \.self) { index in
                Text(keys[index])
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .padding(.horizontal, 5)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            }
        }
        .fixedSize()
        // The row says the keys as words (its value); the signs say nothing aloud.
        .accessibilityHidden(true)
    }
}
