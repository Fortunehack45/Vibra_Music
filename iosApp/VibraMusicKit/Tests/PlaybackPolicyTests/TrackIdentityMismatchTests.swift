import XCTest
import VibraMusicCore
@testable import PlaybackPolicy

/// Playback identity preservation and duration mismatch handling (ports TrackIdentityMismatchTest).
///
/// The São Paulo (Hurry Up Tomorrow) regression: a 3:29 (209 s) YouTube music video was cached or
/// substituted for a 5:02 (302 s) album track, and the decoder's runtime poisoned the upgrade
/// search target, so the genuine album stream was rejected as a different recording.
///
/// The Android test's `TrackMatcher.withinSeconds` assertions belong to the Sources module's matcher
/// and are not repeated here; what this module owns is the duration the search is asked to match.
final class TrackIdentityMismatchTests: XCTestCase {
    func testCatalogueTarget302AndRuntime209PreservesTheCatalogueDuration() {
        XCTAssertEqual(
            QualityUpgrade.effectiveTargetDuration(expectedSec: 302, playingSec: 209),
            302,
            "the authoritative catalogue duration must be preserved when the runtime drifts severely"
        )
    }

    func testACandidateMatchingTheCatalogueDurationIsTheSameRecording() {
        XCTAssertTrue(QualityUpgrade.sameRecording(candidateSec: 302, playingSec: 302))
        XCTAssertEqual(QualityUpgrade.Target(song: Song(videoId: "x", title: "São Paulo", artist: "The Weeknd", durationText: "5:02")).durationSec, 302)
    }

    func testACachedRenditionDrifting93SecondsIsASevereMismatch() {
        XCTAssertTrue(
            QualityUpgrade.isSevereMismatch(expectedSec: 302, actualSec: 209),
            "93 s (> 30 s limit) must be flagged"
        )
    }

    func testSmallLegitimateDifferencesKeepTheRuntime() {
        // 2 s drift is common between masters.
        XCTAssertFalse(QualityUpgrade.isSevereMismatch(expectedSec: 302, actualSec: 300))
        XCTAssertEqual(QualityUpgrade.effectiveTargetDuration(expectedSec: 302, playingSec: 300), 300)

        // 14 s: a typical intro/outro pad, inside the 30 s limit.
        XCTAssertFalse(QualityUpgrade.isSevereMismatch(expectedSec: 302, actualSec: 288))
        XCTAssertEqual(QualityUpgrade.effectiveTargetDuration(expectedSec: 302, playingSec: 288), 288)

        // Exactly at the limit is still the same recording.
        XCTAssertFalse(QualityUpgrade.isSevereMismatch(expectedSec: 302, actualSec: 272))
        XCTAssertTrue(QualityUpgrade.isSevereMismatch(expectedSec: 302, actualSec: 271))
    }

    func testAMissingDurationFallsBackToWhicheverIsKnown() {
        XCTAssertFalse(QualityUpgrade.isSevereMismatch(expectedSec: nil, actualSec: 209))
        XCTAssertEqual(QualityUpgrade.effectiveTargetDuration(expectedSec: nil, playingSec: 209), 209)
        XCTAssertEqual(QualityUpgrade.effectiveTargetDuration(expectedSec: 302, playingSec: nil), 302)
        XCTAssertNil(QualityUpgrade.effectiveTargetDuration(expectedSec: nil, playingSec: nil))
    }

    func testFullSaoPauloRegressionScenario() {
        let catalogue = QualityUpgrade.Target(title: "São Paulo", artist: "The Weeknd, Anitta", durationSec: 302, album: "Hurry Up Tomorrow")
        let youTubeVideoRuntime = 209 // 3:29 music video (2kjolTLZ_Mg)
        let jioSaavnCandidate = 302 // 5:02 album stream

        XCTAssertTrue(QualityUpgrade.isSevereMismatch(expectedSec: catalogue.durationSec, actualSec: youTubeVideoRuntime))

        let effective = QualityUpgrade.effectiveTargetDuration(expectedSec: catalogue.durationSec, playingSec: youTubeVideoRuntime)
        XCTAssertEqual(effective, 302, "must preserve 302 s instead of being poisoned by 209 s")

        // Without the fix: a raw runtime comparison rejects the genuine album stream.
        XCTAssertFalse(QualityUpgrade.sameRecording(candidateSec: jioSaavnCandidate, playingSec: youTubeVideoRuntime))
        // With it: the comparison against the effective duration accepts it.
        XCTAssertTrue(QualityUpgrade.sameRecording(candidateSec: jioSaavnCandidate, playingSec: effective))
    }

    /// End to end through the second look: the search is asked for the catalogue length, and the
    /// 302 s JioSaavn stream it finds is accepted.
    func testTheSecondLookSearchesForTheCatalogueLengthWhenTheCachedCopyIsTheWrongCut() async {
        let album = Streams.make("aac.saavncdn.com", codec: "aac", kbps: 320, durationSeconds: 302, sourceConfigId: "jiosaavn")
        let search = FakeUpgradeSearch(candidates: [album])
        let upgrade = QualityUpgrade.testInstance(search: search)
        let target = QualityUpgrade.Target(title: "São Paulo", artist: "The Weeknd, Anitta", durationSec: 302, album: "Hurry Up Tomorrow")
        XCTAssertTrue(upgrade.adoptUnresolved(
            "2kjolTLZ_Mg",
            uri: "vibramusic://watch?v=2kjolTLZ_Mg&n=S%C3%A3o%20Paulo",
            target: target,
            playingMime: "audio/mp4a-latm",
            playing: StreamFormat(codec: "aac", kbps: 128)
        ))

        let found = await upgrade.lookAgain("2kjolTLZ_Mg", playingDurationSec: 209)

        XCTAssertEqual(found, album)
        XCTAssertEqual(search.calls.first?.target.durationSec, 302)
    }

    func testTheLateLookupIsHeldToTheEffectiveLengthNotTheDecodersRuntime() async {
        let album = Streams.make("aac.saavncdn.com", codec: "aac", kbps: 320, durationSeconds: 302, sourceConfigId: "jiosaavn")
        let upgrade = QualityUpgrade.testInstance(search: FakeUpgradeSearch())
        let lookup = Task<ResolvedStream?, Never> { album }
        let target = QualityUpgrade.Target(title: "São Paulo", artist: "The Weeknd", durationSec: 302)
        XCTAssertTrue(upgrade.settledForLess("2kjolTLZ_Mg", target: target, inFlight: lookup, playing: StreamFormat(codec: "aac", kbps: 128)))

        let found = await upgrade.lookAgain("2kjolTLZ_Mg", playingDurationSec: 209)

        XCTAssertEqual(found, album)
    }
}
