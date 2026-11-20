import XCTest
@testable import VibraMusic

@MainActor
final class PlayerDockTests: XCTestCase {
    private let mini = CGRect(x: 28, y: 700, width: 40, height: 40)
    private let open = CGRect(x: 30, y: 120, width: 330, height: 330)
    private let travel: CGFloat = 800

    func testTheArtworkStartsOnTheCoverEndsInItsPlaceAndLandsOnTheCoverAtZeroSpeed() {
        func rect(_ t: CGFloat) -> CGRect { PlayerDockMotion.rect(open: open, mini: mini, t: t, travel: travel) }
        XCTAssertEqual(rect(1), open)
        XCTAssertEqual(rect(0), mini)
        let delta = mini.minY - open.minY
        XCTAssertLessThan(abs(rect(0.01).minY - mini.minY), 0.001 * delta)
        for step in 0...100 {
            XCTAssertLessThanOrEqual(rect(CGFloat(step) / 100).minY, mini.minY + 0.001, "it went below the cover at \(step)%")
        }
    }

    func testTheArtworkArrivesWithTheSheetRatherThanCatchingUpWithIt() {
        func height(_ t: CGFloat) -> CGFloat { PlayerDockMotion.rect(open: open, mini: mini, t: t, travel: travel).minY }
        func slot(_ t: CGFloat) -> CGFloat { open.minY + (1 - t) * travel }
        for t in [0.55, 0.7, 0.8, 0.9, 0.95] as [CGFloat] {
            XCTAssertEqual(height(t), slot(t), accuracy: 0.02 * travel, "at \(t)")
        }
        XCTAssertEqual(height(1) - height(0.99), slot(1) - slot(0.99), accuracy: 0.02, "the same speed on arrival")
    }

    func testAPullIsFullyOpenBeforeTheFingerReachesTheTopAndStaysSmoothOnTheWay() {
        let dock = PlayerDock(reduced: { false }, drivesFrames: false)
        dock.travel = 834
        let start: CGFloat = 780
        func hold(fingerAt y: CGFloat) -> CGFloat {
            dock.hold(offset: PlayerDockMotion.pullOffset(y - start, from: start, travel: dock.travel))
            return dock.fraction
        }
        XCTAssertEqual(hold(fingerAt: start), 0, accuracy: 0.001)
        XCTAssertEqual(hold(fingerAt: PlayerDockMotion.pullTopMargin), 1, accuracy: 0.001)
        XCTAssertEqual(hold(fingerAt: 40), 1, "a finger going on up keeps it open")
        var last: CGFloat = 0
        for y in stride(from: start, through: PlayerDockMotion.pullTopMargin, by: -1) {
            let now = hold(fingerAt: y)
            XCTAssertLessThan(now - last, 2 / dock.travel, "no jump with the finger at \(y)")
            last = now
        }
    }

    func testTheArtworkFollowsOnlyAsMuchOfThePlayersTravelAsItCanLandWith() {
        let below = open.offsetBy(dx: 0, dy: 900)
        let halfway = PlayerDockMotion.rect(open: below, mini: mini, t: 0.5, travel: travel)
        XCTAssertEqual(halfway.minY, (mini.minY + below.minY) / 2, accuracy: 0.001)
    }

    func testTheRestOfThePlayerIsGoneWithAFifthOfTheWayToGo() {
        XCTAssertEqual(PlayerDockMotion.fade(0), 0)
        XCTAssertEqual(PlayerDockMotion.fade(0.15), 0)
        XCTAssertEqual(PlayerDockMotion.fade(0.575), 0.5, accuracy: 0.0001)
        XCTAssertEqual(PlayerDockMotion.fade(1), 1)
    }

    func testTheBarRisesLessThanTheFingerTravels() {
        XCTAssertEqual(PlayerDockMotion.pullLift(0), 0)
        XCTAssertEqual(PlayerDockMotion.pullLift(72), 29.82, accuracy: 0.01)
        XCTAssertLessThan(PlayerDockMotion.pullLift(400), 400 / 2)
    }

    func testADragOnTheMiniPlayerIsDecidedOnceAsAPullASwipeOrAScroll() {
        func axis(_ x: CGFloat, _ y: CGFloat, pull: Bool = true) -> PlayerDockMotion.MiniAxis {
            PlayerDockMotion.miniAxis(CGSize(width: x, height: y), pullAllowed: pull)
        }
        XCTAssertEqual(axis(10, -20), .pull)
        XCTAssertEqual(axis(-10, -20), .pull)
        XCTAssertEqual(axis(31, -20), .swipe)
        XCTAssertEqual(axis(5, 20), .scroll)
        XCTAssertEqual(axis(10, -20, pull: false), .scroll, "a pull the app doesn't allow is the page's scroll")
    }

    func testAReleasedPullOpensAboveHalfWayUnlessFlickedBack() {
        func release(offset: CGFloat, release: CGFloat = 0, average: CGFloat = 0) -> (opens: Bool, velocity: CGFloat) {
            PlayerDockMotion.pullRelease(offset: offset, travel: travel, releaseVelocity: release, averageVelocity: average)
        }
        XCTAssertTrue(release(offset: 300).opens)
        XCTAssertFalse(release(offset: 500).opens)
        XCTAssertFalse(release(offset: 720, release: 500).opens, "a flick down from 10% open closes")
        XCTAssertTrue(release(offset: 100, release: 500, average: -700).opens, "the faster of the two speeds decides")
        let lifted = release(offset: 600, release: 0, average: -600)
        XCTAssertTrue(lifted.opens, "a zero lift-off speed doesn't hide a fast pull")
        XCTAssertEqual(lifted.velocity, -600)
    }

    func testTheSpringSettlesWithoutOvershootAndStaysInsideTheUnitRange() throws {
        let threshold = 0.5 / travel
        var previous: CGFloat = 0
        var settledAt: TimeInterval?
        for frame in 0...120 {
            let elapsed = TimeInterval(frame) / 120
            let state = PlayerDockMotion.spring(from: 0, to: 1, velocity: 0, elapsed: elapsed, threshold: threshold)
            XCTAssertGreaterThanOrEqual(state.value, previous - 0.000_001, "it went back at \(elapsed) s")
            XCTAssertLessThanOrEqual(state.value, 1)
            previous = state.value
            if state.settled, settledAt == nil { settledAt = elapsed }
        }
        XCTAssertLessThan(try XCTUnwrap(settledAt), 0.8)

        for frame in 0...60 {
            let state = PlayerDockMotion.spring(from: 0.9, to: 1, velocity: 40, elapsed: TimeInterval(frame) / 60, threshold: threshold)
            XCTAssertTrue((0...1).contains(state.value))
        }
    }

    func testTheFrameHoldsAtFullyOpenWhileNotDockingAndScalesTheStageAndScrimWithTheFraction() {
        let art = MiniArt(rect: mini, corner: 8)
        var frame = DockFrame(fraction: 0.25, travel: travel, mini: art, docks: true)
        XCTAssertEqual(frame.t, 0.25)
        XCTAssertEqual(frame.stageOffset, 600, accuracy: 0.001)
        XCTAssertEqual(frame.scrim, 0.08, accuracy: 0.0001)
        frame.docks = false
        XCTAssertEqual(frame.t, 1, "without a cover to dock into nothing fades")
        XCTAssertEqual(frame.fade, 1)
        XCTAssertEqual(frame.stageOffset, 600, accuracy: 0.001, "the stage still slides")
    }

    @MainActor
    private final class Clock {
        var now: CFTimeInterval = 100
        func tick(_ dock: PlayerDock) { now += 1.0 / 60; dock.step(to: now) }
    }

    private func makeDock(reduced: @escaping @MainActor () -> Bool = { false }) -> (PlayerDock, Clock) {
        let dock = PlayerDock(reduced: reduced, drivesFrames: false)
        dock.travel = travel
        dock.reportMiniArt(MiniArt(rect: mini, corner: 8), on: .home)
        return (dock, Clock())
    }

    /// Steps until `done`, failing if it takes more than two seconds of frames.
    private func run(_ dock: PlayerDock, _ clock: Clock, until done: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<120 where !done() { clock.tick(dock) }
        XCTAssertTrue(done(), "still moving after two seconds", file: file, line: line)
    }

    func testOpeningRaisesTheCoverAtZeroAndRisesOnlyOncePlayerIsOnScreen() {
        let (dock, clock) = makeDock()
        dock.open()
        XCTAssertTrue(dock.isPresented)
        XCTAssertEqual(dock.fraction, 0)
        clock.tick(dock)
        XCTAssertEqual(dock.fraction, 0, "it moved before the player had appeared")

        dock.playerDidAppear()
        var fractions: [CGFloat] = []
        run(dock, clock, until: {
            if fractions.last != 1 { fractions.append(dock.fraction) }
            return dock.fraction == 1
        })
        XCTAssertEqual(fractions, fractions.sorted(), "an open never goes back")
        XCTAssertGreaterThan(fractions.count, 10, "it jumped instead of sliding")
    }

    func testTheTopEdgeDissolvesEarlyInEachMoveAndIsClearBeforeItLands() {
        let band = PlayerDockMotion.edgeBand(travel: travel)
        func edge(_ moved: CGFloat) -> CGFloat { PlayerDockMotion.edge(moved, travel: travel) }
        XCTAssertEqual(edge(0), 0)
        XCTAssertEqual(edge(1), 0)
        XCTAssertGreaterThan(edge(0.03), 0, "up as soon as it moves")
        XCTAssertEqual(edge(0.3), band, accuracy: 0.001)
        XCTAssertLessThan(edge(0.04), band / 6, "a small drag took the handle and caption away")
        XCTAssertLessThan(edge(0.85), band / 2, "mostly clear before it lands")
        for moved in stride(from: 0.3, to: 0.95, by: 0.05) as StrideTo<CGFloat> {
            XCTAssertEqual(edge(moved) - edge(moved + 0.05), band * 0.05 / 0.7, accuracy: 0.01,
                           "the sheet's visible edge keeps one speed up to the top, at \(moved)")
        }

        // Both ways: the band follows the move, not the position.
        let (dock, clock) = makeDock()
        dock.open()
        dock.playerDidAppear()
        run(dock, clock, until: { dock.fraction > 0.3 })
        XCTAssertGreaterThan(dock.frame(miniOn: .home).edge, band * 0.8, "opening, early on")
        run(dock, clock, until: { dock.fraction == 1 })
        XCTAssertEqual(dock.frame(miniOn: .home).edge, 0, "at rest, crisp")
        dock.close()
        run(dock, clock, until: { dock.fraction < 0.7 })
        XCTAssertGreaterThan(dock.frame(miniOn: .home).edge, band * 0.8, "closing, early on")

        // A finger's move too, whichever end it starts from.
        let (pulled, _) = makeDock()
        pulled.hold(offset: travel * 0.7)
        XCTAssertEqual(pulled.frame(miniOn: .home).edge, band, accuracy: 0.001, "pulled up 30% of the way from the mini player")
        let (dragged, draggedClock) = makeDock()
        dragged.open()
        dragged.playerDidAppear()
        run(dragged, draggedClock, until: { dragged.fraction == 1 })
        dragged.hold(offset: travel * 0.3)
        XCTAssertEqual(dragged.frame(miniOn: .home).edge, band, accuracy: 0.001, "dragged down 30% of the way from open")

        // Let go near the top: the short slide that finishes the open carries on clearing the band
        // instead of starting it over.
        let (released, releasedClock) = makeDock()
        released.hold(offset: travel * 0.05)
        let before = released.frame(miniOn: .home).edge
        released.open()
        releasedClock.tick(released)
        XCTAssertLessThanOrEqual(released.frame(miniOn: .home).edge, before + 1, "no flash on letting go")

        // Let go short, so it falls back: the band carries on from where it was and clears as it lands.
        let (short, shortClock) = makeDock()
        short.hold(offset: travel * 0.7)
        let held = short.frame(miniOn: .home).edge
        XCTAssertEqual(held, band, accuracy: 0.001, "30% of the way up: full")
        short.close()
        shortClock.tick(short)
        XCTAssertEqual(short.frame(miniOn: .home).edge, held, accuracy: band * 0.1, "no drop as it turns back")
        run(short, shortClock, until: { short.fraction < 0.05 })
        let falling = short.frame(miniOn: .home).edge
        short.hold(offset: (1 - short.fraction) * travel)
        XCTAssertEqual(short.frame(miniOn: .home).edge, falling, accuracy: band * 0.05, "caught while falling back: no pop")
        short.close()
        run(short, shortClock, until: { !short.isPresented })

        // Caught by a finger near the top of an open: still heading up, the band stays nearly clear.
        let (caught, caughtClock) = makeDock()
        caught.open()
        caught.playerDidAppear()
        run(caught, caughtClock, until: { caught.fraction > 0.95 })
        let beforeCatch = caught.frame(miniOn: .home).edge
        caught.hold(offset: (1 - caught.fraction) * travel)
        XCTAssertEqual(caught.frame(miniOn: .home).edge, beforeCatch, accuracy: band * 0.05, "no jump at the catch")

        // A close from fully open is a new trip, not a turn back: the band comes up as usual.
        let (fresh, freshClock) = makeDock()
        fresh.open()
        fresh.playerDidAppear()
        run(fresh, freshClock, until: { fresh.fraction == 1 })
        fresh.close()
        run(fresh, freshClock, until: { fresh.fraction < 0.7 })
        XCTAssertGreaterThan(fresh.frame(miniOn: .home).edge, band * 0.8)
    }

    func testALetGoNearTheTopSettlesOverFramesInsteadOfJumping() {
        let (dock, clock) = makeDock()
        dock.hold(offset: travel * 0.02)
        let before = dock.fraction
        dock.open(velocity: -5000)   // the spike a finger hands over at lift-off
        clock.tick(dock)
        clock.tick(dock)
        XCTAssertLessThan(dock.fraction - before, (1 - before) * 0.6, "not the whole way in two frames")
        run(dock, clock, until: { dock.fraction == 1 })

        // A flick from midway keeps its speed.
        let (flicked, flickedClock) = makeDock()
        flicked.hold(offset: travel * 0.5)
        flicked.open(velocity: -2000)
        flickedClock.tick(flicked)
        flickedClock.tick(flicked)
        XCTAssertGreaterThan(flicked.fraction, 0.5 + 2000.0 / travel / 60, "carried at about the finger's speed")
    }

    func testAFingerReachingTheWindowsEdgeHasMovedThePlayerTheWholeWay() {
        // A pull up from a mini player 55 pt above the bottom: the finger at the top is fully open.
        let start = travel - 55
        XCTAssertEqual(travel + PlayerDockMotion.reach(-start, from: start, toward: 0, travel: travel), 0, accuracy: 0.001)
        // A drag down from the handle 40 pt below the top: the finger at the bottom is closed.
        XCTAssertEqual(PlayerDockMotion.reach(travel - 40, from: 40, toward: travel, travel: travel), travel, accuracy: 0.001)
        // Halfway is still about halfway, and a finger that starts at the edge is followed 1:1.
        XCTAssertEqual(PlayerDockMotion.reach(-100, from: start, toward: 0, travel: travel), -100 * travel / start, accuracy: 0.001)
        XCTAssertEqual(PlayerDockMotion.reach(-100, from: travel, toward: 0, travel: travel), -100)
    }

    func testTheEdgeBandFollowsTheWindowAndStaysReadableInShortOnes() {
        XCTAssertEqual(PlayerDockMotion.edgeBand(travel: 852), 852 * 0.21, accuracy: 0.001, "a 6.1-inch phone: about 180")
        XCTAssertEqual(PlayerDockMotion.edgeBand(travel: 393), 96, "a phone on its side keeps the floor")
        XCTAssertEqual(PlayerDockMotion.edgeBand(travel: 1366), 260, "a 12.9-inch iPad stops at the ceiling")
    }

    func testAPlayerThatMovesIsFlaggedMovingOnlyBetweenTheMiniPlayerAndOpen() {
        let (dock, clock) = makeDock()
        XCTAssertFalse(dock.isMoving)
        dock.open()
        dock.playerDidAppear()
        clock.tick(dock)
        clock.tick(dock)
        XCTAssertTrue(dock.isMoving)
        run(dock, clock, until: { dock.fraction == 1 })
        XCTAssertFalse(dock.isMoving)
        dock.close()
        clock.tick(dock)
        clock.tick(dock)
        XCTAssertTrue(dock.isMoving)
        run(dock, clock, until: { !dock.isPresented })
        XCTAssertFalse(dock.isMoving)
    }

    func testClosingTwiceRunsOneSlideAndDropsTheCoverOnlyOnceTheMiniPlayerIsReached() {
        let (dock, clock) = makeDock()
        dock.open()
        dock.playerDidAppear()
        run(dock, clock, until: { dock.fraction == 1 })

        dock.close()
        clock.tick(dock)
        clock.tick(dock)
        let afterTwoFrames = dock.fraction
        dock.close()
        XCTAssertEqual(dock.fraction, afterTwoFrames, "the second close started the slide over")
        var wentWhileUp = false
        run(dock, clock, until: {
            if !dock.isPresented, dock.fraction != 0 { wentWhileUp = true }
            return !dock.isPresented
        })
        XCTAssertFalse(wentWhileUp)
        XCTAssertEqual(dock.fraction, 0)
    }

    func testClosingAPlayerThatIsNotOnTheWindowDropsTheCoverAtOnce() {
        let (dock, _) = makeDock()
        dock.open()
        XCTAssertTrue(dock.isPresented)
        dock.close()
        XCTAssertFalse(dock.isPresented, "a cover at 0 has nothing to carry down")

        let unmeasured = PlayerDock(reduced: { false }, drivesFrames: false)
        unmeasured.open()
        unmeasured.close()
        XCTAssertFalse(unmeasured.isPresented)
    }

    func testAFingerOnThePlayerStopsTheSlideAndTheReleaseTakesItFromThere() {
        let (dock, clock) = makeDock()
        dock.open()
        dock.playerDidAppear()
        run(dock, clock, until: { dock.fraction == 1 })

        dock.close()
        clock.tick(dock)
        clock.tick(dock)
        dock.hold(offset: 200)
        XCTAssertEqual(dock.fraction, 0.75, accuracy: 0.0001)
        clock.tick(dock)
        XCTAssertEqual(dock.fraction, 0.75, accuracy: 0.0001, "the slide carried on under the finger")

        dock.open(velocity: 0)
        run(dock, clock, until: { dock.fraction == 1 })
        XCTAssertTrue(dock.isPresented, "a close the finger interrupted went through anyway")
    }

    func testPullingFromTheMiniPlayerRaisesTheCoverUnderTheFingerAndAReleaseBelowHalfDocksAgain() {
        let (dock, clock) = makeDock()
        dock.hold(offset: 700)
        XCTAssertTrue(dock.isPresented)
        XCTAssertEqual(dock.fraction, 0.125, accuracy: 0.0001)
        dock.hold(offset: 500)
        XCTAssertEqual(dock.fraction, 0.375, accuracy: 0.0001)

        dock.close()
        run(dock, clock, until: { !dock.isPresented })
        XCTAssertEqual(dock.fraction, 0)
    }

    func testUnderReduceAnimationThePlayerSlidesButNothingDocksOrPulls() {
        let (dock, clock) = makeDock(reduced: { true })
        XCTAssertFalse(dock.allowsPull)
        dock.hold(offset: 700)
        XCTAssertFalse(dock.isPresented, "a pull started under Reduce animation")

        dock.open()
        dock.playerDidAppear()
        var frames = 0
        run(dock, clock, until: {
            if dock.fraction != 1 { frames += 1 }
            return dock.fraction == 1
        })
        XCTAssertLessThan(frames, 15, "Reduce animation should land near 0.2 s, not run the full spring")
        XCTAssertGreaterThan(frames, 3, "the stage didn't slide")
        let frame = dock.frame(miniOn: .home)
        XCTAssertFalse(frame.docks)
        XCTAssertEqual(frame.t, 1)
        XCTAssertFalse(dock.isMoving)
    }

    func testTurningTheWindowMidFlightKeepsTheShareOfTheWayGone() {
        let (dock, _) = makeDock()
        dock.hold(offset: 400)
        XCTAssertEqual(dock.frame(miniOn: .home).stageOffset, 400, accuracy: 0.001)
        dock.travel = 400
        XCTAssertEqual(dock.frame(miniOn: .home).stageOffset, 200, accuracy: 0.001)
    }

    func testOnlyTheSelectedTabsCoverIsTheFarEnd() {
        let (dock, _) = makeDock()
        let other = MiniArt(rect: CGRect(x: 28, y: 650, width: 40, height: 40), corner: 8)
        dock.reportMiniArt(other, on: .library)
        XCTAssertEqual(dock.frame(miniOn: .home).mini?.rect, mini)
        XCTAssertEqual(dock.frame(miniOn: .library).mini?.rect, other.rect)
    }
}

extension PlayerDockTests {
    func testAHoldTheGestureNeverReleasedDocksTheCoverAndADecidedReleaseIsLeftAlone() {
        let (dock, clock) = makeDock()
        dock.hold(offset: 700)
        XCTAssertTrue(dock.isPresented)
        dock.abandonHold()
        run(dock, clock, until: { !dock.isPresented })

        dock.hold(offset: 300)
        dock.open()
        dock.abandonHold()
        dock.playerDidAppear()
        run(dock, clock, until: { dock.fraction == 1 })
        XCTAssertTrue(dock.isPresented, "a released open was undone by the cancel fallback")
    }
}

extension PlayerDockTests {
    private func frame(_ fraction: CGFloat, docks: Bool = true) -> DockFrame {
        DockFrame(fraction: fraction, travel: travel, mini: MiniArt(rect: mini, corner: 8), docks: docks)
    }

    private static let surfaces: [(name: String, shape: ArtworkShape)] = [
        ("card", ArtworkShape(corner: 8, castsShadow: true)),
        ("thumb", ArtworkShape(corner: 6, castsShadow: true)),
        ("landscape", ArtworkShape(corner: 10, castsShadow: true)),
        ("banner", ArtworkShape(corner: 0, castsShadow: false, dissolves: true)),
    ]

    func testAtFullyOpenTheArtworkIsItsRestLookOnEverySurfaceDockingOrNot() {
        let pose = ArtworkPose(scale: 0.86, offset: CGSize(width: 12, height: -9))
        for (name, shape) in Self.surfaces {
            let rest = frame(1, docks: false).artwork(open: open, shape: shape, pose: pose)
            let docked = frame(1).artwork(open: open, shape: shape, pose: pose)
            XCTAssertEqual(docked, rest, name)
            XCTAssertEqual(rest.rect, open, name)
            XCTAssertEqual(rest.corner, shape.dissolves ? 0 : shape.corner, name)
            XCTAssertEqual(rest.shadow, shape.castsShadow ? 1 : 0, name)
            XCTAssertEqual(rest.dissolve, shape.dissolves ? 1 : 0, name)
            XCTAssertEqual(rest.scale, 0.86, name)
            XCTAssertEqual(rest.offset, pose.offset, name)
        }
    }

    func testOnTheMiniPlayerTheArtworkIsTheCoverAndNeverPassesBelowIt() {
        for (name, shape) in Self.surfaces {
            let start = frame(0).artwork(open: open, shape: shape, pose: ArtworkPose(scale: 0.86, offset: CGSize(width: 12, height: -9)))
            XCTAssertEqual(start.rect, mini, name)
            XCTAssertEqual(start.corner, 8, name)
            XCTAssertEqual(start.shadow, 0, name)
            XCTAssertEqual(start.scale, 1, name)
            XCTAssertEqual(start.offset, .zero, name)
            for step in 0...100 {
                let placed = frame(CGFloat(step) / 100).artwork(open: open, shape: shape, pose: .rest)
                XCTAssertLessThanOrEqual(placed.rect.minY, mini.minY + 0.001, "\(name) went below the cover at \(step)%")
            }
        }
    }

    func testThePausedShrinkAndTheNudgeAreBlendedInByTheFraction() {
        let pose = ArtworkPose(scale: 0.8, offset: CGSize(width: 20, height: -10))
        let half = frame(0.5).artwork(open: open, shape: Self.surfaces[0].shape, pose: pose)
        XCTAssertEqual(half.scale, 0.9, accuracy: 0.0001)
        XCTAssertEqual(half.offset.width, 10, accuracy: 0.0001)
        XCTAssertEqual(half.offset.height, -5, accuracy: 0.0001)
    }

    func testTheBannerFirmsUpIntoACardAsItDocks() {
        let banner = ArtworkShape(corner: 0, castsShadow: true, dissolves: true)
        let half = frame(0.5).artwork(open: open, shape: banner, pose: .rest)
        XCTAssertEqual(half.dissolve, 0.5, accuracy: 0.0001)
        XCTAssertEqual(half.shadow, 0, accuracy: 0.0001, "a banner casts none until it is mostly a card")
        XCTAssertEqual(frame(0.25).artwork(open: open, shape: banner, pose: .rest).shadow, 0.125, accuracy: 0.0001)
    }

    func testTheRestOfThePlayerNeverFadesToNothingSoItKeepsReportingItsLayout() {
        XCTAssertEqual(frame(0).fade, 1.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(frame(0.575).fade, 0.5, accuracy: 0.0001)
    }

    func testADockedPlayerWaitsOnScreenInvisibleButAPlainOneStartsBelowTheWindow() {
        XCTAssertEqual(frame(0).stageOffset, 0, "parked below the window it gets no layout")
        XCTAssertEqual(frame(0, docks: false).stageOffset, travel, "a plain slide must not flash")
        XCTAssertEqual(frame(0.01).stageOffset, 792, accuracy: 0.001)
    }

    func testWithoutACoverToDockIntoTheArtworkRidesThePlayersOwnSlide() {
        let placed = frame(0.25, docks: false).artwork(open: open, shape: Self.surfaces[0].shape, pose: .rest)
        XCTAssertEqual(placed.rect, open.offsetBy(dx: 0, dy: 600))
        XCTAssertEqual(placed.corner, 8)
    }

    func testABannerThatSettlesMidFlightSwapsInOnlyAtRest() {
        let (dock, clock) = makeDock()
        dock.open()
        dock.reportBanner(false)
        dock.playerDidAppear()
        clock.tick(dock)
        clock.tick(dock)
        dock.reportBanner(true)
        XCTAssertFalse(dock.isBanner(live: true), "the banner swapped in under a flying sleeve")
        run(dock, clock, until: { dock.fraction == 1 })
        XCTAssertTrue(dock.isBanner(live: true))
        XCTAssertFalse(dock.isBanner(live: false))

        // The close that follows starts from the banner on screen, not the sleeve latched before.
        dock.close()
        clock.tick(dock)
        clock.tick(dock)
        XCTAssertTrue(dock.isMoving)
        XCTAssertTrue(dock.isBanner(live: true), "the close snapped the banner to the sleeve")
        dock.reportBanner(true)   // what the player reports as the trip starts
        dock.reportBanner(false)  // and a change mid-trip is held off
        XCTAssertTrue(dock.isBanner(live: false))
    }

    func testTheBannerRisesOverThePlayerOnlyOnceThePlayerHasFadedOut() {
        let (dock, _) = makeDock()
        dock.hold(offset: travel * 0.95)
        XCTAssertTrue(dock.bannerOverPlayer, "the player is invisible here")
        for held in [0.2, 0.5, 0.9, 0.99] as [CGFloat] {
            dock.hold(offset: travel * (1 - held))
            XCTAssertTrue(dock.isMoving)
            XCTAssertFalse(dock.bannerOverPlayer, "the handle and scrim vanished at \(held)")
        }
        dock.hold(offset: 0)
        XCTAssertFalse(dock.bannerOverPlayer)
    }

    func testTheBannersClipIsOverItsStillOnlyNearTheMiniCover() {
        XCTAssertEqual(PlayerDockMotion.clipFade(0.05), 0)
        XCTAssertGreaterThan(PlayerDockMotion.clipFade(0.1), 0)
        XCTAssertEqual(PlayerDockMotion.clipFade(0.2), 1, accuracy: 0.0001, "a double exposure across the trip")
        XCTAssertEqual(PlayerDockMotion.clipFade(1), 1)
    }

    func testTheArtworksSizeLeavesItsRestWithNoSpeed() {
        func width(_ t: CGFloat) -> CGFloat { PlayerDockMotion.rect(open: open, mini: mini, t: t, travel: travel).width }
        XCTAssertEqual(width(1), open.width)
        XCTAssertEqual(width(0), mini.width)
        XCTAssertLessThan(open.width - width(0.95), 0.003 * open.width, "an inset card as soon as the sheet moved")
        for step in 1...100 {
            XCTAssertGreaterThanOrEqual(width(CGFloat(step) / 100), width(CGFloat(step - 1) / 100))
        }
    }

    func testTheNerdStatsAreDrawnOnlyWhereTheyAreWhileTheArtworkFliesAway() {
        XCTAssertFalse(frame(0.5).showsStats, "the stats hung at the open place while the sleeve flew to the mini cover")
        XCTAssertFalse(frame(0).showsStats)
        XCTAssertTrue(frame(1).showsStats)
        XCTAssertTrue(frame(0.5, docks: false).showsStats, "a plain slide carries the stats with the artwork")
    }

    func testTheCoverStandsAsideOnlyOnceThePlayerIsOnScreenAndAwayFromTheMiniPlayer() {
        let (dock, clock) = makeDock()
        XCTAssertFalse(dock.coversMiniArt)
        dock.open()
        XCTAssertFalse(dock.coversMiniArt, "at fraction 0 the cover is the artwork")
        dock.playerDidAppear()
        clock.tick(dock)
        XCTAssertFalse(dock.coversMiniArt)
        clock.tick(dock)
        XCTAssertTrue(dock.coversMiniArt)
        run(dock, clock, until: { dock.fraction == 1 })
        dock.close()
        run(dock, clock, until: { !dock.isPresented })
        XCTAssertFalse(dock.coversMiniArt)

        let pulled = makeDock().0
        pulled.hold(offset: 400)
        XCTAssertFalse(pulled.coversMiniArt, "a pull before the player is attached left a hole")
        pulled.playerDidAppear()
        XCTAssertTrue(pulled.coversMiniArt)

        let (calm, _) = makeDock(reduced: { true })
        calm.open()
        calm.playerDidAppear()
        XCTAssertFalse(calm.coversMiniArt, "Reduce animation never hides the cover")
    }

    func testADragOnTheOpenPlayerThatTheSystemCancelsSettlesBackOpen() {
        let (dock, clock) = makeDock()
        dock.open()
        dock.playerDidAppear()
        run(dock, clock, until: { dock.fraction == 1 })

        dock.hold(offset: 300)
        XCTAssertEqual(dock.fraction, 0.625, accuracy: 0.0001)
        dock.abandonHold(settlingOpen: true)
        run(dock, clock, until: { dock.fraction == 1 })
        XCTAssertTrue(dock.isPresented)

        dock.hold(offset: 0)
        dock.open(velocity: 0)
        dock.abandonHold(settlingOpen: true)
        XCTAssertEqual(dock.fraction, 1, "a decided release was undone by the cancel fallback")
    }
}
