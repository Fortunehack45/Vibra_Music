import Foundation
import VibraMusicCore

// Ports data/stats/ArtistFacts.kt: what the Replay knows about an artist beyond their name —
// their picture, their page, and what kind of music they make.
//
// ## Why any of this needs looking up
//
// Listening is counted per *name*, because a name is the only thing every track carries. That is
// enough to rank artists and nothing else: every track carries its own sleeve (an artist chart
// illustrated with album covers reads as the page having drawn the wrong list), a browse id only
// rides along when the row that queued the track happened to have one, and nothing this app talks
// to states a genre.
//
// ## One store, two sources, two gates
//
// The picture and the page come from a YouTube Music artist search, which the app is already
// talking to constantly. The genre comes from Last.fm's `artist.getTopTags` and *is* gated
// (`genresEnabled`, wired by the app to the `replayGenres` setting and its Last.fm key): it sends
// an artist's name and nothing else, and turned off, the genre chart simply isn't drawn while
// every other chart is unaffected.
//
// Both are asked once per artist and kept on this device for good.
//
// ## iOS shape
//
// Android runs a serial worker with a 1.5 s spacing and a 5 s save timer. This class keeps the
// policy (what is worth asking, once per artist, miss expiry, caps) but leaves the scheduling to
// the app: `noticed(_:)` queues, and the app drains the queue with `resolvePending()` (for
// example from a background task while music plays — enrichment must never cost a stream a
// millisecond of latency). Network access arrives as two injected closures, so this module stays
// offline-testable and the Last.fm JSON parsing lives with the app's networking.

/// The picture and page a YouTube Music artist search returned for a name.
public struct ReplayArtistCard: Hashable, Sendable {
    /// The hit's title, exactly as the catalogue spells it.
    public var title: String
    public var imageUrl: String?
    public var browseId: String?

    public init(title: String, imageUrl: String? = nil, browseId: String? = nil) {
        self.title = title
        self.imageUrl = imageUrl
        self.browseId = browseId
    }
}

public final class ReplayArtistFacts: ReplayArtistFactsReading, @unchecked Sendable {
    public static let fileName = "artist_facts.json"
    /// An artist neither service has heard of is asked about again after this long — the reason
    /// for a miss is as often a dropped connection as an unknown artist.
    public static let retryIntervalDays = 14
    public static let maxNameLength = 120
    public static let maxGenresPerArtist = 2
    public static let maxArtists = 4_000

    struct StoredArtist: Codable, Hashable {
        var key: String
        var genres: [String] = []
        var genresAt: Int64 = 0
        var image: String? = nil
        var browseId: String? = nil
        var cardAt: Int64 = 0
    }

    private struct Stored: Codable {
        var version: Int = 2
        var artists: [StoredArtist] = []
    }

    private let store: JSONFileStore
    private let nowMillis: () -> Int64
    /// Whether genre lookups may run and their answers count. The app wires this to its
    /// `replayGenres` setting and the presence of a Last.fm key.
    public var genresEnabled: Bool
    /// A YouTube Music artist search for the name, or nil when the app hasn't wired one.
    public var cardProvider: (@Sendable (String) async -> ReplayArtistCard?)?
    /// Raw Last.fm `artist.getTopTags` tag names for the name (highest first), or nil unwired.
    public var tagProvider: (@Sendable (String) async -> [String])?

    private let lock = NSLock()
    private var known: [String: StoredArtist] = [:]
    private var queued: Set<String> = []
    private var pending: [String] = []
    private var dirty = false
    private var revisionValue = 0

    public init(
        store: JSONFileStore,
        genresEnabled: Bool = false,
        nowMillis: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.store = store
        self.genresEnabled = genresEnabled
        self.nowMillis = nowMillis
    }

    public static func standard(genresEnabled: Bool = false) -> ReplayArtistFacts {
        ReplayArtistFacts(store: .applicationSupport("Replay"), genresEnabled: genresEnabled)
    }

    // MARK: Reading (never touches the network)

    /// Bumped whenever a lookup lands. The Replay reads these facts once while building its
    /// charts, so a picture arriving a second after the page opened would otherwise not appear
    /// until the page was opened again — which for a page opened a few times a year means never.
    public var replayFactsRevision: Int { lock.withLock { revisionValue } }

    /// Names currently queued for lookup, oldest first. Exposed for the app's drain scheduling
    /// and for tests.
    public var pendingArtists: [String] { lock.withLock { pending } }

    public func replayGenres(for artist: String) -> [String] {
        lock.withLock {
            guard genresEnabled else { return [] }
            return known[key(artist)]?.genres ?? []
        }
    }

    /// A picture of the artist, or nil to fall back to whatever the row has.
    public func replayImage(for artist: String) -> String? {
        lock.withLock { known[key(artist)]?.image }
    }

    /// The artist's page, so a chart row opens it without searching first.
    public func replayBrowseId(for artist: String) -> String? {
        lock.withLock { known[key(artist)]?.browseId }
    }

    /// An artist was played. Looks them up if anything about them is missing.
    ///
    /// Called from the recording path rather than from the Replay page, so the answers accumulate
    /// quietly while music plays and the page has them in hand when it opens.
    public func noteReplayArtist(_ name: String) {
        noticed(name)
    }

    public func noticed(_ artist: String) {
        let enabled = lock.withLock { genresEnabled }
        lock.withLock {
            let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
            let k = key(trimmed)
            if k.isEmpty || k.count > Self.maxNameLength { return }
            if let entry = known[k], !wants(entry, genresEnabled: enabled) { return }
            if queued.contains(k) { return }
            queued.insert(k)
            pending.append(trimmed)
        }
    }

    private func wants(_ entry: StoredArtist, genresEnabled: Bool) -> Bool {
        let now = nowMillis()
        let retryMs = Int64(Self.retryIntervalDays) * 86_400_000
        let wantsCard = entry.browseId == nil && now - entry.cardAt > retryMs
        let wantsGenres = genresEnabled && entry.genres.isEmpty && now - entry.genresAt > retryMs
        return wantsCard || wantsGenres
    }

    // MARK: Resolving

    /// Runs every queued lookup, serially: background enrichment for a page that may not be
    /// opened for months, sharing the app's HTTP client and session with playback. Saves once at
    /// the end rather than per answer — the cache holds every artist ever played, so rewriting it
    /// per lookup meant a few hundred kilobytes per artist during a backfill.
    public func resolvePending() async {
        while true {
            let name: String? = lock.withLock {
                guard !pending.isEmpty else { return nil }
                return pending.removeFirst()
            }
            guard let name else { break }
            if replayBrowseId(for: name) == nil, let cardProvider {
                // Only when the hit is actually this artist. A search for a name nobody has
                // heard of still returns *something*, and filing a stranger's photograph under
                // someone else's name is worse than keeping the sleeve.
                let hit = await cardProvider(name)
                    .flatMap { $0.title.compare(name, options: .caseInsensitive) == .orderedSame ? $0 : nil }
                lock.withLock {
                    let k = key(name)
                    var entry = known[k] ?? StoredArtist(key: k)
                    if let image = hit?.imageUrl { entry.image = image }
                    if let browseId = hit?.browseId { entry.browseId = browseId }
                    // A miss or a wrong-artist hit still counts as asked, or it is asked on every play.
                    entry.cardAt = nowMillis()
                    known[k] = entry
                    dirty = true
                }
            }
            let enabled = lock.withLock { genresEnabled }
            if enabled, let tagProvider, (lock.withLock { known[key(name)]?.genres.isEmpty ?? true }) {
                let tags = await tagProvider(name)
                let genres = tags.lazy.compactMap(Self.canonical).reduce(into: [String]()) { acc, genre in
                    if !acc.contains(genre) { acc.append(genre) }
                }.prefix(Self.maxGenresPerArtist)
                lock.withLock {
                    let k = key(name)
                    var entry = known[k] ?? StoredArtist(key: k)
                    entry.genres = Array(genres)
                    entry.genresAt = nowMillis()
                    known[k] = entry
                    dirty = true
                }
            }
            lock.withLock {
                revisionValue += 1
                _ = queued.remove(key(name))
            }
        }
        save()
    }

    // MARK: Genres

    /// A Last.fm tag as a genre, or nil if it isn't one.
    ///
    /// Last.fm tags are folksonomy, not taxonomy: alongside "shoegaze" sit "seen live",
    /// "favourites" and "albums i own". A tag only counts if it matches the fixed vocabulary, and
    /// an artist with no matching tag contributes nothing rather than a wrong answer. Spelling
    /// variants ("hip-hop" vs "hip hop", "r&b" vs "rnb") fold to one row, because splitting one
    /// genre across two rows is the same failure as admitting "seen live", just less obvious.
    public static func canonical(_ tag: String) -> String? {
        var cleaned = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        cleaned = cleaned.replacingOccurrences(of: "-", with: " ")
        cleaned = cleaned.replacingOccurrences(of: "&", with: "and")
        cleaned = cleaned.replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { return nil }
        if let genre = vocabulary[cleaned] { return genre }
        if let alias = aliases[cleaned], let genre = vocabulary[alias] { return genre }
        return nil
    }

    private func key(_ artist: String) -> String {
        artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: Persistence

    public func load() {
        guard let stored: Stored = try? store.load(Stored.self, from: Self.fileName) else { return }
        lock.withLock {
            for artist in stored.artists { known[artist.key] = artist }
        }
    }

    public func save() {
        let shouldSave = lock.withLock { dirty }
        guard shouldSave else { return }
        lock.withLock { dirty = false }
        let artists: [StoredArtist] = lock.withLock {
            known.values.sorted { max($0.cardAt, $0.genresAt) > max($1.cardAt, $1.genresAt) }
                .prefix(Self.maxArtists).map { $0 }
        }
        try? store.save(Stored(artists: artists), to: Self.fileName)
    }

    /// Genres whose display name isn't just their words capitalised.
    private static let spellings: [String: String] = [
        "randb": "R&B", "edm": "EDM", "lo fi": "Lo-Fi", "hip hop": "Hip-Hop",
        "k pop": "K-Pop", "j pop": "J-Pop", "j rock": "J-Rock", "c pop": "C-Pop",
        "drum and bass": "Drum & Bass", "singer songwriter": "Singer-Songwriter",
        "post punk": "Post-Punk", "post rock": "Post-Rock", "bossa nova": "Bossa Nova",
    ]

    /// The genres a chart may name. A fixed list rather than a heuristic because the failure mode
    /// of a heuristic here is silent and permanent: a tag that slips through becomes a row on
    /// someone's Replay with no signal anywhere that it was wrong. Adding to this list is cheap;
    /// letting it grow itself is not.
    private static let vocabulary: [String: String] = {
        let words = [
            "pop", "rock", "hip hop", "rap", "randb", "soul", "funk", "jazz", "blues",
            "country", "folk", "indie", "indie pop", "indie rock", "alternative",
            "alternative rock", "metal", "heavy metal", "punk", "punk rock", "hardcore",
            "electronic", "house", "deep house", "techno", "trance", "dubstep",
            "drum and bass", "edm", "ambient", "lo fi", "synthpop", "disco",
            "classical", "opera", "soundtrack", "instrumental", "acoustic",
            "reggae", "reggaeton", "dancehall", "ska", "latin", "salsa", "bossa nova",
            "afrobeats", "afrobeat", "k pop", "j pop", "j rock", "c pop",
            "bollywood", "punjabi", "desi", "bhangra", "hindi", "sufi", "ghazal",
            "singer songwriter", "emo", "grunge", "shoegaze", "psychedelic",
            "progressive rock", "hard rock", "garage rock", "post punk", "new wave",
            "gospel", "christian", "world", "experimental", "trap", "drill", "grime",
            "phonk", "hyperpop", "chillout", "downtempo", "jungle", "garage",
            "bluegrass", "americana", "swing", "big band", "motown", "britpop",
            "dream pop", "art pop", "noise", "industrial", "gothic", "doom metal",
            "black metal", "death metal", "thrash metal", "metalcore", "post rock",
            "math rock", "jam band", "surf rock", "rockabilly", "boom bap",
            "cloud rap", "conscious hip hop", "west coast rap", "east coast rap",
        ]
        return Dictionary(uniqueKeysWithValues: words.map { word in
            (word, spellings[word] ?? word.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " "))
        })
    }()

    /// Tags that are a genre in the vocabulary under another name.
    private static let aliases: [String: String] = [
        "rnb": "randb", "r and b": "randb", "rhythm and blues": "randb",
        "contemporary randb": "randb", "hiphop": "hip hop", "hip hop rap": "hip hop",
        "lofi": "lo fi", "lo fi hip hop": "lo fi", "chillhop": "lo fi",
        "kpop": "k pop", "jpop": "j pop", "jrock": "j rock", "cpop": "c pop",
        "korean": "k pop", "dnb": "drum and bass", "drum n bass": "drum and bass",
        "drumandbass": "drum and bass", "electronica": "electronic", "electro": "electronic",
        "dance": "electronic", "electropop": "synthpop", "synth pop": "synthpop",
        "indierock": "indie rock", "indiepop": "indie pop", "alt rock": "alternative rock",
        "altrock": "alternative rock", "singersongwriter": "singer songwriter",
        "female vocalists": "pop", "hindi pop": "bollywood", "indian": "desi",
        "filmi": "bollywood", "afro beats": "afrobeats", "afropop": "afrobeats",
        "amapiano": "afrobeats", "regueton": "reggaeton", "latin pop": "latin",
        "trip hop": "downtempo", "nu metal": "metal", "classic rock": "rock",
        "soft rock": "rock", "pop rock": "rock", "pop punk": "punk",
        "hardcore punk": "hardcore", "orchestral": "classical", "film score": "soundtrack",
        "score": "soundtrack", "ost": "soundtrack", "chill": "chillout",
        "chillwave": "chillout", "worship": "christian", "rap rock": "rap",
        "gangsta rap": "rap", "underground hip hop": "hip hop",
    ]
}
