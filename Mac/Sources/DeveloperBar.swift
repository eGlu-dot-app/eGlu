import PadCore
import SwiftUI
import WebEngineCore

/// The developer bar across a page's top, as Arc's own bar: the whole
/// address with its port, the response's status, and the tools' buttons.
/// One per page's card, shown while the site has developer mode on
/// (DeveloperMode.isOn); its commands act on the card's own page, so the
/// bar on the page beside acts on that page.
struct DeveloperBar: View {
    @ObservedObject var model: WindowModel
    let tab: UUID?
    let page: Page
    let focused: Bool

    /// Where the card's page is, with what it is loading while one goes.
    private var address: URL? {
        focused ? model.url : (page.displayURL ?? page.state.url)
    }

    private var statusCode: Int? {
        focused ? model.statusCode : page.statusCode
    }

    /// Whether the card's page has developer mode on, as the window's
    /// settings have it (a choice on either site repaints both bars).
    static func isOn(_ page: Page?, url: URL?) -> Bool {
        let preferences = Session.shared.preferences
        return DeveloperMode.isOn(url ?? page?.displayURL ?? page?.state.url,
                                  choices: preferences.developerSites, local: preferences.developerLocal)
    }

    /// The bar's height: the page under it is that much shorter, and what
    /// stands at the card's top (the toast, the find bar) goes below it.
    static let height: CGFloat = 28

    /// Whether the card at the pages' top `edge` has the bar: what stands
    /// at that corner over the pages (the toast, an extension's popup) goes
    /// below it, off the bar's address and buttons.
    static func isOn(at edge: HorizontalEdge, in model: WindowModel) -> Bool {
        var page = model.page
        if let split = model.split, let partner = model.partner,
           (edge == .leading ? split.left : split.right) != model.tabID {
            page = partner
        }
        return isOn(page, url: page === model.page ? model.url : nil)
    }

    var body: some View {
        HStack(spacing: 8) {
            if let address {
                addressText(address)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
                    .onTapGesture(perform: type)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { type() }
            }
            Spacer(minLength: 4)
            if let code = statusCode {
                // On a pill of its own colour, faint, so the number reads as a status at a glance.
                Text(verbatim: String(code))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Self.color(for: code))
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(Capsule().fill(Self.color(for: code).opacity(0.14)))
            }
            HStack(spacing: 1) { buttons }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        // Off for the site from the bar itself, without a button of its own:
        // its menu, from a secondary click on the bar (and the Size menu).
        .contextMenu { siteItems }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        // The bar's page is the card's, not the window's: its buttons act
        // on it through Page and WebKit's own calls, never on the window's.
        .environment(\.openURL, OpenURLAction { _ in .handled })
    }

    /// What the bar's menus have for the site: developer mode off for it
    /// (the bar shows only while it is on), and its address copied whole.
    @ViewBuilder
    private var siteItems: some View {
        Button(String(localized: "Turn Developer Mode Off for This Site")) {
            model.setDeveloperMode(false, for: address)
        }
        .disabled(DeveloperMode.siteKey(address) == nil)
        if let address {
            Button(String(localized: "Copy Address")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(address.absoluteString, forType: .string)
            }
        }
    }

    /// A click on the address: the command bar, holding it, for the card's page.
    private func type() {
        if let tab, !focused { model.focus(pane: tab) }
        model.commandBar = .here
    }

    /// The address whole: scheme, host, the port in the accent colour, and
    /// the path and query, as the Decided bar has it. One attributed string,
    /// so the address is never a key to look up in the String Catalog.
    private func addressText(_ url: URL) -> Text {
        var host = url.host() ?? ""
        if host.hasPrefix("[") == false, host.contains(":") { host = "[\(host)]" }
        var text = AttributedString("\(url.scheme ?? "")://\(host)")
        if let port = url.port {
            var colon = AttributedString(":\(port)")
            colon.swiftUI.foregroundColor = .accentColor
            text += colon
        }
        let tail = (url.path().isEmpty || url.path() == "/" ? "" : url.path())
            + (url.query().map { "?" + $0 } ?? "")
            + (url.fragment().map { "#" + $0 } ?? "")
        text += AttributedString(tail)
        return Text(text)
    }

    /// 2xx green, 3xx grey, 4xx orange, 5xx red.
    private static func color(for code: Int) -> Color {
        switch code {
        case 200..<300: return .green
        case 300..<400: return .secondary
        case 400..<500: return .orange
        case 500..<600: return .red
        default: return .secondary
        }
    }

    /// In threes by what they are for: Web Inspector's, the page's own
    /// tools, and the page reloaded or sized; a hairline between.
    @ViewBuilder
    private var buttons: some View {
        button(.inspector) { act(.inspector) }
        button(.console) { act(.console) }
        button(.selectElement) { act(.selectElement) }
        separator
        button(.elementPicture) { act(.elementPicture) }
        // The tool's button pressed again ends it, as ⌃⌥M does.
        button(.measure, on: page.measure != nil) { act(.measure) }
        separator
        button(.reloadOrigin) { act(.reloadOrigin) }
        sizeMenu
        // Raw, on a page with the JSON view: on while the page shows its
        // own text, and the way back to the view (Page.jsonView).
        if let drawn = page.jsonView {
            Toggle(String(localized: "Raw"), isOn: Binding(get: { !drawn }, set: { _ in page.toggleJSONView() }))
                .toggleStyle(.button)
                .controlSize(.small)
                .font(.system(size: 11, weight: .medium))
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 14)
            .padding(.horizontal, 4)
    }

    /// A tool: its symbol in a square the same size as every other, lit
    /// under the pointer; while it runs on the card's page (Measure), on a
    /// faint chip of the accent colour, the symbol in it.
    private func button(_ command: Command, on: Bool = false, act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: command.symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(BarToolStyle(on: on))
        .help(WindowModel.keys(for: command).map { String(localized: "\(command.macTitle) (\($0))") } ?? command.macTitle)
        .accessibilityLabel(command.macTitle)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The page at a device's size with its user agent (Decided 9):
    /// iPhone 393 by 852, iPad 820 by 1180, Full as the card is. The one
    /// it is at has the check, and the menu's icon is its device.
    private var sizeMenu: some View {
        let size = page.deviceSize
        return Menu {
            Toggle(String(localized: "Full"), isOn: chosen(size == nil) { page.size(nil, pad: false) })
            Toggle(String(localized: "iPhone"), isOn: chosen(size == Self.iPhone) { page.size(Self.iPhone, pad: false) })
            Toggle(String(localized: "iPad"), isOn: chosen(size == Self.iPad) { page.size(Self.iPad, pad: true) })
            // The bar's one visible menu has the site's switch too.
            Divider()
            siteItems
        } label: {
            Image(systemName: size == Self.iPhone ? "iphone" : size == Self.iPad ? "ipad" : "macwindow")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 24, height: 22)
        .foregroundStyle(.secondary)
        .help(String(localized: "Size"))
        .accessibilityLabel(String(localized: "Size"))
    }

    /// A size's item: checked while the page is at it; chosen, it goes there.
    private func chosen(_ on: Bool, _ go: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: { on }, set: { _ in if !on { go() } })
    }

    private static let iPhone = CGSize(width: 393, height: 852)
    private static let iPad = CGSize(width: 820, height: 1180)

    /// The card's page is what each button works on, focused or not.
    private func act(_ command: Command) {
        switch command {
        case .inspector: inspector(.inspector)
        case .console: inspector(.console)
        case .selectElement: inspector(.elementSelection)
        case .elementPicture: model.elementPicture(of: page)
        case .reloadOrigin: page.reloadFromOrigin()
        // On the card's own page, as the rest: the page beside's too.
        case .measure: page.toggleMeasuring()
        default: model.perform(command)
        }
    }

    private func inspector(_ part: WebDeveloperTool) {
        if !page.showDeveloperTool(part) {
            model.show(ActionToast(symbol: "hammer", text: WebInspector.unavailable))
        }
    }
}

/// The developer bar's tools: a 24 by 22 point square each, the symbol in
/// the words' second colour, lit under the pointer and held down as the
/// Mac's other icon buttons are; while on, a faint accent chip.
private struct BarToolStyle: ButtonStyle {
    let on: Bool

    func makeBody(configuration: Configuration) -> some View {
        BarToolBody(configuration: configuration, on: on)
    }
}

private struct BarToolBody: View {
    let configuration: ButtonStyleConfiguration
    let on: Bool
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        configuration.label
            .foregroundStyle(on ? Color.accentColor : Color.secondary)
            .frame(width: 24, height: 22)
            .background {
                if on { shape.fill(Color.accentColor.opacity(0.14)) }
            }
            .background(Highlight(hovering: hovering && !on, pressed: configuration.isPressed, shape: shape))
            .contentShape(shape)
            .onHover { hovering = $0 }
    }
}
