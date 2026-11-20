import Foundation

// Ports playback/StreamContainer.kt.

/// Whether the URL serving a track points at audio or at an index of it.
///
/// A source's stream URL is whatever its backend feels like serving, and that is not always a file.
/// Tidal answers a lossless or Dolby Atmos request with an MPEG-DASH manifest, and answered the same
/// request with an HLS one until September 2026 — same track, same tier. The playback URIs this app
/// queues (`vibramusic://watch?v=…`, `vibramusic://source?…`) carry no extension to infer from, so the
/// player defaults to treating the bytes as a progressive file, and a progressive reader handed a
/// manifest fails with the only error it can raise ("none of the extractors could read the stream").
///
/// That URL was not broken, which is the whole reason this exists: sixteen seconds later the
/// identical URL played as Dolby Atmos because it arrived through the one path that declared the
/// type. The failure had been read as a dead stream and the track struck off substitution for the
/// session.
///
/// So "what is on the end of this URL" gets one answer, asked where an upgrade builds its item, where
/// the live path decides whether it may substitute at all, and where a failed track is put back on
/// its feet. Judged on the extension (or on what a source *declared*), never on the codec a module
/// named: `format: "flac"` describes the audio inside and says nothing about the envelope.
///
/// ### On iOS
///
/// `AVPlayer` plays HLS natively and cannot play DASH at all (PORTING.md §4). The Playback module
/// uses ``transport(of:)`` to hand an HLS URL to `AVURLAsset` with `AVURLAssetOverrideMIMETypeKey`
/// when the URL has no `.m3u8` to sniff, and to treat a DASH answer as unplayable — falling back to
/// YouTube (``PlaybackFallback``) — rather than as a broken stream.
public final class StreamContainer: @unchecked Sendable {
    public static let shared = StreamContainer()

    /// What a manifest URL carries.
    public enum Transport: String, Hashable, Sendable, CaseIterable {
        case hls
        case dash

        /// Media3's names, which are also what `AVURLAssetOverrideMIMETypeKey` accepts for HLS.
        public var mimeType: String {
            switch self {
            case .hls: return StreamContainer.hlsMimeType
            case .dash: return StreamContainer.dashMimeType
            }
        }

        /// Whether `AVPlayer` can play this transport at all.
        public var playsInAVFoundation: Bool { self == .hls }

        init?(mimeType: String) {
            switch mimeType {
            case StreamContainer.hlsMimeType: self = .hls
            case StreamContainer.dashMimeType: self = .dash
            default: return nil
            }
        }
    }

    /// Media3's `MimeTypes.APPLICATION_M3U8`.
    public static let hlsMimeType = "application/x-mpegURL"
    /// Media3's `MimeTypes.APPLICATION_MPD`.
    public static let dashMimeType = "application/dash+xml"

    /// Bounded the cheap way (clear on overflow): this is an optimisation over sniffing, and losing
    /// an entry costs a guess, not a track.
    public static let maxRemembered = 64

    private let lock = NSLock()
    /// What a source stated about a URL — true wherever the URL turns up.
    private var declared: [String: String] = [:]
    /// What each track was last actually served, keyed by media id — true only until the track moves.
    private var serving: [String: String] = [:]

    public init() {}

    /// Gives a manifest retry a different playback URI from the progressive item it replaces.
    ///
    /// Media3 accepts an updated item in place when its URI and cache key are unchanged, so an item
    /// replaced with the same URI plus a manifest MIME type only updated the old progressive source.
    /// The marker changes only the app's virtual `vibramusic://` URI: the resolver ignores it, and the
    /// cache keys YouTube tracks from `v`/`q` and source tracks from `s`/`t`, so it neither changes
    /// the stream selected nor invents another cache rendition. `AVPlayer` has the same trait (an
    /// `AVPlayerItem` for an unchanged URL reuses what it loaded), so the marker keeps its job.
    public static func markedForManifestReopen(_ uri: String, mime: String) -> String {
        guard let transport = Transport(mimeType: mime) else { return uri }
        let fragmentAt = uri.firstIndex(of: "#")
        let base = fragmentAt.map { String(uri[..<$0]) } ?? uri
        let fragment = fragmentAt.map { String(uri[$0...]) } ?? ""
        let separator = base.contains("?") ? "&" : "?"
        return "\(base)\(separator)\(PlaybackURI.manifestReopenParameter)=\(transport.rawValue)\(fragment)"
    }

    /// The MIME type the player needs to be told for `url`, or nil when it points at ordinary audio.
    ///
    /// A source that *said* what the URL is outranks the extension — see ``declare(_:transport:)``.
    public func manifestMime(of url: String) -> String? {
        if let stated = lock.withLock({ declared[url] }) { return stated }
        let path = url.before("?")
        let ext = path.range(of: ".", options: .backwards).map { String(path[$0.upperBound...]) } ?? String(path)
        switch ext.lowercased() {
        case "m3u8": return Self.hlsMimeType
        case "mpd": return Self.dashMimeType
        default: return nil
        }
    }

    /// ``manifestMime(of:)`` as a ``Transport``.
    public func transport(of url: String) -> Transport? {
        manifestMime(of: url).flatMap(Transport.init(mimeType:))
    }

    /// Records that `url` carries `transport` (`hls` or `dash`) because the source that handed it
    /// over said so.
    ///
    /// The extension is a guess, and wrong in the case met most often: an addon serving an HLS
    /// playlist from an extensionless path (`/dash/{id}`, which is not DASH despite the name, and
    /// reports `format: "flac"`). Keyed by URL because that is what every caller holds, and a signed
    /// URL is already unique to one resolution of one track. Unknown transports are ignored.
    public func declare(_ url: String, transport: String) {
        guard let known = Transport(rawValue: transport.lowercased()) else { return }
        lock.withLock {
            if declared.count >= Self.maxRemembered { declared.removeAll() }
            declared[url] = known.mimeType
        }
    }

    /// Whether `url` is an index of the audio rather than the audio.
    public func isManifest(_ url: String) -> Bool {
        manifestMime(of: url) != nil
    }

    /// Records that `mediaId` is being served from `url`. Recorded on every resolve, so the entry is
    /// never a stale claim about a track that has since moved to another source.
    public func served(_ mediaId: String, from url: String) {
        lock.withLock {
            // Bounded rather than pruned: nothing here is a promise the way StreamChoice's entries
            // are, so the cheap eviction is the right one.
            if serving.count >= Self.maxRemembered { serving.removeAll() }
            serving[mediaId] = url
        }
    }

    /// The MIME type `mediaId`'s current stream needed, or nil if it is not being served a manifest.
    public func manifestServing(_ mediaId: String) -> String? {
        guard let url = lock.withLock({ serving[mediaId] }) else { return nil }
        return manifestMime(of: url)
    }
}
