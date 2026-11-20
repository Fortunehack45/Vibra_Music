import AVFoundation
import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import Sources

/// JioSaavn parsing on responses recorded from the live API (2026-09-26, "Tum Hi Ho"), the URL
/// selection rules from Android's SourcesTest, and the source on a stubbed network.
final class JioSaavnTests: XCTestCase {
    private let fixtures = FixtureLoader(bundle: .module)

    func testParsesARecordedSearchResponse() throws {
        let songs = JioSaavnService.parseSearch(try fixtures.data("jiosaavn_search_tum_hi_ho.json"))
        XCTAssertEqual(songs.count, 10)
        let first = try XCTUnwrap(songs.first)
        XCTAssertEqual(first.id, "aRZbUYD7")
        XCTAssertEqual(first.title, "Tum Hi Ho")
        XCTAssertEqual(first.album, "Aashiqui 2")
        XCTAssertEqual(first.duration, "262")
        XCTAssertTrue(first.supports320)
        XCTAssertFalse(first.isExplicit)
        XCTAssertEqual(first.primaryArtists.map(\.name), ["Mithoon", "Arijit Singh"])
        XCTAssertFalse(first.encryptedMediaURL.isEmpty)
        // The API HTML-escapes titles; the entities are decoded.
        XCTAssertEqual(songs[1].title, "Tum Hi Ho (From \"Aashiqui 2\")")
    }

    /// `song.getDetails` answers `{"<id>": {…}}`, not the `{"songs": […]}` envelope.
    func testParsesARecordedDetailsResponseKeyedById() throws {
        let song = try XCTUnwrap(JioSaavnService.parseDetails(try fixtures.data("jiosaavn_details_aRZbUYD7.json")))
        XCTAssertEqual(song.id, "aRZbUYD7")
        XCTAssertTrue(song.supports320)
        // And the envelope shape still reads, should the endpoint change its mind.
        let enveloped = Data(#"{"songs":[{"id":"x","title":"T","more_info":{"320kbps":"false","encrypted_media_url":"abc"}}]}"#.utf8)
        XCTAssertEqual(JioSaavnService.parseDetails(enveloped)?.id, "x")
    }

    /// DES-ECB under the public key: the recorded URL decrypts to the CDN's 96 kbps object, and the
    /// catalogue's 320 flag upgrades it.
    func testDecryptsTheRecordedMediaURLAndPicksThe320Rendition() throws {
        let song = try XCTUnwrap(JioSaavnService.parseDetails(try fixtures.data("jiosaavn_details_aRZbUYD7.json")))
        XCTAssertEqual(JioSaavnService.decrypt(song.encryptedMediaURL), "https://aac.saavncdn.com/430/5c5ea5cc00e3bff45616013226f376fe_96.mp4")
        let best = JioSaavnService.bestStream(encryptedURL: song.encryptedMediaURL, supports320: song.supports320)
        XCTAssertEqual(best, JioSaavnStream(url: "https://aac.saavncdn.com/430/5c5ea5cc00e3bff45616013226f376fe_320.mp4", kbps: 320))
        XCTAssertEqual(JioSaavnService.decrypt(""), "")
        XCTAssertEqual(JioSaavnService.decrypt("not base64 at all!"), "")
    }

    func testUpgradesAParameterized96kbpsCDNURLWithoutLosingItsQuery() {
        let selected = JioSaavnService.selectBestStream(decryptedURL: "https://aac.saavncdn.com/871/song_96.mp4?Expires=123&Signature=abc", supports320: true)
        XCTAssertEqual(selected?.url, "https://aac.saavncdn.com/871/song_320.mp4?Expires=123&Signature=abc")
        XCTAssertEqual(selected?.kbps, 320)
    }

    func testNeverCallsAnUnrecognisedUnchangedURL320kbps() {
        let url = "https://aac.saavncdn.com/871/song.mp4?token=abc"
        XCTAssertEqual(JioSaavnService.selectBestStream(decryptedURL: url, supports320: true), JioSaavnStream(url: url, kbps: nil))
    }

    /// Rewriting to `_320` when the catalogue says there is none fetched nothing better and once
    /// reported a flat 320 — a 96 kbps stream advertised as 320.
    func testKeepsTheOfferedRateWhenThereIsNo320() {
        XCTAssertEqual(
            JioSaavnService.selectBestStream(decryptedURL: "https://aac.saavncdn.com/1/x_160.mp4", supports320: false),
            JioSaavnStream(url: "https://aac.saavncdn.com/1/x_160.mp4", kbps: 160)
        )
    }

    func testPrioritizesTheUncensoredDuplicate() {
        let clean = JioSaavnSong(id: "clean", title: "Starboy", explicitContent: "0")
        let explicit = JioSaavnSong(id: "explicit", title: "Starboy", explicitContent: "1")
        let anotherClean = JioSaavnSong(id: "clean-2", title: "Starboy", explicitContent: "0")
        XCTAssertEqual(JioSaavnService.prioritizeExplicit([clean, explicit, anotherClean]).map(\.id), ["explicit", "clean", "clean-2"])
    }

    func testAcceptsTextualExplicitFlagsDefensively() {
        XCTAssertTrue(JioSaavnSong(explicitContent: "true").isExplicit)
        XCTAssertFalse(JioSaavnSong(explicitContent: "false").isExplicit)
        XCTAssertFalse(JioSaavnSong(explicitContent: "").isExplicit)
    }

    // MARK: The source, on the recorded responses

    private func source(_ stub: URLProtocolStub) -> JioSaavnSource {
        JioSaavnSource(
            config: SourceConfig(id: "jio", kind: .jioSaavn, enabled: true),
            service: JioSaavnService(session: stub.makeSession())
        )
    }

    func testSearchSendsAndroidsRequestAndMapsRowsToSongs() async throws {
        let stub = URLProtocolStub()
        stub.register(host: "www.jiosaavn.com", path: "/api.php", response: .data(try fixtures.data("jiosaavn_search_tum_hi_ho.json")))
        let songs = try await source(stub).search("Tum Hi Ho Arijit Singh", limit: 3)

        let request = try XCTUnwrap(stub.requests.first)
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        XCTAssertEqual(value("__call"), "search.getResults")
        XCTAssertEqual(value("q"), "Tum Hi Ho Arijit Singh")
        XCTAssertEqual(value("api_version"), "4")
        XCTAssertEqual(value("ctx"), "android")
        XCTAssertEqual(value("n"), "10")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "explicit_content=1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Forwarded-For"), "49.36.0.1")

        XCTAssertEqual(songs.count, 3)
        XCTAssertEqual(songs[0].videoId, "src:jio::aRZbUYD7")
        XCTAssertEqual(songs[0].artist, "Mithoon, Arijit Singh")
        XCTAssertEqual(songs[0].durationText, "4:22")
        XCTAssertEqual(songs[0].albumName, "Aashiqui 2")
        XCTAssertEqual(songs[0].sourceQuality, .high)
        XCTAssertEqual(songs[0].isExplicit, false)
        XCTAssertEqual(songs[0].thumbnailUrl, "https://c.saavncdn.com/430/Aashiqui-2-Hindi-2013-500x500.jpg")
    }

    func testStreamDecryptsTheDetailsAnswerIntoA320AacStream() async throws {
        let stub = URLProtocolStub()
        stub.register(host: "www.jiosaavn.com", path: "/api.php", response: .data(try fixtures.data("jiosaavn_details_aRZbUYD7.json")))
        let stream = try await XCTUnwrapAsync(try await source(stub).stream(trackId: "aRZbUYD7", tier: .best))
        XCTAssertEqual(stream.url.absoluteString, "https://aac.saavncdn.com/430/5c5ea5cc00e3bff45616013226f376fe_320.mp4")
        XCTAssertEqual(stream.origin, .jioSaavn)
        XCTAssertEqual(stream.format, StreamFormat(codec: "mp4", kbps: 320))
        XCTAssertEqual(stream.format.isLossless, false)
        let items = URLComponents(url: stub.requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "pids" }?.value, "aRZbUYD7")
    }

    /// 96 kbps is below YouTube's own AAC: a miss, so the resolver steps over JioSaavn.
    func testARenditionThisThinIsRefused() async throws {
        let stub = URLProtocolStub()
        var details = try XCTUnwrap(String(data: try fixtures.data("jiosaavn_details_aRZbUYD7.json"), encoding: .utf8))
        details = details.replacingOccurrences(of: #""320kbps":"true""#, with: #""320kbps":"false""#)
        stub.register(host: "www.jiosaavn.com", path: "/api.php", response: .text(details))
        let stream = try await source(stub).stream(trackId: "aRZbUYD7", tier: .best)
        XCTAssertNil(stream)
    }

    func testAFailedSearchIsEmptyNotAnError() async throws {
        let stub = URLProtocolStub()
        stub.register(host: "www.jiosaavn.com", response: .status(503))
        let songs = try await source(stub).search("anything", limit: 5)
        XCTAssertTrue(songs.isEmpty)
    }
}

/// The live JioSaavn API: search plus a stream URL for a well-known song, and whether the 320 kbps
/// object is really there. Skipped unless `VIBRAMUSIC_LIVE_TESTS=1`.
final class JioSaavnLiveTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VIBRAMUSIC_LIVE_TESTS"] == "1", "set VIBRAMUSIC_LIVE_TESTS=1 to run")
    }

    func testSearchesStreamsAndServes320kbpsForAWellKnownSong() async throws {
        let session = URLSession(configuration: VibraMusicHTTP.makeConfiguration())
        let source = JioSaavnSource(config: SourceConfig(id: "jio", kind: .jioSaavn, enabled: true), service: JioSaavnService(session: session))
        let songs = try await source.search("Tum Hi Ho Arijit Singh", limit: 10)
        let target = TrackMatcher.Target("Tum Hi Ho", "Arijit Singh", durationSec: 262, album: "Aashiqui 2")
        let match = try XCTUnwrap(TrackMatcher.best(songs, target), "no match among \(songs.map(\.title))")
        let trackId = try XCTUnwrap(SourceRegistry.parseTrackKey(match.videoId)?.trackId)

        let stream = try await XCTUnwrapAsync(try await source.stream(trackId: trackId, tier: .best))
        XCTAssertEqual(stream.format.kbps, 320)
        XCTAssertTrue(stream.url.absoluteString.contains("_320.mp4"), stream.url.absoluteString)

        // The CDN really has the 320 object: a ranged GET answers with audio/mp4.
        var request = URLRequest(url: stream.url)
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertTrue([200, 206].contains(http.statusCode), "HTTP \(http.statusCode)")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "audio/mp4")
        XCTAssertEqual(String(decoding: data.dropFirst(4).prefix(4), as: UTF8.self), "ftyp")
        let total = http.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap { Int64($0) }
        let kbps = total.map { Double($0) * 8 / 1_000 / 262 }
        print("JioSaavn live: \(match.title) — \(stream.url.lastPathComponent), \(total ?? -1) bytes ≈ \(Int(kbps ?? 0)) kbps")
        XCTAssertGreaterThan(kbps ?? 0, 280, "the _320 object is really ~320 kbps")
    }

    /// The whole substitution path against the live catalogue: a YouTube-queued "Tum Hi Ho" is
    /// matched on JioSaavn, streamed at 320, and the file opens in AVFoundation at the catalogue's
    /// runtime.
    @MainActor
    func testTheResolverSubstitutesJioSaavnForAYouTubeTrackAndAVFoundationOpensIt() async throws {
        let environment = SourceEnvironment(session: URLSession(configuration: VibraMusicHTTP.makeConfiguration()),
                                            deviceCodecs: .fixed(false), dolbyAtmosEnabled: { false })
        let registry = SourceRegistry(store: nil, environment: environment)
        registry.setEnabled(try XCTUnwrap(registry.configs.first { $0.kind == .jioSaavn }).id, true)
        let resolver = SourceResolver(registry: registry)
        let youTubeRow = Song(videoId: "Umqb9KENgmk", title: "Tum Hi Ho (From \"Aashiqui 2\")", artist: "Arijit Singh",
                              durationText: "4:22", albumName: "Aashiqui 2")

        let stream = try await XCTUnwrapAsync(try await resolver.substituteForYouTube(TrackMatcher.targetOf(youTubeRow), request: .playback(.high)))
        XCTAssertEqual(stream.origin, .jioSaavn)
        XCTAssertEqual(stream.format.kbps, 320)
        XCTAssertEqual(stream.durationSeconds, 262)
        XCTAssertFalse(stream.belowRequest)

        let duration = try await AVURLAsset(url: stream.url).load(.duration)
        XCTAssertEqual(duration.seconds, 262, accuracy: 2)
    }
}
