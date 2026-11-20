import VibraMusicCore
import Lyrics
import PlaybackQueue
import SwiftUI
import XCTest
@testable import VibraMusic

/// PORTING.md 2.3 "Now Playing screen" — done: the user can scrub, skip, and open the lyrics and
/// queue panels.
@MainActor
final class NowPlayingScreenTests: XCTestCase {
    // MARK: Panels

    func testLyricsAndTheQueueShareOnePlaceAndTheSleeveIsTheWayBack() {
        var panes = PlayerPaneState()
        XCTAssertEqual(panes.pane, .main)

        panes.toggleLyrics()
        XCTAssertTrue(panes.lyricsOpen)
        // Opening the queue closes the lyrics behind it.
        panes.toggleQueue()
        XCTAssertTrue(panes.queueOpen)
        XCTAssertFalse(panes.lyricsOpen)
        // And the lyrics close the queue.
        panes.openLyrics()
        XCTAssertEqual(panes.pane, .lyrics)
        // The collapsed sleeve goes back to the artwork from either.
        panes.showMain()
        XCTAssertEqual(panes.pane, .main)
        panes.toggleQueue()
        panes.toggleQueue()
        XCTAssertEqual(panes.pane, .main)
    }

    func testThePlayerReopensOnTheSurfaceItWasLeftOn() {
        let settings = makeTestSettings()
        let model = NowPlayingModel(restoring: .queue)
        model.persistPane = { settings.lastPlayerScreen = $0 }
        XCTAssertTrue(model.panes.queueOpen)
        model.panes.openLyrics()
        XCTAssertEqual(settings.lastPlayerScreen, .lyrics)
        XCTAssertEqual(PlayerPaneState(restoring: settings.lastPlayerScreen).pane, .lyrics)
    }

    // MARK: The deck under the lyrics

    /// The lyrics panel's scroll and its lower-half tap reach the deck through the chrome the
    /// portrait player hands it: reading on puts the deck away, coming back up brings it out.
    func testTheLyricsChromePutsTheDeckAwayAndBringsItBack() {
        let model = NowPlayingModel()
        XCTAssertTrue(model.panes.deckShown(picking: false), "the artwork always has its deck")
        model.panes.openLyrics()
        XCTAssertTrue(model.lyricsPanelChrome.controlsOpen, "the lyrics open with the deck up")
        XCTAssertTrue(model.panes.deckShown(picking: false))

        model.lyricsPanelChrome.onHideControls()
        XCTAssertFalse(model.lyricsPanelChrome.controlsOpen)
        XCTAssertFalse(model.panes.deckShown(picking: false), "scrolling on left the deck up")

        model.lyricsPanelChrome.onRevealControls()
        XCTAssertTrue(model.panes.deckShown(picking: false), "scrolling back did not bring the deck out")
        XCTAssertFalse(model.panes.deckShown(picking: true), "a pick owns the screen")

        // Away when the lyrics close, the deck is back on the artwork and up on the next visit.
        model.lyricsPanelChrome.onHideControls()
        model.panes.showMain()
        XCTAssertTrue(model.panes.deckShown(picking: false))
        model.panes.openLyrics()
        XCTAssertTrue(model.lyricsPanelChrome.controlsOpen)
    }

    /// The idle wait is Android's: five seconds, then the deck stands down for the words.
    func testLeftAloneOnTheLyricsTheDeckStandsDown() async {
        XCTAssertEqual(NowPlayingModel.lyricsControlsIdle, .seconds(5))
        let model = NowPlayingModel()
        model.panes.openLyrics()
        await model.hideLyricsControlsWhenIdle(after: .milliseconds(20))
        XCTAssertFalse(model.panes.deckShown(picking: false))

        // Not on the artwork: there is nothing to put away there.
        let main = NowPlayingModel()
        await main.hideLyricsControlsWhenIdle(after: .milliseconds(20))
        XCTAssertTrue(main.panes.deckShown(picking: false))
    }

    /// A finger on the scrubber or the volume bar holds the deck up; letting go starts the wait.
    func testHoldingTheScrubberOrTheVolumeKeepsTheDeckUp() async {
        let model = NowPlayingModel()
        model.panes.openLyrics()
        let before = model.lyricsControlsIdleKey

        model.scrub.drag(to: 0.3)
        XCTAssertNotEqual(model.lyricsControlsIdleKey, before, "taking hold of the scrubber does not start the wait over")
        await model.hideLyricsControlsWhenIdle(after: .milliseconds(20))
        XCTAssertTrue(model.panes.lyricsControlsOpen, "the deck went from under the scrubber")

        // Taken hold of part-way through the wait.
        model.scrub.release()
        let wait = Task { await model.hideLyricsControlsWhenIdle(after: .milliseconds(600)) }
        try? await Task.sleep(for: .milliseconds(100))
        let released = model.lyricsControlsIdleKey
        model.volumeDragging = true
        XCTAssertNotEqual(model.lyricsControlsIdleKey, released, "taking hold of the volume does not start the wait over")
        await wait.value
        XCTAssertTrue(model.panes.lyricsControlsOpen, "the deck went from under the volume bar")

        model.volumeDragging = false
        await model.hideLyricsControlsWhenIdle(after: .milliseconds(20))
        XCTAssertFalse(model.panes.lyricsControlsOpen)
    }

    /// The real screen: opened on the lyrics, the transport is there; left alone, it goes, and the
    /// two frames are attached to the result as the before and after.
    func testOnTheLyricsTheDeckGoesAfterFiveIdleSeconds() async throws {
        await enableAccessibilityTree()
        let harness = PlayerHarness(test: self)
        let app = makeNowPlayingApp(settings: harness.settings)
        harness.player.play([try harness.playerSong("np-deck")])
        await waitUntil("a song is current") { harness.player.currentSong != nil }
        harness.settings.lastPlayerScreen = .lyrics
        AppSettings.shared.lastPlayerScreen = .lyrics
        defer { AppSettings.shared.lastPlayerScreen = .main }
        let host = hostInScene(NowPlayingScreen().nowPlayingEnvironment(app: app, harness: harness), test: self)
        let window = try XCTUnwrap(host.view.window)

        await waitUntil("the deck is up under the lyrics") { host.view.accessibilityElement(labeled: L10n.widgetNext) != nil }
        attach(windowFrame(window, "np-lyrics-deck-up"), "lyrics, deck up")
        await waitUntil("the deck stood down", timeout: 8) { host.view.accessibilityElement(labeled: L10n.widgetNext) == nil }
        try await Task.sleep(for: .milliseconds(600))
        attach(windowFrame(window, "np-lyrics-deck-away"), "lyrics, deck away")
    }

    private func attach(_ image: UIImage, _ name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Scrubbing

    func testAReleasedScrubHoldsTheDropPointUntilThePlayerCatchesUp() {
        let scrub = PlayerScrub()
        let start = Date()
        scrub.drag(to: 0.5)
        XCTAssertTrue(scrub.scrubbing)
        XCTAssertEqual(scrub.shown(position: 10, duration: 200), 0.5)
        XCTAssertEqual(scrub.release(now: start), 0.5)
        // Still buffering: the old position is reported, the handle stays where it was dropped.
        scrub.positionDidChange(10, duration: 200, now: start.addingTimeInterval(0.5))
        XCTAssertEqual(scrub.shown(position: 10, duration: 200), 0.5)
        // Within 1.5 s of the target: hand over to the real position.
        scrub.positionDidChange(99.2, duration: 200, now: start.addingTimeInterval(1))
        XCTAssertNil(scrub.pendingSeek)
        XCTAssertEqual(scrub.shown(position: 99.2, duration: 200), 0.496, accuracy: 0.0001)
    }

    func testASeekThatNeverSettlesLetsGoAfterFourSeconds() {
        let scrub = PlayerScrub()
        let start = Date()
        scrub.drag(to: 0.9)
        scrub.release(now: start)
        scrub.positionDidChange(3, duration: 100, now: start.addingTimeInterval(3.9))
        XCTAssertEqual(scrub.pendingSeek, 0.9)
        scrub.positionDidChange(3, duration: 100, now: start.addingTimeInterval(4.1))
        XCTAssertNil(scrub.pendingSeek)
        XCTAssertEqual(scrub.shown(position: 3, duration: 100), 0.03, accuracy: 0.0001)
    }

    func testATrackChangeDropsAHeldScrub() {
        let scrub = PlayerScrub()
        scrub.drag(to: 0.7)
        scrub.release()
        scrub.trackDidChange()
        XCTAssertNil(scrub.pendingSeek)
        XCTAssertEqual(scrub.shown(position: 0, duration: 100), 0)
    }

    func testTheTimesReadElapsedAndRemaining() {
        XCTAssertEqual(PlayerTime.format(0), "0:00")
        XCTAssertEqual(PlayerTime.format(187.9), "3:07")
        XCTAssertEqual(PlayerTime.format(3_725), "62:05")
        let labels = PlayerTime.labels(fraction: 0.25, duration: 200)
        XCTAssertEqual(labels.elapsed, "0:50")
        XCTAssertEqual(labels.remaining, "-2:30")
    }

    // MARK: Skipping

    func testASidewaysFlingPastTheThresholdSkips() {
        XCTAssertEqual(PlayerSkipSwipe.outcome(translation: -80, controlsLocked: false), .next)
        XCTAssertEqual(PlayerSkipSwipe.outcome(translation: 80, controlsLocked: false), .previous)
        XCTAssertEqual(PlayerSkipSwipe.outcome(translation: 40, controlsLocked: false), .none)
        // Towards the leading edge is "next" in a right-to-left layout too.
        XCTAssertEqual(PlayerSkipSwipe.outcome(translation: 80, controlsLocked: false, rightToLeft: true), .next)
        // A party host holds the controls: say why nothing happened, only for a real fling.
        XCTAssertEqual(PlayerSkipSwipe.outcome(translation: -80, controlsLocked: true), .blocked)
        XCTAssertEqual(PlayerSkipSwipe.outcome(translation: -20, controlsLocked: true), .none)
        XCTAssertEqual(PlayerSkipSwipe.artworkOffset(translation: 100), 35)
    }

    func testDraggingTheArtworkDownClosesAndUpOpensTheQueue() {
        XCTAssertEqual(PlayerVerticalDrag.outcome(translation: 160, predictedEnd: 170, queueTravel: 300), .dismiss)
        XCTAssertEqual(PlayerVerticalDrag.outcome(translation: 40, predictedEnd: 400, queueTravel: 300), .dismiss)
        XCTAssertEqual(PlayerVerticalDrag.outcome(translation: 40, predictedEnd: 50, queueTravel: 300), .none)
        XCTAssertEqual(PlayerVerticalDrag.outcome(translation: -100, predictedEnd: -105, queueTravel: 300), .openQueue)
        XCTAssertEqual(PlayerVerticalDrag.outcome(translation: -50, predictedEnd: -52, queueTravel: 300), .none)
        // A flick opens it on its own.
        XCTAssertEqual(PlayerVerticalDrag.outcome(translation: -20, predictedEnd: -200, queueTravel: 300), .openQueue)
    }

    func testBackIsLitWhileThereIsSomewhereToGoOrSomethingToRestart() {
        XCTAssertTrue(PlayerTransportState.previousEnabled(controlsLocked: false, hasPrevious: true, position: 0))
        XCTAssertTrue(PlayerTransportState.previousEnabled(controlsLocked: false, hasPrevious: false, position: 12))
        XCTAssertFalse(PlayerTransportState.previousEnabled(controlsLocked: false, hasPrevious: false, position: 4))
        XCTAssertFalse(PlayerTransportState.previousEnabled(controlsLocked: true, hasPrevious: true, position: 30))
        XCTAssertFalse(PlayerTransportState.nextEnabled(controlsLocked: true, hasNext: true))
        XCTAssertFalse(PlayerTransportState.nextEnabled(controlsLocked: false, hasNext: false))
    }

    func testThePausedSleeveShrinksBack() {
        XCTAssertEqual(PlayerArtworkPose.portraitScale(isPlaying: true), 1)
        XCTAssertEqual(PlayerArtworkPose.portraitScale(isPlaying: false), 0.86)
    }

    // MARK: Done criterion

    func testTheUserCanScrubSkipAndOpenTheLyricsAndQueuePanels() async throws {
        let harness = PlayerHarness(test: self)
        let songs = try ["np-a", "np-b", "np-c"].map { try harness.song($0, seconds: 8) }
        harness.player.play(songs)
        await waitUntil("the first song plays") { harness.player.isPlaying }

        // Scrub: drag the handle to half way and let go.
        let model = NowPlayingModel()
        model.scrub.drag(to: 0.5)
        let fraction = model.scrub.release()
        harness.player.seek(to: fraction * harness.player.duration)
        await waitUntil("the playhead lands near the drop point") { abs(harness.player.position - 4) < 1 }

        // Skip.
        XCTAssertTrue(harness.player.next())
        await waitUntil("the second song is current") { harness.player.currentSong?.videoId == "np-b" }

        // Open the lyrics and the queue panels.
        withAnimation { model.panes.openLyrics() }
        XCTAssertTrue(model.panes.lyricsOpen)
        withAnimation { model.panes.toggleQueue() }
        XCTAssertTrue(model.panes.queueOpen)
    }

    // MARK: Render

    func testThePlayerRendersOnEverySurface() async throws {
        let harness = PlayerHarness(test: self)
        let app = makeNowPlayingApp(settings: harness.settings)
        var song = try harness.song("np-render", seconds: 8)
        song.albumName = "An Album"
        song.isExplicit = true
        harness.player.play([song], source: QueueSource(title: "An Album", type: .browse, id: "MPREb_x"))
        await waitUntil("a song is current") { harness.player.currentSong != nil }

        for screen in LastPlayerScreen.allCases {
            harness.settings.lastPlayerScreen = screen
            AppSettings.shared.lastPlayerScreen = screen
            assertRendered(hostAndLayOut(NowPlayingScreen().nowPlayingEnvironment(app: app, harness: harness)), "on \(screen)")
        }
        AppSettings.shared.lastPlayerScreen = .main
    }

    /// The song menu's "Add to playlist" and "Lyrics offset" ask the router for an app sheet. The
    /// app's sheets hang off the tab view under the full-screen player, so the player takes the
    /// request and shows the sheet over itself; left on the router it would never be seen.
    func testASheetTheAppAsksForWhileThePlayerIsUpShowsOverThePlayer() async throws {
        let harness = PlayerHarness(test: self)
        let app = makeNowPlayingApp(settings: harness.settings)
        harness.player.play([try harness.playerSong("np-sheet")])
        await waitUntil("a song is current") { harness.player.currentSong != nil }
        app.router.nowPlaying.open()
        AppSettings.shared.lastPlayerScreen = .main
        let host = hostInScene(NowPlayingScreen().nowPlayingEnvironment(app: app, harness: harness), test: self)
        try await Task.sleep(for: .milliseconds(300))

        app.router.present(.lyricsOffset)
        await waitUntil("the player took the request") { app.router.sheet == nil }
        await waitUntil("the sheet is up over the player") { host.presentedViewController != nil }
    }

    // MARK: Closing

    /// Closing is one motion: the player carries on down off the window with the tabs showing
    /// above it, and only then does the cover go, with no slide of its own. It used to be handed to
    /// UIKit's dismiss slide, which started over from the cover's own frame on a curve of its own,
    /// wherever the finger had left the player. A drag can't be sent from a test; the handle's
    /// close button runs the same `close()` a released drag does, from an offset of 0.
    func testClosingCarriesThePlayerOffTheWindowBeforeTheCoverGoesWithoutASlideOfItsOwn() async throws {
        await enableAccessibilityTree()
        let harness = PlayerHarness(test: self)
        let app = makeAppModel(self, settings: harness.settings)
        harness.player.play([try harness.playerSong("np-close")])
        await waitUntil("a song is current") { harness.player.currentSong != nil }
        AppSettings.shared.lastPlayerScreen = .main
        let host = hostInScene(RootTabView().nowPlayingEnvironment(app: app, harness: harness), test: self)
        let window = try XCTUnwrap(host.view.window)
        // Light tabs, so they can be told apart from the dark player in a frame.
        window.overrideUserInterfaceStyle = .light
        let handle = try await openPlayersHandle(host: host, router: app.router)
        let rest = handle.accessibilityFrame.minY

        XCTAssertTrue(handle.accessibilityActivate())
        var coverSlid: CGFloat = 0
        var animatedDismissal = false
        var lastWhileUp = rest
        var movedBackUp = false
        var midway: UIImage?
        let deadline = Date().addingTimeInterval(3)
        while let cover = host.presentedViewController, Date() < deadline {
            coverSlid = max(coverSlid, abs(cover.view.layer.presentation()?.frame.minY ?? 0))
            if cover.isBeingDismissed, cover.transitionCoordinator?.isAnimated == true { animatedDismissal = true }
            let top = handle.accessibilityFrame.minY
            if app.router.nowPlaying.isPresented {
                if top < lastWhileUp - 0.5 { movedBackUp = true }
                lastWhileUp = top
                if midway == nil, top > window.bounds.height / 3 {
                    midway = windowFrame(window, "np-close-midway")
                }
            }
            try await Task.sleep(for: .milliseconds(8))
        }

        XCTAssertNil(host.presentedViewController, "the player never went")
        XCTAssertFalse(app.router.nowPlaying.isPresented)
        XCTAssertEqual(coverSlid, 0, accuracy: 0.5, "the cover slid on its own instead of the player carrying on")
        XCTAssertFalse(animatedDismissal, "the cover went with an animation of its own")
        XCTAssertGreaterThanOrEqual(lastWhileUp - rest, window.bounds.height - 1, "the cover went while the player was still on the window")
        XCTAssertFalse(movedBackUp, "the player moved back up on its way off")
        let frame = try XCTUnwrap(midway, "the player never got a third of the way down while it was up")
        // Above the player: the tabs, under a scrim that has thinned, not the player's dark floor.
        XCTAssertGreaterThan(frame.brightness(at: CGPoint(x: 20, y: 30)), 0.6, "the tabs don't show above the player as it leaves")
        windowFrame(window, "np-close-after")

        // Reopened, the player is back at rest under the finger, not where the last one left off.
        let reopened = try await openPlayersHandle(host: host, router: app.router)
        XCTAssertEqual(reopened.accessibilityFrame.minY, rest, accuracy: 0.5)
    }

    /// Opens the player over the tabs and returns its handle's close button once it is drawn.
    private func openPlayersHandle(host: UIViewController, router: AppRouter) async throws -> NSObject {
        router.nowPlaying.open()
        await waitUntil("the player is up") { host.presentedViewController.map { !$0.isBeingPresented } ?? false }
        await waitUntil("the player has risen") { router.nowPlaying.fraction == 1 }
        let cover = try XCTUnwrap(host.presentedViewController)
        var handle: NSObject?
        await waitUntil("the handle is drawn") {
            handle = cover.view.accessibilityElement(labeled: L10n.close)
            return handle != nil
        }
        return try XCTUnwrap(handle)
    }

    /// What the window shows right now, cover and all (``uiSnapshot`` draws only the view it is
    /// handed), written to `$UI_SNAPSHOT_DIR` as ``uiSnapshot`` does.
    @discardableResult
    private func windowFrame(_ window: UIWindow, _ name: String) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.preferredRange = .standard  // 8 bits a channel, which `brightness(at:)` reads
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        if let dir = ProcessInfo.processInfo.environment["UI_SNAPSHOT_DIR"], !dir.isEmpty {
            try? image.pngData()?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        return image
    }

    // MARK: Lyric strip

    func testTheStripMarksTheIntroAndBreaksAsInstrumental() {
        let lines = [LyricLine(timeMs: 10_000, text: "first"), LyricLine(timeMs: 20_000, text: "second")]
        XCTAssertTrue(PlayerLyricLine.isInstrumental(lines, positionMs: 4_000, offsetMs: 0), "before the first sung line")
        XCTAssertEqual(PlayerLyricLine.text(lines, positionMs: 4_000, offsetMs: 0), L10n.instrumental)
        XCTAssertFalse(PlayerLyricLine.isInstrumental(lines, positionMs: 12_000, offsetMs: 0))
        XCTAssertEqual(PlayerLyricLine.text(lines, positionMs: 12_000, offsetMs: 0), "first")
    }

    /// A gap line between two sung ones is the break: the strip says "Instrumental" there and
    /// goes back to the words when the next line starts.
    func testTheStripMarksABreakBetweenSungLinesAsInstrumental() {
        let lines = [LyricLine(timeMs: 10_000, text: "first"), LyricLine(timeMs: 15_000, text: ""), LyricLine(timeMs: 20_000, text: "second")]
        XCTAssertTrue(PlayerLyricLine.isInstrumental(lines, positionMs: 16_000, offsetMs: 0))
        XCTAssertEqual(PlayerLyricLine.text(lines, positionMs: 16_000, offsetMs: 0), L10n.instrumental)
        XCTAssertFalse(PlayerLyricLine.isInstrumental(lines, positionMs: 21_000, offsetMs: 0))
        XCTAssertEqual(PlayerLyricLine.text(lines, positionMs: 21_000, offsetMs: 0), "second")
    }
}

private extension UIView {
    /// The accessibility element (not a view) labelled `label`, anywhere under this view.
    func accessibilityElement(labeled label: String) -> NSObject? {
        func find(_ element: Any) -> NSObject? {
            if let object = element as? NSObject {
                if object.accessibilityLabel == label, !(object is UIView) { return object }
                for child in object.accessibilityElements ?? [] {
                    if let found = find(child) { return found }
                }
            }
            if let view = element as? UIView {
                for child in view.subviews {
                    if let found = find(child) { return found }
                }
            }
            return nil
        }
        return find(self)
    }
}

private extension UIImage {
    /// The mean of the red, green and blue of the pixel at `point` (in points), 0…1.
    func brightness(at point: CGPoint) -> CGFloat {
        guard let image = cgImage, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        let x = min(Int(point.x * scale), image.width - 1)
        let y = min(Int(point.y * scale), image.height - 1)
        let pixel = bytes + y * image.bytesPerRow + x * image.bitsPerPixel / 8
        // BGRA or RGBA alike: the first three bytes are the colour.
        return CGFloat(Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / (3 * 255)
    }
}
