import ImageIO
import XCTest
@testable import Theming

/// The whole pipeline on real sleeves, as YouTube Music serves them (captured
/// into Fixtures/), and — with `VIBRAMUSIC_LIVE_TESTS=1` — fetched live.
final class RealArtworkFixtureTests: XCTestCase {
    func testRandomAccessMemoriesPageIsBlackWithAGoldAccent() throws {
        let pixels = try ThemingFixtures.pixels(ThemingFixtures.randomAccessMemories, side: ArtworkSeed.decodePixels)
        let seed = try XCTUnwrap(ArtworkSeed(pixels: pixels))
        // Nine-tenths black sky: the page is black…
        XCTAssertLessThan(seed.dominant.luminance, 0.01, "\(seed.dominant)")
        // …and the accent is the gold helmet, not black and not a grey.
        let accent = seed.vibrant.hsl
        XCTAssertTrue((25...60).contains(accent.hue), "gold hue, got \(accent.hue)")
        XCTAssertGreaterThan(accent.saturation, 0.3)
        // The sky under the status bar is dark, so the scrim stays subtle.
        XCTAssertLessThan(seed.topBandLuminance, 0.1)
        XCTAssertLessThan(seed.statusBarScrimAlpha, 0.2)
        XCTAssertLessThan(seed.edge.luminance, 0.02)

        let dark = seed.palette(dark: true)
        XCTAssertEqual(dark.background.hsl.lightness, 0.13, accuracy: 0.005)
        XCTAssertGreaterThan(ThemeColor.white.contrastRatio(over: dark.background), 7)
        XCTAssertTrue((25...60).contains(dark.accent.hsl.hue))
    }

    func testRandomAccessMemoriesMeshStaysMostlyBlack() throws {
        let pixels = try ThemingFixtures.pixels(ThemingFixtures.randomAccessMemories, side: ArtworkMesh.decodePixels)
        XCTAssertEqual([pixels.width, pixels.height], [120, 120])
        let mesh = try XCTUnwrap(ArtworkMesh(pixels: pixels, seed: 1))
        // The seam row is the sleeve's bottom edge: black sky either side of the
        // helmets' chins.
        let seamRow = mesh.controlColors.prefix(6)
        XCTAssertTrue(seamRow.allSatisfy { $0.luminance < 0.1 }, "\(Array(seamRow))")
        XCTAssertGreaterThanOrEqual(seamRow.filter { $0.luminance < 0.01 }.count, 3)
        let dark = mesh.controlColors.filter { $0.luminance < 0.05 }.count
        XCTAssertGreaterThanOrEqual(dark, 24, "most of the mesh is the black sky")
        // The blob mesh reads the quantiser's view instead: the most populous
        // colours the default filter lets through — the silver helmet first, not
        // the black (filtered) and not the stock purple.
        let blobs = MeshPalette(pixels: try ThemingFixtures.pixels(ThemingFixtures.randomAccessMemories, side: MeshPalette.decodePixels))
        XCTAssertEqual(blobs.colors.count, 4)
        let silver = blobs.colors[0].hsl
        XCTAssertTrue((200...245).contains(silver.hue) && (0.45...0.7).contains(silver.lightness), "\(blobs.colors)")
        XCTAssertFalse(blobs.colors.contains { MeshPalette.fallbackColors.contains($0) })
    }

    func testCurrentsAccentsInItsPurple() throws {
        let pixels = try ThemingFixtures.pixels(ThemingFixtures.currents, side: ArtworkSeed.decodePixels)
        let seed = try XCTUnwrap(ArtworkSeed(pixels: pixels))
        let accent = seed.vibrant.hsl
        // Violet-magenta stripes (hue ~260–330°), or the red-orange streak.
        XCTAssertTrue((250...340).contains(accent.hue) || accent.hue < 25, "got \(accent.hue)")
        XCTAssertGreaterThan(accent.saturation, 0.3)
        let palette = ArtworkSwatchPalette(pixels: pixels, maximumColorCount: 24)
        XCTAssertNotNil(palette.vibrantSwatch ?? palette.lightVibrantSwatch ?? palette.darkVibrantSwatch)
        XCTAssertGreaterThan(palette.swatches.count, 8)

        let light = seed.palette(dark: false)
        XCTAssertEqual(light.background.hsl.lightness, 0.91, accuracy: 0.005)
        XCTAssertGreaterThan(ThemeColor.black.contrastRatio(over: light.background), 7)
        XCTAssertGreaterThan(light.accent.contrastRatio(over: light.background), 3)

        let blurred = pixels.boxBlurred()
        XCTAssertEqual([blurred.width, blurred.height], [128, 128])
    }
}

/// Real artwork over the network. Skipped unless `VIBRAMUSIC_LIVE_TESTS=1`.
final class LiveArtworkTests: XCTestCase {
    /// Daft Punk — Random Access Memories, as YouTube Music's search returns it.
    private let randomAccessMemories = URL(string: "https://yt3.googleusercontent.com/N55arCGj69gtw6thXK8JUPisxoVYiwuIEQ7I6SGlkEyNcSJ7xIWPe76Vuu1SiUqRyx5w9qvR_zV8fV3CWQ=w544-h544-l90-rj")!
    /// Tame Impala — Currents.
    private let currents = URL(string: "https://yt3.googleusercontent.com/J67cuSWAzGMlj8d9orcAZjPHsl8RWcXIXkT1d8mGmx9jmXPvXkYpFzuLnucmaqJwVMqxPlSq1GbqPeQy=w544-h544-l90-rj")!

    /// No shared URL cache, so every run really goes to the network.
    private let session = URLSession(configuration: .ephemeral)

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VIBRAMUSIC_LIVE_TESTS"] == "1", "set VIBRAMUSIC_LIVE_TESTS=1 to hit YouTube Music's image servers")
    }

    func testSizedArtworkIsServedAtTheRequestedSize() async throws {
        let sized = ArtworkSizing.youTubeMusic(randomAccessMemories, 160)
        XCTAssertTrue(sized.absoluteString.contains("=w160-h160-"))
        let (data, response) = try await session.data(from: sized)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual([image.width, image.height], [160, 160])
    }

    func testEveryReadWorksAgainstTheRealService() async throws {
        let cache = ArtworkPaletteCache(session: session)

        let seedResult = await cache.seed(for: randomAccessMemories, artPixels: 480)

        let seed = try XCTUnwrap(seedResult)
        XCTAssertLessThan(seed.dominant.luminance, 0.01)
        XCTAssertTrue((25...60).contains(seed.vibrant.hsl.hue), "\(seed.vibrant)")

        let meshResult = await cache.mesh(for: randomAccessMemories, artPixels: 480)

        let mesh = try XCTUnwrap(meshResult)
        XCTAssertEqual(mesh.texture.argb.count, 32 * 32)
        XCTAssertTrue(mesh.controlColors.prefix(6).allSatisfy { $0.luminance < 0.1 })
        XCTAssertGreaterThanOrEqual(mesh.controlColors.filter { $0.luminance < 0.05 }.count, 24)

        let blobsResult = await cache.meshPalette(for: currents)

        let blobs = try XCTUnwrap(blobsResult)
        XCTAssertEqual(blobs.colors.count, 4)
        XCTAssertNotEqual(blobs, .fallback)

        let blurredResult = await cache.blurredArtwork(for: currents, artPixels: 480)

        let blurred = try XCTUnwrap(blurredResult)
        XCTAssertEqual([blurred.width, blurred.height], [128, 128])
        XCTAssertNotNil(blurred.makeCGImage())
    }

    func testMissingArtworkIsNilNotACrash() async {
        let cache = ArtworkPaletteCache(session: session)
        let missing = URL(string: "https://yt3.googleusercontent.com/definitely-not-a-real-image-id=w544-h544-l90-rj")!
        let seed = await cache.seed(for: missing)
        XCTAssertNil(seed)
    }
}
