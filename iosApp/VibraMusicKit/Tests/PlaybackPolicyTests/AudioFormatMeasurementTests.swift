import XCTest
import AVFoundation
import AudioToolbox
import VibraMusicCore
import VibraMusicTestSupport
@testable import PlaybackPolicy

/// Filling "stats for nerds" from AVFoundation: real encoded files (Fixtures/audio, made with
/// `afconvert` from generated test tones) measured through the same calls the player uses.
final class AudioFormatMeasurementTests: XCTestCase {
    private let fixtures = FixtureLoader(bundle: .module)

    private func measure(_ name: String) async throws -> MeasuredAudioFormat {
        let url = try fixtures.url("audio/\(name)")
        let measured = try await AudioFormatMeasurement.measure(asset: AVURLAsset(url: url))
        return try XCTUnwrap(measured, "no audio track in \(name)")
    }

    private func snapshot(_ measured: MeasuredAudioFormat) -> NerdStats.Snapshot {
        let stats = NerdStats()
        stats.publish(measured: measured, mediaId: "t", sourceName: nil)
        return stats.current!
    }

    // MARK: Real files

    func testAHiResFLACIsHiResLossless() async throws {
        let measured = try await measure("flac_24_96.flac")
        XCTAssertEqual(measured.mimeType, "audio/flac")
        XCTAssertEqual(measured.sampleRateHz, 96_000)
        XCTAssertEqual(measured.channels, 2)
        XCTAssertEqual(measured.bitDepth, 24)
        XCTAssertEqual(measured.pcmBitrateKbps, 4608)

        let stats = snapshot(measured)
        XCTAssertEqual(stats.statsLine, "FLAC · 24-bit · 96.0 kHz · 4608 kbps · Stereo")
        XCTAssertEqual(PlaybackQualityBadge.resolve(isLoading: false, stillRacing: false, effectiveQuality: .lossless, stats: stats), .hiResLossless)
    }

    /// Tidal serves FLAC inside MP4, where the sample entry may carry a zero rate and the real
    /// figures live in the `dfLa` box.
    func testFLACInsideMP4MeasuresTheSame() async throws {
        let measured = try await measure("flac_24_96_in_mp4.m4a")
        XCTAssertEqual(measured.mimeType, "audio/flac")
        XCTAssertEqual(measured.sampleRateHz, 96_000)
        XCTAssertEqual(measured.bitDepth, 24)
        XCTAssertEqual(measured.channels, 2)
    }

    /// A bit-exact CD rip is "Lossless", not "Hi-Res Lossless".
    func testCDQualityAppleLosslessIsLossless() async throws {
        let measured = try await measure("alac_16_44.m4a")
        XCTAssertEqual(measured.mimeType, "audio/alac")
        XCTAssertEqual(measured.bitDepth, 16)
        XCTAssertEqual(measured.sampleRateHz, 44_100)
        XCTAssertEqual(snapshot(measured).bitrateKbps, 1411)
        XCTAssertEqual(PlaybackQualityBadge.resolve(isLoading: false, stillRacing: false, effectiveQuality: .lossless, stats: snapshot(measured)), .lossless)
    }

    func testPCMIsLosslessPCM() async throws {
        let measured = try await measure("pcm_16_44.wav")
        XCTAssertEqual(measured.mimeType, "audio/raw")
        XCTAssertEqual(measured.bitDepth, 16)
        let stats = snapshot(measured)
        XCTAssertTrue(stats.isLossless)
        XCTAssertEqual(stats.statsLine, "PCM · 16-bit · 44.1 kHz · 1411 kbps · Stereo")
    }

    /// A lossy stream has no source bit depth, and its bitrate is the track's own data rate.
    func testA256KbpsAACIsHighQuality() async throws {
        let measured = try await measure("aac_256.m4a")
        XCTAssertEqual(measured.mimeType, "audio/mp4a-latm")
        XCTAssertNil(measured.bitDepth)
        XCTAssertEqual(measured.sampleRateHz, 44_100)
        let kbps = try XCTUnwrap(measured.bitrateKbps)
        XCTAssertGreaterThanOrEqual(kbps, 250)
        XCTAssertLessThanOrEqual(kbps, 290)
        let stats = snapshot(measured)
        XCTAssertTrue(stats.isHiQuality)
        XCTAssertEqual(PlaybackQualityBadge.resolve(isLoading: false, stillRacing: false, effectiveQuality: .high, stats: stats), .highQuality)
    }

    /// A VBR container that states no data rate leaves the bitrate to the resolver's figure: the
    /// line says what YouTube picked rather than inventing one.
    func testOpusIsNamedOpusAndFallsBackToThePickedBitrate() async throws {
        let measured = try await measure("opus_160.caf")
        XCTAssertEqual(measured.mimeType, "audio/opus")
        XCTAssertEqual(measured.sampleRateHz, 48_000)
        XCTAssertEqual(NerdStats.codecLabel(measured.mimeType), "Opus")
        XCTAssertNil(measured.bitrateKbps, "this CAF has no data rate to state")
        XCTAssertNil(snapshot(measured).bitrateKbps)

        let stats = NerdStats()
        stats.onStreamPicked("t", kbps: 160, source: "YouTube")
        stats.publish(measured: measured, mediaId: "t", sourceName: "YouTube")
        XCTAssertEqual(stats.current?.statsLine, "Opus · 48.0 kHz · 160 kbps · Stereo")
        XCTAssertTrue(stats.current?.isMediumQuality == true)
    }

    /// Implicit-SBR HE-AAC is stored as plain AAC at half the rate; the decoder plays it at 48 kHz.
    func testHEAACReportsTheRateItDecodesAt() async throws {
        let measured = try await measure("heaac_64.m4a")
        XCTAssertEqual(measured.mimeType, "audio/mp4a-latm")
        XCTAssertEqual(measured.sampleRateHz, 48_000)
        XCTAssertEqual(measured.channels, 2)
        XCTAssertNil(measured.bitDepth)
    }

    // MARK: Descriptions

    func testFormatIDsMapToTheMimeVocabulary() {
        XCTAssertEqual(AudioFormatMeasurement.mimeType(forFormatID: kAudioFormatFLAC), "audio/flac")
        XCTAssertEqual(AudioFormatMeasurement.mimeType(forFormatID: kAudioFormatAppleLossless), "audio/alac")
        XCTAssertEqual(AudioFormatMeasurement.mimeType(forFormatID: kAudioFormatLinearPCM), "audio/raw")
        XCTAssertEqual(AudioFormatMeasurement.mimeType(forFormatID: kAudioFormatMPEG4AAC_HE), "audio/mp4a-latm")
        XCTAssertEqual(AudioFormatMeasurement.mimeType(forFormatID: kAudioFormatMPEGLayer3), "audio/mpeg")
        XCTAssertEqual(AudioFormatMeasurement.mimeType(forFormatID: kAudioFormatOpus), "audio/opus")
        XCTAssertEqual(AudioFormatMeasurement.mimeType(forFormatID: kAudioFormatEnhancedAC3), "audio/eac3")
        XCTAssertEqual(AudioFormatMeasurement.mimeType(forFormatID: kAudioFormatAC3), "audio/ac3")
        XCTAssertEqual(AudioFormatMeasurement.mimeType(forFormatID: 0x77787A21), "audio/wxz!", "unknown IDs keep their four-char code")
        XCTAssertTrue(NerdStats.isDolbyAtmosMime(AudioFormatMeasurement.mimeType(forFormatID: kAudioFormatEnhancedAC3)))
    }

    func testBitDepthComesFromTheSourceDepthFlagForLosslessCodecs() {
        var alac = AudioStreamBasicDescription()
        alac.mFormatID = kAudioFormatAppleLossless
        alac.mFormatFlags = 3 // kAppleLosslessFormatFlag_24BitSourceData
        alac.mSampleRate = 48_000
        alac.mChannelsPerFrame = 2
        XCTAssertEqual(AudioFormatMeasurement.measure(alac).bitDepth, 24)

        var pcm = AudioStreamBasicDescription()
        pcm.mFormatID = kAudioFormatLinearPCM
        pcm.mBitsPerChannel = 32
        XCTAssertEqual(AudioFormatMeasurement.measure(pcm).bitDepth, 32)

        var aac = AudioStreamBasicDescription()
        aac.mFormatID = kAudioFormatMPEG4AAC
        aac.mBitsPerChannel = 16
        XCTAssertNil(AudioFormatMeasurement.measure(aac).bitDepth, "a lossy codec has no source depth")
    }

    /// A zero rate in the description is read from STREAMINFO, the layer that always states it.
    func testGapsInAFLACDescriptionAreFilledFromStreamInfo() {
        var flac = AudioStreamBasicDescription()
        flac.mFormatID = kAudioFormatFLAC
        let measured = AudioFormatMeasurement.measure(flac, magicCookie: Self.dfLaPayload)
        XCTAssertEqual(measured.sampleRateHz, 44_100)
        XCTAssertEqual(measured.channels, 2)
        XCTAssertEqual(measured.bitDepth, 16)
    }

    // MARK: STREAMINFO shapes

    /// 16-bit, 44.1 kHz, stereo.
    private static let streamInfoBody: [UInt8] = [
        0x10, 0x00, 0x10, 0x00, // min/max block size 4096
        0x00, 0x00, 0x0E, 0x00, 0x30, 0x00, // min/max frame size
        0x0A, 0xC4, 0x42, // 44100 << 4 | (channels-1) << 1 | (bps-1) >> 4
        0xF0, // (bps-1) & 0xF << 4 | total samples high bits
        0x00, 0x00, 0x00, 0x00, // total samples
    ] + [UInt8](repeating: 0xAB, count: 16) // MD5

    private static let streamInfoHeader: [UInt8] = [0x80, 0x00, 0x00, 0x22]

    private static var dfLaPayload: Data { Data([0, 0, 0, 0] + streamInfoHeader + streamInfoBody) }

    func testStreamInfoIsFoundInEveryShapeItArrivesIn() {
        let streamInfoHeader = Self.streamInfoHeader
        let streamInfoBody = Self.streamInfoBody
        let shapes: [String: [UInt8]] = [
            "fLaC marker": Array("fLaC".utf8) + streamInfoHeader + streamInfoBody,
            "bare header": streamInfoHeader + streamInfoBody,
            "dfLa payload": [0, 0, 0, 0] + streamInfoHeader + streamInfoBody,
            "dfLa box": [0, 0, 0, 50] + Array("dfLa".utf8) + [0, 0, 0, 0] + streamInfoHeader + streamInfoBody,
            "bare body": streamInfoBody,
        ]
        for (shape, bytes) in shapes {
            let info = AudioFormatMeasurement.flacStreamInfo(Data(bytes))
            XCTAssertEqual(info, .init(sampleRateHz: 44_100, channels: 2, bitDepth: 16), shape)
        }
        XCTAssertNil(AudioFormatMeasurement.flacStreamInfo(Data([1, 2, 3])))
    }

    /// The real magic cookie AVFoundation hands over for a FLAC track parses the same way.
    func testTheFixturesMagicCookieCarriesStreamInfo() async throws {
        let asset = AVURLAsset(url: try fixtures.url("audio/flac_24_96_in_mp4.m4a"))
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let descriptions = try await track.load(.formatDescriptions)
        let description = try XCTUnwrap(descriptions.first)
        var size = 0
        let cookie = try XCTUnwrap(CMAudioFormatDescriptionGetMagicCookie(description, sizeOut: &size))
        let info = AudioFormatMeasurement.flacStreamInfo(Data(bytes: cookie, count: size))
        XCTAssertEqual(info, .init(sampleRateHz: 96_000, channels: 2, bitDepth: 24))
    }

    // MARK: Access log

    /// HLS states a rendition bandwidth, and sometimes the audio track's own average; network
    /// throughput is never an audio bitrate.
    func testTheAccessLogsAudioBitrateIgnoresThroughput() {
        let hls = AudioFormatMeasurement.AccessLogFigures(indicatedBitrate: 66_400, averageAudioBitrate: 0, observedBitrate: 12_000_000)
        XCTAssertEqual(hls.audioBitrateKbps, 66)
        XCTAssertEqual(hls.throughputKbps, 12_000)

        let withAverage = AudioFormatMeasurement.AccessLogFigures(indicatedBitrate: 140_000, averageAudioBitrate: 128_300)
        XCTAssertEqual(withAverage.audioBitrateKbps, 128)

        let nothing = AudioFormatMeasurement.AccessLogFigures(indicatedBitrate: -1, averageAudioBitrate: .nan, observedBitrate: -1)
        XCTAssertNil(nothing.audioBitrateKbps)
        XCTAssertNil(nothing.throughputKbps)
    }

    func testPCMRateNeedsAllThreeFigures() {
        XCTAssertNil(MeasuredAudioFormat(sampleRateHz: 44_100, channels: 2).pcmBitrateKbps, "two thirds of this product is not a bitrate")
        XCTAssertEqual(MeasuredAudioFormat(sampleRateHz: 44_100, channels: 2, bitDepth: 16).pcmBitrateKbps, 1411)
    }

    /// A player item for a local file measures through its asset before anything plays.
    func testAPlayerItemIsMeasuredThroughItsAsset() async throws {
        let item = AVPlayerItem(url: try fixtures.url("audio/alac_16_44.m4a"))
        let measured = await AudioFormatMeasurement.measure(playerItem: item)
        XCTAssertEqual(measured?.mimeType, "audio/alac")
        XCTAssertEqual(measured?.bitDepth, 16)
        XCTAssertNil(measured?.networkThroughputKbps, "a file has no access log")
    }
}
