import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import InnerTube

/// The shape of every Innertube request: the WEB_REMIX identity, the locale, the visitor id, the
/// continuation form, retries, and what goes out signed out versus anonymously.
final class InnerTubeRequestTests: XCTestCase {
    private var stub: InnerTubeStub!

    override func setUp() {
        stub = InnerTubeStub()
        stub.on("browse", #"{"responseContext":{"visitorData":"CgtGSVJTVF9WSVNJVE9SKICAgICAgICAgAE%3D"}}"#)
    }

    func testSignedOutBrowseIsAPlainWebRemixRequest() async throws {
        let client = stub.makeClient(language: "fr")
        _ = try await client.browse("FEmusic_home", params: "PARAMS")

        let request = try XCTUnwrap(stub.requests(to: "browse").first)
        XCTAssertEqual(request.httpMethod, "POST")
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query, [URLQueryItem(name: "prettyPrint", value: "false"), URLQueryItem(name: "hl", value: "fr")])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Language"), "fr,en-US;q=0.8,en;q=0.7")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-YouTube-Client-Name"), "67")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-YouTube-Client-Version"), "1.20250101.01.00")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://music.youtube.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Origin"), "https://music.youtube.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://music.youtube.com/")
        for header in ["Cookie", "Authorization", "X-Goog-AuthUser", "X-Goog-PageId", "X-Goog-Visitor-Id"] {
            XCTAssertNil(request.value(forHTTPHeaderField: header), header)
        }

        let body = InnerTubeStub.body(of: request)
        XCTAssertEqual(body.s("browseId"), "FEmusic_home")
        XCTAssertEqual(body.s("params"), "PARAMS")
        let client_ = body.o("context").o("client")
        XCTAssertEqual(client_.s("clientName"), "WEB_REMIX")
        XCTAssertEqual(client_.s("clientVersion"), "1.20250101.01.00")
        XCTAssertEqual(client_.s("hl"), "fr")
        XCTAssertEqual(client_.s("gl"), "US")
        XCTAssertNil(client_.s("visitorData"))
        XCTAssertEqual(body.o("context").o("user").s("lockedSafetyMode"), "false")
        XCTAssertNil(body.o("context").o("user").s("onBehalfOfUser"))
        XCTAssertEqual(body.o("context").o("request").s("useSsl"), "true")
        // No session means no shell fetch either.
        XCTAssertEqual(stub.stub.requests.count, 1)
    }

    func testTheFirstVisitorIdIsKeptAndSentFromThenOn() async throws {
        let client = stub.makeClient()
        _ = try await client.browse("A")
        stub.on("browse", #"{"responseContext":{"visitorData":"CgtTRUNPTkRfVklTSVRPUiiAgICAgICAgIAB"}}"#)
        _ = try await client.browse("B")
        _ = try await client.browse("C")

        let requests = stub.requests(to: "browse")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "X-Goog-Visitor-Id"))
        for request in requests.dropFirst() {
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-Visitor-Id"), "CgtGSVJTVF9WSVNJVE9SKICAgICAgICAgAE%3D")
            XCTAssertEqual(InnerTubeStub.body(of: request).o("context").o("client").s("visitorData"), "CgtGSVJTVF9WSVNJVE9SKICAgICAgICAgAE%3D")
        }
    }

    func testContinuationsCarryTheTokenInTheBodyAndTheQuery() async throws {
        stub.on("search", "{}")
        let client = stub.makeClient()
        _ = try await client.browseContinuation("TOKEN+/=")
        _ = try await client.searchContinuation("SEARCH_TOKEN")

        let browse = try XCTUnwrap(stub.requests(to: "browse").first)
        let items = URLComponents(url: try XCTUnwrap(browse.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "ctoken" }?.value, "TOKEN+/=")
        XCTAssertEqual(items.first { $0.name == "continuation" }?.value, "TOKEN+/=")
        XCTAssertEqual(items.first { $0.name == "type" }?.value, "next")
        XCTAssertEqual(InnerTubeStub.body(of: browse).s("continuation"), "TOKEN+/=")
        XCTAssertEqual(InnerTubeStub.bodyField("continuation", of: try XCTUnwrap(stub.requests(to: "search").first)), "SEARCH_TOKEN")
    }

    func testEndpointBodies() async throws {
        for endpoint in ["next", "search", "music/get_search_suggestions", "get_transcript"] { stub.on(endpoint, "{}") }
        let client = stub.makeClient()
        _ = try await client.next(videoId: "5NV6Rdv1a3I")
        _ = try await client.search("daft punk", params: SearchFilter.songs.params)
        _ = try await client.searchSuggestions("daft p")
        _ = try await client.transcript(videoId: "khnokW3Mw24")

        let next = InnerTubeStub.body(of: try XCTUnwrap(stub.requests(to: "next").first))
        XCTAssertEqual(next.s("videoId"), "5NV6Rdv1a3I")
        XCTAssertEqual(next.s("playlistId"), "RDAMVM5NV6Rdv1a3I", "the radio mix YouTube Music would play")
        XCTAssertEqual(next.s("isAudioOnly"), "true")
        let search = InnerTubeStub.body(of: try XCTUnwrap(stub.requests(to: "search").first))
        XCTAssertEqual(search.s("query"), "daft punk")
        XCTAssertEqual(search.s("params"), "EgWKAQIIAWoKEAkQChAFEAMQBA==")
        XCTAssertEqual(InnerTubeStub.bodyField("input", of: try XCTUnwrap(stub.requests(to: "music/get_search_suggestions").first)), "daft p")
        XCTAssertEqual(InnerTubeStub.bodyField("params", of: try XCTUnwrap(stub.requests(to: "get_transcript").first)), InnerTubeClient.transcriptParams(videoId: "khnokW3Mw24"))
    }

    func testTypeaheadSearchNeverCarriesTheSession() async throws {
        stub.on("search", "{}")
        stub.stub.register(host: "music.youtube.com", path: "/", response: .text(try Fixtures.text("signed_in/music_shell_signed_in.html")))
        let client = stub.makeClient(language: "de")
        await client.setCookie("SID=1; SAPISID=secret")
        _ = try await client.searchTypeahead("perf")

        let request = try XCTUnwrap(stub.requests(to: "search").first)
        for header in ["Cookie", "Authorization", "X-Goog-AuthUser", "X-Goog-PageId"] {
            XCTAssertNil(request.value(forHTTPHeaderField: header), header)
        }
        let body = InnerTubeStub.body(of: request)
        XCTAssertNil(body.o("context").o("user").s("onBehalfOfUser"))
        XCTAssertEqual(body.o("context").o("client").s("hl"), "en", "anonymous lookups are asked in English, as on Android")
        XCTAssertEqual(body.s("query"), "perf")
        XCTAssertTrue(stub.stub.requests(toPath: "/").isEmpty, "an anonymous request has no reason to read the session's shell")
    }

    // MARK: - Failures

    func testTransportFailuresAreRetriedWithBackoff() async throws {
        let attempts = LockedCounter()
        let stub = self.stub!
        stub.stub.register(host: "music.youtube.com", path: "/youtubei/v1/browse") { _ in
            attempts.increment() < 3 ? .failure(.networkConnectionLost) : .json(#"{"ok":true}"#)
        }
        let response = try await stub.makeClient().browse("X")
        XCTAssertEqual(response.s("ok"), "true")
        XCTAssertEqual(stub.requests(to: "browse").count, 3)
    }

    func testTransportFailuresGiveUpAfterThreeAttempts() async {
        stub.stub.register(host: "music.youtube.com", path: "/youtubei/v1/browse", response: .failure(.notConnectedToInternet))
        do {
            _ = try await stub.makeClient().browse("X")
            XCTFail("expected a failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(stub.requests(to: "browse").count, 3)
    }

    func testATimeoutIsNotRetried() async {
        stub.stub.register(host: "music.youtube.com", path: "/youtubei/v1/browse", response: .failure(.timedOut))
        do {
            _ = try await stub.makeClient().browse("X")
            XCTFail("expected a failure")
        } catch {}
        XCTAssertEqual(stub.requests(to: "browse").count, 1, "a timeout is this app's own decision, not weather")
    }

    func testAnHTTPErrorIsAnAnswerNotRetried() async {
        stub.on("browse", #"{"error":{}}"#, status: 403)
        do {
            _ = try await stub.makeClient().browse("X")
            XCTFail("expected a failure")
        } catch let error as InnerTubeError {
            XCTAssertEqual(error, .httpStatus(403, endpoint: "browse"))
            XCTAssertTrue(error.isAuthRejection)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(stub.requests(to: "browse").count, 1)
    }

    func testABodyThatIsNotAJSONObjectIsAnInvalidResponse() async {
        stub.on("browse", "[1,2]")
        do {
            _ = try await stub.makeClient().browse("X")
            XCTFail("expected a failure")
        } catch let error as InnerTubeError {
            guard case .invalidResponse = error else { return XCTFail("unexpected \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - Visitor id bootstrap

    func testAVisitorIdIsMintedFromTheServiceWorkerData() async throws {
        stub.stub.register(host: "www.youtube.com", path: "/sw.js_data", response: .text(try Fixtures.text("sw_js_data.txt")))
        let client = stub.makeClient()
        let ensured = await client.ensureVisitorData()
        let minted = try XCTUnwrap(ensured)
        XCTAssertTrue(minted.hasPrefix("CgtVWmRDdjR5bmplWSj7s93VBjIK"))
        // Asked again, the one in hand is kept.
        _ = await client.ensureVisitorData()
        XCTAssertEqual(stub.stub.requests(toPath: "/sw.js_data").count, 1)
        _ = try await client.browse("X")
        XCTAssertEqual(stub.requests(to: "browse").first?.value(forHTTPHeaderField: "X-Goog-Visitor-Id"), minted)
    }

    func testTheVisitorIdIsFoundByShapeAnywhereInTheArrays() throws {
        let body = ")]}'\n[[\"a\",[null,1,\"CgtBQkNERUZHSElKSyiAgICAgICAgIAEyCgoCVVMSBBoAIAAxxxx\"]]]"
        XCTAssertEqual(try InnerTubeClient.visitorData(fromServiceWorkerData: body), "CgtBQkNERUZHSElKSyiAgICAgICAgIAEyCgoCVVMSBBoAIAAxxxx")
        XCTAssertNil(try InnerTubeClient.visitorData(fromServiceWorkerData: ")]}'\n[[\"Cgshort\"]]"))
    }

    // MARK: - Pings

    func testStatsPingsExtendTheBaseURLAndCarryTheSession() async throws {
        stub.stub.register(host: "s.youtube.com", response: .status(204))
        stub.stub.register(host: "music.youtube.com", path: "/", response: .text(try Fixtures.text("signed_in/music_shell_signed_in.html")))
        let client = stub.makeClient()
        await client.setCookie("SID=1; SAPISID=secret")

        let status = try await client.pingPlayback(baseUrl: "https://s.youtube.com/api/stats/playback?cl=1&el=detailpage", cpn: "CPN")
        XCTAssertEqual(status, 204)
        try await client.pingWatchtime(baseUrl: "https://s.youtube.com/api/stats/watchtime?cl=1", cpn: "CPN", seconds: 42, final: true)
        try await client.pingAtr(baseUrl: "https://s.youtube.com/api/stats/atr?ver=2&c=WEB_REMIX", cpn: "CPN")

        let pings = stub.stub.requests.filter { $0.url?.host() == "s.youtube.com" }
        XCTAssertEqual(pings.count, 3)
        let playback = try XCTUnwrap(pings[0].url?.query())
        XCTAssertTrue(playback.hasPrefix("cl=1&el=detailpage&ver=2&c=WEB_REMIX&cver=1.20260922.09.00&cpn=CPN&cplayer=UNIPLAYER"), playback)
        XCTAssertFalse(playback.contains("el=detailpage&el="), "no second el")
        let watchtime = try XCTUnwrap(pings[1].url?.query())
        XCTAssertTrue(watchtime.hasSuffix("&st=0&et=42&cmt=42&state=paused&final=1"), watchtime)
        XCTAssertEqual(pings[2].url?.query(), "ver=2&c=WEB_REMIX&cpn=CPN", "atr's base URL already carries ver, c and cver")

        for ping in pings {
            XCTAssertEqual(ping.value(forHTTPHeaderField: "Cookie"), "SID=1; SAPISID=secret")
            XCTAssertEqual(ping.value(forHTTPHeaderField: "X-Goog-AuthUser"), "1")
            XCTAssertEqual(ping.value(forHTTPHeaderField: "X-Goog-PageId"), "113355")
            XCTAssertEqual(ping.value(forHTTPHeaderField: "X-Goog-Visitor-Id"), "CgtTRVNTSU9OX0JPVU5EKICAgICAgICAgAEyCgoCVVMSBBoAIAA%3D")
            XCTAssertEqual(ping.value(forHTTPHeaderField: "Authorization"), "SAPISIDHASH 1700000000_d2a0deeb95ea263a68778d9e9ac8840dce59d800")
        }
    }

    func testPlaybackTrackingIsOnlyAskedForWithASession() async throws {
        stub.on("player", try Fixtures.text("signed_in/player_tracking.json"))
        stub.stub.register(host: "music.youtube.com", path: "/", response: .text(try Fixtures.text("signed_in/music_shell_signed_in_personal.html")))
        let client = stub.makeClient()
        let guest = try await client.playbackTracking(videoId: "FGBhQbmPwH8", signatureTimestamp: 20717)
        XCTAssertNil(guest)
        XCTAssertTrue(stub.requests(to: "player").isEmpty)

        await client.setCookie("SAPISID=secret")
        let tracking = try await client.playbackTracking(videoId: "FGBhQbmPwH8", signatureTimestamp: 20717)
        XCTAssertEqual(tracking?.atrAfterSeconds, 7)
        let body = InnerTubeStub.body(of: try XCTUnwrap(stub.requests(to: "player").first))
        XCTAssertEqual(body.s("videoId"), "FGBhQbmPwH8")
        XCTAssertEqual(body.s("contentCheckOk"), "true")
        let context = body.o("playbackContext").o("contentPlaybackContext")
        XCTAssertEqual(context.s("signatureTimestamp"), "20717")
        XCTAssertEqual(context.s("html5Preference"), "HTML5_PREF_WANTS")
        XCTAssertEqual(context.s("referer"), "https://music.youtube.com/watch?v=FGBhQbmPwH8")
    }

    func testANewCpnIsSixteenCharactersOfTheNonceAlphabet() {
        let alphabet = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let cpns = (0..<50).map { _ in InnerTubeClient.newCpn() }
        XCTAssertTrue(cpns.allSatisfy { $0.count == 16 && $0.allSatisfy(alphabet.contains) })
        XCTAssertGreaterThan(Set(cpns).count, 45)
    }
}
