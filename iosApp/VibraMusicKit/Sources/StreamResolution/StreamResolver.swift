import VibraMusicCore
import Foundation

/// Turns a YouTube videoId into a URL AVPlayer can actually stream. Port of `StreamResolver.kt`.
///
///  1. **The client catalog.** Each `StreamClientProfile` is asked in order — direct-URL clients
///     first, then the cipher tier (web identities whose formats need the player script) — and
///     the first usable answer wins. See `InnerTubeStreamExtractor`.
///  2. **Whether the URL is real.** A URL can be dead on arrival for reasons no amount of care
///     predicts, so nothing is handed to the player, or cached, until bytes have been fetched
///     from it. See `StreamURLProbe`.
///
/// iOS differences from Android, all forced by AVPlayer: playback only ever picks AAC-in-MP4
/// (itag 140, 139 under a low ceiling), never Opus/WebM; and the stream comes back with its
/// media headers attached, because `AVURLAsset` takes them at creation.
public actor StreamResolver {
    public struct Configuration: Sendable {
        /// The walk, in order.
        public var catalog: [StreamClientProfile] = StreamClientProfile.defaultCatalog
        /// The playback ceiling in force right now, read at the start of each resolve
        /// (Android: `AppSettings.effectiveAudioQuality.maxKbps`).
        public var playbackCeilingKbps: @Sendable () -> Int = { Int.max }
        /// `hl` for requests (Android: `Innertube.currentLanguage`).
        public var language: @Sendable () -> String = { "en" }
        /// How long a probed URL is reused. Google issues them with hours of validity, but a URL
        /// is tied to the playback session that minted it, and holding one indefinitely lets a
        /// stale entry survive long enough to fail a play. Twenty minutes covers a track and the
        /// seeking around it.
        public var urlTTL: TimeInterval = 20 * 60
        /// How long a permanent verdict is remembered. Long enough that a retry storm cannot
        /// re-form, short enough that a listener who fixes the cause does not have to relaunch.
        public var unplayableTTL: TimeInterval = 10 * 60
        /// A URL this close to its `expire` is not handed out again.
        public var expiryMargin: TimeInterval = 5 * 60
        public var probeTimeout: TimeInterval = 6
        public init() {}
    }

    private let configuration: Configuration
    private let extractor: InnerTubeStreamExtractor
    private let probe: StreamURLProbe
    private let cipher: StreamCipherSolver?
    private let poTokens: StreamPoTokenProvider?
    private let visitorData: StreamVisitorDataStore
    private let auth: StreamAuthProvider?
    private let now: @Sendable () -> Date

    private struct Remembered {
        let stream: ResolvedYouTubeStream
        let at: Date
    }

    private struct Verdict {
        let reason: String
        let at: Date
    }

    /// Stream URLs already resolved, by videoId — and, since only probed URLs are stored,
    /// already known good rather than merely recent.
    private var recent: [String: Remembered] = [:]
    /// Tracks that failed for a reason retrying cannot fix, and since when. This is what turns a
    /// track stuck in BUFFERING while every retry layer re-walks the catalog back into a failure
    /// that happens once.
    private var unplayable: [String: Verdict] = [:]
    /// One walk per videoId at a time.
    private var inFlight: [String: SharedWalk<ResolvedYouTubeStream>] = [:]

    /// Enough for the queue in hand; this is a latency cache, not a store.
    static let maxRemembered = 32

    /// - Parameters:
    ///   - session: every request (player, probe, cipher, visitor id) goes through it.
    ///   - visitorData: share one store with the InnerTube module if it has one; default is private.
    ///   - cipher: the cipher tier; nil drops the web identities from the walk.
    ///   - poTokens: BotGuard tokens for web identities; nil walks them without tokens.
    ///   - auth: the signed-in session for identities that accept one.
    public init(
        session: URLSession = VibraMusicHTTP.session,
        configuration: Configuration = Configuration(),
        visitorData: StreamVisitorDataStore? = nil,
        cipher: StreamCipherSolver? = nil,
        poTokens: StreamPoTokenProvider? = nil,
        auth: StreamAuthProvider? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let visitorStore = visitorData ?? StreamVisitorDataStore(session: session, now: now)
        self.configuration = configuration
        self.cipher = cipher
        self.poTokens = poTokens
        self.visitorData = visitorStore
        self.auth = auth
        self.now = now
        probe = StreamURLProbe(session: session, timeout: configuration.probeTimeout)
        extractor = InnerTubeStreamExtractor(
            session: session, catalog: configuration.catalog, visitorData: visitorStore, cipher: cipher,
            poTokens: poTokens, auth: auth, language: configuration.language, now: now
        )
    }

    /// The usual wiring: a private visitor-id store, the cipher tier with its on-disk player
    /// cache, and the given PoToken provider and auth.
    public static func standard(
        session: URLSession = VibraMusicHTTP.session,
        configuration: Configuration = Configuration(),
        defaults: UserDefaults? = .standard,
        poTokens: StreamPoTokenProvider? = nil,
        auth: StreamAuthProvider? = nil
    ) -> StreamResolver {
        let visitorData = StreamVisitorDataStore(session: session, defaults: defaults)
        let cipher = StreamCipherSolver(
            session: session, defaults: defaults, fallbackHash: { await visitorData.musicShell()?.playerHash }
        )
        return StreamResolver(
            session: session, configuration: configuration, visitorData: visitorData, cipher: cipher,
            poTokens: poTokens, auth: auth
        )
    }

    // MARK: - Playback

    /// A directly streamable URL that has been proven to serve bytes, or a thrown reason.
    ///
    /// Results are held briefly: resolving is the slow part of starting a track, and the player
    /// asks again for every re-open.
    public func resolve(_ videoId: String) async throws -> ResolvedYouTubeStream {
        guard YouTubeVideoId.isValid(videoId) else { throw StreamResolutionError.invalidVideoId(videoId) }
        if let cached = freshRemembered(videoId) { return cached }

        // A verdict, not a failure: asking again cannot change the answer, so every caller after
        // the first is told so without a request being sent.
        if let reason = unplayableReason(videoId) { throw StreamResolutionError.permanentlyUnplayable(reason: reason) }

        return try await coalescedResolve(videoId)
    }

    /// How many bytes the whole track is, or nil if neither the URL nor the format says. Read
    /// from the resolved URL's `clen`, falling back to the format's declared `contentLength`
    /// (the two agree in practice) rather than learned from a request that reaches the end of
    /// the resource: a bounded range never reveals the total. Resolving is memoised, so asking
    /// costs nothing after the first time.
    public func contentLength(for videoId: String) async throws -> Int64? {
        try await resolve(videoId).contentLength
    }

    /// The headers a media fetch for `url` must carry to match whoever minted it.
    public func mediaHeaders(for url: URL) async -> [String: String] {
        if let minted = await extractor.headers(for: url) { return minted }
        if let cached = recent.values.first(where: { $0.stream.url == url }) { return cached.stream.mediaHeaders }
        return StreamPlayerClient.forStreamURL(url).mediaHeaders
    }

    /// Largest single range googlevideo reliably serves for `url`'s client.
    public nonisolated static func rangeBytes(for url: URL) -> Int64 { StreamPlayerClient.rangeBytes(for: url) }

    /// A URL the probe cleared has been refused while actually playing.
    ///
    /// The probe runs before playback and not again, so without this the cache would hand back
    /// the same dead URL for the rest of its lifetime. So the refusal is fed back: forget the
    /// URL, and bench the client that minted it for this track.
    public func onPlaybackRefused(url: URL, statusCode: Int) async {
        guard StreamURLProbe.refusalCodes.contains(statusCode) else { return }
        // Only googlevideo's URLs say anything about the client that minted them. Another
        // server's 404 is that server's business and must not bench a YouTube client.
        guard url.isGoogleVideo else { return }
        let videoId: String?
        if let minted = await extractor.onRefused(url) {
            videoId = minted
        } else {
            videoId = recent.first(where: { $0.value.stream.url == url })?.key
        }
        guard let videoId else { return }
        recent[videoId] = nil
    }

    /// Signing in is the one event that can turn an age-gated track playable, and signing out
    /// the one that can turn it back — so both clear every verdict, and clients refused while
    /// anonymous get a fresh hearing. The visitor id goes too, as Android's did with the cookie:
    /// it belonged to the session that just left.
    public func onSessionChanged() async {
        await extractor.onSessionChanged()
        await visitorData.invalidate()
        unplayable.removeAll()
    }

    /// Pays the cold costs before a track needs them: the visitor id, the player script and its
    /// evaluation, and (when a provider is set) BotGuard. Measured on Android, paying them on the
    /// play path put a cold track 15–20 s from first audio. Best-effort; failures are logged.
    public func prewarm() async {
        let started = now()
        let visitor = await visitorData.visitorData()
        await cipher?.prewarm()
        if let poTokens, let visitor { await poTokens.prewarm(visitorData: visitor) }
        let ms = Int(now().timeIntervalSince(started) * 1000)
        streamLog.debug("stream resolution warmed in \(ms)ms")
    }

    /// The current player's `signatureTimestamp` (for `PlaybackHistoryTracker`), or nil.
    public func signatureTimestamp() async -> Int? { await cipher?.signatureTimestamp() }

    // MARK: - Download

    /// As `resolve`, but for a file being kept rather than a stream being heard: the best
    /// format the *download* setting allows, and no connection has a say.
    ///
    /// `requireM4a` defaults to true on iOS (Android defaulted to false and kept Opus-in-WebM
    /// for app-private downloads): AVPlayer cannot play a WebM file, so a WebM download is only
    /// worth asking for when the caller has its own Opus decoder.
    ///
    /// There is no "best available" fallback to the other container: a walk that takes another
    /// container can no longer fulfil the destination already chosen. Nothing here touches the
    /// playback cache — its entries are picked under the *playback* ceiling.
    ///
    /// - Parameter maxKbps: the ceiling from the download quality setting, passed in so one
    ///   download resolves at one bitrate even if the setting changes mid-fetch.
    public func resolveForDownload(
        _ videoId: String, maxKbps: Int, requireM4a: Bool = true
    ) async throws -> ResolvedYouTubeStream {
        guard YouTubeVideoId.isValid(videoId) else { throw StreamResolutionError.invalidVideoId(videoId) }
        let selection = StreamSelection.download(maxKbps: maxKbps, requireM4a: requireM4a)
        var skip: Set<String> = []
        // Whether any client offered the container at all, as distinct from whether one could be
        // turned into a working URL. Only the second is worth "try again".
        var offered = false
        for _ in 0..<max(1, configuration.catalog.count) {
            switch await extractor.extract(videoId: videoId, selection: selection, skip: skip) {
            case .found(let found):
                offered = true
                let verdict = await probe.probe(found.url, headers: found.headers)
                if verdict == .ok {
                    await extractor.noteProbe(profileId: found.profileId, ok: true)
                    let stream = found.resolved
                    let allowed: Set<String> = requireM4a ? ["m4a"] : ["m4a", "webm"]
                    guard allowed.contains(stream.downloadExtension) else {
                        throw StreamResolutionError.downloadUnavailable(message: "Can't save \(stream.mimeType) — try again")
                    }
                    return stream
                }
                if verdict == .refused { await extractor.noteProbe(profileId: found.profileId, ok: false) }
                skip.insert(found.profileId)
            case .exhausted(_, let anyOffered, let detail):
                if anyOffered { offered = true }
                streamLog.warning("no downloadable copy of \(videoId, privacy: .public): \(detail, privacy: .public)")
                return try downloadFailure(offered: offered)
            }
        }
        return try downloadFailure(offered: offered)
    }

    private func downloadFailure(offered: Bool) throws -> ResolvedYouTubeStream {
        if offered { throw StreamResolutionError.downloadUnavailable(message: "Couldn't reach a downloadable copy just now — try again") }
        throw StreamResolutionError.downloadUnavailable(message: "No downloadable audio for this track")
    }

    // MARK: - Walk

    private func coalescedResolve(_ videoId: String) async throws -> ResolvedYouTubeStream {
        if let running = inFlight[videoId] { return try await running.value() }
        let walk = SharedWalk<ResolvedYouTubeStream>()
        inFlight[videoId] = walk
        // Unstructured, so a caller giving up cancels only its own wait, never the walk another
        // caller may still be waiting on. Unregistered by the walk's own completion rather than
        // by an awaiter, which is the difference between coalescing and only appearing to.
        Task {
            let result: Result<ResolvedYouTubeStream, Error>
            do {
                let stream = try await self.resolveUncached(videoId)
                // Remembered by the walk itself, before it stops being in flight, so no caller
                // can slip between the two and start a second walk — and a result nobody is
                // waiting for any more (read-ahead the queue moved past) still warms the cache.
                self.remember(stream)
                result = .success(stream)
            } catch {
                result = .failure(error)
            }
            self.finishWalk(videoId, walk: walk)
            walk.fulfil(result)
        }
        return try await walk.value()
    }

    private func finishWalk(_ videoId: String, walk: SharedWalk<ResolvedYouTubeStream>) {
        if inFlight[videoId] === walk { inFlight[videoId] = nil }
    }

    static let logCategory = "StreamResolution"

    /// How long the embedded player's fresh URLs are waited out: up to 5 × 1.5 s.
    static let embeddedWarmUpRetries = 5
    static let embeddedWarmUpInterval: TimeInterval = 1.5

    private func resolveUncached(_ videoId: String) async throws -> ResolvedYouTubeStream {
        let started = now()
        let selection = StreamSelection.playback(maxKbps: configuration.playbackCeilingKbps())
        var skip: Set<String> = []
        // A stream was offered at some point in this walk; a later "permanent" answer from
        // another client then describes that client, not the track.
        var sawStream = false
        // The embedded player's URL, refused at first: waited out only if no other client can play
        // the track (see `waitOut`).
        var warmingUp: ExtractedStream?
        for _ in 0..<max(1, configuration.catalog.count) {
            switch await extractor.extract(videoId: videoId, selection: selection, skip: skip) {
            case .found(let found):
                sawStream = true
                let verdict = await probe.probe(found.url, headers: found.headers)
                // The embedded player's URLs answer 403 for the first few seconds after they are
                // minted, then serve the whole file (measured 2026-09-26: 403 at +2 s and +4 s, 206
                // from +6 s). Rather than sleep through that on the play path, the walk asks the
                // next client; this URL is waited out only if none of them can play the track, by
                // which time its seconds are partly spent.
                if verdict == .refused, found.profileId == StreamClientProfile.webEmbedded.id, warmingUp == nil {
                    TrackLog.d(Self.logCategory, "\(found.profileId)'s URL refused at first; asking the other clients while it warms up",
                               about: videoId)
                    warmingUp = found
                    // Not counted toward its bench: a URL still warming up isn't a broken client, and
                    // a benched embedded player is then missing on the track nothing else can play.
                    // It is counted only when `waitOut` gives up on it.
                    skip.insert(found.profileId)
                    continue
                }
                let ms = Int(now().timeIntervalSince(started) * 1000)
                if verdict == .ok {
                    await extractor.noteProbe(profileId: found.profileId, ok: true)
                    streamLog.debug("resolved \(videoId, privacy: .public) via \(found.profileId, privacy: .public) itag \(found.itag) @ \(found.kbps)kbps in \(ms)ms")
                    TrackLog.d(Self.logCategory, "YouTube: \(found.profileId) itag \(found.itag) @ \(found.kbps) kbps, probed, in \(ms)ms", about: videoId)
                    return found.resolved
                }
                streamLog.warning("\(found.profileId, privacy: .public) minted an unusable URL for \(videoId, privacy: .public): \(String(describing: verdict), privacy: .public)")
                TrackLog.w(Self.logCategory, "YouTube: \(found.profileId)'s URL failed its probe (\(verdict)) at \(ms)ms; next client", about: videoId)
                // An unreachable probe (timeout, dropped connection) says nothing about the client.
                if verdict == .refused { await extractor.noteProbe(profileId: found.profileId, ok: false) }
                skip.insert(found.profileId)
            case .exhausted(let permanent, _, let detail):
                if let warmingUp, let stream = await waitOut(warmingUp, videoId: videoId, started: started) { return stream }
                if let permanent, !sawStream {
                    let signedIn = await auth?.streamAuthSession() != nil
                    let reason = permanent.message(signedIn: signedIn)
                    rememberUnplayable(videoId, reason: reason)
                    streamLog.warning("\(videoId, privacy: .public) is not playable: \(reason, privacy: .public); not asking again for \(Int(self.configuration.unplayableTTL / 60)) minutes")
                    throw StreamResolutionError.permanentlyUnplayable(reason: reason)
                }
                streamLog.warning("resolve failed for \(videoId, privacy: .public): \(detail, privacy: .public)")
                TrackLog.w(Self.logCategory, "YouTube: no client could play it (\(Int(now().timeIntervalSince(started) * 1000))ms): \(detail)",
                           about: videoId)
                throw StreamResolutionError.noPlayableStream(detail: detail)
            }
        }
        if let warmingUp, let stream = await waitOut(warmingUp, videoId: videoId, started: started) { return stream }
        throw StreamResolutionError.noPlayableStream(detail: "every client's URL was refused")
    }

    /// The embedded player's URL asked again until it serves: now, then up to
    /// ``embeddedWarmUpRetries`` more times ``embeddedWarmUpInterval`` apart. Nil if it never does.
    private func waitOut(_ found: ExtractedStream, videoId: String, started: Date) async -> ResolvedYouTubeStream? {
        TrackLog.d(Self.logCategory, "no other client could play it; waiting out \(found.profileId)'s URL (up to "
            + "\(Self.embeddedWarmUpRetries) × \(Self.embeddedWarmUpInterval) s)", about: videoId)
        for attempt in 0...Self.embeddedWarmUpRetries {
            if attempt > 0 { try? await Task.sleep(for: .seconds(Self.embeddedWarmUpInterval)) }
            let verdict = await probe.probe(found.url, headers: found.headers)
            // Only a refusal is the warm-up; anything else is the network, and waiting won't help.
            guard verdict == .ok else {
                if verdict == .refused { continue } else { return nil }
            }
            await extractor.noteProbe(profileId: found.profileId, ok: true)
            let ms = Int(now().timeIntervalSince(started) * 1000)
            streamLog.debug("resolved \(videoId, privacy: .public) via \(found.profileId, privacy: .public) after its warm-up, in \(ms)ms")
            TrackLog.d(Self.logCategory, "YouTube: \(found.profileId) itag \(found.itag) @ \(found.kbps) kbps, probed, in \(ms)ms", about: videoId)
            return found.resolved
        }
        // Refused through every retry; a network failure returned above without a strike.
        await extractor.noteProbe(profileId: found.profileId, ok: false)
        return nil
    }

    // MARK: - Memory

    private func freshRemembered(_ videoId: String) -> ResolvedYouTubeStream? {
        guard let entry = recent[videoId] else { return nil }
        let current = now()
        let withinTTL = current.timeIntervalSince(entry.at) < configuration.urlTTL
        let beforeExpiry = entry.stream.expiresAt.map { current.addingTimeInterval(configuration.expiryMargin) < $0 } ?? true
        if withinTTL && beforeExpiry { return entry.stream }
        recent[videoId] = nil
        return nil
    }

    private func remember(_ stream: ResolvedYouTubeStream) {
        if recent.count >= Self.maxRemembered {
            let cutoff = now().addingTimeInterval(-configuration.urlTTL)
            recent = recent.filter { $0.value.at >= cutoff }
            if recent.count >= Self.maxRemembered { recent.removeAll() }
        }
        recent[stream.videoId] = Remembered(stream: stream, at: now())
    }

    private func unplayableReason(_ videoId: String) -> String? {
        guard let entry = unplayable[videoId] else { return nil }
        if now().timeIntervalSince(entry.at) < configuration.unplayableTTL { return entry.reason }
        unplayable[videoId] = nil
        return nil
    }

    private func rememberUnplayable(_ videoId: String, reason: String) {
        if unplayable.count > Self.maxRemembered { unplayable.removeAll() }
        unplayable[videoId] = Verdict(reason: reason, at: now())
    }
}
