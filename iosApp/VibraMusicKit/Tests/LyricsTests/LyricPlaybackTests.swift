import XCTest
@testable import Lyrics

/// The frame clock against delayed position reports (ported from Android's `LyricClockTest`).
final class LyricClockTests: XCTestCase {

    func testDelayedPollDoesNotReactivatePreviousLine() {
        var clock = LyricClockReconciler(initialReportedMs: 9_500, initialObservedAtMs: 0, initialPlaying: true)
        // A line starts at 10 seconds; rendering already crossed its boundary before a
        // delayed position report arrived.
        let reconciled = clock.reconcile(displayedMs: 10_018, reportedMs: 9_985, observedAtMs: 500, isPlaying: true)
        XCTAssertEqual(reconciled, 10_018)
        XCTAssertEqual([0, 10_000].lastIndex { $0 <= reconciled }, 1)
    }

    func testDelayedReportsNeverMoveWordsOrLinesBackwards() {
        let lineStarts = [44_754, 48_000, 51_104, 54_158]
        var clock = LyricClockReconciler(initialReportedMs: 44_500, initialObservedAtMs: 0, initialPlaying: true)
        var displayed = 44_500
        var previousLine = 0
        // Position samples are occasionally delivered several hundred milliseconds late.
        let reports = [
            (500, 44_980, 45_080), (1_000, 45_470, 45_690), (3_500, 47_930, 48_180),
            (4_000, 48_430, 48_790), (6_500, 50_900, 51_240), (9_500, 53_900, 54_260),
        ]
        for (observedAt, report, rendered) in reports {
            displayed = max(displayed, rendered)
            displayed = clock.reconcile(displayedMs: displayed, reportedMs: report, observedAtMs: observedAt, isPlaying: true)
            let line = lineStarts.lastIndex { $0 <= displayed } ?? -1
            XCTAssertGreaterThanOrEqual(line, previousLine)
            previousLine = line
        }
    }

    func testBackwardSeekResetsImmediately() {
        var clock = LyricClockReconciler(initialReportedMs: 9_500, initialObservedAtMs: 0, initialPlaying: true)
        XCTAssertEqual(clock.reconcile(displayedMs: 10_018, reportedMs: 4_000, observedAtMs: 500, isPlaying: true), 4_000)
    }

    func testForwardSeekResetsImmediately() {
        var clock = LyricClockReconciler(initialReportedMs: 9_500, initialObservedAtMs: 0, initialPlaying: true)
        XCTAssertEqual(clock.reconcile(displayedMs: 10_018, reportedMs: 20_000, observedAtMs: 500, isPlaying: true), 20_000)
    }

    func testPollAheadOfDisplayCatchesUp() {
        var clock = LyricClockReconciler(initialReportedMs: 9_500, initialObservedAtMs: 0, initialPlaying: true)
        XCTAssertEqual(clock.reconcile(displayedMs: 10_018, reportedMs: 10_050, observedAtMs: 500, isPlaying: true), 10_050)
    }

    func testPausedClockAcceptsASeekWithoutWaitingForFrames() {
        var clock = LyricClockReconciler(initialReportedMs: 10_000, initialObservedAtMs: 0, initialPlaying: false)
        XCTAssertEqual(clock.reconcile(displayedMs: 10_000, reportedMs: 30_000, observedAtMs: 250, isPlaying: false), 30_000)
    }

    /// A player says it is playing before its clock moves: the words wait for the clock.
    func testAPlayerThatHasNotMovedYetIsNotAdvancing() {
        var clock = LyricClockReconciler(initialReportedMs: 0, initialObservedAtMs: 0, initialPlaying: false)
        XCTAssertEqual(clock.reconcile(displayedMs: 0, reportedMs: 0, observedAtMs: 10, isPlaying: true), 0)
        XCTAssertFalse(clock.isAdvancing)
        XCTAssertEqual(clock.reconcile(displayedMs: 0, reportedMs: 250, observedAtMs: 2_000, isPlaying: true), 250)
        XCTAssertTrue(clock.isAdvancing)
    }

    func testASeekWaitsForThePlayerToMoveAgain() {
        var clock = LyricClockReconciler(initialReportedMs: 9_500, initialObservedAtMs: 0, initialPlaying: true)
        XCTAssertEqual(clock.reconcile(displayedMs: 10_018, reportedMs: 40_000, observedAtMs: 500, isPlaying: true), 40_000)
        XCTAssertFalse(clock.isAdvancing)
        XCTAssertEqual(clock.reconcile(displayedMs: 40_000, reportedMs: 40_250, observedAtMs: 950, isPlaying: true), 40_250)
        XCTAssertTrue(clock.isAdvancing)
    }

    /// Lyrics opened mid-song, and a resume: the player's clock is known to run.
    func testAPlayerAlreadyMovingAdvancesAtOnce() {
        var clock = LyricClockReconciler(initialReportedMs: 9_500, initialObservedAtMs: 0, initialPlaying: true)
        XCTAssertTrue(clock.isAdvancing)
        _ = clock.reconcile(displayedMs: 9_600, reportedMs: 9_600, observedAtMs: 100, isPlaying: false)
        XCTAssertFalse(clock.isAdvancing, "paused")
        _ = clock.reconcile(displayedMs: 9_600, reportedMs: 9_600, observedAtMs: 3_000, isPlaying: true)
        XCTAssertTrue(clock.isAdvancing, "resumed")
    }

    func testPausingSettlesAFrameClockThatWasSlightlyAhead() {
        var clock = LyricClockReconciler(initialReportedMs: 10_000, initialObservedAtMs: 0, initialPlaying: true)
        XCTAssertEqual(clock.reconcile(displayedMs: 10_650, reportedMs: 10_400, observedAtMs: 400, isPlaying: false), 10_400)
    }
}

/// Which rows stay lit when vocals overlap (ported from Android's `LyricFocusTest`).
final class LyricFocusTests: XCTestCase {
    private let overlap = [
        LyricLine(timeMs: 1_000, text: "upper", sungUntilMs: 4_000),
        LyricLine(timeMs: 2_000, text: "middle", sungUntilMs: 5_000),
        LyricLine(timeMs: 3_000, text: "lower", sungUntilMs: 6_000),
    ]

    func testUpperLineKeepsAnchorAcrossThreeOverlappingVocals() {
        XCTAssertEqual(LyricFocus.activeRows(overlap, positionMs: 3_500), [0, 1, 2])
    }

    func testAnchorAdvancesExactlyWhenUpperVocalEnds() {
        XCTAssertEqual(LyricFocus.activeRows(overlap, positionMs: 4_000), [1, 2])
        XCTAssertEqual(LyricFocus.activeRows(overlap, positionMs: 5_000), [2])
    }

    func testFinishedMiddleRowDoesNotCutOffLongUpperVocal() {
        var lines = overlap
        lines[1].sungUntilMs = 2_900
        XCTAssertEqual(LyricFocus.activeRows(lines, positionMs: 3_500), [0, 2])
    }

    func testBackgroundVocalKeepsItsParentRowAnchored() {
        let lines = [
            LyricLine(timeMs: 1_000, text: "lead", sungUntilMs: 1_900, background: LyricLine(timeMs: 1_500, text: "echo", sungUntilMs: 3_000)),
            LyricLine(timeMs: 2_000, text: "next", sungUntilMs: 4_000),
        ]
        XCTAssertEqual(LyricFocus.activeRows(lines, positionMs: 2_500), [0, 1])
        XCTAssertEqual(LyricFocus.activeRows(lines, positionMs: 3_000), [1])
    }

    func testPlainLRCAdvancesWithoutInventingAnOverlap() {
        let lines = overlap.map { line -> LyricLine in
            var copy = line
            copy.sungUntilMs = nil
            return copy
        }
        XCTAssertEqual(LyricFocus.activeRows(lines, positionMs: 2_500), [1])
    }

    func testBackwardSeekRecomputesTheAnchor() {
        XCTAssertEqual(LyricFocus.activeRows(overlap, positionMs: 5_500), [2])
        XCTAssertEqual(LyricFocus.activeRows(overlap, positionMs: 1_500), [0])
        XCTAssertEqual(LyricFocus.activeRows(overlap, positionMs: 500), [])
    }

    func testTheScrollRunUpIsTheSilenceBeforeTheNextLineBounded() {
        let lines = [
            LyricLine(timeMs: 1_000, text: "a", sungUntilMs: 1_600),
            LyricLine(timeMs: 2_000, text: "b", sungUntilMs: 2_990),
            LyricLine(timeMs: 3_000, text: "c", sungUntilMs: 3_100),
            LyricLine(timeMs: 9_000, text: "d"),
        ]
        XCTAssertEqual(LyricFocus.scrollLeadMs(lines, positionMs: 1_200), 400)
        XCTAssertEqual(LyricFocus.scrollLeadMs(lines, positionMs: 2_200), 350)
        XCTAssertEqual(LyricFocus.scrollLeadMs(lines, positionMs: 3_200), 500)
        // Before the first line, and on the last, there is nothing to measure.
        XCTAssertEqual(LyricFocus.scrollLeadMs(lines, positionMs: 0), 350)
        XCTAssertEqual(LyricFocus.scrollLeadMs(lines, positionMs: 9_500), 350)
        XCTAssertEqual(LyricFocus.currentIndex(lines, positionMs: 2_500), 1)
    }
}

/// The lyrics offset sheet's arithmetic (ported from Android's `LyricsOffsetTest`).
final class LyricsOffsetTests: XCTestCase {

    func testPositiveOffsetDelaysLyrics() {
        XCTAssertEqual(LyricsOffset.adjustedPosition(positionMs: 10_000, offsetMs: 1_500), 8_500)
    }

    func testNegativeOffsetAdvancesLyrics() {
        XCTAssertEqual(LyricsOffset.adjustedPosition(positionMs: 10_000, offsetMs: -1_500), 11_500)
    }

    func testOffsetNeverProducesANegativeLyricClock() {
        XCTAssertEqual(LyricsOffset.adjustedPosition(positionMs: 500, offsetMs: 1_500), 0)
    }

    func testSeekingALyricIncludesItsOffset() {
        XCTAssertEqual(LyricsOffset.seekTarget(lineTimeMs: 10_000, offsetMs: 1_500), 11_500)
        XCTAssertEqual(LyricsOffset.seekTarget(lineTimeMs: 10_000, offsetMs: -1_500), 8_500)
    }

    /// PORTING.md's done-test: +500 ms moves the highlight later.
    func testPlusFiveHundredMillisecondsMovesTheHighlightLater() {
        let lines = [LyricLine(timeMs: 0, text: "a"), LyricLine(timeMs: 10_000, text: "b")]
        let position = 10_200
        XCTAssertEqual(LyricFocus.currentIndex(lines, positionMs: LyricsOffset.adjustedPosition(positionMs: position, offsetMs: 0)), 1)
        // With +500 the line lights 500 ms later: at 10.2 s it is still on the first line…
        XCTAssertEqual(LyricFocus.currentIndex(lines, positionMs: LyricsOffset.adjustedPosition(positionMs: position, offsetMs: 500)), 0)
        // …and moves on at 10.5 s.
        XCTAssertEqual(LyricFocus.currentIndex(lines, positionMs: LyricsOffset.adjustedPosition(positionMs: 10_500, offsetMs: 500)), 1)
    }

    func testTheButtonsStepByATenthOfASecondWithinFiveSeconds() {
        XCTAssertEqual(LyricsOffset.increased(0), 100)
        XCTAssertEqual(LyricsOffset.decreased(0), -100)
        XCTAssertEqual(LyricsOffset.increased(5_000), 5_000)
        XCTAssertEqual(LyricsOffset.decreased(-5_000), -5_000)
        XCTAssertFalse(LyricsOffset.canIncrease(5_000))
        XCTAssertFalse(LyricsOffset.canDecrease(-5_000))
        XCTAssertTrue(LyricsOffset.canIncrease(0))
    }

    func testTheSliderSnapsToSteps() {
        XCTAssertEqual(LyricsOffset.fraction(forOffset: 0), 0.5, accuracy: 0.0001)
        XCTAssertEqual(LyricsOffset.fraction(forOffset: -5_000), 0, accuracy: 0.0001)
        XCTAssertEqual(LyricsOffset.offset(forFraction: 0.5), 0)
        XCTAssertEqual(LyricsOffset.offset(forFraction: 1), 5_000)
        XCTAssertEqual(LyricsOffset.offset(forFraction: 2), 5_000)
        XCTAssertEqual(LyricsOffset.offset(forFraction: 0.5123), 100)
        XCTAssertEqual(LyricsOffset.offset(forFraction: 0.5049), 0)
    }

    func testTheReadoutAlwaysShowsItsSign() {
        let posix = Locale(identifier: "en_US_POSIX")
        XCTAssertEqual(LyricsOffset.formatted(500, locale: posix), "+0.5 s")
        XCTAssertEqual(LyricsOffset.formatted(-1_200, locale: posix), "-1.2 s")
        XCTAssertEqual(LyricsOffset.formatted(0, locale: posix), "+0.0 s")
    }
}
