import CryptoKit
import Foundation
import VibraMusicCore

/// The on-disk half of the audio cache: one sparse file per entry plus a JSON range index, the
/// eviction bookkeeping, and the fetches that fill the holes.
///
/// ## Layout
///
/// `<directory>/<hash>.audio` holds an entry's bytes at their real offsets (a sparse file: holes
/// cost nothing), `<hash>.json` its key, length, type and the spans on disk. The index is rewritten
/// after the bytes it describes are written (with a barrier fsync between), so a crash can lose the
/// last span but never describe bytes that aren't there. Opening reconciles the two: spans past the
/// end of their file are dropped, and entries whose file vanished (lost when the cache lived in
/// `Caches`, which iOS purges) are forgotten, as Media3's cache dropped spans whose files disappeared.
///
/// ## Fetches
///
/// A hole is filled by exactly one fetch at a time. Everyone who needs bytes from it — the player,
/// read-ahead, the analysis head — subscribes to that fetch and is handed each piece as it arrives,
/// so a range is never downloaded twice and nobody waits for a whole range to land before playing
/// its first bytes. This replaces Media3's one-writer-per-entry lock, whose contention the Android
/// comments spend pages on: a read-ahead that lost the lock to the player downloaded nine megabytes
/// into nowhere. Here the loser simply joins.
///
/// A fetch keeps going after its last subscriber finished normally, to the next whole
/// ``lingerBytes`` from where it started (so the player's two-byte probe turns into a useful first
/// range, and a fetch never stops partway through one of the source's own bounded requests), and
/// stops as soon as its last subscriber is cancelled (a skip or a seek).
///
/// The opening of an entry is held back until its MP4 init segment is complete, so the duration
/// fix in ``FragmentedMP4Durations`` is written to disk with it. Bytes are written to disk as they arrive; a
/// write that fails (full disk) turns the rest of that fetch into a pass-through rather than a
/// playback error, as `FLAG_IGNORE_CACHE_ON_ERROR` did on Android.
actor AudioCacheStore {
    /// Longest span one write produces: Media3's cache-file fragment size. Bounds how much one
    /// eviction drops and how much a crash can lose.
    static let fragmentBytes: Int64 = 5 * 1_024 * 1_024
    /// The unit a fetch's planned end is rounded up to, counted from where it started: how far it
    /// reads on once its subscribers have what they wanted. A megabyte is a whole number of
    /// googlevideo ranges for every client (512 KB or 1 MB).
    static let lingerBytes: Int64 = 1_024 * 1_024
    /// A subscriber this close ahead of a fetch's progress waits for it rather than opening a
    /// second request.
    static let joinSlackBytes: Int64 = 256 * 1_024
    /// Largest piece handed out of one disk read.
    static let readPieceBytes: Int64 = 256 * 1_024
    /// How long a free-space reading is trusted.
    static let capacityTTL: TimeInterval = 10
    /// How long touched-span timestamps wait before being written back.
    static let flushDelay: Duration = .seconds(2)
    private static let maxOpenFiles = 24
    private static let recordVersion = 1

    struct Configuration: Sendable {
        var directory: URL
        var limitBytes: Int64
        var minimumFreeBytes: Int64
        var headBytes: Int64
        var headBudgetBytes: Int64
        var availableCapacity: @Sendable (URL) -> Int64?
        var clock: @Sendable () -> Date
    }

    /// Subscription handle returned by ``subscribe(_:at:wantEnd:source:)``.
    struct Subscription: Sendable {
        let fetchID: Int
        let subscriberID: Int
        let stream: AsyncThrowingStream<Data, Error>
    }

    private final class Entry {
        let key: AudioCacheKey
        let base: String
        let generation: Int
        var contentLength: Int64?
        var mimeType: String?
        var contentType: String?
        /// Sorted by start, never overlapping.
        var spans: [AudioCacheSpan] = []
        var fd: Int32 = -1
        var dirty = false

        init(key: AudioCacheKey, base: String, generation: Int) {
            self.key = key
            self.base = base
            self.generation = generation
        }

        var cachedBytes: Int64 { spans.reduce(0) { $0 + $1.length } }
    }

    private struct Subscriber {
        var position: Int64
        let wantEnd: Int64
        let continuation: AsyncThrowingStream<Data, Error>.Continuation
    }

    private final class Fetch {
        let id: Int
        let key: AudioCacheKey
        let generation: Int
        let start: Int64
        let requestEnd: Int64
        var stopAt: Int64
        var position: Int64
        var fragmentStart: Int64
        var persist: Bool
        var subscribers: [Int: Subscriber] = [:]
        var task: Task<Void, Never>?
        var finished = false
        /// Stopped because its last subscriber was cancelled: never joined again.
        var cancelled = false
        var receivedAny = false
        /// Started by a background fill, not a player's read. Its source finding another file only
        /// stops it: a player may hold the header of the file on disk, and removing that file
        /// put another's bytes under it, which it decoded to silence.
        var keepsEntryWhenFileDiffers = false

        init(id: Int, key: AudioCacheKey, generation: Int, start: Int64, requestEnd: Int64, stopAt: Int64, persist: Bool) {
            self.id = id
            self.key = key
            self.generation = generation
            self.start = start
            self.requestEnd = requestEnd
            self.stopAt = stopAt
            self.position = start
            self.fragmentStart = start
            self.persist = persist
        }
    }

    private struct EntryRecord: Codable {
        var version: Int
        var key: AudioCacheKey
        var contentLength: Int64?
        var mimeType: String?
        var contentType: String?
        var spans: [SpanRecord]
    }

    private struct SpanRecord: Codable {
        var start: Int64
        var length: Int64
        var touched: Int64
    }

    nonisolated let directory: URL
    private let executorQueue: DispatchSerialQueue
    private let configuration: Configuration
    private var entries: [AudioCacheKey: Entry] = [:]
    private var evictor: AudioCacheEvictor
    private var limitBytes: Int64
    private var fetches: [Int: Fetch] = [:]
    private var nextID = 0
    private var infoTasks: [AudioCacheKey: Task<AudioContentInfo, Error>] = [:]
    private var capacityReading: (at: Date, available: Int64, cacheSize: Int64)?
    private var openFiles: [AudioCacheKey] = []
    private var flushTask: Task<Void, Never>?
    /// The index load, started in ``init`` so construction never blocks on entry files. Every
    /// public method awaits it before touching state, so nobody sees a half-loaded index.
    private var loadTask: Task<Void, Never>? = nil

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executorQueue.asUnownedSerialExecutor()
    }

    init(configuration: Configuration) throws {
        self.configuration = configuration
        self.directory = configuration.directory
        self.executorQueue = DispatchSerialQueue(label: "com.fortune.vibramusic.ios.AudioCache", qos: .utility)
        self.limitBytes = configuration.limitBytes
        self.evictor = AudioCacheEvictor(
            maxBytes: configuration.limitBytes,
            headBytes: configuration.headBytes,
            headBudgetBytes: configuration.headBudgetBytes
        )
        try FileManager.default.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
        // Reconcile the index off the caller's thread. Every public method awaits ``ensureLoaded``
        // before touching cache state, so nobody sees a half-loaded index, and a read, write or
        // eviction issued right after ``init`` waits for the load rather than racing it.
        loadTask = Task { await loadIndex() }
    }

    /// The rest of what ``init`` used to do synchronously: walk the directory, decode each index
    /// file, drop what no longer matches the bytes, and seed the evictor. Runs on this actor's
    /// serial queue, never on the thread that constructed the cache.
    private func loadIndex() {
        var loaded: [AudioCacheKey: Entry] = [:]
        var tracked = evictor
        var generation = 0
        for entry in Self.loadEntries(in: configuration.directory) {
            generation += 1
            let fresh = Entry(key: entry.key, base: entry.base, generation: generation)
            fresh.contentLength = entry.contentLength
            fresh.mimeType = entry.mimeType
            fresh.contentType = entry.contentType
            fresh.spans = entry.spans
            fresh.dirty = entry.dirty
            loaded[entry.key] = fresh
            for span in entry.spans { Self.trackWithoutEviction(&tracked, span) }
        }
        entries = loaded
        evictor = tracked
        nextID = generation
    }

    /// Waits until the index has been loaded from disk. Idempotent: the same task is awaited.
    private func ensureLoaded() async {
        await loadTask?.value
    }

    /// Adds a loaded span to the evictor without evicting: the limit is applied once everything is
    /// in, so the oldest spans go rather than whichever happened to load last.
    private static func trackWithoutEviction(_ evictor: inout AudioCacheEvictor, _ span: AudioCacheSpan) {
        let ceiling = evictor.maxBytes
        evictor.maxBytes = .max
        _ = evictor.spanAdded(span)
        evictor.maxBytes = ceiling
    }

    // MARK: Limits

    /// Applies the configured limit (and free space) to what was loaded from disk.
    func applyLimitNow() async {
        await ensureLoaded()
        refreshCeiling(force: true)
        remove(evicted: evictor.applyNow())
    }

    func setLimit(_ bytes: Int64) async {
        limitBytes = max(0, bytes)
        await applyLimitNow()
    }

    var limit: Int64 { limitBytes }

    /// The ceiling eviction works to: the user's limit, lowered so the cache never eats into the
    /// last ``Configuration/minimumFreeBytes`` of the volume. Reading free space costs a system
    /// call, so a reading is reused for ``capacityTTL`` together with the cache size at the time,
    /// which keeps the ceiling steady while the cache itself grows into that space.
    private func refreshCeiling(force: Bool = false) {
        let now = configuration.clock()
        if force || capacityReading.map({ now.timeIntervalSince($0.at) > Self.capacityTTL || now < $0.at }) ?? true {
            if let available = configuration.availableCapacity(directory) {
                capacityReading = (now, available, evictor.currentSize)
            } else {
                capacityReading = nil
            }
        }
        var ceiling = limitBytes
        if let reading = capacityReading {
            let room = max(0, reading.available - configuration.minimumFreeBytes)
            ceiling = min(ceiling, reading.cacheSize + room)
        }
        evictor.maxBytes = max(0, ceiling)
    }

    func effectiveCeiling() async -> Int64 {
        await ensureLoaded()
        refreshCeiling()
        return evictor.maxBytes
    }

    // MARK: Queries

    /// Sum of every cached span.
    func cachedBytes() async -> Int64 {
        await ensureLoaded()
        return evictor.currentSize
    }

    func keys() async -> [AudioCacheKey] {
        await ensureLoaded()
        return Array(entries.keys)
    }

    func keys(ofTrack trackID: String) async -> [AudioCacheKey] {
        await ensureLoaded()
        return entries.keys.filter { $0.belongs(toTrack: trackID) }.sorted()
    }

    func contentLength(of key: AudioCacheKey) async -> Int64? {
        await ensureLoaded()
        return entries[key]?.contentLength
    }

    func storedInfo(of key: AudioCacheKey) async -> AudioContentInfo? {
        await ensureLoaded()
        guard let entry = entries[key], let length = entry.contentLength else { return nil }
        return AudioContentInfo(contentLength: length, mimeType: entry.mimeType, contentType: entry.contentType)
    }

    /// The committed spans of `key`, in order.
    func spans(of key: AudioCacheKey) async -> [Range<Int64>] {
        await ensureLoaded()
        return entries[key]?.spans.map { $0.start..<$0.end } ?? []
    }

    /// Media3's `getCachedLength`: from `position`, the length of the cached run (capped at
    /// `length`) when `position` is cached, otherwise minus the length of the hole.
    func cachedLength(_ key: AudioCacheKey, position: Int64, length: Int64) async -> Int64 {
        await ensureLoaded()
        guard length > 0 else { return 0 }
        let end = position + length
        let runs = committedRuns(key)
        if let run = runs.first(where: { $0.lowerBound <= position && position < $0.upperBound }) {
            return min(run.upperBound, end) - position
        }
        let next = runs.first(where: { $0.lowerBound > position })?.lowerBound ?? end
        return -(min(next, end) - position)
    }

    /// Media3's `getCachedBytes`: every cached byte in the range, however scattered.
    func cachedBytes(_ key: AudioCacheKey, position: Int64, length: Int64) async -> Int64 {
        await ensureLoaded()
        guard length > 0 else { return 0 }
        let end = position + length
        return (entries[key]?.spans ?? []).reduce(0) { total, span in
            total + max(0, min(span.end, end) - max(span.start, position))
        }
    }

    /// How far into a rendition ``cachedPrefixBytes(_:)`` looks when its real length isn't known.
    /// Only an upper bound on the answer, so it costs nothing to set well past the half-minute of
    /// audio any caller wants; eight megabytes covers that even for lossless.
    static let headProbeBytes: Int64 = 8 * 1_024 * 1_024

    /// Bytes on disk contiguously from 0 (committed spans only), probed over the content length or
    /// ``headProbeBytes`` when that isn't known yet.
    func cachedPrefixBytes(_ key: AudioCacheKey) async -> Int64 {
        await ensureLoaded()
        let probe = entries[key]?.contentLength.flatMap { $0 > 0 ? $0 : nil } ?? Self.headProbeBytes
        return max(0, await cachedLength(key, position: 0, length: probe))
    }

    func isFullyCached(_ key: AudioCacheKey) async -> Bool {
        await ensureLoaded()
        guard let length = entries[key]?.contentLength, length > 0 else { return false }
        return await cachedPrefixBytes(key) >= length
    }

    func renditions(ofTrack trackID: String) async -> [AudioCacheRendition] {
        await ensureLoaded()
        var found: [AudioCacheRendition] = []
        for key in await keys(ofTrack: trackID) {
            let prefix = await cachedPrefixBytes(key)
            guard prefix > 0 else { continue }
            found.append(AudioCacheRendition(key: key, contentLength: max(0, entries[key]?.contentLength ?? 0), cachedPrefix: prefix))
        }
        return found.sorted { ($0.contentLength, $0.key) < ($1.contentLength, $1.key) }
    }

    /// Every rendition that is whole on disk, across all tracks.
    func completeRenditions() async -> [AudioCacheRendition] {
        await ensureLoaded()
        var found: [AudioCacheRendition] = []
        // One pass with the actor held: no hop per entry for playback's reads to queue behind.
        for (key, entry) in entries {
            guard let length = entry.contentLength, length > 0,
                  let opening = committedRuns(key).first, opening.lowerBound == 0, opening.upperBound >= length else { continue }
            found.append(AudioCacheRendition(key: key, contentLength: length, cachedPrefix: length))
        }
        return found
    }

    /// Committed spans merged into contiguous runs.
    private func committedRuns(_ key: AudioCacheKey) -> [Range<Int64>] {
        Self.merge((entries[key]?.spans ?? []).map { $0.start..<$0.end })
    }

    /// Bytes readable from disk: committed spans plus what in-flight fetches have written but not
    /// yet committed.
    private func availableRuns(_ key: AudioCacheKey) -> [Range<Int64>] {
        guard let entry = entries[key] else { return [] }
        var ranges = entry.spans.map { $0.start..<$0.end }
        for fetch in fetches.values where fetch.key == key && fetch.persist && fetch.generation == entry.generation
            && fetch.position > fetch.fragmentStart {
            ranges.append(fetch.fragmentStart..<fetch.position)
        }
        return Self.merge(ranges)
    }

    static func merge(_ ranges: [Range<Int64>]) -> [Range<Int64>] {
        var merged: [Range<Int64>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where !range.isEmpty {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    // MARK: Content information

    /// What `key` is: from the index when it is known, otherwise from `source` (once, however many
    /// callers ask at the same time). A source that disagrees with the recorded length means the key
    /// now names a different file; the old bytes are discarded.
    ///
    /// - Parameter opening: asked for a player opening this key afresh, the one asker that may replace
    ///   a partial entry with another file. Anyone else (read-ahead, an analysis head, a player
    ///   already reading) leaves it: an asset opened on the old file holds that file's header, and
    ///   read-ahead replacing the bytes under it played a 16-bit FLAC to a decoder set up for 24-bit,
    ///   which ran in silence.
    func contentInfo(for key: AudioCacheKey, source: (any AudioRangeDataSource)?, opening: Bool = false) async throws -> AudioContentInfo {
        await ensureLoaded()
        // A source that states another length before it is asked anything is another file under
        // this key (a substitute's slot filled ahead by one add-on's copy, opened now on another's):
        // answered from the index, the player was handed the old file's length and opening, and the
        // new copy failed at the first hole, mid-track. An entry whole on disk is kept: it
        // plays as the file it is, and nothing of it is fetched again.
        if opening, let stated = source?.statedContentLength, let recorded = entries[key]?.contentLength, stated != recorded,
           committedRuns(key).first.map({ $0.lowerBound > 0 || $0.upperBound < recorded }) ?? true {
            TrackLog.w(Self.category, "\(key)'s new source is \(stated) bytes, not \(recorded); discarding the old copy", about: key.trackID)
            removeKey(key)
        }
        if let entry = entries[key], let length = entry.contentLength, let type = entry.contentType {
            return AudioContentInfo(contentLength: length, mimeType: entry.mimeType, contentType: type)
        }
        if let entry = entries[key], let length = entry.contentLength, entry.contentType == nil {
            // Length known (recorded by an analysis-head fetch) but never opened by a player:
            // the type is all that's missing, and the opening may already be on disk.
            let sniffed = try? await sniffType(key, length: length, source: source)
            if let type = entry.contentType ?? sniffed ?? AudioContentType.uti(mimeType: entry.mimeType) {
                entry.contentType = type
                markDirty(entry, persistNow: true)
                return AudioContentInfo(contentLength: length, mimeType: entry.mimeType, contentType: type)
            }
            if source == nil {
                return AudioContentInfo(contentLength: length, mimeType: entry.mimeType, contentType: AudioContentType.mpeg4Audio)
            }
        }
        guard let source else { throw AudioCacheError.notCached(key) }
        let task: Task<AudioContentInfo, Error>
        if let running = infoTasks[key] {
            task = running
        } else {
            // Asked afresh: whatever length the source was told to expect no longer applies.
            source.expectContentLength(nil)
            task = Task { try await source.contentInfo() }
            infoTasks[key] = task
        }
        let info: AudioContentInfo
        do {
            info = try await task.value
            if infoTasks[key] == task { infoTasks[key] = nil }
        } catch {
            if infoTasks[key] == task { infoTasks[key] = nil }
            throw Self.attach(key, to: error)
        }
        guard info.contentLength > 0 else {
            throw AudioCacheError.badResponse("\(key) reported no length")
        }
        if let existing = entries[key], let recorded = existing.contentLength, recorded != info.contentLength {
            TrackLog.w(Self.category, "\(key) is now \(info.contentLength) bytes, not \(recorded); discarding the old copy", about: key.trackID)
            removeKey(key)
        }
        let entry = entry(for: key)
        if entry.contentLength == nil { entry.contentLength = info.contentLength }
        if entry.mimeType == nil { entry.mimeType = info.mimeType }
        if entry.contentType == nil {
            entry.contentType = info.contentType ?? AudioContentType.uti(mimeType: info.mimeType)
        }
        if entry.contentType == nil {
            entry.contentType = try await sniffType(key, length: info.contentLength, source: source)
        }
        markDirty(entry, persistNow: true)
        return AudioContentInfo(
            contentLength: info.contentLength,
            mimeType: entry.mimeType,
            // Nothing recognisable: MPEG-4 is what almost every stream this app sees is.
            contentType: entry.contentType ?? AudioContentType.mpeg4Audio
        )
    }

    private func sniffType(_ key: AudioCacheKey, length: Int64, source: (any AudioRangeDataSource)?) async throws -> String? {
        let wanted = min(16, length)
        if await cachedLength(key, position: 0, length: wanted) < wanted {
            guard source != nil else { return nil }
            try await fill(key, range: 0..<wanted, source: source)
        }
        guard let prefix = readFromDisk(key, at: 0, length: wanted, touch: false) else { return nil }
        return AudioContentType.sniff(prefix)
    }

    /// Records a length learned elsewhere (a bounded fetch never describes the whole resource).
    func recordContentLength(_ key: AudioCacheKey, _ total: Int64) async {
        await ensureLoaded()
        guard total > 0, let entry = entries[key], (entry.contentLength ?? 0) <= 0 else { return }
        entry.contentLength = total
        markDirty(entry, persistNow: true)
    }

    // MARK: Reading

    /// Up to `maxLength` contiguous bytes of `key` from `position` that are already on disk, or nil
    /// when `position` isn't.
    func read(_ key: AudioCacheKey, at position: Int64, maxLength: Int64) async -> Data? {
        await ensureLoaded()
        guard maxLength > 0 else { return nil }
        let runs = availableRuns(key)
        guard let run = runs.first(where: { $0.lowerBound <= position && position < $0.upperBound }) else { return nil }
        let length = min(maxLength, run.upperBound - position, Self.readPieceBytes)
        return readFromDisk(key, at: position, length: length, touch: true)
    }

    private func readFromDisk(_ key: AudioCacheKey, at position: Int64, length: Int64, touch: Bool) -> Data? {
        guard let entry = entries[key], length > 0 else { return nil }
        let fd = descriptor(for: entry)
        guard fd >= 0 else { return nil }
        var data = Data(count: Int(length))
        var done = 0
        let ok: Bool = data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return false }
            while done < raw.count {
                let count = pread(fd, base + done, raw.count - done, off_t(position) + off_t(done))
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if count == 0 { break }
                done += count
            }
            return true
        }
        guard ok, done == data.count else {
            // The index promised bytes the file doesn't have: the file was truncated or replaced
            // underneath us. Forget the entry rather than serve zeros.
            TrackLog.w(Self.category, "\(key) is shorter on disk than its index; dropping it", about: key.trackID)
            removeKey(key)
            return nil
        }
        if touch { touchSpans(entry, overlapping: position..<(position + length)) }
        return data
    }

    private func touchSpans(_ entry: Entry, overlapping range: Range<Int64>) {
        let now = timestamp()
        var evicted: [AudioCacheSpan] = []
        for index in entry.spans.indices where entry.spans[index].start < range.upperBound && range.lowerBound < entry.spans[index].end {
            let old = entry.spans[index]
            guard old.touched != now else { continue }
            let new = old.touched(at: now)
            entry.spans[index] = new
            evicted += evictor.spanTouched(old, new)
        }
        markDirty(entry, persistNow: false)
        remove(evicted: evicted)
    }

    // MARK: Fetching

    /// Subscribes to the bytes of `key` from `position` onwards, joining a fetch already heading
    /// there or starting one. The stream finishes when the fetch stops (the caller checks the disk
    /// and subscribes again for anything still missing) or when `wantEnd` is reached. Callers must
    /// ``release(_:cancelled:)`` the subscription when they stop reading it.
    ///
    /// `info` re-creates the entry if it was removed after the caller learned it (a clear while a
    /// track plays must not fail the player).
    func subscribe(
        _ key: AudioCacheKey,
        at position: Int64,
        wantEnd: Int64,
        source: (any AudioRangeDataSource)?,
        info: AudioContentInfo? = nil,
        exact: Bool = false,
        background: Bool = false
    ) async throws -> Subscription {
        await ensureLoaded()
        if entries[key]?.contentLength == nil, let info, source != nil {
            let fresh = entry(for: key)
            fresh.contentLength = info.contentLength
            fresh.mimeType = info.mimeType
            fresh.contentType = info.contentType
        }
        guard let entry = entries[key], let length = entry.contentLength else {
            throw source == nil ? AudioCacheError.notCached(key) : AudioCacheError.badResponse("\(key) has no length yet")
        }
        guard position < length else {
            throw AudioCacheError.unexpectedEndOfStream(key: key, position: position)
        }
        let target = min(length, max(wantEnd, position + 1))
        let live = fetches.values.filter { $0.key == key && !$0.finished }

        if let joinable = live.first(where: {
            !$0.cancelled && $0.generation == entry.generation
                && $0.position <= position && position < $0.requestEnd && position - $0.position <= Self.joinSlackBytes
        }) {
            let desiredStop = exact ? target : Self.plannedStop(start: joinable.start, target: target, length: length)
            joinable.stopAt = max(joinable.stopAt, min(joinable.requestEnd, desiredStop))
            return addSubscriber(to: joinable, at: position, wantEnd: target)
        }
        let desiredStop = exact ? target : Self.plannedStop(start: position, target: target, length: length)
        guard let source else { throw AudioCacheError.notCached(key) }

        // A fetch that is headed here but still far off stops where this one starts, so the two
        // never write the same bytes.
        for fetch in live where fetch.position < position && position < fetch.stopAt {
            fetch.stopAt = position
        }
        // The hole ends where bytes already are (on disk, or on their way from a fetch that is
        // writing them) so no byte is fetched twice.
        let availableNext = availableRuns(key).first(where: { $0.lowerBound > position })?.lowerBound ?? length
        let fetchNext = live
            .filter { !$0.cancelled && $0.persist && $0.generation == entry.generation && $0.position > position }
            .map(\.position).min() ?? length
        let holeEnd = min(length, availableNext, fetchNext)
        var requestEnd = holeEnd <= position ? min(length, position + 1) : holeEnd
        // An exact fetch asks the server for what it wants and no more: the hole can run to the
        // end of the file, and a request cancelled at `stopAt` still has its overshoot in flight.
        if exact { requestEnd = min(requestEnd, target) }
        let bounded = source.maxRangeBytes >= requestEnd - position ? requestEnd : position + max(1, source.maxRangeBytes)

        nextID += 1
        let fetch = Fetch(
            id: nextID, key: key, generation: entry.generation, start: position,
            requestEnd: bounded, stopAt: min(bounded, desiredStop), persist: source.isCacheable
        )
        fetch.keepsEntryWhenFileDiffers = background
        fetches[fetch.id] = fetch
        refreshCeiling()
        remove(evicted: evictor.startFile(length: min(Self.fragmentBytes, fetch.stopAt - position)))
        let subscription = addSubscriber(to: fetch, at: position, wantEnd: target)
        fetch.task = Task { await self.run(fetch, source: source) }
        return subscription
    }

    /// Where a fetch from `start` should stop to serve `target`: rounded up to a whole
    /// ``lingerBytes`` from `start`, and never past the end.
    static func plannedStop(start: Int64, target: Int64, length: Int64) -> Int64 {
        let wanted = max(1, target - start)
        let rounded = (wanted + lingerBytes - 1) / lingerBytes * lingerBytes
        return min(length, start + rounded)
    }

    private func addSubscriber(to fetch: Fetch, at position: Int64, wantEnd: Int64) -> Subscription {
        nextID += 1
        let id = nextID
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        fetch.subscribers[id] = Subscriber(position: position, wantEnd: wantEnd, continuation: continuation)
        return Subscription(fetchID: fetch.id, subscriberID: id, stream: stream)
    }

    /// Ends a subscription. The last subscriber leaving because it was *cancelled* (a skip, a
    /// seek, a replaced read-ahead) stops the fetch; one that simply got what it wanted lets it
    /// run on to its planned end.
    func release(_ subscription: Subscription, cancelled: Bool) async {
        await ensureLoaded()
        guard let fetch = fetches[subscription.fetchID],
              let subscriber = fetch.subscribers.removeValue(forKey: subscription.subscriberID) else { return }
        subscriber.continuation.finish()
        if cancelled, fetch.subscribers.isEmpty, !fetch.finished {
            fetch.cancelled = true
            fetch.stopAt = fetch.position
            fetch.task?.cancel()
        }
    }

    private func run(_ fetch: Fetch, source: any AudioRangeDataSource) async {
        // Bytes for this entry must be of the file it recorded, not another one under its key. An
        // entry replaced since this fetch began isn't its to compare with (accept drops its bytes).
        let entry = entries[fetch.key]
        source.expectContentLength(entry?.generation == fetch.generation ? entry?.contentLength : nil)
        // Only a fetch from byte 0 can hold the init segment back; one starting later is past it.
        // The flag is read per piece rather than once up front: a lazily-resolved source only
        // knows its origin after its first request, which is also when the first piece arrives.
        var gate: InitSegmentGate? = fetch.start == 0 ? InitSegmentGate() : nil
        do {
            for try await piece in source.stream(fetch.start..<fetch.requestEnd) {
                var ready = piece
                if var held = gate {
                    let patch: (inout Data) -> Int = source.requiresYouTubeDurationFix
                        ? FragmentedMP4Durations.patchYouTubeInitSegment : { _ in 0 }
                    guard let released = held.feed(piece, patch: patch) else {
                        gate = held
                        continue
                    }
                    gate = nil
                    ready = released
                }
                if !accept(ready, into: fetch) { break }
            }
            // A stream shorter than an init segment: what arrived is all there is.
            if var held = gate {
                _ = accept(held.release(), into: fetch)
            }
            finish(fetch, error: nil)
        } catch {
            // Bytes still held back were never released unpatched; they're fetched again later.
            finish(fetch, error: error)
        }
    }

    private func accept(_ piece: Data, into fetch: Fetch) -> Bool {
        guard !fetch.finished, fetch.position < fetch.stopAt else { return false }
        guard !piece.isEmpty else { return true }
        let room = fetch.stopAt - fetch.position
        let data = Int64(piece.count) > room ? piece.prefix(Int(room)) : piece
        let pieceStart = fetch.position

        if fetch.persist {
            if let entry = entries[fetch.key], entry.generation == fetch.generation {
                if !write(data, to: entry, at: pieceStart) {
                    // Commit what landed, then stream the rest past the disk.
                    commitFragment(of: fetch)
                    fetch.persist = false
                }
            } else {
                fetch.persist = false
            }
        }
        fetch.position += Int64(data.count)
        fetch.receivedAny = true

        for (id, var subscriber) in fetch.subscribers where subscriber.position < fetch.position {
            let offset = subscriber.position - pieceStart
            guard offset >= 0 else { continue }
            let slice = offset == 0 ? Data(data) : Data(data.dropFirst(Int(offset)))
            subscriber.position = fetch.position
            fetch.subscribers[id] = subscriber
            subscriber.continuation.yield(slice)
            if subscriber.position >= subscriber.wantEnd {
                // Satisfied: its stream ends here, the fetch lingers on.
                fetch.subscribers.removeValue(forKey: id)
                subscriber.continuation.finish()
            }
        }

        if fetch.persist, fetch.position - fetch.fragmentStart >= Self.fragmentBytes {
            commitFragment(of: fetch)
            refreshCeiling()
            remove(evicted: evictor.startFile(length: min(Self.fragmentBytes, fetch.stopAt - fetch.position)))
        }
        return fetch.position < fetch.stopAt
    }

    private func finish(_ fetch: Fetch, error: Error?) {
        guard !fetch.finished else { return }
        fetch.finished = true
        fetches[fetch.id] = nil
        commitFragment(of: fetch)

        var failure: Error?
        if let error, !Self.isCancellation(error) {
            failure = Self.attach(fetch.key, to: error)
            if case AudioCacheError.contentChanged? = failure, !fetch.keepsEntryWhenFileDiffers {
                removeKey(fetch.key)
            }
            TrackLog.d(Self.category, "fetch of \(fetch.key) [\(fetch.start), \(fetch.requestEnd)) stopped at \(fetch.position): \(failure!)", about: fetch.key.trackID)
        } else if error == nil, !fetch.receivedAny, fetch.stopAt > fetch.start {
            failure = AudioCacheError.unexpectedEndOfStream(key: fetch.key, position: fetch.start)
        }
        for subscriber in fetch.subscribers.values {
            if let failure {
                subscriber.continuation.finish(throwing: failure)
            } else {
                subscriber.continuation.finish()
            }
        }
        fetch.subscribers.removeAll()
    }

    private func commitFragment(of fetch: Fetch) {
        let length = fetch.position - fetch.fragmentStart
        defer { fetch.fragmentStart = fetch.position }
        guard length > 0, fetch.persist, let entry = entries[fetch.key], entry.generation == fetch.generation else { return }
        let fd = descriptor(for: entry)
        if fd >= 0 {
            // Bytes before the index that describes them.
            _ = fcntl(fd, F_BARRIERFSYNC)
        }
        let span = AudioCacheSpan(key: fetch.key, start: fetch.fragmentStart, length: length, touched: timestamp())
        let index = entry.spans.firstIndex(where: { $0.start > span.start }) ?? entry.spans.count
        entry.spans.insert(span, at: index)
        markDirty(entry, persistNow: true)
        remove(evicted: evictor.spanAdded(span))
    }

    /// Fills `range` of `key` (skipping what is already there), for read-ahead and the analysis
    /// head. Throws what the fetch threw; cancellation stops it and whatever it started.
    ///
    /// With `exact` the fetches stop at the end of `range` instead of lingering on to a whole
    /// ``lingerBytes`` (a warm-up of a header or a swap point, where the bytes past it are not
    /// about to be read).
    func fill(_ key: AudioCacheKey, range: Range<Int64>, source: (any AudioRangeDataSource)?, info: AudioContentInfo? = nil,
              exact: Bool = false) async throws {
        await ensureLoaded()
        var position = range.lowerBound
        while position < range.upperBound {
            try Task.checkCancellation()
            if let run = availableRuns(key).first(where: { $0.lowerBound <= position && position < $0.upperBound }) {
                position = run.upperBound
                continue
            }
            let subscription = try await subscribe(key, at: position, wantEnd: range.upperBound, source: source, info: info, exact: exact, background: true)
            do {
                for try await piece in subscription.stream {
                    position += Int64(piece.count)
                    if position >= range.upperBound { break }
                }
            } catch {
                await release(subscription, cancelled: Task.isCancelled)
                throw error
            }
            await release(subscription, cancelled: Task.isCancelled)
        }
    }

    /// Whether anything is fetching into `key` right now.
    func isFetching(_ key: AudioCacheKey) async -> Bool {
        await ensureLoaded()
        return fetches.values.contains { $0.key == key && !$0.finished }
    }

    // MARK: Removing

    /// Drops `key` from disk. A fetch still filling it keeps feeding whoever is listening, but
    /// writes nothing more, so the bytes really are gone.
    func remove(_ key: AudioCacheKey) async {
        await ensureLoaded()
        removeKey(key)
    }

    /// The synchronous half of ``remove``: safe to call from other isolated methods that have
    /// already awaited the load (reads, writes, and eviction are always post-load).
    private func removeKey(_ key: AudioCacheKey) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        for span in entry.spans { evictor.spanRemoved(span) }
        for fetch in fetches.values where fetch.key == key { fetch.persist = false }
        closeDescriptor(of: entry)
        try? FileManager.default.removeItem(at: dataURL(entry.base))
        try? FileManager.default.removeItem(at: recordURL(entry.base))
    }

    /// Drops everything, including files the index doesn't know about.
    func removeAll() async {
        await ensureLoaded()
        for key in Array(entries.keys) { removeKey(key) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        for name in names {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    /// Spans the evictor picked: out of the index, their blocks handed back to the file system.
    private func remove(evicted spans: [AudioCacheSpan]) {
        for span in spans {
            guard let entry = entries[span.key], let index = entry.spans.firstIndex(where: { $0.start == span.start && $0.length == span.length }) else { continue }
            entry.spans.remove(at: index)
            if entry.spans.isEmpty, !fetches.values.contains(where: { $0.key == span.key && !$0.finished }) {
                entries[span.key] = nil
                closeDescriptor(of: entry)
                try? FileManager.default.removeItem(at: dataURL(entry.base))
                try? FileManager.default.removeItem(at: recordURL(entry.base))
            } else {
                punchHole(entry, span.start..<span.end)
                markDirty(entry, persistNow: true)
            }
        }
    }

    /// Frees the whole file-system blocks inside `range` (APFS supports holes; partial blocks at
    /// the edges may hold a neighbouring span's bytes and stay).
    private func punchHole(_ entry: Entry, _ range: Range<Int64>) {
        let fd = descriptor(for: entry)
        guard fd >= 0 else { return }
        var info = stat()
        let block = fstat(fd, &info) == 0 && info.st_blksize > 0 ? Int64(info.st_blksize) : 4_096
        let start = (range.lowerBound + block - 1) / block * block
        let end = range.upperBound / block * block
        guard end > start else { return }
        var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(start), fp_length: off_t(end - start))
        _ = fcntl(fd, F_PUNCHHOLE, &hole)
    }

    // MARK: Disk usage

    /// Bytes the cache directory actually occupies (allocated blocks, index files included).
    func diskUsage() async -> Int64 {
        await flushDirty()
        return Self.allocatedSize(of: directory)
    }

    nonisolated static func allocatedSize(of directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    func entryCount() async -> Int {
        await ensureLoaded()
        return entries.count
    }

    // MARK: Persistence

    private func entry(for key: AudioCacheKey) -> Entry {
        if let entry = entries[key] { return entry }
        nextID += 1
        let entry = Entry(key: key, base: Self.fileBase(for: key), generation: nextID)
        entries[key] = entry
        return entry
    }

    private func markDirty(_ entry: Entry, persistNow: Bool) {
        entry.dirty = true
        if persistNow {
            save(entry)
        } else if flushTask == nil {
            flushTask = Task {
                try? await Task.sleep(for: Self.flushDelay)
                await self.flushDirty()
            }
        }
    }

    /// Writes back every index with unsaved touches.
    func flushDirty() async {
        await ensureLoaded()
        flushTask?.cancel()
        flushTask = nil
        for entry in entries.values where entry.dirty { save(entry) }
    }

    private func save(_ entry: Entry) {
        guard entries[entry.key] === entry else { return }
        let record = EntryRecord(
            version: Self.recordVersion,
            key: entry.key,
            contentLength: entry.contentLength,
            mimeType: entry.mimeType,
            contentType: entry.contentType,
            spans: entry.spans.map { SpanRecord(start: $0.start, length: $0.length, touched: $0.touched) }
        )
        do {
            try JSONEncoder().encode(record).write(to: recordURL(entry.base), options: .atomic)
            entry.dirty = false
        } catch {
            TrackLog.w(Self.category, "could not save the index of \(entry.key)", error: error, about: entry.key.trackID)
        }
    }

    private struct LoadedEntry {
        let key: AudioCacheKey
        let base: String
        let contentLength: Int64?
        let mimeType: String?
        let contentType: String?
        let spans: [AudioCacheSpan]
        let dirty: Bool
    }

    private nonisolated static func loadEntries(in directory: URL) -> [LoadedEntry] {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        var loaded: [LoadedEntry] = []
        var described: Set<String> = []
        for name in names where name.hasSuffix(".json") {
            let base = String(name.dropLast(5))
            let recordURL = directory.appending(path: name)
            let dataURL = directory.appending(path: base + ".audio")
            guard let data = try? Data(contentsOf: recordURL),
                  let record = try? JSONDecoder().decode(EntryRecord.self, from: data),
                  record.version == recordVersion else {
                try? manager.removeItem(at: recordURL)
                continue
            }
            let size = (try? manager.attributesOfItem(atPath: dataURL.path(percentEncoded: false))[.size] as? NSNumber)?.int64Value
            guard let size else {
                // The bytes are gone; the index means nothing.
                try? manager.removeItem(at: recordURL)
                continue
            }
            let spans = record.spans
                .filter { $0.length > 0 && $0.start >= 0 && $0.start + $0.length <= size }
                .sorted { $0.start < $1.start }
                .reduce(into: [AudioCacheSpan]()) { kept, span in
                    if let last = kept.last, span.start < last.end { return }
                    kept.append(AudioCacheSpan(key: record.key, start: span.start, length: span.length, touched: span.touched))
                }
            guard !spans.isEmpty else {
                try? manager.removeItem(at: recordURL)
                try? manager.removeItem(at: dataURL)
                continue
            }
            described.insert(base)
            loaded.append(LoadedEntry(
                key: record.key, base: base, contentLength: record.contentLength, mimeType: record.mimeType,
                contentType: record.contentType, spans: spans, dirty: spans.count != record.spans.count
            ))
        }
        for name in names where name.hasSuffix(".audio") && !described.contains(String(name.dropLast(6))) {
            try? manager.removeItem(at: directory.appending(path: name))
        }
        return loaded
    }

    // MARK: Files

    private nonisolated static func fileBase(for key: AudioCacheKey) -> String {
        SHA256.hash(data: Data(key.rawValue.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func dataURL(_ base: String) -> URL { directory.appending(path: base + ".audio") }
    private func recordURL(_ base: String) -> URL { directory.appending(path: base + ".json") }

    private func descriptor(for entry: Entry) -> Int32 {
        if entry.fd >= 0 {
            if let index = openFiles.firstIndex(of: entry.key) {
                openFiles.remove(at: index)
                openFiles.append(entry.key)
            }
            return entry.fd
        }
        let fd = open(dataURL(entry.base).path(percentEncoded: false), O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return -1 }
        entry.fd = fd
        openFiles.append(entry.key)
        while openFiles.count > Self.maxOpenFiles {
            let oldest = openFiles.removeFirst()
            if let other = entries[oldest], other !== entry { closeDescriptor(of: other) }
        }
        return fd
    }

    private func closeDescriptor(of entry: Entry) {
        guard entry.fd >= 0 else { return }
        close(entry.fd)
        entry.fd = -1
        openFiles.removeAll { $0 == entry.key }
    }

    private func write(_ data: Data, to entry: Entry, at offset: Int64) -> Bool {
        let fd = descriptor(for: entry)
        guard fd >= 0 else { return false }
        return data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var done = 0
            while done < raw.count {
                let count = pwrite(fd, base + done, raw.count - done, off_t(offset) + off_t(done))
                if count < 0 {
                    if errno == EINTR { continue }
                    TrackLog.w(Self.category, "write to \(entry.key) failed (errno \(errno)); streaming past the disk", about: entry.key.trackID)
                    return false
                }
                done += count
            }
            return true
        }
    }

    private func timestamp() -> Int64 {
        Int64((configuration.clock().timeIntervalSince1970 * 1_000).rounded())
    }

    // MARK: Errors

    static func attach(_ key: AudioCacheKey, to error: Error) -> Error {
        if case AudioCacheError.contentChanged(nil, let expected, let actual)? = error as? AudioCacheError {
            return AudioCacheError.contentChanged(key: key, expected: expected, actual: actual)
        }
        return error
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        return false
    }

    static let category = "AudioCache"
}
