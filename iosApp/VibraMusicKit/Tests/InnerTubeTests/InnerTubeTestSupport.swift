import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import InnerTube

/// Fixture access for this target.
enum Fixtures {
    static let loader = FixtureLoader(bundle: .module)

    static func json(_ name: String) throws -> InnerTubeJSON {
        try InnerTubeJSON.parse(loader.data(name))
    }

    static func text(_ name: String) throws -> String {
        try loader.string(name)
    }
}

/// Parses inline JSON in a test.
func json(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> InnerTubeJSON {
    do {
        return try InnerTubeJSON.parse(text)
    } catch {
        XCTFail("bad test JSON: \(error)", file: file, line: line)
        return .null
    }
}

extension SearchResult {
    var trackSong: Song? {
        if case .track(let song) = self { return song }
        return nil
    }

    var topSong: Song? {
        if case .topTrack(let song) = self { return song }
        return nil
    }

    var browseItem: BrowseItem? {
        if case .browse(let item) = self { return item }
        return nil
    }
}

/// A stubbed network for client and repository tests: answers Innertube endpoints by path (and,
/// where it matters, by the `browseId`/`continuation` in the body).
final class InnerTubeStub: @unchecked Sendable {
    let stub = URLProtocolStub()

    func makeClient(language: String = "en", now: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> InnerTubeClient {
        InnerTubeClient(
            session: stub.makeSession(),
            language: { language },
            clock: { now },
            retryBaseDelay: .milliseconds(1)
        )
    }

    /// Answers `youtubei/v1/<endpoint>` with `body`.
    func on(_ endpoint: String, _ body: String, status: Int = 200) {
        stub.register(host: "music.youtube.com", path: "/youtubei/v1/\(endpoint)", response: .json(body, status: status))
    }

    /// Answers `youtubei/v1/<endpoint>` with a fixture.
    func on(_ endpoint: String, fixture: String) throws {
        on(endpoint, try Fixtures.text(fixture))
    }

    /// Answers `browse` for one browse id (by the request body).
    func onBrowse(_ browseId: String, fixture: String) throws {
        let body = try Fixtures.text(fixture)
        stub.register(matching: { request in
            request.url?.path() == "/youtubei/v1/browse" && Self.bodyField("browseId", of: request) == browseId
        }) { _ in .json(body) }
    }

    /// Answers `browse` for one continuation token.
    func onContinuation(_ token: String, fixture: String) throws {
        let body = try Fixtures.text(fixture)
        onContinuation(token, body: body)
    }

    func onContinuation(_ token: String, body: String) {
        stub.register(matching: { request in
            request.url?.path() == "/youtubei/v1/browse" && Self.bodyField("continuation", of: request) == token
        }) { _ in .json(body) }
    }

    /// Requests to an Innertube endpoint, in order.
    func requests(to endpoint: String) -> [URLRequest] {
        stub.requests(toPath: "/youtubei/v1/\(endpoint)")
    }

    /// A top-level string field of a request's JSON body.
    static func bodyField(_ key: String, of request: URLRequest) -> String? {
        guard let body = request.httpBody, let parsed = try? InnerTubeJSON.parse(body) else { return nil }
        return parsed.s(key)
    }

    static func body(of request: URLRequest) -> InnerTubeJSON {
        guard let body = request.httpBody, let parsed = try? InnerTubeJSON.parse(body) else { return .null }
        return parsed
    }
}

/// A counter a synchronous stub responder can bump; returns the new value.
final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }

    var value: Int { lock.withLock { count } }
}
