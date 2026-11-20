import XCTest
@testable import Theming

/// The UI-facing models that port `rememberArtworkPalette`,
/// `rememberArtworkMesh` and `rememberArtworkColors`.
@MainActor
final class ArtworkColorModelTests: XCTestCase {
    private let first = URL(string: "https://yt3.googleusercontent.com/first=w544-h544-l90-rj")!
    private let second = URL(string: "https://yt3.googleusercontent.com/second=w544-h544-l90-rj")!

    private func sized(_ url: URL, _ px: Int = ArtworkPaletteCache.defaultArtPixels) -> URL {
        ArtworkSizing.youTubeMusic(url, px)
    }

    // MARK: Tint

    func testTintStartsUntintedThenWarmsInWithAFade() async {
        let loader = StubArtworkLoader()
        loader.serve(solidPixels(argb(40, 90, 200)), at: sized(first))
        let cache = ArtworkPaletteCache(loader: loader)
        let model = ArtworkTintModel(cache: cache)

        XCTAssertEqual(model.palette(for: first, scheme: .dark), .untinted(.dark))
        XCTAssertEqual(model.fade(for: first, reduceAnimation: false), 0.26)

        await model.load(first)
        XCTAssertFalse(model.knownUpFront)
        XCTAssertNotNil(model.seed)
        XCTAssertEqual(model.palette(for: first, scheme: .dark), model.seed?.palette(dark: true))
        XCTAssertEqual(model.palette(for: first, scheme: .light), model.seed?.palette(dark: false))
        XCTAssertEqual(model.fade(for: first, reduceAnimation: false), 0.26)
        XCTAssertEqual(model.fade(for: first, reduceAnimation: true), nil)
        XCTAssertNotNil(model.topBandLuminance(for: first))
    }

    func testCoverSeenBeforeIsTintedOnTheFirstFrameWithoutAFade() async {
        let loader = StubArtworkLoader()
        loader.serve(solidPixels(argb(40, 90, 200)), at: sized(first))
        let cache = ArtworkPaletteCache(loader: loader)
        await ArtworkTintModel(cache: cache).load(first)

        // A second page with the same cover: coloured before it loads anything.
        let page = ArtworkTintModel(cache: cache)
        XCTAssertNotEqual(page.palette(for: first, scheme: .dark), .untinted(.dark))
        XCTAssertNil(page.fade(for: first, reduceAnimation: false))
        await page.load(first)
        XCTAssertTrue(page.knownUpFront)
        XCTAssertEqual(loader.requests.count, 1)
    }

    func testTintSwitchesCoversAndIgnoresNil() async {
        let loader = StubArtworkLoader()
        loader.serve(solidPixels(argb(40, 90, 200)), at: sized(first))
        loader.serve(solidPixels(argb(200, 60, 40)), at: sized(second))
        let model = ArtworkTintModel(cache: ArtworkPaletteCache(loader: loader))
        await model.load(first)
        let firstSeed = model.seed
        await model.load(second)
        XCTAssertNotEqual(model.seed, firstSeed)
        XCTAssertEqual(model.artworkURL, second)
        await model.load(nil)
        XCTAssertNil(model.seed)
        XCTAssertEqual(model.palette(for: nil, scheme: .light), .untinted(.light))
    }

    // MARK: Mesh

    func testMeshCarriesOverWithinATrackAndResetsOnANewOne() async {
        let loader = StubArtworkLoader()
        loader.serve(solidPixels(width: 120, height: 120, argb(200, 30, 30)), at: sized(first))
        let cache = ArtworkPaletteCache(loader: loader, retryDelay: 0.01)
        let model = ArtworkMeshModel(cache: cache)

        await model.load(first, trackID: "a")
        let red = model.mesh
        XCTAssertNotNil(red)

        // Same track, a cover that won't load (a version's own thumbnail): the
        // red mesh stays rather than blanking.
        await model.load(second, trackID: "a")
        XCTAssertEqual(model.mesh, red)
        XCTAssertEqual(loader.requests.filter { $0.url == sized(second) }.count, ArtworkMeshBackdropStyle.loadAttempts)

        // A new track drops the carried mesh (the crossfade keeps drawing the old one).
        await model.load(second, trackID: "b")
        XCTAssertNil(model.mesh)

        // Back to a cached cover: on colour immediately, no fetch.
        let before = loader.requests.count
        XCTAssertEqual(model.currentMesh(for: first), red)
        await model.load(first, trackID: "c")
        XCTAssertEqual(model.mesh, red)
        XCTAssertEqual(loader.requests.count, before)
    }

    func testCanvasFramesTakeOverUnlessBlack() async {
        let loader = StubArtworkLoader()
        loader.serve(solidPixels(width: 120, height: 120, argb(200, 30, 30)), at: sized(first))
        let model = ArtworkMeshModel(cache: ArtworkPaletteCache(loader: loader))
        await model.load(first, trackID: "a")
        let still = model.mesh

        await model.receiveCanvasFrame(solidPixels(width: 64, height: 36, argb(2, 2, 2)))
        XCTAssertEqual(model.mesh, still, "a black frame is the surface warming up, not the clip")

        let frame = solidPixels(width: 64, height: 36, argb(30, 180, 60))
        await model.receiveCanvasFrame(frame)
        XCTAssertEqual(model.mesh, ArtworkMesh(pixels: frame, seed: ArtworkMesh.seed(forArtworkURL: first.absoluteString)))
    }

    // MARK: Blob mesh colours

    func testMeshPaletteStartsFromStockColoursThenTakesTheSleeves() async {
        let loader = StubArtworkLoader()
        loader.serve(solidPixels(argb(40, 60, 200)), at: first)
        let cache = ArtworkPaletteCache(loader: loader)
        let model = MeshPaletteModel(cache: cache)
        XCTAssertEqual(model.palette, .fallback)
        XCTAssertEqual(model.currentPalette(for: first), .fallback)

        await model.load(first)
        XCTAssertNotEqual(model.palette, .fallback)
        let sleeve = model.palette

        // A cover that can't be read goes back to the stock colours.
        await model.load(second)
        XCTAssertEqual(model.palette, .fallback)
        // A known one is immediate.
        XCTAssertEqual(model.currentPalette(for: first), sleeve)
        await model.load(nil)
        XCTAssertEqual(model.palette, .fallback)
    }

    func testMeshPaletteModelReadsAtTheSizeItIsGiven() async {
        let loader = StubArtworkLoader()
        let drawn = URL(string: "https://yt3.googleusercontent.com/cover=w160-h160-l90-rj")!
        loader.serve(solidPixels(argb(40, 60, 200)), at: drawn)
        let model = MeshPaletteModel(cache: ArtworkPaletteCache(loader: loader))
        await model.load(URL(string: "https://yt3.googleusercontent.com/cover=w544-h544-l90-rj")!, artPixels: 160)
        XCTAssertEqual(loader.requests, [.init(url: drawn, side: 128)])
        XCTAssertNotEqual(model.palette, .fallback)
    }

    func testACanvasFrameIsNotReplacedByTheStillSleeveReadLandingLater() async {
        let loader = StubArtworkLoader()
        loader.serve(solidPixels(argb(40, 60, 200)), at: first)
        loader.delay = 0.3
        let model = MeshPaletteModel(cache: ArtworkPaletteCache(loader: loader))
        let reading = Task { await model.load(first) }
        // Lets the load register its URL and start the (slow) read of the still.
        await Task.yield()

        let frame = solidPixels(argb(200, 200, 40))
        await model.receiveCanvasFrame(frame)
        await reading.value
        XCTAssertEqual(model.palette, MeshPalette(pixels: frame))

        // Visiting the same cover again doesn't read the still over the clip either.
        await model.load(first)
        XCTAssertEqual(model.palette, MeshPalette(pixels: frame))
    }

    func testMeshPaletteFollowsCanvasFrames() async {
        let model = MeshPaletteModel(cache: ArtworkPaletteCache(loader: StubArtworkLoader()))
        await model.receiveCanvasFrame(solidPixels(argb(0, 0, 0)))
        XCTAssertEqual(model.palette, .fallback)
        await model.receiveCanvasFrame(solidPixels(argb(200, 200, 40)))
        XCTAssertEqual(model.palette, MeshPalette(pixels: solidPixels(argb(200, 200, 40))))
    }
}
