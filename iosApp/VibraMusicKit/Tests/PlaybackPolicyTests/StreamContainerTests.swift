import XCTest
@testable import PlaybackPolicy

/// Whether a stream URL is audio or an index of it (ports StreamContainerTest, plus the declared and
/// served halves it doesn't cover).
final class StreamContainerTests: XCTestCase {
    func testDashReopenChangesVirtualURIWhilePreservingPlaybackIdentity() {
        let original = "vibramusic://watch?v=iQnRCdtECl8&n=Wait&a=M83&d=344"

        let reopened = StreamContainer.markedForManifestReopen(original, mime: "application/dash+xml")

        XCTAssertNotEqual(reopened, original)
        XCTAssertEqual(reopened, "\(original)&manifest_reopen=dash")
    }

    func testHLSSourceTrackReopenPreservesSourceParametersAndFragment() {
        let original = "vibramusic://source?s=addon-1&t=track-2&n=Wait#part"

        XCTAssertEqual(
            StreamContainer.markedForManifestReopen(original, mime: "application/x-mpegURL"),
            "vibramusic://source?s=addon-1&t=track-2&n=Wait&manifest_reopen=hls#part"
        )
    }

    func testNonManifestMimeDoesNotForceASourceRebuild() {
        let original = "vibramusic://watch?v=iQnRCdtECl8"

        XCTAssertEqual(StreamContainer.markedForManifestReopen(original, mime: "audio/flac"), original)
    }

    func testAURIWithoutAQueryGetsOne() {
        XCTAssertEqual(
            StreamContainer.markedForManifestReopen("vibramusic://source", mime: StreamContainer.hlsMimeType),
            "vibramusic://source?manifest_reopen=hls"
        )
    }

    /// Judged on the extension, never on the query or the codec a module named.
    func testTheExtensionDecidesWhenNothingWasDeclared() {
        let container = StreamContainer()
        XCTAssertEqual(container.manifestMime(of: "https://cdn.example/t/master.m3u8?token=a.b"), StreamContainer.hlsMimeType)
        XCTAssertEqual(container.manifestMime(of: "https://cdn.example/t/manifest.MPD"), StreamContainer.dashMimeType)
        XCTAssertNil(container.manifestMime(of: "https://cdn.example/t/track.flac?format=m3u8"))
        XCTAssertNil(container.manifestMime(of: "https://cdn.example/dash/123"))
        XCTAssertFalse(container.isManifest("https://cdn.example/t/track.m4a"))
        XCTAssertTrue(container.isManifest("https://cdn.example/t/index.m3u8"))
    }

    /// The reference addon serves an HLS playlist from `/dash/{id}` and reports `format: "flac"`:
    /// three ways of looking like a plain file. The addon saying so is the only way to know.
    func testADeclaredTransportOutranksTheExtension() {
        let container = StreamContainer()
        let url = "https://addon.example/dash/3919244?sig=abc"
        XCTAssertNil(container.transport(of: url))

        container.declare(url, transport: "HLS")

        XCTAssertEqual(container.transport(of: url), .hls)
        XCTAssertEqual(container.manifestMime(of: url), StreamContainer.hlsMimeType)
        XCTAssertTrue(StreamContainer.Transport.hls.playsInAVFoundation)
        XCTAssertFalse(StreamContainer.Transport.dash.playsInAVFoundation, "AVPlayer has no DASH support")
    }

    func testAnUnknownTransportIsIgnored() {
        let container = StreamContainer()
        container.declare("https://addon.example/x", transport: "smooth")
        XCTAssertNil(container.manifestMime(of: "https://addon.example/x"))
    }

    /// Last write wins, and the last write is what is playing.
    func testWhatATrackIsServedIsTheLastRecordedURL() {
        let container = StreamContainer()
        container.served("track", from: "https://cdn.example/a/index.mpd")
        XCTAssertEqual(container.manifestServing("track"), StreamContainer.dashMimeType)

        container.served("track", from: "https://rr1.googlevideo.com/videoplayback?itag=140")
        XCTAssertNil(container.manifestServing("track"))
        XCTAssertNil(container.manifestServing("never-served"))
    }

    /// Bounded the cheap way: losing an entry costs a guess, not a track.
    func testDeclarationsAreBounded() {
        let container = StreamContainer()
        for index in 0..<StreamContainer.maxRemembered {
            container.declare("https://addon.example/\(index)", transport: "dash")
        }
        XCTAssertEqual(container.transport(of: "https://addon.example/0"), .dash)
        container.declare("https://addon.example/overflow", transport: "dash")
        XCTAssertNil(container.transport(of: "https://addon.example/0"))
        XCTAssertEqual(container.transport(of: "https://addon.example/overflow"), .dash)
    }
}
