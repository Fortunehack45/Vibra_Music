import VibraMusicCore
import Foundation

/// When a track becomes eligible for scrobbling (ports the timing rules in
/// `ScrobbleManager.kt`).
///
/// A track must be longer than `minDurationSeconds` (default 30 s); the
/// scrobble fires after half its duration or `maxDelaySeconds` (default
/// 4 minutes), whichever comes first. `delayPercent` / `maxDelaySeconds` map
/// to `AppSettings.scrobbleDelayPercent` / `scrobbleDelaySeconds`.
public enum ScrobbleTiming {
    public static let defaultMinDurationSeconds = 30
    public static let defaultDelayPercent: Double = 0.5
    public static let defaultMaxDelaySeconds = 180

    /// Milliseconds of playback after which to scrobble, or `nil` when the
    /// track must never scrobble (too short / unknown length).
    public static func delayMilliseconds(
        durationSeconds: Int?,
        minDurationSeconds: Int = defaultMinDurationSeconds,
        delayPercent: Double = defaultDelayPercent,
        maxDelaySeconds: Int = defaultMaxDelaySeconds
    ) -> Int? {
        guard let durationSeconds, durationSeconds > minDurationSeconds else { return nil }
        let thresholdMs = Int((Double(durationSeconds) * 1000.0 * delayPercent).rounded())
        return min(thresholdMs, maxDelaySeconds * 1000)
    }

    /// Parses an `"M:SS"` duration label to seconds (0 when unparseable).
    public static func parseDurationSeconds(_ text: String?) -> Int {
        guard let text else { return 0 }
        let parts = text.split(separator: ":")
        guard parts.count == 2,
              let minutes = Int(parts[0]),
              let seconds = Int(parts[1])
        else { return 0 }
        return minutes * 60 + seconds
    }

    /// Parses an `"M:SS"` duration label to milliseconds (0 when unparseable).
    public static func parseDurationMs(_ text: String?) -> Int64 {
        Int64(parseDurationSeconds(text)) * 1000
    }
}

/// Coordinates now-playing + scrobble submission for the current track (ports
/// `ScrobbleManager.kt`).
///
/// The Android manager posts `LastFM` calls from a `CoroutineScope` and pauses
/// the scrobble countdown while paused, resuming with the remaining time. This
/// actor keeps the same state machine — `noteStarted` / `noteResumed` /
/// `notePaused` / `noteStopped` / `notePlayingChanged` — but performs the
/// network work through injected `nowPlaying` / `scrobble` closures so tests
/// stay offline and the app can wire in `LastFMClient` plus `AppSettings`.
///
/// Pausing freezes the countdown by recording the remaining time; resuming
/// schedules a fresh sleep for that remainder. A zero-millisecond delay
/// scrobbles immediately, matching Kotlin's `scrobbleRemainingMillis <= 0`
/// path.
public actor ScrobbleTracker {
    public struct Configuration: Hashable, Sendable {
        public var minDurationSeconds: Int
        public var delayPercent: Double
        public var maxDelaySeconds: Int
        public var useNowPlaying: Bool
        public var usePrimaryArtistOnly: Bool

        public init(
            minDurationSeconds: Int = ScrobbleTiming.defaultMinDurationSeconds,
            delayPercent: Double = ScrobbleTiming.defaultDelayPercent,
            maxDelaySeconds: Int = ScrobbleTiming.defaultMaxDelaySeconds,
            useNowPlaying: Bool = true,
            usePrimaryArtistOnly: Bool = false
        ) {
            self.minDurationSeconds = minDurationSeconds
            self.delayPercent = delayPercent
            self.maxDelaySeconds = maxDelaySeconds
            self.useNowPlaying = useNowPlaying
            self.usePrimaryArtistOnly = usePrimaryArtistOnly
        }
    }

    public struct ScrobbleEvent: Hashable, Sendable {
        public var artist: String
        public var title: String
        public var album: String?
        public var durationSeconds: Int
        public var timestamp: Int64
        public init(artist: String, title: String, album: String?, durationSeconds: Int, timestamp: Int64) {
            self.artist = artist
            self.title = title
            self.album = album
            self.durationSeconds = durationSeconds
            self.timestamp = timestamp
        }
    }

    private var configuration: Configuration
    private let nowPlaying: @Sendable (ScrobbleEvent) async -> Void
    private let scrobble: @Sendable (ScrobbleEvent) async -> Void

    private var pendingTask: Task<Void, Never>?
    private var remainingMillis: Int64 = 0
    private var timerStartedAt: Date?
    private var trackStartedAt: Int64 = 0
    private var trackStarted = false
    private var pendingEvent: ScrobbleEvent?

    public init(
        configuration: Configuration = Configuration(),
        nowPlaying: @escaping @Sendable (ScrobbleEvent) async -> Void = { _ in },
        scrobble: @escaping @Sendable (ScrobbleEvent) async -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.nowPlaying = nowPlaying
        self.scrobble = scrobble
    }

    public func updateConfiguration(_ configuration: Configuration) {
        self.configuration = configuration
    }

    /// Remaining countdown in milliseconds (exposed for tests).
    public func remainingMilliseconds() -> Int64 { remainingMillis }

    public func noteStarted(song: Song, durationMs: Int64? = nil, at date: Date = Date()) {
        guard !song.title.isEmpty else { return }
        trackStartedAt = Int64(date.timeIntervalSince1970)
        trackStarted = true
        startTimer(song: song, durationMs: durationMs, at: date)
        if configuration.useNowPlaying {
            let event = event(for: song, durationSeconds: resolvedDurationSeconds(song: song, durationMs: durationMs))
            Task { await nowPlaying(event) }
        }
    }

    public func noteResumed(song: Song) {
        resumeTimer(song: song)
    }

    public func notePaused(at date: Date = Date()) {
        pauseTimer(at: date)
    }

    public func noteStopped() {
        stopTimer()
        trackStarted = false
    }

    public func notePlayingChanged(isPlaying: Bool, song: Song, durationMs: Int64? = nil, at date: Date = Date()) {
        if isPlaying {
            if !trackStarted {
                noteStarted(song: song, durationMs: durationMs, at: date)
            } else {
                noteResumed(song: song)
            }
        } else {
            notePaused(at: date)
        }
    }

    // MARK: - Internals

    private func artistForScrobble(_ credit: String) -> String {
        configuration.usePrimaryArtistOnly ? ArtistCredit.primary(of: credit) : credit
    }

    private func resolvedDurationSeconds(song: Song, durationMs: Int64?) -> Int {
        if let durationMs, durationMs > 0 { return Int(durationMs / 1000) }
        return ScrobbleTiming.parseDurationSeconds(song.durationText)
    }

    private func event(for song: Song, durationSeconds: Int) -> ScrobbleEvent {
        ScrobbleEvent(
            artist: artistForScrobble(song.artist),
            title: song.title,
            album: song.albumName,
            durationSeconds: durationSeconds,
            timestamp: trackStartedAt
        )
    }

    private func startTimer(song: Song, durationMs: Int64?, at date: Date) {
        pendingTask?.cancel()
        pendingTask = nil
        let durationSeconds = resolvedDurationSeconds(song: song, durationMs: durationMs)
        guard let delayMs = ScrobbleTiming.delayMilliseconds(
            durationSeconds: durationSeconds,
            minDurationSeconds: configuration.minDurationSeconds,
            delayPercent: configuration.delayPercent,
            maxDelaySeconds: configuration.maxDelaySeconds
        ) else {
            remainingMillis = 0
            pendingEvent = nil
            return
        }
        remainingMillis = Int64(delayMs)
        pendingEvent = event(for: song, durationSeconds: durationSeconds)
        if remainingMillis <= 0 {
            firePending()
            return
        }
        timerStartedAt = date
        scheduleSleep(millis: remainingMillis)
    }

    private func scheduleSleep(millis: Int64) {
        pendingTask?.cancel()
        let event = pendingEvent
        pendingTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(max(millis, 0)) * 1_000_000)
            } catch {
                return
            }
            await self.fired(event)
        }
    }

    private func fired(_ event: ScrobbleEvent?) async {
        // The sleep can finish just as a pause or the next track cancels this countdown;
        // by then `pendingTask` and `pendingEvent` belong to whoever cancelled it.
        guard !Task.isCancelled else { return }
        pendingTask = nil
        guard let event else { return }
        pendingEvent = nil
        remainingMillis = 0
        await scrobble(event)
    }

    private func firePending() {
        let event = pendingEvent
        pendingEvent = nil
        remainingMillis = 0
        Task { await scrobble(event ?? ScrobbleEvent(artist: "", title: "", album: nil, durationSeconds: 0, timestamp: trackStartedAt)) }
    }

    private func pauseTimer(at date: Date) {
        pendingTask?.cancel()
        pendingTask = nil
        if let started = timerStartedAt {
            let elapsed = Int64(date.timeIntervalSince(started) * 1000)
            remainingMillis = max(remainingMillis - elapsed, 0)
            timerStartedAt = nil
        }
    }

    private func resumeTimer(song: Song) {
        guard remainingMillis > 0, pendingEvent != nil else { return }
        pendingTask?.cancel()
        timerStartedAt = Date()
        // Refresh the event's artist choice in case the setting changed mid-track.
        if let pending = pendingEvent {
            pendingEvent = ScrobbleEvent(
                artist: artistForScrobble(song.artist),
                title: pending.title,
                album: pending.album,
                durationSeconds: pending.durationSeconds,
                timestamp: pending.timestamp
            )
        }
        scheduleSleep(millis: remainingMillis)
    }

    private func stopTimer() {
        pendingTask?.cancel()
        pendingTask = nil
        remainingMillis = 0
        timerStartedAt = nil
        pendingEvent = nil
    }
}
