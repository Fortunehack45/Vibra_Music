import Foundation

// Ports data/model/Models.kt (Song and its helpers).

/// Tier of an item in the playback queue.
///
/// Raw values are the Android enum names, so persisted queues and backups read the same on both.
public enum QueueTier: String, Codable, Hashable, Sendable, CaseIterable {
    /// Explicitly queued by the user ("Play Next", "Add to Queue", or a preserved user queue).
    case userQueue = "USER_QUEUE"
    /// Part of the active album, playlist or artist collection.
    case context = "CONTEXT"
    /// Radio recommendations appended when the context and user queue run out.
    case autoplay = "AUTOPLAY"
}

/// A queue-level origin shown above Now Playing ("Playing from …"), in the style of Spotify.
public enum PlaybackSourceType: String, Codable, Hashable, Sendable, CaseIterable {
    case home = "HOME"
    case search = "SEARCH"
    case history = "HISTORY"
    case replay = "REPLAY"
    case explore = "EXPLORE"
    case browse = "BROWSE"
    case sharedLink = "SHARED_LINK"
    case queue = "QUEUE"
}

/// What a non-YouTube source says it can serve a recording at.
///
/// Carried on the row rather than discovered at stream time because it is the only thing that
/// distinguishes two catalogues holding the same track, and the choice between them has to be made
/// *before* either is asked for a URL. Without it a Deezer row and a 16-bit FLAC row look identical,
/// the FLAC loses a tie-break on artist spelling, and the track plays as a 128 kbps MP3.
public enum SourceQuality: String, Codable, Hashable, Sendable, CaseIterable {
    case lossless = "LOSSLESS"
    case high = "HIGH"
    case low = "LOW"
    /// The immersive (Dolby Atmos) mix, published by some catalogues as its own row. Not a rung on
    /// the same ladder as the other three: Tidal files these rows under `LOW`, so Sources reads
    /// the row's audio mode rather than its bitrate label (Android `ModuleSource.DOLBY`).
    case dolby = "DOLBY"
}

/// A playable track: a YouTube Music row, a source-backed row, a download or a local file.
///
/// The shared vocabulary of the whole app. It round-trips through JSON (queue persistence,
/// downloads, party sync), and decoding is deliberately lenient: every field except `videoId`,
/// `title` and `artist` may be missing, unknown enum values decode as their default, and unknown
/// keys are ignored — so JSON written by an older or newer build still loads.
public struct Song: Codable, Hashable, Sendable, Identifiable {
    public var videoId: String
    public var title: String
    public var artist: String
    public var thumbnailUrl: String?
    /// Display duration as YouTube sends it (`"3:45"`). See ``durationMillis``.
    public var durationText: String?
    /// Browse ids lifted from the row, used by the long-press actions.
    public var artistId: String?
    public var albumId: String?
    /// Names the album page header, which ``albumId`` alone can't.
    public var albumName: String?
    /// A music-video upload rather than the catalogue track.
    public var isVideo: Bool
    /// True for a video upload and for its manually selected catalogue match. The latter stays
    /// video-origin so playback policies such as Automix don't mistake a converted video for a
    /// normal music track. Defaults to ``isVideo``.
    public var isVideoOrigin: Bool
    /// This track's identity *within one playlist*, which is not its ``videoId``: the same song
    /// added twice is two entries with two set-video-ids, and removing one of them is only
    /// expressible in those terms. Present only on rows parsed from a playlist page.
    public var setVideoId: String?
    /// Which queue tier this track belongs to in the playback timeline.
    public var queueTier: QueueTier
    /// Unique, immutable queue-entry identity assigned when the track enters the player's queue.
    /// Preserved across stream transformations and persistence.
    public var queueEntryId: String?
    /// The seed title of an explicitly started radio. Every item in that queue carries the same
    /// value, so the player can keep naming the station across skips and queue edits.
    public var radioName: String?
    /// File URL (as a string) for downloaded or imported audio.
    public var localUri: String?
    /// A premium rendition marker recorded for the Downloads list (for example `"FLAC"`).
    public var downloadFormat: String?
    /// Filesystem path backing ``localUri`` when known.
    public var localPath: String?
    /// Timestamps used only to sort downloaded and imported libraries (seconds since 1970).
    public var localDateAddedSeconds: Int64?
    public var localDateModifiedSeconds: Int64?
    /// What a non-YouTube source says it can serve this recording at; nil for every row that
    /// didn't come from one.
    public var sourceQuality: SourceQuality?
    /// Explicit-content state from the catalogue; nil when that source does not say.
    public var isExplicit: Bool?
    /// The page, collection or feed section that put this track in the queue.
    ///
    /// Deliberately separate from ``albumName``: a song can belong to an album while it was played
    /// from Search, History, a playlist or a shelf. Kept on every queue item so Now Playing can
    /// name the origin after skips and after a restored queue.
    public var playbackSource: String?
    /// Where tapping ``playbackSource`` should return in the app.
    public var playbackSourceType: PlaybackSourceType?
    /// Browse id for an album, playlist or other source page.
    public var playbackSourceId: String?

    public init(
        videoId: String,
        title: String,
        artist: String,
        thumbnailUrl: String? = nil,
        durationText: String? = nil,
        artistId: String? = nil,
        albumId: String? = nil,
        albumName: String? = nil,
        isVideo: Bool = false,
        isVideoOrigin: Bool? = nil,
        setVideoId: String? = nil,
        queueTier: QueueTier = .context,
        queueEntryId: String? = nil,
        radioName: String? = nil,
        localUri: String? = nil,
        downloadFormat: String? = nil,
        localPath: String? = nil,
        localDateAddedSeconds: Int64? = nil,
        localDateModifiedSeconds: Int64? = nil,
        sourceQuality: SourceQuality? = nil,
        isExplicit: Bool? = nil,
        playbackSource: String? = nil,
        playbackSourceType: PlaybackSourceType? = nil,
        playbackSourceId: String? = nil
    ) {
        self.videoId = videoId
        self.title = title
        self.artist = artist
        self.thumbnailUrl = thumbnailUrl
        self.durationText = durationText
        self.artistId = artistId
        self.albumId = albumId
        self.albumName = albumName
        self.isVideo = isVideo
        self.isVideoOrigin = isVideoOrigin ?? isVideo
        self.setVideoId = setVideoId
        self.queueTier = queueTier
        self.queueEntryId = queueEntryId
        self.radioName = radioName
        self.localUri = localUri
        self.downloadFormat = downloadFormat
        self.localPath = localPath
        self.localDateAddedSeconds = localDateAddedSeconds
        self.localDateModifiedSeconds = localDateModifiedSeconds
        self.sourceQuality = sourceQuality
        self.isExplicit = isExplicit
        self.playbackSource = playbackSource
        self.playbackSourceType = playbackSourceType
        self.playbackSourceId = playbackSourceId
    }

    /// The most specific identity the row has: its queue entry, then its playlist slot, then its
    /// video id. So a queue or a playlist holding the same song twice still yields unique ids in a
    /// SwiftUI `ForEach`. Equality (`==`) still compares every field.
    public var id: String { queueEntryId ?? setVideoId ?? videoId }

    /// Legacy derived flag: true if and only if ``queueTier`` is ``QueueTier/autoplay``.
    public var fromAutoplay: Bool { queueTier == .autoplay }

    /// ``durationText`` in milliseconds, or 0 when the row didn't state one.
    ///
    /// A row's duration is a display string, and anything that has to *reason* about the length
    /// needs it back as a quantity. Lyrics matching forced this: LRCLIB keys its exact lookup on
    /// the length and falls back to the closest fuzzy hit, so a zero duration doesn't miss — it
    /// silently matches the shortest edit of the song. Zero is the answer for anything that isn't
    /// a duration, so a caller has one thing to check.
    public var durationMillis: Int { DurationText.millis(from: durationText) }

    /// Artwork at `px` pixels square. See ``Artwork/resized(_:to:)``.
    public func artworkAt(_ px: Int) -> String? { Artwork.resized(thumbnailUrl, to: px) }

    /// ``artworkAt(_:)`` as a URL.
    public func artworkURL(at px: Int) -> URL? { artworkAt(px).flatMap(URL.init(string:)) }

    /// The first credited artist. See ``ArtistCredit/primary(of:)``.
    public var primaryArtist: String { ArtistCredit.primary(of: artist) }

    /// Whether a row is the track the player is on, for the now-playing highlight.
    ///
    /// Title and credit, matched exactly, and nothing else. Every id a row could be matched on
    /// instead is scoped to where the row came from and lies across that boundary: a set-video-id
    /// names a slot in one playlist (two playlists hand the same one to unrelated tracks), and the
    /// same recording arrives with different video ids from a download, a local file and a source.
    /// The cost is that an album track and its compilation appearance both light up — the
    /// highlight means "this is the song you are hearing", not "this queue entry".
    ///
    /// The player's own queue must not use this; it matches on position.
    public func isSameTrackAs(_ other: Song?) -> Bool {
        guard let other else { return false }
        return title == other.title && artist == other.artist
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case videoId, title, artist, thumbnailUrl, durationText, artistId, albumId, albumName
        case isVideo, isVideoOrigin, setVideoId, queueTier, queueEntryId, radioName, localUri
        case downloadFormat, localPath, localDateAddedSeconds, localDateModifiedSeconds
        case sourceQuality, isExplicit, playbackSource, playbackSourceType, playbackSourceId
        /// Written by builds that predate ``queueTier``; read only.
        case fromAutoplay
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        videoId = try c.decode(String.self, forKey: .videoId)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        thumbnailUrl = try c.decodeIfPresent(String.self, forKey: .thumbnailUrl)
        durationText = try c.decodeIfPresent(String.self, forKey: .durationText)
        artistId = try c.decodeIfPresent(String.self, forKey: .artistId)
        albumId = try c.decodeIfPresent(String.self, forKey: .albumId)
        albumName = try c.decodeIfPresent(String.self, forKey: .albumName)
        isVideo = try c.decodeIfPresent(Bool.self, forKey: .isVideo) ?? false
        isVideoOrigin = try c.decodeIfPresent(Bool.self, forKey: .isVideoOrigin) ?? isVideo
        setVideoId = try c.decodeIfPresent(String.self, forKey: .setVideoId)
        // Unknown tier names (a newer build) fall back rather than failing the whole queue.
        if let tier = try? c.decodeIfPresent(QueueTier.self, forKey: .queueTier) {
            queueTier = tier
        } else if (try? c.decodeIfPresent(Bool.self, forKey: .fromAutoplay)) == true {
            queueTier = .autoplay
        } else {
            queueTier = .context
        }
        queueEntryId = try c.decodeIfPresent(String.self, forKey: .queueEntryId)
        radioName = try c.decodeIfPresent(String.self, forKey: .radioName)
        localUri = try c.decodeIfPresent(String.self, forKey: .localUri)
        downloadFormat = try c.decodeIfPresent(String.self, forKey: .downloadFormat)
        localPath = try c.decodeIfPresent(String.self, forKey: .localPath)
        localDateAddedSeconds = try c.decodeIfPresent(Int64.self, forKey: .localDateAddedSeconds)
        localDateModifiedSeconds = try c.decodeIfPresent(Int64.self, forKey: .localDateModifiedSeconds)
        sourceQuality = (try? c.decodeIfPresent(SourceQuality.self, forKey: .sourceQuality)) ?? nil
        isExplicit = try c.decodeIfPresent(Bool.self, forKey: .isExplicit)
        playbackSource = try c.decodeIfPresent(String.self, forKey: .playbackSource)
        playbackSourceType = (try? c.decodeIfPresent(PlaybackSourceType.self, forKey: .playbackSourceType)) ?? nil
        playbackSourceId = try c.decodeIfPresent(String.self, forKey: .playbackSourceId)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(videoId, forKey: .videoId)
        try c.encode(title, forKey: .title)
        try c.encode(artist, forKey: .artist)
        try c.encodeIfPresent(thumbnailUrl, forKey: .thumbnailUrl)
        try c.encodeIfPresent(durationText, forKey: .durationText)
        try c.encodeIfPresent(artistId, forKey: .artistId)
        try c.encodeIfPresent(albumId, forKey: .albumId)
        try c.encodeIfPresent(albumName, forKey: .albumName)
        try c.encode(isVideo, forKey: .isVideo)
        try c.encode(isVideoOrigin, forKey: .isVideoOrigin)
        try c.encodeIfPresent(setVideoId, forKey: .setVideoId)
        try c.encode(queueTier, forKey: .queueTier)
        try c.encodeIfPresent(queueEntryId, forKey: .queueEntryId)
        try c.encodeIfPresent(radioName, forKey: .radioName)
        try c.encodeIfPresent(localUri, forKey: .localUri)
        try c.encodeIfPresent(downloadFormat, forKey: .downloadFormat)
        try c.encodeIfPresent(localPath, forKey: .localPath)
        try c.encodeIfPresent(localDateAddedSeconds, forKey: .localDateAddedSeconds)
        try c.encodeIfPresent(localDateModifiedSeconds, forKey: .localDateModifiedSeconds)
        try c.encodeIfPresent(sourceQuality, forKey: .sourceQuality)
        try c.encodeIfPresent(isExplicit, forKey: .isExplicit)
        try c.encodeIfPresent(playbackSource, forKey: .playbackSource)
        try c.encodeIfPresent(playbackSourceType, forKey: .playbackSourceType)
        try c.encodeIfPresent(playbackSourceId, forKey: .playbackSourceId)
    }
}

// MARK: - Artwork

/// Artwork sizing for YouTube-served images.
///
/// YouTube serves every size from one URL via a `w<n>-h<n>` hint, so the size an image is fetched
/// at is the caller's to choose, in both directions. Up: the advertised size is far short of what a
/// full-screen player draws, and source images run to about 1400 px, so asking for more is free and
/// sharper. Down: a row thumbnail left at the advertised size costs an order of magnitude more bytes
/// than the square it fills (84 kB against 7.8 kB, measured on the same cover).
///
/// Video thumbnails carry no hint and are returned unchanged.
public enum Artwork {
    /// `url` with its size hint replaced by `w<px>-h<px>`, or unchanged when it has none.
    public static func resized(_ url: String?, to px: Int) -> String? {
        guard let url else { return nil }
        return url.replacing(sizeHint, with: "w\(px)-h\(px)")
    }

    /// Built once: every cover a list row draws comes through here on the main thread, and a regex
    /// built per call is compiled again on its first match. Shared across threads, which a Regex
    /// allows: it is immutable, and compiles its program once, atomically.
    nonisolated(unsafe) private static let sizeHint = #/w\d+-h\d+/#
}

/// The artwork size ladder, in pixels. One value per surface rather than per row height, so
/// surfaces that draw the same size share a cache entry instead of each fetching its own.
public enum ArtworkSize {
    /// A list row: 52 pt at most, so about 140 px on a 3x screen, rounded up.
    public static let row = 160
    /// A shelf card: 166 pt wide, a little under 450 px at 3x.
    public static let card = 480
    /// A page header, drawn near enough full width.
    public static let header = 720
    /// Handed to the lock screen / Now Playing info / CarPlay (Android's notification size).
    /// Generous because those surfaces draw it large and never fetch a better copy later.
    public static let lockScreen = 544
    /// The full player, and the largest rung. The widget picks its size off this ladder too, so a
    /// large widget and an open player fetch the same cover once and agree on whether it exists.
    public static let player = 1200
}

// MARK: - Duration text

/// Conversions between YouTube-style duration strings (`"3:45"`, `"1:02:33"`) and quantities.
public enum DurationText {
    /// `M:SS` or `H:MM:SS` in milliseconds; 0 for nil, blank, or anything that isn't a duration.
    /// Whitespace around and inside the fields is tolerated. Never negative.
    public static func millis(from text: String?) -> Int {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return 0
        }
        var numbers: [Int] = []
        for part in trimmed.split(separator: ":", omittingEmptySubsequences: false) {
            guard let value = Int(part.trimmingCharacters(in: .whitespaces)) else { return 0 }
            numbers.append(value)
        }
        let seconds: Int
        switch numbers.count {
        case 2: seconds = numbers[0] * 60 + numbers[1]
        case 3: seconds = numbers[0] * 3_600 + numbers[1] * 60 + numbers[2]
        default: return 0
        }
        return max(seconds * 1_000, 0)
    }

    /// `"M:SS"` for a length in milliseconds, the form every Android source formatter used
    /// (minutes are not rolled into hours: 75 minutes is `"75:00"`). Negative input formats as 0.
    public static func format(millis: Int) -> String {
        format(seconds: max(millis, 0) / 1_000)
    }

    /// `"M:SS"` for a length in whole seconds.
    public static func format(seconds: Int) -> String {
        let total = max(seconds, 0)
        let secs = total % 60
        return "\(total / 60):\(secs < 10 ? "0" : "")\(secs)"
    }
}

// MARK: - Artist credits

/// Helpers on artist credit strings.
public enum ArtistCredit {
    /// The first credited artist, for services that don't handle joint credits well (Last.fm,
    /// ListenBrainz). Splits on `,`, ` & ` and the full-width ` ＆ `; the original value is kept
    /// when there is no separator, so names such as "AC/DC" remain intact.
    public static func primary(of credit: String) -> String {
        let separator = #/\s*,\s*|\s+&\s+|\s+＆\s+/#
        guard let match = credit.firstMatch(of: separator) else {
            return blankFallback(credit.trimmingCharacters(in: .whitespaces), credit)
        }
        let first = credit[..<match.range.lowerBound].trimmingCharacters(in: .whitespaces)
        return blankFallback(first, credit)
    }

    private static func blankFallback(_ value: String, _ original: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? original : value
    }
}
