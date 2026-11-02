import AppKit
import PadCore
import SwiftUI

/// Settings › Extensions, as Settings › Spaces is: every extension in its
/// toolbar order, to drag into another, with + and − under them; and the
/// chosen one's spaces, access and actions in the sections below.
struct ExtensionSettings: View {
    @ObservedObject private var extensions = Extensions.shared
    @ObservedObject private var session = Session.shared
    @AppStorage(Extensions.checksKey) private var checksDaily = true
    @State private var checking = false
    @State private var host: NSWindow?
    @State private var result: ExtensionUpdateReport?
    @State private var chosen: String?

    var body: some View {
        let installed = extensions.installed
        let item = chosen.flatMap { id in installed.first { $0.id == id } }
        Form {
            if let problem = extensions.listSaveProblem {
                Section {
                    Text(problem).foregroundStyle(.orange)
                    Button("Retry Saving Extensions") { extensions.retryListSave() }
                }
            }
            Section {
                if installed.isEmpty {
                    Text("No extensions installed. Add one from the Chrome Web Store or a file.")
                        .foregroundStyle(.secondary)
                } else {
                    List(selection: $chosen) {
                        ForEach(installed) { item in
                            ExtensionSettingsRow(item: item, host: host)
                                .tag(item.id)
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        }
                        .onMove { extensions.move(fromOffsets: $0, toOffset: $1) }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(installed.count <= Self.rowsShown)
                    .frame(height: CGFloat(min(installed.count, Self.rowsShown)) * Self.row)
                }
                HStack(spacing: 0) {
                    Menu {
                        Button("Chrome Web Store…") {
                            Session.shared.open([URL(string: "https://chromewebstore.google.com/category/extensions")!])
                        }
                        Divider()
                        Button("Install from File…") { extensions.addFromFile(in: nil, host: host) }
                        Button("Load Unpacked…") { extensions.loadUnpacked(in: nil, host: host) }
                    } label: {
                        Image(systemName: "plus").frame(width: 24, height: 20)
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Add an Extension")
                    .accessibilityLabel("Add an Extension")
                    Divider().frame(height: 14)
                    Button {
                        if let item { extensions.confirmRemoval(of: item.id, in: nil, host: host) }
                    } label: {
                        Image(systemName: "minus").frame(width: 24, height: 20)
                    }
                    .disabled(item == nil)
                    .help("Remove from eGlu…")
                    .accessibilityLabel("Remove from eGlu")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .menuStyle(.borderlessButton)
            } header: {
                Text("Installed")
            } footer: {
                if installed.count > 1 {
                    Note(String(localized: "Drag an extension to change its place in the toolbar's list of extensions."))
                }
            }
            if let item {
                ExtensionDetail(item: item, host: host)
            }
            Section {
                Toggle("Check for updates daily", isOn: $checksDaily)
                LabeledContent {
                    Button(checking ? String(localized: "Checking…") : String(localized: "Check Again")) {
                        checking = true
                        Task {
                            result = await extensions.checkForUpdates(now: true, host: host)
                            checking = false
                        }
                    }
                    .disabled(checking || !installed.contains { $0.source == .store })
                } label: {
                    if let report = result ?? extensions.updateReport {
                        Text(report.summary).textSelection(.enabled)
                        ForEach(Array(report.entries.enumerated()), id: \.offset) { _, entry in
                            if let detail = entry.detail {
                                Text("\(entry.name): \(detail)").textSelection(.enabled)
                            }
                        }
                    } else if let last = Extensions.lastChecked {
                        Text("Last checked \(last.formatted(.relative(presentation: .named)))")
                    } else {
                        Text("Not checked yet")
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                Note(String(localized: "The check sends the IDs and installed versions of your Chrome Web Store extensions to Google."))
            }
        }
        .background(ExtensionSettingsWindowReader { host = $0 })
        .onAppear { if chosen == nil { chosen = extensions.justInstalled?.id ?? installed.first?.id } }
        // The first when there was none; one removed: the one in its place, or the last.
        .onChange(of: installed.map(\.id)) { before, now in
            guard let chosen else { return self.chosen = now.first }
            guard !now.contains(chosen) else { return }
            let index = before.firstIndex(of: chosen) ?? 0
            self.chosen = now.indices.contains(index) ? now[index] : now.last
        }
    }

    /// As high as the form's own rows.
    static let row: CGFloat = 34
    /// Past this many the list scrolls, so the chosen one's settings stay in view.
    private static let rowsShown = 6

    /// Where it came from, for a report (ExtensionReport).
    static func source(of item: Extensions.Installed) -> String {
        switch item.source {
        case .store: return String(localized: "from the Chrome Web Store")
        case .file: return String(localized: "from a file, signed by its developer")
        case .unsigned: return String(localized: "from a file, unsigned")
        case .unpacked: return String(localized: "loaded from a folder")
        }
    }
}

/// An extension in the list: the handle, its icon, its name, and where it is on.
private struct ExtensionSettingsRow: View {
    let item: Extensions.Installed
    let host: NSWindow?
    @ObservedObject private var extensions = Extensions.shared
    @ObservedObject private var session = Session.shared

    var body: some View {
        let problem = extensions.isIncompatible(item.id) || extensions.isWarned(item.id)
        HStack(spacing: 8) {
            DragHandle()
            ExtensionImage(image: extensions.icon(of: item.id), size: 20)
            Text(item.name)
                .lineLimit(1)
            Spacer(minLength: 8)
            if problem {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(extensions.isIncompatible(item.id) ? String(localized: "Incompatible with this Mac") : String(localized: "May not work as expected"))
            }
            Text(placement)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(height: ExtensionSettings.row)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Move Up") { extensions.move(item.id, by: -1) }
                .disabled(extensions.installed.first?.id == item.id)
            Button("Move Down") { extensions.move(item.id, by: 1) }
                .disabled(extensions.installed.last?.id == item.id)
            Divider()
            Button("Report a Problem…") { ExtensionReport.show(item.id, in: nil, host: host) }
            Button("Remove from eGlu…") { extensions.confirmRemoval(of: item.id, in: nil, host: host) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Drag to change the order.")
        .accessibilityAction(named: "Move Up") { extensions.move(item.id, by: -1) }
        .accessibilityAction(named: "Move Down") { extensions.move(item.id, by: 1) }
    }

    /// The space it is on in, how many, or Off.
    private var placement: String {
        let on = session.workspace.spaces.filter { item.spaces.contains($0.id) }
        switch on.count {
        case 0: return String(localized: "Off")
        case 1: return on[0].name
        case session.workspace.spaces.count: return String(localized: "All Spaces")
        default: return String(localized: "\(on.count) Spaces")
        }
    }
}

/// The chosen extension: what it is, where it is on, what it may reach,
/// and what can be done with it.
private struct ExtensionDetail: View {
    let item: Extensions.Installed
    let host: NSWindow?
    @ObservedObject private var extensions = Extensions.shared
    @ObservedObject private var session = Session.shared
    @State private var allShown = false

    var body: some View {
        let incompatible = extensions.isIncompatible(item.id)
        let summary = ExtensionAccessSummary(grants: item.granted ?? [])
        Section {
            HStack(spacing: 12) {
                ExtensionImage(image: extensions.icon(of: item.id), size: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.headline)
                    HStack(spacing: 6) {
                        Text("Version \(item.version)")
                        Text(verbatim: "·").accessibilityHidden(true)
                        ExtensionSourceLine(source: item.source)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            if incompatible {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Incompatible with this Mac")
                        Text(extensions.incompatibility(item.id))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            if extensions.saidLooksWrong(item.id) {
                Button("Show Warnings Again") { extensions.setLooksWrong(item.id, false) }
            } else if extensions.isWarned(item.id) {
                Button(incompatible ? String(localized: "Try This Version Again and Hide Its Warnings")
                                    : String(localized: "Hide Warnings for This Version")) {
                    extensions.setLooksWrong(item.id, true)
                }
            }
        }
        Section {
            ForEach(session.workspace.spaces) { space in
                let on = item.spaces.contains(space.id)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: Binding(get: { on }, set: { extensions.turn(item.id, on: $0, in: space.id) })) {
                        SpaceName(space: space, size: 20)
                    }
                    .disabled(incompatible && !on)
                    if on, let warning = extensions.warning(item.id, in: space.id) {
                        Text(([warning.title] + warning.lines).joined(separator: " "))
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            let on = session.workspace.spaces.filter { item.spaces.contains($0.id) }
            if !on.isEmpty {
                LabeledContent("Sign-ins and Saved Data") {
                    Menu("Remove…") {
                        ForEach(on) { space in
                            Button("From \(space.name)…") {
                                extensions.confirmRemoval(of: item.id, from: space.id, in: nil, host: host)
                            }
                        }
                    }
                    .fixedSize()
                }
            }
        } header: {
            Text("Spaces")
        } footer: {
            Note(String(localized: "Each space keeps its own sign-ins and data for this extension. Turning it off keeps that data. New spaces don't get it automatically."))
        }
        Section {
            if summary.siteHeadline(onClick: false) != nil {
                Picker("Site access", selection: Binding(get: { item.siteAccess }, set: { extensions.setSiteAccess(item.id, $0) })) {
                    Text("All Sites It Asks For").tag(Extensions.Installed.SiteAccess.allSites)
                    Text("When I Click It").tag(Extensions.Installed.SiteAccess.onClick)
                }
            }
            if let headline = summary.siteHeadline(onClick: item.siteAccess == .onClick) {
                AccessLabel(symbol: "globe", text: headline, tint: .accentColor)
            }
            ForEach(summary.notable, id: \.self) { line in
                AccessLabel(symbol: line.symbol, text: line.text)
            }
            // Its cookies, the person's choice for it: blocked until allowed.
            if extensions.asksForCookies(item) {
                Toggle(isOn: Binding(get: { item.readsCookies == true }, set: { extensions.setReadsCookies(item.id, $0) })) {
                    Text("Allow cookies")
                    Text(ExtensionAccessGroups.cookiesNote + " " + String(localized: "It restarts when you change this."))
                }
            }
            if summary.isEmpty {
                AccessLabel(symbol: "checkmark.shield", text: String(localized: "It asks for no sites and no special capabilities."))
            } else if !summary.routine.isEmpty || summary.siteLines.count > 1 {
                DisclosureGroup("Everything It Asks For", isExpanded: $allShown) {
                    ForEach(summary.routine, id: \.self) { line in
                        AccessLabel(symbol: line.symbol, text: line.text)
                    }
                    ForEach(summary.siteLines, id: \.self) { line in
                        AccessLabel(symbol: "globe", text: line)
                    }
                }
            }
            if ExtensionCapture.allowed(item.id) {
                LabeledContent("May record your screen") {
                    Button("Take Back") { ExtensionCapture.forget(item.id) }
                }
            }
        } header: {
            Text("Access")
        } footer: {
            Note(String(localized: "Applies in every space. On allowed sites it can read and change page content and send that content elsewhere. Google's sign-in pages stay blocked, and cookies unless you allow them."))
        }
        // Its commands' keys, none until you give one (ExtensionKeys);
        // from its manifest while it is on in no space.
        let commands = extensions.contexts.values.compactMap { $0[item.id] }.first
            .map { $0.commands.map { ExtensionManifest.Command(id: $0.id, title: $0.title) } }
            ?? ExtensionKeys.shared.declaredCommands(of: item)
        if !commands.isEmpty {
            Section {
                DisclosureGroup("Keyboard Shortcuts") {
                    ForEach(commands, id: \.id) { command in
                        ExtensionKeyRecorder(id: item.id, command: command.id, title: command.title)
                    }
                    Text("Its commands are in the Extensions menu. A shortcut works in every space it is on in.").foregroundStyle(.secondary)
                }
            }
        }
        Section {
            HStack {
                Button("Report a Problem…") { ExtensionReport.show(item.id, in: nil, host: host) }
                if item.source == .unpacked {
                    Button("Reload") { extensions.reload(item.id, host: host) }
                }
                Spacer()
                Button("Remove from eGlu…", role: .destructive) {
                    extensions.confirmRemoval(of: item.id, in: nil, host: host)
                }
            }
        }
    }
}

/// A line of what it may do, in the form: its symbol, then its words.
private struct AccessLabel: View {
    let symbol: String
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
        }
    }
}

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

/// Captures the Settings window, including when no browser window exists.
private struct ExtensionSettingsWindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void
    func makeNSView(context: Context) -> Reader { Reader(found: found) }
    func updateNSView(_ view: Reader, context: Context) { view.found = found }
    final class Reader: NSView {
        var found: (NSWindow?) -> Void
        init(found: @escaping (NSWindow?) -> Void) { self.found = found; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let owner = window
            DispatchQueue.main.async { [weak self] in self?.found(owner) }
        }
    }
}
