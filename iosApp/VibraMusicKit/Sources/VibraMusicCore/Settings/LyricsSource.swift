import Foundation

// Ports the LyricsSource enum from data/lyrics/LyricsSource.kt. It lives in Core because
// AppSettings persists the enabled set and the order by these names, and needs the full list to
// tell a source the user switched off from one added by an upgrade. The Lyrics module maps each
// case to its provider implementation.

/// One lyrics database the user can switch on, off and reorder.
///
/// Declaration order (``allCases``) is the default priority. Stored by name (raw value), so this
/// list can be rearranged without disturbing an order somebody already chose. The three Apple hosts
/// lead because their catalogue carries the voices; BiniLyrics goes first because it answers to a
/// recording rather than a name and is where the ISRC the others use comes from.
public enum LyricsSource: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case biniLyrics = "BINI_LYRICS"
    case betterLyrics = "BETTER_LYRICS"
    case betterLyricsPortato = "BETTER_LYRICS_PORTATO"
    case paxSenix = "PAXSENIX"
    case paxSenixSpotify = "PAXSENIX_SPOTIFY"
    case paxSenixMusixmatch = "PAXSENIX_MUSIXMATCH"
    case lyricsPlus = "LYRICS_PLUS"
    case simpMusic = "SIMP_MUSIC"
    case unison = "UNISON"
    case youtubeTranscript = "YOUTUBE_TRANSCRIPT"
    case youtubeMusic = "YOUTUBE_MUSIC"
    case megalobiz = "MEGALOBIZ"
    case kuGou = "KUGOU"
    case lrcLib = "LRCLIB"
    case musixmatch = "MUSIXMATCH"
    case genius = "GENIUS"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .biniLyrics: return "BiniLyrics"
        case .betterLyrics: return "BetterLyrics"
        case .betterLyricsPortato: return "BetterLyrics Portato"
        case .paxSenix: return "PaxSenix"
        case .paxSenixSpotify: return "PaxSenix: Spotify"
        case .paxSenixMusixmatch: return "PaxSenix: Musixmatch"
        case .lyricsPlus: return "LyricsPlus"
        case .simpMusic: return "SimpMusic"
        case .unison: return "Unison"
        case .youtubeTranscript: return "YouTube captions"
        case .youtubeMusic: return "YouTube Music"
        case .megalobiz: return "Megalobiz"
        case .kuGou: return "KuGou"
        case .lrcLib: return "LRCLIB"
        case .musixmatch: return "Musixmatch"
        case .genius: return "Genius"
        }
    }

    public var detail: String {
        switch self {
        case .biniLyrics: return "The same Apple timings, matched on the recording itself"
        case .betterLyrics: return "Apple Music timings, word by word"
        case .betterLyricsPortato: return "QQ Music karaoke timings through BetterLyrics"
        case .paxSenix: return "Apple Music timings through the original keyless provider"
        case .paxSenixSpotify: return "Spotify lyrics with PaxSenix fallback; API key required"
        case .paxSenixMusixmatch: return "Musixmatch timings with PaxSenix fallback; API key required"
        case .lyricsPlus: return "Syllable by syllable, on community mirrors"
        case .simpMusic: return "Matched on the video, so never the wrong edit"
        case .unison: return "Contributed by listeners, so it has what nobody licensed"
        case .youtubeTranscript: return "Timed captions matched to the exact playing video"
        case .youtubeMusic: return "Plain lyrics from the playing video's Lyrics tab"
        case .megalobiz: return "Community-made, whole-line LRC"
        case .kuGou: return "Whole lines, strong outside the English catalogue"
        case .lrcLib: return "Whole lines only, and always up"
        case .musixmatch: return "Whole lines, from the biggest lyrics database there is"
        case .genius: return "Plain text fallback, massive web catalogue"
        }
    }

    /// Whether it can return per-word timings, or only whole lines.
    public var wordSynced: Bool {
        switch self {
        case .biniLyrics, .betterLyrics, .betterLyricsPortato, .paxSenix, .paxSenixMusixmatch,
             .lyricsPlus, .simpMusic, .unison:
            return true
        case .paxSenixSpotify, .youtubeTranscript, .youtubeMusic, .megalobiz, .kuGou, .lrcLib,
             .musixmatch, .genius:
            return false
        }
    }

    /// The sources that existed before `lyrics_sources_seen` was written. Fixed forever: it
    /// describes what an old build could have saved, so it does not grow when this enum does.
    public static let legacySources: Set<LyricsSource> = [
        .lyricsPlus, .paxSenix, .betterLyrics, .simpMusic, .kuGou, .lrcLib, .musixmatch, .genius,
    ]
}
