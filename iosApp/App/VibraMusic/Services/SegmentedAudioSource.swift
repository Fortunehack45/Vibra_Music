import AudioCache
import VibraMusicCore
import Downloads
import Foundation

/// A segmented stream as one file, for the audio cache.
///
/// A playlist stream (HLS, or a source's DASH manifest converted to one: an add-on's lossless and
/// Dolby Atmos) used to be handed to AVFoundation, which fetches the segments itself, outside the
/// cache. So it was downloaded again on every play, never read ahead, and never there with no
/// connection. Android's player cache holds those segments; this is the iOS counterpart.
///
/// An fMP4 playlist's init segment followed by each segment's `moof`/`mdat` *is* a fragmented MP4
/// file (what Downloads saves a package as). This lays that file out without fetching it: the init
/// segment in hand, and for every media segment its size and where its `moof` starts, learned from
/// one small ranged request each. The cache then asks for byte ranges of the file, each range is
/// fetched from the segment it falls in, and what arrives is written to disk as the track plays —
/// once. From the next play on the track is on disk: at once, at this quality, offline too.
///
/// A segment's bytes go on as they arrive. AVPlayer reads every fragment's `moof` across the file
/// before it starts, so bytes held until a whole slice landed could mean it never started (measured
/// at 2 Mbps). A read that stops making progress is cut and asked again from the byte reached:
/// what it brought is already on its way to the disk and isn't downloaded twice.
struct SegmentedAudioSource: AudioRangeDataSource {
    /// One media segment's place in the file.
    struct Part: Hashable, Sendable {
        let url: URL
        /// Bytes at the segment's start that are left out (`styp`, `sidx`: they describe the
        /// segment as a file of its own and mean nothing mid-stream).
        let skip: Int64
        /// Bytes of the segment that are in the file.
        let length: Int64
        /// Where they start in the file.
        let offset: Int64
    }

    /// One ranged request: the bytes, and the resource's whole size when the answer states it.
    /// A refusal throws ``AudioCacheError/httpStatus(_:url:)``. What a layout is made from.
    typealias Fetch = @Sendable (_ url: URL, _ headers: [String: String], _ range: Range<Int64>?) async throws -> (data: Data, total: Int64?)
    /// One ranged request for a segment's audio: `deliver` gets the bytes as they arrive, in order
    /// from the range's start and none past its end. Returning having delivered fewer means the
    /// answer ended early. A refusal throws ``AudioCacheError/httpStatus(_:url:)``. Cancelled, it
    /// stops the request and returns or throws at once.
    typealias ReadSegment = @Sendable (_ url: URL, _ headers: [String: String], _ range: Range<Int64>, _ deliver: @escaping @Sendable (Data) -> Void) async throws -> Void
    /// Returns when one stall window has passed; throws when cancelled.
    typealias StallTimer = @Sendable () async throws -> Void
    /// The stream found again and laid out afresh (see ``refreshing(_:expiresAt:)``).
    typealias Refresh = @Sendable () async throws -> SegmentedAudioSource

    let initialization: Data
    let parts: [Part]
    let headers: [String: String]
    let fetch: Fetch
    let readSegment: ReadSegment
    let stallTimer: StallTimer
    /// The whole length, from the playlist: AVFoundation can't tell it from a fragmented file's
    /// opening (neither `mehd`, a `sidx` nor an edit list moves it: measured on CI), so it
    /// knows only the fragments it has read — 0:24 of a 3:07 song still arriving. The player
    /// shows this instead meanwhile.
    let knownDuration: TimeInterval?
    /// The length the cache recorded for the entry being filled (``expectContentLength(_:)``):
    /// an add-on can answer one track with its Atmos mix one time and its FLAC the next, under the
    /// same entry, and the two must never be spliced.
    private let expected = LockedLength()
    /// How a copy whose segment links went stale mid-read (refused, or past the stream's expiry)
    /// is found again, as an HTTP copy's URL is. Nil: a refused segment fails the read.
    private var refresh: Refresh?
    /// The segment links reads use: the layout's own until ``refresh`` replaces them.
    private var links: Links

    /// Without `readSegment`, each read is `fetch`'s, handed over whole.
    init(initialization: Data, parts: [Part], headers: [String: String], fetch: @escaping Fetch, readSegment: ReadSegment? = nil,
         stallTimer: @escaping StallTimer = SegmentedAudioSource.waitOutStallWindow, knownDuration: TimeInterval? = nil) {
        self.initialization = initialization
        self.parts = parts
        self.headers = headers
        self.fetch = fetch
        let whole: ReadSegment = { url, headers, range, deliver in
            let data = try await fetch(url, headers, range).data
            deliver(data)
        }
        self.readSegment = readSegment ?? whole
        self.stallTimer = stallTimer
        self.knownDuration = knownDuration
        self.links = Links(Links.State(parts: parts, headers: headers, expiresAt: nil))
    }

    /// This layout, read with links that expire at `expiresAt` and are found again through
    /// `refresh` once refused or expired.
    func refreshing(_ refresh: Refresh?, expiresAt: Date?) -> SegmentedAudioSource {
        var copy = self
        copy.refresh = refresh
        copy.links = Links(Links.State(parts: parts, headers: headers, expiresAt: expiresAt))
        return copy
    }

    var contentLength: Int64 { parts.last.map { $0.offset + $0.length } ?? Int64(initialization.count) }

    var statedContentLength: Int64? { contentLength }

    /// How much of each segment's opening is read to find its `moof`: `styp` and `sidx` together
    /// are well under a hundred bytes.
    static let headBytes: Int64 = 1_024
    /// How many segments are sized at once. High on purpose: the requests are a kilobyte each and
    /// share one HTTP/2 connection, so a four-minute track's sixty-odd segments are sized in about
    /// a round trip rather than eight — the start waits on this.
    static let concurrency = 64
    /// How long a segment's read gets to show progress. A new request gets past a stuck answer (one
    /// segment sat at 1.75 MB of 2.54 MB for five minutes while the next arrived in under a second),
    /// and it costs a round trip, so this is short: 10 s is a long gap for a player waiting
    /// on its first audio, and long enough for a slow first byte on a busy link.
    static let stallWindow: Duration = .seconds(10)
    /// What a window has to bring or the read is cut: 16 kB/s, 128 kbps. URLSession's limit is 30 s
    /// between bytes, which a trickle never reaches. Fixed rather than a share of the stream's
    /// bitrate: an add-on's segmented copies are lossless or Atmos, several times this, and a
    /// hi-res copy's share could exceed a link that is merely slow. Cut on such a link, a read loses
    /// a round trip and nothing it received.
    static let stallFloorBytes: Int64 = 160 * 1_024
    /// How many times one slice's read is cut before it fails as timed out. Three windows bringing
    /// nothing are the 30 s URLSession gave a dead read, so a dead link fails no later than before.
    /// The loader's retries then carry on from the byte reached (`serveBytes`).
    static let maxCuts = 2
    static let waitOutStallWindow: StallTimer = { try await Task.sleep(for: SegmentedAudioSource.stallWindow) }

    /// Whether `stream` is a playlist rather than one file.
    static func handles(_ stream: ResolvedStream) -> Bool {
        stream.isHLS || stream.url.scheme == "vibramusic-hls"
    }

    /// Lays `stream` out. Throws for a playlist that isn't fMP4 segments at whole URLs (MPEG-TS,
    /// encrypted, byte-range), or whose server doesn't answer ranges: the caller plays those the
    /// old way.
    static func make(
        _ stream: ResolvedStream,
        playlistText: @Sendable (URL, [String: String]) async throws -> String,
        fetch: @escaping Fetch,
        readSegment: ReadSegment? = nil,
        stallTimer: @escaping StallTimer = SegmentedAudioSource.waitOutStallWindow
    ) async throws -> SegmentedAudioSource {
        var url = stream.url
        var urls: [URL] = []
        var durations: [Double] = []
        // One level of indirection at most: a master playlist names media playlists.
        for _ in 0..<2 where urls.isEmpty {
            let text = try await playlistText(url, stream.headers)
            switch try StreamPackage.parse(playlist: text, base: url) {
            case .segments(let found):
                urls = found
                durations = segmentSeconds(text)
            case .variant(let next): url = next
            }
        }
        guard urls.count > 1 else { throw SegmentedSourceError.unsupported("no segments") }
        let headers = stream.headers
        let initialization = try await fetch(urls[0], headers, nil).data
        // Checked the way the package saver checks it: a `moov`, and not MPEG-TS.
        _ = try StreamPackage.flatten(initialization, isInitialization: true)

        let media = Array(urls.dropFirst())
        var measured = [(skip: Int64, length: Int64)?](repeating: nil, count: media.count)
        try await withThrowingTaskGroup(of: (Int, Int64, Int64).self) { group in
            var next = 0
            func add() {
                guard next < media.count else { return }
                let index = next
                next += 1
                group.addTask {
                    let head = try await fetch(media[index], headers, 0..<headBytes)
                    guard let total = head.total, total > 0 else { throw SegmentedSourceError.unsupported("a segment's size isn't stated") }
                    let skip = try moofOffset(in: head.data)
                    return (index, skip, total - skip)
                }
            }
            for _ in 0..<concurrency { add() }
            while let (index, skip, length) = try await group.next() {
                measured[index] = (skip, length)
                add()
            }
        }
        let sizes = try measured.map { measure -> (skip: Int64, length: Int64) in
            guard let measure, measure.length > 0 else { throw SegmentedSourceError.unsupported("an empty segment") }
            return measure
        }
        var parts: [Part] = []
        var offset = Int64(initialization.count)
        for (index, size) in sizes.enumerated() {
            parts.append(Part(url: media[index], skip: size.skip, length: size.length, offset: offset))
            offset += size.length
        }
        // The playlist's figure when it states every segment's (a repeated URL is fetched once, a
        // tag may not parse), failing that the track's.
        let seconds = durations.count == media.count ? durations.reduce(0, +) : 0
        let known = seconds > 0 ? seconds : stream.durationSeconds.map(TimeInterval.init)
        return SegmentedAudioSource(initialization: initialization, parts: parts, headers: headers, fetch: fetch, readSegment: readSegment,
                                    stallTimer: stallTimer, knownDuration: known)
    }

    /// Each media segment's length from its `#EXTINF`, in playlist order.
    static func segmentSeconds(_ text: String) -> [Double] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.hasPrefix("#EXTINF:") else { return nil }
            return Double(line.dropFirst(8).prefix { $0 != "," }.trimmingCharacters(in: .whitespaces))
        }
    }

    /// Where the first `moof` starts in a segment's opening bytes.
    static func moofOffset(in head: Data) throws -> Int64 {
        let bytes = [UInt8](head)
        var offset = 0
        while offset + 8 <= bytes.count {
            let size = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            if bytes[offset + 4...offset + 7].elementsEqual("moof".utf8) { return Int64(offset) }
            // A 64-bit or open-ended box before the first fragment: not a shape this reads.
            guard size >= 8 else { break }
            offset += size
        }
        throw SegmentedSourceError.unsupported("no moof in a segment's first \(bytes.count) bytes")
    }

    // MARK: AudioRangeDataSource

    func expectContentLength(_ length: Int64?) {
        expected.value = length
    }

    func contentInfo() async throws -> AudioContentInfo {
        AudioContentInfo(contentLength: contentLength, mimeType: "audio/mp4")
    }

    func read(_ range: Range<Int64>) async throws -> Data {
        var out = Data()
        for try await piece in stream(range) { out.append(piece) }
        return out
    }

    func stream(_ range: Range<Int64>) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let expected = expected.value, expected != contentLength {
                        throw AudioCacheError.contentChanged(key: nil, expected: expected, actual: contentLength)
                    }
                    let wanted = range.clamped(to: 0..<contentLength)
                    let opening = wanted.clamped(to: 0..<Int64(initialization.count))
                    if !opening.isEmpty {
                        continuation.yield(initialization.subdata(in: Int(opening.lowerBound)..<Int(opening.upperBound)))
                    }
                    for index in parts.indices where parts[index].offset < wanted.upperBound && parts[index].offset + parts[index].length > wanted.lowerBound {
                        // Found again at most once per segment for a refusal, as an HTTP copy is
                        // once per range, and apart from that once for links past their expiry: as
                        // for an HTTP copy, links renewed for their expiry can still be refused.
                        var renewedForExpiry = false
                        var renewedForRefusal = false
                        let slice = wanted.clamped(to: parts[index].offset..<(parts[index].offset + parts[index].length))
                        let progress = ReadProgress()
                        let started = ContinuousClock.now
                        var cuts = 0
                        while progress.arrived < Int64(slice.count) {
                            try Task.checkCancellation()
                            var current = links.state
                            if refresh != nil, !renewedForExpiry, current.isExpired {
                                renewedForExpiry = true
                                current = try await renew(from: current)
                            }
                            let part = current.parts[index]
                            let before = progress.arrived
                            // Only what hasn't arrived: never the bytes an earlier attempt brought.
                            let rest = (slice.lowerBound + before - part.offset + part.skip)..<(slice.upperBound - part.offset + part.skip)
                            do {
                                try await readWatching(part.url, current.headers, rest, progress) { continuation.yield($0) }
                                // A cancelled read ends quietly, which mustn't pass for an early end.
                                try Task.checkCancellation()
                                // An answer that ended early is asked for the rest; one that brought
                                // nothing never will.
                                guard progress.arrived > before else {
                                    throw SegmentedSourceError.unsupported("a segment answered \(before) of \(slice.count) bytes")
                                }
                            } catch is StalledRead {
                                cuts += 1
                                let reached = slice.lowerBound + progress.arrived
                                guard cuts <= Self.maxCuts else {
                                    TrackLog.d("AudioCache", "segment \(index) stalled at \(reached) of [\(slice.lowerBound), \(slice.upperBound)); giving up after \(Self.maxCuts) cuts")
                                    throw URLError(.timedOut)
                                }
                                TrackLog.d("AudioCache", "segment \(index) stalled at \(reached) of [\(slice.lowerBound), \(slice.upperBound)); cut \(cuts) of \(Self.maxCuts), asking for the rest")
                            } catch AudioCacheError.httpStatus(let code, _) where refresh != nil && !renewedForRefusal && HTTPAudioSource.refusalCodes.contains(code) {
                                TrackLog.d("AudioCache", "segment \(index) refused (\(code)); finding the stream again")
                                renewedForRefusal = true
                                _ = try await renew(from: current)
                            }
                        }
                        if cuts > 0 {
                            TrackLog.d("AudioCache", "segment \(index) [\(slice.lowerBound), \(slice.upperBound)) arrived after \(cuts) \(cuts == 1 ? "cut" : "cuts"), \(TrackLog.ms(since: started))ms")
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `range` read and handed to `deliver` as it arrives, under a watch: a window that brings under
    /// ``stallFloorBytes`` ends the read and throws ``StalledRead``. Both tasks are done when this
    /// returns, so `progress` is final and nothing is delivered behind the next attempt's back.
    private func readWatching(_ url: URL, _ headers: [String: String], _ range: Range<Int64>, _ progress: ReadProgress,
                              deliver: @escaping @Sendable (Data) -> Void) async throws {
        let readSegment = readSegment, stallTimer = stallTimer
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await readSegment(url, headers, range) { piece in
                    progress.add(Int64(piece.count))
                    deliver(piece)
                }
            }
            group.addTask {
                while true {
                    try await stallTimer()
                    if progress.takeWindow() < SegmentedAudioSource.stallFloorBytes { throw StalledRead() }
                }
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private struct StalledRead: Error {}

    /// How far one slice's read has come, across its attempts.
    private final class ReadProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var total: Int64 = 0
        private var window: Int64 = 0

        var arrived: Int64 { lock.withLock { total } }

        func add(_ count: Int64) {
            lock.withLock {
                total += count
                window += count
            }
        }

        /// The bytes since the last call.
        func takeWindow() -> Int64 {
            lock.withLock {
                defer { window = 0 }
                return window
            }
        }
    }

    /// The links after the stream is found again, unless another read already has. Only a layout
    /// the same as this one carries on: the same init segment, and every segment the same size at
    /// the same place. All of it, not only up to the byte reached: the entry's recorded length is
    /// this layout's, so one that differs further on is another file too. Anything else fails the
    /// read rather than splicing two copies, and the player falls back to YouTube.
    private func renew(from stale: Links.State) async throws -> Links.State {
        guard let refresh else { return stale }
        let initialization = initialization, parts = parts, length = contentLength
        return try await links.renew(from: stale) {
            let fresh = try await refresh()
            guard fresh.initialization == initialization,
                  fresh.parts.map({ [$0.offset, $0.length] }) == parts.map({ [$0.offset, $0.length] }) else {
                TrackLog.d("AudioCache", "segmented stream found again with another layout; not spliced")
                throw AudioCacheError.contentChanged(key: nil, expected: length, actual: fresh.contentLength)
            }
            return fresh.links.state
        }
    }

    /// The segment links in use, shared by every read of one source.
    private final class Links: @unchecked Sendable {
        struct State: Sendable {
            let parts: [Part]
            let headers: [String: String]
            let expiresAt: Date?
            /// Bumped by each renewal, so a read that saw stale links can tell another read
            /// already replaced them.
            var generation = 0

            /// Past the stream's expiry, with the margin ``ResolvedStream/isExpired(at:margin:)`` keeps.
            var isExpired: Bool { expiresAt.map { Date().addingTimeInterval(60) >= $0 } ?? false }
        }

        private let lock = NSLock()
        private var current: State
        private var renewing: Task<State, Error>?

        init(_ state: State) { current = state }

        var state: State { lock.withLock { current } }

        func renew(from stale: State, with work: @escaping @Sendable () async throws -> State) async throws -> State {
            let task: Task<State, Error> = lock.withLock {
                if current.generation != stale.generation {
                    let now = current
                    return Task { now }
                }
                if let renewing { return renewing }
                let task = Task { try await work() }
                renewing = task
                return task
            }
            do {
                var fresh = try await task.value
                return lock.withLock {
                    if renewing == task {
                        renewing = nil
                        fresh.generation = current.generation + 1
                        current = fresh
                    }
                    return current
                }
            } catch {
                lock.withLock { if renewing == task { renewing = nil } }
                throw error
            }
        }
    }
}

final class LockedLength: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int64?
    var value: Int64? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

struct SegmentedSourceError: Error, CustomStringConvertible {
    let description: String
    static func unsupported(_ why: String) -> SegmentedSourceError { SegmentedSourceError(description: why) }
}

/// The laid-out sources for the streams in play, so a stream opened twice (an upgrade's silent
/// proof, then its swap; a retry) is sized once.
final class SegmentedSources: @unchecked Sendable {
    private let lock = NSLock()
    /// By stream URL, for as long as the stream itself is used (``ReadAheadStreams/freshness``):
    /// an upgrade's silent proof and its swap open the same stream seconds apart, and a skip to a
    /// track read ahead minutes earlier plays the stream read-ahead found, so it is laid out once.
    /// Keyed by the playlist's text too: a converted playlist keeps its URL when it is rewritten
    /// with fresh segment links or another representation (the Atmos switch changed), and a layout
    /// must not outlive the links it was made from. Never past the expiry of the stream it was
    /// made from either, as for ``ReadAheadStreams``. Its age counts from when it started, not from
    /// when it landed: the links in it are no younger for having taken long to size.
    private var building: [Layout: (task: Task<SegmentedAudioSource?, Never>, at: ContinuousClock.Instant, stream: ResolvedStream, token: UUID)] = [:]
    private struct Layout: Hashable {
        let url: URL
        let playlist: String?
    }
    static let reuseFor: Duration = .seconds(ReadAheadStreams.freshness)
    /// Longest a start waits for the layout before playing the stream the old way. Only the wait
    /// ends here: the layout goes on and is kept. On a saturated link one can take longer than this,
    /// and cancelled, it started again from nothing at each open and never landed.
    static let layoutDeadline: Duration = .seconds(8)
    /// How often a row nobody is listening to yet looks at whether somebody has started to.
    private static let listeningPoll: Duration = .milliseconds(150)
    private let playlistText: @Sendable (URL, [String: String]) async throws -> String
    private let fetch: SegmentedAudioSource.Fetch
    private let readSegment: SegmentedAudioSource.ReadSegment?
    private let stallTimer: SegmentedAudioSource.StallTimer
    private let now: @Sendable () -> ContinuousClock.Instant
    private let deadline: Duration

    init(
        playlistText: @escaping @Sendable (URL, [String: String]) async throws -> String,
        fetch: @escaping SegmentedAudioSource.Fetch,
        readSegment: SegmentedAudioSource.ReadSegment? = nil,
        stallTimer: @escaping SegmentedAudioSource.StallTimer = SegmentedAudioSource.waitOutStallWindow,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        layoutDeadline: Duration = SegmentedSources.layoutDeadline
    ) {
        self.playlistText = playlistText
        self.fetch = fetch
        self.readSegment = readSegment
        self.stallTimer = stallTimer
        self.now = now
        self.deadline = layoutDeadline
    }

    /// Over HTTP, with converted playlists read through `localPlaylist`.
    convenience init(session: URLSession, localPlaylist: @escaping @Sendable (URL) -> String?,
                     stallTimer: @escaping SegmentedAudioSource.StallTimer = SegmentedAudioSource.waitOutStallWindow) {
        @Sendable func request(_ url: URL, _ headers: [String: String], _ range: Range<Int64>?) -> URLRequest {
            var request = URLRequest(url: url)
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            if let range {
                request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
                if request.value(forHTTPHeaderField: "Accept-Encoding") == nil {
                    // Byte offsets must mean bytes of the file, not of a compressed transfer.
                    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                }
            }
            return request
        }
        self.init(playlistText: { url, headers in
            if let local = localPlaylist(url) { return local }
            let (data, response) = try await session.data(for: request(url, headers, nil))
            guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else { throw URLError(.badServerResponse) }
            return String(decoding: data, as: UTF8.self)
        }, fetch: { url, headers, range in
            let (data, response) = try await session.data(for: request(url, headers, range))
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            // A refusal by status, which says the segment's link went stale (see `stream(_:)`).
            guard (200..<300).contains(http.statusCode) else { throw AudioCacheError.httpStatus(http.statusCode, url: url) }
            guard let range else { return (data, Int64(data.count)) }
            if http.statusCode == 206 {
                // "bytes 0-1023/52311": the size after the slash.
                let total = http.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap { Int64($0) }
                return (data, total)
            }
            // The server ignored the range and sent the whole segment.
            let whole = Int64(data.count)
            let slice = range.clamped(to: 0..<whole)
            return (data.subdata(in: Int(slice.lowerBound)..<Int(slice.upperBound)), whole)
        }, readSegment: { url, headers, range, deliver in
            // How HTTPAudioSource streams a range. Ending this loop cancels the request.
            var unwanted: Int64 = 0
            var left = Int64(range.count)
            for try await event in HTTPAudioSource.events(for: request(url, headers, range), session: session) {
                switch event {
                case .response(let http):
                    // A refusal by status, which says the segment's link went stale (see `stream(_:)`).
                    guard (200..<300).contains(http.statusCode) else { throw AudioCacheError.httpStatus(http.statusCode, url: url) }
                    // A captive portal's page is not this segment, and must not reach the disk.
                    if HTTPAudioSource.isWebPage(http) { throw AudioCacheError.badResponse("a web page, not audio (a captive portal?) from \(url.host() ?? "a segment")") }
                    if http.statusCode == 206 {
                        guard HTTPAudioSource.parseContentRange(http.value(forHTTPHeaderField: "Content-Range") ?? "")?.start == range.lowerBound else {
                            throw AudioCacheError.badResponse("a segment's answer doesn't start at \(range.lowerBound)")
                        }
                    } else {
                        // The server ignored the range and is sending the whole segment.
                        unwanted = range.lowerBound
                        if unwanted > 0 { TrackLog.d("AudioCache", "a segment's server ignored its range: \(unwanted) bytes downloaded again") }
                    }
                case .data(let raw):
                    let dropped = min(unwanted, Int64(raw.count))
                    unwanted -= dropped
                    let piece = raw.dropFirst(Int(dropped)).prefix(Int(left))
                    if !piece.isEmpty {
                        left -= Int64(piece.count)
                        deliver(Data(piece))
                    }
                    if left == 0 { return }
                }
            }
        }, stallTimer: stallTimer)
    }

    /// The laid-out source for `stream`, or nil when it can't be one file (the caller plays it as
    /// a playlist, uncached, as before). With `refresh`, links refused or past the stream's expiry
    /// mid-read are found again: the stream resolved and laid out anew, and the read resumed where
    /// it was if the layout is the same (see ``SegmentedAudioSource/refreshing(_:expiresAt:)``).
    ///
    /// ``layoutDeadline`` counts from when `listening` says somebody is waiting to hear the stream.
    /// Until then the wait lasts as long as the layout does: an open settled on the playlist stays
    /// on it for the whole play, however soon the layout lands after it.
    func source(for stream: ResolvedStream, refresh: HTTPAudioSource.Resolver? = nil,
                listening: @Sendable () async -> Bool = { true }) async -> SegmentedAudioSource? {
        guard let source = await layout(for: stream, listening: listening) else { return nil }
        var again: SegmentedAudioSource.Refresh?
        if let refresh {
            again = {
                let fresh = try await refresh()
                // Laid out anew even under the same key: a remote playlist keeps its URL when only
                // the segment links inside it are signed again, and the layout kept for it holds the
                // links that just went stale.
                guard SegmentedAudioSource.handles(fresh), let source = await self.layout(for: fresh, reuse: false) else {
                    throw SegmentedSourceError.unsupported("the stream found again can't be laid out")
                }
                return source.refreshing(nil, expiresAt: fresh.expiresAt)
            }
        }
        return source.refreshing(again, expiresAt: stream.expiresAt)
    }

    private func layout(for stream: ResolvedStream, reuse: Bool = true, listening: @Sendable () async -> Bool = { true }) async -> SegmentedAudioSource? {
        // A converted playlist is a file on this device, rewritten in place: read now (at no cost)
        // to tell a rewrite from the one laid out, and handed to the layout so it isn't read twice.
        // A remote playlist is keyed by its URL alone, which a fresh resolution signs anew.
        let playlistText = self.playlistText
        let text = stream.url.scheme == "vibramusic-hls" ? try? await playlistText(stream.url, stream.headers) : nil
        let layout = Layout(url: stream.url, playlist: text)
        let task: Task<SegmentedAudioSource?, Never> = lock.withLock {
            let now = self.now()
            building = building.filter { now - $0.value.at < Self.reuseFor && !$0.value.stream.isExpired() }
            if reuse, let running = building[layout] { return running.task }
            let fetch = self.fetch, readSegment = self.readSegment, stallTimer = self.stallTimer
            let token = UUID()
            // Its own task, which no waiter's deadline or skip cancels.
            let task = Task<SegmentedAudioSource?, Never> {
                let started = ContinuousClock.now
                do {
                    let source = try await SegmentedAudioSource.make(stream, playlistText: { url, headers in
                        if url == stream.url, let text { return text }
                        return try await playlistText(url, headers)
                    }, fetch: fetch, readSegment: readSegment, stallTimer: stallTimer)
                    TrackLog.d("AudioCache", "segmented stream laid out: \(source.parts.count) segments, \(source.contentLength) bytes, "
                        + "\(TrackLog.ms(since: started))ms")
                    return source
                } catch {
                    TrackLog.d("AudioCache", "segmented stream plays uncached: \(error)")
                    // A failure isn't remembered: the next open tries again.
                    self.lock.withLock {
                        if self.building[layout]?.token == token { self.building[layout] = nil }
                    }
                    return nil
                }
            }
            building[layout] = (task, now, stream, token)
            return task
        }
        return await waited(for: task, listening: listening)
    }

    /// What `task` lands on, or nil once somebody has been listening for ``deadline`` (or the caller
    /// is cancelled). Only this wait ends: the layout runs on for the next open.
    private func waited(for task: Task<SegmentedAudioSource?, Never>, listening: @Sendable () async -> Bool) async -> SegmentedAudioSource? {
        let landed = { @Sendable () async -> SegmentedAudioSource?? in .some(await task.value) }
        while !Task.isCancelled, await !listening() {
            if let answer = await withDeadline(Self.listeningPoll, landed) { return answer }
        }
        let started = ContinuousClock.now
        if let answer = await withDeadline(deadline, landed) { return answer }
        if !Task.isCancelled {
            TrackLog.d("AudioCache", "segmented stream plays uncached after \(TrackLog.ms(since: started))ms; its layout goes on for the next open")
        }
        return nil
    }
}
