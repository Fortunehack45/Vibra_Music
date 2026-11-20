import Foundation
import VibraMusicCore

// Ports data/sources/TrackMatcher.kt, rule for rule.

/// Decides whether one catalogue's track is the same recording as another's, and what to ask that
/// catalogue for in the first place.
///
/// Both failure modes are silent:
/// - **Too loose** and the wrong recording plays under the right title — a cover, a remix, an
///   hour-long loop — with nothing on screen to say so.
/// - **Too strict** and the source the user configured is quietly never used, which is what
///   a title with a `(From "<film>")` suffix and one credited singer does against a catalogue
///   holding the same audio under the bare title and both singers of the duet.
///
/// The way out of both is to be explicit about *which part of a title carries identity*. A title is
/// taken apart into its words (must agree exactly), its version markers — remix, live, acoustic
/// (must agree exactly, both directions) — and its context, everything thrown away with the
/// brackets (never a veto, only a tie-break). Artist and runtime are then checked against that.
public enum TrackMatcher {

    /// What a cross-source match is made on.
    public struct Target: Hashable, Sendable {
        public var title: String
        public var artist: String
        /// Runtime in whole seconds; nil when the queue row never carried one.
        public var durationSec: Int?
        /// Release name, when the queue knows it. Separates catalogue collisions.
        public var album: String?
        /// Explicit/clean edition; nil when the originating catalogue did not say.
        public var isExplicit: Bool?
        /// Music-video timing includes visual intros/outros that catalogue audio omits.
        public var isVideo: Bool

        public init(
            _ title: String,
            _ artist: String = "",
            durationSec: Int? = nil,
            album: String? = nil,
            isExplicit: Bool? = nil,
            isVideo: Bool = false
        ) {
            self.title = title
            self.artist = artist
            self.durationSec = durationSec
            self.album = album
            self.isExplicit = isExplicit
            self.isVideo = isVideo
        }
    }

    public static func targetOf(_ song: Song) -> Target {
        Target(
            song.title,
            song.artist,
            durationSec: secondsOf(song.durationText),
            album: song.albumName,
            isExplicit: song.isExplicit,
            isVideo: song.isVideo
        )
    }

    // MARK: Asking

    /// What to put to a source's search box, best query first.
    ///
    /// The raw title is deliberately not one of them: a YouTube title carries the packaging —
    /// `Paniyon Sa (From "Satyamev Jayate")` — and handing that to a catalogue that lists the track
    /// as `Paniyon Sa` asks it to match on words it has never stored. The second query drops the
    /// artist, for catalogues that credit the composer or the film rather than the singer.
    public static func queries(_ target: Target) -> [String] {
        let title = searchableTitle(target.title, artist: target.artist)
        if title.nonBlank == nil { return [] }
        let artist = primaryArtist(target.artist)
        if artist.nonBlank == nil { return [title] }
        return ["\(title) \(artist)", title]
    }

    /// The title with the packaging taken off, version markers kept.
    static func searchableTitle(_ title: String, artist: String = "") -> String {
        let parts = parseTitle(title, artist: artist)
        return (parts.words + parts.versions).joined(separator: " ")
    }

    /// The first credited artist — who a catalogue most likely files the track under.
    static func primaryArtist(_ artist: String) -> String {
        (artistSeparators.split(artist.lowercased()).first ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// Whether both credits name at least one of the same artists.
    public static func sharesArtist(_ wanted: String, _ got: String) -> Bool {
        let want = artistNames(wanted)
        let have = artistNames(got)
        return !want.isEmpty && !have.isEmpty && want.contains { w in have.contains { h in sameArtist(w, h) } }
    }

    // MARK: Judging

    /// The best of `candidates` that is genuinely `target`, or nil. Best, not first: a search
    /// answers with the single, the album cut, a sped-up edit and a karaoke version in whatever
    /// order the backend likes, and the runtime and fuller credit break that tie.
    public static func best(_ candidates: [Song], _ target: Target) -> Song? {
        ranked(candidates, target).first
    }

    /// The catalogue counterpart for a music-video upload the listener explicitly switched to audio.
    ///
    /// A video and its song can differ by well over a minute (intro, outro, dialogue), which the
    /// ordinary matcher must reject. Here an exact recording title, identical version markers and a
    /// shared artist establish the relationship; duration only ranks equivalent releases. A cover,
    /// remix or karaoke version still can't cross the switch.
    public static func bestOfficialAudioForVideo(_ candidates: [Song], _ target: Target) -> Song? {
        let wanted = parseTitle(target.title, artist: target.artist)
        guard !wanted.core.isEmpty else { return nil }
        let scored: [(Song, Int)] = candidates.compactMap { candidate in
            let got = parseTitle(candidate.title, artist: candidate.artist)
            guard wanted.core == got.core, wanted.versions == got.versions,
                  let artist = artistScore(target.artist, candidate.artist) else { return nil }
            var duration = 0
            if let expected = target.durationSec {
                duration = secondsOf(candidate.durationText).map { -abs(expected - $0) } ?? -120
            }
            return (candidate, artist * 1_000 + duration)
        }
        return stableSortedDescending(scored).first?.0
    }

    /// Every candidate that really is `target`, most confident first. The whole list rather than
    /// the winner: which copy to open is a quality question, and that belongs to
    /// ``SourceResolver``.
    public static func ranked(_ candidates: [Song], _ target: Target) -> [Song] {
        let scored: [(Song, Int)] = candidates.compactMap { candidate in
            score(candidate, target).map { (candidate, $0) }
        }
        // A runtime-identical cover is only a last-resort explanation for catalogues crediting the
        // same master differently. If the search also returned anything carrying the requested
        // artist, the different-artist rows leave contention — which also avoids opening their
        // stream URLs while a correct result waits.
        let credited = scored.filter { artistScore(target.artist, $0.0.artist) != nil }
        return stableSortedDescending(credited.isEmpty ? scored : credited).map(\.0)
    }

    /// How confident this is the same recording, or nil when it is not one. Nil is the common and
    /// safe answer: it costs a source its turn, and YouTube still plays what was asked for.
    public static func score(_ candidate: Song, _ target: Target) -> Int? {
        let wanted = parseTitle(target.title, artist: target.artist)
        let got = parseTitle(candidate.title, artist: candidate.artist)
        guard !wanted.core.isEmpty, !got.core.isEmpty, wanted.core == got.core else { return nil }
        // Both directions: the album cut must not land on the live take, nor the reverse.
        guard wanted.versions == got.versions else { return nil }

        let creditedArtist = artistScore(target.artist, candidate.artist)
        // A music video may carry a long visual intro. That drift is credible only when the row
        // names the same artist; duration must never make an unrelated artist into the song.
        guard let duration = durationScore(
            target.durationSec,
            secondsOf(candidate.durationText),
            allowVideoDrift: creditedArtist != nil
        ) else { return nil }

        let artist: Int
        if let creditedArtist {
            artist = creditedArtist
        } else if !target.isVideo, withinSeconds(candidate, target, creditOverrideSec) {
            // The credits name different people, sometimes because they describe the same
            // recording from different ends: YouTube Music may file a film song under the composer
            // who wrote it, and every store under the singer. A runtime agreeing to the second is
            // the same master; a cover or remix essentially never lands there. Only an exact
            // runtime may stand in, and never a music video's (a 3:30 track by one artist would
            // otherwise pass for another artist's 3:31 video of the same title).
            artist = creditsDisagree
        } else {
            return nil
        }
        guard let explicit = explicitScore(target.isExplicit, candidate.isExplicit) else { return nil }
        return base + artist + duration + albumScore(target.album, candidate.albumName) + explicit
            + contextScore(wanted, got)
    }

    /// Whether otherwise valid rows describe more than one release while the requested track gives
    /// no release to choose between them. JioSaavn has catalogue collisions where title and artist
    /// agree and the audio doesn't, and a different recording can be a second nearer in runtime.
    public static func hasConflictingAlbums(_ candidates: [Song], _ target: Target) -> Bool {
        if let album = target.album, album.nonBlank != nil { return false }
        let comparable = target.durationSec != nil
            ? candidates.filter { withinSeconds($0, target, durationLimitSec) }
            : candidates
        // No catalogue audio within the normal song window: an unlabelled music video with a long
        // intro. Release disagreement can't be resolved from that runtime and must not veto the
        // search's top same-artist result.
        if target.durationSec != nil, comparable.isEmpty { return false }
        return Set(comparable.compactMap { albumKey($0.albumName) }).count > 1
    }

    /// Resolves a JioSaavn release collision only when one close candidate is plainly more fully
    /// credited than every other (a film's original release names the whole vocal ensemble;
    /// compilations cut it down). A tie is not enough to guess on.
    public static func uniquelyMostCreditedCloseMatch(_ candidates: [Song], _ target: Target) -> Song? {
        let close = candidates.filter { withinSeconds($0, target, durationLimitSec) }
        guard close.count >= 2 else { return nil }
        let counted = close.map { ($0, artistNames($0.artist).count) }
        guard let top = counted.map(\.1).max(), top >= 2 else { return nil }
        let winners = counted.filter { $0.1 == top }
        return winners.count == 1 ? winners[0].0 : nil
    }

    /// Whether `candidate` states a runtime within `seconds` of `target`'s. Both halves are
    /// requirements: an unstated runtime is not a near miss, it is a candidate that can't be checked.
    public static func withinSeconds(_ candidate: Song, _ target: Target, _ seconds: Int) -> Bool {
        guard let wanted = target.durationSec, let got = secondsOf(candidate.durationText) else { return false }
        return abs(wanted - got) <= seconds
    }

    /// Yes/no, for the YouTube seed lookup behind autoplay and for tests.
    public static func matches(_ candidate: Song, title: String, artist: String, durationSec: Int? = nil) -> Bool {
        score(candidate, Target(title, artist, durationSec: durationSec)) != nil
    }

    /// Whether two runtimes differ by more than ``durationLimitSec`` — a cached or live stream that
    /// is a different edit from the requested catalogue track.
    public static func isSevereMismatch(expectedSec: Int?, actualSec: Int?) -> Bool {
        guard let expectedSec, let actualSec else { return false }
        return abs(actualSec - expectedSec) > durationLimitSec
    }

    // MARK: Title

    struct TitleParts: Hashable {
        /// The title proper, lowercased, one entry per word.
        var words: [String]
        /// `words` with everything but letters and digits removed — what identity is compared on.
        var core: String
        /// Markers meaning a different take: `remix`, `live`, `acoustic`. Sorted, like Kotlin's
        /// `sortedSetOf`, so the searchable title lists them in a stable order.
        var versions: [String]
        /// Words dropped with the packaging. A tie-break hint, never a veto.
        var context: Set<String>
    }

    static func parseTitle(_ raw: String, artist: String = "") -> TitleParts {
        var versions = Set<String>()
        var context = Set<String>()
        var text = raw.lowercased().replacingOccurrences(of: "&", with: " and ")

        // Bracketed asides, innermost first: `(From "Satyamev Jayate")`, `[Official Audio]`.
        for _ in 0..<bracketPasses {
            let matches = bracketed.regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            if matches.isEmpty { break }
            var rebuilt = ""
            var cursor = text.startIndex
            for match in matches {
                guard let whole = Range(match.range, in: text), let inner = Range(match.range(at: 1), in: text) else { continue }
                rebuilt += text[cursor..<whole.lowerBound]
                classify(String(text[inner]), &versions, &context)
                rebuilt += " "
                cursor = whole.upperBound
            }
            rebuilt += text[cursor...]
            text = rebuilt
        }
        // An unbalanced bracket — a title truncated mid-aside — takes the rest of the line with it.
        if let open = text.firstIndex(where: { $0 == "(" || $0 == "[" }) {
            classify(String(text[open...]), &versions, &context)
            text = String(text[..<open])
        }

        // Dash- and pipe-separated tails: "Paniyon Sa - Satyamev Jayate", "Song | Official Video".
        // The "Artist - Title" upload convention inverts it, so a head that is just the artist's
        // name hands over to the tail.
        for _ in 0..<dashPasses {
            guard let match = dash.firstMatch(in: text), let range = Range(match.range, in: text) else { break }
            let head = String(text[..<range.lowerBound])
            let tail = String(text[range.upperBound...])
            if isArtistName(head, artist) {
                classify(head, &versions, &context)
                text = tail
            } else {
                classify(tail, &versions, &context)
                text = head
            }
        }

        // A feat. credit belongs to the artist field wherever a catalogue prints it.
        text = featuring.replacing(in: text, with: " ")

        var words = wordSplit.split(text)
            .map { nonAlnum.replacing(in: $0, with: "") }
            .filter { !$0.isEmpty && !joiningWords.contains($0) }
        // "Paniyon Sa Full Song", "Tum Hi Ho Audio": an unbracketed trailing label. Never stripped
        // to nothing — a track really called "Song" keeps its name.
        while words.count > 1, let last = words.last, trailingNoise.contains(last) {
            words.removeLast()
        }
        return TitleParts(words: words, core: words.joined(), versions: versions.sorted(), context: context)
    }

    /// Files one dropped segment under versions or context. A segment naming a take is identity;
    /// everything else is packaging. `Album Version`, `Radio Edit` and friends read like takes and
    /// describe the ordinary release.
    private static func classify(_ segment: String, _ versions: inout Set<String>, _ context: inout Set<String>) {
        let words = wordSplit.split(segment).map { nonAlnum.replacing(in: $0, with: "") }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return }
        if neutralSegments.contains(words.joined()) { return }
        let marks = words.filter { versionWords.contains($0) }
        if !marks.isEmpty {
            versions.formUnion(marks)
            return
        }
        context.formUnion(words.filter { $0.count > 2 && !noiseWords.contains($0) })
    }

    /// Whether `text` is nothing but (part of) `artist` — the "Artist - Title" upload shape.
    private static func isArtistName(_ text: String, _ artist: String) -> Bool {
        guard artist.nonBlank != nil else { return false }
        let words = wordSplit.split(text).map { nonAlnum.replacing(in: $0, with: "") }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return false }
        let credited = Set(
            wordSplit.split(artist.lowercased()).map { nonAlnum.replacing(in: $0, with: "") }.filter { !$0.isEmpty }
        )
        return words.allSatisfy { credited.contains($0) }
    }

    // MARK: Artist

    /// Points for the credit agreeing, nil when it disagrees. A partial credit must survive — a
    /// duet's "Atif Aslam" and "Atif Aslam, Tulsi Kumar" are one recording — and a side with no
    /// credit at all scores zero: there is nothing to disagree with.
    private static func artistScore(_ wanted: String, _ got: String) -> Int? {
        let want = artistNames(wanted)
        let have = artistNames(got)
        if want.isEmpty || have.isEmpty { return 0 }
        guard sharesArtist(wanted, got) else { return nil }
        return want == have ? artistExact : artistShared
    }

    /// The credited artists, each as its own list of words, so containment is checked on whole
    /// names ("Queen" is not one of "Queensrÿche"'s artists). Single letters go: "A. R. Rahman" is
    /// "AR Rahman".
    static func artistNames(_ value: String) -> Set<[String]> {
        Set(
            artistSeparators.split(value.lowercased())
                .map { name in
                    wordSplit.split(name).map { nonAlnum.replacing(in: $0, with: "") }.filter { $0.count > 1 }
                }
                .filter { !$0.isEmpty }
        )
    }

    private static func sameArtist(_ a: [String], _ b: [String]) -> Bool { runOf(a, b) || runOf(b, a) }

    /// Whether `outer` contains `inner` as a run of whole words.
    private static func runOf(_ outer: [String], _ inner: [String]) -> Bool {
        guard !inner.isEmpty, inner.count <= outer.count else { return false }
        return (0...(outer.count - inner.count)).contains { Array(outer[$0..<($0 + inner.count)]) == inner }
    }

    // MARK: Duration, album, explicit

    /// Points for the runtimes agreeing, nil when too far apart to be the same recording. The
    /// strongest signal there is: it catches the ten-minute loop, the album-side upload, the snippet.
    private static func durationScore(_ wanted: Int?, _ got: Int?, allowVideoDrift: Bool) -> Int? {
        guard let wanted, let got else { return 0 }
        let drift = abs(wanted - got)
        if drift > durationLimitSec, allowVideoDrift, drift <= videoDurationLimitSec { return 0 }
        if drift > durationLimitSec { return nil }
        return drift <= durationTightSec ? durationTight : durationLoose
    }

    /// Exact release agreement outweighs a tight-versus-loose runtime, so the known album beats a
    /// different release one second closer. Disagreement is not a veto: compilations hold masters.
    private static func albumScore(_ wanted: String?, _ got: String?) -> Int {
        guard let want = albumKey(wanted), let have = albumKey(got) else { return 0 }
        return want == have ? albumExact : 0
    }

    /// Clean and uncensored editions can be otherwise identical. When both catalogues state the flag
    /// they must agree; an unknown side made no contradictory claim.
    private static func explicitScore(_ wanted: Bool?, _ got: Bool?) -> Int? {
        guard let wanted, let got else { return 0 }
        return wanted == got ? explicitExact : nil
    }

    /// Punctuation, spacing and a trailing edition label are formatting, not release identity.
    static func albumKey(_ value: String?) -> String? {
        var text = (value ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        for _ in 0..<bracketPasses { text = bracketed.replacing(in: text, with: " ") }
        let key = wordSplit.split(text)
            .map { nonAlnum.replacing(in: $0, with: "") }
            .filter { !$0.isEmpty && !albumNoiseWords.contains($0) }
            .joined()
        return key.isEmpty ? nil : key
    }

    /// "3:45" or "1:02:03" as whole seconds; nil for anything else (and for zero).
    public static func secondsOf(_ text: String?) -> Int? {
        guard let parts = text?.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false),
              (2...3).contains(parts.count) else { return nil }
        var total = 0
        for part in parts {
            guard let number = Int(part.trimmingCharacters(in: .whitespaces)) else { return nil }
            total = total * 60 + number
        }
        return total > 0 ? total : nil
    }

    /// "M:SS" for a runtime in seconds, as sources fill in `durationText`.
    static func durationText(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// A nudge when both listings mention the same film or album in their asides.
    private static func contextScore(_ wanted: TitleParts, _ got: TitleParts) -> Int {
        wanted.context.isDisjoint(with: got.context) ? 0 : contextShared
    }

    /// Kotlin's `sortedByDescending`, which is stable: equal scores keep their input order.
    private static func stableSortedDescending(_ scored: [(Song, Int)]) -> [(Song, Int)] {
        scored.enumerated()
            .sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }
            .map(\.element)
    }

    // MARK: Weights

    private static let base = 100
    private static let artistExact = 25
    private static let artistShared = 10
    /// A match the runtime vouched for rather than the credit: a penalty, so any properly credited
    /// candidate beats it.
    private static let creditsDisagree = -30
    /// How exactly runtimes must agree to stand in for a shared credit.
    private static let creditOverrideSec = 2
    private static let durationTight = 40
    private static let durationLoose = 15
    private static let albumExact = 35
    private static let explicitExact = 20
    private static let contextShared = 20
    /// Within this many seconds is the same master, allowing for trimmed silence.
    private static let durationTightSec = 3
    /// Past this, two tracks sharing a title are not sharing a recording.
    public static let durationLimitSec = 30
    /// Visual intros/outros can make a video substantially longer than its audio master.
    private static let videoDurationLimitSec = 90
    private static let bracketPasses = 3
    private static let dashPasses = 3

    private static let bracketed = Pattern(#"[(\[]([^()\[\]]*)[)\]]"#)
    private static let dash = Pattern(#"\s+[-–—|]+\s+"#)
    private static let featuring = Pattern(#"\b(feat|ft|featuring|with)\b.*"#)
    private static let wordSplit = Pattern(#"[\s.·]+"#)
    private static let nonAlnum = Pattern(#"[^a-z0-9]"#)
    private static let artistSeparators =
        Pattern(#"\s*(?:[,&/;·|]|\band\b|\bx\b|\bvs\.?\b|\bfeat\.?\b|\bft\.?\b|\bfeaturing\b|\bwith\b)\s*"#)

    /// What makes a listing a different recording. On one side only, refused outright.
    private static let versionWords: Set<String> = [
        "remix", "remixes", "rmx", "refix", "flip", "bootleg", "mashup", "medley",
        "live", "concert", "unplugged", "acoustic", "instrumental", "karaoke",
        // A stem is not the song: "Vocals Only" carries the right title and artist.
        "vocals", "vocal", "acapella", "acappella", "backing", "stems", "stem",
        "cover", "demo", "reprise", "remake", "rework", "extended", "edit",
        "version", "mix", "dub", "vip", "session", "sessions",
        "sped", "slowed", "reverb", "nightcore", "lofi", "orchestral", "symphonic",
        "part", "pt", "chapter",
    ]

    /// Asides that read like a version and describe the ordinary release.
    private static let neutralSegments: Set<String> = [
        "albumversion", "originalversion", "originalmix", "singleversion",
        "radioversion", "radioedit", "stereoversion", "monoversion",
        "studioversion", "fullversion", "standardversion", "explicitversion",
        "deluxeversion", "originaltrack",
    ]

    /// Packaging words, worth nothing as a tie-break because everything has them.
    private static let noiseWords: Set<String> = [
        "official", "video", "audio", "lyrics", "lyric", "lyrical", "visualizer",
        "song", "songs", "full", "music", "the", "and", "from", "feat", "ft",
        "featuring", "with", "new", "latest", "free", "download", "remaster",
        "remastered", "explicit", "clean", "bonus", "track", "deluxe", "original",
        "album", "single", "hd", "hq", "4k", "mp3",
    ]

    private static let albumNoiseWords: Set<String> = [
        "album", "deluxe", "edition", "expanded", "remaster", "remastered",
        "version", "explicit", "clean", "bonus", "anniversary",
    ]

    /// Trailing labels an upload hangs on a title with no brackets to hold them.
    private static let trailingNoise: Set<String> = [
        "song", "songs", "video", "audio", "lyrics", "lyric", "lyrical",
        "official", "full", "hd", "hq", "4k", "mp3", "ost", "soundtrack",
    ]

    /// Dropped from the core so "Jack and Jill" and "Jack & Jill" are one title.
    private static let joiningWords: Set<String> = ["and"]
}
