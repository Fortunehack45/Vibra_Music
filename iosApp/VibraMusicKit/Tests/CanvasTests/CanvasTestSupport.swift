import VibraMusicTestSupport
import Foundation
import XCTest
@testable import Canvas

/// A recorded response from `Fixtures/`.
enum CanvasFixture {
    static func data(_ name: String) throws -> Data {
        try FixtureLoader(bundle: .module).data(name)
    }

    static func text(_ name: String) throws -> String {
        try FixtureLoader(bundle: .module).string(name)
    }
}

/// Live tests talk to the real services and only run with `VIBRAMUSIC_LIVE_TESTS=1`.
func requireLiveCanvasTests() throws {
    guard ProcessInfo.processInfo.environment["VIBRAMUSIC_LIVE_TESTS"] == "1" else {
        throw XCTSkip("Set VIBRAMUSIC_LIVE_TESTS=1 to run tests against the real canvas services")
    }
}

/// A `CanvasSpotifyTokenHarvester` that answers from a fixed token.
final class StubCanvasHarvester: CanvasSpotifyTokenHarvester, @unchecked Sendable {
    var harvested: CanvasHarvestedToken?
    private let delay: Duration?
    private let lock = NSLock()
    private var value = 0

    init(harvested: CanvasHarvestedToken? = nil, delay: Duration? = nil) {
        self.harvested = harvested
        self.delay = delay
    }

    func harvest(spDcCookie: String) async -> CanvasHarvestedToken? {
        lock.withLock { value += 1 }
        if let delay { try? await Task.sleep(for: delay) }
        return harvested
    }

    var calls: Int { lock.withLock { value } }
}

/// A stubbed `URLSession` answering every request through one responder.
func canvasStubSession(_ stub: URLProtocolStub) -> URLSession {
    stub.makeSession()
}

/// Registers a canned body for every request to `host`/`path`.
func canvasRoute(_ stub: URLProtocolStub, host: String, path: String, fixture name: String) throws {
    let body = try CanvasFixture.text(name)
    stub.register(host: host, path: path, response: .text(body))
}
