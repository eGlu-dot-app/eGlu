import XCTest
@testable import PadCore

final class SidebarResizeTests: XCTestCase {
    func testTheMovingSidebarEdgeMeasuresTheDragInFixedCoordinates() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Mac/Sources/BrowserView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private var edge: some View {"))
        let end = try XCTUnwrap(source.range(of: "private var peek: some View {", range: start.upperBound..<source.endIndex))
        let edge = source[start.lowerBound..<end.lowerBound]
        XCTAssertTrue(edge.contains("DragGesture(minimumDistance: 1, coordinateSpace: .global)"),
                      "The divider moves during resizing, so local drag coordinates make the sidebar oscillate")
    }
}

final class PinchTests: XCTestCase {
    func testSpreadingZoomsInWithANegativeDelta() {
        XCTAssertLessThan(Pinch.wheelDelta(step: 1.1), 0)
        XCTAssertGreaterThan(Pinch.wheelDelta(step: 0.9), 0)
        XCTAssertEqual(Pinch.wheelDelta(step: 1), 0)
    }

    func testDoublingSendsChromesAmount() {
        XCTAssertEqual(Pinch.wheelDelta(step: 2), -69.3147, accuracy: 0.001)
    }

    func testStepsAddUpToTheWholePinch() {
        let split = Pinch.wheelDelta(step: 1.1) + Pinch.wheelDelta(step: 1.1)
        XCTAssertEqual(split, Pinch.wheelDelta(step: 1.21), accuracy: 1e-9)
    }

    func testNonsenseScalesSendNothing() {
        XCTAssertEqual(Pinch.wheelDelta(step: 0), 0)
        XCTAssertEqual(Pinch.wheelDelta(step: -1), 0)
        XCTAssertEqual(Pinch.wheelDelta(step: .infinity), 0)
    }
}

final class WheelTests: XCTestCase {
    func testFingersUpScrollDown() {
        let delta = Wheel.delta(translationX: 3, translationY: -10)
        XCTAssertEqual(delta.x, -3)
        XCTAssertEqual(delta.y, 10)
    }
}

final class WheelLineTests: XCTestCase {
    struct Step: WheelStep, Equatable {
        var kind: String
        var amount: Double
        /// How many steps this one is made of: each has someone to tell.
        var made = 1

        func joins(_ other: Step) -> Bool { kind == other.kind }
        mutating func add(_ other: Step) {
            amount += other.amount
            made += other.made
        }
    }

    func testTheFirstGoesAtOnceAndTheNextOnItsAnswer() {
        var line = WheelLine<Step>()
        XCTAssertEqual(line.take(Step(kind: "scroll", amount: 4)), Step(kind: "scroll", amount: 4))
        XCTAssertNil(line.take(Step(kind: "scroll", amount: 6)), "the page is still answering the first")
        XCTAssertEqual(line.answered(in: line.run), Step(kind: "scroll", amount: 6))
        XCTAssertNil(line.answered(in: line.run))
        XCTAssertFalse(line.out)
        XCTAssertEqual(line.take(Step(kind: "scroll", amount: 1)), Step(kind: "scroll", amount: 1), "nothing owed: it goes at once")
    }

    func testThoseOfAKindAddUpWhileOneIsOut() {
        var line = WheelLine<Step>()
        _ = line.take(Step(kind: "scroll", amount: 1))
        for _ in 0..<50 { XCTAssertNil(line.take(Step(kind: "scroll", amount: 2))) }
        XCTAssertEqual(line.held.count, 1, "a slow page is sent one, not fifty")
        XCTAssertEqual(line.answered(in: line.run), Step(kind: "scroll", amount: 100, made: 50))
    }

    func testAnotherKindWaitsItsTurnBehind() {
        var line = WheelLine<Step>()
        _ = line.take(Step(kind: "scroll", amount: 1))
        _ = line.take(Step(kind: "scroll", amount: 2))
        _ = line.take(Step(kind: "pinch", amount: 5))
        _ = line.take(Step(kind: "pinch", amount: 5))
        _ = line.take(Step(kind: "scroll", amount: 3))
        XCTAssertTrue(line.out)
        // One at a time, in the order they were made; a scroll after the pinch is not added to the one before it.
        XCTAssertEqual(line.answered(in: line.run), Step(kind: "scroll", amount: 2))
        XCTAssertEqual(line.answered(in: line.run), Step(kind: "pinch", amount: 10, made: 2))
        XCTAssertEqual(line.answered(in: line.run), Step(kind: "scroll", amount: 3))
        XCTAssertNil(line.answered(in: line.run))
        XCTAssertFalse(line.out)
    }

    func testEveryStepReachesThePageOnce() {
        var line = WheelLine<Step>()
        var sent: [Step] = []
        var owed = 0
        // The page answers one in three of the moments a step is made.
        for index in 0..<300 {
            if let now = line.take(Step(kind: index % 40 < 30 ? "scroll" : "pinch", amount: 1)) {
                sent.append(now)
                owed += 1
            }
            if index % 3 == 0, owed > 0 {
                owed -= 1
                if let next = line.answered(in: line.run) {
                    sent.append(next)
                    owed += 1
                }
            }
            XCTAssertLessThanOrEqual(owed, 1, "never two with the page at once")
        }
        while owed > 0 {
            owed -= 1
            if let next = line.answered(in: line.run) {
                sent.append(next)
                owed += 1
            }
        }
        XCTAssertEqual(sent.reduce(0) { $0 + $1.amount }, 300)
        XCTAssertEqual(sent.reduce(0) { $0 + $1.made }, 300)
        XCTAssertLessThan(sent.count, 300)
        XCTAssertTrue(line.held.isEmpty)
    }

    func testAPageThatWentOwesNothing() {
        var line = WheelLine<Step>()
        let before = line.run
        _ = line.take(Step(kind: "scroll", amount: 1))
        _ = line.take(Step(kind: "scroll", amount: 2))
        _ = line.take(Step(kind: "pinch", amount: 3))
        // Its process ended with one unanswered: those that waited are handed back, and the next goes at once.
        XCTAssertEqual(line.drop(), [Step(kind: "scroll", amount: 2), Step(kind: "pinch", amount: 3)])
        XCTAssertFalse(line.out)
        XCTAssertEqual(line.take(Step(kind: "scroll", amount: 7)), Step(kind: "scroll", amount: 7))
        _ = line.take(Step(kind: "scroll", amount: 8))
        // The old answer, coming late, sends nothing and frees nothing.
        XCTAssertNil(line.answered(in: before))
        XCTAssertTrue(line.out)
        XCTAssertEqual(line.held, [Step(kind: "scroll", amount: 8)])
        XCTAssertEqual(line.answered(in: line.run), Step(kind: "scroll", amount: 8))
    }
}

final class MomentumTests: XCTestCase {
    func testASwipeGoesBackWhenItHasGoneFarEnoughOrFastEnough() {
        XCTAssertEqual(HistorySwipe.progress(distance: 55), 0.5, accuracy: 0.001)
        XCTAssertEqual(HistorySwipe.progress(distance: 400), 1)
        XCTAssertEqual(HistorySwipe.progress(distance: -20), 0)
        XCTAssertTrue(HistorySwipe.commits(distance: 110, velocity: 0))
        XCTAssertFalse(HistorySwipe.commits(distance: 100, velocity: 0))
        XCTAssertTrue(HistorySwipe.commits(distance: 40, velocity: 900), "a flick")
        XCTAssertFalse(HistorySwipe.commits(distance: 20, velocity: 900), "a twitch isn't one")
        XCTAssertFalse(HistorySwipe.commits(distance: 100, velocity: -900), "let go on the way back")
        XCTAssertFalse(HistorySwipe.commits(distance: 150, velocity: -900), "far enough, but flicked back")
        XCTAssertTrue(HistorySwipe.commits(distance: 150, velocity: -100), "a hand that eases off still means it")
    }

    func testTwoFingersSidewaysGoBackOnlyWhenThePageLeftEveryStep() {
        var swipe = TrackpadSwipe()
        for _ in 0..<12 {
            swipe.moved(dx: 10, dy: 0.5)
            XCTAssertNil(swipe.commits(velocity: 0), "an answer is still to come")
            swipe.answered(free: true)
        }
        XCTAssertEqual(swipe.way, .back, "fingers to the right: the page before")
        XCTAssertEqual(swipe.distance, 120, accuracy: 0.001)
        XCTAssertEqual(swipe.commits(velocity: 0), .back)

        var used = TrackpadSwipe()
        for step in 0..<12 {
            used.moved(dx: -10, dy: 0)
            used.answered(free: step != 5)
        }
        XCTAssertNil(used.way, "the page took one step: the swipe is its own")
        XCTAssertNil(used.commits(velocity: -2000))
    }

    func testTwoFingersGoBackSoonerThanAFinger() {
        var swipe = TrackpadSwipe()
        for _ in 0..<6 {
            swipe.moved(dx: 10, dy: 0)
            swipe.answered(free: true)
        }
        XCTAssertEqual(swipe.distance, 60, accuracy: 0.001)
        XCTAssertEqual(swipe.commits(velocity: 0), .back, "60 points on the trackpad is far enough")
        XCTAssertFalse(HistorySwipe.commits(distance: 60, velocity: 0), "a finger across the glass goes further")
        XCTAssertEqual(HistorySwipe.progress(distance: 30, reach: HistorySwipe.trackpadReach), 0.5, accuracy: 0.001)

        var short = TrackpadSwipe()
        for _ in 0..<5 {
            short.moved(dx: 10, dy: 0)
            short.answered(free: true)
        }
        XCTAssertNil(short.commits(velocity: 0), "50 points isn't")
    }

    func testAScrollThatTurnsSidewaysStaysAScroll() {
        var swipe = TrackpadSwipe()
        for _ in 0..<4 {
            swipe.moved(dx: 1, dy: 8)
            swipe.answered(free: true)
        }
        for _ in 0..<20 {
            swipe.moved(dx: 12, dy: 0)
            swipe.answered(free: true)
        }
        XCTAssertNil(swipe.way)
        XCTAssertEqual(swipe.distance, 0)
        XCTAssertNil(swipe.commits(velocity: 3000))
    }

    func testASwipeForwardAndOneTakenBack() {
        var swipe = TrackpadSwipe()
        XCTAssertNil(swipe.way, "nothing before the page has answered")
        for _ in 0..<6 {
            swipe.moved(dx: -10, dy: 0)
            swipe.answered(free: true)
        }
        XCTAssertEqual(swipe.way, .forward)
        XCTAssertEqual(swipe.commits(velocity: -900), .forward, "a flick the same way")
        for _ in 0..<5 {
            swipe.moved(dx: 10, dy: 0)
            swipe.answered(free: true)
        }
        XCTAssertEqual(swipe.distance, 10, accuracy: 0.001)
        XCTAssertNil(swipe.commits(velocity: 900), "back where it began, it goes nowhere")
    }

    /// A Mac gesture with its scrolls as (dx, dy), a hundredth of a second apart.
    private func gesture(_ open: Set<HistorySwipe.Way>, _ scrolls: [(Double, Double)], from start: Double = 0) -> (ScrollSwipe, [ScrollSwipe.Scroll]) {
        var swipe = ScrollSwipe(open: open)
        let fates = scrolls.enumerated().map { swipe.moved(dx: $1.0, dy: $1.1, at: start + Double($0) / 100) }
        return (swipe, fates)
    }

    func testAMacSwipeIsTakenOnceThePageLeftTheAskedScrollAlone() {
        var (swipe, fates) = gesture([.back], [(4, 0), (6, 0.5), (8, 0)])
        XCTAssertEqual(fates, [.asked, .page, .page], "the first sideways scroll is asked; under the slack, and before the answer, all are the page's")
        XCTAssertTrue(swipe.awaitsAnswer)
        XCTAssertNil(swipe.way)
        swipe.leftAlone()
        XCTAssertEqual(swipe.way, .back)
        XCTAssertEqual(swipe.moved(dx: 10, dy: 4, at: 0.03), .swipe, "from now the fingers are the swipe's")
        XCTAssertEqual(swipe.distance, 28, accuracy: 0.001)
        XCTAssertNil(swipe.commits(velocity: 0))
        for step in 0..<4 { swipe.moved(dx: 8, dy: 0, at: 0.04 + Double(step) / 100) }
        XCTAssertEqual(swipe.distance, 60, accuracy: 0.001)
        XCTAssertEqual(swipe.commits(velocity: 0), .back, "the trackpad's reach")

        var (late, lateFates) = gesture([.back, .forward], Array(repeating: (-5, 0), count: 7))
        XCTAssertEqual(lateFates.filter { $0 == .swipe }, [])
        late.leftAlone()
        XCTAssertEqual(late.way, .forward, "an answer that comes late still counts")
        XCTAssertEqual(late.distance, 35, accuracy: 0.001)
        XCTAssertNil(late.commits(velocity: -900), "no flick on the trackpad: the arrow hasn't filled")
    }

    func testAMacSwipeAsksTheFirstScrollThatGoesSideways() {
        // Fingers that land before they slide, then a little down: the
        // answer waited for is to the first scroll with a sideways part.
        var (swipe, fates) = gesture([.back], [(0, 0), (0, 1), (3, 0.5), (8, 0), (8, 0)])
        XCTAssertEqual(fates, [.page, .page, .asked, .page, .page])
        swipe.leftAlone()
        XCTAssertEqual(swipe.way, .back)

        // A little aslant at first is still a swipe, once it is more sideways than not.
        var (aslant, aslantFates) = gesture([.forward], [(-2, 1), (-8, 0), (-8, 0)])
        XCTAssertEqual(aslantFates.first, .asked)
        aslant.leftAlone()
        XCTAssertEqual(aslant.way, .forward)
    }

    func testAMacSwipeThePageUsedOrCannotGoIsAScroll() {
        var (used, usedFates) = gesture([.back], Array(repeating: (6, 0), count: 21))
        XCTAssertFalse(usedFates.contains(.swipe))
        XCTAssertNil(used.way, "no answer: the page used it")
        XCTAssertNil(used.commits(velocity: 2000))

        var (edge, _) = gesture([.forward], [(6, 0)])
        edge.leftAlone()
        XCTAssertTrue(edge.isScroll, "back is not open: not at the page's left edge, or nothing to go back to")
        XCTAssertEqual(edge.moved(dx: 30, dy: 0, at: 0.01), .page)
        XCTAssertNil(edge.way)

        var nowhere = ScrollSwipe(open: [])
        XCTAssertTrue(nowhere.isScroll)
        XCTAssertEqual(nowhere.moved(dx: 30, dy: 0, at: 0), .page)
        nowhere.leftAlone()
        XCTAssertNil(nowhere.way)

        var (unasked, _) = gesture([.back], [(0, 2), (0, 3)])
        unasked.leftAlone()
        unasked.moved(dx: 0, dy: 1, at: 0.02)
        XCTAssertEqual(unasked.moved(dx: 40, dy: 0, at: 0.03), .asked, "an answer to a scroll with nothing sideways in it counts for nothing")
        XCTAssertNil(unasked.way)
    }

    func testAMacScrollThatHeadsDownOrTurnsBackStaysAScroll() {
        var (down, _) = gesture([.back], [(1, 6), (2, 12)])
        down.leftAlone()
        XCTAssertTrue(down.isScroll)
        XCTAssertEqual(down.moved(dx: 40, dy: 0, at: 0.02), .page)
        XCTAssertNil(down.way)

        var (turned, _) = gesture([.back], [(10, 0), (10, 0)])
        XCTAssertTrue(turned.awaitsAnswer)
        turned.moved(dx: 0, dy: 15, at: 0.02)
        turned.leftAlone()
        XCTAssertTrue(turned.isScroll, "it turned down before the page answered")

        var (other, _) = gesture([.back, .forward], [(3, 0)] + Array(repeating: (-10, 0), count: 6))
        other.leftAlone()
        XCTAssertTrue(other.isScroll, "it began back and went forward: the answer was for back")
        XCTAssertNil(other.way)

        var (reversed, _) = gesture([.back], [(18, 0)])
        XCTAssertTrue(reversed.awaitsAnswer)
        reversed.moved(dx: -80, dy: 0, at: 0.01)
        reversed.leftAlone()
        XCTAssertTrue(reversed.isScroll, "it turned back before the page answered")
    }

    func testAMacSwipeTakenBackGoesNowhere() {
        var (swipe, _) = gesture([.back], [(10, 0)])
        swipe.leftAlone()
        for step in 1...6 { swipe.moved(dx: 10, dy: 0, at: Double(step) / 100) }
        XCTAssertEqual(swipe.commits(velocity: 0), .back)
        for step in 7...20 { XCTAssertEqual(swipe.moved(dx: -10, dy: 0, at: Double(step) / 100), .swipe, "still the swipe's") }
        XCTAssertEqual(swipe.distance, 0)
        XCTAssertNil(swipe.commits(velocity: 900))
    }

    func testAMacSwipesSpeedIsTheFingersLastMoments() {
        var (swipe, _) = gesture([.back], [(10, 0)])
        swipe.leftAlone()
        for step in 1...20 { swipe.moved(dx: 10, dy: 0, at: Double(step) / 100) }
        XCTAssertEqual(swipe.speed(at: 0.205), 1000, accuracy: 1, "10 points every hundredth of a second")
        XCTAssertEqual(swipe.speed(at: 0.5), 0, "they had stopped before they left")
        XCTAssertEqual(swipe.commits(velocity: swipe.speed(at: 0.205)), .back)
    }

    func testTheTrackpadTakesTheStepOnlyWhereTheArrowFills() {
        XCTAssertTrue(HistorySwipe.commits(distance: 40, velocity: 900), "a finger's flick goes from a third of the way")
        XCTAssertFalse(HistorySwipe.trackpadCommits(distance: 40, velocity: 3000), "two fingers' doesn't")
        XCTAssertTrue(HistorySwipe.trackpadCommits(distance: 60, velocity: 0))
        XCTAssertFalse(HistorySwipe.trackpadCommits(distance: 80, velocity: -900), "flicked back")

        var pad = TrackpadSwipe()
        for _ in 0..<3 {
            pad.moved(dx: 10, dy: 0)
            pad.answered(free: true)
        }
        XCTAssertNil(pad.commits(velocity: 3000), "30 points on the iPad's trackpad, however fast")
    }

    func testGlideSlowsAndEnds() {
        var glide = Momentum(velocityX: 0, velocityY: 2000)
        var total = 0.0
        var steps = 0
        var last = Double.infinity
        while let step = glide.advance(by: 1.0 / 60) {
            XCTAssertLessThan(step.y, last)
            last = step.y
            total += step.y
            steps += 1
            XCTAssertLessThan(steps, 10_000)
        }
        XCTAssertTrue(glide.isDone)
        // Under exponential decay the whole glide comes to v / -ln(rate) / 1000.
        let whole = 2000 / (-Foundation.log(0.998) * 1000)
        XCTAssertEqual(total, whole, accuracy: whole * 0.01)
    }

    func testFrameRateDoesNotChangeTheDistance() {
        func distance(_ frame: Double) -> Double {
            var glide = Momentum(velocityX: 1500, velocityY: 0)
            var total = 0.0
            while let step = glide.advance(by: frame) { total += step.x }
            return total
        }
        XCTAssertEqual(distance(1.0 / 60), distance(1.0 / 120), accuracy: 2)
    }

    func testSlowReleaseDoesNotGlide() {
        var glide = Momentum(velocityX: 5, velocityY: 5)
        XCTAssertNil(glide.advance(by: 1.0 / 60))
    }
}

final class ZoomLockTests: XCTestCase {
    func testHeldAtOne() {
        XCTAssertEqual(ZoomLock.scale(webKitMinimum: 1), 1)
        XCTAssertEqual(ZoomLock.scale(webKitMinimum: 1.5), 1)
        XCTAssertEqual(ZoomLock.scale(webKitMinimum: nil), 1)
        XCTAssertEqual(ZoomLock.scale(webKitMinimum: 0), 1)
    }

    func testANarrowWindowKeepsWebKitsFit() {
        XCTAssertEqual(ZoomLock.scale(webKitMinimum: 0.78), 0.78)
    }
}

final class ThrowTests: XCTestCase {
    func testAThrowCarriesAsAScrollViewDecelerates() {
        XCTAssertEqual(Throw.carry(0), 0)
        XCTAssertEqual(Throw.carry(1000), 499, accuracy: 0.001)
        XCTAssertEqual(Throw.carry(-1000), -499, accuracy: 0.001)
    }

    func testTheRubberBandGivesLessAndLessAndNeverReachesItsRange() {
        XCTAssertEqual(Throw.rubberband(0, range: 100), 0)
        XCTAssertEqual(Throw.rubberband(1, range: 100), 0.55, accuracy: 0.01)
        XCTAssertLessThan(Throw.rubberband(10_000, range: 100), 100)
        XCTAssertGreaterThan(Throw.rubberband(10_000, range: 100), 98)
        XCTAssertEqual(Throw.rubberband(-40, range: 100), -Throw.rubberband(40, range: 100))
    }

    func testTheTabSheetFollowsAFlickAndOtherwiseTheThrow() {
        // A flick up opens it from barely started; one down shuts it from nearly open.
        XCTAssertTrue(Throw.opens(progress: 0.05, speed: 400, distance: 600, line: 0.3))
        XCTAssertFalse(Throw.opens(progress: 0.95, speed: -400, distance: 600, line: 0.7))
        // Let go still, it goes to the side of the line it is on.
        XCTAssertTrue(Throw.opens(progress: 0.31, speed: 0, distance: 600, line: 0.3))
        XCTAssertFalse(Throw.opens(progress: 0.29, speed: 0, distance: 600, line: 0.3))
        // A slow push carries it over: 200 points a second goes about 100 points more.
        XCTAssertTrue(Throw.opens(progress: 0.2, speed: 200, distance: 600, line: 0.3))
    }

    func testTheSlideGoesOnlyWhenItWouldRestPastHalfway() {
        // Dragged left 150 of 400, let go still: back. Thrown on: to the tab on the right.
        XCTAssertFalse(Throw.slideGoes(offset: -150, velocity: 0, side: 1, width: 400))
        XCTAssertTrue(Throw.slideGoes(offset: -150, velocity: -300, side: 1, width: 400))
        // Thrown back the other way, it stays.
        XCTAssertFalse(Throw.slideGoes(offset: -250, velocity: 400, side: 1, width: 400))
        XCTAssertTrue(Throw.slideGoes(offset: 250, velocity: 0, side: -1, width: 400))
    }

    func testACardIsThrownAwayButNotBackTheWayItCame() {
        XCTAssertTrue(Throw.cardThrown(x: 120, speed: 0, width: 180, line: 100))
        XCTAssertTrue(Throw.cardThrown(x: 30, speed: 600, width: 180, line: 100))
        XCTAssertFalse(Throw.cardThrown(x: 30, speed: 0, width: 180, line: 100))
        // Past the line but flung back across where it started.
        XCTAssertFalse(Throw.cardThrown(x: 120, speed: -2000, width: 180, line: 100))
    }
}
