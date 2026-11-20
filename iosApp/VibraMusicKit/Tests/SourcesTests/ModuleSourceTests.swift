import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import Sources

/// Legacy JS module sources, executed in JavaScriptCore against a stubbed network: the index, the
/// download, the engine (session state kept between calls, `fetch`, `setTimeout`, `context.settings`),
/// the fan-out and the stream answer rules.
final class ModuleSourceTests: XCTestCase {
    private let fixtures = FixtureLoader(bundle: .module)
    private var stub: URLProtocolStub!

    override func setUpWithError() throws {
        stub = URLProtocolStub()
        stub.register(matching: { _ in true }) { _ in .status(404) }
        stub.register(url: URL(string: "https://modules.example.com/index.json")!, response: .data(try fixtures.data("module_index.json")))
        stub.register(url: URL(string: "https://modules.example.com/echo.js")!, response: .data(try fixtures.data("module_echo.js")))
        stub.register(url: URL(string: "https://modules.example.com/lib/template.js")!, response: .data(try fixtures.data("module_template.js")))
        // echo.js's relative `fetch('/session')` resolves against the directory it was downloaded from.
        stub.register(url: URL(string: "https://modules.example.com/session")!, response: .json(#"{"token":"tok-123"}"#))
        stub.register(host: "api.example.com", path: "/search") { request in
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
            let body: [String: Any] = ["items": [
                ["id": "e1", "title": query, "artist": auth, "album": "Echoes", "seconds": 245, "quality": "LOSSLESS"],
                ["id": "e2", "title": "Second", "artist": "B", "album": "", "seconds": 61, "quality": "320kbps"],
            ]]
            return .data(try JSONSerialization.data(withJSONObject: body), headers: ["Content-Type": "application/json"])
        }
    }

    private func environment(atmos: Bool = false) -> SourceEnvironment {
        SourceEnvironment(session: stub.makeSession(), deviceCodecs: .fixed(true), dolbyAtmosEnabled: { atmos })
    }

    private func source(atmos: Bool = false) -> ModuleSource {
        ModuleSource(
            config: SourceConfig(id: "mods", kind: .customModule, label: "My modules", baseUrl: "https://modules.example.com/index.json"),
            environment: environment(atmos: atmos)
        )
    }

    // MARK: Index

    func testTheIndexIsReadUnderEveryCategoryButTheExcludedOnesAndDeduplicated() throws {
        let modules = try ModuleIndex.parseModules(try fixtures.data("module_index.json"))
        XCTAssertEqual(modules.map(\.id), ["echo", "template"])
        XCTAssertEqual(modules[0].tags, ["FLAC", "Lossless"])
        XCTAssertTrue(modules[0].isLossless)
        XCTAssertEqual(modules[1].tags, ["HIGH"], "labels stand in when tags are absent")
    }

    func testHealthCountsTheModules() async {
        let health = await source().health()
        XCTAssertEqual(health, .ok(detail: "2 modules"))
        let missing = ModuleSource(config: SourceConfig(kind: .customModule, baseUrl: ""), environment: environment())
        let noURL = await missing.health()
        XCTAssertEqual(noURL, .rejected("A module index URL is required"))
    }

    // MARK: The engine

    /// The session token fetched at load time survives into the search call, arguments arrive as
    /// real values (a quote in the query doesn't break the call), and the answer is JSON.
    func testTheEngineKeepsModuleStateBetweenCallsAndPassesArgumentsAsValues() async throws {
        let pool = ModuleScriptPool(session: stub.makeSession())
        try await pool.load("echo", jsCode: try fixtures.string("module_echo.js"), fetchBase: "https://modules.example.com")
        let raw = try await pool.call("echo", function: "searchTracks", argumentsJSON: #"["Don't \"Stop\"", 5, {"settings":{}}]"#).get()
        let response = try JSONDecoder().decode(ModuleSearchResponse.self, from: Data(raw.utf8))
        XCTAssertEqual(response.total, 2)
        XCTAssertEqual(response.tracks.first?.title, #"Don't "Stop""#)
        XCTAssertEqual(response.tracks.first?.artist, "Bearer tok-123")
    }

    func testAThrowingExportComesBackAsAnErrorAnswerAndAMissingOneAsAFailure() async throws {
        let pool = ModuleScriptPool(session: stub.makeSession())
        try await pool.load("echo", jsCode: try fixtures.string("module_echo.js"), fetchBase: "https://modules.example.com")
        let context = #"{"settings":{"quality":{"value":"HIGH"},"fallbackMode":{"value":"flexible"},"dolbyAtmos":{"value":"false"}}}"#
        let thrown = try await pool.call("echo", function: "getTrackStreamUrl", argumentsJSON: #"["broken","HIGH",\#(context)]"#).get()
        XCTAssertEqual(thrown, #"{"error":"backend exploded"}"#)
        let missing = await pool.call("echo", function: "getAlbum", argumentsJSON: "[]")
        XCTAssertThrowsError(try missing.get())
        let unloaded = await pool.call("nobody", function: "searchTracks", argumentsJSON: "[]")
        XCTAssertThrowsError(try unloaded.get())
    }

    func testAModuleWhoseInitThrowsIsRefusedAtLoad() async throws {
        let pool = ModuleScriptPool(session: stub.makeSession())
        do {
            try await pool.load("bad", jsCode: "throw new Error('no token for you');", fetchBase: "")
            XCTFail("a module whose init throws was loaded")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no token for you"), error.localizedDescription)
        }
        let loaded = await pool.isLoaded("bad")
        XCTAssertFalse(loaded)
    }

    /// ES-module exports are stripped; a module that never assigns `module.exports` still has its
    /// top-level functions found.
    func testESModuleExportsArePickedUp() async throws {
        let pool = ModuleScriptPool(session: stub.makeSession())
        let code = """
        export async function searchTracks(query) { return { tracks: [{ id: "1", title: query, artist: "A" }], total: 1 }; }
        export async function getTrackStreamUrl(id) { return { streamUrl: "https://cdn.example.com/" + id + ".flac" }; }
        export { searchTracks as search };
        """
        try await pool.load("esm", jsCode: code, fetchBase: "")
        let raw = try await pool.call("esm", function: "getTrackStreamUrl", argumentsJSON: #"["42"]"#).get()
        XCTAssertEqual(raw, #"{"streamUrl":"https://cdn.example.com/42.flac"}"#)
    }

    func testTheTemplateLiteralFormatIsUnwrapped() {
        let unwrapped = ModuleScriptEngine.preprocess((try? fixtures.string("module_template.js")) ?? "")
        XCTAssertTrue(unwrapped.hasPrefix("// a template literal module"), unwrapped)
        XCTAssertTrue(unwrapped.hasSuffix("module.exports = { searchTracks, getTrackStreamUrl };"), unwrapped)
    }

    /// Concurrent callers on one module get separate engines (up to three), so one slow call doesn't
    /// queue the rest, and every call still gets its own answer.
    func testConcurrentCallsEachGetTheirOwnAnswer() async throws {
        let pool = ModuleScriptPool(session: stub.makeSession())
        let code = """
        module.exports = { getTrackStreamUrl: async function (id) { await setTimeout(null, 30); return { streamUrl: "https://cdn.example.com/" + id }; } };
        """
        try await pool.load("slow", jsCode: code, fetchBase: "")
        let answers = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<8 {
                group.addTask { try await pool.call("slow", function: "getTrackStreamUrl", argumentsJSON: "[\"\(index)\"]").get() }
            }
            return try await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        XCTAssertEqual(answers, Set((0..<8).map { #"{"streamUrl":"https://cdn.example.com/\#($0)"}"# }))
    }

    /// The overlap itself: each engine has its own JavaScript state, so three calls that are all in
    /// flight at once come back from three different engines. One serialized engine would answer
    /// all three with the same number.
    func testCallsInFlightTogetherRunOnSeparateEngines() async throws {
        let pool = ModuleScriptPool(session: stub.makeSession())
        let code = """
        var engine = Math.random();
        module.exports = { getTrackStreamUrl: async function () { await setTimeout(null, 300); return { streamUrl: "https://cdn.example.com/" + engine }; } };
        """
        try await pool.load("overlap", jsCode: code, fetchBase: "")
        let answers = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<ModuleScriptPool.enginesPerModule {
                group.addTask { try await pool.call("overlap", function: "getTrackStreamUrl", argumentsJSON: "[]").get() }
            }
            return try await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        XCTAssertEqual(answers.count, ModuleScriptPool.enginesPerModule)
    }

    /// A module's timer delay comes straight from its JavaScript. A finite delay past about
    /// 1.8e13 ms overflowed the conversion to nanoseconds, which traps. One past a day now fires at
    /// once instead of sleeping the context away.
    func testATimerDelayPastTheCapFiresAtOnce() async throws {
        let pool = ModuleScriptPool(session: stub.makeSession())
        let code = "module.exports = { getTrackStreamUrl: async function () { await setTimeout(null, 1e14); return { ok: true }; } };"
        try await pool.load("timer", jsCode: code, fetchBase: "")
        let answer = try await pool.call("timer", function: "getTrackStreamUrl", argumentsJSON: "[]", timeout: 5).get()
        XCTAssertEqual(answer, #"{"ok":true}"#)
    }

    func testRelativeFetchURLsResolveAgainstTheModulesOwnDirectory() {
        XCTAssertEqual(ModuleScriptEngine.resolveURL("/session", base: "https://m.example.com/lib"), "https://m.example.com/session")
        XCTAssertEqual(ModuleScriptEngine.resolveURL("data.json", base: "https://m.example.com/lib"), "https://m.example.com/lib/data.json")
        XCTAssertEqual(ModuleScriptEngine.resolveURL("https://other.example/x", base: "https://m.example.com/lib"), "https://other.example/x")
    }

    // MARK: The source

    /// Every module asked, answers interleaved (first of each before second of any), ids packed as
    /// `<module>::<upstream>` behind the source key, tiers read off the rows.
    func testSearchFansOutToEveryModuleAndInterleavesTheirAnswers() async throws {
        let songs = try await source().search("Kesariya", limit: 10)
        XCTAssertEqual(songs.map(\.title), ["Kesariya", "Template Song", "Second"])
        XCTAssertEqual(songs[0].videoId, "src:mods::echo::e1")
        XCTAssertEqual(songs[0].durationText, "4:05")
        XCTAssertEqual(songs[0].sourceQuality, .lossless)
        XCTAssertEqual(songs[0].thumbnailUrl, "https://img.example.com/e1.jpg")
        XCTAssertEqual(songs[1].videoId, "src:mods::template::t-1")
        XCTAssertEqual(songs[2].sourceQuality, .high)
        // The index was fetched once for all of it.
        XCTAssertEqual(stub.requests.filter { $0.url?.path == "/index.json" }.count, 1)
    }

    func testTheStreamCarriesTheTierAsArgumentAndSettingAndIsDescribed() async throws {
        let source = source(atmos: true)
        let stream = try await XCTUnwrapAsync(try await source.stream(trackId: "echo::e1", tier: .lossless))
        XCTAssertEqual(stream.url.absoluteString, "https://cdn.example.com/e1.flac?mode=strict&atmos=true")
        XCTAssertEqual(stream.origin, .module)
        XCTAssertEqual(stream.format.codec, "flac")
        XCTAssertEqual(stream.format.bitDepth, 24)
        XCTAssertEqual(stream.format.sampleRateHz, 96_000, "a kHz figure in the Hz field is scaled")
        XCTAssertNotNil(stream.expiresAt)

        let lossy = try await XCTUnwrapAsync(try await source.stream(trackId: "echo::e2", tier: .best))
        XCTAssertEqual(lossy.url.absoluteString, "https://cdn.example.com/e2.320.mp3?mode=flexible&atmos=true")
        XCTAssertEqual(lossy.format.codec, "mp3")
        XCTAssertEqual(lossy.format.kbps, 320)
    }

    func testANullStreamURLAThrowAndAnUnknownModuleAreMisses() async throws {
        let source = source()
        let missing = try await source.stream(trackId: "echo::missing", tier: .lossless)
        let broken = try await source.stream(trackId: "echo::broken", tier: .lossless)
        let unknown = try await source.stream(trackId: "nobody::x", tier: .lossless)
        let malformedId = try await source.stream(trackId: "no-separator", tier: .lossless)
        XCTAssertNil(missing)
        XCTAssertNil(broken)
        XCTAssertNil(unknown)
        XCTAssertNil(malformedId)
    }

    func testRowTierPrefersWhatTheRowStatesOverItsMenu() throws {
        let stated = try JSONDecoder().decode(ModuleSearchResult.self, from: Data(#"{"id":"1","audioQuality":"128kbps","availableQualities":["LOSSLESS","HIGH"]}"#.utf8))
        XCTAssertEqual(ModuleSource.rowTier(stated), .low)
        let menuOnly = try JSONDecoder().decode(ModuleSearchResult.self, from: Data(#"{"id":"1","availableQualities":["LOW","LOSSLESS","HIGH"]}"#.utf8))
        XCTAssertEqual(ModuleSource.rowTier(menuOnly), .lossless)
    }

    func testInterleaveTakesNthPlaceEverywhereBeforeSecondPlaceAnywhere() {
        func songs(_ ids: String...) -> [Song] { ids.map { Song(videoId: $0, title: $0, artist: "") } }
        XCTAssertEqual(ModuleSource.interleave([songs("a1", "a2", "a3"), songs("b1"), songs("c1", "c2")]).map(\.videoId),
                       ["a1", "b1", "c1", "a2", "c2", "a3"])
    }

    // MARK: Stream URLs a module should not be trusted with (Android SourcesTest)

    func testRejectsAStreamURLCarryingASecondCopyOfItsOwnOrigin() {
        let blob = "eyJhbGciOiJIUzI1NiJ9"
        XCTAssertTrue(ModuleSource.malformed("https://sp-ad-fa.audio.tidal.com/mediatracks/\(blob)/https://sp-ad-fa.audio.tidal.com/mediatracks/\(blob)/0.mp4?token=1756000000~c2ln"))
        XCTAssertFalse(ModuleSource.malformed("https://sp-ad-fa.audio.tidal.com/mediatracks/\(blob)/0.mp4?token=1756000000~c2ln"))
    }

    func testAcceptsAURLThatPassesAnotherURLAlongToAProxy() {
        XCTAssertFalse(ModuleSource.malformed("https://cdn.example.com/get?url=https://real.host/f.flac"))
        XCTAssertFalse(ModuleSource.malformed("https://cdn.example.com/https://real.host/f.flac"))
    }

    func testRejectsAStreamURLThePlayersOwnParserWouldRefuse() {
        for url in ["/mediatracks/blob/0.mp4", "sp-ad-fa.audio.tidal.com/mediatracks/blob/0.mp4", "vibramusic://watch?v=rpemDBaFK0c", "", "undefined", "null", "https://cdn.example.com/a b.flac"] {
            XCTAssertTrue(ModuleSource.malformed(url), url)
        }
    }

    func testRefusesToLetAModulePointThePlayerAtAnythingButHTTP() {
        XCTAssertTrue(ModuleSource.malformed("file:///var/mobile/Containers/Data/x.flac"))
        XCTAssertTrue(ModuleSource.malformed("content://media/external/audio/media/42"))
        XCTAssertTrue(ModuleSource.malformed("ftp://cdn.example.com/f.mp3"))
    }

    func testAcceptsAnOriginWithNoPathOfItsOwn() {
        XCTAssertFalse(ModuleSource.malformed("https://sp-ad-fa.audio.tidal.com"))
    }

    // MARK: Quality tiers

    func testReadsATierOutOfWhateverAModuleCallsIt() {
        XCTAssertEqual(ModuleSource.qualityTier("LOSSLESS"), "LOSSLESS")
        XCTAssertEqual(ModuleSource.qualityTier("FLAC 16-bit / 44.1kHz"), "LOSSLESS")
        XCTAssertEqual(ModuleSource.qualityTier("hires-96"), "LOSSLESS")
        XCTAssertEqual(ModuleSource.qualityTier("HIGH"), "HIGH")
        XCTAssertEqual(ModuleSource.qualityTier("320kbps"), "HIGH")
        XCTAssertEqual(ModuleSource.qualityTier("128kbps"), "LOW")
        XCTAssertEqual(ModuleSource.qualityTier("LOW"), "LOW")
        XCTAssertNil(ModuleSource.qualityTier(""))
        XCTAssertNil(ModuleSource.qualityTier("Deadbeat"))
    }

    func testDoesNotMistakeABitDepthForABitrateTier() {
        XCTAssertEqual(ModuleSource.qualityTier("24-bit / 192 kHz"), "LOSSLESS")
        XCTAssertEqual(ModuleSource.qualityTier("FLAC 128"), "LOSSLESS")
    }

    func testOrdersTiersWorstToBest() {
        XCTAssertEqual(ModuleSource.tiers, ["LOW", "HIGH", "LOSSLESS"])
    }

    func testTheTierAskedForFollowsTheRequest() {
        XCTAssertEqual(ModuleSource.tierName(.lossless), "LOSSLESS")
        XCTAssertEqual(ModuleSource.tierName(.best), "HIGH")
        XCTAssertEqual(ModuleSource.tierName(.capped(kbps: 64)), "LOW")
        XCTAssertEqual(ModuleSource.tierName(.capped(kbps: 256)), "HIGH")
    }

    /// An Atmos-only answer (the Tidal module asks for MAX whatever it's told) is refused on a device
    /// or setting that won't play it, so another source can be heard.
    func testAnAtmosAnswerIsRefusedWhenAtmosIsNotWanted() async throws {
        stub.register(url: URL(string: "https://modules.example.com/echo.js")!, response: .text("""
        module.exports = {
          searchTracks: async function () { return { tracks: [] }; },
          getTrackStreamUrl: async function (id) { return { streamUrl: "https://cdn.example.com/" + id + ".m3u8", track: { audioQuality: "DOLBY_ATMOS EAC3_JOC" } }; }
        };
        """))
        let refused = try await source(atmos: false).stream(trackId: "echo::x", tier: .lossless)
        XCTAssertNil(refused)
        let played = try await source(atmos: true).stream(trackId: "echo::x", tier: .lossless)
        XCTAssertEqual(played?.format.codec, "eac3-joc")
        XCTAssertEqual(played?.isHLS, true)
    }
}
