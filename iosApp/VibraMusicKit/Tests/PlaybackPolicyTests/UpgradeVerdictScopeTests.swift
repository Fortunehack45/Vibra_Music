import XCTest
@testable import PlaybackPolicy

/// How long an upgrade verdict is allowed to stand (ports QualityUpgradeScopeTest).
///
/// `asked` records that a track has had its second look, so the cached-track path stops offering a
/// track already dealt with. That is the right scope *within one playback* and the wrong one across
/// two: the upgraded bytes live under their own rendition key and the marked URI goes with the queue
/// entry that carried it, so the next play of the same song reads the base cache entry — YouTube's
/// copy — while the previous play's verdict says the question is settled.
///
/// Measured on a device, same process, one session:
///
///     23:38:28  substituted: 'Gehra Hua' … over YouTube at Dolby Atmos
///     23:44:07  TIMING track selected: i1o1p_DD6TU (reason=3)   ← Opus, and no lookup at all
final class UpgradeVerdictScopeTests: XCTestCase {
    private let mediaId = "i1o1p_DD6TU"
    private var upgrade: QualityUpgrade!

    override func setUp() {
        super.setUp()
        upgrade = .testInstance()
    }

    func testAFreshPlayReopensAVerdictReachedOnThePreviousOne() {
        upgrade.markAnsweredForTest(mediaId)
        XCTAssertTrue(upgrade.hasAnswered(mediaId))

        // The item a listener gets by queueing the song again: no marker on it, because the marked
        // URI belonged to the entry that was swapped.
        upgrade.onPlaybackStarted(mediaId, rendition: nil)

        XCTAssertFalse(
            upgrade.hasAnswered(mediaId),
            "a second play reads the base cache entry, so last play's yes does not describe it"
        )
    }

    /// The upgraded item itself must not re-open the question — that would have the swap that just
    /// happened searched for all over again.
    func testTheUpgradedItemDoesNotReopenItsOwnVerdict() {
        upgrade.markAnsweredForTest(mediaId)

        upgrade.onPlaybackStarted(mediaId, rendition: "hifi")

        XCTAssertTrue(upgrade.hasAnswered(mediaId))
    }

    /// A hand-reverted track is playing `q=original`, which is equally not a fresh copy.
    func testARevertedItemDoesNotReopenItsOwnVerdictEither() {
        upgrade.markAnsweredForTest(mediaId)

        upgrade.onPlaybackStarted(mediaId, rendition: "original")

        XCTAssertTrue(upgrade.hasAnswered(mediaId))
    }

    /// One track's replay says nothing about another's.
    func testReopeningOneTrackLeavesTheRestAlone() {
        upgrade.markAnsweredForTest(mediaId)
        upgrade.markAnsweredForTest("other")

        upgrade.onPlaybackStarted(mediaId, rendition: nil)

        XCTAssertFalse(upgrade.hasAnswered(mediaId))
        XCTAssertTrue(upgrade.hasAnswered("other"))
    }

    /// The rendition a caller passes comes off the item's URI; an ordinary entry has none.
    func testRenditionIsReadOffThePlaybackURI() {
        XCTAssertNil(QualityUpgrade.cacheTag("vibramusic://watch?v=\(mediaId)&n=Gehra%20Hua"))
        XCTAssertEqual(QualityUpgrade.cacheTag("vibramusic://watch?v=\(mediaId)&q=hifi-2"), "hifi-2")
        XCTAssertEqual(QualityUpgrade.cacheTag("vibramusic://watch?v=\(mediaId)&direct_youtube=1&q=original"), "original")
    }
}
