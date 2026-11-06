import AppKit
import PadCore
import SwiftUI
import WebEngineAppKit

/// Where extensions show in a window (Docs/ExtensionsDesign.md, section 2,
/// "Where extensions show"): the puzzle button, with this space's
/// extensions in its list, in the order the person drags them to; on the
/// sidebar's address row, or at the end of the tabs along the top.
struct ExtensionsButton: View {
    @ObservedObject var model: WindowModel
    @ObservedObject private var extensions = Extensions.shared

    var body: some View {
        let unseen = extensions.unseen.contains { $0.hasPrefix(model.spaceID.uuidString) }
        Button {
            model.extensionsShown.toggle()
        } label: {
            Image(systemName: "puzzlepiece.extension")
                .overlay(alignment: .topTrailing) {
                    // Something new to read about one of them: in by scale,
                    // opacity and blur, not suddenly.
                    if unseen {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .offset(x: 3, y: -2)
                            .transition(.mark)
                    }
                }
                .animation(.bar, value: unseen)
        }
        .buttonStyle(PressedIconStyle())
        .help("Extensions")
        .accessibilityLabel("Extensions")
        .accessibilityValue(unseen ? String(localized: "Something new to read") : "")
        .popover(isPresented: $model.extensionsShown, arrowEdge: .bottom) {
            ExtensionsList(model: model)
        }
        // Right after an install the list opens by itself, with the new one's
        // check; once, not again as the button is drawn anew.
        .onReceive(extensions.$justInstalled) { installed in
            // In the window in front that shows the space.
            guard let installed, installed.space == model.spaceID,
                  Session.shared.allWindows.first(where: { $0.spaceID == installed.space && $0.window?.isKeyWindow == true })
                    ?? Session.shared.allWindows.first(where: { $0.spaceID == installed.space }) === model else { return }
            model.extensionsShown = true
            DispatchQueue.main.async { extensions.tookJustInstalled() }
        }
    }
}

/// The puzzle button's panel, in three pages, so using an extension and
/// setting it up never share a row (Docs/ExtensionsDesign.md, section 2):
///
/// - Use: the extensions on in this space, four to a row, each a tile of
///   glass as a pinned tab's is, pressed to open it as its button in
///   Chrome's toolbar is; its name under it, its badge on its corner.
/// - Manage: every extension, its switch for this space, dragged into the
///   order Use shows; other Macs' to add; adding.
/// - One extension: on here, site access, options, a report, removal.
///
/// Every row's content stands 16 in from the panel's sides: rows 8 in,
/// their content 8 further. A page comes in from the side it is reached
/// from and leaves the way it came.
struct ExtensionsList: View {
    @ObservedObject var model: WindowModel
    @ObservedObject private var extensions = Extensions.shared
    @State private var page: Page = Self.firstPage
    /// Which way the last move went: forward comes in from the trailing side.
    @State private var forward = true
    /// The page an extension's own was opened from, to go back to.
    @State private var cameFrom: Page = .manage

    enum Page: Equatable {
        case use
        case manage
        case detail(String)
    }

    static let width: CGFloat = 320

    /// Use; or, for a picture of the others, the one named (-extensionPanelPage manage, detail).
    private static var firstPage: Page {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "extensionPanelPage") {
        case "manage": return .manage
        case "detail": return Extensions.shared.installed.first.map { .detail($0.id) } ?? .use
        default: return .use
        }
        #else
        return .use
        #endif
    }

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                switch page {
                case .use:
                    UsePage(model: model, manage: { go(.manage, forward: true) }, open: { go(.detail($0), forward: true) })
                case .manage:
                    ManagePage(model: model, back: { go(.use, forward: false) }, open: { go(.detail($0), forward: true) })
                case .detail(let id):
                    DetailPage(model: model, id: id) { go(cameFrom, forward: false) }
                }
            }
            .transition(.asymmetric(insertion: .offset(x: forward ? 40 : -40).combined(with: .opacity),
                                    removal: .offset(x: forward ? -40 : 40).combined(with: .opacity)))
        }
        .frame(width: Self.width)
        .clipped()
        // Its own height, not the popover's guess.
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { extensions.seen(in: model.spaceID) }
        // One removed while its page is up: back to the list.
        .onChange(of: extensions.installed.map(\.id)) { _, ids in
            if case .detail(let id) = page, !ids.contains(id) { go(cameFrom, forward: false) }
        }
    }

    private func go(_ next: Page, forward: Bool) {
        if case .detail = next { cameFrom = page }
        self.forward = forward
        withAnimation(.bar) { page = next }
    }
}

// MARK: Use

/// The extensions on in this space, to open; and the way to manage them.
private struct UsePage: View {
    @ObservedObject var model: WindowModel
    let manage: () -> Void
    /// An extension's own page, for a long press on its tile.
    let open: (String) -> Void
    @ObservedObject private var extensions = Extensions.shared
    @ObservedObject private var sync = Sync.shared

    var body: some View {
        let usable = extensions.installed.filter { $0.spaces.contains(model.spaceID) && !extensions.isIncompatible($0.id) }
        let offers = extensions.offers(from: sync)
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(String(localized: "Extensions"))
            if usable.isEmpty {
                // Nothing to open here: say why, in a line, and leave the way on below.
                Text(extensions.installed.isEmpty
                     ? String(localized: "Add extensions from the Chrome Web Store: each one\u{2019}s page there has an Add to eGlu button.")
                     : String(localized: "None are on in this space."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            } else {
                UseGrid(model: model, items: usable, open: open)
            }
            Divider()
            VStack(spacing: 0) {
                if extensions.installed.isEmpty {
                    PanelButton(action: { openStore(in: model) }) {
                        RowLabel(symbol: "bag", title: String(localized: "Chrome Web Store"), trailing: .outward)
                    }
                }
                PanelButton(action: manage) {
                    RowLabel(symbol: "slider.horizontal.3", title: String(localized: "Manage Extensions"),
                             note: offers.isEmpty ? nil : String(localized: "\(offers.count) to add"), trailing: .onward)
                }
            }
            .padding(8)
        }
    }
}

/// The extensions to open, four to a row in the order Manage gives them,
/// dragged here too as pinned tabs are; four rows, then scrolled.
private struct UseGrid: View {
    @ObservedObject var model: WindowModel
    let items: [Extensions.Installed]
    let open: (String) -> Void
    @ObservedObject private var extensions = Extensions.shared
    @State private var dragging: String?

    static let columns = Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 4)

    var body: some View {
        let grid = GlassEffectContainer(spacing: 2) {
            LazyVGrid(columns: Self.columns, spacing: 10) {
                ForEach(items) { item in
                    UseTile(model: model, item: item) { open(item.id) }
                        .onDrag {
                            dragging = item.id
                            return NSItemProvider(object: item.id as NSString)
                        }
                        .onDrop(of: [.text], delegate: Reorder(target: item.id, dragging: $dragging))
                        .accessibilityAction(named: "Move Up") { extensions.move(item.id, by: -1) }
                        .accessibilityAction(named: "Move Down") { extensions.move(item.id, by: 1) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 14)
        }
        if items.count <= 16 {
            grid.fixedSize(horizontal: false, vertical: true)
        } else {
            ScrollView { grid }.frame(height: 330)
        }
    }
}

/// An extension to open: its icon on a square of glass, as a pinned tab's
/// tile is, darkening under the pointer and giving a little when pressed;
/// its badge (a count, a word) on the tile's corner, a warning mark on the
/// other, its name under it. Dimmed and inert while its button is disabled.
/// Its options, as Chrome's toolbar button gives them, on a secondary click;
/// a long press opens its own page in the panel, where all of them are.
private struct UseTile: View {
    @ObservedObject var model: WindowModel
    let item: Extensions.Installed
    let manage: () -> Void
    @ObservedObject private var extensions = Extensions.shared
    @State private var hovering = false
    @State private var targeted = false

    /// The tile: 52 square, its icon 24, 14 from each side, and its corners
    /// the icon's (about 5) and those 14.
    static let size: CGFloat = 52
    static let icon: CGFloat = 24
    static let corner: CGFloat = 19

    var body: some View {
        // Read again whenever WebKit says an action changed (actionsChanged).
        let _ = extensions.actionsChanged
        let action = extensions.action(for: item.id, in: model, iconSize: CGSize(width: Self.icon, height: Self.icon))
        let warning = extensions.warning(item.id, in: model.spaceID)
        let unavailable = extensions.unavailableReason(item.id, in: model)
        let enabled = unavailable == nil
        let label = (action?.label).flatMap { $0.isEmpty ? nil : $0 } ?? item.name
        let badge = (action?.badgeText).flatMap { $0.isEmpty ? nil : String($0.prefix(4)) }
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        Button {
            model.extensionsShown = false
            extensions.run(item.id, in: model)
        } label: {
            VStack(spacing: 5) {
                Group {
                    if let icon = action?.icon ?? extensions.icon(of: item.id, in: model.spaceID) {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "puzzlepiece.extension").resizable().scaledToFit().foregroundStyle(.secondary)
                    }
                }
                .frame(width: Self.icon, height: Self.icon)
                .opacity(enabled ? 1 : 0.45)
                .frame(width: Self.size, height: Self.size)
                .background(Highlight(hovering: hovering && enabled, shape: shape))
                .contentShape(shape)
                .glassEffect(.regular, in: shape)
                .overlay {
                    if targeted { shape.strokeBorder(Color.accentColor, lineWidth: 2) }
                }
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        // Counts don't shift the badge as they change.
                        Text(badge)
                            .font(.system(size: 10, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Capsule().fill(Color.accentColor))
                            .offset(x: 5, y: -5)
                            .transition(.mark)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if warning != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 11))
                            .offset(x: 3, y: 3)
                            .transition(.mark)
                    }
                }
                .animation(.bar, value: badge)
                Text(item.name)
                    .font(.system(size: 11))
                    .foregroundStyle(enabled ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
        }
        // A press gives a little, inside the tile's own room, as a pinned tab's does.
        .buttonStyle(TilePress())
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .onLongPressGesture(minimumDuration: 0.5, perform: manage)
        .contextMenu { ExtensionMenu(model: model, item: item, manage: manage) }
        // Why it is dimmed, under the pointer: the tile itself stays its icon and its name.
        .help(warning.map { "\(label): \(([$0.title + "."] + $0.lines).joined(separator: " "))" }
              ?? unavailable.map { "\(label): \($0)" } ?? label)
        .accessibilityLabel(label)
        .accessibilityValue([badge, warning?.title].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(unavailable ?? String(localized: "Opens the extension"))
    }
}

// MARK: Manage

/// Every extension with its switch for this space, in the order Use shows
/// them, each pressed for its own page; other Macs' to add; adding.
private struct ManagePage: View {
    @ObservedObject var model: WindowModel
    let back: () -> Void
    let open: (String) -> Void
    @ObservedObject private var extensions = Extensions.shared
    @ObservedObject private var sync = Sync.shared
    /// The row being dragged to another place.
    @State private var dragging: String?

    var body: some View {
        let offers = extensions.offers(from: sync)
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: String(localized: "Manage Extensions"), back: back)
            if !extensions.installed.isEmpty || !offers.isEmpty {
                Scrolled(count: extensions.installed.count + offers.count) {
                    ForEach(extensions.installed) { item in
                        ManageRow(model: model, item: item) { open(item.id) }
                            .onDrag {
                                dragging = item.id
                                return NSItemProvider(object: item.id as NSString)
                            }
                            .onDrop(of: [.text], delegate: Reorder(target: item.id, dragging: $dragging))
                            .accessibilityAction(named: "Move Up") { extensions.move(item.id, by: -1) }
                            .accessibilityAction(named: "Move Down") { extensions.move(item.id, by: 1) }
                    }
                    if !extensions.installed.isEmpty {
                        Note(String(localized: "Switches are for this space. Drag to change the order."))
                    }
                    // Other Macs' that aren't on this one (iCloud).
                    if !offers.isEmpty {
                        SectionTitle(String(localized: "On Your Other Macs"))
                        ForEach(offers, id: \.storeID) { offer in
                            OfferRow(model: model, offer: offer)
                        }
                    }
                }
                Divider()
            }
            VStack(spacing: 0) {
                PanelButton(action: { openStore(in: model) }) {
                    RowLabel(symbol: "bag", title: String(localized: "Chrome Web Store"), trailing: .outward)
                }
                PanelButton(action: { extensions.addFromFile(in: model) }) {
                    RowLabel(symbol: "doc.badge.plus", title: String(localized: "Add from File\u{2026}"))
                }
                PanelButton(action: { extensions.loadUnpacked(in: model) }) {
                    RowLabel(symbol: "folder.badge.plus", title: String(localized: "Load Unpacked\u{2026}"))
                }
            }
            .padding(8)
        }
    }
}

/// An extension in Manage, the whole row one target under the pointer:
/// pressed for its own page, its switch for this space just before the
/// chevron that says so. One that can't run here has a warning triangle in
/// the switch's place.
private struct ManageRow: View {
    @ObservedObject var model: WindowModel
    let item: Extensions.Installed
    let open: () -> Void
    @ObservedObject private var extensions = Extensions.shared
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        let on = item.spaces.contains(model.spaceID)
        let incompatible = extensions.isIncompatible(item.id)
        let warning = on ? extensions.warning(item.id, in: model.spaceID) : nil
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 8) {
                    ExtensionIcon(item: item, action: nil, space: model.spaceID)
                        .opacity(on && !incompatible ? 1 : 0.5)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(on && !incompatible ? .primary : .secondary)
                            .lineLimit(1)
                        if incompatible {
                            Text(String(localized: "Incompatible: \(extensions.incompatibility(item.id))"))
                                .fixedSize(horizontal: false, vertical: true)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        } else if let warning {
                            Text(([warning.title] + warning.lines).joined(separator: " "))
                                .fixedSize(horizontal: false, vertical: true)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer(minLength: 4)
                }
                .frame(minHeight: Metrics.control)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressReporting(pressed: $pressed))
            .accessibilityLabel(item.name)
            .accessibilityHint("Shows its settings")
            if incompatible {
                // In the switch's place, as wide as it: it can't be turned on here.
                SwitchShape(isOn: .constant(false))
                    .hidden()
                    .overlay {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 13))
                    }
                    .help("Incompatible with eGlu on this Mac. \(extensions.incompatibility(item.id))")
                    .accessibilityElement()
                    .accessibilityLabel("\(item.name) is incompatible")
            } else {
                SwitchShape(isOn: Binding(get: { on }, set: { extensions.turn(item.id, on: $0, in: model.spaceID) }))
                    .help("Use in This Space")
                    .accessibilityLabel("Use \(item.name) in this space")
            }
            // The chevron too opens its page, its glyph on the content edge.
            Button(action: open) {
                Onward()
                    .frame(width: 12, height: Metrics.control, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressReporting(pressed: $pressed))
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // One highlight for the row, its switch and chevron in it: in under
        // the pointer quickly, down at once on a press, back up softly.
        .background {
            RoundedRectangle(cornerRadius: Metrics.rowCorner, style: .continuous)
                .fill(pressed ? Palette.press : hovering ? Palette.hover : Color.clear)
                .animation(pressed ? nil : .hover, value: pressed)
                .animation(.hover, value: hovering)
        }
        .onHover { hovering = $0 }
        .contextMenu { ExtensionMenu(model: model, item: item, manage: open) }
    }
}

/// A small switch, at its own width.
private struct SwitchShape: View {
    let isOn: Binding<Bool>

    var body: some View {
        Toggle("", isOn: isOn)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .fixedSize()
    }
}

/// An extension's options on a secondary click, as Chrome's toolbar
/// button gives them: its own options, its site access, off or out of this
/// space, a report, and its page in the panel, where all of them are.
private struct ExtensionMenu: View {
    @ObservedObject var model: WindowModel
    let item: Extensions.Installed
    let manage: () -> Void
    @ObservedObject private var extensions = Extensions.shared

    var body: some View {
        let on = item.spaces.contains(model.spaceID)
        let incompatible = extensions.isIncompatible(item.id)
        if on, !incompatible, extensions.optionsPageURL(item.id, in: model.spaceID) != nil {
            Button("Options") {
                model.extensionsShown = false
                extensions.openOptions(item.id, in: model)
            }
        }
        Picker("Site Access", selection: Binding(get: { item.siteAccess }, set: { extensions.setSiteAccess(item.id, $0) })) {
            Text("All Sites It Asks For").tag(Extensions.Installed.SiteAccess.allSites)
            Text("When I Click It").tag(Extensions.Installed.SiteAccess.onClick)
        }
        Divider()
        if !incompatible {
            Toggle("Use in This Space", isOn: Binding(get: { on }, set: { extensions.turn(item.id, on: $0, in: model.spaceID) }))
        }
        Button("Remove Data from This Space…") { extensions.confirmRemoval(of: item.id, from: model.spaceID, in: model) }
        Button("Remove from eGlu\u{2026}") { extensions.confirmRemoval(of: item.id, in: model) }
        Divider()
        if extensions.saidLooksWrong(item.id) {
            Button("Show Its Warnings Again") { extensions.setLooksWrong(item.id, false) }
        } else if extensions.isWarned(item.id) {
            Button(extensions.isIncompatible(item.id) ? String(localized: "Try Again and Hide Warnings") : String(localized: "Hide Warnings for This Version")) { extensions.setLooksWrong(item.id, true) }
        }
        Button("Report a Problem\u{2026}") { ExtensionReport.show(item.id, in: model) }
        Button("Move Up") { extensions.move(item.id, by: -1) }
            .disabled(extensions.installed.first?.id == item.id)
        Button("Move Down") { extensions.move(item.id, by: 1) }
            .disabled(extensions.installed.last?.id == item.id)
        Button("Manage Extension") { manage() }
    }
}

/// Another Mac's extension that isn't on this one: its name, and Add,
/// which downloads it here and asks in this Mac's own sheet.
private struct OfferRow: View {
    @ObservedObject var model: WindowModel
    let offer: SyncExtension
    @ObservedObject private var extensions = Extensions.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
            Text(offer.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Add") {
                extensions.add(storeID: offer.storeID, in: model, access: offer.siteAccess == "onClick" ? .onClick : .allSites)
            }
            .controlSize(.small)
            .disabled(extensions.busy != nil)
            .accessibilityLabel("Add \(offer.title) to This Mac")
        }
        .frame(minHeight: Metrics.control)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contextMenu {
            Button("Don\u{2019}t Offer on This Mac") { extensions.decline(offer.storeID) }
        }
        .accessibilityAction(named: "Don\u{2019}t Offer on This Mac") { extensions.decline(offer.storeID) }
    }
}

// MARK: One extension

/// One extension's own page: whether it is on here and what it may read;
/// what it offers; a report; then removal, last and apart.
private struct DetailPage: View {
    @ObservedObject var model: WindowModel
    let id: String
    let back: () -> Void
    @ObservedObject private var extensions = Extensions.shared

    var body: some View {
        if let item = extensions.installed.first(where: { $0.id == id }) {
            let on = item.spaces.contains(model.spaceID)
            let incompatible = extensions.isIncompatible(id)
            let warning = on ? extensions.warning(id, in: model.spaceID) : nil
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: item.name, back: back)
                // What was found, in full here: the list says it in a word.
                if incompatible {
                    Finding(title: String(localized: "Incompatible with eGlu on this Mac"), text: extensions.incompatibility(id))
                } else if let warning {
                    Finding(title: warning.title, text: warning.lines.joined(separator: " "))
                }
                VStack(spacing: 0) {
                    SettingLine(title: String(localized: "Use in This Space")) {
                        SwitchShape(isOn: Binding(get: { on }, set: { extensions.turn(id, on: $0, in: model.spaceID) }))
                            .disabled(incompatible)
                            .accessibilityLabel("Use \(item.name) in this space")
                    }
                    SettingLine(title: String(localized: "Site Access"), note: String(localized: "In every space")) {
                        Picker("Site Access", selection: Binding(get: { item.siteAccess }, set: { extensions.setSiteAccess(id, $0) })) {
                            Text("All Sites It Asks For").tag(Extensions.Installed.SiteAccess.allSites)
                            Text("When I Click It").tag(Extensions.Installed.SiteAccess.onClick)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }
                    VersionLine(version: item.version)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
                Divider()
                VStack(spacing: 0) {
                    if on, !incompatible, extensions.optionsPageURL(id, in: model.spaceID) != nil {
                        PanelButton(action: {
                            model.extensionsShown = false
                            extensions.openOptions(id, in: model)
                        }) {
                            RowLabel(symbol: "gearshape", title: String(localized: "Options"), trailing: .outward)
                        }
                    }
                    if item.source == .unpacked {
                        PanelButton(action: { extensions.reload(id) }) {
                            RowLabel(symbol: "arrow.clockwise", title: String(localized: "Reload"))
                        }
                    }
                    // The person's word over the checks', until it updates.
                    if extensions.saidLooksWrong(id) {
                        PanelButton(action: { extensions.setLooksWrong(id, false) }) {
                            RowLabel(symbol: "exclamationmark.bubble", title: String(localized: "Show Its Warnings Again"))
                        }
                    } else if extensions.isWarned(id) {
                        PanelButton(action: { extensions.setLooksWrong(id, true) }) {
                            RowLabel(symbol: "hand.raised", title: incompatible ? String(localized: "Try Again and Hide Warnings") : String(localized: "Hide Warnings for This Version"))
                        }
                    }
                    PanelButton(action: { ExtensionReport.show(id, in: model) }) {
                        RowLabel(symbol: "ladybug", title: String(localized: "Report a Problem\u{2026}"))
                    }
                }
                .padding(8)
                Divider()
                // Last, and apart: what takes what it kept.
                VStack(spacing: 0) {
                    PanelButton(action: { extensions.confirmRemoval(of: id, from: model.spaceID, in: model) }) {
                        RowLabel(symbol: "minus.circle", title: String(localized: "Remove Data from This Space…"), role: .destructive)
                    }
                    .help("Turns it off here and deletes what it kept in this space")
                    PanelButton(action: { extensions.confirmRemoval(of: id, in: model) }) {
                        RowLabel(symbol: "trash", title: String(localized: "Remove from eGlu\u{2026}"), role: .destructive)
                    }
                }
                .padding(8)
            }
        }
    }
}

/// Its version, pressed to copy it: the number gives way to "Copied" for
/// a moment, then comes back.
private struct VersionLine: View {
    let version: String
    @State private var copied = false

    var body: some View {
        PanelButton(action: copy) {
            HStack(spacing: 8) {
                Text("Version").font(.system(size: 13))
                Spacer(minLength: 8)
                Text(copied ? String(localized: "Copied") : version)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.opacity)
            }
        }
        .help("Copy the Version Number")
        .accessibilityLabel("Version \(version)")
        .accessibilityHint("Copies it")
        .accessibilityValue(copied ? String(localized: "Copied") : "")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(version, forType: .string)
        withAnimation(.hover) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.hover) { copied = false }
        }
    }
}

/// A setting's line: its name (and a note under it) and its control, on one line.
private struct SettingLine<Control: View>: View {
    let title: String
    var note: String?
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            control()
        }
        .frame(minHeight: Metrics.control)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

/// What the checks found, in full, under the header: in the warning's
/// colour, on a wash of it.
private struct Finding: View {
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                if !text.isEmpty {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: Metrics.rowCorner, style: .continuous).fill(Color.orange.opacity(0.1)))
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}

// MARK: The parts

@MainActor private func openStore(in model: WindowModel) {
    model.extensionsShown = false
    model.open(URL(string: "https://chromewebstore.google.com/category/extensions")!, newTab: true)
}

/// A page's name, at its top, on the content edge.
private struct PageTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.headline)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }
}

/// A page reached from another: back, then its name.
private struct PageHeader: View {
    let title: String
    let back: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(PressedIconStyle())
            .help("Back")
            .accessibilityLabel("Back")
            Text(title)
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        // The chevron's glyph, not its cell, near the content edge.
        .padding(.leading, 6)
        .padding(.trailing, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}

/// A section's name over its rows.
private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }
}

/// A line under rows that says how they work.
private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 6)
    }
}

/// Rows 8 in from the panel's sides, their whole height for a few and
/// scrolled past that.
private struct Scrolled<Content: View>: View {
    let count: Int
    @ViewBuilder let content: () -> Content

    var body: some View {
        let rows = VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        if count <= 6 {
            rows.fixedSize(horizontal: false, vertical: true)
        } else {
            ScrollView { rows }.frame(height: 360)
        }
    }
}

/// Where a row leads: on to a page in the panel, or out of it (a tab).
private enum Trailing {
    case none, onward, outward
}

private struct Onward: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
    }
}

/// A row's content: a symbol in the icons' 20-point place, its title, a
/// note at the end, and where it leads.
private struct RowLabel: View {
    let symbol: String
    let title: String
    var note: String?
    var trailing: Trailing = .none
    var role: ButtonRole?

    var body: some View {
        let tint: Color = role == .destructive ? .red : .primary
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(role == .destructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                .frame(width: 20, height: 20)
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(tint)
            Spacer(minLength: 4)
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            switch trailing {
            case .none: EmptyView()
            case .onward: Onward()
            case .outward:
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// A row pressed for what it says, as a Mac menu's items are: flat until
/// the pointer is on it, washed then, darker the moment it is pressed (not
/// on its release), back softly; dimmed and inert when it can't be used.
private struct PanelButton<Label: View>: View {
    var enabled = true
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    #if DEBUG
    /// Drawn hovered for a picture of it (-extensionRowHover YES).
    @State private var hovering = UserDefaults.standard.bool(forKey: "extensionRowHover")
    #else
    @State private var hovering = false
    #endif
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, minHeight: Metrics.control, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressReporting(pressed: $pressed))
        .disabled(!enabled)
        // The row's corners round its icon's (4) by the 8 between them.
        .background {
            RoundedRectangle(cornerRadius: Metrics.rowCorner, style: .continuous)
                .fill(pressed ? Palette.press : hovering && enabled ? Palette.hover : Color.clear)
                .animation(pressed ? nil : .hover, value: pressed)
                .animation(.hover, value: hovering)
        }
        .onHover { hovering = $0 }
    }
}

/// Tells the row its button is held down, so it darkens on the press itself.
private struct PressReporting: ButtonStyle {
    @Binding var pressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, now in pressed = now }
    }
}

/// A row moved as another is dragged over it, as a list on the Mac moves.
private struct Reorder: DropDelegate {
    let target: String
    @Binding var dragging: String?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(.bar) { Extensions.shared.move(dragging, to: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// An extension's icon: the one its button shows on this tab if it set
/// one, with its badge (a count, a word) at the corner.
private struct ExtensionIcon: View {
    let item: Extensions.Installed
    let action: WebExtensionAction?
    let space: UUID
    @ObservedObject private var extensions = Extensions.shared

    var body: some View {
        Group {
            if let icon = action?.icon ?? extensions.icon(of: item.id, in: space) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "puzzlepiece.extension").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .frame(width: 20, height: 20)
        .overlay(alignment: .bottomTrailing) {
            if let badge = action?.badgeText, !badge.isEmpty {
                // Counts don't shift the badge as they change.
                Text(badge.prefix(4))
                    .font(.system(size: 8, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .frame(minWidth: 12, minHeight: 11)
                    .background(Capsule().fill(Color.accentColor))
                    .offset(x: 5, y: 4)
                    .transition(.mark)
            }
        }
        .animation(.bar, value: action?.badgeText)
    }
}

extension AnyTransition {
    /// A small mark coming and going: from a quarter of its size, unseen
    /// and 4 points blurred.
    static var mark: AnyTransition {
        .scale(scale: 0.25).combined(with: .opacity).combined(with: .modifier(active: Blurred(radius: 4), identity: Blurred(radius: 0)))
    }
}

private struct Blurred: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

/// The bars' icon buttons, as PlainIconStyle draws them, pressed down a
/// little (0.96) as they are clicked.
struct PressedIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PlainIconStyle().makeBody(configuration: configuration)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.hover, value: configuration.isPressed)
    }
}
