import Foundation
import Network
import XCTest

// Two ways for an app test to answer HTTP: a URLProtocol session for the clients that take a
// `URLSession` (InnerTube, the scrobblers), and a loopback server for the ones that build their
// own (WebDAV, the Last.fm login whose endpoint the user can set). Both record what was asked.

/// One request as the server saw it.
struct RecordedHTTPRequest: Sendable {
    let method: String
    let url: URL
    /// Header names lower-cased.
    let headers: [String: String]
    let body: Data

    var path: String { url.path }

    /// An `application/x-www-form-urlencoded` body.
    var form: [String: String] {
        var fields: [String: String] = [:]
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let decode = { (text: String) in text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? text }
            fields[decode(parts[0])] = decode(parts[1])
        }
        return fields
    }

    var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
}

struct StubbedHTTPResponse: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var body = Data()

    static func json(_ text: String, status: Int = 200) -> StubbedHTTPResponse {
        StubbedHTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
    }

    static func status(_ code: Int) -> StubbedHTTPResponse { StubbedHTTPResponse(status: code) }
}

typealias HTTPResponder = @Sendable (RecordedHTTPRequest) -> StubbedHTTPResponse

// MARK: - URLProtocol

/// A session whose requests never leave the process: `respond` answers each one, and every one is
/// kept for the test to read. Each stub is independent (a routing header names its owner).
final class HTTPRecordingStub: @unchecked Sendable {
    private static let header = "X-Test-Stub-Id"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var live: [String: WeakStub] = [:]

    private let id = UUID().uuidString
    private let respond: HTTPResponder
    private let lock = NSLock()
    private var seen: [RecordedHTTPRequest] = []

    init(respond: @escaping HTTPResponder) {
        self.respond = respond
        Self.lock.withLock { Self.live[id] = WeakStub(self) }
    }

    deinit {
        _ = Self.lock.withLock { Self.live.removeValue(forKey: id) }
    }

    var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPRecordingProtocol.self]
        configuration.httpAdditionalHeaders = [Self.header: id]
        return URLSession(configuration: configuration)
    }

    var requests: [RecordedHTTPRequest] { lock.withLock { seen } }

    func requests(toPath path: String) -> [RecordedHTTPRequest] { requests.filter { $0.path == path } }

    fileprivate static func answer(_ request: URLRequest) -> StubbedHTTPResponse? {
        guard let id = request.value(forHTTPHeaderField: header), let stub = lock.withLock({ live[id]?.stub }) else { return nil }
        var headers = (request.allHTTPHeaderFields ?? [:]).reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
        headers[header.lowercased()] = nil
        let recorded = RecordedHTTPRequest(method: request.httpMethod ?? "GET", url: request.url!, headers: headers, body: bodyData(of: request))
        stub.lock.withLock { stub.seen.append(recorded) }
        return stub.respond(recorded)
    }

    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class WeakStub {
    weak var stub: HTTPRecordingStub?
    init(_ stub: HTTPRecordingStub) { self.stub = stub }
}

final class HTTPRecordingProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let answer = HTTPRecordingStub.answer(request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Loopback server

/// A tiny HTTP/1.1 server on 127.0.0.1 for the clients that make their own `URLSession`. Answers
/// from `respond`, closes after each response, and records every request.
final class LoopbackHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackHTTPServer")
    private let respond: HTTPResponder
    private let lock = NSLock()
    private var seen: [RecordedHTTPRequest] = []
    private var opened: [String] = []
    private var port: UInt16 = 0

    init(respond: @escaping HTTPResponder) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.respond = respond
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var requests: [RecordedHTTPRequest] { lock.withLock { seen } }
    /// The first bytes of every connection, in hex, whether or not it became a request.
    var connectionOpenings: [String] { lock.withLock { opened } }

    /// Starts listening and stops again when the test ends.
    func start(for test: XCTestCase) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.port = self?.listener.port?.rawValue ?? 0
                    if once.claim() { continuation.resume() }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: self?.queue ?? .main)
                self?.receive(connection, buffer: Data())
            }
            listener.start(queue: queue)
        }
        let listener = self.listener
        test.addTeardownBlock { listener.cancel() }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count == data?.count, let data, !data.isEmpty {
                self.lock.withLock { self.opened.append(data.prefix(8).map { String(format: "%02x", $0) }.joined()) }
                // A TLS handshake (WebKit trying https first): closed at once, so the client falls
                // back to plain http instead of waiting on a reply that never comes.
                if data.first == 0x16 {
                    connection.cancel()
                    return
                }
            }
            if let request = Self.parse(buffer) {
                self.answer(request, on: connection)
            } else if complete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    /// The request once its head and its whole body have arrived.
    private static func parse(_ buffer: Data) -> RecordedHTTPRequest? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let start = lines.first?.split(separator: " ").map(String.init) ?? []
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = headers["content-length"].flatMap(Int.init) ?? 0
        let body = buffer[end.upperBound...]
        guard body.count >= length else { return nil }
        guard let url = URL(string: "http://127.0.0.1" + start[1]) else { return nil }
        return RecordedHTTPRequest(method: start[0], url: url, headers: headers, body: Data(body.prefix(length)))
    }

    private func answer(_ request: RecordedHTTPRequest, on connection: NWConnection) {
        lock.withLock { seen.append(request) }
        let response = respond(request)
        var head = "HTTP/1.1 \(response.status) \(HTTPURLResponse.localizedString(forStatusCode: response.status))\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(head.utf8)
        if request.method != "HEAD" { payload.append(response.body) }
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// True the first time only.
    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
