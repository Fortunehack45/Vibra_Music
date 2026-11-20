import Foundation
import VibraMusicCore

// Ports data/stats/ListeningStats.kt: what this device has listened to, kept on this device.
//
// ## Aggregates, not an event log
//
// The obvious shape for listening history is a row per play, summed up when something asks. It is
// also the shape that grows without bound on a phone nobody is going to garbage-collect. So the
// addition happens on the way in: a track's total is a counter that goes up while it plays, and
// reading the Replay is a merge of a handful of already finished sums. The cost is what any
// aggregate costs — the raw plays are gone, so a question nobody thought of in advance cannot be
// answered later. Every question Replay asks is here.
//
// ## One file per month
//
// Buckets are calendar months in the device's own time zone, one JSON file each, under
// Application Support/Vibra Music/Replay/Listening. That is what makes "this year" and "all time"
// the same operation on different numbers of files. A month is also the granularity below which
// nothing on the Replay page asks a question; days are still counted, as a total per day inside
// the bucket, which is enough for "your biggest day" without a file per day to get there.
//
// ## Storage: JSON files, not SQLite
//
// A full bucket is capped at 600 tracks and 400 artists/albums each — well under a hundred
// kilobytes — and at most 36 are kept. The only reads are "load whole month" and "list months",
// the only writes are whole-month rewrites every few samples. SQLite would add a schema, a query
// planner and a migration story for a workload that is a dozen small JSON files; Core's
// `JSONFileStore` (atomic write-to-temp-then-rename, so a kill mid-write leaves the previous
// month rather than a truncated one) is the whole persistence story.
//
// ## Threading
//
// All methods are synchronous and serialized on an internal lock; call them off the main thread.
// `record` never touches the disk — `flush` writes the dirty months — and `summary` flushes first
// so the page agrees with what has just been playing.

/// The sink `ReplayListeningRecorder` writes through. `ReplayListeningStats` conforms; tests use a spy.
public protocol ReplayListeningSink: AnyObject, Sendable {
    func replayRecord(_ song: Song, playedMs: Int64, countsAsPlay: Bool, at: Date)
    func replayFlush()
}

public final class ReplayListeningStats: ReplayListeningSink, @unchecked Sendable {
    /// How far down the artist chart a page opening sends lookups for.
    public static let artistsToResolve = 15
    /// Three years, which is longer than "all time" means to most people.
    public static let keepMonths = 36
    /// Per-month caps: generous enough that nobody reaches them by listening, tight enough that a
    /// bucket stays well under a hundred kilobytes. Eviction is by time played, not recency — a
    /// track heard once in passing is the first thing out, and it was never going to appear on any
    /// page this data exists to draw.
    public static let maxTracks = 600
    public static let maxNames = 400

    public static func standardListeningStore() -> JSONFileStore {
        .applicationSupport("Replay/Listening")
    }

    private final class OpenBucket {
        let key: String
        var tracks: [String: ReplayTrackEntry] = [:]
        var artists: [String: ReplayNameEntry] = [:]
        var albums: [String: ReplayNameEntry] = [:]
        var hours: [Int64] = Array(repeating: 0, count: 24)
        var days: [Int: Int64] = [:]
        /// The month's file was there but couldn't be read, so this holds only the plays since.
        /// The file is read again, and these merged into it, before anything is written over it.
        var unread = false

        init(key: String) { self.key = key }

        init(key: String, stored: ReplayStoredBucket) {
            self.key = key
            for entry in stored.tracks { tracks[entry.id] = entry }
            // Re-keyed on the lead artist, so entries a previous build filed under a whole credit
            // fold into the person on read instead of sitting beside them forever. Two entries
            // that now share a key add together rather than overwriting — `associateByTo` would
            // silently drop one of their totals.
            for entry in stored.artists {
                var copy = entry
                copy.name = replayLeadArtist(of: entry.name) ?? entry.name
                let key = copy.name.lowercased()
                if var existing = artists[key] {
                    existing.absorb(copy)
                    artists[key] = existing
                } else {
                    artists[key] = copy
                }
            }
            for entry in stored.albums {
                let key = replayAlbumKey(name: entry.name, artist: entry.sub ?? "")
                if var existing = albums[key] {
                    existing.absorb(entry)
                    albums[key] = existing
                } else {
                    albums[key] = entry
                }
            }
            hours = (0..<24).map { $0 < stored.hours.count ? stored.hours[$0] : 0 }
            days = stored.days
        }

        /// Adds `other`'s totals into this month.
        func absorb(_ other: OpenBucket) {
            for (id, entry) in other.tracks {
                if var existing = tracks[id] { existing.absorb(entry); tracks[id] = existing } else { tracks[id] = entry }
            }
            for (key, entry) in other.artists {
                if var existing = artists[key] { existing.absorb(entry); artists[key] = existing } else { artists[key] = entry }
            }
            for (key, entry) in other.albums {
                if var existing = albums[key] { existing.absorb(entry); albums[key] = existing } else { albums[key] = entry }
            }
            for hour in hours.indices { hours[hour] += other.hours[hour] }
            for (day, ms) in other.days { days[day, default: 0] += ms }
        }

        func snapshot() -> ReplayStoredBucket {
            ReplayStoredBucket(
                month: key,
                tracks: Array(tracks.values),
                // `key` is written for readers and exports, never read back (see ReplayNameEntry).
                artists: artists.map { key, entry in var copy = entry; copy.key = key; return copy },
                albums: albums.map { key, entry in var copy = entry; copy.key = key; return copy },
                hours: hours, days: days
            )
        }
    }

    private struct Cached {
        var period: ReplayPeriod
        var version: Int64
        var facts: Int
        var day: String
        var summary: ReplaySummary
    }

    private let store: JSONFileStore
    private let facts: (any ReplayArtistFactsReading)?
    private let now: () -> Date
    private let calendar: Calendar
    private let lock = NSLock()
    private var open: [String: OpenBucket] = [:]
    private var dirty: Set<String> = []
    private var version: Int64 = 0
    private var cached: Cached?

    /// - `store`: where `YYYY-MM.json` buckets live. Tests point this at a temporary directory.
    /// - `facts`: artist pictures/pages/genres. Nil in tests that don't cover them.
    /// - `now`/`calendar`: the clock and time zone. Tests fix both for determinism. Only the time
    ///   zone is taken: months, days and hours are Gregorian like Android's java.time, so a
    ///   Buddhist or Persian calendar device still writes `2026-10.json` and restores the other
    ///   platform's backups.
    public init(
        store: JSONFileStore,
        facts: (any ReplayArtistFactsReading)? = nil,
        now: @escaping () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        self.store = store
        self.facts = facts
        self.now = now
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        self.calendar = gregorian
        moveOffsetYearMonths()
    }

    /// Months a Buddhist, Japanese or Republic of China calendar device filed under its own year
    /// (`2569-10.json`) before months were pinned to Gregorian: they counted under All time but
    /// dropped out of This month and This year. Renamed once at launch, merged into the Gregorian
    /// month's file when there already is one. A name that is not clearly one of those is left alone.
    private func moveOffsetYearMonths() {
        for name in (try? store.fileNames()) ?? [] {
            guard let month = ReplayMonth(fileName: name), let year = Self.gregorianYear(ofOffsetYear: month.year),
                  let moved: ReplayStoredBucket = try? store.load(ReplayStoredBucket.self, from: name) else { continue }
            let key = ReplayMonth(year: year, month: month.month).key
            var merged = OpenBucket(key: key, stored: moved)
            // A twin that exists but can't be read is left alone and this file waits for the next
            // launch: saving `moved` by itself would overwrite that month on disk.
            do {
                if let existing = try store.load(ReplayStoredBucket.self, from: "\(key).json") {
                    merged = OpenBucket(key: key, stored: existing)
                    merged.absorb(OpenBucket(key: key, stored: moved))
                }
            } catch { continue }
            // Written before the old file goes, so a failed write leaves it to be tried again.
            guard (try? store.save(merged.snapshot(), to: "\(key).json")) != nil else { continue }
            try? store.remove(name)
        }
    }

    /// The Gregorian year a file year belongs to, or nil for one that is Gregorian already.
    /// Buddhist years run 543 ahead; Japanese ones are Reiwa years (1 is 2019); Republic of China
    /// years run 1911 behind. The ranges don't overlap, and none holds a real Gregorian month.
    private static func gregorianYear(ofOffsetYear year: Int) -> Int? {
        switch year {
        case 2400...2799: return year - 543
        case 100...199: return year + 1911
        case 1...99: return year + 2018
        default: return nil
        }
    }

    public static func standard(
        facts: (any ReplayArtistFactsReading)? = nil,
        calendar: Calendar = .current
    ) -> ReplayListeningStats {
        ReplayListeningStats(store: standardListeningStore(), facts: facts, calendar: calendar)
    }

    // MARK: Writing

    /// Adds `playedMs` of `song` to the current month.
    ///
    /// `countsAsPlay` separates the two things a listener means by "played": the minutes are what
    /// actually came out of the speaker and are added on every sample; a *play* is a whole listen
    /// and is counted once, by whoever is watching the track (see `ReplayListeningRecorder`, which
    /// holds the same threshold the scrobbler uses).
    public func record(_ song: Song, playedMs: Int64, countsAsPlay: Bool, at date: Date? = nil) {
        replayRecord(song, playedMs: playedMs, countsAsPlay: countsAsPlay, at: date ?? now())
    }

    public func replayRecord(_ song: Song, playedMs: Int64, countsAsPlay: Bool, at date: Date) {
        if playedMs <= 0 && !countsAsPlay { return }
        if song.videoId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        lock.withLock {
            let at = date
            let month = ReplayMonth(at, calendar: calendar)
            let bucket = bucketFor(month)
            var track = bucket.tracks[song.videoId] ?? ReplayTrackEntry(
                id: song.videoId, title: song.title, artist: song.artist,
                album: song.albumName, albumId: song.albumId, artistId: song.artistId,
                art: song.thumbnailUrl
            )
            track.ms += playedMs
            track.last = Int64(at.timeIntervalSince1970 * 1000)
            // Filled in as it becomes known: a track queued from search reaches the player with no
            // album, and the lookup that finds one lands while it is already playing.
            if track.album == nil { track.album = song.albumName }
            if track.albumId == nil { track.albumId = song.albumId }
            if track.artistId == nil { track.artistId = song.artistId }
            if track.art == nil { track.art = song.thumbnailUrl }
            if countsAsPlay { track.plays += 1 }
            bucket.tracks[song.videoId] = track

            // The lead artist, not the credit as a string. A track billed "Cheema Y & Gur Sidhu"
            // is not a third artist who happens to share both their names; the *lead* rather than
            // everyone named, which is the reading the rest of the app already makes (a row's
            // artist id points at whoever its page opens).
            if let lead = replayLeadArtist(of: song.artist) {
                facts?.noteReplayArtist(lead)
                let key = lead.lowercased()
                var artist = bucket.artists[key] ?? ReplayNameEntry(name: lead, art: song.thumbnailUrl)
                artist.ms += playedMs
                if countsAsPlay { artist.plays += 1 }
                if artist.id == nil { artist.id = song.artistId }
                bucket.artists[key] = artist
            }

            let albumName = song.albumName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !albumName.isEmpty {
                // Keyed on album *and* artist: "Greatest Hits" is not one release, and merging
                // every one of them into a single row is how a compilation nobody owns tops the
                // album chart.
                let key = replayAlbumKey(name: albumName, artist: song.artist)
                var album = bucket.albums[key] ?? ReplayNameEntry(name: albumName, sub: song.artist, art: song.thumbnailUrl)
                album.ms += playedMs
                if countsAsPlay { album.plays += 1 }
                if album.id == nil { album.id = song.albumId }
                bucket.albums[key] = album
            }

            let hour = calendar.component(.hour, from: at)
            if (0..<24).contains(hour) { bucket.hours[hour] += playedMs }
            let day = calendar.component(.day, from: at)
            bucket.days[day, default: 0] += playedMs
            dirty.insert(bucket.key)
        }
    }

    /// Backfills metadata for a track whose lookup has just landed (the artist page, the album),
    /// in every month that holds the track.
    ///
    /// The player asks this same question while its screen is up, but most listening happens with
    /// the phone in a pocket — exactly the listening that would otherwise go uncredited on the
    /// album chart. The app calls this when its track-links lookup resolves. Totals are untouched;
    /// only missing metadata fills in, and a track whose album arrives late contributes the
    /// minutes it already banked to that album's row — as if the album had been known when they
    /// played. Calling twice is a no-op: only nil fields fill.
    public func noteMetadata(_ song: Song) {
        lock.withLock {
            for key in monthsLocked() {
                let bucket = bucketFor(key)
                guard var track = bucket.tracks[song.videoId] else { continue }
                if track.album == nil, let album = song.albumName {
                    track.album = album
                    // The minutes were banked before the album was known; move them onto the
                    // album's own row now, creating it when this track is its first.
                    let albumKey = replayAlbumKey(name: album, artist: track.artist)
                    var row = bucket.albums[albumKey] ?? ReplayNameEntry(
                        name: album, sub: track.artist, art: song.thumbnailUrl ?? track.art
                    )
                    row.ms += track.ms
                    row.plays += track.plays
                    if row.id == nil { row.id = song.albumId ?? track.albumId }
                    if row.art == nil { row.art = song.thumbnailUrl ?? track.art }
                    bucket.albums[albumKey] = row
                    dirty.insert(bucket.key)
                }
                if track.albumId == nil, let albumId = song.albumId {
                    track.albumId = albumId
                    dirty.insert(bucket.key)
                }
                if track.artistId == nil, let artistId = song.artistId {
                    track.artistId = artistId
                    // The artist row exists already (it is keyed by name, which was always
                    // known); it just never got a page to open.
                    if let lead = replayLeadArtist(of: track.artist) {
                        let artistKey = lead.lowercased()
                        if var row = bucket.artists[artistKey], row.id == nil {
                            row.id = artistId
                            bucket.artists[artistKey] = row
                        }
                    }
                    dirty.insert(bucket.key)
                }
                if track.art == nil, let art = song.thumbnailUrl {
                    track.art = art
                    dirty.insert(bucket.key)
                }
                bucket.tracks[song.videoId] = track
            }
            // monthsLocked also covers open buckets with no file yet.
            for (key, bucket) in open where bucket.tracks[song.videoId] != nil {
                dirty.insert(key)
            }
        }
    }

    /// Writes every changed month out. Called on a cadence rather than on every sample: the
    /// numbers are worth losing a few seconds of, and a music player has better uses for its disk
    /// than re-serialising a month every time a track ticks over.
    public func flush() {
        replayFlush()
    }

    public func replayFlush() {
        let pending: [(String, ReplayStoredBucket)] = lock.withLock {
            let keys = dirty
            dirty.removeAll()
            return keys.compactMap { key -> (String, ReplayStoredBucket)? in
                guard var bucket = open[key] else { return nil }
                if bucket.unread, let month = ReplayMonth(key: key) { bucket = bucketFor(month) }
                if bucket.unread {
                    // Still unreadable: saving now would put these plays alone over the month on
                    // disk. They stay dirty and are written once the file reads.
                    dirty.insert(key)
                    return nil
                }
                return (key, bucket.snapshot())
            }
        }
        var wrote = false
        for (key, snapshot) in pending {
            do {
                try store.save(snapshot, to: "\(key).json")
                wrote = true
            } catch {
                // A failed write re-dirties so the numbers aren't silently dropped; the next
                // flush retries. (Logging lives in the app; this module has no Logger of its own.)
                lock.withLock { _ = dirty.insert(key) }
            }
        }
        if wrote { lock.withLock { version += 1 } }
    }

    // MARK: Reading

    /// The Replay for `period`, merged off disk. Flushes first so the page agrees with what has
    /// just been playing. Results are cached on every input to the merge (period, stored version,
    /// artist-facts revision, and — because "this month" and "this year" are relative — the day),
    /// since the Library tab asks for this often and usually for an unchanged answer.
    public func summary(for period: ReplayPeriod, today todayDate: Date? = nil) -> ReplaySummary {
        flush()
        let today = todayDate ?? now()
        let todayMonth = ReplayMonth(today, calendar: calendar)
        let dayKey = String(format: "%04d-%02d-%02d",
                            calendar.component(.year, from: today),
                            calendar.component(.month, from: today),
                            calendar.component(.day, from: today))
        let factsRevision = facts?.replayFactsRevision ?? 0
        if let cached {
            if cached.period == period, cached.version == lock.withLock({ version }),
               cached.facts == factsRevision, cached.day == dayKey {
                return cached.summary
            }
        }
        var merger = ReplayBucketMerger()
        for month in months() where period.covers(monthKey: month.key, today: todayMonth) {
            if let bucket = read(month.key) { merger.add(bucket) }
        }
        let summary = merger.toSummary(period: period, label: period.label(today: today, calendar: calendar), facts: facts)
        let currentVersion = lock.withLock { version }
        lock.withLock { cached = Cached(period: period, version: currentVersion, facts: factsRevision, day: dayKey, summary: summary) }
        return summary
    }

    /// Every month with a file, oldest first. Unparseable files are ignored, never deleted here.
    public func months() -> [ReplayMonth] {
        lock.withLock { monthsLocked() }
    }

    private func monthsLocked() -> [ReplayMonth] {
        var months = Set(open.keys.compactMap(ReplayMonth.init(key:)))
        if let names = try? store.fileNames() {
            for name in names {
                if let month = ReplayMonth(fileName: name) { months.insert(month) }
            }
        }
        return months.sorted()
    }

    private func bucketFor(_ month: ReplayMonth) -> OpenBucket {
        let held = open[month.key]
        if let held, !held.unread { return held }
        let bucket: OpenBucket
        do {
            bucket = OpenBucket(key: month.key, stored: try load(month.key) ?? ReplayStoredBucket(month: month.key))
        } catch {
            // The file is there but can't be read right now (file protection before the first
            // unlock, a passing file-system error). Taking it for an empty month would write that
            // over it on the next flush, so plays are held apart until a later call reads it.
            if let held { return held }
            bucket = OpenBucket(key: month.key)
            bucket.unread = true
        }
        if let held { bucket.absorb(held) }
        open[month.key] = bucket
        prune()
        return bucket
    }

    /// The month on disk, or nil when it has no file or the file is corrupt. Throws when the file
    /// is there but can't be read, so a caller can tell that apart from an empty month.
    private func load(_ key: String) throws -> ReplayStoredBucket? {
        do {
            return try store.load(ReplayStoredBucket.self, from: "\(key).json")
        } catch is DecodingError {
            // Corrupt months are discarded (and overwritten on the next flush) rather than crashing
            // the page: one bad file must not take the whole Replay with it.
            return nil
        }
    }

    private func read(_ key: String) -> ReplayStoredBucket? {
        try? load(key)
    }

    /// Keeps the folder to `keepMonths` and each open bucket to its entry caps.
    private func prune() {
        let existing = monthsLocked()
        if existing.count > Self.keepMonths {
            for stale in existing.prefix(existing.count - Self.keepMonths) {
                try? store.remove("\(stale.key).json")
                open.removeValue(forKey: stale.key)
            }
        }
        for bucket in open.values {
            trim(&bucket.tracks, limit: Self.maxTracks) { $0.ms }
            trim(&bucket.artists, limit: Self.maxNames) { $0.ms }
            trim(&bucket.albums, limit: Self.maxNames) { $0.ms }
        }
    }

    private func trim<Value>(_ map: inout [String: Value], limit: Int, weight: (Value) -> Int64) {
        if map.count <= limit { return }
        let victims = map.sorted { weight($0.value) < weight($1.value) }.prefix(map.count - limit)
        for victim in victims { map.removeValue(forKey: victim.key) }
    }

    // MARK: Backup

    /// Every bucket, for `ReplayBackup`.
    public func exportAll() -> [ReplayStoredBucket] {
        flush()
        return months().compactMap { read($0.key) }
    }

    /// Replaces everything held with `buckets`.
    ///
    /// A replace rather than a merge, and deliberately so: an import is a restore onto a new
    /// device, and two copies of the same month added together would silently double every number
    /// on the page with no way to tell afterwards.
    ///
    /// Throws on the first month it cannot write, so a restore that fell short says so instead of
    /// reporting success.
    public func importAll(_ buckets: [ReplayStoredBucket]) throws {
        try lock.withLock {
            open.removeAll()
            dirty.removeAll()
            version += 1
            cached = nil
            // Written before anything is removed, so a restore cut short leaves too much rather
            // than nothing; the months the backup lacks go only once every month is on disk.
            var written: Set<String> = []
            for bucket in buckets {
                guard ReplayMonth(key: bucket.month) != nil else { continue }
                let name = "\(bucket.month).json"
                try store.save(bucket, to: name)
                written.insert(name)
            }
            for name in (try? store.fileNames()) ?? [] where !written.contains(name) {
                try? store.remove(name)
            }
        }
    }
}
