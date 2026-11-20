import Foundation
import XCTest
@testable import StreamResolution

// Test helpers private to this target. VibraMusicTestSupport is still a placeholder while Core is
// being written, so the URLProtocol stub lives here, named after the subsystem.

enum StreamFixture {
    static func url(_ name: String) -> URL {
        guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil) else {
            fatalError("missing fixture \(name)")
        }
        return url
    }

    static func data(_ name: String) -> Data {
        guard let data = try? Data(contentsOf: url(name)) else { fatalError("unreadable fixture \(name)") }
        return data
    }

    static func string(_ name: String) -> String { String(decoding: data(name), as: UTF8.self) }

    static func playerResponse(_ name: String) throws -> PlayerResponse { try PlayerResponse.decode(data(name)) }

    /// The real player_ias script for 7460dd14, stored raw-deflated (it is ~3 MB).
    static let playerSource: String = {
        let compressed = data("player_ias_7460dd14.js.deflate") as NSData
        guard let inflated = try? compressed.decompressed(using: .zlib) else { fatalError("cannot inflate player") }
        return String(decoding: inflated as Data, as: UTF8.self)
    }()

    static let playerHash = "7460dd14"
}

/// One canned answer.
struct StreamStubResponse {
    var status: Int = 200
    var headers: [String: String] = [:]
    var body = Data()
    /// Send the headers, then never the body: a stalled stream.
    var stallAfterHeaders = false
    var error: Error?

    static func json(_ data: Data, status: Int = 200) -> StreamStubResponse {
        StreamStubResponse(status: status, headers: ["Content-Type": "application/json"], body: data)
    }

    static func text(_ text: String, status: Int = 200) -> StreamStubResponse {
        StreamStubResponse(status: status, headers: ["Content-Type": "text/html"], body: Data(text.utf8))
    }

    static func audio(bytes: Int, status: Int = 206, type: String = "audio/mp4") -> StreamStubResponse {
        var payload = Data(count: bytes)
        if bytes >= 8 { payload.replaceSubrange(4..<8, with: Data("ftyp".utf8)) }
        return StreamStubResponse(status: status, headers: ["Content-Type": type], body: payload)
    }
}

/// A recorded request, with its body read out of the stream URLSession hands a protocol.
struct StreamStubRequest {
    var request: URLRequest
    var body: Data?

    var url: URL { request.url! }
    var jsonBody: [String: Any]? { body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
    func header(_ name: String) -> String? { request.value(forHTTPHeaderField: name) }
}

/// Routes requests to a handler and records them. One per test; isolated by a token header.
final class StreamStubServer: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [StreamStubRequest] = []
    private var handler: (StreamStubRequest) -> StreamStubResponse
    let token = UUID().uuidString

    init(handler: @escaping (StreamStubRequest) -> StreamStubResponse = { _ in StreamStubResponse(status: 404) }) {
        self.handler = handler
    }

    func setHandler(_ handler: @escaping (StreamStubRequest) -> StreamStubResponse) {
        lock.withLock { self.handler = handler }
    }

    var requests: [StreamStubRequest] { lock.withLock { recorded } }

    func requests(host: String) -> [StreamStubRequest] { requests.filter { $0.url.host == host } }

    func respond(to request: StreamStubRequest) -> StreamStubResponse {
        let handler = lock.withLock { () -> (StreamStubRequest) -> StreamStubResponse in
            recorded.append(request)
            return self.handler
        }
        return handler(request)
    }

    lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamStubProtocol.self]
        configuration.httpAdditionalHeaders = [StreamStubProtocol.tokenHeader: token]
        StreamStubProtocol.register(self)
        return URLSession(configuration: configuration)
    }()
}

final class StreamStubProtocol: URLProtocol {
    static let tokenHeader = "X-Stream-Stub-Token"
    private static let lock = NSLock()
    private static var servers: [String: StreamStubServer] = [:]
    private var stopped = false

    static func register(_ server: StreamStubServer) {
        lock.withLock { servers[server.token] = server }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let token = request.value(forHTTPHeaderField: Self.tokenHeader) ?? ""
        guard let server = Self.lock.withLock({ Self.servers[token] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let recorded = StreamStubRequest(request: request, body: Self.body(of: request))
        let response = server.respond(to: recorded)
        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        var headers = response.headers
        headers["Content-Length"] = headers["Content-Length"] ?? String(response.body.count)
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if response.stallAfterHeaders { return }
        // Delivered in slices so streaming readers see a stream, not one blob.
        var offset = 0
        while offset < response.body.count && !stopped {
            let end = min(offset + 4096, response.body.count)
            client?.urlProtocol(self, didLoad: response.body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { stopped = true }

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// A fixed signed-in session, or none.
struct FixedAuthProvider: StreamAuthProvider {
    var session: StreamAuthSession?
    func streamAuthSession() async -> StreamAuthSession? { session }
}

/// A clock tests can move.
final class StreamTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_790_000_000)) { current = start }

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
    var function: @Sendable () -> Date { { [self] in self.now } }
}

extension XCTestCase {
    /// Skips unless VIBRAMUSIC_LIVE_TESTS=1, as the README requires for tests that touch real services.
    func requireLiveTests() throws {
        guard ProcessInfo.processInfo.environment["VIBRAMUSIC_LIVE_TESTS"] == "1" else {
            throw XCTSkip("live test; set VIBRAMUSIC_LIVE_TESTS=1 to run against the real service")
        }
    }
}
