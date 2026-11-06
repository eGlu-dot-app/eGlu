import AppKit
import PadCore
import SwiftUI
import WebEngineAppKit

// MARK: Asking

extension Extensions {
    /// A question about an extension's access, as a sheet on the window, in
    /// one layout (ExtensionAskSheet) wherever it is asked: at install, on
    /// an update that wants more, and when it asks for more while it runs.
    /// Never a modal run of its own, as `present` explains; with no window
    /// to put it on, the answer is nil, as no.
    func ask<Answer, Content: View>(in window: WindowModel?, host owner: NSWindow? = nil,
                                    _ content: (_ answer: @escaping (Answer?) -> Void) -> Content) async -> Answer? {
        guard let host = owner ?? window?.window ?? NSApp.keyWindow ?? Session.shared.frontWindow?.window,
              host.isVisible else { return nil }
        // Titled only: a sheet that could be resized or closed by itself
        // would leave the question without an answer.
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: ExtensionAskSheetMetrics.width, height: 240),
                             styleMask: [.titled], backing: .buffered, defer: true)
        let kept = AskAnswer<Answer>()
        // No taller than the window it hangs from, nor than the screen.
        let room = min(host.frame.height - 24, (host.screen?.visibleFrame.height ?? host.frame.height) - 48)
        let root = AskSheetRoot(content: content { [weak host, weak sheet] answer in
            kept.value = answer
            if let sheet { host?.endSheet(sheet) }
        }, room: room, resized: { [weak sheet] height in sheet?.fit(height) })
        // The sheet sized here, to what it says, and again when Show is
        // chosen: sized by SwiftUI through the window's constraints, its
        // insets changed with each new height and it never settled (AppKit
        // threw).
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = []
        controller.safeAreaRegions = []
        sheet.contentViewController = controller
        sheet.setContentSize(NSSize(width: ExtensionAskSheetMetrics.width, height: controller.view.fittingSize.height))
        return await withCheckedContinuation { continuation in
            host.beginSheet(sheet) { _ in continuation.resume(returning: kept.value) }
        }
    }

    /// A question from a running extension, in the space it runs in: Don't
    /// Allow, the safe answer, is also Escape's.
    func askForMore(title: String, image: NSImage?, in space: UUID, window: WindowModel?,
                    host: NSWindow? = nil, note: String? = nil, @ViewBuilder content: () -> some View) async -> Bool {
        let place = Session.shared.workspace.space(space)
        let content = content()
        return await ask(in: window, host: host) { answer in
            ExtensionAskSheet(image: image, title: title,
                              subtitle: place.map { place in AnyView(Label { Text("In \(place.name)") } icon: { SpaceName(space: place, showsName: false) }) },
                              note: note, cancel: String(localized: "Don't Allow"), confirm: String(localized: "Allow"),
                              answer: { answer($0) }) { content }
        } == true
    }

    static func name(in archive: Data, manifest: ExtensionManifest, fallback: String) -> String {
        EngineComposition.name(in: archive, manifest: manifest, fallback: fallback)
    }

    /// Its icon from its package, before it is installed: the largest its
    /// manifest lists.
    static func icon(in archive: Data, manifest: ExtensionManifest) -> NSImage? {
        EngineComposition.icon(in: archive, manifest: manifest)
    }
}

/// A sheet's content at its own height, top first, its height told as it
/// changes.
private struct AskSheetRoot<Content: View>: View {
    let content: Content
    let room: CGFloat
    let resized: (CGFloat) -> Void

    var body: some View {
        content
            .environment(\.askRoom, room)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                // After this pass, not inside it.
                DispatchQueue.main.async { resized(height) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private extension NSWindow {
    /// As tall as its content, its top kept where it is so what was
    /// clicked stays under the pointer, unless that would take its bottom
    /// past its window's: then it moves up as far as it must.
    func fit(_ height: CGFloat) {
        let content = contentRect(forFrameRect: frame)
        guard abs(content.height - height) > 0.5 else { return }
        var next = frameRect(forContentRect: NSRect(x: content.minX, y: content.maxY - height, width: content.width, height: height))
        next.origin.y = frame.maxY - next.height
        if let parent = sheetParent { next.origin.y = max(next.origin.y, parent.frame.minY + 12) }
        setFrame(next, display: true, animate: isVisible)
    }
}

private struct AskRoom: EnvironmentKey {
    static let defaultValue: CGFloat = .infinity
}

extension EnvironmentValues {
    /// How tall a question's sheet may be: what it asks about scrolls past it.
    var askRoom: CGFloat {
        get { self[AskRoom.self] }
        set { self[AskRoom.self] = newValue }
    }
}

private final class AskAnswer<Answer> {
    var value: Answer?
}

enum ExtensionAskSheetMetrics {
    /// An alert's width, with room for a line and its symbol.
    static let width: CGFloat = 460
}

/// Where an extension came from, said in its sheet and in Settings, with
/// a mark for how far it can be trusted.
struct ExtensionSourceLine: View {
    let source: Extensions.Installed.Source

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }

    private var text: String {
        switch source {
        case .store: return String(localized: "Chrome Web Store, signed by Google")
        case .file: return String(localized: "From a file, signed by its developer")
        case .unsigned: return String(localized: "From a file, not signed by anyone")
        case .unpacked: return String(localized: "From a folder on this Mac, not signed")
        }
    }

    private var symbol: String {
        switch source {
        case .store: return "checkmark.seal.fill"
        case .file: return "signature"
        case .unsigned: return "exclamationmark.triangle.fill"
        case .unpacked: return "folder"
        }
    }

    private var tint: Color {
        switch source {
        case .store: return .green
        case .unsigned: return .orange
        case .file, .unpacked: return .secondary
        }
    }
}

/// An extension's own icon, or a puzzle piece on a tile when it has none.
struct ExtensionImage: View {
    let image: NSImage?
    var size: CGFloat = 32

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "puzzlepiece.extension.fill")
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.55, height: size * 0.55)
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Color.gray.gradient, in: RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        }
    }
}

// MARK: The sheet

/// What every question about access shares: the extension's icon and the
/// question beside it, what it asks for in groups, a note, and the
/// answers, the safe one on the left as an alert has it.
struct ExtensionAskSheet<Content: View>: View {
    let image: NSImage?
    let title: String
    /// Under the title: where it came from, or where it applies.
    var subtitle: AnyView?
    /// Choices kept in view under what scrolls, beside the answers.
    var choices: AnyView?
    var note: String?
    let cancel: String
    let confirm: String
    var canConfirm = true
    let answer: (Bool) -> Void
    @ViewBuilder let content: Content
    @Environment(\.askRoom) private var room
    /// The heights above and below what scrolls, measured.
    @State private var top: CGFloat = 0
    @State private var bottom: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { top = $0 }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content }
            }
            .scrollBounceBehavior(.basedOnSize)
            .fadesClippedEdges()
            .frame(maxHeight: max(160, room - top - bottom - 2 * 16 - 2 * 20))
            footer
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { bottom = $0 }
        }
        .padding(20)
        .frame(width: ExtensionAskSheetMetrics.width)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ExtensionImage(image: image, size: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    subtitle
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let choices { choices }
            if let note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer()
                Button(cancel) { answer(false) }
                    .keyboardShortcut(.cancelAction)
                Button(confirm) { answer(true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
    }
}

extension View {
    /// A scroll view's content faded out at an edge where it goes on past
    /// it, and only there: a hard cut at the edge read as the end.
    func fadesClippedEdges(by length: CGFloat = 28) -> some View {
        modifier(ClippedEdgeFades(length: length))
    }
}

private struct ClippedEdgeFades: ViewModifier {
    let length: CGFloat
    @State private var clipped = Clipped()

    struct Clipped: Equatable {
        var top = false
        var bottom = false
    }

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Clipped.self) { geometry in
                Clipped(top: geometry.visibleRect.minY > 0.5,
                        bottom: geometry.visibleRect.maxY < geometry.contentSize.height - 0.5)
            } action: { _, now in
                clipped = now
            }
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(clipped.top ? 0 : 1), .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: length)
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(clipped.bottom ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                        .frame(height: length)
                }
                // In as the edge is left, out as it is reached; no movement.
                .animation(.easeOut(duration: 0.15), value: clipped)
            }
    }
}

/// A titled group of lines on a plate, as a grouped form's section.
struct AskGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08))
                }
        }
    }
}

/// One thing it may do: a symbol to scan by, the words, and a note under them.
struct AskLine: View {
    let symbol: String
    let text: String
    var detail: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: AskLine.symbolWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    static let symbolWidth: CGFloat = 20
    /// Where a line's words start, for a divider that starts there too.
    static let textInset: CGFloat = 12 + symbolWidth + 10
}

/// A line under a group's lines that shows more of them, and the more.
private struct AskMore<More: View>: View {
    let title: String
    let count: Int
    /// The first line of its group, with no divider above it.
    var first = false
    @Binding var shown: Bool
    @ViewBuilder let more: More

    var body: some View {
        if !first { Divider().padding(.leading, AskLine.textInset) }
        Button {
            withAnimation(.easeOut(duration: 0.2)) { shown.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(shown ? String(localized: "Hide") : title)
                Spacer(minLength: 0)
                if !shown { Text(count, format: .number).monospacedDigit() }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(shown ? 90 : 0))
            }
            .foregroundStyle(.secondary)
            .padding(.leading, AskLine.textInset)
            .padding(.trailing, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(shown ? String(localized: "Shown") : String(localized: "Hidden"))
        if shown {
            more.transition(.opacity)
        }
    }
}

/// What it asks for, as two groups: its sites in a line, with its site
/// access beside them when that is being chosen; then the capabilities
/// worth a second look, the rest a click away. `everything`: all of it at
/// once, for a question about a few new things.
struct ExtensionAccessGroups: View {
    let summary: ExtensionAccessSummary
    var access: Binding<Extensions.Installed.SiteAccess>?
    var everything = false
    /// Asked to give it now (permissions.request): its cookies are what a
    /// yes gives. Otherwise they stay blocked, a choice for its settings.
    var grantsCookies = false
    @State private var sitesShown = false
    @State private var moreShown = false

    /// What allowing cookies reaches, said wherever they are given.
    static var cookiesNote: String {
        String(localized: "With cookies, it can read your sign-ins on the sites it can access, Google's included, in every space, and send them elsewhere.")
    }

    var body: some View {
        let onClick = access?.wrappedValue == .onClick
        if let headline = summary.siteHeadline(onClick: onClick) {
            AskGroup(title: String(localized: "Sites")) {
                AskLine(symbol: "globe", text: headline,
                        detail: String(localized: "It can also send what it reads elsewhere. Google's sign-in pages stay blocked."),
                        tint: .accentColor)
                    .animation(.easeOut(duration: 0.15), value: onClick)
                // Under the line it changes.
                if let access {
                    Picker("Site access", selection: access) {
                        Text("All Sites It Asks For").tag(Extensions.Installed.SiteAccess.allSites)
                        Text("When I Click It").tag(Extensions.Installed.SiteAccess.onClick)
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .labelsHidden()
                    .accessibilityLabel("When the extension may access sites")
                    .padding(.leading, AskLine.textInset)
                    .padding(.trailing, 12)
                    .padding(.bottom, 9)
                }
                if everything {
                    siteList
                } else if summary.siteLines.count > 1 {
                    AskMore(title: String(localized: "Show Details"), count: summary.siteLines.count, shown: $sitesShown) { siteList }
                }
            }
        }
        let shown = everything ? summary.notable + summary.routine : summary.notable
        if !shown.isEmpty || !summary.routine.isEmpty || summary.cookies {
            AskGroup(title: String(localized: "Capabilities")) {
                if summary.cookies {
                    if grantsCookies {
                        AskLine(symbol: ExtensionAccessDescription.symbol("cookies"), text: ExtensionAccessDescription.capability("cookies"))
                    } else {
                        AskLine(symbol: ExtensionAccessDescription.symbol("cookies"), text: String(localized: "Cookies stay blocked"),
                                detail: String(localized: "They keep you signed in to sites. You can allow them later in its settings."))
                    }
                    if !shown.isEmpty { Divider().padding(.leading, AskLine.textInset) }
                }
                lines(shown)
                if !everything, !summary.routine.isEmpty {
                    AskMore(title: shown.isEmpty ? String(localized: "Show Capabilities") : String(localized: "Show More"),
                            count: summary.routine.count, first: shown.isEmpty && !summary.cookies, shown: $moreShown) {
                        Divider().padding(.leading, AskLine.textInset)
                        lines(summary.routine)
                    }
                }
            }
        }
        if summary.isEmpty {
            AskGroup(title: String(localized: "Access")) {
                AskLine(symbol: "checkmark.shield", text: String(localized: "It asks for no sites and no special capabilities."))
            }
        }
    }

    @ViewBuilder
    private func lines(_ lines: [ExtensionAccessSummary.Line]) -> some View {
        ForEach(Array(lines.enumerated()), id: \.element) { index, line in
            if index > 0 { Divider().padding(.leading, AskLine.textInset) }
            AskLine(symbol: line.symbol, text: line.text)
        }
    }

    /// Every site as it asked for it, in a list that scrolls past a few.
    private var siteList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(summary.siteLines, id: \.self) { line in
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.leading, AskLine.textInset)
            .padding(.trailing, 12)
            .padding(.bottom, 8)
        }
        .fadesClippedEdges(by: 16)
        .frame(maxHeight: 150)
        .textSelection(.enabled)
    }
}

// MARK: Installing

/// Add "1Password"?: where it came from, what it asks for, how it may
/// reach sites and which spaces it goes in. The line for its sites says
/// what the site access chosen leaves it, as it is chosen.
struct ExtensionInstallSheet: View {
    struct Choice {
        var access: Extensions.Installed.SiteAccess
        var spaces: [UUID]
    }

    let name: String
    let image: NSImage?
    let source: Extensions.Installed.Source
    let summary: ExtensionAccessSummary
    let spaces: [Space]
    let answer: (Choice?) -> Void
    @State private var access: Extensions.Installed.SiteAccess
    @State private var chosen: Set<UUID>

    init(name: String, image: NSImage?, source: Extensions.Installed.Source, summary: ExtensionAccessSummary,
         spaces: [Space], access: Extensions.Installed.SiteAccess, in space: UUID, answer: @escaping (Choice?) -> Void) {
        self.name = name
        self.image = image
        self.source = source
        self.summary = summary
        self.spaces = spaces
        self.answer = answer
        _access = State(initialValue: access)
        _chosen = State(initialValue: [space])
    }

    var body: some View {
        ExtensionAskSheet(image: image, title: String(localized: "Add \u{201C}\(name)\u{201D}?"),
                          subtitle: AnyView(ExtensionSourceLine(source: source)), choices: AnyView(spacesGroup),
                          note: note, cancel: String(localized: "Cancel"), confirm: String(localized: "Add"),
                          canConfirm: !chosen.isEmpty) { yes in
            answer(yes ? Choice(access: access, spaces: spaces.map(\.id).filter(chosen.contains)) : nil)
        } content: {
            ExtensionAccessGroups(summary: summary, access: $access)
        }
    }

    private var spacesGroup: some View {
        AskGroup(title: String(localized: "Turn On In")) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 12, alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(spaces) { space in
                    Toggle(isOn: Binding(get: { chosen.contains(space.id) },
                                         set: { if $0 { chosen.insert(space.id) } else { chosen.remove(space.id) } })) {
                        SpaceName(space: space)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private var note: String {
        var lines = [String(localized: "Each space keeps its own sign-ins and data for this extension. New spaces don't get it automatically.")]
        if source == .unpacked { lines.append(String(localized: "Reload in Settings reads the folder again.")) }
        return lines.joined(separator: " ")
    }
}

/// Messages with apps on this Mac (nativeMessaging), asked for as Chrome
/// asks: an extension that wants it only when it needs it.
struct NativeAppsGroup: View {
    var body: some View {
        AskGroup(title: String(localized: "Capabilities")) {
            AskLine(symbol: ExtensionAccessDescription.symbol("nativeMessaging"),
                    text: ExtensionAccessDescription.capability("nativeMessaging"),
                    detail: String(localized: "An app that has made itself known to Chrome for it, such as a password manager's, could exchange information with it."))
        }
    }
}

/// A space's name after its icon on its colour, as its sidebar shows it.
struct SpaceName: View {
    let space: Space
    var size: CGFloat = 16
    var showsName = true

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: space.symbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(space.color.ink)
                .frame(width: size, height: size)
                .background(space.color.color, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
                .accessibilityHidden(true)
            if showsName {
                Text(space.name)
                    .lineLimit(1)
            }
        }
    }
}

#if DEBUG
extension Extensions {
    /// Each question as a sheet, to see it without an extension asking:
    /// `-extensionAsk install:<folder>` offers a folder as Load Unpacked
    /// does; `more`, `sites`, `native` and `update` ask about the first
    /// one installed (`-installExtension`), on the front window.
    func askFromTheCommandLine() {
        guard let kind = UserDefaults.standard.string(forKey: "extensionAsk") else { return }
        Task {
            try? await Task.sleep(for: .seconds(kind.hasPrefix("install:") ? 7 : 10))
            guard let window = Session.shared.frontWindow else { return }
            if kind.hasPrefix("install:") {
                let path = URL(fileURLWithPath: String(kind.dropFirst(8))).standardizedFileURL.path
                do {
                    try await offer(try await Self.zipped(URL(fileURLWithPath: path, isDirectory: true)),
                                    id: ExtensionID.id(forUnpackedPath: path), source: .store, in: window, folder: path)
                } catch {
                    tell(error, in: window)
                }
                return
            }
            guard let item = installed.first, runtime.isLoaded(item.id, in: window.spaceID) else { return }
            let name = "\u{201C}\(item.name)\u{201D}"
            switch kind {
            case "more":
                _ = await askForMore(title: "\(name) wants more access", image: runtime.permissionIcon(item.id, in: window.spaceID), in: window.spaceID, window: window) {
                    ExtensionAccessGroups(summary: ExtensionAccessSummary(permissions: ["clipboardRead", "history"], sites: []), everything: true)
                }
            case "sites":
                _ = await askForMore(title: "\(name) wants to read and change more sites", image: runtime.permissionIcon(item.id, in: window.spaceID), in: window.spaceID, window: window) {
                    ExtensionAccessGroups(summary: ExtensionAccessSummary(permissions: [], sites: ["https://*.github.com/*", "https://mail.google.com/*"]), everything: true)
                }
            case "native":
                _ = await askForMore(title: "\(name) wants to talk to apps on this Mac", image: runtime.permissionIcon(item.id, in: window.spaceID), in: window.spaceID, window: window) {
                    NativeAppsGroup()
                }
            case "update":
                guard let host = window.window else { return }
                _ = await askToUpdate(item, version: "9.0.1", wanting: ["history", "site:https://*.example.org/*"], host: host)
            default:
                break
            }
        }
    }
}
#endif
