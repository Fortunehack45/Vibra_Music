import Foundation
import VibraMusicCore

// Ports AudioCache.prefetchQueue / fetchWhole / cacheWholeOnce / fetch.

/// Read-ahead: the next track's bytes, and the one after's stream URL.
///
/// The first item gets the full treatment: its opening onto disk first, so it can start the moment
/// it's reached, then the rest of it, so seeking around it is a disk read from the first second it
/// plays. Only that one track, and never bytes for anything further out: full-track bytes for
/// tracks that may never be reached would spend real mobile data on nothing.
///
/// The next ``queueLookahead`` items get a lighter treatment: only their ``AudioCachePrefetchItem/warmUp``
/// (a stream URL minted into the resolver's own cache). That's the gap a fast run of skips falls
/// into — the queue moving faster than a single-track read-ahead can follow — and a resolve costs a
/// handful of small round trips, not a stream's worth of data.
///
/// One, not three, and the difference is not the round trips: on Android, while every player
/// client was being refused, every warm-up fell through to the one extraction path that collapses
/// when run concurrently (1.8 s alone against 30.3 s with three in flight), which cost the track the
/// listener was waiting on a thirty-second start.
///
/// What the caller decides (these rules lived in `prefetchQueue` on Android, next to state the
/// cache no longer owns): leave out downloaded and source-backed tracks that play from elsewhere;
/// pass a nil ``AudioCachePrefetchItem/source`` for a track whose substitution isn't pinned yet, or
/// that the listener reverted to YouTube's original (which plays from its own `#original` entry),
/// so read-ahead can't write bytes under a key playback won't read.
actor AudioCacheReadAhead {
    /// How many tracks past the next one get their stream URL warmed: a quick run of two or three
    /// skips lands on a track whose URL is already minted. Still one at a time, staggered, so the
    /// warm-ups never run concurrently (see above).
    static let queueLookahead = 3
    /// URL warm-ups are a few small round trips, so they start almost at once; the next track's
    /// bytes wait out ``AudioStreamCache/Configuration/prefetchDelay``.
    static let warmUpDelay: Duration = .milliseconds(500)
    /// How long a finished warm-up stands. The URL it minted sits in the resolver's own cache for
    /// about as long (an add-on's stream is held five minutes), so asking again inside this time
    /// would run a whole race to learn nothing — and a pause, which clears the plan, then a play
    /// would do exactly that for every queued track.
    static let warmUpFreshness: Duration = .seconds(5 * 60)
    /// How much of the next track to fetch first: about 50 seconds at 160 kbps, long enough that
    /// playback starts instantly and keeps going while the rest streams.
    static let preloadBytes: Int64 = 1_024 * 1_024
    /// Size of each range the whole-track pass checks and fills.
    static let chunkBytes: Int64 = 2 * 1_024 * 1_024
    /// Enough to cover a hand-over, not enough to keep chasing a lost cause.
    static let maxAttempts = 4

    private let store: AudioCacheStore
    private let prefetchDelay: Duration
    private let retryDelay: Duration
    private let stagger: Duration

    private struct PlanStep: Equatable {
        let key: AudioCacheKey
        let fetchesBytes: Bool
        let warmsURL: Bool
    }

    /// The plan running now: each item's key, and whether it came with a source and a warm-up.
    /// Only a call that matches it in all three is the same plan; the same keys with a source that
    /// wasn't there before (a substitution pinned since) is a plan the old one never fetched for.
    private var pendingPlan: [PlanStep] = []
    private var job: Task<Void, Never>?
    private var warmedAt: [AudioCacheKey: ContinuousClock.Instant] = [:]

    init(store: AudioCacheStore, configuration: AudioStreamCache.Configuration) {
        self.store = store
        self.prefetchDelay = configuration.prefetchDelay
        self.retryDelay = configuration.retryDelay
        self.stagger = configuration.queueWarmUpStagger
    }

    var target: AudioCacheKey? { pendingPlan.first?.key }

    func prefetch(_ upcoming: [AudioCachePrefetchItem]) {
        let plan = upcoming.map { PlanStep(key: $0.key, fetchesBytes: $0.source != nil, warmsURL: $0.warmUp != nil) }
        if plan == pendingPlan { return }
        pendingPlan = plan
        job?.cancel()
        guard let next = upcoming.first else {
            job = nil
            return
        }
        let delay = prefetchDelay
        let stagger = stagger
        let cacheBytes = next.source != nil
        let warm = Array(upcoming.prefix(Self.queueLookahead + 1).dropFirst(cacheBytes ? 1 : 0))
        job = Task {
            await withTaskGroup(of: Void.self) { group in
                if let source = next.source {
                    group.addTask {
                        await TrackLog.about(next.key.trackID) {
                            guard (try? await Task.sleep(for: delay)) != nil else { return }
                            await self.fetch(next.key, range: 0..<Self.preloadBytes, source: source)
                            await self.fetchWhole(next.key, source: source)
                        }
                    }
                }
                group.addTask {
                    guard (try? await Task.sleep(for: min(delay, Self.warmUpDelay))) != nil else { return }
                    for item in warm {
                        guard !Task.isCancelled else { return }
                        if let warmUp = item.warmUp, !(await self.isWarm(item.key)) {
                            do {
                                // Filed under the track it warms, not the one playing.
                                try await TrackLog.about(item.key.trackID) { try await warmUp() }
                                await self.noteWarmed(item.key)
                            } catch {
                                TrackLog.d(AudioCacheStore.category, "queue warm-up skipped \(item.key): \(error)", about: item.key.trackID)
                            }
                        }
                        guard (try? await Task.sleep(for: stagger)) != nil else { return }
                    }
                }
            }
        }
    }

    private func isWarm(_ key: AudioCacheKey) -> Bool {
        guard let at = warmedAt[key] else { return false }
        return at.duration(to: .now) < Self.warmUpFreshness
    }

    private func noteWarmed(_ key: AudioCacheKey) {
        // Bounded by the queue depth in practice; the sweep only stops a long session collecting keys.
        warmedAt = warmedAt.filter { $0.value.duration(to: .now) < Self.warmUpFreshness }
        warmedAt[key] = .now
    }

    func cancel() {
        pendingPlan = []
        job?.cancel()
        job = nil
    }

    /// Gets the whole of `key` onto disk, a range at a time. Progress is measured rather than
    /// assumed; a few spaced retries ride out a dropped connection, and then it is left alone.
    private func fetchWhole(_ key: AudioCacheKey, source: any AudioRangeDataSource) async {
        for _ in 0..<Self.maxAttempts {
            // Cancelling a job takes until its next checkpoint, so the walk for a track the queue
            // has moved on from can still be a retry in by the time the new one starts. Once this
            // key is no longer what the queue wants read ahead, every further attempt is spent on
            // a track nobody is waiting for.
            guard target == key, !Task.isCancelled else {
                TrackLog.d(AudioCacheStore.category, "\(key) is no longer the read-ahead target; stopping", about: key.trackID)
                return
            }
            if await cacheWholeOnce(key, source: source, onlyWhileTarget: true) { return }
            guard (try? await Task.sleep(for: retryDelay)) != nil else { return }
        }
        TrackLog.d(AudioCacheStore.category, "stopped short of caching \(key) in full", about: key.trackID)
    }

    /// True once every range of `key` is on disk.
    func cacheWholeOnce(_ key: AudioCacheKey, source: any AudioRangeDataSource, onlyWhileTarget: Bool) async -> Bool {
        guard let total = try? await store.contentInfo(for: key, source: source).contentLength else { return false }
        var position: Int64 = 0
        while position < total {
            // Checked per chunk, not once per pass: a long track can have the queue move on
            // partway through.
            if onlyWhileTarget, target != key { return false }
            if Task.isCancelled { return false }
            let length = min(Self.chunkBytes, total - position)
            if await store.cachedBytes(key, position: position, length: length) < length {
                await fetch(key, range: position..<(position + length), source: source)
                if await store.cachedBytes(key, position: position, length: length) < length { return false }
            }
            position += length
        }
        return true
    }

    /// Pulls `range` of `key` into the cache; only the gaps are fetched. Failures are logged:
    /// expected on a skip, and never worth failing playback over. `exact` stops at the end of the
    /// range rather than lingering on (see ``AudioCacheStore/fill(_:range:source:info:exact:)``).
    func fetch(_ key: AudioCacheKey, range: Range<Int64>, source: any AudioRangeDataSource, exact: Bool = false) async {
        guard !range.isEmpty else { return }
        let started = ContinuousClock.now
        // Read-ahead is the app's largest consumer of bandwidth and, unlogged, its most invisible.
        TrackLog.d(AudioCacheStore.category, "read-ahead fetching \(key) [\(range.lowerBound), \(range.upperBound))", about: key.trackID)
        do {
            let info = try await store.contentInfo(for: key, source: source)
            // A re-resolve can shrink the file under a pass planned against the old length.
            guard range.lowerBound < info.contentLength else { return }
            let clamped = range.lowerBound..<min(range.upperBound, info.contentLength)
            guard !clamped.isEmpty else { return }
            try await store.fill(key, range: clamped, source: source, info: info, exact: exact)
            let elapsed = ContinuousClock.now - started
            TrackLog.d(AudioCacheStore.category, "read-ahead fetched \(key) [\(clamped.lowerBound), \(clamped.upperBound)) in \(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)ms", about: key.trackID)
        } catch {
            TrackLog.d(AudioCacheStore.category, "read-ahead stopped for \(key): \(error)", about: key.trackID)
        }
    }
}
