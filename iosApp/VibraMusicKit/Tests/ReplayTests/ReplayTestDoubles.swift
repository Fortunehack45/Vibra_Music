import Foundation
import VibraMusicTestSupport
import VibraMusicCore
@testable import Replay

// Shared doubles and clocks for the Replay tests. Everything is deterministic: a fixed UTC clock,
// an in-memory sink spy, and a stub facts reader.

func replayUTCCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

func replayUTCDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    var calendar = replayUTCCalendar()
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    return calendar.date(from: components)!
}

func replaySong(
    _ videoId: String,
    title: String = "Title",
    artist: String = "Artist",
    album: String? = "Album",
    duration: String? = "3:20",
    art: String? = "https://example.test/art.jpg"
) -> Song {
    Song(
        videoId: videoId, title: title, artist: artist, thumbnailUrl: art,
        durationText: duration, artistId: "UC-\(videoId)", albumId: "MPRE-\(videoId)", albumName: album
    )
}

final class ReplaySinkSpy: ReplayListeningSink, @unchecked Sendable {
    struct Sample: Sendable {
        var song: Song
        var ms: Int64
        var countsAsPlay: Bool
        var at: Date
    }

    private let lock = NSLock()
    private(set) var samples: [Sample] = []
    private(set) var flushes = 0

    func replayRecord(_ song: Song, playedMs: Int64, countsAsPlay: Bool, at date: Date) {
        lock.withLock { samples.append(Sample(song: song, ms: playedMs, countsAsPlay: countsAsPlay, at: date)) }
    }

    func replayFlush() {
        lock.withLock { flushes += 1 }
    }
}

final class ReplayStubFacts: ReplayArtistFactsReading, @unchecked Sendable {
    var genres: [String: [String]] = [:]
    var images: [String: String] = [:]
    var browseIds: [String: String] = [:]
    var noticed: [String] = []
    var revision = 0

    var replayFactsRevision: Int { revision }

    func replayGenres(for artist: String) -> [String] { genres[artist] ?? [] }
    func replayImage(for artist: String) -> String? { images[artist] }
    func replayBrowseId(for artist: String) -> String? { browseIds[artist] }
    func noteReplayArtist(_ name: String) { noticed.append(name) }
}
