import CryptoKit
import Foundation
import os

/// One logger for the module, as the README asks: subsystem `com.fortune.vibramusic.ios`, category = module.
let streamLog = Logger(subsystem: "com.fortune.vibramusic.ios", category: "StreamResolution")

// MARK: - Quality ceilings

/// The streaming ceiling, mirroring Android's `AudioQuality` rungs.
///
/// Only [low] actually caps the YouTube ladder (64 kbps); the other three all mean "best
/// available" here. What tells Medium, High and Lossless apart on Android is which *other*
/// sources are asked before YouTube, and that decision lives outside this module. The app maps
/// `AppSettings.effectiveAudioQuality` onto this (or passes `maxKbps` straight through).
public enum StreamAudioQuality: String, CaseIterable, Sendable {
    case low, medium, high, lossless

    public var maxKbps: Int {
        switch self {
        case .low: return 64
        case .medium, .high, .lossless: return Int.max
        }
    }
}

/// The download ceiling, mirroring Android's `DownloadQuality`. Standard caps the ladder at
/// 128 kbps; High and Lossless take whichever rung is best.
public enum StreamDownloadQuality: String, CaseIterable, Sendable {
    case standard, high, lossless

    public var maxKbps: Int {
        switch self {
        case .standard: return 128
        case .high, .lossless: return Int.max
        }
    }
}

// MARK: - Result

/// A resolved stream: the URL, what the format behind it turned out to be, and what its media
/// fetch has to look like. Port of `StreamResolver.Stream`, widened with the facts the Kotlin
/// kept in separate maps (headers, loudness, content length) because on iOS the caller — an
/// `AVURLAsset` or a download task — needs all of them at the moment it opens the URL.
public struct ResolvedYouTubeStream: Sendable, Hashable {
    public var videoId: String
    public var url: URL
    public var itag: Int
    /// Average bitrate in kbps. The container carries no bitrate field, so this is the only
    /// place the real figure is ever known (Android feeds it to stats-for-nerds).
    public var kbps: Int
    /// As the player endpoint reports it, e.g. `audio/mp4; codecs="mp4a.40.2"`.
    public var mimeType: String
    /// YouTube's own normalisation figure for this rendition, when it gave one.
    public var loudnessDb: Double?
    /// The whole file's size, from the URL's `clen` or the format's `contentLength`.
    public var contentLength: Int64?
    public var approxDurationMs: Int64?
    /// The InnerTube client that minted the URL (`VISIONOS`, `WEB_REMIX`, ...).
    public var clientName: String
    /// Catalog id of the exact client variant; what exclusions key on.
    public var profileId: String
    /// Headers the media fetch must carry — googlevideo compares them with the minting client.
    public var mediaHeaders: [String: String]
    /// When googlevideo stops honouring the URL (its `expire` parameter).
    public var expiresAt: Date?

    public init(
        videoId: String, url: URL, itag: Int, kbps: Int, mimeType: String, loudnessDb: Double? = nil,
        contentLength: Int64? = nil, approxDurationMs: Int64? = nil, clientName: String, profileId: String,
        mediaHeaders: [String: String], expiresAt: Date? = nil
    ) {
        self.videoId = videoId
        self.url = url
        self.itag = itag
        self.kbps = kbps
        self.mimeType = mimeType
        self.loudnessDb = loudnessDb
        self.contentLength = contentLength
        self.approxDurationMs = approxDurationMs
        self.clientName = clientName
        self.profileId = profileId
        self.mediaHeaders = mediaHeaders
        self.expiresAt = expiresAt
    }

    /// The container these bytes are actually in, which is not always what names them.
    ///
    /// Nothing here transcodes or remuxes, so the extension has to describe the bytes rather
    /// than the codec inside them. YouTube's Opus is Opus-in-WebM; naming that file `.opus`
    /// would promise an Ogg file and make it refuse to open elsewhere.
    public var downloadExtension: String {
        (mimeType.contains("mp4") || mimeType.contains("m4a")) ? "m4a" : "webm"
    }

    /// What a file store should be told this file is.
    public var downloadMimeType: String {
        downloadExtension == "m4a" ? "audio/mp4" : "audio/webm"
    }

    /// Whether `AVPlayer` can play these bytes. It cannot demux WebM, so only AAC-in-MP4 is.
    public var isAVPlayerCompatible: Bool { downloadExtension == "m4a" }

    /// Largest single range googlevideo reliably serves for this URL; see `StreamPlayerClient.rangeBytes(for:)`.
    public var rangeChunkBytes: Int64 { StreamPlayerClient.rangeBytes(for: url) }
}

// MARK: - Errors

public enum StreamResolutionError: Error, Hashable, LocalizedError {
    /// A track this app cannot play, for a reason that will read the same in ten seconds — an
    /// age gate no session gets past, a takedown, a region block. Its own case because
    /// everything above the resolver has to tell it apart from a failure worth retrying.
    /// Port of `StreamResolver.PermanentlyUnplayableException`.
    case permanentlyUnplayable(reason: String)
    /// Every client was tried and none produced a URL that served bytes. Worth retrying later.
    case noPlayableStream(detail: String)
    /// The download path ran out of its required container ladder; the message is user-facing.
    case downloadUnavailable(message: String)
    /// Not an 11-character YouTube video id.
    case invalidVideoId(String)

    public var errorDescription: String? {
        switch self {
        case .permanentlyUnplayable(let reason): return reason
        case .noPlayableStream(let detail): return "Couldn't load this track just now: \(detail)"
        case .downloadUnavailable(let message): return message
        case .invalidVideoId(let id): return "\"\(id)\" is not a YouTube video id"
        }
    }

    /// Whether retrying cannot change the answer (the caller should skip the track).
    public var isPermanent: Bool {
        if case .permanentlyUnplayable = self { return true }
        return false
    }
}

// MARK: - Signed-in requests

/// The signed-in session to send with requests that accept one (the `WEB_REMIX` player request
/// and the playback-stats pings). The InnerTube module owns sign-in and implements
/// `StreamAuthProvider`; this type is the small vocabulary both sides share, so this module
/// never needs to know about cookie jars or account switching.
///
/// Maps from Android's `Innertube.cookie` plus its `SessionScope`/`ChannelSelection`.
public struct StreamAuthSession: Sendable, Hashable {
    /// The whole `Cookie` header for youtube.com / music.youtube.com.
    public var cookie: String
    /// Which account in the cookie jar (`X-Goog-AuthUser`). `"0"` when unknown.
    public var authUser: String
    /// Brand channel (`X-Goog-PageId`), when acting as one.
    public var pageId: String?
    /// The account as `context.user.onBehalfOfUser`. Only ever a value read back from a shell
    /// that said it was signed in: Google answers one it cannot tie to the cookie with 401.
    public var dataSyncId: String?
    /// Visitor id bound to this session; outranks an anonymous one for everything it signs.
    public var visitorData: String?
    /// The live `WEB_REMIX` client version from the signed-in shell, if known.
    public var webRemixClientVersion: String?

    public init(
        cookie: String, authUser: String = "0", pageId: String? = nil, dataSyncId: String? = nil,
        visitorData: String? = nil, webRemixClientVersion: String? = nil
    ) {
        self.cookie = cookie
        self.authUser = authUser
        self.pageId = pageId
        self.dataSyncId = dataSyncId
        self.visitorData = visitorData
        self.webRemixClientVersion = webRemixClientVersion
    }

    /// Cookie names that can carry the API-signing secret, in the order Android looks for them.
    ///
    /// `SAPISID` is the documented one and the one a partitioned or `__Host`-prefixed login can
    /// lack; any of the three signs a request. Missing this silently made every history ping
    /// anonymous on Android while the UI showed the user signed in.
    static let sapisidNames = ["SAPISID", "__Secure-3PAPISID", "__Secure-1PAPISID"]

    /// The API-signing secret out of the cookie header, or nil.
    public var sapisid: String? {
        var jar: [String: String] = [:]
        for entry in cookie.split(separator: ";") {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let name = entry[..<eq].trimmingCharacters(in: .whitespaces)
            let value = entry[entry.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !value.isEmpty, jar[name] == nil { jar[name] = value }
        }
        return Self.sapisidNames.lazy.compactMap { jar[$0] }.first
    }

    /// `SAPISIDHASH <ts>_<sha1("<ts> <sapisid> <origin>")>`, or nil without a SAPISID cookie.
    public func authorization(origin: String, now: Date = Date()) -> String? {
        guard let sapisid else { return nil }
        let timestamp = Int(now.timeIntervalSince1970)
        let digest = Insecure.SHA1.hash(data: Data("\(timestamp) \(sapisid) \(origin)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(timestamp)_\(hex)"
    }

    /// Cookie, Authorization, X-Goog-AuthUser and (for a brand channel) X-Goog-PageId.
    public func headers(origin: String, now: Date = Date()) -> [String: String] {
        var headers = ["Cookie": cookie, "X-Goog-AuthUser": authUser]
        if let pageId, !pageId.isEmpty { headers["X-Goog-PageId"] = pageId }
        if let authorization = authorization(origin: origin, now: now) { headers["Authorization"] = authorization }
        return headers
    }
}

/// Supplies the signed-in session, or nil when browsing as a guest. Implemented by the
/// InnerTube module; injected into `StreamResolver` and `PlaybackHistoryTracker`.
public protocol StreamAuthProvider: Sendable {
    func streamAuthSession() async -> StreamAuthSession?
}

// MARK: - Small shared helpers

enum YouTubeVideoId {
    /// A videoId, as opposed to anything else that can be a media id (a local file URI, an
    /// add-on's own id). Asking Google about one of those is a request that cannot succeed.
    static func isValid(_ id: String) -> Bool {
        id.utf8.count == 11 && id.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2D || byte == 0x5F
        }
    }
}

extension URL {
    /// First value of query parameter `name`, percent-decoded.
    func streamQueryValue(_ name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    /// This URL with `name=value` set (replacing an existing value, or appended).
    func settingStreamQuery(_ name: String, _ value: String) -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        var items = components.percentEncodedQueryItems ?? []
        let encoded = value.addingPercentEncoding(withAllowedCharacters: .streamQueryValueAllowed) ?? value
        if let index = items.firstIndex(where: { $0.name == name }) {
            items[index].value = encoded
        } else {
            items.append(URLQueryItem(name: name, value: encoded))
        }
        components.percentEncodedQueryItems = items
        return components.url ?? self
    }

    /// Whether this is a googlevideo media URL, the only kind that says anything about a client.
    var isGoogleVideo: Bool { host?.hasSuffix("googlevideo.com") == true }
}

extension CharacterSet {
    /// Unreserved characters only, so `+`, `/`, `=` and `&` in signatures and tokens survive.
    static let streamQueryValueAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}
