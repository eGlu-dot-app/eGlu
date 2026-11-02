import AppKit
import Engines
import PadCore
import SwiftUI

/// eGlu › Settings (⌘,): a sidebar of panes beside a grouped form, as
/// System Settings is (and Harper's Settings), with Back and Forward in the
/// toolbar (⌘[ and ⌘]). The window can be made larger, and every pane is a
/// grouped form, so its sections, rows and notes sit in the same places.
/// What is dragged into another order (the spaces, the pinned tabs) is a
/// list inside its section: a form's rows can't be dragged. The window opens
/// on the pane it was last on.
struct MacSettings: View {
    @AppStorage("settingsPane") private var pane = SettingsPane.general
    /// The panes seen before and after this one, for Back and Forward.
    @State private var backward: [SettingsPane] = []
    @State private var forward: [SettingsPane] = []

    var body: some View {
        NavigationSplitView {
            List(selection: chosen) {
                ForEach(SettingsPane.sidebar, id: \.self) { item in
                    Label {
                        Text(item.title)
                    } icon: {
                        SymbolTile(symbol: item.symbol, color: item.tint)
                    }
                    .tag(item)
                }
            }
            .listStyle(.sidebar)
            // One width, as System Settings' sidebar has. The Settings window
            // goes by neither column width at first (it gave the sidebar 144
            // points); a frame it can't go under, it does.
            .frame(minWidth: 215)
            .navigationSplitViewColumnWidth(215)
            // System Settings has no sidebar button.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch pane {
                case .general: GeneralSettings()
                case .iCloud: CloudSettings()
                case .spaces: SpaceSettings()
                case .pinned: PinnedTabSettings()
                case .blocking: BlockingSettings()
                case .writing: WritingSettings()
                case .writingRules: WritingRulesPage()
                case .extensions: ExtensionSettings()
                case .developer: DeveloperSettings()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(pane.title)
            // A row that opens a page a step below its pane, kept for Back as a pane is.
            .environment(\.openSettingsPane, go)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    ControlGroup {
                        Button(action: back) {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .disabled(backward.isEmpty)
                        .keyboardShortcut("[", modifiers: .command)
                        .help("Back")
                        Button(action: ahead) {
                            Label("Forward", systemImage: "chevron.right")
                        }
                        .disabled(forward.isEmpty)
                        .keyboardShortcut("]", modifiers: .command)
                        .help("Forward")
                    }
                    .controlGroupStyle(.navigation)
                }
            }
        }
        .frame(minWidth: 700, minHeight: 480)
        .background(UnifiedToolbar())
    }

    /// Choosing a pane in the sidebar keeps the one it leaves, for Back. A
    /// page a step below a pane has its pane chosen in the sidebar.
    private var chosen: Binding<SettingsPane?> {
        Binding {
            pane.above ?? pane
        } set: { next in
            guard let next, next != pane else { return }
            go(to: next)
        }
    }

    private func go(to next: SettingsPane) {
        guard next != pane else { return }
        backward.append(pane)
        forward.removeAll()
        pane = next
    }

    private func back() {
        guard let previous = backward.popLast() else { return }
        forward.append(pane)
        pane = previous
    }

    private func ahead() {
        guard let next = forward.popLast() else { return }
        backward.append(pane)
        pane = next
    }
}

enum SettingsPane: String, CaseIterable {
    case general, iCloud, spaces, pinned, blocking, writing, extensions, developer
    /// Writing › Rules: a page a step below Writing, not in the sidebar.
    case writingRules

    /// The panes the sidebar lists.
    static let sidebar = allCases.filter { $0.above == nil }

    /// The pane a page is a step below.
    var above: SettingsPane? {
        self == .writingRules ? .writing : nil
    }

    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .iCloud: return String(localized: "iCloud")
        case .spaces: return String(localized: "Spaces")
        case .pinned: return String(localized: "Pinned Tabs")
        case .blocking: return String(localized: "Ads and Trackers")
        case .writing: return String(localized: "Writing")
        case .writingRules: return String(localized: "Rules")
        case .extensions: return String(localized: "Extensions")
        case .developer: return String(localized: "Developer")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .iCloud: return "icloud.fill"
        case .spaces: return "square.stack.fill"
        case .pinned: return "pin.fill"
        case .blocking: return "shield.fill"
        case .writing, .writingRules: return "character.cursor.ibeam"
        case .extensions: return "puzzlepiece.extension.fill"
        case .developer: return "hammer.fill"
        }
    }

    /// The tile's colour in the sidebar, as System Settings' panes each have one.
    var tint: Color {
        switch self {
        case .general: return .gray
        case .iCloud: return .blue
        case .spaces: return .indigo
        case .pinned: return .orange
        case .blocking: return .green
        case .writing, .writingRules: return .pink
        case .extensions: return .teal
        case .developer: return .purple
        }
    }
}

/// Makes the Settings window's toolbar a unified one, as System Settings'
/// is: Back and Forward beside the pane's name, not centred under it as
/// SwiftUI's Settings window has its toolbar.
private struct UnifiedToolbar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Reader() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Reader: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.toolbarStyle = .unified
        }
    }
}

/// A pane's symbol, white on a rounded tile of its colour, as in System
/// Settings' sidebar.
private struct SymbolTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        // Each symbol fitted into the same box, half the tile: by a font
        // size, a wide one (the cloud, the puzzle piece) ran to the tile's
        // edges while a narrow one (the pin) stayed small.
        Image(systemName: symbol)
            .resizable()
            .scaledToFit()
            .frame(width: size * 0.5, height: size * 0.5)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(color.gradient))
            .accessibilityHidden(true)
    }
}

private enum SettingsMetrics {
    /// A row of a list inside a section, as high as the form's own rows.
    static let row: CGFloat = 34
}

// MARK: General

private struct GeneralSettings: View {
    @ObservedObject private var session = Session.shared
    @ObservedObject private var extensions = Extensions.shared
    @State private var isDefault = DefaultBrowser.isDefault
    @State private var clearingHistory = false

    var body: some View {
        Form {
            Section {
                // The name's capitals and the pictures' top edge as far from the
                // row's top as the name is from its left (10 points, measured):
                // the name raised by the room its line keeps over its capitals.
                HStack(alignment: .top) {
                    Text("Tabs")
                        .padding(.top, -3)
                    Spacer()
                    // Nil is the Mac's own way: in a sidebar.
                    TabsLayoutPicker(selection: Binding(get: { session.preferences.tabsPlacement ?? .sidebar },
                                                        set: { session.preferences.tabsPlacement = $0 }))
                        .padding(.bottom, 4)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Tabs")
            } header: {
                Text("Window")
            }
            Section {
                Toggle("Automatic Picture in Picture", isOn: $session.preferences.automaticPictureInPicture)
            } header: {
                Text("Picture in Picture")
            } footer: {
                Note(String(localized: "Keep playing videos and supported calls visible when you switch tabs, spaces or apps."))
            }
            Section {
                Picker("Links from other apps open in", selection: $session.preferences.linksFromApps) {
                    Text("A Little Window").tag(Preferences.LinksFromApps.littleWindow)
                    Text("A New Tab").tag(Preferences.LinksFromApps.newTab)
                }
                Toggle("Open other sites from pinned tabs in Peek", isOn: $session.preferences.peekFromPinnedTabs)
                // While an extension asks to show its page in new tabs.
                if !extensions.newTabChoices.isEmpty {
                    Picker("New tabs show", selection: Binding(get: { extensions.newTabPageID }, set: { extensions.setNewTabPage($0) })) {
                        Text("The Command Bar").tag(String?.none)
                        ForEach(extensions.newTabChoices) { item in
                            Text(item.name).tag(String?.some(item.id))
                        }
                    }
                }
            } header: {
                Text("Links")
            } footer: {
                Note(String(localized: "A little window keeps a link to itself until you open it in a tab with ⌃⌥O. A Peek shows a page over the tab it came from; pop-ups open in one too. ⌃⌥O opens it in a tab, ⌘W closes it."))
            }
            // Only in a build that may run Apple's helper (ApplePasswords).
            if ApplePasswords.entitled {
                ApplePasswordsSettings()
            }
            Section {
                Picker("Search engine", selection: $session.preferences.engine) {
                    ForEach(Destination.engines, id: \.id) { engine in
                        Text(engine.name).tag(engine.id)
                    }
                }
                Toggle("Send typing to \(Autocomplete.engineName(session.preferences.engine))", isOn: Binding(
                    get: { session.preferences.allowsRemoteSuggestions(for: session.preferences.engine) },
                    set: { session.preferences.setRemoteSuggestions($0) }))
                    .disabled(!Autocomplete.offersSuggestions(engine: session.preferences.engine))
                // Only where Apple Intelligence is there to suggest.
                if session.hasIntelligence {
                    Toggle("Suggest with Apple Intelligence", isOn: $session.preferences.intelligence)
                }
            } header: {
                Text("Search")
            } footer: {
                Note(Autocomplete.suggestionsDisclosure(engine: session.preferences.engine)
                     + (session.hasIntelligence ? " " + String(localized: "Apple Intelligence reads your tabs, bookmarks and history on this Mac and sends nothing anywhere.") : ""))
            }
            Section {
                Picker("Keep history for", selection: $session.preferences.historyRetention) {
                    ForEach(HistoryRetention.allCases, id: \.self) { retention in
                        Text(retention.label).tag(retention)
                    }
                }
                LabeledContent("Visited pages") {
                    Button("Clear History…") { clearingHistory = true }
                }
            } header: {
                Text("History")
            } footer: {
                Note(String(localized: "Each space keeps its own history. Pages older than this are deleted."))
            }
            .sheet(isPresented: $clearingHistory) {
                ClearHistoryView(spaceID: nil) { clearingHistory = false }
            }
            if session.hasIntelligence {
                Section {
                    Toggle("Use Handoff", isOn: $session.preferences.handoff)
                } header: {
                    Text("Handoff")
                } footer: {
                    Note(String(localized: "The page goes as text to the app you pick, such as Claude or ChatGPT, for your question. Nothing leaves this Mac until you pick one."))
                }
            }
            Section {
                LabeledContent("Default browser") {
                    if isDefault {
                        Label("eGlu", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Make Default…") { DefaultBrowser.ask() }
                    }
                }
            } footer: {
                Note(isDefault ? String(localized: "Links you open in other apps open here.") : String(localized: "Links you open in other apps open in your default browser."))
            }
            AppIconSettings()
            #if DIRECT
            UpdateSettings()
            #endif
        }
        .onAppear { isDefault = DefaultBrowser.isDefault }
        // macOS's dialog takes the front, so eGlu comes back once it's answered.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isDefault = DefaultBrowser.isDefault
        }
    }
}

// MARK: iCloud

/// Spaces, their bookmarks and pinned tabs, and each device's open tabs, in
/// the user's own iCloud (Sync.swift, the iPad's), with the iPhone and iPad
/// signed in to the same Apple Account.
private struct CloudSettings: View {
    @ObservedObject private var session = Session.shared
    @ObservedObject private var sync = Sync.shared

    private var syncing: Bool {
        Session.canSync && session.preferences.iCloudSync
    }

    var body: some View {
        Form {
            Section {
                Toggle("Sync with iCloud", isOn: $session.preferences.iCloudSync.animation())
                    .disabled(!Session.canSync)
                // What iCloud also carries, under it and only while it is on:
                // with iCloud off there is nothing for it to go through.
                if syncing {
                    Toggle("Sync history", isOn: $session.preferences.historySync)
                    SyncStatusView()
                }
                if !Session.canSync {
                    Label("This copy of eGlu isn't signed for iCloud. The signed copy from eGlu's releases, or one built with your team, syncs.",
                          systemImage: "exclamationmark.icloud")
                        .foregroundStyle(.secondary)
                } else if session.preferences.iCloudSync, let problem = sync.problem {
                    Label(problem, systemImage: "exclamationmark.icloud")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Note(String(localized: "Spaces, bookmarks and pinned tabs sync between your devices, and your Chrome Web Store extensions sync between Macs. Open tabs, sign-ins and what sites and extensions store stay on each device.")
                     + (syncing ? " " + String(localized: "Synced history is encrypted in iCloud.") + " " + sync.historyScopeDescription : ""))
            }
        }
    }
}

// MARK: Spaces

/// Every space, in the order ⌃1 to ⌃9 go to them, to drag into another
/// order, with + and − under them as a Mac's lists have; and the chosen
/// one's name, colour and icon in the section below.
private struct SpaceSettings: View {
    @ObservedObject private var session = Session.shared
    @State private var chosen: UUID?
    @State private var name = ""
    @State private var owner: NSWindow?

    var body: some View {
        let spaces = session.workspace.spaces
        let space = chosen.flatMap { session.workspace.space($0) }
        Form {
            Section {
                List(selection: $chosen) {
                    ForEach(spaces) { space in
                        SpaceSettingsRow(space: space)
                            .tag(space.id)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    }
                    .onMove { offsets, destination in
                        session.change { $0.moveSpaces(from: offsets, to: destination) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDisabled(spaces.count <= Self.rowsShown)
                .frame(height: CGFloat(min(spaces.count, Self.rowsShown)) * SettingsMetrics.row)
                AddRemove(canRemove: spaces.count > 1 && space != nil, add: add) {
                    if let chosen { remove(chosen) }
                }
            } header: {
                Text("Spaces")
            } footer: {
                Note(String(localized: "Drag a space to change its place. ⌃1 to ⌃9 go to the spaces in this order."))
            }
            if let space {
                Section {
                    TextField("Name", text: $name)
                    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Enter a name. This space is still named \(space.name) until a valid name is entered.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    LabeledContent("Colour") {
                        SpaceColours(space: space)
                    }
                    LabeledContent("Icon") {
                        SpaceSymbols(space: space)
                            .padding(.vertical, 4)
                    }
                } header: {
                    Text(space.name)
                }
                Section("Bookmarks") {
                    Button("Import Bookmarks into \(space.name)…") {
                        guard let owner else { return }
                        session.chooseBookmarksFile(into: space.id, in: owner)
                    }
                    .disabled(owner == nil)
                    Note(String(localized: "Choose an HTML bookmarks export from Chrome, Firefox or Safari, or a Safari ZIP export that includes Bookmarks."))
                }
            }
        }
        .background(BookmarkImportWindowReader { owner = $0 })
        .onAppear {
            if chosen == nil { chosen = spaces.first?.id }
            name = space?.name ?? ""
        }
        .onChange(of: chosen) { _, id in name = id.flatMap { session.workspace.space($0)?.name } ?? "" }
        .onChange(of: name) { _, now in
            guard let chosen, session.workspace.space(chosen)?.name != now else { return }
            session.change { $0.renameSpace(chosen, to: now) }
        }
    }

    /// Past this many the list scrolls, so the chosen space's settings stay in view.
    private static let rowsShown = 6

    private func add() {
        let id = session.change { $0.addSpace(named: String(localized: "Space \(session.workspace.spaces.count + 1)")) }
        chosen = id
    }

    private func remove(_ id: UUID) {
        guard let space = session.workspace.space(id), let owner else { return }
        let alert = NSAlert.removal(of: space)
        let finish = { (answer: NSApplication.ModalResponse) in
            guard answer == .alertFirstButtonReturn else { return }
            Session.shared.removeSpace(id)
            chosen = Session.shared.workspace.spaces.first?.id
        }
        alert.beginSheetModal(for: owner, completionHandler: finish)
    }
}

/// A space in Settings' list: the handle, its icon on its colour, its name,
/// and how many tabs it has.
private struct SpaceSettingsRow: View {
    let space: Space

    var body: some View {
        HStack(spacing: 8) {
            DragHandle()
            Image(systemName: space.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(space.color.ink)
                .frame(width: 22, height: 22)
                .background(space.color.color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(space.name)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(BrowserText.tabCount(space.tabs.count))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(height: SettingsMetrics.row)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Drag to change the order.")
    }
}

/// + and − at the foot of a list, as a Mac's lists have them.
private struct AddRemove: View {
    let canRemove: Bool
    let add: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: add) {
                Image(systemName: "plus").frame(width: 24, height: 20)
            }
            .help("New Space")
            .accessibilityLabel("New Space")
            Divider().frame(height: 14)
            Button(action: remove) {
                Image(systemName: "minus").frame(width: 24, height: 20)
            }
            .disabled(!canRemove)
            .help("Remove Space…")
            .accessibilityLabel("Remove Space")
            Spacer()
        }
        .buttonStyle(.borderless)
    }
}

// MARK: Pinned Tabs

/// Each space's pinned tabs, in their order, to drag into another and to
/// show or hide in this Mac's sidebar. A hidden one stays pinned, in its
/// place and on your other devices: only this Mac's sidebar goes without
/// it (Preferences.hiddenPinnedTabs). The order is the space's, everywhere.
private struct PinnedTabSettings: View {
    @ObservedObject private var session = Session.shared

    var body: some View {
        let spaces = session.workspace.spaces.filter { $0.pinnedCount > 0 }
        Form {
            if spaces.isEmpty {
                Section {
                    Text("No pinned tabs yet.")
                        .foregroundStyle(.secondary)
                } footer: {
                    Note(String(localized: "Pin a tab from its menu, or with ⇧⌘D, to keep it at the top."))
                }
            }
            ForEach(spaces) { space in
                Section {
                    let pinned = Array(space.tabs.prefix(space.pinnedCount))
                    List {
                        ForEach(pinned) { tab in
                            PinnedSettingsRow(tab: tab, shown: shown(tab.id))
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        }
                        .onMove { offsets, destination in
                            session.change { $0.movePinned(in: space.id, from: offsets, to: destination) }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(true)
                    .frame(height: CGFloat(pinned.count) * SettingsMetrics.row)
                    .environment(\.spaceColor, space.color)
                } header: {
                    HStack {
                        Label(space.name, systemImage: space.symbol)
                        Spacer()
                        // What the switches at the rows' ends say.
                        Text("View on macOS")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    if space.id == spaces.last?.id {
                        Note(String(localized: "Drag a tab to change its place everywhere. A hidden tab stays pinned; only this Mac leaves it out."))
                    }
                }
            }
        }
    }

    private func shown(_ tab: UUID) -> Binding<Bool> {
        Binding(get: { !session.preferences.hiddenPinnedTabs.contains(tab) },
                set: { show in
                    if show {
                        session.preferences.hiddenPinnedTabs.remove(tab)
                    } else {
                        session.preferences.hiddenPinnedTabs.insert(tab)
                    }
                })
    }
}

/// A pinned tab in Settings' list: the handle, its icon and name, and
/// whether this Mac's sidebar shows it.
private struct PinnedSettingsRow: View {
    let tab: TabRecord
    let shown: Binding<Bool>

    var body: some View {
        HStack(spacing: 8) {
            DragHandle()
            SiteIconView(url: tab.pinned ?? tab.url, size: 18)
            Text(tab.label)
                .lineLimit(1)
                .foregroundStyle(shown.wrappedValue ? .primary : .secondary)
            Spacer(minLength: 8)
            Toggle("View on macOS", isOn: shown)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .frame(height: SettingsMetrics.row)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Writing

/// Settings › Writing: grammar checking in pages, with Harper on this Mac
/// (WritingChecker, the Engines package). The rule and dictionary lists
/// follow harperSwift's own (Shared/Writing/WritingLists.swift).
private struct WritingSettings: View {
    @Environment(\.openSettingsPane) private var openSettingsPane
    @ObservedObject private var access = AccessibilityAccess.shared
    @ObservedObject private var fields = FrontField.shared
    @ObservedObject private var session = Session.shared
    @State private var rules: [GrammarRule] = []
    @State private var words: [String] = WritingWords.load()
    @State private var harperDesktop: [String]? = nil

    var body: some View {
        Form {
            Section {
                Toggle("Check Grammar and Spelling in Pages", isOn: $session.preferences.writing)
            } footer: {
                Note(String(localized: "English only. Harper checks it on this Mac; nothing you type is sent anywhere."))
            }
            Section {
                // Other apps are checked by the linter pages turn on, so
                // the switch waits for that one; the footer says so.
                Toggle("Check in Other Apps", isOn: otherApps)
                    .disabled(!session.preferences.writing)
                Group {
                    if session.preferences.writingOtherApps, !access.isTrusted {
                        Note(String(localized: "Allow eGlu in System Settings › Privacy & Security › Accessibility."))
                        Button(String(localized: "Open Accessibility Settings")) {
                            access.openSettings()
                        }
                    }
                    if fields.harperDesktopRunning {
                        Note(String(localized: "Harper Desktop is checking other apps, so eGlu leaves them to it."))
                    }
                    ForEach(appRows, id: \.id) { row in
                        Toggle(isOn: checked(row.id)) {
                            HStack(spacing: 8) {
                                // The size System Settings gives an app's icon in a row (Login Items), so the
                                // rows are as tall as the switches' around them.
                                Image(nsImage: row.icon)
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(width: 20, height: 20)
                                Text(row.name)
                            }
                        }
                        .contextMenu {
                            Button(String(localized: "Remove from List")) { remove(row.id) }
                                .disabled(!WritingApps.canRemove(row.id, choices: session.preferences.writingApps))
                        }
                    }
                    Toggle("Check New Apps", isOn: $session.preferences.writingNewApps)
                }
                .disabled(!session.preferences.writing || !session.preferences.writingOtherApps)
            } header: {
                Text("In Other Apps")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if !session.preferences.writing {
                        Note(String(localized: "Turn on Check Grammar and Spelling in Pages first: other apps are checked by the same Harper."))
                    }
                    Note(String(localized: "eGlu reads the text of the field you type in, while you type, to check it on this Mac. It keeps nothing and sends nothing."))
                    // Turned off is not unwatched (FrontField): it says so,
                    // and how an app leaves the list.
                    Note(String(localized: "An app turned off is still watched for a text field in use, to list it here, but its text isn't read. Control-click an app to remove it."))
                }
            }
            // How Harper checks, which means nothing while it doesn't: every
            // section after the switch waits for it.
            Group {
                Section {
                    Picker("English", selection: $session.preferences.writingDialect) {
                        // Harper's dialects, in its own order.
                        ForEach(Dialect.allCases, id: \.rawValue) { dialect in
                            Text(dialect.name).tag(dialect.rawValue)
                        }
                    }
                }
                Section {
                    // A page of their own, a step below, where they can be searched: there are many.
                    Button {
                        openSettingsPane(.writingRules)
                    } label: {
                        HStack {
                            Text("Rules")
                            Spacer()
                            Text(WritingRulesPage.summary(rules: rules, changed: session.preferences.writingRules))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Section {
                    WritingDictionaryList(words: $words)
                    if let harperDesktop, !harperDesktop.isEmpty {
                        Button(String(localized: "Add Harper Desktop's Words")) {
                            WritingWords.save(words + harperDesktop)
                            words = WritingWords.load()
                        }
                        .disabled(Set(harperDesktop).isSubset(of: words))
                    }
                } header: {
                    Text("Dictionary")
                }
                Section {
                    if session.preferences.writingOffSites.isEmpty {
                        Text("Checking is on for every site.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.preferences.writingOffSites, id: \.self) { site in
                        LabeledContent(site) {
                            Button(String(localized: "Remove")) {
                                session.preferences.writingOffSites.removeAll { $0 == site }
                            }
                        }
                    }
                } header: {
                    Text("Sites")
                } footer: {
                    Note(String(localized: "Turn checking off for a site from the page's menu."))
                }
            }
            .disabled(!session.preferences.writing)
        }
        .onAppear {
            rules = WritingChecker.rules()
            harperDesktop = WritingWords.harperDesktopWords()
        }
        // The file changed under the linter: it takes the words at once,
        // not at the next change to the settings.
        .onChange(of: words) { WritingChecker.shared.wordsChanged() }
    }

    /// Check in Other Apps: turning it on asks for Accessibility, the
    /// permission the reading takes, only then (Docs/Tasks/03, B3).
    private var otherApps: Binding<Bool> {
        Binding(
            get: { session.preferences.writingOtherApps },
            set: { on in
                session.preferences.writingOtherApps = on
                if on { AccessibilityAccess.shared.ask() }
            })
    }

    /// The apps in the list: the curated ones and every app eGlu has seen a
    /// field of or been told a choice for, by name. An app not on this Mac
    /// has nothing to check and no name to show, so it isn't listed.
    private var appRows: [(id: String, name: String, icon: NSImage)] {
        let ids = WritingApps.listed(seen: fields.seenApps, choices: session.preferences.writingApps)
        return ids.compactMap { id -> (id: String, name: String, icon: NSImage)? in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            let bundle = Bundle(url: url)
            let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            return (id, name, NSWorkspace.shared.icon(forFile: url.path))
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// An app's switch: the person's choice where made, else the curated
    /// default or Check New Apps. A choice equal to the default is not kept.
    private func checked(_ id: String) -> Binding<Bool> {
        Binding(
            get: { WritingApps.isOn(id, choices: session.preferences.writingApps,
                                    newApps: session.preferences.writingNewApps) },
            set: { on in
                let base = WritingApps.curated.contains(id) || session.preferences.writingNewApps
                session.preferences.writingApps[id] = on == base ? nil : on
            })
    }

    /// Remove from List: one change to the settings, so they are saved once.
    private func remove(_ id: String) {
        var choices = session.preferences.writingApps
        fields.removeFromList(id, choices: &choices)
        session.preferences.writingApps = choices
    }
}

// MARK: Ads and Trackers

/// Blocking on or off, and each filter list with a switch, what it takes
/// away, whose it is (as its licence asks) and how its copy stands.
private struct BlockingSettings: View {
    @ObservedObject private var session = Session.shared
    @ObservedObject private var blocker = ContentBlocker.shared

    var body: some View {
        Form {
            Section {
                Toggle("Block ads and trackers", isOn: $session.preferences.blocksContent)
            } footer: {
                Note(blocker.summary)
            }
            Section("Filter Lists") {
                ForEach(ContentBlocking.lists) { list in
                    Toggle(isOn: uses(list)) {
                        Text(list.name)
                        Text(list.about)
                        Text(note(for: list))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .disabled(!session.preferences.blocksContent)
        }
    }

    private func uses(_ list: FilterList) -> Binding<Bool> {
        Binding(get: { session.preferences.uses(list, languages: ContentBlocker.languages, region: ContentBlocker.region) },
                set: { session.preferences.filterLists[list.id] = $0 })
    }

    private func note(for list: FilterList) -> String {
        let credit = String(localized: "By \(list.credit)")
        switch blocker.states[list.id] ?? .off {
        case .off:
            return credit
        case .waiting:
            return credit + " · " + String(localized: "Getting ready…")
        case .missing:
            return credit + " · " + String(localized: "Not downloaded yet. eGlu tries again when it opens.")
        case .ready(let made, let rules):
            let count = String(localized: "\(rules) rules")
            guard let made else { return credit + " · " + count }
            return credit + " · " + made.formatted(date: .abbreviated, time: .omitted) + " · " + count
        }
    }
}

/// A section's note, under it: smaller and quieter than its rows, wrapping
/// as long as it needs.
private struct Note: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Developer

/// The developer mode's settings: whether local sites get it by
/// themselves, the sites it remembers a choice for, JSON pages formatted,
/// and which keys its tools answer to.
private struct DeveloperSettings: View {
    @ObservedObject private var session = Session.shared
    @State private var chosen: String?

    /// The sites a choice is remembered for, alphabetical as the lists are.
    private var sites: [String] {
        session.preferences.developerSites.keys.sorted()
    }

    var body: some View {
        Form {
            Section {
                Toggle("Developer Mode on Local Sites", isOn: $session.preferences.developerLocal)
            } footer: {
                Note(String(localized: "Localhost and the local network get the developer bar by themselves. When you turn it on or off for a site, from the page's menu or the Developer menu, that site keeps your choice."))
            }
            if !sites.isEmpty {
                Section {
                    List(selection: $chosen) {
                        ForEach(sites, id: \.self) { site in
                            HStack(spacing: 8) {
                                Text(site)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(session.preferences.developerSites[site] == true
                                     ? String(localized: "On") : String(localized: "Off"))
                                    .foregroundStyle(.secondary)
                                Button {
                                    session.preferences.developerSites[site] = nil
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help("Remove")
                                .accessibilityLabel("Remove \(site)")
                            }
                            .frame(height: 24)
                            .contentShape(Rectangle())
                            .tag(site)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(sites.count <= Self.rowsShown)
                    .frame(height: CGFloat(min(sites.count, Self.rowsShown)) * SettingsMetrics.row)
                } header: {
                    Text("Remembered Sites")
                }
            }
            Section {
                Toggle("Format JSON", isOn: $session.preferences.formatJSON)
            } footer: {
                Note(String(localized: "JSON pages show as a tree you can fold. When this is off, they show the text as it came."))
            }
            Section {
                Picker("Developer Tools' Keys", selection: $session.preferences.developerKeys) {
                    Text(verbatim: "⌃⌥").tag(Preferences.DeveloperKeys.controlOption)
                    Text(verbatim: "⌥⌘").tag(Preferences.DeveloperKeys.optionCommand)
                }
            } footer: {
                Note(session.preferences.developerKeys == .optionCommand
                     ? String(localized: "The developer tools use ⌥⌘, as in Chrome. Pages will no longer get these keys.")
                     : String(localized: "The developer tools use ⌃⌥, as the rest of eGlu's own keys do, which pages leave alone."))
            }
        }
    }

    /// Past this many sites the list scrolls.
    private static let rowsShown = 6
}

/// Goes to a pane, or a page a step below one, as the sidebar does, kept for Back.
private struct OpenSettingsPane: EnvironmentKey {
    static let defaultValue: (SettingsPane) -> Void = { _ in }
}

extension EnvironmentValues {
    var openSettingsPane: (SettingsPane) -> Void {
        get { self[OpenSettingsPane.self] }
        set { self[OpenSettingsPane.self] = newValue }
    }
}
