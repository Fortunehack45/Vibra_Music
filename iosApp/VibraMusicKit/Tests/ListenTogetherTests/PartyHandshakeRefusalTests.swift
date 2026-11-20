import Foundation
import Network
import XCTest
@testable import ListenTogether

/// A restarted party server has forgotten every party, and says so as an HTTP 404 on the
/// socket handshake itself — no upgrade, so the in-band `no_such_party` frame never exists.
final class PartyHandshakeRefusalTests: XCTestCase {
    func testAServerThatRefusesTheHandshakeAsUnknownEndsTheMembershipWithoutEverShowingLive() async throws {
        let server = try RefusingHTTPServer(status: "404 Not Found")
        try await server.start()
        defer { server.stop() }
        let (store, _) = try PartyTestFixtures.makeStore()
        let client = PartyTestFixtures.makeClient(store: store)
        await client.commitMembershipForTesting(
            serverBase: "http://127.0.0.1:\(server.port)", membership: PartyTestFixtures.membership())
        let seen = SeenConnections()
        let watcher = Task {
            for await state in await client.stateStream() { seen.append(state.connection) }
        }

        await client.connectForTesting()
        let left = await client.waitUntil(timeoutSeconds: 15) { $0.code == nil }
        watcher.cancel()

        XCTAssertTrue(left, "the party is gone for good, so the membership is dropped")
        XCTAssertEqual(PartyLimits.handshakeRefusalLimit, server.socketRequests)
        XCTAssertFalse(seen.values.contains(.live), "a refused handshake is not a live party")
    }
}

private final class SeenConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [PartyConnection] = []

    var values: [PartyConnection] { lock.withLock { _values } }

    func append(_ value: PartyConnection) { lock.withLock { _values.append(value) } }
}

/// Answers every request with a bodiless HTTP error, and counts the ones aimed at the socket path.
private final class RefusingHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "RefusingHTTPServer")
    private let lock = NSLock()
    private let status: String
    private var _socketRequests = 0
    private(set) var port: UInt16 = 0

    init(status: String) throws {
        self.status = status
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    var socketRequests: Int { lock.withLock { _socketRequests } }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = FirstCall()
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
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                if String(decoding: buffer, as: UTF8.self).contains("/ws/parties/") {
                    self.lock.withLock { self._socketRequests += 1 }
                }
                let reply = "HTTP/1.1 \(self.status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            } else if complete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }
}

/// True the first time only, so the listener's repeated state updates resume once.
private final class FirstCall: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false

    func claim() -> Bool {
        lock.withLock {
            defer { called = true }
            return !called
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
