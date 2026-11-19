import PadCore
import SwiftUI
import UIKit

// Every colour is a pair, one for light and one for dark, resolved against
// the window's own appearance. The page is the ground, so everything the app
// draws stays grey and quiet around it.
enum Palette {
    static let ground = Color(uiColor: UI.ground)
    static let ink = Color(uiColor: UI.ink)
    static let muted = Color(uiColor: UI.muted)
    static let faint = Color(uiColor: UI.faint)
    static let hairline = Color(uiColor: UI.hairline)
    static let wash = Color(uiColor: UI.wash)
    static let hover = Color(uiColor: UI.hover)
    /// The tab overview's tray, and the cards on it: a light grey under
    /// white cards, as Safari's tabs are shown, so the glass of the dock
    /// and the buttons floating on it has something to show against.
    static let tray = Color(uiColor: UI.tray)
    static let card = Color(uiColor: UI.card)
    /// See-through dark, for what lies on the bars: they take the page's
    /// colour, and a grey of its own would sit on it as a patch, where a
    /// dark that lets the colour through reads as a deeper shade of it. A
    /// split's shared ground, and a tab under the pointer.
    static let shade = Color(uiColor: UI.shade)
    static let hoverShade = Color(uiColor: UI.hoverShade)
    /// The only two that aren't grey: a connection nobody can read on the
    /// way, and one anybody can.
    static let safe = Color(uiColor: UI.safe)
    static let unsafe = Color(uiColor: UI.unsafe)

    enum UI {
        static let ground = pair(1.0, 0.11)
        static let ink = pair(0.09, 0.93)
        // 4.5:1 on white, the least for text under 18 points (0.55 was 3.4:1).
        static let muted = pair(0.40, 0.66)
        static let faint = pair(0.83, 0.32)
        static let hairline = pair(0.91, 0.20)
        static let wash = pair(0.937, 0.175)
        static let hover = pair(0.965, 0.15)
        static let tray = pair(0.93, 0.06)
        static let card = pair(1.0, 0.16)
        /// A split's band between its panes and the handle on it: a light grey no page
        /// is, so two white pages read as two without the band pulling the eye.
        static let shade = dark(0.06, 0.24)
        static let hoverShade = dark(0.04, 0.14)
        static let safe = tint(light: (0.08, 0.50, 0.24), dark: (0.29, 0.87, 0.50))
        static let unsafe = tint(light: (0.71, 0.33, 0.04), dark: (0.98, 0.75, 0.14))

        private static func pair(_ light: CGFloat, _ dark: CGFloat) -> UIColor {
            UIColor { traits in
                UIColor(white: traits.userInterfaceStyle == .dark ? dark : light, alpha: 1)
            }
        }

        private static func dark(_ light: CGFloat, _ dark: CGFloat) -> UIColor {
            UIColor { traits in
                UIColor(white: 0, alpha: traits.userInterfaceStyle == .dark ? dark : light)
            }
        }

        private static func tint(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> UIColor {
            UIColor { traits in
                let c = traits.userInterfaceStyle == .dark ? dark : light
                return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
            }
        }
    }
}

enum Metrics {
    /// The row of tabs, and the address bar under it when it shows. Tall
    /// enough for 44-point touch cells.
    static let bar: CGFloat = 44
    static let corner: CGFloat = 8
    /// What a control on a bar draws, and the area that answers a touch or
    /// a click, which is never smaller than 44 points a side.
    static let control: CGFloat = 32
    static let target: CGFloat = 44
    /// The ring between the two, where a click answers but nothing is drawn.
    static let ring: CGFloat = (target - control) / 2
}

/// How big the address and what is in it are drawn: for a pointer, beside
/// the tabs, or for a thumb, on the phone bar, where the address has a row
/// of its own and a touch needs the 44 points Apple asks for.
enum BarScale {
    case pointer
    case thumb

    /// The address's height.
    var control: CGFloat { self == .thumb ? 44 : Metrics.control }
    /// The area that answers: the drawn height, never under 44.
    var target: CGFloat { max(control, Metrics.target) }
    var text: CGFloat { self == .thumb ? 16 : 13 }
    var icon: CGFloat { self == .thumb ? 18 : 16 }
    /// The star's, reload's and clear's width.
    var button: CGFloat { self == .thumb ? 44 : 30 }
    /// From the capsule's end to the icon's slot: a thumb-sized capsule's
    /// end curves further in.
    var lead: CGFloat { self == .thumb ? 8 : TabFace.lead }
}

private struct BarScaleKey: EnvironmentKey {
    static let defaultValue = BarScale.pointer
}

extension EnvironmentValues {
    var barScale: BarScale {
        get { self[BarScaleKey.self] }
        set { self[BarScaleKey.self] = newValue }
    }
}

// MARK: A space's colour

extension SpaceColor {
    /// The system's own shades, which turn lighter in the dark as Apple's
    /// colours do.
    var uiColor: UIColor {
        switch self {
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .teal: return .systemTeal
        case .indigo: return .systemIndigo
        case .gray: return .systemGray
        }
    }

    var color: Color {
        Color(uiColor: uiColor)
    }

    /// Words on the colour: dark on the light ones, white on the rest.
    var ink: Color {
        Color(uiColor: uiInk)
    }

    var uiInk: UIColor {
        self == .yellow ? UIColor.black.withAlphaComponent(0.85) : .white
    }

    var name: String {
        BrowserText.localized(rawValue.capitalized)
    }
}

// MARK: The site's colour (PadCore's SiteColor) in UIKit's terms.

extension SiteColor {
    /// A page's theme-color. Nil when it is mostly see-through, which says
    /// nothing about the page.
    init?(_ color: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a), a >= 0.5 else { return nil }
        // Wide-gamut colours come back outside 0...1.
        self.init(red: Double(min(max(r, 0), 1)), green: Double(min(max(g, 0), 1)), blue: Double(min(max(b, 0), 1)))
    }

    /// The mean colour of a picture of the page's top edge.
    init?(picture: UIImage) {
        guard let image = picture.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = 16
        var bytes = [UInt8](repeating: 0, count: width * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: 1))
            return true
        }
        guard drawn, let color = SiteColor.average(rgba: bytes) else { return nil }
        self = color
    }

    var uiColor: UIColor {
        UIColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: 1)
    }
}

// MARK: Liquid Glass, where the system has it

/// Which of the system's two glasses: regular for what you act on now, clear
/// for what sits beside it (the other tabs).
enum GlassKind {
    case regular
    case clear
}

extension View {
    /// Liquid Glass in `shape` on iPadOS 26 and later, tinted with `tint`
    /// when there is one; the flat `fallback` fill (or the tint) before, as
    /// the bars always looked.
    ///
    /// `reacting`: the glass itself answers a press, for a control that is
    /// all glass (a round button). Glass holding controls of its own (the
    /// address with its star and reload) must not: it takes the touch, and
    /// the controls inside never hear it.
    @ViewBuilder
    func liquidGlass<S: Shape>(_ kind: GlassKind = .regular, tint: Color? = nil, reacting: Bool = true, in shape: S,
                               otherwise fallback: Color) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect((kind == .regular ? Glass.regular : Glass.clear).tint(tint).interactive(reacting), in: shape)
        } else {
            background(tint ?? fallback, in: shape)
        }
    }

    /// The surface of what floats over the page with rows of its own: the
    /// command bar, and the rows over a phone's bar. Liquid Glass on iOS and
    /// iPadOS 26 and later, as the bars are; before, the system's blurred
    /// material with a hairline and a shadow. It never answers a press
    /// itself: the rows inside take the touches (liquidGlass, `reacting`).
    ///
    /// `tint` is the caller's: the space's colour, faint, for the iPad's
    /// command bar, as the Mac's has it, so it reads as the browser's and
    /// not as more of the page under it; none for the rows over a phone's
    /// bar, which take the colour of what they lie over, as the bar does
    /// while an address is typed. How clear the glass is otherwise is left
    /// to the system, which has the person's own Liquid Glass setting (and
    /// Reduce Transparency).
    ///
    /// `frosted` blurs what is under it more than the glass alone does, for
    /// rows of words over a busy page (the command bar's).
    @ViewBuilder
    func floatingGlass(cornerRadius: CGFloat, tint: Color?, frosted: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            // Clipped first: rows scrolled to an end would show past the corners.
            clipShape(shape)
                .background { if frosted { shape.fill(.ultraThinMaterial) } }
                .glassEffect(.regular.tint(tint), in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.22), radius: 36, y: 14)
        }
    }
}

/// The motion of everything on the bars: a spring with no bounce, which
/// starts from wherever the last one left off when interrupted.
extension Animation {
    static let bar = Animation.spring(duration: 0.3, bounce: 0)
}

/// A press that shows: the control gives a little, to 0.96, while held.
/// Quick going down, so a short tap shows it at all; back up as the bars move.
struct PressScale: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.7 : 1)
            .animation(reduceMotion ? .easeOut(duration: 0.15) : configuration.isPressed ? .spring(duration: 0.12, bounce: 0) : .bar, value: configuration.isPressed)
    }
}

// MARK: A site's icon

/// A site's icon as SiteIcons has it, or its first letter on the space's
/// colour until it does. No outline: a site's icon already has its own
/// shape, and a second edge around it reads as a frame.
struct SiteIconView: View {
    let url: URL?
    var size: CGFloat = 16
    @ObservedObject private var icons = SiteIcons.shared
    /// A drawn icon with a dark look of its own shows it on a dark screen.
    @Environment(\.colorScheme) private var scheme
    @Environment(\.spaceColor) private var space

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        let lightGround = icons.needsLightGround(url, dark: scheme == .dark)
        Group {
            if let image = icons.image(for: url, dark: scheme == .dark) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    // A dark shape on clear, on a dark screen: on a light ground, as Safari shows it.
                    .padding(lightGround ? size * 0.14 : 0)
                    .background { if lightGround { Color.white.opacity(0.92) } }
            } else {
                ZStack {
                    space.color
                    Text(letter)
                        .font(.system(size: size * 0.56, weight: .semibold, design: .rounded))
                        .foregroundStyle(space.ink)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .accessibilityHidden(true)
    }

    private var host: String {
        guard let host = url?.host() else { return "" }
        return Destination.registrable(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
    }

    private var letter: String {
        host.first.map { String($0).uppercased() } ?? "•"
    }
}
