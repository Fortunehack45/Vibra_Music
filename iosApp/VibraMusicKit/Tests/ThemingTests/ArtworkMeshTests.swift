import CoreGraphics
import XCTest
@testable import Theming

/// The player's mesh backdrop (`meshOf` and friends in ArtworkMeshBackdrop.kt).
final class ArtworkMeshTests: XCTestCase {
    private func row(_ mesh: ArtworkMesh, _ index: Int) -> [UInt32] {
        Array(mesh.controlPoints[(index * mesh.columns)..<((index + 1) * mesh.columns)])
    }

    func testSleeveIsFlippedSoItsBottomEdgeMeetsTheSeam() throws {
        // Red top half, blue bottom half, at the decode size.
        let pixels = makePixels(width: 120, height: 120) { _, y in y < 60 ? argb(200, 30, 30) : argb(30, 30, 200) }
        let mesh = try XCTUnwrap(ArtworkMesh(pixels: pixels, seed: 7))
        XCTAssertEqual([mesh.columns, mesh.rows], [6, 6])
        let blue = ArtworkMesh.lifted(argb(30, 30, 200))
        let red = ArtworkMesh.lifted(argb(200, 30, 30))
        for index in 0..<3 {
            XCTAssertEqual(row(mesh, index), Array(repeating: blue, count: 6), "row \(index) is the sleeve's bottom")
        }
        for index in 3..<6 {
            XCTAssertEqual(row(mesh, index), Array(repeating: red, count: 6), "row \(index) is the sleeve's top")
        }
    }

    func testProportionsSurviveMostlyBlackStaysMostlyBlack() throws {
        // Nine-tenths black with a red stripe — the case that made the old
        // quantised backdrop a red screen.
        let pixels = makePixels(width: 120, height: 120) { _, y in (54..<66).contains(y) ? argb(220, 30, 40) : argb(0, 0, 0) }
        let mesh = try XCTUnwrap(ArtworkMesh(pixels: pixels, seed: 1))
        let dark = mesh.controlColors.filter { $0.luminance < 0.02 }.count
        XCTAssertGreaterThanOrEqual(dark, 24, "at least two-thirds of the cells stay black")
        let texelsDark = mesh.texture.argb.filter { StatusBarContrast.relativeLuminance(argb: $0) < 0.02 }.count
        XCTAssertGreaterThan(Double(texelsDark) / Double(mesh.texture.argb.count), 0.5)
    }

    func testBlackIsFlooredAndAveragesAreReSaturated() {
        // Pure black cells are lifted to lightness 0.045 — 11.475 → 11.
        XCTAssertEqual(ArtworkMesh.lifted(argb(0, 0, 0)), argb(11, 11, 11))
        // A mid colour's saturation is multiplied by 1.12, lightness untouched.
        let source = ColorUtilsPort.rgbToHSL(argb: argb(120, 80, 80))
        let lifted = ColorUtilsPort.rgbToHSL(argb: ArtworkMesh.lifted(argb(120, 80, 80)))
        XCTAssertEqual(lifted.saturation, source.saturation * 1.12, accuracy: 0.01)
        XCTAssertEqual(lifted.lightness, source.lightness, accuracy: 0.003)
        // Already fully saturated stays capped.
        XCTAssertEqual(ArtworkMesh.lifted(argb(255, 0, 0)), argb(255, 0, 0))
    }

    func testRowsBelowTheSeamRotateTogetherKeepingNeighbours() throws {
        // Six vertical stripes; every row reads 0…5 in the source.
        let stripes: [UInt32] = [argb(250, 0, 0), argb(0, 250, 0), argb(0, 0, 250), argb(250, 250, 0), argb(0, 250, 250), argb(250, 0, 250)]
        let pixels = makePixels(width: 120, height: 120) { x, _ in stripes[x / 20] }
        let lifted = stripes.map(ArtworkMesh.lifted)
        for seed in [Int32(0), 1, 42, -99, ArtworkMesh.seed(forArtworkURL: "https://yt3.googleusercontent.com/abc=w544-h544-l90-rj")] {
            let mesh = try XCTUnwrap(ArtworkMesh(pixels: pixels, seed: seed))
            XCTAssertEqual(row(mesh, 0), lifted, "the seam row is kept literal")
            let moved = row(mesh, 1)
            for index in 2..<6 {
                XCTAssertEqual(row(mesh, index), moved, "every row below the seam moves by the same amount")
            }
            // A cyclic shift, possibly mirrored: each cell's neighbours are the same.
            var candidates = [[UInt32]]()
            for shift in 0..<6 {
                candidates.append((0..<6).map { (x: Int) -> UInt32 in lifted[(x + shift) % 6] })
                candidates.append((0..<6).map { (x: Int) -> UInt32 in lifted[(5 - x + shift) % 6] })
            }
            XCTAssertTrue(candidates.contains(moved), "seed \(seed): \(moved) is not a rotation of the source row")
        }
    }

    func testArrangementIsSeededAndRepeatable() throws {
        let stripes: [UInt32] = [argb(250, 0, 0), argb(0, 250, 0), argb(0, 0, 250), argb(250, 250, 0), argb(0, 250, 250), argb(250, 0, 250)]
        let pixels = makePixels(width: 120, height: 120) { x, _ in stripes[x / 20] }
        let first = try XCTUnwrap(ArtworkMesh(pixels: pixels, seed: 12345))
        XCTAssertEqual(first, try XCTUnwrap(ArtworkMesh(pixels: pixels, seed: 12345)))

        // The rotation is Kotlin's Random(seed): one nextBoolean() for the mirror,
        // then nextInt(columns) for the shift.
        var random = KotlinXorWowRandom(seed: 12345)
        let mirror = random.nextBoolean()
        let shift = Int(random.nextInt(until: 6))
        let lifted = stripes.map(ArtworkMesh.lifted)
        let expected = (0..<6).map { x in lifted[((mirror ? 5 - x : x) + shift) % 6] }
        XCTAssertEqual(Array(first.controlPoints[6..<12]), expected)
    }

    func testTextureIsASmoothResampleOfTheGrid() throws {
        let uniform = try XCTUnwrap(ArtworkMesh(pixels: solidPixels(width: 120, height: 120, argb(40, 90, 160)), seed: 3))
        XCTAssertEqual(uniform.texture.width, 32)
        XCTAssertEqual(uniform.texture.height, 32)
        XCTAssertEqual(Set(uniform.texture.argb), [ArtworkMesh.lifted(argb(40, 90, 160))])

        let split = try XCTUnwrap(ArtworkMesh(pixels: makePixels(width: 120, height: 120) { _, y in y < 60 ? argb(250, 250, 250) : argb(0, 0, 0) }, seed: 3))
        let column = (0..<32).map { split.texture.argb[$0 * 32 + 5] }
        // Held flat at the ends, monotonic between.
        XCTAssertEqual(column.first, ArtworkMesh.lifted(argb(0, 0, 0)))
        XCTAssertEqual(column.last, ArtworkMesh.lifted(argb(250, 250, 250)))
        let brightness = column.map { Int($0 & 0xFF) }
        XCTAssertEqual(brightness, brightness.sorted())
        // Smoothstep is flat at the control points: the step either side of a
        // cell centre is small compared with the step through the middle.
        let steps = zip(brightness, brightness.dropFirst()).map { $1 - $0 }
        XCTAssertGreaterThan(steps.max() ?? 0, 30)
    }

    func testSmoothstepAndLerp() {
        XCTAssertEqual(ArtworkMesh.smoothstep(-1), 0)
        XCTAssertEqual(ArtworkMesh.smoothstep(0.5), 0.5)
        XCTAssertEqual(ArtworkMesh.smoothstep(2), 1)
        XCTAssertEqual(ArtworkMesh.lerpARGB(argb(0, 0, 0), argb(255, 100, 1), 0.5), argb(128, 50, 1))
        XCTAssertEqual(ArtworkMesh.lerpARGB(argb(1, 2, 3), argb(9, 9, 9), 0), argb(1, 2, 3))
        XCTAssertEqual(ArtworkMesh.lerpARGB(argb(1, 2, 3), argb(9, 9, 9), 1), argb(9, 9, 9))
    }

    func testSmallAndOddSources() throws {
        // Never more cells than pixels: a 3×2 image is a 3×2 grid.
        let tiny = try XCTUnwrap(ArtworkMesh(pixels: solidPixels(width: 3, height: 2, argb(100, 100, 100)), seed: 0))
        XCTAssertEqual([tiny.columns, tiny.rows], [3, 2])
        XCTAssertEqual(tiny.texture.argb.count, 32 * 32)
        // One row: nothing to rotate.
        let strip = try XCTUnwrap(ArtworkMesh(pixels: makePixels(width: 6, height: 1) { x, _ in argb(x * 40, 0, 0) }, seed: 5))
        XCTAssertEqual(strip.rows, 1)
        XCTAssertEqual(strip.controlPoints, (0..<6).map { ArtworkMesh.lifted(argb($0 * 40, 0, 0)) })
        // A large clip frame is sampled on a stride, and still covers every cell.
        let frame = try XCTUnwrap(ArtworkMesh(pixels: makePixels(width: 1280, height: 720) { x, _ in x < 640 ? argb(0, 200, 0) : argb(0, 0, 200) }, seed: 9))
        XCTAssertEqual(Set(frame.controlPoints).count, 2)
        XCTAssertNil(ArtworkMesh(pixels: ArtworkPixels(width: 0, height: 0, argb: []), seed: 0))
    }

    func testFromCGImageDecodesAtMeshSize() throws {
        let image = makeCGImage(width: 480, height: 480) { context in
            // Core Graphics' origin is bottom-left: this fills the image's *bottom* half.
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 480, height: 240))
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 240, width: 480, height: 240))
        }
        let mesh = try XCTUnwrap(ArtworkMesh(image: image, seed: 0))
        XCTAssertEqual(mesh.controlPoints[0], ArtworkMesh.lifted(argb(0, 0, 255)), "the bottom edge is the seam row")
        XCTAssertEqual(mesh.controlPoints[35], ArtworkMesh.lifted(argb(255, 255, 0)))
    }

    func testImagesForTheTexturePath() throws {
        let mesh = try XCTUnwrap(ArtworkMesh(pixels: solidPixels(width: 12, height: 12, argb(10, 20, 30)), seed: 0))
        let texture = try XCTUnwrap(mesh.textureImage())
        XCTAssertEqual([texture.width, texture.height], [32, 32])
        let seamRow = try XCTUnwrap(mesh.seamRowImage())
        XCTAssertEqual([seamRow.width, seamRow.height], [32, 1])

        let regions = ArtworkMesh.textureRegions(in: CGSize(width: 390, height: 844), seam: 390)
        XCTAssertEqual(regions.held, CGRect(x: 0, y: 0, width: 390, height: 390))
        XCTAssertEqual(regions.body, CGRect(x: 0, y: 390, width: 390, height: 454))
        let noSeam = ArtworkMesh.textureRegions(in: CGSize(width: 390, height: 844), seam: 0)
        XCTAssertEqual(noSeam.held, .zero)
        XCTAssertEqual(noSeam.body, CGRect(x: 0, y: 0, width: 390, height: 844))
    }
}

/// The mesh laid out for SwiftUI's `MeshGradient`.
final class ArtworkMeshGridTests: XCTestCase {
    private func mesh() throws -> ArtworkMesh {
        // Distinct rows so the layout's row mapping is visible.
        try XCTUnwrap(ArtworkMesh(pixels: makePixels(width: 120, height: 120) { _, y in argb(0, 0, 40 + (119 - y) / 20 * 40) }, seed: 0))
    }

    func testWithoutASeamTheWholeMeshIsOnScreen() throws {
        let mesh = try mesh()
        let grid = mesh.gridLayout(seamFraction: 0)
        XCTAssertEqual([grid.width, grid.height], [8, 8])
        XCTAssertEqual(grid.points.count, 64)
        XCTAssertEqual(grid.colors.count, 64)
        XCTAssertEqual(grid.points[0], SIMD2(0, 0))
        XCTAssertEqual(grid.points[63], SIMD2(1, 1))
        // Column 1 sits at the first cell's centre; row 1 likewise.
        XCTAssertEqual(grid.points[1].x, 1.0 / 12.0, accuracy: 1e-6)
        XCTAssertEqual(grid.points[8].y, 1.0 / 12.0, accuracy: 1e-6)
        // Edges hold the outermost control colours.
        XCTAssertEqual(grid.colors[0], mesh.controlColors[0])
        XCTAssertEqual(grid.colors[8 * 7 + 7], mesh.controlColors[35])
        XCTAssertEqual(grid.colors[8 * 3 + 4], mesh.controlColors[2 * 6 + 3])
    }

    func testTheSeamRowIsHeldBehindTheArtwork() throws {
        let mesh = try mesh()
        let grid = mesh.gridLayout(seamFraction: 0.4)
        XCTAssertEqual([grid.width, grid.height], [8, 9])
        // Rows at y = 0 and y = seam both carry the seam row.
        XCTAssertEqual(grid.points[8].y, 0.4, accuracy: 1e-6)
        for column in 0..<8 {
            XCTAssertEqual(grid.colors[column], grid.colors[8 + column])
        }
        XCTAssertEqual(grid.colors[1], mesh.controlColors[0])
        // The first cell centre below the seam.
        XCTAssertEqual(grid.points[16].y, 0.4 + 0.6 / 12, accuracy: 1e-6)
        XCTAssertEqual(grid.colors[8 * 8 + 1], mesh.controlColors[30])
    }

    func testSeamAtTheBottomHoldsOneRowEverywhere() throws {
        let mesh = try mesh()
        let grid = mesh.gridLayout(seamFraction: 1.5)
        XCTAssertEqual([grid.width, grid.height], [8, 2])
        XCTAssertEqual(Array(grid.colors[0..<8]), Array(grid.colors[8..<16]))
        XCTAssertEqual(mesh.gridLayout(seamFraction: .nan).height, 8)
    }

    @available(iOS 18.0, macOS 15.0, *)
    func testBuildsAMeshGradient() throws {
        let grid = try mesh().gridLayout(seamFraction: 0.3)
        _ = grid.meshGradient()
    }
}

/// The mesh backdrop's crossfade (`ArtworkMeshBackdrop`'s `LaunchedEffect(mesh)`).
final class ArtworkMeshCrossfadeTests: XCTestCase {
    private func mesh(_ color: UInt32) -> ArtworkMesh {
        ArtworkMesh(pixels: solidPixels(width: 12, height: 12, color), seed: 0)!
    }

    func testFirstMeshHasNothingToFadeFrom() {
        var fade = ArtworkMeshCrossfade()
        fade.receive(mesh(argb(200, 0, 0)), at: 0, reduceAnimation: false)
        XCTAssertEqual(fade.shown, mesh(argb(200, 0, 0)))
        XCTAssertNil(fade.incoming)
        XCTAssertEqual(fade.layers(at: 0).map(\.opacity), [1])
    }

    func testNewMeshFadesInOverTheOldOne() {
        let red = mesh(argb(200, 0, 0))
        let blue = mesh(argb(0, 0, 200))
        var fade = ArtworkMeshCrossfade(mesh: red)
        fade.receive(blue, at: 10, reduceAnimation: false)
        XCTAssertEqual(fade.shown, red)
        XCTAssertEqual(fade.incoming, blue)
        XCTAssertEqual(fade.incomingOpacity(at: 10), 0)
        XCTAssertEqual(fade.layers(at: 10).count, 1, "an invisible layer isn't drawn")
        XCTAssertEqual(fade.incomingOpacity(at: 10 + 0.9 * 0.35), 0.5, accuracy: 1e-6)
        XCTAssertFalse(fade.isSettled(at: 10.5))
        let halfway = fade.layers(at: 10.45)
        XCTAssertEqual(halfway.map(\.mesh), [red, blue])
        XCTAssertEqual(halfway[0].opacity, 1)

        XCTAssertTrue(fade.isSettled(at: 10.9))
        fade.settle(at: 10.9)
        XCTAssertEqual(fade.shown, blue)
        XCTAssertNil(fade.incoming)
    }

    func testChangeMidFadeFadesFromWhatWasFadingIn() {
        let red = mesh(argb(200, 0, 0))
        let blue = mesh(argb(0, 0, 200))
        let green = mesh(argb(0, 200, 0))
        var fade = ArtworkMeshCrossfade(mesh: red)
        fade.receive(blue, at: 0, reduceAnimation: false)
        fade.receive(green, at: 0.3, reduceAnimation: false)
        XCTAssertEqual(fade.shown, blue, "the incoming mesh is promoted, not the one before it")
        XCTAssertEqual(fade.incoming, green)
        XCTAssertEqual(fade.fadeStart, 0.3)
    }

    func testReduceAnimationCuts() {
        let red = mesh(argb(200, 0, 0))
        let blue = mesh(argb(0, 0, 200))
        var fade = ArtworkMeshCrossfade(mesh: red)
        fade.receive(blue, at: 0, reduceAnimation: true)
        XCTAssertEqual(fade.shown, blue)
        XCTAssertNil(fade.incoming)
    }

    func testRepeatsAndNilChangeNothing() {
        let red = mesh(argb(200, 0, 0))
        let blue = mesh(argb(0, 0, 200))
        var fade = ArtworkMeshCrossfade(mesh: red)
        fade.receive(red, at: 0, reduceAnimation: false)
        XCTAssertNil(fade.incoming)
        fade.receive(blue, at: 1, reduceAnimation: false)
        // The same mesh arriving again doesn't restart or cut the fade.
        fade.receive(blue, at: 1.2, reduceAnimation: false)
        XCTAssertEqual(fade.incoming, blue)
        XCTAssertEqual(fade.fadeStart, 1)
        // A track whose cover hasn't been read yet leaves the backdrop alone.
        fade.receive(nil, at: 1.3, reduceAnimation: false)
        XCTAssertEqual(fade.shown, red)
        XCTAssertEqual(fade.incoming, blue)
    }
}

/// Kotlin's seeded `Random` and Java's `String.hashCode`, which together decide a
/// cover's mesh arrangement — they must match Android bit for bit.
final class KotlinDeterminismTests: XCTestCase {
    /// Kotlin's own sample, `samples.random.Randoms.seededRandom`.
    func testSeededRandomMatchesKotlinStdlib() {
        func list(_ seed: Int32) -> [Int32] {
            var random = KotlinXorWowRandom(seed: seed)
            return (0..<10).map { _ in random.nextInt(until: 100) }
        }
        XCTAssertEqual(list(42), [33, 40, 41, 2, 41, 32, 21, 40, 69, 87])
        XCTAssertEqual(list(0), [14, 48, 57, 67, 82, 7, 61, 27, 14, 59])
    }

    func testPowerOfTwoBoundsTakeUpperBits() {
        var a = KotlinXorWowRandom(seed: 7)
        var b = KotlinXorWowRandom(seed: 7)
        let raw = b.nextInt()
        XCTAssertEqual(a.nextInt(until: 8), Int32(bitPattern: UInt32(bitPattern: raw) >> 29))
        XCTAssertEqual(KotlinXorWowRandom.takeUpperBits(-1, 0), 0)
        XCTAssertEqual(KotlinXorWowRandom.takeUpperBits(-1, 1), 1)
        XCTAssertEqual(KotlinXorWowRandom.takeUpperBits(Int32.min, 1), 1)
        var c = KotlinXorWowRandom(seed: 3)
        XCTAssertEqual(c.nextInt(until: 1), 0)
    }

    func testJavaStringHashCode() {
        XCTAssertEqual(javaStringHashCode(""), 0)
        XCTAssertEqual(javaStringHashCode("abc"), 96354)
        XCTAssertEqual(javaStringHashCode("hello"), 99_162_322)
        // The famous one that wraps to exactly Integer.MIN_VALUE.
        XCTAssertEqual(javaStringHashCode("polygenelubricants"), Int32.min)
        // UTF-16 code units, not scalars or bytes.
        XCTAssertEqual(javaStringHashCode("é"), 233)
        XCTAssertEqual(javaStringHashCode("😀"), 0xD83D &* 31 &+ 0xDE00)
        XCTAssertEqual(ArtworkMesh.seed(forArtworkURL: nil), 0)
        XCTAssertEqual(ArtworkMesh.seed(forArtworkURL: "abc"), 96354)
    }
}
