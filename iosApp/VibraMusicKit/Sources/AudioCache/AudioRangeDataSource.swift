import Foundation

/// What a byte source says about the resource it serves.
public struct AudioContentInfo: Codable, Hashable, Sendable {
    /// Total size in bytes.
    public var contentLength: Int64
    /// The MIME type as served (`audio/mp4; codecs="mp4a.40.2"`), when known.
    public var mimeType: String?
    /// The uniform type identifier AVFoundation is told (see ``AudioContentType``). When nil the
    /// cache derives it from ``mimeType`` or, failing that, sniffs the first bytes.
    public var contentType: String?

    public init(contentLength: Int64, mimeType: String? = nil, contentType: String? = nil) {
        self.contentLength = contentLength
        self.mimeType = mimeType
        self.contentType = contentType
    }
}

/// Where a track's bytes come from when they aren't on disk yet.
///
/// ``HTTPAudioSource`` covers googlevideo, addons and anything else reachable over HTTP. Other
/// schemes plug in by implementing this: SMB and WebDAV streaming from NetworkLibrary, for example,
/// need only a length, a type and a ranged read. The cache asks for ranges no larger than
/// ``maxRangeBytes``, writes what arrives to disk, and serves AVFoundation from there, so a source
/// never sees a request for bytes that are already cached.
///
/// Implementations must be safe to call concurrently (the player and read-ahead can both be
/// fetching different parts of one track) and should respond to task cancellation.
public protocol AudioRangeDataSource: Sendable {
    /// Total length and type. Called once per entry that has no recorded length yet; may do I/O.
    func contentInfo() async throws -> AudioContentInfo

    /// The bytes in `range`. Returning fewer only means the resource ended early.
    func read(_ range: Range<Int64>) async throws -> Data

    /// `range` as a sequence of pieces, so the player can be fed while a range is still arriving.
    /// The default yields ``read(_:)`` in one piece; sources that can stream should.
    func stream(_ range: Range<Int64>) -> AsyncThrowingStream<Data, Error>

    /// The largest range the cache asks for at once. Default 1 MB.
    var maxRangeBytes: Int64 { get }

    /// Whether the bytes from this source are a YouTube fragmented-MP4 stream (itag 139/140
    /// shape) whose declared durations must be zeroed before AVFoundation sees them, or the
    /// cache stores them, via StreamResolution's `YouTubeMP4InitSegment.patchDurations(in:)`.
    /// AVFoundation reads the whole-track duration YouTube declares in the `moov` *in addition
    /// to* the fragments and reports about twice the length; zeroing the declaration makes it
    /// take the duration from the fragments alone.
    ///
    /// Only YouTube-origin streams set this. The zeroing applies to any `moov` it finds, so it
    /// must never run on an ordinary file, whose `moov` declares its real length — the cache
    /// additionally checks for the fragmented marker (`mvex`) first. Default false: bytes are
    /// stored and served byte-identical.
    var requiresYouTubeDurationFix: Bool { get }

    /// The whole length when the source knows it before the bytes are in: a segmented copy's
    /// playlist states it, while AVFoundation, reading a fragmented file, counts only the fragments
    /// that have arrived. The player shows this while AVFoundation says less (see
    /// ``AudioStreamCache/knownDuration(of:)``). Default nil: AVFoundation's figure stands.
    var knownDuration: TimeInterval? { get }

    /// Whether bytes from this source are worth writing to disk. A file already on this device is
    /// not: caching it would only be a redundant copy.
    var isCacheable: Bool { get }

    /// The length the cache already recorded for the entry this source is about to fill, or nil
    /// when it is asking afresh. A source that sees the totals of its responses must refuse one
    /// for a file of another length with ``AudioCacheError/contentChanged(key:expected:actual:)``:
    /// otherwise a different rendition under the same key fills the old file's holes.
    /// Default: nothing to compare.
    func expectContentLength(_ length: Int64?)

    /// The whole length the source already states without a request (a playlist's layout, a
    /// stream's stated or `clen` length), or nil. The cache checks it against the entry before it
    /// answers from disk: another length is another file under the same key. Default nil.
    var statedContentLength: Int64? { get }
}

extension AudioRangeDataSource {
    public func expectContentLength(_ length: Int64?) {}

    public func stream(_ range: Range<Int64>) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let data = try await read(range)
                    if !data.isEmpty { continuation.yield(data) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public var maxRangeBytes: Int64 { 1_024 * 1_024 }

    public var requiresYouTubeDurationFix: Bool { false }

    public var knownDuration: TimeInterval? { nil }

    public var isCacheable: Bool { true }

    public var statedContentLength: Int64? { nil }
}

/// A file on this device as a byte source: downloads and Files imports, which the cache serves
/// without copying (Android's `file`/`content` bypass).
public struct FileAudioSource: AudioRangeDataSource {
    public let url: URL
    public let mimeType: String?
    /// Set for a downloaded YouTube stream (fragmented MP4 with declared durations): its opening
    /// is patched on the way out, as a cached copy's would be. A file of unknown provenance must
    /// leave this off — the patch must never run on an ordinary file.
    public let requiresYouTubeDurationFix: Bool

    public init(url: URL, mimeType: String? = nil, requiresYouTubeDurationFix: Bool = false) {
        self.url = url
        self.mimeType = mimeType
        self.requiresYouTubeDurationFix = requiresYouTubeDurationFix
    }

    public func contentInfo() async throws -> AudioContentInfo {
        let size = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? NSNumber
        return AudioContentInfo(
            contentLength: size?.int64Value ?? 0,
            mimeType: mimeType,
            contentType: AudioContentType.uti(mimeType: mimeType, pathExtension: url.pathExtension)
        )
    }

    public func read(_ range: Range<Int64>) async throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.lowerBound))
        return try handle.read(upToCount: Int(range.count)) ?? Data()
    }

    public var maxRangeBytes: Int64 { 4 * 1_024 * 1_024 }

    public var isCacheable: Bool { false }
}

/// Why a cached read failed.
public enum AudioCacheError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The bytes aren't on disk and there is no source to fetch them from (offline, or a track
    /// the cache was asked for by key alone).
    case notCached(AudioCacheKey)
    /// A source answered with a different total length than the entry recorded: the key now
    /// names a different file (a re-minted URL for another format, a re-encoded upload). The entry
    /// is discarded so the next open starts clean; splicing the two would corrupt both. `key` is nil
    /// when a source throws it (sources don't know which entry they fill); the cache fills it in.
    case contentChanged(key: AudioCacheKey?, expected: Int64, actual: Int64)
    /// A source ended without delivering anything at a position inside the resource.
    case unexpectedEndOfStream(key: AudioCacheKey, position: Int64)
    /// The server refused the request.
    case httpStatus(Int, url: URL)
    /// A response that can't be used for the range asked for (wrong `Content-Range`, not HTTP).
    case badResponse(String)
    /// The stream is HLS, which is a playlist rather than one file and can't be cached by range.
    case notProgressive

    public var description: String {
        switch self {
        case .notCached(let key): return "\(key) is not cached and has no source"
        case .contentChanged(let key, let expected, let actual):
            return "\(key?.rawValue ?? "stream") changed length: recorded \(expected), served \(actual)"
        case .unexpectedEndOfStream(let key, let position): return "\(key) ended early at \(position)"
        case .httpStatus(let code, let url): return "HTTP \(code) from \(url.host() ?? String(url.absoluteString.prefix(120)))"
        case .badResponse(let reason): return "unusable response: \(reason)"
        case .notProgressive: return "HLS streams are not cached"
        }
    }
}

extension AudioCacheError {
    /// Whether `error` (by itself, not its underlying chain) was the connection's fault rather
    /// than the bytes': the network dropped or timed out, or a server refused the request (an
    /// expired URL). Such a failure says nothing against what is already on disk (Android's
    /// `isNetworkFault`: connection failed, timeout, bad HTTP status).
    public static func isNetworkFault(_ error: Error) -> Bool {
        if case .httpStatus = error as? AudioCacheError { return true }
        return AudioCacheResourceLoader.isTransientNetworkError(error)
    }
}
