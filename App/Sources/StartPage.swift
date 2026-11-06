import PadCore
import SwiftUI
import UIKit

/// What a new tab shows, as the Mac's does (StartTiles.swift): the space's
/// mark and name, the way to an address where the bar isn't at the bottom,
/// the space's bookmarks as tiles, one folder at a time, each space's its
/// own (with none yet, the way to bring them over from Chrome, Firefox or Safari),
/// and the pages last gone to, here and on the other devices; each part
/// on or off from Customize at the foot.
struct StartPage: View {
    @ObservedObject var session: Session
    let window: WindowModel
    let act: (BarAction) -> Void
    /// The folders opened, outermost first.
    @State private var path: [UUID] = []
    @State private var shown = false
    @State private var askingFolder = false
    @State private var folderName = ""
    /// The bookmark or folder being renamed, and the name typed for it.
    @State private var renaming: Bookmark?
    @State private var newName = ""

    var body: some View {
        let space = session.workspace.space(window.spaceID)
        let hidden = session.preferences.hiddenStartSections
        let folders = Bookmarks.folders(along: path, in: space?.bookmarks ?? [])
        let items = folders.last?.children ?? space?.bookmarks ?? []
        // Every folder a tile could move to, found once for all the tiles.
        let places = moveTargets(in: space?.bookmarks ?? [])
        GeometryReader { box in
            ScrollView {
                VStack(spacing: 0) {
                    if let space {
                        SpaceMark(space: space)
                            .foregroundStyle(Palette.ink)
                            .arriving(shown, after: 0)
                    }
                    // On a phone the bar at the foot is the field, just under the thumb.
                    if !window.phone {
                        field
                            .padding(.top, 28)
                            .arriving(shown, after: 0.03)
                    }
                    if !hidden.contains(.bookmarks) {
                        bookmarks(space: space, folders: folders, items: items, places: places)
                    }
                    if let space {
                        ForEach([Preferences.StartSection.history, .otherDevices].filter { !hidden.contains($0) }, id: \.self) { section in
                            RecentPages(section: section, space: space.id, headingHeight: Metrics.target, shown: shown, delay: 0.08,
                                        showAll: { act(.command(.history)) }, open: { act(.open($0)) },
                                        openInNewTab: { act(.openInNewTab($0)) },
                                        copy: { act(.copy($0)) })
                                .padding(.top, window.phone ? 28 : 36)
                        }
                    }
                    StartCustomize(hidden: $session.preferences.hiddenStartSections)
                        .padding(.top, 36)
                        .arriving(shown, after: 0.12)
                }
                .frame(width: max(StartMetrics.square, min(StartMetrics.column, box.size.width - StartMetrics.margin * 2)))
                .padding(.top, StartMetrics.top(in: box.size.height))
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .background(Palette.ground)
        .onAppear { shown = true }
        .onDisappear { shown = false }
        .onChange(of: window.spaceID) { _, _ in path = [] }
        .alert("New Folder", isPresented: $askingFolder) {
            TextField("Name", text: $folderName)
            Button("Create") { act(.newFolder(folderName, in: path.last)) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
               presenting: renaming) { item in
            TextField("Name", text: $newName)
            Button("Rename") { act(.renameBookmark(item.id, newName)) }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// The space's bookmarks: their heading, and the tiles of the folder open, or why there are none.
    @ViewBuilder
    private func bookmarks(space: Space?, folders: [Bookmark], items: [Bookmark],
                           places: [(target: MoveTarget, within: [UUID])]) -> some View {
        header(folders: folders)
            .padding(.top, window.phone ? 24 : 32)
            .arriving(shown, after: 0.04)
        if items.isEmpty {
            empty(space: space, inFolder: !folders.isEmpty)
                .padding(.top, 4)
                .arriving(shown, after: 0.06)
        } else {
            TileGrid {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let isBar = item.id == space?.bar?.id
                    BookmarkTile(item: item, colour: space?.color ?? .blue, isBar: isBar,
                                 targets: isBar ? [] : targets(for: item, among: places), act: act, open: {
                        if item.isFolder {
                            withAnimation(.bar) { path.append(item.id) }
                        } else if let url = item.url {
                            HistoryRecorder.shared.expect(.bookmark, url)
                            act(.open(url))
                        }
                    }, rename: {
                        newName = item.title
                        renaming = item
                    })
                    // In one after another, as the eye reads them, all of
                    // them in by a fifth of a second: a new tab is opened often.
                    .arriving(shown, after: 0.06 + min(Double(index) * 0.03, 0.12))
                }
            }
            .padding(.top, 10)
        }
    }

    /// The address field as it stands until tapped, which types in the
    /// command bar, as the bar's own does; the keys for it beside it.
    private var field: some View {
        Button { act(.editAddress) } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                Text(AddressEditor.placeholder)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let keys = Device.keys(for: .address) {
                    Text(keys)
                        .foregroundStyle(Palette.faint)
                }
            }
            .font(.body)
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(minHeight: StartMetrics.field)
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .floatingGlass(cornerRadius: StartMetrics.field / 2, tint: nil)
        .hoverEffect(.highlight)
        .accessibilityLabel(AddressEditor.placeholder)
    }

    /// Where a bookmark or a folder can be moved to: the top level, from
    /// inside a folder, and every folder but the one it is in, itself and
    /// its own, each named by its path.
    private func targets(for item: Bookmark, among places: [(target: MoveTarget, within: [UUID])]) -> [MoveTarget] {
        let top = path.last == nil ? [] : [MoveTarget(folder: nil, label: String(localized: "Bookmarks"))]
        // Only a folder has anything inside it to rule out.
        guard item.isFolder else { return top + places.map(\.target) }
        return top + places.filter { !$0.within.contains(item.id) }.map(\.target)
    }

    /// Every folder but the one that is open, each named by its path, with
    /// the folders it is in (itself among them). The tree is gone through
    /// once here, not once for each tile.
    private func moveTargets(in bookmarks: [Bookmark]) -> [(target: MoveTarget, within: [UUID])] {
        func folders(in items: [Bookmark], prefix: String, above: [UUID]) -> [(target: MoveTarget, within: [UUID])] {
            items.filter(\.isFolder).flatMap { folder -> [(target: MoveTarget, within: [UUID])] in
                let label = prefix.isEmpty ? folder.label : "\(prefix) › \(folder.label)"
                let within = above + [folder.id]
                let own = folder.id == path.last ? [] : [(target: MoveTarget(folder: folder.id, label: label), within: within)]
                return own + folders(in: folder.children ?? [], prefix: label, above: within)
            }
        }
        return folders(in: bookmarks, prefix: "", above: [])
    }

    /// "Bookmarks", or the folder open with the way back out of it; and a new folder.
    private func header(folders: [Bookmark]) -> some View {
        HStack(spacing: 2) {
            if !folders.isEmpty {
                Button {
                    withAnimation(.bar) { _ = path.popLast() }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .frame(width: window.phone ? 44 : Metrics.target, height: window.phone ? 44 : Metrics.target)
                        .contentShape(Rectangle())
                        .contentShape(.hoverEffect, Circle().inset(by: Metrics.ring))
                }
                .buttonStyle(PressScale())
                .hoverEffect(.highlight)
                // The chevron's own edge on the column's, as the tiles' squares are.
                .padding(.leading, -16)
                .accessibilityLabel("Back to \(folders.dropLast().last?.label ?? String(localized: "Bookmarks"))")
            }
            Text(folders.last?.label ?? String(localized: "Bookmarks"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                act(.command(.bookmarkManager))
            } label: {
                Image(systemName: Command.bookmarkManager.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: window.phone ? 44 : Metrics.target, height: window.phone ? 44 : Metrics.target)
                    .contentShape(Rectangle())
                    .contentShape(.hoverEffect, Circle().inset(by: Metrics.ring))
            }
            .buttonStyle(PressScale())
            .hoverEffect(.highlight)
            .help("Bookmark Manager")
            .accessibilityLabel("Bookmark Manager")
            Button {
                folderName = ""
                askingFolder = true
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: window.phone ? 44 : Metrics.target, height: window.phone ? 44 : Metrics.target)
                    .contentShape(Rectangle())
                    .contentShape(.hoverEffect, Circle().inset(by: Metrics.ring))
            }
            .buttonStyle(PressScale())
            .hoverEffect(.highlight)
            // Its symbol's edge on the column's right edge, as the field's is.
            .padding(.trailing, -12)
            .help("New Folder")
            .accessibilityLabel("New Folder")
        }
        // As high in a folder, where the back button is, as at the top: the tiles don't move as one opens.
        .frame(minHeight: Metrics.target)
    }

    private func empty(space: Space?, inFolder: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            let name = space?.name ?? String(localized: "this space")
            Text(inFolder ? String(localized: "Nothing in this folder yet.")
                          : Device.keys(for: .bookmark).map { String(localized: "No bookmarks in \(name) yet. Bring them over from Chrome, Firefox or Safari, or star the page you’re on (\($0)).") }
                            ?? String(localized: "No bookmarks in \(name) yet. Bring them over from Chrome, Firefox or Safari, or star the page you’re on."))
                .font(.subheadline)
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            if !inFolder {
                Button("Import Bookmarks…") { act(.importBookmarks) }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A folder a bookmark can be moved to, or the top level for nil.
private struct MoveTarget: Identifiable {
    let folder: UUID?
    let label: String

    var id: String {
        folder?.uuidString ?? "top"
    }
}

/// A bookmark or a folder as a tile (BookmarkFace): its page, or the folder
/// opened in place; renamed, moved or deleted from its menu.
private struct BookmarkTile: View {
    let item: Bookmark
    let colour: SpaceColor
    /// The space's bookmarks bar keeps its name and its place, and is never deleted.
    let isBar: Bool
    let targets: [MoveTarget]
    let act: (BarAction) -> Void
    let open: () -> Void
    let rename: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            BookmarkFace(item: item, colour: colour, hovering: hovering)
                .foregroundStyle(Palette.ink)
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
        .animation(.bar, value: hovering)
        .help(item.url.map(Destination.pretty) ?? item.label)
        .contextMenu {
            if let url = item.url {
                Button("Open in New Tab", systemImage: "plus.square.on.square") { act(.openInNewTab(url)) }
                Button("Copy Address", systemImage: "doc.on.doc") { act(.copy(url)) }
            }
            if !isBar {
                Button("Rename…", systemImage: "pencil") { rename() }
            }
            if !targets.isEmpty {
                Menu("Move to…", systemImage: "folder") {
                    ForEach(targets) { target in
                        Button(target.label, systemImage: target.folder == nil ? "star.square.on.square" : "folder") {
                            act(.moveBookmark(item.id, into: target.folder))
                        }
                    }
                }
            }
            if !isBar {
                Button(item.isFolder ? "Delete Folder" : "Delete Bookmark", systemImage: "trash", role: .destructive) {
                    act(.removeBookmark(item.id))
                }
            }
            Divider()
            Button("Bookmark Manager", systemImage: Command.bookmarkManager.symbol) { act(.command(.bookmarkManager)) }
        }
        .accessibilityLabel(item.isFolder ? String(localized: "\(item.label), folder") : item.label)
    }
}
