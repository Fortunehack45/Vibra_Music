import Foundation

// Ports the stored shapes of data/stats/ListeningStats.kt (TrackEntry, NameEntry, StoredBucket)
// plus its key helpers (albumKey, primaryArtist).
//
// The JSON matches Android's field for field — `id`, `art`, `ms`, `sub`, `hours`, `days` and all —
// so a backup exported on Android restores on iOS and vice versa. Day maps encode with string
// keys (`{"14": 90000}`), which both platforms' JSON mappers produce for integer-keyed maps.

/// One track's totals inside a monthly bucket.
public struct ReplayTrackEntry: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var artist: String
    public var album: String?
    public var albumId: String?
    public var artistId: String?
    public var art: String?
    public var ms: Int64
    public var plays: Int
    public var last: Int64

    public init(
        id: String, title: String = "", artist: String = "",
        album: String? = nil, albumId: String? = nil, artistId: String? = nil, art: String? = nil,
        ms: Int64 = 0, plays: Int = 0, last: Int64 = 0
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.albumId = albumId
        self.artistId = artistId
        self.art = art
        self.ms = ms
        self.plays = plays
        self.last = last
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        album = try c.decodeIfPresent(String.self, forKey: .album)
        albumId = try c.decodeIfPresent(String.self, forKey: .albumId)
        artistId = try c.decodeIfPresent(String.self, forKey: .artistId)
        art = try c.decodeIfPresent(String.self, forKey: .art)
        ms = try c.decodeIfPresent(Int64.self, forKey: .ms) ?? 0
        plays = try c.decodeIfPresent(Int.self, forKey: .plays) ?? 0
        last = try c.decodeIfPresent(Int64.self, forKey: .last) ?? 0
    }

    /// Folds `other` into this entry. Missing metadata fills in from whoever has it; totals add.
    public mutating func absorb(_ other: ReplayTrackEntry) {
        ms += other.ms
        plays += other.plays
        last = max(last, other.last)
        if album == nil { album = other.album }
        if albumId == nil { albumId = other.albumId }
        if artistId == nil { artistId = other.artistId }
        if art == nil { art = other.art }
    }
}

/// One artist's or album's totals inside a monthly bucket.
///
/// `key` is the map key the entry was stored under. It is written for a reader's benefit and for
/// anything downstream of an export; it is deliberately *not* read back. Reading it was Android's
/// original design, and what that bought was the opposite of stability: an entry keyed by an older
/// build kept its old key forever, so the same artist ended up in two rows the moment the spelling
/// changed. Recomputing on load means a change heals itself.
public struct ReplayNameEntry: Codable, Hashable, Sendable {
    public var name: String
    public var sub: String?
    public var art: String?
    public var id: String?
    public var ms: Int64
    public var plays: Int
    public var key: String?

    public init(
        name: String = "", sub: String? = nil, art: String? = nil, id: String? = nil,
        ms: Int64 = 0, plays: Int = 0, key: String? = nil
    ) {
        self.name = name
        self.sub = sub
        self.art = art
        self.id = id
        self.ms = ms
        self.plays = plays
        self.key = key
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        sub = try c.decodeIfPresent(String.self, forKey: .sub)
        art = try c.decodeIfPresent(String.self, forKey: .art)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        ms = try c.decodeIfPresent(Int64.self, forKey: .ms) ?? 0
        plays = try c.decodeIfPresent(Int.self, forKey: .plays) ?? 0
        key = try c.decodeIfPresent(String.self, forKey: .key)
    }

    public mutating func absorb(_ other: ReplayNameEntry) {
        ms += other.ms
        plays += other.plays
        if art == nil { art = other.art }
        if id == nil { id = other.id }
    }
}

/// One calendar month on disk: the unit of storage, backup and merging.
public struct ReplayStoredBucket: Codable, Hashable, Sendable {
    public var version: Int
    public var month: String
    public var tracks: [ReplayTrackEntry]
    public var artists: [ReplayNameEntry]
    public var albums: [ReplayNameEntry]
    /// Milliseconds played per hour of the day, index 0...23.
    public var hours: [Int64]
    /// Milliseconds played per day of the month, keyed by day of month.
    public var days: [Int: Int64]

    public init(
        version: Int = 1, month: String,
        tracks: [ReplayTrackEntry] = [], artists: [ReplayNameEntry] = [], albums: [ReplayNameEntry] = [],
        hours: [Int64] = Array(repeating: 0, count: 24), days: [Int: Int64] = [:]
    ) {
        self.version = version
        self.month = month
        self.tracks = tracks
        self.artists = artists
        self.albums = albums
        self.hours = hours
        self.days = days
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        month = try c.decode(String.self, forKey: .month)
        tracks = try c.decodeIfPresent([ReplayTrackEntry].self, forKey: .tracks) ?? []
        artists = try c.decodeIfPresent([ReplayNameEntry].self, forKey: .artists) ?? []
        albums = try c.decodeIfPresent([ReplayNameEntry].self, forKey: .albums) ?? []
        hours = try c.decodeIfPresent([Int64].self, forKey: .hours) ?? Array(repeating: 0, count: 24)
        days = try c.decodeIfPresent([Int: Int64].self, forKey: .days) ?? [:]
    }
}

/// How an album is filed: its name and its artist, folded to lower case.
///
/// Joined on U+001F (unit separator) rather than a space, because that is the one character
/// neither half can contain: with a space, "Greatest Hits" by "Vol 2" and "Greatest Hits Vol" by
/// "2" file as the same album. Spelled as a scalar value rather than an escape so no invisible
/// control byte sits in the middle of a source line.
public func replayAlbumKey(name: String, artist: String) -> String {
    name.lowercased() + "\u{1F}" + artist.lowercased()
}

private let replayCreditSeparators: NSRegularExpression = {
    // Punctuation, not words: `,`, `&`, `x` and the feature markers are how every catalogue this
    // app reads joins two artists, while " and " and " with " are as often part of a band's actual
    // name — "Florence and the Machine" — so they are left alone. A name is still split wrongly
    // now and then ("Simon & Garfunkel"), which costs one duplicated chart row; not splitting at
    // all costs a row for every collaboration anyone has ever recorded.
    try! NSRegularExpression(
        pattern: #"\s*,\s*|\s+&\s+|\s+x\s+|\s+feat\.?\s+|\s+ft\.?\s+|\s+featuring\s+"#,
        options: .caseInsensitive
    )
}()

/// The lead person named on a track's credit, or nil when the credit is blank.
///
/// Deliberately separate from Core's `ArtistCredit.primary(of:)`: that helper serves scrobblers
/// and splits on fewer separators, while this one must also split features (`feat.`, `ft.`, `x`)
/// so a guest verse doesn't file a third artist who shares both names — and returns nil for a
/// blank credit so the caller files nothing instead of an empty row.
public func replayLeadArtist(of credit: String) -> String? {
    let range = NSRange(credit.startIndex..., in: credit)
    let first: String
    if let match = replayCreditSeparators.firstMatch(in: credit, range: range),
       let matchRange = Range(match.range, in: credit) {
        first = String(credit[..<matchRange.lowerBound])
    } else {
        first = credit
    }
    let name = first.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? nil : name
}
