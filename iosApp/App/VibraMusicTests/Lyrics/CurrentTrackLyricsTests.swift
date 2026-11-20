import VibraMusicCore
import Lyrics
import PlaybackQueue
import SwiftUI
import XCTest
@testable import VibraMusic

/// The playing track's lyrics belong to the app, not to the player screen (Android: the lyrics
/// state in MainViewModel, loaded from MainActivity's LaunchedEffect on the track). Closing the
/// player and opening it again must not bring back the lyrics placeholder. Before this,
/// every presentation of Now Playing built a new session and looked the lyrics up
/// again.
@MainActor
final class CurrentTrackLyricsTests: XCTestCase {
    /// Counts the lookups that reach a provider.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [String] = []
        func record(_ videoId: String) { lock.withLock { requests.append(videoId) } }
        var count: Int { lock.withLock { requests.count } }
        func count(for videoId: String) -> Int { lock.withLock { requests.filter { $0 == videoId }.count } }
    }

    private struct CountingProvider: LyricsProvider {
        let counter: Counter
        let lines: [LyricLine]?

        func lyrics(for request: LyricsProviderRequest) async throws -> LyricsProviderAnswer? {
            counter.record(request.videoId)
            try await Task.sleep(for: .milliseconds(20))
            return lines.map { LyricsProviderAnswer(lines: $0) }
        }
    }

    /// Every source answers through the counter; with one source switched on, one lookup is one
    /// provider request.
    private func makeHolder(counter: Counter) -> CurrentTrackLyrics {
        var overrides: [Lyrics.LyricsSource: any LyricsProvider] = [:]
        for source in Lyrics.LyricsSource.allCases {
            overrides[source] = CountingProvider(counter: counter, lines: LyricsDemo.wordSynced)
        }
        let repository = LyricsRepository(overrides: overrides)
        return CurrentTrackLyrics(repository: repository)
    }

    private func oneSourceSettings() -> AppSettings {
        let settings = makeTestSettings()
        settings.syncedLyrics = true
        settings.lyricsSources = [VibraMusicCore.LyricsSource.lrcLib]
        return settings
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// A track starts with the player closed: its lyrics are looked up then, once — the duration
    /// landing a beat later doesn't look them up again — and the player, opened afterwards, shows
    /// the loaded lines on its first frame, with no placeholder.
    func testStartingATrackWithThePlayerClosedLooksItUpOnceAndThePlayerOpensOnTheLines() async throws {
        let settings = oneSourceSettings()
        let harness = PlayerHarness(test: self, settings: settings)
        let counter = Counter()
        let holder = makeHolder(counter: counter)
        holder.follow(player: harness.player, settings: settings)
        defer { holder.stopFollowing() }

        let song = try harness.song("lyr-a")
        harness.player.play([song], source: QueueSource(title: "An Album", type: .browse, id: "MPREb_lyr"))
        await waitUntil("the lyrics are loaded") { holder.session.lines != nil }
        await waitUntil("the player knows the track's length") { harness.player.duration > 0 }
        await settle()
        XCTAssertEqual(counter.count(for: "lyr-a"), 1, "one lookup for the track")
        XCTAssertEqual(holder.trackId, "lyr-a")

        // Now the player opens.
        let model = NowPlayingModel(lyrics: holder)
        XCTAssertTrue(model.lyrics === holder.session)
        let app = makeNowPlayingApp(settings: settings)
        let host = renderLyricsView(
            LyricsPanel()
                .environment(model.lyrics)
                .nowPlayingEnvironment(app: app, harness: harness),
            settings: settings
        )
        XCTAssertFalse(host.view.lyricsDescendants(of: LyricLineUIView.self).isEmpty, "the lines, not the loading placeholder")
        XCTAssertEqual(counter.count(for: "lyr-a"), 1, "opening the player looks nothing up")
    }

    /// Open, dismiss, reopen: the same session every time, no new request, nothing to wait for.
    func testReopeningThePlayerKeepsTheSameSessionAndMakesNoRequest() async throws {
        let settings = oneSourceSettings()
        let counter = Counter()
        let holder = makeHolder(counter: counter)
        let song = Song(videoId: "lyr-b", title: "Lighthouse", artist: "Vibra Music", durationText: "3:20")
        holder.update(song: song, playerDuration: 200, settings: settings)
        await waitUntil("loaded") { holder.session.isChecked }
        let loaded = holder.session

        for _ in 0..<3 {
            // Each presentation of Now Playing makes a new model (a new @State).
            let model = NowPlayingModel(lyrics: holder)
            XCTAssertTrue(model.lyrics === loaded)
            XCTAssertTrue(model.lyrics.isChecked, "no loading state to show")
            XCTAssertNotNil(model.lyrics.lines)
            // What the open player feeds back on appearing is the same key: a no-op.
            holder.update(song: song, playerDuration: 200, settings: settings)
            XCTAssertTrue(holder.session === loaded)
        }
        await settle()
        XCTAssertEqual(counter.count, 1)
    }

    /// A new track gets a new session; the old one's lines are gone with it.
    func testChangingTrackStartsANewSession() async {
        let settings = oneSourceSettings()
        let counter = Counter()
        let holder = makeHolder(counter: counter)
        let first = Song(videoId: "lyr-c", title: "One", artist: "A", durationText: "3:00")
        let second = Song(videoId: "lyr-d", title: "Two", artist: "B", durationText: "3:00")
        holder.update(song: first, playerDuration: 180, settings: settings)
        await waitUntil("first loaded") { holder.session.isChecked }
        let firstSession = holder.session

        holder.update(song: second, playerDuration: 0, settings: settings)
        XCTAssertFalse(holder.session === firstSession)
        XCTAssertNil(holder.session.lines, "nothing of the last track's")
        XCTAssertEqual(holder.trackId, "lyr-d")
        await waitUntil("second loaded") { holder.session.isChecked }
        XCTAssertEqual(counter.count(for: "lyr-c"), 1)
        XCTAssertEqual(counter.count(for: "lyr-d"), 1)
    }

    /// No length anywhere yet (not the player's, not the catalogue's): the lookup waits, and the
    /// duration's arrival starts it — once.
    func testALateDurationStartsTheLookupOnce() async {
        let settings = oneSourceSettings()
        let counter = Counter()
        let holder = makeHolder(counter: counter)
        let song = Song(videoId: "lyr-e", title: "Late", artist: "C")
        XCTAssertEqual(song.durationMillis, 0)
        holder.update(song: song, playerDuration: 0, settings: settings)
        await settle()
        XCTAssertEqual(counter.count, 0, "nothing to match on yet")
        let session = holder.session

        holder.update(song: song, playerDuration: 212.4, settings: settings)
        await waitUntil("loaded") { holder.session.isChecked }
        holder.update(song: song, playerDuration: 212.4, settings: settings)
        await settle()
        XCTAssertEqual(counter.count, 1)
        XCTAssertTrue(holder.session === session, "the same track keeps its session")
    }

    /// Turning a source on applies to the track already playing (the key carries the sources).
    func testTogglingALyricsSourceReloadsTheCurrentTrack() async throws {
        let settings = oneSourceSettings()
        let harness = PlayerHarness(test: self, settings: settings)
        let counter = Counter()
        let holder = makeHolder(counter: counter)
        holder.follow(player: harness.player, settings: settings)
        defer { holder.stopFollowing() }
        let song = try harness.song("lyr-f")
        harness.player.play([song], source: QueueSource(title: "An Album", type: .browse, id: "MPREb_lyr"))
        await waitUntil("loaded") { holder.session.isChecked }
        await settle()
        XCTAssertEqual(counter.count, 1)

        settings.lyricsSources = [VibraMusicCore.LyricsSource.lrcLib, VibraMusicCore.LyricsSource.betterLyrics]
        await waitUntil("looked up again") { counter.count > 1 }
        await waitUntil("reloaded") { holder.session.isChecked }
        XCTAssertEqual(holder.trackId, "lyr-f")
    }

    /// The key Android's LaunchedEffect is keyed on.
    func testTheKeyIsTheTrackThePlayersLengthAndTheLyricSettings() {
        let settings = oneSourceSettings()
        let song = Song(videoId: "k", title: "K", artist: "K", durationText: "3:00")
        let base = CurrentTrackLyrics.key(song: song, playerDuration: 0, settings: settings)
        XCTAssertNotEqual(base, CurrentTrackLyrics.key(song: song, playerDuration: 180, settings: settings))
        settings.syncedLyrics = false
        XCTAssertNotEqual(base, CurrentTrackLyrics.key(song: song, playerDuration: 0, settings: settings))
        settings.syncedLyrics = true
        settings.lyricsSourceOrder = settings.lyricsSourceOrder.reversed()
        XCTAssertEqual(base, CurrentTrackLyrics.key(song: song, playerDuration: 0, settings: settings), "the order isn't in Android's key")
    }
}
