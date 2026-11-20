import VibraMusicCore
import Playback
import PlaybackPolicy
import SwiftUI
import XCTest
@testable import Vibra Music

/// PORTING.md 2.3 "Landscape layout" — done: rotating the iPhone shows artwork and lyrics side by
/// side.
@MainActor
final class LandscapeLayoutTests: XCTestCase {
    func testASidewaysPhoneGetsTheTwoColumnPlayerAndAnUprightTabletDoesNot() {
        // iPhone 16 on its side, and upright.
        XCTAssertTrue(NowPlayingLayout.isLandscape(CGSize(width: 852, height: 393)))
        XCTAssertFalse(NowPlayingLayout.isLandscape(CGSize(width: 393, height: 852)))
        // An upright iPad is as wide as a sideways phone, but it's the portrait shape.
        XCTAssertFalse(NowPlayingLayout.isLandscape(CGSize(width: 820, height: 1180)))
        // A landscape window too narrow to split stays one column.
        XCTAssertFalse(NowPlayingLayout.isLandscape(CGSize(width: 540, height: 400)))
    }

    func testTheLandscapeSleevePosesArePausedOverScrubbingOverPlaying() {
        XCTAssertEqual(PlayerArtworkPose.landscapeScale(isPlaying: false, scrubbing: true), 0.88)
        XCTAssertEqual(PlayerArtworkPose.landscapeScale(isPlaying: true, scrubbing: true), 0.94)
        XCTAssertEqual(PlayerArtworkPose.landscapeScale(isPlaying: true, scrubbing: false), 1)
    }

    func testRotatingShowsTheArtworkBesideTheLyrics() async throws {
        let harness = PlayerHarness(test: self)
        let app = makeNowPlayingApp(settings: harness.settings)
        harness.player.play([try harness.song("land-a")])
        await waitUntil("a song is current") { harness.player.currentSong != nil }

        let model = NowPlayingModel()
        model.panes.openLyrics()
        let size = CGSize(width: 852, height: 393)
        let host = hostAndLayOut(
            LandscapePlayer(song: try XCTUnwrap(harness.player.currentSong), model: model, size: size)
                .environment(model.lyrics)
                .nowPlayingEnvironment(app: app, harness: harness),
            size: size
        )
        assertRendered(host)

        // And the whole screen picks the two-column shape at that size: the queue button sits
        // under the artwork, in the left column, which the single-column shape would put beyond
        // the window's middle.
        await enableAccessibilityTree()
        let previous = AppSettings.shared.lastPlayerScreen
        AppSettings.shared.lastPlayerScreen = .main
        addTeardownBlock { @MainActor in AppSettings.shared.lastPlayerScreen = previous }
        let screen = hostAndLayOut(NowPlayingScreen().nowPlayingEnvironment(app: app, harness: harness), size: size)
        defer { screen.view.window?.isHidden = true }
        _ = await renderedLabelsSettling(screen)
        let queue = try XCTUnwrap(screen.view.accessibilityFrames(labelled: L10n.upNext).first, "the queue button is not drawn")
        XCTAssertLessThanOrEqual(queue.maxX, size.width / 2 + 2, "\(queue) is not in the left column")
    }
}

/// PORTING.md 2.3 "Stats for nerds" — done: turning on the toggle shows real stream stats.
@MainActor
final class StatsForNerdsTests: XCTestCase {
    func testAHiResFlacReadsAsHiResLosslessWithItsFigures() throws {
        let stats = PlaybackStats(itemID: "item", codec: "flac", sampleRateHz: 96_000, channels: 2, bitDepth: 24)
        let snapshot = try XCTUnwrap(PlayerNerdStatsText.snapshot(stats: stats, stream: nil, itemID: "item"))
        XCTAssertTrue(snapshot.isLossless)
        XCTAssertTrue(snapshot.isHiRes)
        XCTAssertEqual(
            PlayerNerdStatsText.line(snapshot),
            ["FLAC", L10n.bitDepth(24), "96.0 kHz", "4608 kbps", L10n.stereo].joined(separator: " · ")
        )
        XCTAssertEqual(
            PlaybackQualityBadge.resolve(isLoading: false, stillRacing: false, effectiveQuality: .lossless, stats: snapshot),
            .hiResLossless
        )
        XCTAssertEqual(PlaybackQualityBadge.hiResLossless.playerLabel, L10n.hiResLossless)
    }

    func testDolbyAtmosAndLossyTiersGetTheirBadges() throws {
        let atmos = try XCTUnwrap(PlayerNerdStatsText.snapshot(stats: PlaybackStats(itemID: "i", codec: "ec-3", channels: 6), stream: nil, itemID: "i"))
        XCTAssertEqual(PlaybackQualityBadge.resolve(isLoading: false, stillRacing: false, effectiveQuality: .lossless, stats: atmos), .dolbyAtmos)
        let aac = try XCTUnwrap(PlayerNerdStatsText.snapshot(stats: PlaybackStats(itemID: "i", codec: "aac", estimatedBitrateKbps: 320), stream: nil, itemID: "i"))
        XCTAssertEqual(PlaybackQualityBadge.resolve(isLoading: false, stillRacing: false, effectiveQuality: .high, stats: aac), .highQuality)
        XCTAssertEqual(PlayerNerdStatsText.line(aac), "AAC · 320 kbps")
    }

    func testTheLastTracksFiguresNeverDescribeTheNewOne() {
        let stats = PlaybackStats(itemID: "old", codec: "flac", sampleRateHz: 44_100, channels: 2, bitDepth: 16)
        XCTAssertNil(PlayerNerdStatsText.snapshot(stats: stats, stream: nil, itemID: "new"))
        XCTAssertNil(PlayerNerdStatsText.line(nil))
    }

    func testAStreamWorseThanItsSourcePromisedSaysSo() throws {
        let promised = StreamFormat(codec: "flac", kbps: 4608, sampleRateHz: 96_000, bitDepth: 24, channels: 2)
        let stats = PlaybackStats(itemID: "i", codec: "flac", sampleRateHz: 48_000, channels: 2, bitDepth: 16, declared: promised)
        let snapshot = try XCTUnwrap(PlayerNerdStatsText.snapshot(stats: stats, stream: nil, itemID: "i"))
        XCTAssertTrue(snapshot.downgraded)
        XCTAssertTrue(PlayerNerdStatsText.line(snapshot)?.hasSuffix(L10n.downgradedFrom(promised.summary)) == true)
    }

    func testAutomixSaysWhyItIsntAnalysingOnlyWhileItsOn() {
        let video = Song(videoId: "v", title: "t", artist: "a", isVideo: true)
        XCTAssertNil(PlayerNerdStatsText.automixLine(smartFadeEnabled: false, inParty: true, song: video))
        XCTAssertEqual(PlayerNerdStatsText.automixLine(smartFadeEnabled: true, inParty: true, song: video), L10n.automixStoppedInParty)
        XCTAssertEqual(PlayerNerdStatsText.automixLine(smartFadeEnabled: true, inParty: false, song: video), L10n.automixNotSupportedVideo)
    }

    func testTurningOnTheToggleShowsRealStreamStatsOnTheSleeve() async throws {
        let harness = PlayerHarness(test: self)
        let app = makeNowPlayingApp(settings: harness.settings)
        harness.settings.showNerdStats = true
        harness.settings.fullBleedArtwork = false
        let song = try harness.song("stats-a", seconds: 8, format: .wav)
        harness.player.play([song])
        await waitUntil("the decoder reports on the stream") {
            // The engine names the item by its queue slot too, so ask about the queued copy.
            let playing = harness.player.currentSong.map(PlayerController.itemID(for:))
            return harness.player.stats?.itemID == playing && harness.player.stats?.sampleRateHz != nil
        }
        let snapshot = try XCTUnwrap(PlayerQuality.snapshot(player: harness.player))
        let line = try XCTUnwrap(PlayerNerdStatsText.line(snapshot))
        XCTAssertTrue(line.contains("44.1 kHz"), line)
        XCTAssertTrue(line.contains(L10n.stereo), line)

        AppSettings.shared.lastPlayerScreen = .main
        assertRendered(hostAndLayOut(NowPlayingScreen().nowPlayingEnvironment(app: app, harness: harness)))
    }

    /// A quality upgrade reopens the row as a tagged rendition (`<id>#<tag>`); the line has to
    /// describe that copy rather than vanish because the tag doesn't match the bare queue id.
    func testTheStatsStayOnTheSleeveAfterAnUpgradeReopensTheTrack() async throws {
        let harness = PlayerHarness(test: self)
        harness.settings.showNerdStats = true
        let song = try harness.song("stats-upgrade", seconds: 8, format: .wav)
        harness.player.play([song])
        await waitUntil("the original is measured") { harness.player.stats?.sampleRateHz != nil }

        harness.player.reopenCurrent(onRendition: "upgrade", stream: nil)
        await waitUntil("the upgraded copy is measured") {
            harness.player.stats?.itemID.hasSuffix("#upgrade") == true && harness.player.stats?.sampleRateHz != nil
        }
        let snapshot = try XCTUnwrap(PlayerQuality.snapshot(player: harness.player))
        XCTAssertNotNil(PlayerNerdStatsText.line(snapshot))
    }
}

/// On an iPad in landscape the artwork stays inside its column, never off the left edge or
/// under the title and scrubber. The frames are read from what was drawn (the cover is a flat
/// colour, so its pixels are its edges), because the artwork's layout frame is the column's square
/// whatever the picture inside it does.
@MainActor
final class LandscapeArtworkFitTests: XCTestCase {
    private static let windows: [(name: String, size: CGSize)] = [
        ("ipad-pro-11", CGSize(width: 1194, height: 834)),
        ("ipad-pro-13", CGSize(width: 1376, height: 1032)),
        ("phone", CGSize(width: 852, height: 393)),
    ]

    /// A square cover, and the 16:9 thumbnail a video track carries.
    private static let covers: [(name: String, width: Int, height: Int)] = [
        ("square", 544, 544),
        ("widescreen", 640, 360),
    ]

    func testTheArtworkStaysInsideItsColumnAndTheNerdStatsAndActionsSitWhereAndroidPutsThem() async throws {
        await enableAccessibilityTree()
        let harness = PlayerHarness(test: self)
        harness.settings.showNerdStats = true
        let app = makeNowPlayingApp(settings: harness.settings)
        harness.player.play([try harness.song("fit-a", seconds: 8, format: .wav)])
        await waitUntil("the decoder reports on the stream") {
            let playing = harness.player.currentSong.map(PlayerController.itemID(for:))
            return harness.player.stats?.itemID == playing && harness.player.stats?.sampleRateHz != nil
        }
        let song = try XCTUnwrap(harness.player.currentSong)

        for cover in Self.covers {
            let url = try writeCover(width: cover.width, height: cover.height, in: harness.directory)
            for window in Self.windows {
                let size = window.size
                let label = "\(cover.name) cover, \(window.name) \(Int(size.width))x\(Int(size.height))"
                let model = NowPlayingModel()
                await model.artwork.load(url)
                XCTAssertNotNil(model.artwork.image, label)
                let host = hostAndLayOut(
                    LandscapePlayer(song: song, model: model, size: size)
                        .environment(\.horizontalSizeClass, .regular)
                        .environment(\.verticalSizeClass, .regular)
                        .environment(model.lyrics)
                        .nowPlayingEnvironment(app: app, harness: harness),
                    size: size
                )
                defer { host.view.window?.isHidden = true }
                _ = await renderedLabelsSettling(host)
                uiSnapshot(host, "landscape-\(cover.name)-\(window.name)")

                // The two columns split the capped width down the middle of the window.
                let columnWidth = min(size.width, LandscapePlayer.maxWidth) / 2
                let leftColumn = CGRect(x: size.width / 2 - columnWidth, y: 0, width: columnWidth, height: size.height)
                let artwork = try XCTUnwrap(host.view.coverBounds(), "no artwork drawn: \(label)")

                XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: -2, dy: -2).contains(artwork),
                              "the artwork \(artwork) leaves the window: \(label)")
                XCTAssertTrue(leftColumn.insetBy(dx: -2, dy: -2).contains(artwork),
                              "the artwork \(artwork) leaves its column \(leftColumn): \(label)")
                XCTAssertEqual(artwork.width, artwork.height, accuracy: 3, "the artwork \(artwork) is not square: \(label)")

                // The right column (title, artist, scrubber, transport) starts at the window's middle.
                XCTAssertLessThanOrEqual(artwork.maxX, size.width / 2 + 2, "the artwork \(artwork) runs into the right column: \(label)")

                let labels = host.view.renderedLabels
                // A miss is a failure of its own and doesn't stop the other sizes being measured.
                func frame(_ labelled: String) -> CGRect? {
                    let found = host.view.accessibilityFrames(labelled: labelled).first
                    if found == nil { XCTFail("\(labelled) not drawn: \(label); labels: \(labels)") }
                    return found
                }

                // Android: the stats line is the sleeve's own overlay, bottom centre. It is the only
                // pale text on the cover, so its pixels are the pale ones inside the artwork.
                if let stats = host.view.drawnBounds(in: artwork, where: { red, green, blue in red > 200 && blue > 200 && green > 100 }) {
                    XCTAssertGreaterThan(stats.midY, artwork.midY, "the stats line \(stats) is not at the artwork's foot \(artwork): \(label)")
                    XCTAssertEqual(stats.midX, artwork.midX, accuracy: 6, "the stats line \(stats) is not centred on the artwork \(artwork): \(label)")
                } else {
                    XCTFail("no stats line drawn in the artwork \(artwork): \(label)")
                }

                // Android: the lyrics / output / queue row is the left column's, under the sleeve.
                for name in [L10n.openLyrics, L10n.upNext] {
                    guard let button = frame(name) else { continue }
                    XCTAssertGreaterThanOrEqual(button.minY, artwork.maxY - 2, "\(name) \(button) is not under the artwork \(artwork): \(label)")
                    XCTAssertTrue(leftColumn.insetBy(dx: -2, dy: -2).contains(button), "\(name) \(button) is outside the left column \(leftColumn): \(label)")
                }
            }
        }
    }

    /// A PNG of a flat colour, so the cover's drawn edges can be found by colour.
    private func writeCover(width: Int, height: Int, in directory: URL) throws -> URL {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor(red: 1, green: 0, blue: 1, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let url = directory.appending(path: "cover-\(width)x\(height).png")
        try XCTUnwrap(image.pngData()).write(to: url)
        return url
    }
}

private extension UIView {
    /// The accessibility frames (screen points; the test window sits at the screen's origin) of
    /// every element SwiftUI labelled `label`.
    func accessibilityFrames(labelled label: String) -> [CGRect] {
        var found: [CGRect] = []
        func walk(_ element: Any) {
            if let object = element as? NSObject {
                if object.accessibilityLabel == label {
                    found.append(object.accessibilityFrame)
                }
                for child in object.accessibilityElements ?? [] { walk(child) }
            }
            if let view = element as? UIView { view.subviews.forEach(walk) }
        }
        walk(self)
        return found
    }

    /// The smallest rectangle, in points, holding every magenta pixel this view draws: where the
    /// cover the test hands the player ends up on screen, wherever its layout frame says it is.
    func coverBounds() -> CGRect? {
        drawnBounds(in: bounds) { red, green, blue in red > 200 && green < 60 && blue > 200 }
    }
}
