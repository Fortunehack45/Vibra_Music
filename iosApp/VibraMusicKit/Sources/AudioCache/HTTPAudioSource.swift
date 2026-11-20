import Foundation
import VibraMusicCore

// Ports playback/ChunkedDataSource.kt, PlayerClient.rangeBytesFor and the refusal hand-back to
// StreamResolver.onPlaybackRefused.

/// An HTTP(S) stream as a byte source, fetched as a run of bounded ranges instead of one
/// open-ended read.
///
/// googlevideo paces a continuous response down to roughly playback speed: ask for a whole track in
/// one request and it arrives at about 15 kB/s, barely ahead of the rate it is being consumed at.
/// Ask for the same bytes as bounded ranges and each one is served at line rate — measured on the
/// same track, over the same connection, seconds apart:
///
/// ```
///   GET (unbounded)               15.5 kB/s
///   Range: bytes=0-2097151         5.7 MB/s
/// ```
///
/// That is the difference between a player that can build a buffer and one that can only just keep
/// up. So every request this makes is at most ``defaultChunkBytes`` long, narrowed per client by
/// ``rangeBytes(for:)`` (googlevideo refuses ANDROID_VR and TVHTML5_SIMPLY ranges past 512 KB).
/// Longer asks are split, so no caller can exceed the limit. Hosts other than googlevideo aren't
/// throttled that way and get one request per ask, as Android forwarded them unchanged.
///
/// **Headers.** Every request carries the stream's ``ResolvedStream/headers``: googlevideo compares
/// the client baked into the URL with the request fetching the bytes, and throttles or refuses a
/// mismatch; WebDAV needs its Authorization.
///
/// **Expired and refused URLs.** Resolved URLs expire and get re-minted. Every refused range is
/// reported to `onRefused` with its status — the one piece of evidence a resolver needs to retire
/// the client that minted it (StreamResolver's `onPlaybackRefused(url:statusCode:)` fits as is) —
/// and when the status says the URL itself is dead (403, 404, 410) and a resolver closure was
/// given, the URL is re-minted and the range asked again, once per range. A URL already past its `expire` is re-minted before use. A
/// re-minted URL that names a file of a different length throws
/// ``AudioCacheError/contentChanged(key:expected:actual:)`` rather than splicing two encodings.
///
/// **Lazy resolving.** Built with ``init(session:chunkBytes:onRefused:resolve:)`` the URL is only
/// resolved when bytes are actually missing, so a track the cache already holds never costs a
/// resolve (on Android the cache sat outside the resolving data source for the same reason).
public final class HTTPAudioSource: AudioRangeDataSource, @unchecked Sendable {
    public typealias Resolver = @Sendable () async throws -> ResolvedStream
    public typealias RefusalHandler = @Sendable (_ url: URL, _ statusCode: Int) -> Void

    /// Upper bound per googlevideo range (Android's `STREAM_CHUNK_BYTES`); ``rangeBytes(for:)``
    /// narrows it per client.
    public static let defaultChunkBytes: Int64 = 1_024 * 1_024
    /// Statuses that mean "this URL is no good any more" rather than "try later".
    public static let refusalCodes: Set<Int> = [403, 404, 410]
    /// Enough to ride out a truncated range, not enough to hang on a dead one.
    static let maxEmptyRanges = 3
    /// How much a length/type probe asks for when the resolver didn't say. Kept and served as the
    /// start of the first read, so the probe isn't wasted.
    public static let probeBytes: Int64 = 256 * 1_024

    private static let wideRangeBytes: Int64 = 1_024 * 1_024
    private static let narrowRangeBytes: Int64 = 512 * 1_024

    /// Largest single range googlevideo reliably serves for `url`'s client (the `c` query
    /// parameter); unlimited for other hosts. Mirrors InnerTubeX's `mediaRangeChunkSize`.
    public static func rangeBytes(for url: URL) -> Int64 {
        guard let host = url.host()?.lowercased(), host.hasSuffix("googlevideo.com") else { return .max }
        let client = queryValue("c", in: url)?.uppercased()
        if client == "ANDROID_VR" || client?.hasPrefix("TVHTML5_SIMPLY") == true {
            return narrowRangeBytes
        }
        return wideRangeBytes
    }

    /// A page, not media: what a captive portal sends in place of whatever was asked for.
    public static func isWebPage(_ response: HTTPURLResponse) -> Bool {
        guard let type = response.mimeType?.lowercased() else { return false }
        return type == "text/html" || type == "application/xhtml+xml"
    }

    /// Nothing but spaces so far (fewer than the 64 bytes the opening is judged on).
    static func isBlank(opening data: Data) -> Bool {
        data.count < 64 && String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
            .isEmpty
    }

    /// The same, from how the body opens, for a portal that doesn't say what it is sending. No
    /// audio stream opens with `<` (an MP4 box size, ID3, an MPEG frame, `fLaC`, `OggS`, `RIFF`),
    /// and every page or XML document does.
    static func isWebPage(opening data: Data) -> Bool {
        String(decoding: data.prefix(64), as: UTF8.self)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
            .hasPrefix("<")
    }

    /// googlevideo's `clen`: the total size, carried by every progressive URL, free to read.
    public static func declaredLength(of url: URL) -> Int64? {
        queryValue("clen", in: url).flatMap { Int64($0) }
    }

    fileprivate let session: URLSession
    private let chunkBytes: Int64
    private let resolver: Resolver?
    fileprivate let onRefused: RefusalHandler?

    private let lock = NSLock()
    private var current: ResolvedStream?
    private var resolving: Task<ResolvedStream, Error>?
    private var knownLength: Int64?
    /// The length the cache recorded for the entry being filled (``expectContentLength(_:)``).
    private var expectedLength: Int64?
    private var primed: (start: Int64, data: Data)?
    private var rangesUnsupported = false
    /// Every range requested, for tests and the nerd-stats log.
    private var requestLog: [Range<Int64>] = []

    /// A stream already resolved. `refresh` re-mints it when refused or expired.
    public init(
        stream: ResolvedStream,
        session: URLSession = VibraMusicHTTP.session,
        chunkBytes: Int64 = HTTPAudioSource.defaultChunkBytes,
        refresh: Resolver? = nil,
        onRefused: RefusalHandler? = nil
    ) {
        self.session = session
        self.chunkBytes = max(1, chunkBytes)
        self.resolver = refresh
        self.onRefused = onRefused
        self.current = stream
        self.knownLength = stream.contentLength ?? Self.declaredLength(of: stream.url)
    }

    /// A stream resolved on first use (and again when refused or expired).
    public init(
        session: URLSession = VibraMusicHTTP.session,
        chunkBytes: Int64 = HTTPAudioSource.defaultChunkBytes,
        onRefused: RefusalHandler? = nil,
        resolve: @escaping Resolver
    ) {
        self.session = session
        self.chunkBytes = max(1, chunkBytes)
        self.resolver = resolve
        self.onRefused = onRefused
    }

    /// The stream currently in use, if one has been resolved.
    public var resolvedStream: ResolvedStream? { lock.withLock { current } }

    public func expectContentLength(_ length: Int64?) {
        lock.withLock { expectedLength = length }
    }

    /// What the stream in hand says, never a response's total: a source still to resolve states nothing.
    public var statedContentLength: Int64? {
        lock.withLock { current.flatMap { $0.contentLength ?? Self.declaredLength(of: $0.url) } }
    }

    var requestedRanges: [Range<Int64>] { lock.withLock { requestLog } }

    // MARK: AudioRangeDataSource

    /// Unlimited: this source bounds its own requests (see the type's documentation), so the cache
    /// can ask for a whole hole and stop reading when it has enough.
    public var maxRangeBytes: Int64 { .max }

    /// True once a YouTube stream is resolved (false before the first resolve, when there is
    /// nothing to judge yet; every use of the flag happens after bytes have started flowing, by
    /// which time the stream is resolved). YouTube's Opus renditions pass through the same flag
    /// and are unaffected: with no `moov` the patch changes nothing.
    public var requiresYouTubeDurationFix: Bool {
        lock.withLock { current?.origin == .youtube }
    }

    /// The range size requests are split into for the current URL (`Int64.max`: not split).
    public var requestRangeBytes: Int64 {
        guard let url = lock.withLock({ current?.url }) else { return chunkBytes }
        return splitBytes(for: url)
    }

    /// googlevideo is the host that paces unbounded responses, so its URLs are split at
    /// `chunkBytes` narrowed per client. Anything else is asked for in one request, as Android
    /// forwarded it unchanged.
    fileprivate func splitBytes(for url: URL) -> Int64 {
        let cap = Self.rangeBytes(for: url)
        return cap == .max ? .max : min(chunkBytes, cap)
    }

    public func contentInfo() async throws -> AudioContentInfo {
        let stream = try await currentStream()
        guard !stream.isHLS else { throw AudioCacheError.notProgressive }
        let length = lock.withLock { knownLength }
        if let length, let mime = stream.mimeType {
            return AudioContentInfo(contentLength: length, mimeType: mime, contentType: AudioContentType.uti(mimeType: mime, pathExtension: stream.url.pathExtension))
        }
        // The resolver didn't say how long or what it is: ask for the opening and read both off
        // the response, keeping the bytes for the first read.
        let probeEnd = min(Self.probeBytes, min(chunkBytes, Self.rangeBytes(for: stream.url)), length ?? .max)
        let reader = RangeReader(source: self, range: 0..<probeEnd, usesPrimed: false)
        var data = Data()
        while let piece = try await reader.next() { data.append(piece) }
        lock.withLock { primed = (0, data) }
        guard let total = lock.withLock({ knownLength }) else {
            throw AudioCacheError.badResponse("no length for \(stream.url.host() ?? "stream")")
        }
        let mime = stream.mimeType ?? reader.responseMimeType
        let active = try await currentStream()
        return AudioContentInfo(contentLength: total, mimeType: mime, contentType: AudioContentType.uti(mimeType: mime, pathExtension: active.url.pathExtension))
    }

    public func read(_ range: Range<Int64>) async throws -> Data {
        var data = Data()
        for try await piece in stream(range) { data.append(piece) }
        return data
    }

    /// `range` a bounded request at a time, and pull-driven like `ChunkedDataSource.read`: the
    /// next range is only asked for once the reader wants bytes past the current one. A reader
    /// that stops at a range boundary (the cache reaching the end of what it planned to fetch)
    /// therefore never opens a request it would cancel straight away, and one that stops
    /// mid-range cancels that request.
    public func stream(_ range: Range<Int64>) -> AsyncThrowingStream<Data, Error> {
        let reader = RangeReader(source: self, range: range, usesPrimed: true)
        return AsyncThrowingStream(unfolding: { try await reader.next() })
    }

    // MARK: Chunking

    /// Reads one span of the stream as a run of bounded ranges.
    ///
    /// A range that ends early is re-opened for the part that didn't arrive, which is also how the
    /// step to the next range happens. ``maxEmptyRanges`` in a row with nothing in them ends the
    /// read: that is what stops a server that has decided to send nothing from spinning here
    /// forever. Used by one consumer at a time (the unfolding stream calls `next()` serially).
    private final class RangeReader: @unchecked Sendable {
        private struct Chunk {
            let url: URL
            let start: Int64
            /// Where this request's bytes stop being wanted.
            var end: Int64
            var delivered: Int64 = 0
            /// Bytes to drop off the front: a server that ignored the range sends from byte 0.
            var skip: Int64 = 0
        }

        private let source: HTTPAudioSource
        private let end: Int64
        private let usesPrimed: Bool
        private var position: Int64
        private var chunk: Chunk?
        private var events: AsyncThrowingStream<Event, Error>.Iterator?
        private var emptyInARow = 0
        /// The range start whose refusal was already answered with a re-mint: once per range, not
        /// forever.
        private var reMintedAt: Int64?
        private var done = false
        private(set) var responseMimeType: String?
        /// The file's first bytes, held back while they are only spaces: an opening split across
        /// reads must still be judged whole.
        private var opening = Data()

        init(source: HTTPAudioSource, range: Range<Int64>, usesPrimed: Bool) {
            self.source = source
            self.position = range.lowerBound
            self.end = range.upperBound
            self.usesPrimed = usesPrimed
        }

        func next() async throws -> Data? {
            while !done {
                try Task.checkCancellation()
                if position >= end {
                    break
                }
                guard chunk != nil, var iterator = events else {
                    if usesPrimed, let head = source.takePrimed(at: position, end: end) {
                        position += Int64(head.count)
                        return head
                    }
                    if emptyInARow >= HTTPAudioSource.maxEmptyRanges { break }
                    try await open()
                    continue
                }
                let event = try await iterator.next()
                events = iterator
                guard let event else {
                    // The request ended; a short one is reopened for the rest on the next pass.
                    let delivered = chunk?.delivered ?? 0
                    closeChunk()
                    emptyInARow = delivered == 0 ? emptyInARow + 1 : 0
                    if let total = source.lengthIfKnown, position >= total { break }
                    continue
                }
                switch event {
                case .response(let response):
                    try await handle(response)
                case .data(let raw):
                    var piece = raw
                    if position == 0 {
                        // The file's opening is never markup: a captive portal's page, however it
                        // is labelled and whatever length it states, is refused before it is kept.
                        // No audio opens with spaces, so holding them back delays nothing.
                        opening.append(raw)
                        if HTTPAudioSource.isBlank(opening: opening) { continue }
                        piece = opening
                        opening = Data()
                        if HTTPAudioSource.isWebPage(opening: piece) {
                            let host = chunk?.url.host() ?? "stream"
                            source.forgetRefusedLength()
                            closeChunk()
                            throw AudioCacheError.badResponse("a web page, not audio (a captive portal?) from \(host)")
                        }
                    }
                    if let data = take(piece) { return data }
                }
            }
            done = true
            closeChunk()
            return nil
        }

        private func open() async throws {
            let stream = try await source.currentStream()
            let limit = source.rangesAreIgnored ? Int64.max : source.splitBytes(for: stream.url)
            let chunkEnd = limit >= end - position ? end : position + limit
            var request = URLRequest(url: stream.url)
            for (name, value) in stream.headers { request.setValue(value, forHTTPHeaderField: name) }
            if request.value(forHTTPHeaderField: "Accept-Encoding") == nil {
                // Byte offsets must mean bytes of the file, not of a compressed transfer.
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            }
            let openEnded = chunkEnd == .max
            request.setValue(openEnded ? "bytes=\(position)-" : "bytes=\(position)-\(chunkEnd - 1)", forHTTPHeaderField: "Range")
            source.logRequest(position..<chunkEnd)
            chunk = Chunk(url: stream.url, start: position, end: chunkEnd)
            events = HTTPAudioSource.events(for: request, session: source.session).makeAsyncIterator()
        }

        /// Dropping the iterator is what cancels an unfinished request.
        private func closeChunk() {
            chunk = nil
            events = nil
            opening = Data()  // held bytes belong to the request they came on
        }

        private func handle(_ response: HTTPURLResponse) async throws {
            guard var current = chunk else { return }
            responseMimeType = response.mimeType
            // A captive portal answers a plain-HTTP stream with its sign-in page. Taken as audio,
            // the page became the whole track on disk, served without asking again.
            if (200..<300).contains(response.statusCode), HTTPAudioSource.isWebPage(response) {
                closeChunk()
                throw AudioCacheError.badResponse("a web page, not audio (a captive portal?) from \(current.url.host() ?? "stream")")
            }
            switch response.statusCode {
            case 206:
                guard let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
                      let parsed = HTTPAudioSource.parseContentRange(contentRange) else {
                    throw AudioCacheError.badResponse("206 without a usable Content-Range")
                }
                guard parsed.start == current.start else {
                    throw AudioCacheError.badResponse("asked for \(current.start), got \(parsed.start)")
                }
                if let total = parsed.total { try source.checkLength(total) }
            case 200:
                // The server ignored the range and is sending the whole file. Take it from where
                // it's wanted, to the end of the whole read rather than of this range, and stop
                // splitting: every further range would be answered from byte zero again.
                source.noteRangesIgnored()
                current.skip = current.start
                current.end = end
                chunk = current
                if response.expectedContentLength > 0 { try source.checkLength(response.expectedContentLength) }
            case 416:
                // Nothing at or past this offset: the resource is shorter than asked.
                done = true
                closeChunk()
            case let code where HTTPAudioSource.refusalCodes.contains(code):
                // Which client minted the URL is the first thing worth knowing when a range is
                // refused, and it isn't recoverable from anywhere else by the time this surfaces
                // as a playback error.
                let url = current.url
                let client = HTTPAudioSource.queryValue("c", in: url) ?? url.host() ?? String(url.absoluteString.prefix(120))
                TrackLog.w(HTTPAudioSource.category, "range \(current.start)-\(current.end == .max ? "" : String(current.end - 1)) refused (\(code)) for \(client)")
                // This is the only place a refusal of the real fetch is seen. Handed back, it is
                // the one piece of evidence that retiring the client rests on.
                source.onRefused?(url, code)
                closeChunk()
                guard source.canReMint, reMintedAt != current.start else {
                    throw AudioCacheError.httpStatus(code, url: url)
                }
                reMintedAt = current.start
                _ = try await source.refresh(replacing: url)
            default:
                // Logged as Android's ChunkedDataSource logs every refused open (a 429, a 5xx), or the
                // track's log shows a failure with no word of who refused it.
                let url = current.url
                let client = HTTPAudioSource.queryValue("c", in: url) ?? url.host() ?? String(url.absoluteString.prefix(120))
                TrackLog.w(HTTPAudioSource.category, "range \(current.start)-\(current.end == .max ? "" : String(current.end - 1)) refused (\(response.statusCode)) for \(client)")
                // Handed back as Android's ChunkedDataSource did with every refused status: the
                // resolver is what decides whether a status says anything about the client.
                source.onRefused?(current.url, response.statusCode)
                closeChunk()
                throw AudioCacheError.httpStatus(response.statusCode, url: current.url)
            }
        }

        private func take(_ raw: Data) -> Data? {
            guard var current = chunk else { return nil }
            var piece = raw[...]
            if current.skip > 0 {
                let dropped = min(current.skip, Int64(piece.count))
                current.skip -= dropped
                piece = piece.dropFirst(Int(dropped))
            }
            let room = min(current.end, end) - position
            if Int64(piece.count) > room { piece = piece.prefix(Int(max(0, room))) }
            current.delivered += Int64(piece.count)
            position += Int64(piece.count)
            chunk = current
            if position >= min(current.end, end) {
                // All this request was for; anything else it sends is not wanted.
                closeChunk()
                emptyInARow = 0
            }
            return piece.isEmpty ? nil : Data(piece)
        }
    }

    // MARK: Shared state for readers

    fileprivate var rangesAreIgnored: Bool { lock.withLock { rangesUnsupported } }
    fileprivate func noteRangesIgnored() { lock.withLock { rangesUnsupported = true } }
    fileprivate var lengthIfKnown: Int64? { lock.withLock { knownLength } }
    fileprivate var canReMint: Bool { resolver != nil }
    fileprivate func logRequest(_ range: Range<Int64>) { lock.withLock { requestLog.append(range) } }

    /// A response refused as a page stated the page's length, not the track's: back to what the
    /// resolver said, so a later contentInfo asks again instead of answering with it.
    fileprivate func forgetRefusedLength() {
        lock.withLock { knownLength = current.flatMap { $0.contentLength ?? Self.declaredLength(of: $0.url) } }
    }

    fileprivate func checkLength(_ total: Int64) throws {
        let (known, expected): (Int64?, Int64?) = lock.withLock {
            // A total the entry refuses describes a file this source won't serve it; not recorded.
            if knownLength == nil, expectedLength == nil || expectedLength == total { knownLength = total }
            return (knownLength, expectedLength)
        }
        if let expected, expected != total {
            throw AudioCacheError.contentChanged(key: nil, expected: expected, actual: total)
        }
        if let known, known != total {
            throw AudioCacheError.contentChanged(key: nil, expected: known, actual: total)
        }
    }

    fileprivate func takePrimed(at position: Int64, end: Int64) -> Data? {
        lock.withLock {
            guard let primed, primed.start == position, !primed.data.isEmpty else { return nil }
            self.primed = nil
            let count = min(Int64(primed.data.count), end - position)
            return primed.data.prefix(Int(count))
        }
    }

    // MARK: Resolving

    fileprivate func currentStream() async throws -> ResolvedStream {
        let state: (stream: ResolvedStream?, task: Task<ResolvedStream, Error>?) = lock.withLock {
            if let current, resolver == nil || !current.isExpired() { return (current, nil) }
            return (nil, startResolve())
        }
        if let stream = state.stream { return stream }
        return try await finishResolve(state.task!)
    }

    /// Re-mints the URL after `url` was refused, unless someone already has.
    fileprivate func refresh(replacing url: URL) async throws -> ResolvedStream {
        let task: Task<ResolvedStream, Error> = lock.withLock {
            if let current, current.url != url, resolving == nil { return Task { current } }
            return startResolve()
        }
        return try await finishResolve(task)
    }

    /// Must be called with `lock` held.
    private func startResolve() -> Task<ResolvedStream, Error> {
        if let resolving { return resolving }
        guard let resolver else {
            let stale = current
            return Task {
                guard let stale else { throw AudioCacheError.badResponse("no stream and no resolver") }
                return stale
            }
        }
        let task = Task { try await resolver() }
        resolving = task
        return task
    }

    private func finishResolve(_ task: Task<ResolvedStream, Error>) async throws -> ResolvedStream {
        do {
            let stream = try await task.value
            let length = stream.contentLength ?? Self.declaredLength(of: stream.url)
            let (known, expected): (Int64?, Int64?) = lock.withLock {
                if resolving == task { resolving = nil }
                current = stream
                if knownLength == nil { knownLength = length }
                return (knownLength, expectedLength)
            }
            if let expected, let length, expected != length {
                throw AudioCacheError.contentChanged(key: nil, expected: expected, actual: length)
            }
            if let known, let length, known != length {
                throw AudioCacheError.contentChanged(key: nil, expected: known, actual: length)
            }
            return stream
        } catch {
            lock.withLock { if resolving == task { resolving = nil } }
            throw error
        }
    }

    // MARK: HTTP plumbing

    public enum Event {
        case response(HTTPURLResponse)
        case data(Data)
    }

    /// The request's response and body as they arrive, so a range can be handed on before it has
    /// finished downloading. Ending iteration cancels the request.
    public static func events(for request: URLRequest, session: URLSession) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = session.dataTask(with: request)
            task.delegate = EventDelegate(continuation)
            continuation.onTermination = { _ in task.cancel() }
            task.resume()
        }
    }

    private final class EventDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let continuation: AsyncThrowingStream<Event, Error>.Continuation

        init(_ continuation: AsyncThrowingStream<Event, Error>.Continuation) {
            self.continuation = continuation
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            guard let http = response as? HTTPURLResponse else {
                continuation.finish(throwing: AudioCacheError.badResponse("not an HTTP response"))
                completionHandler(.cancel)
                return
            }
            continuation.yield(.response(http))
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            continuation.yield(.data(data))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
    }

    /// `bytes 0-1023/5000` → (0, 1023, 5000); total is nil for `*`.
    public static func parseContentRange(_ header: String) -> (start: Int64, end: Int64, total: Int64?)? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes") else { return nil }
        let spec = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        let parts = spec.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let bounds = parts[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]), end >= start else { return nil }
        return (start, end, parts[1] == "*" ? nil : Int64(parts[1]))
    }

    static func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    static let category = "AudioCache"
}
