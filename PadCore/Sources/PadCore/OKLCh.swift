import Foundation

/// Colours blended in OKLCh, by lightness, chroma and hue apart, as CSS's
/// gradients `in oklch` are: the hue turns from one colour's to the other's
/// the shorter way round, and the chroma goes straight from one to the
/// other. Blended as red, green and blue, two colours meet in a duller one
/// than either (orange and blue in grey); in OKLab they meet in a greyer
/// one still, straight through the middle; in OKLCh they stay as strong
/// as they are all the way, which is what a pinned tile's light, its icon's
/// colour at the core and the space's at the edge, is drawn with.
public enum OKLCh {
    /// `count` colours from `from` to `to`, both included, at even steps. A
    /// colour with next to no chroma (a grey) has no hue of its own and
    /// takes the other's, so the blend doesn't swing through others on its
    /// way. Each is brought into sRGB by lowering its chroma alone.
    public static func blend(_ from: SiteColor, _ to: SiteColor, count: Int) -> [SiteColor] {
        guard count > 1 else { return count == 1 ? [from] : [] }
        let a = lch(from), b = lch(to)
        let grey = 0.02
        let start = a.c < grey ? b.h : a.h
        let end = b.c < grey ? a.h : b.h
        // The shorter way round, from -π to π.
        var turn = end - start
        while turn > .pi { turn -= 2 * .pi }
        while turn < -.pi { turn += 2 * .pi }
        return (0..<count).map { i in
            let t = Double(i) / Double(count - 1)
            let (red, green, blue) = IconGlow.srgb(l: a.l + (b.l - a.l) * t, c: a.c + (b.c - a.c) * t, hue: start + turn * t)
            return SiteColor(red: red, green: green, blue: blue)
        }
    }

    /// A colour's lightness, chroma and hue (radians).
    static func lch(_ colour: SiteColor) -> (l: Double, c: Double, h: Double) {
        let lab = IconGlow.oklab(colour.red, colour.green, colour.blue)
        return (lab.l, (lab.a * lab.a + lab.b * lab.b).squareRoot(), atan2(lab.b, lab.a))
    }
}
