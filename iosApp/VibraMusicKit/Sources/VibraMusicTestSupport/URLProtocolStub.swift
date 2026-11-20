import Foundation
import VibraMusicCore

/// Canned HTTP responses for tests, without a network.
///
/// ```swift
/// let stub = URLProtocolStub()
/// stub.register(host: "music.youtube.com", path: "/youtubei/v1/search", response: .json(fixtureText))
/// let client = InnerTubeClient(session: stub.makeSession())
/// … exercise the client …
/// XCTAssertEqual(stub.requests.first?.httpMethod, "POST")
/// ```
///
/// Each stub is independent: its sessions carry a private routing header (stripped before
/// responders and ``requests`` see the request), so two stubs in one process never answer each
/// other's traffic. Responders are tried newest first, so a test can override a shared default by
/// registering again. A request nothing matches fails with `URLError(.unsupportedURL)` and is
/// recorded in ``unmatchedRequests``.
public final class URLProtocolStub: @unchecked Sendable {
    /// A canned answer.
    public struct Response: Sendable {
        public var statusCode: Int
        public var headers: [String: String]
        public var body: Data
        /// When set, the request fails with this error instead of answering.
        public var error: URLError?

        public init(statusCode: Int = 200, headers: [String: String] = [:], body: Data = Data(), error: URLError? = nil) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
            self.error = error
        }

        public static func data(_ body: Data, status: Int = 200, headers: [String: String] = [:]) -> Response {
            Response(statusCode: status, headers: headers, body: body)
        }

        public static func text(_ body: String, status: Int = 200, headers: [String: String] = [:]) -> Response {
            Response(statusCode: status, headers: ["Content-Type": "text/plain; charset=utf-8"].merging(headers) { $1 }, body: Data(body.utf8))
        }

        public static func json(_ body: String, status: Int = 200, headers: [String: String] = [:]) -> Response {
            Response(statusCode: status, headers: ["Content-Type": "application/json"].merging(headers) { $1 }, body: Data(body.utf8))
        }

        public static func json<T: Encodable>(encoding value: T, status: Int = 200, encoder: JSONEncoder = JSONEncoder()) throws -> Response {
            Response(statusCode: status, headers: ["Content-Type": "application/json"], body: try encoder.encode(value))
        }

        /// An empty body with `code`.
        public static func status(_ code: Int) -> Response {
            Response(statusCode: code)
        }

        /// A transport failure (timeout, offline, …).
        public static func failure(_ code: URLError.Code) -> Response {
            Response(error: URLError(code))
        }
    }

    /// Builds the answer for a request. Throwing fails the request with the thrown error.
    public typealias Responder = @Sendable (URLRequest) throws -> Response

    private struct Route {
        let matches: @Sendable (URLRequest) -> Bool
        let respond: Responder
    }

    fileprivate static let routingHeader = "X-Vibra Music-URLProtocolStub"
    private static let registryLock = NSLock()
    private static var registry: [String: WeakStub] = [:]

    private let id = UUID().uuidString
    private let lock = NSLock()
    private var routes: [Route] = []
    private var recorded: [URLRequest] = []
    private var unmatched: [URLRequest] = []

    public init() {
        Self.registryLock.withLock { Self.registry[id] = WeakStub(self) }
    }

    deinit {
        _ = Self.registryLock.withLock { Self.registry.removeValue(forKey: id) }
    }

    // MARK: Registering

    /// Answers requests matching `predicate`.
    public func register(matching predicate: @escaping @Sendable (URLRequest) -> Bool, _ responder: @escaping Responder) {
        lock.withLock { routes.insert(Route(matches: predicate, respond: responder), at: 0) }
    }

    /// Answers requests to `url`. Scheme, host and path must match; when `url` has a query, the
    /// request must carry the same query items (in any order), otherwise any query matches.
    public func register(url: URL, method: String? = nil, _ responder: @escaping Responder) {
        register(matching: { request in
            guard let target = request.url, Self.method(of: request, is: method) else { return false }
            return Self.url(target, matches: url)
        }, responder)
    }

    public func register(url: URL, method: String? = nil, response: Response) {
        register(url: url, method: method) { _ in response }
    }

    /// Answers requests to `host` (and `path`, when given, exactly), any query.
    public func register(host: String, path: String? = nil, method: String? = nil, _ responder: @escaping Responder) {
        register(matching: { request in
            guard let target = request.url, Self.method(of: request, is: method),
                  target.host()?.lowercased() == host.lowercased() else { return false }
            return path.map { target.path(percentEncoded: false) == $0 } ?? true
        }, responder)
    }

    public func register(host: String, path: String? = nil, method: String? = nil, response: Response) {
        register(host: host, path: path, method: method) { _ in response }
    }

    /// Forgets routes and recorded requests.
    public func reset() {
        lock.withLock {
            routes.removeAll()
            recorded.removeAll()
            unmatched.removeAll()
        }
    }

    // MARK: Inspecting

    /// Every request made through this stub's sessions, in order, with any streamed body read into
    /// `httpBody` and the routing header removed.
    public var requests: [URLRequest] { lock.withLock { recorded } }

    /// Requests no route matched.
    public var unmatchedRequests: [URLRequest] { lock.withLock { unmatched } }

    /// Recorded requests whose path is `path`.
    public func requests(toPath path: String) -> [URLRequest] {
        requests.filter { $0.url?.path(percentEncoded: false) == path }
    }

    // MARK: Sessions

    /// `base` (by default the app's own configuration) routed through this stub.
    public func makeConfiguration(base: URLSessionConfiguration = VibraMusicHTTP.makeConfiguration()) -> URLSessionConfiguration {
        // A copy, so a configuration shared between two stubs keeps each one's routing header.
        let configuration = base.copy() as! URLSessionConfiguration
        configuration.protocolClasses = [StubURLProtocol.self]
        var headers = configuration.httpAdditionalHeaders ?? [:]
        headers[Self.routingHeader] = id
        configuration.httpAdditionalHeaders = headers
        return configuration
    }

    /// A session whose every request is answered by this stub.
    public func makeSession(base: URLSessionConfiguration = VibraMusicHTTP.makeConfiguration()) -> URLSession {
        URLSession(configuration: makeConfiguration(base: base))
    }

    // MARK: Internals

    fileprivate static func stub(for request: URLRequest) -> URLProtocolStub? {
        guard let id = request.value(forHTTPHeaderField: routingHeader) else { return nil }
        return registryLock.withLock { registry[id]?.stub }
    }

    fileprivate func respond(to request: URLRequest) -> Result<Response, Error> {
        let route: Route? = lock.withLock {
            recorded.append(request)
            let match = routes.first { $0.matches(request) }
            if match == nil { unmatched.append(request) }
            return match
        }
        guard let route else { return .failure(URLError(.unsupportedURL)) }
        return Result { try route.respond(request) }
    }

    private static func method(of request: URLRequest, is method: String?) -> Bool {
        guard let method else { return true }
        return (request.httpMethod ?? "GET").uppercased() == method.uppercased()
    }

    private static func url(_ candidate: URL, matches target: URL) -> Bool {
        guard candidate.scheme?.lowercased() == target.scheme?.lowercased(),
              candidate.host()?.lowercased() == target.host()?.lowercased(),
              candidate.port == target.port,
              candidate.path(percentEncoded: false) == target.path(percentEncoded: false) else { return false }
        let wanted = URLComponents(url: target, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard !wanted.isEmpty else { return true }
        let actual = URLComponents(url: candidate, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Set(wanted.map { "\($0.name)=\($0.value ?? "")" }) == Set(actual.map { "\($0.name)=\($0.value ?? "")" })
    }
}

private final class WeakStub {
    weak var stub: URLProtocolStub?
    init(_ stub: URLProtocolStub) { self.stub = stub }
}

/// The `URLProtocol` that hands requests to the owning ``URLProtocolStub``.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: URLProtocolStub.routingHeader) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let original = request
        guard let stub = URLProtocolStub.stub(for: original), let url = original.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        var cleaned = original
        cleaned.setValue(nil, forHTTPHeaderField: URLProtocolStub.routingHeader)
        if cleaned.httpBody == nil, let stream = original.httpBodyStream {
            cleaned.httpBody = Self.read(stream)
        }

        switch stub.respond(to: cleaned) {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .success(let response):
            if let error = response.error {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
            guard let http = HTTPURLResponse(url: url, statusCode: response.statusCode, httpVersion: "HTTP/1.1", headerFields: response.headers) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            if !response.body.isEmpty { client?.urlProtocol(self, didLoad: response.body) }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
