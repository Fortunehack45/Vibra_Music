import XCTest
@testable import StreamResolution

/// Which rendition gets picked: `pickForQuality`/`underCeiling`, and the iOS rule that playback
/// is AAC-in-MP4 only.
final class StreamSelectionTests: XCTestCase {
    private var visionOS: [PlayerResponse.Format] = []

    override func setUpWithError() throws {
        visionOS = try StreamFixture.playerResponse("player_visionos_ok.json").audioFormats
    }

    func testUnderCeilingTakesTheHighestRungWithinBudget() {
        let rungs = [(kbps: 48, value: "139"), (kbps: 129, value: "140"), (kbps: 256, value: "141")]
        XCTAssertEqual(underCeiling(rungs, maxKbps: 128), "139")
        XCTAssertEqual(underCeiling(rungs, maxKbps: 129), "140")
        XCTAssertEqual(underCeiling(rungs, maxKbps: .max), "141")
    }

    /// Everything above the ceiling: a rung over budget still beats no audio at all.
    func testUnderCeilingFallsBackToTheCheapestWhenAllAreOver() {
        let rungs = [(kbps: 160, value: "a"), (kbps: 130, value: "b"), (kbps: 250, value: "c")]
        XCTAssertEqual(underCeiling(rungs, maxKbps: 64), "b")
        XCTAssertNil(underCeiling([(kbps: Int, value: String)](), maxKbps: 64))
    }

    func testPlaybackNeverPicksWebMWhateverTheCeiling() throws {
        for ceiling in [32, 64, 128, 160, Int.max] {
            let pick = try XCTUnwrap(StreamSelection.playback(maxKbps: ceiling).pick(from: visionOS))
            XCTAssertTrue(pick.isMP4Audio, "ceiling \(ceiling) picked \(pick.mimeType ?? "")")
        }
        let opusOnly = visionOS.filter(\.isWebMOpus)
        XCTAssertNil(StreamSelection.playback(maxKbps: .max).pick(from: opusOnly))
        XCTAssertFalse(StreamSelection.playback(maxKbps: .max).offersContainer(opusOnly))
    }

    func testQualityTiersMapToTheAACLadder() throws {
        XCTAssertEqual(StreamSelection.playback(maxKbps: StreamAudioQuality.low.maxKbps).pick(from: visionOS)?.itag, 139)
        for quality in [StreamAudioQuality.medium, .high, .lossless] {
            XCTAssertEqual(StreamSelection.playback(maxKbps: quality.maxKbps).pick(from: visionOS)?.itag, 140, quality.rawValue)
        }
    }

    func testDownloadRequiringM4aTakesAAC() {
        XCTAssertEqual(StreamSelection.download(maxKbps: StreamDownloadQuality.high.maxKbps, requireM4a: true).pick(from: visionOS)?.itag, 140)
        XCTAssertEqual(StreamSelection.download(maxKbps: StreamDownloadQuality.standard.maxKbps, requireM4a: true).pick(from: visionOS)?.itag, 139)
    }

    /// Without the MP4 requirement a download keeps Opus-in-WebM, as Android's app-private ones do.
    func testDownloadWithoutM4aTakesTheOpusLadderUnderItsCeiling() {
        XCTAssertEqual(StreamSelection.download(maxKbps: .max, requireM4a: false).pick(from: visionOS)?.itag, 251)
        // 251 averages 128.9 kbps, which Standard's 128 ceiling admits (kbps is truncated, as on Android).
        XCTAssertEqual(StreamSelection.download(maxKbps: StreamDownloadQuality.standard.maxKbps, requireM4a: false).pick(from: visionOS)?.itag, 251)
        XCTAssertEqual(StreamSelection.download(maxKbps: 100, requireM4a: false).pick(from: visionOS)?.itag, 250)
    }

    func testDynamicRangeCompressedAndDubbedRenditionsAreSkipped() throws {
        var drc = try XCTUnwrap(visionOS.first { $0.itag == 140 })
        drc.isDrc = true
        drc.averageBitrate = 400_000
        var dub = try XCTUnwrap(visionOS.first { $0.itag == 140 })
        dub.audioTrack = .init(displayName: "French", id: "fr.3", audioIsDefault: false)
        dub.averageBitrate = 300_000
        let pick = StreamSelection.playback(maxKbps: .max).pick(from: visionOS + [drc, dub])
        XCTAssertEqual(pick?.averageBitrate, visionOS.first { $0.itag == 140 }?.averageBitrate)
    }

    func testTierCeilingsMatchAndroid() {
        XCTAssertEqual(StreamAudioQuality.low.maxKbps, 64)
        XCTAssertEqual(StreamAudioQuality.medium.maxKbps, Int.max)
        XCTAssertEqual(StreamDownloadQuality.standard.maxKbps, 128)
        XCTAssertEqual(StreamDownloadQuality.lossless.maxKbps, Int.max)
    }
}

/// The container a resolved stream's bytes are in (Android's `Stream.downloadExtension`).
final class ResolvedStreamContainerTests: XCTestCase {
    private func stream(_ mime: String) -> ResolvedYouTubeStream {
        ResolvedYouTubeStream(
            videoId: "dQw4w9WgXcQ", url: URL(string: "https://example.googlevideo.com/videoplayback")!, itag: 0,
            kbps: 0, mimeType: mime, clientName: "X", profileId: "x", mediaHeaders: [:]
        )
    }

    func testAACInMP4IsSavedAsM4a() {
        XCTAssertEqual(stream(#"audio/mp4; codecs="mp4a.40.2""#).downloadExtension, "m4a")
        XCTAssertEqual(stream("audio/m4a").downloadExtension, "m4a")
        XCTAssertEqual(stream("audio/mp4").downloadMimeType, "audio/mp4")
        XCTAssertTrue(stream("audio/mp4").isAVPlayerCompatible)
    }

    /// YouTube's Opus is Opus-in-WebM; naming it `.opus` would promise an Ogg file.
    func testOpusIsSavedAsWebMNotOpus() {
        XCTAssertEqual(stream(#"audio/webm; codecs="opus""#).downloadExtension, "webm")
        XCTAssertEqual(stream("audio/opus").downloadExtension, "webm")
        XCTAssertEqual(stream("audio/webm").downloadMimeType, "audio/webm")
        XCTAssertFalse(stream("audio/webm").isAVPlayerCompatible)
    }
}
