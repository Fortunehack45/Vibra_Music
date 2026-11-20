import XCTest
import VibraMusicCore
@testable import PlaybackPolicy

/// The `vibramusic://` queue URIs every rule in this module is phrased against.
final class PlaybackURITests: XCTestCase {
    func testAWatchURICarriesWhatAMatchIsMadeOn() {
        let song = Song(
            videoId: "iQnRCdtECl8",
            title: "Wait (Live) & more",
            artist: "M83",
            durationText: "5:44",
            albumName: "Hurry Up, We're Dreaming",
            isExplicit: false
        )
        XCTAssertEqual(
            PlaybackURI.watch(for: song),
            "vibramusic://watch?v=iQnRCdtECl8&n=Wait%20(Live)%20%26%20more&a=M83&d=344&l=Hurry%20Up%2C%20We're%20Dreaming&e=0"
        )
    }

    /// A row that never carried a runtime or album simply omits them.
    func testMissingFieldsAreOmittedAndMusicVideosAreMarked() {
        let video = Song(videoId: "2kjolTLZ_Mg", title: "São Paulo", artist: "The Weeknd", albumName: " ", isVideo: true)
        XCTAssertEqual(
            PlaybackURI.watch(for: video),
            "vibramusic://watch?v=2kjolTLZ_Mg&n=S%C3%A3o%20Paulo&a=The%20Weeknd&m=1"
        )
    }

    func testASourceKeyBecomesASourceURI() {
        let song = Song(videoId: "src:addon 1::391/9244", title: "Bin Tere", artist: "Vishal & Shekhar", durationText: "4:01")
        XCTAssertEqual(
            PlaybackURI.forStreaming(song, pinnedToOriginal: true),
            "vibramusic://source?s=addon%201&t=391%2F9244&n=Bin%20Tere&a=Vishal%20%26%20Shekhar&d=241",
            "a source track has no YouTube original to be pinned to"
        )
    }

    func testFilesPlayFromTheirOwnURI() {
        let song = Song(videoId: "file:///var/mobile/Downloads/a.flac", title: "t", artist: "a")
        XCTAssertEqual(PlaybackURI.forStreaming(song, pinnedToOriginal: false), "file:///var/mobile/Downloads/a.flac")
    }

    func testMediaLibraryFilesPlayFromTheirOwnURI() {
        let song = Song(videoId: "ipod-library://item/42", title: "t", artist: "a")
        XCTAssertEqual(PlaybackURI.forStreaming(song, pinnedToOriginal: false), "ipod-library://item/42")
        XCTAssertEqual(PlaybackURI.forStreaming(song, pinnedToOriginal: true), "ipod-library://item/42")
    }

    func testQueryValuesAreDecodedAndTheFirstOccurrenceWins() {
        let uri = "vibramusic://watch?v=abc&n=Bin%20Tere&a=Vishal+%26+Shekhar&q=hifi&q=hifi-2&empty=&bare#frag=x"
        XCTAssertEqual(PlaybackURI.queryValue("v", in: uri), "abc")
        XCTAssertEqual(PlaybackURI.queryValue("n", in: uri), "Bin Tere")
        XCTAssertEqual(PlaybackURI.queryValue("a", in: uri), "Vishal & Shekhar")
        XCTAssertEqual(PlaybackURI.queryValue("q", in: uri), "hifi")
        XCTAssertEqual(PlaybackURI.queryValue("empty", in: uri), "")
        XCTAssertEqual(PlaybackURI.queryValue("bare", in: uri), "")
        XCTAssertNil(PlaybackURI.queryValue("frag", in: uri), "the fragment is not the query")
        XCTAssertNil(PlaybackURI.queryValue("v", in: "vibramusic://watch"))
    }

    func testSourceURIsAreRecognisedByAuthority() {
        XCTAssertTrue(PlaybackURI.isSourceURI("vibramusic://source?s=a&t=b"))
        XCTAssertTrue(PlaybackURI.isSourceURI("vibramusic://source#x"))
        XCTAssertFalse(PlaybackURI.isSourceURI("vibramusic://watch?v=source"))
        XCTAssertFalse(PlaybackURI.isSourceURI("vibramusic://sourcery?s=a"))
    }
}
