import WritingServiceKit
import GameController
import PadCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings categories, with direct routing from command search.
struct SettingsView: View {
    @ObservedObject var session: Session
    let spaceID: UUID
    var anchor: SettingsAnchor?
    var phoneLayout = Device.phone
    var padLayout = !Device.phone
    let done: () -> Void
    @State private var keyboard = GCKeyboard.coalesced != nil
    @State private var path: [SettingsGroup] = []
    @State private var openedAnchor = false
    // Import failures and parsed-file recovery survive returning to categories.
    @State private var importing = false
    @State private var imported: BookmarkImportOutcome?
    @State private var importWorking = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(SettingsGroup.allCases.filter {
                    $0.shown(padLayout: padLayout, keyboard: keyboard)
                }, id: \.self) { group in
                    NavigationLink(value: group) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.shownTitle(padLayout: padLayout))
                            Text(group.shownDetail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                // Last, as an app's acknowledgements are.
                Section {
                    NavigationLink(String(localized: "Acknowledgements")) { LicencesView() }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) }
            }
            .navigationDestination(for: SettingsGroup.self) { group in
                SettingsDetail(session: session, spaceID: spaceID, group: group,
                               anchor: anchor?.group == group ? anchor : nil,
                               phoneLayout: phoneLayout, padLayout: padLayout,
                               done: done, keyboard: keyboard,
                               importing: $importing, imported: $imported, importWorking: $importWorking)
            }
            .task {
                guard !openedAnchor else { return }
                openedAnchor = true
                if let anchor,
                   anchor.group.shown(padLayout: padLayout, keyboard: keyboard) {
                    path = [anchor.group]
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in keyboard = true }
            .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in
                keyboard = GCKeyboard.coalesced != nil
            }
        }
    }
}

private struct SettingsDetail: View {
    @ObservedObject var session: Session
    /// The space of the window Settings opened from, which imports go into.
    let spaceID: UUID
    let group: SettingsGroup
    /// The part to open at, when the address bar sent one (SettingsAnchor).
    var anchor: SettingsAnchor?
    /// Which layouts' parts to have (Device.settingsLayouts): a phone-width
    /// window's (one bar at the bottom, Desktop View), an iPad's (the tabs'
    /// place, the trackpad, shortcuts), or, on the iPhone Duo, both.
    var phoneLayout = Device.phone
    var padLayout = !Device.phone
    let done: () -> Void
    /// A keyboard with keys is attached: a phone's Settings then have the
    /// keyboard's parts too (its shortcuts work, Browser.phoneKeys).
    let keyboard: Bool
    @Binding var importing: Bool
    @Binding var imported: BookmarkImportOutcome?
    @Binding var importWorking: Bool
    @State private var clearingHistory = false
    @AppStorage(Menus.controlShortcutsKey) private var controlShortcuts = false
    /// The part the address bar sent Settings to, for a moment after it opens there.
    @State private var lit: SettingsAnchor?
    /// Apple Intelligence on this device, as Settings opens (Intelligence.swift).
    private let intelligence = IntelligenceStatus.current

    /// Where what is typed goes, and that Apple Intelligence stays on the device where it is there.
    private var searchFooter: String {
        var text = Autocomplete.suggestionsDisclosure(engine: session.preferences.engine)
        if intelligence == .ready {
            text += " " + String(localized: "Apple Intelligence works on this \(Device.name) and sends nothing anywhere.")
        }
        return text
    }

    /// Settings › Developer's note: where the bar comes by itself, and the
    /// keys' sentence only where there is a keyboard to press them on.
    private var developerNote: String {
        let bar = String(localized: "Localhost and the local network get the developer bar by themselves. When you turn it on or off for a site, from the page's menu or the Developer menu, that site keeps your choice.")
        guard keyboard else { return bar }
        let keys = session.preferences.developerKeys == .optionCommand
            ? String(localized: "The developer tools use ⌥⌘, as in Chrome. Pages will no longer get these keys.")
            : String(localized: "The developer tools use ⌃⌥, as the rest of eGlu's own keys do, which pages leave alone.")
        return bar + " " + keys
    }

    var body: some View {
        // Direct search opens this category and scrolls to its section.
        ScrollViewReader { scroller in
            Form {
                if group == .general {
                    DefaultBrowserSection()
                    AppIconSection()
                }
                if group == .spaces {
                    CloudSection(session: session)
                }
                if group == .writing {
                    WritingSection(session: session)
                }

                if group == .browsing {
                    if phoneLayout {
                        Section {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Cursor speed")
                                HStack(spacing: 10) {
                                    Image(systemName: "tortoise.fill").foregroundStyle(.secondary)
                                    Slider(value: $session.preferences.cursorSpeed, in: DesktopView.cursorSpeeds)
                                        .accessibilityLabel("Cursor speed")
                                    Image(systemName: "hare.fill").foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        } header: {
                            SettingsHeader("Trackpad View", .desktopView)
                        }
                        Section {
                            // Its choices as rows: a menu beside a label this long has no room on a phone.
                            Picker("The address bar shows", selection: $session.preferences.address) {
                                Text("The page's address").tag(AddressMode.always)
                                Text("The page's title").tag(AddressMode.automatic)
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        } header: {
                            SettingsHeader("The address bar shows", .addressBar)
                        } footer: {
                            Text("Sign-in pages always show their address.")
                        }
                    }
                    if padLayout {
                    Section {
                        // The name's capitals and the pictures' top edge as far from the
                        // row's top as the name is from its left (17 points, measured).
                        HStack(alignment: .top) {
                            Text("Tabs")
                                .padding(.top, -1.5)
                            Spacer()
                            // Nil is the iPad's own way: along the top.
                            TabsLayoutPicker(selection: Binding {
                                session.preferences.tabsPlacement ?? .top
                            } set: {
                                session.preferences.tabsPlacement = $0
                            })
                            .padding(.top, 2)
                            .padding(.bottom, 6)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Tabs")
                        if session.preferences.tabsPlacement == .sidebar {
                            Toggle("Show the sidebar", isOn: $session.preferences.tabBar)
                        } else {
                            // Asked once: the phone layout's own part above already asks it.
                            if !phoneLayout {
                                Picker("The tab you are on shows", selection: $session.preferences.address) {
                                    Text("Its address").tag(AddressMode.always)
                                    Text("Its title").tag(AddressMode.automatic)
                                }
                            }
                            Toggle("Show the tab bar", isOn: $session.preferences.tabBar)
                        }
                    } header: {
                        SettingsHeader("Window", .window)
                    } footer: {
                        if session.preferences.tabsPlacement == .sidebar {
                            Text("With the sidebar hidden, ⌃⌥K lists every tab.")
                        } else {
                            Text("Sign-in pages always show their address. With the tab bar hidden, ⌃⌥K lists every tab.")
                        }
                    }
                    }

                }

                if group == .spaces {
                    Section {
                        NavigationLink {
                            SpaceList(session: session)
                        } label: {
                            HStack {
                                Text("Spaces")
                                Spacer()
                                Text("\(session.workspace.spaces.count)")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        NavigationLink {
                            PinnedTabList(session: session)
                        } label: {
                            HStack {
                                Text("Pinned Tabs")
                                Spacer()
                                Text("\(session.workspace.spaces.reduce(0) { $0 + $1.pinnedCount })")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        Button("Import Bookmarks into \(session.workspace.space(spaceID)?.name ?? String(localized: "This Space"))…") {
                            importing = true
                        }
                        .disabled(importWorking)
                        if importWorking { ProgressView("Importing bookmarks") }
                        BookmarkImportStatusView(session: session, outcome: $imported, chooseFile: { importing = true })
                    } header: {
                        SettingsHeader("Spaces and bookmarks", .spaces)
                    } footer: {
                        Text("Import an HTML bookmarks export from Chrome, Firefox or Safari, or a Safari ZIP export that includes bookmarks.")
                    }

                }

                if group == .browsing {
                    Section {
                        Stepper(value: $session.preferences.limits.lightOffScreen, in: 0...6) {
                            Text("Inactive page limit: \(session.preferences.limits.lightOffScreen)")
                        }
                    } header: {
                        SettingsHeader("Memory", .memory)
                    } footer: {
                        Text("Up to this many less demanding pages stay loaded in the background. Other inactive pages may reload when reopened.")
                    }

                    LinkMenuSection(session: session)

                    // An iPhone has no developer group, but JSON pages are
                    // still shown formatted there, so the switch lives here.
                    if Device.phone {
                        Section {
                            Toggle("Format JSON", isOn: $session.preferences.formatJSON)
                        }
                    }
                }

                if group == .input {
                    if padLayout {
                    Section {
                        Picker("Two-finger scroll", selection: $session.preferences.wheel) {
                            Text("As each site needs").tag(WheelMode?.none)
                            Text("Help when normal scrolling fails").tag(WheelMode?.some(.auto))
                            Text("Always send scrolling to the page").tag(WheelMode?.some(.always))
                            Text("Use system scrolling only").tag(WheelMode?.some(.off))
                        }
                        Picker("Tab and arrow keys", selection: $session.preferences.keys) {
                            Text("As each site needs").tag(Override.site)
                            Text("Send to the page first").tag(Override.on)
                            Text("Leave to the system").tag(Override.off)
                        }
                        Toggle("Use the site's cursor style", isOn: $session.preferences.pageCursors)
                    } header: {
                        SettingsHeader("Trackpad and keyboard", .trackpad)
                    } footer: {
                        Text("Some web apps provide their own cursor shapes. Turn this off to use system cursor styles.")
                    }
                    } else if keyboard {
                    Section {
                        Picker("Tab and arrow keys", selection: $session.preferences.keys) {
                            Text("As each site needs").tag(Override.site)
                            Text("Send to the page first").tag(Override.on)
                            Text("Leave to the system").tag(Override.off)
                        }
                    } header: {
                        SettingsHeader("Keyboard", .trackpad)
                    }
                    }

                }

                if group == .privacy {
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
                        // Only where Apple Intelligence is there to suggest: not turned off, not still getting ready.
                        if intelligence == .ready {
                            Toggle("Suggest with Apple Intelligence", isOn: $session.preferences.intelligence)
                        }
                    } header: {
                        SettingsHeader("Search", .search)
                    } footer: {
                        Text(searchFooter)
                    }

                    Section {
                        Picker("Keep history for", selection: $session.preferences.historyRetention) {
                            ForEach(HistoryRetention.allCases, id: \.self) { retention in
                                Text(retention.label).tag(retention)
                            }
                        }
                        Button("Clear History…") { clearingHistory = true }
                    } header: {
                        SettingsHeader("History", .history)
                    } footer: {
                        Text("Each space keeps its own history. Pages older than this are deleted.")
                    }
                    .sheet(isPresented: $clearingHistory) {
                        ClearHistoryView(spaceID: spaceID) { clearingHistory = false }
                    }

                    BlockingSection(session: session)

                    // Nothing of Handoff without Apple Intelligence: not even its switch.
                    if session.hasIntelligence {
                        HandoffSection(session: session)
                    }

                }

                // Developer mode is the Mac's and the iPad's: none on an iPhone.
                if group == .developer && !Device.phone {
                    Section {
                        Toggle("Developer Mode on Local Sites", isOn: $session.preferences.developerLocal)
                        let sites = session.preferences.developerSites.keys.sorted()
                        if !sites.isEmpty {
                            ForEach(sites, id: \.self) { site in
                                HStack {
                                    Text(site)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(session.preferences.developerSites[site] == true ? String(localized: "On") : String(localized: "Off"))
                                        .foregroundStyle(.secondary)
                                    Button(String(localized: "Remove")) {
                                        session.preferences.developerSites[site] = nil
                                    }
                                }
                            }
                        }
                        Toggle("Format JSON", isOn: $session.preferences.formatJSON)
                        // The keys' choice needs a keyboard to press them
                        // on, as the Shortcuts list does (Device.keys).
                        if keyboard {
                            Picker("Developer Tools' Keys", selection: $session.preferences.developerKeys) {
                                Text(verbatim: "⌃⌥").tag(Preferences.DeveloperKeys.controlOption)
                                Text(verbatim: "⌥⌘").tag(Preferences.DeveloperKeys.optionCommand)
                            }
                            .onChange(of: session.preferences.developerKeys) { _, _ in
                                UIMenuSystem.main.setNeedsRebuild()
                            }
                        }
                    } header: {
                        SettingsHeader("Developer", .developer)
                    } footer: {
                        Text(developerNote)
                    }
                }

                // The diagnostics panel's switch, at the developer group's foot.
                if group == .developer && Device.diagnostics {
                    Section {
                        Toggle("Show developer diagnostics", isOn: $session.preferences.diagnostics)
                    } header: {
                        SettingsHeader("Developer diagnostics", .diagnostics)
                    } footer: {
                        Text("Developer information for troubleshooting. Nothing in this panel is sent from your device.")
                    }
                }

                if group == .shortcuts && (padLayout || keyboard) {
                Section {
                    Toggle("Use Control shortcuts", isOn: $controlShortcuts)
                        .onChange(of: controlShortcuts) { _, _ in UIMenuSystem.main.setNeedsRebuild() }
                    Text("Uses Control instead of Control-Option for browser commands, avoiding VoiceOver's modifier. These keys can conflict with webpage or text-editing shortcuts. Reserved browser shortcuts stay the same.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // By the menu each is in, as the command bar lists them.
                    ForEach(ShortcutGroup.allCases.flatMap(\.commands).filter { Device.offers($0, compact: !padLayout) }, id: \.self) { command in
                        HStack {
                            Text(command.title)
                            Spacer()
                            KeyCaps(keys: Menus.keyCaps(for: command) ?? [])
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(command.title)
                        .accessibilityValue(Menus.keyCaps(for: command)?.joined() ?? "")
                    }
                    HStack {
                        Text("A tab by its place, the last one")
                        Spacer()
                        Text(controlShortcuts ? "⌃1 … ⌃9" : "⌃⌥1 … ⌃⌥9").foregroundStyle(.secondary).monospaced()
                    }
                } header: {
                    SettingsHeader("Shortcuts", .shortcuts)
                }

                Section("Known limitations") {
                    Text(Device.phone
                         ? "iOS keeps its own shortcuts (⌘Tab, ⌘Space, the Globe key); no app can give those to a page."
                         : "iPadOS keeps its own shortcuts (⌘Tab, ⌘Space, the Globe key) and its three- and four-finger gestures; no app can give those to a page.")
                    Text("With VoiceOver on, Control-Option is VoiceOver's modifier. Use Control shortcuts above or choose browser commands from the menus.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(group.shownTitle(padLayout: padLayout))
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.html, .zip]) { result in
                guard case .success(let file) = result else { imported = .cancelled; return }
                importWorking = true
                // Readable until the import has read it, which it does away from the main thread.
                let scoped = file.startAccessingSecurityScopedResource()
                session.importBookmarks(from: file, into: spaceID) { outcome in
                    if scoped { file.stopAccessingSecurityScopedResource() }
                    imported = outcome
                    importWorking = false
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: done)
                }
            }
            .environment(\.settingsLit, lit)
            // Sent to a part, the list goes to that section's first row, at
            // the top: its header, just above, would be under the title bar.
            // This much more kept clear there leaves the header in view. (A
            // list scrolls a row to its top, middle or bottom, nowhere between.)
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear
                    .frame(height: anchor == nil ? 0 : SettingsHeader.room)
                    .allowsHitTesting(false)
            }
            .task {
                guard let anchor else { return }
                // Once the list has its rows: before that there is nowhere to scroll to.
                try? await Task.sleep(for: .milliseconds(120))
                scroller.scrollTo(anchor, anchor: .top)
                lit = anchor
                try? await Task.sleep(for: .seconds(2))
                withAnimation(.easeOut(duration: 0.6)) { lit = nil }
            }
            }
    }
}

extension EnvironmentValues {
    /// The section highlighted after a direct search result opens it.
    @Entry var settingsLit: SettingsAnchor?
}

/// A section's header in Settings, which is also a place the address bar
/// can send Settings to (SettingsAnchor): the list scrolls to it, and it
/// shows in the accent colour for a moment, so the eye finds the section
/// among the others on screen (the last ones can't be brought to the top).
struct SettingsHeader: View {
    let title: String
    let anchor: SettingsAnchor
    @Environment(\.settingsLit) private var lit

    /// A header's height with the gap over it, about: what the list keeps
    /// clear at its top when it is sent to a section (SettingsView).
    static let room: CGFloat = 44

    init(_ title: String, _ anchor: SettingsAnchor) {
        self.title = BrowserText.localized(title)
        self.anchor = anchor
    }

    var body: some View {
        Text(title)
            // Left as the list draws its headers but while it is lit.
            .foregroundStyle(lit == anchor ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.foreground))
            .id(anchor)
    }
}

/// Settings' iCloud section: Sync with iCloud, and under it, while it is on,
/// Sync history.
struct CloudSection: View {
    @ObservedObject var session: Session
    @ObservedObject var sync = Sync.shared

    var body: some View {
        let syncing = session.preferences.iCloudSync
        Section {
            Toggle("Sync with iCloud", isOn: $session.preferences.iCloudSync.animation())
            // What iCloud also carries, under it and only while it is on:
            // with iCloud off there is nothing for it to go through.
            if syncing {
                Toggle("Sync history", isOn: $session.preferences.historySync)
                SyncStatusView()
            }
            if syncing, let problem = sync.problem {
                Label(problem, systemImage: "exclamationmark.icloud")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            SettingsHeader("iCloud", .sync)
        } footer: {
            Text(footer(syncing: syncing))
        }
    }

    /// Each sentence looked up whole, so a language can say it its own way.
    private func footer(syncing: Bool) -> String {
        var text = String(localized: "Spaces, bookmarks and pinned tabs sync between your devices. Open tabs and sign-ins stay on each device.")
        if syncing {
            text += " " + String(localized: "Synced history is encrypted in iCloud.") + " " + sync.historyScopeDescription
        }
        return text
    }
}

/// Settings › Writing: grammar checking in pages, with Harper on this
/// device (WritingChecker, the Engines package). The Mac's pane's first
/// sections, minus checking in other apps, which iOS does not allow; the
/// rule and dictionary lists are shared with it (Shared/Writing/WritingLists.swift).
private struct WritingSection: View {
    @ObservedObject var session: Session
    @State private var rules: [WritingRule] = []
    @State private var words: [String] = WritingWords.load()

    var body: some View {
        Section {
            Toggle("Check Grammar and Spelling in Pages", isOn: $session.preferences.writing)
        } header: {
            SettingsHeader("Writing", .writing)
        } footer: {
            Text("English only. Harper checks it on this \(Device.name); nothing you type is sent anywhere.")
        }
        Group {
            Section {
                Picker("English", selection: $session.preferences.writingDialect) {
                    // Harper's dialects, in its own order.
                    ForEach(WritingDialect.allCases, id: \.rawValue) { dialect in
                        Text(dialect.name).tag(dialect.rawValue)
                    }
                }
            }
            Section {
                // A page of their own, a step below, where they can be searched: there are many.
                NavigationLink {
                    WritingRulesPage()
                        .navigationTitle("Rules")
                } label: {
                    HStack {
                        Text("Rules")
                        Spacer()
                        Text(WritingRulesPage.summary(rules: rules, changed: session.preferences.writingRules))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            Section {
                WritingDictionaryList(words: $words)
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
                Text("Turn checking off for a site from the page's menu.")
            }
        }
        .disabled(!session.preferences.writing)
        .onAppear { rules = WritingChecker.rules() }
        // The file changed under the linter: it takes the words at once,
        // not at the next change to the settings.
        .onChange(of: words) { WritingChecker.shared.wordsChanged() }
    }
}

/// Handoff (Handoff.swift): its switch. What goes beside the file is the
/// page's address and a line for the question, which is the person's to
/// ask in the app they pick (Handoff.prompt).
private struct HandoffSection: View {
    @ObservedObject var session: Session

    var body: some View {
        Section {
            Toggle("Use Handoff", isOn: $session.preferences.handoff)
        } header: {
            SettingsHeader("Handoff", .handoff)
        } footer: {
            Text("The page goes as text to the app you pick, such as Claude or ChatGPT, for your question. Nothing leaves this \(Device.name) until you pick one.")
        }
    }
}

/// A link's menu, and the way to the sites that keep their own (OwnMenus).
private struct LinkMenuSection: View {
    @ObservedObject var session: Session

    var body: some View {
        let kept = OwnMenus.builtIn.filter { session.preferences.keepsOwnMenus(onHost: $0.host) }.count
            + session.preferences.addedOwnMenuSites.count
        Section {
            NavigationLink {
                OwnMenuSites(session: session)
            } label: {
                LabeledContent("Sites with their own menus") {
                    Text(kept.formatted(.number)).monospacedDigit()
                }
            }
        } header: {
            SettingsHeader("Link menu", .linkMenu)
        } footer: {
            Text("On web apps with their own menus, eGlu's link menu stays out of the way.")
        }
    }
}

/// Settings › Link menu › Sites with their own menus: the built-in ones,
/// each with a switch, and one's own, added by host.
private struct OwnMenuSites: View {
    @ObservedObject var session: Session
    @State private var typed = ""

    var body: some View {
        List {
            Section {
                ForEach(session.preferences.addedOwnMenuSites, id: \.self) { host in
                    Text(host)
                }
                .onDelete { offsets in
                    let hosts = session.preferences.addedOwnMenuSites
                    for index in offsets where hosts.indices.contains(index) {
                        session.preferences.setKeepsOwnMenus(false, onHost: hosts[index])
                    }
                }
                HStack {
                    TextField("app.example.com", text: $typed)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.done)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(OwnMenus.host(typed: typed) == nil)
                }
            } header: {
                Text("Your sites")
            } footer: {
                Text("A site covers every address under it: example.com covers app.example.com too.")
            }
            Section {
                ForEach(OwnMenus.builtIn, id: \.host) { site in
                    Toggle(isOn: keeps(site.host)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(site.name)
                            Text(site.host)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Built in")
            } footer: {
                Text("Turn one off for eGlu's link menu on that site.")
            }
        }
        .navigationTitle("Sites with their own menus")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func keeps(_ host: String) -> Binding<Bool> {
        Binding(get: { session.preferences.keepsOwnMenus(onHost: host) },
                set: { session.preferences.setKeepsOwnMenus($0, onHost: host) })
    }

    private func add() {
        guard let host = OwnMenus.host(typed: typed) else { return }
        session.preferences.setKeepsOwnMenus(true, onHost: host)
        typed = ""
    }
}

/// Ads and trackers (ContentBlocker): on or off, the way to the filter lists,
/// and the sites it is off for.
private struct BlockingSection: View {
    @ObservedObject var session: Session
    @ObservedObject private var blocker = ContentBlocker.shared

    var body: some View {
        Section {
            Toggle("Block ads and trackers", isOn: $session.preferences.blocksContent)
            if session.preferences.blocksContent {
                NavigationLink {
                    FilterListsView(session: session)
                } label: {
                    LabeledContent("Filter lists") {
                        let on = session.preferences.filterLists(languages: ContentBlocker.languages, region: ContentBlocker.region).count
                        Text("\(on) on").monospacedDigit()
                    }
                }
                LabeledContent("Rules") {
                    if let shown = blocker.shown {
                        Text(shown.rules.formatted(.number)).monospacedDigit()
                    } else {
                        Text("Getting ready…")
                    }
                }
            }
            if session.preferences.blocksContent && !session.preferences.unblockedSites.isEmpty {
                let count = session.preferences.unblockedSites.count
                Button("Block on All Sites Again (\(count) allowed)") {
                    session.preferences.unblockedSites = []
                }
            }
        } header: {
            SettingsHeader("Ads and trackers", .blocking)
        } footer: {
            Text(footer)
        }
    }

    private var footer: String {
        var text = String(localized: "A site's menu can allow them on that site.")
        if session.preferences.blocksContent, let dropped = blocker.shown?.dropped, dropped > 0 {
            text += " " + String(localized: "\(dropped) of WebKit's rule lists couldn't be made, so some ads still show.")
        }
        return text
    }
}

/// Settings › Ads and trackers › Filter lists: every list there is, each
/// with a switch, what it takes away, whose it is (as its licence asks) and
/// the day the copy in use was made.
private struct FilterListsView: View {
    @ObservedObject var session: Session
    @ObservedObject private var blocker = ContentBlocker.shared

    var body: some View {
        List {
            Section {
                ForEach(ContentBlocking.lists) { list in
                    Toggle(isOn: uses(list)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(list.name)
                            Text(list.about)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text(note(for: list))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } footer: {
                Text("EasyList, EasyPrivacy and YousList come with eGlu; the others download when you turn them on.")
            }
        }
        .navigationTitle("Filter lists")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func uses(_ list: FilterList) -> Binding<Bool> {
        Binding(get: { session.preferences.uses(list, languages: ContentBlocker.languages, region: ContentBlocker.region) },
                set: { session.preferences.filterLists[list.id] = $0 })
    }

    /// Whose the list is, and how the copy in use stands: each line looked up whole.
    private func note(for list: FilterList) -> String {
        let credit = list.credit
        switch blocker.states[list.id] ?? .off {
        case .off:
            return String(localized: "By \(credit)")
        case .waiting:
            return String(localized: "By \(credit) · Getting ready…")
        case .missing:
            return String(localized: "By \(credit) · Not downloaded yet. eGlu tries again when it opens.")
        case .ready(let made, let rules):
            guard let made else { return String(localized: "By \(credit) · \(rules) rules") }
            return String(localized: "By \(credit) · \(made.formatted(date: .abbreviated, time: .omitted)) · \(rules) rules")
        }
    }
}

/// The Home Screen icon: eGlu, the app's own, or one of the alternates the
/// asset catalog compiles in (AppIcon, in PadCore, lists them). The system
/// keeps the choice, by the alternate's name, so nothing here stores it; each
/// preview is that icon rendered in light and dark, so it matches the screen.
private struct AppIconSection: View {
    @State private var current = UIApplication.shared.alternateIconName
    @State private var failure: String?

    var body: some View {
        if UIApplication.shared.supportsAlternateIcons {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 12)], spacing: 16) {
                    ForEach(AppIcon.allCases) { choice in
                        let chosen = choice.alternateName == current
                        Button { choose(choice) } label: {
                            VStack(spacing: 6) {
                                Image("IconPreview\(choice.alternateName ?? "Eglu")")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 60, height: 60)
                                    .padding(4)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .strokeBorder(chosen ? Color.accentColor : .clear, lineWidth: 2.5)
                                    }
                                Text(choice.title)
                                    .font(.caption)
                                    .foregroundStyle(chosen ? .primary : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(choice.title)
                        .accessibilityAddTraits(chosen ? .isSelected : [])
                    }
                }
                .padding(.vertical, 6)
            } header: {
                SettingsHeader("App icon", .appIcon)
            } footer: {
                // Nothing under the icons but the system's refusal, when there is one.
                if let failure { Text(failure) }
            }
        }
    }

    private func choose(_ choice: AppIcon) {
        guard choice.alternateName != current else { return }
        // The ring moves at the tap; the system's own notice comes after.
        let previous = current
        current = choice.alternateName
        Task { @MainActor in
            do {
                try await UIApplication.shared.setAlternateIconName(choice.alternateName)
                failure = nil
            } catch {
                // The system refused (it does while the app is not in front, or when it is busy): say so, put the ring back.
                current = previous
                failure = String(localized: "The icon couldn't change: \(error.localizedDescription)")
            }
        }
    }
}

private extension SettingsGroup {
    /// Whether Settings lists the group here: as SettingsGroup says, and on
    /// an iPhone, which has no developer mode, Developer only for the
    /// diagnostics' switch, in a build from Xcode.
    @MainActor
    func shown(padLayout: Bool, keyboard: Bool) -> Bool {
        guard isOffered(padLayout: padLayout, keyboard: keyboard) else { return false }
        return self != .developer || !Device.phone || Device.diagnostics
    }

    /// Its name here: Keyboard where there is no trackpad, and the
    /// diagnostics' own name for an iPhone's Developer group.
    @MainActor
    func shownTitle(padLayout: Bool) -> String {
        if self == .input && !padLayout { return String(localized: "Keyboard") }
        if self == .developer && Device.phone { return BrowserText.localized("Developer diagnostics") }
        return title
    }

    @MainActor
    var shownDetail: String {
        self == .developer && Device.phone ? BrowserText.localized("Local troubleshooting information") : detail
    }
}
