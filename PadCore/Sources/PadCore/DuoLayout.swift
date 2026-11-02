import Foundation

/// What the iPhone Duo's fold does to the window's layout, worked out
/// without UIKit so it can be tested anywhere (Docs/iPhoneDuoDesign.md §5).
public enum DuoLayout {
    /// The sidebar's width, and the room between its trailing edge and the
    /// page, in the window's points.
    public struct Sidebar: Equatable, Sendable {
        public let width: CGFloat
        /// From the sidebar's trailing edge to the page's leading one.
        public let gap: CGFloat
    }

    /// The sidebar while it shows. Folded like a book (the fold running top
    /// to bottom), it reaches the fold and the page starts past it, so each
    /// half of the display is one of the two. Folded like a laptop, fully
    /// open, or with the fold on the wrong side or too near the edge for a
    /// sidebar, it is its own width with the usual gap.
    ///
    /// - Parameters:
    ///   - start: where the sidebar starts: its left edge, or its right one
    ///     in right-to-left languages, where it stands on the right.
    ///   - fold: the active fold's frame, its margins included, or nil.
    ///   - rightToLeft: the sidebar stands on the right.
    ///   - standard: the sidebar's own width.
    ///   - minimum: the narrowest the sidebar goes to reach a fold.
    ///   - gap: the room between sidebar and page with no fold.
    public static func sidebar(start: CGFloat, fold: CGRect?, rightToLeft: Bool,
                               standard: CGFloat, minimum: CGFloat, gap: CGFloat) -> Sidebar {
        let usual = Sidebar(width: standard, gap: gap)
        guard let fold, fold.height > fold.width else { return usual }
        let width = rightToLeft ? start - fold.maxX : fold.minX - start
        guard width >= minimum else { return usual }
        return Sidebar(width: width, gap: fold.width)
    }

    /// What the strip takes of a page that runs on under it, in the page
    /// view's points, as strip.js is told it (Docs/iPhoneDuoDesign.md §9).
    /// The strip is taken only in bands: the status bar and the system's
    /// items at its top, New Tab and Tabs at its foot. Between the bands it
    /// is empty, and what can be pressed on the page may stand under it.
    public struct Strip: Equatable, Sendable, Encodable {
        public enum Side: String, Equatable, Sendable, Encodable {
            case left
            case right
        }

        public let side: Side
        /// From the window's edge to the safe area's.
        public let width: CGFloat
        /// Top and bottom of each band, top first, none touching another.
        public let bands: [[CGFloat]]
        /// How far below and above a band the room for what can be pressed
        /// takes to widen back to the window's edge: a slant rather than a step.
        public let ramp: CGFloat
        /// Whether the bands are where the strip's items are: false when the
        /// system didn't say where one stands, and the whole strip is one band.
        public let known: Bool

        public init(side: Side, width: CGFloat, bands: [[CGFloat]], ramp: CGFloat, known: Bool = true) {
            self.side = side
            self.width = width
            self.bands = bands
            self.ramp = ramp
            self.known = known
        }
    }

    /// The strip's bands from what stands in it, in the window's points: the
    /// system's items (`items`, nil for one the system gave no place for),
    /// and the status bar's and the cameras' regions (`occlusions`, nil where
    /// the system can't say). An item without a place makes the whole strip
    /// one band, as nothing then says where it is empty: a band never left
    /// out for want of a frame. Without the regions, the strip above its
    /// topmost item is taken as theirs.
    public static func stripBands(items: [CGRect?], occlusions: [CGRect]?, pageTop: CGFloat, pageHeight: CGFloat,
                                  margin: CGFloat) -> (bands: [[CGFloat]], known: Bool) {
        let placed = items.compactMap { $0 }.filter { !$0.isEmpty && !$0.isInfinite && !$0.isNull }
        guard !items.isEmpty, placed.count == items.count, let top = placed.min(by: { $0.minY < $1.minY }) else {
            return ([[0, pageHeight.rounded(.up)]], false)
        }
        var frames = placed
        if let occlusions, !occlusions.isEmpty {
            frames += occlusions
        } else {
            frames.append(CGRect(x: top.minX, y: pageTop, width: top.width, height: max(0, top.minY - pageTop)))
        }
        return (stripBands(of: frames, pageTop: pageTop, pageHeight: pageHeight, margin: margin), true)
    }

    /// The strip's bands from what stands in it, as frames in the window's
    /// points: each frame's top and bottom, `margin` further out at both, in
    /// the page's points (its top at `pageTop`), in whole points, top first,
    /// those that overlap or touch made one. Those wholly above the page or
    /// below its foot (`pageHeight`) are left out.
    public static func stripBands(of frames: [CGRect], pageTop: CGFloat, pageHeight: CGFloat,
                                  margin: CGFloat) -> [[CGFloat]] {
        let spans = frames
            .filter { $0.width > 0 && $0.height > 0 }
            .map { (top: ($0.minY - pageTop - margin).rounded(.down), bottom: ($0.maxY - pageTop + margin).rounded(.up)) }
            .filter { $0.bottom > 0 && $0.top < pageHeight }
            .sorted { $0.top < $1.top }
        var bands: [[CGFloat]] = []
        for span in spans {
            if let last = bands.last, span.top <= last[1] {
                bands[bands.count - 1][1] = max(last[1], span.bottom)
            } else {
                bands.append([span.top, span.bottom])
            }
        }
        return bands
    }
}
