import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import Sources

/// A tiny addon server over `URLProtocolStub`: per-path answers set by each test, 404 for anything
/// else, and every request recorded — the same shape as Android's MockWebServer dispatcher.
final class FakeAddonServer: @unchecked Sendable {
    static let base = "https://addon.test"
    let stub = URLProtocolStub()
    private let lock = NSLock()
    private var routes: [String: URLProtocolStub.Response] = [:]
    private var responders: [String: URLProtocolStub.Responder] = [:]

    init() {
        stub.register(matching: { _ in true }) { [weak self] request in
            guard let self, let url = request.url else { return .status(404) }
            let key = (url.host() ?? "") + url.path(percentEncoded: true)
            let path = url.path(percentEncoded: true)
            if let responder = self.lock.withLock({ self.responders[key] ?? (url.host() == "addon.test" ? self.responders[path] : nil) }) {
                return try responder(request)
            }
            return self.lock.withLock { self.routes[key] ?? (url.host() == "addon.test" ? self.routes[path] : nil) } ?? .status(404)
        }
    }

    /// `path` on the addon, or `host/path` for another server (a CDN, a manifest host).
    func route(_ path: String, _ response: URLProtocolStub.Response) {
        lock.withLock { routes[path] = response }
    }

    func route(_ path: String, _ responder: @escaping URLProtocolStub.Responder) {
        lock.withLock { responders[path] = responder }
    }

    func requests(to path: String) -> [URLRequest] {
        stub.requests.filter { $0.url?.host() == "addon.test" && $0.url?.path(percentEncoded: true) == path }
    }

    /// Query item `name` of the first request to `path`.
    func query(_ name: String, of path: String) -> String? {
        guard let url = requests(to: path).first?.url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}

/// The addon protocol end to end: what Vibra Music puts on the wire and what it does with what comes
/// back. Ported from Android's AddonSourceTest (which ran a real MockWebServer); every payload in
/// the "real addon" section is the verbatim capture from a live multi-backend addon (Sept 2026).
/// iOS-specific: DASH answers are converted (see `DashToHLSTests` for the conversion itself).
final class AddonSourceTests: XCTestCase {
    private var server: FakeAddonServer!
    private var manifestDirectory: URL!
    private let codecs = DeviceCodecs.fixed(true)
    private let atmosSetting = LockedBox(true)

    override func setUpWithError() throws {
        server = FakeAddonServer()
        manifestDirectory = try makeTemporaryDirectory()
    }

    private func environment() -> SourceEnvironment {
        let setting = atmosSetting
        return SourceEnvironment(
            session: server.stub.makeSession(),
            deviceCodecs: codecs,
            dolbyAtmosEnabled: { setting.value },
            manifestFiles: SourceManifestFiles(directory: manifestDirectory)
        )
    }

    private func config() -> SourceConfig { SourceConfig(kind: .addon, baseUrl: FakeAddonServer.base) }
    private func source() -> AddonSource { AddonSource(config: config(), environment: environment()) }
    private func manifest() -> URLProtocolStub.Response {
        .json(#"{"id":"com.test.addon","name":"Test Addon","version":"2.1.0","resources":["search","stream"]}"#)
    }

    // MARK: URL handling

    /// Numbers from an add-on or a module, as JSON numbers or numeric strings ("inf",
    /// "1e300"), went straight into `Int(...)`, which traps on infinity and past Int's range.
    func testHostileNumbersFromAnAddonOrModuleAreDroppedNotTrapped() throws {
        let decoder = JSONDecoder()
        let track = try decoder.decode(AddonTrack.self, from: Data(#"{"id":"t","duration":"1e300"}"#.utf8))
        XCTAssertNil(track.durationSec)
        for value in [#""inf""#, #""1e300""#, "1e300"] {
            let json = #"{"url":"https://x","sampleRate":\#(value),"bitDepth":\#(value),"bitrate":\#(value)}"#
            let stream = try decoder.decode(AddonStream.self, from: Data(json.utf8))
            XCTAssertNil(stream.sampleRateHz, value)
            XCTAssertNil(stream.bits, value)
            XCTAssertNil(stream.kbps, value)
            let module = try decoder.decode(ModuleStreamTrack.self, from: Data(#"{"sampleRate":\#(value)}"#.utf8))
            XCTAssertNil(module.sampleRate, value)
        }
        let label = try decoder.decode(AddonStream.self, from: Data(#"{"url":"https://x","quality":"999999999999999999999 kHz"}"#.utf8))
        XCTAssertNil(label.sampleRateHz)
    }

    func testNormalizeBaseAcceptsEveryFormOfTheAddressAUserMightPaste() {
        let expected = "https://addon.example.com"
        XCTAssertEqual(AddonClient.normalizeBase("https://addon.example.com"), expected)
        XCTAssertEqual(AddonClient.normalizeBase("https://addon.example.com/"), expected)
        XCTAssertEqual(AddonClient.normalizeBase("  https://addon.example.com//  "), expected)
        XCTAssertEqual(AddonClient.normalizeBase("https://addon.example.com/manifest.json"), expected)
        XCTAssertEqual(AddonClient.normalizeBase("https://addon.example.com/MANIFEST.JSON"), expected)
    }

    func testNormalizeBaseKeepsATokenBearingPathIntact() {
        XCTAssertEqual(AddonClient.normalizeBase("https://addon.example.com/abc123/manifest.json"), "https://addon.example.com/abc123")
    }

    /// The path is the credential, so the path is what a log line must not carry.
    func testRedactHidesTheTokenInThePathAndKeepsTheHost() {
        XCTAssertEqual(AddonClient.redact("https://addon.example.com/secret-token/stream/42"), "https://addon.example.com/***")
        XCTAssertEqual(AddonClient.redact("not a url"), "***")
    }

    // MARK: Manifest

    func testAWellFormedManifestReportsHealthyWithItsNameAndVersion() async {
        server.route("/manifest.json", manifest())
        let health = await source().health()
        XCTAssertEqual(health, .ok(detail: "Test Addon v2.1.0"))
    }

    /// The string Android 1.8 sends, so an add-on's allow-list needs no change for this app.
    func testAnAddonIsSentAndroidsUserAgent() async {
        server.route("/manifest.json", manifest())
        _ = await source().health()
        let agent = server.requests(to: "/manifest.json").first?.value(forHTTPHeaderField: "User-Agent")
        XCTAssertEqual(agent, "Vibra Music/v1.8")
    }

    /// Rejected, not unreachable: retrying will never change it.
    func testAnAddonThatCannotBeSearchedIsRejectedNotMerelyUnreachable() async {
        server.route("/manifest.json", .json(#"{"id":"x","name":"X","resources":["stream"]}"#))
        let health = await source().health()
        guard case .rejected(let reason) = health else { return XCTFail("expected rejected, got \(health)") }
        XCTAssertTrue(reason.contains("needs search"))
    }

    func testAnAddonThatDeclaresSearchButNotStreamIsAccepted() async {
        server.route("/manifest.json", .json(#"{"id":"x","name":"X","resources":["search"]}"#))
        let health = await source().health()
        XCTAssertTrue(health.isOk)
    }

    func testAnAddonWithNoManifestIsHealthyWhenItsSearchEndpointAnswers() async {
        server.route("/search", .json(#"{"tracks":[{"id":"t1","title":"S","artist":"A"}]}"#))
        let health = await source().health()
        XCTAssertEqual(health, .ok(detail: "No manifest · search works"))
    }

    func testAURLThatAnswersWithSomethingOtherThanAManifestIsRejected() async {
        server.route("/manifest.json", .json(#"{"hello":"world"}"#))
        guard case .rejected = await source().health() else { return XCTFail("expected rejected") }
    }

    /// The one 404 that is not a miss: no manifest means no addon here.
    func testNoManifestAtTheURLIsRejectedRatherThanReportedAsAMiss() async {
        guard case .rejected = await source().health() else { return XCTFail("expected rejected") }
    }

    func testAServerErrorReadsAsUnreachable() async {
        server.route("/manifest.json", .status(503))
        guard case .unreachable = await source().health() else { return XCTFail("expected unreachable") }
    }

    // MARK: Search

    func testSearchMapsRowsToSongsTaggedWithThisSource() async throws {
        server.route("/manifest.json", manifest())
        server.route("/search", .json("""
        {"tracks":[
          {"id":"t1","title":"Song One","artist":"Artist","album":"Album","duration":245,"artworkURL":"https://cdn/x.jpg","format":"flac"},
          {"id":"t2","title":"Song Two","artist":"Artist","duration":61,"format":"mp3"}
        ]}
        """))
        let config = config()
        let songs = try await AddonSource(config: config, environment: environment()).search("song", limit: 10)
        XCTAssertEqual(songs.count, 2)
        XCTAssertEqual(songs[0].title, "Song One")
        XCTAssertEqual(songs[0].albumName, "Album")
        XCTAssertEqual(songs[0].thumbnailUrl, "https://cdn/x.jpg")
        XCTAssertEqual(songs[0].durationText, "4:05")
        XCTAssertEqual(songs[0].sourceQuality, .lossless)
        XCTAssertEqual(songs[1].durationText, "1:01")
        XCTAssertEqual(songs[1].sourceQuality, .high)
        XCTAssertTrue(songs[0].videoId.hasPrefix("src:\(config.id)::"))
        XCTAssertTrue(songs[0].videoId.hasSuffix("::t1"))
    }

    func testSearchDropsRowsWithNoIdOrNoTitle() async throws {
        server.route("/manifest.json", manifest())
        server.route("/search", .json(#"{"tracks":[{"id":"","title":"No id"},{"id":"t","title":""},{"id":"ok","title":"Fine"}]}"#))
        let songs = try await source().search("x", limit: 10)
        XCTAssertEqual(songs.map(\.title), ["Fine"])
    }

    func testSearchHonoursTheCallersLimit() async throws {
        server.route("/manifest.json", manifest())
        let rows = (1...20).map { #"{"id":"t\#($0)","title":"Song \#($0)","artist":"A"}"# }.joined(separator: ",")
        server.route("/search", .json(#"{"tracks":[\#(rows)]}"#))
        let songs = try await source().search("x", limit: 3)
        XCTAssertEqual(songs.count, 3)
    }

    func testAnUnreachableAddonReturnsNoResultsRatherThanThrowing() async throws {
        server.route("/manifest.json", manifest())
        let songs = try await source().search("x", limit: 5)
        XCTAssertTrue(songs.isEmpty)
    }

    func testManualRefreshAsksAgainAfterACachedEmptySearch() async throws {
        server.route("/manifest.json", manifest())
        server.route("/search", .json(#"{"tracks":[]}"#))
        let source = source()
        let first = try await source.search("song", limit: 5)
        XCTAssertTrue(first.isEmpty)
        server.route("/search", .json(#"{"tracks":[{"id":"recovered","title":"Song","artist":"Artist"}]}"#))
        let cached = try await source.search("song", limit: 5)
        XCTAssertTrue(cached.isEmpty, "the ordinary path still sees the cached empty answer")
        await source.clearCompletedTrackCalls()
        let refreshed = try await source.search("song", limit: 5)
        XCTAssertEqual(refreshed.map(\.title), ["Song"])
        XCTAssertEqual(server.requests(to: "/search").count, 2)
    }

    func testManualRefreshAsksAgainForACachedStreamURL() async throws {
        server.route("/manifest.json", manifest())
        server.route("/stream/track", .json(#"{"url":"https://cdn.test/old.flac","codec":"flac"}"#))
        let source = source()
        let first = try await source.stream(trackId: "track", tier: .lossless)
        XCTAssertEqual(first?.url.absoluteString, "https://cdn.test/old.flac")
        server.route("/stream/track", .json(#"{"url":"https://cdn.test/new.flac","codec":"flac"}"#))
        let cached = try await source.stream(trackId: "track", tier: .lossless)
        XCTAssertEqual(cached?.url.absoluteString, "https://cdn.test/old.flac")
        await source.clearCompletedTrackCalls()
        let refreshed = try await source.stream(trackId: "track", tier: .lossless)
        XCTAssertEqual(refreshed?.url.absoluteString, "https://cdn.test/new.flac")
        XCTAssertEqual(server.requests(to: "/stream/track").count, 2)
    }

    // MARK: Settings passthrough

    /// Declared defaults travel; `quality` overrides its default and is negotiated against the
    /// options the addon enumerates.
    func testDeclaredSettingDefaultsTravelWithTheRequestAndQualityOverridesThem() async throws {
        server.route("/manifest.json", .json("""
        {"id":"a","name":"A","resources":["search","stream","settings"],
         "settings":[
           {"key":"quality","type":"select","default":"normal","options":[{"value":"lossless"},{"value":"high"},{"value":"normal"}]},
           {"key":"region","type":"text","default":"US"},
           {"key":"preferOpus","type":"toggle","default":true}
         ]}
        """))
        server.route("/search", .json(#"{"tracks":[]}"#))
        _ = try await source().search("hello", limit: 5)
        XCTAssertEqual(server.query("q", of: "/search"), "hello")
        XCTAssertEqual(server.query("region", of: "/search"), "US")
        XCTAssertEqual(server.query("preferOpus", of: "/search"), "true")
        XCTAssertEqual(server.query("quality", of: "/search"), "lossless")
    }

    func testAnAddonThatEnumeratesNoOptionsIsSentTheTierVerbatim() async throws {
        server.route("/manifest.json", manifest())
        server.route("/stream/t1", .json(#"{"url":"https://cdn.test/a.flac"}"#))
        _ = try await source().stream(trackId: "t1", tier: .lossless)
        XCTAssertEqual(server.query("quality", of: "/stream/t1"), "LOSSLESS")
    }

    func testACappedRequestAsksForTheAddonsSmallTier() async throws {
        server.route("/manifest.json", manifest())
        server.route("/stream/t1", .json(#"{"url":"https://cdn.test/a.mp3"}"#))
        _ = try await source().stream(trackId: "t1", tier: .capped(kbps: 64))
        XCTAssertEqual(server.query("quality", of: "/stream/t1"), "LOW")
    }

    func testASearchBehindACappedRequestAsksTheAddonAtThatTier() async throws {
        server.route("/manifest.json", manifest())
        server.route("/search", .json(#"{"tracks":[]}"#))
        _ = try await source().search("x", limit: 5, waitForAll: false, tier: .capped(kbps: 64))
        XCTAssertEqual(server.query("quality", of: "/search"), "LOW")
    }

    func testASearchWithNoRequestBehindItStillAsksForLossless() async throws {
        server.route("/manifest.json", manifest())
        server.route("/search", .json(#"{"tracks":[]}"#))
        _ = try await source().search("x", limit: 5)
        XCTAssertEqual(server.query("quality", of: "/search"), "LOSSLESS")
    }

    /// A query with `+`, `&` and non-ASCII reaches the addon intact.
    func testTheQueryIsEncodedSoPunctuationSurvives() async throws {
        server.route("/manifest.json", manifest())
        server.route("/search", .json(#"{"tracks":[]}"#))
        _ = try await source().search("Rock & Roll + São Paulo", limit: 5)
        XCTAssertEqual(server.query("q", of: "/search"), "Rock & Roll + São Paulo")
    }

    // MARK: Immersive audio

    /// Exactly `auto`: `1`/`true` select strict mode, which would turn every ordinary track into a miss.
    func testTheAtmosHintTravelsOnSearchAndStreamWhenTheDeviceAndTheUserBothWantIt() async throws {
        server.route("/manifest.json", manifest())
        server.route("/search", .json(#"{"tracks":[]}"#))
        server.route("/stream/t1", .json(#"{"url":"https://cdn.test/a.flac","codec":"flac"}"#))
        let source = source()
        _ = try await source.search("x", limit: 5)
        _ = try await source.stream(trackId: "t1", tier: .lossless)
        XCTAssertEqual(server.query("atmos", of: "/search"), "auto")
        XCTAssertEqual(server.query("atmos", of: "/stream/t1"), "auto")
    }

    /// The derived parameters are reused for a second, but the hint follows the setting at once.
    func testTheAtmosHintFollowsTheSettingWithinTheSecondTheOtherParametersAreReused() async throws {
        server.route("/manifest.json", manifest())
        server.route("/search", .json(#"{"tracks":[]}"#))
        server.route("/stream/t1", .json(#"{"url":"https://cdn.test/a.flac","codec":"flac"}"#))
        let source = source()
        _ = try await source.search("x", limit: 5)
        atmosSetting.value = false
        _ = try await source.stream(trackId: "t1", tier: .lossless)
        XCTAssertEqual(server.query("atmos", of: "/search"), "auto")
        XCTAssertNil(server.query("atmos", of: "/stream/t1"))
    }

    func testNoAtmosHintIsSentWhenTheSettingIsOff() async throws {
        atmosSetting.value = false
        server.route("/manifest.json", manifest())
        server.route("/stream/t1", .json(#"{"url":"https://cdn.test/a.flac","codec":"flac"}"#))
        _ = try await source().stream(trackId: "t1", tier: .lossless)
        XCTAssertNil(server.query("atmos", of: "/stream/t1"))
    }

    func testNoAtmosHintIsSentWhenTheDeviceCannotDecodeIt() async throws {
        codecs.force(false)
        server.route("/manifest.json", manifest())
        server.route("/stream/t1", .json(#"{"url":"https://cdn.test/a.flac","codec":"flac"}"#))
        _ = try await source().stream(trackId: "t1", tier: .lossless)
        XCTAssertNil(server.query("atmos", of: "/stream/t1"))
    }

    func testADeclaredAtmosDefaultIsNotOverriddenByTheHint() async throws {
        server.route("/manifest.json", .json("""
        {"id":"a","name":"A","resources":["search","stream","settings"],
         "settings":[{"key":"atmos","type":"select","default":"only","options":[{"value":"only"},{"value":"auto"},{"value":"off"}]}]}
        """))
        server.route("/stream/t1", .json(#"{"url":"https://cdn.test/a.flac","codec":"flac"}"#))
        _ = try await source().stream(trackId: "t1", tier: .lossless)
        XCTAssertEqual(server.query("atmos", of: "/stream/t1"), "only")
    }

    /// A server answering `?atmos=auto` the way the spec describes: the immersive mix when asked,
    /// the stereo ladder otherwise. The Atmos answer is verbatim (underscore codec and all) and
    /// points at a DASH manifest, which iOS converts.
    private func routeAtmosAddon() throws {
        server.route("/manifest.json", manifest())
        let mpd = try FixtureLoader(bundle: .module).data("dash_atmos_and_flac.mpd")
        server.route("cdn.example.com/dash/tidal-atmos", .data(mpd, headers: ["Content-Type": "application/dash+xml"]))
        server.route("/stream/t1") { request in
            let atmos = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "atmos" }?.value
            if atmos == "auto" {
                return .json("""
                {"url":"https://cdn.example.com/dash/tidal-atmos","format":"dash","quality":"Tidal · Dolby Atmos",
                 "streamQuality":"[Tidal] DOLBY_ATMOS","codec":"eac3_joc","container":"mp4",
                 "manifest":"dash","sampleRate":48000,"atmos":true,"encrypted":false}
                """)
            }
            return .json(#"{"url":"https://cdn.example.com/a.flac","codec":"flac","container":"flac"}"#)
        }
    }

    func testAskingForAtmosGetsAnImmersiveAnswerThePlayerCanOpen() async throws {
        try routeAtmosAddon()
        let stream = try await XCTUnwrapAsync(await source().stream(trackId: "t1", tier: .lossless))
        XCTAssertEqual(stream.format.codec, "eac3-joc")
        XCTAssertTrue(stream.format.isDolbyAtmos)
        XCTAssertEqual(stream.format.summary, "Dolby Atmos")
        XCTAssertEqual(stream.format.isLossless, false)
        // DASH → an HLS playlist over the E-AC-3 representation, served by SourcePlaylistLoader.
        XCTAssertEqual(stream.url.scheme, "vibramusic-hls")
        XCTAssertTrue(stream.isHLS)
        let playlist = try XCTUnwrap(SourceManifestFiles(directory: manifestDirectory).playlistText(for: stream.url))
        XCTAssertTrue(playlist.contains("https://cdn.example.com/tidal/527739156/eac3/init.mp4"), playlist)
        XCTAssertTrue(playlist.contains("eac3/seg-00000.m4s"), playlist)
    }

    func testWithoutTheHintTheSameAddonAnswersWithTheStereoLadder() async throws {
        atmosSetting.value = false
        try routeAtmosAddon()
        let stream = try await XCTUnwrapAsync(await source().stream(trackId: "t1", tier: .lossless))
        XCTAssertEqual(stream.format.codec, "flac")
        XCTAssertEqual(stream.format.isLossless, true)
        XCTAssertFalse(stream.format.isDolbyAtmos)
    }

    /// The two rows a real Tidal-backed addon returns for one song, verbatim: the immersive one is a
    /// different id filed under LOW.
    func testATidalImmersiveRowIsTaggedAsAtmosAndNotAsItsLowBitrateLabel() async throws {
        guard let immersive = SourceQuality.immersive else { throw XCTSkip("needs Core's SourceQuality.dolby (requested change)") }
        server.route("/manifest.json", manifest())
        server.route("/search", .json("""
        {"tracks":[
          {"id":"tidal:479222720","title":"Gehra Hua","artist":"Shashwat Sachdev","album":"Dhurandhar","duration":362,"format":"flac",
           "audioQuality":"LOSSLESS","audioModes":["STEREO"],"provider":"Tidal"},
          {"id":"tidal:527739156","title":"Gehra Hua (From \\"Dhurandhar\\")","artist":"Shashwat Sachdev","album":"Dhurandhar","duration":362,
           "format":"dash","audioQuality":"LOW","audioModes":["DOLBY_ATMOS"],"atmos":true,"provider":"Tidal"}
        ]}
        """))
        let songs = try await source().search("gehra hua", limit: 10)
        XCTAssertEqual(songs.map(\.sourceQuality), [.lossless, immersive])
    }

    func testAnImmersiveRowIsRecognisedFromAudioModesWithNoAtmosFlag() async throws {
        guard let immersive = SourceQuality.immersive else { throw XCTSkip("needs Core's SourceQuality.dolby (requested change)") }
        server.route("/manifest.json", manifest())
        server.route("/search", .json(#"{"tracks":[{"id":"t1","title":"S","artist":"A","duration":200,"audioQuality":"LOW","audioModes":["DOLBY_ATMOS"]}]}"#))
        let songs = try await source().search("s", limit: 5)
        XCTAssertEqual(songs.first?.sourceQuality, immersive)
    }

    func testAStereoRowKeepsTheTierItsLabelStates() async throws {
        server.route("/manifest.json", manifest())
        server.route("/search", .json(#"{"tracks":[{"id":"t1","title":"S","artist":"A","duration":200,"audioQuality":"LOW","audioModes":["STEREO"],"format":"mp3"}]}"#))
        let songs = try await source().search("s", limit: 5)
        XCTAssertEqual(songs.first?.sourceQuality, .low)
    }

    /// An id is a path segment, not string concatenation.
    func testATrackIdContainingASlashStaysOnePathSegment() async throws {
        server.route("/manifest.json", manifest())
        server.route("/stream/a%2Fb%3Fc", .json(#"{"url":"https://cdn.test/a.flac"}"#))
        let stream = try await source().stream(trackId: "a/b?c", tier: .lossless)
        XCTAssertNotNil(stream, "the id was not encoded into a single segment")
    }

    // MARK: Stream

    func testTheRoutingFieldsBecomeTheFormatThePlayerIsToldAbout() async throws {
        server.route("/manifest.json", manifest())
        server.route("/stream/t1", .json("""
        {"url":"https://cdn.example.com/a.flac","format":"flac","quality":"lossless","codec":"flac","container":"flac",
         "manifest":"none","encrypted":false,"sampleRate":96000,"bitDepth":24}
        """))
        let stream = try await XCTUnwrapAsync(await source().stream(trackId: "t1", tier: .lossless))
        XCTAssertEqual(stream.url.absoluteString, "https://cdn.example.com/a.flac")
        XCTAssertEqual(stream.origin, .addon)
        XCTAssertEqual(stream.format.codec, "flac")
        XCTAssertEqual(stream.format.sampleRateHz, 96_000)
        XCTAssertEqual(stream.format.bitDepth, 24)
        XCTAssertEqual(stream.format.isLossless, true)
        XCTAssertFalse(stream.isHLS)
    }

    /// An HLS playlist served from a path with no extension, reporting `format: "flac"`: declared,
    /// so AVPlayer opens it as HLS rather than sniffing a FLAC file.
    func testAnExtensionlessHLSPlaylistIsDeclaredToThePlayerRatherThanSniffed() async throws {
        server.route("/manifest.json", manifest())
        server.route("/stream/t1", .json(#"{"url":"https://cdn.example.com/dash/t1","format":"flac","codec":"flac","manifest":"hls"}"#))
        let stream = try await XCTUnwrapAsync(await source().stream(trackId: "t1", tier: .lossless))
        XCTAssertEqual(stream.url.absoluteString, "https://cdn.example.com/dash/t1")
        XCTAssertEqual(stream.mimeType, "application/x-mpegURL")
        XCTAssertTrue(stream.isHLS)
    }

    /// A declared DASH transport whose representation is one file plays that file progressively.
    func testADeclaredDashTransportWithASingleFileIsPlayedProgressively() async throws {
        server.route("/manifest.json", manifest())
        server.route("/stream/t2", .json(#"{"url":"https://cdn.example.com/play/t2","manifest":"dash"}"#))
        server.route("cdn.example.com/play/t2", .data(try FixtureLoader(bundle: .module).data("dash_segment_base.mpd")))
        let stream = try await XCTUnwrapAsync(await source().stream(trackId: "t2", tier: .lossless))
        XCTAssertEqual(stream.url.absoluteString, "https://files.example.com/hi.mp4", "the highest-bandwidth audio representation")
        XCTAssertEqual(stream.mimeType, "audio/mp4")
        XCTAssertEqual(stream.format.codec, "flac")
        XCTAssertEqual(stream.format.sampleRateHz, 96_000)
    }

    /// A DASH manifest that can't be read is a miss for this source, so another can be heard.
    func testAnUnreadableDashManifestIsAMiss() async throws {
        server.route("/manifest.json", manifest())
        server.route("/stream/t3", .json(#"{"url":"https://cdn.example.com/play/t3","manifest":"dash"}"#))
        server.route("cdn.example.com/play/t3", .text("<html>expired</html>"))
        let stream = try await source().stream(trackId: "t3", tier: .lossless)
        XCTAssertNil(stream)
    }

    func testAnEncryptedRenditionIsRefused() async throws {
        server.route("/manifest.json", manifest())
        server.route("/stream/t1", .json(#"{"url":"https://cdn.test/a.mpd","encrypted":"widevine","manifest":"dash"}"#))
        let stream = try await source().stream(trackId: "t1", tier: .lossless)
        XCTAssertNil(stream)
    }

    func testEncryptedFalseIsNotTreatedAsEncrypted() async throws {
        server.route("/manifest.json", manifest())
        server.route("/stream/t1", .json(#"{"url":"https://cdn.test/a.flac","encrypted":false}"#))
        let stream = try await source().stream(trackId: "t1", tier: .lossless)
        XCTAssertNotNil(stream)
    }

    func testAMalformedStreamURLIsRefusedBeforeThePlayerSeesIt() async throws {
        server.route("/manifest.json", manifest())
        server.route("/stream/t1", .json(#"{"url":"/relative/path.flac"}"#))
        let stream = try await source().stream(trackId: "t1", tier: .lossless)
        XCTAssertNil(stream)
    }

    func testAStream404IsAMissNotACrash() async throws {
        server.route("/manifest.json", manifest())
        let stream = try await source().stream(trackId: "nope", tier: .lossless)
        XCTAssertNil(stream)
    }

    /// An addon serving permanent direct links may treat `/stream` as optional.
    func testTheSearchRowsOwnURLIsUsedWhenTheStreamEndpointHasNothing() async throws {
        server.route("/manifest.json", manifest())
        server.route("/search", .json(#"{"tracks":[{"id":"t1","title":"S","artist":"A","duration":180,"streamURL":"https://cdn.example.com/direct.mp3","format":"mp3"}]}"#))
        let source = source()
        _ = try await source.search("s", limit: 5)
        let stream = try await XCTUnwrapAsync(await source.stream(trackId: "t1", tier: .best))
        XCTAssertEqual(stream.url.absoluteString, "https://cdn.example.com/direct.mp3")
        XCTAssertEqual(stream.format.codec, "mp3")
        XCTAssertEqual(stream.durationSeconds, 180)
    }

    func testWithNoRowRememberedAndNoStreamAnswerThereIsNothingToPlay() async throws {
        server.route("/manifest.json", manifest())
        let stream = try await source().stream(trackId: "unknown", tier: .best)
        XCTAssertNil(stream)
    }

    func testASearchedRowsDurationReachesTheStreamItProduces() async throws {
        server.route("/manifest.json", manifest())
        server.route("/search", .json(#"{"tracks":[{"id":"t1","title":"S","artist":"A","duration":242}]}"#))
        server.route("/stream/t1", .json(#"{"url":"https://cdn.test/a.flac","codec":"flac"}"#))
        let source = source()
        _ = try await source.search("s", limit: 5)
        let stream = try await source.stream(trackId: "t1", tier: .lossless)
        XCTAssertEqual(stream?.durationSeconds, 242)
    }

    // MARK: Rate limiting

    /// A 429 must not read as "this addon doesn't have the track".
    func testARateLimitedRequestIsWaitedOutAndRetried() async throws {
        server.route("/manifest.json", manifest())
        let answers = LockedBox<[URLProtocolStub.Response]>([
            .init(statusCode: 429, headers: ["Retry-After": "0"]),
            .json(#"{"url":"https://cdn.test/a.flac","codec":"flac"}"#),
        ])
        server.route("/stream/t1") { _ in
            var queue = answers.value
            let next = queue.removeFirst()
            answers.value = queue
            return next
        }
        let stream = try await source().stream(trackId: "t1", tier: .lossless)
        XCTAssertNotNil(stream, "a 429 should be retried, not reported as a miss")
        XCTAssertTrue(answers.value.isEmpty)
    }

    func testRetryAfterIsBelievedAndBackoffIsCapped() {
        XCTAssertEqual(AddonClient.retryAfter("2", attempt: 0), 2)
        XCTAssertEqual(AddonClient.retryAfter(nil, attempt: 0), 0.5)
        XCTAssertEqual(AddonClient.retryAfter(nil, attempt: 1), 1)
        XCTAssertEqual(AddonClient.retryAfter("600", attempt: 0), 8)
    }

    // MARK: Fallback quality inference

    func testABareAnswerStillYieldsWhatCanBeInferredFromTheURL() async throws {
        server.route("/manifest.json", manifest())
        server.route("/stream/t1", .json(#"{"url":"https://cdn.example.com/track.128.mp3"}"#))
        let format = try await XCTUnwrapAsync(await source().stream(trackId: "t1", tier: .best)).format
        XCTAssertEqual(format.codec, "mp3")
        XCTAssertEqual(format.isLossless, false)
    }

    func testABitrateInBitsPerSecondIsReadAsKbps() async throws {
        server.route("/manifest.json", manifest())
        server.route("/stream/t1", .json(#"{"url":"https://cdn.test/a.mp3","codec":"mp3","bitrate":320000}"#))
        let stream = try await source().stream(trackId: "t1", tier: .best)
        XCTAssertEqual(stream?.format.kbps, 320)
    }

    func testABitrateAlreadyInKbpsIsLeftAlone() async throws {
        server.route("/manifest.json", manifest())
        server.route("/stream/t1", .json(#"{"url":"https://cdn.test/a.flac","codec":"flac","bitrate":1411}"#))
        let stream = try await source().stream(trackId: "t1", tier: .lossless)
        XCTAssertEqual(stream?.format.kbps, 1411)
    }

    func testAnAtmosRenditionIsRefusedOnADeviceThatCannotDecodeIt() async throws {
        codecs.force(false)
        server.route("/manifest.json", manifest())
        server.route("/stream/t1", .json(#"{"url":"https://cdn.test/a.mp4","codec":"eac3_joc","quality":"Dolby Atmos"}"#))
        let stream = try await source().stream(trackId: "t1", tier: .lossless)
        XCTAssertNil(stream)
    }

    func testAnAtmosRenditionPlaysOnADeviceThatCanDecodeIt() async throws {
        server.route("/manifest.json", manifest())
        server.route("/stream/t1", .json(#"{"url":"https://cdn.test/a.mp4","codec":"eac3-joc","quality":"Dolby Atmos"}"#))
        let stream = try await XCTUnwrapAsync(await source().stream(trackId: "t1", tier: .lossless))
        XCTAssertTrue(stream.format.isDolbyAtmos)
    }

    // MARK: Against what a real addon actually sends

    /// A Hi-Res FLAC over DASH whose only statement that it is a manifest is `format: "dash"` — no
    /// `manifest`, no codec, no `.mpd`. On iOS the MPD is fetched and becomes a local HLS playlist.
    func testARealTidalHiResAnswerIsConvertedFromDashToHLS() async throws {
        let url = "https://im-fa.manifest.tidal.com/1/manifests/Egk0MTc1OTQ2NzEYAigBMAJY3onUY2CHaGoIUExBWUJBQ0s"
        server.route("/manifest.json", manifest())
        server.route("/stream/t1", .json("""
        {"url":"\(url)","format":"dash","quality":"Tidal · Hi-Res FLAC (DASH)",
         "streamQuality":"[Tidal] HI_RES_LOSSLESS","provider":"Tidal","expiresAt":1788633325}
        """))
        server.route("im-fa.manifest.tidal.com/1/manifests/Egk0MTc1OTQ2NzEYAigBMAJY3onUY2CHaGoIUExBWUJBQ0s",
                     .data(try FixtureLoader(bundle: .module).data("dash_tidal_hires_timeline.mpd")))
        let stream = try await XCTUnwrapAsync(await source().stream(trackId: "t1", tier: .lossless))
        XCTAssertEqual(stream.format.codec, "flac")
        XCTAssertEqual(stream.format.isLossless, true)
        XCTAssertEqual(stream.format.sampleRateHz, 96_000)
        XCTAssertEqual(stream.mimeType, "application/x-mpegURL")
        XCTAssertTrue(SourcePlaylistLoader.handles(stream.url))
        let playlist = try XCTUnwrap(SourceManifestFiles(directory: manifestDirectory).playlistText(for: stream.url))
        XCTAssertEqual(playlist.components(separatedBy: "#EXTINF:").count - 1, 54)
    }

    /// `format: "mp4"` is a container in the field the Tidal answer used for a transport; it must not
    /// be opened as a manifest, and its codec must not come back unknown.
    func testAContainerInTheFormatFieldIsNotMistakenForATransport() async throws {
        let url = "https://aac.saavncdn.com/601/b81082b74fa06e4596b5b111b0115d1a_320.mp4"
        server.route("/manifest.json", manifest())
        server.route("/stream/t1", .json(#"{"url":"\#(url)","format":"mp4","quality":"320kbps","provider":"JioSaavn"}"#))
        let stream = try await XCTUnwrapAsync(await source().stream(trackId: "t1", tier: .best))
        XCTAssertEqual(stream.url.absoluteString, url)
        XCTAssertFalse(stream.isHLS)
        XCTAssertEqual(stream.format.kbps, 320)
        XCTAssertEqual(stream.format.codec, "mp4")
        XCTAssertEqual(stream.format.isLossless, false)
    }

    func testA200CarryingAnErrorAndNoURLIsAMiss() async throws {
        server.route("/manifest.json", manifest())
        server.route("/stream/t1", .json(#"{"error":"Deezer ARL required — set it in the setup page"}"#))
        let stream = try await source().stream(trackId: "t1", tier: .lossless)
        XCTAssertNil(stream)
    }

    func testAGatewayErrorOnAnUnknownIdIsAMissRatherThanACrash() async throws {
        server.route("/manifest.json", manifest())
        server.route("/stream/nope", .status(502))
        let stream = try await source().stream(trackId: "nope", tier: .lossless)
        XCTAssertNil(stream)
    }

    func testRealSearchRowsSurviveTheirProviderPrefixedIds() async throws {
        server.route("/manifest.json", manifest())
        server.route("/search", .json("""
        {"tracks":[{"id":"tidal:417594671","sourceId":"417594671","title":"Daylight","artist":"David Kushner","album":"Daylight",
          "albumId":"417594670","albumArtworkURL":"https://resources.tidal.com/images/x/1080x1080.jpg","trackNumber":1,"duration":212,
          "format":"flac","isrc":"QZXDB2300005","audioQuality":"LOSSLESS","provider":"Tidal","audioModes":["STEREO"]}],
         "albums":[],"artists":[],"playlists":[]}
        """))
        let songs = try await source().search("daylight", limit: 5)
        XCTAssertEqual(songs.count, 1)
        XCTAssertEqual(songs[0].sourceQuality, .lossless)
        XCTAssertEqual(songs[0].durationText, "3:32")
        XCTAssertTrue(songs[0].videoId.hasSuffix("::tidal:417594671"))
        XCTAssertEqual(songs[0].thumbnailUrl, "https://resources.tidal.com/images/x/1080x1080.jpg")
    }

    func testBitDepthAndSampleRateAreReadOutOfAFreeTextQualityLabel() async throws {
        server.route("/manifest.json", manifest())
        server.route("/stream/t1", .json(#"{"url":"https://cdn.test/a","quality":"FLAC 24-bit / 96 kHz"}"#))
        let format = try await XCTUnwrapAsync(await source().stream(trackId: "t1", tier: .lossless)).format
        XCTAssertEqual(format.bitDepth, 24)
        XCTAssertEqual(format.sampleRateHz, 96_000)
        XCTAssertEqual(format.codec, "flac")
    }

    // MARK: Registry flows

    /// The Sources screen's Test/Save: identify, refuse a duplicate, probe, store.
    @MainActor
    func testCheckIdentifiesProbesAndSavesAnAddon() async throws {
        server.route("/manifest.json", manifest())
        let registry = SourceRegistry(store: nil, environment: environment())
        let tested = await registry.check(FakeAddonServer.base + "/manifest.json", save: false)
        XCTAssertTrue(tested.isGood)
        XCTAssertEqual(tested.message, "Connected · Addon · Test Addon v2.1.0")
        XCTAssertFalse(registry.configs.contains { $0.kind == .addon })

        let saved = await registry.check(FakeAddonServer.base, save: true)
        XCTAssertTrue(saved.saved)
        XCTAssertEqual(registry.configs.first { $0.kind == .addon }?.label, "Test Addon")

        let again = await registry.check(FakeAddonServer.base + "/", save: true)
        XCTAssertFalse(again.isGood)
        XCTAssertEqual(again.message, "Test Addon is already added")
        XCTAssertEqual(registry.configs.filter { $0.kind == .addon }.count, 1)
    }
}

/// `XCTUnwrap` for an optional produced by an `await`.
func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
