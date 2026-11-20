import Foundation
import VibraMusicCore

// Ports the summary half of data/stats/ListeningStats.kt (ReplaySummary, RankedEntry, RankedSong)
// and the merge that builds it (MergedBucket).

/// A row on one of the artist/album/genre charts.
public struct ReplayRankedEntry: Hashable, Sendable {
    public var title: String
    public var subtitle: String?
    public var artworkUrl: String?
    public var browseId: String?
    public var ms: Int64
    public var plays: Int

    public init(title: String, subtitle: String? = nil, artworkUrl: String? = nil, browseId: String? = nil, ms: Int64 = 0, plays: Int = 0) {
        self.title = title
        self.subtitle = subtitle
        self.artworkUrl = artworkUrl
        self.browseId = browseId
        self.ms = ms
        self.plays = plays
    }
}

/// A song row, which keeps the whole `Song` so tapping it can play it.
public struct ReplayRankedSong: Hashable, Sendable {
    public var song: Song
    public var ms: Int64
    public var plays: Int

    public init(song: Song, ms: Int64 = 0, plays: Int = 0) {
        self.song = song
        self.ms = ms
        self.plays = plays
    }
}

/// Everything the Replay page and the stories draw, worked out once.
///
/// Deliberately a plain value with the charts already sorted: the stories flip between eight views
/// of the same numbers, and recomputing a ranking per page would put a sort on the swipe.
public struct ReplaySummary: Hashable, Sendable {
    public var period: ReplayPeriod
    public var label: String
    public var totalMs: Int64
    public var totalPlays: Int
    public var songs: [ReplayRankedSong]
    public var artists: [ReplayRankedEntry]
    public var albums: [ReplayRankedEntry]
    public var genres: [ReplayRankedEntry]
    public var hourOfDay: [Int64]
    /// `YYYY-MM-DD` of the day with the most listening, or nil when there is none.
    public var busiestDay: String?
    public var busiestDayMs: Int64
    public var distinctSongs: Int
    public var distinctArtists: Int
    public var distinctAlbums: Int
    /// The earliest month with anything in it, `YYYY-MM`.
    public var since: String?

    public init(
        period: ReplayPeriod, label: String, totalMs: Int64 = 0, totalPlays: Int = 0,
        songs: [ReplayRankedSong] = [], artists: [ReplayRankedEntry] = [], albums: [ReplayRankedEntry] = [],
        genres: [ReplayRankedEntry] = [], hourOfDay: [Int64] = Array(repeating: 0, count: 24),
        busiestDay: String? = nil, busiestDayMs: Int64 = 0,
        distinctSongs: Int = 0, distinctArtists: Int = 0, distinctAlbums: Int = 0,
        since: String? = nil
    ) {
        self.period = period
        self.label = label
        self.totalMs = totalMs
        self.totalPlays = totalPlays
        self.songs = songs
        self.artists = artists
        self.albums = albums
        self.genres = genres
        self.hourOfDay = hourOfDay
        self.busiestDay = busiestDay
        self.busiestDayMs = busiestDayMs
        self.distinctSongs = distinctSongs
        self.distinctArtists = distinctArtists
        self.distinctAlbums = distinctAlbums
        self.since = since
    }

    public var minutes: Int64 { totalMs / 60_000 }
    public var hours: Int64 { totalMs / 3_600_000 }

    /// Whether there is anything at all to draw. One track is enough: a minimum here was tried
    /// (five minutes, on the reasoning that a chart of two songs is not a chart) and it was wrong
    /// in the only way that matters — someone who just played a couple of songs and went looking
    /// for the page is told they have not listened to anything, which reads as the feature being
    /// broken. A small Replay is a small Replay, and it grows.
    public var isEmpty: Bool { songs.isEmpty }

    /// The hour of the day with the most listening, or nil if nothing was. Ties go to the
    /// earliest hour, matching Android's `maxByOrNull` (first maximum wins).
    public var peakHour: Int? {
        var best: Int?
        var bestMs: Int64 = 0
        for (hour, ms) in hourOfDay.enumerated() where ms > bestMs {
            bestMs = ms
            best = hour
        }
        return best
    }
}

/// The facts about artists a summary build may consult: picture, page and genres.
///
/// `ReplayListeningStats` reads through this protocol so tests can inject a stub and the app can
/// wire the real `ReplayArtistFacts` without this module depending on networking. All reads are
/// synchronous off what is already known — an artist that isn't yet known keeps the track's sleeve
/// and no genre this time round.
public protocol ReplayArtistFactsReading: Sendable {
    /// Bumped whenever a lookup lands, so a summary built earlier can tell it is stale.
    var replayFactsRevision: Int { get }
    func replayGenres(for artist: String) -> [String]
    func replayImage(for artist: String) -> String?
    func replayBrowseId(for artist: String) -> String?
    /// An artist was played, or appeared on a page being built; queues a lookup if needed.
    func noteReplayArtist(_ name: String)
}

/// Merges stored monthly buckets into a summary. Internal: `ReplayListeningStats` owns the only
/// call site, but the merge is pure over its inputs (buckets + facts) so tests can drive it
/// without touching the disk.
struct ReplayBucketMerger {
    var tracks: [String: ReplayTrackEntry] = [:]
    var artists: [String: ReplayNameEntry] = [:]
    var albums: [String: ReplayNameEntry] = [:]
    var hours: [Int64] = Array(repeating: 0, count: 24)
    var days: [String: Int64] = [:]
    var earliest: String?

    mutating func add(_ bucket: ReplayStoredBucket) {
        for entry in bucket.tracks {
            if var existing = tracks[entry.id] {
                existing.absorb(entry)
                tracks[entry.id] = existing
            } else {
                tracks[entry.id] = entry
            }
        }
        for entry in bucket.artists {
            // Re-keyed on the lead artist, so entries a previous build filed under a whole credit
            // fold into the person on read instead of sitting beside them forever.
            let lead = replayLeadArtist(of: entry.name) ?? entry.name
            var copy = entry
            copy.name = lead
            let key = lead.lowercased()
            if var existing = artists[key] {
                existing.absorb(copy)
                artists[key] = existing
            } else {
                artists[key] = copy
            }
        }
        for entry in bucket.albums {
            let key = replayAlbumKey(name: entry.name, artist: entry.sub ?? "")
            if var existing = albums[key] {
                existing.absorb(entry)
                albums[key] = existing
            } else {
                albums[key] = entry
            }
        }
        for hour in 0..<24 {
            hours[hour] += hour < bucket.hours.count ? bucket.hours[hour] : 0
        }
        for (day, ms) in bucket.days {
            let date = String(format: "%@-%02d", bucket.month, day)
            days[date, default: 0] += ms
        }
        if earliest == nil || bucket.month < earliest! {
            earliest = bucket.month
        }
    }

    func toSummary(period: ReplayPeriod, label: String, facts: (any ReplayArtistFactsReading)?) -> ReplaySummary {
        let rankedSongs = tracks.values
            .sorted { $0.ms != $1.ms ? $0.ms > $1.ms : $0.plays > $1.plays }
            .map { entry in
                ReplayRankedSong(
                    song: Song(
                        videoId: entry.id, title: entry.title, artist: entry.artist,
                        thumbnailUrl: entry.art, artistId: entry.artistId,
                        albumId: entry.albumId, albumName: entry.album
                    ),
                    ms: entry.ms, plays: entry.plays
                )
            }
        // The artist's own picture and page where one has been found, and the track's sleeve
        // where one hasn't. Resolved here rather than stored in the bucket because it is a fact
        // about the artist, not about the evening they were played on: written into every month it
        // would freeze at whatever was known the first time they came up, and be missing from
        // every month before that.
        let rankedArtists = artists.values
            .sorted { $0.ms != $1.ms ? $0.ms > $1.ms : $0.plays > $1.plays }
            .map { entry in
                ReplayRankedEntry(
                    title: entry.name, subtitle: entry.sub,
                    artworkUrl: facts?.replayImage(for: entry.name) ?? entry.art,
                    browseId: entry.id ?? facts?.replayBrowseId(for: entry.name),
                    ms: entry.ms, plays: entry.plays
                )
            }
        let rankedAlbums = albums.values
            .sorted { $0.ms != $1.ms ? $0.ms > $1.ms : $0.plays > $1.plays }
            .map { ReplayRankedEntry(title: $0.name, subtitle: $0.sub, artworkUrl: $0.art, browseId: $0.id, ms: $0.ms, plays: $0.plays) }

        // Genres are derived rather than stored. An artist with no tag yet simply doesn't vote,
        // which is why this can be an empty list on a page whose other charts are full. Order is
        // first appearance (then by total): ties keep the order the artists introduced them in,
        // matching Android's insertion-ordered merge.
        var genreOrder: [String] = []
        var genreMs: [String: Int64] = [:]
        var genrePlays: [String: Int] = [:]
        var genreArt: [String: String] = [:]
        for artist in rankedArtists {
            for genre in facts?.replayGenres(for: artist.title) ?? [] {
                if genreMs[genre] == nil { genreOrder.append(genre) }
                genreMs[genre, default: 0] += artist.ms
                genrePlays[genre, default: 0] += artist.plays
                if genreArt[genre] == nil { genreArt[genre] = artist.artworkUrl }  // nil leaves it to the next artist
            }
        }
        // Anything still missing a picture is asked about now, so opening the page is a second
        // way for these to fill in — the first being playing the music, which is no help to
        // someone who has just installed a build that started collecting them.
        rankedArtists.prefix(ReplayListeningStats.artistsToResolve)
            .filter { $0.artworkUrl == nil || $0.browseId == nil }
            .forEach { facts?.noteReplayArtist($0.title) }

        let rankedGenres = genreOrder
            .sorted { (genreMs[$0] ?? 0) > (genreMs[$1] ?? 0) }
            .map { genre in
                ReplayRankedEntry(
                    title: genre, subtitle: nil,
                    artworkUrl: genreArt[genre], browseId: nil,
                    ms: genreMs[genre] ?? 0, plays: genrePlays[genre] ?? 0
                )
            }

        var busiestDay: String?
        var busiestDayMs: Int64 = 0
        for (day, ms) in days where ms > busiestDayMs {
            busiestDayMs = ms
            busiestDay = day
        }
        return ReplaySummary(
            period: period, label: label,
            totalMs: tracks.values.reduce(0) { $0 + $1.ms },
            totalPlays: tracks.values.reduce(0) { $0 + $1.plays },
            songs: rankedSongs, artists: rankedArtists, albums: rankedAlbums, genres: rankedGenres,
            hourOfDay: hours,
            busiestDay: busiestDay, busiestDayMs: busiestDayMs,
            distinctSongs: tracks.count, distinctArtists: artists.count, distinctAlbums: albums.count,
            since: earliest
        )
    }
}
