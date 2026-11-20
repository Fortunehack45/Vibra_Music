import XCTest
@testable import AudioDSP

/// Presets and the tone pad measured end to end: what a listener hears when
/// they pick one. PORTING.md's done-test for the equaliser is "the Bass Boost
/// preset audibly boosts the low end".
final class EqualizerFrequencyResponseTests: XCTestCase {

    private let sampleRate = 48_000.0
    private let frames = 48_000
    private let settle = 12_000

    /// The bottom band is a shelf cornered at 60 Hz, so the full lift arrives
    /// below it: about +6.4 dB at 40 Hz against the mids, half that at 60 Hz.
    func testBassBoostRaisesTheLowEndAgainstA4kHzSine() {
        let settings = EqualizerSettings(isEnabled: true, mode: .manual, bandsDb: EqualizerPreset.bassBoost.bandsDb)
        let deep = rmsGainDb(settings, hz: 40)
        let low = rmsGainDb(settings, hz: 60)
        let high = rmsGainDb(settings, hz: 4_000)
        XCTAssertGreaterThan(deep - high, 5.5, "40 Hz \(deep) dB against 4 kHz \(high) dB")
        XCTAssertGreaterThan(low - high, 3.3, "60 Hz \(low) dB against 4 kHz \(high) dB")
        XCTAssertLessThanOrEqual(deep, 0.05, "the make-up keeps even the boosted band from getting louder than it went in")
    }

    func testBassCutDoesTheOpposite() {
        let settings = EqualizerSettings(isEnabled: true, mode: .manual, bandsDb: EqualizerPreset.bassCut.bandsDb)
        XCTAssertLessThan(rmsGainDb(settings, hz: 40) - rmsGainDb(settings, hz: 4_000), -5.5)
    }

    func testTrebleBoostRaisesTheTopAgainstTheBottom() {
        let settings = EqualizerSettings(isEnabled: true, mode: .manual, bandsDb: EqualizerPreset.trebleBoost.bandsDb)
        XCTAssertGreaterThan(rmsGainDb(settings, hz: 8_000) - rmsGainDb(settings, hz: 100), 2)
    }

    func testTheTonePadWarmCornerFavoursTheLowEnd() {
        let warm = EqualizerSettings(isEnabled: true, mode: .dynamic, toneX: -5, toneY: 0)
        XCTAssertGreaterThan(rmsGainDb(warm, hz: 80) - rmsGainDb(warm, hz: 8_000), 9)
    }

    /// Every preset, measured through the digital filters, lands where the
    /// analog prototypes `EqualizerCurve.responseDb` predicts — the same
    /// response the make-up is computed from and the screen draws.
    func testEveryPresetMatchesItsPredictedResponse() {
        let probes: [Double] = [40, 100, 300, 1_000, 3_000, 8_000]
        for preset in EqualizerPreset.selectable {
            let curve = EqualizerCurve.manual(bandsDb: preset.bandsDb)
            let processor = EqualizerProcessor()
            processor.setTuning(enabled: true, curve: curve, balance: 0)
            for hz in probes {
                let measured = correlationGainDb(processor, hz: hz)
                let predicted = Double(curve.responseDb(atHz: Float(hz)) + curve.preampDb)
                XCTAssertEqual(measured, predicted, accuracy: 0.35, "\(preset) at \(hz) Hz")
            }
        }
    }

    /// A preset switch is a glide, not a step: the first block after the change
    /// is part-way there, and the target is reached within about a tenth of a second.
    func testAPresetChangeGlidesToItsTarget() {
        let processor = EqualizerProcessor()
        processor.configure(sampleRate: sampleRate, channelCount: 2)
        processor.setTuning(enabled: true, curve: .manual(bandsDb: EqualizerPreset.flat.bandsDb), balance: 0)
        processor.flush()

        let curve = EqualizerCurve.manual(bandsDb: EqualizerPreset.bassBoost.bandsDb)
        processor.setTuning(enabled: true, curve: curve, balance: 0)
        let tone = DSPTestSignals.stereoSine(hz: 60, amplitude: 0.25, frames: 9_600, sampleRate: sampleRate)
        let output = DSPTestSignals.run(processor, tone, sampleRate: sampleRate, chunkFrames: 64, configure: false)

        let target = Double(curve.responseDb(atHz: 60) + curve.preampDb)
        let firstMs = DSPTestSignals.decibels(DSPTestSignals.rms(of: output, channel: 0, channelCount: 2, from: 0, to: 800) /
                                              DSPTestSignals.rms(of: tone, channel: 0, channelCount: 2, from: 0, to: 800))
        let late = DSPTestSignals.decibels(DSPTestSignals.rms(of: output, channel: 0, channelCount: 2, from: 7_200, to: 9_600) /
                                           DSPTestSignals.rms(of: tone, channel: 0, channelCount: 2, from: 7_200, to: 9_600))
        XCTAssertLessThan(abs(firstMs), abs(target) - 0.5, "the first 16 ms should still be on the way (target \(target) dB)")
        XCTAssertEqual(late, target, accuracy: 0.4)
    }

    /// Balance trims one side and never boosts the other.
    func testBalanceTrimsOneSideOnly() {
        let processor = EqualizerProcessor()
        processor.apply(EqualizerSettings(isEnabled: true, mode: .manual, balance: 0.5))
        let tone = DSPTestSignals.stereoSine(hz: 1_000, amplitude: 0.5, frames: 4_800, sampleRate: sampleRate)
        let output = DSPTestSignals.run(processor, tone, sampleRate: sampleRate)
        XCTAssertEqual(DSPTestSignals.rms(of: output, channel: 0, channelCount: 2) /
                       DSPTestSignals.rms(of: tone, channel: 0, channelCount: 2), 0.5, accuracy: 0.001)
        XCTAssertEqual(DSPTestSignals.rms(of: output, channel: 1, channelCount: 2) /
                       DSPTestSignals.rms(of: tone, channel: 1, channelCount: 2), 1, accuracy: 0.001)
    }

    /// Mono has no sides to balance: the trim applies the make-up only.
    func testBalanceIsIgnoredForMono() {
        let processor = EqualizerProcessor()
        processor.apply(EqualizerSettings(isEnabled: true, mode: .manual, balance: -1))
        let tone = (0..<4_800).map { Float(0.5 * sin(2 * .pi * 1_000 * Double($0) / sampleRate)) }
        let output = DSPTestSignals.run(processor, tone, channelCount: 1, sampleRate: sampleRate)
        XCTAssertEqual(output, tone, "flat curve, balance ignored: mono passes through")
    }

    func testTheSettingsSideReportsWhatItIsAimingAt() {
        let processor = EqualizerProcessor()
        XCTAssertFalse(processor.isEnabled)
        let settings = EqualizerSettings(isEnabled: true, mode: .manual, balance: 0.3, bandsDb: EqualizerPreset.jazz.bandsDb)
        processor.apply(settings)
        XCTAssertTrue(processor.isEnabled)
        XCTAssertEqual(processor.targetCurve, settings.curve)
        XCTAssertEqual(processor.targetBalance, 0.3)
        processor.setTuning(enabled: false, curve: settings.curve, balance: 0.3)
        XCTAssertFalse(processor.isEnabled)
        XCTAssertEqual(processor.targetCurve, .flat)
        XCTAssertEqual(processor.targetBalance, 0)
    }

    // ---- Helpers ----------------------------------------------------------------

    private func rmsGainDb(_ settings: EqualizerSettings, hz: Double) -> Double {
        let processor = EqualizerProcessor()
        processor.apply(settings)
        let tone = DSPTestSignals.stereoSine(hz: hz, amplitude: 0.25, frames: frames, sampleRate: sampleRate)
        let output = DSPTestSignals.run(processor, tone, sampleRate: sampleRate)
        return DSPTestSignals.decibels(DSPTestSignals.rms(of: output, channel: 0, channelCount: 2, from: settle) /
                                       DSPTestSignals.rms(of: tone, channel: 0, channelCount: 2, from: settle))
    }

    private func correlationGainDb(_ processor: EqualizerProcessor, hz: Double) -> Double {
        let tone = DSPTestSignals.stereoSine(hz: hz, amplitude: 0.25, frames: frames, sampleRate: sampleRate)
        let output = DSPTestSignals.run(processor, tone, sampleRate: sampleRate)
        return DSPTestSignals.decibels(
            DSPTestSignals.amplitude(of: output, channel: 0, channelCount: 2, hz: hz, sampleRate: sampleRate, settleFrames: settle) /
                DSPTestSignals.amplitude(of: tone, channel: 0, channelCount: 2, hz: hz, sampleRate: sampleRate, settleFrames: settle)
        )
    }
}
