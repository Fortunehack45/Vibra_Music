import VibraMusicCore
import Foundation

// Ports data/webdav/WebDavRepository.kt: the WebDAV library as Song rows,
// shaped like the on-device library so the same Songs / Artists / Albums
// view can draw it.
//
// Stateless apart from its client: every load re-lists the server. The album
// of a track is its parent folder, which groups a "Music/Artist/Album"
// remote layout back into releases without any tags.

/// The WebDAV server as song rows.
public struct WebDavRepository: Sendable {
    private let client: WebDavClient
    private let credentials: WebDavCredentials

    public init(credentials: WebDavCredentials, client: WebDavClient) {
        self.credentials = credentials
        self.client = client
    }

    public var isConfigured: Bool {
        credentials.isConfigured
    }

    /// Every audio file on the server as a row. Empty when unconfigured or
    /// when the server can't be read.
    public func getSongs() async -> [Song] {
        guard credentials.isConfigured else { return [] }
        guard let listing = try? await client.listLibrary(credentials) else { return [] }
        let artByDir = Dictionary(grouping: listing.images, by: { Self.dirKey($0.url) })
        return listing.audio.map { entry in
            entryToSong(entry, artworkUrl: Self.artworkFor(fileUrl: entry.url, siblings: artByDir[Self.dirKey(entry.url)] ?? []))
        }
    }

    public func testConnection() async throws {
        try await client.testConnection(credentials)
    }

    func entryToSong(_ entry: WebDavClient.Entry, artworkUrl: String? = nil) -> Song {
        let album = Self.parentFolderName(entry.url)
        var song = WebDavConfig.songFor(fileUrl: entry.url, albumName: album)
        // Prefer the server's display name over the URL-decoded guess when
        // it carries one.
        let base = entry.displayName.split(separator: ".").dropLast().joined(separator: ".")
        let stem = base.isEmpty ? entry.displayName : base
        if !stem.isEmpty {
            let (artist, title) = RemoteSong.splitArtistTitle(stem)
            if let title, !title.isEmpty { song.title = title }
            if let artist, !artist.isEmpty { song.artist = artist }
        }
        song.thumbnailUrl = artworkUrl
        return song
    }

    /// The cover for a track: a picture filed beside it. Embedded pictures
    /// inside the audio itself are not read — that would be a ranged fetch
    /// per track at list time. See ``RemoteArtwork``.
    public static func artworkFor(fileUrl: String, siblings: [WebDavClient.Entry]) -> String? {
        RemoteArtwork.pick(siblings.map(\.url))
    }

    static func dirKey(_ fileUrl: String) -> String {
        guard let url = URL(string: fileUrl), let host = url.host else {
            let parent = fileUrl.split(separator: "/").dropLast().last.map(String.init) ?? ""
            return parent.lowercased()
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parent = path.split(separator: "/").dropLast().joined(separator: "/")
        return "\(host)/\(parent)".lowercased()
    }

    static func parentFolderName(_ fileUrl: String) -> String? {
        guard let url = URL(string: fileUrl) else { return nil }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = path.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        let parent = String(parts[parts.count - 2]).removingPercentEncoding ?? String(parts[parts.count - 2])
        return parent.isEmpty ? nil : parent
    }
}
