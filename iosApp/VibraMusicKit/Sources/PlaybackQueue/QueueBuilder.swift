import Foundation
import VibraMusicCore

// Ports playback/QueueBuilder.kt.

/// Builds the station that plays on after a one-off song.
///
/// Two problems this exists to solve:
///
///  - YouTube's watch queues routinely carry the same recording twice — the official audio and the
///    music video are separate videoIds with near identical titles — so de-duping on id alone lets a
///    track play, then play again as its video. Songs are matched on a normalised title plus lead
///    artist instead.
///
///  - A radio mix leans hard on the seed's own artist. Capping how many tracks any one artist
///    contributes keeps a station from turning into a single artist's discography.
public enum QueueBuilder {

    /// No more than this many tracks by one artist in a single batch.
    static let perArtistLimit = 2

    /// The artist the station was seeded on gets more room, but not the run of it.
    static let seedArtistLimit = 4

    /// The subset of `candidates` worth appending after `existing`: nothing already queued, nothing
    /// repeated, at most `limit` tracks.
    public static func extend(existing: [Song], candidates: [Song], limit: Int) -> [Song] {
        var taken = existing
        var perArtist: [String: Int] = [:]
        let seedArtists = existing.last.map { artistSet($0.artist) } ?? []
        var out: [Song] = []

        // A mix pairs all but every track with its own music-video upload — the same recording
        // under a different id, titled far enough apart ("Dildaara (Stand By Me)" against "Lyrical
        // Video: Dildara Song") that no title match will catch it. The catalogue cut is the one a
        // music app wants; videos only stand in when there is nothing else.
        let songsOnly = candidates.filter { !$0.isVideo }
        let ordered = songsOnly.isEmpty ? candidates : songsOnly

        for candidate in ordered {
            if out.count >= limit { break }
            if taken.contains(where: { isSameRecording($0, candidate) }) { continue }

            let artists = artistSet(candidate.artist)
            if let key = artists.min() {
                let cap = artists.contains(where: seedArtists.contains) ? seedArtistLimit : perArtistLimit
                let played = perArtist[key] ?? 0
                if played >= cap { continue }
                perArtist[key] = played + 1
            }

            taken.append(candidate)
            out.append(candidate)
        }
        return out
    }

    /// Whether two entries are the same recording. Ids differ between the audio and video cuts of a
    /// track, which is exactly the case id equality misses.
    public static func isSameRecording(_ a: Song, _ b: Song) -> Bool {
        if a.videoId == b.videoId { return true }
        let title = normalisedTitle(a.title)
        if title.isEmpty || title != normalisedTitle(b.title) { return false }
        // One shared name is enough. The two cuts of a track get billed in whatever order the
        // upload used — "Pritam, Arijit Singh & Shilpa Rao" against "Shilpa Rao, Arijit Singh, &
        // Pritam" is one song, twice.
        let left = artistSet(a.artist)
        let right = artistSet(b.artist)
        return left.isEmpty || right.isEmpty || !left.isDisjoint(with: right)
    }

    /// `Kesariya (From "Brahmastra") | Official Video` and `Kesariya` are one recording as far as a
    /// queue is concerned. Remix and cover markers are deliberately left in — those really are
    /// different tracks.
    static func normalisedTitle(_ raw: String) -> String {
        var title = raw.lowercased()
        if let bar = title.range(of: " | ") {
            title = String(title[..<bar.lowerBound])
        }
        title = replacing(noise, in: title, with: " ")
        title = replacing(punctuation, in: title, with: " ")
        title = replacing(spaces, in: title, with: " ")
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The cast behind a credit, split out so billing order stops mattering.
    static func artistSet(_ raw: String) -> Set<String> {
        let lowered = replacing(topic, in: raw.lowercased(), with: " ")
        var names = Set<String>()
        for part in split(lowered, on: artistSeparators) {
            var name = replacing(punctuation, in: part, with: " ")
            name = replacing(spaces, in: name, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { names.insert(name) }
        }
        return names
    }

    /// Kotlin's `split(",", "&", …)`: at each position the earliest delimiter wins, ties going to
    /// the first one listed.
    private static let artistSeparators = [",", "&", "·", "•", ";", " feat", " ft.", " ft ", " x ", " with "]

    private static func split(_ text: String, on delimiters: [String]) -> [String] {
        var parts: [String] = []
        var current = Substring()
        var rest = Substring(text)
        outer: while !rest.isEmpty {
            for delimiter in delimiters where rest.hasPrefix(delimiter) {
                parts.append(String(current))
                current = Substring()
                rest = rest.dropFirst(delimiter.count)
                continue outer
            }
            current.append(rest.removeFirst())
        }
        parts.append(String(current))
        return parts
    }

    private static func replacing(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }

    // NSRegularExpression (ICU) rather than Swift Regex: it is Sendable, so these can be built once.
    private static let noise = makeRegex(
        #"\((?:official|lyric|lyrics|lyrical|audio|video|visuali[sz]er|full song|hd|4k)[^)]*\)"#
            + #"|\(from[^)]*\)"#
            + #"|\[[^\]]*\]"#
            + #"|\b(?:official (?:video|audio|music video)|lyrical video|full video|4k video)\b"#,
        caseInsensitive: true
    )
    private static let topic = makeRegex(#"\s*-\s*topic\b"#, caseInsensitive: true)
    private static let punctuation = makeRegex(#"[^\p{L}\p{N}]+"#)
    private static let spaces = makeRegex(#"\s+"#)

    private static func makeRegex(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
        } catch {
            preconditionFailure("QueueBuilder pattern \(pattern) does not compile: \(error)")
        }
    }
}
