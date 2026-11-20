import XCTest
@testable import Automix

/// Beat This! post-processing, and the model itself through ONNX Runtime.
final class BeatTrackerTests: XCTestCase {

    // MARK: - Peak picking

    func testPeaksAreLocalMaximaThatArePositive() {
        var logits = [Float](repeating: -1, count: 40)
        logits[5] = 2
        logits[20] = 3
        logits[22] = 1 // inside 20's seven-frame window, and lower: not a peak
        logits[35] = -0.5 // a maximum, but not positive
        XCTAssertEqual(BeatTracker.pickPeaks(logits).map { $0.rounded() }, [5, 20])
    }

    func testAdjacentTiedFramesCollapseOntoTheirMean() {
        var logits = [Float](repeating: -1, count: 30)
        logits[10] = 2
        logits[11] = 2
        let peaks = BeatTracker.pickPeaks(logits)
        XCTAssertEqual(peaks.count, 1)
        // Mean 10.5 rounds half up to 11, then the parabola pulls it back toward the plateau.
        XCTAssertEqual(peaks[0], 10.5, accuracy: 0.5)
    }

    func testPeaksAreRefinedToSubFrameResolution() {
        var logits = [Float](repeating: -2, count: 20)
        logits[9] = 1
        logits[10] = 2
        logits[11] = 1.5
        let peak = BeatTracker.pickPeaks(logits)[0]
        // Parabola through (9,1) (10,2) (11,1.5): vertex at 10 + 0.5·(1−1.5)/(1−4+1.5) = 10.1667.
        XCTAssertEqual(peak, 10 + 1.0 / 6.0, accuracy: 1e-9)
    }

    // MARK: - Tempo and confidence

    private func grid(bpm: Double, count: Int, start: Double = 1) -> [Double] {
        (0..<count).map { start + Double($0) * 60 / bpm }
    }

    func testTempoIsTheMedianIntervalAndSurvivesDroppedBeats() {
        XCTAssertEqual(BeatTracker.tempoFromBeats(grid(bpm: 128, count: 32)), 128, accuracy: 1e-9)
        var holes = grid(bpm: 128, count: 32)
        holes.remove(at: 10)
        holes.remove(at: 20)
        XCTAssertEqual(BeatTracker.tempoFromBeats(holes), 128, accuracy: 1e-9)
    }

    func testImplausibleOrThinGridsHaveNoTempo() {
        XCTAssertEqual(BeatTracker.tempoFromBeats(grid(bpm: 128, count: 7)), 0, "fewer than eight beats")
        XCTAssertEqual(BeatTracker.tempoFromBeats(grid(bpm: 300, count: 32)), 0)
        XCTAssertEqual(BeatTracker.tempoFromBeats(grid(bpm: 30, count: 32)), 0)
    }

    func testConfidenceRewardsRegularityAndDecisivenessButStopsShortOfCertainty() {
        let beats = grid(bpm: 120, count: 32)
        let decisive = BeatTracker.gridConfidence(beats, peakLogits: [Double](repeating: 6, count: 32))
        XCTAssertEqual(decisive, 0.95, accuracy: 1e-9, "capped: a model is evidence, not proof")
        let hesitant = BeatTracker.gridConfidence(beats, peakLogits: [Double](repeating: 0, count: 32))
        XCTAssertLessThan(hesitant, decisive)
        var ragged = beats
        for index in stride(from: 1, to: ragged.count, by: 2) { ragged[index] += 0.12 }
        XCTAssertLessThan(BeatTracker.gridConfidence(ragged, peakLogits: [Double](repeating: 6, count: 32)), decisive)
        XCTAssertEqual(BeatTracker.gridConfidence(Array(beats.prefix(5)), peakLogits: [1]), 0)
    }

    func testDownbeatsAreSnappedOntoTheBeatGrid() throws {
        // Fifty frames per second: beats every 25 frames, downbeat head peaking a frame late.
        var beatLogits = [Float](repeating: -3, count: 500)
        var downbeatLogits = [Float](repeating: -3, count: 500)
        for frame in stride(from: 10, to: 500, by: 25) { beatLogits[frame] = 4 }
        for frame in stride(from: 11, to: 500, by: 100) { downbeatLogits[frame] = 3 }
        let grid = try XCTUnwrap(BeatTracker.grid(beatLogits: beatLogits, downbeatLogits: downbeatLogits, offsetSeconds: 60))
        XCTAssertEqual(grid.bpm, 120, accuracy: 1e-6)
        XCTAssertEqual(grid.beatInterval, 0.5, accuracy: 1e-9)
        XCTAssertEqual(grid.firstBeat, 60.2, accuracy: 1e-9, "stated on the full track's timeline")
        XCTAssertEqual(grid.downbeats.count, 5)
        XCTAssertTrue(grid.downbeats.allSatisfy { grid.beats.contains($0) }, "every downbeat is a beat")
        XCTAssertEqual(grid.downbeats.first ?? 0, 60.2, accuracy: 1e-9)
        XCTAssertEqual(grid.beatConfidence, 0.95, accuracy: 1e-9)
    }

    // MARK: - The model

    func testWindowCostsExactlyOneInference() {
        XCTAssertEqual(BeatTracker.windowSeconds, 29.76, accuracy: 1e-9)
    }

    func testTheShippedModelTracksADrumKit() throws {
        let tracker = BeatTracker(threads: { 2 })
        XCTAssertTrue(tracker.isAvailable, "the model ships as a module resource and ONNX Runtime is linked")
        let samples = SyntheticAudio.drumTrack(bpm: 96, seconds: 30, sampleRate: MelSpectrogram.sampleRate)

        let grid = try XCTUnwrap(tracker.track(samples))
        XCTAssertEqual(grid.bpm, 96, accuracy: 96 * 0.02)
        XCTAssertGreaterThanOrEqual(grid.beats.count, 8)
        XCTAssertTrue(grid.downbeats.allSatisfy { grid.beats.contains($0) })
        XCTAssertTrue((0.35...0.95).contains(grid.beatConfidence))

        let shifted = try XCTUnwrap(tracker.track(samples, offsetSeconds: 100))
        XCTAssertEqual(shifted.firstBeat, grid.firstBeat + 100, accuracy: 1e-9)
        tracker.release()
    }

    func testAMissingModelIsNoGridNotAnError() {
        let tracker = BeatTracker(modelURL: URL(fileURLWithPath: "/nonexistent/beat.onnx"), threads: { 1 })
        XCTAssertFalse(tracker.isAvailable)
        XCTAssertNil(tracker.track(SyntheticAudio.drumTrack(bpm: 120, seconds: 12, sampleRate: MelSpectrogram.sampleRate)))
        // The tracker alone would say nil for an unconfigured model, so the front end is asked directly.
        XCTAssertNil(MelSpectrogram.compute([Float](repeating: 0, count: 100)), "shorter than one padded frame")
    }
}
