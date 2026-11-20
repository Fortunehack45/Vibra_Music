import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import AudioCache

/// The cache key (track identity, one entry per rendition) and the content type AVFoundation is
/// told for a custom-scheme asset.
final class CacheKeyAndContentTypeTests: XCTestCase {
    // MARK: Keys

    func testKeysReadLikeAndroidsCacheKeys() {
        XCTAssertEqual(AudioCacheKey.youtube(videoId: "dQw4w9WgXcQ").rawValue, "dQw4w9WgXcQ")
        XCTAssertEqual(AudioCacheKey.youtube(videoId: "dQw4w9WgXcQ", rendition: "hifi").rawValue, "dQw4w9WgXcQ#hifi")
        XCTAssertEqual(AudioCacheKey.youtube(videoId: "v", rendition: "").rawValue, "v")
        XCTAssertEqual(AudioCacheKey.substitute(videoId: "v", atmosAllowed: true).rawValue, "v#alt")
        XCTAssertEqual(AudioCacheKey.substitute(videoId: "v", atmosAllowed: false).rawValue, "v#alt-noatmos")
        XCTAssertEqual(AudioCacheKey.source("jiosaavn", track: "abc").rawValue, "jiosaavn|abc")
        XCTAssertEqual(AudioCacheKey.source("addon", track: "t1", rendition: "flac").rawValue, "addon|t1#flac")
    }

    func testTrackAndRenditionAreParsedBack() {
        let upgrade = AudioCacheKey(rawValue: "vid#hifi")
        XCTAssertEqual(upgrade.trackID, "vid")
        XCTAssertEqual(upgrade.rendition, "hifi")
        XCTAssertFalse(upgrade.isSubstitute)
        XCTAssertNil(AudioCacheKey(rawValue: "vid").rendition)
        XCTAssertNil(AudioCacheKey(rawValue: "vid#").rendition)
        XCTAssertTrue(AudioCacheKey.substitute(videoId: "vid", atmosAllowed: false).isSubstitute)
        XCTAssertEqual(AudioCacheKey.source("s", track: "t", rendition: "r").trackID, "s|t")
    }

    func testEveryRenditionBelongsToItsTrackAndNoOther() {
        XCTAssertTrue(AudioCacheKey(rawValue: "vid").belongs(toTrack: "vid"))
        XCTAssertTrue(AudioCacheKey(rawValue: "vid#alt").belongs(toTrack: "vid"))
        XCTAssertFalse(AudioCacheKey(rawValue: "vid2").belongs(toTrack: "vid"), "a longer id is another track")
        XCTAssertFalse(AudioCacheKey(rawValue: "vi").belongs(toTrack: "vid"))
    }

    func testKeyEncodesAsItsRawString() throws {
        let key = AudioCacheKey.youtube(videoId: "vid", rendition: "hifi")
        let data = try JSONEncoder().encode(key)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"vid#hifi\"")
        XCTAssertEqual(try JSONDecoder().decode(AudioCacheKey.self, from: data), key)
    }

    // MARK: Content types

    func testMIMETypesMapToTheUTIsAVFoundationWants() {
        XCTAssertEqual(AudioContentType.uti(mimeType: "audio/mp4; codecs=\"mp4a.40.2\""), AudioContentType.mpeg4Audio)
        XCTAssertEqual(AudioContentType.uti(mimeType: "AUDIO/MP4"), AudioContentType.mpeg4Audio)
        XCTAssertEqual(AudioContentType.uti(mimeType: "video/mp4"), AudioContentType.mpeg4)
        XCTAssertEqual(AudioContentType.uti(mimeType: "audio/mpeg"), AudioContentType.mp3)
        XCTAssertEqual(AudioContentType.uti(mimeType: "audio/flac"), AudioContentType.flac)
        XCTAssertEqual(AudioContentType.uti(mimeType: "audio/x-flac"), AudioContentType.flac)
        XCTAssertEqual(AudioContentType.uti(mimeType: "audio/webm; codecs=\"opus\""), AudioContentType.webm)
        XCTAssertEqual(AudioContentType.uti(mimeType: "audio/aac"), AudioContentType.aac)
    }

    func testOctetStreamFallsBackToTheExtension() {
        XCTAssertNil(AudioContentType.uti(mimeType: "application/octet-stream"))
        XCTAssertEqual(AudioContentType.uti(mimeType: "application/octet-stream", pathExtension: "flac"), AudioContentType.flac)
        XCTAssertEqual(AudioContentType.uti(mimeType: nil, pathExtension: "M4A"), AudioContentType.mpeg4Audio)
        XCTAssertEqual(AudioContentType.uti(mimeType: nil, pathExtension: "mp3"), AudioContentType.mp3)
        XCTAssertNil(AudioContentType.uti(mimeType: nil, pathExtension: "txt"))
        XCTAssertNil(AudioContentType.uti(mimeType: nil, pathExtension: nil))
    }

    func testContainersAreRecognisedFromTheirFirstBytes() throws {
        let youtube = try FixtureLoader(bundle: .module).data("itag140_init_segment.mp4")
        XCTAssertEqual(AudioContentType.sniff(youtube), AudioContentType.mpeg4Audio, "brand `dash`")
        XCTAssertEqual(AudioContentType.sniff(Data("fLaC\0\0\0\"".utf8)), AudioContentType.flac)
        XCTAssertEqual(AudioContentType.sniff(Data("ID3\u{4}\0\0\0\0\0\0".utf8)), AudioContentType.mp3)
        XCTAssertEqual(AudioContentType.sniff(Data([0xFF, 0xFB, 0x90, 0x64])), AudioContentType.mp3, "a bare MPEG audio frame")
        XCTAssertEqual(AudioContentType.sniff(Data([0xFF, 0xF1, 0x50, 0x80])), AudioContentType.aac, "ADTS")
        XCTAssertEqual(AudioContentType.sniff(Data([0x1A, 0x45, 0xDF, 0xA3, 0x01])), AudioContentType.webm)
        XCTAssertEqual(AudioContentType.sniff(Data("OggS\0\u{2}".utf8)), AudioContentType.ogg)
        XCTAssertEqual(AudioContentType.sniff(Data("RIFF\0\0\0\0WAVEfmt ".utf8)), AudioContentType.wave)
        XCTAssertEqual(AudioContentType.sniff(Data("\0\0\0\u{1C}ftypisom".utf8)), AudioContentType.mpeg4)
        XCTAssertNil(AudioContentType.sniff(Data("<html>".utf8)))
    }
}
