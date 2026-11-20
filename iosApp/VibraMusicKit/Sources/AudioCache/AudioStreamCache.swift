@preconcurrency import AVFoundation
import Foundation
import Observation
import VibraMusicCore

// Ports playback/AudioCache.kt (the object the rest of the app talks to).

/// On-disk cache of the audio itself, and the read-ahead that fills it.
///
/// Two problems, one cache:
///
///  - **Seeking.** Everything played is written to disk on the way through, so seeking back is
///    always a file read. Seeking *forward* past what the player has buffered is the gap, and it
///    closes once a track is on disk in full — which is why read-ahead fetches whole tracks rather
///    than openings.
///  - **Track changes.** The next track needs a stream URL resolved before its first byte can even
///    be asked for. Fetching it ahead of time moves all of that off the gap between songs.
///
/// Playback asks for an asset by ``AudioCacheKey`` (track identity, never a URL; see there for
/// why) and a byte source. AVFoundation then reads the custom-scheme URL through an
/// `AVAssetResourceLoaderDelegate` that answers from disk and fills holes from the source — lazily,
/// so a track already cached never resolves a URL. A fully cached track therefore plays with no
/// network at all (airplane mode).
///
/// ```swift
/// let cache = try AudioStreamCache()
/// let source = HTTPAudioSource(onRefused: resolver.noteRefused) {
///     try await resolver.resolveStream(for: song, request: request)
/// }
/// let item = AVPlayerItem(asset: cache.makeAsset(for: .youtube(videoId: song.videoId), source: source))
/// ```
///
/// iOS differences from Android:
///  - There is no single-writer lock (fetches are shared, see ``AudioCacheStore``), so the
///    read-ahead's lock probe and lost-race retries are gone.
///  - The key is chosen by the caller rather than derived from global settings inside the cache.
///  - Eviction also respects free space on the volume.
///  - YouTube's fragmented MP4 has its declared durations zeroed on the way to disk, or
///    AVFoundation would report twice the track's length (see ``FragmentedMP4Durations``).
///  - A player read that hits a hole with no network is retried a few times before it fails
///    (``Configuration/networkRetryDelays``), as ExoPlayer's load-error policy did.
///  - Android's one-off purge of `#alt` entries written before its matcher fix is not carried
///    over: no iOS install has such entries.
public final class AudioStreamCache: Sendable {
    /// The scheme of the asset URLs this cache serves. Anything AVFoundation doesn't know itself,
    /// so it has to ask the resource loader.
    public static let urlScheme = "vibramusic-cache"

    /// How many upcoming tracks are worth handing to ``prefetch(_:)``: the next one gets its bytes,
    /// the ones after it their stream URLs warmed.
    public static let queueDepth = AudioCacheReadAhead.queueLookahead + 1

    /// Enough of a YouTube head to decode the opening window version alignment measures.
    public static let minAlignmentPrefixBytes: Int64 = 800 * 1_024

    public struct Configuration: Sendable {
        /// Where entries live. The default is under `Application Support`, not `Caches`: iOS empties
        /// `Caches` under storage pressure, and the offline backup plays what is whole in here
        /// (Android keeps it in `noBackupFilesDir` for the same reason). Eviction already keeps it
        /// clear of the last ``minimumFreeBytes``.
        public var directory: URL
        /// The disk budget (``AppSettings/audioCacheLimitBytes``: 512 MB by default, up to 10 GB).
        /// Least-recently-used spans are dropped past it, so it's a ceiling rather than something
        /// the listener has to manage.
        public var limitBytes: Int64
        /// Free space the cache never eats into, whatever the limit says: a 10 GB limit on a phone
        /// with 3 GB free must not fill it.
        public var minimumFreeBytes: Int64
        /// Head protection (see ``AudioCacheEvictor``).
        public var headBytes: Int64
        public var headBudgetBytes: Int64
        /// Grace period before reading ahead. The seconds just after a track starts are when the
        /// player fills its own buffer and the listener is waiting on sound; read-ahead competing
        /// for bandwidth there would trade the gap between songs for a gap at the start of one. It
        /// also collapses a burst of skips into a single fetch of wherever the listener lands.
        public var prefetchDelay: Duration
        /// How long to leave an entry alone before trying the whole-track fetch again.
        public var retryDelay: Duration
        /// Spacing between queued warm-ups, so warming the queue never competes with the track
        /// actually playing.
        public var queueWarmUpStagger: Duration
        /// Waits before failing a player's read whose fetch found no network, one per retry (see
        /// ``AudioCacheResourceLoader``). ExoPlayer's default policy retried a failed load three
        /// times with growing gaps; so does this.
        public var networkRetryDelays: [Duration]
        /// Bytes available for opportunistic use on the cache's volume; nil when unknown.
        public var availableCapacity: @Sendable (URL) -> Int64?
        public var clock: @Sendable () -> Date

        public init(
            directory: URL,
            limitBytes: Int64 = AppSettings.defaultAudioCacheLimitBytes,
            minimumFreeBytes: Int64 = 1_024 * 1_024 * 1_024,
            headBytes: Int64 = 4 * 1_024 * 1_024,
            headBudgetBytes: Int64 = 96 * 1_024 * 1_024,
            prefetchDelay: Duration = .seconds(2),
            retryDelay: Duration = .seconds(5),
            queueWarmUpStagger: Duration = .milliseconds(500),
            networkRetryDelays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2)],
            availableCapacity: @escaping @Sendable (URL) -> Int64? = { AudioStreamCache.availableCapacity(at: $0) },
            clock: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.directory = directory
            self.limitBytes = limitBytes
            self.minimumFreeBytes = minimumFreeBytes
            self.headBytes = headBytes
            self.headBudgetBytes = headBudgetBytes
            self.prefetchDelay = prefetchDelay
            self.retryDelay = retryDelay
            self.queueWarmUpStagger = queueWarmUpStagger
            self.networkRetryDelays = networkRetryDelays
            self.availableCapacity = availableCapacity
            self.clock = clock
        }

        /// `Library/Application Support/Vibra Music/AudioCache` with the default limits.
        public static func standard(limitBytes: Int64 = AppSettings.defaultAudioCacheLimitBytes) -> Configuration {
            Configuration(directory: URL.applicationSupportDirectory.appending(path: "Vibra Music", directoryHint: .isDirectory)
                .appending(path: "AudioCache", directoryHint: .isDirectory), limitBytes: limitBytes)
        }
    }

    /// `Library/Caches/AudioCache`, where earlier builds kept the cache.
    public static var legacyDirectory: URL {
        URL.cachesDirectory.appending(path: "AudioCache", directoryHint: .isDirectory)
    }

    /// Moves a cache from `legacy` to `directory`, once, before anything opens it. Moved, not
    /// copied: one rename when `directory` doesn't exist yet, which is atomic, so a launch killed
    /// part-way finds the cache wholly in one place or the other. Otherwise (an older build ran in
    /// between and started a cache of its own) file by file, each move again atomic and never over
    /// a file `directory` already has, so a launch killed part-way leaves the rest for the next one,
    /// and the store, which opens only afterwards, finds each entry's bytes beside its index.
    /// Nothing is fetched again for an entry that moved.
    public static func moveCache(from legacy: URL = legacyDirectory, to directory: URL = Configuration.standard().directory) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: legacy.path(percentEncoded: false)) else { return }
        do {
            if !manager.fileExists(atPath: directory.path(percentEncoded: false)) {
                try manager.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.moveItem(at: legacy, to: directory)
                TrackLog.d(AudioCacheStore.category, "moved the audio cache out of Caches")
                return
            }
            var moved = 0
            for name in try manager.contentsOfDirectory(atPath: legacy.path(percentEncoded: false)) {
                let from = legacy.appending(path: name), to = directory.appending(path: name)
                if manager.fileExists(atPath: to.path(percentEncoded: false)) {
                    // The same entry twice: the copy already in place wins.
                    try manager.removeItem(at: from)
                } else {
                    try manager.moveItem(at: from, to: to)
                    moved += 1
                }
            }
            try manager.removeItem(at: legacy)
            TrackLog.d(AudioCacheStore.category, "merged \(moved) files of the old audio cache into the new one")
        } catch {
            // What is left stays where it is, and the next launch tries again.
            TrackLog.w(AudioCacheStore.category, "could not move the audio cache out of Caches", error: error)
        }
    }

    public let configuration: Configuration
    let store: AudioCacheStore
    let readAhead: AudioCacheReadAhead
    let heads: AudioCacheAnalysisHeads

    /// Opens (or creates) the cache at `configuration.directory`, reconciling the index with what
    /// is actually on disk and applying the limit.
    public init(configuration: Configuration = .standard()) throws {
        self.configuration = configuration
        let store = try AudioCacheStore(configuration: .init(
            directory: configuration.directory,
            limitBytes: configuration.limitBytes,
            minimumFreeBytes: configuration.minimumFreeBytes,
            headBytes: configuration.headBytes,
            headBudgetBytes: configuration.headBudgetBytes,
            availableCapacity: configuration.availableCapacity,
            clock: configuration.clock
        ))
        self.store = store
        self.readAhead = AudioCacheReadAhead(store: store, configuration: configuration)
        self.heads = AudioCacheAnalysisHeads(store: store)
        // Fetched again on demand, so never worth a slot in the listener's iCloud backup. Set on
        // every open: the version-update wipe makes the directory afresh, without it.
        var directory = configuration.directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        Task { await store.applyLimitNow() }
    }

    /// Opportunistic free space on `url`'s volume, the figure Apple asks caches to size themselves
    /// by.
    public static func availableCapacity(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForOpportunisticUsageKey, .volumeAvailableCapacityKey])
        if let opportunistic = values?.volumeAvailableCapacityForOpportunisticUsage { return opportunistic }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    // MARK: Assets

    /// `asset` over again with AVFoundation asked for precise timing, for an open that lands mid-song.
    ///
    /// Without it a seek in a raw FLAC or MP3 lands on an estimated byte and the player stamps what
    /// it finds there with the time it was asked for, so its clock is off from the sound by whole
    /// frames until the next seek to the top (measured against the rendered audio on macOS,
    /// up to 8.7 s in a Qobuz FLAC). Lyrics follow that clock, and a swap lines up on it. With it,
    /// the player walks the frames from the start before it plays, which costs a whole-file FLAC
    /// seconds on an iPad, and bytes that haven't arrived have to be waited for. So a play from the
    /// top, which is exact anyway, never asks for it. An asset this can't reopen is returned as is.
    public static func preciselyTimed(_ asset: AVURLAsset) -> AVURLAsset {
        let options = [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        if asset.url.isFileURL { return AVURLAsset(url: asset.url, options: options) }
        guard let loader = resourceLoader(of: asset) else { return asset }
        let precise = AVURLAsset(url: asset.url, options: options)
        precise.resourceLoader.setDelegate(loader, queue: loader.queue)
        objc_setAssociatedObject(precise, &AudioStreamCache.loaderAssociation, loader, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return precise
    }

    /// An asset that plays `key` through the cache. Cached bytes come off disk; missing ones come
    /// from `source` and are written to disk on the way through. With a nil `source` the asset
    /// plays only what is cached (offline, or an analysis read that must never fetch).
    public func makeAsset(for key: AudioCacheKey, source: (any AudioRangeDataSource)?, options: [String: Any]? = nil) -> AVURLAsset {
        let asset = AVURLAsset(url: Self.url(for: key), options: options)
        let loader = AudioCacheResourceLoader(key: key, source: source, store: store, retryDelays: configuration.networkRetryDelays)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        // The resource loader holds its delegate weakly; tie the delegate's life to the asset's.
        objc_setAssociatedObject(asset, &AudioStreamCache.loaderAssociation, loader, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return asset
    }

    /// The whole length the source behind `asset` knows ahead of its bytes
    /// (``AudioRangeDataSource/knownDuration``); nil for an asset this cache didn't make.
    public static func knownDuration(of asset: AVAsset) -> TimeInterval? {
        resourceLoader(of: asset)?.source?.knownDuration
    }

    /// Whether every byte behind `asset` is on disk; false for an asset this cache didn't make.
    public static func isWhole(_ asset: AVAsset) async -> Bool {
        guard let loader = resourceLoader(of: asset) else { return false }
        return await loader.store.isFullyCached(loader.key)
    }

    /// How many bytes behind `asset` are on disk; 0 for an asset this cache didn't make.
    public static func bytesOnDisk(of asset: AVAsset) async -> Int64 {
        guard let loader = resourceLoader(of: asset) else { return 0 }
        return await loader.store.spans(of: loader.key).reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    /// Gets the next `ahead` seconds' worth of `asset`'s bytes around `seconds` (of `length`) onto
    /// disk, whatever the player is doing. Returns at once for an asset this cache didn't make or
    /// doesn't store. Throws when the link fails, or brings nothing for `stallLimit`.
    public static func fetchAhead(of asset: AVAsset, at seconds: TimeInterval, of length: TimeInterval,
                                  ahead: TimeInterval, stallLimit: Duration) async throws {
        try await resourceLoader(of: asset)?.fetchAhead(at: seconds, of: length, ahead: ahead, stallLimit: stallLimit)
    }

    /// What's on disk behind `asset` and what the player is still waiting on, for the log; nil for
    /// an asset this cache didn't make.
    public static func readReport(of asset: AVAsset) async -> String? {
        await resourceLoader(of: asset)?.readReport()
    }

    private static func resourceLoader(of asset: AVAsset) -> AudioCacheResourceLoader? {
        objc_getAssociatedObject(asset, &AudioStreamCache.loaderAssociation) as? AudioCacheResourceLoader
    }

    /// An asset for an already-resolved stream. HLS playlists and files on this device aren't
    /// cached by range and are returned as plain assets (with the stream's headers).
    public func makeAsset(
        for key: AudioCacheKey,
        stream: ResolvedStream,
        session: URLSession = VibraMusicHTTP.session,
        refresh: HTTPAudioSource.Resolver? = nil,
        onRefused: HTTPAudioSource.RefusalHandler? = nil,
        options: [String: Any]? = nil
    ) -> AVURLAsset {
        if stream.url.isFileURL {
            return AVURLAsset(url: stream.url, options: options)
        }
        if stream.isHLS {
            var merged = options ?? [:]
            if !stream.headers.isEmpty { merged["AVURLAssetHTTPHeaderFieldsKey"] = stream.headers }
            return AVURLAsset(url: stream.url, options: merged)
        }
        let source = HTTPAudioSource(stream: stream, session: session, refresh: refresh, onRefused: onRefused)
        return makeAsset(for: key, source: source, options: options)
    }

    /// `vibramusic-cache://audio/<key>`.
    public static func url(for key: AudioCacheKey) -> URL {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = "audio"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        components.percentEncodedPath = "/" + (key.rawValue.addingPercentEncoding(withAllowedCharacters: allowed) ?? key.rawValue)
        return components.url!
    }

    /// The key an asset URL from ``url(for:)`` names.
    public static func key(from url: URL) -> AudioCacheKey? {
        guard url.scheme == urlScheme else { return nil }
        let path = url.path(percentEncoded: false)
        guard path.count > 1 else { return nil }
        return AudioCacheKey(rawValue: String(path.dropFirst()))
    }

    nonisolated(unsafe) private static var loaderAssociation: UInt8 = 0

    // MARK: Read-ahead

    /// Gets the queue ahead of the one playing warmed up, in play order: the first item's opening
    /// onto disk, then the rest of it; the next ``queueDepth`` − 1 items only their ``AudioCachePrefetchItem/warmUp``.
    /// A call naming the same queue as the one already running, each item with a source and a
    /// warm-up where it had one before, is left alone; a different one replaces it outright, since
    /// on a run of skips only wherever the listener lands is worth chasing. See
    /// ``AudioCacheReadAhead`` for the rules the caller is expected to apply.
    public func prefetch(_ upcoming: [AudioCachePrefetchItem]) async {
        await readAhead.prefetch(upcoming)
    }

    /// Nothing to read ahead for once playback stops. Resuming starts the fetch again rather than
    /// being mistaken for one already in hand.
    public func cancelPrefetch() async {
        await readAhead.cancel()
    }

    /// Pulls exactly `range` of `key` onto disk (for example the opening of a rendition about to
    /// be swapped in, so the player's first read after the swap isn't a round trip in silence):
    /// the request asks for that range and the fetch stops at its end, rather than lingering on
    /// the way a player's read does. Failures are logged, not thrown: nothing waits on a warm-up.
    public func warmRange(_ key: AudioCacheKey, source: any AudioRangeDataSource, range: Range<Int64>) async {
        await readAhead.fetch(key, range: range, source: source, exact: true)
    }

    /// Gets every byte of `key` onto disk now (no delay, no retries). True when it's all there.
    @discardableResult
    public func cacheCompletely(_ key: AudioCacheKey, source: any AudioRangeDataSource) async -> Bool {
        await readAhead.cacheWholeOnce(key, source: source, onlyWhileTarget: false)
    }

    // MARK: Inspecting

    /// True once every byte of `key` is on disk, contiguously from the start. Holes count: a
    /// decoder stops at the first one, and the Android analyzer once read a four-minute track as
    /// ending at 61 seconds because a scattered total looked complete.
    public func isFullyCached(_ key: AudioCacheKey) async -> Bool {
        await store.isFullyCached(key)
    }

    /// The full size of `key`'s rendition in bytes, or 0 when it isn't known yet. Recorded the first
    /// time anything opened it, so it is available well before the bytes are.
    public func contentLength(of key: AudioCacheKey) async -> Int64 {
        await store.contentLength(of: key) ?? 0
    }

    /// Bytes on disk contiguously from the start: the only measure a head-only decode can act on.
    /// Probed over 8 MB when the length isn't known, because the tracks this matters for are the
    /// ones nothing has opened yet.
    public func cachedPrefixBytes(of key: AudioCacheKey) async -> Int64 {
        await store.cachedPrefixBytes(key)
    }

    /// The byte ranges of `key` on disk, merged.
    public func cachedRanges(of key: AudioCacheKey) async -> [Range<Int64>] {
        AudioCacheStore.merge(await store.spans(of: key))
    }

    /// What is actually on disk for `key`, as a log line. "The audition cached it" is an assumption
    /// that has already been wrong once, and this is the only place it can be checked.
    public func cachedSummary(of key: AudioCacheKey) async -> String {
        let spans = await store.spans(of: key)
        guard !spans.isEmpty else { return "\(key) holds nothing" }
        let total = spans.reduce(Int64(0)) { $0 + ($1.upperBound - $1.lowerBound) }
        let ranges = spans.map { "[\($0.lowerBound),\($0.upperBound))" }.joined(separator: " ")
        return "\(key) holds \(total / 1_024)kB in \(spans.count) spans: \(ranges)"
    }

    /// Every rendition of `trackID` with an opening on disk, smallest first (decode time tracks
    /// bytes, and the lightest complete rendition was usually available earliest). Callers must
    /// still check durations agree before treating two as interchangeable: a substitute (`#alt`)
    /// can be a different cut of the same song.
    public func renditions(ofTrack trackID: String) async -> [AudioCacheRendition] {
        await store.renditions(ofTrack: trackID)
    }

    /// Every rendition that is whole on disk, across all tracks: what plays with no connection.
    public func completeRenditions() async -> [AudioCacheRendition] {
        await store.completeRenditions()
    }

    /// A random-access reader over `key`'s cached bytes that never fetches. With
    /// `requireComplete` it is nil unless the whole rendition is on disk (analysis treats anything
    /// less as "not ready"); without it, nil only when there is no opening at all, and reads stop
    /// where the cached prefix does.
    public func reader(for key: AudioCacheKey, requireComplete: Bool) async -> AudioCacheReader? {
        if requireComplete {
            guard await store.isFullyCached(key) else { return nil }
        } else {
            guard await store.cachedPrefixBytes(key) > 0 else { return nil }
        }
        return AudioCacheReader(key: key, store: store, size: await store.contentLength(of: key) ?? -1)
    }

    // MARK: Storage

    /// What the cache holds. ``AudioCacheUsage/diskBytes`` is what Settings should show: it is what
    /// ``clear()`` frees.
    public func usage() async -> AudioCacheUsage {
        AudioCacheUsage(
            cachedBytes: await store.cachedBytes(),
            diskBytes: await store.diskUsage(),
            entryCount: await store.entryCount(),
            limitBytes: await store.limit,
            ceilingBytes: await store.effectiveCeiling()
        )
    }

    /// Moves the ceiling. A lower one is applied at once rather than on the next write, otherwise a
    /// lowered limit only takes effect whenever the listener next plays something.
    public func setLimit(_ bytes: Int64) async {
        await store.setLimit(bytes)
    }

    /// Keeps the limit in step with ``AppSettings/audioCacheLimitBytes`` until the returned task is
    /// cancelled.
    @MainActor
    public func followLimit(of settings: AppSettings) -> Task<Void, Never> {
        let (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        @MainActor func current() -> Int64 {
            withObservationTracking { settings.audioCacheLimitBytes } onChange: { continuation.yield() }
        }
        let first = current()
        return Task { @MainActor [weak self] in
            await self?.setLimit(first)
            for await _ in changes {
                let limit = current()
                await self?.setLimit(limit)
            }
        }
    }

    /// Drops everything on disk. The listener asked; no grace period. Read-ahead stops and the
    /// analysis bookkeeping is reset with it: a remembered head size is a size for a file that is
    /// gone. A track still playing keeps playing (its fetch streams on without writing).
    /// Returns the bytes freed.
    @discardableResult
    public func clear() async -> Int64 {
        await readAhead.cancel()
        await heads.reset()
        let before = await store.diskUsage()
        await store.removeAll()
        let after = await store.diskUsage()
        TrackLog.d(AudioCacheStore.category, "cleared the audio cache: \(before - after) bytes freed")
        return max(0, before - after)
    }

    /// Throws away every rendition of `trackID`, so the next open fetches it again from the top.
    /// For when what is on disk is the problem rather than the network: a half-written entry, or one
    /// filled from two different files and unreadable at the seam. Nothing can tell which, so every
    /// rendition goes; the cost is a re-download rather than a track that can't be played at all.
    ///
    /// - Parameter keepComplete: spares every rendition that is on disk in full, for a failure that
    ///   was the network's rather than the file's (a dropped connection, an expired URL, no
    ///   connection at all). A complete entry is never written to again, so it can't be the seam
    ///   this clears, and throwing it away for a network error deleted the very copies offline
    ///   playback and the offline backup play (Android's `AudioCache.discard(keepComplete)`).
    public func discard(trackID: String, keepComplete: Bool = false) async {
        let why = keepComplete ? "a network failure" : "a failure that may be the bytes'"
        for key in await store.keys(ofTrack: trackID) {
            if keepComplete, await store.isFullyCached(key) {
                TrackLog.d(AudioCacheStore.category, "kept complete cache entry \(key) through \(why)", about: trackID)
                continue
            }
            await store.remove(key)
            TrackLog.d(AudioCacheStore.category, "discarded cache entry \(key) after \(why)", about: trackID)
        }
    }

    /// Drops every substitute's copy (`#alt…`: an add-on's or JioSaavn's) and upgrade copy
    /// (`#hifi…`) that is only partly on disk, except those of `keepingTracks` (the tracks around
    /// the playhead, still being read, seeked through or looked ahead for). Android's
    /// `dropForeignEntries`. Nothing is left to finish such an entry once its track is behind: its
    /// URL has expired, and the next lookup may land on another file, whose different length fails
    /// that open first (``AudioCacheError/contentChanged(key:expected:actual:)``) before the entry
    /// is dropped anyway. A whole copy is never written to again, so it stays and plays straight
    /// off disk next time. Returns how many entries went.
    @discardableResult
    public func dropPartialAddonEntries(keepingTracks: Set<String>) async -> Int {
        var dropped = 0
        for key in await store.keys() where key.isSubstitute || key.rendition?.hasPrefix("hifi") == true {
            guard !keepingTracks.contains(key.trackID), !(await store.isFullyCached(key)) else { continue }
            await store.remove(key)
            await heads.forget(key)
            dropped += 1
        }
        if dropped > 0 { TrackLog.d(AudioCacheStore.category, "dropped \(dropped) partial add-on cache entries") }
        return dropped
    }

    /// Throws away only `key`, leaving the track's other renditions (an upgrade that was fetched
    /// and then not used must not leave a prefix for the next upgrade to be spliced onto, but the
    /// stream still playing is fine).
    public func discardRendition(_ key: AudioCacheKey) async {
        await store.remove(key)
        TrackLog.d(AudioCacheStore.category, "discarded unused rendition \(key)", about: key.trackID)
    }

    /// Throws away `key` because its bytes can't be decoded, unless it is `playing` (whose bytes
    /// are by definition fine: the decode that failed was of a sibling copy). Re-arms the
    /// analysis head for the track, so the discard leads to a clean pull rather than to nothing.
    /// - Returns: whether the bytes are gone, which the caller must treat as "stop holding this key
    ///   against the track".
    @discardableResult
    public func discardBadRendition(_ key: AudioCacheKey, playing: AudioCacheKey?) async -> Bool {
        if key == playing {
            TrackLog.d(AudioCacheStore.category, "keeping undecodable rendition \(key): it is the one playing", about: key.trackID)
            return false
        }
        await store.remove(key)
        await heads.forget(key)
        TrackLog.d(AudioCacheStore.category, "discarded undecodable rendition \(key)", about: key.trackID)
        return true
    }

    /// Records a length learned elsewhere, for an entry filled by bounded fetches only.
    public func recordContentLength(_ key: AudioCacheKey, _ total: Int64) async {
        await store.recordContentLength(key, total)
    }

    /// Writes back pending index updates (last-used times). Call when the app goes to the
    /// background; they are written within seconds anyway.
    public func flush() async {
        await store.flushDirty()
    }

    // MARK: Analysis head

    /// Pulls `key`'s opening onto disk for Automix (sized once from the real length; see
    /// ``AudioCacheAnalysisHeads``), falling back to `fallback` when the pinned copy won't come.
    public func requestAnalysisHead(
        for key: AudioCacheKey,
        source: any AudioRangeDataSource,
        fallback: (key: AudioCacheKey, source: any AudioRangeDataSource)? = nil
    ) async {
        await heads.request(key, source: source, fallback: fallback)
    }

    /// Requests the analysis head if needed and waits until enough of the opening is on disk to
    /// align two versions of a track. False once no further round can improve on it.
    public func awaitAnalysisHead(
        for key: AudioCacheKey,
        source: any AudioRangeDataSource,
        fallback: (key: AudioCacheKey, source: any AudioRangeDataSource)? = nil,
        timeout: Duration = .seconds(20)
    ) async -> Bool {
        await heads.waitForHead(key, source: source, fallback: fallback, timeout: timeout)
    }
}

/// How much the cache holds, for Settings.
public struct AudioCacheUsage: Hashable, Sendable {
    /// Audio bytes in the index.
    public var cachedBytes: Int64
    /// Allocated bytes of the cache directory (audio, holes excluded, plus the index files): what
    /// clearing frees.
    public var diskBytes: Int64
    public var entryCount: Int
    /// The user's limit.
    public var limitBytes: Int64
    /// The limit after free-space awareness: what eviction is working to right now.
    public var ceilingBytes: Int64
}

/// One rendition of a recording, as the analyzer sees it. `key` names the entry, not a URL: the
/// point is to name a rendition the player is not using.
public struct AudioCacheRendition: Hashable, Sendable {
    public var key: AudioCacheKey
    /// 0 when not known yet.
    public var contentLength: Int64
    /// Bytes on disk contiguously from the start.
    public var cachedPrefix: Int64

    public var isComplete: Bool { contentLength > 0 && cachedPrefix >= contentLength }

    public init(key: AudioCacheKey, contentLength: Int64, cachedPrefix: Int64) {
        self.key = key
        self.contentLength = contentLength
        self.cachedPrefix = cachedPrefix
    }
}

/// A queued track as read-ahead needs it.
public struct AudioCachePrefetchItem: Sendable {
    /// The entry playback will open this track under. Must be the same key playback uses, or every
    /// byte lands in an entry nothing reads.
    public var key: AudioCacheKey
    /// Where its bytes come from, or nil when read-ahead must not write bytes for it (a
    /// substitution that isn't pinned yet: read-ahead resolving to YouTube on its own would write
    /// Opus into the entry a higher-ranked source is about to fill).
    public var source: (any AudioRangeDataSource)?
    /// The cheap half: resolve the stream URL into the resolver's own cache without fetching bytes.
    public var warmUp: (@Sendable () async throws -> Void)?

    public init(key: AudioCacheKey, source: (any AudioRangeDataSource)?, warmUp: (@Sendable () async throws -> Void)? = nil) {
        self.key = key
        self.source = source
        self.warmUp = warmUp
    }
}
