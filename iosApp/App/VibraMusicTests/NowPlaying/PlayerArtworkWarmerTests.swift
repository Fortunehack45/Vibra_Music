import VibraMusicCore
import PlaybackQueue
import Theming
import XCTest
@testable import VibraMusic

/// A skip finds the next and previous tracks' cover, mesh, tint and blur already read, from one
/// download each.
@MainActor
final class PlayerArtworkWarmerTests: XCTestCase {
    private func song(_ id: String) -> Song {
        Song(videoId: id, title: id, artist: "a", thumbnailUrl: "https://covers.test/\(UUID().uuidString)/\(id)-w120-h120.png")
    }

    func testOnlyTheNeighboursOfTheCurrentTrackAreWarmed() {
        let songs = ["a", "b", "c", "d", "e"].map(song)
        let state = PlaybackQueueState(songs: songs, currentIndex: 2)
        XCTAssertEqual(PlayerArtworkWarmer.neighbours(in: state).map(\.videoId), ["b", "d"])
        XCTAssertEqual(PlayerArtworkWarmer.neighbours(in: PlaybackQueueState(songs: songs, currentIndex: 0)).map(\.videoId), ["b"])
        XCTAssertTrue(PlayerArtworkWarmer.neighbours(in: PlaybackQueueState()).isEmpty)
        // Repeat all wraps: the first track's previous is the last, and the last's next the first.
        let wrapped = PlaybackQueueState(songs: songs, currentIndex: 0, repeatMode: .all)
        XCTAssertEqual(PlayerArtworkWarmer.neighbours(in: wrapped).map(\.videoId), ["e", "b"])
    }

    func testAWarmedNeighbourIsInEveryCacheAtTheSizeThePlayerAsksForAfterOneDownload() async throws {
        let images = ArtworkImageCache(directory: makeTemporaryDirectory(self), session: CoverServer.session())
        let palettes = ArtworkPaletteCache(loader: ArtworkCacheLoader(cache: images))
        let warmer = PlayerArtworkWarmer(images: images, palettes: palettes)
        let next = song("next"), later = song("later")
        let url = try XCTUnwrap(PlayerArtworkLoader.url(for: next))

        await warmer.warm([next])

        // What the player reads on the swap: the cover unsized, the mesh, tint and blur by URL.
        XCTAssertNotNil(images.memoryImage(for: url))
        XCTAssertNotNil(palettes.cachedMesh(for: url))
        XCTAssertNotNil(palettes.cachedSeed(for: url))
        XCTAssertNotNil(palettes.cachedBlurredArtwork(for: url))
        XCTAssertEqual(CoverServer.requests(for: url), 1)
        // The colour reads join that download; a read at another size would be a second one.
        for pixels in [ArtworkSize.row, ArtworkSize.card] {
            let other = try XCTUnwrap(Artwork.resized(next.thumbnailUrl, to: pixels).flatMap(URL.init(string:)))
            XCTAssertEqual(CoverServer.requests(for: other), 0)
        }
        XCTAssertEqual(CoverServer.requests(for: try XCTUnwrap(PlayerArtworkLoader.url(for: later))), 0)
    }
}
