import VibraMusicCore
import Foundation
import os

/// Transport behind the gateway socket, so tests can run the full handshake
/// without a network. Production uses `URLSessionWebSocketTransport`.
public protocol DiscordGatewayTransport: Sendable {
    func send(_ text: String) async throws
    /// Returns the next text message, or throws when the socket closes.
    func receive() async throws -> String
    func close() async
}

/// `URLSessionWebSocketTask`-backed transport.
public final class URLSessionWebSocketTransport: DiscordGatewayTransport, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    /// Discord's READY for a real account carries its guilds, relationships and settings and runs
    /// to several megabytes; URLSessionWebSocketTask refuses any message over 1 MiB by default, so
    /// READY never arrived and no presence could be published. OkHttp (Android's Kizzy) has no
    /// such cap.
    public static let maximumMessageSize = 64 * 1024 * 1024

    public init(task: URLSessionWebSocketTask) {
        self.task = task
        task.maximumMessageSize = Self.maximumMessageSize
        task.resume()
    }

    public func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    public func receive() async throws -> String {
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch {
            // The error itself only says the socket is gone; Discord's reason is the close code, which
            // URLSession keeps on the task. 0 is `.invalid`: closed without a code (a dropped network).
            let code = task.closeCode.rawValue
            throw DiscordTransportClosed(code: code == 0 ? nil : code)
        }
        switch message {
        case .string(let text): return text
        case .data(let data): return String(data: data, encoding: .utf8) ?? ""
        @unknown default: return ""
        }
    }

    public func close() async {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

/// A socket that has closed. `code` is the WebSocket close code the server gave, when it gave one:
/// Discord uses 4000-4999 to say why it hung up (see `DiscordCloseCode`).
public struct DiscordTransportClosed: Error {
    public let code: Int?

    public init(code: Int? = nil) {
        self.code = code
    }
}

/// The gateway close codes the connection loop acts on; any other code gets the ordinary backoff.
enum DiscordCloseCode {
    /// The token was refused. Redialling with it can only be refused again.
    static let authenticationFailed = 4004
    /// The resume's sequence number was invalid, or the session timed out: the session is gone and
    /// resuming it again fails the same way. Identify afresh.
    static let invalidSequence = 4007
    static let sessionTimedOut = 4009
}

/// The Discord gateway socket (ports `DiscordWebSocket.kt`) on
/// `URLSessionWebSocketTask`.
///
/// The whole lifecycle lives in one `Task` — `runConnectionLoop` — which
/// connects, pumps frames until the connection goes away for any reason,
/// waits out a backoff and goes round again. Two failures the loop alone
/// does not cover, handled here as in the Kotlin:
///
/// - **Zombie sockets.** A connection that dies while the radio sleeps is not
///   reported as closed. Every heartbeat therefore requires Discord's
///   `HEARTBEAT_ACK`; one going unanswered for a whole interval drops the
///   socket so the loop builds a new one.
/// - **A presence lost with its session.** Discord holds a presence for the
///   gateway session's lifetime and discards it when the session ends, so the
///   last presence (`lastPresence`) is replayed as soon as a new session is
///   ready.
///
/// iOS backgrounding: the system suspends sockets when the app is suspended.
/// Presence updates therefore only flow while the app runs — in practice,
/// while audio plays under the `"Audio"` background mode. A suspended socket
/// looks exactly like a dead one to the watchdog, so backgrounding costs a
/// reconnect and a replayed presence, not a stuck state.
public actor DiscordGatewaySocket {
    public static let defaultGatewayURL = URL(string: "wss://gateway.discord.gg/?v=9&encoding=json")!

    /// The socket's session: the app's HTTP policy (``VibraMusicHTTP``: no cookie jar, no URL
    /// cache) with the minute of idle time `URLSession.shared` gave it. The request timeout can
    /// also bound a WebSocket task's wait for the next frame, and Discord's heartbeat interval
    /// (about 41 s) is longer than VibraMusicHTTP's 30 s.
    public static let defaultSession: URLSession = {
        let configuration = VibraMusicHTTP.makeConfiguration()
        configuration.timeoutIntervalForRequest = 60
        return URLSession(configuration: configuration)
    }()

    public struct Configuration: Hashable, Sendable {
        public var initialBackoffNanoseconds: UInt64
        public var maxBackoffNanoseconds: UInt64
        public var sessionWaitNanoseconds: UInt64
        public var staleGraceNanoseconds: UInt64

        public init(
            initialBackoffNanoseconds: UInt64 = 1_000_000_000,
            maxBackoffNanoseconds: UInt64 = 60_000_000_000,
            sessionWaitNanoseconds: UInt64 = 20_000_000_000,
            staleGraceNanoseconds: UInt64 = 15_000_000_000
        ) {
            self.initialBackoffNanoseconds = initialBackoffNanoseconds
            self.maxBackoffNanoseconds = maxBackoffNanoseconds
            self.sessionWaitNanoseconds = sessionWaitNanoseconds
            self.staleGraceNanoseconds = staleGraceNanoseconds
        }
    }

    private let token: String
    private let gatewayURL: URL
    private let os: String
    private let browser: String
    private let device: String
    private let configuration: Configuration
    private let makeTransport: @Sendable (URL) async throws -> any DiscordGatewayTransport
    private let backoffSleep: @Sendable (UInt64) async -> Void
    private let logger = Logger(subsystem: "com.fortune.vibramusic.ios", category: "Integrations")

    private var loopTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    /// The backoff wait in progress, tagged so a timer from an earlier wait can never resume a
    /// later one (that double resume aborted the app when Wi-Fi dropped).
    private var retryWaiter: (id: UUID, continuation: CheckedContinuation<Void, Never>)?
    private var sessionWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    private var closed = false
    /// Discord refused the token (close code 4004). Terminal: the token is fixed for this socket's
    /// life, so nothing is redialled and presence pushes return at once. A new token needs a new socket.
    private var authenticationRejected = false
    private var sessionReady = false
    /// Whether the current connection attempt got as far as READY or RESUMED. HELLO alone proves only
    /// that the server answered.
    private var sessionOpened = false
    private var sequence = 0
    private var sessionId: String?
    private var resumeGatewayURL: URL?
    private var heartbeatIntervalMs: Int64 = 0
    private var lastAckAt: Date?
    private var awaitingAck = false
    private var immediateRetry = false
    private var currentTransport: (any DiscordGatewayTransport)?
    private var lastPresence: DiscordPresence?
    private var deliveredPresence: DiscordPresence?

    public init(
        token: String,
        gatewayURL: URL = defaultGatewayURL,
        session: URLSession = DiscordGatewaySocket.defaultSession,
        os: String = "iOS",
        browser: String = "Discord iOS",
        device: String = "iOS Device",
        configuration: Configuration = Configuration(),
        makeTransport: (@Sendable (URL) async throws -> any DiscordGatewayTransport)? = nil,
        // Tests fire backoff timers by hand: the double-resume crash needs an old wait's timer to go off
        // during a newer wait, an order real time can't pin down.
        backoffSleep: @escaping @Sendable (UInt64) async -> Void = { nanoseconds in
            _ = try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.token = token
        self.gatewayURL = gatewayURL
        self.os = os
        self.browser = browser
        self.device = device
        self.configuration = configuration
        self.backoffSleep = backoffSleep
        if let makeTransport {
            self.makeTransport = makeTransport
        } else {
            self.makeTransport = { url in
                URLSessionWebSocketTransport(task: session.webSocketTask(with: url))
            }
        }
    }

    // MARK: - Lifecycle

    /// Starts the connection loop if it isn't already running.
    public func connect() {
        guard !closed, !authenticationRejected, loopTask == nil else { return }
        loopTask = Task { await runConnectionLoop() }
    }

    /// Collapses the reconnect backoff so the loop tries now. A track change
    /// is evidence the user is listening and shouldn't wait on a timer set
    /// when the last attempt failed.
    public func retryNow() {
        guard !closed else { return }
        if let waiter = retryWaiter {
            retryWaiter = nil
            waiter.continuation.resume()
        }
    }

    public func close() async {
        closed = true
        sessionReady = false
        lastPresence = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        loopTask?.cancel()
        loopTask = nil
        if let waiter = retryWaiter { retryWaiter = nil; waiter.continuation.resume() }
        for (_, waiter) in sessionWaiters { waiter.resume(returning: false) }
        sessionWaiters.removeAll()
        await currentTransport?.close()
        currentTransport = nil
    }

    public func isConnected() -> Bool {
        sessionReady && !isStale()
    }

    /// Whether Discord refused the token. The socket has stopped for good; the owner of the token
    /// should ask the user to sign in again.
    public func isAuthenticationRejected() -> Bool {
        authenticationRejected
    }

    // MARK: - Presence

    /// Publishes `presence`, waiting for a usable session if there isn't one
    /// yet. Bounded: a push that times out is not lost — it becomes the
    /// presence `onSessionReady` replays when a session comes back.
    public func sendActivity(_ presence: DiscordPresence) async {
        lastPresence = presence
        guard !closed, !authenticationRejected else { return }
        if sessionReady, isStale() { await dropSocket(why: "stale before a presence push") }
        connect()
        retryNow()
        let ready = await waitForSession(timeoutNanoseconds: configuration.sessionWaitNanoseconds)
        guard ready, !Task.isCancelled else {
            logger.warning("Gateway: no session for presence push; it will be replayed on reconnect")
            return
        }
        await sendPresence(presence)
    }

    /// Publishes an activity-less presence (how Discord is told to clear the
    /// card) without waiting for a session. With the socket already down there
    /// is nothing left on Discord to clear; recording it as `lastPresence` is
    /// what matters, so a later reconnect replays the *clear* rather than a
    /// stopped track.
    public func clearActivity() async {
        let presence = DiscordPresence(activities: [])
        lastPresence = presence
        guard !closed, sessionReady, !isStale() else { return }
        await sendPresence(presence)
    }

    // MARK: - Connection loop

    private func runConnectionLoop() async {
        var backoff = configuration.initialBackoffNanoseconds
        while !closed, !Task.isCancelled {
            let url = resumeGatewayURL ?? gatewayURL
            var closeCode: Int?
            sessionOpened = false
            do {
                let transport = try await makeTransport(url)
                guard !closed, !Task.isCancelled else {
                    await transport.close()
                    return
                }
                currentTransport = transport
                // Connected means a session opened (READY or RESUMED), not that a frame arrived:
                // URLSessionWebSocketTask connects lazily, and a resume URL can answer HELLO and then
                // hang up. Counting either as connected kept the loop on a dead resume URL, and kept the
                // backoff at its floor.
                closeCode = await pump(transport)
                if sessionOpened { backoff = configuration.initialBackoffNanoseconds }
            } catch {
                if Task.isCancelled || closed { return }
                logger.error("Gateway: could not connect: \(error.localizedDescription, privacy: .public)")
            }
            await teardownSocket()
            if closed { return }
            if closeCode == DiscordCloseCode.authenticationFailed {
                rejectToken()
                return
            }
            // 4007 and 4009 say the session is gone. Only a resume can be refused for that, so when
            // there was state to drop the identify that follows is a new attempt and goes at once;
            // with none, the identify itself was refused and the backoff applies.
            let sessionGone = closeCode == DiscordCloseCode.invalidSequence
                || closeCode == DiscordCloseCode.sessionTimedOut
            let retryAtOnce = sessionGone && sessionId != nil
            // An attempt that died before a session opened suggests a stale
            // resume URL as often as a dead network; the base gateway always
            // takes a fresh identify.
            if sessionGone || !sessionOpened { forgetSession() }
            if immediateRetry || retryAtOnce {
                immediateRetry = false
                continue
            }
            await waitBackoff(backoff)
            backoff = min(backoff * 2, configuration.maxBackoffNanoseconds)
        }
    }

    /// Reads frames until the socket goes away; returns the close code Discord gave, if any.
    private func pump(_ transport: any DiscordGatewayTransport) async -> Int? {
        while !closed, !Task.isCancelled {
            do {
                let text = try await transport.receive()
                if text.isEmpty { continue }
                if let payload = try? DiscordGatewayPayload.decode(text) {
                    await onMessage(payload)
                } else {
                    logger.warning("Gateway: unreadable message (\(text.utf8.count) bytes) dropped")
                }
            } catch {
                // Named, not swallowed: a socket that dies on every READY looked exactly like a quiet
                // one, and presence silently never appeared.
                let code = (error as? DiscordTransportClosed)?.code
                if !closed, !Task.isCancelled {
                    logger.error("Gateway: socket closed (code \(code ?? 0, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                }
                return code
            }
        }
        return nil
    }

    /// Stops for good after Discord refused the token, and frees any presence push waiting on a
    /// session that will now never come.
    private func rejectToken() {
        logger.error("Gateway: Discord rejected the token (close code 4004); not reconnecting")
        authenticationRejected = true
        loopTask = nil
        for (_, waiter) in sessionWaiters { waiter.resume(returning: false) }
        sessionWaiters.removeAll()
    }

    private func teardownSocket() async {
        sessionReady = false
        awaitingAck = false
        deliveredPresence = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        await currentTransport?.close()
        currentTransport = nil
    }

    private func forgetSession() {
        resumeGatewayURL = nil
        sessionId = nil
        sequence = 0
    }

    private func dropSocket(why: String) async {
        logger.warning("Gateway: dropping socket (\(why, privacy: .public))")
        sessionReady = false
        await currentTransport?.close()
        // The pump observes the close and returns, ending this attempt.
    }

    private func waitBackoff(_ nanoseconds: UInt64) async {
        let id = UUID()
        await withCheckedContinuation { continuation in
            retryWaiter = (id, continuation)
            Task {
                await self.backoffSleep(nanoseconds)
                self.finishBackoff(id)
            }
        }
    }

    /// Ends the backoff wait `id` when its timer fires, unless retryNow() or close() already ended
    /// it. Checking the id, not just "is a wait stored", matters: by the time an old timer fires,
    /// the stored wait can be a newer one, and resuming the old continuation again crashes.
    private func finishBackoff(_ id: UUID) {
        guard let waiter = retryWaiter, waiter.id == id else { return }
        retryWaiter = nil
        waiter.continuation.resume()
    }

    private func waitForSession(timeoutNanoseconds: UInt64) async -> Bool {
        if sessionReady { return true }
        if closed || authenticationRejected { return false }
        let id = UUID()
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            self.expireSessionWaiter(id)
        }
        let ready = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            if self.sessionReady || self.closed {
                continuation.resume(returning: self.sessionReady)
            } else {
                self.sessionWaiters[id] = continuation
            }
        }
        timeoutTask.cancel()
        return ready
    }

    private func expireSessionWaiter(_ id: UUID) {
        guard let waiter = sessionWaiters.removeValue(forKey: id) else { return }
        waiter.resume(returning: false)
    }

    private func markSessionReady() {
        sessionReady = true
        sessionOpened = true
        lastAckAt = Date()
        let waiters = sessionWaiters
        sessionWaiters.removeAll()
        for (_, waiter) in waiters { waiter.resume(returning: true) }
    }

    // MARK: - Frames

    private func onMessage(_ payload: DiscordGatewayPayload) async {
        if let seq = payload.s { sequence = seq }
        switch payload.op {
        case .dispatch:
            await handleDispatch(payload)
        case .heartbeat:
            await sendHeartbeat()
        case .heartbeatAck:
            awaitingAck = false
            lastAckAt = Date()
        case .reconnect:
            immediateRetry = true
            await dropSocket(why: "gateway asked us to reconnect")
        case .invalidSession:
            await handleInvalidSession()
        case .hello:
            await handleHello(payload)
        default:
            break
        }
    }

    private func handleDispatch(_ payload: DiscordGatewayPayload) async {
        switch payload.t {
        case "READY":
            if let data = try? DiscordGatewayPayload.encoder.encode(payload.d),
               let ready = try? JSONDecoder().decode(DiscordReady.self, from: data)
            {
                sessionId = ready.sessionId
                if let resumeString = ready.resumeGatewayUrl,
                   let resumeURL = URL(string: resumeString + "/?v=9&encoding=json")
                {
                    resumeGatewayURL = resumeURL
                }
            }
            onSessionReady()
        case "RESUMED":
            onSessionReady()
        default:
            break
        }
    }

    private func onSessionReady() {
        markSessionReady()
        guard let presence = lastPresence else { return }
        Task { await self.sendPresence(presence) }
    }

    private func handleInvalidSession() async {
        // The session these named is the one Discord just invalidated;
        // resuming against it again would loop.
        forgetSession()
        try? await Task.sleep(nanoseconds: 150_000_000)
        await sendIdentify()
    }

    private func handleHello(_ payload: DiscordGatewayPayload) async {
        guard let interval = DiscordHello.interval(from: payload) else { return }
        heartbeatIntervalMs = interval
        // Handshake first, then heartbeats — the order Discord's own client
        // uses. A gateway answering the handshake with silence is still
        // caught: the watchdog drops the socket after one unanswered interval.
        if sequence > 0, sessionId != nil {
            await sendResume()
        } else {
            await sendIdentify()
        }
        startHeartbeatJob(intervalMs: interval)
    }

    private func sendHeartbeat() async {
        await send(DiscordGatewayFrames.heartbeat(sequence: sequence))
    }

    private func sendIdentify() async {
        guard let text = try? DiscordGatewayFrames.identify(token: token, os: os, browser: browser, device: device) else {
            return
        }
        await send(text)
    }

    private func sendResume() async {
        guard let text = try? DiscordGatewayFrames.resume(seq: sequence, sessionId: sessionId, token: token) else {
            return
        }
        await send(text)
    }

    private func send(_ text: String) async {
        guard let transport = currentTransport else { return }
        try? await transport.send(text)
    }

    private func sendPresence(_ presence: DiscordPresence) async {
        // Discord rate-limits presence updates and both this call and the
        // fresh-session replay fire with the same payload; the second is dropped.
        if deliveredPresence == presence { return }
        guard let text = try? DiscordGatewayFrames.presenceUpdate(presence) else { return }
        guard let transport = currentTransport else { return }
        // Recorded before the send suspends. A new session reaches here twice at once, from the push
        // that was waiting for it and from the replay, and a check that only saw finished sends let
        // both through.
        deliveredPresence = presence
        do {
            try await transport.send(text)
        } catch {
            // Not delivered after all, so the next session still replays it.
            if deliveredPresence == presence { deliveredPresence = nil }
        }
    }

    private func startHeartbeatJob(intervalMs: Int64) {
        heartbeatTask?.cancel()
        awaitingAck = false
        lastAckAt = Date()
        heartbeatTask = Task {
            let intervalNs = UInt64(max(intervalMs, 0)) * 1_000_000
            while !Task.isCancelled {
                if await self.takeHeartbeatTurn() == false { return }
                try? await Task.sleep(nanoseconds: intervalNs)
            }
        }
    }

    /// One heartbeat turn. Returns `false` when the socket was dropped.
    private func takeHeartbeatTurn() async -> Bool {
        if awaitingAck {
            await dropSocket(why: "heartbeat went unacknowledged")
            return false
        }
        awaitingAck = true
        await sendHeartbeat()
        return true
    }

    private func isStale() -> Bool {
        guard heartbeatIntervalMs > 0, let lastAck = lastAckAt else { return false }
        let sinceAckNs = UInt64(Date().timeIntervalSince(lastAck) * 1_000_000_000)
        return sinceAckNs > UInt64(heartbeatIntervalMs) * 1_000_000 + configuration.staleGraceNanoseconds
    }
}
