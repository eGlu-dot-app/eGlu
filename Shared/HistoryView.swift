import PadCore
#if os(macOS)
import QuickLook
#endif
import SwiftUI

/// The space's history (Show All History: ⌘Y on a Mac, ⌃⌥Y on an iPad):
/// the pages gone to in it, by day, newest first, each page once a day,
/// and the handoffs made in it, each its own row; or, with words typed, the
/// pages and handoffs they find. A page is opened from here, a handoff's
/// Markdown file offered again (the share sheet; Quick Look on a Mac), or
/// either let go of, alone or with its day; Clear History lets go of a
/// stretch of time. The filter beside the search narrows the list, and
/// what is found, to a stretch of time, to pages or handoffs and, where
/// history goes through iCloud, to this device's visits or the others'.
struct HistoryView: View {
    let spaceID: UUID
    /// A page chosen: in the tab on screen, or in a new one.
    let open: (URL, _ newTab: Bool) -> Void
    let done: () -> Void
    @ObservedObject private var recorder = HistoryRecorder.shared
    @State private var entries: [HistoryEntry] = []
    @State private var days: [HistoryDay] = []
    @State private var found: [HistoryPage] = []
    @State private var foundHandoffs: [HistoryHandoff] = []
    @State private var pageLimit = History.searchLimit
    @State private var handoffLimit = History.searchLimit
    @State private var pageSearch: Task<Void, Never>?
    @State private var handoffSearch: Task<Void, Never>?
    /// The words `found` answers, so "No Results" waits for the store.
    @State private var searched: String?
    /// What Apple Intelligence made of the words sent with Return
    /// (Intelligence.historyQuery): searched for in their place while they stay.
    @State private var understood: (text: String, query: HistoryQuery)?
    @State private var understanding = false
    @State private var text = ""
    @State private var filter = HistoryFilter()
    /// Whether the store has been asked yet, so an empty list isn't called empty before it is.
    @State private var loaded = false
    /// Whether older visits may be left to show, as the list reaches its end.
    @State private var more = true
    /// Older visits being asked for (loadOlder): let go of when the list is loaded again, or changed.
    @State private var paging: Task<Void, Never>?
    @State private var clearing = false
    /// The day whose Clear was pressed, asked about before it goes.
    @State private var dayAsked: HistoryDay?
    @State private var pageAsked: HistoryPage?
    @State private var handoffAsked: HistoryHandoff?
    /// A handoff being deleted, kept for Retry if it fails, as a clearing is (clearRequest).
    @State private var handoffGoing: HistoryHandoff?
    #if os(macOS)
    /// A handoff's file shown in Quick Look.
    @State private var previewed: URL?
    @State private var selection: HistorySelection?
    #endif
    @State private var loadingProblem: HistoryOperationError?
    @State private var clearRequest: HistoryRecorder.ClearRequest?
    @State private var clearProblem: HistoryOperationError?
    @State private var clearBusy = false
    @ObservedObject private var sync = Sync.shared

    /// Visits asked for at a time.
    private static let batch = 300

    #if os(iOS)
    private static let clearPlacement = ToolbarItemPlacement.topBarLeading
    #else
    private static let clearPlacement = ToolbarItemPlacement.destructiveAction
    #endif

    var body: some View {
        NavigationStack {
            list
                .navigationTitle("History")
                .searchable(text: $text, prompt: Self.searchPrompt)
                .onSubmit(of: .search) { Task { await understand() } }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: done).disabled(clearBusy)
                    }
                    // Apart from Done, at the other end on iPad, so neither is pressed for the other.
                    ToolbarItem(placement: Self.clearPlacement) {
                        Button("Clear…") { clearing = true }
                            .disabled(clearBusy || (loaded && loadingProblem == nil && entries.isEmpty && filter.isEmpty))
                    }
                }
                .modifier(BesideSearch(filter: filterMenu))
        }
        // Reloaded as words are typed (a moment after the last), as the filter
        // changes, and as history does.
        .task(id: searchIdentity) { await load() }
        .onDisappear { stopSearchPaging() }
        .sheet(isPresented: $clearing) {
            ClearHistoryView(spaceID: spaceID) { clearing = false }
        }
        .confirmationDialog(dayAsked.map { String(localized: "Clear the history of \(Self.name(of: $0.start))?") } ?? "",
                            isPresented: Binding(get: { dayAsked != nil }, set: { if !$0 { dayAsked = nil } }),
                            titleVisibility: .visible, presenting: dayAsked) { day in
            Button("Clear \(Self.name(of: day.start))", role: .destructive) { clear(day) }
        } message: { _ in
            Text(String(localized: "Every visit in this space on that day will be removed, including visits hidden by filters.")
                 + (Self.offersHandoff ? " " + String(localized: "Handoffs made then are removed too, with their files.") : "")
                 + " " + sync.historyScopeDescription)
        }
        .confirmationDialog("Delete This Page from History?",
                            isPresented: Binding(get: { pageAsked != nil }, set: { if !$0 { pageAsked = nil } }),
                            titleVisibility: .visible, presenting: pageAsked) { page in
            Button("Delete from History", role: .destructive) { delete(page) }
        } message: { _ in
            Text(String(localized: "Every visit to this page in this space will be removed, including visits hidden by filters.") + " " + sync.historyScopeDescription)
        }
        .confirmationDialog("Delete This Handoff from History?",
                            isPresented: Binding(get: { handoffAsked != nil }, set: { if !$0 { handoffAsked = nil } }),
                            titleVisibility: .visible, presenting: handoffAsked) { handoff in
            Button("Delete from History", role: .destructive) { delete(handoff) }
        } message: { _ in
            Text("Its Markdown file is removed from this device.")
        }
        #if os(macOS)
        .quickLookPreview($previewed)
        #endif
        .environment(\.spaceColor, Self.colour(of: spaceID))
        .interactiveDismissDisabled(clearBusy)
    }

    @ViewBuilder
    private var list: some View {
        let searching = !text.trimmingCharacters(in: .whitespaces).isEmpty
        historyList {
            if clearBusy { ProgressView("Clearing history…") }
            if let issue = clearProblem {
                Section {
                    Text(String(localized: "History was not cleared.") + " " + issue.message).foregroundStyle(.red)
                    Button("Retry Clearing") { runClear() }.disabled(clearBusy)
                    Button("Cancel Request") { clearRequest = nil; handoffGoing = nil; clearProblem = nil }
                }
            }
            if let issue = recorder.writeProblem, clearProblem == nil {
                Section {
                    Text(issue.message).foregroundStyle(.red)
                    Button("Retry Saving History") { Task { await recorder.retry(); await load() } }
                }
            }
            if searching {
                Section {
                    ForEach(found) { page in
                        row(page, time: page.last, day: true)
                            #if os(macOS)
                            .tag(HistorySelection.page(space: page.space, key: page.key))
                            .id(HistorySelection.page(space: page.space, key: page.key))
                            #endif
                    }
                    #if os(macOS)
                    if searchReady, History.searchIsCapped(count: found.count, limit: pageLimit) {
                        morePagesRow
                            .tag(HistorySelection.morePages)
                            .id(HistorySelection.morePages)
                    }
                    #endif
                } header: {
                    if loaded, loadingProblem == nil, searched == text.trimmingCharacters(in: .whitespaces),
                       History.searchIsCapped(count: found.count, limit: pageLimit) {
                        Text("Showing the first \(found.count) page matches")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if understanding {
                        Label("Asking Apple Intelligence…", systemImage: "sparkles")
                    } else if let understood, understood.text == text.trimmingCharacters(in: .whitespaces) {
                        Label(Self.describe(understood.query), systemImage: "sparkles")
                    }
                } footer: {
                    #if os(iOS)
                    if searchReady, History.searchIsCapped(count: found.count, limit: pageLimit) {
                        Button("Show More") { showMore(handoffs: false) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text("Show \(History.searchLimit) more pages"))
                            .disabled(pageSearch != nil)
                    }
                    #endif
                }
                if !foundHandoffs.isEmpty {
                    Section {
                        ForEach(foundHandoffs) { handoff in
                            row(handoff, day: true)
                                #if os(macOS)
                                .tag(HistorySelection.handoff(handoff.id))
                                .id(HistorySelection.handoff(handoff.id))
                                #endif
                        }
                        #if os(macOS)
                        if searchReady, History.searchIsCapped(count: foundHandoffs.count, limit: handoffLimit) {
                            moreHandoffsRow
                                .tag(HistorySelection.moreHandoffs)
                                .id(HistorySelection.moreHandoffs)
                        }
                        #endif
                    } header: {
                        Text("Handoffs")
                        if loaded, loadingProblem == nil, searched == text.trimmingCharacters(in: .whitespaces),
                           History.searchIsCapped(count: foundHandoffs.count, limit: handoffLimit) {
                            Text("Showing the first \(foundHandoffs.count) handoff matches")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        #if os(iOS)
                        if searchReady, History.searchIsCapped(count: foundHandoffs.count, limit: handoffLimit) {
                            Button("Show More") { showMore(handoffs: true) }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(Text("Show \(History.searchLimit) more handoffs"))
                                .disabled(handoffSearch != nil)
                        }
                        #endif
                    }
                }
            } else {
                ForEach(days) { day in
                    Section {
                        ForEach(day.entries) { entry in
                            Group {
                                if let handoff = entry.handoff {
                                    row(handoff, day: false)
                                } else {
                                    row(entry.page, time: entry.time, day: false)
                                }
                            }
                            #if os(macOS)
                            .tag(entry.handoff.map { HistorySelection.handoff($0.id) } ?? .visit(entry.id))
                            .id(entry.handoff.map { HistorySelection.handoff($0.id) } ?? .visit(entry.id))
                            #endif
                            .onAppear { if entry.id == days.last?.entries.last?.id { showOlder() } }
                        }
                    } header: {
                        HStack {
                            Text(Self.name(of: day.start))
                            Spacer()
                            Button("Clear") { dayAsked = day }
                                .buttonStyle(.borderless)
                                .font(.subheadline)
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .overlay {
            if let issue = loadingProblem {
                ContentUnavailableView {
                    Label("History Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(issue.message)
                } actions: {
                    Button("Retry") { Task { await recorder.retry(); await load() } }
                }
            } else if loaded, searching, searched == text.trimmingCharacters(in: .whitespaces), found.isEmpty, foundHandoffs.isEmpty {
                ContentUnavailableView.search(text: text)
            } else if loaded, !searching, days.isEmpty {
                if filter.isEmpty {
                    ContentUnavailableView("No History", systemImage: "clock",
                                           description: Text("Pages you go to in this space show here."))
                } else {
                    ContentUnavailableView {
                        Label(filter.show == .handoffs ? String(localized: "No Handoffs") : String(localized: "No Pages"),
                              systemImage: "line.3.horizontal.decrease")
                    } description: {
                        Text("Nothing in this space’s history fits the filter.")
                    } actions: {
                        Button("Show All History") { filter = HistoryFilter() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func historyList<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(macOS)
        ScrollViewReader { proxy in
            List(selection: $selection, content: content)
                .contextMenu(forSelectionType: HistorySelection.self) { _ in
                } primaryAction: { rows in
                    if let row = rows.first { activate(row) }
                }
                .onChange(of: selection) { _, row in
                    if let row { proxy.scrollTo(row) }
                }
        }
        #else
        List(content: content)
        #endif
    }

    #if os(macOS)
    private var morePagesRow: some View {
        Button { showMore(handoffs: false) } label: { moreLabel }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("Show \(History.searchLimit) more pages"))
            .disabled(pageSearch != nil)
    }

    private var moreHandoffsRow: some View {
        Button { showMore(handoffs: true) } label: { moreLabel }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("Show \(History.searchLimit) more handoffs"))
            .disabled(handoffSearch != nil)
    }

    private func activate(_ row: HistorySelection) {
        guard !clearBusy else { return }
        switch row {
        case .page(let space, let key):
            if let page = found.first(where: { $0.space == space && $0.key == key }) {
                open(page.url, false)
                done()
            }
        case .visit(let id):
            if let entry = entries.first(where: { $0.id == id }) {
                open(entry.page.url, false)
                done()
            }
        case .handoff(let id):
            if let handoff = foundHandoffs.first(where: { $0.id == id }) ?? entries.compactMap(\.handoff).first(where: { $0.id == id }) {
                previewed = handoff.file
            }
        case .morePages:
            if searchReady, pageSearch == nil { showMore(handoffs: false) }
        case .moreHandoffs:
            if searchReady, handoffSearch == nil { showMore(handoffs: true) }
        }
    }

    private var moreLabel: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Show More")
            Text(" ").font(.subheadline).hidden().accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
    #endif

    // MARK: The filter

    /// Where the visits were made, when, and whether pages, handoffs or
    /// both. Where they were made only while history goes through iCloud:
    /// otherwise all are this device's. Pages or handoffs only where there
    /// is Handoff (Session.hasIntelligence).
    private var filterMenu: some View {
        Menu {
            if Self.offersHandoff || filter.show != .everything {
                Picker("Show", selection: $filter.show) {
                    Text("Everything").tag(HistoryFilter.Show.everything)
                    Text("Pages").tag(HistoryFilter.Show.pages)
                    Text("Handoffs").tag(HistoryFilter.Show.handoffs)
                }
                .pickerStyle(.inline)
            }
            if Self.syncsHistory {
                Picker("Visited On", selection: $filter.source) {
                    Text("All Devices").tag(HistoryFilter.Source.all)
                    Text(Self.thisDevice).tag(HistoryFilter.Source.thisDevice)
                    Text("From Other Devices").tag(HistoryFilter.Source.otherDevices)
                }
                .pickerStyle(.inline)
            }
            Picker("Visited", selection: $filter.period) {
                Text("Any Time").tag(HistoryFilter.Period.all)
                Text("Today").tag(HistoryFilter.Period.today)
                Text("Yesterday").tag(HistoryFilter.Period.yesterday)
                Text("Last 7 Days").tag(HistoryFilter.Period.week)
                Text("Last 30 Days").tag(HistoryFilter.Period.month)
            }
            .pickerStyle(.inline)
            if !filter.isEmpty {
                Button("Show All History", systemImage: "xmark.circle") { filter = HistoryFilter() }
            }
        } label: {
            // Filled, in the space's colour, while it narrows the list.
            Label("Filter", systemImage: filter.isEmpty ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
        }
        .tint(filter.isEmpty ? nil : Self.colour(of: spaceID).color)
        .accessibilityValue(filter.isEmpty ? "Off" : "On")
    }

    /// The filter beside the search field: on iOS 26 and later both in the
    /// bar at the bottom, as Mail has them.
    private struct BesideSearch<Filter: View>: ViewModifier {
        let filter: Filter

        func body(content: Content) -> some View {
            #if os(iOS)
            if #available(iOS 26.0, *) {
                content.toolbar {
                    DefaultToolbarItem(kind: .search, placement: .bottomBar)
                    // Its own glass, not an end of the field's.
                    ToolbarSpacer(.fixed, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) { filter }
                }
            } else {
                content.toolbar { ToolbarItem(placement: .bottomBar) { filter } }
            }
            #else
            content.toolbar { ToolbarItem(placement: .primaryAction) { filter } }
            #endif
        }
    }

    /// Whether this device has Handoff, whose handoffs History keeps: a
    /// device without Apple Intelligence has none (Session.hasIntelligence).
    static var offersHandoff: Bool {
        Session.shared.hasIntelligence
    }

    private static var syncsHistory: Bool {
        Session.shared.preferences.iCloudSync && Session.shared.preferences.historySync
    }

    private static var thisDevice: String {
        #if os(iOS)
        String(localized: "This \(UIDevice.current.model)")
        #else
        String(localized: "This Mac")
        #endif
    }

    private static func colour(of space: UUID) -> SpaceColor {
        Session.shared.workspace.space(space)?.color ?? .gray
    }

    private func row(_ page: HistoryPage, time: Date, day: Bool) -> some View {
        Button {
            open(page.url, false)
            done()
        } label: {
            HistoryRow(page: page, time: time, showsDay: day)
        }
        .buttonStyle(.plain)
        .disabled(clearBusy)
        .contextMenu {
            Button("Open in New Tab", systemImage: "plus.square.on.square") {
                open(page.url, true)
                done()
            }
            Button("Copy Link", systemImage: "doc.on.doc") { copy(page.url) }
            Divider()
            Button("Delete from History…", systemImage: "trash", role: .destructive) { pageAsked = page }
        }
        .swipeActions {
            Button("Delete…", systemImage: "trash", role: .destructive) { pageAsked = page }
        }
    }

    /// A handoff: chosen, its Markdown file is offered again, with the
    /// words that went beside it (HistoryHandoff.prompt).
    private func row(_ handoff: HistoryHandoff, day: Bool) -> some View {
        reopening(handoff) {
            HandoffHistoryRow(handoff: handoff, showsDay: day)
        }
        .buttonStyle(.plain)
        .disabled(clearBusy)
        .contextMenu {
            ShareLink(item: handoff.file, message: Text(handoff.prompt)) {
                #if os(macOS)
                // A submenu of the Mac's sharing services, which a menu names without "…".
                Label("Share", systemImage: "square.and.arrow.up")
                #else
                Label("Share…", systemImage: "square.and.arrow.up")
                #endif
            }
            if let address = handoff.address {
                Button("Open in New Tab", systemImage: "plus.square.on.square") {
                    open(address, true)
                    done()
                }
                Button("Copy Link", systemImage: "doc.on.doc") { copy(address) }
            }
            Divider()
            Button("Delete from History…", systemImage: "trash", role: .destructive) { handoffAsked = handoff }
        }
        .swipeActions {
            Button("Delete…", systemImage: "trash", role: .destructive) { handoffAsked = handoff }
        }
    }

    /// What choosing a handoff does: on a Mac its file in Quick Look, whose
    /// panel shares it too; on iPhone and iPad the share sheet, as at first.
    @ViewBuilder
    private func reopening<Row: View>(_ handoff: HistoryHandoff, @ViewBuilder label: () -> Row) -> some View {
        #if os(macOS)
        Button { previewed = handoff.file } label: { label() }
        #else
        ShareLink(item: handoff.file, message: Text(handoff.prompt)) { label() }
        #endif
    }

    // MARK: Loading

    private struct Reload: Equatable {
        var space: UUID
        var text: String
        var filter: HistoryFilter
        var revision: Int
        var understood: String?
    }

    private var searchIdentity: Reload {
        Reload(space: spaceID, text: text, filter: filter, revision: recorder.revision, understood: understood?.text)
    }

    private var searchReady: Bool {
        loaded && loadingProblem == nil && searched == text.trimmingCharacters(in: .whitespaces)
    }

    private func stopSearchPaging() {
        pageSearch?.cancel()
        handoffSearch?.cancel()
        pageSearch = nil
        handoffSearch = nil
    }

    private func showMore(handoffs: Bool) {
        let identity = searchIdentity
        let words = text.trimmingCharacters(in: .whitespaces)
        let query = understood?.text == words ? understood?.query : nil
        let parsed = query ?? HistoryQuery.parse(words, now: Date())
        let limit = History.nextSearchLimit(after: handoffs ? handoffLimit : pageLimit)
        let task = Task {
            if handoffs {
                let result = await recorder.handoffSearchResult(space: spaceID, query: parsed, limit: limit, filter: filter)
                guard !Task.isCancelled, identity == searchIdentity else { return }
                switch result {
                case .success(let rows):
                    #if os(macOS)
                    selection = HistorySelection.firstNew(in: rows.map { .handoff($0.id) }, after: foundHandoffs.map { .handoff($0.id) })
                    #endif
                    foundHandoffs = rows
                    handoffLimit = limit
                case .failure(let issue): loadingProblem = issue
                }
                handoffSearch = nil
            } else {
                let result = await recorder.searchResult(space: spaceID, query: parsed, limit: limit, filter: filter)
                guard !Task.isCancelled, identity == searchIdentity else { return }
                switch result {
                case .success(let rows):
                    #if os(macOS)
                    selection = HistorySelection.firstNew(in: rows.map { .page(space: $0.space, key: $0.key) }, after: found.map { .page(space: $0.space, key: $0.key) })
                    #endif
                    found = rows
                    pageLimit = limit
                case .failure(let issue): loadingProblem = issue
                }
                pageSearch = nil
            }
        }
        if handoffs { handoffSearch = task } else { pageSearch = task }
    }

    /// Apple Intelligence, where it is on: Return asks it what the words mean.
    private static var asksIntelligence: Bool {
        Session.shared.preferences.intelligence && Session.shared.hasIntelligence
    }

    private static var searchPrompt: String {
        asksIntelligence ? String(localized: "Search or Describe") : String(localized: "Search History")
    }

    /// The words sent, as Apple Intelligence reads them: the words to look
    /// for, and the days, which a phrase like "last Friday" names.
    private func understand() async {
        let words = text.trimmingCharacters(in: .whitespaces)
        guard Self.asksIntelligence, !words.isEmpty, understood?.text != words, let mind = IntelligenceStatus.model() else { return }
        understanding = true
        defer { understanding = false }
        guard let query = await mind.historyQuery(words, now: Date()),
              text.trimmingCharacters(in: .whitespaces) == words else { return }
        understood = (words, query)
    }

    /// What Apple Intelligence searched for: its words, and its days.
    static func describe(_ query: HistoryQuery) -> String {
        var parts: [String] = []
        if !query.words.isEmpty { parts.append(String(localized: "“\(query.words)”")) }
        if let from = query.from, let to = query.to {
            let calendar = Calendar.current
            parts.append(calendar.isDate(from, inSameDayAs: to) ? name(of: from)
                         : String(localized: "\(from.formatted(.dateTime.month(.abbreviated).day())) to \(to.formatted(.dateTime.month(.abbreviated).day()))"))
        }
        return parts.isEmpty ? String(localized: "Everything") : parts.joined(separator: ", ")
    }

    private func load() async {
        stopPaging()
        #if os(macOS)
        selection = nil
        #endif
        stopSearchPaging()
        pageLimit = History.searchLimit
        handoffLimit = History.searchLimit
        loaded = false
        loadingProblem = nil
        let words = text.trimmingCharacters(in: .whitespaces)
        if words.isEmpty {
            found = []
            foundHandoffs = []
            searched = nil
        } else {
            // A moment after the last key, so each one doesn't ask the store.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            // What Apple Intelligence made of these words, if it was asked; else the words as typed.
            let query = understood?.text == words ? understood?.query : nil
            let parsed = query ?? HistoryQuery.parse(words, now: Date())
            let result = await recorder.searchResult(space: spaceID, query: parsed, limit: History.searchLimit, filter: filter)
            guard !Task.isCancelled else { return }
            let handoffs = await recorder.handoffSearchResult(space: spaceID, query: parsed, limit: History.searchLimit, filter: filter)
            guard !Task.isCancelled else { return }
            switch (result, handoffs) {
            case (.success(let pages), .success(let made)): found = pages; foundHandoffs = made; searched = words
            case (.failure(let issue), _), (_, .failure(let issue)): loadingProblem = issue; return
            }
        }
        // The days as well while searching, so what was cleared meanwhile is
        // gone when the search is. As many as were showing, so a change
        // doesn't take the list back to its start.
        let wanted = max(entries.count, Self.batch)
        let result = await recorder.entriesResult(space: spaceID, limit: wanted, filter: filter)
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let fresh):
            show(fresh)
            more = fresh.count == wanted
            loaded = true
        case .failure(let issue): loadingProblem = issue
        }
    }

    private func showOlder() {
        guard more, paging == nil else { return }
        paging = Task {
            await loadOlder()
            paging = nil
        }
    }

    private func stopPaging() {
        paging?.cancel()
        paging = nil
    }

    /// The next older visits, as the list's last row comes on screen; more
    /// of them while they add no row, all being to pages the last day shows.
    private func loadOlder() async {
        while more, let last = entries.last {
            let rows = days.reduce(0) { $0 + $1.entries.count }
            let result = await recorder.entriesResult(space: spaceID, before: last.time, limit: Self.batch, filter: filter)
            guard !Task.isCancelled else { return }
            let older: [HistoryEntry]
            switch result {
            case .success(let found): older = found
            case .failure(let issue): loadingProblem = issue; return
            }
            show(entries + older)
            more = older.count == Self.batch
            if days.reduce(0, { $0 + $1.entries.count }) > rows { return }
        }
    }

    private func show(_ list: [HistoryEntry]) {
        entries = list
        days = History.days(list)
    }

    // MARK: Letting go

    /// Every visit to the page in this space, as Safari deletes a history item.
    private func delete(_ page: HistoryPage) {
        stopPaging()
        guard !clearBusy else { return }
        handoffGoing = nil
        clearRequest = recorder.clearing(space: spaceID, scope: .page(History.digest(ofKey: page.key)))
        runClear()
    }

    private func clear(_ day: HistoryDay) {
        stopPaging()
        // To the day's last moment, not the next one's first (HistoryRemoval takes both ends).
        let end = (Calendar.current.date(byAdding: .day, value: 1, to: day.start) ?? day.start).addingTimeInterval(-0.001)
        let to = min(end, Date())
        guard !clearBusy else { return }
        handoffGoing = nil
        clearRequest = recorder.clearing(space: spaceID, scope: .range(from: day.start, to: to))
        runClear()
    }

    /// One handoff and its file: only this device has it, so nothing is
    /// kept of the deletion for other devices, as a clearing is.
    private func delete(_ handoff: HistoryHandoff) {
        stopPaging()
        guard !clearBusy else { return }
        clearRequest = nil
        handoffGoing = handoff
        runClear()
    }

    private func runClear() {
        guard !clearBusy, clearRequest != nil || handoffGoing != nil else { return }
        let (clearRequest, handoffGoing) = (clearRequest, handoffGoing)
        clearBusy = true
        Task {
            let result: Result<Void, HistoryOperationError>
            if let clearRequest {
                result = await recorder.clear(clearRequest)
            } else if let handoffGoing {
                result = await recorder.removeHandoff(handoffGoing.id)
            } else {
                result = .success(())
            }
            clearBusy = false
            switch result {
            case .success:
                self.clearRequest = nil
                self.handoffGoing = nil
                clearProblem = nil
                await load()
            case .failure(let issue): clearProblem = issue
            }
        }
    }

    private func copy(_ url: URL) {
        let clean = Tracking.clean(url)
        #if os(iOS)
        UIPasteboard.general.url = clean
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([clean as NSURL])
        #endif
    }

    /// "Today", "Yesterday", or the day's date, with its year only when it isn't this one.
    static func name(of day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        if calendar.isDate(day, equalTo: Date(), toGranularity: .year) {
            return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
        }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }
}

/// A page in the History list: its icon, its name and its site, and when.
private struct HistoryRow: View {
    let page: HistoryPage
    let time: Date
    /// The day as well as the time: in search results, which aren't by day.
    let showsDay: Bool

    var body: some View {
        HStack(spacing: 10) {
            SiteIconView(url: page.url, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(page.title.isEmpty ? site : page.title)
                    .lineLimit(1)
                Text(site)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(showsDay && !Calendar.current.isDateInToday(time) ? time.formatted(.dateTime.month(.abbreviated).day())
                                                                   : time.formatted(date: .omitted, time: .shortened))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var site: String {
        guard let host = page.url.host() else { return page.url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// A handoff in the History list: Handoff's mark, what was handed off,
/// where from (its site, or for a file on the device the file that went),
/// and when.
private struct HandoffHistoryRow: View {
    let handoff: HistoryHandoff
    /// The day as well as the time: in search results, which aren't by day.
    let showsDay: Bool
    @Environment(\.spaceColor) private var colour

    var body: some View {
        HStack(spacing: 10) {
            // Handoff's own mark, as its command has it: passed on, as a message is forwarded.
            Image(systemName: "arrowshape.turn.up.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(colour.color)
                .frame(width: 20, height: 20)
                .accessibilityLabel("Handoff")
            VStack(alignment: .leading, spacing: 1) {
                Text(handoff.title.isEmpty ? source : handoff.title)
                    .lineLimit(1)
                Text(source)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(showsDay && !Calendar.current.isDateInToday(handoff.time) ? handoff.time.formatted(.dateTime.month(.abbreviated).day())
                                                                            : handoff.time.formatted(date: .omitted, time: .shortened))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var source: String {
        guard let address = handoff.address else { return handoff.file.lastPathComponent }
        guard let host = address.host() else { return address.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Clear History: a stretch of time back from now, in one space or in
/// every one, with the handoffs made in it. What a page stored (sign-ins,
/// cookies) stays: that is the space's own, and a space is cleared of it
/// in its settings.
struct ClearHistoryView: View {
    let done: () -> Void
    @State private var span = HistorySpan.lastHour
    /// The space it clears; nil for every one.
    @State private var space: UUID?
    @ObservedObject private var session = Session.shared
    @ObservedObject private var sync = Sync.shared
    @State private var request: HistoryRecorder.ClearRequest?
    @State private var problem: HistoryOperationError?
    @State private var busy = false

    /// Opened from a window, on its space; from Settings on a Mac, which has none, on every space.
    init(spaceID: UUID?, done: @escaping () -> Void) {
        _space = State(initialValue: spaceID)
        self.done = done
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Clear", selection: $span) {
                        ForEach(HistorySpan.allCases, id: \.self) { span in
                            Text(span.label).tag(span)
                        }
                    }
                    .pickerStyle(.inline)
                    .disabled(busy || request != nil)
                    if session.workspace.spaces.count > 1 {
                        Picker("From", selection: $space) {
                            Text("Every Space").tag(UUID?.none)
                            ForEach(session.workspace.spaces) { space in
                                Text(space.name).tag(UUID?.some(space.id))
                            }
                        }
                        .disabled(busy || request != nil)
                    }
                } footer: {
                    Text(String(localized: "Removes history for the selected time and spaces, including visits hidden by the History list’s filters.")
                         + (HistoryView.offersHandoff ? " " + String(localized: "Handoffs made then are removed too, with their files.") : "")
                         + " " + sync.historyScopeDescription
                         + " " + String(localized: "Closed tabs in that time leave Reopen Closed Tab. Sign-ins and what sites have stored stay."))
                }
                if busy { ProgressView("Clearing history…") }
                if let problem {
                    Section {
                        Text(String(localized: "History was not cleared.") + " " + problem.message).foregroundStyle(.red)
                        Text("Your original time and space selection is kept for Retry.").font(.caption)
                        Button("Change Selection") { request = nil; self.problem = nil }.disabled(busy)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Clear History")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: done).disabled(busy)
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button(problem == nil ? "Clear History" : "Retry Clearing", role: .destructive) {
                        guard !busy else { return }
                        let asked = request ?? HistoryRecorder.shared.clearing(space: space, scope: span.scope(now: Date()))
                        request = asked
                        busy = true
                        Task {
                            let result = await HistoryRecorder.shared.clear(asked)
                            busy = false
                            switch result {
                            case .success: done()
                            case .failure(let issue): problem = issue
                            }
                        }
                    }
                    .disabled(busy)
                }
            }
        }
        .interactiveDismissDisabled(busy)
        #if os(macOS)
        .frame(width: 420)
        .frame(minHeight: 420)
        #endif
    }
}
