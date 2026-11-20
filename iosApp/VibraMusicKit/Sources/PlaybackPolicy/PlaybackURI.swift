import Foundation
import VibraMusicCore

// Ports the playback-URI half of playback/PlayerConnection.kt (`Song.toMediaItem`'s choice of URI,
// `matchQuery`, `toDirectYouTubeMediaItem`, `DIRECT_YOUTUBE_PARAMETER`) — the pieces every rule in
// this module is phrased against.

/// The app's own `vibramusic://` URIs for a queue entry, resolved into a real stream URL only when the
/// player opens them.
///
/// Android's queue holds `vibramusic://watch?v=…` and `vibramusic://source?s=…&t=…` items, and a resolving
/// data source turns them into URLs at open time. The same indirection is what lets a queue entry
/// say *which rendition* of a track it wants without knowing any URL: the upgraded copy
/// (`q=hifi`, `q=hifi-2`), YouTube's own upload after a revert (`direct_youtube=1&q=original`), or a
/// manifest re-open (`manifest_reopen=dash`). On iOS the Playback module's `AVAssetResourceLoader`
/// plays the part of the resolving data source, and the AudioCache keys renditions apart off the
/// same marker (see ``QualityUpgrade/cacheTag(_:)``).
///
/// Everything here is string work, deliberately: the rules must survive round trips through the
/// queue snapshot and a party sync byte for byte, and the Android tests that pin them down are
/// written against literal strings.
public enum PlaybackURI {
    public static let scheme = "vibramusic"
    /// `vibramusic://watch?v=<videoId>…` — a YouTube id, possibly substituted by a higher-ranked source.
    public static let watchPrefix = "vibramusic://watch"
    /// `vibramusic://source?s=<configId>&t=<trackId>…` — a track queued from a source's own catalogue.
    public static let sourcePrefix = "vibramusic://source"

    public static let videoIdParameter = "v"
    public static let sourceConfigParameter = "s"
    public static let sourceTrackParameter = "t"
    /// The rendition marker: absent on an ordinary entry, `hifi`/`hifi-N` on an upgraded one,
    /// `original` on a revert. Android's `QualityUpgrade.MARKER`.
    public static let renditionParameter = "q"
    /// "This exact YouTube rendition, immediately" — never a substitute, never an upgrade.
    public static let directYouTubeParameter = "direct_youtube"
    /// Makes a manifest retry a different URI from the progressive item it replaces; see
    /// ``StreamContainer/markedForManifestReopen(_:mime:)``.
    public static let manifestReopenParameter = "manifest_reopen"
    /// `m=1`: a music video, played on its own audio. Controls source routing, not player policy.
    public static let musicVideoParameter = "m"

    /// The URI a streamed queue entry for `song` starts on.
    ///
    /// The order is Android's `Song.toMediaItem`, minus its first step: a file on the device (a
    /// download, a Files import) plays from its own URL, and whether a saved copy exists is the
    /// Downloads module's question — the caller asks it first and only comes here for a stream.
    ///
    /// A pinned track is built straight onto YouTube's own upload, which is what makes "Revert to
    /// original" survive a relaunch, a replay from a list or a restored queue: everything downstream
    /// reads the URI, nothing downstream reads the pin. See ``OriginalVersion``.
    public static func forStreaming(_ song: Song, pinnedToOriginal: Bool) -> String {
        let id = song.videoId
        if id.hasPrefix("content://") || id.hasPrefix("file://") || id.hasPrefix("ipod-library://") { return id }
        if let key = SourceTrackKey.parse(id) {
            return source(configId: key.configId, trackId: key.trackId, song: song)
        }
        if pinnedToOriginal { return directYouTube(for: song) }
        return watch(for: song)
    }

    /// `vibramusic://watch?v=<id>&n=…&a=…` for an ordinary YouTube-id entry.
    public static func watch(for song: Song) -> String {
        "\(watchPrefix)?\(videoIdParameter)=\(song.videoId)\(matchQuery(for: song))"
    }

    /// The same entry reopened through YouTube alone, bypassing every substitute and upgrade path.
    ///
    /// The separate `q=original` rendition is essential: the base cache entry may hold a module's or
    /// JioSaavn's bytes, and resuming that entry as though it were YouTube's corrupts the stream.
    public static func directYouTube(for song: Song) -> String {
        watch(for: song) + "&\(directYouTubeParameter)=1&\(renditionParameter)=original"
    }

    /// `vibramusic://source?s=<configId>&t=<trackId>&n=…` for a source-backed entry.
    public static func source(configId: String, trackId: String, song: Song) -> String {
        "\(sourcePrefix)?\(sourceConfigParameter)=\(encode(configId))&\(sourceTrackParameter)=\(encode(trackId))"
            + matchQuery(for: song)
    }

    /// The first value of `name` in `uri`'s query, percent-decoded (and `+` read as a space, as
    /// Android's `Uri.getQueryParameter` does), or nil when absent.
    public static func queryValue(_ name: String, in uri: String) -> String? {
        let query = uri.after("?", missing: "").before("#")
        guard !query.isEmpty else { return nil }
        for part in query.split(separator: "&", omittingEmptySubsequences: true) {
            let key = part.before("=")
            guard decode(String(key)) == name else { continue }
            let raw = part.after("=", missing: "")
            return decode(raw)
        }
        return nil
    }

    /// Whether `uri` is a `vibramusic://source` entry (Android: `uri.authority == "source"`).
    public static func isSourceURI(_ uri: String) -> Bool {
        uri.before("?").before("#") == sourcePrefix
    }

    /// The `(n, a, d, l, e, m)` tail every playback URI carries: what this track is, in the terms a
    /// cross-source match is made on.
    ///
    /// The resolver runs with nothing but the URI in hand — read-ahead resolves tracks that are not
    /// the current item — so title, artist and runtime ride along. The runtime is only ever a hint:
    /// a row that never carried one omits it and matching falls back to title and artist.
    static func matchQuery(for song: Song) -> String {
        var query = "&n=\(encode(song.title))&a=\(encode(song.artist))"
        if let seconds = durationSeconds(of: song) { query += "&d=\(seconds)" }
        if let album = song.albumName, !album.trimmingCharacters(in: .whitespaces).isEmpty {
            query += "&l=\(encode(album))"
        }
        if let explicit = song.isExplicit { query += "&e=\(explicit ? "1" : "0")" }
        // `m` controls source routing, not player policy. A converted catalogue track keeps
        // isVideoOrigin for Automix but is audio here, so the normal upgrade path can improve it.
        if song.isVideo { query += "&\(musicVideoParameter)=1" }
        return query
    }

    /// Whole seconds from the row's duration text, nil when it carried none (Android
    /// `TrackMatcher.secondsOf`).
    static func durationSeconds(of song: Song) -> Int? {
        let seconds = song.durationMillis / 1_000
        return seconds > 0 ? seconds : nil
    }

    /// Android's `Uri.encode`: UTF-8 percent-encoding that leaves letters, digits and `_-!.~'()*`
    /// alone. Spaces become `%20`, not `+`.
    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: uriUnreserved) ?? value
    }

    static func decode(_ value: String) -> String {
        let spaced = value.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    private static let uriUnreserved: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-!.~'()*")
        return set
    }()
}
