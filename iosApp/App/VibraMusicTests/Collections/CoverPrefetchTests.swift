import VibraMusicCore
import InnerTube
import UIKit
import XCTest
@testable import VibraMusic

/// A list loads the covers of the rows just below the screen, as UICollectionView prefetches, so a
/// scroll finds them in memory and draws them on its first frame rather than fading them in.
@MainActor
final class CoverPrefetchTests: XCTestCase {
    /// Sixty tracks, each with a cover file of its own, titled in running order.
    private func coveredSongs(_ prefix: String) throws -> [Song] {
        let folder = makeTemporaryDirectory(self)
        let picture = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return try (0..<60).map { index -> Song in
            let cover = folder.appending(path: "cover-\(index).png")
            try picture.write(to: cover)
            return Song(videoId: "\(prefix)\(index)", title: String(format: "Track %02d", index), artist: "Artist",
                        thumbnailUrl: cover.absoluteString)
        }
    }

    private func inMemory(_ song: Song) -> Bool {
        ArtworkImageCache.shared.memoryImage(for: URL(string: song.thumbnailUrl ?? "")!, pixels: ArtworkSize.row) != nil
    }

    func testAPlaylistLoadsTheCoversOfTheRowsBelowTheScreen() async throws {
        let songs = try coveredSongs("pf")
        let service = FakeCollectionsService()
        service.songPages[CollectionsFixtures.playlistId] = YTMusicRepository.SongPage(
            songs: songs, continuation: nil, library: nil,
            header: InnerTubeParser.BrowseHeader(title: "Long", subtitle: "Playlist • Me", thumbnailUrl: nil), description: nil)
        let (model, _, _) = makeCollectionsTestModel(self, service: service)

        await host(AlbumPlaylistScreen(browseId: CollectionsFixtures.playlistId, seed: nil), model: model)

        await waitUntil("the first row draws its cover") { self.inMemory(songs[0]) }
        // Under the header an iPhone screen shows a handful of rows; row 20 is far below them.
        await waitUntil("a row below the screen has its cover in memory") { self.inMemory(songs[20]) }
        XCTAssertFalse(inMemory(songs[59]), "a window ahead of the reader, not the whole list")
    }

    /// The Downloads folder's Songs tab reads ahead the same way.
    func testTheDownloadsFolderLoadsTheCoversOfTheRowsBelowTheScreen() async throws {
        let songs = try coveredSongs("lm")
        let (model, _, _) = makeCollectionsTestModel(self)
        model.settings.downloadedMusicSort = .titleAsc
        model.settings.downloadedMusicViewType = .list

        await host(LocalMusicView(title: L10n.downloads, browseId: LocalBrowseID.downloads, songs: songs, isDownloads: true),
                   model: model)

        await waitUntil("the first row draws its cover") { self.inMemory(songs[0]) }
        // About fourteen rows fit under the search field and the tabs; row 30 is well below them.
        await waitUntil("a row below the screen has its cover in memory") { self.inMemory(songs[30]) }
        XCTAssertFalse(inMemory(songs[59]), "a window ahead of the reader, not the whole list")
    }
}
