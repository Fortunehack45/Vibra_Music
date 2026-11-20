import XCTest
@testable import StreamResolution

/// Acquiring, caching and refreshing the visitor id (Android's `ensureVisitorData`).
final class StreamVisitorDataStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "StreamVisitorDataStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private let shellVisitor = firstMatch(#""VISITOR_DATA":"([^"]+)""#, in: StreamFixture.string("music_shell_signed_out.html"))!

    private func shellServer(shell: StreamStubResponse? = nil, worker: StreamStubResponse? = nil) -> StreamStubServer {
        StreamStubServer { request in
            switch request.url.host {
            case "music.youtube.com": return shell ?? .text(StreamFixture.string("music_shell_signed_out.html"))
            case "www.youtube.com": return worker ?? .text(StreamFixture.string("sw_js_data.txt"))
            default: return StreamStubResponse(status: 404)
            }
        }
    }

    func testShellFactsParseFromTheRecordedShell() {
        let facts = MusicShellFacts.parse(StreamFixture.string("music_shell_signed_out.html"))
        XCTAssertEqual(facts.clientVersion, "1.20260922.09.00")
        XCTAssertEqual(facts.playerJsPath, "/s/player/7460dd14/player_es6.vflset/en_US/base.js")
        XCTAssertEqual(facts.playerHash, "7460dd14")
        XCTAssertEqual(facts.loggedIn, false)
        XCTAssertTrue(StreamVisitorDataStore.looksLikeVisitorData(facts.visitorData ?? ""))
    }

    /// The bootstrap answers with an anti-hijacking prefix then nested arrays; found by shape.
    func testServiceWorkerDataYieldsAVisitorId() throws {
        let found = try XCTUnwrap(StreamVisitorDataStore.visitorData(fromServiceWorkerData: StreamFixture.string("sw_js_data.txt")))
        XCTAssertTrue(found.hasPrefix("Cg"))
        XCTAssertNil(StreamVisitorDataStore.visitorData(fromServiceWorkerData: ")]}'\n[[\"nothing\",1]]"))
    }

    func testFetchesOnceThenServesFromMemory() async {
        let server = shellServer()
        let store = StreamVisitorDataStore(session: server.session)
        let first = await store.visitorData()
        let second = await store.visitorData()
        XCTAssertEqual(first, shellVisitor)
        XCTAssertEqual(second, shellVisitor)
        XCTAssertEqual(server.requests.count, 1)
    }

    func testConcurrentCallersShareOneFetch() async {
        let server = shellServer()
        let store = StreamVisitorDataStore(session: server.session)
        async let a = store.visitorData()
        async let b = store.visitorData()
        async let c = store.visitorData()
        let results = await [a, b, c]
        XCTAssertEqual(Set(results.compactMap { $0 }), [shellVisitor])
        XCTAssertEqual(server.requests.count, 1)
    }

    func testFallsBackToTheServiceWorkerWhenTheShellFails() async {
        let server = shellServer(shell: StreamStubResponse(status: 503))
        let store = StreamVisitorDataStore(session: server.session)
        let value = await store.visitorData()
        XCTAssertEqual(value, StreamVisitorDataStore.visitorData(fromServiceWorkerData: StreamFixture.string("sw_js_data.txt")))
        XCTAssertEqual(server.requests.map(\.url.host), ["music.youtube.com", "www.youtube.com"])
    }

    func testNoIdAnywhereIsNilNotACrash() async {
        let server = shellServer(shell: StreamStubResponse(status: 500), worker: StreamStubResponse(status: 500))
        let value = await StreamVisitorDataStore(session: server.session).visitorData()
        XCTAssertNil(value)
    }

    func testRefreshTakesAFreshId() async {
        var served = 0
        let server = StreamStubServer { _ in
            served += 1
            return .text(#"<script>ytcfg.set({"VISITOR_DATA":"Cg\#(String(repeating: "A", count: 40))\#(served)"})</script>"#)
        }
        let store = StreamVisitorDataStore(session: server.session)
        let first = await store.visitorData()
        let refreshed = await store.visitorData(refresh: true)
        XCTAssertNotEqual(first, refreshed)
        XCTAssertEqual(server.requests.count, 2)
    }

    /// A session-bound id outranks an anonymous one; only an explicit refresh replaces it.
    func testSessionBoundIdIsNotReplacedByAnAnonymousOne() async {
        let server = shellServer()
        let store = StreamVisitorDataStore(session: server.session)
        let bound = "Cg" + String(repeating: "B", count: 42)
        await store.adoptSessionBound(bound)
        let kept = await store.visitorData()
        XCTAssertEqual(kept, bound)
        XCTAssertTrue(server.requests.isEmpty)
        let refreshed = await store.visitorData(refresh: true)
        XCTAssertEqual(refreshed, shellVisitor)
    }

    func testPersistsAcrossInstancesUntilItAges() async {
        let clock = StreamTestClock()
        let server = shellServer()
        let first = StreamVisitorDataStore(session: server.session, defaults: defaults, maxAge: 3600, now: clock.function)
        _ = await first.visitorData()
        let relaunched = StreamVisitorDataStore(session: server.session, defaults: defaults, maxAge: 3600, now: clock.function)
        let fromDisk = await relaunched.current
        XCTAssertEqual(fromDisk, shellVisitor)
        clock.advance(3601)
        let aged = StreamVisitorDataStore(session: server.session, defaults: defaults, maxAge: 3600, now: clock.function)
        let nothing = await aged.current
        XCTAssertNil(nothing)
    }

    func testInvalidateForgetsTheIdEverywhere() async {
        let server = shellServer()
        let store = StreamVisitorDataStore(session: server.session, defaults: defaults)
        _ = await store.visitorData()
        await store.invalidate()
        let gone = await store.current
        XCTAssertNil(gone)
        XCTAssertNil(defaults.string(forKey: StreamVisitorDataStore.defaultsValueKey))
    }

    func testShellIsReadOnceForItsFacts() async {
        let server = shellServer()
        let store = StreamVisitorDataStore(session: server.session)
        let shell = await store.musicShell()
        XCTAssertEqual(shell?.playerHash, "7460dd14")
        let version = await store.shellClientVersion
        XCTAssertEqual(version, "1.20260922.09.00")
        _ = await store.visitorData()
        XCTAssertEqual(server.requests.count, 1)
    }
}
