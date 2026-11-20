import VibraMusicCore
import Foundation

/// The track lyrics are wanted for — the handful of `Song` fields the lookup reads.
///
/// Deliberately this module's own type rather than Core's `Song`, so the two can evolve
/// separately; mapping is field for field (`videoId`, `title`, `artist`, `albumName`,
/// duration in milliseconds, `localUri`).
public struct LyricsTrack: Hashable, Sendable, Codable {
    /// The YouTube video id. SimpMusic and both YouTube sources are keyed on it, and it is
    /// the key the recording (ISRC) is remembered against.
    public var videoId: String
    /// As YouTube names it; cleaned for searching by `forLyricsSearch` inside the lookup.
    public var title: String
    public var artist: String
    public var album: String?
    /// Zero while unknown. The databases match on length, so `LyricsSession` waits for it
    /// unless the track has a local file to read first.
    public var durationMs: Int
    /// The recording, where the caller knows it (a downloaded or local file's own tags).
    public var isrc: String?
    /// A file this track plays from on the device, read for embedded lyrics before the network.
    public var localFileURL: URL?

    public init(
        videoId: String,
        title: String,
        artist: String,
        album: String? = nil,
        durationMs: Int,
        isrc: String? = nil,
        localFileURL: URL? = nil
    ) {
        self.videoId = videoId
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.isrc = isrc
        self.localFileURL = localFileURL
    }
}

/// Every lyrics setting the Android code reads from `AppSettings`, as one value.
///
/// Core's `AppSettings` maps onto this; the storage helpers on `LyricsSource`
/// (`enabledSources(stored:seen:)`, `sourceOrder(stored:)`) read the Android string format.
public struct LyricsPreferences: Hashable, Sendable, Codable {
    /// Time-synced lyrics on the player at all (`syncedLyrics`). Off means no source is asked.
    public var syncedLyricsEnabled: Bool
    /// The databases that may be asked (`lyricsSources`). Empty is the same as off.
    public var enabledSources: Set<LyricsSource>
    /// The order they are asked in (`lyricsSourceOrder`); a full permutation in practice.
    public var sourceOrder: [LyricsSource]
    /// Keep looking for a word-synced answer after a merely line-synced one
    /// (`prioritizeSyllableSync`). Off by default.
    public var prioritizeSyllableSync: Bool
    /// Positive delays the lyrics, negative brings them forward (`lyricsOffsetMs`), clamped
    /// to `LyricsOffset.range`.
    public var offsetMs: Int {
        didSet { offsetMs = LyricsOffset.clamp(offsetMs) }
    }
    /// Language code the translate button translates into (`translationLanguage`). Blank
    /// — the default — means "whatever the app is set to"; see `LyricsTranslationTarget`.
    public var translationLanguage: String
    /// Blur on the lines that aren't being sung (`lyricsBlur`).
    public var blurUnfocusedLines: Bool
    /// User-issued credential for api.paxsenix.org (`paxSenixApiKey`); "Bearer " prefix optional.
    public var paxSenixAPIKey: String

    public init(
        syncedLyricsEnabled: Bool = true,
        enabledSources: Set<LyricsSource> = Set(LyricsSource.allCases),
        sourceOrder: [LyricsSource] = LyricsSource.allCases,
        prioritizeSyllableSync: Bool = false,
        offsetMs: Int = 0,
        translationLanguage: String = "",
        blurUnfocusedLines: Bool = true,
        paxSenixAPIKey: String = ""
    ) {
        self.syncedLyricsEnabled = syncedLyricsEnabled
        self.enabledSources = enabledSources
        self.sourceOrder = sourceOrder
        self.prioritizeSyllableSync = prioritizeSyllableSync
        self.offsetMs = LyricsOffset.clamp(offsetMs)
        self.translationLanguage = translationLanguage
        self.blurUnfocusedLines = blurUnfocusedLines
        self.paxSenixAPIKey = paxSenixAPIKey
    }

    /// What a fresh install has.
    public static let `default` = LyricsPreferences()

    /// The sources a lookup may contact: none when synced lyrics are off.
    public var activeSources: Set<LyricsSource> { syncedLyricsEnabled ? enabledSources : [] }

    /// "Start over on *which* lyrics" (`resetLyricsSourceSettings`): every source on, in the
    /// default order, syllable priority off. Synced lyrics themselves are left alone.
    public func resettingSources() -> LyricsPreferences {
        var copy = self
        copy.enabledSources = Set(LyricsSource.allCases)
        copy.sourceOrder = LyricsSource.allCases
        copy.prioritizeSyllableSync = false
        return copy
    }
}

/// Lyrics, and which source they turned out to come from.
public struct LyricsResult: Hashable, Sendable {
    public var source: LyricsSource
    public var lines: [LyricLine]

    public init(source: LyricsSource, lines: [LyricLine]) {
        self.source = source
        self.lines = lines
    }

    /// Whether any line carries word timings.
    public var isWordSynced: Bool { lines.contains(where: \.isWordSynced) }
    /// Whether the lines are stamped at all, rather than plain text to scroll by hand.
    public var isTimed: Bool { lines.contains { $0.timeMs > 0 } }
}

/// One row of the per-track provider picker.
public enum LyricsProviderState: String, Hashable, Sendable {
    case notFetched
    case fetching
    case found
    case notFound
}

/// What a lookup reports about each provider as it goes (Android's `onSourceStarted`,
/// `onSourceResult` and `onSourceCancelled` callbacks).
public enum LyricsProviderEvent: Hashable, Sendable {
    /// The provider's request began — including a lazily started one.
    case started(LyricsSource)
    /// A completed attempt. A nil result is a genuine miss.
    case finished(LyricsSource, LyricsResult?)
    /// A race loser that was cancelled mid-flight — deliberately not reported as a miss, so
    /// the picker can turn it back into "not fetched".
    case cancelled(LyricsSource)

    public var source: LyricsSource {
        switch self {
        case .started(let source), .finished(let source, _), .cancelled(let source): source
        }
    }
}
