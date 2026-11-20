import XCTest
import VibraMusicTestSupport
@testable import VibraMusicCore

/// Song is persisted by the queue, downloads and party sync, so its JSON is a contract.
final class SongModelTests: XCTestCase {
    private let fixtures = FixtureLoader(bundle: .module)

    private func everyFieldSong() -> Song {
        Song(
            videoId: "dQw4w9WgXcQ",
            title: "Never Gonna Give You Up",
            artist: "Rick Astley",
            thumbnailUrl: "https://lh3.googleusercontent.com/abc=w120-h120-l90-rj",
            durationText: "3:33",
            artistId: "UCuAXFkgsw1L7xaCfnd5JJOw",
            albumId: "MPREb_abc",
            albumName: "Whenever You Need Somebody",
            isVideo: true,
            isVideoOrigin: true,
            setVideoId: "56B44F6D10557CC6",
            queueTier: .userQueue,
            queueEntryId: "entry-1",
            radioName: "Rick Astley Radio",
            localUri: "file:///var/mobile/Downloads/dQw4w9WgXcQ.m4a",
            downloadFormat: "FLAC",
            localPath: "/var/mobile/Downloads/dQw4w9WgXcQ.m4a",
            localDateAddedSeconds: 1_700_000_000,
            localDateModifiedSeconds: 1_700_000_100,
            sourceQuality: .lossless,
            isExplicit: false,
            playbackSource: "Liked Music",
            playbackSourceType: .browse,
            playbackSourceId: "VLLM"
        )
    }

    func testEveryFieldSurvivesAJSONRoundTrip() throws {
        let song = everyFieldSong()
        let decoded = try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(song))
        XCTAssertEqual(decoded, song)
    }

    func testAQueueSurvivesAJSONFileStoreRoundTrip() throws {
        let store = JSONFileStore(directory: try makeTemporaryDirectory())
        let queue = [everyFieldSong(), Song(videoId: "b", title: "B", artist: "Artist")]
        try store.save(queue, to: "queue.json")
        XCTAssertEqual(try store.load([Song].self, from: "queue.json"), queue)
    }

    /// The recorded shape: if this breaks, persisted queues and downloads stop loading.
    func testDecodesTheRecordedJSONShape() throws {
        let decoded = try fixtures.decode(Song.self, from: "song_full.json")
        XCTAssertEqual(decoded, everyFieldSong())
    }

    func testDecodingIsLenientAboutMissingUnknownAndFutureValues() throws {
        let song = try fixtures.decode(Song.self, from: "song_minimal_future.json")
        XCTAssertEqual(song.videoId, "abc123")
        XCTAssertEqual(song.queueTier, .context, "an unknown tier falls back instead of failing the queue")
        XCTAssertNil(song.sourceQuality)
        XCTAssertNil(song.playbackSourceType)
        XCTAssertFalse(song.isVideo)
        XCTAssertFalse(song.isVideoOrigin)
        XCTAssertNil(song.thumbnailUrl)
    }

    func testLegacyFromAutoplayFlagBecomesTheAutoplayTier() throws {
        let json = #"{"videoId":"x","title":"T","artist":"A","fromAutoplay":true}"#
        let song = try JSONDecoder().decode(Song.self, from: Data(json.utf8))
        XCTAssertEqual(song.queueTier, .autoplay)
        XCTAssertTrue(song.fromAutoplay)
    }

    func testNilFieldsAreOmittedFromJSON() throws {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Song(videoId: "x", title: "T", artist: "A"))) as? [String: Any]
        XCTAssertEqual(Set((json ?? [:]).keys), ["videoId", "title", "artist", "isVideo", "isVideoOrigin", "queueTier"])
    }

    func testVideoOriginDefaultsToIsVideo() {
        XCTAssertTrue(Song(videoId: "x", title: "T", artist: "A", isVideo: true).isVideoOrigin)
        XCTAssertFalse(Song(videoId: "x", title: "T", artist: "A").isVideoOrigin)
        // A video's catalogue match stays video-origin.
        XCTAssertTrue(Song(videoId: "x", title: "T", artist: "A", isVideo: false, isVideoOrigin: true).isVideoOrigin)
    }

    func testIdPrefersQueueEntryThenPlaylistSlotThenVideoId() {
        XCTAssertEqual(Song(videoId: "v", title: "T", artist: "A").id, "v")
        XCTAssertEqual(Song(videoId: "v", title: "T", artist: "A", setVideoId: "s").id, "s")
        XCTAssertEqual(Song(videoId: "v", title: "T", artist: "A", setVideoId: "s", queueEntryId: "q").id, "q")
    }

    // MARK: Now-playing highlight

    func testSameTrackMatchesOnTitleAndArtistOnly() {
        let playing = Song(videoId: "yt", title: "One More Time", artist: "Daft Punk", setVideoId: "slot1")
        let download = Song(videoId: "local-1", title: "One More Time", artist: "Daft Punk")
        XCTAssertTrue(download.isSameTrackAs(playing), "the same recording from another catalogue still lights up")
        let stranger = Song(videoId: "yt2", title: "Aerodynamic", artist: "Daft Punk", setVideoId: "slot1")
        XCTAssertFalse(stranger.isSameTrackAs(playing), "a shared set-video-id must not light up a stranger's row")
        XCTAssertFalse(playing.isSameTrackAs(nil))
    }

    // MARK: Artwork

    func testArtworkAtRewritesTheSizeHint() {
        let song = Song(videoId: "x", title: "T", artist: "A", thumbnailUrl: "https://lh3.googleusercontent.com/abc=w120-h120-l90-rj")
        XCTAssertEqual(song.artworkAt(ArtworkSize.player), "https://lh3.googleusercontent.com/abc=w1200-h1200-l90-rj")
        XCTAssertEqual(song.artworkAt(ArtworkSize.row), "https://lh3.googleusercontent.com/abc=w160-h160-l90-rj")
        XCTAssertEqual(song.artworkURL(at: 480)?.absoluteString, "https://lh3.googleusercontent.com/abc=w480-h480-l90-rj")
    }

    func testArtworkWithoutAHintIsUnchanged() {
        let video = "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"
        XCTAssertEqual(Artwork.resized(video, to: 544), video)
        XCTAssertNil(Artwork.resized(nil, to: 544))
        XCTAssertNil(Song(videoId: "x", title: "T", artist: "A").artworkAt(160))
    }

    func testArtworkLadderMatchesAndroid() {
        XCTAssertEqual([ArtworkSize.row, ArtworkSize.card, ArtworkSize.header, ArtworkSize.lockScreen, ArtworkSize.player],
                       [160, 480, 720, 544, 1200])
    }
}
