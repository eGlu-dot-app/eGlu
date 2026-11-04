import PadCore
import SwiftUI
#if os(macOS)
import AppKit
/// A colour as each platform has one.
typealias TintColor = NSColor
#else
import UIKit
typealias TintColor = UIColor
#endif

// A pinned tab's look, the iPad's and the Mac's alike: how its icon is
// read (IconTint), drawn on its tile (PinnedIcon), the soft plate
// of colour under it (Plate), the light under the pointer (PointerGlow) and
// the rows the tiles stand in (PinnedRows).

extension SiteImage {
    /// The picture's pixels, for reading.
    var cgPicture: CGImage? {
        #if os(macOS)
        cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        cgImage
        #endif
    }

    /// A picture of pixels, one to a point.
    static func made(_ picture: CGImage) -> SiteImage {
        #if os(macOS)
        NSImage(cgImage: picture, size: NSSize(width: picture.width, height: picture.height))
        #else
        UIImage(cgImage: picture)
        #endif
    }
}

extension TintColor {
    static func srgb(_ red: Double, _ green: Double, _ blue: Double) -> TintColor {
        #if os(macOS)
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        #else
        UIColor(red: red, green: green, blue: blue, alpha: 1)
        #endif
    }

    /// Red, green and blue in sRGB, 0 to 1.
    var srgbComponents: (red: Double, green: Double, blue: Double) {
        #if os(macOS)
        let rgb = usingColorSpace(.sRGB) ?? self
        return (Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent))
        #else
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (Double(red), Double(green), Double(blue))
        #endif
    }
}

extension TintColor {
    /// The colour as it is drawn in the light or the dark (a system colour
    /// is lighter in the dark), in sRGB.
    func site(in scheme: ColorScheme) -> SiteColor {
        #if os(macOS)
        var rgb = srgbComponents
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance { rgb = self.srgbComponents }
        #else
        let rgb = resolvedColor(with: UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)).srgbComponents
        #endif
        return SiteColor(red: min(max(rgb.red, 0), 1), green: min(max(rgb.green, 0), 1), blue: min(max(rgb.blue, 0), 1))
    }
}

extension SpaceColor {
    /// The space's colour as each platform has one.
    var tint: TintColor {
        #if os(macOS)
        nsColor
        #else
        uiColor
        #endif
    }
}

extension Color {
    init(site colour: SiteColor) {
        self.init(.sRGB, red: colour.red, green: colour.green, blue: colour.blue)
    }

    init(tint: TintColor) {
        #if os(macOS)
        self.init(nsColor: tint)
        #else
        self.init(uiColor: tint)
        #endif
    }
}

extension Image {
    init(site: SiteImage) {
        #if os(macOS)
        self.init(nsImage: site)
        #else
        self.init(uiImage: site)
        #endif
    }
}

/// The colour of the space a window shows, for what is drawn in it: a
/// site's letter, until its icon comes, is on it (SiteIconView). The Mac's
/// window sets it in SwiftUI; the iPad's and iPhone's as a trait
/// (SpaceColorTrait), which SwiftUI inside them reads as this.
struct SpaceColorKey: EnvironmentKey {
    static let defaultValue = SpaceColor.blue
}

extension EnvironmentValues {
    var spaceColor: SpaceColor {
        get { self[SpaceColorKey.self] }
        set { self[SpaceColorKey.self] = newValue }
    }
}

#if !os(macOS)
struct SpaceColorTrait: UITraitDefinition {
    static let defaultValue = SpaceColor.blue
}

extension UITraitCollection {
    var spaceColor: SpaceColor { self[SpaceColorTrait.self] }
}

extension UIMutableTraits {
    var spaceColor: SpaceColor {
        get { self[SpaceColorTrait.self] }
        set { self[SpaceColorTrait.self] = newValue }
    }
}

extension SpaceColorKey: UITraitBridgedEnvironmentKey {
    static func read(from traitCollection: UITraitCollection) -> SpaceColor {
        traitCollection.spaceColor
    }

    static func write(to mutableTraits: inout UIMutableTraits, value: SpaceColor) {
        mutableTraits.spaceColor = value
    }
}
#endif

/// What a site's icon is made of, for its pinned tile: the colour
/// of its own ground (Figma's black, Notion's white, Hacker News's orange),
/// read along the edge of what is drawn of it, the median of its pixels
/// there, for the mark that stands on it; and the light its colours give
/// off (glow), for the tile's glow and glass. An icon that is a shape on a
/// clear ground (Apple's, WebKit's) has no ground of its own. A site with
/// no icon yet has its letter's.
@MainActor
enum IconTint {
    /// By site, for icons that have arrived: each is read once, and again
    /// when the site's icon is another picture (one chosen again, SiteIcons).
    private static var known: [String: Read<TintColor?>] = [:]
    private static var marks: [String: Read<SiteImage?>] = [:]
    private static var lights: [String: Read<Glow?>] = [:]
    private static var looks: [String: Read<Look>] = [:]
    private static var trims: [String: Read<SiteImage?>] = [:]
    private static var extents: [ObjectIdentifier: Read<IconOptics.Extent?>] = [:]

    /// How a pinned tile shows a site's icon (PinnedIcon).
    enum Look: Equatable {
        /// It fills a square of its own (Figma's app icon, Notion's,
        /// Hacker News's). Its ground, where its edge is all one colour, is
        /// left out and its mark stands on the ground's light, which tints
        /// its tile on screen; with no one ground it is drawn whole.
        case own(ground: TintColor?)
        /// A badge: a shape on clear whose outline is all one colour, a
        /// disc or a lozenge (Pinterest's red, Discord's, Apple's white,
        /// Spotify's green), that stands out on the glass: with no square.
        /// Its colour lights the tile, and what it holds stands on it: the
        /// badge's inside without the colour, or, all one colour, the badge
        /// itself in white or black, whichever stands out on that colour more.
        case badge(colour: TintColor, solid: Bool)
        /// Any other shape on clear: a cluster of colours with nothing round
        /// it (Figma's logo, Slack's), or one lost on the glass in the light
        /// or the dark (GitHub's dark disc). Drawn as the shape alone: in
        /// the words' colour on the space's where it is all one colour, in
        /// its own on their light where it has several.
        case shape(oneColour: Bool)
    }

    /// The site's icon cut to what it draws: the clear space a site leaves
    /// round its icon, more for some than for others, goes, so that icons
    /// are sized by what is seen of them (PinnedIcon).
    static func trimmed(for url: URL?) -> SiteImage? {
        guard let key = IconKey.of(url), let image = SiteIcons.shared.image(for: url) else { return nil }
        if let read = trims[key], read.picture === image { return read.value }
        var cut: SiteImage? = image
        if let picture = image.cgPicture {
            let width = picture.width, height = picture.height
            // The bitmap's rows run from its top, as CGImage's cropping counts them.
            if let bytes = pixels(of: picture, width: width, height: height, interpolation: .default),
               let box = opaqueBounds(in: bytes, width: width, height: height, alphaAtLeast: 26.0 / 255),
               box.maxX - box.minX + 1 < width || box.maxY - box.minY + 1 < height,
               let piece = picture.cropping(to: CGRect(x: box.minX, y: box.minY,
                                                       width: box.maxX - box.minX + 1, height: box.maxY - box.minY + 1)) {
                cut = SiteImage.made(piece)
            }
        }
        trims[key] = Read(picture: image, value: cut)
        return cut
    }

    /// How the site's icon is shown on a pinned tile; nil until it has one.
    static func look(for url: URL?) -> Look? {
        guard let key = IconKey.of(url), let image = SiteIcons.shared.image(for: url) else { return nil }
        if let read = looks[key], read.picture === image { return read.value }
        let read: Look
        if let shape = shape(of: image) {
            read = shape
        } else {
            _ = color(for: url)
            read = .own(ground: known[key]?.value ?? nil)
        }
        looks[key] = Read(picture: image, value: read)
        return read
    }

    /// A shape on clear: under half the edge of the box round what is solid
    /// is itself solid (a square with clear space round it is still a
    /// square); nil for an icon that fills its square.
    ///
    /// A badge where seven in ten of the pixels along its outline are near
    /// their median colour, and its most standing-out part (its 5% that
    /// stand out most) is seen on both the light glass and the dark: 0.15 or
    /// more apart in OKLab, where hue and how strong a colour is count as
    /// well as lightness. By lightness alone Spotify's green on the light
    /// glass (1.4 to 1) is as lost as GitHub's dark disc on the dark (1.3 to
    /// 1), which it plainly isn't; in OKLab the green is 0.27 away and the
    /// dark disc 0.07. What would be lost is a shape, not a badge.
    /// Its colours, all one or several, are within a tenth of the way to
    /// white of their average on every channel or not.
    private static func shape(of image: SiteImage) -> Look? {
        let side = 48
        guard let bytes = pixels(of: image, side: side) else { return nil }
        func alpha(_ x: Int, _ y: Int) -> Double { Double(bytes[(y * side + x) * 4 + 3]) / 255 }
        guard let (minX, minY, maxX, maxY) = opaqueBounds(in: bytes, width: side, height: side, alphaAtLeast: 0.6)
        else { return nil }
        var ring = 0, solid = 0
        for y in minY...maxY {
            for x in minX...maxX where x - minX < 2 || maxX - x < 2 || y - minY < 2 || maxY - y < 2 {
                ring += 1
                if alpha(x, y) >= 0.6 { solid += 1 }
            }
        }
        guard Double(solid) < Double(ring) * 0.5 else { return nil }
        func colour(_ x: Int, _ y: Int) -> [Double] {
            let i = (y * side + x) * 4, a = max(alpha(x, y), 0.01)
            // Premultiplied: divided back out.
            return (0..<3).map { Double(bytes[i + $0]) / 255 / a }
        }
        func opaque(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && x < side && y >= 0 && y < side && alpha(x, y) >= 0.6
        }
        var channels: [[Double]] = [[], [], []]
        var outline: [[Double]] = []
        var labs: [(Double, Double, Double)] = []
        for y in 0..<side {
            for x in 0..<side where alpha(x, y) >= 0.5 {
                let rgb = colour(x, y)
                for c in 0..<3 { channels[c].append(rgb[c]) }
                labs.append(oklab(rgb[0], rgb[1], rgb[2]))
                if opaque(x, y), !opaque(x + 1, y) || !opaque(x - 1, y) || !opaque(x, y + 1) || !opaque(x, y - 1) {
                    outline.append(rgb)
                }
            }
        }
        guard !channels[0].isEmpty else { return nil }
        let oneColour = channels.allSatisfy { values in
            let mean = values.reduce(0, +) / Double(values.count)
            return (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)).squareRoot() < 0.1
        }
        if !outline.isEmpty {
            let median = (0..<3).map { c in outline.map { $0[c] }.sorted()[outline.count / 2] }
            let near = outline.filter { abs($0[0] - median[0]) + abs($0[1] - median[1]) + abs($0[2] - median[2]) < 0.3 }.count
            // The glass of a pinned tile, as it is in the light and in the dark.
            func standsOut(on glass: (Double, Double, Double)) -> Bool {
                let apart = labs.map { lab -> Double in
                    let (l, a, b) = (lab.0 - glass.0, lab.1 - glass.1, lab.2 - glass.2)
                    return (l * l + a * a + b * b).squareRoot()
                }.sorted()
                return apart[min(apart.count - 1, Int(Double(apart.count) * 0.95))] >= 0.15
            }
            if Double(near) >= Double(outline.count) * 0.7,
               standsOut(on: oklab(0.88, 0.9, 0.94)), standsOut(on: oklab(0.2, 0.22, 0.27)) {
                return .badge(colour: TintColor.srgb(min(median[0], 1), min(median[1], 1), min(median[2], 1)),
                              solid: oneColour)
            }
        }
        return .shape(oneColour: oneColour)
    }

    /// How light a colour is to the eye, 0 for black to 1 for white (its
    /// relative luminance, as WCAG has it).
    static func luminance(of colour: TintColor) -> Double {
        let rgb = colour.srgbComponents
        return 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
    }

    /// White or near-black on `colour`, whichever stands out on it more.
    static func ink(on colour: TintColor) -> Color {
        let rgb = colour.srgbComponents
        let light = 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
        return 1.05 / (light + 0.05) >= (light + 0.05) / 0.05 ? .white : Color.black.opacity(0.85)
    }

    /// sRGB as OKLab (Björn Ottosson's): lightness, then green to red and
    /// blue to yellow, where equal distances look about equally far apart.
    private static func oklab(_ red: Double, _ green: Double, _ blue: Double) -> (Double, Double, Double) {
        let (r, g, b) = (linear(red), linear(green), linear(blue))
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// A channel of sRGB as light, for WCAG's luminance.
    private static func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// The icon drawn at `side` pixels a side, as premultiplied RGBA bytes.
    private static func pixels(of image: SiteImage, side: Int) -> [UInt8]? {
        guard let picture = image.cgPicture else { return nil }
        return pixels(of: picture, width: side, height: side, interpolation: .high)
    }

    /// The picture drawn at `width` by `height` pixels in sRGB, as
    /// premultiplied RGBA bytes, its rows from its top.
    private static func pixels(of picture: CGImage, width: Int, height: Int,
                               interpolation: CGInterpolationQuality) -> [UInt8]? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = interpolation
            context.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }

    /// The box round the pixels of `bytes` (premultiplied RGBA, `width` by
    /// `height`) whose alpha is `alphaAtLeast` or more; nil where none is.
    private static func opaqueBounds(in bytes: [UInt8], width: Int, height: Int,
                                     alphaAtLeast threshold: Double) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where Double(bytes[(y * width + x) * 4 + 3]) / 255 >= threshold {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return (minX, minY, maxX, maxY)
    }

    /// What was read of a site's icon, and the picture it was read from,
    /// held so that no other picture can come to be taken for it.
    private struct Read<Value> {
        let picture: SiteImage
        let value: Value
    }

    /// The icon without its ground (`ground`): what it draws, standing on
    /// clear. On a pinned tile, lit with that ground's colour (and on screen
    /// its glass tinted with it), the icon has no square left to show: only
    /// its mark, on its own colour. Nil for an icon with no ground of its own.
    static func mark(for url: URL?) -> SiteImage? {
        guard let key = IconKey.of(url), let image = trimmed(for: url) else { return nil }
        if let made = marks[key], made.picture === image { return made.value }
        // Read the ground first; an icon with none keeps its own look.
        _ = color(for: url)
        var ground = known[key]?.value ?? nil
        if case .badge(let colour, _)? = look(for: url) { ground = colour }
        let made = ground.flatMap { knockout(image, ground: $0) }
        marks[key] = Read(picture: image, value: made)
        return made
    }

    /// Pixels near the ground's colour go clear, smoothly, and those partly
    /// of it keep the colour that is left once the ground is taken out of
    /// them, so the mark's edge carries no fringe of the ground.
    private static func knockout(_ image: SiteImage, ground: TintColor) -> SiteImage? {
        let side = 96
        guard let picture = image.cgPicture,
              let space = CGColorSpace(name: CGColorSpace.sRGB),

              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data
        else { return nil }
        context.interpolationQuality = .high
        // Whole and centred, its proportions kept: a trimmed icon is near square, not always square.
        let scale = CGFloat(side) / max(image.size.width, image.size.height, 1)
        let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        context.draw(picture, in: CGRect(x: (CGFloat(side) - fitted.width) / 2, y: (CGFloat(side) - fitted.height) / 2,
                                         width: fitted.width, height: fitted.height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        let (gr, gg, gb) = ground.srgbComponents
        var drawn = 0
        for i in stride(from: 0, to: side * side * 4, by: 4) {
            let a = Double(bytes[i + 3]) / 255
            guard a > 0 else { continue }
            let r = Double(bytes[i]) / 255 / a, g = Double(bytes[i + 1]) / 255 / a, b = Double(bytes[i + 2]) / 255 / a
            let distance = ((r - gr) * (r - gr) + (g - gg) * (g - gg) + (b - gb) * (b - gb)).squareRoot()
            // Clear within 0.1 of the ground, whole from 0.4, eased between.
            let t = min(max((distance - 0.1) / 0.3, 0), 1)
            let kept = t * t * (3 - 2 * t)
            guard kept > 0 else {
                bytes[i] = 0; bytes[i + 1] = 0; bytes[i + 2] = 0; bytes[i + 3] = 0
                continue
            }
            func own(_ value: Double, _ under: Double) -> Double { min(max((value - under * (1 - kept)) / kept, 0), 1) }
            let alpha = a * kept
            if alpha > 0.5 { drawn += 1 }
            bytes[i] = UInt8(own(r, gr) * alpha * 255)
            bytes[i + 1] = UInt8(own(g, gg) * alpha * 255)
            bytes[i + 2] = UInt8(own(b, gb) * alpha * 255)
            bytes[i + 3] = UInt8(alpha * 255)
        }
        // An icon all of its ground (Mobbin's, one black shape) leaves next to
        // nothing: no mark, rather than an empty one.
        guard drawn >= side * side / 50, let made = context.makeImage() else { return nil }
        return SiteImage.made(made)
    }

    /// The light an icon gives off on its tile (IconGlow): its own
    /// colours where they are, spread soft past its edges.
    struct Glow {
        let picture: SiteImage
        /// How many times the icon's side the picture is across: the icon
        /// is in its middle, with room round it for the light to spread.
        let span: CGFloat
        /// Its colours as one, for the tile's glass: greyer the further apart their hues are.
        let tint: TintColor
        /// Its strongest colour, for the core of the tile on screen's light (CoreLight).
        let core: SiteColor
    }

    /// The site's icon's light; nil for an icon with no colour of its own
    /// (black, white, greys), whose tile is lit in the space's colour.
    static func glow(for url: URL?) -> Glow? {
        guard let key = IconKey.of(url), let image = trimmed(for: url) else { return nil }
        if let read = lights[key], read.picture === image { return read.value }
        let side = 24
        var made: Glow?
        if let bytes = fitted(image, side: side), let light = IconGlow.light(of: bytes, side: side),
           let picture = picture(of: light.pixels, side: light.side) {
            made = Glow(picture: picture, span: CGFloat(light.side) / CGFloat(side),
                        tint: TintColor.srgb(light.tint.red, light.tint.green, light.tint.blue), core: light.core)
        }
        lights[key] = Read(picture: image, value: made)
        return made
    }

    /// What a picture the tile draws (an icon trimmed, a mark) covers of the
    /// square it is fitted into, for its size beside the others (IconOptics).
    static func extent(of picture: SiteImage) -> IconOptics.Extent? {
        if let read = extents[ObjectIdentifier(picture)], read.picture === picture { return read.value }
        let side = 64
        let read = fitted(picture, side: side).flatMap { IconOptics.extent(of: $0, side: side) }
        extents[ObjectIdentifier(picture)] = Read(picture: picture, value: read)
        return read
    }

    /// The icon whole, centred, its proportions kept, at `side` pixels a side
    /// as premultiplied RGBA bytes, as the tile draws it (aspect fit).
    private static func fitted(_ image: SiteImage, side: Int) -> [UInt8]? {
        guard let picture = image.cgPicture, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .high
            let scale = CGFloat(side) / max(image.size.width, image.size.height, 1)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            context.draw(picture, in: CGRect(x: (CGFloat(side) - size.width) / 2, y: (CGFloat(side) - size.height) / 2,
                                             width: size.width, height: size.height))
            return true
        }
        return drawn ? bytes : nil
    }

    /// Premultiplied RGBA bytes in sRGB as a picture.
    private static func picture(of bytes: [UInt8], side: Int) -> SiteImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let made = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                                 space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return SiteImage.made(made)
    }

    static func color(for url: URL?) -> Color? {
        guard let key = IconKey.of(url), let image = SiteIcons.shared.image(for: url) else { return nil }
        if let read = known[key], read.picture === image { return read.value.map { Color(tint: $0) } }
        let read = ground(of: image)
        known[key] = Read(picture: image, value: read)
        return read.map { Color(tint: $0) }
    }

    /// The icon drawn at 48 pixels; the box round what of it is solid (an
    /// icon may come with clear space round it); and the two pixels along
    /// that box's inside. Half or more of them solid and mostly of one
    /// colour is a ground, and that colour is theirs.
    private static func ground(of image: SiteImage) -> TintColor? {
        let side = 48
        guard let bytes = pixels(of: image, side: side) else { return nil }
        func alpha(_ x: Int, _ y: Int) -> Double { Double(bytes[(y * side + x) * 4 + 3]) / 255 }
        guard let (minX, minY, maxX, maxY) = opaqueBounds(in: bytes, width: side, height: side, alphaAtLeast: 0.6)
        else { return nil }
        let band = 2
        var edge: [(r: Double, g: Double, b: Double)] = []
        var ring = 0
        for y in minY...maxY {
            for x in minX...maxX where x - minX < band || maxX - x < band || y - minY < band || maxY - y < band {
                ring += 1
                let a = alpha(x, y)
                guard a >= 0.6 else { continue }
                // Premultiplied: divided back out.
                let i = (y * side + x) * 4
                edge.append((Double(bytes[i]) / 255 / a, Double(bytes[i + 1]) / 255 / a, Double(bytes[i + 2]) / 255 / a))
            }
        }
        guard Double(edge.count) >= Double(ring) * 0.5 else { return nil }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        let r = median(edge.map(\.r)), g = median(edge.map(\.g)), b = median(edge.map(\.b))
        // A ground is one colour: most of the edge near the median, not a picture running off it.
        let near = edge.filter { abs($0.r - r) + abs($0.g - g) + abs($0.b - b) < 0.3 }.count
        guard Double(near) >= Double(edge.count) * 0.6 else { return nil }
        return TintColor.srgb(min(r, 1), min(g, 1), min(b, 1))
    }
}

/// The densest of a tile's light, under its mark: the icon's own
/// colours spread soft (IconTint.glow); or a soft plate of one colour (K3,
/// from a sheet of looks: 26 points, corners of 8, softened by 9), the
/// space's for an icon with none of its own. While the pointer is on the
/// tile it leans well toward it, out from under the mark, and spreads a
/// little, so the colour can be seen to follow; otherwise, under the tab on
/// screen, it drifts by a point or so, slowly, as light through glass
/// would. It holds still where Reduce Motion is on, and leans without
/// spreading.
struct Plate: View {
    enum Fill {
        case colour(Color)
        /// The icon's light, spread already: drawn `side` across as it is.
        case light(SiteImage)
    }

    let fill: Fill
    /// Toward the pointer; nil while it is elsewhere.
    let toward: CGSize?
    /// Its side, corner and softening: the sidebar's tile's, or smaller in the row along the top.
    var side: CGFloat = 26
    var corner: CGFloat = 8
    var blur: CGFloat = 9
    /// Under the tab on screen only: every tile drifting would redraw a
    /// sidebar of them thirty times a second for a point of movement.
    var drifts = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || toward != nil || !drifts)) { context in
            Group {
                switch fill {
                case .colour(let colour):
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(colour)
                        .frame(width: side, height: side)
                        .blur(radius: blur)
                case .light(let picture):
                    // Spread already; softened a little more, so no colour has an edge.
                    Image(site: picture)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: side, height: side)
                        .blur(radius: blur / 2)
                }
            }
            .scaleEffect(toward == nil || reduceMotion ? 1 : 1.25)
            .offset(toward ?? (drifts ? drift(at: context.date) : .zero))
        }
    }

    /// Where the plate leans: toward the pointer, three fifths of the way
    /// from the tile's middle, as far as `reach` either way; nil while the
    /// pointer is elsewhere.
    static func lean(toward pointer: CGPoint?, in size: CGSize, reach: CGSize) -> CGSize? {
        guard let pointer, size.width > 0 else { return nil }
        let x = (pointer.x - size.width / 2) * 0.6
        let y = (pointer.y - size.height / 2) * 0.6
        return CGSize(width: min(max(x, -reach.width), reach.width), height: min(max(y, -reach.height), reach.height))
    }

    /// A slow loop of about a point and a half across and one down, its
    /// two periods apart so it never quite repeats.
    private func drift(at date: Date) -> CGSize {
        guard !reduceMotion else { return .zero }
        let t = date.timeIntervalSinceReferenceDate
        return CGSize(width: cos(t * 2 * .pi / 7) * 1.5, height: sin(t * 2 * .pi / 5) * 1)
    }
}

/// The light of the tile on screen (PinnedIcon.fills), filling it: its
/// icon's colour at the core, the space's at the edge, blended between in
/// OKLCh (PadCore's OKLCh), so the hue turns from one to the other as
/// strong as both are, with no grey ring where they meet as there is
/// halfway in red, green and blue (asked for on 3 November 2026). The core
/// sits round the icon, and while its window is in front drifts on a slow
/// loop a fifth of the tile across and a sixth down, its two periods apart
/// so it never quite repeats: enough to be seen to move, as light behind
/// glass, where the old plate's point and a half went by unseen. Under the
/// pointer it leans toward it instead, and it holds still where Reduce
/// Motion is on.
struct CoreLight: View {
    let core: SiteColor
    let edge: SiteColor
    /// Toward the pointer, in points from the tile's middle; nil while it is elsewhere.
    let toward: CGSize?
    var drifts = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { box in
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || toward != nil || !drifts)) { context in
                RadialGradient(stops: stops, center: centre(in: box.size, at: context.date), startRadius: 0,
                               endRadius: (box.size.width * box.size.width + box.size.height * box.size.height).squareRoot() / 2 * 1.1)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Nine steps of the blend from the core outward, out to a little past
    /// the tile's corners: the core whole over the first third, well round
    /// the icon (asked for on 3 November 2026: "make the core bigger"), and
    /// the space's colour reaching the corners; fuller at the core than at
    /// the edge, so the glass still shows through there.
    private var stops: [Gradient.Stop] {
        let steps = OKLCh.blend(core, edge, count: 9)
        let (inner, outer) = scheme == .dark ? (0.8, 0.42) : (0.85, 0.5)
        return steps.enumerated().map { index, colour in
            let t = Double(index) / Double(steps.count - 1)
            return Gradient.Stop(color: Color(site: colour).opacity(inner + (outer - inner) * t), location: 0.36 + 0.64 * t)
        }
    }

    /// Where the core is, in the tile's fractions.
    private func centre(in size: CGSize, at date: Date) -> UnitPoint {
        guard size.width > 0, size.height > 0 else { return .center }
        if let toward {
            return UnitPoint(x: 0.5 + toward.width / size.width, y: 0.5 + toward.height / size.height)
        }
        guard drifts, !reduceMotion else { return .center }
        let t = date.timeIntervalSinceReferenceDate
        return UnitPoint(x: 0.5 + cos(t * 2 * .pi / 6.5) * 0.2, y: 0.5 + sin(t * 2 * .pi / 4.6) * 0.17)
    }
}

/// A pinned tile at rest, its tab neither on screen nor under the pointer,
/// on the Mac and the iPad alike: no glass and no light, its icon as it is
/// (PinnedIcon `lit` false), on a ground lighter than the sidebar's, in
/// white, edged faintly in the words' colour, so the one on screen, on
/// glass and lit, stands out among them.
enum PinnedRest {
    static func ground(_ scheme: ColorScheme) -> Color {
        Color.white.opacity(scheme == .dark ? 0.08 : 0.4)
    }

    static func line(_ scheme: ColorScheme) -> Color {
        Color.primary.opacity(scheme == .dark ? 0.16 : 0.1)
    }
}

/// A pinned tab's icon, in the sidebar's tile and the row's, the same in
/// every space and every look of the screen (IconTint.Look), and every icon
/// as large to the eye as the others: each is cut to what it draws first
/// (IconTint.trimmed), so the clear space a site leaves round it counts for
/// nothing, and then drawn so the outline round what is seen of it covers as
/// much as a square icon's rounded square (IconOptics): a disc a little
/// larger, a wide mark wider and shorter.
///
/// The icon lights its tile with its own colours, where they are
/// (IconTint.glow), leaning to the pointer, or, having none (black, white,
/// greys), with the space's; and the icon is what stands on that light: an
/// own icon's or a badge's mark without its ground (a badge of one colour,
/// itself in white or black); an icon of several colours and no one ground,
/// whole; a shape alone, in its own colours, or, all one colour, in the
/// words' colour on the space's.
///
/// The same on every tile, whether its tab is on screen, open behind or
/// closed, and in a window behind: drawn so for the tab on screen only and
/// whole on a square for the others, a tab's icon changed as it came on
/// screen. Which tab is on screen is said by its tile's tinted glass
/// (tileTint) and its light's slow drift; and, for an icon of no colour of
/// its own (Are.na's, GitHub's, ChatGPT's), by a deeper light under it with
/// the icon in white on it (`drawnWhite`), as nothing of its own would show.
/// The mark of a pinned tab or a bar bookmark that is open: a small dot, as
/// the iPhone's dock has under an open one's icon and the Mac's Dock under
/// an app that is running. It lies close to the icon it marks, closer than
/// to anything else, so it reads as the icon's: under a tile's icon (`under`),
/// or left of a row's. It comes and goes growing from half its size as it
/// fades, never from nothing.
struct OpenDot: View {
    let shown: Bool
    var size: CGFloat = 4

    /// From the icon's edge to the dot: the iPhone dock's 2 points, and a
    /// step more under a tile's larger icon.
    static func gap(for icon: CGFloat) -> CGFloat {
        icon >= 18 ? 3 : 2
    }

    /// How far below an icon's centre the dot's centre is, for an icon centred in its tile.
    static func under(icon: CGFloat, size: CGFloat = 4) -> CGFloat {
        icon / 2 + gap(for: icon) + size / 2
    }

    /// From a row's leading edge to the dot, for a row whose icon starts `lead` in.
    static func before(lead: CGFloat, icon: CGFloat = 16, size: CGFloat = 4) -> CGFloat {
        lead - gap(for: icon) - size
    }

    var body: some View {
        Circle()
            .fill(Color.primary.opacity(0.55))
            .frame(width: size, height: size)
            .scaleEffect(shown ? 1 : 0.5)
            .opacity(shown ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: shown)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct PinnedIcon: View {
    let url: URL?
    /// On screen, in a window in front: its light drifts.
    let open: Bool
    let colour: SpaceColor
    /// The room for its icon, which no icon goes past: a square icon is
    /// drawn five sixths of it across (`squareShare`), leaving the rest for
    /// a disc a tenth larger and a mark wider than it is tall (IconOptics).
    let size: CGFloat
    let lean: CGSize?
    var plate = PinnedIcon.tilePlate
    /// On its light, the mark alone where its ground goes; false for a tile
    /// neither on screen nor under the pointer (Mac and iPad), or a row of
    /// the Duo's pinned list neither on screen nor under the finger, which
    /// has no glow, and so shows the icon as it is (unlit).
    var lit = true
    /// Its tab is the one on screen, whether or not its window is in front;
    /// as `open` where not given.
    var current: Bool?
    /// On the tile on screen, the light fills the tile (CoreLight): the
    /// icon's colour at the core, the space's at the edge. False where the
    /// icon stands in a row of words (PinnedPanel's), which has its own.
    var fills = false
    @ObservedObject private var icons = SiteIcons.shared
    @Environment(\.colorScheme) private var scheme

    /// The plate under the mark on a sidebar's tile.
    static let tilePlate = (side: CGFloat(26), corner: CGFloat(8), blur: CGFloat(9))

    /// How much of `size` a square icon is drawn across: 15 points of the sidebar's 18.
    static let squareShare: CGFloat = 5.0 / 6

    /// The tile's glass on screen, tinted as its light is: with the icon's
    /// colours as one; with the deep light of an icon in white (`drawnWhite`);
    /// with the space's, fainter, for an icon of no colour drawn as it is,
    /// and, more, for a letter until the icon comes.
    static func tileTint(for url: URL?, colour: SpaceColor) -> Color? {
        guard let look = IconTint.look(for: url) else {
            // No icon yet: its letter's, which is on the space's colour (SiteIconView).
            return IconKey.of(url) == nil ? nil : colour.color.opacity(0.32)
        }
        if drawnWhite(look, url: url) { return colour.deep.opacity(0.3) }
        guard let glow = IconTint.glow(for: url) else { return colour.color.opacity(0.16) }
        return Color(tint: glow.tint).opacity(0.3)
    }

    /// An icon the tile on screen shows in white (dark on yellow) on a deep
    /// light of the space's colour: a shape of one colour, and an own icon
    /// or a badge with no colour of its own, whose mark or shape is drawn so.
    /// An icon of greys and no one ground stays as it is: in one colour its
    /// parts would run together.
    static func drawnWhite(_ look: IconTint.Look, url: URL?) -> Bool {
        switch look {
        case .shape(true): true
        case .own(_?), .badge: IconTint.glow(for: url) == nil
        case .shape(false), .own(nil): false
        }
    }

    /// The colour an icon brings of its own: an own icon's ground, a badge's.
    private static func own(_ look: IconTint.Look?) -> TintColor? {
        switch look {
        case .own(let ground?)?: ground
        case .badge(let colour, _)?: colour
        default: nil
        }
    }

    /// The icon's own colour is all but black on a light screen, or all but
    /// white on a dark one (Vercel's disc, Mobbin's mark): its mark alone
    /// would be lost there, so it stays whole.
    private static func far(_ look: IconTint.Look?, scheme: ColorScheme) -> Bool {
        guard let colour = own(look) else { return false }
        let light = IconTint.luminance(of: colour)
        return scheme == .dark ? light > 0.8 : light < 0.04
    }

    /// What is seen of the icon, by which it is sized, on its tile in any
    /// state alike: its mark where its ground is all but the tile's own
    /// (Notion's white); otherwise the icon cut to what it draws, a mark
    /// drawn in its place when its ground goes (Hacker News's Y).
    private func seen(_ look: IconTint.Look, _ trimmed: SiteImage) -> SiteImage {
        guard case .own(let ground?) = look, Self.sunk(ground, scheme: scheme) else { return trimmed }
        return IconTint.mark(for: url) ?? trimmed
    }

    /// The side of the square the icon is drawn in, every picture of it
    /// fitted into it alike: what is seen of it (`seen`) as large to the
    /// eye as a square icon `squareShare` of `size` across (IconOptics).
    private func square(of seen: SiteImage) -> CGFloat {
        let side = Double(size * Self.squareShare)
        return CGFloat(IconTint.extent(of: seen).map { IconOptics.square(for: $0, side: side) } ?? side).rounded()
    }

    var body: some View {
        if let look = IconTint.look(for: url), let trimmed = IconTint.trimmed(for: url) {
            let white = lit && (current ?? open) && Self.drawnWhite(look, url: url)
            let side = square(of: seen(look, trimmed))
            if !lit {
                unlit(look, trimmed, side: side)
                    .id(lit)
                    .transition(.opacity)
            } else {
                light(under: look, side: side, white: white)
                    .transition(.opacity)
                Group {
                    if white {
                        inWhite(look, trimmed, side: side)
                    } else {
                        onLight(look, trimmed, side: side)
                    }
                }
                .id(white)
                .transition(.opacity)
            }
        } else {
            // No icon yet: its letter, on the space's colour, as large as a square icon.
            SiteIconView(url: url, size: (size * Self.squareShare).rounded())
                .environment(\.spaceColor, colour)
                .transition(.opacity)
        }
    }

    /// On its light, what stands out on it.
    @ViewBuilder private func onLight(_ look: IconTint.Look, _ trimmed: SiteImage, side: CGFloat) -> some View {
        let far = Self.far(look, scheme: scheme)
        switch look {
        case .shape(true):
            ink.mask { picture(trimmed) }
                .frame(width: side, height: side)
        case .shape:
            picture(trimmed).frame(width: side, height: side)
        case .own(nil):
            // Colours of its own and no one ground to take away: whole, on its light.
            picture(trimmed)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: side * 0.225, style: .continuous))
        case .own(let own):
            if let mark = IconTint.mark(for: url) {
                // Over a faded plate, whole: its own colour is part of what it draws.
                picture(far ? trimmed : mark)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: far ? side * 0.225 : 0, style: .continuous))
            } else {
                // All of its own colour: its shape, in what stands out on its plate.
                inked(on: own, far: far).mask { picture(trimmed) }
                    .frame(width: side, height: side)
            }
        case .badge(let badge, let solid):
            if solid || IconTint.mark(for: url) == nil {
                inked(on: badge, far: far).mask { picture(trimmed) }
                    .frame(width: side, height: side)
            } else {
                picture(far ? trimmed : IconTint.mark(for: url) ?? trimmed).frame(width: side, height: side)
            }
        }
    }

    /// On the deep light of the tile on screen (`drawnWhite`), in the
    /// space's ink: what is seen of it on its tile at rest (`seen`), as
    /// large as it is there; where that is its ground, with its mark cut out
    /// of it, as GitHub's cat is out of its disc (Vercel's triangle out of
    /// its black one); where its ground is not seen, its mark (Notion's N).
    private func inWhite(_ look: IconTint.Look, _ trimmed: SiteImage, side: CGFloat) -> some View {
        let seen = seen(look, trimmed)
        let mark: SiteImage? = if case .shape = look { nil } else if seen === trimmed { IconTint.mark(for: url) } else { nil }
        return colour.ink.mask { picture(seen) }
            .frame(width: side, height: side)
            .overlay {
                if let mark { picture(mark).blendMode(.destinationOut) }
            }
            .compositingGroup()
    }

    /// With no light under it, the icon carries its own colours: whole, its
    /// ground and all, where its mark alone would be white on the tile; a
    /// shape of one colour in the words' colour; and a mark whose ground is
    /// nearly the tile's own (Mobbin's black in the dark) alone, so no square
    /// of nearly the same colour shows a rim round it.
    @ViewBuilder private func unlit(_ look: IconTint.Look, _ trimmed: SiteImage, side: CGFloat) -> some View {
        switch look {
        case .shape(true):
            // In the words' colour of where it stands, as the tile's line is.
            Color.primary.opacity(0.85).mask { picture(trimmed) }
                .frame(width: side, height: side)
        case .shape:
            picture(trimmed).frame(width: side, height: side)
        case .own(let own?) where IconTint.mark(for: url) != nil && Self.sunk(own, scheme: scheme):
            picture(IconTint.mark(for: url) ?? trimmed)
                .frame(width: side, height: side)
        case .own:
            picture(trimmed)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: side * 0.225, style: .continuous))
        case .badge:
            picture(trimmed).frame(width: side, height: side)
        }
    }

    /// A ground nearly the tile's own: all but black in the dark, all but white in the light.
    private static func sunk(_ ground: TintColor, scheme: ColorScheme) -> Bool {
        let light = IconTint.luminance(of: ground)
        return scheme == .dark ? light < 0.08 : light > 0.92
    }

    /// The light under the icon: its own colours, spread soft
    /// (IconTint.glow), or the space's for an icon of none; a firmer plate
    /// of the space's under a shape of one colour, for its ink to stand out
    /// on; and fuller and deeper again under an icon in white on the tile on
    /// screen (`drawnWhite`). On dark glass the light adds to it, as light
    /// does, rather than mixing with its grey into a duller colour where it
    /// thins out.
    @ViewBuilder private func light(under look: IconTint.Look, side: CGFloat, white: Bool) -> some View {
        let adds: BlendMode = scheme == .dark ? .plusLighter : .normal
        if fills, current ?? open {
            CoreLight(core: core(white: white), edge: colour.tint.site(in: scheme), toward: lean, drifts: open)
        } else if white {
            Plate(fill: .colour(colour.deep), toward: lean, side: (plate.side * 1.25).rounded(),
                  corner: (plate.corner * 1.3).rounded(), blur: plate.blur - 1, drifts: open)
        } else if case .shape(true) = look {
            Plate(fill: .colour(colour.color), toward: lean, side: plate.side + 4, corner: plate.corner + 1, blur: plate.blur - 1,
                  drifts: open)
                .opacity(0.85)
        } else if let glow = IconTint.glow(for: url) {
            // A little past the picture's own room, so the light reaches the tile's edges.
            Plate(fill: .light(glow.picture), toward: lean, side: (side * glow.span * 1.16).rounded(), drifts: open)
                .opacity(0.9)
                .blendMode(adds)
        } else {
            Plate(fill: .colour(colour.color), toward: lean, side: plate.side, corner: plate.corner, blur: plate.blur, drifts: open)
                .opacity(scheme == .dark ? 0.6 : 0.5)
                .blendMode(adds)
        }
    }

    /// The core of the tile on screen's light (CoreLight): the icon's
    /// strongest colour (IconTint.glow); for an icon of none, drawn in white, the
    /// space's colour deepened as under it now (SpaceColor.deep), so the
    /// white stands out on it; otherwise the space's own.
    private func core(white: Bool) -> SiteColor {
        if let glow = IconTint.glow(for: url) { return glow.core }
        let space = colour.tint.site(in: scheme)
        guard white, scheme == .light, colour != .yellow else { return space }
        return SiteColor(red: space.red * 0.7, green: space.green * 0.7, blue: space.blue * 0.7)
    }

    /// A picture whole, in its own colours, as large as its frame lets it be.
    private func picture(_ image: SiteImage) -> some View {
        Image(site: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .accessibilityHidden(true)
    }

    /// What a mark of one colour is drawn in on its plate: white or black,
    /// whichever stands out on the plate's colour; over a faded plate, the
    /// screen's own, which is all that is left behind it.
    private func inked(on colour: TintColor?, far: Bool) -> Color {
        guard !far, let colour else { return scheme == .dark ? .white : Color.black.opacity(0.85) }
        return IconTint.ink(on: colour)
    }

    /// A shape of one colour on the space's: white, or dark where white
    /// would stand out too little, on yellow, and on gray in the light,
    /// where the tile is lighter than the colour itself (3 to 1 at the
    /// least, as WCAG asks of what isn't text).
    private var ink: Color {
        colour == .gray && scheme == .light ? Color.black.opacity(0.85) : colour.ink
    }
}

extension SpaceColor {
    /// The light under an icon in white on its tile on screen
    /// (PinnedIcon.drawnWhite): the space's colour, and, in the light, a
    /// third of the way to black, so the white stands out on it (gray's 3 to
    /// 1 becomes 6). Yellow, whose ink is dark, stays as it is.
    var deep: Color {
        #if os(macOS)
        let base = nsColor
        return Color(nsColor: NSColor(name: nil) { appearance in
            var resolved = base
            appearance.performAsCurrentDrawingAppearance { resolved = base.usingColorSpace(.sRGB) ?? base }
            guard appearance.bestMatch(from: [.aqua, .darkAqua]) != .darkAqua, self != .yellow else { return resolved }
            let rgb = resolved.srgbComponents
            return .srgb(rgb.red * 0.7, rgb.green * 0.7, rgb.blue * 0.7)
        })
        #else
        let base = uiColor
        return Color(uiColor: UIColor { traits in
            let resolved = base.resolvedColor(with: traits)
            guard traits.userInterfaceStyle != .dark, self != .yellow else { return resolved }
            let rgb = resolved.srgbComponents
            return .srgb(rgb.red * 0.7, rgb.green * 0.7, rgb.blue * 0.7)
        })
        #endif
    }
}

/// A soft light while the pointer is on a pinned tile, on every tile,
/// whether or not its icon has a ground for a plate. It stands where the
/// icon's own light leans (Plate.lean), not at the pointer itself, so the
/// two are one light that follows the pointer, not a spot and a plate apart;
/// faint, and fading out slowly, as light through frosted glass.
struct PointerGlow: View {
    /// Where the icon's light leans from the tile's middle; nil while the pointer is elsewhere.
    let lean: CGSize?
    var radius: CGFloat = 44
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { box in
            if let lean {
                let peak = scheme == .dark ? 0.14 : 0.45
                RadialGradient(gradient: Gradient(stops: [
                                   .init(color: Color.white.opacity(peak), location: 0),
                                   .init(color: Color.white.opacity(peak * 0.35), location: 0.5),
                                   .init(color: Color.white.opacity(0), location: 1),
                               ]),
                               center: UnitPoint(x: 0.5 + lean.width / max(box.size.width, 1),
                                                 y: 0.5 + lean.height / max(box.size.height, 1)),
                               startRadius: 0, endRadius: radius)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    #if DEBUG
    /// Where a debug build puts the pointer on the open tile, in the tile's
    /// own fractions, for a picture of it: `-hoverPinned 0.8,0.3`.
    static let debugSpot: CGPoint? = {
        let parts = (UserDefaults.standard.string(forKey: "hoverPinned") ?? "").split(separator: ",").compactMap { Double($0) }
        return parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : nil
    }()
    #endif
}


/// The pinned tiles in rows across the sidebar's whole width, as Arc's
/// favourites are, every tile one width: as many columns as the rows need
/// when as many go to a row as fit `minimum` wide (five where four fit are
/// three columns, a row of three and a row of two), the columns sharing the
/// width, so a full row always reaches both edges.
struct PinnedRows: Layout {
    var minimum: CGFloat = 52
    let spacing: CGFloat

    /// How many columns `count` tiles stand in across `width`: the fewest
    /// rows they fit in, then the fewest columns that fill those rows.
    func columns(of count: Int, in width: CGFloat) -> Int {
        guard count > 0 else { return 1 }
        let fit = max(1, Int((width + spacing) / (minimum + spacing)))
        let rows = (count + fit - 1) / fit
        return (count + rows - 1) / rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (minimum + spacing) * CGFloat(subviews.count) - spacing
        let columns = columns(of: subviews.count, in: width)
        let rows = CGFloat((subviews.count + columns - 1) / columns)
        return CGSize(width: width, height: max(rows * height(of: subviews) + (rows - 1) * spacing, 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let height = height(of: subviews)
        let columns = columns(of: subviews.count, in: bounds.width)
        let width = (bounds.width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        for (index, subview) in subviews.enumerated() {
            let column = CGFloat(index % columns), row = CGFloat(index / columns)
            subview.place(at: CGPoint(x: bounds.minX + column * (width + spacing), y: bounds.minY + row * (height + spacing)),
                          proposal: ProposedViewSize(width: width, height: height))
        }
    }

    /// A tile's height, which is the same for every tile.
    private func height(of subviews: Subviews) -> CGFloat {
        subviews.first?.sizeThatFits(ProposedViewSize(width: minimum, height: nil)).height ?? 0
    }
}
