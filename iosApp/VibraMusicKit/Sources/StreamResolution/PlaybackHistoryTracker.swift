import VibraMusicCore
import Foundation

/// The stats endpoints a player response nominates for one playback. Port of
/// `Innertube.PlaybackTracking`.
struct PlaybackTrackingURLs: Sendable, Equatable {
    var playbackURL: URL
    var watchtimeURL: URL?
    /// The ad-tracking ping real clients fire a few seconds in.
    var atrURL: URL?
    /// How far in `atrURL` is due, per the response's own schedule.
    var atrAfterSeconds: Int

    /// What YouTube Music itself schedules `atr` for, when it doesn't say.
    static let defaultAtrSeconds = 5

    init(playbackURL: URL, watchtimeURL: URL?, atrURL: URL?, atrAfterSeconds: Int) {
        self.playbackURL = playbackURL
        self.watchtimeURL = watchtimeURL
        self.atrURL = atrURL
        self.atrAfterSeconds = atrAfterSeconds
    }

    init?(_ tracking: PlayerResponse.PlaybackTracking?) {
        guard let playback = tracking?.videostatsPlaybackUrl?.baseUrl.flatMap(URL.init(string:)) else { return nil }
        playbackURL = playback
        watchtimeURL = tracking?.videostatsWatchtimeUrl?.baseUrl.flatMap(URL.init(string:))
        atrURL = tracking?.atrUrl?.baseUrl.flatMap(URL.init(string:))
        atrAfterSeconds = tracking?.atrUrl?.elapsedMediaTimeSeconds ?? Self.defaultAtrSeconds
    }
}

/// Registers plays against the signed-in account's YouTube Music history, so recommendations on
/// the home tab reflect what's actually been listened to. Port of `PlaybackTracker.kt` and the
/// `Innertube` calls it made (`playbackTracking`, `pingPlayback`, `pingWatchtime`, `pingAtr`).
///
/// Three pings make one play, which is the sequence a real client performs:
///  - `videostatsPlaybackUrl` the moment a track becomes audible. This creates the history entry.
///  - `atrUrl` a few seconds in, which separates a play that started from a play that happened.
///  - `videostatsWatchtimeUrl` as it plays on, and once more when it ends. An entry with no
///    watchtime behind it looks like a skip, which is close to worthless as a signal.
/// All three carry the same client-playback-nonce; a nonce reused across tracks gets the second
/// play discarded.
///
/// Best-effort only: a failure here must never affect playback. That constrains how failures
/// are handled; it is not permission to ignore them — opening a session is retried.
///
/// The Kotlin entry points were fire-and-forget; these are `async` but return as soon as state
/// has changed, with network work in child tasks, so callers keep ordering (a track change is
/// seen before the next track's `onPlaying`).
public actor PlaybackHistoryTracker {
    private let session: URLSession
    private let auth: StreamAuthProvider
    private let signatureTimestamp: @Sendable () async -> Int?
    private let anonymousVisitorData: @Sendable () async -> String?
    private let isNetworkAvailable: @Sendable () -> Bool
    private let language: @Sendable () -> String
    private let openRetryDelay: TimeInterval
    private let now: @Sendable () -> Date

    /// Report watched time once this much new audio has gone by.
    static let reportIntervalSeconds = 30
    /// Attempts at opening a session before the play is written off. A track starting is the
    /// worst moment to require a round trip to succeed first time.
    static let openAttempts = 3
    static let musicOrigin = "https://music.youtube.com"
    /// Only a starting point until the signed-in shell's live version is known.
    static let fallbackWebRemixVersion = "1.20260922.09.00"
    static let webRemixClientId = "67"

    private final class Session {
        let videoId: String
        let cpn: String
        let tracking: PlaybackTrackingURLs
        var reportedSeconds = 0
        /// Set before the network call, so a slow flush can't stack up behind itself.
        var flushingTo = 0
        var atrSent = false

        init(videoId: String, cpn: String, tracking: PlaybackTrackingURLs) {
            self.videoId = videoId
            self.cpn = cpn
            self.tracking = tracking
        }
    }

    private var current: Session?
    /// The track a session is being opened for, so repeat calls don't stack up.
    private var opening: String?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let gate = SerialGate()
    private var subscribers: [UUID: AsyncStream<Int>.Continuation] = [:]

    /// Bumped each time a play lands in the account's history. The home feed's lead shelf is
    /// built from that history, so it has gone stale whenever this moves.
    public private(set) var registeredPlays = 0

    /// - Parameters:
    ///   - signatureTimestamp: the current player's (`StreamResolver.signatureTimestamp`). The
    ///     tracking request is not answered without a current one.
    ///   - visitorData: the anonymous visitor id, used when the session carries none of its own.
    ///   - isNetworkAvailable: false skips a play outright rather than spending retries offline
    ///     (Android: `AppSettings.meteredConnection == null`).
    public init(
        session: URLSession = VibraMusicHTTP.session,
        auth: StreamAuthProvider,
        signatureTimestamp: @escaping @Sendable () async -> Int?,
        visitorData: @escaping @Sendable () async -> String? = { nil },
        isNetworkAvailable: @escaping @Sendable () -> Bool = { true },
        language: @escaping @Sendable () -> String = { "en" },
        openRetryDelay: TimeInterval = 2,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.auth = auth
        self.signatureTimestamp = signatureTimestamp
        anonymousVisitorData = visitorData
        self.isNetworkAvailable = isNetworkAvailable
        self.language = language
        self.openRetryDelay = openRetryDelay
        self.now = now
    }

    /// Every change of `registeredPlays`, for as long as the stream is iterated.
    public func registeredPlayUpdates() -> AsyncStream<Int> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Int>.makeStream()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        return stream
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    /// Call when `videoId` becomes audible — on play/resume and when the queue moves on. A
    /// no-op while the same track is already being tracked, so a pause/resume does not register
    /// a second play.
    public func onPlaying(_ videoId: String) async {
        guard YouTubeVideoId.isValid(videoId) else { return }
        // A downloaded track plays perfectly well with the radio off; nothing here is urgent
        // enough to wait for connectivity, so an offline play is skipped outright.
        guard isNetworkAvailable() else { return }
        guard await auth.streamAuthSession() != nil else { return }
        if current?.videoId == videoId || opening == videoId { return }
        opening = videoId
        spawn {
            await self.openWithRetries(videoId)
            await self.finishOpening(videoId)
        }
    }

    /// Call when the queue moves to a different track. The previous session's watched time is
    /// flushed before it is dropped, so a track skipped at two minutes is reported as two minutes.
    public func onTrackChanged(positionSeconds: Int) async {
        guard let closing = current else { return }
        current = nil
        spawn { await self.flush(closing, positionSeconds: positionSeconds, final: true) }
    }

    /// Periodic progress for the current track, in seconds played. Cheap to call often — it only
    /// hits the network every `reportIntervalSeconds` of new audio.
    public func onProgress(videoId: String, positionSeconds: Int) async {
        guard let session = current, session.videoId == videoId else { return }
        if !session.atrSent && positionSeconds >= session.tracking.atrAfterSeconds {
            session.atrSent = true
            if let atr = session.tracking.atrURL {
                spawn { await self.pingAtr(atr, cpn: session.cpn, videoId: videoId) }
            }
        }
        // Against `flushingTo`, not `reportedSeconds`: a ping can take longer than the sampling
        // interval, and gating on a value written only after the request returned fired the same
        // report several times over.
        guard positionSeconds - max(session.reportedSeconds, session.flushingTo) >= Self.reportIntervalSeconds else { return }
        // Claimed here, before the child task even starts, so a burst of progress calls cannot
        // each see the old value.
        session.flushingTo = max(session.flushingTo, positionSeconds)
        spawn { await self.flush(session, positionSeconds: positionSeconds, final: false) }
    }

    /// Close out the current play for good — the queue running dry, or playback going away.
    /// Neither fires a track transition, so without this a session that ended by finishing its
    /// last song reported everything except the part that says it finished.
    public func onPlaybackFinished(positionSeconds: Int) async {
        // A session still opening has nothing to close yet, but it must not install itself (or
        // register the play) after the queue is gone: nothing would ever close it.
        opening = nil
        guard let closing = current else { return }
        current = nil
        spawn { await self.flush(closing, positionSeconds: positionSeconds, final: true) }
    }

    /// Waits until every ping started so far has finished. For tests and orderly shutdown.
    func waitUntilIdle() async {
        while let entry = tasks.first {
            await entry.value.value
        }
    }

    // MARK: - Internals

    private func spawn(_ work: @escaping @Sendable () async -> Void) {
        let id = UUID()
        let task = Task {
            await work()
            self.taskFinished(id)
        }
        tasks[id] = task
    }

    private func taskFinished(_ id: UUID) { tasks[id] = nil }

    private func finishOpening(_ videoId: String) {
        if opening == videoId { opening = nil }
    }

    /// `open`, given more than one chance. Stops early on the answers that will not change:
    /// another track having become current, the session having opened, and YouTube declining
    /// to issue a tracking block at all. Only genuine failures are repeated.
    private func openWithRetries(_ videoId: String) async {
        for attempt in 0..<Self.openAttempts {
            if opening != videoId || Task.isCancelled { return }
            let settled: Bool
            do {
                settled = try await open(videoId)
            } catch is CancellationError {
                // Not a failure, and not ours to swallow: stop retrying and end promptly,
                // as Android's `openWithRetries` rethrowing `CancellationException` did.
                return
            } catch {
                streamLog.warning("history registration failed for \(videoId, privacy: .public) (attempt \(attempt + 1)/\(Self.openAttempts)): \(error.localizedDescription, privacy: .public)")
                settled = false
            }
            if settled { return }
            if attempt < Self.openAttempts - 1 {
                try? await Task.sleep(nanoseconds: UInt64(openRetryDelay * 1_000_000_000))
            }
        }
    }

    /// - Returns: whether there is anything left to try. False means worth repeating.
    private func open(_ videoId: String) async throws -> Bool {
        try await gate.run {
            guard let sts = await self.signatureTimestamp() else {
                streamLog.warning("no signature timestamp yet; retrying history for \(videoId, privacy: .public)")
                return false
            }
            guard let auth = await self.auth.streamAuthSession() else { return true }
            let visitor = await self.visitorData(for: auth)
            guard let tracking = try await self.fetchTracking(videoId: videoId, signatureTimestamp: sts, auth: auth, visitorData: visitor) else {
                // A verdict, not a failure — asking again with the same timestamp gets the same answer.
                streamLog.debug("no playback tracking for \(videoId, privacy: .public) (the player declined)")
                return true
            }
            guard await self.opening == videoId else { return true }
            let fresh = Session(videoId: videoId, cpn: InnerTubeStreamExtractor.newCpn(), tracking: tracking)
            let status = try await self.pingStats(tracking.playbackURL, cpn: fresh.cpn, auth: auth, visitorData: visitor, extras: [])
            await self.install(fresh)
            streamLog.debug("history entry created for \(videoId, privacy: .public) (HTTP \(status))")
            return true
        }
    }

    private func install(_ session: Session) {
        guard opening == session.videoId else { return }
        current = session
        registeredPlays += 1
        for continuation in subscribers.values { continuation.yield(registeredPlays) }
    }

    private func flush(_ target: Session, positionSeconds: Int, final: Bool) async {
        guard let url = target.tracking.watchtimeURL else { return }
        // A final report is worth sending even at a position already covered: it is the
        // `final=1` that matters, not the number.
        if !final && positionSeconds <= target.reportedSeconds { return }
        target.flushingTo = max(target.flushingTo, positionSeconds)
        do {
            try await gate.run {
                guard let auth = await self.auth.streamAuthSession() else { return }
                let visitor = await self.visitorData(for: auth)
                var extras = [
                    URLQueryItem(name: "st", value: "0"),
                    URLQueryItem(name: "et", value: String(positionSeconds)),
                    // Where the playhead is, as distinct from how much was watched: `et` bounds a
                    // segment, `cmt` is a position.
                    URLQueryItem(name: "cmt", value: String(positionSeconds)),
                    URLQueryItem(name: "state", value: final ? "paused" : "playing"),
                ]
                if final { extras.append(URLQueryItem(name: "final", value: "1")) }
                let status = try await self.pingStats(url, cpn: target.cpn, auth: auth, visitorData: visitor, extras: extras)
                await self.markReported(target, positionSeconds)
                streamLog.debug("watchtime \(positionSeconds)s reported for \(target.videoId, privacy: .public)\(final ? " (final)" : "", privacy: .public) (HTTP \(status))")
            }
        } catch {
            streamLog.warning("watchtime ping failed for \(target.videoId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func markReported(_ target: Session, _ seconds: Int) {
        target.reportedSeconds = max(target.reportedSeconds, seconds)
    }

    private func pingAtr(_ url: URL, cpn: String, videoId: String) async {
        do {
            guard let auth = await auth.streamAuthSession() else { return }
            let visitor = await visitorData(for: auth)
            // Its base URL already carries `ver`, `c` and `cver`, so unlike the others it is sent as-is.
            var request = URLRequest(url: Self.appending([URLQueryItem(name: "cpn", value: cpn)], to: url))
            statsHeaders(&request, auth: auth, visitorData: visitor)
            _ = try await session.data(for: request)
        } catch {
            streamLog.warning("atr ping failed for \(videoId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func visitorData(for auth: StreamAuthSession) async -> String? {
        if let own = auth.visitorData, !own.isEmpty { return own }
        return await anonymousVisitorData()
    }

    /// The player response fetched *with* the session, purely to read back `playbackTracking`.
    ///
    /// `signatureTimestamp` is not optional in practice: without a current one Google answers
    /// HTTP 200, `UNPLAYABLE`, "The page needs to be reloaded", and simply omits the tracking
    /// block — so no ping is ever sent and nothing fails loudly enough to notice.
    func fetchTracking(
        videoId: String, signatureTimestamp: Int, auth: StreamAuthSession, visitorData: String?
    ) async throws -> PlaybackTrackingURLs? {
        let request = try Self.trackingRequest(
            videoId: videoId, signatureTimestamp: signatureTimestamp, auth: auth, visitorData: visitorData,
            language: language(), now: now()
        )
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw StreamResolutionError.noPlayableStream(detail: "tracking request HTTP \(status)")
        }
        let decoded = try PlayerResponse.decode(data)
        guard let tracking = PlaybackTrackingURLs(decoded.playbackTracking) else {
            let playability = decoded.playabilityStatus
            streamLog.warning("player response has no playbackTracking for \(videoId, privacy: .public) (status=\(playability?.status ?? "-", privacy: .public), reason=\(playability?.explanation ?? "-", privacy: .public), sts=\(signatureTimestamp))")
            return nil
        }
        return tracking
    }

    static func trackingRequest(
        videoId: String, signatureTimestamp: Int, auth: StreamAuthSession, visitorData: String?,
        language: String, now: Date
    ) throws -> URLRequest {
        let version = auth.webRemixClientVersion ?? fallbackWebRemixVersion
        var client: [String: Any] = ["clientName": "WEB_REMIX", "clientVersion": version, "hl": language, "gl": "US"]
        if let visitorData { client["visitorData"] = visitorData }
        var user: [String: Any] = ["lockedSafetyMode": false]
        // Only ever a value from a signed-in shell: Google answers one it cannot tie to the
        // cookie with 401.
        if let dataSyncId = auth.dataSyncId, !dataSyncId.isEmpty { user["onBehalfOfUser"] = dataSyncId }
        let body: [String: Any] = [
            "context": ["client": client, "user": user, "request": ["useSsl": true]] as [String: Any],
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
            // Real clients always describe where playback is happening; the tracking block is
            // scoped to it.
            "playbackContext": [
                "contentPlaybackContext": [
                    "html5Preference": "HTML5_PREF_WANTS",
                    "referer": "\(musicOrigin)/watch?v=\(videoId)",
                    "signatureTimestamp": signatureTimestamp,
                ] as [String: Any],
            ],
        ]
        var components = URLComponents(string: "\(musicOrigin)/youtubei/v1/player")!
        components.queryItems = [URLQueryItem(name: "prettyPrint", value: "false"), URLQueryItem(name: "hl", value: language)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(language == "en" ? "en-US,en;q=0.9" : "\(language),en-US;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        request.setValue(musicOrigin, forHTTPHeaderField: "X-Origin")
        request.setValue(musicOrigin, forHTTPHeaderField: "Origin")
        request.setValue("\(musicOrigin)/", forHTTPHeaderField: "Referer")
        request.setValue(StreamPlayerClient.webUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(webRemixClientId, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(version, forHTTPHeaderField: "X-YouTube-Client-Version")
        if let visitorData { request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        for (name, value) in auth.headers(origin: musicOrigin, now: now) { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    /// Shared shape of the s.youtube.com stats pings. No `el`: the base URL already carries
    /// `el=detailpage`, and a repeated parameter is an ambiguous request, not a stronger one.
    private func pingStats(
        _ baseURL: URL, cpn: String, auth: StreamAuthSession, visitorData: String?, extras: [URLQueryItem]
    ) async throws -> Int {
        let request = Self.statsRequest(
            baseURL, cpn: cpn, auth: auth, visitorData: visitorData, extras: extras, now: now()
        )
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    static func statsRequest(
        _ baseURL: URL, cpn: String, auth: StreamAuthSession, visitorData: String?, extras: [URLQueryItem], now: Date
    ) -> URLRequest {
        let version = auth.webRemixClientVersion ?? fallbackWebRemixVersion
        // What the web client says about itself; the pings are weighted by how much they look
        // like a real session.
        let items = [
            URLQueryItem(name: "ver", value: "2"),
            URLQueryItem(name: "c", value: "WEB_REMIX"),
            URLQueryItem(name: "cver", value: version),
            URLQueryItem(name: "cpn", value: cpn),
            URLQueryItem(name: "cplayer", value: "UNIPLAYER"),
            URLQueryItem(name: "cbr", value: "Chrome"),
            URLQueryItem(name: "cbrver", value: "141.0.0.0"),
            URLQueryItem(name: "cos", value: "Windows"),
            URLQueryItem(name: "cosver", value: "10.0"),
            URLQueryItem(name: "hl", value: "en_US"),
            URLQueryItem(name: "cr", value: "US"),
        ] + extras
        var request = URLRequest(url: appending(items, to: baseURL))
        request.timeoutInterval = 15
        statsHeaders(&request, auth: auth, visitorData: visitorData, now: now)
        return request
    }

    /// The three headers the tracking block asks for by name — USER_AUTH, VISITOR_ID and
    /// PLUS_PAGE_ID. Sending fewer is what makes a ping land somewhere other than the
    /// listener's own history.
    private func statsHeaders(_ request: inout URLRequest, auth: StreamAuthSession, visitorData: String?) {
        Self.statsHeaders(&request, auth: auth, visitorData: visitorData, now: now())
    }

    static func statsHeaders(_ request: inout URLRequest, auth: StreamAuthSession, visitorData: String?, now: Date) {
        request.setValue(musicOrigin, forHTTPHeaderField: "X-Origin")
        request.setValue(musicOrigin, forHTTPHeaderField: "Origin")
        request.setValue("\(musicOrigin)/", forHTTPHeaderField: "Referer")
        request.setValue(StreamPlayerClient.webUserAgent, forHTTPHeaderField: "User-Agent")
        if let visitorData { request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        for (name, value) in auth.headers(origin: musicOrigin, now: now) { request.setValue(value, forHTTPHeaderField: name) }
    }

    /// `url` with `items` appended (kept even when a name repeats, as the Kotlin's `parameter()` did).
    static func appending(_ items: [URLQueryItem], to url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var existing = components.percentEncodedQueryItems ?? []
        for item in items {
            let value = item.value?.addingPercentEncoding(withAllowedCharacters: .streamQueryValueAllowed)
            existing.append(URLQueryItem(name: item.name, value: value))
        }
        components.percentEncodedQueryItems = existing
        return components.url ?? url
    }
}

/// A FIFO async lock: one body at a time, in arrival order. Android's `Mutex` around session
/// hand-over and pings; an actor alone would interleave them at every `await`.
///
/// Waiting is cancellable (Android's `Mutex.withLock` is too): a task cancelled while queued
/// is dequeued and throws `CancellationError` instead of leaking a waiter that `run` and
/// `waitUntilIdle` hang on.
final class SerialGate: @unchecked Sendable {
    private final class Ticket {
        var continuation: CheckedContinuation<Void, Error>?
        var granted = false
        var cancelled = false
    }

    private let lock = NSLock()
    private var busy = false
    private var waiters: [Ticket] = []

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async throws {
        let ticket = Ticket()
        let immediate: Bool = lock.withLock {
            if busy {
                waiters.append(ticket)
                return false
            }
            busy = true
            return true
        }
        guard !immediate else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // `release` may have dequeued this ticket between the enqueue above and now
                // (`granted`), and `onCancel` may already have fired (`cancelled`, when the
                // task was cancelled before it parked — the handler runs once and never again).
                // Either way the grant is already decided and the continuation resumes at once.
                enum Decision { case resume, resumeThrowing, park }
                let decision: Decision = lock.withLock {
                    if ticket.cancelled { return .resumeThrowing }
                    if ticket.granted { return .resume }
                    ticket.continuation = continuation
                    return .park
                }
                switch decision {
                case .resume: continuation.resume()
                case .resumeThrowing: continuation.resume(throwing: CancellationError())
                case .park: break
                }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
                // Already granted: `release` owns the resume. Already cancelled: the parker
                // resumes itself. Otherwise dequeue so nobody ever resumes it, and resume
                // here with cancellation.
                if ticket.granted || ticket.cancelled { return nil }
                ticket.cancelled = true
                waiters.removeAll { $0 === ticket }
                let pending = ticket.continuation
                ticket.continuation = nil
                return pending
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    private func release() {
        let next: CheckedContinuation<Void, Error>? = lock.withLock {
            while !waiters.isEmpty {
                let ticket = waiters.removeFirst()
                ticket.granted = true
                // Not yet parked in its continuation: `acquire` resumes it from the grant.
                guard let continuation = ticket.continuation else { return nil }
                ticket.continuation = nil
                return continuation
            }
            busy = false
            return nil
        }
        next?.resume()
    }
}
