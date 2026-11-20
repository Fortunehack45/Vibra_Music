import VibraMusicCore
import Foundation

// Ports data/smb/SmbRepository.kt: the SMB library as Song rows, shaped like
// every other library in the app so the same Songs / Artists / Albums view
// can draw it.
//
// Stateless apart from its client: every load re-lists the share. The album
// of a track is its parent folder, which groups a "Music/Artist/Album"
// share layout back into releases without any tags — and covers are the
// pictures filed beside the music, matched by directory.

/// The SMB share as song rows.
public struct SmbRepository: Sendable {
    private let client: SmbClient
    private let credentials: SmbCredentials

    public init(credentials: SmbCredentials, client: SmbClient) {
        self.credentials = credentials
        self.client = client
    }

    public var isConfigured: Bool {
        credentials.isConfigured
    }

    /// Every audio file on the share as a row. Empty when unconfigured or
    /// when the server can't be read — a failed listing is reported through
    /// ``RemoteListing`` by the caller, never as silence here.
    public func getSongs() async -> [Song] {
        guard credentials.isConfigured else { return [] }
        guard let listing = try? await client.listLibrary() else { return [] }
        let artByDir = Dictionary(grouping: listing.images, by: { Self.dirKey($0.path) })
        return listing.audio.map { entry in
            toSong(entry, siblings: artByDir[Self.dirKey(entry.path)] ?? [])
        }
    }

    public func testConnection() async throws {
        try await client.testConnection()
    }

    private func toSong(_ entry: SmbListing.Entry, siblings: [SmbListing.Entry]) -> Song {
        // Entry paths accumulate from the base folder down, so they are
        // already share-rooted.
        let fullPath = entry.path
        let album = fullPath.split(separator: "/").dropLast().last.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let coverUrls = siblings.map { streamUrl($0.path) }
        var song = SmbConfig.songFor(
            host: credentials.host,
            share: credentials.share,
            path: fullPath,
            albumName: album?.isEmpty == false ? album : nil
        )
        song.thumbnailUrl = RemoteArtwork.pick(coverUrls)
        return song
    }

    private func streamUrl(_ path: String) -> String {
        "smb://\(SmbConfig.normalizeHost(credentials.host))/\(credentials.share)/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
    }

    static func dirKey(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let slash = trimmed.lastIndex(of: "/") else { return "" }
        return String(trimmed[..<slash]).lowercased()
    }
}
