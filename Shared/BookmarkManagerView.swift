import PadCore
import SwiftUI
import UniformTypeIdentifiers

/// The space's bookmarks to sort out, as Chromium's Bookmark Manager has
/// them (⌥⌘B on a Mac, ⌃⌥⇧B on an iPad): its folders down the side, the
/// bookmarks bar first and Other Bookmarks, the rest, after it; the folder
/// chosen there in the list beside them. Bookmarks and folders are dragged
/// into another order or onto another folder, moved from their menu,
/// renamed, given another address, deleted, and found by their words; the
/// space's bookmarks are imported from another browser's file and exported
/// as one. The bookmarks bar is always there and never deleted: it is
/// where the bar's bookmarks go.
struct BookmarkManagerView: View {
    let spaceID: UUID
    /// Pages chosen, all at once: one in the tab on screen, or each in a new
    /// one. Handed over together so the host can give each a tab of its own
    /// (WindowModel.open(_:newTab:)).
    let open: ([URL], _ newTab: Bool) -> Void
    let done: () -> Void
    @ObservedObject private var session = Session.shared
    /// The folder listed, as the side has it chosen: the bar at first, but
    /// on a phone none, so it opens on the folders (onAppear).
    #if os(iOS)
    @State private var place: Place?
    @Environment(\.horizontalSizeClass) private var width
    #else
    @State private var place: Place? = .bar
    #endif
    @State private var selection: Set<UUID> = []
    /// What to choose in the list once `place` has changed to show it (Show in Folder).
    @State private var chosenNext: UUID?
    /// The folders opened down the side; the two at the top start open.
    @State private var expanded: Set<Place> = [.bar, .others]
    @State private var text = ""
    @State private var editor: Editor?
    /// What Delete was asked of, when it takes more than one bookmark.
    @State private var deleting: [UUID] = []
    @State private var importing = false
    @State private var imported: BookmarkImportOutcome?
    @State private var exportFile: BookmarksFile?
    @State private var exporting = false
    @State private var exportFailed = false
    /// On a phone, the folders first, as Settings opens: the list comes when one is chosen.
    @State private var column = NavigationSplitViewColumn.sidebar

    /// The folders down the side: the bar, the space's other bookmarks, and
    /// any folder in either.
    enum Place: Hashable {
        case bar
        case others
        case folder(UUID)
    }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $column) {
            sidebar
                .navigationTitle("Bookmarks")
                #if os(macOS)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
                #else
                // On the folders' column, which a phone shows first: the
                // split view's own toolbar shows in neither column there.
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: done)
                    }
                }
                #endif
        } detail: {
            contents
                .navigationTitle(text.isEmpty ? title(of: place ?? .bar) : String(localized: "Search Results"))
                #if os(iOS)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        organize
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) { importBanner }
                #else
                // A sheet on a Mac shows no toolbar items but its search and
                // Done: the folder's name and what to do in it head the list.
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        header
                        importBanner
                    }
                }
                #endif
        }
        .searchable(text: $text, placement: .toolbar, prompt: Text("Search Bookmarks"))
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: done)
            }
        }
        #else
        .onAppear { if width == .regular, place == nil { place = .bar } }
        #endif
        .sheet(item: $editor) { asked in
            BookmarkEditorView(editor: asked) { finished in
                save(finished)
                editor = nil
            } cancel: {
                editor = nil
            }
        }
        .confirmationDialog(deletingTitle, isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { remove(deleting) }
        } message: {
            Text(deleting.count == 1 ? String(localized: "The bookmarks and folders in it are deleted too.")
                                     : String(localized: "The bookmarks and folders in them are deleted too."))
        }
        .fileExporter(isPresented: $exporting, document: exportFile, contentType: .html,
                      defaultFilename: String(localized: "\(space?.name ?? "eGlu") Bookmarks")) { result in
            if case .failure(let error) = result, (error as NSError).code != NSUserCancelledError { exportFailed = true }
        }
        // Over the whole manager, as the exporter is, so it shows whichever
        // column is out; a level apart from it, one presentation a view.
        .background {
            Color.clear
                .fileImporter(isPresented: $importing, allowedContentTypes: [.html, .zip]) { result in
                    guard case .success(let file) = result else { return }
                    importFile(file)
                }
        }
        .alert("The Bookmarks Weren't Exported", isPresented: $exportFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Choose another location and try again.")
        }
        .environment(\.spaceColor, space?.color ?? .gray)
        // Another space's bookmarks are never these: back to the bar if the folder went.
        .onChange(of: folderIDs) { _, ids in
            if case .folder(let id) = place, !ids.contains(id) { place = .bar }
            selection = selection.filter { Bookmarks.find($0, in: bookmarks) != nil }
        }
        .onChange(of: place) { _, _ in
            selection = chosenNext.map { [$0] } ?? []
            chosenNext = nil
        }
    }

    // MARK: The side

    private var sidebar: some View {
        List(selection: $place) {
            ForEach(sideRows, id: \.place) { row in
                FolderRow(title: row.title, symbol: row.symbol, depth: row.depth, expandable: row.expandable,
                          expanded: expanded.contains(row.place)) {
                    expanded.formSymmetricDifference([row.place])
                }
                .tag(Optional(row.place))
                .dropDestination(for: BookmarkDrag.self) { drops, _ -> Bool in
                    move(drops.map(\.id), into: row.place, before: nil)
                }
            }
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #endif
        // The folders in the space's colour, as the list beside them has them.
        .tint(space?.color.color ?? .accentColor)
        #if DEBUG
        // `-bookmarkManagerImport <path>`: that file imported as one chosen here is, for a test.
        .task {
            guard let path = UserDefaults.standard.string(forKey: "bookmarkManagerImport") else { return }
            importFile(URL(fileURLWithPath: path))
        }
        #endif
    }

    private struct SideRow {
        let place: Place
        let title: String
        let symbol: String
        let depth: Int
        let expandable: Bool
    }

    private var sideRows: [SideRow] {
        func folders(in level: [Bookmark], depth: Int) -> [SideRow] {
            level.filter(\.isFolder).flatMap { folder -> [SideRow] in
                let inside = folder.children ?? []
                let own = SideRow(place: .folder(folder.id), title: folder.label, symbol: "folder.fill", depth: depth,
                                  expandable: inside.contains(where: \.isFolder))
                return [own] + (expanded.contains(own.place) ? folders(in: inside, depth: depth + 1) : [])
            }
        }
        let bar = Bookmarks.bar(in: bookmarks)?.children ?? []
        let others = Bookmarks.others(in: bookmarks)
        let barRow = SideRow(place: .bar, title: title(of: .bar), symbol: "bookmark.square", depth: 0,
                             expandable: bar.contains(where: \.isFolder))
        let othersRow = SideRow(place: .others, title: title(of: .others), symbol: "book", depth: 0,
                                expandable: others.contains(where: \.isFolder))
        return [barRow] + (expanded.contains(.bar) ? folders(in: bar, depth: 1) : [])
            + [othersRow] + (expanded.contains(.others) ? folders(in: others, depth: 1) : [])
    }

    // MARK: The list

    private var contents: some View {
        let searching = !text.trimmingCharacters(in: .whitespaces).isEmpty
        let shown = place ?? .bar
        let items = searching ? [] : self.items(in: shown)
        let found = searching ? Bookmarks.matching(text, in: bookmarks) : []
        return List(selection: $selection) {
            if searching {
                ForEach(found, id: \.item.id) { result in
                    row(result.item, path: result.path)
                }
            } else {
                ForEach(items) { item in
                    row(item, path: nil)
                }
                // Into another order. On iPhone and iPad a drag within the list
                // is the list's own move and reaches only onMove; the drop
                // takes a row dragged as a bookmark wherever the list is given
                // one as a drop instead.
                .onMove { offsets, index in
                    move(offsets.map { items[$0].id }, into: shown, before: index < items.count ? items[index].id : nil)
                }
                .dropDestination(for: BookmarkDrag.self) { drops, index in
                    move(drops.map(\.id), into: shown, before: index < items.count ? items[index].id : nil)
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        .onDeleteCommand { askToRemove(Array(selection)) }
        #endif
        .contextMenu(forSelectionType: UUID.self) { ids in
            menu(for: ids, in: shown)
        } primaryAction: { ids in
            choose(ids)
        }
        .overlay {
            if searching, found.isEmpty {
                ContentUnavailableView.search(text: text)
            } else if !searching, items.isEmpty, imported == nil {
                ContentUnavailableView {
                    Label(shown == .bar ? String(localized: "The Bookmarks Bar Is Empty") : String(localized: "No Bookmarks"),
                          systemImage: shown == .bar ? "bookmark.square" : "book")
                } description: {
                    Text("Drag bookmarks here, or add one.")
                } actions: {
                    Button("Add Bookmark…") { editor = .newBookmark(in: shown) }
                }
            }
        }
    }

    /// A bookmark's row: its site's icon or a folder, its name, and its
    /// address, or, among what words found, the folders it is in.
    private func row(_ item: Bookmark, path: [Bookmark]?) -> some View {
        let detail: String? = path.map { folders in
            folders.isEmpty ? title(of: .others) : folders.map(\.label).joined(separator: " › ")
        } ?? item.url.map(Destination.pretty)
        return HStack(spacing: 10) {
            Group {
                if item.isFolder {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(space?.color.color ?? .accentColor)
                } else {
                    SiteIconView(url: item.url, size: 16)
                }
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            if item.isFolder {
                Text(item.children?.count ?? 0, format: .number)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(String(localized: "\(item.children?.count ?? 0) items"))
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .tag(item.id)
        .draggable(BookmarkDrag(id: item.id)) {
            Label(item.label, systemImage: item.isFolder ? "folder" : "bookmark")
                .padding(6)
        }
        #if os(iOS)
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) { askToRemove([item.id]) }
            Button("Edit", systemImage: "pencil") { editor = .edit(item) }
        }
        #endif
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.isFolder ? String(localized: "\(item.label), folder") : item.label)
    }

    /// What a row's menu, or the list's away from any row, offers for `ids`.
    @ViewBuilder
    private func menu(for ids: Set<UUID>, in shown: Place) -> some View {
        // A folder chosen with what is in it is one: Open All opens each page once.
        let chosen = Bookmarks.outermost(ids, in: bookmarks).compactMap { Bookmarks.find($0, in: bookmarks) }
        let links = chosen.flatMap(\.links).compactMap(\.url)
        if chosen.isEmpty {
            Button("Add Bookmark…", systemImage: "plus") { editor = .newBookmark(in: shown) }
            Button("New Folder…", systemImage: "folder.badge.plus") { editor = .newFolder(in: shown) }
        } else {
            if chosen.count == 1, let item = chosen.first, let url = item.url {
                Button("Open", systemImage: "arrow.up.right.square") { go([url], newTab: false) }
                Button("Open in New Tab", systemImage: "plus.square.on.square") { go([url], newTab: true) }
                Button("Copy Address", systemImage: "doc.on.doc") { copy(url) }
            } else if !links.isEmpty {
                Button("Open All in New Tabs (\(links.count))", systemImage: "plus.square.on.square") {
                    go(links, newTab: true)
                }
            }
            if chosen.count == 1, let item = chosen.first {
                Button(item.isFolder ? String(localized: "Rename…") : String(localized: "Edit…"), systemImage: "pencil") {
                    editor = .edit(item)
                }
                if !text.isEmpty, let folder = folderOf(item.id) {
                    Button("Show in Folder", systemImage: "folder") { show(item.id, in: folder) }
                }
            }
            let targets = moveTargets(for: chosen)
            if !targets.isEmpty {
                Menu("Move to", systemImage: "folder") {
                    ForEach(targets, id: \.place) { target in
                        Button(target.title) { move(chosen.map(\.id), into: target.place, before: nil) }
                    }
                }
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { askToRemove(chosen.map(\.id)) }
        }
    }

    #if os(macOS)
    /// Over the list on a Mac, as Chromium's page has it: the folder's name,
    /// a bookmark or a folder added in it, and the rest in a menu.
    private var header: some View {
        let shown = place ?? .bar
        return HStack(spacing: 6) {
            Text(text.trimmingCharacters(in: .whitespaces).isEmpty ? title(of: shown) : String(localized: "Search Results"))
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button { editor = .newBookmark(in: shown) } label: {
                Image(systemName: "plus").frame(width: 22, height: 22)
            }
            .help("Add Bookmark…")
            .accessibilityLabel("Add Bookmark…")
            Button { editor = .newFolder(in: shown) } label: {
                Image(systemName: "folder.badge.plus").frame(width: 22, height: 22)
            }
            .help("New Folder…")
            .accessibilityLabel("New Folder…")
            organize
                .menuIndicator(.hidden)
                .fixedSize()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
    #endif

    /// What an import came to, over the list until it is put away: a
    /// result with its way on (another space, a retry), or a failure's.
    @ViewBuilder
    private var importBanner: some View {
        if imported != nil {
            HStack(alignment: .top, spacing: 8) {
                BookmarkImportStatusView(session: session, outcome: $imported, chooseFile: { importing = true })
                Spacer(minLength: 0)
                Button { imported = nil } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Hide")
                .accessibilityLabel("Hide")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    /// The toolbar's menu, as Chromium's ⋮: adding, sorting, and files.
    private var organize: some View {
        Menu {
            let shown = place ?? .bar
            Button("Add Bookmark…", systemImage: "plus") { editor = .newBookmark(in: shown) }
            Button("New Folder…", systemImage: "folder.badge.plus") { editor = .newFolder(in: shown) }
            Button("Sort by Name", systemImage: "arrow.up.arrow.down") { sort(shown) }
                .disabled(items(in: shown).count < 2)
            Divider()
            Button("Import Bookmarks…", systemImage: "square.and.arrow.down") { importing = true }
                .disabled(!session.canUseWorkspace)
            Button("Export Bookmarks…", systemImage: "square.and.arrow.up") {
                exportFile = BookmarksFile(items: bookmarks)
                exporting = true
            }
            // Folders alone are worth keeping: only a space with nothing but an empty bar has nothing to export.
            .disabled(bookmarks.allSatisfy { $0.id == Bookmarks.bar(in: bookmarks)?.id && ($0.children ?? []).isEmpty })
        } label: {
            Label("Organize", systemImage: "ellipsis.circle")
        }
        .help("Add, sort, import or export bookmarks")
    }

    // MARK: What there is

    private var space: Space? { session.workspace.space(spaceID) }

    private var bookmarks: [Bookmark] { space?.bookmarks ?? [] }

    /// Every folder's id, to notice one going: here, or on another device.
    private var folderIDs: Set<UUID> {
        func ids(_ level: [Bookmark]) -> [UUID] {
            level.filter(\.isFolder).flatMap { [$0.id] + ids($0.children ?? []) }
        }
        return Set(ids(bookmarks))
    }

    private func items(in place: Place) -> [Bookmark] {
        switch place {
        case .bar: return Bookmarks.bar(in: bookmarks)?.children ?? []
        case .others: return Bookmarks.others(in: bookmarks)
        case .folder(let id): return Bookmarks.find(id, in: bookmarks)?.children ?? []
        }
    }

    private func title(of place: Place) -> String {
        switch place {
        case .bar: return BrowserText.localized("Bookmarks bar")
        case .others: return String(localized: "Other Bookmarks")
        case .folder(let id): return Bookmarks.find(id, in: bookmarks)?.label ?? BrowserText.localized("Folder")
        }
    }

    /// The place the bookmark `id` is in, as the side names it.
    private func folderOf(_ id: UUID) -> Place? {
        guard Bookmarks.find(id, in: bookmarks) != nil else { return nil }
        guard let parent = Bookmarks.parent(of: id, in: bookmarks) else { return .others }
        return parent == Bookmarks.bar(in: bookmarks)?.id ? .bar : .folder(parent)
    }

    /// The folders `chosen` could go into: never one of them or one inside
    /// them, nor the one they are all in already.
    private func moveTargets(for chosen: [Bookmark]) -> [SideRow] {
        let inside = Set(chosen.flatMap(Self.everything).map(\.id))
        let here = Set(chosen.compactMap { folderOf($0.id) })
        func all(in level: [Bookmark], prefix: String) -> [SideRow] {
            level.filter(\.isFolder).flatMap { folder -> [SideRow] in
                guard !inside.contains(folder.id) else { return [] }
                let name = "\(prefix) › \(folder.label)"
                return [SideRow(place: .folder(folder.id), title: name, symbol: "folder.fill", depth: 0, expandable: false)]
                    + all(in: folder.children ?? [], prefix: name)
            }
        }
        let bar = SideRow(place: .bar, title: title(of: .bar), symbol: "", depth: 0, expandable: false)
        let others = SideRow(place: .others, title: title(of: .others), symbol: "", depth: 0, expandable: false)
        let rows = [bar] + all(in: Bookmarks.bar(in: bookmarks)?.children ?? [], prefix: bar.title)
            + [others] + all(in: Bookmarks.others(in: bookmarks), prefix: others.title)
        return rows.filter { here.count != 1 || !here.contains($0.place) }
    }

    private static func everything(_ item: Bookmark) -> [Bookmark] {
        [item] + (item.children ?? []).flatMap(everything)
    }

    // MARK: Doing it

    /// A row chosen (a double click on a Mac, a tap on iPhone and iPad):
    /// a folder opens in the list, a page in the tab on screen.
    private func choose(_ ids: Set<UUID>) {
        let chosen = ids.compactMap { Bookmarks.find($0, in: bookmarks) }
        if chosen.count == 1, let item = chosen.first, item.isFolder {
            text = ""
            show(nil, in: .folder(item.id))
            return
        }
        let links = chosen.compactMap(\.url)
        go(links, newTab: links.count > 1)
    }

    /// Pages opened from here, as from a bookmark in History, and the manager put away.
    private func go(_ links: [URL], newTab: Bool) {
        guard !links.isEmpty else { return }
        for url in links { HistoryRecorder.shared.expect(.bookmark, url) }
        open(links, newTab)
        done()
    }

    /// `place` listed, its folders open down the side, and `id` chosen in it.
    private func show(_ id: UUID?, in place: Place) {
        text = ""
        var opening = place
        while case .folder(let folder) = opening, let up = folderOf(folder) {
            expanded.insert(up)
            opening = up
        }
        if self.place == place {
            selection = id.map { [$0] } ?? []
        } else {
            // Chosen as the list changes, which otherwise clears what was chosen.
            chosenNext = id
            self.place = place
        }
    }

    /// Into `place`, before `before` there or at its end. The bookmarks bar
    /// is made, at the top, the first time something goes in. False when
    /// none of them could go.
    @discardableResult
    private func move(_ ids: [UUID], into place: Place, before: UUID?) -> Bool {
        // A folder moved with what is in it takes that with it, and several go in the order they stand.
        let moving = Bookmarks.outermost(ids, in: bookmarks).filter { $0 != before }
        guard !moving.isEmpty else { return false }
        session.change { w in
            guard let folder = Self.folder(of: place, in: &w, space: spaceID) else { return }
            for id in moving {
                w.moveBookmark(id, into: folder, before: before, in: spaceID)
            }
        }
        return true
    }

    /// The workspace's folder for a place: the top level (nil) for the
    /// others, the bar made where there is none yet. Nil when there is no
    /// such space.
    private static func folder(of place: Place, in w: inout Workspace, space: UUID) -> UUID?? {
        switch place {
        case .bar: return w.makeBar(in: space).map { .some($0) }
        case .others: return w.space(space) == nil ? nil : .some(nil)
        case .folder(let id): return .some(id)
        }
    }

    /// What is in `place` by name, as Chromium's Sort by Name: folders and
    /// links together, in the order of their names for this language.
    private func sort(_ place: Place) {
        session.change { w in
            switch place {
            case .bar: if let bar = Bookmarks.bar(in: bookmarks) { w.sortBookmarks(in: bar.id, of: spaceID) }
            case .others: w.sortBookmarks(in: nil, of: spaceID)
            case .folder(let id): w.sortBookmarks(in: id, of: spaceID)
            }
        }
    }

    /// Delete, asked first when it takes a folder with something in it, or
    /// more than one; the bookmarks bar is never among what goes.
    private func askToRemove(_ ids: [UUID]) {
        let barID = Bookmarks.bar(in: bookmarks)?.id
        // What goes with a folder that goes is not asked about again, nor counted twice.
        let going = Bookmarks.outermost(ids, in: bookmarks).filter { $0 != barID }.compactMap { Bookmarks.find($0, in: bookmarks) }
        guard !going.isEmpty else { return }
        if going.count > 1 || going.contains(where: { !($0.children ?? []).isEmpty }) {
            deleting = going.map(\.id)
        } else {
            remove(going.map(\.id))
        }
    }

    private var deletingTitle: String {
        let count = deleting.count
        if count == 1, let item = deleting.first.flatMap({ Bookmarks.find($0, in: bookmarks) }) {
            return String(localized: "Delete “\(item.label)” and Everything in It?")
        }
        return String(localized: "Delete \(count) Bookmarks and Folders?")
    }

    private func remove(_ ids: [UUID]) {
        deleting = []
        selection.subtract(ids)
        session.change { w in
            for id in ids { w.removeBookmark(id, in: spaceID) }
        }
    }

    private func save(_ finished: Editor) {
        let name = finished.name
        let url = finished.address.flatMap(Destination.webAddress(from:))
        session.change { w in
            switch finished.kind {
            case .newBookmark(let place):
                guard let url, let folder = Self.folder(of: place, in: &w, space: spaceID) else { return }
                w.addBookmark(url, title: name, into: folder, in: spaceID)
            case .newFolder(let place):
                guard let folder = Self.folder(of: place, in: &w, space: spaceID) else { return }
                w.addFolder(named: name, in: folder, of: spaceID)
            case .edit(let id):
                // A link's name cleared is its address, as a new one's is.
                let named = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? url.map(Destination.pretty) ?? name : name
                w.renameBookmark(id, to: named, in: spaceID)
                if let url { w.changeBookmarkAddress(id, to: url, in: spaceID) }
            }
        }
    }

    /// A file chosen to import: into this space, and what came of it at the top of the list.
    private func importFile(_ file: URL) {
        let scoped = file.startAccessingSecurityScopedResource()
        session.importBookmarks(from: file, into: spaceID) { outcome in
            if scoped { file.stopAccessingSecurityScopedResource() }
            imported = outcome
        }
    }

    private func copy(_ url: URL) {
        #if os(iOS)
        UIPasteboard.general.url = url
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        #endif
    }
}

// MARK: - A folder down the side

/// A folder's row down the side, a step in for each folder it is in, with
/// the way to open it where it holds folders of its own.
private struct FolderRow: View {
    let title: String
    let symbol: String
    let depth: Int
    let expandable: Bool
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(expandable ? 1 : 0)
            .disabled(!expandable)
            .accessibilityLabel(expanded ? String(localized: "Close \(title)") : String(localized: "Open \(title)"))
            .accessibilityHidden(!expandable)
            Label(title, systemImage: symbol)
                .lineLimit(1)
        }
        .padding(.leading, CGFloat(depth) * 14)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Adding and editing

extension BookmarkManagerView {
    /// A bookmark or folder being made or changed, and what is typed for it.
    struct Editor: Identifiable {
        enum Kind {
            case newBookmark(BookmarkManagerView.Place)
            case newFolder(BookmarkManagerView.Place)
            case edit(UUID)
        }

        let id = UUID()
        let kind: Kind
        var name: String
        /// Nil for a folder, which has none.
        var address: String?

        static func newBookmark(in place: BookmarkManagerView.Place) -> Editor {
            Editor(kind: .newBookmark(place), name: "", address: "")
        }

        static func newFolder(in place: BookmarkManagerView.Place) -> Editor {
            Editor(kind: .newFolder(place), name: "", address: nil)
        }

        static func edit(_ item: Bookmark) -> Editor {
            Editor(kind: .edit(item.id), name: item.title, address: item.url.map(Destination.editable))
        }

        var heading: String {
            switch kind {
            case .newBookmark: return String(localized: "Add Bookmark")
            case .newFolder: return String(localized: "New Folder")
            case .edit: return address == nil ? String(localized: "Rename Folder") : String(localized: "Edit Bookmark")
            }
        }
    }
}

/// The name, and for a bookmark the address, in a sheet of their own. Save
/// waits for an address a tab can open: words are never a search here.
private struct BookmarkEditorView: View {
    @State var editor: BookmarkManagerView.Editor
    let save: (BookmarkManagerView.Editor) -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    init(editor: BookmarkManagerView.Editor, save: @escaping (BookmarkManagerView.Editor) -> Void,
         cancel: @escaping () -> Void) {
        _editor = State(initialValue: editor)
        self.save = save
        self.cancel = cancel
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $editor.name)
                    .focused($focused)
                if let address = editor.address {
                    TextField("URL", text: Binding(get: { address }, set: { editor.address = $0 }))
                        #if os(iOS)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    if !address.trimmingCharacters(in: .whitespaces).isEmpty, !valid {
                        Text("Type a web address, such as figma.com.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle(editor.heading)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(editor) }
                        .disabled(!valid)
                }
            }
            .onSubmit { if valid { save(editor) } }
        }
        #if os(macOS)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        #endif
        .onAppear { focused = true }
    }

    /// A folder takes any name (an empty one is "New Folder"); a bookmark
    /// needs an address a tab can open, and keeps its name otherwise.
    private var valid: Bool {
        guard let address = editor.address else {
            if case .edit = editor.kind { return !editor.name.trimmingCharacters(in: .whitespaces).isEmpty }
            return true
        }
        return Destination.webAddress(from: address) != nil
    }
}

// MARK: - Dragging and files

/// A bookmark or folder dragged in the bookmark manager.
struct BookmarkDrag: Codable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .egluBookmark)
    }
}

extension UTType {
    /// Read where a drag is encoded, which is no actor's.
    nonisolated static let egluBookmark = UTType(exportedAs: "net.taehee.safience.bookmark")
}

/// A space's bookmarks as the HTML file every browser imports.
struct BookmarksFile: FileDocument {
    static var readableContentTypes: [UTType] { [.html] }
    let data: Data

    init(items: [Bookmark]) { data = BookmarkFile.export(items) }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
