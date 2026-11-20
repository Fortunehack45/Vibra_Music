import Foundation
import os
import XCTest
@testable import Lyrics

/// A recorded response from `Fixtures/`.
enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/" + name, withExtension: nil),
            "missing fixture \(name)"
        )
        return try Data(contentsOf: url)
    }

    static func text(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }
}

/// Live tests talk to the real services and only run with `VIBRAMUSIC_LIVE_TESTS=1`.
func requireLiveTests() throws {
    guard ProcessInfo.processInfo.environment["VIBRAMUSIC_LIVE_TESTS"] == "1" else {
        throw XCTSkip("Set VIBRAMUSIC_LIVE_TESTS=1 to run tests against the real services")
    }
}

/// Serves canned responses to a `URLSession`, with no network. Each stubbed session gets its
/// own routing table (matched by a header the session adds to every request), so tests can
/// run side by side.
final class StubURLProtocol: URLProtocol {
    struct Reply {
        var status: Int
        var body: Data
        var delay: TimeInterval = 0

        static func ok(_ body: Data, delay: TimeInterval = 0) -> Reply { Reply(status: 200, body: body, delay: delay) }
        static func ok(_ text: String, delay: TimeInterval = 0) -> Reply { ok(Data(text.utf8), delay: delay) }
        static func status(_ code: Int, _ text: String = "") -> Reply { Reply(status: code, body: Data(text.utf8)) }
    }

    typealias Route = @Sendable (URLRequest) -> Reply?

    private static let routes = OSAllocatedUnfairLock(initialState: [String: Route]())
    private static let recorded = OSAllocatedUnfairLock(initialState: [String: [URLRequest]]())
    private static let header = "X-Lyrics-Stub"

    /// A session whose every request is answered by `route` (nil → 404).
    static func session(_ route: @escaping Route) -> (URLSession, id: String) {
        let id = UUID().uuidString
        routes.withLock { $0[id] = route }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = [header: id]
        return (URLSession(configuration: configuration), id)
    }

    static func requests(_ id: String) -> [URLRequest] {
        recorded.withLock { $0[id] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var cancelled = OSAllocatedUnfairLock(initialState: false)

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: Self.header) ?? ""
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream { body = Self.read(stream) }
        var mutable = request
        mutable.httpBody = body
        let captured = mutable
        Self.recorded.withLock { $0[id, default: []].append(captured) }
        let route = Self.routes.withLock { $0[id] }
        let reply = route?(captured) ?? .status(404)
        let deliver = { [weak self] in
            guard let self, !self.cancelled.withLock({ $0 }) else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: [:])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: reply.body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if reply.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() {
        cancelled.withLock { $0 = true }
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

extension URLRequest {
    /// A query item's (decoded) value.
    func query(_ name: String) -> String? {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == name }?.value
    }

    /// A form body field's decoded value.
    func formField(_ name: String) -> String? {
        guard let body = httpBody.map({ String(decoding: $0, as: UTF8.self) }) else { return nil }
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] == name else { continue }
            return parts[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        }
        return nil
    }
}

extension Array where Element == LyricLine {
    /// Sung lines only — no instrumental gaps.
    var sung: [LyricLine] { filter { !$0.isGap } }
}

/// A provider that answers from a closure, recording when it was asked.
final class FakeLyricsProvider: LyricsProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private let answer: @Sendable (LyricsProviderRequest) async throws -> LyricsProviderAnswer?

    init(_ answer: @escaping @Sendable (LyricsProviderRequest) async throws -> LyricsProviderAnswer?) {
        self.answer = answer
    }

    convenience init(lines: [LyricLine]?, delay: TimeInterval = 0, isrc: String? = nil) {
        self.init { _ in
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            return lines.map { LyricsProviderAnswer(lines: $0, isrc: isrc) }
        }
    }

    var calls: Int { lock.withLock { _calls } }

    func lyrics(for request: LyricsProviderRequest) async throws -> LyricsProviderAnswer? {
        lock.withLock { _calls += 1 }
        return try await answer(request)
    }
}

/// Collects repository events in order.
final class LyricsEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events = [LyricsProviderEvent]()

    var events: [LyricsProviderEvent] { lock.withLock { _events } }

    var handler: @Sendable (LyricsProviderEvent) async -> Void {
        { [self] event in lock.withLock { _events.append(event) } }
    }
}

/// Line-synced sample lines.
func lineSynced(_ texts: String...) -> [LyricLine] {
    texts.enumerated().map { LyricLine(timeMs: ($0.offset + 1) * 1_000, text: $0.element) }
}

/// Word-synced sample lines.
func wordSynced(_ text: String, at startMs: Int = 1_000) -> [LyricLine] {
    let words = text.split(separator: " ").enumerated().map {
        LyricWord(startMs: startMs + $0.offset * 300, endMs: startMs + $0.offset * 300 + 280, text: String($0.element))
    }
    return [LyricLine(timeMs: startMs, text: text, words: words)]
}
