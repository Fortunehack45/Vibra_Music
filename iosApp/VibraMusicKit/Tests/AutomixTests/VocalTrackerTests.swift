import XCTest
@testable import Automix

/// open-unmix vocal presence: the fixed-width input, the band reduction, and the model itself.
final class VocalTrackerTests: XCTestCase {

    func testShorterSpectrogramsArePaddedPerBinNotAppended() {
        let bins = 3
        let frames = 2
        // Channel-major, bin-major values 1...12 for 2 channels × 3 bins × 2 frames.
        let values = (1...12).map(Float.init)
        var buffer = [Float](repeating: -1, count: 2 * bins * VocalTracker.fixedFrames)
        buffer.withUnsafeMutableBufferPointer { VocalTracker.fillFixedFrames($0, values: values, bins: bins, frames: frames) }
        for row in 0..<(2 * bins) {
            XCTAssertEqual(buffer[row * VocalTracker.fixedFrames], values[row * frames])
            XCTAssertEqual(buffer[row * VocalTracker.fixedFrames + 1], values[row * frames + 1])
            XCTAssertEqual(buffer[row * VocalTracker.fixedFrames + 2], 0, "padding, not the next bin")
            XCTAssertEqual(buffer[row * VocalTracker.fixedFrames + VocalTracker.fixedFrames - 1], 0)
        }
    }

    func testTheCurveIsTheBandAveragedMaskOverRealFramesOnly() {
        let bins = VocalSpectrogram.bins
        let size = 2 * bins * VocalTracker.fixedFrames
        var mix = [Float](repeating: 1, count: size)
        var target = [Float](repeating: 0.25, count: size)
        // Frame 1: the target exceeds the mix, which clamps to 1; frame 2: a silent mix is skipped.
        for channel in 0..<2 {
            for bin in 0..<bins {
                let row = (channel * bins + bin) * VocalTracker.fixedFrames
                target[row + 1] = 3
                mix[row + 2] = 0
            }
        }
        let curve = mix.withUnsafeBufferPointer { mixPointer in
            target.withUnsafeBufferPointer { targetPointer in
                VocalTracker.reduceToBandCurve(mix: mixPointer, target: targetPointer, bins: bins, usableFrames: 3)
            }
        }
        XCTAssertEqual(curve.count, 3, "only the frames that carry audio")
        XCTAssertEqual(curve[0], 0.25, accuracy: 1e-6)
        XCTAssertEqual(curve[1], 1, accuracy: 1e-6)
        XCTAssertEqual(curve[2], 0, "no measurable mix, no vocal")
    }

    /// A sung-sounding line (a harmonic stack with vibrato), two seconds on and one off, over a kit.
    private func voiceOverDrums(seconds: Double, rate: Double) -> (voice: [Float], mix: [Float]) {
        var voice = [Float](repeating: 0, count: Int(seconds * rate))
        let notes = [220.0, 247, 262, 294, 330, 294, 262]
        var time = 0.5
        var note = 0
        while time < seconds - 2 {
            SyntheticAudio.addTone(into: &voice, frequency: notes[note % notes.count], start: time, seconds: 2, sampleRate: rate, gain: 0.15, vibrato: 0.012, harmonics: 12)
            time += 3
            note += 1
        }
        let drums = SyntheticAudio.drumTrack(bpm: 120, seconds: seconds, sampleRate: rate)
        return (voice, zip(voice, drums).map { $0 + $1 * 0.6 })
    }

    func testTheShippedModelHearsWhenTheVoiceIsThere() throws {
        let rate = 44_100.0
        let tracker = VocalTracker(threads: { 2 })
        XCTAssertTrue(tracker.isAvailable)
        let (voice, mix) = voiceOverDrums(seconds: 20, rate: rate)

        let curve = try XCTUnwrap(tracker.track(left: mix, right: mix, sampleRate: rate))
        XCTAssertEqual(curve.count, VocalSpectrogram.compute(left: mix, right: mix)?.frames)
        XCTAssertTrue(curve.allSatisfy { (0...1).contains($0) })

        var singing: [Float] = []
        var gaps: [Float] = []
        for (index, value) in curve.enumerated() {
            let time = Double(index) / VocalSpectrogram.frameRate
            guard time > 0.5 && time < 18.5 else { continue }
            let phase = (time - 0.5).truncatingRemainder(dividingBy: 3)
            if phase > 0.2 && phase < 1.8 { singing.append(value) } else if phase > 2.2 && phase < 2.8 { gaps.append(value) }
        }
        let singingMean = singing.reduce(0, +) / Float(singing.count)
        let gapMean = gaps.reduce(0, +) / Float(gaps.count)
        XCTAssertGreaterThan(singingMean, gapMean + 0.1, "vocal presence follows the line")

        let alone = try XCTUnwrap(tracker.track(left: voice, right: voice, sampleRate: rate))
        XCTAssertGreaterThan(Double(alone.max() ?? 0), TransitionPolicy.vocalActiveThreshold, "an unaccompanied line reads as singing")
        tracker.release()
    }

    func testWindowsWiderThanTheModelAreRefusedAndMissingModelsAnswerNil() {
        let rate = 44_100.0
        let tooLong = [Float](repeating: 0.01, count: Int(25 * rate))
        XCTAssertNil(VocalTracker(threads: { 1 }).track(left: tooLong, right: tooLong, sampleRate: rate))
        let missing = VocalTracker(modelURL: nil, threads: { 1 })
        XCTAssertFalse(missing.isAvailable)
        let short = [Float](repeating: 0.01, count: Int(5 * rate))
        XCTAssertNil(missing.track(left: short, right: short, sampleRate: rate))
    }
}
