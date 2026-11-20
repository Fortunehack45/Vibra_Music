import VibraMusicCore
import Foundation

/// A refusal from the server, carrying the machine-readable half.
/// (Ports `ListenTogether.PartyException`.)
public struct PartyClientError: Error, Hashable, Sendable {
    public var code: String
    public var message: String
    public var statusCode: Int?

    public init(code: String, message: String, statusCode: Int? = nil) {
        self.code = code
        self.message = message
        self.statusCode = statusCode
    }

    /// What the listener is told when the transport fails.
    public var displayMessage: String {
        code == "__transport__" ? "Couldn’t reach the party server." : message
    }

    public static func transport(_ error: Error) -> PartyClientError {
        PartyClientError(code: "__transport__", message: error.localizedDescription)
    }
}

public enum PartySwitchResult: Hashable, Sendable {
    case success(partyCode: String)
    case targetFailedRecovered(partyCode: String, targetError: String)
    case targetFailedNoParty(targetError: String)
}

/// Listen together: one party, shared by up to five signed-in devices.
///
/// The whole client half of the feature — membership, the socket, the clock, and the
/// controls any member may send. It does **not** touch the player. What it publishes
/// instead is the session state, from which `PartySessionState/positionMs(serverNowMs:)`
/// answers where this device ought to be right now, on its own clock.
/// `PartySyncCoordinator` is what binds that to the player, and it lives outside this
/// actor, because everything above that line is testable and everything below it is not.
///
/// Backgrounding, the screen going off, a tunnel, a handover — none of those end a party;
/// the reconnect loop below exists for exactly that. The membership outlives the socket
/// (the server holds the slot through its 45 s grace period), so reconnecting is invisible
/// to everyone else, and the clock is re-sampled on arrival rather than trusted across
/// the gap. The app calls `noteResumed()` when it comes back; a socket kept alive by
/// background audio needs nothing. (Ports `ListenTogether` in
/// `data/listentogether/ListenTogether.kt`, over `URLSessionWebSocketTask` per PORTING.md §5.)
public actor PartyClient {
    private static let logCategory = "ListenTogether"

    private let store: PartyServerStore
    private let session: URLSession
    private let clock: PartyServerClock
    private let identityProvider: (any PartyIdentityProvider)?
    private let monotonicMs: () -> Int64
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    private var _state = PartySessionState()
    private var _activity: [PartyActivity] = []
    private var _connectionState: PartyServerConnectionState = .checking
    private var _effectiveIdleServer: String
    private var _awaitingStart = false

    private var token: String?
    private var activeServerBase: String?
    private var socketTask: Task<Void, Never>?
    private var webSocket: URLSessionWebSocketTask?
    private var continuations: [UUID: AsyncStream<PartySessionState>.Continuation] = [:]
    /// False in offline tests: membership commits without opening a socket.
    private var socketEnabled = true

    /// - Parameters:
    ///   - identityProvider: nil in tests that pass identities explicitly.
    public init(
        store: PartyServerStore,
        urlSession: URLSession = VibraMusicHTTP.session,
        clock: PartyServerClock = PartyServerClock(),
        identityProvider: (any PartyIdentityProvider)? = nil,
        monotonicMs: @escaping () -> Int64 = PartyServerClock.systemMonotonicMs
    ) {
        self.store = store
        self.session = urlSession
        self.clock = clock
        self.identityProvider = identityProvider
        self.monotonicMs = monotonicMs
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
        self._effectiveIdleServer = store.customServer.isEmpty ? store.defaultServer : store.customServer
    }

    // MARK: - Observed state

    public var state: PartySessionState { _state }
    public var activity: [PartyActivity] { _activity }
    public var serverConnection: PartyServerConnectionState { _connectionState }
    public var effectiveIdleServer: String { _effectiveIdleServer }
    public var activePartyServer: String? { activeServerBase }

    /// Whether idle operations are currently falling back to the default server.
    public var isUsingDefaultFallback: Bool {
        let configured = store.customServer
        return !configured.isEmpty
            && _effectiveIdleServer == store.defaultServer
            && configured != store.defaultServer
    }

    public var hasServer: Bool { !_effectiveIdleServer.isEmpty }

    /// A resume this device has accepted but is not allowed to perform yet. Written only by
    /// the sync engine, which owns the wait; held here because the player screen is the only
    /// thing that needs to see it and the player itself is not something the UI can reach.
    public var awaitingStart: Bool {
        get { _awaitingStart }
        set {
            _awaitingStart = newValue
            yieldState()
        }
    }

    public func setAwaitingStart(_ value: Bool) {
        _awaitingStart = value
        yieldState()
    }

    /// The server's clock, read from here. Nil until the first pong lands.
    public func serverClockNow() -> Int64? {
        clock.serverNowMs()
    }

    public func stateStream() -> AsyncStream<PartySessionState> {        let id = UUID()
        return AsyncStream { [weak self] continuation in
            guard let self else { continuation.finish(); return }
            Task { await self.addContinuation(id, continuation) }
            continuation.onTermination = { _ in Task { await self.removeContinuation(id) } }
        }
    }

    private func addContinuation(_ id: UUID, _ c: AsyncStream<PartySessionState>.Continuation) {
        continuations[id] = c
        c.yield(_state)
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func updateState(_ transform: (inout PartySessionState) -> Void) {
        transform(&_state)
        yieldState()
    }

    private func yieldState() {
        let snapshot = _state
        for c in continuations.values { c.yield(snapshot) }
    }

    private func recordActivity(_ entry: PartyActivity) {
        _activity = ([entry] + _activity).prefix(100).map { $0 }
    }

    // MARK: - Startup

    /// Hands a previous process's slot back, so the others see them leave now rather than
    /// when the server's disconnect grace sweeps it — then probes the idle server health.
    /// A party lasts as long as the app is open; closing the app ends it.
    public func start() async {
        if let saved = store.savedMembership() {
            let server = activeServerBase ?? PartyServerConfig.resolveHttpBase(
                _effectiveIdleServer, defaultServer: store.defaultServer)
            store.clearMembership()
            await releaseSlotOnServer(server: server, code: saved.code, token: saved.token)
        }
        await refreshServerHealth()
    }

    private func releaseSlotOnServer(server: String, code: String, token: String) async {
        guard !server.isEmpty, !code.isEmpty, !token.isEmpty else { return }
        var request = URLRequest(url: URL(string: "\(server)/api/parties/\(code)/leave")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: request)
    }

    // MARK: - Server health

    public func setScreenActive(_ active: Bool) async {
        if active { await refreshServerHealth() }
    }

    public func refreshServerHealth() async {
        let custom = store.customServer
        let (effective, state) = await PartyServerConfig.resolveServerConnection(
            customServer: custom,
            defaultServer: store.defaultServer,
            probeCustom: { await self.probeHealthWithLatency(server: custom, timeout: 6) },
            probeDefault: { await self.probeHealthWithLatency(
                server: self.store.defaultServer, timeout: 30) }
        )
        _effectiveIdleServer = effective
        _connectionState = state
    }

    /// Points this install at another server, or back at the default one if blank.
    /// Accepts only canonical URLs produced by `parseAndNormalizeServerUrl`.
    public func setCustomServerUrl(_ normalizedUrl: String) async -> PartyServerConnectionState {
        // A caller's contract, but one that rides on user input: refuse an address that isn't
        // canonical rather than trap on it.
        guard PartyServerConfig.parseAndNormalizeServerUrl(normalizedUrl) == .valid(normalizedUrl: normalizedUrl) else {
            return _connectionState
        }
        store.setCustomServer(normalizedUrl)
        await refreshServerHealth()
        return _connectionState
    }

    func probeHealthWithLatency(server: String, timeout: TimeInterval) async -> PartyProbeResult {
        let raw = PartyServerConfig.resolveHttpBase(server, defaultServer: store.defaultServer)
        guard !raw.isEmpty, let url = URL(string: "\(raw)/healthz") else {
            return PartyProbeResult(isOnline: false)
        }
        let start = monotonicMs()
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
                return PartyProbeResult(isOnline: false)
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            guard body.contains("\"ok\":true") else { return PartyProbeResult(isOnline: false) }
            return PartyProbeResult(isOnline: true, latencyMs: max(0, monotonicMs() - start))
        } catch {
            DebugLog.w(Self.logCategory, "health check failed: \(error.localizedDescription)")
            return PartyProbeResult(isOnline: false)
        }
    }

    // MARK: - Joining

    public var nickname: String { store.nickname }
    public func setNickname(_ value: String) { store.setNickname(value) }

    public func canJoin() async -> Bool {
        await identityProvider?.partyIdentity() != nil
    }

    /// Creates a party on the idle server, falling back to the default server when the
    /// custom one is unreachable (transport outage or 5xx — never a 4xx).
    public func createParty(nickname: String? = nil, maxMembers: Int = PartyLimits.defaultMaxMembers, autoplayEnabled: Bool = true) async -> Result<String, PartyClientError> {
        let primary = PartyServerConfig.resolveHttpBase(
            _effectiveIdleServer, defaultServer: store.defaultServer)
        do {
            let code = try await doCreateOnServer(primary, nickname: nickname, maxMembers: maxMembers, autoplayEnabled: autoplayEnabled)
            return .success(code)
        } catch {
            var failure = error
            if PartyServerConfig.normalizeServerBase(primary) != store.defaultServer,
               Self.isEligibleForFallback(error)
            {
                DebugLog.w(Self.logCategory, "createParty failed on custom server, falling back to default")
                let fallback = PartyServerConfig.resolveHttpBase(
                    store.defaultServer, defaultServer: store.defaultServer)
                do {
                    let code = try await doCreateOnServer(
                        fallback, nickname: nickname, maxMembers: maxMembers, autoplayEnabled: autoplayEnabled)
                    return .success(code)
                } catch {
                    failure = error
                }
            }
            let wrapped = failure as? PartyClientError ?? PartyClientError.transport(failure)
            updateState { $0.error = wrapped.displayMessage }
            return .failure(wrapped)
        }
    }

    private func doCreateOnServer(
        _ serverBase: String, nickname: String?, maxMembers: Int, autoplayEnabled: Bool,
        identity: PartyIdentity? = nil
    ) async throws -> String {
        let who: PartyIdentity?
        if let identity { who = identity } else { who = await identityProvider?.partyIdentity() }
        guard let who else {
            throw PartyClientError(code: "not_signed_in", message: "Sign in to listen together.")
        }
        guard !serverBase.isEmpty else {
            throw PartyClientError(code: "no_server", message: "Set the party server address first.")
        }
        let name = nickname?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? who.displayName
        let membership: PartyMembership = try await post(
            "\(serverBase)/api/parties",
            body: PartyJoinRequest(
                userId: who.userId, deviceId: who.deviceId, displayName: name,
                avatarUrl: who.avatarUrl, maxMembers: maxMembers, autoplayEnabled: autoplayEnabled))
        commitMembership(serverBase: serverBase, membership: membership)
        connect()
        return membership.code
    }

    /// Joins a party on the idle server. IDLE only: use `switchParty` for deep-link
    /// transitions while already live in a party.
    public func joinParty(code: String, nickname: String? = nil) async -> Result<String, PartyClientError> {
        let target = PartyServerConfig.resolveHttpBase(
            _effectiveIdleServer, defaultServer: store.defaultServer)
        do {
            return .success(try await doJoinOnServer(target, code: code, nickname: nickname))
        } catch let failure as PartyClientError {
            DebugLog.w(Self.logCategory, "could not enter a party: \(failure.code)")
            updateState { $0.error = failure.displayMessage }
            return .failure(failure)
        } catch {
            let wrapped = PartyClientError.transport(error)
            updateState { $0.error = wrapped.displayMessage }
            return .failure(wrapped)
        }
    }

    private func doJoinOnServer(
        _ serverBase: String, code: String, nickname: String?,
        identity: PartyIdentity? = nil
    ) async throws -> String {
        let who: PartyIdentity?
        if let identity { who = identity } else { who = await identityProvider?.partyIdentity() }
        guard let who else {
            throw PartyClientError(code: "not_signed_in", message: "Sign in to listen together.")
        }
        guard !serverBase.isEmpty else {
            throw PartyClientError(code: "no_server", message: "Set the party server address first.")
        }
        let cleaned = PartyCode.normalize(code)
        guard cleaned.count == PartyLimits.codeLength, PartyCode.isValid(cleaned) else {
            throw PartyClientError(code: "bad_code", message: "A party code is six letters or digits.")
        }
        try refuseIfRecentlyKicked(cleaned)
        let name = nickname?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? who.displayName
        let membership: PartyMembership = try await post(
            "\(serverBase)/api/parties/\(cleaned)/join",
            body: PartyJoinRequest(
                userId: who.userId, deviceId: who.deviceId, displayName: name, avatarUrl: who.avatarUrl))
        commitMembership(serverBase: serverBase, membership: membership)
        connect()
        return membership.code
    }

    private func commitMembership(serverBase: String, membership: PartyMembership) {
        activeServerBase = serverBase
        token = membership.token
        store.saveMembership(code: membership.code, token: membership.token)
        clock.reset()
        _state = PartySessionState(
            code: membership.code,
            you: membership.you,
            members: membership.party.members,
            maxMembers: membership.party.maxMembers,
            hostOnlyControl: membership.party.hostOnlyControl,
            playback: membership.party.playback,
            queue: membership.party.queue,
            connection: .connecting)
        yieldState()
    }

    // MARK: - Deep-link switching

    /// Transactionally transitions to an invite target: the target `/join` is attempted
    /// before the current party or the persisted server preference is touched, so a failed
    /// target leaves the current party untouched. Strictly contacts the target server and
    /// never queries idle fallback. (Ports `ListenTogether.switchPartyWithRecovery`.)
    public func switchParty(targetServer: String, targetCode: String, nickname: String? = nil) async -> PartySwitchResult {
        guard let who = await identityProvider?.partyIdentity() else {
            let message = "Sign in to listen together."
            if let code = _state.code { return .targetFailedRecovered(partyCode: code, targetError: message) }
            return .targetFailedNoParty(targetError: message)
        }
        guard case .valid(let normTarget) = PartyServerConfig.parseAndNormalizeServerUrl(targetServer) else {
            let message = "Target server address is invalid."
            if let code = _state.code { return .targetFailedRecovered(partyCode: code, targetError: message) }
            return .targetFailedNoParty(targetError: message)
        }
        let targetBase = PartyServerConfig.resolveHttpBase(normTarget, defaultServer: store.defaultServer)
        guard !targetBase.isEmpty else {
            let message = "Target server address is invalid or missing."
            if let code = _state.code { return .targetFailedRecovered(partyCode: code, targetError: message) }
            return .targetFailedNoParty(targetError: message)
        }
        let cleaned = PartyCode.normalize(targetCode)
        guard PartyCode.isValid(cleaned) else {
            let message = "A party code is six letters or digits."
            if let code = _state.code { return .targetFailedRecovered(partyCode: code, targetError: message) }
            return .targetFailedNoParty(targetError: message)
        }
        if store.isKickedOut(of: cleaned) {
            let refusal = "Couldn’t let you in — you’ve recently been kicked out of this party."
            if let code = _state.code { return .targetFailedRecovered(partyCode: code, targetError: refusal) }
            return .targetFailedNoParty(targetError: refusal)
        }

        let oldServer = activeServerBase ?? PartyServerConfig.resolveHttpBase(
            store.customServer, defaultServer: store.defaultServer)
        let oldCode = _state.code
        let oldToken = token

        let name = nickname?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? who.displayName
        let attempt: PartyMembership
        do {
            attempt = try await post(
                "\(targetBase)/api/parties/\(cleaned)/join",
                body: PartyJoinRequest(
                    userId: who.userId, deviceId: who.deviceId, displayName: name, avatarUrl: who.avatarUrl))
        } catch let failure as PartyClientError {
            DebugLog.w(Self.logCategory, "failed to join target party: \(failure.code)")
            if let code = oldCode { return .targetFailedRecovered(partyCode: code, targetError: failure.displayMessage) }
            return .targetFailedNoParty(targetError: failure.displayMessage)
        } catch {
            let wrapped = PartyClientError.transport(error)
            if let code = oldCode { return .targetFailedRecovered(partyCode: code, targetError: wrapped.displayMessage) }
            return .targetFailedNoParty(targetError: wrapped.displayMessage)
        }

        // Commit: the target join succeeded. Release the old slot asynchronously,
        // drop the old socket, and move authority to the target.
        if let oldCode, let oldToken, oldServer != targetBase || oldCode != attempt.code {
            let server = oldServer, oc = oldCode, ot = oldToken
            Task { await self.releaseSlotOnServer(server: server, code: oc, token: ot) }
        }
        socketTask?.cancel()
        socketTask = nil
        webSocket?.cancel()
        webSocket = nil
        activeServerBase = targetBase
        store.setCustomServer(normTarget)
        await refreshServerHealth()
        commitMembership(serverBase: targetBase, membership: attempt)
        connect()
        return .success(partyCode: attempt.code)
    }

    /// Gives up this device's slot. The party carries on without it.
    public func leaveParty() async {
        let code = _state.code
        let held = token
        let server = activeServerBase ?? PartyServerConfig.resolveHttpBase(
            _effectiveIdleServer, defaultServer: store.defaultServer)
        socketTask?.cancel()
        socketTask = nil
        webSocket?.cancel()
        webSocket = nil
        clock.reset()
        token = nil
        activeServerBase = nil
        store.clearMembership()
        _state = PartySessionState()
        _awaitingStart = false
        yieldState()
        if let code, let held {
            await releaseSlotOnServer(server: server, code: code, token: held)
        }
    }

    // MARK: - Recently kicked

    private func refuseIfRecentlyKicked(_ code: String) throws {
        if store.isKickedOut(of: code) {
            throw PartyClientError(
                code: "recently_kicked",
                message: "Couldn’t let you in — you’ve recently been kicked out of this party.")
        }
    }

    /// REST plumbing throws the session's own error for a transport failure, so the
    /// outage is still visible here; a `PartyClientError` is an answer from the server.
    private static func isEligibleForFallback(_ error: Error) -> Bool {
        if let failure = error as? PartyClientError {
            return PartyServerConfig.isEligibleForFallback(statusCode: failure.statusCode)
        }
        return PartyServerConfig.isEligibleForFallback(statusCode: nil, transportError: error)
    }

    // MARK: - Preview

    /// Who is in a party, before committing a slot to it. Unauthenticated on both sides —
    /// what it discloses is exactly what joining would disclose a second later.
    public func previewParty(code: String, server: String? = nil) async -> Result<PartyPreview, PartyClientError> {
        let cleaned = PartyCode.normalize(code)
        guard PartyCode.isValid(cleaned) else {
            return .failure(PartyClientError(code: "bad_code", message: "A party code is six letters or digits."))
        }
        if store.isKickedOut(of: cleaned) {
            return .failure(PartyClientError(
                code: "recently_kicked",
                message: "Couldn’t let you in — you’ve recently been kicked out of this party."))
        }
        let base = PartyServerConfig.resolveHttpBase(
            server ?? _effectiveIdleServer, defaultServer: store.defaultServer)
        guard !base.isEmpty else {
            return .failure(PartyClientError(code: "no_server", message: "Set the party server address first."))
        }
        do {
            let preview: PartyPreview = try await get("\(base)/api/parties/\(cleaned)/preview")
            return .success(preview)
        } catch let failure as PartyClientError {
            // A server that predates the endpoint answers the unknown route as plain-text
            // 404, which parses with no machine code — that is "cannot be looked at", not
            // "does not exist", so the confirmation still confirms.
            if failure.statusCode == 404, failure.code == "http_404" {
                return .success(PartyPreview(code: cleaned))
            }
            return .failure(failure)
        } catch {
            return .failure(PartyClientError.transport(error))
        }
    }

    // MARK: - Controls

    public func play(at positionMs: Int64? = nil) { sendControl(.play(at: positionMs)) }
    public func pause(at positionMs: Int64? = nil) { sendControl(.pause(at: positionMs)) }
    public func seek(to positionMs: Int64) { sendControl(.seek(to: positionMs)) }
    public func next() { sendControl(.next()) }
    public func previous() { sendControl(.previous()) }

    public func setTrack(_ track: PartyTrack, positionMs: Int64 = 0, isPlaying: Bool = true) {
        sendControl(.setTrack(track, positionMs: positionMs, isPlaying: isPlaying))
    }

    public func setQueue(_ queue: [PartyTrack], index: Int) {
        sendControl(.setQueue(queue, index: index))
    }

    public func queueAdd(_ tracks: [PartyTrack], playNext: Bool = false) {
        sendControl(.queueAdd(tracks, playNext: playNext))
    }

    public func queueRemove(videoId: String) { sendControl(.queueRemove(videoId: videoId)) }
    public func queueClear() { sendControl(.queueClear()) }

    public func queueMove(from fromIndex: Int, to toIndex: Int, videoId: String? = nil) {
        sendControl(.queueMove(from: fromIndex, to: toIndex, videoId: videoId))
    }

    public func setMaxMembers(_ value: Int) { sendControl(.setMaxMembers(value)) }
    public func kick(memberId: String) { sendControl(.kick(memberId: memberId)) }
    public func setAutoplay(_ enabled: Bool) { sendControl(.setAutoplay(enabled)) }

    /// Host only, and refused by the server from anybody else.
    public func setHostOnlyControl(_ enabled: Bool) {
        sendControl(.setHostOnlyControl(enabled))
    }

    private func sendControl(_ message: PartyControlMessage) {
        controlSinkForTesting?(message)
        guard let socket = webSocket else { return }
        guard let data = try? encoder.encode(message),
              let text = String(data: data, encoding: .utf8)
        else { return }
        Task {
            do { try await socket.send(.string(text)) }
            catch { DebugLog.w(Self.logCategory, "control not sent: \(message.action.rawValue)") }
        }
    }

    // MARK: - Playhead

    /// Where this device should be in the current track, right now.
    public func partyPositionMs() -> Int64? {
        _state.positionMs(serverNowMs: clock.serverNowMs())
    }

    /// How far in the future the party's next resume is scheduled, or 0 if under way.
    public func msUntilStart() -> Int64 {
        _state.msUntilStart(serverNowMs: clock.serverNowMs())
    }

    // MARK: - Socket

    /// Opens the socket for a live membership. Idempotent — returns immediately when a
    /// socket task is already up or when there is no party. The app calls this on resume;
    /// the server's 45 s grace period keeps the slot meanwhile. (PORTING.md §4.)
    public func ensureConnected() {
        guard _state.code != nil, token != nil, socketTask == nil else { return }
        connect()
    }

    public func noteResumed() {
        ensureConnected()
    }

    private func connect() {
        guard socketEnabled else { return }
        socketTask?.cancel()
        socketTask = Task { await self.runSocketLoop() }
    }

    /// Connect, pump frames until the connection goes away for any reason, back off, go
    /// round again. The loop is the design, not error handling bolted onto one: a socket
    /// held by a backgrounded music app is dropped repeatedly over a session — the radio
    /// sleeping, a Wi-Fi handover, a captive portal — and every one of those has to heal
    /// without anyone reopening the app.
    private func runSocketLoop() async {
        var backoffNs: UInt64 = 1_000_000_000
        var refusals = 0
        while !Task.isCancelled {
            guard let code = _state.code, let held = token else { return }
            let base = activeServerBase ?? PartyServerConfig.resolveHttpBase(
                _effectiveIdleServer, defaultServer: store.defaultServer)
            updateState { $0.connection = .connecting }
            var request = URLRequest(url: URL(
                string: "\(PartyServerConfig.wsBase(httpBase: base))/ws/parties/\(code)")!)
            request.setValue("Bearer \(held)", forHTTPHeaderField: "Authorization")
            // Tokens ride the handshake header, never the URL, so they stay out of logs.
            let socket = session.webSocketTask(with: request)
            webSocket = socket
            socket.resume()
            let pingTask = Task { await self.pingLoop(socket) }
            let reportTask = Task { await self.reportLoop(socket) }
            var heardFrame = false
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    // Live means the server answered, not that the handshake was started: a
                    // refused one only surfaces here, and would flash "live" every backoff cycle.
                    if !heardFrame {
                        heardFrame = true
                        refusals = 0
                        backoffNs = 1_000_000_000
                        updateState { $0.connection = .live; $0.error = nil }
                    }
                    switch message {
                    case .string(let text): onFrame(text)
                    case .data: break
                    @unknown default: break
                    }
                }
            } catch {
                // Cancellation unwinds the receive; anything else is a drop worth logging.
                if !Task.isCancelled, (error as NSError).code != NSURLErrorCancelled {
                    DebugLog.w(Self.logCategory, "party socket dropped")
                }
                // A server that restarted refuses the handshake itself, so the in-band
                // `no_such_party` / `bad_token` frames never get sent.
                let status = (socket.response as? HTTPURLResponse)?.statusCode
                refusals = !heardFrame && (status == 401 || status == 404) ? refusals + 1 : 0
            }
            pingTask.cancel()
            reportTask.cancel()
            socket.cancel()
            if webSocket === socket { webSocket = nil }
            if Task.isCancelled { return }
            if refusals >= PartyLimits.handshakeRefusalLimit {
                DebugLog.w(Self.logCategory, "party socket refused as unknown, leaving the party")
                Task { await self.leaveParty() }
                return
            }
            updateState { $0.connection = .connecting }
            // The clock is not carried across a gap. Whatever the offset was before the
            // socket died, the only honest thing to say afterwards is that it has not been
            // measured since.
            clock.reset()
            updateState { $0.clockSynced = false }
            try? await Task.sleep(nanoseconds: backoffNs)
            backoffNs = min(backoffNs * 2, 20_000_000_000)
        }
    }

    /// A burst on arrival, then a slow trickle. The burst is what makes the first seconds
    /// of a party accurate: the best of several quick round trips is a far better offset
    /// than the first one. After that the offset only has to keep up with clock drift.
    private func pingLoop(_ socket: URLSessionWebSocketTask) async {
        for _ in 0 ..< 4 {
            if Task.isCancelled { return }
            await sendPing(socket)
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        while !Task.isCancelled {
            try? await Task.sleep(
                nanoseconds: UInt64(PartyLimits.pingIntervalMs) * 1_000_000)
            if Task.isCancelled { return }
            await sendPing(socket)
        }
    }

    private func sendPing(_ socket: URLSessionWebSocketTask) async {
        let sentAt = monotonicMs()
        let text = "{\"type\":\"ping\",\"clientMs\":\(sentAt)}"
        try? await socket.send(.string(text))
    }

    /// Tells the server where this device actually is. Nothing is decided by it — the
    /// server's state is the truth, and a party averaged towards its slowest member would
    /// be a party that drags. It keeps the membership alive and makes real drift visible
    /// in the server log, the only place the two halves of this feature can be compared.
    private func reportLoop(_ socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            try? await Task.sleep(
                nanoseconds: UInt64(PartyLimits.reportIntervalMs) * 1_000_000)
            if Task.isCancelled { return }
            guard let position = partyPositionMs() else { continue }
            let playing = _state.playback.isPlaying
            let text = "{\"type\":\"report\",\"positionMs\":\(position),\"isPlaying\":\(playing ? "true" : "false")}"
            try? await socket.send(.string(text))
        }
    }

    func onFrame(_ text: String) {
        let received = monotonicMs()
        guard let data = text.data(using: .utf8),
              let frame = try? decoder.decode(PartyServerMessage.self, from: data),
              let type = frame.type
        else { return }
        switch type {
        case .welcome:
            guard let party = frame.party else { return }
            updateState {
                $0.code = party.code
                if let you = frame.you { $0.you = you }
                $0.members = party.members
                $0.maxMembers = party.maxMembers
                $0.hostOnlyControl = party.hostOnlyControl
                $0.playback = party.playback
                // A snapshot is the one message that carries the queue unconditionally —
                // a device that has just arrived has no other way to learn it.
                $0.queue = party.queue
                $0.connection = .live
                $0.error = nil
            }
        case .pong:
            guard let sentAt = frame.clientMs, let serverMs = frame.serverMs else { return }
            clock.record(sentAtLocalMs: sentAt, serverMs: serverMs, receivedAtLocalMs: received)
            updateState {
                $0.clockSynced = clock.isSynced
                $0.roundTripMs = clock.roundTripMs
            }
        case .state:
            guard let playback = frame.playback else { return }
            // Older than what is already applied, so it says nothing: the guard that keeps
            // two simultaneous controllers from sending each other backwards.
            guard playback.seq >= _state.playback.seq else { return }
            updateState { $0.playback = playback }
            // The queue does not ride along with the state — only its sequence number does.
            // Disagreeing with the copy held here means a queue frame was missed, which the
            // heartbeat therefore heals within seconds via an explicit re-request.
            if playback.queueSeq != _state.queue.seq {
                sendSyncQueue()
            }
        case .queue:
            guard let queue = frame.queue else { return }
            guard queue.seq >= _state.queue.seq else { return }
            updateState { $0.queue = queue }
        case .members:
            guard let members = frame.members else { return }
            updateState { current in
                current.members = members
                if let max = frame.maxMembers { current.maxMembers = max }
                // Absent on a server that predates the setting, which is not the same as
                // "off": keeping the value already held means an upgrade mid-party does not
                // silently unlock (or lock) the party.
                if let hostOnly = frame.hostOnlyControl { current.hostOnlyControl = hostOnly }
                // This frame is the only place a promotion is ever announced — the server
                // hands the host role to an arbitrary survivor when a host leaves and says
                // so nowhere else. Left unread, `you` keeps saying "not the host" for the
                // rest of the party, hiding the host's own controls — and, with the lock on,
                // locking them out of a party they now own.
                if let mine = current.you,
                   let promoted = members.first(where: { $0.memberId == mine.memberId })
                {
                    current.you = promoted
                }
            }
        case .activity:
            guard let action = frame.action, !action.isEmpty,
                  let by = frame.by, !by.isEmpty
            else { return }
            recordActivity(PartyActivity(
                action: action, by: by, atMs: frame.atMs ?? received,
                detail: frame.detail ?? ""))
        case .error:
            let message = frame.message
            DebugLog.w(Self.logCategory, "party server refused a frame: \(frame.error ?? "")")
            updateState { $0.error = message }
            // Terminal: the reconnect loop cannot learn on its own that the party no
            // longer knows this device — it would keep dialling for as long as the app
            // is open. The ordinary way here is the server having restarted.
            if frame.error == "bad_token" || frame.error == "no_such_party" {
                Task { await self.leaveParty() }
            }
        case .bye:
            // The server has let this membership go. Reconnecting would be answered with
            // failure forever, so the loop is stopped rather than left spinning. A removal
            // is the one kind worth remembering: the code goes on this device's own
            // shut-out list before the state carrying it is torn down.
            if frame.reason == "kicked", let code = _state.code {
                store.recordKick(code: code)
            }
            Task { await self.leaveParty() }
        }
    }

    private func sendSyncQueue() {
        // `onFrame` is synchronous; the request goes out on the socket task.
        guard let socket = webSocket else { return }
        Task { try? await socket.send(.string("{\"type\":\"syncQueue\"}")) }
    }

    // MARK: - REST plumbing

    private func get<Value: Decodable>(_ urlString: String, token: String? = nil) async throws -> Value {
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "GET"
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return try await perform(request)
    }

    private func post<Body: Encodable, Value: Decodable>(_ urlString: String, body: Body) async throws -> Value {
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        return try await perform(request)
    }

    private func perform<Value: Decodable>(_ request: URLRequest) async throws -> Value {
        // A transport failure keeps its `URLError` so `createParty` can tell an outage from
        // an answer; the `Result` entry points wrap it as `PartyClientError.transport`.
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PartyClientError(code: "__transport__", message: "No response from the party server.")
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw partyError(statusCode: http.statusCode, data: data)
        }
        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            throw PartyClientError(
                code: "bad_response",
                message: "The party server answered in a way this build doesn't understand.",
                statusCode: http.statusCode)
        }
    }

    private func partyError(statusCode: Int, data: Data) -> PartyClientError {
        if let parsed = try? decoder.decode(PartyApiError.self, from: data), !parsed.code.isEmpty {
            return PartyClientError(
                code: parsed.code,
                message: parsed.message.isEmpty ? "The party server said \(statusCode)." : parsed.message,
                statusCode: statusCode)
        }
        let message = statusCode == 422
            ? "This account can't be used to jam."
            : "The party server said \(statusCode)."
        return PartyClientError(
            code: "http_\(statusCode)", message: message, statusCode: statusCode)
    }

    // MARK: - Test hooks

    /// Creates a party against an explicit server with an explicit identity (live tests).
    public func createParty(
        on serverBase: String,
        as identity: PartyIdentity,
        nickname: String? = nil,
        maxMembers: Int = PartyLimits.defaultMaxMembers,
        autoplayEnabled: Bool = true
    ) async throws -> String {
        try await doCreateOnServer(
            serverBase, nickname: nickname, maxMembers: maxMembers,
            autoplayEnabled: autoplayEnabled, identity: identity)
    }

    /// Joins a party against an explicit server with an explicit identity (live tests).
    public func joinParty(
        on serverBase: String,
        code: String,
        as identity: PartyIdentity,
        nickname: String? = nil
    ) async throws -> String {
        try await doJoinOnServer(serverBase, code: code, nickname: nickname, identity: identity)
    }

    /// Polls `state` until `predicate` holds or the timeout lapses (live tests).
    public func waitUntil(
        timeoutSeconds: Double = 15,
        pollIntervalMs: UInt64 = 100,
        _ predicate: @Sendable (PartySessionState) -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if predicate(_state) { return true }
            try? await Task.sleep(nanoseconds: pollIntervalMs * 1_000_000)
        }
        return predicate(_state)
    }

    /// Feeds a raw server frame through the handler (offline protocol tests).
    func receiveForTesting(_ text: String) {
        onFrame(text)
    }

    /// Opens the socket that `commitMembershipForTesting` left closed (offline tests that dial a
    /// local server).
    func connectForTesting() {
        socketEnabled = true
        connect()
    }

    /// Observes outbound controls without a socket (offline sync tests).
    var controlSinkForTesting: ((PartyControlMessage) -> Void)?

    /// Commits a membership without touching the network (offline state tests).
    func commitMembershipForTesting(serverBase: String, membership: PartyMembership) {
        socketEnabled = false
        socketTask?.cancel()
        socketTask = nil
        commitMembership(serverBase: serverBase, membership: membership)
        socketTask?.cancel()
        socketTask = nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
