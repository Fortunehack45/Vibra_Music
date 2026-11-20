import VibraMusicCore
import SwiftUI
import XCTest
@testable import VibraMusic

/// PORTING.md "Home-screen widgets": the small and medium widgets show the current song, and
/// play/pause works (MediaWidget.kt, MediaWidgetPill.kt, MediaWidgetActions.kt).
@MainActor
final class HomeScreenWidgetTests: XCTestCase {
    private func snapshot(playing: Bool = true, artist: String = "Daft Punk", hasPrevious: Bool = false, hasNext: Bool = true,
                          liked: Bool = false, shuffle: Bool = false) -> NowPlayingSnapshot {
        NowPlayingSnapshot(videoId: "v1", title: "Get Lucky", artist: artist, isPlaying: playing, isLiked: liked, shuffleEnabled: shuffle,
                           repeatMode: "OFF", hasNext: hasNext, hasPrevious: hasPrevious, positionMs: 0, durationMs: 1_000, updatedAt: Date())
    }

    func testTheWidgetShowsTheCurrentSongAndTheToggleFollowsPlayWhenReady() {
        let face = WidgetFace(snapshot(playing: true))
        XCTAssertTrue(face.hasTrack)
        XCTAssertEqual(face.title, "Get Lucky")
        XCTAssertEqual(face.artist, "Daft Punk")
        XCTAssertEqual(face.pillTitle, "Get Lucky - Daft Punk")
        XCTAssertEqual(face.toggleSymbol, "pause.fill")
        XCTAssertEqual(face.toggleLabel, L10n.widgetPause)

        let paused = WidgetFace(snapshot(playing: false))
        XCTAssertEqual(paused.toggleSymbol, "play.fill")
        XCTAssertEqual(paused.toggleLabel, L10n.widgetPlay)
    }

    func testTheEndsOfTheQueueAreDimmedAndABlankArtistIsHidden() {
        let face = WidgetFace(snapshot(artist: "  ", hasPrevious: false, hasNext: true))
        XCTAssertNil(face.artist, "the 4×2 hides a blank artist line")
        XCTAssertEqual(face.pillTitle, "Get Lucky", "the 4×1 shows the title alone")
        XCTAssertEqual(face.opacity(.previous), WidgetFace.disabledOpacity, accuracy: 0.001)
        XCTAssertEqual(face.opacity(.next), WidgetFace.enabledOpacity)
        XCTAssertEqual(face.opacity(.togglePlayPause), WidgetFace.enabledOpacity)
    }

    func testBeforeAnythingHasPlayedEveryControlIsDimmedAndTheTitleSaysSo() {
        let face = WidgetFace(nil)
        XCTAssertFalse(face.hasTrack)
        XCTAssertEqual(face.title, L10n.widgetNothingPlayed)
        XCTAssertEqual(face.pillTitle, L10n.widgetNothingPlayed)
        for action in WidgetTransportAction.allCases {
            XCTAssertEqual(face.opacity(action), WidgetFace.disabledOpacity, accuracy: 0.001, "\(action)")
        }
    }

    func testThePillsHeartAndShuffleFollowTheSnapshot() {
        let face = WidgetFace(snapshot(liked: true, shuffle: true))
        XCTAssertEqual(face.likeSymbol, "heart.fill")
        XCTAssertEqual(face.likeLabel, L10n.removeFromLiked)
        XCTAssertEqual(face.shuffleLabel, L10n.shuffleOn)
        let off = WidgetFace(snapshot(liked: false, shuffle: false))
        XCTAssertEqual(off.likeSymbol, "heart")
        XCTAssertEqual(off.likeLabel, L10n.like)
        XCTAssertEqual(off.shuffleLabel, L10n.shuffleOff)
    }

    /// The widget's strings come out of the app's string catalog, as L10n's do.
    func testWidgetStringsAreTheAppsLocalizedStrings() {
        XCTAssertEqual(SharedStrings.widgetNothingPlayed, L10n.widgetNothingPlayed)
        XCTAssertEqual(SharedStrings.widgetSquareLabel, L10n.widgetSquareLabel)
        XCTAssertNotEqual(SharedStrings.widgetPillDescription, "widget_pill_description")
    }

    /// The widget can't read the app's defaults, so the in-app language is mirrored into the App
    /// Group, once per change.
    func testTheInAppLanguageIsMirroredForTheWidget() throws {
        let appSuite = "vibramusic.system.lang.app.\(UUID().uuidString)"
        let groupSuite = "vibramusic.system.lang.group.\(UUID().uuidString)"
        let app = try XCTUnwrap(UserDefaults(suiteName: appSuite))
        let group = try XCTUnwrap(UserDefaults(suiteName: groupSuite))
        addTeardownBlock {
            app.removePersistentDomain(forName: appSuite)
            group.removePersistentDomain(forName: groupSuite)
        }
        let mirror = WidgetLanguageMirror.shared
        app.set("de", forKey: SharedStrings.languageOverrideKey)
        XCTAssertTrue(mirror.sync(from: app, to: group, reload: false))
        XCTAssertEqual(group.string(forKey: SharedStrings.languageOverrideKey), "de")
        XCTAssertFalse(mirror.sync(from: app, to: group, reload: false), "unchanged: no redraw")
        app.removeObject(forKey: SharedStrings.languageOverrideKey)
        XCTAssertTrue(mirror.sync(from: app, to: group, reload: false))
        XCTAssertNil(group.string(forKey: SharedStrings.languageOverrideKey), "back to the system language")
    }

    /// Play/pause, next, previous, like and shuffle, as the widget's buttons run them in the app.
    func testTheWidgetsButtonsDriveThePlayer() async throws {
        let suite = "vibramusic.system.widget.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let harness = PlayerHarness(test: self)
        let observer = WidgetSnapshotObserver(player: harness.player, defaults: defaults, reloadsWidgets: false)
        harness.player.addObserver(observer)
        let songs = try (1...3).map { try harness.song("wwwwwwwwww\($0)") }
        harness.player.play(songs, startAt: 0)
        await waitUntil("playing") { harness.engine.isPlaying }

        WidgetTransport.perform(.togglePlayPause, player: harness.player, defaults: defaults, reloadWidgets: false)
        XCTAssertFalse(harness.player.playWhenReady, "a tap while playing pauses")
        await waitUntil("the widget says paused") { NowPlayingSnapshot.load(from: defaults)?.isPlaying == false }

        WidgetTransport.perform(.togglePlayPause, player: harness.player, defaults: defaults, reloadWidgets: false)
        XCTAssertTrue(harness.player.playWhenReady, "and a second tap plays")
        await waitUntil("the widget says playing") { NowPlayingSnapshot.load(from: defaults)?.isPlaying == true }

        WidgetTransport.perform(.next, player: harness.player, defaults: defaults, reloadWidgets: false)
        await waitUntil("next") { harness.player.currentSong?.videoId == songs[1].videoId }
        WidgetTransport.perform(.previous, player: harness.player, defaults: defaults, reloadWidgets: false)
        await waitUntil("previous") { harness.player.currentSong?.videoId == songs[0].videoId }

        WidgetTransport.perform(.like, player: harness.player, defaults: defaults, reloadWidgets: false)
        XCTAssertEqual(harness.player.likeStatus(), .like)
        XCTAssertEqual(NowPlayingSnapshot.load(from: defaults)?.isLiked, true)

        WidgetTransport.perform(.shuffle, player: harness.player, defaults: defaults, reloadWidgets: false)
        XCTAssertTrue(harness.player.shuffleEnabled)
        XCTAssertEqual(NowPlayingSnapshot.load(from: defaults)?.shuffleEnabled, true, "shuffle is written for the 4×1's button")
    }

    /// Shuffle toggled inside the app (Now Playing's button, not the widget's) still reaches the
    /// widget: it isn't a playback event, so the snapshot observer watches the queue for it.
    func testShuffleToggledInTheAppIsPublishedToTheWidget() async throws {
        let suite = "vibramusic.system.widget.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let harness = PlayerHarness(test: self)
        let observer = WidgetSnapshotObserver(player: harness.player, defaults: defaults, reloadsWidgets: false)
        harness.player.addObserver(observer)
        let songs = try (1...3).map { try harness.song("ssssssssss\($0)") }
        harness.player.play(songs, startAt: 0)
        await waitUntil("the widget has the song") { NowPlayingSnapshot.load(from: defaults)?.videoId == songs[0].videoId }
        XCTAssertEqual(NowPlayingSnapshot.load(from: defaults)?.shuffleEnabled, false)

        harness.player.toggleShuffle()
        await waitUntil("shuffle on reaches the widget") { NowPlayingSnapshot.load(from: defaults)?.shuffleEnabled == true }
        harness.player.toggleShuffle()
        await waitUntil("and shuffle off") { NowPlayingSnapshot.load(from: defaults)?.shuffleEnabled == false }
        withExtendedLifetime(observer) {}
    }

    func testWithNothingQueuedTheButtonsDoNothing() {
        let harness = PlayerHarness(test: self)
        WidgetTransport.perform(.togglePlayPause, player: harness.player, defaults: nil, reloadWidgets: false)
        XCTAssertFalse(harness.player.playWhenReady)
        WidgetTransport.perform(.shuffle, player: harness.player, defaults: nil, reloadWidgets: false)
        XCTAssertFalse(harness.player.shuffleEnabled)
    }

    /// The Shared intents find the app's handler by name, and each button sends its own action.
    func testEachWidgetIntentReachesTheAppsHandler() async throws {
        XCTAssertTrue(SystemIntentBridge.handler == SystemIntentHandler.self, "the app registers its handler under the shared name")
        RecordingIntentHandler.actions = []
        SystemIntentBridge.handlerOverride = RecordingIntentHandler.self
        defer { SystemIntentBridge.handlerOverride = nil }
        _ = try await TogglePlaybackIntent().perform()
        _ = try await NextTrackIntent().perform()
        _ = try await PreviousTrackIntent().perform()
        _ = try await ToggleLikeIntent().perform()
        _ = try await ToggleShuffleIntent().perform()
        XCTAssertEqual(RecordingIntentHandler.actions, [.togglePlayPause, .next, .previous, .like, .shuffle])
    }

    func testTheArtIsBakedSmallWithABlurredFootAndBody() throws {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 2_000, height: 2_000)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2_000, height: 2_000))
        }
        let art = try XCTUnwrap(WidgetArt.make(from: big))
        XCTAssertLessThanOrEqual(max(art.cover.size.width, art.cover.size.height) * art.cover.scale, WidgetArt.maxPixels)
        XCTAssertEqual(art.softened.size, art.cover.size)
        XCTAssertEqual(art.body.size, art.cover.size)
    }

    /// Render smoke: each widget, with a track and without, hosted and laid out.
    func testEveryWidgetRendersWithAndWithoutATrack() {
        let art = SystemWidgetGallery.sampleArt
        XCTAssertNotNil(art)
        let playing = snapshot()
        assertRendered(hostAndLayOut(CompactWidgetView(snapshot: playing, art: art, canvas: .inline).frame(width: 158, height: 158)), "2×2")
        assertRendered(hostAndLayOut(CompactWidgetView(snapshot: nil, art: nil, canvas: .inline).frame(width: 158, height: 158)), "2×2 empty")
        assertRendered(hostAndLayOut(WideWidgetView(snapshot: playing, art: art, canvas: .inline).frame(width: 338, height: 158)), "4×2")
        assertRendered(hostAndLayOut(WideWidgetView(snapshot: nil, art: nil, canvas: .inline).frame(width: 338, height: 158)), "4×2 empty")
        assertRendered(hostAndLayOut(PillWidgetView(snapshot: playing, art: art, canvas: .inline).frame(width: 338, height: 158)), "4×1")
        assertRendered(hostAndLayOut(PillWidgetView(snapshot: nil, art: nil, canvas: .inline).frame(width: 338, height: 158)), "4×1 empty")
        assertRendered(hostAndLayOut(SystemWidgetGallery().environment(\.layoutDirection, .rightToLeft).dynamicTypeSize(.accessibility3)), "RTL, large type")
    }
}

/// Stands in for the app's handler so the intents can be run without a player.
final class RecordingIntentHandler: SystemIntentHandling {
    @MainActor static var actions: [WidgetTransportAction] = []
    @MainActor static var requests: [String?] = []
    @MainActor static var outcome: SystemPlayOutcome = .playing

    @MainActor static func perform(_ action: WidgetTransportAction) async { actions.append(action) }

    @MainActor static func play(request: String?) async -> SystemPlayOutcome {
        requests.append(request)
        return outcome
    }
}
