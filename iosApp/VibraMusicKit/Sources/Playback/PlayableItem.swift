import AVFoundation
import VibraMusicCore

/// One thing the engine can play: what to show about it, and where its audio comes from.
///
/// The engine never resolves streams or reads a cache itself. Whoever builds the item decides
/// that, through ``Source``: a file on disk, an `AVURLAsset` produced on demand (the AudioCache
/// module hands one out backed by its resource loader), or a ``ResolvedStream`` resolved on demand.
/// The factories are called when the item is about to be needed — to start it, to preload it for a
/// gapless or crossfaded advance, or again to recover from an error — so a stream URL that expires
/// after a few hours is resolved at play time rather than when the queue was built, the same reason
/// the Android service resolved its `vibramusic://` URIs lazily in the data source.
public struct PlayableItem: Identifiable, Sendable {
    /// Unique per queue slot, not per song: the same song queued twice is two items. Returning the
    /// *same* id from ``AudioPlayerEngineDelegate/audioPlayerEngine(_:itemAfter:)`` is how the app
    /// asks for repeat-one, which the engine loops gaplessly and never crossfades into itself.
    public var id: String
    public var title: String
    public var artist: String
    public var album: String?
    /// Sized for the lock screen by whoever builds the item (see ``init(song:source:)``).
    public var artworkURL: URL?
    /// What the catalogue says the track runs, used until the decoder reports its own length.
    public var duration: TimeInterval?
    public var source: Source
    /// YouTube's normalization figure for the track, when it is known before playback. A
    /// ``Source/stream(_:)`` source can also supply one when it resolves; that one wins.
    public var loudnessDb: Double?
    /// What the source promised, for stats for nerds. Also superseded by a resolved stream's own,
    /// and by a ``Source/resolvedAsset(_:)`` open that declares nothing.
    public var declaredFormat: StreamFormat?
    /// Picked from a music-video row. Automix never plans a transition into or out of one (the
    /// Android controller's `isVideoOrigin` rule); a plain crossfade still applies.
    public var isVideoOrigin: Bool
    /// The queue row this item was built from, when it was built from one, so the app can map an
    /// engine callback back onto its queue without a lookup.
    public var song: Song?

    public typealias AssetFactory = @Sendable () async throws -> AVURLAsset
    public typealias StreamFactory = @Sendable () async throws -> ResolvedStream
    public typealias ResolvedAssetFactory = @Sendable () async throws -> (asset: AVURLAsset, stream: ResolvedStream?)

    public enum Source: Sendable {
        /// A file on this device: a download or a Files import.
        case file(URL)
        /// An asset made on demand, typically by the audio cache's resource loader.
        case asset(AssetFactory)
        /// A stream resolved on demand. The engine opens it with the stream's headers and MIME type.
        case stream(StreamFactory)
        /// An asset made on demand (typically by the audio cache) together with the stream it was
        /// resolved from, so the engine still learns the stream's loudness and declared format.
        /// A nil stream means nothing was resolved (a copy whole on disk): the open then declares
        /// no format, and the item's ``PlayableItem/declaredFormat``, settled before the open chose
        /// its copy, is not used.
        case resolvedAsset(ResolvedAssetFactory)
    }

    public init(
        id: String,
        title: String,
        artist: String,
        album: String? = nil,
        artworkURL: URL? = nil,
        duration: TimeInterval? = nil,
        source: Source,
        loudnessDb: Double? = nil,
        declaredFormat: StreamFormat? = nil,
        isVideoOrigin: Bool = false,
        song: Song? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.duration = duration.flatMap { $0 > 0 ? $0 : nil }
        self.source = source
        self.loudnessDb = loudnessDb
        self.declaredFormat = declaredFormat
        self.isVideoOrigin = isVideoOrigin
        self.song = song
    }

    /// An item for a queue row. The id is the row's ``Song/id`` (unique per queue slot), the artwork
    /// is sized for the lock screen like the Android notification's `NOTIFICATION_ART_PX`, and the
    /// catalogue duration comes from the row's duration text.
    public init(song: Song, source: Source, loudnessDb: Double? = nil) {
        let millis = song.durationMillis
        self.init(
            id: song.id,
            title: song.title,
            artist: song.artist,
            album: song.albumName,
            artworkURL: song.artworkURL(at: ArtworkSize.lockScreen),
            duration: millis > 0 ? TimeInterval(millis) / 1_000 : nil,
            source: source,
            loudnessDb: loudnessDb,
            isVideoOrigin: song.isVideoOrigin,
            song: song
        )
    }

    /// The id ``TrackLog`` files this item's lines under: the row's video id, which is what a pasted
    /// track log is looked up by. ``id`` is the queue slot (plus a rendition tag), so lines filed
    /// under it never reached the paste.
    public var trackID: String { song?.videoId ?? id }

    /// The local file behind the item, when it is one.
    public var fileURL: URL? {
        if case .file(let url) = source { return url }
        return nil
    }
}

extension PlayableItem: Equatable {
    /// Identity and metadata; factories can't be compared, so two ``Source/asset(_:)`` sources are
    /// treated as the same source.
    public static func == (lhs: PlayableItem, rhs: PlayableItem) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.artist == rhs.artist && lhs.album == rhs.album &&
            lhs.artworkURL == rhs.artworkURL && lhs.duration == rhs.duration && lhs.fileURL == rhs.fileURL &&
            lhs.loudnessDb == rhs.loudnessDb && lhs.isVideoOrigin == rhs.isVideoOrigin
    }
}

extension PlayableItem: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(title)
        hasher.combine(artist)
    }
}

/// What opening a ``PlayableItem/Source`` produced.
struct OpenedAudio: @unchecked Sendable {
    let asset: AVURLAsset
    let loudnessDb: Double?
    let declaredFormat: StreamFormat?
    /// Whether the open said what it opened (a ``PlayableItem/Source/resolvedAsset(_:)``): its
    /// `declaredFormat` then stands, nil included, over the item's.
    var settlesFormat = false
}

extension PlayableItem.Source {
    /// Opens the source. Called on the main actor; factories suspend rather than block it.
    func open() async throws -> OpenedAudio {
        switch self {
        case .file(let url):
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                throw PlaybackSourceError.missingLocalFile(url)
            }
            return OpenedAudio(asset: AVURLAsset(url: url), loudnessDb: nil, declaredFormat: nil)
        case .asset(let factory):
            return OpenedAudio(asset: try await factory(), loudnessDb: nil, declaredFormat: nil)
        case .stream(let factory):
            let stream = try await factory()
            return OpenedAudio(asset: Self.asset(for: stream), loudnessDb: stream.loudnessDb, declaredFormat: Self.declared(stream))
        case .resolvedAsset(let factory):
            let (asset, stream) = try await factory()
            return OpenedAudio(asset: asset, loudnessDb: stream?.loudnessDb, declaredFormat: stream.flatMap(Self.declared), settlesFormat: true)
        }
    }

    /// The stream's claimed format, nil when it claimed nothing.
    private static func declared(_ stream: ResolvedStream) -> StreamFormat? {
        stream.format == StreamFormat() ? nil : stream.format
    }

    /// An asset that fetches `stream` the way its source requires: some servers bind the URL to the
    /// request that minted it (User-Agent, Referer, Authorization), so the headers travel with it,
    /// and the MIME type is passed as a hint because a signed URL rarely has a usable extension.
    static func asset(for stream: ResolvedStream) -> AVURLAsset {
        var options: [String: Any] = [:]
        if !stream.headers.isEmpty {
            // Not exported as a constant, but the documented-by-convention key AVFoundation reads.
            options["AVURLAssetHTTPHeaderFieldsKey"] = stream.headers
        }
        if let mime = stream.mimeType?.split(separator: ";").first.map(String.init), !mime.isEmpty {
            options[AVURLAssetOverrideMIMETypeKey] = mime
        }
        return AVURLAsset(url: stream.url, options: options)
    }
}

extension AVURLAsset {
    /// An HLS playlist: a `.m3u8` URL, or the `vibramusic-hls` scheme the Sources module serves
    /// converted DASH manifests under.
    var isStreamingPlaylist: Bool {
        url.pathExtension.lowercased() == "m3u8" || url.scheme?.lowercased() == "vibramusic-hls"
    }
}

/// Failures the engine raises about a source before AVFoundation is involved.
public enum PlaybackSourceError: Error, Hashable, Sendable, CustomStringConvertible {
    /// A downloaded or imported file that is no longer on disk.
    case missingLocalFile(URL)
    /// The asset opened but carries no audio track.
    case noAudioTrack

    public var description: String {
        switch self {
        case .missingLocalFile(let url): return "The file \(url.lastPathComponent) is missing"
        case .noAudioTrack: return "The stream has no audio track"
        }
    }
}
