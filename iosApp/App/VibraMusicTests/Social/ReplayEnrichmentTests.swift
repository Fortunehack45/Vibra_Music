import VibraMusicCore
import Replay
import XCTest
@testable import Vibra Music

/// What the app does around Replay's numbers so they fill in: the album a track belongs to, and each
/// artist's picture, page and genres (Android's ListeningRecorder `enriched` and ArtistFacts worker).
@MainActor
final class ReplayEnrichmentTests: XCTestCase {
    private let id = "abcdefghijk"

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func add(_ id: String) { lock.withLock { ids.append(id) } }
        var all: [String] { lock.withLock { ids } }
    }

    private func bareSong(_ videoId: String? = nil, artist: String = "Some Band") -> Song {
        Song(videoId: videoId ?? id, title: "Title", artist: artist)
    }

    private func make(
        genres: Bool = true,
        calls: Calls = Calls(),
        links: Song? = nil,
        card: ReplayArtistCard? = nil,
        tags: [String] = []
    ) -> (ReplayEnrichment, ReplayListeningStats, ReplayArtistFacts) {
        let facts = ReplayArtistFacts(store: JSONFileStore(directory: makeTemporaryDirectory(self)), genresEnabled: genres)
        let stats = ReplayListeningStats(store: JSONFileStore(directory: makeTemporaryDirectory(self)), facts: facts)
        let enrichment = ReplayEnrichment(
            stats: stats, facts: facts, spacing: .zero,
            trackLinks: { videoId in
                calls.add(videoId)
                guard let links else { throw URLError(.notConnectedToInternet) }
                return links
            },
            searchArtist: { _ in card },
            topTags: { _ in tags }
        )
        return (enrichment, stats, facts)
    }

    func testATrackQueuedWithoutAnAlbumCountsTowardTheAlbumChartOnceItsLinksAreFound() async {
        var found = bareSong()
        found.albumName = "Late Album"
        found.albumId = "MPREb_late"
        found.artistId = "UCband"
        found.thumbnailUrl = "https://example.test/sleeve.jpg"
        let calls = Calls()
        let (enrichment, stats, _) = make(calls: calls, links: found)
        let song = bareSong()
        // Minutes banked before the answer lands.
        stats.record(song, playedMs: 100_000, countsAsPlay: false)
        XCTAssertTrue(stats.summary(for: .allTime).albums.isEmpty)

        XCTAssertEqual(enrichment.enriched(song), song, "the sample isn't held back for the lookup")
        await waitUntil("the album is credited") { stats.summary(for: .allTime).albums.first?.title == "Late Album" }
        XCTAssertEqual(stats.summary(for: .allTime).albums.first?.ms, 100_000)

        // Later samples carry what was found, so their minutes land on the album too.
        let later = enrichment.enriched(song)
        XCTAssertEqual(later.albumName, "Late Album")
        XCTAssertEqual(later.artistId, "UCband")
        XCTAssertEqual(later.thumbnailUrl, "https://example.test/sleeve.jpg")
        _ = enrichment.enriched(song)
        XCTAssertEqual(calls.all, [id], "a track is asked about once")
    }

    private func makeFailingOnce(calls: Calls, found: Song, retryGap: Duration) -> ReplayEnrichment {
        let facts = ReplayArtistFacts(store: JSONFileStore(directory: makeTemporaryDirectory(self)), genresEnabled: false)
        let stats = ReplayListeningStats(store: JSONFileStore(directory: makeTemporaryDirectory(self)), facts: facts)
        return ReplayEnrichment(
            stats: stats, facts: facts, spacing: .zero, retryGap: retryGap,
            trackLinks: { videoId in
                calls.add(videoId)
                if calls.all.count == 1 { throw URLError(.notConnectedToInternet) }
                return found
            },
            searchArtist: { _ in nil },
            topTags: { _ in [] }
        )
    }

    /// A lookup that failed is asked again later, not remembered as asked for good.
    func testAFailedLookupIsRetriedLater() async {
        var found = bareSong()
        found.albumName = "Late Album"
        let calls = Calls()
        let enrichment = makeFailingOnce(calls: calls, found: found, retryGap: .zero)
        _ = enrichment.enriched(bareSong())
        await waitUntil("the first lookup is made") { !calls.all.isEmpty }
        // Each call after the failure lands asks again, until an answer is kept.
        await waitUntil("the second ask finds the album") { enrichment.enriched(self.bareSong()).albumName == "Late Album" }
        XCTAssertEqual(calls.all, [id, id])
    }

    /// The retry waits out its gap: samples arrive every few seconds, and an offline device must
    /// not make a request per sample.
    func testAFailedLookupWaitsOutItsGapBeforeAskingAgain() async {
        let calls = Calls()
        let enrichment = makeFailingOnce(calls: calls, found: bareSong(), retryGap: .seconds(60))
        _ = enrichment.enriched(bareSong())
        await waitUntil("the first lookup is made") { !calls.all.isEmpty }
        try? await Task.sleep(for: .milliseconds(100))      // the failure lands and arms the gap
        for _ in 0..<5 { _ = enrichment.enriched(bareSong()) }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(calls.all, [id])
    }

    func testOnlyTracksYouTubeCanAnswerForAreLookedUp() async {
        let calls = Calls()
        let (enrichment, _, _) = make(calls: calls, links: bareSong())
        var file = bareSong()
        file.localUri = "file:///Music/a.m4a"
        _ = enrichment.enriched(file)
        _ = enrichment.enriched(bareSong("add-on-track"))
        var complete = bareSong()
        complete.albumName = "Known"
        complete.artistId = "UCknown"
        _ = enrichment.enriched(complete)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(calls.all, [])
    }

    func testAnArtistsPicturePageAndGenresFillInOffTheQueue() async {
        let card = ReplayArtistCard(title: "some band", imageUrl: "https://example.test/face.jpg", browseId: "UCband")
        let (enrichment, stats, facts) = make(card: card, tags: ["Shoegaze", "seen live"])
        var song = bareSong()
        song.artistId = nil
        stats.record(song, playedMs: 60_000, countsAsPlay: true)
        XCTAssertEqual(facts.pendingArtists, ["Some Band"], "playing queues the artist")

        enrichment.drainArtistsIfNeeded()
        await waitUntil("the artist is looked up") { facts.replayBrowseId(for: "Some Band") != nil && !facts.replayGenres(for: "Some Band").isEmpty }

        let summary = stats.summary(for: .allTime)
        XCTAssertEqual(summary.artists.first?.artworkUrl, "https://example.test/face.jpg")
        XCTAssertEqual(summary.artists.first?.browseId, "UCband")
        XCTAssertEqual(summary.genres.map(\.title), ["Shoegaze"], "only real genres count")
    }

    func testOpeningTheReplayLooksUpTheArtistsOnIt() async {
        let (enrichment, stats, facts) = make(card: ReplayArtistCard(title: "Some Band", imageUrl: "https://example.test/face.jpg", browseId: "UCband"))
        stats.record(bareSong(), playedMs: 60_000, countsAsPlay: true)
        let source = LiveReplayDataSource(stats: stats, onSummary: { enrichment.drainArtistsIfNeeded() })
        _ = await source.summary(for: .allTime)
        await waitUntil("the artist is looked up") { facts.replayBrowseId(for: "Some Band") == "UCband" }
    }

    func testGenresAreNotAskedForWhileTheyAreOff() async {
        let (enrichment, stats, facts) = make(genres: false, tags: ["Shoegaze"])
        stats.record(bareSong(), playedMs: 60_000, countsAsPlay: true)
        enrichment.drainArtistsIfNeeded()
        await waitUntil("the queue is drained") { facts.pendingArtists.isEmpty && facts.replayFactsRevision > 0 }
        XCTAssertEqual(facts.replayGenres(for: "Some Band"), [])
        facts.genresEnabled = true
        XCTAssertEqual(facts.replayGenres(for: "Some Band"), [], "nothing was stored while off")
    }

    func testLastFMTopTagsAreReadFromTheAnswerAndAskedByName() throws {
        let answer = #"{"toptags":{"tag":[{"name":"shoegaze","count":100},{"name":"seen live","count":50}],"@attr":{"artist":"Slowdive"}}}"#
        XCTAssertEqual(LastFMArtistTags.names(in: Data(answer.utf8)), ["shoegaze", "seen live"])
        XCTAssertEqual(LastFMArtistTags.names(in: Data(#"{"error":6,"message":"Artist not found"}"#.utf8)), [])
        let url = try XCTUnwrap(LastFMArtistTags.url(artist: "Simon & Garfunkel", apiKey: "k"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first { $0.name == "artist" }?.value, "Simon & Garfunkel")
        XCTAssertEqual(items?.first { $0.name == "method" }?.value, "artist.gettoptags")
        XCTAssertEqual(url.host, "ws.audioscrobbler.com")
    }

    func testTheAppWiresTheArtistLookupsAndTheRecorderIntoTheFacts() {
        let app = makeAppModel(self)
        _ = app.replayEnrichment
        XCTAssertNotNil(app.replayFacts.cardProvider, "artist search is connected")
        XCTAssertNotNil(app.replayFacts.tagProvider, "the genre search is connected")
    }
}
