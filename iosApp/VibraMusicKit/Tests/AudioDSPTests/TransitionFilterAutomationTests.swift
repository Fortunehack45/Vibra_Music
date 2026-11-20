import XCTest
@testable import AudioDSP

/// The Automix transition filter as a crossfade drives it: set, swept, parked.
final class TransitionFilterAutomationTests: XCTestCase {

    private let sampleRate = 44_100.0

    func testCutoffsAreClampedToTheirRanges() {
        let filter = TransitionFilterProcessor()
        filter.setCutoffs(lowPassHz: 1, highPassHz: 9_000)
        XCTAssertEqual(filter.targetCutoffs.lowPassHz, 10)
        XCTAssertEqual(filter.targetCutoffs.highPassHz, TransitionFilterProcessor.maxHighPassHz)
        filter.setCutoffs(lowPassHz: 50_000, highPassHz: 0)
        XCTAssertEqual(filter.targetCutoffs.lowPassHz, TransitionFilterProcessor.openHz)
        XCTAssertEqual(filter.targetCutoffs.highPassHz, TransitionFilterProcessor.offHz)
    }

    /// A NaN cutoff would poison the filter state for the rest of the item.
    func testANaNCutoffMeansNotFiltering() {
        let filter = TransitionFilterProcessor()
        filter.setCutoffs(lowPassHz: .nan, highPassHz: .nan)
        XCTAssertEqual(filter.targetCutoffs.lowPassHz, TransitionFilterProcessor.openHz)
        XCTAssertEqual(filter.targetCutoffs.highPassHz, TransitionFilterProcessor.offHz)
        XCTAssertFalse(filter.isFiltering)
    }

    func testIsFilteringCoversTheTargetAndTheGlideBack() {
        let filter = TransitionFilterProcessor()
        filter.configure(sampleRate: sampleRate, channelCount: 2)
        XCTAssertFalse(filter.isFiltering)

        filter.setCutoffs(lowPassHz: 400, highPassHz: TransitionFilterProcessor.offHz)
        XCTAssertTrue(filter.isFiltering)
        let noise = (0..<(8_192 * 2)).map { Float(($0 * 7_919) % 201 - 100) / 200 }
        _ = DSPTestSignals.run(filter, noise, sampleRate: sampleRate, configure: false)

        filter.open()
        _ = DSPTestSignals.run(filter, Array(noise.prefix(128)), sampleRate: sampleRate, configure: false)
        XCTAssertTrue(filter.isFiltering, "still gliding back open")
        // The glide is geometric and parks within 1 Hz of fully open: about a third of a second from 400 Hz.
        var glidedFrames = 64
        while filter.isFiltering && glidedFrames < Int(sampleRate / 2) {
            _ = DSPTestSignals.run(filter, Array(noise.prefix(2_048)), sampleRate: sampleRate, configure: false)
            glidedFrames += 1_024
        }
        XCTAssertFalse(filter.isFiltering, "parked once the glide lands")
        XCTAssertGreaterThan(glidedFrames, Int(sampleRate / 10), "the glide back is not a snap")
        XCTAssertEqual(DSPTestSignals.run(filter, noise, sampleRate: sampleRate, configure: false), noise,
                       "a parked filter hands samples back untouched")
    }

    /// A sweep is automation, not a switch: closing a low-pass over a bright
    /// tone takes the level down progressively rather than in one step.
    func testClosingTheLowPassSweepsRatherThanSteps() {
        let filter = TransitionFilterProcessor()
        filter.configure(sampleRate: sampleRate, channelCount: 2)
        filter.setCutoffs(lowPassHz: 300, highPassHz: TransitionFilterProcessor.offHz)
        let tone = DSPTestSignals.stereoSine(hz: 3_000, amplitude: 0.5, frames: 8_820, sampleRate: sampleRate)
        let output = DSPTestSignals.run(filter, tone, sampleRate: sampleRate, chunkFrames: 64, configure: false)

        func level(_ from: Int, _ to: Int) -> Double {
            DSPTestSignals.rms(of: output, channel: 0, channelCount: 2, from: from, to: to) /
                DSPTestSignals.rms(of: tone, channel: 0, channelCount: 2, from: from, to: to)
        }
        let early = level(0, 441)
        let middle = level(1_323, 1_764)
        let late = level(7_938, 8_820)
        XCTAssertGreaterThan(early, middle)
        XCTAssertGreaterThan(middle, late)
        XCTAssertGreaterThan(early, 0.5, "the first 10 ms should still be mostly open")
        XCTAssertLessThan(late, 0.02, "three octaves above a 24 dB/oct cutoff, once arrived")
    }

    /// Configure and flush snap to the target, as Android's do, so a filter set
    /// before audio starts is already in place for the first sample.
    func testConfigureSnapsToTheTarget() {
        let filter = TransitionFilterProcessor()
        filter.setCutoffs(lowPassHz: TransitionFilterProcessor.openHz, highPassHz: 1_000)
        filter.configure(sampleRate: sampleRate, channelCount: 1)
        let tone = (0..<4_410).map { Float(0.5 * sin(2 * .pi * 60 * Double($0) / sampleRate)) }
        let output = DSPTestSignals.run(filter, tone, channelCount: 1, sampleRate: sampleRate, configure: false)
        let level = DSPTestSignals.rms(of: output, channel: 0, channelCount: 1, from: 441) /
            DSPTestSignals.rms(of: tone, channel: 0, channelCount: 1, from: 441)
        XCTAssertLessThan(level, 0.001, "60 Hz under a 1 kHz 24 dB/oct high-pass, from the start")
    }

    /// Butterworth: -3 dB at the cutoff, whichever side.
    func testTheResponseIsThreeDecibelsDownAtTheCutoff() {
        for (low, high, probe) in [(Float(2_000), TransitionFilterProcessor.offHz, 2_000.0),
                                   (TransitionFilterProcessor.openHz, Float(500), 500.0)] {
            let filter = TransitionFilterProcessor()
            filter.setCutoffs(lowPassHz: low, highPassHz: high)
            let tone = DSPTestSignals.stereoSine(hz: probe, amplitude: 0.5, frames: 44_100, sampleRate: sampleRate)
            let output = DSPTestSignals.run(filter, tone, sampleRate: sampleRate)
            let gain = DSPTestSignals.decibels(
                DSPTestSignals.amplitude(of: output, channel: 0, channelCount: 2, hz: probe, sampleRate: sampleRate, settleFrames: 11_025) /
                    DSPTestSignals.amplitude(of: tone, channel: 0, channelCount: 2, hz: probe, sampleRate: sampleRate, settleFrames: 11_025))
            XCTAssertEqual(gain, -3, accuracy: 0.3, "cutoff at \(probe) Hz")
        }
    }

    func testResetParksTheFilter() {
        let filter = TransitionFilterProcessor()
        filter.setCutoffs(lowPassHz: 500, highPassHz: 300)
        filter.reset()
        XCTAssertFalse(filter.isFiltering)
        XCTAssertEqual(filter.targetCutoffs.lowPassHz, TransitionFilterProcessor.openHz)
    }

    /// The crossfade controller's view of the two filters: `open()` parks both.
    func testTransitionFiltersOpenParksBothSides() {
        final class Recorder: TransitionFilters {
            var calls: [String] = []
            func incoming(lowPassHz: Float, highPassHz: Float) { calls.append("in \(lowPassHz) \(highPassHz)") }
            func outgoing(lowPassHz: Float, highPassHz: Float) { calls.append("out \(lowPassHz) \(highPassHz)") }
        }
        let recorder = Recorder()
        recorder.open()
        XCTAssertEqual(recorder.calls, ["in 20000.0 20.0", "out 20000.0 20.0"])
        NoTransitionFilters().open() // a no-op, and must not trap
    }
}
