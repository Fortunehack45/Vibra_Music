import XCTest
import VibraMusicCore
@testable import PlaybackPolicy

/// The second look end to end: becoming a candidate, the look itself, and what each outcome leaves
/// behind. None of this had a JVM test on Android (it needed a populated source registry); here the
/// source layer is a protocol and a fake stands in for it.
final class QualityUpgradeLifecycleTests: XCTestCase {
    private let id = "AdEKgwUqPKI"
    private let uri = "vibramusic://watch?v=AdEKgwUqPKI&n=Bounce&a=Artist&d=143"
    private let target = QualityUpgrade.Target(title: "Bounce", artist: "Artist", durationSec: 143)
    private let opus = StreamFormat(codec: "opus", kbps: 141)

    private var search: FakeUpgradeSearch!
    private var stats: NerdStats!
    private var upgrade: QualityUpgrade!

    override func setUp() {
        super.setUp()
        search = FakeUpgradeSearch()
        stats = NerdStats()
        upgrade = .testInstance(search: search, nerdStats: stats)
    }

    private func flac(duration: Int = 143, source: String = "addon-1") -> ResolvedStream {
        Streams.make("tidal.example", codec: "flac", durationSeconds: duration, sourceConfigId: source)
    }

    private func aac320(duration: Int = 143, source: String = "jiosaavn") -> ResolvedStream {
        Streams.make("aac.saavncdn.com", codec: "aac", kbps: 320, durationSeconds: duration, sourceConfigId: source)
    }

    // MARK: Becoming a candidate

    func testSettlingForLessMarksTheTrackPendingAndLightsTheBadge() {
        XCTAssertTrue(upgrade.settledForLess(id, target: target, playing: opus))
        XCTAssertTrue(upgrade.isPending(id))
        XCTAssertTrue(stats.isRacing(id))
    }

    /// No such thing as an upgrade when nothing outranks YouTube, and a still-running lookup is
    /// cancelled rather than left to finish for nobody.
    func testNothingIsPendingWhenNoSourceOutranksYouTube() async {
        search.canSubstituteForYouTube = false
        let lookup = Task<ResolvedStream?, Never> {
            try? await Task.sleep(for: .seconds(30))
            return nil
        }

        XCTAssertFalse(upgrade.settledForLess(id, target: target, inFlight: lookup))

        _ = await lookup.value
        XCTAssertTrue(lookup.isCancelled)
        XCTAssertFalse(upgrade.isPending(id))
        XCTAssertFalse(stats.isRacing(id))
    }

    func testMusicVideosUntitledTracksAndRefusedTracksAreNotCandidates() {
        XCTAssertFalse(upgrade.settledForLess(id, target: QualityUpgrade.Target(title: "Bounce", isVideo: true)))
        XCTAssertFalse(upgrade.settledForLess(id, target: QualityUpgrade.Target(title: "  ")))
        upgrade.refuseUpgrades(id)
        XCTAssertFalse(upgrade.settledForLess(id, target: target))
        XCTAssertFalse(stats.isRacing(id))
    }

    func testCouldStillUpgradeReadsTheQueueEntry() {
        XCTAssertTrue(upgrade.couldStillUpgrade(id, uri: uri))
        XCTAssertFalse(upgrade.couldStillUpgrade(id, uri: nil))
        XCTAssertFalse(upgrade.couldStillUpgrade(id, uri: "vibramusic://source?s=addon-1&t=1"), "no YouTube id to upgrade")
        XCTAssertFalse(upgrade.couldStillUpgrade(id, uri: uri + "&m=1"), "a music video plays its own audio")
        XCTAssertFalse(upgrade.couldStillUpgrade(id, uri: uri + "&q=hifi"), "this *is* the better copy")
        XCTAssertFalse(upgrade.couldStillUpgrade(id, uri: uri + "&direct_youtube=1&q=original"), "held on the original")
        search.canSubstituteForYouTube = false
        XCTAssertFalse(upgrade.couldStillUpgrade(id, uri: uri))
    }

    /// A cache entry written by a previous session's upgrade already holds the FLAC.
    func testATrackAlreadyPlayingLosslessFromCacheIsSettledWithoutASearch() {
        XCTAssertFalse(upgrade.adoptUnresolved(id, uri: uri, target: target, playingMime: "audio/flac", playing: nil))
        XCTAssertTrue(upgrade.hasAnswered(id))
        XCTAssertFalse(upgrade.couldStillUpgrade(id, uri: uri), "never offered again this play")
        XCTAssertFalse(stats.isRacing(id))
    }

    func testALossyCachedTrackIsAdoptedWithItsMeasuredFloor() async {
        search.candidates = [aac320()]
        XCTAssertTrue(upgrade.adoptUnresolved(id, uri: uri, target: target, playingMime: "audio/opus", playing: opus))
        XCTAssertTrue(stats.isRacing(id))
        XCTAssertFalse(upgrade.couldStillUpgrade(id, uri: uri), "pending keeps the offer off while the question is open")

        let found = await upgrade.lookAgain(id, playingDurationSec: 143)

        // 320 − 141 clears the 96 kbps bar: the measured floor is what makes a lossy upgrade possible.
        XCTAssertEqual(found, aac320())
        XCTAssertTrue(stats.isRacing(id), "a yes leaves the badge up until the swap lands")
    }

    /// The bug the measured floor fixed: with no floor, nothing lossy clears the bar.
    func testAnUnmeasuredFloorRefusesEveryLossyCandidate() async {
        search.candidates = [aac320()]
        XCTAssertTrue(upgrade.adoptUnresolved(id, uri: uri, target: target, playingMime: "audio/opus", playing: nil))

        let found = await upgrade.lookAgain(id, playingDurationSec: 143)

        XCTAssertNil(found)
        XCTAssertEqual(search.refused, [aac320()])
        XCTAssertFalse(stats.isRacing(id), "a no ends the race")
        XCTAssertTrue(upgrade.hasAnswered(id))
    }

    // MARK: The late lookup

    func testTheLiveLookupThatLostTheRaceGetsFirstRefusal() async {
        let late = flac()
        let lookup = Task<ResolvedStream?, Never> { late }
        upgrade.settledForLess(id, target: target, inFlight: lookup, playing: opus, servedBy: nil)

        let found = await upgrade.lookAgain(id, playingDurationSec: 143)

        XCTAssertEqual(found, late)
        XCTAssertTrue(search.calls.isEmpty, "no second search when the first one's answer is good")
        XCTAssertFalse(upgrade.isPending(id))
    }

    /// Measured on Android: a 189-second cut swapped into a 163-second song.
    func testALateAnswerOfTheWrongLengthIsNotSwappedIn() async {
        let lookup = Task<ResolvedStream?, Never> { self.flac(duration: 189) }
        search.candidates = [flac(duration: 164)]
        upgrade.settledForLess(id, target: QualityUpgrade.Target(title: "Bounce", durationSec: 163), inFlight: lookup, playing: opus)

        let found = await upgrade.lookAgain(id, playingDurationSec: 163)

        XCTAssertEqual(found?.durationSeconds, 164, "the fresh search's same-length copy wins instead")
        XCTAssertEqual(search.calls.count, 1)
    }

    func testTheSearchSkipsTheSourceAlreadyServingTheTrack() async {
        search.candidates = [aac320(source: "jiosaavn"), flac(source: "addon-1")]
        upgrade.settledForLess(id, target: target, playing: StreamFormat(codec: "aac", kbps: 320), servedBy: "jiosaavn")

        let found = await upgrade.lookAgain(id, playingDurationSec: 143)

        XCTAssertEqual(search.calls.first?.servedBy, "jiosaavn")
        XCTAssertEqual(found?.sourceConfigId, "addon-1")
    }

    // MARK: Cancellation leaves the question open

    /// The single biggest hole in the Android feature: two seconds on another track recorded a
    /// search that never finished as "nothing better exists".
    func testACancelledSearchLeavesTheTrackPending() async {
        search.delay = .seconds(30)
        search.candidates = [flac()]
        upgrade.settledForLess(id, target: target, playing: opus)

        let look = Task { await self.upgrade.lookAgain(id, playingDurationSec: 143) }
        try? await Task.sleep(for: .milliseconds(100))
        look.cancel()
        let found = await look.value

        XCTAssertNil(found)
        XCTAssertTrue(upgrade.isPending(id), "nothing was learned, so the track is still worth asking about")
        XCTAssertFalse(upgrade.hasAnswered(id))
        XCTAssertFalse(stats.isRacing(id), "the badge goes out with the search")
    }

    /// Waiting on the inherited lookup gives up with its caller, without cancelling the lookup.
    func testCancellingWhileWaitingOnTheLateLookupReturnsPromptly() async {
        let lookup = Task<ResolvedStream?, Never> {
            try? await Task.sleep(for: .seconds(30))
            return nil
        }
        upgrade.settledForLess(id, target: target, inFlight: lookup, playing: opus)

        let started = Date()
        let look = Task { await self.upgrade.lookAgain(id, playingDurationSec: 143) }
        try? await Task.sleep(for: .milliseconds(100))
        look.cancel()
        let found = await look.value

        XCTAssertNil(found)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertTrue(upgrade.isPending(id))
        XCTAssertFalse(lookup.isCancelled, "the lookup belongs to whoever started it")
        upgrade.forget(id)
        XCTAssertTrue(lookup.isCancelled, "…and forget is what tears it down")
    }

    func testAFailedSearchIsNotAVerdict() async {
        search.error = URLError(.notConnectedToInternet)
        upgrade.settledForLess(id, target: target, playing: opus)

        let found = await upgrade.lookAgain(id, playingDurationSec: 143)

        XCTAssertNil(found)
        XCTAssertTrue(upgrade.isPending(id))
        XCTAssertFalse(upgrade.hasAnswered(id))
    }

    /// `upgradeFor`'s preconditions: without a length there is nothing to check a candidate against.
    func testNoSearchWithoutALengthToCheckAgainst() async {
        upgrade.settledForLess(id, target: QualityUpgrade.Target(title: "Bounce"), playing: opus)

        let found = await upgrade.lookAgain(id, playingDurationSec: nil)

        XCTAssertNil(found)
        XCTAssertTrue(search.calls.isEmpty)
        XCTAssertTrue(upgrade.hasAnswered(id))
    }

    func testLookingAgainAtATrackThatIsNotPendingDoesNothing() async {
        let found = await upgrade.lookAgain(id, playingDurationSec: 143)
        XCTAssertNil(found)
        XCTAssertTrue(search.calls.isEmpty)
    }

    // MARK: Lossless follow-up

    /// With lossless requested, JioSaavn's 320 can win the first pass while a slower FLAC source is
    /// still searching; once it has swapped in, the question is asked again with 320 as the floor.
    func testALossyUpgradeIsFollowedByALosslessPassOnlyAfterItSwapsIn() async {
        search.candidates = [aac320()]
        upgrade.settledForLess(id, target: target, playing: opus)
        let first = await upgrade.lookAgain(id, playingDurationSec: 143)
        XCTAssertEqual(first, aac320())
        stats.onLosslessRaceEnd(id) // the swap landed

        XCTAssertTrue(upgrade.continueAfterLossySwap(id))
        XCTAssertTrue(upgrade.isPending(id))
        XCTAssertTrue(stats.isRacing(id))
        XCTAssertFalse(upgrade.continueAfterLossySwap(id), "re-armed once")

        search.candidates = [aac320(), flac()]
        let second = await upgrade.lookAgain(id, playingDurationSec: 143)

        XCTAssertEqual(second, flac(), "JioSaavn is now unchanged against its own floor and the FLAC wins")
        XCTAssertEqual(search.calls.last?.servedBy, "jiosaavn")
        // The sources weigh candidates against the same floor: the swapped-in 320, not the Opus.
        XCTAssertEqual(search.calls.map(\.playing), [opus, aac320().format] as [StreamFormat?])
    }

    func testNoFollowUpWhenLosslessWasNotAskedFor() async {
        let highUpgrade = QualityUpgrade.testInstance(search: search, tier: .best, nerdStats: stats)
        search.candidates = [aac320()]
        highUpgrade.settledForLess(id, target: target, playing: opus)
        _ = await highUpgrade.lookAgain(id, playingDurationSec: 143)
        XCTAssertFalse(highUpgrade.continueAfterLossySwap(id))
    }

    /// Dolby Atmos is lossy by codec and final by definition: the completed immersive tier.
    func testNoFollowUpAfterDolbyAtmos() async {
        let atmos = Streams.make("tidal.example", codec: "eac3-joc", kbps: 768, durationSeconds: 143, sourceConfigId: "addon-1")
        search.candidates = [atmos]
        upgrade.settledForLess(id, target: target, playing: opus)
        _ = await upgrade.lookAgain(id, playingDurationSec: 143)
        XCTAssertFalse(upgrade.continueAfterLossySwap(id))
    }

    /// A failed audition must leave the original search as the last word.
    func testForgettingDropsTheFollowUp() async {
        search.candidates = [aac320()]
        upgrade.settledForLess(id, target: target, playing: opus)
        _ = await upgrade.lookAgain(id, playingDurationSec: 143)
        upgrade.forget(id)
        XCTAssertFalse(upgrade.continueAfterLossySwap(id))
    }

    // MARK: Hand requests, refusals, sessions

    func testARefusedTrackIsNotOfferedAgainUntilTheListenerAsks() {
        upgrade.refuseUpgrades(id)
        XCTAssertFalse(upgrade.couldStillUpgrade(id, uri: uri))
        upgrade.askByHand(id)
        XCTAssertTrue(upgrade.couldStillUpgrade(id, uri: uri))
    }

    /// The hand request's exemption lasts as long as the listener stays on the track.
    func testForgettingATrackEndsItsHandRequest() {
        let reverted = uri + "&direct_youtube=1&q=original"
        upgrade.askByHand(id)
        XCTAssertTrue(upgrade.couldStillUpgrade(id, uri: reverted))
        upgrade.forget(id)
        XCTAssertFalse(upgrade.couldStillUpgrade(id, uri: reverted))
    }

    /// Measured on Android with the process surviving: last session's successful upgrade left the
    /// track in `asked`, and the next session's cached play of it was refused a second look.
    func testForgettingTheLastSessionMakesAWarmRestartBehaveLikeAColdOne() {
        upgrade.markAnsweredForTest(id)
        upgrade.refuseUpgrades("broken")
        upgrade.settledForLess("pending", target: target, playing: opus)
        upgrade.force("forced", stream: flac())
        upgrade.beginAudition("auditioning")

        upgrade.forgetLastSession()

        XCTAssertFalse(upgrade.hasAnswered(id))
        XCTAssertTrue(upgrade.couldStillUpgrade(id, uri: uri))
        XCTAssertTrue(upgrade.couldStillUpgrade("broken", uri: "vibramusic://watch?v=broken"))
        XCTAssertFalse(upgrade.isPending("pending"))
        XCTAssertFalse(stats.isRacing("pending"), "the badge goes out with the lookup")
        XCTAssertNil(upgrade.forcedStream("vibramusic://watch?v=forced&q=hifi"))
        XCTAssertFalse(upgrade.isAuditioning("auditioning"))
    }

    // MARK: Auditions and the shelf

    func testAuditionsAreTrackedPerTrack() {
        XCTAssertFalse(upgrade.isAuditioning(id))
        upgrade.beginAudition(id)
        XCTAssertTrue(upgrade.isAuditioning(id))
        XCTAssertFalse(upgrade.isAuditioning(nil))
        upgrade.endAudition(id)
        XCTAssertFalse(upgrade.isAuditioning(id))
    }

    /// A proved upgrade that ran out of track is kept for a return visit, and its "yes" is not left
    /// recorded as a settled question.
    func testAShelvedUpgradeWaitsForTheListenerToComeBack() {
        upgrade.markAnsweredForTest(id)
        upgrade.shelve(id, stream: flac())
        XCTAssertEqual(upgrade.shelved(id), flac())
        XCTAssertFalse(upgrade.hasAnswered(id))

        upgrade.unshelve(id)
        XCTAssertNil(upgrade.shelved(id))
    }

    // MARK: The ceiling

    /// Wi-Fi's lossless ceiling, then High on cellular: High pays for JioSaavn but not an add-on.
    func testTheCeilingInForceDecidesWhichSourcesAStreamMayComeFrom() {
        let high = QualityUpgrade(search: search, requestForNow: { .playback(.high) }, streamChoice: StreamChoice(), nerdStats: stats)
        XCTAssertFalse(high.permitsForPlayback(flac()), "an add-on's FLAC")
        XCTAssertTrue(high.permitsForPlayback(Streams.make("aac.saavncdn.com", codec: "aac", kbps: 320, origin: .jioSaavn)))
        XCTAssertTrue(high.permitsForPlayback(Streams.youTubeOpus), "YouTube is permitted on every rung")
        XCTAssertTrue(upgrade.permitsForPlayback(flac()), "lossless pays for everything")
    }

    /// Android `onCeilingLowered`: a shelved copy the new ceiling skips is dropped, one it allows is
    /// kept, and the lossless follow-up is let go.
    func testALoweredCeilingDropsWhatItNoLongerPaysFor() async {
        search.candidates = [aac320()]
        upgrade.settledForLess(id, target: target, playing: opus)
        _ = await upgrade.lookAgain(id, playingDurationSec: 143)
        upgrade.shelve("lossless", stream: flac())
        upgrade.shelve("lossy", stream: aac320())

        upgrade.onCeilingLowered(keep: [id]) { $0.format.isLossless != true }

        XCTAssertNil(upgrade.shelved("lossless"))
        XCTAssertEqual(upgrade.shelved("lossy"), aac320())
        XCTAssertFalse(upgrade.continueAfterLossySwap(id), "no lossless pass is chased under a ceiling that doesn't ask for one")
    }

    // MARK: Handing the stream to the player

    func testAForcedStreamIsFoundOnlyThroughAnUpgradeMarker() {
        upgrade.force(id, stream: flac())
        XCTAssertEqual(upgrade.forcedStream(QualityUpgrade.upgradedURI(uri)), flac())
        XCTAssertEqual(upgrade.forcedStream(uri + "&q=hifi-3"), flac())
        XCTAssertNil(upgrade.forcedStream(uri), "the unmarked item reads the base stream")
        XCTAssertNil(upgrade.forcedStream(uri + "&direct_youtube=1&q=original"))
        // Read rather than consumed: every reopen arrives at the same bytes.
        XCTAssertEqual(upgrade.forcedStream(uri + "&q=hifi"), flac())
    }

    func testUpgradeMarkersCountGenerations() {
        let first = QualityUpgrade.upgradedURI(uri)
        XCTAssertEqual(first, uri + "&q=hifi")
        let second = QualityUpgrade.upgradedURI(first)
        XCTAssertEqual(second, uri + "&q=hifi-2", "replaced, not duplicated")
        XCTAssertEqual(QualityUpgrade.upgradedURI(second), uri + "&q=hifi-3")
    }

    /// A revert's rendition is not a generation to count from, and its `direct_youtube` would hand
    /// the upgrade back the very copy it replaces.
    func testUpgradingARevertedItemDropsTheDirectYouTubeMarker() {
        XCTAssertEqual(QualityUpgrade.upgradedURI(uri + "&direct_youtube=1&q=original"), uri + "&q=hifi")
    }

    // MARK: Worth the seam

    func testLosslessAlwaysClearsTheBar() {
        XCTAssertTrue(QualityUpgrade.worthSwapping(StreamFormat(codec: "flac"), over: nil))
        XCTAssertTrue(QualityUpgrade.worthSwapping(StreamFormat(codec: "alac"), over: StreamFormat(codec: "aac", kbps: 320)))
    }

    /// Bitrate compares poorly across codecs, so the gap is wide: 160 to 320 clears it, 128 to 192
    /// does not.
    func testALossyCandidateNeedsA96KbpsGain() {
        XCTAssertTrue(QualityUpgrade.worthSwapping(StreamFormat(codec: "aac", kbps: 320), over: StreamFormat(codec: "opus", kbps: 160)))
        XCTAssertFalse(QualityUpgrade.worthSwapping(StreamFormat(codec: "aac", kbps: 192), over: StreamFormat(codec: "aac", kbps: 128)))
        XCTAssertTrue(QualityUpgrade.worthSwapping(StreamFormat(codec: "aac", kbps: 224), over: StreamFormat(codec: "aac", kbps: 128)))
        XCTAssertFalse(QualityUpgrade.worthSwapping(StreamFormat(codec: "aac", kbps: 223), over: StreamFormat(codec: "aac", kbps: 128)))
        XCTAssertFalse(QualityUpgrade.worthSwapping(StreamFormat(codec: "aac"), over: StreamFormat(codec: "opus", kbps: 64)))
    }

    /// A FLAC is a better copy and a worse mix once Atmos is what is playing.
    func testNothingSwapsAwayFromAnImmersiveMix() {
        let atmos = StreamFormat(codec: "eac3-joc", kbps: 768)
        XCTAssertFalse(QualityUpgrade.worthSwapping(StreamFormat(codec: "flac"), over: atmos))
        XCTAssertTrue(QualityUpgrade.worthSwapping(atmos, over: atmos))
        XCTAssertTrue(QualityUpgrade.worthSwapping(atmos, over: StreamFormat(codec: "opus", kbps: 160)))
    }

    func testSameRecordingAllowsTwoSecondsOfRounding() {
        XCTAssertTrue(QualityUpgrade.sameRecording(candidateSec: 165, playingSec: 163))
        XCTAssertFalse(QualityUpgrade.sameRecording(candidateSec: 166, playingSec: 163))
        XCTAssertFalse(QualityUpgrade.sameRecording(candidateSec: nil, playingSec: 163), "an unverifiable length is not one that agrees")
    }
}
