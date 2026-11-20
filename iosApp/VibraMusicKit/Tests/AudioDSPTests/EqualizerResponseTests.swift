import XCTest
@testable import AudioDSP

/// What the equaliser actually does to a signal. Ported from Android's
/// `EqualizerProcessorTest`.
///
/// The risk this covers is not that the code throws — it is that a filter is
/// quietly the wrong shape. A state-variable section with a mistyped output mix
/// still runs, still sounds like *something*, and is indistinguishable by ear
/// from one that is correct until you go looking for the decibels you asked
/// for. So every test here measures: a sine goes in, its amplitude is read out
/// of the result by correlation at the frequency it was generated at, and the
/// gain is compared against what the curve promised.
final class EqualizerResponseTests: XCTestCase {

    static let sampleRate = 48_000.0
    /// Two seconds, so every frequency under test holds whole cycles in the window.
    static let toneFrames = 96_000
    /// Half a second of run-up, discarded: the filters need a moment to ring up.
    static let settleFrames = 24_000
    /// Well below full scale (in 16-bit units), so a boost under test has somewhere to go.
    static let amplitude = 8_000.0
    static let boostDb: Float = 6
    static let toleranceDb = 0.4
    /// The tilt pair's shelves overlap slightly, so their ends read a touch shy.
    static let tiltToleranceDb = 0.8

    func testABandLiftsItsOwnCentreByTheDecibelsItWasGiven() {
        // The five interior bands are bells, and a bell's gain at its centre is
        // the gain it was set to.
        for band in 1..<(EqualizerLayout.manualCount - 1) {
            XCTAssertEqual(measureBand(band, gainDb: Self.boostDb), Double(Self.boostDb),
                           accuracy: Self.toleranceDb, "band \(band) at +\(Self.boostDb) dB")
        }
    }

    func testABandCutsItsOwnCentreByTheDecibelsItWasGiven() {
        for band in 1..<(EqualizerLayout.manualCount - 1) {
            XCTAssertEqual(measureBand(band, gainDb: -Self.boostDb), Double(-Self.boostDb),
                           accuracy: Self.toleranceDb, "band \(band) at -\(Self.boostDb) dB")
        }
    }

    /// The two end bands are shelves, not bells. A shelf's labelled frequency is
    /// its corner, which is the half-way point of its travel, so 60 Hz reads
    /// +3 dB when the slider says +6 and the full +6 arrives below it.
    func testTheEndBandsAreShelvesHalfWayUpAtTheirCornerAndAllTheWayPastIt() {
        let low = Double(EqualizerLayout.manualBandsHz[0])
        XCTAssertEqual(measureBand(0, gainDb: Self.boostDb, atHz: low), Double(Self.boostDb) / 2,
                       accuracy: Self.toleranceDb, "60 Hz corner")
        XCTAssertEqual(measureBand(0, gainDb: Self.boostDb, atHz: 20), Double(Self.boostDb),
                       accuracy: Self.toleranceDb, "20 Hz shelf")

        let high = Double(EqualizerLayout.manualBandsHz.last!)
        let top = EqualizerLayout.manualCount - 1
        XCTAssertEqual(measureBand(top, gainDb: Self.boostDb, atHz: high), Double(Self.boostDb) / 2,
                       accuracy: Self.toleranceDb, "14 kHz corner")
    }

    /// The pad's horizontal axis: left warm, right bright, by equal amounts.
    func testTheTonePadTiltsTheSpectrumWithoutMovingItsMiddle() {
        let bright = EqualizerCurve.tone(x: EqualizerLayout.toneSteps, y: 0, focused: false)
        let corner = Double(Float(EqualizerLayout.toneSteps) * EqualizerLayout.toneDbPerStep)

        let processor = EqualizerProcessor()
        processor.setTuning(enabled: true, curve: bright, balance: 0)
        let lowEnd = measure(processor, hz: 60) - Double(bright.preampDb)
        let highEnd = measure(processor, hz: 12_000) - Double(bright.preampDb)

        XCTAssertEqual(lowEnd, -corner, accuracy: Self.tiltToleranceDb, "bass cut at x=+5")
        XCTAssertEqual(highEnd, corner, accuracy: Self.tiltToleranceDb, "treble lifted at x=+5")
    }

    /// And its vertical one, which only ever touches the middle.
    func testTheTonePadsContourMovesTheMidsAndLeavesTheEndsAlone() {
        let forward = EqualizerCurve.tone(x: 0, y: EqualizerLayout.toneSteps, focused: true)
        let processor = EqualizerProcessor()
        processor.setTuning(enabled: true, curve: forward, balance: 0)

        let mids = measure(processor, hz: 1_000) - Double(forward.preampDb)
        let bass = measure(processor, hz: 60) - Double(forward.preampDb)

        let expected = Double(Float(EqualizerLayout.toneSteps) * EqualizerLayout.toneDbPerStep)
        XCTAssertEqual(mids, expected, accuracy: Self.toleranceDb, "1 kHz lifted")
        XCTAssertLessThan(abs(bass), 0.5, "60 Hz should be left alone, was \(bass) dB")
    }

    /// Focused is narrower than Broad, and that is the whole of the difference.
    func testFocusedIsNarrowerThanBroadAtTheSameSetting() {
        let steps = EqualizerLayout.toneSteps
        let broadCurve = EqualizerCurve.tone(x: 0, y: steps, focused: false)
        let focusedCurve = EqualizerCurve.tone(x: 0, y: steps, focused: true)
        let broad = EqualizerProcessor()
        broad.setTuning(enabled: true, curve: broadCurve, balance: 0)
        let focused = EqualizerProcessor()
        focused.setTuning(enabled: true, curve: focusedCurve, balance: 0)

        // An octave below the 1 kHz centre, where the two skirts are furthest
        // apart: the wide bell is still lifting and the narrow one has let go.
        let broadSkirt = measure(broad, hz: 500) - Double(broadCurve.preampDb)
        let focusedSkirt = measure(focused, hz: 500) - Double(focusedCurve.preampDb)
        XCTAssertGreaterThan(broadSkirt, focusedSkirt + 1.5,
                             "broad (\(broadSkirt) dB) should reach further than focused (\(focusedSkirt) dB)")
    }

    func testBalanceSilencesTheSideItIsPushedAwayFrom() {
        let processor = EqualizerProcessor()
        processor.setTuning(enabled: true, curve: .manual(bandsDb: EqualizerPreset.flat.bandsDb), balance: -1)
        let output = DSPTestSignals.quantized16(run(processor, tone(hz: 1_000)))

        let right = stride(from: 1, to: output.count, by: 2).map { abs(Int(output[$0])) }.max()!
        let left = stride(from: 0, to: output.count, by: 2).map { abs(Int(output[$0])) }.max()!
        XCTAssertEqual(right, 0, "hard left should mute the right channel")
        XCTAssertGreaterThan(left, 7_000, "hard left should leave the left channel alone, peaked at \(left)")
    }

    /// The make-up attenuation exists so that boosting cannot run the signal
    /// into the top of a 16-bit sample. Every band up as far as it goes is the
    /// worst case there is.
    func testBoostingEveryBandAtOnceDoesNotClip() {
        let processor = EqualizerProcessor()
        let bands = [Float](repeating: EqualizerLayout.manualRangeDb, count: EqualizerLayout.manualCount)
        processor.setTuning(enabled: true, curve: .manual(bandsDb: bands), balance: 0)

        let output = DSPTestSignals.quantized16(run(processor, tone(hz: 400, amplitude: 24_000)))
        let peak = output.map { abs(Int($0)) }.max()!
        XCTAssertLessThanOrEqual(peak, 24_200, "output peaked at \(peak), above what went in")
    }

    func testASwitchedOffEqualizerHandsTheSignalBackUntouched() {
        let processor = EqualizerProcessor()
        processor.setTuning(enabled: false, curve: .manual(bandsDb: EqualizerPreset.rock.bandsDb), balance: 0.5)
        let input = tone(hz: 1_000)
        XCTAssertEqual(run(processor, input), input)
    }

    /// Switching off mid-track glides down rather than cutting, so the buffers
    /// either side of the change are neither identical nor silent — but once
    /// the glide lands, the passthrough has to be exact again. A processor that
    /// settled a hair off flat would sit there altering every sample it touched
    /// for the rest of the session.
    func testOnceTheSwitchOffHasGlidedDownThePassthroughIsExactAgain() {
        let processor = EqualizerProcessor()
        processor.setTuning(enabled: true, curve: .manual(bandsDb: EqualizerPreset.bassBoost.bandsDb), balance: 0)
        processor.configure(sampleRate: Self.sampleRate, channelCount: 2)
        processor.flush()

        let chunk = tone(hz: 1_000, frames: 4_096)
        let first = drain(processor, chunk)
        XCTAssertNotEqual(first, chunk, "bass boost should change the signal")
        processor.setTuning(enabled: false, curve: .manual(bandsDb: EqualizerPreset.flat.bandsDb), balance: 0)
        let gliding = drain(processor, chunk)
        XCTAssertNotEqual(gliding, chunk, "switching off should glide, not cut")
        // A second of audio is far longer than the glide needs.
        for _ in 0..<12 { _ = drain(processor, chunk) }
        XCTAssertEqual(drain(processor, chunk), chunk)
    }

    // ---- Harness -----------------------------------------------------------

    /// Sets one band and reports what the cascade did at [atHz], net of make-up.
    private func measureBand(_ band: Int, gainDb: Float, atHz: Double? = nil) -> Double {
        var bands = [Float](repeating: 0, count: EqualizerLayout.manualCount)
        bands[band] = gainDb
        let curve = EqualizerCurve.manual(bandsDb: bands)
        let processor = EqualizerProcessor()
        processor.setTuning(enabled: true, curve: curve, balance: 0)
        return measure(processor, hz: atHz ?? Double(EqualizerLayout.manualBandsHz[band])) - Double(curve.preampDb)
    }

    /// Gain in decibels at [hz], measured rather than predicted.
    private func measure(_ processor: EqualizerProcessor, hz: Double) -> Double {
        let input = tone(hz: hz)
        let output = run(processor, input)
        let settle = Self.settleFrames
        let rate = Self.sampleRate
        return DSPTestSignals.decibels(
            DSPTestSignals.amplitude(of: output, channel: 0, channelCount: 2, hz: hz, sampleRate: rate, settleFrames: settle) /
                DSPTestSignals.amplitude(of: input, channel: 0, channelCount: 2, hz: hz, sampleRate: rate, settleFrames: settle)
        )
    }

    private func tone(hz: Double, amplitude: Double = amplitude, frames: Int = toneFrames) -> [Float] {
        DSPTestSignals.stereoTone16(hz: hz, amplitude: amplitude, frames: frames, sampleRate: Self.sampleRate)
    }

    private func run(_ processor: EqualizerProcessor, _ input: [Float]) -> [Float] {
        DSPTestSignals.run(processor, input, sampleRate: Self.sampleRate)
    }

    private func drain(_ processor: EqualizerProcessor, _ input: [Float]) -> [Float] {
        DSPTestSignals.run(processor, input, sampleRate: Self.sampleRate, configure: false)
    }
}
