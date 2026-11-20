import Foundation
import VibraMusicCore

// The value types the download queue, the Downloads page and the app share. Ports the data classes
// at the bottom of download/Downloads.kt (DownloadState, DownloadTarget, SavedCollection,
// DownloadedCollection, SavedSongMetadata, resolvedDownloadDates, youtubeDownloadBadge).

/// Where a track is between "not on this device" and "on it".
public enum DownloadState: Hashable, Sendable {
    /// Accepted, waiting for the one in front of it — or for Wi-Fi (see
    /// ``DownloadManager/isWaitingForWiFi``).
    case queued
    /// `fraction` is 0 until the length is known, which is the first thing asked for.
    case running(fraction: Double)
    case failed(reason: String)

    public var isInFlight: Bool {
        switch self {
        case .queued, .running: return true
        case .failed: return false
        }
    }
}

/// What a batch download was asked for as a whole.
///
/// Built by whichever surface the tap came from — a release page's own download button, a shelf
/// card's menu — because that surface is the only thing that knows the answer, and by the time the
/// tracks reach the queue they are forty unrelated rows. Nil everywhere a single track is
/// downloaded on its own, which is the honest answer there: one song off an album is not the album.
public struct DownloadTarget: Codable, Hashable, Sendable {
    /// What this release is filed under: its browse id where it has one, so the same album
    /// downloaded twice is one entry rather than two.
    public var id: String
    public var title: String
    public var subtitle: String
    public var thumbnailUrl: String?
    /// Playlists and albums are grouped alike but not billed alike.
    public var playlist: Bool

    public init(id: String, title: String, subtitle: String = "", thumbnailUrl: String? = nil, playlist: Bool = false) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.thumbnailUrl = thumbnailUrl
        self.playlist = playlist
    }
}

/// A release the record says was downloaded whole, as it is written down.
///
/// Only the tracks' ids, not the tracks: a ``Song`` is a wide row full of things that go stale, and a
/// second copy of one per release is a second copy to keep in step. The songs are looked up out of
/// what the Downloads page already read off disk instead; see
/// ``DownloadLibrary/collectionsAmong(_:)``.
public struct SavedCollection: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String
    /// The remote cover the release was billed with.
    public var thumbnailUrl: String?
    /// The cover cached on this device, relative to the download root. Android replaced
    /// `thumbnailUrl` with a `file://` URI; on iOS the app container's absolute path changes across
    /// updates and restores, so the local copy is kept as a relative path beside the remote URL and
    /// resolved when read (``DownloadLibrary/artworkURL(forRelativePath:)``).
    public var artworkPath: String?
    public var playlist: Bool
    /// In the order the page listed them, which is the order to play them in.
    public var videoIds: [String]

    public init(
        id: String,
        title: String,
        subtitle: String = "",
        thumbnailUrl: String? = nil,
        artworkPath: String? = nil,
        playlist: Bool = false,
        videoIds: [String] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.thumbnailUrl = thumbnailUrl
        self.artworkPath = artworkPath
        self.playlist = playlist
        self.videoIds = videoIds
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, subtitle, thumbnailUrl, artworkPath, playlist, videoIds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        thumbnailUrl = try c.decodeIfPresent(String.self, forKey: .thumbnailUrl)
        artworkPath = try c.decodeIfPresent(String.self, forKey: .artworkPath)
        playlist = try c.decodeIfPresent(Bool.self, forKey: .playlist) ?? false
        videoIds = try c.decodeIfPresent([String].self, forKey: .videoIds) ?? []
    }
}

/// A ``SavedCollection`` with its surviving tracks attached, ready to draw.
public struct DownloadedCollection: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String
    /// The cached local cover as a `file://` URL string when there is one, else the remote cover,
    /// else the first track's.
    public var thumbnailUrl: String?
    public var playlist: Bool
    public var songs: [Song]

    public init(id: String, title: String, subtitle: String, thumbnailUrl: String?, playlist: Bool, songs: [Song]) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.thumbnailUrl = thumbnailUrl
        self.playlist = playlist
        self.songs = songs
    }
}

/// Whether a file in the library came out of the download queue or was picked in Files.
public enum LocalTrackOrigin: String, Codable, Hashable, Sendable {
    case download = "DOWNLOAD"
    case imported = "IMPORTED"
}

/// The record of one saved file, by the id it can be asked about (Android `SavedSongMetadata`).
public struct SavedTrackRecord: Codable, Hashable, Sendable {
    public var videoId: String
    public var title: String
    public var artist: String
    /// The remote cover the row carried.
    public var thumbnailUrl: String?
    /// The cover saved on this device, relative to the download root. Preferred over
    /// ``thumbnailUrl`` so the Downloads page draws covers with no connection.
    public var artworkPath: String?
    public var durationText: String?
    /// What release this track is off, when the row it was downloaded from knew.
    public var albumName: String?
    /// The file, relative to the download root (Android kept a `content://` or `file://` URI; see
    /// ``SavedCollection/artworkPath`` for why iOS can't).
    public var path: String
    /// Premium-rendition badge shown only in the Downloads list (`"FLAC"`, `"AAC · 128 kbps"`).
    public var downloadFormat: String?
    /// Stable creation time, so "Date added" survives a retag.
    public var dateAddedSeconds: Int64?
    public var origin: LocalTrackOrigin

    public init(
        videoId: String,
        title: String,
        artist: String,
        thumbnailUrl: String? = nil,
        artworkPath: String? = nil,
        durationText: String? = nil,
        albumName: String? = nil,
        path: String,
        downloadFormat: String? = nil,
        dateAddedSeconds: Int64? = nil,
        origin: LocalTrackOrigin = .download
    ) {
        self.videoId = videoId
        self.title = title
        self.artist = artist
        self.thumbnailUrl = thumbnailUrl
        self.artworkPath = artworkPath
        self.durationText = durationText
        self.albumName = albumName
        self.path = path
        self.downloadFormat = downloadFormat
        self.dateAddedSeconds = dateAddedSeconds
        self.origin = origin
    }

    private enum CodingKeys: String, CodingKey {
        case videoId, title, artist, thumbnailUrl, artworkPath, durationText, albumName, path
        case downloadFormat, dateAddedSeconds, origin
    }

    /// Lenient: fields added after the fact (album, date added, origin) decode as absent, so a
    /// record written before they existed still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        videoId = try c.decode(String.self, forKey: .videoId)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        thumbnailUrl = try c.decodeIfPresent(String.self, forKey: .thumbnailUrl)
        artworkPath = try c.decodeIfPresent(String.self, forKey: .artworkPath)
        durationText = try c.decodeIfPresent(String.self, forKey: .durationText)
        albumName = try c.decodeIfPresent(String.self, forKey: .albumName)
        path = try c.decode(String.self, forKey: .path)
        downloadFormat = try c.decodeIfPresent(String.self, forKey: .downloadFormat)
        dateAddedSeconds = try c.decodeIfPresent(Int64.self, forKey: .dateAddedSeconds)
        origin = (try? c.decodeIfPresent(LocalTrackOrigin.self, forKey: .origin)) ?? .download
    }
}

/// The lyrics to write into a track being saved, in the two forms the taggers take (Android
/// `LyricsTag.Embeddable`).
///
/// ``plain`` goes in the container's own lyrics field, where every other player looks. ``enhanced``
/// is the same lines with their word timings kept, in a field only this app reads — nil when the
/// source was line-synced and there was nothing extra to say.
public struct DownloadLyrics: Hashable, Sendable {
    public var plain: String
    public var enhanced: String?

    public init(plain: String, enhanced: String? = nil) {
        self.plain = plain
        self.enhanced = enhanced
    }
}

/// Supplies the lyrics to embed in a download. The Lyrics module is wired in by the app; it gets the
/// track and returns LRC text (or nil for none). May throw — a failure costs the lyrics, never the
/// download.
public typealias DownloadLyricsProvider = @Sendable (Song) async throws -> DownloadLyrics?

/// Told when googlevideo refuses a URL partway through a download (403/404/410), before the queue
/// resolves the track again. Android's Downloader called `StreamResolver.onPlaybackRefused` at this
/// point: the refusal means the client that minted the URL has been stood down for this track, and
/// unless the resolver hears so it may hand the same dead URL straight back. Core's
/// `StreamResolving` has no such call, so the app wires this to StreamResolution's
/// `StreamResolver.onPlaybackRefused(url:statusCode:)`.
public typealias DownloadStreamRefusalHandler = @Sendable (_ url: URL, _ statusCode: Int) async -> Void

/// What a tap on "Download" (one track or a whole release) turned into, for the toast.
public struct DownloadRequestOutcome: Hashable, Sendable {
    /// Tracks newly put in the queue.
    public var queued: Int
    /// Tracks skipped because they are already on the device.
    public var alreadyDownloaded: Int
    /// Tracks skipped because they were already queued or running.
    public var alreadyQueued: Int
    /// The queue is holding for Wi-Fi (Wi-Fi only is on and the connection is metered).
    public var waitingForWiFi: Bool

    public init(queued: Int = 0, alreadyDownloaded: Int = 0, alreadyQueued: Int = 0, waitingForWiFi: Bool = false) {
        self.queued = queued
        self.alreadyDownloaded = alreadyDownloaded
        self.alreadyQueued = alreadyQueued
        self.waitingForWiFi = waitingForWiFi
    }
}

/// A failure a user can read. Every message is written for them; ``DownloadManager`` shows it on
/// the failed row as-is.
public struct DownloadError: Error, Hashable, Sendable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// Why a download didn't start or is holding, when the reason is a setting rather than a fault.
/// Names the switch, because a wait that only says "waiting" leaves the user looking for a network
/// problem that isn't there.
public let wifiOnlyWaitingMessage = "Waiting for Wi-Fi — downloads are set to Wi-Fi only"

/// Dates for a downloaded file-backed row.
///
/// Old metadata has no persisted creation time, so the file timestamp is the only honest migration
/// value. From then on the persisted value stays fixed, while modified time continues to follow the
/// file on disk.
public func resolvedDownloadDates(persistedAddedSeconds: Int64?, fileModifiedMillis: Int64?) -> (added: Int64?, modified: Int64?) {
    let modifiedSeconds = fileModifiedMillis.flatMap { $0 > 0 ? $0 / 1_000 : nil }
    return (persistedAddedSeconds ?? modifiedSeconds, modifiedSeconds)
}

/// YouTube does not expose a named quality tier once the resolved file has been saved, so the
/// concrete codec and bitrate are kept alongside the download. Display metadata only. `webm` stays
/// in the table for parity with Android's records, although iOS never saves WebM (AVPlayer can't
/// play it).
public func youtubeDownloadBadge(extension ext: String, kbps: Int) -> String? {
    guard kbps > 0 else { return nil }
    let codec = ext.lowercased() == "m4a" ? "AAC" : "OPUS"
    return "\(codec) · \(kbps) kbps"
}

extension StreamFormat {
    /// Premium source labels used in the Downloads list.
    var downloadBadge: String? {
        if isDolbyAtmos { return "DOLBY" }
        if codec == "flac" || codec == "x-flac" { return "FLAC" }
        return nil
    }
}
