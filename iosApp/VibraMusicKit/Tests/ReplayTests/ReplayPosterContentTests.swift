import XCTest
import VibraMusicTestSupport
import VibraMusicCore
@testable import Replay

// The shared picture's content: header, totals, columns, albums, genres, and each story card's
// picture carrying the same facts as the card on screen.

final class ReplayPosterContentTests: XCTestCase {
    private func summary() -> ReplaySummary {
        ReplaySummary(
            period: .thisYear, label: "2026", totalMs: 9_000_000, totalPlays: 42,
            songs: [
                ReplayRankedSong(song: replaySong("s1", title: "Top Song", artist: "Top Artist"), ms: 1_000_000, plays: 20),
                ReplayRankedSong(song: replaySong("s2", title: "Second", artist: "Other"), ms: 500_000, plays: 10),
            ],
            artists: [
                ReplayRankedEntry(title: "Top Artist", artworkUrl: "https://example.test/face.jpg", browseId: "UC1", ms: 2_000_000, plays: 25),
            ],
            albums: [
                ReplayRankedEntry(title: "Big Album", subtitle: "Top Artist", artworkUrl: "https://example.test/album.jpg", ms: 900_000, plays: 12),
            ],
            genres: [
                ReplayRankedEntry(title: "Shoegaze", ms: 800_000, plays: 10),
                ReplayRankedEntry(title: "Pop", ms: 100_000, plays: 2),
            ],
            hourOfDay: Array(repeating: 0, count: 24),
            busiestDay: "2026-08-14", busiestDayMs: 900_000,
            distinctSongs: 30, distinctArtists: 8, distinctAlbums: 4, since: "2026-01"
        )
    }

    func testPosterSizeMatchesStoryCanvas() {
        XCTAssertEqual(replayPosterWidth, 1080)
        XCTAssertEqual(replayPosterHeight, 1920)
        XCTAssertEqual(replayPosterSongRows, 5)
        XCTAssertEqual(replayPosterAlbumCount, 3)
        XCTAssertEqual(replayPosterGenreCount, 4)
    }

    func testHeaderTitle() {
        XCTAssertEqual(replayPosterTitle(periodLabel: "2026"), "Replay'26")
        XCTAssertEqual(replayPosterTitle(periodLabel: "August 2026"), "Replay · August 2026")
        XCTAssertEqual(replayPosterTitle(periodLabel: "All time"), "Replay · All time")
    }

    func testCreditLine() {
        XCTAssertEqual(
            replayPosterCredit(holder: "Ada", memberSince: "01/24"),
            "ADA · MEMBER SINCE 01/24"
        )
        // No signed-in account to name: the listener label stands in.
        XCTAssertEqual(replayPosterCredit(holder: "", memberSince: nil), "VIBRA MUSIC LISTENER")
        XCTAssertEqual(replayPosterCredit(holder: "Ada", memberSince: nil), "ADA")
    }

    func testWholeReplayContent() {
        let poster = replayPosterContent(for: summary(), holder: "Ada", memberSince: "01/24")
        XCTAssertEqual(poster.title, "Replay'26")
        XCTAssertEqual(poster.creditLine, "ADA · MEMBER SINCE 01/24")
        XCTAssertEqual(poster.minutesValue, "150")
        XCTAssertEqual(poster.minutesLabel, "Minutes listened")
        XCTAssertEqual(poster.totalsLine, "42 plays · 30 songs · 8 artists")
        XCTAssertEqual(poster.songs.map(\.title), ["Top Song", "Second"])
        XCTAssertEqual(poster.artists.map(\.title), ["Top Artist"])
        XCTAssertEqual(poster.albums.map(\.title), ["Big Album"])
        XCTAssertEqual(poster.genres.map(\.title), ["Shoegaze", "Pop"])
        XCTAssertEqual(poster.footer, "Counted on this device with Vibra Music")
    }

    func testCardBodiesMatchScreenCards() {
        let s = summary()
        // Leaderboards carry the same five rows, artists circular.
        if case .leaderboard(let rows, let circular) = replayPosterCard(for: s, page: .songs) {
            XCTAssertEqual(rows.map(\.title), ["Top Song", "Second"])
            XCTAssertFalse(circular)
        } else {
            XCTFail("songs card should be a leaderboard")
        }
        if case .leaderboard(let rows, let circular) = replayPosterCard(for: s, page: .artists) {
            XCTAssertEqual(rows.map(\.title), ["Top Artist"])
            XCTAssertTrue(circular)
        } else {
            XCTFail("artists card should be a leaderboard")
        }
        if case .genreList(let rows) = replayPosterCard(for: s, page: .genres) {
            XCTAssertEqual(rows.map(\.title), ["Shoegaze", "Pop"])
            XCTAssertTrue(rows.allSatisfy { $0.artworkUrl == nil })
        } else {
            XCTFail("genres card should be a genre list")
        }
        if case .habits(let stats) = replayPosterCard(for: s, page: .habits) {
            XCTAssertEqual(stats.map(\.value), ["4", "14 August"])
        } else {
            XCTFail("habits card should be habit stats")
        }
        if case .recap(let lines) = replayPosterCard(for: s, page: .summary) {
            XCTAssertEqual(lines.map(\.label), ["Minutes", "Top song", "Top artist", "Top album", "Top genre"])
        } else {
            XCTFail("summary card should be a recap")
        }
        if case .collage(let squares, let faces) = replayPosterCard(for: s, page: .intro) {
            XCTAssertEqual(squares, ["https://example.test/art.jpg"])
            XCTAssertEqual(faces, ["https://example.test/face.jpg"])
        } else {
            XCTFail("intro card should be a collage")
        }
    }
}
