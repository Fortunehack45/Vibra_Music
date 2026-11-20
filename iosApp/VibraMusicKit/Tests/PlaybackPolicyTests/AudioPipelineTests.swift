import XCTest
import VibraMusicCore
@testable import PlaybackPolicy

/// The audio pipeline models: quality tiers, codec labels, authoritative source tracking, the output
/// status and the resampler stage (ports AudioPipelineTest), plus the "is the signal altered" verdict
/// behind the Audio Pipeline dialog.
final class AudioPipelineTests: XCTestCase {
    private var stats: NerdStats!
    private var output: AudioOutputStatus!

    override func setUp() {
        super.setUp()
        stats = NerdStats()
        output = AudioOutputStatus()
    }

    private func snapshot(_ mime: String, kbps: Int?, rate: Int = 48_000, depth: Int? = nil) -> NerdStats.Snapshot {
        NerdStats.Snapshot(mimeType: mime, bitrateKbps: kbps, sampleRateHz: rate, channels: 2, bitDepth: depth)
    }

    // MARK: Quality badge classification

    func testLowQualityTierIdentifiesStreamsAtOrBelow80Kbps() {
        let lowOpus = snapshot("audio/opus", kbps: 64)
        XCTAssertTrue(lowOpus.isLowQuality)
        XCTAssertFalse(lowOpus.isMediumQuality)
        XCTAssertFalse(lowOpus.isHiQuality)
        XCTAssertFalse(lowOpus.isLossless)

        let edgeLow = snapshot("audio/opus", kbps: NerdStats.lowQualityMaxKbps)
        XCTAssertTrue(edgeLow.isLowQuality)
        XCTAssertFalse(edgeLow.isMediumQuality)

        let justAbove = snapshot("audio/opus", kbps: NerdStats.lowQualityMaxKbps + 1)
        XCTAssertFalse(justAbove.isLowQuality)
        XCTAssertTrue(justAbove.isMediumQuality)
    }

    func testMediumQualityTierIdentifiesStreamsBetween80And256Kbps() {
        let ytOpus160 = snapshot("audio/opus", kbps: 160)
        XCTAssertFalse(ytOpus160.isLowQuality)
        XCTAssertTrue(ytOpus160.isMediumQuality)
        XCTAssertFalse(ytOpus160.isHiQuality)
        XCTAssertFalse(ytOpus160.isLossless)

        let aac128 = snapshot("audio/mp4a-latm", kbps: 128, rate: 44_100)
        XCTAssertTrue(aac128.isMediumQuality)
        XCTAssertFalse(aac128.isHiQuality)
    }

    func testHighQualityTierRequires256KbpsOrHigherAndIsLossy() {
        let aac320 = snapshot("audio/mp4a-latm", kbps: 320, rate: 44_100)
        XCTAssertFalse(aac320.isLowQuality)
        XCTAssertFalse(aac320.isMediumQuality)
        XCTAssertTrue(aac320.isHiQuality)
        XCTAssertFalse(aac320.isLossless)

        let boundary256 = snapshot("audio/mp4a-latm", kbps: NerdStats.hiQualityKbps, rate: 44_100)
        XCTAssertTrue(boundary256.isHiQuality)
        XCTAssertFalse(boundary256.isMediumQuality)
    }

    func testLosslessAndHiResLosslessAreNeverTaggedAsLossyTiers() {
        let flacCD = snapshot("audio/flac", kbps: 1411, rate: 44_100, depth: 16)
        XCTAssertTrue(flacCD.isLossless)
        XCTAssertFalse(flacCD.isHiRes)
        XCTAssertFalse(flacCD.isLowQuality)
        XCTAssertFalse(flacCD.isMediumQuality)
        XCTAssertFalse(flacCD.isHiQuality)

        let flacHiRes = snapshot("audio/flac", kbps: 4608, rate: 96_000, depth: 24)
        XCTAssertTrue(flacHiRes.isLossless)
        XCTAssertTrue(flacHiRes.isHiRes)
        XCTAssertFalse(flacHiRes.isLowQuality)
        XCTAssertFalse(flacHiRes.isMediumQuality)
        XCTAssertFalse(flacHiRes.isHiQuality)
    }

    func testAnUnknownBitrateIsNoLossyTierAtAll() {
        let unknown = snapshot("audio/mp4a-latm", kbps: nil)
        XCTAssertFalse(unknown.isLowQuality)
        XCTAssertFalse(unknown.isMediumQuality)
        XCTAssertFalse(unknown.isHiQuality)
    }

    // MARK: Codec label resolution

    func testCodecLabelFormatsStandardMimeTypesIntoCleanDisplayNames() {
        XCTAssertEqual(NerdStats.codecLabel("audio/flac"), "FLAC")
        XCTAssertEqual(NerdStats.codecLabel("audio/opus"), "Opus")
        XCTAssertEqual(NerdStats.codecLabel("audio/mp4a-latm"), "AAC")
        XCTAssertEqual(NerdStats.codecLabel("audio/aac"), "AAC")
        XCTAssertEqual(NerdStats.codecLabel("audio/mpeg"), "MP3")
        XCTAssertEqual(NerdStats.codecLabel("audio/mp3"), "MP3")
        XCTAssertEqual(NerdStats.codecLabel("audio/alac"), "ALAC")
        XCTAssertEqual(NerdStats.codecLabel("audio/raw"), "PCM")
        XCTAssertEqual(NerdStats.codecLabel("audio/vorbis"), "Vorbis")
        XCTAssertEqual(NerdStats.codecLabel("audio/eac3-joc"), "E-AC-3 JOC")
        XCTAssertEqual(NerdStats.codecLabel("audio/eac3"), "E-AC-3")
        XCTAssertEqual(NerdStats.codecLabel("audio/ac3"), "AC3")
        XCTAssertNil(NerdStats.codecLabel(nil))
    }

    // MARK: Authoritative source tracking

    func testAuthoritativeSourcesAreRecordedAndRetrievedAcrossTrackIdentifiers() {
        stats.recordSource("track-123", "YouTube")
        XCTAssertEqual(stats.source(for: "track-123"), "YouTube")

        stats.onSourceStream("track-456", format: StreamFormat(codec: "flac"), source: "Unified Addon")
        XCTAssertEqual(stats.source(for: "track-456"), "Unified Addon")

        stats.onStreamPicked("track-789", kbps: 320, source: "JioSaavn")
        XCTAssertEqual(stats.source(for: "track-789"), "JioSaavn")
    }

    func testSourceLookupUnwrapsPrefixedSourceTrackKeys() {
        stats.recordSource("inner-id-abc", "Qobuz FLAC")
        XCTAssertEqual(stats.source(for: "src:config-uuid-123::inner-id-abc"), "Qobuz FLAC")
    }

    func testClearDeclaredDropsTheRecordedSourceForThatTrack() {
        stats.recordSource("track-abandoned", "Tidal HiFi")
        XCTAssertEqual(stats.source(for: "track-abandoned"), "Tidal HiFi")

        stats.clearDeclared("track-abandoned")
        XCTAssertNil(stats.source(for: "track-abandoned"))
    }

    func testForgetLastSessionClearsAllRecordedSourcesAndSnapshots() {
        stats.recordSource("track-1", "YouTube")
        stats.recordSource("track-2", "JioSaavn")
        stats.current = NerdStats.Snapshot(mimeType: "audio/flac", bitrateKbps: 1411, sampleRateHz: 44_100, channels: 2, sourceName: "JioSaavn")
        stats.onLosslessRaceStart("track-1")

        stats.forgetLastSession()

        XCTAssertNil(stats.current)
        XCTAssertNil(stats.source(for: "track-1"))
        XCTAssertNil(stats.source(for: "track-2"))
        XCTAssertTrue(stats.racingLossless.isEmpty)
    }

    // MARK: Dynamic source transition and leak prevention

    func testStaleProviderMustNeverLeakAcrossTracksSharingTheSameInnerIdentifier() {
        // Track 1 played from JioSaavn with inner track id "101".
        stats.recordSource("101", "JioSaavn")
        XCTAssertEqual(stats.exactSource(for: "101"), "JioSaavn")

        // Track 2 is an addon track with the same inner id under an addon prefix: before the addon
        // records itself, the exact lookup must not leak JioSaavn.
        let addonMediaId = "src:addon-uuid-xyz::101"
        XCTAssertNil(stats.exactSource(for: addonMediaId))

        stats.recordSource(addonMediaId, "Unified Addon")
        XCTAssertEqual(stats.exactSource(for: addonMediaId), "Unified Addon")
        XCTAssertEqual(stats.exactSource(for: "101"), "JioSaavn")
    }

    func testPlaybackSourceTransitionsMaintainCorrectSequenceWithoutStaleBleed() {
        let jiosaavnId = "src:jiosaavn-uuid::track-jio"
        let addonId = "src:addon-uuid::track-addon"
        let localId = "local-storage-track-uri"

        stats.recordSource(jiosaavnId, "JioSaavn")
        XCTAssertEqual(stats.exactSource(for: jiosaavnId), "JioSaavn")
        stats.recordSource(addonId, "Tidal Addon")
        XCTAssertEqual(stats.exactSource(for: addonId), "Tidal Addon")
        XCTAssertNil(stats.exactSource(for: localId))
        XCTAssertEqual(stats.exactSource(for: jiosaavnId), "JioSaavn")
        XCTAssertEqual(stats.exactSource(for: addonId), "Tidal Addon")
        XCTAssertEqual(stats.exactSource(for: jiosaavnId), "JioSaavn")
    }

    func testUnknownProviderAndMissingMetadataRemainNilInExactLookup() {
        XCTAssertNil(stats.exactSource(for: nil))
        XCTAssertNil(stats.exactSource(for: ""))
        XCTAssertNil(stats.exactSource(for: "src:unknown-provider-uuid::track-999"))
    }

    // MARK: Output status model

    func testAudioOutputStatusTracksDecoderNameAndBufferSize() {
        output.publishDecoder("AudioToolbox (FLAC)")
        XCTAssertEqual(output.current.decoderName, "AudioToolbox (FLAC)")

        output.publishRender(sampleRateHz: 48_000, bufferFrames: 4_096)
        let snap = output.current
        XCTAssertEqual(snap.decoderName, "AudioToolbox (FLAC)")
        XCTAssertEqual(snap.renderSampleRateHz, 48_000)
        XCTAssertEqual(snap.bufferFrames, 4_096)

        output.publishRender(sampleRateHz: 44_100)
        XCTAssertEqual(output.current.bufferFrames, 4_096, "a render publish without a buffer keeps the last one")

        // The output sheet's summary names what the app renders at, as Android's does with the
        // AudioTrack's rate — not the hardware rate.
        output.publishRoute(ports: [], hardwareSampleRateHz: 48_000, outputChannels: 2)
        XCTAssertEqual(output.current.summary, "44.1 kHz · 2 ch")

        output.reset()
        XCTAssertNil(output.current.decoderName)
        XCTAssertNil(output.current.bufferFrames)
        XCTAssertNil(output.current.renderSampleRateHz)
    }

    /// Route publishes never overwrite the measured DSP figures — on Android copying the
    /// negotiator's constants over them left both rows reading "Float32" for ever.
    func testARoutePublishLeavesTheMeasuredDSPFormatAlone() {
        output.publishDsp(decoderOutputFormat: "Int16 · 44.1 kHz", dspFormat: "Float32 non-interleaved")
        output.publishRoute(
            ports: [AudioRouting.Port(type: .bluetoothA2DP, name: "AirPods Pro", uid: "bt-1")],
            hardwareSampleRateHz: 48_000,
            outputChannels: 2
        )
        XCTAssertEqual(output.current.decoderOutputFormat, "Int16 · 44.1 kHz")
        XCTAssertEqual(output.current.dspFormat, "Float32 non-interleaved")
        XCTAssertEqual(output.current.deviceName, "AirPods Pro")
        XCTAssertEqual(output.current.routeKind, .bluetooth)
        XCTAssertEqual(output.current.bluetoothProfile, "A2DP")
        XCTAssertEqual(output.current.activeDeviceId, "bt-1")
        XCTAssertEqual(output.current.summary, "48 kHz · 2 ch")
    }

    func testAnEmptyRouteReadsAsTheSystemDefault() {
        output.publishRoute(ports: [], hardwareSampleRateHz: 0, outputChannels: 0)
        XCTAssertEqual(output.current.deviceName, "System default")
        XCTAssertNil(output.current.hardwareSampleRateHz)
        XCTAssertEqual(output.current.summary, "—")
    }

    // MARK: Resampler stage and the route's "System" row

    /// The Resampler stage compares the source rate with the rate the app hands to iOS — its render
    /// rate. The route's own hardware rate is iOS's business: it shows on Output Device's "System"
    /// row, and the bit-exact verdict credits iOS for the conversion. One row per case, as
    /// (source, render, hardware, tapped), with the deriver's expected rows and verdict.
    func testTheResamplerStageSeparatesTheAppStageFromTheRoute() {
        struct Case {
            let name: String
            let sourceHz: Int
            let renderHz: Int?
            let hardwareHz: Int?
            let tapped: Bool
            let ioRate: String
            let type: String
            let quality: String
            let systemRow: String?
            let pcmFormat: String
            let dspSampleRate: String
            let verdict: String
        }
        let measuredFormat = "Float32 non-interleaved"
        let cases = [
            Case(
                name: "a 44.1 kHz source the app hands iOS untouched on a 48 kHz route",
                sourceHz: 44_100, renderHz: 44_100, hardwareHz: 48_000, tapped: true,
                ioRate: "44100 Hz → 44100 Hz", type: "None", quality: "Passthrough",
                systemRow: "Core Audio 48000 Hz, converts 44.1 → 48 kHz",
                pcmFormat: measuredFormat, dspSampleRate: "44100 Hz",
                verdict: "No — converted by iOS 44.1 → 48 kHz"
            ),
            Case(
                name: "44.1 kHz from source to route",
                sourceHz: 44_100, renderHz: 44_100, hardwareHz: 44_100, tapped: true,
                ioRate: "44100 Hz → 44100 Hz", type: "None", quality: "Passthrough",
                systemRow: "Core Audio 44100 Hz",
                pcmFormat: measuredFormat, dspSampleRate: "44100 Hz",
                verdict: "Yes (44.1 kHz end to end)"
            ),
            Case(
                name: "the app resamples 44.1 kHz up to its 48 kHz render rate",
                sourceHz: 44_100, renderHz: 48_000, hardwareHz: 48_000, tapped: true,
                ioRate: "44100 Hz → 48000 Hz", type: "Resampler", quality: "Resampled",
                systemRow: "Core Audio 48000 Hz",
                pcmFormat: measuredFormat, dspSampleRate: "48000 Hz",
                verdict: "No — resampled 44.1 → 48 kHz"
            ),
            Case(
                name: "the app resamples and the route runs faster still",
                sourceHz: 44_100, renderHz: 48_000, hardwareHz: 96_000, tapped: true,
                ioRate: "44100 Hz → 48000 Hz", type: "Resampler", quality: "Resampled",
                systemRow: "Core Audio 96000 Hz, converts 48 → 96 kHz",
                pcmFormat: measuredFormat, dspSampleRate: "48000 Hz",
                verdict: "No — resampled 44.1 → 48 kHz"
            ),
            Case(
                name: "an unmeasured render rate assumes the app passes the source through",
                sourceHz: 44_100, renderHz: nil, hardwareHz: 48_000, tapped: true,
                ioRate: "44100 Hz → 44100 Hz", type: "None", quality: "Passthrough",
                systemRow: "Core Audio 48000 Hz, converts 44.1 → 48 kHz",
                pcmFormat: measuredFormat, dspSampleRate: "44100 Hz",
                verdict: "No — converted by iOS 44.1 → 48 kHz"
            ),
            Case(
                name: "an unmeasured output rate is not claimed as exact",
                sourceHz: 44_100, renderHz: nil, hardwareHz: nil, tapped: true,
                ioRate: "44100 Hz → 44100 Hz", type: "None", quality: "Passthrough",
                systemRow: nil,
                pcmFormat: measuredFormat, dspSampleRate: "44100 Hz",
                verdict: "No — not measured yet"
            ),
            Case(
                name: "a tap-less item",
                sourceHz: 44_100, renderHz: 44_100, hardwareHz: 48_000, tapped: false,
                ioRate: "44100 Hz → 44100 Hz", type: "None", quality: "Passthrough",
                systemRow: "Core Audio 48000 Hz, converts 44.1 → 48 kHz",
                pcmFormat: "Bypassed", dspSampleRate: "—",
                verdict: "No — converted by iOS 44.1 → 48 kHz"
            ),
        ]

        for testCase in cases {
            // Drive the publishers, not the fields, so the snapshot is the one production builds.
            output.reset()
            if let renderHz = testCase.renderHz { output.publishRender(sampleRateHz: renderHz) }
            if let hardwareHz = testCase.hardwareHz {
                output.publishRoute(ports: [], hardwareSampleRateHz: hardwareHz, outputChannels: 2)
            }
            output.publishDsp(decoderOutputFormat: nil, dspFormat: measuredFormat)
            let pipeline = AudioPipeline.build(
                stats: snapshot("audio/flac", kbps: 1411, rate: testCase.sourceHz, depth: 16),
                output: output.current,
                dsp: .init(loudnessNormalization: false, tapped: testCase.tapped)
            )
            let resampler = pipeline.stage(.resampler)
            XCTAssertEqual(resampler?.value("I/O Rate"), testCase.ioRate, testCase.name)
            XCTAssertEqual(resampler?.value("Type"), testCase.type, testCase.name)
            XCTAssertEqual(resampler?.value("Quality"), testCase.quality, testCase.name)
            XCTAssertEqual(pipeline.stage(.outputDevice)?.value("System"), testCase.systemRow, testCase.name)
            XCTAssertEqual(pipeline.stage(.dsp)?.value("PCM Format"), testCase.pcmFormat, testCase.name)
            XCTAssertEqual(pipeline.stage(.dsp)?.value("Sample Rate"), testCase.dspSampleRate, testCase.name)
            XCTAssertEqual(pipeline.bitExactVerdict, testCase.verdict, testCase.name)
        }
    }

    func testNothingMeasuredReadsAsDashesNotGuesses() {
        let pipeline = AudioPipeline.build(stats: nil, output: output.current, dsp: .init())
        XCTAssertEqual(pipeline.stages.map(\.kind), AudioPipeline.StageKind.allCases)
        XCTAssertEqual(pipeline.stage(.trackInfo)?.value("Format"), "—")
        XCTAssertEqual(pipeline.stage(.trackInfo)?.value("Bitrate"), "—")
        XCTAssertEqual(pipeline.stage(.resampler)?.value("Type"), "—")
        XCTAssertEqual(pipeline.stage(.decoder)?.value("Decoder Name"), "—")
        XCTAssertEqual(pipeline.stage(.dsp)?.value("PCM Format"), "—", "nothing measured, not a Float32 guess")
        XCTAssertEqual(pipeline.stage(.dsp)?.value("Gain"), "—", "normalization on, but no figure for this track")
        XCTAssertEqual(pipeline.bitExactVerdict, "No — not measured yet")
    }
}

/// "With EQ on, the dialog shows the signal as altered" (PORTING.md, Audio pipeline dialog).
final class AudioSignalAlterationTests: XCTestCase {
    private let flacCD = NerdStats.Snapshot(mimeType: "audio/flac", bitrateKbps: 1411, sampleRateHz: 44_100, channels: 2, bitDepth: 16, sourceName: "Unified Addon")

    private func outputAt(_ rate: Int) -> AudioOutputStatus.Snapshot {
        var snapshot = AudioOutputStatus.Snapshot()
        snapshot.hardwareSampleRateHz = rate
        return snapshot
    }

    func testNothingRunningAndMatchingRatesIsBitExact() {
        let pipeline = AudioPipeline.build(stats: flacCD, output: outputAt(44_100), dsp: .init(loudnessNormalization: false))
        XCTAssertFalse(pipeline.isSignalAltered)
        XCTAssertTrue(pipeline.alterations.isEmpty)
        XCTAssertEqual(pipeline.bitExactVerdict, "Yes (44.1 kHz end to end)")
        XCTAssertEqual(pipeline.stage(.dsp)?.value("Bit-exact"), pipeline.bitExactVerdict)
        XCTAssertEqual(pipeline.stage(.trackInfo)?.value("Source"), "Unified Addon")
        XCTAssertEqual(pipeline.stage(.trackInfo)?.value("Bit Depth"), "16-bit")
    }

    func testTheEqualizerAltersTheSignal() {
        let pipeline = AudioPipeline.build(
            stats: flacCD,
            output: outputAt(44_100),
            dsp: .init(equalizerEnabled: true, equalizerDescription: "Bass boost", loudnessNormalization: false)
        )
        XCTAssertTrue(pipeline.isSignalAltered)
        XCTAssertEqual(pipeline.alterations, [.equalizer])
        XCTAssertEqual(pipeline.bitExactVerdict, "No — equalizer")
        XCTAssertEqual(pipeline.stage(.dsp)?.value("EQ Preset"), "Bass boost")
    }

    /// Normalization only counts when it is applying a gain: switched on for a track YouTube offered
    /// no figure for, it does nothing to the samples.
    func testLoudnessNormalizationAltersOnlyWhenApplyingAGain() {
        var output = outputAt(44_100)
        let idle = AudioPipeline.build(stats: flacCD, output: output, dsp: .init(loudnessNormalization: true))
        XCTAssertFalse(idle.isSignalAltered)

        output.loudnessGainDb = -4.2
        output.loudnessLufs = 3.1
        let applying = AudioPipeline.build(stats: flacCD, output: output, dsp: .init(loudnessNormalization: true))
        XCTAssertTrue(applying.isSignalAltered)
        XCTAssertEqual(applying.bitExactVerdict, "No — loudness normalization")
        XCTAssertEqual(applying.stage(.dsp)?.value("Gain"), "-4.2 dB")
        XCTAssertEqual(applying.stage(.dsp)?.value("Measured"), "+3.1 LUFS")

        let switchedOff = AudioPipeline.build(stats: flacCD, output: output, dsp: .init(loudnessNormalization: false))
        XCTAssertFalse(switchedOff.isSignalAltered)
        XCTAssertEqual(switchedOff.stage(.dsp)?.value("Gain"), "Off")
    }

    func testSpatialAudioAltersTheSignal() {
        let pipeline = AudioPipeline.build(stats: flacCD, output: outputAt(44_100), dsp: .init(spatialAudio: true, loudnessNormalization: false))
        XCTAssertEqual(pipeline.bitExactVerdict, "No — spatial audio")
        XCTAssertEqual(pipeline.stage(.dsp)?.value("Stereo Expand"), "250%")
    }

    func testAPlaybackSpeedOtherThanOneAltersTheSignal() {
        let pipeline = AudioPipeline.build(stats: flacCD, output: outputAt(44_100), dsp: .init(loudnessNormalization: false, playbackSpeed: 1.25))
        XCTAssertTrue(pipeline.isSignalAltered)
        XCTAssertEqual(pipeline.alterations, [.playbackSpeed(1.25)])
        XCTAssertEqual(pipeline.bitExactVerdict, "No — playback speed 1.25×")
        XCTAssertEqual(pipeline.stage(.dsp)?.value("Speed"), "1.25× (time-stretched)")
    }

    /// The verdict names the first stage in the chain; all of them are listed.
    func testTheFirstAlterationInTheChainIsNamed() {
        var output = outputAt(48_000)
        output.loudnessGainDb = 2
        let pipeline = AudioPipeline.build(
            stats: flacCD,
            output: output,
            dsp: .init(equalizerEnabled: true, spatialAudio: true, loudnessNormalization: true, playbackSpeed: 0.5)
        )
        XCTAssertEqual(pipeline.alterations, [
            .loudnessNormalization(gainDb: 2), .equalizer, .spatialAudio, .playbackSpeed(0.5),
            .resampled(fromHz: 44_100, toHz: 48_000),
        ])
        XCTAssertEqual(pipeline.bitExactVerdict, "No — loudness normalization")
    }

    /// A tap-less item never runs the app's DSP chain, so the equalizer, spatial audio and
    /// normalization stages stay off however the settings read, and the verdict does not name a
    /// stage that never saw a sample. (Playback speed is AVFoundation's `audioTimePitchAlgorithm`,
    /// not the chain, so it stays ungated — see `testAPlaybackSpeedOtherThanOneAltersTheSignal`.)
    func testATapLessItemIgnoresTheDSPChainSettings() {
        var output = outputAt(44_100)
        output.loudnessGainDb = -3
        let pipeline = AudioPipeline.build(
            stats: flacCD,
            output: output,
            dsp: .init(
                equalizerEnabled: true,
                equalizerDescription: "Bass boost",
                spatialAudio: true,
                loudnessNormalization: true,
                tapped: false
            )
        )
        XCTAssertFalse(pipeline.isSignalAltered)
        XCTAssertTrue(pipeline.alterations.isEmpty)
        XCTAssertEqual(pipeline.bitExactVerdict, "Yes (44.1 kHz end to end)")
        XCTAssertEqual(pipeline.stage(.dsp)?.value("PCM Format"), "Bypassed")
        XCTAssertEqual(pipeline.stage(.dsp)?.value("Gain"), "Off")
        XCTAssertEqual(pipeline.stage(.dsp)?.value("EQ Preset"), "Flat")
        XCTAssertEqual(pipeline.stage(.dsp)?.value("Stereo Expand"), "100%")
    }

    /// No DSP, but a 44.1 kHz source on a 48 kHz route is still converted — by iOS, not the app.
    func testResamplingAloneAltersTheSignal() {
        let pipeline = AudioPipeline.build(stats: flacCD, output: outputAt(48_000), dsp: .init(loudnessNormalization: false))
        XCTAssertTrue(pipeline.isSignalAltered)
        XCTAssertEqual(pipeline.bitExactVerdict, "No — converted by iOS 44.1 → 48 kHz")
    }

    func testTheOutputStageDescribesTheRoute() {
        var output = outputAt(48_000)
        output.deviceName = "AirPods Pro"
        output.routeKind = .bluetooth
        output.bluetoothProfile = "A2DP"
        output.outputChannels = 2
        output.outputLatency = 0.1604
        output.systemSpatialAudioEnabled = true
        output.bufferFrames = 480
        output.bufferOrigin = .sessionIO
        let pipeline = AudioPipeline.build(stats: flacCD, output: output, dsp: .init())
        let stage = pipeline.stage(.outputDevice)
        XCTAssertEqual(stage?.value("Device Name"), "AirPods Pro")
        XCTAssertEqual(stage?.value("Route"), "BLUETOOTH")
        XCTAssertEqual(stage?.value("Sample Rate"), "48000 Hz")
        XCTAssertEqual(stage?.value("Latency"), "160 ms")
        XCTAssertEqual(stage?.value("Bluetooth"), "A2DP")
        XCTAssertEqual(stage?.value("Codec"), "System Managed")
        XCTAssertEqual(stage?.value("Spatial Audio"), "On (system)")
        XCTAssertEqual(pipeline.stage(.dsp)?.value("Buffers"), "10 ms, 480 frames (I/O)")
        XCTAssertEqual(pipeline.stage(.dsp)?.value("Output API"), "AVPlayer")
    }

    /// Frames are derived at the hardware route rate, so the milliseconds must be too: a 44.1 kHz
    /// track on a 48 kHz route must not turn a 10 ms / 480-frame I/O buffer into 11 ms.
    func testBuffersMillisecondsComeFromTheRateTheFramesWereDerivedAt() {
        var output = AudioOutputStatus.Snapshot()
        output.hardwareSampleRateHz = 48_000
        output.renderSampleRateHz = 44_100
        output.bufferFrames = 480
        output.bufferOrigin = .sessionIO
        output.ioBufferDuration = 0.01
        let pipeline = AudioPipeline.build(stats: flacCD, output: output, dsp: .init())
        XCTAssertEqual(pipeline.stage(.dsp)?.value("Buffers"), "10 ms, 480 frames (I/O)")
    }

    /// A render buffer a caller publishes carries the render rate with it, so the row still converts
    /// at the rate the frames were counted at even when the route runs at a different rate — and it
    /// is not labelled as the session's I/O buffer.
    func testARenderBufferUsesTheRenderRateItWasPublishedAt() {
        let status = AudioOutputStatus()
        // The session's I/O buffer is derived at the route rate first…
        status.publishRoute(ports: [], hardwareSampleRateHz: 44_100, outputChannels: 2, ioBufferDuration: 0.011)
        // …then a render buffer at 48 kHz replaces it.
        status.publishRender(sampleRateHz: 48_000, bufferFrames: 480)
        XCTAssertEqual(status.current.bufferSampleRateHz, 48_000)
        XCTAssertEqual(status.current.bufferOrigin, .render)
        let pipeline = AudioPipeline.build(stats: flacCD, output: status.current, dsp: .init())
        XCTAssertEqual(pipeline.stage(.dsp)?.value("Buffers"), "10 ms, 480 frames")

        // Frames published without a usable rate clear the previous buffer rather than describe it
        // with the new count at an unrelated rate.
        status.publishRender(sampleRateHz: 0, bufferFrames: 480)
        XCTAssertNil(status.current.bufferFrames)
        XCTAssertNil(status.current.bufferSampleRateHz)
        XCTAssertNil(status.current.bufferOrigin)
    }
}
