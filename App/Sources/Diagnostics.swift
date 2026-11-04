import PadCore
import SwiftUI
import WebKit

/// A small panel over the page (⌃⌥D) for checking the bridges on a real
/// iPad: what the page is told it runs in, what the trackpad and the keys
/// send it, whether WebKit sends wheel events of its own, and which tabs
/// are live. Nothing in it leaves the iPad.
struct DiagnosticsView: View {
    let page: () -> Page?
    /// The window's own view, for its measures (Diagnostics.lines(forWindow:)).
    let window: () -> UIView?
    let close: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Developer Diagnostics").font(.headline)
                    Spacer()
                    Button(action: close) {
                        Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Close Developer Diagnostics")
                }
                ForEach(Diagnostics.lines(for: page()) + Diagnostics.lines(forWindow: window()), id: \.self) { line in
                    Text(line)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Palette.ink)
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metrics.corner))
            .overlay(RoundedRectangle(cornerRadius: Metrics.corner).stroke(Palette.hairline))
        }
    }
}

@MainActor
enum Diagnostics {
    static func lines(for page: Page?) -> [String] {
        let pages = Session.shared.pages
        let tabs = "tabs live \(pages.live.count) · frozen or unopened \(max(0, pages.frozenCount))"
        guard let page else { return ["no page", tabs] }
        let view = page.view
        let scroll = view.scrollView
        let stats = page.stats
        let bridges = page.bridges
        let expected = Identity.macUserAgent(applicationName: Identity.applicationName(for: ProcessInfo.processInfo.operatingSystemVersion))
        let agent: String
        if page.isHandsOff {
            agent = "user agent: not read here (hands-off page)"
        } else if let seen = stats.userAgent {
            agent = seen == expected ? "user agent: Mac Safari, as sent" : "user agent: \(seen)"
        } else {
            agent = "user agent: not reported yet"
        }
        let mode = view.configuration.defaultWebpagePreferences.preferredContentMode == .desktop ? "desktop" : "mobile"
        return [
            "\(page.adapter.name)\(page.isHandsOff ? " · hands-off, nothing injected" : "") · \(mode) pages · \(page.isHeavy ? "heavy" : "light")",
            "zoom \(String(format: "%.2f", Double(scroll.zoomScale))) · WebKit scrolling \(scroll.isScrollEnabled ? "on" : "off") · its pinch \(scroll.pinchGestureRecognizer?.isEnabled == true ? "on" : "off")",
            agent,
            "pinch \(stats.pinchSteps) · ⌘ zoom \(stats.commandZoomSteps) · bridged \(stats.bridgedWheels) · stood aside \(stats.standAside)",
            "WebKit wheel events seen by the page \(stats.webKitWheels) · last: \(stats.lastOutcome.isEmpty ? "none" : stats.lastOutcome)",
            "wheel bridge \(bridges.wheel.rawValue) · keys to page: \(bridges.keys.isEmpty ? "none" : bridges.keys.map(\.rawValue).sorted().joined(separator: ", ")) · relayed \(stats.relayedKeys) · typing: \(page.editing ? "yes" : "no")",
            "\(tabs) · process ends \(stats.processEnds)",
            "cursor: \(bridges.cursors ? page.pointer?.cursorSummary ?? "the system's" : "the system's (pages' cursors off)")",
            "ad blocking: \(page.blocksContent ? "on here" : "off here") · \(ContentBlocker.shared.status)",
        ]
    }

    /// The hinge as last heard (Browser.showDiagnostics), on an iPhone Duo.
    static var hinge = "not heard"
    /// The strip the page runs under as last measured (Browser.stripCover), on an iPhone Duo.
    static var strip = "no strip measured"

    /// The window's measures, for laying out on the iPhone Duo (Docs/iPhoneDuoPlan.md,
    /// Phase 0): its size and size classes, the safe area, the side the vertical bar
    /// takes, the fold and the cameras, the hinge, and what the system allows here.
    static func lines(forWindow view: UIView?) -> [String] {
        guard let view, let window = view.window else { return [] }
        let traits = view.traitCollection
        let insets = view.safeAreaInsets
        let screen = window.windowScene?.screen.bounds.size ?? .zero
        let idiom = UIDevice.current.userInterfaceIdiom == .phone ? "phone" : "pad"
        var lines = [
            "window \(points(window.bounds.size)) · width \(name(traits.horizontalSizeClass)) · height \(name(traits.verticalSizeClass)) · \(idiom)",
            "safe area top \(points(insets.top)) left \(points(insets.left)) bottom \(points(insets.bottom)) right \(points(insets.right))",
            "screen \(points(screen)) · windows \(UIApplication.shared.supportsMultipleScenes ? "many" : "one") · main menu \(Menus.built ? "built" : "not built")",
        ]
        if #available(iOS 27.1, *) {
            let edge = switch traits.verticalBarEdge {
            case .leading: "leading"
            case .trailing: "trailing"
            default: "none"
            }
            lines.append("vertical bar \(edge) · hinge \(hinge)")
            lines.append(strip)
            for (kind, label) in [(UIView.ReservedRegion.Kind.division, "fold"), (.occlusion, "occlusion")] {
                for region in view.reservedRegions(kind: kind, options: .includeInactive) {
                    let frame = region.frame, margins = region.margins
                    lines.append("\(label)\(region.isActive ? "" : " (inactive)") at \(points(frame.minX)), \(points(frame.minY)) "
                        + "size \(points(frame.size)) · margins \(points(margins.top)) \(points(margins.left)) \(points(margins.bottom)) \(points(margins.right))")
                }
            }
        }
        return lines
    }

    private static func name(_ sizeClass: UIUserInterfaceSizeClass) -> String {
        switch sizeClass {
        case .compact: "compact"
        case .regular: "regular"
        default: "unspecified"
        }
    }

    private static func points(_ value: CGFloat) -> String {
        value.rounded() == value ? "\(Int(value))" : String(format: "%.1f", Double(value))
    }

    private static func points(_ size: CGSize) -> String {
        "\(points(size.width)) × \(points(size.height))"
    }
}
