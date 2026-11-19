import PadCore
import SwiftUI

/// A space's own settings: its name, its colour and its icon, each applied
/// as it is chosen. From the space's menu (Space Settings…, ⌃⌥⇧S) as a
/// sheet, and from Settings › Spaces.
struct SpaceEditor: View {
    @ObservedObject var session: Session
    @ObservedObject private var sync = Sync.shared
    let spaceID: UUID
    /// Given when shown as a sheet of its own.
    var done: (() -> Void)?
    @State private var name = ""
    @State private var confirming = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let space = session.workspace.space(spaceID)
        Form {
            if let space {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: space.symbol)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(space.color.ink)
                            .frame(width: 40, height: 40)
                            .background(space.color.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .animation(.bar, value: space.color)
                        TextField("Name", text: $name)
                            .font(.body.weight(.medium))
                            .submitLabel(.done)
                            .onSubmit(save)
                    }
                    .padding(.vertical, 2)
                    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Enter a name. This space is still named \(space.name) until a valid name is entered.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("Colour") {
                    ColourRow(selected: space.color) { colour in
                        session.change { $0.setColor(spaceID, to: colour) }
                    }
                }

                Section("Icon") {
                    IconGrid(selected: space.symbol, colour: space.color) { symbol in
                        session.change { $0.setSymbol(spaceID, to: symbol) }
                    }
                }

                if session.workspace.spaces.count > 1 {
                    Section {
                        Button("Remove Space…", role: .destructive) { confirming = true }
                    } footer: {
                        Text(sync.spaceRemovalDescription(space))
                    }
                }
            }
        }
        .navigationTitle(space?.name ?? String(localized: "Space"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let done {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save()
                        done()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear { name = space?.name ?? "" }
        .onChange(of: name) { _, _ in save() }
        .confirmationDialog("Remove \(space?.name ?? String(localized: "this space"))?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Remove Space", role: .destructive) {
                Session.shared.removeSpace(spaceID)
                if let done { done() } else { dismiss() }
            }
        } message: {
            if let space { Text(sync.spaceRemovalDescription(space)) }
        }
    }

    private func save() {
        session.change { $0.renameSpace(spaceID, to: name) }
    }
}

/// The colours to choose from, each a dot; the chosen one ringed in its own
/// colour, the ring's gap the same all round. The welcome's too (Welcome.swift).
struct ColourRow: View {
    let selected: SpaceColor
    let choose: (SpaceColor) -> Void

    /// Two rows of five: ten 44-point targets need more than an iPhone's width in one.
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 5)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(SpaceColor.allCases, id: \.self) { colour in
                Button {
                    choose(colour)
                } label: {
                    ZStack {
                        Circle()
                            .strokeBorder(colour.color, lineWidth: 2)
                            .frame(width: 36, height: 36)
                            .opacity(colour == selected ? 1 : 0)
                            .scaleEffect(colour == selected ? 1 : 0.8)
                        Circle()
                            .fill(colour.color)
                            .frame(width: 26, height: 26)
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .animation(.bar, value: selected)
                }
                .buttonStyle(PressScale())
                .accessibilityLabel(colour.name)
                .accessibilityAddTraits(colour == selected ? .isSelected : [])
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Every icon a space can wear, as the icons themselves, in a grid: the
/// chosen one filled with the space's colour.
struct IconGrid: View {
    let selected: String
    let colour: SpaceColor
    let choose: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44, maximum: 52), spacing: 8)], spacing: 8) {
            ForEach(Workspace.symbols, id: \.self) { symbol in
                let chosen = symbol == selected
                Button {
                    choose(symbol)
                } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: chosen ? .semibold : .regular))
                        .foregroundStyle(chosen ? colour.ink : Palette.ink)
                        .frame(width: 44, height: 44)
                        .background(chosen ? colour.color : Palette.wash,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(Rectangle())
                        .animation(.bar, value: chosen)
                }
                .buttonStyle(PressScale())
                .accessibilityLabel(Workspace.symbolName(symbol))
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
    }
}

/// Settings › Spaces: every space, in the order ⌃⌥↑ and ⌃⌥↓ step through,
/// to reorder (Edit) and to open.
struct SpaceList: View {
    @ObservedObject var session: Session
    @State private var creating = false
    @State private var newName = ""

    var body: some View {
        List {
            Section {
                ForEach(session.workspace.spaces) { space in
                    NavigationLink(value: SettingsNavigation.Page.space(space.id)) {
                        HStack(spacing: 12) {
                            Image(systemName: space.symbol)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(space.color.ink)
                                .frame(width: 28, height: 28)
                                .background(space.color.color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            Text(space.name)
                            Spacer()
                            Text(BrowserText.tabCount(space.tabs.count))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                .onMove { offsets, destination in
                    session.change { $0.moveSpaces(from: offsets, to: destination) }
                }
            } footer: {
                Text("Edit, then drag a space by its handle to change the order.")
            }
        }
        .navigationTitle("Spaces")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("New Space", systemImage: "plus") { creating = true } }
            ToolbarItem(placement: .secondaryAction) { EditButton() }
        }
        .alert("New Space", isPresented: $creating) {
            TextField("Space Name", text: $newName)
            Button("Create") {
                session.change { $0.addSpace(named: newName) }
                newName = ""
            }
            .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { newName = "" }
        } message: {
            Text("Give each client or account a separate space for its sign-ins, tabs and bookmarks.")
        }
    }
}

/// Settings › Pinned Tabs: each space's pinned tabs, in their order, to
/// reorder (Edit) and to show or hide in this device's tab bar. A hidden
/// one stays pinned, in its place and in iCloud: only this device's row
/// goes without it (Preferences.hiddenPinnedTabs), and the Mac chooses for
/// itself.
struct PinnedTabList: View {
    @ObservedObject var session: Session

    var body: some View {
        let spaces = session.workspace.spaces.filter { $0.pinnedCount > 0 }
        List {
            if spaces.isEmpty {
                Section {
                    Text("No pinned tabs yet.")
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("Pin a tab from its menu to keep it at the front of the row.")
                }
            }
            ForEach(spaces) { space in
                Section {
                    ForEach(space.tabs.prefix(space.pinnedCount)) { tab in
                        Toggle(isOn: shown(tab.id)) {
                            HStack(spacing: 12) {
                                SiteIconView(url: tab.pinned ?? tab.url, size: 22)
                                Text(tab.label)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .onMove { offsets, destination in
                        session.change { $0.movePinned(in: space.id, from: offsets, to: destination) }
                    }
                    .environment(\.spaceColor, space.color)
                } header: {
                    HStack {
                        Label(space.name, systemImage: space.symbol)
                        Spacer()
                        // What the switches at the rows' ends say.
                        Text("View on \(Device.phone ? "iOS" : "iPadOS")")
                    }
                } footer: {
                    if space.id == spaces.last?.id {
                        Text("A hidden tab stays pinned; only this \(Device.name) leaves it out. Edit, then drag a tab to change its place everywhere.")
                    }
                }
            }
        }
        .navigationTitle("Pinned Tabs")
        .toolbar {
            if !spaces.isEmpty { EditButton() }
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
