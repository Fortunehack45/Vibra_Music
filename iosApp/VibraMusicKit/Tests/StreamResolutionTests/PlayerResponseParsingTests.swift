import XCTest
@testable import StreamResolution

/// Recorded `/player` answers (2026-09-26) read the way the walk reads them.
final class PlayerResponseParsingTests: XCTestCase {
    func testVisionOSAnswerCarriesDirectAACAndOpusURLs() throws {
        let response = try StreamFixture.playerResponse("player_visionos_ok.json")
        XCTAssertEqual(response.playabilityStatus?.status, "OK")
        let audio = response.audioFormats
        XCTAssertEqual(Set(audio.map(\.itag)), [139, 140, 249, 250, 251])
        XCTAssertTrue(audio.allSatisfy { $0.url != nil && $0.signatureCipher == nil })
        let aac = try XCTUnwrap(audio.first { $0.itag == 140 })
        XCTAssertTrue(aac.isMP4Audio)
        XCTAssertFalse(aac.isWebMOpus)
        XCTAssertEqual(aac.kbps, 129)
        XCTAssertEqual(aac.contentLengthValue, 3_449_447)
        XCTAssertNotNil(aac.approxDurationMsValue)
        XCTAssertNotNil(response.loudnessDb(for: aac))
        let opus = try XCTUnwrap(audio.first { $0.itag == 251 })
        XCTAssertTrue(opus.isWebMOpus)
        let url = try XCTUnwrap(aac.url.flatMap(URL.init(string:)))
        XCTAssertEqual(url.streamQueryValue("c"), "VISIONOS")
        XCTAssertNil(url.streamQueryValue("n"), "visionOS URLs need no n transform")
    }

    /// The same recording: WEB_REMIX states −6.01 dB against its −7 LKFS target, VISIONOS +0.99 dB
    /// against −14. Read on one scale, they agree.
    func testEveryClientsLoudnessFigureIsOnTheSameScale() throws {
        let visionOS = try StreamFixture.playerResponse("player_visionos_ok.json")
        let webRemix = try StreamFixture.playerResponse("player_web_remix_cipher.json")
        let a = try XCTUnwrap(visionOS.audioFormats.first { $0.itag == 140 })
        let b = try XCTUnwrap(webRemix.audioFormats.first { $0.itag == 140 })
        XCTAssertEqual(try XCTUnwrap(webRemix.loudnessDb(for: b)), try XCTUnwrap(visionOS.loudnessDb(for: a)), accuracy: 0.05)
    }

    func testAndroidVRAnswerCarriesDirectURLsWithItsClientName() throws {
        let response = try StreamFixture.playerResponse("player_android_vr_ok.json")
        let aac = try XCTUnwrap(response.audioFormats.first { $0.itag == 140 })
        let url = try XCTUnwrap(aac.url.flatMap(URL.init(string:)))
        XCTAssertEqual(url.streamQueryValue("c"), "ANDROID_VR")
        XCTAssertEqual(StreamPlayerClient.rangeBytes(for: url), 512 * 1024)
    }

    func testWebRemixFormatsAreCipheredWithAnNParameter() throws {
        let response = try StreamFixture.playerResponse("player_web_remix_cipher.json")
        let aac = try XCTUnwrap(response.audioFormats.first { $0.itag == 140 })
        XCTAssertNil(aac.url)
        let cipher = try XCTUnwrap(aac.signatureCipher)
        XCTAssertTrue(cipher.contains("s="))
        XCTAssertTrue(cipher.contains("sp=sig"))
        XCTAssertTrue(cipher.contains("n%3D"))
        XCTAssertNotNil(response.playbackTracking?.videostatsPlaybackUrl?.baseUrl)
    }

    /// SABR-only answers look fine and hold nothing a URL-based player can use.
    func testIOSAnswerIsSABROnlyAndOffersNothingUsable() throws {
        let response = try StreamFixture.playerResponse("player_ios_sabr_only.json")
        XCTAssertEqual(response.playabilityStatus?.status, "OK")
        XCTAssertNotNil(response.streamingData?.serverAbrStreamingUrl)
        XCTAssertFalse(response.audioFormats.isEmpty)
        XCTAssertTrue(response.audioFormats.allSatisfy { $0.url == nil && $0.signatureCipher == nil })
        XCTAssertNil(StreamSelection.playback(maxKbps: .max).pick(from: response.audioFormats))
        XCTAssertTrue(StreamSelection.playback(maxKbps: .max).offersContainer(response.audioFormats))
    }

    func testErrorScreenTextJoinsReasonAndSubreason() throws {
        let response = try StreamFixture.playerResponse("player_web_remix_age_unplayable.json")
        let explanation = try XCTUnwrap(response.playabilityStatus?.explanation)
        XCTAssertTrue(explanation.contains("Video unavailable"), explanation)
        XCTAssertTrue(explanation.contains("This video is not available"), explanation)
    }

    func testTrackingBlockParsesAllThreePingURLs() throws {
        let response = try StreamFixture.playerResponse("player_web_remix_cipher.json")
        let tracking = try XCTUnwrap(PlaybackTrackingURLs(response.playbackTracking))
        XCTAssertEqual(tracking.playbackURL.path, "/api/stats/playback")
        XCTAssertEqual(tracking.watchtimeURL?.path, "/api/stats/watchtime")
        XCTAssertEqual(tracking.atrURL?.path, "/api/stats/atr")
        XCTAssertGreaterThan(tracking.atrAfterSeconds, 0)
    }

    func testTrackingElapsedSecondsAcceptsStringOrNumber() throws {
        let json = #"{"playbackTracking":{"videostatsPlaybackUrl":{"baseUrl":"https://s.youtube.com/api/stats/playback?a=1"},"atrUrl":{"baseUrl":"https://s.youtube.com/api/stats/atr","elapsedMediaTimeSeconds":"7"}}}"#
        let response = try PlayerResponse.decode(Data(json.utf8))
        let tracking = try XCTUnwrap(PlaybackTrackingURLs(response.playbackTracking))
        XCTAssertEqual(tracking.atrAfterSeconds, 7)
        XCTAssertNil(tracking.watchtimeURL)
        let numeric = try PlayerResponse.decode(Data(json.replacingOccurrences(of: "\"7\"", with: "9").utf8))
        XCTAssertEqual(PlaybackTrackingURLs(numeric.playbackTracking)?.atrAfterSeconds, 9)
        let missing = try PlayerResponse.decode(Data(#"{"playbackTracking":{"videostatsPlaybackUrl":{"baseUrl":"https://s.youtube.com/x"},"atrUrl":{"baseUrl":"https://s.youtube.com/atr"}}}"#.utf8))
        XCTAssertEqual(PlaybackTrackingURLs(missing.playbackTracking)?.atrAfterSeconds, PlaybackTrackingURLs.defaultAtrSeconds)
    }

    func testMissingFieldsReadAsAbsentNotAsAFailure() throws {
        let response = try PlayerResponse.decode(Data("{}".utf8))
        XCTAssertNil(response.playabilityStatus)
        XCTAssertTrue(response.audioFormats.isEmpty)
        XCTAssertNil(PlaybackTrackingURLs(response.playbackTracking))
    }

    /// Audio offered only in progressive `formats` counts: Android's extractor read those,
    /// and a client that answers usable audio only there must not read as "no usable format".
    func testProgressiveAudioFormatsCountToo() throws {
        let json = """
        {"playabilityStatus":{"status":"OK"},"streamingData":{"adaptiveFormats":[],"formats":[
        {"itag":18,"mimeType":"audio/mp4; codecs=\\"mp4a.40.2\\"","bitrate":96000,"averageBitrate":96000,
        "contentLength":"960000","url":"https://rr1---sn-abc.googlevideo.com/videoplayback?c=TVHTML5&cver=1.0&clen=960000"}
        ]}}
        """
        let response = try PlayerResponse.decode(Data(json.utf8))
        let picked = try XCTUnwrap(StreamSelection.playback(maxKbps: .max).pick(from: response.audioFormats))
        XCTAssertEqual(picked.itag, 18)
        XCTAssertTrue(picked.isMP4Audio)
    }
}
