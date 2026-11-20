import Foundation
import Network
import XCTest
@testable import Integrations

/// Full gateway handshake against an in-process fake WebSocket server: an
/// `NWListener` speaking `NWProtocolWebSocket`, driven by
/// `URLSessionWebSocketTask` on the client side.
///
/// Script: server sends `HELLO` → client answers `IDENTIFY` (op 2, carrying
/// the token) → server sends `READY` → client sends heartbeats (op 1) which
/// the server acks (op 11) → `sendActivity` delivers a presence (op 3).
/// No live Discord account is available here; the server is local only.
final class DiscordGatewayHandshakeTests: XCTestCase {
    func testHelloIdentifyHeartbeatPresence() async throws {
        try await assertHandshake(readyPadding: 0)
    }

    /// A real account's READY runs to megabytes (guilds, relationships, settings), over
    /// URLSessionWebSocketTask's 1 MiB default message cap: the socket died on every READY, so no
    /// session ever opened and presence silently never appeared.
    func testAReadyOverOneMebibyteStillOpensTheSession() async throws {
        try await assertHandshake(readyPadding: 3 * 1024 * 1024)
    }

    /// READY names a resume URL (here `wss://127.0.0.1:1`, which refuses). When Discord then asks for a
    /// reconnect and that URL won't open, the client has to give up on resuming and identify afresh on the
    /// gateway, as the Android socket does. It used to dial the dead URL forever.
    func testAResumeURLThatNeverOpensFallsBackToAFreshIdentify() async throws {
        let server = try FakeDiscordGateway(reconnectAfterFirstReady: true)
        try server.start()
        defer { server.stop() }

        let socket = makeSocket(url: server.url)
        await socket.sendActivity(
            DiscordPresence(activities: [DiscordActivity(name: "Vibra Music", state: "A", details: "T")], status: "online")
        )

        let deadline = Date().addingTimeInterval(10)
        var connected = false
        while !connected, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            if server.identifyCount == 2 { connected = await socket.isConnected() }
        }
        await socket.close()
        XCTAssertEqual(server.identifyCount, 2, "after the resume URL refused, the client must identify again on the gateway")
        XCTAssertTrue(connected, "the fresh identify must open a session")
    }

    /// The watchdog drops a socket whose heartbeat goes unacked for one interval. With the fake's
    /// interval cut to 300 ms, a client that ignored op 11 would be dropped and identify a second time
    /// within the first second; one that honours it rides through several turns on one session.
    func testHeartbeatAcksKeepTheSessionAcrossSeveralIntervals() async throws {
        let server = try FakeDiscordGateway(heartbeatIntervalMs: 300)
        try server.start()
        defer { server.stop() }

        let socket = makeSocket(url: server.url)
        await socket.sendActivity(
            DiscordPresence(activities: [DiscordActivity(name: "Vibra Music", state: "A", details: "T")], status: "online")
        )

        let deadline = Date().addingTimeInterval(10)
        while server.heartbeatCount < 4, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let connected = await socket.isConnected()
        await socket.close()
        XCTAssertGreaterThanOrEqual(server.heartbeatCount, 4)
        XCTAssertEqual(server.identifyCount, 1, "an unacked heartbeat drops the socket, which then identifies again")
        XCTAssertTrue(connected)
    }

    private func assertHandshake(readyPadding: Int) async throws {
        let server = try FakeDiscordGateway(readyPadding: readyPadding)
        try server.start()
        defer { server.stop() }

        let socket = makeSocket(url: server.url)
        await socket.sendActivity(
            DiscordPresence(
                activities: [DiscordActivity(name: "Vibra Music", state: "A", details: "T")],
                status: "online"
            )
        )

        let deadline = Date().addingTimeInterval(10)
        while server.receivedPresence == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(server.receivedIdentify, "server must see an op-2 identify carrying the token")
        XCTAssertTrue(server.receivedHeartbeat, "server must see op-1 heartbeats")
        let presence = try XCTUnwrap(server.receivedPresence, "sendActivity must deliver an op-3 presence")
        XCTAssertEqual(presence.activities?.first??.name, "Vibra Music")
        let connected = await socket.isConnected()
        XCTAssertTrue(connected)
        await socket.close()
    }

    private func makeSocket(url: URL) -> DiscordGatewaySocket {
        DiscordGatewaySocket(
            token: "TEST-TOKEN",
            gatewayURL: url,
            configuration: DiscordGatewaySocket.Configuration(
                initialBackoffNanoseconds: 50_000_000,
                maxBackoffNanoseconds: 200_000_000,
                sessionWaitNanoseconds: 10_000_000_000,
                staleGraceNanoseconds: 60_000_000_000
            )
        )
    }
}

// MARK: - Fake server

/// Minimal Discord gateway: accepts WebSockets, sends `HELLO`, records
/// `IDENTIFY` / heartbeats / presence frames, acks heartbeats, and answers
/// each identify with `READY`.
private final class FakeDiscordGateway: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "FakeDiscordGateway")
    private let state = LockedState()

    var receivedIdentify: Bool { state.receivedIdentify }
    var identifyCount: Int { state.identifyCount }
    var receivedHeartbeat: Bool { state.receivedHeartbeat }
    var heartbeatCount: Int { state.heartbeatCount }
    var receivedPresence: DiscordPresence? { state.receivedPresence }

    var url: URL {
        URL(string: "ws://127.0.0.1:\(listener.port?.rawValue ?? 0)/")!
    }

    var debugConnections: Int { state.connections }
    var debugState: String { state.lastState }
    var debugError: String? { state.lastError }
    var debugRawFrames: Int { state.rawFrames }
    var debugListener: String { state.listenerState }

    /// Extra bytes carried in READY, standing in for a real account's guilds and settings.
    private let readyPadding: Int
    /// Follow the first READY with op 7 (RECONNECT), which sends the client to READY's resume URL.
    private let reconnectAfterFirstReady: Bool

    /// The interval sent in HELLO: Discord's own unless a test shortens it. The client's watchdog drops
    /// a socket whose heartbeat goes unacked for one interval, and the ack for its first heartbeat is queued behind READY on the wire. At the 100 ms
    /// this fake used to send, serializing a 3 MiB READY here and handling it in the client took 55-100 ms
    /// even on an idle runner, so on a busy one the watchdog dropped the session as it opened.
    private let heartbeatIntervalMs: Int

    init(readyPadding: Int = 0, reconnectAfterFirstReady: Bool = false, heartbeatIntervalMs: Int = 41_250) throws {
        self.heartbeatIntervalMs = heartbeatIntervalMs
        self.readyPadding = readyPadding
        self.reconnectAfterFirstReady = reconnectAfterFirstReady
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        // The fake must be able to send a real account's multi-megabyte READY itself.
        options.maximumMessageSize = 64 * 1024 * 1024
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() throws {
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        let ready = DispatchSemaphore(value: 0)
        var startError: Error?
        listener.stateUpdateHandler = { [weak self] listenerState in
            self?.state.listenerState = "\(listenerState)"
            switch listenerState {
            case .ready:
                ready.signal()
            case .failed(let error):
                startError = error
                ready.signal()
            case .cancelled:
                ready.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 5) == .timedOut {
            throw NSError(domain: "FakeDiscordGateway", code: 1, userInfo: [NSLocalizedDescriptionKey: "listener not ready in 5 s (state=\(state.listenerState))"])
        }
        if let startError { throw startError }
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        state.connections += 1
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.state.lastState = "\(state)"
            if state == .ready {
                self.send(op: 10, data: ["heartbeat_interval": self.heartbeatIntervalMs], on: connection)
                self.receive(on: connection)
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let error {
                self.state.lastError = "\(error)"
                return
            }
            if let data, !data.isEmpty {
                self.state.rawFrames += 1
                if let payload = try? DiscordGatewayPayload.decode(String(data: data, encoding: .utf8) ?? "")
                {
                    self.handle(payload, on: connection)
                }
            }
            self.receive(on: connection)
        }
    }

    private func handle(_ payload: DiscordGatewayPayload, on connection: NWConnection) {
        switch payload.op {
        case .identify:
            state.receivedIdentify = tokenMatches(payload)
            state.identifyCount += 1
            // Answer with READY so the client session opens.
            send(
                event: "READY",
                sequence: 1,
                data: ["session_id": "SID", "resume_gateway_url": "wss://127.0.0.1:1",
                       "user_settings_proto": String(repeating: "A", count: readyPadding)],
                on: connection
            )
            if reconnectAfterFirstReady, state.identifyCount == 1 {
                send(op: 7, data: [:], on: connection)
            }
        case .heartbeat:
            state.receivedHeartbeat = true
            state.heartbeatCount += 1
            send(op: 11, data: [:], on: connection)
        case .presenceUpdate:
            state.receivedPresence = decodePresence(payload)
        default:
            break
        }
    }

    private func tokenMatches(_ payload: DiscordGatewayPayload) -> Bool {
        guard let data = try? DiscordGatewayPayload.encoder.encode(payload.d),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["token"] as? String == "TEST-TOKEN"
    }

    private func decodePresence(_ payload: DiscordGatewayPayload) -> DiscordPresence? {
        guard let data = try? DiscordGatewayPayload.encoder.encode(payload.d) else { return nil }
        return try? JSONDecoder().decode(DiscordPresence.self, from: data)
    }

    private func send(event: String, sequence: Int, data: [String: Any], on connection: NWConnection) {
        let envelope: [String: Any] = ["op": 0, "s": sequence, "t": event, "d": data]
        sendJSON(envelope, on: connection)
    }

    private func send(op: Int, data: [String: Any], on connection: NWConnection) {
        sendJSON(["op": op, "d": data], on: connection)
    }

    private func sendJSON(_ object: [String: Any], on connection: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }
}

private final class LockedState: @unchecked Sendable {
    private let lock = NSLock()
    private var _receivedIdentify = false
    private var _identifyCount = 0
    private var _receivedHeartbeat = false
    private var _heartbeatCount = 0
    private var _receivedPresence: DiscordPresence?
    private var _connections = 0
    private var _lastState = "none"
    private var _lastError: String?
    private var _rawFrames = 0
    private var _listenerState = "none"

    var listenerState: String {
        get { lock.withLock { _listenerState } }
        set { lock.withLock { _listenerState = newValue } }
    }

    var receivedIdentify: Bool {
        get { lock.withLock { _receivedIdentify } }
        set { lock.withLock { _receivedIdentify = newValue } }
    }

    var identifyCount: Int {
        get { lock.withLock { _identifyCount } }
        set { lock.withLock { _identifyCount = newValue } }
    }

    var receivedHeartbeat: Bool {
        get { lock.withLock { _receivedHeartbeat } }
        set { lock.withLock { _receivedHeartbeat = newValue } }
    }

    var heartbeatCount: Int {
        get { lock.withLock { _heartbeatCount } }
        set { lock.withLock { _heartbeatCount = newValue } }
    }

    var receivedPresence: DiscordPresence? {
        get { lock.withLock { _receivedPresence } }
        set { lock.withLock { _receivedPresence = newValue } }
    }

    var connections: Int {
        get { lock.withLock { _connections } }
        set { lock.withLock { _connections = newValue } }
    }

    var lastState: String {
        get { lock.withLock { _lastState } }
        set { lock.withLock { _lastState = newValue } }
    }

    var lastError: String? {
        get { lock.withLock { _lastError } }
        set { lock.withLock { _lastError = newValue } }
    }

    var rawFrames: Int {
        get { lock.withLock { _rawFrames } }
        set { lock.withLock { _rawFrames = newValue } }
    }
}
