import XCTest
@testable import AudioDSP

/// Loudness normalization: Android's gain computation, exactly, and the
/// `LoudnessEnhancer` behaviour it drives. PORTING.md's done-test is "quiet and
/// loud tracks play at a similar volume".
final class LoudnessNormalizationTests: XCTestCase {

    private let sampleRate = 48_000.0

    // ---- The gain Android computes -------------------------------------------

    func testGainIsTheNegatedFigureInMillibels() {
        XCTAssertEqual(LoudnessNormalizer.gainMillibels(forLoudnessDb: 5.3), -530)
        XCTAssertEqual(LoudnessNormalizer.gainMillibels(forLoudnessDb: -2.0), 200)
        XCTAssertEqual(LoudnessNormalizer.gainMillibels(forLoudnessDb: 0), 0)
        XCTAssertEqual(LoudnessNormalizer.gainMillibels(forLoudnessDb: 7.77), -777)
    }

    /// `(-loudnessDb * 100).roundToInt().coerceIn(-1500, 300)`.
    func testGainIsHeldBetweenMinusFifteenAndPlusThreeDecibels() {
        XCTAssertEqual(LoudnessNormalizer.gainMillibels(forLoudnessDb: -4.0), 300)
        XCTAssertEqual(LoudnessNormalizer.gainMillibels(forLoudnessDb: -40), 300)
        XCTAssertEqual(LoudnessNormalizer.gainMillibels(forLoudnessDb: 15.0), -1500)
        XCTAssertEqual(LoudnessNormalizer.gainMillibels(forLoudnessDb: 22.4), -1500)
        XCTAssertEqual(LoudnessNormalizer.gainMillibels(forLoudnessDb: 1e300), -1500)
    }

    /// Kotlin's `roundToInt` breaks ties toward +∞, not away from zero.
    func testGainRoundsHalvesTowardPositiveInfinityLikeKotlin() {
        XCTAssertEqual(LoudnessNormalizer.gainMillibels(forLoudnessDb: -0.125), 13) // 12.5 → 13
        XCTAssertEqual(LoudnessNormalizer.gainMillibels(forLoudnessDb: 0.125), -12) // -12.5 → -12
        XCTAssertEqual(LoudnessNormalizer.gainMillibels(forLoudnessDb: 2.004), -200)
        XCTAssertEqual(LoudnessNormalizer.gainMillibels(forLoudnessDb: 2.006), -201)
    }

    func testANonFiniteFigureIsTreatedAsUnknown() {
        XCTAssertNil(LoudnessNormalizer.gainMillibels(forLoudnessDb: .nan))
        XCTAssertNil(LoudnessNormalizer.gainMillibels(forLoudnessDb: .infinity))
        XCTAssertEqual(LoudnessNormalizer.readout(enabled: true, loudnessDb: .nan), .inactive)
    }

    /// What the pipeline readout shows: gain in dB, the figure as "measured",
    /// and nothing at all when off or unknown.
    func testTheReadoutMatchesWhatAndroidPublishes() {
        XCTAssertEqual(LoudnessNormalizer.readout(enabled: true, loudnessDb: 6.25),
                       LoudnessReadout(gainDb: -6.25, loudnessDb: 6.25))
        XCTAssertEqual(LoudnessNormalizer.readout(enabled: true, loudnessDb: -9),
                       LoudnessReadout(gainDb: 3, loudnessDb: -9))
        XCTAssertEqual(LoudnessNormalizer.readout(enabled: false, loudnessDb: 6.25), .inactive)
        XCTAssertEqual(LoudnessNormalizer.readout(enabled: true, loudnessDb: nil), .inactive)
        XCTAssertEqual(LoudnessNormalizer.retryDelay, 6)
    }

    func testTheStageTracksSettingAndFigureTogether() {
        let normalizer = LoudnessNormalizer()
        XCTAssertFalse(normalizer.isActive, "on by default, but nothing to apply without a figure")
        XCTAssertEqual(normalizer.setTrackLoudness(4), LoudnessReadout(gainDb: -4, loudnessDb: 4))
        XCTAssertTrue(normalizer.isActive)
        XCTAssertEqual(normalizer.setEnabled(false), .inactive)
        XCTAssertFalse(normalizer.isActive)
        XCTAssertEqual(normalizer.setEnabled(true), LoudnessReadout(gainDb: -4, loudnessDb: 4), "the figure is remembered")
        XCTAssertEqual(normalizer.apply(enabled: true, loudnessDb: nil), .inactive)
    }

    // ---- What it does to samples ----------------------------------------------

    func testOffOrUnknownLeavesSamplesUntouched() {
        let tone = DSPTestSignals.stereoSine(hz: 440, amplitude: 0.9, frames: 4_800, sampleRate: sampleRate)
        let unknown = LoudnessNormalizer()
        XCTAssertEqual(DSPTestSignals.run(unknown, tone, sampleRate: sampleRate), tone)
        let off = LoudnessNormalizer()
        off.apply(enabled: false, loudnessDb: 8)
        XCTAssertEqual(DSPTestSignals.run(off, tone, sampleRate: sampleRate), tone)
    }

    /// Below the compressor's knee the stage is exactly the gain.
    func testBelowTheKneeTheGainIsAppliedExactly() {
        for (figure, expectedDb) in [(6.0, -6.0), (-3.0, 3.0), (12.5, -12.5)] {
            let normalizer = LoudnessNormalizer()
            normalizer.setTrackLoudness(figure)
            let tone = DSPTestSignals.stereoSine(hz: 440, amplitude: 0.03, frames: 9_600, sampleRate: sampleRate) // -30 dBFS
            let output = DSPTestSignals.run(normalizer, tone, sampleRate: sampleRate)
            let gain = DSPTestSignals.decibels(DSPTestSignals.rms(of: output, channel: 0, channelCount: 2) /
                                               DSPTestSignals.rms(of: tone, channel: 0, channelCount: 2))
            XCTAssertEqual(gain, expectedDb, accuracy: 0.01, "figure \(figure)")
        }
    }

    /// Above -8 dBFS (after gain) the 7:1 compressor rides the level, and the
    /// output never reaches full scale — which is how a +3 dB gain on a hot
    /// master stays clean on Android.
    func testAboveTheKneeTheCompressorHoldsPeaksDown() {
        let normalizer = LoudnessNormalizer()
        normalizer.setTrackLoudness(-3) // +3 dB
        let tone = DSPTestSignals.stereoSine(hz: 200, amplitude: 1, frames: 48_000, sampleRate: sampleRate)
        let output = DSPTestSignals.run(normalizer, tone, sampleRate: sampleRate)

        let peak = output.map(abs).max()!
        XCTAssertLessThanOrEqual(peak, 32_767 / 32_768, "hard-limited like the AOSP effect")
        let steadyPeak = output[(24_000 * 2)...].map(abs).max()!
        // Knee -8 dBFS, 7:1: a +3 dBFS peak comes out near -8 + 11/7 ≈ -6.4 dBFS.
        XCTAssertLessThan(DSPTestSignals.decibels(Double(steadyPeak)), -4)
        XCTAssertGreaterThan(DSPTestSignals.decibels(Double(steadyPeak)), -9)
    }

    func testChannelsAreLinkedSoTheImageDoesNotShift() {
        let normalizer = LoudnessNormalizer()
        normalizer.setTrackLoudness(0)
        var input = DSPTestSignals.stereoSine(hz: 200, amplitude: 1, frames: 9_600, sampleRate: sampleRate)
        for frame in 0..<9_600 { input[frame * 2 + 1] *= 0.1 } // quiet right channel
        let output = DSPTestSignals.run(normalizer, input, sampleRate: sampleRate)
        for frame in stride(from: 4_800, to: 9_600, by: 37) where abs(input[frame * 2]) > 0.5 {
            XCTAssertEqual(output[frame * 2 + 1] / output[frame * 2], 0.1, accuracy: 0.0005,
                           "one gain for both channels, frame \(frame)")
        }
    }

    func testMonoIsNormalizedToo() {
        let normalizer = LoudnessNormalizer()
        normalizer.setTrackLoudness(6)
        let tone = (0..<4_800).map { Float(0.03 * sin(2 * .pi * 440 * Double($0) / sampleRate)) }
        let output = DSPTestSignals.run(normalizer, tone, channelCount: 1, sampleRate: sampleRate)
        XCTAssertEqual(DSPTestSignals.rms(of: output, channel: 0, channelCount: 1) /
                       DSPTestSignals.rms(of: tone, channel: 0, channelCount: 1), pow(10, -6.0 / 20), accuracy: 0.0005)
    }

    /// A loud modern master and a quiet older one, each with the figure YouTube
    /// would give it relative to its reference, come out at the same level.
    func testQuietAndLoudTracksPlayAtASimilarVolume() {
        // RMS -8 dB and -17 dB: 9 dB apart going in.
        let loud = DSPTestSignals.stereoSine(hz: 330, amplitude: Float(pow(10, -8.0 / 20) * 2.0.squareRoot()),
                                             frames: 24_000, sampleRate: sampleRate)
        let quiet = DSPTestSignals.stereoSine(hz: 330, amplitude: Float(pow(10, -17.0 / 20) * 2.0.squareRoot()),
                                              frames: 24_000, sampleRate: sampleRate)
        func played(_ tone: [Float], figure: Double) -> Double {
            let chain = DSPChain()
            chain.apply(AudioDSPSettings(loudnessNormalization: true))
            chain.loudness.setTrackLoudness(figure)
            let output = DSPTestSignals.run(chain, tone, sampleRate: sampleRate)
            return DSPTestSignals.decibels(DSPTestSignals.rms(of: output, channel: 0, channelCount: 2, from: 4_800))
        }
        let loudLevel = played(loud, figure: 6)    // 6 dB over the reference
        let quietLevel = played(quiet, figure: -3) // 3 dB under it
        XCTAssertEqual(loudLevel, quietLevel, accuracy: 1, "\(loudLevel) dB vs \(quietLevel) dB")
        XCTAssertEqual(loudLevel, -14, accuracy: 1)
    }

    // ---- The AOSP compressor's pieces --------------------------------------------

    func testKneeFollowsAOSPsTargetGainTable() {
        XCTAssertEqual(LoudnessCompressor.kneeDecibels(forTargetGain: 0.2), -8)
        XCTAssertEqual(LoudnessCompressor.kneeDecibels(forTargetGain: 1.41), -8)
        XCTAssertEqual(LoudnessCompressor.kneeDecibels(forTargetGain: 2.5), -8.25, accuracy: 1e-6)
        XCTAssertEqual(LoudnessCompressor.kneeDecibels(forTargetGain: 4.5), -9.5, accuracy: 1e-6)
        XCTAssertEqual(LoudnessCompressor.kneeDecibels(forTargetGain: 9), -10)
        XCTAssertEqual(LoudnessCompressor.kneeThreshold(decibels: 0), log(32_767), accuracy: 1e-4)
    }

    func testFastLogTracksTheNaturalLog() {
        for value: Float in [0.032767, 0.5, 1, 3, 100, 1_000, 32_767, 60_000] {
            XCTAssertEqual(LoudnessCompressor.fastLog(value), log(value), accuracy: 0.01, "\(value)")
        }
    }
}
