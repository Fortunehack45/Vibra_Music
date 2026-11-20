import Foundation

// Ports data/model/SearchHistoryEntity.kt.

/// An entity the user tapped in search results: a track, album, artist or playlist.
///
/// Unlike raw query strings these carry the exact identity (id, artwork, type) of what was tapped,
/// so recents render instantly with real cover art and tapping one navigates straight to that
/// entity instead of re-running a text search.
///
/// The JSON shape matches Android's (`timestamp` is epoch milliseconds, `entityType` is
/// `"TRACK"`/`"ALBUM"`/`"ARTIST"`/`"PLAYLIST"`), so a backup's `search_history` restores on
/// either platform.
public struct SearchHistoryEntity: Codable, Hashable, Sendable, Identifiable {
    public enum EntityType: String, Codable, Hashable, Sendable, CaseIterable {
        case track = "TRACK"
        case album = "ALBUM"
        case artist = "ARTIST"
        case playlist = "PLAYLIST"
    }

    /// videoId for tracks, browseId for albums, artists and playlists.
    public var id: String
    /// Song name, album name, artist name, and so on.
    public var title: String
    /// For example "Song • Drake", "Album • Artist", or just the type label.
    public var subtitle: String
    public var artworkUrl: String?
    public var entityType: EntityType
    /// Epoch milliseconds; refreshed on each re-tap to bubble the entry to the top.
    public var timestamp: Int64

    public init(
        id: String,
        title: String,
        subtitle: String,
        artworkUrl: String?,
        entityType: EntityType,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.artworkUrl = artworkUrl
        self.entityType = entityType
        self.timestamp = timestamp
    }

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp) / 1_000) }

    private enum CodingKeys: String, CodingKey {
        case id, title, subtitle, artworkUrl, entityType, timestamp
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        artworkUrl = try c.decodeIfPresent(String.self, forKey: .artworkUrl)
        entityType = try c.decode(EntityType.self, forKey: .entityType)
        timestamp = try c.decodeIfPresent(Int64.self, forKey: .timestamp)
            ?? Int64(Date().timeIntervalSince1970 * 1_000)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(subtitle, forKey: .subtitle)
        // Written as an explicit null, like kotlinx.serialization, so Android can read it back.
        try c.encode(artworkUrl, forKey: .artworkUrl)
        try c.encode(entityType, forKey: .entityType)
        try c.encode(timestamp, forKey: .timestamp)
    }
}
