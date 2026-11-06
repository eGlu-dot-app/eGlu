import AppKit
import PadCore
import SwiftUI
import WebEngineAppKit

/// `chrome.sidePanel`, which WebKit lacks: an extension's own page in a
/// card beside the page's, as Chrome shows one beside its tab
/// (Docs/ExtensionsDesign.md, section 2). What each extension asked for is
/// kept by space and extension: its page and whether it is on, for every
/// tab and for one tab; and whether its button opens it. One panel a window
/// at a time, as Chrome has one beside a tab.
@MainActor
final class ExtensionSidePanels: ObservableObject {
    static let shared = ExtensionSidePanels()

    struct Options: Equatable {
        var path: String?
        var enabled: Bool?
    }

    /// By "space/id": for every tab, and for one ("space/id/tab").
    private var options: [String: Options] = [:]
    /// By "space/id": its button opens the panel.
    private var onAction: Set<String> = []
    /// By "space/tab": the extension that asked for its panel in a tab not
    /// on screen, opened there when it comes on screen.
    private var pending: [String: String] = [:]

    @MainActor final class Panel: ObservableObject, Identifiable {
        let id = UUID()
        let surface: any WebExtensionSurface
        /// The page it was opened at, which its own links may have left.
        let entry: URL
        let name: String
        let icon: NSImage?
        weak var window: WindowModel?

        init(surface: any WebExtensionSurface, entry: URL, name: String, icon: NSImage?, window: WindowModel) {
            self.surface = surface
            self.entry = entry
            self.name = name
            self.icon = icon
            self.window = window
        }
    }

    @Published private(set) var shown: [ObjectIdentifier: Panel] = [:]

    private func key(_ id: String, _ space: UUID, _ tab: UUID? = nil) -> String {
        "\(space.uuidString)/\(id)" + (tab.map { "/\($0.uuidString)" } ?? "")
    }

    func panel(in window: WindowModel) -> Panel? { shown[ObjectIdentifier(window)] }

    // MARK: What the extension asks

    func setOptions(_ id: String, in space: UUID, tab: UUID?, path: String?, enabled: Bool?) {
        var current = options[key(id, space, tab)] ?? Options()
        if let path { current.path = path }
        if let enabled { current.enabled = enabled }
        options[key(id, space, tab)] = current
        // Turned off, or a new page, where it is open now.
        for window in Session.shared.allWindows where window.spaceID == space && (tab == nil || window.tabID == tab) {
            guard panel(in: window)?.surface.extensionID == id else { continue }
            if current.enabled == false { close(in: window) } else if path != nil { open(id, in: window) }
        }
    }

    func options(_ id: String, in space: UUID, tab: UUID?) -> [String: Any] {
        let all = options[key(id, space)] ?? Options()
        let one = tab.flatMap { options[key(id, space, $0)] } ?? Options()
        var out: [String: Any] = ["enabled": one.enabled ?? all.enabled ?? true]
        if let path = one.path ?? all.path ?? defaultPath(id, in: space) { out["path"] = path }
        return out
    }

    func setOpensOnAction(_ id: String, in space: UUID, _ on: Bool) {
        if on { onAction.insert(key(id, space)) } else { onAction.remove(key(id, space)) }
    }

    func opensOnAction(_ id: String, in space: UUID) -> Bool { onAction.contains(key(id, space)) }

    private func defaultPath(_ id: String, in space: UUID) -> String? {
        Extensions.shared.sidePanelDefaultPath(id, in: space)
    }

    // MARK: Showing it

    /// Its page for the tab on screen in the window, if it has one and is on there.
    func open(_ id: String, in window: WindowModel) {
        guard let source = Extensions.shared.sidePanelSource(id, in: window.spaceID) else { return }
        let asked = options(id, in: window.spaceID, tab: window.tabID)
        guard asked["enabled"] as? Bool != false, let path = asked["path"] as? String,
              let url = source.entry(path) else { return }
        // The same page kept, wherever its own links have taken it.
        if let open = panel(in: window), open.surface.extensionID == id, open.entry == url { return }
        close(in: window)
        guard let page = source.makePage(url, window.spaceID) else { return }
        let surface = page.surface
        let panel = Panel(surface: surface, entry: url, name: page.name, icon: page.icon, window: window)
        let key = ObjectIdentifier(window)
        surface.onClose = { [weak self, weak panel] in
            guard let self, let panel, self.shown[key] === panel else { return }
            self.close(key)
        }
        withAnimation(.bar) { shown[key] = panel }
    }

    /// Its panel for a tab that isn't on screen: opened when the tab is.
    func open(_ id: String, whenShowing tab: UUID, in space: UUID) {
        pending["\(space.uuidString)/\(tab.uuidString)"] = id
    }

    /// Closed for a tab not on screen: no longer opened when it is.
    func cancel(_ id: String, tab: UUID, in space: UUID) {
        let key = "\(space.uuidString)/\(tab.uuidString)"
        if pending[key] == id { pending[key] = nil }
    }

    func toggle(_ id: String, in window: WindowModel) {
        if panel(in: window)?.surface.extensionID == id { close(in: window) } else { open(id, in: window) }
    }

    func close(in window: WindowModel) { close(ObjectIdentifier(window)) }

    private func close(_ key: ObjectIdentifier) {
        guard let panel = shown[key] else { return }
        // The keys back to the page, if they were in the panel.
        let focused = panel.surface.hasFocus
        withAnimation(.bar) { _ = shown.removeValue(forKey: key) }
        panel.surface.close()
        if focused { panel.window?.focusPage() }
    }

    /// An extension's panels, when it unloads, or a space's.
    func closeAll(of id: String? = nil, in space: UUID? = nil) {
        for (key, panel) in shown where (id == nil || panel.surface.extensionID == id) && (space == nil || panel.surface.space == space) {
            close(key)
        }
        guard id != nil || space != nil else { return }
        let matches = { (name: String) in (space == nil || name.hasPrefix(space!.uuidString)) && (id == nil || name.contains("/\(id!)")) }
        for name in Array(options.keys) where matches(name) { options[name] = nil }
        for (name, asked) in pending where (space == nil || name.hasPrefix(space!.uuidString)) && (id == nil || asked == id) { pending[name] = nil }
    }

    /// An extension removed from eGlu: its panels, and everything it
    /// asked for, in every space.
    func forget(_ id: String) {
        closeAll(of: id)
        options = options.filter { !$0.key.contains("/\(id)") }
        onAction = onAction.filter { !$0.hasSuffix("/\(id)") }
        pending = pending.filter { $0.value != id }
    }

    /// Another tab on screen: the panel follows what was asked for that tab.
    func tabChanged(in window: WindowModel) {
        if let tab = window.tabID, let id = pending.removeValue(forKey: "\(window.spaceID.uuidString)/\(tab.uuidString)") {
            return open(id, in: window)
        }
        guard let panel = panel(in: window) else { return }
        let asked = options(panel.surface.extensionID, in: window.spaceID, tab: window.tabID)
        if asked["enabled"] as? Bool == false { close(in: window) } else { open(panel.surface.extensionID, in: window) }
    }
}

/// The panel beside the page's card: a card of its own, its extension's
/// icon, name and × along its top, as the popup's pane has them. 360
/// wide, narrower down to 240 to leave the page 320; in a window too narrow
/// for even that, a compact notice offers resize and close.
struct ExtensionSidePanelView: View {
    @ObservedObject var model: WindowModel
    /// The width the page's card and the panel share.
    let room: CGFloat
    @ObservedObject private var panels = ExtensionSidePanels.shared

    var body: some View {
        let width = min(360, max(240, room - Metrics.gap - 320))
        if let panel = panels.panel(in: model), room - Metrics.gap - width >= 160 {
            let shape = RoundedRectangle(cornerRadius: Metrics.card, style: .continuous)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Group {
                        if let icon = panel.icon {
                            Image(nsImage: icon).resizable().interpolation(.high)
                        } else {
                            Image(systemName: "puzzlepiece.extension").resizable().scaledToFit().foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 16, height: 16)
                    Text(panel.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button {
                        panels.close(in: model)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(PressedIconStyle())
                    .help("Close Side Panel")
                    .accessibilityLabel("Close \(panel.name)'s side panel")
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                SurfaceView(surface: panel.surface)
                    .id(panel.id)
            }
            .frame(width: width)
            .background(shape.fill(Color(nsColor: .textBackgroundColor)))
            .clipShape(shape)
            .shadow(color: .black.opacity(0.16), radius: 1, y: 0.5)
            .shadow(color: .black.opacity(0.08), radius: 14, y: 6)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        } else if let panel = panels.panel(in: model) {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(panel.name) side panel is open").font(.headline)
                Text("Widen this window to show its content.").font(.callout).foregroundStyle(.secondary)
                Button("Widen Window") {
                    guard let window = model.window else { return }
                    var size = window.contentLayoutRect.size
                    size.width = max(size.width, 800)
                    window.setContentSize(size)
                }
                Button("Close Side Panel") { panels.close(in: model) }
            }
            .padding(12)
            .frame(width: min(200, max(120, room * 0.45)))
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metrics.card))
        }
    }
}
