import Foundation

/// What a provider is asked for: the track as the lookup prepared it.
public struct LyricsProviderRequest: Hashable, Sendable {
    public var videoId: String
    /// Already cleaned with `forLyricsSearch`.
    public var title: String
    /// Already cleaned with `artistForLyricsSearch`.
    public var artist: String
    /// Zero when unknown; providers treat it as "don't filter on length".
    public var durationMs: Int
    public var album: String?
    /// The recording, where the caller or `BiniLyricsProvider` identified it.
    public var isrc: String?

    public init(videoId: String, title: String, artist: String, durationMs: Int, album: String? = nil, isrc: String? = nil) {
        self.videoId = videoId
        self.title = title
        self.artist = artist
        self.durationMs = durationMs
        self.album = album
        self.isrc = isrc
    }

    /// Kotlin's `(durationMs / 1000).toInt()`.
    var seconds: Int { durationMs / 1000 }
}

/// A provider's answer: the lines, and — where the provider knows it — the ISRC of the
/// recording it matched, which the repository remembers for the other providers.
public struct LyricsProviderAnswer: Hashable, Sendable {
    public var lines: [LyricLine]
    public var isrc: String?

    public init(lines: [LyricLine], isrc: String? = nil) {
        self.lines = lines
        self.isrc = isrc
    }
}

/// One lyrics database. Returns nil for "not here"; throwing is also read as a miss.
public protocol LyricsProvider: Sendable {
    func lyrics(for request: LyricsProviderRequest) async throws -> LyricsProviderAnswer?
}

/// The one request made before the race — "which recording is this?" — answered with an
/// ISRC. `BiniLyricsProvider` is the only implementation; the protocol exists so tests and
/// the app can substitute it.
public protocol LyricsRecordingIdentifier: Sendable {
    func identify(_ request: LyricsProviderRequest) async throws -> String?
}

extension Array where Element == LyricLine {
    /// Kotlin's `takeIf { it.isNotEmpty() }` on a provider's parse.
    var nonEmpty: [LyricLine]? { isEmpty ? nil : self }

    var answer: LyricsProviderAnswer? { isEmpty ? nil : LyricsProviderAnswer(lines: self) }
}
