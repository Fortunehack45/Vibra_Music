import AVFoundation
import VibraMusicCore
import XCTest
@testable import Playback

final class PlayableItemTests: XCTestCase {
    func testAQueueRowMapsOntoAnItem() {
        let song = Song(
            videoId: "vid",
            title: "Title",
            artist: "Artist",
            thumbnailUrl: "https://lh3.googleusercontent.com/abc=w120-h120",
            durationText: "3:45",
            albumName: "Album",
            isVideo: true,
            queueEntryId: "entry-7"
        )
        let item = PlayableItem(song: song, source: .file(URL(fileURLWithPath: "/tmp/x.m4a")), loudnessDb: -4)
        XCTAssertEqual(item.id, "entry-7", "one item per queue slot, not per song")
        XCTAssertEqual(item.title, "Title")
        XCTAssertEqual(item.album, "Album")
        XCTAssertEqual(item.duration, 225)
        XCTAssertEqual(item.loudnessDb, -4)
        XCTAssertTrue(item.isVideoOrigin)
        XCTAssertEqual(item.song, song)
        XCTAssertEqual(item.artworkURL, song.artworkURL(at: ArtworkSize.lockScreen), "sized for the lock screen")
        XCTAssertEqual(item.fileURL?.lastPathComponent, "x.m4a")
    }

    func testUnknownDurationStaysUnknown() {
        let item = PlayableItem(id: "a", title: "a", artist: "b", duration: 0, source: .asset { AVURLAsset(url: URL(fileURLWithPath: "/tmp/a")) })
        XCTAssertNil(item.duration)
        XCTAssertNil(item.fileURL)
    }

    func testAResolvedStreamOpensWithItsHeadersAndType() async throws {
        let stream = ResolvedStream(
            url: URL(string: "https://rr1.googlevideo.com/videoplayback?expire=1")!,
            origin: .youtube,
            mimeType: "audio/mp4; codecs=\"mp4a.40.2\"",
            format: StreamFormat(codec: "aac", kbps: 128),
            headers: ["User-Agent": "com.google.android.youtube/19"],
            loudnessDb: -6.5
        )
        let opened = try await PlayableItem.Source.stream { stream }.open()
        XCTAssertEqual(opened.asset.url, stream.url)
        XCTAssertEqual(opened.loudnessDb, -6.5)
        XCTAssertEqual(opened.declaredFormat, StreamFormat(codec: "aac", kbps: 128))
    }

    func testAResolvedAssetOpensItsAssetWithTheStreamsFacts() async throws {
        let asset = AVURLAsset(url: URL(string: "vibramusic-cache://track/abc")!)
        let stream = ResolvedStream(url: URL(string: "https://example.com/a")!, origin: .youtube,
                                    format: StreamFormat(codec: "opus", kbps: 160), loudnessDb: -3)
        let opened = try await PlayableItem.Source.resolvedAsset { (asset, stream) }.open()
        XCTAssertTrue(opened.asset === asset)
        XCTAssertEqual(opened.loudnessDb, -3)
        XCTAssertEqual(opened.declaredFormat, StreamFormat(codec: "opus", kbps: 160))

        let bare = try await PlayableItem.Source.resolvedAsset { (asset, nil) }.open()
        XCTAssertNil(bare.loudnessDb)
        XCTAssertNil(bare.declaredFormat)
        let unclaimed = ResolvedStream(url: URL(string: "https://example.com/a")!, origin: .youtube)
        let blank = try await PlayableItem.Source.resolvedAsset { (asset, unclaimed) }.open()
        XCTAssertNil(blank.declaredFormat, "an empty claim is no claim")
    }

    func testAMissingFileFailsBeforeAVFoundationIsInvolved() async {
        let url = URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID().uuidString).caf")
        do {
            _ = try await PlayableItem.Source.file(url).open()
            XCTFail("expected a missing-file error")
        } catch {
            XCTAssertEqual(error as? PlaybackSourceError, .missingLocalFile(url))
        }
    }
}
