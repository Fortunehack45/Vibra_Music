import Foundation
import VibraMusicCore

// Ports playback/PlaybackFallback.kt, plus `Song.hasYouTubeOriginal` from PlayerConnection.kt.

/// The one-way escape from a higher-quality source that failed after it had already been selected.
///
/// A normal retry is deliberately free to resolve again, which is useful for a transient YouTube URL
/// and exactly wrong for an addon or JioSaavn failure: the same deterministic catalogue lookup wins
/// again and hands the player the same broken stream. A failed alternative therefore becomes an
/// explicit YouTube request for the rest of this playback.
public enum PlaybackFallback {
    /// Whether `uri` is currently allowed to resolve to something above YouTube — and so whether a
    /// failure on it has a YouTube copy to fall back to.
    ///
    /// - Parameter substitutedYouTube: whether the resolver substituted a source for this YouTube id
    ///   (``StreamChoice/isSubstitute(_:)``).
    public static func isAlternative(_ uri: String, substitutedYouTube: Bool) -> Bool {
        if parameter(uri, PlaybackURI.directYouTubeParameter) == "1" { return false }
        if uri.before("?").before("#") == PlaybackURI.sourcePrefix { return true }
        let rendition = parameter(uri, PlaybackURI.renditionParameter)
        return substitutedYouTube || rendition == "hifi" || rendition?.hasPrefix("hifi-") == true
    }

    /// Marks a source-backed item as a direct YouTube fallback while preserving the
    /// title/artist/duration query used to find the corresponding upload.
    ///
    /// Stale transport and rendition markers are dropped (`manifest_reopen`, `q`, an earlier
    /// `direct_youtube`), and the item gets its own `q=original` rendition so the fallback's YouTube
    /// bytes are never written into the failed source's cache entry.
    public static func directYouTubeSourceURI(_ uri: String) -> String {
        let fragmentAt = uri.firstIndex(of: "#")
        let withoutFragment = fragmentAt.map { String(uri[..<$0]) } ?? uri
        let fragment = fragmentAt.map { String(uri[$0...]) } ?? ""
        let queryAt = withoutFragment.firstIndex(of: "?")
        let base = queryAt.map { String(withoutFragment[..<$0]) } ?? withoutFragment
        var kept: [String] = []
        if let queryAt {
            let query = withoutFragment[withoutFragment.index(after: queryAt)...]
            kept = query
                .split(separator: "&", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { part in
                    let key = String(part.before("="))
                    return key != PlaybackURI.directYouTubeParameter &&
                        key != PlaybackURI.renditionParameter &&
                        key != PlaybackURI.manifestReopenParameter
                }
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        let params = kept + [
            "\(PlaybackURI.directYouTubeParameter)=1",
            "\(PlaybackURI.renditionParameter)=original",
        ]
        return "\(base)?\(params.joined(separator: "&"))\(fragment)"
    }

    /// Whether there is a YouTube upload behind `song` to go back *to* — the question "Revert to
    /// original" only means something for.
    ///
    /// Offered for any track that has one rather than only for one a quality upgrade visibly
    /// swapped: a source ranked above YouTube gets first refusal on every track, so a song can be
    /// playing a module's idea of it from the first second with nothing on screen having changed.
    /// A live version, a remaster or a different mix agreeing on title, artist and runtime is a
    /// catalogue's ordinary business, and the listener is the only one who can hear it.
    ///
    /// The exclusions are all "there is no such upload": a track queued from a source's own
    /// catalogue (a `src:` key), a file on the device, and a music video — which *is* the upload.
    public static func hasYouTubeOriginal(_ song: Song) -> Bool {
        let id = song.videoId
        return !id.trimmingCharacters(in: .whitespaces).isEmpty &&
            !id.hasPrefix("content://") &&
            !id.hasPrefix("file://") &&
            !id.hasPrefix("ipod-library://") &&
            !song.isVideo &&
            SourceTrackKey.parse(id) == nil
    }

    /// The URI to rebuild a failed queue entry on, as a direct YouTube request with no stale
    /// manifest type (Android's `MediaItem.toYouTubeFallbackMediaItem`).
    ///
    /// A YouTube-id entry becomes ``PlaybackURI/directYouTube(for:)``. A source-backed entry keeps
    /// its source URI's metadata so the resolver can find the matching upload
    /// (``directYouTubeSourceURI(_:)``). Nil for anything else — a file, or a source entry with no
    /// URI to carry the metadata. The caller should also drop the item's "quality upgraded" flag and
    /// any MIME type it declared: YouTube audio is progressive and must be sniffed afresh.
    public static func youTubeFallbackURI(for song: Song, currentURI: String?) -> String? {
        if hasYouTubeOriginal(song) { return PlaybackURI.directYouTube(for: song) }
        guard let currentURI, PlaybackURI.isSourceURI(currentURI) else { return nil }
        return directYouTubeSourceURI(currentURI)
    }

    /// The raw (undecoded) value of the first `wanted` parameter, "" for a bare key, nil if absent.
    static func parameter(_ uri: String, _ wanted: String) -> String? {
        let query = uri.after("?", missing: "").before("#")
        return query.split(separator: "&", omittingEmptySubsequences: false)
            .first { $0.before("=") == wanted }
            .map { $0.after("=", missing: "") }
    }
}
