import Foundation
import XCTest
@testable import Integrations

/// How the gateway loop reacts to the way a connection ended: Discord's close codes, and a resume
/// URL that answers HELLO and then hangs up. Driven through an in-memory transport so each frame and
/// each close code is scripted exactly; the loopback server in the handshake tests can't send a 4xxx
/// close code reliably.
final class DiscordGatewayCloseCodeTests: XCTestCase {
    private let base = URL(string: "wss://gateway.test/?v=9&encoding=json")!
    private let resume = URL(string: "wss://resume.test/?v=9&encoding=json")!
    private let initialBackoff: UInt64 = 50_000_000

    /// A token Discord refuses can only be refused again, so the socket stops instead of redialling.
    func testRejectedTokenStopsTheGatewayForGood() async throws {
        let gateway = ScriptedGateway()
        let socket = makeSocket(gateway)
        await socket.connect()
        try await gateway.hello(on: 0)
        try await gateway.waitForOp(.identify, on: 0)
        await gateway.closeFromServer(on: 0, code: 4004)

        try await eventually("the token to be marked rejected") { await socket.isAuthenticationRejected() }
        try await Task.sleep(nanoseconds: 200_000_000)
        // A later track change must not wake it, nor make the push wait out the session timeout.
        await socket.connect()
        await socket.sendActivity(presence())
        let dials = await gateway.urls.count
        XCTAssertEqual(dials, 1, "a refused token must not be dialled again")
        let connected = await socket.isConnected()
        XCTAssertFalse(connected)
        await socket.close()
    }

    /// Both codes mean the session is gone. Resuming it again fails the same way, so the next attempt
    /// goes to the base gateway and identifies, at once rather than after a backoff.
    func testAFailedResumeIdentifiesAfreshOnTheBaseGateway() async throws {
        for code in [4007, 4009] {
            let gateway = ScriptedGateway()
            let socket = makeSocket(gateway)
            try await openSession(socket, gateway)
            await gateway.closeFromServer(on: 0, code: nil)
            try await gateway.hello(on: 1)
            try await gateway.waitForOp(.resume, on: 1)
            await gateway.closeFromServer(on: 1, code: code)
            try await gateway.hello(on: 2)
            try await gateway.waitForOp(.identify, on: 2)

            let urls = await gateway.urls
            XCTAssertEqual(urls, [base, resume, base], "close code \(code) must drop the resume URL")
            let sleeps = await gateway.sleeps
            XCTAssertEqual(sleeps, [initialBackoff], "close code \(code) retries at once, with no second backoff")
            await socket.close()
        }
    }

    /// A resume URL that sends HELLO and hangs up before RESUMED never opened a session. It used to
    /// count as connected: the backoff went back to its floor and the dead URL was redialled.
    func testAResumeThatHangsUpAfterHelloIsNotCountedAsConnected() async throws {
        let gateway = ScriptedGateway()
        let socket = makeSocket(gateway)
        try await openSession(socket, gateway)
        await gateway.closeFromServer(on: 0, code: nil)
        try await gateway.hello(on: 1)
        try await gateway.waitForOp(.resume, on: 1)
        await gateway.closeFromServer(on: 1, code: nil)
        try await gateway.hello(on: 2)
        try await gateway.waitForOp(.identify, on: 2)

        let urls = await gateway.urls
        XCTAssertEqual(urls, [base, resume, base])
        let sleeps = await gateway.sleeps
        XCTAssertEqual(sleeps, [initialBackoff, initialBackoff * 2], "the failed resume keeps the backoff growing")
        await socket.close()
    }

    /// Anything but 4004, 4007 and 4009 is an ordinary drop: the session survives and is resumed.
    func testAnyOtherCloseCodeResumesTheSession() async throws {
        let gateway = ScriptedGateway()
        let socket = makeSocket(gateway)
        try await openSession(socket, gateway)
        await gateway.closeFromServer(on: 0, code: 4000)
        try await gateway.hello(on: 1)
        try await gateway.waitForOp(.resume, on: 1)

        let urls = await gateway.urls
        XCTAssertEqual(urls, [base, resume])
        await socket.close()
    }

    /// A new session used to publish the presence twice: the push that was waiting for the session and
    /// the replay both passed the duplicate check before either send finished.
    func testANewSessionPublishesThePresenceOnce() async throws {
        let gateway = ScriptedGateway()
        let socket = makeSocket(gateway)
        let published = presence()
        let push = Task { await socket.sendActivity(published) }
        try await gateway.hello(on: 0)
        try await gateway.waitForOp(.identify, on: 0)
        await gateway.ready(on: 0)
        await push.value
        try await Task.sleep(nanoseconds: 200_000_000)

        let ops = await gateway.sentOps(on: 0)
        XCTAssertEqual(ops.filter { $0 == .presenceUpdate }.count, 1)
        await socket.close()
    }

    // MARK: - Helpers

    /// Connects, completes HELLO, IDENTIFY and READY on the first connection.
    private func openSession(_ socket: DiscordGatewaySocket, _ gateway: ScriptedGateway) async throws {
        await socket.connect()
        try await gateway.hello(on: 0)
        try await gateway.waitForOp(.identify, on: 0)
        await gateway.ready(on: 0)
        try await eventually("the session to open") { await socket.isConnected() }
    }

    private func makeSocket(_ gateway: ScriptedGateway) -> DiscordGatewaySocket {
        DiscordGatewaySocket(
            token: "TOKEN",
            gatewayURL: base,
            configuration: DiscordGatewaySocket.Configuration(
                initialBackoffNanoseconds: initialBackoff,
                maxBackoffNanoseconds: 1_000_000_000,
                sessionWaitNanoseconds: 10_000_000_000,
                staleGraceNanoseconds: 60_000_000_000
            ),
            makeTransport: { url in await gateway.dial(url) },
            // Backoffs elapse at once; the gateway records how long each was asked to be.
            backoffSleep: { nanoseconds in await gateway.recordSleep(nanoseconds) }
        )
    }

    private func presence() -> DiscordPresence {
        DiscordPresence(activities: [DiscordActivity(name: "Vibra Music", state: "A", details: "T")], status: "online")
    }
}

private struct Timeout: Error {}

/// Polls until `condition` holds; fails the test (and stops it) after `timeout`.
private func eventually(
    _ what: String,
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !(await condition()) {
        if Date() > deadline {
            XCTFail("timed out waiting for \(what)", file: file, line: line)
            throw Timeout()
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// The server side of a script: hands the socket one in-memory transport per dial and keeps what it
/// was asked to dial and how long it was asked to back off.
private actor ScriptedGateway {
    private(set) var urls: [URL] = []
    private(set) var sleeps: [UInt64] = []
    private var transports: [ScriptedTransport] = []

    func dial(_ url: URL) -> ScriptedTransport {
        let transport = ScriptedTransport()
        urls.append(url)
        transports.append(transport)
        return transport
    }

    func recordSleep(_ nanoseconds: UInt64) {
        sleeps.append(nanoseconds)
    }

    func hello(on index: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        let transport = try await connection(index, file: file, line: line)
        await transport.push(#"{"op":10,"d":{"heartbeat_interval":41250}}"#)
    }

    func ready(on index: Int) async {
        await transports[index].push(
            #"{"op":0,"s":1,"t":"READY","d":{"session_id":"SID","resume_gateway_url":"wss://resume.test"}}"#
        )
    }

    func closeFromServer(on index: Int, code: Int?) async {
        await transports[index].closeFromServer(code: code)
    }

    func sentOps(on index: Int) async -> [DiscordOpCode] {
        await transports[index].sentOps()
    }

    func waitForOp(_ op: DiscordOpCode, on index: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        let transport = try await connection(index, file: file, line: line)
        try await eventually("the client to send \(op) on connection \(index)", file: file, line: line) {
            await transport.sentOps().contains(op)
        }
    }

    /// Waits for the socket to dial connection `index`.
    private func connection(_ index: Int, file: StaticString, line: UInt) async throws -> ScriptedTransport {
        let deadline = Date().addingTimeInterval(5)
        while transports.count <= index {
            if Date() > deadline {
                XCTFail("the socket never dialled connection \(index)", file: file, line: line)
                throw Timeout()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return transports[index]
    }
}

/// One connection: frames the server pushes come out of `receive()`, frames the client sends are
/// recorded, and a server close arrives as the error `receive()` throws.
private actor ScriptedTransport: DiscordGatewayTransport {
    private var inbox: [Result<String, Error>] = []
    private var waiter: CheckedContinuation<String, Error>?
    private var sent: [String] = []
    private var closed = false

    func push(_ text: String) {
        deliver(.success(text))
    }

    func closeFromServer(code: Int?) {
        deliver(.failure(DiscordTransportClosed(code: code)))
    }

    func sentOps() -> [DiscordOpCode] {
        sent.compactMap { (try? DiscordGatewayPayload.decode($0))?.op }
    }

    func send(_ text: String) async throws {
        if closed { throw DiscordTransportClosed() }
        sent.append(text)
    }

    func receive() async throws -> String {
        if !inbox.isEmpty { return try inbox.removeFirst().get() }
        if closed { throw DiscordTransportClosed() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func close() async {
        closed = true
        if let waiter {
            self.waiter = nil
            waiter.resume(throwing: DiscordTransportClosed())
        }
    }

    private func deliver(_ item: Result<String, Error>) {
        if let waiter {
            self.waiter = nil
            waiter.resume(with: item)
        } else {
            inbox.append(item)
        }
    }
}
