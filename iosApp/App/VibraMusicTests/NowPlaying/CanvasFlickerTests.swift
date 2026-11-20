import Canvas
import XCTest
@testable import Vibra Music

/// Regression tests for a Now Playing artwork flicker: the clip player tore
/// itself down and rebuilt several times a second, and the full-bleed banner flipped with it.
///
/// (a) The clip player's mount decision: a repeated request for the same clip — which SwiftUI
/// makes on every update, including the twice-a-second position ticks — must be a no-op, and once
/// both the clip and its fallback have failed nothing is started again. Both are decisions of
/// ``PlayerCanvasMountState``, split out of `PlayerCanvasUIView` so they can be tested without an
/// AVPlayer.
///
/// (b) The banner latch ``PlayerHeroState``: once the track's cover has loaded or its clip has
/// painted a frame, the banner stays for the rest of the track even as the clip drops its frame,
/// and only a new track starts it over.
@MainActor
final class CanvasFlickerTests: XCTestCase {
    private let original = URL(string: "https://clips.test/instant-crush.mp4")!
    private let fallback = URL(string: "https://clips.test/instant-crush-fallback.mp4")!
    private let other = URL(string: "https://clips.test/around-the-world.mp4")!

    // MARK: (a) The clip player's mount decision

    func testRepeatingTheSameRequestDoesNotRestartThePlayingClip() {
        var state = PlayerCanvasMountState()
        XCTAssertEqual(state.mount(original, fallback: fallback), .start(original))
        XCTAssertEqual(state.playing, original)

        // Every SwiftUI update (the position ticks, twice a second) asks for the same clip.
        for _ in 0..<20 {
            XCTAssertEqual(state.mount(original, fallback: fallback), .unchanged)
        }
        XCTAssertEqual(state.playing, original, "the playing clip is left alone")
    }

    func testAfterAFailureTheSameRequestIsStillANoOpSoTheFallbackKeepsPlaying() {
        var state = PlayerCanvasMountState()
        _ = state.mount(original, fallback: fallback)
        // The original fails: one try at the fallback.
        XCTAssertEqual(state.failed(), .start(fallback))
        XCTAssertEqual(state.playing, fallback)

        // The bug: the next update asked for the original again, saw it differed from the playing
        // fallback, and restarted the whole failed cycle.
        for _ in 0..<20 {
            XCTAssertEqual(state.mount(original, fallback: fallback), .unchanged)
        }
        XCTAssertEqual(state.playing, fallback, "the fallback keeps playing; it is not torn down")
    }

    func testADifferentRequestRestartsThePlayer() {
        var state = PlayerCanvasMountState()
        _ = state.mount(original, fallback: fallback)
        _ = state.failed()
        XCTAssertEqual(state.mount(other, fallback: fallback), .start(other))
        XCTAssertEqual(state.playing, other)
    }

    func testBothRenditionsFailingStopsWithNoFurtherStarts() {
        var state = PlayerCanvasMountState()
        XCTAssertEqual(state.mount(original, fallback: fallback), .start(original))
        XCTAssertEqual(state.failed(), .start(fallback))
        // The fallback fails too: stop, leave the still art up, retry nothing.
        XCTAssertEqual(state.failed(), .stop)
        XCTAssertEqual(state.failed(), .stop, "no further starts once both renditions are spent")
        // The repeated update is still a no-op after giving up.
        XCTAssertEqual(state.mount(original, fallback: fallback), .unchanged)
        XCTAssertEqual(state.playing, fallback)
    }

    func testAFailureWithoutAFallbackOrWithTheSameUrlStops() {
        var state = PlayerCanvasMountState()
        _ = state.mount(original, fallback: nil)
        XCTAssertEqual(state.failed(), .stop)

        var same = PlayerCanvasMountState()
        _ = same.mount(original, fallback: original)
        XCTAssertEqual(same.failed(), .stop, "a fallback that is the same url has nowhere to go")
    }

    func testMountingNothingTearsDownWithoutStarting() {
        var state = PlayerCanvasMountState()
        _ = state.mount(original, fallback: fallback)
        XCTAssertEqual(state.mount(nil, fallback: nil), .start(nil))
        XCTAssertNil(state.playing)
        XCTAssertEqual(state.mount(nil, fallback: nil), .unchanged)
    }

    func testDismantlingResetsSoTheNextMountStartsFresh() {
        var state = PlayerCanvasMountState()
        _ = state.mount(original, fallback: fallback)
        state.reset()
        XCTAssertEqual(state.mount(original, fallback: fallback), .start(original), "a fresh view restarts")
    }

    // MARK: (b) The banner latch

    func testTheBannerStaysSettledAfterTheClipDropsOut() {
        var hero = PlayerHeroState()
        XCTAssertFalse(hero.isHero(fullBleedArtwork: true, fillsWindow: true, artworkLoaded: false, canvasRendered: false))

        hero.settle(artworkLoaded: false, canvasRendered: true)
        XCTAssertTrue(hero.settled)

        // The clip drops its frame: the banner stays for the rest of the track.
        hero.settle(artworkLoaded: false, canvasRendered: false)
        XCTAssertTrue(hero.isHero(fullBleedArtwork: true, fillsWindow: true, artworkLoaded: false, canvasRendered: false))
    }

    func testTheStillCoverAlsoSettlesTheBanner() {
        var hero = PlayerHeroState()
        hero.settle(artworkLoaded: true, canvasRendered: false)
        XCTAssertTrue(hero.settled)

        hero.settle(artworkLoaded: false, canvasRendered: false)
        XCTAssertTrue(hero.isHero(fullBleedArtwork: true, fillsWindow: true, artworkLoaded: false, canvasRendered: false))
    }

    func testANewTrackStartsTheBannerOver() {
        var hero = PlayerHeroState()
        hero.settle(artworkLoaded: true, canvasRendered: false)
        hero.trackDidChange()
        XCTAssertFalse(hero.settled)
        XCTAssertFalse(hero.isHero(fullBleedArtwork: true, fillsWindow: true, artworkLoaded: false, canvasRendered: false))
    }

    func testFullBleedOffIsNeverHero() {
        var hero = PlayerHeroState()
        hero.settle(artworkLoaded: true, canvasRendered: true)
        XCTAssertFalse(hero.isHero(fullBleedArtwork: false, fillsWindow: true, artworkLoaded: true, canvasRendered: true))
        XCTAssertFalse(hero.isHero(fullBleedArtwork: false, fillsWindow: true, artworkLoaded: false, canvasRendered: false))
    }

    func testANarrowWindowIsNotHero() {
        var hero = PlayerHeroState()
        hero.settle(artworkLoaded: true, canvasRendered: true)
        XCTAssertFalse(hero.isHero(fullBleedArtwork: true, fillsWindow: false, artworkLoaded: true, canvasRendered: true))
    }

    // MARK: (c) The clip's first frame, under the clip

    func testThePosterIsTheClipsOwnFirstFrameOnceTheClipIsOnDisk() async throws {
        let fixture = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "VibraMusicKit/Tests/PlaybackTests/Fixtures/tall-first-frame-red.mp4")
        let canvas = CanvasArtwork(url: "https://clips.test/\(UUID().uuidString).mp4")
        let early = await PlayerCanvasPosters.load(for: canvas)
        XCTAssertNil(early, "nothing on disk to read")

        _ = PlayerCanvasClips.cache.store(try Data(contentsOf: fixture), for: try XCTUnwrap(URL(string: canvas.url)))
        let poster = await PlayerCanvasPosters.load(for: canvas)
        let frame = try XCTUnwrap(poster?.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(frame, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertGreaterThan(pixel[0], 180, "the fixture's first frame is red; a later one is blue")
        XCTAssertLessThan(pixel[2], 80)
        XCTAssertTrue(PlayerCanvasPosters.cached(for: canvas) === poster, "the next open must not wait for a read")
    }
}
