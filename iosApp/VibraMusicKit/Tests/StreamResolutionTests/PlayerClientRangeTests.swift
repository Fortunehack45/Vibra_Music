import XCTest
@testable import StreamResolution

/// Port of `PlayerClientRangeTest`, plus the header mapping `forStreamURL` owes every client.
final class PlayerClientRangeTests: XCTestCase {
    private func gv(_ client: String, _ version: String = "1.0") -> String {
        "https://rr1---sn-abc.googlevideo.com/videoplayback?c=\(client)&cver=\(version)&clen=5000000"
    }

    func testGooglevideoRangesAreCappedAtOneMegabyte() {
        XCTAssertEqual(StreamPlayerClient.rangeBytes(for: gv("IOS")), 1024 * 1024)
        XCTAssertEqual(StreamPlayerClient.rangeBytes(for: gv("VISIONOS", "1.02")), 1024 * 1024)
        XCTAssertEqual(StreamPlayerClient.rangeBytes(for: gv("TVHTML5")), 1024 * 1024)
    }

    func testClientsRefusedPastAMegabyteGetHalfThat() {
        XCTAssertEqual(StreamPlayerClient.rangeBytes(for: gv("ANDROID_VR", "1.65.10")), 512 * 1024)
        XCTAssertEqual(StreamPlayerClient.rangeBytes(for: gv("TVHTML5_SIMPLY")), 512 * 1024)
    }

    func testNonGooglevideoHostsAreNotCapped() {
        XCTAssertEqual(StreamPlayerClient.rangeBytes(for: "https://sp-ad-cf.audio.tidal.com/x.flac"), Int64.max)
        XCTAssertEqual(StreamPlayerClient.rangeBytes(for: "not a url"), Int64.max)
    }

    func testVisionOSURLsAreFetchedAsVisionOSNotAsAnIPhone() throws {
        let client = StreamPlayerClient.forStreamURL(gv("VISIONOS", "1.02"))
        XCTAssertEqual(client.clientName, "VISIONOS")
        let agent = try XCTUnwrap(client.mediaHeaders["User-Agent"])
        XCTAssertTrue(agent.hasPrefix("com.google.visionos.youtube/1.02"), agent)
    }

    func testRangeOfAResolvedStreamFollowsItsURL() {
        let stream = ResolvedYouTubeStream(
            videoId: "dQw4w9WgXcQ", url: URL(string: gv("ANDROID_VR"))!, itag: 140, kbps: 129,
            mimeType: "audio/mp4", clientName: "ANDROID_VR", profileId: "android_vr", mediaHeaders: [:]
        )
        XCTAssertEqual(stream.rangeChunkBytes, 512 * 1024)
        XCTAssertEqual(StreamResolver.rangeBytes(for: stream.url), 512 * 1024)
    }

    func testEveryModelledClientIsRecognisedFromItsURL() {
        XCTAssertEqual(StreamPlayerClient.forStreamURL(gv("IOS", "21.29.1")), StreamPlayerClient.iosRecent)
        XCTAssertEqual(StreamPlayerClient.forStreamURL(gv("IOS", "20.1")), StreamPlayerClient.ios)
        XCTAssertEqual(StreamPlayerClient.forStreamURL(gv("ANDROID_VR", "1.43.32")), StreamPlayerClient.androidVRLegacy)
        XCTAssertEqual(StreamPlayerClient.forStreamURL(gv("ANDROID_VR", "1.65.10")), StreamPlayerClient.androidVR)
        XCTAssertEqual(StreamPlayerClient.forStreamURL(gv("ANDROID_MUSIC")), StreamPlayerClient.androidMusic)
        XCTAssertEqual(StreamPlayerClient.forStreamURL(gv("ANDROID")), StreamPlayerClient.android)
        XCTAssertEqual(StreamPlayerClient.forStreamURL(gv("TVHTML5_SIMPLY")), StreamPlayerClient.tvhtml5)
        XCTAssertEqual(StreamPlayerClient.forStreamURL(gv("WEB_REMIX")), StreamPlayerClient.webRemix)
        XCTAssertEqual(StreamPlayerClient.forStreamURL(gv("WEB")), StreamPlayerClient.web)
        XCTAssertEqual(StreamPlayerClient.forStreamURL(gv("MWEB")), StreamPlayerClient.web)
        XCTAssertEqual(StreamPlayerClient.forStreamURL(gv("web_remix")), StreamPlayerClient.webRemix, "case-insensitive")
    }

    /// Approximately right beats a smart TV's headers for a URL an iPhone asked for.
    func testUnknownOrMissingClientFallsBackToIOS() {
        XCTAssertEqual(StreamPlayerClient.forStreamURL(gv("SOMETHING_NEW")), StreamPlayerClient.ios)
        XCTAssertEqual(StreamPlayerClient.forStreamURL("https://rr1---sn-abc.googlevideo.com/videoplayback?itag=140"), StreamPlayerClient.ios)
        XCTAssertEqual(StreamPlayerClient.forStreamURL("not a url"), StreamPlayerClient.ios)
    }

    /// App clients send no Origin; browser-shaped ones send Origin and a Referer ending in "/".
    func testOnlyBrowserShapedClientsSendOriginAndReferer() {
        let ios = StreamPlayerClient.forStreamURL(gv("IOS")).mediaHeaders
        XCTAssertNil(ios["Origin"])
        XCTAssertNil(ios["Referer"])
        let remix = StreamPlayerClient.forStreamURL(gv("WEB_REMIX")).mediaHeaders
        XCTAssertEqual(remix["Origin"], "https://music.youtube.com")
        XCTAssertEqual(remix["Referer"], "https://music.youtube.com/")
        XCTAssertEqual(remix["User-Agent"], StreamPlayerClient.webUserAgent)
    }

    /// Request-side profiles and the media-side model agree on the identity they present.
    func testCatalogProfilesDressMediaFetchesAsThemselves() {
        XCTAssertEqual(StreamClientProfile.visionOS.mediaHeaders["User-Agent"], StreamPlayerClient.visionOSUserAgent)
        XCTAssertEqual(StreamClientProfile.androidVR.mediaHeaders, StreamPlayerClient.androidVR.mediaHeaders)
        XCTAssertEqual(StreamClientProfile.webRemix.mediaHeaders["Origin"], "https://music.youtube.com")
        XCTAssertEqual(StreamClientProfile.defaultCatalog.map(\.id), ["visionos", "web_embedded", "android_vr", "web_remix", "tv_simply", "mweb"])
        XCTAssertEqual(StreamClientProfile.webEmbedded.mediaHeaders["Origin"], "https://www.youtube.com")
    }
}
