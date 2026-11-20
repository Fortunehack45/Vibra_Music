import AVKit
import VibraMusicCore
import MediaPlayer
import Canvas
import Playback
import PlaybackPolicy
import PlaybackQueue
import SwiftUI
import XCTest
@testable import VibraMusic

// One class per PORTING.md feature the player carries beyond the screen itself: the canvas, the
// queue panel, shuffle and repeat, the output sheet, the pipeline, the sleep timer, revert /
// upgrade, and the song ↔ video switch.

/// PORTING.md 2.3 "Animated cover art (Canvas)" — done: a popular track shows motion artwork on
/// Wi-Fi.
@MainActor
final class AnimatedCoverArtTests: XCTestCase {
    private struct FakeLookup: PlayerCanvasLookup {
        let clip: CanvasArtwork?
        func cachedCanvas(for song: Song, spotifyFirst: Bool) async -> CanvasArtwork? { nil }
        func lookUpCanvas(for song: Song, spotifyFirst: Bool) async -> CanvasArtwork? { clip }
    }

    func testTheClipIsOffWhenSwitchedOffAndWiFiOnlyKeepsItOffCellular() {
        let wifi = NetworkStatus(interface: .wifi)
        let cellular = NetworkStatus(interface: .cellular, isExpensive: true)
        XCTAssertTrue(CanvasPolicy.isAllowed(animatedCanvas: true, canvasOverCellular: false, network: wifi))
        XCTAssertFalse(CanvasPolicy.isAllowed(animatedCanvas: true, canvasOverCellular: false, network: cellular))
        XCTAssertTrue(CanvasPolicy.isAllowed(animatedCanvas: true, canvasOverCellular: true, network: cellular))
        XCTAssertFalse(CanvasPolicy.isAllowed(animatedCanvas: false, canvasOverCellular: true, network: wifi))
    }

    func testAPopularTrackShowsItsClipOnWiFiAndNothingOnceItIsNotAllowed() async throws {
        let song = Song(videoId: "canvas-a", title: "Blinding Lights", artist: "The Weeknd", albumName: "After Hours")
        let clip = CanvasArtwork(url: "https://clips.test/blinding.mp4", title: "Blinding Lights", artist: "The Weeknd")
        let model = PlayerCanvasModel(albumSettle: 0)
        let wifi = CanvasPolicy.isAllowed(animatedCanvas: true, canvasOverCellular: false, network: NetworkStatus(interface: .wifi))

        await model.load(for: song, allowed: wifi, spotifyFirst: false, lookup: FakeLookup(clip: clip))
        XCTAssertEqual(model.canvas, clip)

        // Switched off (or on cellular with Wi-Fi only): the still cover.
        await model.load(for: song, allowed: false, spotifyFirst: false, lookup: FakeLookup(clip: clip))
        XCTAssertNil(model.canvas)

        // A file on the device never gets one.
        var local = song
        local.localUri = "file:///music/a.m4a"
        await model.load(for: local, allowed: true, spotifyFirst: false, lookup: FakeLookup(clip: clip))
        XCTAssertNil(model.canvas)
    }

    func testAnEmptyLookupKeepsTheClipAlreadyPlayingForTheSameSong() async {
        let song = Song(videoId: "canvas-b", title: "Song", artist: "Artist", albumName: "Album")
        let clip = CanvasArtwork(url: "https://clips.test/b.mp4", title: "Song", artist: "Artist")
        let model = PlayerCanvasModel(albumSettle: 0)
        await model.load(for: song, allowed: true, spotifyFirst: false, lookup: FakeLookup(clip: clip))
        await model.load(for: song, allowed: true, spotifyFirst: false, lookup: FakeLookup(clip: nil))
        XCTAssertEqual(model.canvas, clip)
    }

    /// Answers the settled lookup only once its task is cancelled, the way a skip lands mid-lookup.
    private struct StalledLookup: PlayerCanvasLookup {
        let clip: CanvasArtwork
        let entered: AsyncStream<Void>.Continuation
        let released: AsyncStream<Void>
        func cachedCanvas(for song: Song, spotifyFirst: Bool) async -> CanvasArtwork? {
            entered.yield()
            for await _ in released {}
            return clip
        }
        func lookUpCanvas(for song: Song, spotifyFirst: Bool) async -> CanvasArtwork? { nil }
    }

    func testASkipDuringTheLookupDoesNotPaintTheLastSongsClip() async {
        let last = Song(videoId: "canvas-last", title: "Last", artist: "Artist", albumName: "Album")
        let next = Song(videoId: "canvas-next", title: "Next", artist: "Other", albumName: "Other Album")
        let lastClip = CanvasArtwork(url: "https://clips.test/last.mp4", title: "Last", artist: "Artist")
        let (entered, enter) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        let model = PlayerCanvasModel(albumSettle: 0)
        let stalled = Task {
            await model.load(for: last, allowed: true, spotifyFirst: false,
                             lookup: StalledLookup(clip: lastClip, entered: enter, released: released))
        }
        var waiting = entered.makeAsyncIterator()
        _ = await waiting.next()

        await model.load(for: next, allowed: true, spotifyFirst: false, lookup: FakeLookup(clip: nil))
        stalled.cancel()
        await stalled.value
        release.finish()

        XCTAssertNil(model.canvas, "the last song's clip came back after the skip")
    }

    func testTheClipViewRendersOverTheSleeve() throws {
        let harness = PlayerHarness(test: self)
        let app = makeNowPlayingApp(settings: harness.settings)
        let clip = CanvasArtwork(url: "https://clips.test/c.mp4")
        let still = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let host = hostAndLayOut(
            PlayerSleeve(image: still, canvas: clip, isPlaying: true).frame(width: 300, height: 300)
                .nowPlayingEnvironment(app: app, harness: harness),
            size: CGSize(width: 320, height: 320)
        )
        assertRendered(host)
        // The clip plays in an AVPlayerLayer-backed view over the still cover: it covers the
        // sleeve, nothing between it and the window is hidden, and at every level it is the
        // topmost layer, so the still can't draw over it.
        let clipView = try XCTUnwrap(host.view.allSubviews.first { $0 is PlayerCanvasUIView })
        let covered = clipView.convert(clipView.bounds, to: host.view)
        XCTAssertEqual(covered.width, 300, accuracy: 1)
        XCTAssertEqual(covered.height, 300, accuracy: 1)
        var view: UIView = clipView
        while view !== host.view, let parent = view.superview {
            XCTAssertFalse(view.isHidden, "the clip sits inside a hidden \(type(of: view))")
            XCTAssertTrue(parent.layer.sublayers?.last === view.layer, "something is layered over the clip inside \(type(of: parent))")
            view = parent
        }
    }
}

/// PORTING.md 2.1 "Queue" (the player's panel) — jump, drag to reorder, remove, clear, in
/// sections by tier.
@MainActor
final class QueuePanelTests: XCTestCase {
    func testADragWithinASectionIsOneTimelineMove() throws {
        // A section whose rows sit at timeline 4, 5, 6, 7.
        let rows = [4, 5, 6, 7]
        // onMove reports "insert before position 3" for dragging row 0 below row 2.
        let down = try XCTUnwrap(QueuePanelMove.timelineMove(rows: rows, offsets: [0], destination: 3))
        XCTAssertEqual(down.from, 4)
        XCTAssertEqual(down.to, 6)
        let up = try XCTUnwrap(QueuePanelMove.timelineMove(rows: rows, offsets: [3], destination: 1))
        XCTAssertEqual(up.from, 7)
        XCTAssertEqual(up.to, 5)
        // Dropped where it started, or past the end of its own section.
        XCTAssertNil(QueuePanelMove.timelineMove(rows: rows, offsets: [1], destination: 1))
        XCTAssertNil(QueuePanelMove.timelineMove(rows: rows, offsets: [1], destination: 2))
        XCTAssertEqual(QueuePanelMove.timelineMove(rows: rows, offsets: [0], destination: 9)?.to, 7)
    }

    func testTheUserJumpsReordersRemovesAndClearsTheirQueue() async throws {
        let harness = PlayerHarness(test: self)
        let player = harness.player
        player.play([try harness.song("q-now", seconds: 8)])
        await waitUntil("a song is current") { player.currentSong != nil }
        player.addToQueue(try ["q-1", "q-2", "q-3"].map { try harness.song($0, seconds: 8) })
        await waitUntil("three songs are queued") { player.sections.user.count == 3 }
        XCTAssertTrue(player.sections.canClearUserQueue)

        // Drag the first queued song below the third.
        let rows = player.sections.user
        let move = try XCTUnwrap(QueuePanelMove.timelineMove(rows: rows.map(\.timelineIndex), offsets: [0], destination: 3))
        XCTAssertEqual(player.move(from: move.from, to: move.to), .done)
        XCTAssertEqual(player.sections.user.map(\.song.videoId), ["q-2", "q-3", "q-1"])

        // Remove the middle one.
        XCTAssertEqual(player.remove(at: player.sections.user[1].timelineIndex), .done)
        XCTAssertEqual(player.sections.user.map(\.song.videoId), ["q-2", "q-1"])

        // Jump to the last.
        XCTAssertEqual(player.jump(to: player.sections.user[1].timelineIndex), .done)
        await waitUntil("the jumped-to song is current") { player.currentSong?.videoId == "q-1" }

        // Clear what's left of the user queue.
        player.addToQueue([try harness.song("q-4", seconds: 8)])
        await waitUntil("one more is queued") { !player.sections.user.isEmpty }
        XCTAssertEqual(player.clearQueue(), .done)
        XCTAssertTrue(player.sections.user.isEmpty)
        XCTAssertFalse(player.sections.canClearUserQueue)
    }

    func testThePanelRendersItsSections() async throws {
        let harness = PlayerHarness(test: self)
        let app = makeNowPlayingApp(settings: harness.settings)
        harness.player.play(try ["qp-a", "qp-b"].map { try harness.song($0) }, source: QueueSource(title: "An Album", type: .browse, id: "MPREb_q"))
        harness.player.addToQueue([try harness.song("qp-user")])
        await waitUntil("the queue has a user section") { !harness.player.sections.user.isEmpty }
        assertRendered(hostAndLayOut(QueuePanel().padding().nowPlayingEnvironment(app: app, harness: harness)))
    }

    /// On an iPad the ∞ on the AutoPlay heading could be clipped down its left side.
    /// The heading's row has no leading inset (queueHeadingRow), so the icon's box sits on the
    /// row's leading edge and whatever the glyph spills past it is cut by the List's cell. Here
    /// the test pads the heading 20 pt in, so a spill has room to show: nothing may be lit left of
    /// x = 20, and the glyph must be lit inside its box, so the first assertion can't pass on a
    /// render that drew nothing at all.
    func testTheAutoPlayIconDrawsInsideItsBox() {
        let host = hostAndLayOut(
            AutoplayHeading(hasTracks: true)
                .padding(.leading, 20)
                .frame(width: 400, height: 100, alignment: .leading)
                .background(Color.black),
            size: CGSize(width: 400, height: 100)
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let snapshot = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
            _ = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        guard let cg = snapshot.cgImage else { return XCTFail("the heading produced no image") }
        let width = cg.width, height = cg.height
        let scale = CGFloat(width) / host.view.bounds.width
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Lit: any channel over 40/255 — the glyph draws white at 75% over the black background.
        func litPixels(columns: Range<Int>) -> (count: Int, leftmost: Int?) {
            var count = 0
            var leftmost: Int?
            for row in 0..<height {
                for x in columns {
                    let i = (row * width + x) * 4
                    if max(Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2])) > 40 {
                        count += 1
                        leftmost = min(leftmost ?? x, x)
                    }
                }
            }
            return (count, leftmost)
        }
        func describe(_ lit: (count: Int, leftmost: Int?)) -> String {
            let left = lit.leftmost.map { String(format: "%.1f", CGFloat($0) / scale) } ?? "none"
            return "\(lit.count) lit pixels, leftmost at \(left) pt"
        }
        // Left of the icon's box: the glyph must not spill towards the row's leading edge.
        let spill = litPixels(columns: 0..<Int(20 * scale))
        XCTAssertEqual(spill.count, 0, "the icon spills past its box: \(describe(spill))")
        // Inside the box: the icon draws, so the assertion above isn't guarding an empty render.
        let inside = litPixels(columns: Int(20 * scale)..<Int(38 * scale))
        XCTAssertGreaterThan(inside.count, 0, "the icon drew nothing inside its box: \(describe(inside))")
        uiSnapshot(host, "queue-autoplay-heading")
    }

    /// The "AutoPlay" heading must not stick to the top of the list on a see-through
    /// band with the row below half hidden under it. Android's headings are LazyColumn items that
    /// scroll away with their rows, so scrolled anywhere, nothing is pinned and nothing overlaps.
    func testSectionHeadingsScrollWithTheQueueAndNeverCoverARow() async throws {
        let harness = PlayerHarness(test: self)
        let app = makeNowPlayingApp(settings: harness.settings)
        let album = try (1...14).map { try harness.song("qh-\($0)") }
        harness.player.play(album, source: QueueSource(title: "An Album", type: .browse, id: "MPREb_qh"))
        harness.player.addToQueue(try ["qh-u1", "qh-u2"].map { try harness.song($0) })
        await waitUntil("the queue has user and album sections") {
            harness.player.sections.user.count == 2 && harness.player.sections.context.count == 13
        }
        let host = hostAndLayOut(QueuePanel().nowPlayingEnvironment(app: app, harness: harness),
                                 size: CGSize(width: 393, height: 420))
        let list = try XCTUnwrap(host.view.allSubviews.compactMap { $0 as? UICollectionView }.first, "the queue is a List")
        assertNoPinnedHeadings(in: list)
        // Each heading is a row of its own, first in its section (Android's heading items).
        XCTAssertEqual(list.numberOfItems(inSection: 0), 2, "the Now playing heading, then the playing row")
        XCTAssertEqual(list.numberOfItems(inSection: 1), 3, "the Next in queue heading, then two rows")
    }

    /// Scrolls `list` end to end a step at a time, turning the run loop so the List lays out at each
    /// offset: no section header stays pinned over the rows, and no two rows ever overlap. Split
    /// from the async test so the synchronous run loop is not read as a call from an async context.
    private func assertNoPinnedHeadings(in list: UICollectionView) {
        for offset in stride(from: 0, through: 700, by: 35) {
            let maxOffset = max(0, list.contentSize.height - list.bounds.height)
            list.setContentOffset(CGPoint(x: 0, y: min(CGFloat(offset), maxOffset)), animated: false)
            list.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            XCTAssertTrue(list.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader).isEmpty,
                          "a pinned section header is showing at offset \(offset)")
            let cells = list.visibleCells.map(\.frame).sorted { $0.minY < $1.minY }
            for (above, below) in zip(cells, cells.dropFirst()) {
                XCTAssertGreaterThanOrEqual(below.minY, above.maxY - 0.5, "rows overlap at offset \(offset)")
            }
        }
    }
}

/// PORTING.md 2.1 "Shuffle and repeat" — done: turning shuffle on then off puts the queue back in
/// its original order.
@MainActor
final class ShuffleAndRepeatTests: XCTestCase {
    func testShuffleOnThenOffRestoresTheOriginalOrder() async throws {
        let harness = PlayerHarness(test: self)
        let player = harness.player
        let ids = (1...8).map { "sh-\($0)" }
        player.play(try ids.map { try harness.song($0) })
        await waitUntil("the album is queued") { player.songs.count == 8 }

        player.toggleShuffle()
        XCTAssertTrue(player.shuffleEnabled)
        let shuffled = player.songs.map(\.videoId)
        XCTAssertEqual(Set(shuffled), Set(ids))
        XCTAssertNotEqual(shuffled, ids, "shuffle on left the queue in its original order")
        player.toggleShuffle()
        XCTAssertFalse(player.shuffleEnabled)
        XCTAssertEqual(player.songs.map(\.videoId), ids)
    }

    func testRepeatCyclesOffAllOneAndSaysSo() {
        let harness = PlayerHarness(test: self)
        let player = harness.player
        XCTAssertEqual(player.repeatMode, .off)
        XCTAssertEqual(PlayerRepeatText.label(player.repeatMode), L10n.repeatOff)
        player.cycleRepeatMode()
        XCTAssertEqual(player.repeatMode, .all)
        XCTAssertEqual(PlayerRepeatText.label(player.repeatMode), L10n.repeatAll)
        player.cycleRepeatMode()
        XCTAssertEqual(player.repeatMode, .one)
        XCTAssertEqual(PlayerRepeatText.label(player.repeatMode), L10n.repeatOne)
        player.cycleRepeatMode()
        XCTAssertEqual(player.repeatMode, .off)
    }

    func testAToggleTappedTwiceInItsWindowCountsOnce() {
        var throttle = PlayerTapThrottle(window: PlayerTapThrottle.shuffle)
        let start = Date()
        XCTAssertTrue(throttle.allow(now: start))
        XCTAssertFalse(throttle.allow(now: start.addingTimeInterval(0.2)))
        XCTAssertTrue(throttle.allow(now: start.addingTimeInterval(0.5)))
    }

    func testTheQueueModesPillRendersWhileTheQueueIsUp() {
        var panes = PlayerPaneState()
        panes.openQueue()
        let row = PlayerActionRow(
            panes: panes, shuffleEnabled: true, repeatMode: .one, autoplayEnabled: true, party: PlayerPartyBadge(),
            onToggleLyrics: {}, onToggleQueue: {}, onToggleShuffle: {}, onCycleRepeat: {}, onToggleAutoplay: {},
            onOpenOutput: {}, onParty: {}
        )
        assertRendered(hostAndLayOut(row.padding().background(Color.black), size: CGSize(width: 393, height: 120)))
    }
}

/// PORTING.md 2.7 "Audio output picker" — done on iOS: the system route picker opens and switches
/// to AirPods.
@MainActor
final class AudioOutputPickerTests: XCTestCase {
    func testOutputsAreNamedAsTheSheetShowsThem() {
        let phone = AudioRouting.Device(id: "p", portType: .builtInSpeaker, name: "Speaker", kind: .phone, isActive: false)
        let pods = AudioRouting.Device(id: "b", portType: .bluetoothA2DP, name: "Alex's AirPods Pro", kind: .bluetooth, isActive: true)
        XCTAssertEqual(PlayerOutputLabel.label(for: phone, accountName: "Kushagra Singh"), L10n.personalPhone("Kushagra"))
        XCTAssertEqual(PlayerOutputLabel.label(for: phone, accountName: nil), L10n.thisPhone)
        XCTAssertEqual(PlayerOutputLabel.label(for: pods, accountName: nil), "Alex's AirPods Pro")
        // The caption under the transport names the active one.
        XCTAssertEqual(PlayerOutputLabel.activeName(of: [phone, pods], accountName: nil), "Alex's AirPods Pro")
        XCTAssertEqual(PlayerOutputLabel.activeName(of: [], accountName: nil), L10n.thisPhone)
    }

    func testTheSheetCarriesTheSystemRoutePickerAndTheVolume() throws {
        let host = hostAndLayOut(
            AudioOutputSheet(accountName: nil, makePipeline: {
                AudioPipeline.build(stats: nil, output: AudioOutputStatus.Snapshot(), dsp: AudioPipeline.DSPSettings())
            })
            .background(Color.black)
        )
        assertRendered(host)
        // Tapping a row is tapping AVRoutePickerView, which is what opens the system's picker.
        XCTAssertTrue(host.view.allSubviews.contains { $0 is AVRoutePickerView }, "no route picker in the sheet")
        XCTAssertTrue(host.view.allSubviews.contains { $0 is MPVolumeView }, "no volume slider in the sheet")
    }
}

/// PORTING.md 2.7 "Audio pipeline dialog" — done: with EQ on, the dialog shows the signal as
/// altered.
@MainActor
final class AudioPipelineDialogTests: XCTestCase {
    private func lossless() -> NerdStats.Snapshot? {
        PlayerNerdStatsText.snapshot(
            stats: PlaybackStats(itemID: "i", codec: "flac", sampleRateHz: 44_100, channels: 2, bitDepth: 16),
            stream: nil, itemID: "i"
        )
    }

    func testWithTheEqualizerOnTheSignalReadsAsAltered() {
        let settings = makeTestSettings()
        settings.loudnessNormalization = false
        settings.playbackSpeed = 1
        var output = AudioOutputStatus.Snapshot()
        output.hardwareSampleRateHz = 44_100

        settings.equalizerEnabled = false
        let clean = AudioPipeline.build(stats: lossless(), output: output,
                                        dsp: PlayerPipelineWording.dspSettings(settings, signalPath: .bitTransparent))
        XCTAssertFalse(clean.isSignalAltered, clean.bitExactVerdict)

        settings.equalizerEnabled = true
        let altered = AudioPipeline.build(stats: lossless(), output: output,
                                          dsp: PlayerPipelineWording.dspSettings(settings, signalPath: .processed))
        XCTAssertTrue(altered.isSignalAltered)
        XCTAssertTrue(altered.alterations.contains(.equalizer))
        XCTAssertEqual(altered.stages.map(\.kind), AudioPipeline.StageKind.allCases)
        // The rows are in the app's language where the catalog has them.
        XCTAssertEqual(PlayerPipelineWording.label("Bit-exact"), L10n.pipelineBitExact)
    }

    func testAnEqualizerTheEngineBypassedDoesNotAlterABitTransparentItem() {
        let settings = makeTestSettings()
        settings.equalizerEnabled = true
        let dsp = PlayerPipelineWording.dspSettings(settings, signalPath: .bitTransparent)
        XCTAssertFalse(dsp.equalizerEnabled)
    }

    func testTheDialogRendersAndMarksAnAlteredSignal() async {
        await enableAccessibilityTree()
        let settings = makeTestSettings()
        settings.loudnessNormalization = false
        settings.playbackSpeed = 1
        var output = AudioOutputStatus.Snapshot()
        output.hardwareSampleRateHz = 44_100

        settings.equalizerEnabled = true
        let altered = AudioPipeline.build(stats: lossless(), output: output,
                                          dsp: PlayerPipelineWording.dspSettings(settings, signalPath: .processed))
        XCTAssertTrue(altered.isSignalAltered)
        let alteredMarks = await sheetMarks(altered)
        XCTAssertTrue(alteredMarks.contains("nowPlaying.pipelineSheet.altered"), "\(alteredMarks)")

        settings.equalizerEnabled = false
        let clean = AudioPipeline.build(stats: lossless(), output: output,
                                        dsp: PlayerPipelineWording.dspSettings(settings, signalPath: .bitTransparent))
        XCTAssertFalse(clean.isSignalAltered, clean.bitExactVerdict)
        let cleanMarks = await sheetMarks(clean)
        XCTAssertTrue(cleanMarks.contains("nowPlaying.pipelineSheet"), "\(cleanMarks)")
        XCTAssertFalse(cleanMarks.contains("nowPlaying.pipelineSheet.altered"), "\(cleanMarks)")
    }

    /// The identifiers the sheet drew: it names itself altered or not, and the accessibility tree
    /// takes a few run-loop turns to report them.
    private func sheetMarks(_ pipeline: AudioPipeline) async -> Set<String> {
        let host = hostAndLayOut(AudioPipelineSheet(pipeline: pipeline, isPlaying: false).background(Color.black))
        defer { host.view.window?.isHidden = true }
        for _ in 0..<20 {
            let ids = host.view.renderedIdentifiers
            if ids.contains(where: { $0.hasPrefix("nowPlaying.pipelineSheet") }) { return ids }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return host.view.renderedIdentifiers
    }
}

/// PORTING.md 2.7 "Sleep timer" — done: playback pauses when the 15 min timer runs out. On Android
/// the timer lives in the song menu opened from the player (MainActivity passes `showSleepTimer`
/// only then), and so it does here: these tests drive the shipped SongActionsSheet.
@MainActor
final class SleepTimerTests: XCTestCase {
    func testOnlyTheMenuOpenedFromThePlayerOffersTheSleepTimer() async throws {
        let harness = PlayerHarness(test: self)
        let app = makeNowPlayingApp(settings: harness.settings)
        harness.player.play([try harness.playerSong("sleep-menu")])
        await waitUntil("a song is current") { harness.player.currentSong != nil }
        let song = try XCTUnwrap(harness.player.currentSong)

        // From a list: no player rows.
        app.router.nowPlaying.close()
        let fromList = await songMenuLabels(song, app: app, harness: harness)
        XCTAssertTrue(fromList.contains(L10n.playNext), "the menu drew its rows: \(fromList)")
        XCTAssertFalse(fromList.contains { $0.hasPrefix(L10n.sleepTimer) })

        // From the player: the sleep timer, and once armed, what's armed.
        app.router.nowPlaying.open()
        let fromPlayer = await songMenuLabels(song, app: app, harness: harness)
        XCTAssertTrue(fromPlayer.contains { $0.hasPrefix(L10n.sleepTimer) }, "\(fromPlayer)")
        harness.player.startSleepTimerAfterTrack()
        let armed = await songMenuLabels(song, app: app, harness: harness)
        XCTAssertTrue(armed.contains { $0.contains(L10n.afterThisSong) }, "the row says what is armed: \(armed)")
    }

    func testPickingFifteenMinutesArmsTheTimerAndTurnOffDisarmsIt() async throws {
        let harness = PlayerHarness(test: self)
        let player = harness.player
        player.play([try harness.song("sleep-a", seconds: 8)])
        await waitUntil("a song is current") { player.currentSong != nil }

        player.startSleepTimer(minutes: 15)
        XCTAssertEqual(player.sleepTimer?.presetMinutes, 15)
        XCTAssertEqual(try XCTUnwrap(player.sleepTimerRemaining), 900, accuracy: 2)
        XCTAssertEqual(SleepTimerRequest.presetMinutes, [15, 30, 45, 60])

        player.cancelSleepTimer()
        XCTAssertNil(player.sleepTimer)
        XCTAssertNil(player.sleepTimerRemaining)
    }

    func testPlaybackPausesWhenTheTimerRunsOut() async throws {
        let harness = PlayerHarness(test: self)
        let player = harness.player
        player.play([try harness.song("sleep-b", seconds: 8)])
        await waitUntil("it plays") { player.isPlaying }
        // The engine's deadline, shortened: a preset is `.minutes`, which the test above checks the
        // player forwards, and waiting out fifteen of them isn't an option.
        harness.engine.startSleepTimer(.duration(0.6))
        XCTAssertNotNil(player.sleepTimer, "the timer was armed")
        await waitUntil("the timer pauses playback") { !player.playWhenReady }
        XCTAssertNil(player.sleepTimer, "and spent once it fires")
    }

    func testThePickerRenders() async throws {
        let harness = PlayerHarness(test: self)
        let app = makeNowPlayingApp(settings: harness.settings)
        harness.player.startSleepTimerAfterTrack()
        await enableAccessibilityTree()
        let host = hostAndLayOut(SleepTimerPicker(accent: .white, divider: .gray, onBack: {})
            .nowPlayingEnvironment(app: app, harness: harness))
        assertRendered(host)
        let labels = await renderedLabelsSettling(host)
        XCTAssertTrue(labels.contains { $0.contains(L10n.afterThisSong) }, "\(labels)")
        XCTAssertTrue(labels.contains { $0.contains(L10n.turnOffTimer) }, "\(labels)")
    }
}

/// PORTING.md 2.7 "Quality upgrade and revert to original" — done: "Revert to original" plays
/// YouTube's own upload, and stays that way after a relaunch.
@MainActor
final class RevertToOriginalTests: XCTestCase {
    private let song = Song(videoId: "rv-song", title: "Song", artist: "Artist")

    override func tearDown() {
        OriginalVersion.shared.unpin("rv-song")
        OriginalVersion.shared.unpin("rv-play")
        super.tearDown()
    }

    func testOnlyThePlayersCopyOfThePlayingTrackGetsAQualityRow() {
        let playing = PlayerQualityMenu.CurrentItem(mediaId: "rv-song", playbackURI: nil)
        XCTAssertEqual(PlayerQualityMenu.row(for: song, openedFromPlayer: true, currentItem: playing), .revertToOriginal)
        XCTAssertNil(PlayerQualityMenu.row(for: song, openedFromPlayer: false, currentItem: playing))
        OriginalVersion.shared.pin("rv-song")
        XCTAssertEqual(PlayerQualityMenu.row(for: song, openedFromPlayer: true, currentItem: playing), .upgradeQuality(enabled: true))
        var local = song
        local.localUri = "file:///a.m4a"
        OriginalVersion.shared.unpin("rv-song")
        XCTAssertNil(PlayerQualityMenu.row(for: local, openedFromPlayer: true, currentItem: playing))
    }

    func testAnUpgradeLightsTheRevertCueOnlyForTheSameEntry() {
        let youtube = ResolvedStream(url: URL(string: "https://rr.googlevideo.test/a")!, origin: .youtube)
        let addon = ResolvedStream(url: URL(string: "https://addon.test/a.flac")!, origin: .addon)
        XCTAssertTrue(PlayerRevertCue.isUpgrade(from: youtube, to: addon, sameEntry: true))
        XCTAssertFalse(PlayerRevertCue.isUpgrade(from: youtube, to: addon, sameEntry: false))
        XCTAssertFalse(PlayerRevertCue.isUpgrade(from: addon, to: youtube, sameEntry: true))

        let model = NowPlayingModel()
        model.streamDidChange(youtube, entry: "e1")
        XCTAssertFalse(model.showsRevertCue)
        model.streamDidChange(addon, entry: "e1")
        XCTAssertTrue(model.showsRevertCue)
        // A skip: the next track was never upgraded.
        model.trackDidChange()
        XCTAssertFalse(model.showsRevertCue)
    }

    func testRevertToOriginalPinsTheTrackAndTheMenuThenOffersTheWayBack() async throws {
        let harness = PlayerHarness(test: self)
        let app = makeNowPlayingApp(settings: harness.settings)
        app.router.nowPlaying.open()
        let player = harness.player
        player.play([try harness.playerSong("rv-play")])
        await waitUntil("the substitute plays") { player.currentStream?.origin == .addon }
        let playing = try XCTUnwrap(player.currentSong)

        // The player's menu leads with "Revert to original".
        let before = await songMenuLabels(playing, app: app, harness: harness)
        XCTAssertTrue(before.contains(L10n.revertToOriginal), "\(before)")
        XCTAssertFalse(before.contains(L10n.upgradeQuality))

        player.revertToOriginal()
        XCTAssertTrue(OriginalVersion.shared.isPinned("rv-play"))
        // Stays that way after a relaunch: the pin is stored, not held in memory.
        OriginalVersion.shared.reload()
        XCTAssertTrue(OriginalVersion.shared.isPinned("rv-play"))

        // Now the menu offers the way back, and taking it lifts the pin.
        let after = await songMenuLabels(playing, app: app, harness: harness)
        XCTAssertFalse(after.contains(L10n.revertToOriginal), "\(after)")
        XCTAssertTrue(after.contains(L10n.upgradeQuality), "\(after)")
        player.upgradeQuality()
        XCTAssertFalse(OriginalVersion.shared.isPinned("rv-play"))
    }
}

/// PORTING.md 2.7 "Switch between song and music video" — done: switching versions carries on
/// from about the same spot in the song.
@MainActor
final class VersionSwitchTests: XCTestCase {
    func testThePlayersMenuOffersTheOtherCut() async throws {
        let harness = PlayerHarness(test: self)
        let app = makeNowPlayingApp(settings: harness.settings)
        app.router.nowPlaying.open()
        harness.player.play([try harness.playerSong("vs-menu")])
        await waitUntil("a song is current") { harness.player.currentSong != nil }
        let audio = try XCTUnwrap(harness.player.currentSong)
        let labels = await songMenuLabels(audio, app: app, harness: harness)
        XCTAssertTrue(labels.contains(L10n.convertToVideo), "\(labels)")
        XCTAssertFalse(labels.contains(L10n.convertToAudio))
        // Opened from a list, the same song gets no version rows.
        app.router.nowPlaying.close()
        let fromList = await songMenuLabels(audio, app: app, harness: harness)
        XCTAssertFalse(fromList.contains(L10n.convertToVideo), "\(fromList)")
    }

    func testConvertingToVideoCarriesOnFromAboutTheSameSpot() async throws {
        let harness = PlayerHarness(test: self)
        let player = harness.player
        harness.settings.smartVersionAlignment = false
        let audio = try harness.song("vs-song", seconds: 12)
        var video = try harness.song("vs-video", seconds: 12)
        video.isVideo = true
        player.versionFinder = { _ in video }
        player.play([audio])
        await waitUntil("the song plays") { player.isPlaying }
        player.seek(to: 5)
        await waitUntil("the playhead is at 5 s") { abs(player.position - 5) < 0.6 }

        // What the menu's "Convert to video" row does.
        await player.switchVersion()
        await waitUntil("the video is playing in the same slot") { player.currentSong?.videoId == "vs-video" && player.isPlaying }
        XCTAssertEqual(player.position, 5, accuracy: 1.5)
        XCTAssertEqual(player.songs.count, 1)
    }

    func testTheSeekBarShimmersWhileTheOtherCutIsFetched() {
        assertRendered(hostAndLayOut(
            PlayerThinSlider(value: 0.4, onChange: { _ in }, loading: true).padding().background(Color.black),
            size: CGSize(width: 393, height: 80)
        ))
    }
}
