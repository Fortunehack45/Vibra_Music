import XCTest
@testable import Lyrics

/// Every provider against the real service, with a well-known song. Skipped unless
/// `VIBRAMUSIC_LIVE_TESTS=1`.
///
/// Each test prints one `LIVE` line with what the service answered, so a run doubles as the
/// "which providers work today" report. Providers known to be refusing this client are
/// asserted to *miss cleanly* rather than to find lyrics; the message says why.
final class LiveLyricsProviderTests: XCTestCase {
    private let request = LyricsProviderRequest(videoId: "4D7u5KF7SP8", title: "Get Lucky", artist: "Daft Punk", durationMs: 248_000)

    override func setUp() async throws {
        try requireLiveTests()
    }

    private func report(_ source: LyricsSource, _ lines: [LyricLine]?, file: StaticString = #filePath, line: UInt = #line) {
        let summary = lines.map { "\($0.sung.count) lines, word-synced: \($0.contains(where: \.isWordSynced)), first: \"\($0.sung.first?.text ?? "")\"" } ?? "no lyrics"
        print("LIVE \(source.rawValue): \(summary)")
    }

    /// A provider known to be refusing us may answer again one day; when it does, what it
    /// serves must still be the song, not a block page read as lyrics.
    private func assertMissOrRealLyrics(_ source: LyricsSource, _ lines: [LyricLine]?, file: StaticString = #filePath, line: UInt = #line) {
        report(source, lines)
        guard let lines else { return }
        print("LIVE \(source.rawValue) is answering again")
        XCTAssertTrue(lines.sung.contains { $0.text.localizedCaseInsensitiveContains("phoenix") }, "\(source.label): \(lines.sung.prefix(3).map(\.text))", file: file, line: line)
    }

    private func assertFound(_ source: LyricsSource, _ lines: [LyricLine]?, wordSynced: Bool? = nil, file: StaticString = #filePath, line: UInt = #line) {
        report(source, lines)
        guard let lines else { return XCTFail("\(source.label) found nothing for Get Lucky", file: file, line: line) }
        XCTAssertTrue(lines.sung.contains { $0.text.localizedCaseInsensitiveContains("phoenix") }, "\(source.label): \(lines.sung.prefix(3).map(\.text))", file: file, line: line)
        if let wordSynced {
            XCTAssertEqual(lines.contains(where: \.isWordSynced), wordSynced, "\(source.label) word timing", file: file, line: line)
        }
    }

    func testLrcLib() async throws {
        assertFound(.lrcLib, try await LrcLibProvider().lyrics(title: "Get Lucky", artist: "Daft Punk", durationMs: 248_000), wordSynced: false)
    }

    func testKuGou() async throws {
        assertFound(.kuGou, try await KuGouProvider().lyrics(title: "Get Lucky", artist: "Daft Punk", durationMs: 248_000), wordSynced: false)
    }

    func testMusixmatch() async throws {
        assertFound(.musixmatch, try await MusixmatchProvider().lyrics(title: "Get Lucky", artist: "Daft Punk", durationMs: 248_000))
    }

    func testGenius() async throws {
        let lines = await GeniusProvider().lyrics(title: "Get Lucky", artist: "Daft Punk")
        assertFound(.genius, lines, wordSynced: false)
        XCTAssertTrue(lines?.allSatisfy { $0.timeMs == 0 } ?? false)
    }

    func testBetterLyrics() async throws {
        assertFound(.betterLyrics, await BetterLyricsProvider().lyrics(title: "Get Lucky", artist: "Daft Punk", durationMs: 248_000), wordSynced: true)
    }

    func testBiniLyricsIdentifiesTheRecordingAndServesItsWords() async throws {
        let bini = BiniLyricsProvider()
        let isrc = try await bini.identify(request)
        print("LIVE BINI_LYRICS identify: \(isrc ?? "nil")")
        XCTAssertEqual(isrc, "USQX91300809")
        var withISRC = request
        withISRC.isrc = isrc
        let answer = try await bini.lyrics(for: withISRC)
        assertFound(.biniLyrics, answer?.lines, wordSynced: true)
    }

    func testPaxSenixKeylessAppleRoute() async throws {
        assertFound(.paxSenix, await PaxSenixProvider().lyrics(title: "Get Lucky", artist: "Daft Punk", durationMs: 248_000), wordSynced: true)
    }

    func testLyricsPlusMirrors() async throws {
        assertFound(.lyricsPlus, await LyricsPlusProvider().lyrics(title: "Get Lucky", artist: "Daft Punk", durationMs: 248_000), wordSynced: true)
    }

    func testUnison() async throws {
        // Contributed, so thin: Get Lucky is not in it (404); golden hour is.
        report(.unison, await UnisonProvider().lyrics(title: "Get Lucky", artist: "Daft Punk", durationMs: 248_000))
        let golden = await UnisonProvider().lyrics(title: "golden hour", artist: "JVKE", durationMs: 209_000)
        print("LIVE UNISON (golden hour): \(golden?.sung.count ?? 0) lines")
        XCTAssertTrue(golden?.sung.contains { $0.text.contains("two lovers") } ?? false)
    }

    func testYouTubeMusicLyricsTab() async throws {
        let lines = await YouTubeMusicLyricsProvider(client: LyricsWebRemixClient()).lyrics(videoId: "4D7u5KF7SP8")
        assertFound(.youtubeMusic, lines, wordSynced: false)
    }

    // MARK: Providers refusing this client today — asserted to miss cleanly

    func testBetterLyricsPortatoMissesCleanly() async throws {
        // Portato answers 404 "no songs found" for English tracks and 401 "API key required"
        // for any query it has not cached (September 2026).
        let lines = await BetterLyricsProvider(endpoint: .portato).lyrics(title: "Get Lucky", artist: "Daft Punk", durationMs: 248_000)
        assertMissOrRealLyrics(.betterLyricsPortato, lines)
    }

    func testSimpMusicMissesCleanlyWhenBlocked() async throws {
        let lines = await SimpMusicProvider().lyrics(videoId: "4D7u5KF7SP8", durationMs: 248_000)
        assertMissOrRealLyrics(.simpMusic, lines)
    }

    func testYouTubeTranscriptMissesCleanly() async throws {
        // get_transcript answers 400 INVALID_ARGUMENT to this request (September 2026).
        let lines = await YouTubeTranscriptLyricsProvider(client: LyricsWebRemixClient()).lyrics(videoId: "4D7u5KF7SP8")
        assertMissOrRealLyrics(.youtubeTranscript, lines)
    }

    func testMegalobizMissesCleanlyWhenDown() async throws {
        let lines = await MegalobizProvider().lyrics(title: "Get Lucky", artist: "Daft Punk")
        assertMissOrRealLyrics(.megalobiz, lines)
    }

    func testPaxSenixAuthenticatedRoutesNeedAKey() async throws {
        let pax = PaxSenixProvider()
        let spotify = await pax.spotifyLyrics(title: "Get Lucky", artist: "Daft Punk", durationMs: 248_000)
        let musixmatch = await pax.musixmatchLyrics(title: "Get Lucky", artist: "Daft Punk", durationMs: 248_000)
        report(.paxSenixSpotify, spotify)
        report(.paxSenixMusixmatch, musixmatch)
        XCTAssertNil(spotify, "no key configured, so nothing is sent")
        XCTAssertNil(musixmatch)
    }

    // MARK: The whole lookup

    func testTheRepositoryFindsWordSyncedLyricsForGetLucky() async throws {
        let log = LyricsEventLog()
        let track = LyricsTrack(videoId: "4D7u5KF7SP8", title: "Get Lucky (Official Audio)", artist: "Daft Punk - Topic", durationMs: 248_000)
        let result = await LyricsRepository().lyrics(for: track, preferences: .default, onEvent: log.handler)
        print("LIVE repository: \(result?.source.rawValue ?? "nil"), \(result?.lines.sung.count ?? 0) lines")
        XCTAssertEqual(result?.isWordSynced, true)
        XCTAssertEqual(result?.source, .biniLyrics)
        XCTAssertTrue(log.events.contains(.started(.biniLyrics)))
    }

    func testTurningOffTheTopProviderLoadsFromTheNextOne() async throws {
        var preferences = LyricsPreferences()
        preferences.enabledSources = [.lrcLib, .kuGou]
        preferences.sourceOrder = [.lrcLib, .kuGou]
        let track = LyricsTrack(videoId: "4D7u5KF7SP8", title: "Get Lucky", artist: "Daft Punk", durationMs: 248_000)
        let first = await LyricsRepository().lyrics(for: track, preferences: preferences)
        XCTAssertEqual(first?.source, .lrcLib)
        preferences.enabledSources.remove(.lrcLib)
        let second = await LyricsRepository().lyrics(for: track, preferences: preferences)
        XCTAssertEqual(second?.source, .kuGou)
    }
}

/// Translation and romanization against Google's live endpoints, with a Japanese song.
final class LiveLyricsTranslationTests: XCTestCase {
    override func setUp() async throws {
        try requireLiveTests()
    }

    private func japanese() async throws -> [LyricLine] {
        let lines = try await LrcLibProvider().lyrics(title: "夜に駆ける", artist: "YOASOBI", durationMs: 261_000)
        return try XCTUnwrap(lines, "LRCLIB has 夜に駆ける")
    }

    func testJapaneseLyricsBecomeEnglishAndTheTimingStillMatches() async throws {
        let source = try await japanese()
        let result = await LyricsTranslator(cacheDirectory: nil).translate(trackId: "yoru-live", lines: source, targetLanguage: "en")
        guard case .translated(let lines, let language, _) = result else { return XCTFail("\(result)") }
        print("LIVE translate ja→en: \(lines.sung.prefix(3).map(\.text))")
        XCTAssertEqual(language, "ja")
        XCTAssertEqual(lines.map(\.timeMs), source.map(\.timeMs))
        XCTAssertEqual(lines.map(\.isGap), source.map(\.isGap))
        XCTAssertFalse(LyricsTranslator.hasNonLatinLetters(LyricsTranslator.flatten(lines)), "English, not Japanese")
    }

    func testJapaneseLyricsRomanize() async throws {
        let source = try await japanese()
        let result = await LyricsTranslator(cacheDirectory: nil).romanize(trackId: "yoru-live", lines: source, targetLanguage: "en")
        guard case .romanized(let lines, _, _) = result else { return XCTFail("\(result)") }
        print("LIVE romanize ja: \(lines.sung.prefix(3).map(\.text))")
        XCTAssertEqual(lines.map(\.timeMs), source.map(\.timeMs))
        XCTAssertTrue(lines.sung.first?.text.lowercased().contains("shizumu") ?? false)
    }
}
