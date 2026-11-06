import Foundation

/// Draws a site's icon given as SVG into a picture (SiteIcons).
@MainActor public protocol WebSVGRasterizer: AnyObject {
    /// The drawing in its light or its dark look at `side` pixels a side,
    /// whole and centred, as PNG with its transparency; nil when the
    /// engine cannot draw it, or takes over three seconds.
    func png(of svg: String, side: Int, dark: Bool) async -> Data?
}
