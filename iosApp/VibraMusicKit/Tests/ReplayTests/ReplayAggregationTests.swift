import XCTest
import VibraMusicTestSupport
import VibraMusicCore
@testable import Replay

// Aggregation per period with a fixed clock: ranking, artist/album filing, habits, persistence,
// pruning, backfill and backup-shaped import/export.

final class ReplayAggregationTests: XCTestCase {
    private func makeStats(facts: ReplayStubFacts? = nil) throws -> (ReplayListeningStats, URL) {
        let dir = try makeTemporaryDirectory()
        let stats = ReplayListeningStats(
            store: JSONFileStore(directory: dir), facts: facts,
            now: { replayUTCDate(2026, 8, 14, 17) }, calendar: replayUTCCalendar()
        )
        return (stats, dir)
    }

    func testRanksByMinutesThenPlays() throws {
        let (stats, _) = try makeStats()
        let at = replayUTCDate(2026, 8, 14, 17)
        stats.record(replaySong("slow", title: "Slow"), playedMs: 60_000, countsAsPlay: false, at: at)
        stats.record(replaySong("fast", title: "Fast"), playedMs: 600_000, countsAsPlay: true, at: at)
        let summary = stats.summary(for: .thisMonth, today: at)
        XCTAssertEqual(summary.songs.map(\.song.videoId), ["fast", "slow"])
        XCTAssertEqual(summary.totalMs, 660_000)
        XCTAssertEqual(summary.totalPlays, 1)
        XCTAssertEqual(summary.distinctSongs, 2)
        XCTAssertFalse(summary.isEmpty)
        XCTAssertEqual(summary.since, "2026-08")
        XCTAssertEqual(summary.label, "August 2026")
    }

    func testEmptyWhenNothingRecorded() throws {
        let (stats, _) = try makeStats()
        let summary = stats.summary(for: .allTime, today: replayUTCDate(2026, 8, 14))
        XCTAssertTrue(summary.isEmpty)
        XCTAssertNil(summary.busiestDay)
        XCTAssertNil(summary.peakHour)
    }

    func testPeriodsFilterMonths() throws {
        let (stats, _) = try makeStats()
        stats.record(replaySong("july"), playedMs: 100_000, countsAsPlay: true, at: replayUTCDate(2026, 7, 3, 10))
        stats.record(replaySong("aug"), playedMs: 200_000, countsAsPlay: true, at: replayUTCDate(2026, 8, 3, 10))
        let today = replayUTCDate(2026, 8, 14)
        XCTAssertEqual(stats.summary(for: .thisMonth, today: today).songs.map(\.song.videoId), ["aug"])
        XCTAssertEqual(stats.summary(for: .thisYear, today: today).totalMs, 300_000)
        XCTAssertEqual(stats.summary(for: .allTime, today: today).totalMs, 300_000)
        XCTAssertEqual(stats.summary(for: .thisYear, today: today).label, "2026")
        XCTAssertEqual(stats.summary(for: .allTime, today: today).label, "All time")
    }

    func testLeadArtistNotWholeCredit() throws {
        let (stats, _) = try makeStats()
        let at = replayUTCDate(2026, 8, 14, 17)
        stats.record(replaySong("a", artist: "Cheema Y & Gur Sidhu"), playedMs: 100_000, countsAsPlay: true, at: at)
        stats.record(replaySong("b", artist: "Cheema Y"), playedMs: 50_000, countsAsPlay: false, at: at)
        let summary = stats.summary(for: .thisMonth, today: at)
        // One artist row, not a third artist sharing both names.
        XCTAssertEqual(summary.artists.map(\.title), ["Cheema Y"])
        XCTAssertEqual(summary.artists.first?.ms, 150_000)
        XCTAssertEqual(summary.distinctArtists, 1)
    }

    func testFeatureCreditFilesLead() {
        XCTAssertEqual(replayLeadArtist(of: "Arijit Singh feat. Shreya Ghoshal"), "Arijit Singh")
        XCTAssertEqual(replayLeadArtist(of: "Drake, Future"), "Drake")
        XCTAssertEqual(replayLeadArtist(of: "DJ Snake x Lauv"), "DJ Snake")
        XCTAssertEqual(replayLeadArtist(of: "Florence and the Machine"), "Florence and the Machine")
        XCTAssertNil(replayLeadArtist(of: "   "))
    }

    func testSameAlbumNameDifferentArtistsStaySeparate() throws {
        let (stats, _) = try makeStats()
        let at = replayUTCDate(2026, 8, 14, 17)
        stats.record(replaySong("a", artist: "Them", album: "Greatest Hits"), playedMs: 100_000, countsAsPlay: false, at: at)
        stats.record(replaySong("b", artist: "Us", album: "Greatest Hits"), playedMs: 100_000, countsAsPlay: false, at: at)
        let summary = stats.summary(for: .thisMonth, today: at)
        XCTAssertEqual(summary.albums.count, 2)
        XCTAssertEqual(summary.distinctAlbums, 2)
    }

    func testHoursDaysAndBusiest() throws {
        let (stats, _) = try makeStats()
        stats.record(replaySong("a"), playedMs: 100_000, countsAsPlay: false, at: replayUTCDate(2026, 8, 14, 17))
        stats.record(replaySong("b"), playedMs: 300_000, countsAsPlay: false, at: replayUTCDate(2026, 8, 15, 9))
        let summary = stats.summary(for: .thisMonth, today: replayUTCDate(2026, 8, 16))
        XCTAssertEqual(summary.hourOfDay[17], 100_000)
        XCTAssertEqual(summary.hourOfDay[9], 300_000)
        XCTAssertEqual(summary.peakHour, 9)
        XCTAssertEqual(summary.busiestDay, "2026-08-15")
        XCTAssertEqual(summary.busiestDayMs, 300_000)
    }

    func testPeakHourTieGoesToEarliest() throws {
        let (stats, _) = try makeStats()
        stats.record(replaySong("a"), playedMs: 100_000, countsAsPlay: false, at: replayUTCDate(2026, 8, 14, 20))
        stats.record(replaySong("b"), playedMs: 100_000, countsAsPlay: false, at: replayUTCDate(2026, 8, 14, 8))
        let summary = stats.summary(for: .thisMonth, today: replayUTCDate(2026, 8, 14))
        XCTAssertEqual(summary.peakHour, 8)
    }

    func testGenresDerivedFromArtistFacts() throws {
        let facts = ReplayStubFacts()
        facts.genres = ["Cheema Y": ["Punjabi", "Pop"]]
        let (stats, _) = try makeStats(facts: facts)
        let at = replayUTCDate(2026, 8, 14, 17)
        stats.record(replaySong("a", artist: "Cheema Y"), playedMs: 100_000, countsAsPlay: true, at: at)
        let summary = stats.summary(for: .thisMonth, today: at)
        XCTAssertEqual(summary.genres.map(\.title), ["Punjabi", "Pop"])
        XCTAssertEqual(summary.genres.first?.ms, 100_000)
        // Unknown artists vote for nothing rather than a wrong answer.
        XCTAssertTrue(summary.genres.allSatisfy { !$0.title.isEmpty })
    }

    func testArtistFactsFillMissingImageAndPage() throws {
        let facts = ReplayStubFacts()
        facts.images = ["Cheema Y": "https://example.test/face.jpg"]
        facts.browseIds = ["Cheema Y": "UCface"]
        let at = replayUTCDate(2026, 8, 14, 17)
        // No browse id rode along with the row: the facts' picture and page apply.
        let (unstamped, _) = try makeStats(facts: facts)
        var bare = replaySong("a", artist: "Cheema Y")
        bare.artistId = nil
        unstamped.record(bare, playedMs: 100_000, countsAsPlay: false, at: at)
        let plain = unstamped.summary(for: .thisMonth, today: at)
        XCTAssertEqual(plain.artists.first?.artworkUrl, "https://example.test/face.jpg")
        XCTAssertEqual(plain.artists.first?.browseId, "UCface")
        // A row that carried one keeps it: the stored id beats the looked-up one.
        let (stamped, _) = try makeStats(facts: facts)
        stamped.record(replaySong("b", artist: "Cheema Y"), playedMs: 100_000, countsAsPlay: false, at: at)
        XCTAssertEqual(stamped.summary(for: .thisMonth, today: at).artists.first?.browseId, "UC-b")
    }

    func testMissingMetadataFillsInAsItBecomesKnown() throws {
        let (stats, _) = try makeStats()
        let at = replayUTCDate(2026, 8, 14, 17)
        var bare = replaySong("a", album: nil)
        bare.albumId = nil
        bare.artistId = nil
        stats.record(bare, playedMs: 100_000, countsAsPlay: false, at: at)
        XCTAssertTrue(stats.summary(for: .thisMonth, today: at).albums.isEmpty)
        stats.noteMetadata(replaySong("a", album: "Late Album"))
        let summary = stats.summary(for: .thisMonth, today: at)
        XCTAssertEqual(summary.albums.map(\.title), ["Late Album"])
        // Totals untouched by the backfill.
        XCTAssertEqual(summary.totalMs, 100_000)
    }

    func testPersistsAcrossInstances() throws {
        let dir = try makeTemporaryDirectory()
        let calendar = replayUTCCalendar()
        let at = replayUTCDate(2026, 8, 14, 17)
        let first = ReplayListeningStats(store: JSONFileStore(directory: dir), calendar: calendar)
        first.record(replaySong("a"), playedMs: 100_000, countsAsPlay: true, at: at)
        first.flush()
        XCTAssertEqual(first.months().map(\.key), ["2026-08"])
        let second = ReplayListeningStats(store: JSONFileStore(directory: dir), calendar: calendar)
        XCTAssertEqual(second.months().map(\.key), ["2026-08"])
        let summary = second.summary(for: .thisMonth, today: at)
        XCTAssertEqual(summary.songs.map(\.song.videoId), ["a"])
        XCTAssertEqual(summary.songs.first?.plays, 1)
    }

    func testCorruptMonthDiscardedNotFatal() throws {
        let dir = try makeTemporaryDirectory()
        try "not json".write(to: dir.appending(path: "2026-08.json"), atomically: true, encoding: .utf8)
        let stats = ReplayListeningStats(store: JSONFileStore(directory: dir), calendar: replayUTCCalendar())
        XCTAssertTrue(stats.summary(for: .thisMonth, today: replayUTCDate(2026, 8, 14)).isEmpty)
    }

    func testACorruptMonthIsReplacedOnTheNextFlush() throws {
        let dir = try makeTemporaryDirectory()
        let store = JSONFileStore(directory: dir)
        try "not json".write(to: store.url(for: "2026-08.json"), atomically: true, encoding: .utf8)
        let stats = ReplayListeningStats(store: store, calendar: replayUTCCalendar())
        stats.record(replaySong("b"), playedMs: 30_000, countsAsPlay: true, at: replayUTCDate(2026, 8, 14, 17))
        stats.flush()
        let august = try XCTUnwrap(try store.load(ReplayStoredBucket.self, from: "2026-08.json"))
        XCTAssertEqual(august.tracks.map(\.id), ["b"])
    }

    /// A month file that is there but can't be read for a moment (file protection before the
    /// first unlock) is not written over as an empty month. The plays wait in memory and merge into
    /// it once it reads.
    func testAMonthThatCannotBeReadIsNotOverwrittenAndItsPlaysMergeOnceItReads() throws {
        let dir = try makeTemporaryDirectory()
        let store = JSONFileStore(directory: dir)
        try store.save(ReplayStoredBucket(month: "2026-08", tracks: [ReplayTrackEntry(id: "a", title: "A", ms: 60_000, plays: 1)],
                                          hours: (0..<24).map { $0 == 17 ? 60_000 : 0 }, days: [14: 60_000]),
                       to: "2026-08.json")
        let file = store.url(for: "2026-08.json")
        let original = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }

        let stats = ReplayListeningStats(store: store, calendar: replayUTCCalendar())
        stats.record(replaySong("b"), playedMs: 30_000, countsAsPlay: true, at: replayUTCDate(2026, 8, 14, 17))
        stats.flush()

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertEqual(try Data(contentsOf: file), original, "an unreadable month is left as it was")

        stats.flush()
        let august = try XCTUnwrap(try store.load(ReplayStoredBucket.self, from: "2026-08.json"))
        XCTAssertEqual(Set(august.tracks.map(\.id)), ["a", "b"])
        XCTAssertEqual(august.hours[17], 90_000)
        XCTAssertEqual(august.days[14], 90_000)
    }

    func testIgnoresBlankIdsAndEmptySamples() throws {
        let (stats, _) = try makeStats()
        let at = replayUTCDate(2026, 8, 14, 17)
        var blank = replaySong("a")
        blank.videoId = "  "
        stats.record(blank, playedMs: 100_000, countsAsPlay: true, at: at)
        stats.record(replaySong("b"), playedMs: 0, countsAsPlay: false, at: at)
        XCTAssertTrue(stats.summary(for: .thisMonth, today: at).isEmpty)
    }

    func testOldMonthsPrunedToKeepLimit() throws {
        let dir = try makeTemporaryDirectory()
        let store = JSONFileStore(directory: dir)
        let calendar = replayUTCCalendar()
        // 37 month files on disk; recording into a new month must retire the oldest.
        for offset in 0..<37 {
            let month = ReplayMonth(year: 2023, month: 1).advanced(by: offset)
            try store.save(ReplayStoredBucket(month: month.key), to: "\(month.key).json")
        }
        let stats = ReplayListeningStats(store: store, calendar: calendar)
        stats.record(replaySong("new"), playedMs: 1_000, countsAsPlay: false, at: replayUTCDate(2026, 8, 14, 17))
        let months = stats.months()
        XCTAssertEqual(months.count, ReplayListeningStats.keepMonths)
        XCTAssertFalse(months.map(\.key).contains("2023-01"))
        XCTAssertTrue(months.map(\.key).contains("2026-08"))
    }

    func testAGenreTakesTheFirstPictureAmongItsArtistsNotTheTopArtistsMissingOne() throws {
        let facts = ReplayStubFacts()
        facts.genres = ["Faceless": ["Rock"], "Pictured": ["Rock"]]
        let (stats, _) = try makeStats(facts: facts)
        let at = replayUTCDate(2026, 8, 14, 17)
        stats.record(replaySong("a", artist: "Faceless", art: nil), playedMs: 200_000, countsAsPlay: true, at: at)
        stats.record(replaySong("b", artist: "Pictured", art: "https://example.test/b.jpg"), playedMs: 100_000, countsAsPlay: true, at: at)
        let summary = stats.summary(for: .thisMonth, today: at)
        XCTAssertEqual(summary.genres.first?.artworkUrl, "https://example.test/b.jpg")
    }

    func testMonthsAreGregorianOnABuddhistCalendarDevice() throws {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(secondsFromGMT: 0)!
        let stats = ReplayListeningStats(store: JSONFileStore(directory: try makeTemporaryDirectory()), calendar: buddhist)
        stats.record(replaySong("a"), playedMs: 100_000, countsAsPlay: true, at: replayUTCDate(2026, 8, 14, 17))
        XCTAssertEqual(stats.exportAll().map(\.month), ["2026-08"])
    }

    /// Months a Buddhist, Japanese or ROC calendar device filed under its own year (2569-10)
    /// are renamed to the Gregorian month at launch, and merged into that month's file when it
    /// exists, so they count under This month and This year again.
    func testMonthsFiledUnderAnOffsetYearMoveToTheGregorianMonth() throws {
        let dir = try makeTemporaryDirectory()
        let store = JSONFileStore(directory: dir)
        func bucket(_ month: String, plays: Int) -> ReplayStoredBucket {
            ReplayStoredBucket(month: month, tracks: [ReplayTrackEntry(id: "a", title: "A", ms: 60_000, plays: plays)],
                               hours: (0..<24).map { $0 == 17 ? 60_000 : 0 }, days: [14: 60_000])
        }
        try store.save(bucket("2569-08", plays: 2), to: "2569-08.json")     // Buddhist, with a Gregorian twin
        try store.save(bucket("2026-08", plays: 1), to: "2026-08.json")
        try store.save(bucket("0008-07", plays: 4), to: "0008-07.json")     // Reiwa 8
        try store.save(bucket("115-06", plays: 8), to: "0115-06.json")      // Republic of China 115
        try store.save(bucket("2019-01", plays: 16), to: "2019-01.json")    // Gregorian: left alone

        let stats = ReplayListeningStats(store: store, now: { replayUTCDate(2026, 8, 14, 17) }, calendar: replayUTCCalendar())

        XCTAssertEqual(stats.months().map(\.key), ["2019-01", "2026-06", "2026-07", "2026-08"])
        let august = try XCTUnwrap(stats.exportAll().first { $0.month == "2026-08" })
        XCTAssertEqual(august.tracks.first?.plays, 3, "the two August files add together")
        XCTAssertEqual(august.tracks.first?.ms, 120_000)
        XCTAssertEqual(august.hours[17], 120_000)
        XCTAssertEqual(august.days[14], 120_000)
        let summary = stats.summary(for: .thisYear, today: replayUTCDate(2026, 8, 14))
        XCTAssertEqual(summary.totalPlays, 3 + 4 + 8)
        XCTAssertEqual(try store.fileNames().sorted(), ["2019-01.json", "2026-06.json", "2026-07.json", "2026-08.json"])
    }

    /// A Gregorian month that exists but can't be read is never written over by the move.
    func testAnUnreadableGregorianTwinIsNotOverwrittenByTheMove() throws {
        let dir = try makeTemporaryDirectory()
        let store = JSONFileStore(directory: dir)
        let moved = ReplayStoredBucket(month: "2569-08", tracks: [ReplayTrackEntry(id: "a", title: "A", ms: 60_000, plays: 2)],
                                       hours: [], days: [:])
        try store.save(moved, to: "2569-08.json")
        let unreadable = Data("not json".utf8)
        try unreadable.write(to: store.url(for: "2026-08.json"))

        _ = ReplayListeningStats(store: store, now: { replayUTCDate(2026, 8, 14, 17) }, calendar: replayUTCCalendar())

        XCTAssertEqual(try Data(contentsOf: store.url(for: "2026-08.json")), unreadable)
        XCTAssertTrue(store.exists("2569-08.json"), "kept, to be moved at a later launch")
    }

    func testAMonthKeyNeedsTwoDigitsLikeAndroid() {
        XCTAssertNil(ReplayMonth(key: "2026-8"))
        XCTAssertEqual(ReplayMonth(key: "2026-08"), ReplayMonth(year: 2026, month: 8))
    }

    func testExportImportReplaces() throws {
        let (stats, _) = try makeStats()
        let at = replayUTCDate(2026, 8, 14, 17)
        stats.record(replaySong("a"), playedMs: 100_000, countsAsPlay: true, at: at)
        let exported = stats.exportAll()
        XCTAssertEqual(exported.count, 1)

        let dir = try makeTemporaryDirectory()
        let other = ReplayListeningStats(store: JSONFileStore(directory: dir), calendar: replayUTCCalendar())
        other.record(replaySong("zzz"), playedMs: 50_000, countsAsPlay: false, at: at)
        try other.importAll(exported)
        // A replace, not a merge: the other device's month is gone, not doubled.
        let summary = other.summary(for: .thisMonth, today: at)
        XCTAssertEqual(summary.songs.map(\.song.videoId), ["a"])
        // Buckets from unparseable months are skipped.
        try other.importAll([ReplayStoredBucket(month: "not-a-month")])
        XCTAssertTrue(other.months().isEmpty)
    }

    func testAMonthThatCannotBeWrittenFailsTheImport() throws {
        // A file where the store's directory should be: every write fails.
        let blocker = try makeTemporaryDirectory().appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let stats = ReplayListeningStats(store: JSONFileStore(directory: blocker), calendar: replayUTCCalendar())
        XCTAssertThrowsError(try stats.importAll([ReplayStoredBucket(month: "2026-08", days: [3: 60_000])]))
    }
}
