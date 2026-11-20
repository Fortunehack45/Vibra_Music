import XCTest
@testable import PlaybackQueue

/// Ports QueueEdgeScrollTest: how fast the queue list carries itself along under a row held at one
/// of its edges, so a track can be dragged across a queue longer than the screen.
final class QueueEdgeScrollTests: XCTestCase {

    /// A 600 pt viewport, a 100 pt row, and a 50 pt zone at each end of it.
    private func speed(top: Double, viewportStart: Double = 0, viewportEnd: Double = 600) -> Double {
        QueueDragAutoScroll.speed(top: top, bottom: top + 100, viewportStart: viewportStart, viewportEnd: viewportEnd, zone: 50, speed: 1000)
    }

    func testARowInTheMiddleOfTheListScrollsItNeitherWay() {
        XCTAssertEqual(speed(top: 250), 0)
    }

    func testARowClearOfTheZoneByASinglePointStillScrollsNothing() {
        XCTAssertEqual(speed(top: 51), 0)
        XCTAssertEqual(speed(top: 449), 0)
    }

    func testReachingTheTopOfTheListScrollsBackTowardsTheStart() {
        XCTAssertLessThan(speed(top: 40), 0)
    }

    func testReachingTheBottomScrollsOnTowardsTheEnd() {
        XCTAssertGreaterThan(speed(top: 460), 0)
    }

    func testTheSpeedAtTheVeryEdgeIsTheFullSpeedAskedFor() {
        XCTAssertEqual(speed(top: 0), -1000, accuracy: 0.01)
        XCTAssertEqual(speed(top: 500), 1000, accuracy: 0.01)
    }

    func testHeldPastTheEdgeItGoesNoFasterThanAtIt() {
        XCTAssertEqual(speed(top: -400), -1000, accuracy: 0.01)
        XCTAssertEqual(speed(top: 900), 1000, accuracy: 0.01)
    }

    func testARowBarelyInsideTheZoneAlreadyMovesTheList() {
        // A fifth of the top speed at the near edge of the zone rather than nothing: reaching it
        // should read as a response, not as a stall.
        let barely = speed(top: 49.5)
        XCTAssertTrue(barely <= -200 && barely > -250, "\(barely)")
    }

    func testTheRampIsEvenAcrossTheZone() {
        XCTAssertEqual(speed(top: 25), -600, accuracy: 0.01)
        XCTAssertEqual(speed(top: 475), 600, accuracy: 0.01)
    }

    func testTheZoneIsMeasuredFromTheViewportNotFromZero() {
        XCTAssertEqual(speed(top: 0, viewportStart: -200, viewportEnd: 400), 0)
        XCTAssertEqual(speed(top: -200, viewportStart: -200, viewportEnd: 400), -1000, accuracy: 0.01)
    }

    func testAViewportTooShortToClearBothEdgesScrollsNeitherWay() {
        XCTAssertEqual(speed(top: 10, viewportStart: 0, viewportEnd: 120), 0)
    }

    func testNoZoneIsNoAutoScroll() {
        XCTAssertEqual(QueueDragAutoScroll.speed(top: 0, bottom: 100, viewportStart: 0, viewportEnd: 600, zone: 0, speed: 1000), 0)
    }

    func testTheDefaultsAreTheAndroidDensityIndependentValues() {
        XCTAssertEqual(QueueDragAutoScroll.zone, 40)
        XCTAssertEqual(QueueDragAutoScroll.speed, 340)
        XCTAssertEqual(QueueDragAutoScroll.speed(top: 0, bottom: 60, viewportStart: 0, viewportEnd: 600), -340, accuracy: 0.01)
    }
}
