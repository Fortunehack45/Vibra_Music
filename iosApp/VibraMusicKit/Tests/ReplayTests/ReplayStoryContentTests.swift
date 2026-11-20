import XCTest
import VibraMusicTestSupport
import VibraMusicCore
@testable import Replay

// The content of the 8 story cards and the Replay page rows: headlines, artwork choice, hues,
// page filtering, ranked rows, hero cards, habits, recap and the queue.

final class ReplayStoryContentTests: XCTestCase {
    private func summary() -> ReplaySummary {
        ReplaySummary(
            period: .thisYear, label: "2026", totalMs: 2 * 3_600_000 + 30 * 60_000, totalPlays: 42,
            songs: [
                ReplayRankedSong(song: replaySong("s1", title: "Top Song", artist: "Top Artist"), ms: 1_000_000, plays: 20),
                ReplayRankedSong(song: replaySong("s2", title: "Second", artist: "Other"), ms: 500_000, plays: 10),
            ],
            artists: [
                ReplayRankedEntry(title: "Top Artist", artworkUrl: "https://example.test/face.jpg", browseId: "UC1", ms: 2_000_000, plays: 25),
                ReplayRankedEntry(title: "Other", ms: 100_000, plays: 2),
            ],
            albums: [
                ReplayRankedEntry(title: "Big Album", subtitle: "Top Artist", artworkUrl: "https://example.test/album.jpg", ms: 900_000, plays: 12),
            ],
            genres: [
                ReplayRankedEntry(title: "Shoegaze", ms: 800_000, plays: 10),
            ],
            hourOfDay: [Int64](repeating: 0, count: 24).withHour(21, ms: 5_000_000),
            busiestDay: "2026-08-14", busiestDayMs: 900_000,
            distinctSongs: 30, distinctArtists: 8, distinctAlbums: 4, since: "2026-01"
        )
    }

    func testHeadlines() {
        let s = summary()
        XCTAssertEqual(
            ReplayHeadlineRun.plain(replayStoryHeadline(for: s, page: .intro)),
            "Your Replay is ready."
        )
        XCTAssertEqual(
            replayStoryHeadline(for: s, page: .intro).filter(\.bold).map(\.text),
            ["Replay"]
        )
        // 2h30m = 150 minutes, always minutes and grouped.
        XCTAssertEqual(
            ReplayHeadlineRun.plain(replayStoryHeadline(for: s, page: .minutes)),
            "You spent 150 with music."
        )
        XCTAssertEqual(
            ReplayHeadlineRun.plain(replayStoryHeadline(for: s, page: .songs)),
            "In total, 42 songs filled your month."
        )
        XCTAssertEqual(
            ReplayHeadlineRun.plain(replayStoryHeadline(for: s, page: .artists)),
            "All month, One artist kept coming back."
        )
        XCTAssertEqual(
            ReplayHeadlineRun.plain(replayStoryHeadline(for: s, page: .albums)),
            "This time, One album held your attention."
        )
        XCTAssertEqual(
            ReplayHeadlineRun.plain(replayStoryHeadline(for: s, page: .genres)),
            "Together, Your genres shaped your sound."
        )
        XCTAssertEqual(
            ReplayHeadlineRun.plain(replayStoryHeadline(for: s, page: .habits)),
            "You explored 30 songs from 8 artists."
        )
        XCTAssertEqual(
            ReplayHeadlineRun.plain(replayStoryHeadline(for: s, page: .summary)),
            "Your listening had a 2026."
        )
    }

    func testHeadlineSingulars() {
        var s = summary()
        s.totalPlays = 1
        s.distinctSongs = 1
        s.distinctArtists = 1
        XCTAssertEqual(
            ReplayHeadlineRun.plain(replayStoryHeadline(for: s, page: .songs)),
            "In total, 1 song filled your month."
        )
        XCTAssertEqual(
            ReplayHeadlineRun.plain(replayStoryHeadline(for: s, page: .habits)),
            "You explored 1 song from 1 artist."
        )
    }

    func testStoryArtworkPinnedAndRotating() {
        let s = summary()
        // The three cards that are about something take that thing's artwork.
        XCTAssertEqual(replayStoryArtwork(for: s, page: .songs), "https://example.test/art.jpg")
        XCTAssertEqual(replayStoryArtwork(for: s, page: .artists), "https://example.test/face.jpg")
        XCTAssertEqual(replayStoryArtwork(for: s, page: .albums), "https://example.test/album.jpg")
        // The rest walk the pool (songs, then artists, then faces, then albums).
        XCTAssertEqual(replayStoryArtwork(for: s, page: .intro), "https://example.test/art.jpg")
        XCTAssertNotNil(replayStoryArtwork(for: s, page: .minutes))
        XCTAssertNotNil(replayStoryArtwork(for: s, page: .habits))
        XCTAssertNotNil(replayStoryArtwork(for: s, page: .summary))
        XCTAssertNil(replayStoryArtwork(for: ReplaySummary(period: .thisYear, label: "2026"), page: .intro))
    }

    func testStoryHuesDistinctPerCard() {
        let hues = ReplayStoryPage.ordered.map(replayStoryHue)
        XCTAssertEqual(hues.first, 0)
        XCTAssertEqual(Set(hues).count, ReplayStoryPage.ordered.count)
        XCTAssertEqual(replayStoryHue(.summary), 325)
    }

    func testStoryPagesSkipEmptyCategories() {
        XCTAssertEqual(replayStoryPages(for: summary()).count, 8)
        var s = summary()
        s.albums = []
        s.genres = []
        XCTAssertEqual(replayStoryPages(for: s), [.intro, .minutes, .artists, .songs, .habits, .summary])
    }

    func testRows() {
        let s = summary()
        let songs = replaySongRows(for: s)
        XCTAssertEqual(songs.first?.rank, 1)
        XCTAssertEqual(songs.first?.key, "s1")
        XCTAssertEqual(songs.first?.subtitle, "Top Artist")
        let artists = replayArtistRows(for: s)
        XCTAssertEqual(artists.first?.title, "Top Artist")
        XCTAssertNil(artists.first?.subtitle)
        let albums = replayAlbumRows(for: s)
        XCTAssertEqual(albums.first?.subtitle, "Top Artist")
        // Genre rows deliberately carry no artwork.
        let genres = replayGenreRows(for: s)
        XCTAssertEqual(genres.first?.title, "Shoegaze")
        XCTAssertNil(genres.first?.artworkUrl)
        // Blank artist means no subtitle.
        var blank = s
        blank.songs = [ReplayRankedSong(song: replaySong("x", artist: ""), ms: 1, plays: 0)]
        XCTAssertNil(replaySongRows(for: blank).first?.subtitle)
    }

    func testHeroCards() {
        let cards = replayHeroCards(for: summary())
        XCTAssertEqual(cards.map(\.page), [.minutes, .songs, .artists, .albums])
        XCTAssertEqual(cards[0].value, "150")
        XCTAssertEqual(cards[0].detail, "42 plays · 2026")
        XCTAssertEqual(cards[1].value, "Top Song")
        XCTAssertEqual(cards[1].detail, "Top Artist · 20 plays")
        XCTAssertEqual(cards[2].value, "Top Artist")
        XCTAssertEqual(cards[2].detail, "33 min · 25 plays")
        XCTAssertEqual(cards[3].detail, "Top Artist · 15 min")
        // A category with nothing in it is left out rather than shown empty.
        XCTAssertEqual(replayHeroCards(for: ReplaySummary(period: .thisYear, label: "2026")).count, 1)
    }

    func testMinutesDetail() {
        // 2h30m: hours lead, then the peak hour.
        XCTAssertEqual(
            replayMinutesDetail(for: summary()),
            "2 hours across 42 plays, mostly around 9 PM."
        )
        var small = summary()
        small.totalMs = 20 * 60_000
        small.totalPlays = 3
        small.hourOfDay = Array(repeating: 0, count: 24)
        XCTAssertEqual(replayMinutesDetail(for: small), " across 3 plays.")
    }

    func testHabitsAndRecap() {
        let stats = replayHabitStats(for: summary())
        XCTAssertEqual(stats.map(\.value), ["4", "14 August", "9 PM"])
        XCTAssertEqual(stats[1].label, "Your biggest day: 15 min")
        let lines = replayRecapLines(for: summary())
        XCTAssertEqual(lines.map(\.label), ["Minutes", "Top song", "Top artist", "Top album", "Top genre"])
        XCTAssertEqual(lines.map(\.value), ["150", "Top Song", "Top Artist", "Big Album", "Shoegaze"])
    }

    func testReplayQueueIsRankedSongs() {
        XCTAssertEqual(replayQueueSongs(for: summary()).map(\.videoId), ["s1", "s2"])
    }

    func testFormatting() {
        XCTAssertEqual(replayGrouped(1_284), "1,284")
        XCTAssertEqual(replayFormatListening(5 * 60_000), "5 min")
        XCTAssertEqual(replayFormatListening(65 * 60_000), "1h 5m")
        XCTAssertEqual(replayFormatListening(1_500 * 60_000), "1,500 min")
        XCTAssertEqual(replayFormatHour(0), "midnight")
        XCTAssertEqual(replayFormatHour(12), "midday")
        XCTAssertEqual(replayFormatHour(9), "9 AM")
        XCTAssertEqual(replayFormatHour(21), "9 PM")
        XCTAssertEqual(replayFormatDay("2026-08-14", locale: Locale(identifier: "en_US")), "14 August")
        XCTAssertEqual(replayFormatDay("not-a-date"), "not-a-date")
        XCTAssertEqual(replayCount(1, one: "play", other: "plays"), "1 play")
        XCTAssertEqual(replayCount(1_284, one: "song", other: "songs"), "1,284 songs")
    }

    func testInitialTileHueStableAndBounded() {
        let hue = replayInitialTileHue(for: "Shoegaze")
        XCTAssertEqual(hue, replayInitialTileHue(for: "Shoegaze"))
        XCTAssertTrue(hue >= 0 && hue < 360)
    }
}

private extension Array where Element == Int64 {
    func withHour(_ hour: Int, ms: Int64) -> [Int64] {
        var copy = self
        copy[hour] = ms
        return copy
    }
}
