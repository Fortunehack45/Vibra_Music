import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import Sources

/// Ranking two copies of a recording, deciding whether an upgrade earns a seam, racing the sources,
/// and the resolver's entry points. Ported from Android's SourcesTest (the resolver half) with
/// tests added for the iOS entry points (the StreamResolving race, downloads, pins).
final class SourceResolverTests: XCTestCase {

    // MARK: Format reporting (Core's StreamFormat, as the resolver reads it)

    func testLosslessIsDecidedByCodecNotBitrate() {
        XCTAssertEqual(StreamFormat(codec: "flac", kbps: 900).isLossless, true)
        XCTAssertEqual(StreamFormat(codec: "alac").isLossless, true)
        XCTAssertEqual(StreamFormat(codec: "opus", sampleRateHz: 192_000).isLossless, false)
        XCTAssertNil(StreamFormat().isLossless)
    }

    func testSummaryStatesDepthAndRateAndDropsBitrateWhenLossless() {
        XCTAssertEqual(StreamFormat(codec: "flac", kbps: 4608, sampleRateHz: 192_000, bitDepth: 24).summary, "FLAC · 24-bit · 192 kHz")
        XCTAssertEqual(StreamFormat(codec: "mp3", kbps: 320, sampleRateHz: 44_100).summary, "MP3 · 44.1 kHz · 320 kbps")
        XCTAssertEqual(StreamFormat().summary, "Unknown format")
    }

    func testDolbyAtmosIsADistinctPremiumCodec() {
        let atmos = StreamFormat(codec: "eac3-joc")
        XCTAssertTrue(atmos.isDolbyAtmos)
        XCTAssertEqual(atmos.isLossless, false)
        XCTAssertEqual(atmos.summary, "Dolby Atmos")
        XCTAssertTrue(SourceResolver.worthSwapping(atmos, playing: StreamFormat(codec: "aac", kbps: 332)))
    }

    /// Refusing for taste (the setting) and for hardware (no decoder) leave the resolver in the
    /// same state; nothing else is affected either way.
    func testAnAtmosRenditionIsRefusedWhenItIsNotAllowedToPlay() {
        let atmos = StreamFormat(codec: "eac3-joc")
        XCTAssertTrue(ModuleSource.unplayable(atmos, atmosAllowed: false))
        XCTAssertFalse(ModuleSource.unplayable(atmos, atmosAllowed: true))
        XCTAssertFalse(ModuleSource.unplayable(StreamFormat(codec: "flac", sampleRateHz: 44_100, bitDepth: 16), atmosAllowed: false))
        XCTAssertFalse(ModuleSource.unplayable(StreamFormat(), atmosAllowed: false))
    }

    // MARK: Row order

    private func song(_ title: String, _ artist: String, _ duration: String? = nil, quality: SourceQuality? = nil, id: String = "x") -> Song {
        Song(videoId: id, title: title, artist: artist, durationText: duration, sourceQuality: quality)
    }

    /// A declared tier is a reason to prefer one copy over another, not to play a different
    /// recording: the DJ edit claims lossless, and only its runtime gives it away.
    func testRefusesToLetALosslessLabelOutrankTheRightRuntime() {
        let target = TrackMatcher.Target("Sakhiyaan", "Maninder Buttar", durationSec: 180)
        var djEdit = song("Sakhiyaan", "Maninder Buttar", "3:05", quality: .lossless)
        djEdit.albumName = "Punjabi Dj Holi songs"
        var albumCut = song("Sakhiyaan", "Maninder Buttar", "3:00")
        albumCut.albumName = "Sakhiyaan"
        XCTAssertTrue(TrackMatcher.matches(djEdit, title: target.title, artist: target.artist))
        XCTAssertEqual(TrackMatcher.best([djEdit, albumCut], target), albumCut)
        XCTAssertEqual(SourceResolver.preferred([djEdit, albumCut], target: target, wantsLossless: true, atmosWanted: false), [albumCut])
    }

    func testPrefersTheLosslessCopyWhenNothingSeparatesTheRecordings() {
        let target = TrackMatcher.Target("Sakhiyaan", "Maninder Buttar", durationSec: 180)
        let plain = song("Sakhiyaan", "Maninder Buttar", "3:00", id: "plain")
        let lossless = song("Sakhiyaan", "Maninder Buttar", "3:00", quality: .lossless, id: "lossless")
        XCTAssertEqual(SourceResolver.preferred([plain, lossless], target: target, wantsLossless: true, atmosWanted: false), [lossless, plain])
    }

    /// Tidal publishes the immersive mix as its own row filed under LOW. Scored on that label it
    /// sorts last and is never asked for; picking the row is the only way to hear it.
    func testPrefersTheImmersiveRowOverALosslessOneWhenAtmosIsWanted() throws {
        guard let immersive = SourceQuality.immersive else { throw XCTSkip("needs Core's SourceQuality.dolby (requested change)") }
        let target = TrackMatcher.Target("Gehra Hua", "Shashwat Sachdev", durationSec: 362)
        let stereo = song("Gehra Hua", "Shashwat Sachdev", "6:02", quality: .lossless, id: "stereo")
        let atmos = song("Gehra Hua", "Shashwat Sachdev", "6:02", quality: immersive, id: "atmos")
        XCTAssertEqual(SourceResolver.preferred([stereo, atmos], target: target, wantsLossless: true, atmosWanted: true), [atmos, stereo])
    }

    func testIgnoresTheImmersiveRowWhenAtmosIsNotWanted() throws {
        guard let immersive = SourceQuality.immersive else { throw XCTSkip("needs Core's SourceQuality.dolby (requested change)") }
        let target = TrackMatcher.Target("Gehra Hua", "Shashwat Sachdev", durationSec: 362)
        let stereo = song("Gehra Hua", "Shashwat Sachdev", "6:02", quality: .lossless, id: "stereo")
        let atmos = song("Gehra Hua", "Shashwat Sachdev", "6:02", quality: immersive, id: "atmos")
        XCTAssertEqual(SourceResolver.preferred([stereo, atmos], target: target, wantsLossless: true, atmosWanted: false), [stereo, atmos])
    }

    // MARK: Whether an upgrade is worth the seam

    func testAlwaysSwapsToLossless() {
        XCTAssertTrue(SourceResolver.worthSwapping(StreamFormat(codec: "flac"), playing: StreamFormat(codec: "opus", kbps: 160)))
        XCTAssertTrue(SourceResolver.worthSwapping(StreamFormat(codec: "flac"), playing: StreamFormat(codec: "aac", kbps: 320)))
    }

    /// The Shaayraana case: a 320 kbps AAC sat unused because the only question asked was "is this
    /// lossless".
    func testSwapsToALossyStreamThatIsClearlyBetterThanWhatIsPlaying() {
        XCTAssertTrue(SourceResolver.worthSwapping(StreamFormat(codec: "aac", kbps: 320), playing: StreamFormat(codec: "opus", kbps: 160)))
    }

    func testRefusesALossySwapThatGainsLittle() {
        XCTAssertFalse(SourceResolver.worthSwapping(StreamFormat(codec: "mp3", kbps: 192), playing: StreamFormat(codec: "aac", kbps: 128)))
        XCTAssertFalse(SourceResolver.worthSwapping(StreamFormat(codec: "mp3", kbps: 128), playing: StreamFormat(codec: "opus", kbps: 160)))
    }

    func testRefusesALossySwapItCannotMeasure() {
        let playing = StreamFormat(codec: "opus", kbps: 160)
        XCTAssertFalse(SourceResolver.worthSwapping(StreamFormat(codec: "aac"), playing: playing))
        XCTAssertFalse(SourceResolver.worthSwapping(StreamFormat(codec: "aac", kbps: 320), playing: nil))
        XCTAssertFalse(SourceResolver.worthSwapping(StreamFormat(codec: "aac", kbps: 320), playing: StreamFormat(codec: "opus")))
    }

    func testNeverSwapsAwayFromAnImmersiveMixThatIsAlreadyPlaying() {
        XCTAssertFalse(SourceResolver.worthSwapping(StreamFormat(codec: "flac", bitDepth: 24), playing: StreamFormat(codec: "eac3-joc")))
        XCTAssertTrue(SourceResolver.worthSwapping(StreamFormat(codec: "eac3-joc"), playing: StreamFormat(codec: "flac", bitDepth: 24)))
    }

    // MARK: Ranking two copies of the same recording

    func testRanksAHigherBitrateLossyStreamAboveALowerOne() {
        XCTAssertTrue(SourceResolver.isBetter(StreamFormat(codec: "mp4", kbps: 320), than: StreamFormat(codec: "mp3", kbps: 128)))
        XCTAssertFalse(SourceResolver.isBetter(StreamFormat(codec: "mp3", kbps: 128), than: StreamFormat(codec: "mp4", kbps: 320)))
    }

    func testRanksLosslessAboveAnyLossyBitrate() {
        XCTAssertTrue(SourceResolver.isBetter(StreamFormat(codec: "flac"), than: StreamFormat(codec: "mp4", kbps: 320)))
        XCTAssertFalse(SourceResolver.isBetter(StreamFormat(codec: "mp4", kbps: 320), than: StreamFormat(codec: "flac")))
    }

    /// Immersive outranks bit-exact; with the lossless test first the Atmos rule was unreachable.
    func testRanksAnImmersiveMixAboveALosslessCopy() {
        let atmos = StreamFormat(codec: "eac3-joc", sampleRateHz: 48_000)
        let flac = StreamFormat(codec: "flac", sampleRateHz: 96_000, bitDepth: 24)
        XCTAssertTrue(SourceResolver.isBetter(atmos, than: flac))
        XCTAssertFalse(SourceResolver.isBetter(flac, than: atmos))
    }

    func testAnythingBeatsNoStreamAtAll() {
        XCTAssertTrue(SourceResolver.isBetter(StreamFormat(codec: "mp3", kbps: 128), than: nil))
    }

    func testAnEqualStreamDoesNotDisplaceTheOneAlreadyHeld() {
        XCTAssertFalse(SourceResolver.isBetter(StreamFormat(codec: "mp4", kbps: 320), than: StreamFormat(codec: "aac", kbps: 320)))
        XCTAssertFalse(SourceResolver.isBetter(StreamFormat(codec: "flac"), than: StreamFormat(codec: "alac")))
    }

    func testAnUndescribedLossyStreamDoesNotOutrankAStatedOne() {
        XCTAssertFalse(SourceResolver.isBetter(StreamFormat(codec: "aac"), than: StreamFormat(codec: "mp4", kbps: 320)))
        XCTAssertTrue(SourceResolver.isBetter(StreamFormat(codec: "mp4", kbps: 320), than: StreamFormat(codec: "aac")))
    }

    // MARK: What a lossy source has to beat to become a file

    func testA320FromASourceIsWorthKeepingOverYouTubesAac() {
        XCTAssertTrue(SourceResolver.beatsYouTubeAac(StreamFormat(codec: "mp4", kbps: 320)))
    }

    func testAThinnerRenditionLosesToYouTubesAac() {
        XCTAssertFalse(SourceResolver.beatsYouTubeAac(StreamFormat(codec: "mp3", kbps: 128)))
        XCTAssertFalse(SourceResolver.beatsYouTubeAac(StreamFormat(codec: "mp4", kbps: 160)))
        XCTAssertFalse(SourceResolver.beatsYouTubeAac(StreamFormat(codec: "aac", kbps: 256)))
    }

    func testAnUnstatedRenditionIsNotWorthKeeping() {
        XCTAssertFalse(SourceResolver.beatsYouTubeAac(StreamFormat()))
        XCTAssertFalse(SourceResolver.beatsYouTubeAac(StreamFormat(codec: "mp4")))
    }

    func testOnlyTheQuickSourceIsWorthResolvingAheadOfPlayback() {
        XCTAssertTrue(SourceKind.jioSaavn.worthPrefetching)
        XCTAssertFalse(SourceKind.module.worthPrefetching)
        XCTAssertFalse(SourceKind.customModule.worthPrefetching)
        XCTAssertFalse(SourceKind.youtube.worthPrefetching)
    }

    // MARK: Racing the sources

    private let raceTitle = "Paniyon Sa"
    private let raceArtist = "Atif Aslam"
    private func raceTarget() -> TrackMatcher.Target { TrackMatcher.Target(raceTitle, raceArtist, durationSec: 120) }

    /// Every fake source's stream URL, answering its first bytes at once as a healthy server does:
    /// a source's answer only wins a start once its server is sending audio.
    private let media: URLProtocolStub = {
        let stub = URLProtocolStub()
        stub.register(matching: { _ in true }) { _ in .data(Data(repeating: 0, count: 64), status: 206) }
        return stub
    }()

    @MainActor
    private func resolver(_ sources: [FakeSource] = [], youTube: StreamResolving? = nil, atmos: Bool = true,
                          directSourceWait: TimeInterval = SourceResolver.directSourceWait,
                          aheadSourceWait: TimeInterval = SourceResolver.aheadSourceWait,
                          substituteTimeout: TimeInterval = SourceResolver.substituteTimeout) -> (SourceResolver, SourceRegistry) {
        let environment = SourceEnvironment(
            session: media.makeSession(),
            deviceCodecs: .fixed(true),
            dolbyAtmosEnabled: { atmos },
            youTubeStreams: youTube
        )
        let byId = Dictionary(uniqueKeysWithValues: sources.map { ($0.configId, $0) })
        let registry = SourceRegistry(store: nil, environment: environment, factory: { config, _ in
            byId[config.id] ?? FakeSource(config.id, after: 0, format: nil, kind: config.kind)
        })
        return (SourceResolver(registry: registry, directSourceWait: directSourceWait, aheadSourceWait: aheadSourceWait,
                               substituteTimeout: substituteTimeout), registry)
    }

    @MainActor
    func testJioSaavnSubstitutionRefusesConflictingAlbumsWithoutATargetAlbum() async throws {
        var villager = song("Brown Rang", "Yo Yo Honey Singh", "2:59", id: "international-villager")
        villager.albumName = "International Villager"
        var chaarIkke = song("Brown Rang", "Yo Yo Honey Singh", "2:54", id: "chaar-ikke")
        chaarIkke.albumName = "Chaar Ikke"
        let source = FakeSource("JioSaavn", after: 0, format: StreamFormat(codec: "mp4", kbps: 320), candidates: [villager, chaarIkke])
        let (resolver, _) = resolver()
        let found = try await resolver.bestAcross([source], TrackMatcher.Target("Brown Rang", "Yo Yo Honey Singh", durationSec: 175), .best)
        XCTAssertNil(found)
    }

    /// The '9:45' case as a race: JioSaavn's quick 320 starts the track; the slow source is asked,
    /// just not waited for.
    @MainActor
    func testTakesTheQuickAnswerRatherThanWaitingForASlowBetterOne() async throws {
        let slow = FakeSource("Ricky's Addon", after: 2_000, format: StreamFormat(codec: "flac"), kind: .addon)
        let quick = FakeSource("JioSaavn", after: 5, format: StreamFormat(codec: "mp4", kbps: 320))
        let (resolver, _) = resolver()
        let started = Date()
        let found = try await resolver.bestAcross([slow, quick], raceTarget(), .lossless)
        XCTAssertEqual(found?.0.displayName, "JioSaavn")
        XCTAssertEqual(found?.1.format.kbps, 320)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "it waited for the slow source")
        XCTAssertTrue(slow.asked)
    }

    @MainActor
    func testAbandonsTheSourcesStillRunningOnceItHasAnAnswer() async throws {
        let slow = FakeSource("Ricky's Addon", after: 2_000, format: StreamFormat(codec: "flac"), kind: .addon)
        let quick = FakeSource("JioSaavn", after: 5, format: StreamFormat(codec: "mp4", kbps: 320))
        let (resolver, _) = resolver()
        _ = try await resolver.bestAcross([slow, quick], raceTarget(), .lossless)
        XCTAssertTrue(slow.cancelled, "the slow source was left running")
    }

    @MainActor
    func testPrefersTheBetterOfTwoAnswersThatArriveTogether() async throws {
        let worse = FakeSource("Ricky's Addon", after: 5, format: StreamFormat(codec: "mp3", kbps: 128), kind: .addon)
        let better = FakeSource("JioSaavn", after: 5, format: StreamFormat(codec: "mp4", kbps: 320))
        let (resolver, _) = resolver()
        let found = try await resolver.bestAcross([worse, better], raceTarget(), .lossless)
        XCTAssertEqual(found?.0.displayName, "JioSaavn")
        XCTAssertEqual(found?.1.format.kbps, 320)
    }

    @MainActor
    func testKeepsWaitingWhenTheFirstSourceToAnswerHasNothing() async throws {
        let empty = FakeSource("Ricky's Addon", after: 5, format: nil, kind: .addon)
        let holder = FakeSource("JioSaavn", after: 200, format: StreamFormat(codec: "mp4", kbps: 320))
        let (resolver, _) = resolver()
        let found = try await resolver.bestAcross([empty, holder], raceTarget(), .lossless)
        XCTAssertEqual(found?.0.displayName, "JioSaavn")
    }

    @MainActor
    func testHasNothingWhenNoSourceHoldsTheTrack() async throws {
        let (resolver, _) = resolver()
        let found = try await resolver.bestAcross(
            [FakeSource("A", after: 5, format: nil), FakeSource("B", after: 10, format: nil)],
            raceTarget(), .lossless
        )
        XCTAssertNil(found)
    }

    /// The patient upgrade must not let JioSaavn's quick 320 cancel a slower FLAC.
    @MainActor
    func testPatientUpgradeChoosesTheBetterLaterAnswer() async throws {
        let playing = StreamFormat(codec: "opus", kbps: 141)
        let slowLossless = FakeSource("Ricky's Addon", after: 200, format: StreamFormat(codec: "flac"), kind: .addon)
        let quickLossy = FakeSource("JioSaavn", after: 5, format: StreamFormat(codec: "mp4", kbps: 320))
        let (resolver, _) = resolver()
        let found = try await resolver.bestAcross(
            [slowLossless, quickLossy], raceTarget(), .lossless,
            waitForAll: true, strictLength: true,
            accept: { _, stream in SourceResolver.worthSwapping(stream.format, playing: playing) }
        )
        XCTAssertEqual(found?.0.displayName, "Ricky's Addon")
        XCTAssertEqual(found?.1.format.codec, "flac")
        XCTAssertFalse(slowLossless.cancelled)
    }

    @MainActor
    func testUpgradeRefusesSameTitleAndRuntimeFromADifferentArtist() async throws {
        let wrongMexico = FakeSource("Ricky's Addon", after: 0, format: StreamFormat(codec: "flac"), kind: .addon,
                                     candidates: [song("Mexico", "CAKE", "3:26")])
        let (resolver, _) = resolver()
        let found = try await resolver.bestAcross(
            [wrongMexico], TrackMatcher.Target("Mexico", "Karan Aujla", durationSec: 207), .lossless,
            waitForAll: true, strictLength: true, requireSharedArtist: true
        )
        XCTAssertNil(found)
    }

    @MainActor
    func testKeepsWaitingWhenTheQuickAnswerIsRefused() async throws {
        let playing = StreamFormat(codec: "opus", kbps: 141)
        let quickRefused = FakeSource("Ricky's Addon", after: 5, format: StreamFormat(codec: "mp3", kbps: 128), kind: .addon)
        let slowTaken = FakeSource("JioSaavn", after: 200, format: StreamFormat(codec: "mp4", kbps: 320))
        let (resolver, _) = resolver()
        let found = try await resolver.bestAcross(
            [quickRefused, slowTaken], raceTarget(), .lossless,
            accept: { _, stream in SourceResolver.worthSwapping(stream.format, playing: playing) }
        )
        XCTAssertEqual(found?.0.displayName, "JioSaavn")
    }

    /// A lossless request answered with an MP3 is kept only as a floor, marked below request, and
    /// the best refused rendition is the floor rather than the first.
    @MainActor
    func testAnUnderQualityAnswerIsAFloorMarkedBelowRequest() async throws {
        let rows = [
            song(raceTitle, raceArtist, "2:00", id: "row-128"),
            song(raceTitle, raceArtist, "2:00", id: "row-320"),
        ]
        let source = FakeSource("Addon", after: 0, format: nil, kind: .addon, candidates: rows, formats: [
            "row-128": StreamFormat(codec: "mp3", kbps: 128),
            "row-320": StreamFormat(codec: "aac", kbps: 320),
        ])
        let (resolver, _) = resolver()
        let stream = try await resolver.matchAndStream(source, raceTarget(), .lossless)
        XCTAssertEqual(stream?.format.kbps, 320)
        XCTAssertEqual(stream?.belowRequest, true)
        XCTAssertEqual(stream?.durationSeconds, 120)
        XCTAssertEqual(stream?.sourceConfigId, "Addon")
    }

    // MARK: Entry points

    @MainActor
    private func seed(_ registry: SourceRegistry, _ sources: [FakeSource]) {
        for source in sources {
            registry.add(SourceConfig(id: source.configId, kind: source.kind, label: source.displayName, baseUrl: "https://\(source.configId).example", enabled: true))
        }
        // Enable JioSaavn built-in and order user-added first (rank does that).
        for config in registry.configs where config.kind == .jioSaavn { registry.setEnabled(config.id, true) }
    }

    // MARK: A song row's length at the start

    private let bangBang = "Bang Bang (My Baby Shot Me Down)"

    /// Observed on an iPad: gglos answered first with a 3:17 copy of the same title and artist, and
    /// took the row from Qobuz's right 2:42.
    @MainActor
    func testTheStartRefusesASongRowsCopyFarFromItsLengthForTheRightOne() async throws {
        let wrong = FakeSource("gglos", after: 0, format: StreamFormat(codec: "flac"), kind: .addon,
                               candidates: [song(bangBang, "Nancy Sinatra", "3:17", id: "wrong")])
        let right = FakeSource("Qobuz", after: 5, format: StreamFormat(codec: "flac"), kind: .addon,
                               candidates: [song(bangBang, "Nancy Sinatra", "2:42", id: "right")])
        let (resolver, registry) = resolver([wrong, right], youTube: FakeYouTubeResolver(delay: 1_000))
        seed(registry, [wrong, right])

        let stream = try await resolver.resolveStream(for: song(bangBang, "Nancy Sinatra", "2:42", id: "bQD-mcJUbR4"), request: .playback(.lossless))

        XCTAssertEqual(stream.sourceConfigId, "Qobuz")
        XCTAssertEqual(wrong.streamedIds, [], "the wrong copy isn't even opened")
    }

    /// Nothing near the row's length: the source has missed, and YouTube's upload plays the song
    /// that was asked for.
    @MainActor
    func testACopyFarFromASongRowsLengthLeavesTheRowToYouTube() async throws {
        let wrong = FakeSource("gglos", after: 0, format: StreamFormat(codec: "flac"), kind: .addon,
                               candidates: [song(bangBang, "Nancy Sinatra", "3:17")])
        let (resolver, registry) = resolver([wrong], youTube: FakeYouTubeResolver(delay: 5))
        seed(registry, [wrong])

        let stream = try await resolver.resolveStream(for: song(bangBang, "Nancy Sinatra", "2:42", id: "bQD-mcJUbR4"), request: .playback(.lossless))

        XCTAssertEqual(stream.origin, .youtube)
        XCTAssertEqual(wrong.streamedIds, [])
    }

    /// The limit itself: the only copy there is starts the row at 5 s off, and not at 6.
    @MainActor
    func testASongRowIsStartedByACopyUpToTheLimitOffAndNotBeyond() async throws {
        let target = TrackMatcher.Target("Feeling Good", "Nina Simone", durationSec: 174)
        func found(_ duration: String) async throws -> Bool {
            let source = FakeSource("addon", after: 0, format: StreamFormat(codec: "flac"), kind: .addon,
                                    candidates: [song("Feeling Good", "Nina Simone", duration)])
            let (resolver, _) = resolver()
            return try await resolver.bestAcross([source], target, .lossless) != nil
        }
        let atLimit = try await found("2:59")
        let beyond = try await found("3:00")
        XCTAssertEqual(SourceResolver.startDriftSec, 5)
        XCTAssertTrue(atLimit)
        XCTAssertFalse(beyond)
    }

    /// A video row runs long on its intro and outro: it keeps the matcher's allowance.
    @MainActor
    func testAVideoRowKeepsItsAllowance() async throws {
        let source = FakeSource("addon", after: 0, format: StreamFormat(codec: "flac"), kind: .addon,
                                candidates: [song(bangBang, "Nancy Sinatra", "3:17")])
        let (resolver, _) = resolver()
        let found = try await resolver.bestAcross([source], TrackMatcher.Target(bangBang, "Nancy Sinatra", durationSec: 162, isVideo: true), .lossless)
        XCTAssertNotNil(found)
    }

    /// No length to measure on either side: nothing to refuse it on, as before.
    @MainActor
    func testARowOrACopyWithNoKnownLengthIsNotRefused() async throws {
        let stated = FakeSource("stated", after: 0, format: StreamFormat(codec: "flac"), kind: .addon,
                                candidates: [song(bangBang, "Nancy Sinatra", "3:17")])
        let unstated = FakeSource("unstated", after: 0, format: StreamFormat(codec: "flac"), kind: .addon,
                                  candidates: [song(bangBang, "Nancy Sinatra")])
        let (resolver, _) = resolver()
        let forNoLength = try await resolver.bestAcross([stated], TrackMatcher.Target(bangBang, "Nancy Sinatra"), .lossless)
        let ofNoLength = try await resolver.bestAcross([unstated], TrackMatcher.Target(bangBang, "Nancy Sinatra", durationSec: 162), .lossless)
        XCTAssertNotNil(forNoLength)
        XCTAssertNotNil(ofNoLength)
    }

    /// A YouTube track: a ranked source that answers first wins the race and plays.
    @MainActor
    func testResolveStreamPrefersARankedSourceThatAnswersFirst() async throws {
        let addon = FakeSource("addon", after: 5, format: StreamFormat(codec: "flac"), kind: .addon)
        let youTube = FakeYouTubeResolver(delay: 1_000)
        let (resolver, registry) = resolver([addon], youTube: youTube)
        seed(registry, [addon])
        let stream = try await resolver.resolveStream(for: song(raceTitle, raceArtist, "2:00", id: "yt123"), request: .playback(.lossless))
        XCTAssertEqual(stream.format.codec, "flac")
        XCTAssertEqual(stream.sourceConfigId, "addon")
        XCTAssertFalse(stream.belowRequest)
        XCTAssertNil(resolver.takeStillLooking("yt123"), "a lookup that won leaves nothing for the second look")
    }

    /// YouTube answering first plays at once, marked for a second look while sources still search.
    /// The sources' lookup isn't cancelled: it is handed over, once, and lands their copy (Android
    /// `DirectSourceGate.stillLooking`).
    @MainActor
    func testResolveStreamStartsOnYouTubeWhenItWinsAndMarksItForASecondLook() async throws {
        let addon = FakeSource("addon", after: 2_000, format: StreamFormat(codec: "flac"), kind: .addon)
        let youTube = FakeYouTubeResolver(delay: 5)
        let (resolver, registry) = resolver([addon], youTube: youTube)
        seed(registry, [addon])
        let stream = try await resolver.resolveStream(for: song(raceTitle, raceArtist, "2:00", id: "yt123"), request: .playback(.lossless))
        XCTAssertEqual(stream.origin, .youtube)
        XCTAssertTrue(stream.belowRequest)

        let lookup = try XCTUnwrap(resolver.takeStillLooking("yt123"), "the lookup still running is handed to the second look")
        XCTAssertNil(resolver.takeStillLooking("yt123"), "handed over once")
        let late = await lookup.value
        XCTAssertEqual(late?.sourceConfigId, "addon")
        XCTAssertEqual(late?.format.codec, "flac")
        XCTAssertFalse(addon.cancelled, "YouTube's win didn't cancel the add-on's search")
    }

    /// A handed-over lookup is still under the sources' limit: a source that never answers ends it
    /// empty at the limit, not whenever the source gives up.
    @MainActor
    func testALookupHandedToTheSecondLookEndsAtTheSourcesLimit() async throws {
        let addon = FakeSource("addon", after: 60_000, format: StreamFormat(codec: "flac"), kind: .addon)
        let (resolver, registry) = resolver([addon], youTube: FakeYouTubeResolver(delay: 5), substituteTimeout: 0.5)
        seed(registry, [addon])
        let started = ContinuousClock.now
        _ = try await resolver.resolveStream(for: song(raceTitle, raceArtist, "2:00", id: "yt123"), request: .playback(.lossless))

        let lookup = try XCTUnwrap(resolver.takeStillLooking("yt123"))
        let late = await lookup.value
        XCTAssertNil(late)
        XCTAssertLessThan(started.duration(to: .now), .seconds(10))
        XCTAssertTrue(addon.cancelled, "the stuck search is let go at the limit")
    }

    private var waiting: StreamRequest {
        var request = StreamRequest.playback(.lossless)
        request.waitsForSources = true
        return request
    }

    /// Direct source stream: YouTube is ready at once, but a ranked source answering inside the cap
    /// starts the track, in lossless from the first second and with nothing left to upgrade.
    @MainActor
    func testWaitingForSourcesPlaysARankedSourceThatAnswersWithinTheCap() async throws {
        let addon = FakeSource("addon", after: 100, format: StreamFormat(codec: "flac"), kind: .addon)
        let (resolver, registry) = resolver([addon], youTube: FakeYouTubeResolver(delay: 0), directSourceWait: 5)
        seed(registry, [addon])
        let stream = try await resolver.resolveStream(for: song(raceTitle, raceArtist, "2:00", id: "yt123"), request: waiting)
        XCTAssertEqual(stream.sourceConfigId, "addon")
        XCTAssertEqual(stream.format.codec, "flac")
        XCTAssertFalse(stream.belowRequest)
    }

    /// The ranked sources finishing with nothing releases YouTube's held stream at once: not marked
    /// below request, and well before the cap.
    @MainActor
    func testWaitingForSourcesPlaysYouTubeAtOnceWhenNoSourceHasTheTrack() async throws {
        let addon = FakeSource("addon", after: 50, format: nil, kind: .addon)
        let (resolver, registry) = resolver([addon], youTube: FakeYouTubeResolver(delay: 0), directSourceWait: 30)
        seed(registry, [addon])
        let started = ContinuousClock.now
        let stream = try await resolver.resolveStream(for: song(raceTitle, raceArtist, "2:00", id: "yt123"), request: waiting)
        XCTAssertEqual(stream.origin, .youtube)
        XCTAssertFalse(stream.belowRequest)
        XCTAssertLessThan(started.duration(to: .now), .seconds(10))
    }

    /// A source slower than the cap loses to YouTube, which plays marked for the usual mid-song upgrade.
    @MainActor
    func testWaitingForSourcesPlaysYouTubeBelowRequestOncePastTheCap() async throws {
        let addon = FakeSource("addon", after: 30_000, format: StreamFormat(codec: "flac"), kind: .addon)
        let (resolver, registry) = resolver([addon], youTube: FakeYouTubeResolver(delay: 0), directSourceWait: 0.2)
        seed(registry, [addon])
        let started = ContinuousClock.now
        let stream = try await resolver.resolveStream(for: song(raceTitle, raceArtist, "2:00", id: "yt123"), request: waiting)
        XCTAssertEqual(stream.origin, .youtube)
        XCTAssertTrue(stream.belowRequest)
        XCTAssertLessThan(started.duration(to: .now), .seconds(10))
    }

    /// Queue only's look at a track ahead outwaits both play-time limits (the hold on YouTube's
    /// stream and the sources' own search limit): a source slower than either still wins, so the
    /// track starts on its copy rather than YouTube's.
    @MainActor
    func testALookAheadInQueueOnlyWaitsPastThePlayTimeCapForTheSources() async throws {
        // A resolver each, so neither answer comes out of the other's cache.
        let playNow = FakeSource("addon", after: 1_500, format: StreamFormat(codec: "flac"), kind: .addon)
        let (nowResolver, nowRegistry) = resolver([playNow], youTube: FakeYouTubeResolver(delay: 0), directSourceWait: 0.2, aheadSourceWait: 10, substituteTimeout: 0.5)
        seed(nowRegistry, [playNow])
        let atPlayTime = try await nowResolver.resolveStream(for: song(raceTitle, raceArtist, "2:00", id: "yt123"), request: waiting)
        XCTAssertEqual(atPlayTime.origin, .youtube, "played now, the cap still lets YouTube start")

        let lookAhead = FakeSource("addon", after: 1_500, format: StreamFormat(codec: "flac"), kind: .addon)
        let (aheadResolver, aheadRegistry) = resolver([lookAhead], youTube: FakeYouTubeResolver(delay: 0), directSourceWait: 0.2, aheadSourceWait: 10, substituteTimeout: 0.5)
        seed(aheadRegistry, [lookAhead])
        var ahead = waiting
        ahead.readsAheadFromSources = true
        let lookedAhead = try await aheadResolver.resolveStream(for: song(raceTitle, raceArtist, "2:00", id: "yt123"), request: ahead)
        XCTAssertNotEqual(lookedAhead.origin, .youtube, "a track ahead starts on the source's copy")
        XCTAssertFalse(lookedAhead.belowRequest)
    }

    /// A look ahead that gives up marks YouTube's copy for the upgrade even when YouTube was ready
    /// late: the hold is counted from the race's start, so it runs out before the sources' limit.
    @MainActor
    func testALookAheadThatGivesUpMarksALateYouTubeCopyForTheUpgrade() async throws {
        // Sources' limit: 1.0 + (0.5 − 0.2) = 1.3 s from the start. YouTube is ready at 0.6 s, past
        // the 0.3 s margin, so a hold counted from YouTube's readiness would end at 1.6 s, after it.
        let addon = FakeSource("addon", after: 30_000, format: StreamFormat(codec: "flac"), kind: .addon)
        let (resolver, registry) = resolver([addon], youTube: FakeYouTubeResolver(delay: 600), directSourceWait: 0.2, aheadSourceWait: 1, substituteTimeout: 0.5)
        seed(registry, [addon])
        var ahead = waiting
        ahead.readsAheadFromSources = true
        let stream = try await resolver.resolveStream(for: song(raceTitle, raceArtist, "2:00", id: "yt125"), request: ahead)
        XCTAssertEqual(stream.origin, .youtube)
        XCTAssertTrue(stream.belowRequest, "marked for the upgrade, so it isn't kept as the track's answer")
    }

    /// Holding is for a stream YouTube has: a YouTube failure still waits on the sources.
    @MainActor
    func testWaitingForSourcesStillWaitsOnTheSourcesWhenYouTubeFails() async throws {
        let addon = FakeSource("addon", after: 150, format: StreamFormat(codec: "flac"), kind: .addon)
        let (resolver, registry) = resolver([addon], youTube: FakeYouTubeResolver(delay: 0, fails: true), directSourceWait: 0.05)
        seed(registry, [addon])
        let stream = try await resolver.resolveStream(for: song(raceTitle, raceArtist, "2:00", id: "yt123"), request: waiting)
        XCTAssertEqual(stream.sourceConfigId, "addon")
    }

    /// Medium quality permits YouTube alone, so no source is raced at all.
    @MainActor
    func testResolveStreamUnderMediumQualityGoesStraightToYouTube() async throws {
        let addon = FakeSource("addon", after: 0, format: StreamFormat(codec: "flac"), kind: .addon)
        let youTube = FakeYouTubeResolver(delay: 0)
        let (resolver, registry) = resolver([addon], youTube: youTube)
        seed(registry, [addon])
        let stream = try await resolver.resolveStream(for: song(raceTitle, raceArtist, "2:00", id: "yt123"), request: .playback(.medium))
        XCTAssertEqual(stream.origin, .youtube)
        XCTAssertFalse(addon.asked)
        XCTAssertFalse(stream.belowRequest)
    }

    /// An age-gated track YouTube will never serve: its quick failure must not end the race while a
    /// catalogue that has it is still answering.
    @MainActor
    func testResolveStreamWaitsForASourceWhenYouTubeFailsFirst() async throws {
        let addon = FakeSource("addon", after: 150, format: StreamFormat(codec: "flac"), kind: .addon)
        let youTube = FakeYouTubeResolver(delay: 0, fails: true)
        let (resolver, registry) = resolver([addon], youTube: youTube)
        seed(registry, [addon])
        let stream = try await resolver.resolveStream(for: song(raceTitle, raceArtist, "2:00", id: "yt123"), request: .playback(.lossless))
        XCTAssertEqual(stream.sourceConfigId, "addon")
    }

    /// A source-backed track plays from its pin; a disabled pin is not reopened, and the track
    /// falls to another source.
    @MainActor
    func testASourceBackedTrackPlaysFromItsPinUnlessThePinIsSwitchedOff() async throws {
        let pinned = FakeSource("pinned", after: 0, format: StreamFormat(codec: "mp4", kbps: 320), kind: .addon)
        let other = FakeSource("other", after: 0, format: StreamFormat(codec: "mp3", kbps: 256), kind: .addon)
        let (resolver, registry) = resolver([pinned, other])
        seed(registry, [pinned, other])
        let track = song(raceTitle, raceArtist, "2:00", id: SourceRegistry.trackKey(configId: "pinned", trackId: "t1"))

        let first = try await resolver.resolveStream(for: track, request: .playback(.high).with(sources: [.addon, .youtube]))
        XCTAssertEqual(first.sourceConfigId, "pinned")
        XCTAssertEqual(pinned.streamedIds, ["t1"])

        registry.setEnabled("pinned", false)
        let second = try await resolver.resolveStream(for: track, request: .playback(.high).with(sources: [.addon, .youtube]))
        XCTAssertEqual(second.sourceConfigId, "other")
    }

    /// With lossless asked for and a lossy pin, a lossless-capable source above it goes first — and
    /// only a genuinely lossless answer from it counts.
    @MainActor
    func testALossyPinIsUpgradedByALosslessSourceRankedAboveIt() async throws {
        let addon = FakeSource("addon", after: 0, format: StreamFormat(codec: "flac"), kind: .addon)
        let jio = FakeSource("jio", after: 0, format: StreamFormat(codec: "mp4", kbps: 320), kind: .jioSaavn)
        let (resolver, registry) = resolver([addon])
        seed(registry, [addon])
        let jioId = registry.configs.first { $0.kind == .jioSaavn }!.id
        _ = jio
        let track = song(raceTitle, raceArtist, "2:00", id: SourceRegistry.trackKey(configId: jioId, trackId: "saavn-1"))
        let stream = try await resolver.resolveStream(for: track, request: .playback(.lossless))
        XCTAssertEqual(stream.format.codec, "flac")
        XCTAssertEqual(stream.sourceConfigId, "addon")
    }

    /// Downloads: the Standard (capped) rung is YouTube's alone; lossless takes a bit-exact file;
    /// High refuses one and keeps a 320 over YouTube.
    @MainActor
    func testDownloadsFollowTheDownloadQualityNotTheStreamingCeiling() async throws {
        let addon = FakeSource("addon", after: 0, format: StreamFormat(codec: "flac"), kind: .addon)
        let jio = FakeSource("jio", after: 0, format: StreamFormat(codec: "mp4", kbps: 320), kind: .jioSaavn)
        let (resolver, registry) = resolver([addon, jio])
        seed(registry, [addon, jio])
        let target = raceTarget()

        let standard = try await resolver.forDownload(target, request: .download(.standard))
        XCTAssertNil(standard)
        let lossless = try await resolver.forDownload(target, request: .download(.lossless))
        XCTAssertEqual(lossless?.format.codec, "flac")
        let high = try await resolver.forDownload(target, request: .download(.high))
        XCTAssertEqual(high?.format.kbps, 320, "High keeps JioSaavn's 320 and refuses the FLAC")
    }

    @MainActor
    func testADownloadFallsToYouTubeWhenNothingBeatsItsAac() async throws {
        let thin = FakeSource("jio", after: 0, format: StreamFormat(codec: "mp4", kbps: 160), kind: .jioSaavn)
        let youTube = FakeYouTubeResolver(delay: 0)
        let (resolver, registry) = resolver([thin], youTube: youTube)
        seed(registry, [thin])
        let stream = try await resolver.resolveStream(for: song(raceTitle, raceArtist, "2:00", id: "yt123"), request: .download(.high))
        XCTAssertEqual(stream.origin, .youtube)
        XCTAssertTrue(thin.asked)
    }

    @MainActor
    func testUpgradeForSkipsTheSourceAlreadyServingTheTrack() async throws {
        let serving = FakeSource("serving", after: 0, format: StreamFormat(codec: "flac"), kind: .addon)
        let other = FakeSource("other", after: 0, format: StreamFormat(codec: "mp4", kbps: 320), kind: .addon)
        let (resolver, registry) = resolver([serving, other])
        seed(registry, [serving, other])
        let stream = try await resolver.upgradeFor(raceTarget(), playing: StreamFormat(codec: "aac", kbps: 128), servedBy: "serving", request: .playback(.lossless))
        XCTAssertEqual(stream?.sourceConfigId, "other")
        XCTAssertFalse(serving.asked)
    }

    /// Two add-ons hold the recording and the first ranks higher, but its server answers its copy
    /// with a 502. The second look takes the second add-on's copy instead of handing the
    /// swap a dead link and giving up.
    @MainActor
    func testUpgradeForPassesOverADeadCopyToTheNextAddon() async throws {
        let first = FakeSource("first", after: 0, format: StreamFormat(codec: "flac"), kind: .addon)
        let second = FakeSource("second", after: 0, format: StreamFormat(codec: "flac"), kind: .addon)
        media.register(host: "first") { _ in .status(502) }
        let (resolver, registry) = resolver([first, second])
        seed(registry, [first, second])
        let stream = try await resolver.upgradeFor(raceTarget(), playing: StreamFormat(codec: "aac", kbps: 128), request: .playback(.lossless))
        XCTAssertEqual(stream?.sourceConfigId, "second")
        XCTAssertTrue(first.asked)
    }

    /// One add-on that stops answering can't hold the second look: once a copy worth swapping
    /// is in hand, the others get a few seconds to beat it, not their whole timeouts.
    @MainActor
    func testUpgradeForDoesNotWaitOutADeadAddon() async throws {
        let dead = FakeSource("dead", after: 30_000, format: StreamFormat(codec: "flac"), kind: .addon)
        let quick = FakeSource("quick", after: 5, format: StreamFormat(codec: "flac"), kind: .addon)
        let (resolver, registry) = resolver([dead, quick])
        seed(registry, [dead, quick])
        let started = Date()
        let stream = try await resolver.upgradeFor(raceTarget(), playing: StreamFormat(codec: "aac", kbps: 128), request: .playback(.lossless))
        XCTAssertEqual(stream?.sourceConfigId, "quick")
        XCTAssertLessThan(Date().timeIntervalSince(started), 15, "the second look waited out the dead add-on")
    }

    @MainActor
    func testCanSubstituteForYouTubeOnlyWhenSomethingOutranksIt() {
        let addon = FakeSource("addon", after: 0, format: nil, kind: .addon)
        let (resolver, registry) = resolver([addon])
        XCTAssertFalse(resolver.canSubstituteForYouTube(.playback(.lossless)), "JioSaavn is off by default and no addon yet")
        seed(registry, [addon])
        XCTAssertTrue(resolver.canSubstituteForYouTube(.playback(.lossless)))
        XCTAssertFalse(resolver.canSubstituteForYouTube(.playback(.low)))
    }

    func testTargetIsReadBackOutOfAPlaybackURI() {
        let target = SourceResolver.target(in: "vibramusic://source?s=c&t=t&n=Paniyon%20Sa&a=Atif%20Aslam&d=247&l=Satyameva&e=1&m=1")
        XCTAssertEqual(target, TrackMatcher.Target("Paniyon Sa", "Atif Aslam", durationSec: 247, album: "Satyameva", isExplicit: true, isVideo: true))
    }
}

extension StreamRequest {
    func with(sources: Set<SourceKind>) -> StreamRequest {
        var copy = self
        copy.permittedSources = sources
        return copy
    }
}

/// A source that answers after `after` milliseconds with a stream of `format` (per-row formats
/// override), or with nothing when `format` is nil and no rows are given.
final class FakeSource: MusicSource, @unchecked Sendable {
    let configId: String
    let displayName: String
    let kind: SourceKind
    var config: SourceConfig?
    private let delay: UInt64
    private let format: StreamFormat?
    private let candidates: [Song]?
    private let formats: [String: StreamFormat]
    private let lock = NSLock()
    private var _asked = false
    private var _cancelled = false
    private var _streamed: [String] = []

    init(_ name: String, after milliseconds: UInt64, format: StreamFormat?, kind: SourceKind = .jioSaavn,
         candidates: [Song]? = nil, formats: [String: StreamFormat] = [:], config: SourceConfig? = nil) {
        self.config = config
        configId = name
        displayName = name
        self.kind = kind
        delay = milliseconds
        self.format = format
        self.candidates = candidates
        self.formats = formats
    }

    var asked: Bool { lock.withLock { _asked } }
    var cancelled: Bool { lock.withLock { _cancelled } }
    var streamedIds: [String] { lock.withLock { _streamed } }

    func health() async -> SourceHealth { .ok() }

    func search(_ query: String, limit: Int, waitForAll: Bool, tier: StreamRequest.Tier?) async throws -> [Song] {
        lock.withLock { _asked = true }
        do {
            try await Task.sleep(nanoseconds: delay * 1_000_000)
        } catch {
            lock.withLock { _cancelled = true }
            throw error
        }
        if let candidates { return candidates }
        guard format != nil else { return [] }
        return [Song(videoId: "\(configId)-1", title: "Paniyon Sa", artist: "Atif Aslam", durationText: "2:00")]
    }

    func stream(trackId: String, tier: StreamRequest.Tier) async throws -> ResolvedStream? {
        lock.withLock { _streamed.append(trackId) }
        guard let chosen = formats[trackId] ?? format else { return nil }
        return ResolvedStream(url: URL(string: "https://\(configId.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "'", with: ""))/\(trackId)")!,
                              origin: kind == .addon ? .addon : .jioSaavn, format: chosen)
    }
}

/// YouTube's resolver, answering after `delay` ms with an AAC stream (or failing).
struct FakeYouTubeResolver: StreamResolving {
    let delay: UInt64
    var fails = false

    func resolveStream(for song: Song, request: StreamRequest) async throws -> ResolvedStream {
        try await Task.sleep(nanoseconds: delay * 1_000_000)
        if fails { throw URLError(.resourceUnavailable) }
        return ResolvedStream(url: URL(string: "https://rr1.googlevideo.com/videoplayback?id=\(song.videoId)")!, origin: .youtube,
                              mimeType: "audio/mp4", format: StreamFormat(codec: "aac", kbps: 128))
    }
}
