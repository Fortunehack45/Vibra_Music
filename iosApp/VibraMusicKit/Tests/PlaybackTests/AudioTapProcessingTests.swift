import AudioDSP
import AVFoundation
import VibraMusicCore
import PlaybackPolicy
import XCTest
@testable import Playback

/// The processing tap: the app's DSP chain sees every frame of a processed item, and lossless or
/// Atmos items that must not be touched play with no tap at all.
@MainActor
final class AudioTapProcessingTests: EngineTestCase {
    override func setUp() async throws {
        try await super.setUp()
        AudioOutputStatus.shared.reset()
    }

    /// The engine publishes what it knows to the Audio Pipeline sheet: the render rate is the track's
    /// own, the decoder is named from the track's format, and the DSP row is the tap's measured
    /// format. Before the fix the store held none of these, so the sheet fell back to the hardware
    /// rate and printed "Float32" for a format nobody measured.
    func testPipelineFactsReportTheTracksRateDecoderAndTappedFormat() async throws {
        let url = try ToneFile.write([.tone(frequency: 440, seconds: 3)], to: directory, name: "facts-aac", container: .aac(bitrate: 128_000))
        let item = PlayableItem.file(url, id: "facts-aac", loudnessDb: -4.5)
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying && h.engine.position > 0.5 }

        let processor = try XCTUnwrap(h.processors[h.engine.activeDeckID])
        await waitUntil("frames through the tap") { processor.frames > 20_000 }
        XCTAssertEqual(try XCTUnwrap(processor.formats.first).sampleRate, 44_100)

        // The DSP row appears once the tap has prepared; render and decoder are published at once.
        await waitUntil("pipeline facts published") {
            let snapshot = AudioOutputStatus.shared.current
            return snapshot.renderSampleRateHz == 44_100
                && snapshot.decoderName?.contains("AAC") == true
                && snapshot.dspFormat?.contains("interleaved") == true
        }
        let snapshot = AudioOutputStatus.shared.current
        XCTAssertEqual(h.engine.signalPath, .processed)
        XCTAssertEqual(snapshot.renderSampleRateHz, 44_100, "the render rate is the track's, not the hardware's")
        XCTAssertTrue(snapshot.decoderName?.contains("AAC") == true, "the decoder is named from the track's format")
        XCTAssertNotEqual(snapshot.dspFormat, "Float32", "the placeholder must not survive")
        XCTAssertEqual(snapshot.dspFormat?.hasPrefix("Float32"), true, "the tap's measured PCM layout")
        XCTAssertEqual(snapshot.dspFormat?.contains("interleaved"), true)
    }

    func testTheProcessorIsCalledWithFramesOfTheItem() async throws {
        let url = try ToneFile.write([.tone(frequency: 440, seconds: 3)], to: directory, name: "tap-aac", container: .aac(bitrate: 128_000))
        let item = PlayableItem.file(url, id: "tap-aac", loudnessDb: -4.5)
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying && h.engine.position > 0.5 }

        let processor = try XCTUnwrap(h.processors[h.engine.activeDeckID])
        await waitUntil("frames through the tap") { processor.frames > 20_000 }
        XCTAssertEqual(h.engine.signalPath, .processed, "lossy audio always goes through the chain")
        let format = try XCTUnwrap(processor.formats.first)
        XCTAssertEqual(format.sampleRate, 44_100)
        XCTAssertEqual(format.channelCount, 2)
        XCTAssertTrue(format.isFloat)
        // Announced with the item's normalization figure before its first buffer.
        XCTAssertEqual(processor.begunItems.first?.id, item.id)
        XCTAssertEqual(processor.begunItems.first?.loudnessDb, -4.5)
        XCTAssertGreaterThan(processor.peak, 0.1, "the processor saw the tone, not silence")
        // Buffers are placed in the item's timeline, in order.
        let positions = processor.framePositions
        XCTAssertGreaterThan(positions.count, 3)
        XCTAssertEqual(positions, positions.sorted())
        // The other deck's processor stayed idle.
        XCTAssertEqual(h.processors[h.engine.activeDeckID == .a ? .b : .a]?.frames, 0)
    }

    func testALosslessItemTheChainWouldNotTouchPlaysWithNoTap() async throws {
        // A CAF of PCM is lossless by the decoder's own account.
        let item = try tone(4, name: "tap-lossless")
        let h = harness(queue: [item])
        h.processors.values.forEach { $0.alters = false }
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying && h.engine.position > 0.4 }

        let deck = h.engine.deck(h.engine.activeDeckID)
        let processor = try XCTUnwrap(h.processors[deck.id])
        XCTAssertEqual(h.engine.signalPath, .bitTransparent)
        XCTAssertNil(deck.current?.playerItem.audioMix, "no tap in the path")
        XCTAssertEqual(processor.frames, 0)
        // The pipeline reports the untouched lossless item as bypassed, at the track's own rate.
        let snapshot = AudioOutputStatus.shared.current
        XCTAssertEqual(snapshot.dspFormat, "Bypassed")
        XCTAssertEqual(snapshot.renderSampleRateHz, 44_100)
        XCTAssertTrue(snapshot.dspAvailable, "the chain could run; it just has nothing to change on this item")

        // The EQ goes on mid-track: the chain now alters the signal, and the tap is attached to
        // the playing item without reopening it.
        processor.alters = true
        h.engine.audioProcessingDidChange()
        XCTAssertEqual(h.engine.signalPath, .processed)
        XCTAssertNotNil(deck.current?.playerItem.audioMix)
        await waitUntil("frames through the new tap") { processor.frames > 4_000 }
        XCTAssertTrue(h.engine.isPlaying)

        // And off again.
        processor.alters = false
        h.engine.audioProcessingDidChange()
        XCTAssertEqual(h.engine.signalPath, .bitTransparent)
        XCTAssertNil(deck.current?.playerItem.audioMix)
    }

    func testALossyItemKeepsItsTapEvenWithNothingToProcess() async throws {
        let url = try ToneFile.write([.tone(frequency: 440, seconds: 2)], to: directory, name: "tap-lossy", container: .aac(bitrate: 128_000))
        let item = PlayableItem.file(url, id: "tap-lossy")
        let h = harness(queue: [item])
        h.processors.values.forEach { $0.alters = false }
        h.engine.load(item, playWhenReady: false)
        await waitUntil("opened") { h.engine.signalPath != nil }
        XCTAssertEqual(h.engine.signalPath, .processed)
    }

    func testDolbyAtmosIsPassedThroughForSpatialRendering() async throws {
        // The source says E-AC-3 JOC; the tap would see it already folded to PCM, so it is never
        // attached, and multichannel spatialization is allowed on the item.
        let url = try ToneFile.write([.tone(frequency: 440, seconds: 3)], to: directory, name: "tap-atmos", container: .aac(bitrate: 128_000))
        let item = PlayableItem(
            id: "tap-atmos",
            title: "Atmos",
            artist: "A",
            source: .file(url),
            declaredFormat: StreamFormat(codec: "eac3-joc", kbps: 768, channels: 6)
        )
        let h = harness(queue: [item])
        // Normalization would report an active gain for this item, but there is no tap to apply it.
        h.processors.values.forEach { $0.readout = LoudnessReadout(gainDb: -4, loudnessDb: 4) }
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying && h.engine.position > 0.4 }

        let deck = h.engine.deck(h.engine.activeDeckID)
        XCTAssertEqual(h.engine.signalPath, .spatialPassthrough)
        XCTAssertNil(deck.current?.playerItem.audioMix)
        XCTAssertEqual(deck.current?.playerItem.allowedAudioSpatializationFormats, .monoStereoAndMultichannel)
        XCTAssertEqual(h.processors[deck.id]?.frames, 0)

        // No tap means the DSP chain cannot run and nothing applies a normalization gain, so the
        // snapshot says both rather than claiming a filter that never sees the audio.
        let snapshot = AudioOutputStatus.shared.current
        XCTAssertEqual(snapshot.dspFormat, "Bypassed")
        XCTAssertFalse(snapshot.dspAvailable, "an Atmos item has no tap, so the DSP chain is inert")
        XCTAssertNil(snapshot.loudnessGainDb, "nothing applies a normalization gain without a tap")
        XCTAssertNil(snapshot.loudnessLufs)

        // Even with the whole chain switched on.
        h.engine.audioProcessingDidChange()
        XCTAssertEqual(h.engine.signalPath, .spatialPassthrough)
        XCTAssertNil(deck.current?.playerItem.audioMix)
    }

    /// When a processed item becomes current, the sheet shows its own DSP state (measured, or
    /// unmeasured until its tap reports), never the previous item's facts.
    func testAProcessedItemNeverInheritsThePreviousItemsBypassedDSPState() async throws {
        // A lossless item the chain would not touch leaves the DSP row at "Bypassed".
        let lossless = try tone(3, name: "dsp-before")
        let h = harness(queue: [lossless])
        h.processors.values.forEach { $0.alters = false }
        h.engine.load(lossless, playWhenReady: true)
        await waitUntil("bypassed") { AudioOutputStatus.shared.current.dspFormat == "Bypassed" }

        // The next item is processed. Loaded paused, its tap may or may not have prepared by the
        // time it becomes current (AVFoundation can prepare it for preroll), so the sheet shows
        // either the measured format or nothing measured yet — never the previous item's Bypassed.
        // ponytail: the slow-tap path is only exercised when preroll loses the race; a fake tap
        // that never prepares would pin it every run.
        let url = try ToneFile.write([.tone(frequency: 440, seconds: 3)], to: directory, name: "dsp-aac", container: .aac(bitrate: 128_000))
        let processed = PlayableItem.file(url, id: "dsp-aac")
        h.engine.load(processed, playWhenReady: false)
        await waitUntil("processed item current") { h.engine.signalPath == .processed }

        let snapshot = AudioOutputStatus.shared.current
        XCTAssertNotEqual(snapshot.dspFormat, "Bypassed", "the previous item's Bypassed must not survive")
        XCTAssertTrue(snapshot.dspAvailable)
    }

    /// An item whose asset has no readable track format (HLS) must not leave the previous track's
    /// render rate on the sheet, or the summary and resampler describe the track that just ended.
    func testAnItemWithNoReadableTrackFormatClearsThePriorRenderRate() async throws {
        let tone = try tone(4, name: "rate-before")
        let (server, playlist) = try await HLSFixture.serve(seconds: 4)
        defer { server.stop() }
        let hls = PlayableItem(id: "hls-rate", title: "HLS", artist: "Test", source: .asset { AVURLAsset(url: playlist) })
        let h = harness(queue: [tone, hls])
        h.engine.load(tone, playWhenReady: true)
        await waitUntil("the tone's rate is published") { AudioOutputStatus.shared.current.renderSampleRateHz == 44_100 }

        h.engine.load(hls, playWhenReady: true)
        await waitUntil("the HLS item is current", timeout: 20) {
            h.engine.currentItem?.id == "hls-rate" && h.engine.signalPath == .unprocessed
        }
        await waitUntil("the prior rate is cleared") { AudioOutputStatus.shared.current.renderSampleRateHz == nil }
        // HLS has no asset-level track, so no tap: the DSP chain cannot run on it either.
        XCTAssertFalse(AudioOutputStatus.shared.current.dspAvailable)
    }

    func testWithoutAProcessorAudioStillFlowsThroughTheSilenceDetector() async throws {
        let url = try ToneFile.write([.tone(frequency: 440, seconds: 2)], to: directory, name: "tap-none", container: .aac(bitrate: 128_000))
        let item = PlayableItem.file(url, id: "tap-none")
        let h = harness(queue: [item], withProcessors: false)
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying && h.engine.position > 0.3 }
        let entry = try XCTUnwrap(h.engine.deck(h.engine.activeDeckID).current)
        XCTAssertEqual(h.engine.signalPath, .processed)
        await waitUntil("tap running") { (entry.tap?.processedFrameCount ?? 0) > 4_000 }
        XCTAssertNotNil(entry.tap?.silence.lastSound, "the detector heard the tone")
    }
}

/// How an item's content is told apart: the decoder's format first, the source's claim second.
final class AudioContentKindTests: XCTestCase {
    func testTheDecoderFormatDecides() {
        XCTAssertEqual(AudioContentKind.classify(AudioTrackFormat(formatID: kAudioFormatFLAC), declared: nil), .lossless)
        XCTAssertEqual(AudioContentKind.classify(AudioTrackFormat(formatID: kAudioFormatAppleLossless), declared: nil), .lossless)
        XCTAssertEqual(AudioContentKind.classify(AudioTrackFormat(formatID: kAudioFormatLinearPCM), declared: nil), .lossless)
        XCTAssertEqual(AudioContentKind.classify(AudioTrackFormat(formatID: kAudioFormatEnhancedAC3), declared: nil), .dolbyAtmos)
        XCTAssertEqual(AudioContentKind.classify(AudioTrackFormat(formatID: kAudioFormatMPEG4AAC), declared: nil), .lossy)
    }

    func testAClaimOfLosslessDoesNotOutrankAnAACDecoder() {
        let claim = StreamFormat(codec: "flac", sampleRateHz: 96_000, bitDepth: 24)
        XCTAssertEqual(AudioContentKind.classify(AudioTrackFormat(formatID: kAudioFormatMPEG4AAC), declared: claim), .lossy)
        XCTAssertEqual(AudioContentKind.classify(AudioTrackFormat(), declared: claim), .lossless, "the claim fills in when the format is unreadable")
    }

    func testADeclaredAtmosStreamIsAtmos() {
        let atmos = StreamFormat(codec: "eac3-joc")
        XCTAssertEqual(AudioContentKind.classify(AudioTrackFormat(formatID: kAudioFormatMPEG4AAC), declared: atmos), .dolbyAtmos)
    }
}

/// On a USB DAC the session is asked for the track's own sample rate; elsewhere it is left alone.
final class PreferredSampleRatePolicyTests: XCTestCase {
    func testAUSBRouteRunsAtTheTracksRate() {
        XCTAssertEqual(PreferredSampleRatePolicy.preferredSampleRate(outputs: [.usb], trackSampleRate: 96_000), 96_000)
        XCTAssertEqual(PreferredSampleRatePolicy.preferredSampleRate(outputs: [.usb], trackSampleRate: 44_100), 44_100)
    }

    func testOtherRoutesAreLeftToTheSystem() {
        XCTAssertNil(PreferredSampleRatePolicy.preferredSampleRate(outputs: [.phone], trackSampleRate: 96_000))
        XCTAssertNil(PreferredSampleRatePolicy.preferredSampleRate(outputs: [.bluetooth], trackSampleRate: 44_100))
        XCTAssertNil(PreferredSampleRatePolicy.preferredSampleRate(outputs: [.airPlay, .hdmi], trackSampleRate: 48_000))
    }

    func testAnUnknownRateAsksForNothing() {
        XCTAssertNil(PreferredSampleRatePolicy.preferredSampleRate(outputs: [.usb], trackSampleRate: nil))
        XCTAssertNil(PreferredSampleRatePolicy.preferredSampleRate(outputs: [.usb], trackSampleRate: 0))
    }
}

/// The measured PCM format text the DSP stage's PCM Format row prints. It must name the bit depth
/// the tap measured, not assume 32 for every float format.
final class AudioTapFormatTests: XCTestCase {
    func testPCMDescriptionNamesTheMeasuredBitDepthAndLayout() {
        let cases: [(format: AudioTapFormat, expected: String)] = [
            (AudioTapFormat(sampleRate: 44_100, channelCount: 2), "Float32 non-interleaved"),
            (AudioTapFormat(sampleRate: 48_000, channelCount: 2, isNonInterleaved: false, bitsPerChannel: 64), "Float64 interleaved"),
            (AudioTapFormat(sampleRate: 44_100, channelCount: 2, isFloat: false, bitsPerChannel: 16), "Int16 non-interleaved"),
            (AudioTapFormat(sampleRate: 44_100, channelCount: 2, isFloat: false, isNonInterleaved: false, bitsPerChannel: 24), "Int24 interleaved"),
            (AudioTapFormat(sampleRate: 44_100, channelCount: 2, bitsPerChannel: 0), "Float non-interleaved"),
            (AudioTapFormat(sampleRate: 44_100, channelCount: 2, isFloat: false, bitsPerChannel: 0), "Int non-interleaved"),
        ]
        for (format, expected) in cases {
            XCTAssertEqual(format.pcmDescription, expected)
        }
        XCTAssertEqual(cases[0].format.measurementDescription, "44100 Hz · 2 ch · Float32 non-interleaved")
    }
}
