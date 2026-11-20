import Foundation
import VibraMusicCore

// Ports AudioCache.requestAnalysisHead / awaitAnalysisHead / alignmentHeadComplete /
// alignmentPrefixBytes / analysisHeadSize / clearPartialHead.

/// Gets a track's opening onto disk for Automix, and says when there is enough of it.
///
/// ## Why the analyzer has to ask for this
///
/// Nothing else fetches a track's opening early enough. Read-ahead writes no bytes for a track
/// whose substitution isn't pinned, and a quality upgrade fetches its rendition from the swap point
/// onward, so a track that plays lossless from the start would otherwise never have a measurable
/// opening at all.
///
/// ## Why it fetches once, at full size
///
/// An earlier Android version started at a megabyte and grew the request on each later call. Every
/// round resolves the stream again, and a resolver doesn't promise the same file twice: round one
/// wrote a megabyte of one encoding, round two skipped what was cached and wrote the remainder of a
/// *different* one into the same entry — a complete-looking file that decodes for fourteen seconds
/// of a 153-second container. One resolve, one range, one encoding: the size is decided once from
/// the real length (``headSize(total:)``), and a part-filled entry is cleared before anything is
/// written to it (``clearPartialHead(_:want:)``). A copy that turns out undecodable is deleted
/// rather than remembered (``AudioStreamCache/discardBadRendition(_:playing:)``), which also re-arms
/// this for the track.
actor AudioCacheAnalysisHeads {
    /// What a head asks for when the track's size can't be had: twelve seconds of anything short
    /// of lossless.
    static let maxHeadBytes: Int64 = 4 * 1_024 * 1_024
    /// The most one track's head pulls when its size *is* known. Covers every YouTube Opus stream in
    /// full (a ten-minute track at 160 kbps is twelve) without pulling a whole 40 MB FLAC.
    static let maxTrackBytes: Int64 = 16 * 1_024 * 1_024
    /// How many passes a wait may start. One is normal; the rest are for a round that ended
    /// part-written.
    static let maxRounds = 3
    /// Gap kept before a retry claims the track again, so a wait can't set off a second fetch
    /// alongside the one it was trying to join.
    static let roundSettle: Duration = .milliseconds(500)
    static let pollInterval: Duration = .milliseconds(40)

    private let store: AudioCacheStore
    /// Keys whose head has been asked for this session.
    private var claimed: Set<AudioCacheKey> = []
    /// Keys with a head fetch in the air, so a tick can't stack another on top.
    private var inFlight: Set<AudioCacheKey> = []
    /// What each key's last round asked for: the only way to tell a finished head from one the
    /// round left part-written.
    private var wanted: [AudioCacheKey: Int64] = [:]

    init(store: AudioCacheStore) {
        self.store = store
    }

    static func headSize(total: Int64) -> Int64 {
        total > 0 ? min(total, maxTrackBytes) : maxHeadBytes
    }

    func reset() {
        claimed.removeAll()
        inFlight.removeAll()
        wanted.removeAll()
    }

    /// Re-arms `key` after its bytes were discarded: without this the entry just freed would never
    /// be refilled this session and the discard buys nothing.
    func forget(_ key: AudioCacheKey) {
        claimed.remove(key)
        wanted[key] = nil
    }

    func isInFlight(_ key: AudioCacheKey) -> Bool { inFlight.contains(key) }

    func request(_ key: AudioCacheKey, source: any AudioRangeDataSource, fallback: (key: AudioCacheKey, source: any AudioRangeDataSource)?) {
        // One round per key per session, sized correctly up front.
        guard claimed.insert(key).inserted else { return }
        guard inFlight.insert(key).inserted else { return }
        Task {
            await TrackLog.about(key.trackID) {
                await self.round(key, source: source, fallback: fallback)
            }
            self.inFlight.remove(key)
        }
    }

    private func round(_ key: AudioCacheKey, source: any AudioRangeDataSource, fallback: (key: AudioCacheKey, source: any AudioRangeDataSource)?) async {
        let info: AudioContentInfo?
        do {
            info = try await store.contentInfo(for: key, source: source)
        } catch {
            TrackLog.w(AudioCacheStore.category, "content length failed for \(key)", error: error)
            info = nil
        }
        let total = info?.contentLength ?? 0
        let want = Self.headSize(total: total)
        wanted[key] = want
        TrackLog.w(AudioCacheStore.category, "analysis head round for \(key): total=\(total) want=\(want) held=\(await alignmentPrefixBytes(key.trackID))")
        // No length means the pinned copy can't be had at all (its resolve failed); the fallback
        // below is still worth a try, as it was on Android.
        if let info {
            guard await clearPartialHead(key, want: want) else {
                TrackLog.w(AudioCacheStore.category, "analysis head round for \(key) skipped: partial is held elsewhere")
                return
            }
            do {
                try await store.fill(key, range: 0..<min(want, info.contentLength), source: source, info: info)
            } catch {
                TrackLog.d(AudioCacheStore.category, "analysis head for \(key) stopped: \(error)")
            }
        }
        if await alignmentPrefixBytes(key.trackID) < AudioStreamCache.minAlignmentPrefixBytes, let fallback {
            // The pinned copy wouldn't come, while playback of the same track reads whichever copy
            // it chose. Alignment opens the fullest copy on disk anyway, so pull that one instead
            // of costing the switch its alignment. Its entry can hold a prefix of an earlier resolve
            // just as the pinned one can, so it is cleared the same way before anything is written.
            do {
                let fallbackInfo = try await store.contentInfo(for: fallback.key, source: fallback.source)
                let fallbackWant = min(want, fallbackInfo.contentLength)
                if await clearPartialHead(fallback.key, want: fallbackWant) {
                    try await store.fill(fallback.key, range: 0..<fallbackWant, source: fallback.source, info: fallbackInfo)
                }
            } catch {
                TrackLog.d(AudioCacheStore.category, "fallback head for \(fallback.key) stopped: \(error)")
            }
        }
        if total > 0 { await store.recordContentLength(key, total) }
        let held = await alignmentPrefixBytes(key.trackID)
        if held < AudioStreamCache.minAlignmentPrefixBytes {
            TrackLog.w(AudioCacheStore.category, "analysis head for \(key) came up short: held=\(held) want=\(want) total=\(total)")
        }
    }

    /// Makes sure `key` is either empty or already covers `want` before anything writes to it.
    /// A part-filled entry came from an earlier resolve, and filling its gap would splice a second
    /// encoding onto it: cheaper to throw the prefix away and pull one clean copy.
    /// - Returns: false when the caller should not fetch — the entry is complete enough, or it is
    ///   being filled by someone else right now (clearing it would create the very seam this avoids).
    func clearPartialHead(_ key: AudioCacheKey, want: Int64) async -> Bool {
        let held = await store.cachedBytes(key, position: 0, length: want)
        if held <= 0 { return true }
        if held >= want { return false }
        if await store.isFetching(key) {
            TrackLog.d(AudioCacheStore.category, "partial head for \(key) is in use", about: key.trackID)
            return false
        }
        await store.remove(key)
        TrackLog.d(AudioCacheStore.category, "cleared partial analysis head for \(key) (\(held) of \(want))", about: key.trackID)
        return true
    }

    /// The figure version alignment opens by: the largest same-source (non-substitute) copy when
    /// it is big enough to measure, and the largest copy of any kind otherwise. A substitute can be
    /// a different cut, so it is only worth waiting on when nothing else is on disk.
    func alignmentPrefixBytes(_ trackID: String) async -> Int64 {
        let renditions = await store.renditions(ofTrack: trackID)
        let sameSource = renditions.filter { !$0.key.isSubstitute }.map(\.cachedPrefix).max() ?? 0
        if sameSource >= AudioStreamCache.minAlignmentPrefixBytes { return sameSource }
        return renditions.map(\.cachedPrefix).max() ?? 0
    }

    /// Whether `key`'s opening is as complete as it is ever going to be: past the alignment
    /// minimum, or as much as the round asked for once that round has stopped writing.
    func headComplete(_ key: AudioCacheKey) async -> Bool {
        let held = await alignmentPrefixBytes(key.trackID)
        if held >= AudioStreamCache.minAlignmentPrefixBytes { return true }
        guard let want = wanted[key], !inFlight.contains(key) else { return false }
        return held >= want
    }

    /// Waits for the head. A round that gave up halfway is not accepted: a head that decodes for a
    /// handful of seconds caps how far two cuts may be slid against each other, and handing that
    /// over as a measurement is how a swap lands near the wrong second while looking like it
    /// worked. So the wait pulls again instead, up to ``maxRounds``.
    func waitForHead(_ key: AudioCacheKey, source: any AudioRangeDataSource, fallback: (key: AudioCacheKey, source: any AudioRangeDataSource)?, timeout: Duration) async -> Bool {
        if await headComplete(key) { return true }
        // A previous round that wrote nothing would otherwise block retries for the session.
        if !inFlight.contains(key) { claimed.remove(key) }
        request(key, source: source, fallback: fallback)
        var rounds = 1
        let clock = ContinuousClock()
        var askedAt = clock.now
        let deadline = askedAt + timeout
        while clock.now < deadline {
            if await headComplete(key) { return true }
            if !inFlight.contains(key) {
                if rounds >= Self.maxRounds { return await headComplete(key) }
                let now = clock.now
                if now - askedAt >= Self.roundSettle {
                    // Below the minimum there is nothing a measurement can act on, so the round
                    // may try again; each retry clears the partial first.
                    if await alignmentPrefixBytes(key.trackID) < AudioStreamCache.minAlignmentPrefixBytes {
                        claimed.remove(key)
                        request(key, source: source, fallback: fallback)
                        rounds += 1
                    }
                    askedAt = now
                }
            }
            guard (try? await Task.sleep(for: Self.pollInterval)) != nil else { break }
        }
        return await headComplete(key)
    }
}
