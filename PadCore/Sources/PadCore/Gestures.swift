import Foundation

/// The arithmetic behind the pointer bridges, kept apart from UIKit so it can
/// be tested anywhere.
public enum Pinch {
    /// The wheel delta Chrome sends for one step of a trackpad pinch on a
    /// Mac: minus `factor` times the natural log of the step's scale, with
    /// ctrlKey set. Negative zooms in. Steps add up: two steps of 1.1 send the
    /// same total as one of 1.21.
    public static func wheelDelta(step: Double, factor: Double = 100) -> Double {
        guard step > 0, step.isFinite else { return 0 }
        return -factor * Foundation.log(step)
    }
}

public enum Wheel {
    /// A two-finger pan as the wheel delta a Mac sends for the same swipe.
    /// With natural scrolling the content follows the fingers, so fingers
    /// moving up (y falling) scroll down, a positive deltaY.
    public static func delta(translationX dx: Double, translationY dy: Double) -> (x: Double, y: Double) {
        (-dx, -dy)
    }
}

/// One step of a scroll or a pinch on its way into a page (WheelLine).
public protocol WheelStep {
    /// The same kind of step, so the two add up to one.
    func joins(_ other: Self) -> Bool
    mutating func add(_ other: Self)
}

/// Wheel steps into a page, one at a time. A trackpad makes over a hundred
/// a second; a page slower than that would have them pile up, and go on
/// scrolling after the fingers had stopped. So while the page is still
/// answering one, those that come wait, each added to the one before it when
/// they are of a kind, and the next goes when the answer is in. Another kind
/// (a pinch after a scroll) waits its turn behind, so the page hears them in
/// the order they were made.
public struct WheelLine<Step: WheelStep> {
    /// Whether the page has yet to answer one.
    public private(set) var out = false
    public private(set) var held: [Step] = []
    /// Which run of steps this is: an answer from before `drop()` says
    /// nothing about this one.
    public private(set) var run = 0

    public init() {}

    /// A step made: returned when it is to go now, kept otherwise.
    public mutating func take(_ step: Step) -> Step? {
        guard out else {
            out = true
            return step
        }
        if let last = held.indices.last, held[last].joins(step) {
            held[last].add(step)
        } else {
            held.append(step)
        }
        return nil
    }

    /// The page answered the step that went in `run`: the next to go, if one waits.
    public mutating func answered(in run: Int) -> Step? {
        guard run == self.run else { return nil }
        guard !held.isEmpty else {
            out = false
            return nil
        }
        return held.removeFirst()
    }

    /// The page's process ended, or the page is going: what it had yet to
    /// answer no longer keeps the next from going. Those that waited come
    /// back, to hear that nothing came of them.
    public mutating func drop() -> [Step] {
        let waited = held
        held = []
        out = false
        run += 1
        return waited
    }
}

/// Back and forward by a swipe sideways, where the app takes it and not
/// WebKit (a desktop page: Page.applyScrolling). A finger drags in from the
/// page's edge; two fingers go sideways on the trackpad, as on a Mac.
public enum HistorySwipe {
    public enum Way: Equatable, Sendable {
        case back, forward
    }

    /// How far, in points, a finger's swipe travels before letting go takes the step.
    public static let reach = 110.0

    /// The same for two fingers on the trackpad: shorter, since fingers on
    /// a trackpad move less for the same intent than one across the glass,
    /// and 110 points took most of a trackpad's width.
    public static let trackpadReach = 60.0

    /// How much of the way there, from 0 to 1.
    public static func progress(distance: Double, reach: Double = reach) -> Double {
        min(1, max(0, distance / reach))
    }

    /// Whether letting go of a finger's swipe now takes the step: far
    /// enough and not on the way back at speed, which takes it back; or a
    /// flick that has gone a third of the way. `velocity` is along the
    /// swipe, in points a second.
    public static func commits(distance: Double, velocity: Double) -> Bool {
        (distance >= reach && velocity > -300) || (distance >= reach / 3 && velocity >= 700)
    }

    /// The same for two fingers on the trackpad: only at the whole reach,
    /// where the arrow fills, so the step is taken when the arrow says it
    /// will be. A third of so short a reach is hardly past where a swipe is
    /// told from a scroll (TrackpadSwipe.slack), so there is no flick.
    public static func trackpadCommits(distance: Double, velocity: Double) -> Bool {
        distance >= trackpadReach && velocity > -300
    }
}

/// Two fingers going sideways on the trackpad. It is a scroll first, and the
/// page's to use. It becomes a step back or forward only when it set out
/// sideways and the page had no use for any of it: every wheel event it made
/// came back unused (bridge.js wheel(): 'free'), as a Mac's browsers go back
/// only when the page left the swipe alone. One answer that says otherwise,
/// or one that never comes, and it stays a scroll.
public struct TrackpadSwipe: Equatable, Sendable {
    /// How far the fingers go before a swipe sideways is told from a scroll.
    public static let slack = 16.0

    private var x = 0.0
    private var y = 0.0
    private var heading: HistorySwipe.Way?
    private var scroll = false
    private var sent = 0
    private var answers = 0
    private var used = false

    public init() {}

    /// One step of the pan, in the points the fingers moved, as it goes to
    /// the page as a wheel event. Fingers moving right go back: the content
    /// follows them, and what was there before is to the left.
    public mutating func moved(dx: Double, dy: Double) {
        x += dx
        y += abs(dy)
        sent += 1
        guard heading == nil, !scroll, max(abs(x), y) >= Self.slack else { return }
        if abs(x) >= 2 * y {
            heading = x > 0 ? .back : .forward
        } else {
            scroll = true
        }
    }

    /// The page's answer to one step: whether it left the sideways part unused.
    public mutating func answered(free: Bool) {
        answers += 1
        if !free { used = true }
    }

    /// Where it would go, once it has set out sideways and the page has
    /// answered at least once, never having used it.
    public var way: HistorySwipe.Way? {
        guard !used, answers > 0 else { return nil }
        return heading
    }

    /// How far it has gone that way; back toward where it began counts down to nothing.
    public var distance: Double {
        switch heading {
        case .back: return max(0, x)
        case .forward: return max(0, -x)
        case nil: return 0
        }
    }

    /// Every step sent has been answered.
    public var settled: Bool {
        answers >= sent
    }

    /// The step to take when the fingers leave at `velocity` (points a
    /// second, to the right): none while an answer is still to come.
    public func commits(velocity: Double) -> HistorySwipe.Way? {
        guard settled, let way else { return nil }
        let along = way == .back ? velocity : -velocity
        return HistorySwipe.trackpadCommits(distance: distance, velocity: along) ? way : nil
    }
}

/// Two fingers going sideways on a Mac's trackpad (the Mac's PageSwipe).
/// There every scroll goes to WebKit as it comes, and WebKit answers only
/// for one the page left unused, never for one it used; so the answer
/// waited for is to one scroll, as WebKit's own swipe waits for one: the
/// gesture's first with a sideways part (`Scroll.asked`). That the page
/// left it alone says nothing under the fingers had any use for that way;
/// a scroll with nothing sideways in it would say nothing of the sort. It
/// becomes a step back or forward when that way was open (the page at its
/// edge there, with a page to go to), the fingers kept to it, more sideways
/// than not, for the first few points, and the page left the asked scroll
/// alone. From then the fingers are the swipe's: what they do goes to no
/// page, and back the way they came takes the swipe back to nothing. Until
/// then it is a scroll and the page's; one that heads up or down, or turns
/// back, stays one.
public struct ScrollSwipe: Equatable, Sendable {
    /// How long before the fingers leave their speed is taken over, in seconds.
    public static let window = 0.08

    /// What becomes of one scroll.
    public enum Scroll: Equatable, Sendable {
        /// It goes to the page.
        case page
        /// It goes to the page, and the page's answer to it is the one waited for.
        case asked
        /// The swipe has it, and it goes to no page.
        case swipe
    }

    private struct Step: Equatable, Sendable {
        let time: Double
        let dx: Double
    }

    /// The ways open when the gesture began.
    private let open: Set<HistorySwipe.Way>
    /// The one way it may go, the asked scroll's, once that has come.
    private var allowed: HistorySwipe.Way?
    private var asked = false
    private var x = 0.0
    private var y = 0.0
    private var heading: HistorySwipe.Way?
    private var free = false
    private var recent: [Step] = []
    /// It is a scroll, the page's, to its end.
    public private(set) var isScroll: Bool

    /// A gesture whose fingers have just begun to move, with the ways
    /// open then: where the page was at its edge with a page to go to.
    public init(open: Set<HistorySwipe.Way>) {
        self.open = open
        isScroll = open.isEmpty
    }

    /// One scroll of the gesture, its first included, in points, positive
    /// to the right and down; with natural scrolling the content follows
    /// the fingers, so fingers moving right go back. `time` in seconds, the
    /// event's own.
    @discardableResult
    public mutating func moved(dx: Double, dy: Double, at time: Double) -> Scroll {
        guard !isScroll else { return .page }
        x += dx
        recent.append(Step(time: time, dx: dx))
        recent.removeAll { $0.time <= time - Self.window }
        guard !taken else { return .swipe }
        y += abs(dy)
        var scroll = Scroll.page
        if !asked, dx != 0 {
            asked = true
            let way: HistorySwipe.Way = dx > 0 ? .back : .forward
            guard open.contains(way) else {
                isScroll = true
                return .page
            }
            allowed = way
            scroll = .asked
        }
        let along = allowed == .back ? x : -x
        if heading == nil {
            guard max(abs(x), y) >= TrackpadSwipe.slack else { return scroll }
            if allowed != nil, along > 0, abs(x) >= 2 * y {
                heading = allowed
            } else {
                isScroll = true
            }
        } else if along <= 0 || 2 * y > abs(x) {
            heading = nil
            isScroll = true
        }
        return taken ? .swipe : scroll
    }

    /// The page left the asked scroll unused.
    public mutating func leftAlone() {
        free = asked
    }

    /// The fingers are the swipe's.
    public var taken: Bool {
        free && heading != nil && !isScroll
    }

    /// It has set out sideways, and the page's answer is still to come.
    public var awaitsAnswer: Bool {
        heading != nil && !isScroll && !free
    }

    public var way: HistorySwipe.Way? {
        taken ? heading : nil
    }

    /// How far it has gone that way, from where it began; back toward there counts down to nothing.
    public var distance: Double {
        switch heading {
        case .back: return max(0, x)
        case .forward: return max(0, -x)
        case nil: return 0
        }
    }

    /// How fast the fingers were going sideways at `time`, in points a
    /// second, to the right: over the last `window`, nothing if they had
    /// stopped by then.
    public func speed(at time: Double) -> Double {
        recent.filter { $0.time > time - Self.window }.reduce(0) { $0 + $1.dx } / Self.window
    }

    /// The step to take when the fingers leave at `velocity`.
    public func commits(velocity: Double) -> HistorySwipe.Way? {
        guard let way else { return nil }
        let along = way == .back ? velocity : -velocity
        return HistorySwipe.trackpadCommits(distance: distance, velocity: along) ? way : nil
    }
}

/// To the space beside by sweeping sideways across the sidebar, as on the
/// Mac (its ReaderView): two fingers on the trackpad, or one on the glass.
/// Only a sweep that sets out more sideways than up and down counts; the
/// tabs scroll otherwise. It goes once it has come far enough, and only
/// once a sweep. The content follows the fingers: a sweep toward the row's
/// start brings in the space after this one, at the row's end.
public struct SpaceSwipe: Equatable, Sendable {
    /// How far the fingers go sideways before the space changes, in points: the Mac's.
    public static let reach = 70.0

    /// A finger let go at this speed, in points a second, after a third of
    /// the reach has gone on in the end: a flick, as HistorySwipe's. The
    /// trackpad has none, as the Mac's sweep doesn't: its fingers leave
    /// with nothing that says how fast.
    public static let flick = 700.0

    /// Whether fingers that have moved `dx` sideways and `dy` up or down
    /// since they set out go sideways: the Mac's measure, half again as much.
    public static func isSideways(dx: Double, dy: Double) -> Bool {
        abs(dx) > abs(dy) * 1.5
    }

    /// Mirrored, the row's end on the left.
    private let rightToLeft: Bool
    /// It has gone to a space, and goes to no other before the fingers leave.
    public private(set) var went = false

    public init(rightToLeft: Bool = false) {
        self.rightToLeft = rightToLeft
    }

    /// The fingers `dx` points from where they set out, positive to the
    /// right: the way to go along the row, 1 to the space after this one
    /// and -1 to the one before, the first time they have come far enough.
    public mutating func moved(to dx: Double) -> Int? {
        guard !went, abs(dx) > Self.reach else { return nil }
        went = true
        return way(dx)
    }

    /// A finger left the glass `dx` points from where it set out at
    /// `velocity` points a second, both positive to the right: the way to
    /// go, if it hadn't gone and this was a flick that way.
    public mutating func letGo(at dx: Double, velocity: Double) -> Int? {
        guard !went, abs(dx) >= Self.reach / 3, abs(velocity) >= Self.flick, (dx < 0) == (velocity < 0) else { return nil }
        went = true
        return way(dx)
    }

    private func way(_ dx: Double) -> Int {
        (dx < 0) != rightToLeft ? 1 : -1
    }
}

/// The glide after the fingers leave the trackpad, which a Mac's trackpad
/// sends as more wheel events and an iPad pan doesn't send at all.
///
/// The speed falls the way a UIScrollView's does at its normal deceleration
/// rate, 0.998 for each millisecond, and the glide ends below `stopSpeed`.
public struct Momentum: Equatable, Sendable {
    public var velocityX: Double
    public var velocityY: Double
    public var rate: Double
    public var stopSpeed: Double

    /// Velocities in wheel units (points) per second.
    public init(velocityX: Double, velocityY: Double, rate: Double = 0.998, stopSpeed: Double = 12) {
        self.velocityX = velocityX
        self.velocityY = velocityY
        self.rate = rate
        self.stopSpeed = stopSpeed
    }

    public var isDone: Bool {
        (velocityX * velocityX + velocityY * velocityY).squareRoot() < stopSpeed
    }

    /// The distance covered in the next `seconds`, or nil once the glide is over.
    public mutating func advance(by seconds: Double) -> (x: Double, y: Double)? {
        guard !isDone, seconds > 0 else { return nil }
        let milliseconds = seconds * 1000
        let decay = Foundation.pow(rate, milliseconds)
        // The distance under exponential decay, not speed times time: the
        // same total whatever the frame rate.
        let k = Foundation.log(rate) * 1000
        let travelled = (decay - 1) / k
        let step = (velocityX * travelled, velocityY * travelled)
        velocityX *= decay
        velocityY *= decay
        return step
    }
}

/// Where the zoom is held.
///
/// At 1: no pinch, double tap or anything else zooms the page itself. The
/// exception is a window narrower than the page's desktop layout, which
/// WebKit can make wider than a narrow window (a portrait iPad, a small Stage
/// Manager window) and then scale down to fit. There WebKit's fit is kept,
/// the smallest scale it allows, so the whole page stays in view instead of
/// being cut off at the window's edge with no way to scroll to the rest.
public enum ZoomLock {
    public static func scale(webKitMinimum: Double?) -> Double {
        guard let minimum = webKitMinimum, minimum > 0, minimum.isFinite else { return 1 }
        return min(1, minimum)
    }
}

/// A drag let go: how far its speed would carry it, and how a drag past an
/// end gives way, as a scroll view has them; and where the app's own drags
/// go when let go (the tab sheet, the bar's slide to the tab beside, a tab
/// card thrown away). Kept apart from UIKit so the decisions can be tested.
public enum Throw {
    /// How much further a throw at `velocity` points a second carries, as
    /// a scroll view decelerates at its normal rate (0.998 a millisecond).
    public static func carry(_ velocity: Double, rate: Double = 0.998) -> Double {
        velocity / 1000 * rate / (1 - rate)
    }

    /// Apple's rubber band for a drag `distance` past an end: a little over
    /// half as far at first, giving less the further it goes, never past
    /// `range`. Either way.
    public static func rubberband(_ distance: Double, range: Double) -> Double {
        distance * range * 0.55 / (range + 0.55 * abs(distance))
    }

    /// Whether the tab sheet, let go at `progress` (0 shut, 1 open) as the
    /// finger goes up at `speed` points a second over `distance` points of
    /// travel, opens. A flick goes the way it was going; anything slower
    /// goes to the side of `line` its throw would come to rest on.
    public static func opens(progress: Double, speed: Double, distance: Double, line: Double,
                             flick: Double = 300) -> Bool {
        speed > flick || (speed > -flick && progress + carry(speed) / distance > line)
    }

    /// Whether the bar's slide, let go `offset` points along at `velocity`,
    /// goes on to the tab beside on `side` (1 the right, which a drag to the
    /// left brings in; -1 the left): its throw comes to rest more than half
    /// of `width` (a page and the gap after it) that way.
    public static func slideGoes(offset: Double, velocity: Double, side: Double, width: Double) -> Bool {
        let resting = offset + carry(velocity)
        return side > 0 ? resting < -width / 2 : resting > width / 2
    }

    /// Whether a tab's card, let go `x` points sideways at `speed`, is thrown
    /// away: its throw carries it past most of its `width`, or it was let
    /// go past `line`; and not when the throw takes it back the way it came.
    public static func cardThrown(x: Double, speed: Double, width: Double, line: Double) -> Bool {
        let resting = x + carry(speed)
        return (abs(resting) > width * 0.9 || abs(x) > line) && (x == 0 || resting * x > 0)
    }
}
