import Foundation

/// Which provider a clip came from — read by the player UI to decide whether the backdrop
/// should keep re-tinting itself off the clip as it loops rather than settling on its first
/// frame. Spotify's Canvas gets the periodic re-tint; the other three don't (Android:
/// `CanvasSource` in `data/canvas/CanvasArtwork.kt`).
public enum CanvasSource: String, Codable, Hashable, Sendable {
    case spotify = "SPOTIFY"
    case other = "OTHER"
}

/// A looping video that stands in for a track's cover art — what Spotify calls a Canvas
/// and Apple calls motion artwork (Android: `CanvasArtwork` in `data/canvas/CanvasArtwork.kt`).
///
/// `url` is what the player mounts; `fallbackUrl` is tried once if that errors, which is how
/// the Apple provider hands over a second rendition of the same clip when the preferred one
/// won't decode. The three metadata fields are not decoration: providers search by free text
/// and will happily return the wrong album's clip, so `matches` re-checks the answer against
/// what's playing.
///
/// Loop metadata for the UI: the clip is a short segment meant to repeat for the whole track.
/// Mount `playbackURLs[0]` in an `AVPlayerLayer` and loop it (`AVPlayerLooper` for MP4, or a
/// boundary-time observer seeking back to zero for HLS); fall to `playbackURLs[1]` on error.
public struct CanvasArtwork: Codable, Hashable, Sendable {
    public var url: String
    public var fallbackUrl: String?
    /// The 3:4 tall rendition, when the provider has one beside the square (Apple's motion
    /// artwork): never mounted by the player, only offered to the iOS lock screen's full-screen
    /// key.
    public var tallUrl: String?
    public var title: String?
    public var artist: String?
    public var album: String?
    public var source: CanvasSource

    public init(
        url: String,
        fallbackUrl: String? = nil,
        tallUrl: String? = nil,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        source: CanvasSource = .other
    ) {
        self.url = url
        self.fallbackUrl = fallbackUrl
        self.tallUrl = tallUrl
        self.title = title
        self.artist = artist
        self.album = album
        self.source = source
    }

    /// Whether this clip really belongs to the track we asked about.
    ///
    /// Title and artists must match exactly once punctuation, case and accents are stripped —
    /// a near miss here is a different song by the same artist, which is the one failure mode
    /// users notice. The album is only held to that standard when both sides know it:
    /// Vibra Music resolves a track's album asynchronously after the player opens, and a track
    /// queued from search may never get one, so requiring it outright would mean no canvas
    /// at all for most of a session.
    public func matches(title wantTitle: String, artist wantArtist: String, album wantAlbum: String?) -> Bool {
        let titleOk = title == nil || wantTitle.isBlankForCanvas ||
            title!.normalizedForCanvasMatch == wantTitle.normalizedForCanvasMatch

        let titleArtists = wantArtist.canvasArtists
        let ourArtists = (artist ?? "").canvasArtists
        let artistOk = artist == nil || wantArtist.isBlankForCanvas ||
            (!titleArtists.isEmpty && !ourArtists.isEmpty &&
                titleArtists.allSatisfy { want in ourArtists.contains(want) })

        let albumOk = album.isNullOrBlankForCanvas || wantAlbum.isNullOrBlankForCanvas ||
            album!.normalizedForCanvasMatch == wantAlbum!.normalizedForCanvasMatch

        return titleOk && artistOk && albumOk
    }

    /// Apple serves motion artwork as HLS; Spotify, Tidal and the community index serve MP4.
    public var isHLS: Bool {
        url.lowercased().contains(".m3u8")
    }

    /// URLs to mount in order: the primary clip, then the fallback rendition when present.
    public var playbackURLs: [URL] {
        [url, fallbackUrl].compactMap { $0 }.compactMap(URL.init(string:))
    }
}

// MARK: - Text matching

extension String {
    /// Case, accents and punctuation all differ between YouTube Music, Apple and Tidal for
    /// the same release — "Beyoncé - CRAZY IN LOVE (feat. JAY-Z)" against "Beyonce Crazy in
    /// Love feat Jay Z". Fold all three away before comparing.
    var normalizedForCanvasMatch: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US_POSIX"))
            .lowercased()
            .unicodeScalars.map { scalar in
                (CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) ||
                    CharacterSet.whitespaces.contains(scalar)) ? Character(scalar) : " "
            }.reduce(into: "") { $0.append($1) }
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// One credit string into its individual artists. Every service picks its own separator —
    /// commas, ampersands, "feat.", a bare "x" between collaborators — so comparing the joined
    /// strings would fail on formatting alone.
    var canvasArtists: [String] {
        canvasSplitArtists(self)
    }

    var isBlankForCanvas: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isNullOrBlankForCanvas: Bool { isBlankForCanvas }
}

extension Optional where Wrapped == String {
    var isNullOrBlankForCanvas: Bool {
        switch self {
        case .none: return true
        case .some(let value): return value.isBlankForCanvas
        }
    }
}

func canvasSplitArtists(_ raw: String) -> [String] {
    CanvasText.artistSeparators.split(raw)
        .map { $0.normalizedForCanvasMatch }
        .filter { !$0.isBlankForCanvas }
}

enum CanvasText {
    /// `(?:\s*,\s*|\s*&\s*|\s+×\s+|\s+x\s+|\bfeat\.?\b|\bft\.?\b|\bfeaturing\b|\bwith\b)`,
    /// case-insensitive — the same separator set as Android's `ARTIST_SEPARATORS`.
    static let artistSeparators: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "(?:\\s*,\\s*|\\s*&\\s*|\\s+×\\s+|\\s+x\\s+|\\bfeat\\.?\\b|\\bft\\.?\\b|\\bfeaturing\\b|\\bwith\\b)",
            options: .caseInsensitive
        )
    }()

    /// YouTube Music titles carry packaging the catalogue services never see — "| Official
    /// Video", bracketed tags, "(Lyrical)". Searching with it finds nothing and matching
    /// against it rejects everything, so it comes off before either. Same treatment as the
    /// lyrics lookup gives it (Android: `CanvasRepository.cleaned`).
    static func cleanedTrackText(_ value: String) -> String {
        let withoutNoise = noise.stringByReplacingMatches(
            in: value, range: NSRange(value.startIndex..., in: value), withTemplate: " ")
        let beforePipe = withoutNoise.components(separatedBy: " | ").first ?? withoutNoise
        let collapsed = beforePipe.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? value : collapsed
    }

    private static let noise: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "\\((?:from|official|lyrical|video|audio)[^)]*\\)|\\[[^\\]]*\\]|" +
                "\\b(?:official (?:video|audio|music video)|lyrical|full song|4k video)\\b",
            options: .caseInsensitive
        )
    }()
}

private extension NSRegularExpression {
    func split(_ string: String) -> [String] {
        let range = NSRange(string.startIndex..., in: string)
        var parts: [String] = []
        var start = string.startIndex
        for match in matches(in: string, range: range) {
            guard let matchRange = Range(match.range, in: string) else { continue }
            parts.append(String(string[start..<matchRange.lowerBound]))
            start = matchRange.upperBound
        }
        parts.append(String(string[start...]))
        return parts
    }
}
