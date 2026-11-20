import XCTest
@testable import AudioDSP

/// The spatial-audio toggle: mid/side widening plus a delayed, dulled cross-feed.
/// PORTING.md's done-test is "the toggle audibly widens the stereo image".
final class StereoWidenTests: XCTestCase {

    private let sampleRate = 44_100.0

    /// Before the cross-feed delay line has anything in it, the output is pure
    /// mid/side arithmetic: mid kept, side × 2.5, all × 0.82.
    func testMidIsKeptAndSideIsWidenedTwoAndAHalfTimes() {
        let spatial = enabledSpatial()
        let frames = 600 // under the 662-frame delay at 44.1 kHz
        var input = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            input[frame * 2] = Float(sin(Double(frame) * 0.05)) * 0.6
            input[frame * 2 + 1] = Float(cos(Double(frame) * 0.021)) * 0.3
        }
        let output = DSPTestSignals.run(spatial, input, sampleRate: sampleRate, configure: false)
        for frame in 0..<frames {
            let left = input[frame * 2], right = input[frame * 2 + 1]
            let mid = (left + right) * 0.5
            let side = (left - right) * 0.5 * 2.5
            XCTAssertEqual(output[frame * 2], (mid + side) * 0.82, accuracy: 1e-6)
            XCTAssertEqual(output[frame * 2 + 1], (mid - side) * 0.82, accuracy: 1e-6)
        }
    }

    /// Measured the way a listener would hear it: the side (difference) signal
    /// grows by about the width gain after make-up, the mid (sum) signal doesn't.
    func testTheSideSignalGrowsAndTheMidSignalDoesNot() {
        let spatial = enabledSpatial()
        let frames = 44_100
        var input = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            // Left and right partly correlated, at 10 kHz where the cross-feed low-pass has let go.
            let a = Float(sin(2 * .pi * 10_000 * Double(frame) / sampleRate))
            input[frame * 2] = 0.4 * a
            input[frame * 2 + 1] = 0.2 * a
        }
        let output = DSPTestSignals.run(spatial, input, sampleRate: sampleRate, configure: false)

        func midSide(_ samples: [Float]) -> (mid: Double, side: Double) {
            var mid = 0.0, side = 0.0
            for frame in 4_410..<frames {
                let m = Double(samples[frame * 2] + samples[frame * 2 + 1]) / 2
                let s = Double(samples[frame * 2] - samples[frame * 2 + 1]) / 2
                mid += m * m
                side += s * s
            }
            return (mid.squareRoot(), side.squareRoot())
        }
        let before = midSide(input)
        let after = midSide(output)
        let sideGain = after.side / before.side
        let midGain = after.mid / before.mid
        XCTAssertEqual(sideGain, 2.5 * 0.82, accuracy: 0.25, "side should grow by width × make-up")
        XCTAssertEqual(midGain, 0.82, accuracy: 0.12, "mid should only take the make-up")
        XCTAssertGreaterThan(sideGain / midGain, 2.2, "the image must get wider")
    }

    /// The cross-feed arrives 15 ms late: 662 frames at 44.1 kHz, rounded the way Android rounds.
    func testTheCrossFeedArrivesFifteenMillisecondsLate() {
        let spatial = enabledSpatial()
        let frames = 700
        var input = [Float](repeating: 0, count: frames * 2)
        input[0] = 1 // left impulse
        let output = DSPTestSignals.run(spatial, input, sampleRate: sampleRate, configure: false)

        XCTAssertEqual(output[1], (0.5 - 1.25) * 0.82, accuracy: 1e-6, "the widened impulse itself")
        for frame in 1..<662 {
            XCTAssertEqual(output[frame * 2 + 1], 0, "nothing reaches the right channel before the delay, frame \(frame)")
        }
        XCTAssertEqual(output[662 * 2 + 1], 0.3 * 0.2 * 0.82, accuracy: 1e-6, "low-passed cross-feed lands at frame 662")
    }

    func testMonoAndMultichannelPassThroughEvenWhenEnabled() {
        for channels in [1, 6] {
            let spatial = SpatialAudioProcessor()
            spatial.isEnabled = true
            spatial.configure(sampleRate: sampleRate, channelCount: channels)
            XCTAssertFalse(spatial.appliesToConfiguredFormat)
            let input = (0..<(256 * channels)).map { Float($0 % 17) * 0.01 }
            XCTAssertEqual(DSPTestSignals.run(spatial, input, channelCount: channels, sampleRate: sampleRate, configure: false),
                           input, "\(channels) channels")
        }
    }

    func testTogglingTakesEffectAtTheNextBlock() {
        let spatial = SpatialAudioProcessor()
        spatial.configure(sampleRate: sampleRate, channelCount: 2)
        let input = DSPTestSignals.stereoSine(hz: 440, amplitude: 0.5, frames: 256, sampleRate: sampleRate)
            .enumerated().map { $0.offset % 2 == 0 ? $0.element : -$0.element }
        XCTAssertEqual(DSPTestSignals.run(spatial, input, sampleRate: sampleRate, configure: false), input)
        spatial.isEnabled = true
        XCTAssertTrue(spatial.isEnabled)
        XCTAssertNotEqual(DSPTestSignals.run(spatial, input, sampleRate: sampleRate, configure: false), input)
    }

    private func enabledSpatial() -> SpatialAudioProcessor {
        let spatial = SpatialAudioProcessor()
        spatial.configure(sampleRate: sampleRate, channelCount: 2)
        spatial.isEnabled = true
        XCTAssertTrue(spatial.appliesToConfiguredFormat)
        return spatial
    }
}
