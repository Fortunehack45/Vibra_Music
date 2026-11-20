import XCTest
import VibraMusicCore
@testable import PlaybackQueue

/// Ports QueueSectionsTest (where the AutoPlay section begins) and adds the queue panel's model:
/// the sections, their headings, row identity and the drag rule.
final class QueueSectionsTests: XCTestCase {

    /// `.` is a track the user queued, `~` one AutoPlay did.
    private func start(_ queue: String, currentIndex: Int) -> Int {
        QueueSections.autoplaySectionStart(fromAutoplay: queue.map { $0 == "~" }, currentIndex: currentIndex)
    }

    func testTheSectionStartsWhereAutoplaysTracksDo() {
        XCTAssertEqual(start("...~~~", currentIndex: 0), 3)
    }

    func testAQueueWithNothingFromAutoplayHasTheSectionAtItsEnd() {
        XCTAssertEqual(start("....", currentIndex: 1), 4)
    }

    func testAutoplayTracksAlreadyPlayedSitAboveTheSectionNotInIt() {
        XCTAssertEqual(start("..~~~~", currentIndex: 4), 5)
    }

    func testTheSectionClosesTheQueueOnceTheMixIsOnItsLastTrack() {
        XCTAssertEqual(start("..~~", currentIndex: 3), 4)
    }

    func testATrackPutInByHandMidMixStaysAboveTheSection() {
        XCTAssertEqual(start("~~~.~~", currentIndex: 2), 4)
    }

    func testAnEmptyQueueHasNowhereForTheSectionButTheTop() {
        XCTAssertEqual(start("", currentIndex: 0), 0)
        XCTAssertEqual(start("", currentIndex: -1), 0)
    }

    // MARK: The panel's model

    private var mixedQueue: [Song] {
        [
            testSong("h0", entryId: "e-h0"),
            testSong("now", entryId: "e-now", source: "Abbey Road"),
            testSong("u1", tier: .userQueue, entryId: "e-u1"),
            testSong("c1", entryId: "e-c1", source: "Abbey Road"),
            testSong("u2", tier: .userQueue, entryId: "e-u2"),
            testSong("a1", tier: .autoplay, entryId: "e-a1"),
            testSong("c2", entryId: "e-c2"),
        ]
    }

    func testRowsSplitIntoNowPlayingAndSectionsWithoutHistory() {
        let sections = QueueSections(queue: mixedQueue, currentIndex: 1)
        XCTAssertEqual(sections.nowPlaying?.song.videoId, "now")
        XCTAssertEqual(sections.user.map(\.song.videoId), ["u1", "u2"])
        XCTAssertEqual(sections.context.map(\.song.videoId), ["c1", "c2"])
        XCTAssertEqual(sections.autoplay.map(\.song.videoId), ["a1"])
        XCTAssertEqual(sections.user.map(\.timelineIndex), [2, 4])
        XCTAssertEqual(sections.nowPlaying?.key, "np_e-now")
        XCTAssertEqual(sections.user.first?.key, "user_e-u1")
        XCTAssertTrue(sections.canClearUserQueue)
        XCTAssertEqual(QueueSections(queue: mixedQueue, currentIndex: 9), .empty)
    }

    func testRowsWithoutEntryIdsAreKeyedByOccurrenceNotPosition() {
        let queue = [testSong("x"), testSong("y"), testSong("x"), testSong("x")]
        let sections = QueueSections(queue: queue, currentIndex: 0)
        XCTAssertEqual(sections.nowPlaying?.key, "np_x#0")
        XCTAssertEqual(sections.context.map(\.key), ["context_y#0", "context_x#1", "context_x#2"])
        XCTAssertEqual(Set(sections.context.map(\.id)).count, 3)
    }

    func testTheContextHeadingNamesTheFirstContextRowsSourceThenFallsBack() {
        XCTAssertEqual(QueueSections(queue: mixedQueue, currentIndex: 1).contextTitle, "Abbey Road")
        let albumOnly = [testSong("now"), testSong("c1", album: "Revolver")]
        XCTAssertEqual(QueueSections(queue: albumOnly, currentIndex: 0).contextTitle, "Revolver")
        let fromPlaying = [testSong("now", source: "Liked Music"), testSong("c1", source: " ")]
        XCTAssertEqual(QueueSections(queue: fromPlaying, currentIndex: 0).contextTitle, "Liked Music")
        XCTAssertNil(QueueSections(queue: [testSong("now")], currentIndex: 0).contextTitle)
    }

    func testTheAutoplayHeadingShowsWhileOnOrWhileItsTracksRemain() {
        let none = QueueSections(queue: [testSong("now")], currentIndex: 0)
        XCTAssertTrue(none.showsAutoplaySection(autoplayEnabled: true))
        XCTAssertFalse(none.showsAutoplaySection(autoplayEnabled: false))
        XCTAssertTrue(QueueSections(queue: mixedQueue, currentIndex: 1).showsAutoplaySection(autoplayEnabled: false))
    }

    func testADragNeverLeavesItsOwnSection() {
        let sections = QueueSections(queue: mixedQueue, currentIndex: 1)
        XCTAssertTrue(sections.canMove(from: 2, to: 4), "within the user queue")
        XCTAssertTrue(sections.canMove(from: 6, to: 3), "within the context")
        XCTAssertFalse(sections.canMove(from: 2, to: 3), "user queue into context")
        XCTAssertFalse(sections.canMove(from: 1, to: 2), "the playing row doesn't move")
        XCTAssertFalse(sections.canMove(from: 0, to: 2), "history isn't listed")
        XCTAssertFalse(sections.canMove(from: 5, to: 5))
    }

    // MARK: Queue history (port of QueueHistoryDisplayTest / QueueKeyUniquenessTest)

    func testHistoryHiddenByDefaultWithoutChangingUpcomingSections() {
        let queue = [testSong("old"), testSong("current"), testSong("manual", tier: .userQueue),
                     testSong("album"), testSong("radio", tier: .autoplay)]
        let hidden = QueueSections(queue: queue, currentIndex: 1)
        let visible = QueueSections(queue: queue, currentIndex: 1, showHistory: true)
        XCTAssertTrue(hidden.history.isEmpty)
        XCTAssertEqual(visible.history.map(\.timelineIndex), [0])
        XCTAssertEqual(hidden.nowPlaying, visible.nowPlaying)
        XCTAssertEqual(hidden.user, visible.user)
        XCTAssertEqual(hidden.context, visible.context)
        XCTAssertEqual(hidden.autoplay, visible.autoplay)
    }

    func testWalkingHistory() {
        let queue = [testSong("a"), testSong("b"), testSong("c")]
        XCTAssertEqual(QueueSections(queue: queue, currentIndex: 2, showHistory: true).history.map(\.song.videoId), ["a", "b"])
        let back = QueueSections(queue: queue, currentIndex: 1, showHistory: true)
        XCTAssertEqual(back.history.map(\.song.videoId), ["a"])
        XCTAssertEqual(back.nowPlaying?.song.videoId, "b")
        XCTAssertEqual(back.context.map(\.timelineIndex), [2])
    }

    func testEmptyInvalidAndFirstSongQueuesHaveNoHistory() {
        XCTAssertTrue(QueueSections(queue: [], currentIndex: 0, showHistory: true).history.isEmpty)
        XCTAssertTrue(QueueSections(queue: [testSong("a")], currentIndex: -1, showHistory: true).history.isEmpty)
        XCTAssertTrue(QueueSections(queue: [testSong("a")], currentIndex: 1, showHistory: true).history.isEmpty)
        XCTAssertTrue(QueueSections(queue: [testSong("a")], currentIndex: 0, showHistory: true).history.isEmpty)
    }

    func testTrimmedHistoryUsesNewTimelineIndices() {
        let queue = (0..<28).map { testSong("\($0)") }
        let sections = QueueSections(queue: Array(queue.dropFirst(2)), currentIndex: 25, showHistory: true)
        XCTAssertEqual(sections.history.count, 25)
        XCTAssertEqual(sections.history.first?.song.videoId, "2")
        XCTAssertEqual(sections.history.first?.timelineIndex, 0)
        XCTAssertEqual(sections.nowPlaying?.song.videoId, "27")
    }

    func testDuplicatesHaveDistinctKeysAndRetainPlaybackIndices() {
        let queue = (0..<4).map { _ in testSong("same") }
        let sections = QueueSections(queue: queue, currentIndex: 2, showHistory: true)
        let rows = sections.history + [sections.nowPlaying!].compactMap { $0 } + sections.context
        XCTAssertEqual(rows.map(\.timelineIndex), [0, 1, 2, 3])
        XCTAssertEqual(rows.count, Set(rows.map(\.key)).count)
    }

    func testRowsSharingEntryIdStillGetDistinctKeys() {
        let queue = [testSong("now", tier: .context, entryId: "np", source: nil),
                     testSong("a", tier: .autoplay, entryId: "dup"),
                     testSong("b", tier: .autoplay, entryId: "dup"),
                     testSong("c", tier: .autoplay, entryId: "dup")]
        let keys = QueueSections(queue: queue, currentIndex: 0).autoplay.map(\.key)
        XCTAssertEqual(keys.count, Set(keys).count)
        XCTAssertEqual(keys.first, "autoplay_dup")
    }

    func testUniqueEntryIdsKeepPlainKeys() {
        let queue = [testSong("now", tier: .context, entryId: "np"),
                     testSong("a", tier: .autoplay, entryId: "x"),
                     testSong("b", tier: .autoplay, entryId: "y")]
        XCTAssertEqual(QueueSections(queue: queue, currentIndex: 0).autoplay.map(\.key), ["autoplay_x", "autoplay_y"])
    }

    func testKeysUniqueAcrossWholeSplit() {
        let queue = [testSong("now", tier: .context, entryId: "e"),
                     testSong("a", tier: .autoplay, entryId: "e"),
                     testSong("b", tier: .autoplay, entryId: "e")]
        let sections = QueueSections(queue: queue, currentIndex: 0, showHistory: true)
        let all = [sections.nowPlaying].compactMap { $0 } + sections.history + sections.user + sections.context + sections.autoplay
        XCTAssertEqual(all.count, Set(all.map(\QueueRow.key)).count)
    }

    func testAutoplayKeysWithSuffix() {
        let queue = [testSong("now", tier: .context, entryId: "np"),
                     testSong("a", tier: .autoplay, entryId: "dup"),
                     testSong("b", tier: .autoplay, entryId: "dup"),
                     testSong("c", tier: .autoplay, entryId: "dup")]
        let keys = QueueSections(queue: queue, currentIndex: 0).autoplay.map(\.key)
        XCTAssertEqual(keys, ["autoplay_dup", "autoplay_dup~1", "autoplay_dup~2"])
    }
}
