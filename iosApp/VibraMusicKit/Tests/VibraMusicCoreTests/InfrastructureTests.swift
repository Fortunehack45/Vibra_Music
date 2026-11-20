import XCTest
import VibraMusicTestSupport
@testable import VibraMusicCore

final class JSONFileStoreTests: XCTestCase {
    private struct Record: Codable, Equatable {
        var name: String
        var at: Date
    }

    func testSavesAndLoadsCodableValues() throws {
        let store = JSONFileStore(directory: try makeTemporaryDirectory().appending(path: "nested/dir"))
        let record = Record(name: "one", at: Date(timeIntervalSince1970: 1_700_000_000))
        try store.save(record, to: "record.json")
        XCTAssertTrue(store.exists("record.json"))
        XCTAssertEqual(try store.load(Record.self, from: "record.json"), record)
        XCTAssertEqual(try store.fileNames(), ["record.json"])
    }

    func testAMissingFileLoadsAsNil() throws {
        let store = JSONFileStore(directory: try makeTemporaryDirectory())
        XCTAssertNil(try store.load(Record.self, from: "absent.json"))
        XCTAssertEqual(try JSONFileStore(directory: try makeTemporaryDirectory().appending(path: "never-created")).fileNames(), [])
    }

    func testACorruptFileThrowsRatherThanReadingAsEmpty() throws {
        let store = JSONFileStore(directory: try makeTemporaryDirectory())
        try Data("{not json".utf8).write(to: store.url(for: "bad.json"))
        XCTAssertThrowsError(try store.load(Record.self, from: "bad.json"))
    }

    func testOverwritesAtomicallyAndRemoves() throws {
        let store = JSONFileStore(directory: try makeTemporaryDirectory())
        try store.save([1, 2, 3], to: "numbers.json")
        try store.save([4], to: "numbers.json")
        XCTAssertEqual(try store.load([Int].self, from: "numbers.json"), [4])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.directory.path(percentEncoded: false))
        XCTAssertEqual(leftovers, ["numbers.json"], "no temporary files left behind")
        try store.remove("numbers.json")
        try store.remove("numbers.json")
        XCTAssertFalse(store.exists("numbers.json"))
    }

    func testTheDefaultLocationIsApplicationSupport() {
        let store = JSONFileStore.applicationSupport("Queue")
        XCTAssertTrue(store.directory.path(percentEncoded: false).contains("Application Support/Vibra Music/Queue"))
    }
}

final class URLProtocolStubTests: XCTestCase {
    func testAnswersByHostAndPathAndRecordsRequests() async throws {
        let stub = URLProtocolStub()
        stub.register(host: "music.youtube.com", path: "/youtubei/v1/search", method: "POST", response: .json(#"{"ok":true}"#))
        var request = URLRequest(url: URL(string: "https://music.youtube.com/youtubei/v1/search?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"query":"daft punk"}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await stub.makeSession().data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"ok":true}"#)

        let recorded = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(recorded.httpMethod, "POST")
        XCTAssertEqual(recorded.httpBody.map { String(decoding: $0, as: UTF8.self) }, #"{"query":"daft punk"}"#, "the body is readable")
        XCTAssertNil(recorded.value(forHTTPHeaderField: "X-Vibra Music-URLProtocolStub"), "the routing header is hidden")
        XCTAssertEqual(stub.requests(toPath: "/youtubei/v1/search").count, 1)
    }

    func testMatchesExactURLsIncludingTheirQuery() async throws {
        let stub = URLProtocolStub()
        stub.register(url: URL(string: "https://api.example.com/v1/track?id=2&fmt=json")!, response: .text("two"))
        stub.register(url: URL(string: "https://api.example.com/v1/other")!, response: .text("other"))
        let session = stub.makeSession()

        let (two, _) = try await session.data(from: URL(string: "https://api.example.com/v1/track?fmt=json&id=2")!)
        XCTAssertEqual(String(decoding: two, as: UTF8.self), "two", "query items match in any order")
        let (other, _) = try await session.data(from: URL(string: "https://api.example.com/v1/other?anything=1")!)
        XCTAssertEqual(String(decoding: other, as: UTF8.self), "other", "a route without a query matches any query")

        do {
            _ = try await session.data(from: URL(string: "https://api.example.com/v1/track?id=3&fmt=json")!)
            XCTFail("an unmatched request must fail")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .unsupportedURL)
        }
        XCTAssertEqual(stub.unmatchedRequests.count, 1)
    }

    func testNewerRoutesWinAndRespondersSeeTheRequest() async throws {
        let stub = URLProtocolStub()
        stub.register(host: "example.com", response: .status(500))
        stub.register(host: "example.com") { request in
            .text("echo \(request.url?.query() ?? "")", status: 201)
        }
        let (data, response) = try await stub.makeSession().data(from: URL(string: "https://example.com/x?q=1")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "echo q=1")
    }

    func testSimulatesTransportFailures() async {
        let stub = URLProtocolStub()
        stub.register(host: "example.com", response: .failure(.notConnectedToInternet))
        do {
            _ = try await stub.makeSession().data(from: URL(string: "https://example.com/")!)
            XCTFail("expected a failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testTwoStubsNeverAnswerEachOthersTraffic() async throws {
        let first = URLProtocolStub()
        let second = URLProtocolStub()
        first.register(host: "example.com", response: .text("first"))
        second.register(host: "example.com", response: .text("second"))
        let (a, _) = try await first.makeSession().data(from: URL(string: "https://example.com/")!)
        let (b, _) = try await second.makeSession().data(from: URL(string: "https://example.com/")!)
        XCTAssertEqual(String(decoding: a, as: UTF8.self), "first")
        XCTAssertEqual(String(decoding: b, as: UTF8.self), "second")
        XCTAssertEqual(first.requests.count, 1)
        XCTAssertEqual(second.requests.count, 1)
    }

    func testOneConfigurationSharedByTwoStubsKeepsEachStubsTraffic() async throws {
        let first = URLProtocolStub()
        let second = URLProtocolStub()
        first.register(host: "example.com", response: .text("first"))
        second.register(host: "example.com", response: .text("second"))
        let shared = VibraMusicHTTP.makeConfiguration()
        let firstSession = first.makeSession(base: shared)
        let secondSession = second.makeSession(base: shared)
        let (a, _) = try await firstSession.data(from: URL(string: "https://example.com/")!)
        let (b, _) = try await secondSession.data(from: URL(string: "https://example.com/")!)
        XCTAssertEqual(String(decoding: a, as: UTF8.self), "first")
        XCTAssertEqual(String(decoding: b, as: UTF8.self), "second")
        XCTAssertEqual(first.requests.count, 1)
        XCTAssertEqual(second.requests.count, 1)
        XCTAssertNil(shared.httpAdditionalHeaders?["X-Vibra Music-URLProtocolStub"], "the caller's configuration is left alone")
    }

    func testResetForgetsRoutesAndRequests() async throws {
        let stub = URLProtocolStub()
        stub.register(host: "example.com", response: .text("x"))
        _ = try await stub.makeSession().data(from: URL(string: "https://example.com/")!)
        stub.reset()
        XCTAssertTrue(stub.requests.isEmpty)
        do {
            _ = try await stub.makeSession().data(from: URL(string: "https://example.com/")!)
            XCTFail("routes should be gone")
        } catch {}
    }

    func testFixtureLoaderFindsFilesInTheFixturesFolder() throws {
        let fixtures = FixtureLoader(bundle: .module)
        XCTAssertTrue(try fixtures.string("song_full.json").contains("dQw4w9WgXcQ"))
        XCTAssertThrowsError(try fixtures.data("missing.json"))
    }
}

final class KeychainStoreTests: XCTestCase {
    /// A unique service per run, so the test never meets real items or a previous run's.
    private func makeStore() throws -> KeychainStore {
        let store = KeychainStore(service: "com.fortune.vibramusic.ios.tests.\(UUID().uuidString)")
        do {
            try store.setString("probe", forKey: "probe")
            try store.removeValue(forKey: "probe")
        } catch let error as KeychainError where error.isUnavailable {
            throw XCTSkip("No usable keychain on this host (\(error)); runs on the iOS simulator.")
        }
        addTeardownBlock { try? store.removeAll() }
        return store
    }

    func testStoresReadsOverwritesAndDeletes() throws {
        let store = try makeStore()
        XCTAssertNil(try store.string(forKey: "token"))
        try store.setString("one", forKey: "token")
        XCTAssertEqual(try store.string(forKey: "token"), "one")
        try store.setString("two", forKey: "token")
        XCTAssertEqual(try store.string(forKey: "token"), "two")
        try store.setString("", forKey: "token")
        XCTAssertNil(try store.string(forKey: "token"), "an empty string deletes")
    }

    func testKeysAreScopedToTheService() throws {
        let store = try makeStore()
        let other = KeychainStore(service: store.service + ".other")
        addTeardownBlock { try? other.removeAll() }
        try store.setData(Data([1, 2, 3]), forKey: "a")
        try store.setString("b", forKey: "b")
        try other.setString("c", forKey: "c")
        XCTAssertEqual(try store.allKeys(), ["a", "b"])
        XCTAssertEqual(try store.data(forKey: "a"), Data([1, 2, 3]))
        XCTAssertNil(try other.string(forKey: "a"))
        try store.removeAll()
        XCTAssertEqual(try store.allKeys(), [])
        XCTAssertEqual(try other.string(forKey: "c"), "c")
    }

    @MainActor
    func testAppSettingsCredentialsLiveInTheKeychain() throws {
        let store = try makeStore()
        let defaults = makeEphemeralDefaults()
        let settings = AppSettings(defaults: defaults, credentials: store)
        settings.listenBrainzToken = "lb-token"
        XCTAssertEqual(try store.string(forKey: "listenbrainz_token"), "lb-token")
        XCTAssertEqual(AppSettings(defaults: defaults, credentials: store).listenBrainzToken, "lb-token")
    }

    func testInMemoryStoreBehavesTheSame() throws {
        let store = InMemoryCredentialStore(["seed": "value"])
        XCTAssertEqual(try store.string(forKey: "seed"), "value")
        try store.setString(nil, forKey: "seed")
        XCTAssertNil(try store.string(forKey: "seed"))
        XCTAssertEqual(store.keys, [])
    }
}

final class NetworkStatusTests: XCTestCase {
    func testMeteredIsNilOfflineAndCoversHotspotsAndLowDataMode() {
        XCTAssertNil(NetworkStatus.offline.isMetered)
        XCTAssertEqual(NetworkStatus.wifi.isMetered, false)
        XCTAssertEqual(NetworkStatus.cellular.isMetered, true)
        XCTAssertEqual(NetworkStatus(interface: .wifi, isExpensive: true).isMetered, true)
        XCTAssertEqual(NetworkStatus(interface: .wired, isConstrained: true).isMetered, true)
        XCTAssertFalse(NetworkStatus.offline.isOnline)
    }

    func testTheFakeMonitorPublishesChanges() async {
        let monitor = FakeNetworkMonitor(.wifi)
        var updates = monitor.statusUpdates().makeAsyncIterator()
        let initial = await updates.next()
        XCTAssertEqual(initial, .wifi)
        monitor.send(.cellular)
        let changed = await updates.next()
        XCTAssertEqual(changed, .cellular)
        XCTAssertEqual(monitor.status, .cellular)
    }

    func testTheRealMonitorYieldsAStatus() async {
        let monitor = NetworkMonitor()
        defer { monitor.cancel() }
        var updates = monitor.statusUpdates().makeAsyncIterator()
        let first = await updates.next()
        XCTAssertNotNil(first, "the stream starts with the current status")
    }
}

final class TrackLogTests: XCTestCase {
    private func song(_ id: String) -> Song { Song(videoId: id, title: "Title \(id)", artist: "Artist") }

    func testATracksLogHoldsItsOwnLinesAndUnattributedOnesButNotOthers() {
        let times = TimeBox()
        let log = TrackLog(now: { times.now })
        log.log(.debug, "Resolver", "resolving A", about: "A")
        log.log(.info, "Playback", "general line", about: nil)
        log.log(.warning, "Resolver", "resolving B", about: "B")
        times.advance(1)

        let text = log.forTrack(song("A"), context: ["playing: aac · 128 kbps"])
        XCTAssertTrue(text.contains("Vibra Music log — Title A — Artist"))
        XCTAssertTrue(text.contains("playing: aac · 128 kbps"))
        XCTAssertTrue(text.contains("resolving A"))
        XCTAssertTrue(text.contains("general line"))
        XCTAssertFalse(text.contains("resolving B"))
        XCTAssertTrue(text.contains("1 for other tracks left out"))
    }

    func testTheWindowStartsAtTheTracksFirstLine() {
        let times = TimeBox()
        let log = TrackLog(now: { times.now })
        log.log(.info, "Playback", "long before", about: nil)
        times.advance(100)
        log.log(.debug, "Resolver", "first line for A", about: "A")
        log.log(.info, "Playback", "after", about: nil)
        let text = log.forTrack(song("A"))
        XCTAssertFalse(text.contains("long before"))
        XCTAssertTrue(text.contains("after"))
    }

    func testATrackWithNoLinesFallsBackToItsStartTime() {
        let times = TimeBox()
        let log = TrackLog(leadIn: 20, now: { times.now })
        log.log(.info, "Playback", "ancient", about: nil)
        times.advance(100)
        log.log(.info, "Playback", "recent", about: nil)
        times.advance(5)
        log.trackStarted("C")
        let text = log.forTrack(song("C"))
        XCTAssertFalse(text.contains("ancient"))
        XCTAssertTrue(text.contains("recent"))
    }

    func testRememberingTheThirtyThirdTrackStartForgetsOnlyTheOldest() {
        let times = TimeBox()
        let log = TrackLog(leadIn: 20, now: { times.now })
        log.log(.info, "Playback", "ancient", about: nil)
        times.advance(100)
        log.log(.info, "Playback", "recent", about: nil)
        times.advance(5)
        for index in 0...32 {
            log.trackStarted("T\(index)")
            times.advance(1)
        }
        let text = log.forTrack(song("T1"))
        XCTAssertFalse(text.contains("ancient"))
        XCTAssertTrue(text.contains("recent"))
        XCTAssertTrue(log.forTrack(song("T0")).contains("ancient"), "the oldest start was forgotten, so its window falls back to everything held")
    }

    func testTheBufferIsBoundedBySizeAndLongLinesAreCut() {
        let log = TrackLog(maxHeldCharacters: 100, maxLineCharacters: 30)
        log.log(.info, "X", String(repeating: "a", count: 50), about: nil)
        XCTAssertTrue(log.heldLines[0].text.hasSuffix("…(20 more)"))
        for index in 0..<10 { log.log(.info, "X", "line \(index) padded out", about: nil) }
        XCTAssertLessThanOrEqual(log.heldLines.reduce(0) { $0 + $1.text.count }, 100)
        XCTAssertEqual(log.heldLines.last?.text, "line 9 padded out")
    }

    func testTaskLocalAttributionFollowsChildTasks() async {
        let log = TrackLog()
        await TrackLog.about("Z") {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { log.log(.debug, "Resolver", "child work") }
            }
            log.log(.debug, "Resolver", "parent work")
        }
        log.log(.debug, "Resolver", "outside")
        XCTAssertEqual(log.heldLines.map(\.track), ["Z", "Z", nil])
    }

    private final class TimeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_000)
        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
    }
}
