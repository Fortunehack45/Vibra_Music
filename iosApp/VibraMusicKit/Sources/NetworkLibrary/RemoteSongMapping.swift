import VibraMusicCore
import Foundation

// Ports data/remote/RemoteSong.kt: what every remote file library (SMB, WebDAV)
// names a track, and the Song row built from it.

/// A track in a remote file library, named after its file.
///
/// Both network libraries treat the server as a folder of audio files, so rows
/// are derived from filenames: `Artist - Title.ext` splits into a credit and a
/// title, anything else is a title by an unknown artist. The caller's protocol
/// supplies identity (`videoId`), the stream address (`localUri`) and the
/// library credit (`playbackSource` / `playbackSourceId`).
public enum RemoteSong {
    /// Splits `Artist - Title` into its credit and title; anything else is a
    /// title with no artist worth naming.
    public static func splitArtistTitle(_ base: String) -> (artist: String?, title: String?) {
        guard let range = base.range(of: " - ") else { return (nil, base) }
        let artist = String(base[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        let title = String(base[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (artist.isEmpty ? nil : artist, title.isEmpty ? nil : title)
    }

    /// A library row for one remote file.
    public static func build(
        videoId: String,
        streamUrl: String,
        fileName: String,
        albumName: String?,
        source: String,
        browseId: String
    ) -> Song {
        let stem = fileName.split(separator: ".").dropLast().joined(separator: ".")
        let base = stem.isEmpty ? fileName : stem
        let (artist, title) = splitArtistTitle(base)
        return Song(
            videoId: videoId,
            title: title ?? base,
            artist: artist ?? "Unknown Artist",
            albumName: albumName?.isEmpty == false ? albumName : nil,
            localUri: streamUrl,
            playbackSource: source,
            playbackSourceType: .browse,
            playbackSourceId: browseId
        )
    }
}
