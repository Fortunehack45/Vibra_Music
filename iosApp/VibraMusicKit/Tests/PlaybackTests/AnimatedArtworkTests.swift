import MediaPlayer
import VibraMusicTestSupport
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import XCTest
@testable import Playback

/// Which animated-artwork key (iOS 26+) a clip may be published under. The decision
/// is pure, so the key choice tests without the system in the loop: pixels in, key (or none) out.
@MainActor
final class AnimatedArtworkKeyTests: XCTestCase {
    private let keys: Set<NowPlayingInfoBuilder.AnimatedArtworkKey> = [.square, .tall]

    /// Tidal's 1280x1280, and any 1:1 within rounding of the key itself.
    func testASquareClipTakesThe1x1Key() {
        XCTAssertEqual(NowPlayingInfoBuilder.animatedArtworkKey(
            for: CGSize(width: 1280, height: 1280), isAllowed: true, supportedKeys: keys), .square)
        XCTAssertEqual(NowPlayingInfoBuilder.animatedArtworkKey(
            for: CGSize(width: 1100, height: 1200), isAllowed: true, supportedKeys: keys), .square, "encoder rounding")
    }

    func testATallClipTakesThe3x4Key() {
        XCTAssertEqual(NowPlayingInfoBuilder.animatedArtworkKey(
            for: CGSize(width: 750, height: 1000), isAllowed: true, supportedKeys: keys), .tall)
    }

    /// Spotify Canvas: usually 9:16, which matches neither key, and this pass crops nothing — a
    /// wrong-shaped asset is exactly what the system says it may reject.
    func testAPortraitClipTakesNoKey() {
        XCTAssertNil(NowPlayingInfoBuilder.animatedArtworkKey(
            for: CGSize(width: 1080, height: 1920), isAllowed: true, supportedKeys: keys))
        XCTAssertNil(NowPlayingInfoBuilder.animatedArtworkKey(
            for: CGSize(width: 720, height: 1280), isAllowed: true, supportedKeys: keys))
    }

    /// `supportedAnimatedArtworkKeys` is the gate the system itself applies; offering a key it
    /// does not list is sending an asset into the void.
    func testAKeyOutsideTheSupportedListIsDropped() {
        XCTAssertNil(NowPlayingInfoBuilder.animatedArtworkKey(
            for: CGSize(width: 1280, height: 1280), isAllowed: true, supportedKeys: []), "the system lists no animated keys")
        XCTAssertNil(NowPlayingInfoBuilder.animatedArtworkKey(
            for: CGSize(width: 1280, height: 1280), isAllowed: true, supportedKeys: [.tall]), "the system lists only the tall key")
        XCTAssertNil(NowPlayingInfoBuilder.animatedArtworkKey(
            for: CGSize(width: 750, height: 1000), isAllowed: true, supportedKeys: [.square]), "the system lists only the square key")
    }

    /// ``CanvasPolicy``'s switch and Wi-Fi-only rule gate the publish before any download; the
    /// builder drops the clip too, so the two halves agree.
    func testADisallowedClipTakesNoKey() {
        XCTAssertNil(NowPlayingInfoBuilder.animatedArtworkKey(
            for: CGSize(width: 1280, height: 1280), isAllowed: false, supportedKeys: keys))
    }

    func testAClipOfNoReportedSizeTakesNoKey() {
        XCTAssertNil(NowPlayingInfoBuilder.animatedArtworkKey(
            for: .zero, isAllowed: true, supportedKeys: keys))
    }
}

/// The lock-screen preview is the clip's own first frame, at the clip's shape: a square still
/// under a 3:4 clip is what the iPhone's tall lock screen refused. The fixture is a 48x64 H.264
/// clip whose first frame is red and the rest blue.
final class AnimatedArtworkPreviewTests: XCTestCase {
    private func fixture() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/tall-first-frame-red", withExtension: "mp4"))
    }

    func testThePreviewIsTheClipsFirstFrameAtTheClipsShape() async throws {
        // A square request still gets the clip's 3:4, fitted inside it.
        let frame = await NowPlayingInfoBuilder.firstFrame(of: try fixture(), fitting: CGSize(width: 40, height: 40))
        let image = try XCTUnwrap(frame, "the clip's first frame decodes")
        XCTAssertEqual(image.width, 30)
        XCTAssertEqual(image.height, 40)
        let (red, blue) = try Self.centrePixel(of: image)
        XCTAssertGreaterThan(red, 200, "the first frame is the red one")
        XCTAssertLessThan(blue, 60, "not a later, blue frame")
    }

    func testAFileWithNoVideoHasNoPreview() async {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("no-such-clip.mp4")
        let frame = await NowPlayingInfoBuilder.firstFrame(of: missing, fitting: CGSize(width: 30, height: 40))
        XCTAssertNil(frame)
    }

    private static func centrePixel(of image: CGImage) throws -> (red: UInt8, blue: UInt8) {
        let centre = try XCTUnwrap(image.cropping(to: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1)))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(centre, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixel = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (pixel[0], pixel[2])
    }
}

/// The dictionary the builder publishes on an iOS 26+: an offered clip lands under the key its
/// shape selects, the still cover stays right where it was, and a 9:16 clip stays out. Gated at
/// compile time so older runtimes skip the class whole.
#if os(iOS)
@available(iOS 26.0, *)
@MainActor
final class AnimatedArtworkDictionaryTests: XCTestCase {
    private let item = PlayableItem(id: "np-anim", title: "T", artist: "A", source: .asset { throw CancellationError() })
    private let still = MPMediaItemArtwork(boundsSize: CGSize(width: 8, height: 6)) { _ in UIImage() }

    private func publishedStill(of info: [String: Any]) -> MPMediaItemArtwork? {
        info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork
    }

    private func testInfo(animated: NowPlayingAnimatedArtwork?) -> [String: Any] {
        testInfo(clips: animated.map { [$0] } ?? [])
    }

    private func testInfo(clips: [NowPlayingAnimatedArtwork]) -> [String: Any] {
        NowPlayingInfoBuilder.info(.init(
            item: item, position: 0, duration: 90, isPlaying: true, rate: 1,
            subtitleOverride: nil, artwork: still, animatedArtworks: clips))
    }

    func testTheAnimatedCoverLandsUnderItsKeyAndKeepsTheStillCover() throws {
        try XCTSkipUnless(NowPlayingInfoBuilder.runtimeSupportedKeys().contains(.square),
                          "this runtime lists no square animated key")
        let key = try XCTUnwrap(NowPlayingInfoBuilder.systemKey(for: .square))
        let info = testInfo(animated: NowPlayingAnimatedArtwork(
            fileURL: URL(fileURLWithPath: "/tmp/np-clip.mp4"),
            pixels: CGSize(width: 1280, height: 1280),
            artworkID: "clip-a/cover"))
        XCTAssertTrue(info[key] is MPMediaItemAnimatedArtwork, "the clip is offered on the lock screen")
        XCTAssertTrue(publishedStill(of: info) === still, "the still cover is unchanged")
    }

    /// A square and a 3:4 clip go out together, each under the key its own size selects.
    func testASquareAndATallClipLandUnderTheirOwnKeys() throws {
        let supported = NowPlayingInfoBuilder.runtimeSupportedKeys()
        try XCTSkipUnless(supported.isSuperset(of: [.square, .tall]), "this runtime lists \(supported), not both keys")
        let squareKey = try XCTUnwrap(NowPlayingInfoBuilder.systemKey(for: .square))
        let tallKey = try XCTUnwrap(NowPlayingInfoBuilder.systemKey(for: .tall))
        let clip = { (id: String, width: CGFloat, height: CGFloat) in
            NowPlayingAnimatedArtwork(fileURL: URL(fileURLWithPath: "/tmp/\(id).mp4"),
                                      pixels: CGSize(width: width, height: height), artworkID: id)
        }
        let info = testInfo(clips: [clip("tall", 1080, 1440), clip("square", 768, 768)])
        XCTAssertTrue(info[squareKey] is MPMediaItemAnimatedArtwork, "the square clip has the 1x1 key")
        XCTAssertTrue(info[tallKey] is MPMediaItemAnimatedArtwork, "the tall clip has the 3x4 key")
        XCTAssertTrue(publishedStill(of: info) === still)
    }

    func testWithoutAClipOnlyTheStillCoverIsPublished() throws {
        try XCTSkipUnless(NowPlayingInfoBuilder.runtimeSupportedKeys().contains(.square),
                          "this runtime lists no square animated key")
        let info = testInfo(animated: nil)
        XCTAssertNil(info[try XCTUnwrap(NowPlayingInfoBuilder.systemKey(for: .square))])
        XCTAssertNil(info[try XCTUnwrap(NowPlayingInfoBuilder.systemKey(for: .tall))])
        XCTAssertTrue(publishedStill(of: info) === still)
    }

    /// A 9:16 clip stays out of the dictionary on iOS 26+ end to end: the key choice the pure
    /// tests make is the same one the builder applies to what it is handed.
    func testAPortraitClipStaysOutOfTheDictionary() throws {
        try XCTSkipUnless(NowPlayingInfoBuilder.runtimeSupportedKeys().contains(.square),
                          "this runtime lists no square animated key")
        let info = testInfo(animated: NowPlayingAnimatedArtwork(
            fileURL: URL(fileURLWithPath: "/tmp/np-portrait.mp4"),
            pixels: CGSize(width: 1080, height: 1920),
            artworkID: "clip-b/cover"))
        XCTAssertNil(info[try XCTUnwrap(NowPlayingInfoBuilder.systemKey(for: .square))])
        XCTAssertNil(info[try XCTUnwrap(NowPlayingInfoBuilder.systemKey(for: .tall))])
        XCTAssertTrue(publishedStill(of: info) === still)
    }
}

/// The engine's own wiring: a clip handed to it reaches the dictionary, and a changed item drops
/// it rather than carrying the last track's clip over. The first offer waits for the still
/// cover — the system re-reads the preview only behind a changed artworkID, so a nil must never
/// get locked in under the id it was resolved with.
@available(iOS 26.0, *)
@MainActor
final class AnimatedArtworkEngineTests: EngineTestCase {
    func testTheCoverReachesTheDictionaryAndLeavesWithTheItem() async throws {
        try XCTSkipUnless(NowPlayingInfoBuilder.runtimeSupportedKeys().contains(.square),
                          "this runtime lists no square animated key")
        let squareKey = try XCTUnwrap(NowPlayingInfoBuilder.systemKey(for: .square))
        // The still cover's download is held until the test lets it through, so the clip can be
        // offered while the still is still loading.
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let png = try Self.png(width: 8, height: 6)
        let artworkStub = URLProtocolStub()
        artworkStub.register(host: "art.example", path: "/cover.png") { _ in
            _ = release.wait(timeout: .now() + 10)
            return .data(png)
        }
        let toneURL = try ToneFile.tone(3, in: directory, name: "np-anim-e2e")
        let item = PlayableItem(
            id: "np-anim-e2e", title: "E2E", artist: "An Artist",
            artworkURL: URL(string: "https://art.example/cover.png"),
            source: .file(toneURL))
        let next = try tone(3, frequency: 550, name: "np-anim-e2e-next")
        let h = harness(queue: [item, next], artworkSession: artworkStub.makeSession())
        h.engine.load(item, playWhenReady: true)
        await waitUntil("the item is current") { h.engine.currentItem?.id == item.id }
        let before = h.nowPlaying.publishCount
        h.engine.nowPlayingAnimatedArtworks = [NowPlayingAnimatedArtwork(
            fileURL: URL(fileURLWithPath: "/tmp/np-anim-e2e.mp4"),
            pixels: CGSize(width: 1280, height: 1280),
            artworkID: "e2e/cover")]
        await waitUntil("the clip's publish went out") { h.nowPlaying.publishCount > before }
        XCTAssertNil(h.nowPlaying.info?[MPMediaItemPropertyArtwork], "the still cover is still loading")
        XCTAssertNil(h.nowPlaying.info?[squareKey], "the first offer waits for the still cover")

        release.signal()
        await waitUntil("the animated cover is published") { h.nowPlaying.info?[squareKey] != nil }
        XCTAssertNotNil(h.nowPlaying.info?[MPMediaItemPropertyArtwork], "it goes out with its preview")

        // The cover belongs to its item: the next one starts with it dropped.
        XCTAssertEqual(h.engine.skipToNext(), true)
        await waitUntil("the next item is current") { h.engine.currentItem?.id == next.id }
        XCTAssertEqual(h.engine.nowPlayingAnimatedArtworks, [])
        await waitUntil("the animated cover is dropped") { h.nowPlaying.info?[squareKey] == nil }
    }

    private static func png(width: Int, height: Int) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }
}

/// Repeat and same-item reloads re-enter `itemBecameCurrent` with the item's own id: a resolved
/// clip belongs to the item, not to the turn, so it must not be dropped.
@MainActor
final class AnimatedArtworkRepeatTests: EngineTestCase {
    func testTheSameItemAgainKeepsItsCoverAndAChangedOneDropsIt() async throws {
        let item = try tone(3, name: "np-anim-again")
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: false)
        await waitUntil("a current item") { h.engine.currentItem != nil }
        let fixture = NowPlayingAnimatedArtwork(
            fileURL: URL(fileURLWithPath: "/tmp/np-anim-again.mp4"),
            pixels: CGSize(width: 1280, height: 1280),
            artworkID: "again/cover")

        h.engine.nowPlayingAnimatedArtworks = [fixture]
        h.engine.itemBecameCurrent(item, reason: .repeated)
        XCTAssertEqual(h.engine.nowPlayingAnimatedArtworks, [fixture], "repeat keeps the item's clip")

        let next = try tone(3, frequency: 550, name: "np-anim-again-next")
        h.engine.itemBecameCurrent(next, reason: .ended)
        XCTAssertEqual(h.engine.nowPlayingAnimatedArtworks, [], "a changed item drops it")
    }
}
#endif
