import Foundation

// Ports playback/DynamicLruCacheEvictor.kt.

/// One cached region of one entry, as eviction sees it: the unit that is written, touched and
/// dropped. At most ``AudioCacheStore/fragmentBytes`` long, as Media3's cache files were.
struct AudioCacheSpan: Hashable, Sendable {
    let key: AudioCacheKey
    let start: Int64
    let length: Int64
    /// Last read or written, in milliseconds since 1970.
    let touched: Int64

    var end: Int64 { start + length }

    func touched(at time: Int64) -> AudioCacheSpan {
        AudioCacheSpan(key: key, start: start, length: length, touched: time)
    }
}

/// Least-recently-used eviction whose ceiling can move, with the opening of each track held back.
///
/// The ceiling is a `var` so a settings change takes effect on the cache already open (and in use
/// by the player) rather than needing a new one; ``applyNow()`` reclaims space the moment the limit
/// drops, rather than whenever the listener next happens to play something.
///
/// ## Why the opening of a track is treated differently
///
/// Plain LRU has a pathology here. A track's first bytes are read once, when playback starts, and
/// never touched again; its tail is read continuously as the listener keeps listening. So the head
/// is always the oldest span a track owns, and plain LRU always evicts it first. Measured on the
/// Android reference device with a full cache: 48 of 170 spans still began at byte 0 — most tracks
/// were sitting on disk almost complete, with their openings gone.
///
/// That is invisible for playback, which re-fetches whatever it needs. It is fatal for Automix,
/// whose analyzer can only decode from the start of a container: a track holding 95% of itself but
/// nothing at byte 0 reads as entirely uncached. Worse, with the cache at its ceiling a track
/// downloading its own tail could evict its own head while still playing.
///
/// So head spans are held back from eviction, up to `headBudgetBytes` in total. The budget
/// matters: heads are never re-read, so nothing would ever age them out, and an unbounded exemption
/// would fill the cache with openings. Past the budget the oldest protected head is released back
/// to ordinary LRU, which is both a bound and roughly the right policy — the tracks played longest
/// ago are the ones least likely to come round again.
///
/// Pure bookkeeping: it decides which spans go, and the store deletes them.
struct AudioCacheEvictor {
    /// Twelve seconds of lossless, comfortably: what the head-only analysis pass reads.
    static let defaultHeadBytes: Int64 = 4 * 1_024 * 1_024
    /// Roughly a hundred compressed openings, or a couple of dozen lossless ones — enough that a
    /// session's worth of tracks stay analysable without meaningfully denting the cache.
    static let defaultHeadBudgetBytes: Int64 = 96 * 1_024 * 1_024

    var maxBytes: Int64
    /// How far into a track counts as its head: the region the analyzer needs contiguously from
    /// zero. Sized for lossless; a compressed rendition's head fits many times over.
    let headBytes: Int64
    /// Ceiling on the total held back.
    let headBudgetBytes: Int64

    private var leastRecentlyUsed = SpanOrder()
    /// Head spans exempt from eviction, oldest first. Ordered by the same clock as
    /// `leastRecentlyUsed`, so releasing one back to ordinary LRU picks the least useful.
    private var protectedHeads = SpanOrder()
    private(set) var protectedSize: Int64 = 0
    private(set) var currentSize: Int64 = 0

    init(
        maxBytes: Int64,
        headBytes: Int64 = AudioCacheEvictor.defaultHeadBytes,
        headBudgetBytes: Int64 = AudioCacheEvictor.defaultHeadBudgetBytes
    ) {
        self.maxBytes = maxBytes
        self.headBytes = headBytes
        self.headBudgetBytes = headBudgetBytes
    }

    /// A span is a head if it starts at the very beginning, or within `headBytes` of it.
    func isHead(_ span: AudioCacheSpan) -> Bool { span.start < headBytes }

    func isProtected(_ span: AudioCacheSpan) -> Bool { protectedHeads.contains(span) }

    var spanCount: Int { leastRecentlyUsed.count + protectedHeads.count }

    /// Called before `length` bytes are written, so there is room for them.
    mutating func startFile(length: Int64) -> [AudioCacheSpan] {
        evict(requiredSpace: max(0, length))
    }

    /// Tracks a newly written span and returns whatever has to go to stay under the ceiling.
    mutating func spanAdded(_ span: AudioCacheSpan) -> [AudioCacheSpan] {
        track(span)
        return evict(requiredSpace: 0)
    }

    /// Forgets a span the store removed itself (a discard or a clear).
    mutating func spanRemoved(_ span: AudioCacheSpan) {
        if protectedHeads.remove(span) {
            protectedSize -= span.length
        } else if leastRecentlyUsed.remove(span) {
            // Tracked in plain LRU.
        } else {
            return
        }
        currentSize -= span.length
    }

    /// A span was read: it moves to the young end of whichever set it lands in.
    mutating func spanTouched(_ old: AudioCacheSpan, _ new: AudioCacheSpan) -> [AudioCacheSpan] {
        spanRemoved(old)
        return spanAdded(new)
    }

    /// Reclaims space right away, for a lowered limit.
    mutating func applyNow() -> [AudioCacheSpan] {
        evict(requiredSpace: 0)
    }

    private mutating func track(_ span: AudioCacheSpan) {
        if isHead(span), protectedSize + span.length <= headBudgetBytes {
            protectedHeads.insert(span)
            protectedSize += span.length
        } else {
            leastRecentlyUsed.insert(span)
        }
        currentSize += span.length
    }

    private mutating func evict(requiredSpace: Int64) -> [AudioCacheSpan] {
        var evicted: [AudioCacheSpan] = []
        while currentSize + requiredSpace > maxBytes {
            if let oldest = leastRecentlyUsed.popFirst() {
                currentSize -= oldest.length
                evicted.append(oldest)
                continue
            }
            // Nothing left but protected heads. Releasing the oldest back to ordinary LRU is what
            // stops the exemption from becoming a way to wedge the cache above its own ceiling: the
            // loop then evicts it on the next pass like any other span.
            guard let oldest = protectedHeads.popFirst() else { break }
            protectedSize -= oldest.length
            leastRecentlyUsed.insert(oldest)
        }
        return evicted
    }
}

/// Spans ordered oldest first; ties broken by key then position, as Media3's `CacheSpan` compared.
struct SpanOrder {
    private(set) var items: [AudioCacheSpan] = []

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }
    var first: AudioCacheSpan? { items.first }

    static func precedes(_ lhs: AudioCacheSpan, _ rhs: AudioCacheSpan) -> Bool {
        if lhs.touched != rhs.touched { return lhs.touched < rhs.touched }
        if lhs.key != rhs.key { return lhs.key < rhs.key }
        return lhs.start < rhs.start
    }

    private func lowerBound(_ span: AudioCacheSpan) -> Int {
        var low = 0
        var high = items.count
        while low < high {
            let mid = (low + high) / 2
            if Self.precedes(items[mid], span) { low = mid + 1 } else { high = mid }
        }
        return low
    }

    func contains(_ span: AudioCacheSpan) -> Bool {
        let index = lowerBound(span)
        return index < items.count && items[index] == span
    }

    mutating func insert(_ span: AudioCacheSpan) {
        items.insert(span, at: lowerBound(span))
    }

    @discardableResult
    mutating func remove(_ span: AudioCacheSpan) -> Bool {
        let index = lowerBound(span)
        guard index < items.count, items[index] == span else { return false }
        items.remove(at: index)
        return true
    }

    mutating func popFirst() -> AudioCacheSpan? {
        items.isEmpty ? nil : items.removeFirst()
    }
}
