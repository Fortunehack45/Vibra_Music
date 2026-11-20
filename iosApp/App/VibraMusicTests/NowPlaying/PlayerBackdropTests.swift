import VibraMusicCore
import SwiftUI
import Theming
import XCTest
@testable import VibraMusic

/// PORTING.md 2.3 "Artwork-driven background" — done: the background colours change with each new
/// song.
@MainActor
final class ArtworkBackgroundTests: XCTestCase {
    func testTheBackgroundColoursChangeWithEachNewSong() async throws {
        let cache = ArtworkPaletteCache(
            loader: SolidColourArtworkLoader(colours: ["red": 0xFFC0_2020, "blue": 0xFF20_40C0]),
            retryDelay: 0
        )
        let model = NowPlayingModel(palettes: cache)
        let red = URL(string: "https://art.test/red")!
        let blue = URL(string: "https://art.test/blue")!

        await model.mesh.load(red, trackID: "song-1", artPixels: ArtworkSize.player)
        let first = try XCTUnwrap(model.mesh.mesh)
        await model.mesh.load(blue, trackID: "song-2", artPixels: ArtworkSize.player)
        let second = try XCTUnwrap(model.mesh.mesh)

        XCTAssertNotEqual(first, second)
        let firstColour = try XCTUnwrap(first.controlColors.first)
        let secondColour = try XCTUnwrap(second.controlColors.first)
        XCTAssertGreaterThan(firstColour.red, firstColour.blue, "a red sleeve leaves a red backdrop")
        XCTAssertGreaterThan(secondColour.blue, secondColour.red, "a blue sleeve leaves a blue backdrop")
    }

    func testTheMeshBackdropRendersWithAndWithoutASeam() async throws {
        let cache = ArtworkPaletteCache(loader: SolidColourArtworkLoader(colours: ["red": 0xFFC0_2020]), retryDelay: 0)
        let found = await cache.mesh(for: URL(string: "https://art.test/red")!)
        let mesh = try XCTUnwrap(found)
        // A red sleeve paints the whole surface red, above the seam, around it and below it; a
        // backdrop that dropped the mesh (or left a gap at the seam) shows the neutral fallback.
        let window = CGSize(width: 393, height: 852)
        for seam in [CGFloat(0), 420] {
            let host = hostAndLayOut(PlayerMeshBackdrop(mesh: mesh, seam: seam), size: window)
            defer { host.view.window?.isHidden = true }
            for band in [CGRect(x: 0, y: 300, width: 393, height: 40), CGRect(x: 0, y: 405, width: 393, height: 30),
                         CGRect(x: 0, y: 500, width: 393, height: 40)] {
                let red = host.view.drawnBounds(in: band) { red, green, blue in red > green + 25 && red > blue + 25 }
                XCTAssertGreaterThan(red?.width ?? 0, 300, "no red across y \(band.minY) with the seam at \(seam)")
            }
        }
        hostAndLayOut(PlayerLegacyMeshBackdrop(palette: .fallback, trackKey: "a"))
        hostAndLayOut(PlayerArtworkBlurBackdrop(url: URL(string: "https://art.test/red"), palettes: cache))
    }

    /// A square cover filled into a tall window must not size the surface to the picture: that
    /// widened the whole portrait player past the screen's edges.
    func testFilledCoversNeverWidenTheirSurface() async throws {
        let cache = ArtworkPaletteCache(loader: SolidColourArtworkLoader(colours: ["red": 0xFFC0_2020]), retryDelay: 0)
        let url = URL(string: "https://art.test/red")!
        _ = await cache.blurredArtwork(for: url, artPixels: ArtworkSize.player)
        let window = CGSize(width: 393, height: 852)

        let blur = hostAndLayOut(PlayerArtworkBlurBackdrop(url: url, palettes: cache), size: window)
        XCTAssertLessThanOrEqual(blur.sizeThatFits(in: window).width, window.width)

        let square = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 600)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
        }
        let banner = hostAndLayOut(PlayerHeroBanner(image: square), size: window)
        XCTAssertLessThanOrEqual(banner.sizeThatFits(in: window).width, window.width)
    }
}
