import VibraMusicCore
import PlaybackQueue
import XCTest
@testable import VibraMusic

/// The widget's now-playing snapshot in the App Group (PORTING.md "Home-screen widgets", app side).
@MainActor
final class WidgetSnapshotTests: XCTestCase {
    func testPlayingWritesWhatTheWidgetShows() async throws {
        let suite = "vibramusic.shell.widget.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let harness = PlayerHarness(test: self)
        let observer = WidgetSnapshotObserver(player: harness.player, defaults: defaults, reloadsWidgets: false)
        harness.player.addObserver(observer)
        let songs = try (1...2).map { try harness.song("nnnnnnnnnn\($0)") }

        harness.player.play(songs, startAt: 0)
        await waitUntil("playing") { harness.engine.isPlaying }
        await waitUntil("the snapshot says playing") { NowPlayingSnapshot.load(from: defaults)?.isPlaying == true }

        var snapshot = try XCTUnwrap(NowPlayingSnapshot.load(from: defaults))
        XCTAssertEqual(snapshot.videoId, songs[0].videoId)
        XCTAssertEqual(snapshot.title, songs[0].title)
        XCTAssertTrue(snapshot.hasNext)
        XCTAssertFalse(snapshot.isLiked)

        harness.player.toggleLike()
        snapshot = try XCTUnwrap(NowPlayingSnapshot.load(from: defaults))
        XCTAssertTrue(snapshot.isLiked)

        harness.player.pause()
        await waitUntil("the snapshot says paused") { NowPlayingSnapshot.load(from: defaults)?.isPlaying == false }
    }

    func testTheSnapshotRoundTripsAndIgnoresAnUnknownVersion() throws {
        let suite = "vibramusic.shell.widget.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        var snapshot = NowPlayingSnapshot(videoId: "v", title: "t", artist: "a", isPlaying: true, isLiked: false, shuffleEnabled: false,
                                          repeatMode: "OFF", hasNext: true, hasPrevious: false, positionMs: 1_000, durationMs: 200_000,
                                          updatedAt: Date(timeIntervalSince1970: 1_000))
        snapshot.save(to: defaults)
        XCTAssertEqual(NowPlayingSnapshot.load(from: defaults), snapshot)
        snapshot.version = 99
        snapshot.save(to: defaults)
        XCTAssertNil(NowPlayingSnapshot.load(from: defaults))
    }
}
