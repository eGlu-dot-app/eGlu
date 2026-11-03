import Foundation

/// The light a site's icon gives off on its pinned tile: its own colours,
/// where they are, spread soft past its edges (Instagram's yellow at its
/// foot and purple at its top, Hacker News's orange all round).
///
/// Only what has colour gives light: an icon's white or black ground and
/// its grey parts give none, so Google's G glows in its four colours and
/// not in the white round it. An icon of no colour at all (GitHub's black,
/// Notion's black and white) has none of its own; the tile then glows in
/// the space's colour (PinnedIcon).
///
/// The colours are spread in OKLCh, by lightness, chroma and hue apart:
/// spread as red, green and blue, two colours meet in a duller one than
/// either (blue and yellow in grey), the dull spot between them. Here,
/// where they meet the hue turns from one to the other and the chroma is
/// what theirs was, much as CSS's gradients in OKLCh go.
public enum IconGlow {
    public struct Light: Sendable {
        /// `side` by `side` pixels, premultiplied RGBA in sRGB: the icon's
        /// place in its middle and room round it for the light to spread.
        public let side: Int
        public let pixels: [UInt8]
        /// The light as one colour, for glass tinted with it: as light as
        /// the light is, and greyer the further apart its hues are (Google's
        /// four, all but grey; Instagram's, a muted pink).
        public let tint: SiteColor
        /// Its strongest colour (core), for the core of the tile on screen's
        /// light, which stands out as one colour where the tint goes grey.
        public let core: SiteColor
    }

    /// The light of an icon `side` pixels a side (premultiplied RGBA in
    /// sRGB, rows from the top); nil for an icon of no colour.
    public static func light(of icon: [UInt8], side: Int) -> Light? {
        guard side > 0, icon.count >= side * side * 4 else { return nil }
        // Room round the icon for the light to spread into: a third of it each side.
        let pad = max(1, side / 3)
        let out = side + pad * 2
        // Each pixel's share of the light, and its lightness, chroma and hue
        // as a vector (OKLab's a and b) times that share, to be spread alike.
        var weight = [Double](repeating: 0, count: out * out)
        var light = weight, chroma = weight, a = weight, b = weight
        var covered = 0.0
        var lit = 0.0
        for y in 0..<side {
            for x in 0..<side {
                let i = (y * side + x) * 4
                let alpha = Double(icon[i + 3]) / 255
                guard alpha > 0.02 else { continue }
                covered += alpha
                // Premultiplied: divided back out.
                let lab = oklab(min(Double(icon[i]) / 255 / alpha, 1), min(Double(icon[i + 1]) / 255 / alpha, 1),
                                min(Double(icon[i + 2]) / 255 / alpha, 1))
                let c = (lab.a * lab.a + lab.b * lab.b).squareRoot()
                // None from greys, all from a colour as strong as a muted brand's.
                let share = alpha * smoothstep(0.035, 0.11, c)
                guard share > 0 else { continue }
                lit += share
                let o = (y + pad) * out + x + pad
                weight[o] = share
                light[o] = share * lab.l
                chroma[o] = share * c
                a[o] = share * lab.a
                b[o] = share * lab.b
            }
        }
        // Less than an eighth of it in colour: the icon has none to give.
        guard covered > 0, lit / covered >= 0.12 else { return nil }

        let sigma = Double(side) * 0.17
        weight = blur(weight, side: out, sigma: sigma)
        light = blur(light, side: out, sigma: sigma)
        chroma = blur(chroma, side: out, sigma: sigma)
        a = blur(a, side: out, sigma: sigma)
        b = blur(b, side: out, sigma: sigma)
        let peak = weight.max() ?? 0
        guard peak > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: out * out * 4)
        for o in 0..<(out * out) where weight[o] > peak * 0.002 {
            let w = weight[o]
            // Bright enough to read as light, never so bright that it is white.
            let l = min(max(light[o] / w, 0.6), 0.84)
            let mean = chroma[o] / w
            let length = (a[o] * a[o] + b[o] * b[o]).squareRoot()
            // How far the hues agree here: all one, 1; opposite ones evenly, 0.
            // Where they disagree the chroma gives a little, not all of it.
            let agree = chroma[o] > 0 ? min(length / chroma[o], 1) : 0
            let c = mean * (0.75 + 0.25 * agree)
            let hue = atan2(b[o], a[o])
            let (red, green, blue) = srgb(l: l, c: c, hue: hue)
            // Fuller than the spread alone, so the light reaches the tile's edges.
            let alpha = Foundation.pow(min(w / peak, 1), 0.75)
            let p = o * 4
            pixels[p] = UInt8((red * alpha * 255).rounded())
            pixels[p + 1] = UInt8((green * alpha * 255).rounded())
            pixels[p + 2] = UInt8((blue * alpha * 255).rounded())
            pixels[p + 3] = UInt8((alpha * 255).rounded())
        }
        return Light(side: out, pixels: pixels, tint: tint(of: icon, side: side), core: core(of: icon, side: side))
    }

    /// The icon's strongest colour: its coloured pixels within a twelfth of
    /// the circle of the hue most of its colour is in, their lightness raised
    /// as the light's is and their chroma kept. Google's blue, not the grey
    /// its four colours make as one; Instagram's pink; Hacker News's orange,
    /// as its tint is.
    private static func core(of icon: [UInt8], side: Int) -> SiteColor {
        let count = 24
        var bins = [Double](repeating: 0, count: count)
        var pixels: [(w: Double, l: Double, c: Double, a: Double, b: Double, h: Double)] = []
        for i in stride(from: 0, to: side * side * 4, by: 4) {
            let alpha = Double(icon[i + 3]) / 255
            guard alpha > 0.02 else { continue }
            let lab = oklab(min(Double(icon[i]) / 255 / alpha, 1), min(Double(icon[i + 1]) / 255 / alpha, 1),
                            min(Double(icon[i + 2]) / 255 / alpha, 1))
            let c = (lab.a * lab.a + lab.b * lab.b).squareRoot()
            let w = alpha * smoothstep(0.035, 0.11, c)
            guard w > 0 else { continue }
            let h = atan2(lab.b, lab.a)
            bins[min(count - 1, Int((h + .pi) / (2 * .pi) * Double(count)))] += w
            pixels.append((w, lab.l, c, lab.a, lab.b, h))
        }
        guard !pixels.isEmpty else { return SiteColor(red: 0.5, green: 0.5, blue: 0.5) }
        // Each bin with its two neighbours, so a hue split across two bins counts whole.
        let near = (0..<count).map { bins[($0 + count - 1) % count] + bins[$0] + bins[($0 + 1) % count] }
        let best = near.indices.max { near[$0] < near[$1] } ?? 0
        let centre = (Double(best) + 0.5) / Double(count) * 2 * .pi - .pi
        var share = 0.0, light = 0.0, chroma = 0.0, a = 0.0, b = 0.0
        for pixel in pixels {
            var apart = abs(pixel.h - centre)
            if apart > .pi { apart = 2 * .pi - apart }
            guard apart <= .pi / 6 else { continue }
            share += pixel.w
            light += pixel.w * pixel.l
            chroma += pixel.w * pixel.c
            a += pixel.w * pixel.a
            b += pixel.w * pixel.b
        }
        guard share > 0 else { return SiteColor(red: 0.5, green: 0.5, blue: 0.5) }
        let (red, green, blue) = srgb(l: min(max(light / share, 0.6), 0.84), c: chroma / share, hue: atan2(b, a))
        return SiteColor(red: red, green: green, blue: blue)
    }

    /// The icon's colour as one: its coloured pixels' lightness, raised as
    /// the light's is, and the hue they lean to; their chroma whole where
    /// two thirds of it is left in the mean of their hues, and less, much
    /// faster than the mean has less, below that.
    private static func tint(of icon: [UInt8], side: Int) -> SiteColor {
        var share = 0.0, light = 0.0, chroma = 0.0, a = 0.0, b = 0.0
        for i in stride(from: 0, to: side * side * 4, by: 4) {
            let alpha = Double(icon[i + 3]) / 255
            guard alpha > 0.02 else { continue }
            let lab = oklab(min(Double(icon[i]) / 255 / alpha, 1), min(Double(icon[i + 1]) / 255 / alpha, 1),
                            min(Double(icon[i + 2]) / 255 / alpha, 1))
            let c = (lab.a * lab.a + lab.b * lab.b).squareRoot()
            let w = alpha * smoothstep(0.035, 0.11, c)
            share += w
            light += w * lab.l
            chroma += w * c
            a += w * lab.a
            b += w * lab.b
        }
        guard share > 0 else { return SiteColor(red: 0.5, green: 0.5, blue: 0.5) }
        let agree = chroma > 0 ? min((a * a + b * b).squareRoot() / chroma * 1.5, 1) : 0
        let (red, green, blue) = srgb(l: min(max(light / share, 0.6), 0.84), c: chroma / share * agree * agree,
                                      hue: atan2(b, a))
        return SiteColor(red: red, green: green, blue: blue)
    }

    // MARK: Colour

    /// sRGB as OKLab (Björn Ottosson's).
    static func oklab(_ red: Double, _ green: Double, _ blue: Double) -> (l: Double, a: Double, b: Double) {
        let (r, g, b) = (linear(red), linear(green), linear(blue))
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// OKLCh as sRGB, its chroma lowered as far as it must be to fit,
    /// keeping its lightness and hue.
    static func srgb(l: Double, c: Double, hue: Double) -> (Double, Double, Double) {
        func linearRGB(_ c: Double) -> (Double, Double, Double) {
            let (a, b) = (c * cos(hue), c * sin(hue))
            let l_ = l + 0.3963377774 * a + 0.2158037573 * b
            let m_ = l - 0.1055613458 * a - 0.0638541728 * b
            let s_ = l - 0.0894841775 * a - 1.2914855480 * b
            let (lc, mc, sc) = (l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_)
            return (4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc,
                    -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc,
                    -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc)
        }
        func fits(_ rgb: (Double, Double, Double)) -> Bool {
            [rgb.0, rgb.1, rgb.2].allSatisfy { $0 >= -0.0001 && $0 <= 1.0001 }
        }
        var rgb = linearRGB(c)
        if !fits(rgb) {
            var (low, high) = (0.0, c)
            for _ in 0..<14 {
                let mid = (low + high) / 2
                if fits(linearRGB(mid)) { low = mid } else { high = mid }
            }
            rgb = linearRGB(low)
        }
        return (gamma(rgb.0), gamma(rgb.1), gamma(rgb.2))
    }

    private static func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : Foundation.pow((c + 0.055) / 1.055, 2.4)
    }

    private static func gamma(_ c: Double) -> Double {
        let c = min(max(c, 0), 1)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * Foundation.pow(c, 1 / 2.4) - 0.055
    }

    private static func smoothstep(_ from: Double, _ to: Double, _ x: Double) -> Double {
        let t = min(max((x - from) / (to - from), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// A Gaussian blur of `field`, `side` by `side`, across and then down.
    private static func blur(_ field: [Double], side: Int, sigma: Double) -> [Double] {
        let radius = max(1, Int((sigma * 3).rounded(.up)))
        var kernel = (-radius...radius).map { Foundation.exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        var across = [Double](repeating: 0, count: field.count)
        for y in 0..<side {
            for x in 0..<side {
                var sum = 0.0
                for k in -radius...radius {
                    let xx = x + k
                    guard xx >= 0, xx < side else { continue }
                    sum += field[y * side + xx] * kernel[k + radius]
                }
                across[y * side + x] = sum
            }
        }
        var down = [Double](repeating: 0, count: field.count)
        for y in 0..<side {
            for x in 0..<side {
                var sum = 0.0
                for k in -radius...radius {
                    let yy = y + k
                    guard yy >= 0, yy < side else { continue }
                    sum += across[yy * side + x] * kernel[k + radius]
                }
                down[y * side + x] = sum
            }
        }
        return down
    }
}
