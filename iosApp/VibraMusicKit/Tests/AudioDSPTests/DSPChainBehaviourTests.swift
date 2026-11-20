import XCTest
@testable import AudioDSP

/// The Float32 processors one by one and composed: filtering, bypass, headroom,
/// precision below 16-bit resolution, stability. Ported from Android's `FloatDspChainTest`.
final class DSPChainBehaviourTests: XCTestCase {

    private let sampleRate = 44_100.0

    private func flatQs() -> [Float] {
        [Float](repeating: 0.707, count: EqualizerLayout.slotCount)
    }

    // ---- Equaliser ------------------------------------------------------------

    func testEqImpulseResponseRingsOverManyFrames() {
        let eq = EqualizerProcessor()
        eq.configure(sampleRate: sampleRate, channelCount: 2)
        var gains = [Float](repeating: 0, count: EqualizerLayout.slotCount)
        gains[3] = 6 // 1 kHz bell
        eq.setTuning(enabled: true, curve: EqualizerCurve(gainsDb: gains, qs: flatQs(), preampDb: 0), balance: 0)
        eq.flush()

        let block = AudioBlock(channelCount: 2, capacityFrames: 256)
        block.samples[0] = 1 // left impulse
        block.reset(256)
        eq.process(block)

        let ringing = (1..<256).filter { abs(block.samples[$0 * 2]) > 1e-4 }.count
        XCTAssertGreaterThan(ringing, 10, "Filter impulse response must ring over multiple frames")
    }

    func testEqGainResponseLiftsCentreFrequencyByExpectedDecibels() {
        let eq = EqualizerProcessor()
        eq.configure(sampleRate: sampleRate, channelCount: 2)
        var gains = [Float](repeating: 0, count: EqualizerLayout.slotCount)
        gains[3] = 6
        eq.setTuning(enabled: true, curve: EqualizerCurve(gainsDb: gains, qs: flatQs(), preampDb: 0), balance: 0)
        eq.flush()

        let frames = 4_096
        let inputAmplitude: Float = 0.25
        let block = AudioBlock(channelCount: 2, capacityFrames: frames)
        DSPTestSignals.fillBlock(block, with: DSPTestSignals.stereoSine(hz: 1_000, amplitude: inputAmplitude,
                                                                      frames: frames, sampleRate: sampleRate))
        eq.process(block)

        let peak = (2_048..<frames).map { abs(block.samples[$0 * 2]) }.max()!
        let expected = inputAmplitude * pow(10, 6 / 20)
        XCTAssertEqual(peak, expected, accuracy: 0.08, "1 kHz centre must be amplified by about +6 dB")
    }

    func testEqSimultaneousShelvesBoostBothEnds() {
        let eq = EqualizerProcessor()
        eq.configure(sampleRate: sampleRate, channelCount: 2)
        var gains = [Float](repeating: 0, count: EqualizerLayout.slotCount)
        gains[0] = 6 // 60 Hz shelf
        gains[9] = 6 // the tone pad's 4 kHz high shelf
        eq.setTuning(enabled: true, curve: EqualizerCurve(gainsDb: gains, qs: flatQs(), preampDb: 0), balance: 0)
        eq.flush()

        let frames = 1_024
        let block = AudioBlock(channelCount: 2, capacityFrames: frames)
        var composite = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let value = Float(0.2 * sin(2 * .pi * 60 * Double(frame) / sampleRate) +
                              0.2 * sin(2 * .pi * 14_000 * Double(frame) / sampleRate))
            composite[frame * 2] = value
            composite[frame * 2 + 1] = value
        }
        DSPTestSignals.fillBlock(block, with: composite)
        eq.process(block)

        let peak = (512..<frames).map { abs(block.samples[$0 * 2]) }.max()!
        XCTAssertGreaterThan(peak, 0.4, "Simultaneous shelves must increase composite peak energy")
    }

    func testEqBypassWhenFlatPassesSamplesThroughUntouched() {
        let eq = EqualizerProcessor()
        eq.configure(sampleRate: sampleRate, channelCount: 2)
        eq.setTuning(enabled: false, curve: .flat, balance: 0)
        eq.flush()
        let block = rampBlock(frames: 64)
        eq.process(block)
        XCTAssertEqual(DSPTestSignals.contents(of: block), rampSamples(frames: 64))
    }

    func testEqMaintainsStereoChannelIndependence() {
        let eq = EqualizerProcessor()
        eq.configure(sampleRate: sampleRate, channelCount: 2)
        eq.setTuning(enabled: true,
                     curve: EqualizerCurve(gainsDb: [Float](repeating: 3, count: EqualizerLayout.slotCount),
                                           qs: flatQs(), preampDb: 0),
                     balance: 0)
        eq.flush()

        let frames = 256
        let block = AudioBlock(channelCount: 2, capacityFrames: frames)
        var samples = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames { samples[frame * 2] = 0.5 } // left has signal, right is silence
        DSPTestSignals.fillBlock(block, with: samples)
        eq.process(block)

        for frame in 0..<frames {
            XCTAssertEqual(block.samples[frame * 2 + 1], 0)
        }
    }

    func testEqPreservesFloat32ValuesBelow16BitResolution() {
        let eq = EqualizerProcessor()
        eq.configure(sampleRate: sampleRate, channelCount: 2)
        var gains = [Float](repeating: 0, count: EqualizerLayout.slotCount)
        gains[5] = 6
        eq.setTuning(enabled: true, curve: EqualizerCurve(gainsDb: gains, qs: flatQs(), preampDb: 0), balance: 0)
        eq.flush()

        // The 16-bit resolution floor is about 3.05e-5; 1e-7 would quantise to zero there.
        let block = AudioBlock(channelCount: 2, capacityFrames: 128)
        DSPTestSignals.fillBlock(block, with: [Float](repeating: 1e-7, count: 256))
        eq.process(block)

        XCTAssertTrue((0..<128).contains { block.samples[$0 * 2] != 0 },
                      "Sub-PCM16 Float32 values must not be truncated to zero")
    }

    // ---- Spatial --------------------------------------------------------------

    func testSpatialCrossfeedLeaksDelayedLowPassedSignalToTheOppositeChannel() {
        let spatial = SpatialAudioProcessor()
        spatial.configure(sampleRate: sampleRate, channelCount: 2)
        spatial.isEnabled = true

        // 15 ms at 44.1 kHz is about 661 frames.
        let frames = 1_000
        let block = AudioBlock(channelCount: 2, capacityFrames: frames)
        var samples = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            samples[frame * 2] = Float(0.5 * sin(2 * .pi * 500 * Double(frame) / sampleRate))
        }
        DSPTestSignals.fillBlock(block, with: samples)
        spatial.process(block)

        let rightEnergy = (700..<frames).reduce(0.0) { $0 + Double(abs(block.samples[$1 * 2 + 1])) }
        XCTAssertGreaterThan(rightEnergy, 1.0, "Crossfeed must produce signal on the right channel")
    }

    func testSpatialBypassPassesSamplesThroughUntouchedWhenDisabled() {
        let spatial = SpatialAudioProcessor()
        spatial.configure(sampleRate: sampleRate, channelCount: 2)
        spatial.isEnabled = false
        let block = rampBlock(frames: 64)
        spatial.process(block)
        XCTAssertEqual(DSPTestSignals.contents(of: block), rampSamples(frames: 64))
    }

    /// A seek flushes the filters, as Media3 flushes its processors on one: the
    /// cross-feed must not carry audio from before the jump into the silence
    /// after it. A block that follows on does carry it — that is the cross-feed.
    func testASeekFlushesTheCrossFeedButContinuousAudioDoesNot() {
        func rightChannelAfterLeftOnlyTone(nextPosition: Int64) -> Float {
            let chain = DSPChain()
            chain.apply(AudioDSPSettings(spatialAudio: true, loudnessNormalization: false))
            chain.configure(sampleRate: sampleRate, channelCount: 2)
            var tone = [Float](repeating: 0, count: 1_024 * 2)
            for frame in 0..<1_024 { tone[frame * 2] = 0.5 }
            tone.withUnsafeMutableBufferPointer {
                chain.process(interleaved: $0.baseAddress!, frameCount: 1_024, channelCount: 2, sourceFramePosition: 0)
            }
            var silence = [Float](repeating: 0, count: 512 * 2)
            silence.withUnsafeMutableBufferPointer {
                chain.process(interleaved: $0.baseAddress!, frameCount: 512, channelCount: 2,
                              sourceFramePosition: nextPosition)
            }
            return (0..<512).map { abs(silence[$0 * 2 + 1]) }.max()!
        }
        XCTAssertGreaterThan(rightChannelAfterLeftOnlyTone(nextPosition: 1_024), 0.01,
                             "continuous audio: the delayed left channel feeds into the right")
        XCTAssertGreaterThan(rightChannelAfterLeftOnlyTone(nextPosition: 1_025), 0.01,
                             "a frame of rounding is not a seek")
        XCTAssertEqual(rightChannelAfterLeftOnlyTone(nextPosition: 500_000), 0,
                       "after a seek nothing from before the jump comes through")
    }

    // ---- Transition filter -----------------------------------------------------

    func testTransitionLowPassAttenuatesHighFrequencySignal() {
        let transition = TransitionFilterProcessor()
        transition.configure(sampleRate: sampleRate, channelCount: 2)
        transition.setCutoffs(lowPassHz: 500, highPassHz: TransitionFilterProcessor.offHz)
        transition.flush()

        let block = sineBlock(hz: 5_000, frames: 1_024)
        transition.process(block)

        // 5 kHz is 10x above the cutoff; at 24 dB/octave it is heavily attenuated.
        let peak = (512..<1_024).map { abs(block.samples[$0 * 2]) }.max()!
        XCTAssertLessThan(peak, 0.1, "5 kHz through a 500 Hz low-pass must be attenuated (got \(peak))")
    }

    func testTransitionHighPassAttenuatesLowFrequencySignal() {
        let transition = TransitionFilterProcessor()
        transition.configure(sampleRate: sampleRate, channelCount: 2)
        transition.setCutoffs(lowPassHz: TransitionFilterProcessor.openHz, highPassHz: 2_000)
        transition.flush()

        let block = sineBlock(hz: 100, frames: 1_024)
        transition.process(block)

        let peak = (512..<1_024).map { abs(block.samples[$0 * 2]) }.max()!
        XCTAssertLessThan(peak, 0.1, "100 Hz through a 2 kHz high-pass must be attenuated (got \(peak))")
    }

    func testTransitionBypassPassesSamplesThroughUntouchedWhenOpen() {
        let transition = TransitionFilterProcessor()
        transition.configure(sampleRate: sampleRate, channelCount: 2)
        transition.open()
        transition.flush()
        let block = rampBlock(frames: 64)
        transition.process(block)
        XCTAssertEqual(DSPTestSignals.contents(of: block), rampSamples(frames: 64))
    }

    // ---- The chain -------------------------------------------------------------

    func testDspChainPreservesFloat32PrecisionAcrossAllStagesWithoutIntermediateQuantisation() {
        let chain = DSPChain()
        chain.configure(sampleRate: sampleRate, channelCount: 2)
        chain.spatial.isEnabled = true
        chain.equalizer.setTuning(enabled: true, curve: .flat, balance: 0)
        chain.transition.open()
        chain.flush()

        let block = AudioBlock(channelCount: 2, capacityFrames: 128)
        DSPTestSignals.fillBlock(block, with: [Float](repeating: 1e-7, count: 256))
        chain.process(block)

        XCTAssertTrue((0..<128).contains { block.samples[$0 * 2] != 0 },
                      "Sub-LSB Float32 signal must survive the entire chain")
    }

    func testDspChainPreservesHeadroomWithoutClippingAboveOne() {
        let chain = DSPChain()
        chain.configure(sampleRate: sampleRate, channelCount: 2)
        chain.spatial.isEnabled = false
        // Flat EQ with +3 dB of preamp.
        chain.equalizer.setTuning(enabled: true,
                                  curve: EqualizerCurve(gainsDb: [Float](repeating: 0, count: EqualizerLayout.slotCount),
                                                        qs: flatQs(), preampDb: 3),
                                  balance: 0)
        chain.transition.open()
        chain.flush()

        let block = AudioBlock(channelCount: 2, capacityFrames: 64)
        // 0.9 lifted by 3 dB is about 1.27, past nominal full scale.
        DSPTestSignals.fillBlock(block, with: [Float](repeating: 0.9, count: 128))
        chain.process(block)

        let sample = block.samples[64 * 2 - 2]
        XCTAssertGreaterThan(sample, 1.1, "Headroom must be preserved above 1.0 (got \(sample))")
    }

    func testZeroLengthInputIsHandledSafelyAcrossTheChain() {
        let chain = DSPChain()
        chain.configure(sampleRate: sampleRate, channelCount: 2)
        let block = AudioBlock(channelCount: 2, capacityFrames: 64)
        block.reset(0)
        chain.process(block)
        XCTAssertEqual(block.frameCount, 0)
    }

    func testRepeatedBlockProcessingStaysContinuousAndStable() {
        let chain = DSPChain()
        chain.configure(sampleRate: sampleRate, channelCount: 2)
        chain.spatial.isEnabled = true
        var gains = [Float](repeating: 0, count: EqualizerLayout.slotCount)
        gains[2] = 4
        chain.equalizer.setTuning(enabled: true, curve: EqualizerCurve(gainsDb: gains, qs: flatQs(), preampDb: 0), balance: 0)
        chain.transition.setCutoffs(lowPassHz: 8_000, highPassHz: 100)

        let blockSize = 512
        let block = AudioBlock(channelCount: 2, capacityFrames: blockSize)
        // 50 consecutive blocks: about a second of audio.
        for iteration in 0..<50 {
            for frame in 0..<blockSize {
                let total = iteration * blockSize + frame
                let value = Float(sin(2 * .pi * 440 * Double(total) / sampleRate))
                block.samples[frame * 2] = value
                block.samples[frame * 2 + 1] = value
            }
            block.reset(blockSize)
            chain.process(block)
            for index in 0..<(blockSize * 2) {
                XCTAssertTrue(block.samples[index].isFinite, "Sample must stay finite at block \(iteration)")
            }
        }
    }

    // ---- Helpers ---------------------------------------------------------------

    private func rampSamples(frames: Int) -> [Float] {
        (0..<(frames * 2)).map { Float($0 + 1) * 0.01 }
    }

    private func rampBlock(frames: Int) -> AudioBlock {
        let block = AudioBlock(channelCount: 2, capacityFrames: frames)
        DSPTestSignals.fillBlock(block, with: rampSamples(frames: frames))
        return block
    }

    private func sineBlock(hz: Double, frames: Int) -> AudioBlock {
        let block = AudioBlock(channelCount: 2, capacityFrames: frames)
        DSPTestSignals.fillBlock(block, with: DSPTestSignals.stereoSine(hz: hz, amplitude: 1, frames: frames,
                                                                      sampleRate: sampleRate))
        return block
    }
}
