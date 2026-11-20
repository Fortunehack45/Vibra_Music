import Foundation

// The contract between the modules that *find* audio (StreamResolution, Sources, NetworkLibrary,
// Downloads for local files) and the ones that *consume* it (Playback, Downloads). Distilled from
// StreamResolver.Stream, SourceStream (data/sources/MusicSource.kt), StreamRequest and
// SourceResolver.requestForNow/requestForDownload. The app wires a concrete StreamResolving in.

/// Where a resolved stream's bytes come from.
public enum StreamOrigin: String, Codable, Hashable, Sendable, CaseIterable {
    /// googlevideo, via the Innertube player endpoint.
    case youtube
    /// A user-configured HTTP addon.
    case addon
    /// A legacy JS module source (PORTING Q4).
    case module
    case jioSaavn
    /// A file on this device: a download or a Files import.
    case local
    /// A WebDAV or SMB share.
    case networkShare

    /// The registry kind that serves this origin, when it is one.
    public var sourceKind: SourceKind? {
        switch self {
        case .youtube: return .youtube
        case .addon: return .addon
        case .module: return .module
        case .jioSaavn: return .jioSaavn
        case .local, .networkShare: return nil
        }
    }
}

/// A URL the player (or a download task) can open, and what is expected to come out of it.
public struct ResolvedStream: Codable, Hashable, Sendable {
    public var url: URL
    public var origin: StreamOrigin
    /// The container as served, e.g. `audio/mp4`, `audio/webm; codecs="opus"`, `audio/flac`,
    /// `application/x-mpegURL`. Describes the *bytes*, which is what a download's file extension
    /// and AVFoundation's type hint must follow.
    public var mimeType: String?
    /// Codec, bitrate, sample rate, bit depth — as far as the source says.
    public var format: StreamFormat
    /// HTTP headers the media fetch must carry. Some sources bind the URL to the request that
    /// minted it (User-Agent, Referer, Authorization for WebDAV). Pass these to
    /// `AVURLAsset(url:options: ["AVURLAssetHTTPHeaderFieldsKey": headers])` or the download request.
    public var headers: [String: String]
    /// YouTube's per-track loudness (dB relative to its reference); drives loudness normalization.
    public var loudnessDb: Double?
    /// Total bytes, when known (YouTube's `clen`, a HEAD, or a file size).
    public var contentLength: Int64?
    /// When the signed URL stops working. googlevideo URLs carry an `expire` query parameter
    /// (see ``expiry(in:)``); module URLs last about five hours. Nil when it doesn't expire or isn't
    /// known.
    public var expiresAt: Date?
    /// How long the catalogue says this recording is, when it says. Lets a stream found for a track
    /// that is already playing be checked against the decoder's runtime before it is cut in (a 163 s
    /// track was once matched to a 189 s cut of the same song).
    public var durationSeconds: Int?
    /// Less than was asked for, taken because nothing better answered in time. Worth asking again
    /// during playback (quality upgrade).
    public var belowRequest: Bool
    /// Which configured source instance answered, when a source did. Lets a second look during
    /// playback skip the source already serving the track.
    public var sourceConfigId: String?

    public init(
        url: URL,
        origin: StreamOrigin,
        mimeType: String? = nil,
        format: StreamFormat = StreamFormat(),
        headers: [String: String] = [:],
        loudnessDb: Double? = nil,
        contentLength: Int64? = nil,
        expiresAt: Date? = nil,
        durationSeconds: Int? = nil,
        belowRequest: Bool = false,
        sourceConfigId: String? = nil
    ) {
        self.url = url
        self.origin = origin
        self.mimeType = mimeType
        self.format = format
        self.headers = headers
        self.loudnessDb = loudnessDb
        self.contentLength = contentLength
        self.expiresAt = expiresAt
        self.durationSeconds = durationSeconds
        self.belowRequest = belowRequest
        self.sourceConfigId = sourceConfigId
    }

    /// Whether this is an HLS playlist rather than one progressive file. HLS can't be saved as a
    /// single file with a plain download task (use `AVAssetDownloadURLSession`).
    public var isHLS: Bool {
        if let mimeType = mimeType?.lowercased(),
           mimeType.contains("mpegurl") {
            return true
        }
        return url.pathExtension.lowercased() == "m3u8"
    }

    /// Whether the URL has expired at `date` (with a safety `margin` so a fetch started now
    /// doesn't die halfway). Never true when the expiry is unknown.
    public func isExpired(at date: Date = Date(), margin: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return date.addingTimeInterval(margin) >= expiresAt
    }

    /// The `expire` query parameter (Unix seconds) that googlevideo URLs carry, as a date.
    public static func expiry(in url: URL) -> Date? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let raw = items.first(where: { $0.name == "expire" })?.value,
              let seconds = TimeInterval(raw) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

/// How much of a stream the caller is willing to pay for, and what for.
///
/// Built per request rather than read from settings by the resolver, because the answer depends on
/// the connection in hand when the track starts (``AppSettings/playbackStreamRequest(for:)``), or
/// on the download setting for a file being kept (``AppSettings/downloadStreamRequest``) — never on
/// what was chosen an hour ago on a different network.
public struct StreamRequest: Codable, Hashable, Sendable {
    /// The per-source ask (Android's `StreamRequest` sealed interface).
    public enum Tier: Codable, Hashable, Sendable {
        /// Bit-exact, whatever it costs. Sources that can't do it should say so rather than substitute.
        case lossless
        /// Whatever the source considers its best lossy rendition.
        case best
        /// A transcode at or below this many kbps. The only tier sources can't meaningfully answer:
        /// YouTube's ladder is the only one that can be capped.
        case capped(kbps: Int)
    }

    public enum Purpose: String, Codable, Hashable, Sendable {
        /// Streaming now; HLS is fine.
        case playback
        /// A file to keep; must be a progressive file (not HLS).
        case download
    }

    public var tier: Tier
    public var purpose: Purpose
    /// Which kinds of source may answer. YouTube is always permitted for playback: it is what a cap
    /// applies to, and the only source that can answer when the others are skipped.
    public var permittedSources: Set<SourceKind>
    /// Whether a YouTube answer that arrives first is held back while the ranked sources finish
    /// looking, so the track can start on one of them (the "Direct source stream" setting). Off:
    /// YouTube starts the track at once and the quality upgrade follows. Playback only.
    public var waitsForSources: Bool
    /// Whether read-ahead asks the ranked sources for the tracks ahead, and a track it found a copy
    /// for starts on that copy (Direct source stream's Queue only). The player's to act on; the
    /// resolver doesn't read it. Playback only.
    public var readsAheadFromSources: Bool

    public init(
        tier: Tier,
        purpose: Purpose = .playback,
        permittedSources: Set<SourceKind> = Set(SourceKind.allCases),
        waitsForSources: Bool = false,
        readsAheadFromSources: Bool = false
    ) {
        self.tier = tier
        self.purpose = purpose
        self.permittedSources = permittedSources
        self.waitsForSources = waitsForSources
        self.readsAheadFromSources = readsAheadFromSources
    }

    /// The kbps cap, or nil when uncapped.
    public var maxKbps: Int? {
        if case .capped(let kbps) = tier { return kbps }
        return nil
    }

    public var wantsLossless: Bool { tier == .lossless }

    public func permits(_ kind: SourceKind) -> Bool { permittedSources.contains(kind) }

    /// The request for streaming under `quality` (Android `SourceResolver.requestForNow`).
    /// Lossless → lossless tier; Medium/High → best; Low → capped. Sources filtered by
    /// ``AudioQuality/permits(_:)``. `directSource` sets ``waitsForSources`` (Always) or
    /// ``readsAheadFromSources`` (Queue only).
    public static func playback(_ quality: AudioQuality, directSource: DirectSourceStream = .off) -> StreamRequest {
        let tier: Tier
        if quality == .lossless {
            tier = .lossless
        } else if let cap = quality.maxKbps {
            tier = .capped(kbps: cap)
        } else {
            tier = .best
        }
        return StreamRequest(
            tier: tier,
            purpose: .playback,
            permittedSources: Set(SourceKind.allCases.filter(quality.permits)),
            waitsForSources: directSource == .always,
            readsAheadFromSources: directSource == .queueOnly
        )
    }

    /// The request for a download kept at `quality` (Android `SourceResolver.requestForDownload`).
    /// Independent of the streaming ceilings on purpose: a capped mobile-data stream must not
    /// quietly downgrade a permanent file. Every source kind is permitted.
    public static func download(_ quality: DownloadQuality) -> StreamRequest {
        let tier: Tier
        if quality.keepsLossless {
            tier = .lossless
        } else if let cap = quality.maxKbps {
            tier = .capped(kbps: cap)
        } else {
            tier = .best
        }
        return StreamRequest(tier: tier, purpose: .download)
    }
}

/// Turns a ``Song`` into something playable.
///
/// Implemented by StreamResolution (YouTube) and Sources (addons, JioSaavn); the app composes them
/// (source ladder first, YouTube fallback) and hands one instance to Playback and Downloads.
/// Implementations must be safe to call concurrently and should throw rather than return a URL they
/// haven't verified. Honour `request.purpose`: a download needs a progressive file.
public protocol StreamResolving: Sendable {
    func resolveStream(for song: Song, request: StreamRequest) async throws -> ResolvedStream
}

extension StreamResolving {
    /// Playback convenience: `maxKbps` nil means uncapped (lossless tier, every source permitted).
    public func resolveStream(for song: Song, maxKbps: Int?) async throws -> ResolvedStream {
        let request: StreamRequest
        if let maxKbps {
            request = StreamRequest(tier: .capped(kbps: maxKbps), permittedSources: [.youtube])
        } else {
            request = StreamRequest(tier: .lossless)
        }
        return try await resolveStream(for: song, request: request)
    }
}
