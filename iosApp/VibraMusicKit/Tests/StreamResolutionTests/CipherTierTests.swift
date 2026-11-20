import XCTest
@testable import StreamResolution

/// The remote player-config table and its security locks (zemer's `PlayerConfigParser`).
final class PlayerConfigTableTests: XCTestCase {
    func testRecordedTableParsesAndKnowsTheRecordedPlayer() throws {
        guard case .success(let configs, _) = PlayerConfigTable.parse(StreamFixture.data("zemer_player_configs.json")) else {
            return XCTFail("recorded table rejected")
        }
        XCTAssertGreaterThan(configs.count, 400)
        XCTAssertEqual(configs["7460dd14"], PlayerScriptConfig(sigExpression: "hQ(40,3024,INPUT)", nClass: "ZO", signatureTimestamp: 20717))
        XCTAssertEqual(configs["57523767"], configs["7460dd14"], "aliases resolve to their entry")
    }

    /// Every value becomes JavaScript, so anything but the locked shapes is dropped.
    func testEntriesThatCouldCarryCodeAreSkipped() throws {
        let json = """
        {"schemaVersion":1,"players":{
          "aaaaaaaa":{"sig":"hQ(40,3024,INPUT)","nClass":"ZO","sts":1},
          "bbbbbbbb":{"sig":"alert(1)//(1,2,INPUT)","nClass":"ZO","sts":1},
          "cccccccc":{"sig":"hQ(40,3024,INPUT)","nClass":"ZO;fetch('x')","sts":1},
          "dddddddd":{"sig":"hQ(40,3024,INPUT)","nClass":"ZO","sts":"1"},
          "NOTAHASH":{"sig":"hQ(40,3024,INPUT)","nClass":"ZO","sts":1},
          "eeeeeeee":{"sig":"hQ(40,3024,INPUT)","nClass":"ZO","sts":0},
          "ffffffff":{"sig":"hQ(40,3024,INPUT)","nClass":"ZO","sts":1,"aliases":["BAD"]}
        }}
        """
        guard case .success(let configs, let skipped) = PlayerConfigTable.parse(Data(json.utf8)) else { return XCTFail() }
        XCTAssertEqual(Array(configs.keys), ["aaaaaaaa"])
        XCTAssertEqual(Set(skipped), ["bbbbbbbb", "cccccccc", "dddddddd", "NOTAHASH", "eeeeeeee", "ffffffff"])
    }

    func testFileLevelDefectsRejectTheWholeTable() {
        let cases = [
            "[]",
            "not json",
            #"{"players":{}}"#,
            #"{"schemaVersion":"1","players":{}}"#,
            #"{"schemaVersion":0,"players":{}}"#,
            #"{"schemaVersion":2,"players":{}}"#,
            #"{"schemaVersion":1}"#,
            #"{"schemaVersion":1,"players":{"aaaaaaaa":{"sig":"a(1,2,INPUT)","nClass":"b","sts":1,"aliases":["bbbbbbbb"]},"bbbbbbbb":{"sig":"a(1,2,INPUT)","nClass":"b","sts":1}}}"#,
        ]
        for json in cases {
            guard case .failure = PlayerConfigTable.parse(Data(json.utf8)) else { return XCTFail("accepted \(json)") }
        }
        guard case .success(let empty, _) = PlayerConfigTable.parse(Data(#"{"schemaVersion":1,"players":{}}"#.utf8)) else { return XCTFail() }
        XCTAssertTrue(empty.isEmpty)
    }

    /// Byte-equal to zemer's `n-template-Yx.golden`, which both its readers pin.
    func testNExpressionTemplateMatchesTheGolden() {
        XCTAssertEqual(
            PlayerScriptConfig.nExpression(nClass: "Yx"),
            "(function(n){try{var u=new g.Yx('https://x.googlevideo.com/videoplayback?n='+n,true);var t=u.get('n');return(t&&t!==n)?t:n;}catch(e){return n;}})(INPUT)"
        )
    }

    /// For a player the table does not know yet, the config is read from the player itself.
    func testDerivingFromTheRecordedPlayerAgreesWithTheTable() {
        XCTAssertEqual(
            PlayerScriptConfig.derive(fromPlayerSource: StreamFixture.playerSource),
            PlayerScriptConfig(sigExpression: "hQ(40,3024,INPUT)", nClass: "ZO", signatureTimestamp: 20717)
        )
        XCTAssertNil(PlayerScriptConfig.derive(fromPlayerSource: "var nothing = 1;"))
    }

    func testPlayerHashIsReadFromBothPlaces() {
        XCTAssertEqual(PlayerScriptLocator.hash(inIframeAPI: StreamFixture.string("iframe_api.js")), "7460dd14")
        XCTAssertEqual(PlayerScriptLocator.hash(inPath: "/s/player/7460dd14/player_es6.vflset/en_US/base.js"), "7460dd14")
        XCTAssertEqual(PlayerScriptLocator.scriptURL(hash: "7460dd14").absoluteString,
                       "https://www.youtube.com/s/player/7460dd14/player_ias.vflset/en_US/base.js")
    }
}

/// The recorded player running in JavaScriptCore. Golden values were produced by running the
/// same player in `jsc` and confirmed against googlevideo (HTTP 206 on the file's last 100 KB).
final class PlayerScriptRuntimeTests: XCTestCase {
    private static let config = PlayerScriptConfig(sigExpression: "hQ(40,3024,INPUT)", nClass: "ZO", signatureTimestamp: 20717)
    private static let runtime: PlayerScriptRuntime? = try? PlayerScriptRuntime(
        hash: StreamFixture.playerHash, playerSource: StreamFixture.playerSource, config: config
    )

    func testRecordedPlayerDeciphersTheRecordedSignature() throws {
        let runtime = try XCTUnwrap(Self.runtime)
        XCTAssertEqual(
            try runtime.decipherSignature("DgDgiigigx8x4PmkBEvB21LdwGhCX2x-bqGiwnrI-19Z74SvGGIC8ne2paHhinHBFMPnlFIV_wDEn49IRucDr2c3smIzh5TgIARwYJ2s0EAEA"),
            "AE0s2JYwRAIgT5hzIms3c2rDcuRI94nEDw_VIFlnPMFBHnXhHap2en8CIGGvS47Z91-IrnwiGqb-x2DChGwdL12BvEBkmP4x8xgi"
        )
    }

    func testRecordedPlayerTransformsN() throws {
        let runtime = try XCTUnwrap(Self.runtime)
        XCTAssertEqual(try runtime.transformN("SsGdbXIaiYFgItXgLe"), "SnTjuvmGhHvpug")
        XCTAssertEqual(try runtime.transformN("KdrqFlzJXl9EcCwlmEy"), "T4c96b3ERJuLBLA")
    }

    /// A wrong config must fail loudly at build time, not produce plausible garbage later.
    func testWrongConfigFailsTheSelfTest() {
        let wrongClass = PlayerScriptConfig(sigExpression: "hQ(40,3024,INPUT)", nClass: "Zz", signatureTimestamp: 20717)
        XCTAssertThrowsError(try PlayerScriptRuntime(hash: "7460dd14", playerSource: StreamFixture.playerSource, config: wrongClass))
        let wrongSig = PlayerScriptConfig(sigExpression: "noSuchFn(1,2,INPUT)", nClass: "ZO", signatureTimestamp: 20717)
        XCTAssertThrowsError(try PlayerScriptRuntime(hash: "7460dd14", playerSource: StreamFixture.playerSource, config: wrongSig))
    }

    func testExportsAreInjectedInsideTheClosure() {
        let injected = PlayerScriptRuntime.inject(exportsFor: Self.config, into: "var _yt_player={};(function(g){var a=1;})(_yt_player);")
        XCTAssertTrue(injected.contains("__vibramusic_sig = function(s){ return hQ(40,3024,s); };"))
        XCTAssertTrue(injected.hasSuffix(" })(_yt_player);"))
    }
}

/// `StreamCipherSolver` end to end, offline: iframe API, table and player served by a stub.
final class StreamCipherSolverTests: XCTestCase {
    private var cacheDirectory: URL!

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("CipherTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        super.tearDown()
    }

    private func server(table: StreamStubResponse? = nil, player: StreamStubResponse? = nil) -> StreamStubServer {
        StreamStubServer { request in
            if request.url.path == "/iframe_api" { return .text(StreamFixture.string("iframe_api.js")) }
            if request.url.path.hasSuffix("player_ias.vflset/en_US/base.js") {
                return player ?? StreamStubResponse(status: 200, headers: ["Content-Type": "text/javascript"], body: Data(StreamFixture.playerSource.utf8))
            }
            if request.url.host == "raw.githubusercontent.com" { return table ?? .json(StreamFixture.data("zemer_player_configs.json")) }
            return StreamStubResponse(status: 404)
        }
    }

    func testSignatureTimestampComesFromTheCurrentPlayer() async {
        let stub = server()
        let solver = StreamCipherSolver(session: stub.session, cacheDirectory: cacheDirectory)
        let sts = await solver.signatureTimestamp()
        XCTAssertEqual(sts, 20717)
    }

    func testRecordedWebRemixFormatDeciphersToTheGoldenURL() async throws {
        let stub = server()
        let solver = StreamCipherSolver(session: stub.session, cacheDirectory: cacheDirectory)
        let response = try StreamFixture.playerResponse("player_web_remix_cipher.json")
        let format = try XCTUnwrap(response.audioFormats.first { $0.itag == 140 })
        let url = try await solver.decipher(signatureCipher: try XCTUnwrap(format.signatureCipher))
        XCTAssertEqual(
            url.streamQueryValue("sig"),
            "AE0s2JYwRAIgT5hzIms3c2rDcuRI94nEDw_VIFlnPMFBHnXhHap2en8CIGGvS47Z91-IrnwiGqb-x2DChGwdL12BvEBkmP4x8xgi"
        )
        XCTAssertEqual(url.streamQueryValue("n"), "SnTjuvmGhHvpug")
        XCTAssertEqual(url.streamQueryValue("itag"), "140")
        XCTAssertEqual(url.host?.hasSuffix("googlevideo.com"), true)
        XCTAssertEqual(url.streamQueryValue("c"), "WEB_REMIX")
    }

    /// The ~3 MB script is downloaded once per version and kept on disk across instances.
    func testPlayerScriptIsCachedOnDisk() async {
        let stub = server()
        let first = StreamCipherSolver(session: stub.session, cacheDirectory: cacheDirectory)
        _ = await first.signatureTimestamp()
        let second = StreamCipherSolver(session: stub.session, cacheDirectory: cacheDirectory)
        _ = await second.signatureTimestamp()
        XCTAssertEqual(stub.requests.filter { $0.url.path.hasSuffix("base.js") }.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent("7460dd14.js").path))
    }

    /// A 200 that is not the player (a consent or captive-portal page) is never cached, and one
    /// already on disk is thrown away and fetched again.
    func testANonPlayerScriptIsNotKeptOnDisk() async throws {
        let file = cacheDirectory.appendingPathComponent("7460dd14.js")
        let consent = StreamStubResponse(status: 200, headers: ["Content-Type": "text/html"], body: Data("<html>consent</html>".utf8))
        _ = await StreamCipherSolver(session: server(player: consent).session, cacheDirectory: cacheDirectory).signatureTimestamp()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try Data("<html>consent</html>".utf8).write(to: file)
        let sts = await StreamCipherSolver(session: server().session, cacheDirectory: cacheDirectory).signatureTimestamp()
        XCTAssertEqual(sts, 20717)
    }

    /// A forced table refresh that lands spends the ten-minute cooldown. One that fails waits only a
    /// minute: a network that can't reach the table must not make every refused URL wait out the
    /// fetch's timeout, but a table that is back should be picked up soon.
    func testAFailedForcedRefreshBacksOffForAMinute() async {
        let clock = StreamTestClock()
        let failing = server(table: StreamStubResponse(status: 500))
        let solver = StreamCipherSolver(session: failing.session, cacheDirectory: nil, now: clock.function)
        func tableRequests() -> Int { failing.requests.filter { $0.url.host == "raw.githubusercontent.com" }.count }
        await solver.refreshAfterStreamRejection()
        await solver.refreshAfterStreamRejection()
        XCTAssertEqual(tableRequests(), 1, "a refusal right after a failed fetch doesn't fetch again")
        clock.advance(61)
        await solver.refreshAfterStreamRejection()
        XCTAssertEqual(tableRequests(), 2, "a minute later it tries again")

        let working = server()
        let fresh = StreamCipherSolver(session: working.session, cacheDirectory: nil, now: clock.function)
        await fresh.refreshAfterStreamRejection()
        clock.advance(61)
        await fresh.refreshAfterStreamRejection()
        XCTAssertEqual(working.requests.filter { $0.url.host == "raw.githubusercontent.com" }.count, 1,
                       "a refresh that landed waits out the whole cooldown")
    }

    /// An unreachable table is not fatal: the config is derived from the script.
    func testWorksWithoutTheRemoteTable() async {
        let stub = server(table: StreamStubResponse(status: 500))
        let solver = StreamCipherSolver(session: stub.session, cacheDirectory: cacheDirectory)
        let sts = await solver.signatureTimestamp()
        XCTAssertEqual(sts, 20717)
        let offline = StreamCipherSolver(session: server().session, cacheDirectory: nil, remoteConfigURL: nil)
        let derived = await offline.signatureTimestamp()
        XCTAssertEqual(derived, 20717)
    }

    /// A stale table entry fails the self-test; the derived config takes over.
    func testBadTableEntryFallsBackToTheDerivedConfig() async {
        let table = #"{"schemaVersion":1,"players":{"7460dd14":{"sig":"hQ(1,2,INPUT)","nClass":"Qq","sts":1}}}"#
        let stub = server(table: .json(Data(table.utf8)))
        let solver = StreamCipherSolver(session: stub.session, cacheDirectory: nil)
        let sts = await solver.signatureTimestamp()
        XCTAssertEqual(sts, 20717)
    }

    func testUnrunnablePlayerIsAnErrorNotACrash() async {
        let stub = server(table: StreamStubResponse(status: 500), player: .text("var nothing = 1;"))
        let solver = StreamCipherSolver(session: stub.session, cacheDirectory: nil)
        let sts = await solver.signatureTimestamp()
        XCTAssertNil(sts)
        do {
            _ = try await solver.decipher(signatureCipher: "s=abc&sp=sig&url=https%3A%2F%2Fx.googlevideo.com%2Fvideoplayback")
            XCTFail("expected an error")
        } catch {}
    }

    func testMalformedCipherIsRejected() async {
        let solver = StreamCipherSolver(session: server().session, cacheDirectory: nil)
        do {
            _ = try await solver.decipher(signatureCipher: "sp=sig")
            XCTFail("expected an error")
        } catch let error as StreamCipherSolver.CipherError {
            XCTAssertEqual(error, .malformedCipher)
        } catch {
            XCTFail("\(error)")
        }
    }

    /// The music shell's jsUrl stands in when the iframe loader cannot be read.
    func testFallsBackToTheShellForThePlayerVersion() async throws {
        let stub = StreamStubServer { request in
            if request.url.path == "/iframe_api" { return StreamStubResponse(status: 500) }
            if request.url.path.hasSuffix("base.js") { return .text(StreamFixture.playerSource) }
            return StreamStubResponse(status: 500)
        }
        let solver = StreamCipherSolver(session: stub.session, cacheDirectory: nil, fallbackHash: { "7460dd14" })
        let hash = try await solver.playerHash()
        XCTAssertEqual(hash, "7460dd14")
    }
}
