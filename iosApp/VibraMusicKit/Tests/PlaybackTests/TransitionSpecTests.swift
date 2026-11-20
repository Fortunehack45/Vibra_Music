import XCTest
@testable import Playback

final class TransitionGainCurveTests: XCTestCase {
    func testEqualPowerPairSumsToConstantPower() {
        for step in 0...20 {
            let progress = Double(step) / 20
            let rise = TransitionGainCurve.equalPowerRise.gain(at: progress)
            let fall = TransitionGainCurve.equalPowerFall.gain(at: progress)
            XCTAssertEqual(rise * rise + fall * fall, 1, accuracy: 0.0001)
        }
        XCTAssertEqual(TransitionGainCurve.equalPowerRise.gain(at: 0), 0)
        XCTAssertEqual(TransitionGainCurve.equalPowerRise.gain(at: 1), 1, accuracy: 0.0001)
        XCTAssertEqual(TransitionGainCurve.equalPowerFall.gain(at: 0.5), Float(cos(Double.pi / 4)), accuracy: 0.0001)
    }

    func testProgressIsClampedOutsideTheTransition() {
        XCTAssertEqual(TransitionGainCurve.equalPowerRise.gain(at: -1), 0)
        XCTAssertEqual(TransitionGainCurve.linearFall.gain(at: 2), 0)
        XCTAssertEqual(TransitionGainCurve.linearRise.gain(at: 0.25), 0.25)
    }

    func testKeyframesInterpolateLinearlyAndHoldAtTheEnds() {
        let curve = TransitionGainCurve.keyframes([
            .init(progress: 0.8, gain: 1),
            .init(progress: 0.2, gain: 0),
            .init(progress: 0.5, gain: 0.9),
        ])
        XCTAssertEqual(curve.gain(at: 0), 0)
        XCTAssertEqual(curve.gain(at: 0.35), 0.45, accuracy: 0.0001)
        XCTAssertEqual(curve.gain(at: 0.65), 0.95, accuracy: 0.0001)
        XCTAssertEqual(curve.gain(at: 1), 1)
        XCTAssertEqual(TransitionGainCurve.keyframes([]).gain(at: 0.5), 1)
    }
}

final class TransitionSpecTests: XCTestCase {
    func testStandardCrossfadeEndsWithTheOutgoingTrack() {
        let spec = TransitionSpec.crossfade(endingAt: 200, overlap: 8)
        XCTAssertEqual(spec.startTime, 192)
        XCTAssertEqual(spec.endTime, 200)
        XCTAssertEqual(spec.incomingCueTime, 0)
        XCTAssertEqual(spec.incomingRate, 1)
        XCTAssertEqual(spec.outgoingGain, .equalPowerFall)
        XCTAssertEqual(spec.incomingGain, .equalPowerRise)
        XCTAssertEqual(spec.filters, .none)
        XCTAssertFalse(spec.isRealMix, "a plain fade is not advertised as a mix")
    }

    func testRealMixIsACueAStretchOrAFilteringStyle() {
        XCTAssertTrue(TransitionSpec(startTime: 0, overlap: 8, incomingCueTime: 12).isRealMix)
        XCTAssertTrue(TransitionSpec(startTime: 0, overlap: 8, incomingRate: 0.98).isRealMix)
        XCTAssertTrue(TransitionSpec(startTime: 0, overlap: 8, filters: .ride(.init(style: .djBlend, bassSwap: true))).isRealMix)
        XCTAssertTrue(TransitionSpec(startTime: 0, overlap: 8, filters: .ride(.init(style: .djFilter, filterSweep: 1))).isRealMix)
        XCTAssertFalse(TransitionSpec(startTime: 0, overlap: 8, filters: .ride(.init(style: .equalPower, vocalOverlap: 0.8))).isRealMix)
        XCTAssertFalse(TransitionSpec(startTime: 0, overlap: 8, filters: .ride(.init(style: .gapless))).isRealMix)
        let keyed = TransitionFilterAutomation.keyframes(
            incoming: [.init(progress: 0, cutoffs: .init(lowPassHz: 20_000, highPassHz: 800))],
            outgoing: []
        )
        XCTAssertTrue(TransitionSpec(startTime: 0, overlap: 8, filters: keyed).isRealMix)
    }

    func testNonsenseInputsAreSanitised() {
        let spec = TransitionSpec(startTime: 10, overlap: 4, incomingCueTime: -3, incomingRate: 0)
        XCTAssertEqual(spec.incomingCueTime, 0)
        XCTAssertEqual(spec.incomingRate, 1)
    }
}

final class TransitionFilterRideTests: XCTestCase {
    private let open = TransitionFilterCutoffs.openHz
    private let off = TransitionFilterCutoffs.offHz

    func testGlideIsGeometric() {
        XCTAssertEqual(TransitionFilterRide.glide(100, 10_000, 0), 100, accuracy: 0.001)
        XCTAssertEqual(TransitionFilterRide.glide(100, 10_000, 1), 10_000, accuracy: 0.01)
        XCTAssertEqual(TransitionFilterRide.glide(100, 10_000, 0.5), 1_000, accuracy: 0.01, "halfway in pitch, not in Hz")
        XCTAssertEqual(TransitionFilterRide.glide(100, 10_000, 3), 10_000, accuracy: 0.01)
    }

    /// The numbers the Android constants were tuned against (FILTER_SWEEP_SHAPE's comment).
    func testAFullFilterRideIsFrontLoaded() {
        let ride = TransitionFilterRide(style: .djFilter, filterSweep: 1)
        XCTAssertEqual(ride.cutoffs(at: 0).outgoing.lowPassHz, 7_000, accuracy: 1, "engages inside the presence range")
        XCTAssertEqual(ride.cutoffs(at: 0.05).outgoing.lowPassHz, 5_000, accuracy: 100, "crosses 5 kHz a twentieth of the way in")
        XCTAssertEqual(ride.cutoffs(at: 0.5).outgoing.lowPassHz, 1_050, accuracy: 60, "about 1 kHz at the midpoint")
        XCTAssertEqual(ride.cutoffs(at: 1).outgoing.lowPassHz, 300, accuracy: 1, "settles on a 300 Hz bed, not silence")
        XCTAssertEqual(ride.cutoffs(at: 0.5).outgoing.highPassHz, off)
    }

    /// ENTRY_SHAPE's comment: 772 Hz a sixth of the way in, 436 Hz at a third, open by 0.6.
    func testTheIncomingHighPassLingersInTheVoiceRange() {
        let ride = TransitionFilterRide(style: .djFilter, filterSweep: 1)
        XCTAssertEqual(ride.cutoffs(at: 0).incoming.highPassHz, 1_200, accuracy: 1)
        XCTAssertEqual(ride.cutoffs(at: 1.0 / 6).incoming.highPassHz, 772, accuracy: 3)
        XCTAssertEqual(ride.cutoffs(at: 1.0 / 3).incoming.highPassHz, 436, accuracy: 3)
        XCTAssertEqual(ride.cutoffs(at: 0.6).incoming.highPassHz, off, accuracy: 0.01)
        XCTAssertEqual(ride.cutoffs(at: 0.9).incoming.highPassHz, off, accuracy: 0.01)
        XCTAssertEqual(ride.cutoffs(at: 0.3).incoming.lowPassHz, open)
    }

    func testAPartialSweepStopsShortOfTheFloor() {
        let ride = TransitionFilterRide(style: .djFilter, filterSweep: 0.5)
        XCTAssertGreaterThan(ride.cutoffs(at: 1).outgoing.lowPassHz, 300)
        XCTAssertLessThan(ride.cutoffs(at: 1).outgoing.lowPassHz, open)
        let none = TransitionFilterRide(style: .djFilter, filterSweep: 0)
        XCTAssertTrue(none.cutoffs(at: 0.5).incoming.isOpen)
        XCTAssertTrue(none.cutoffs(at: 0.5).outgoing.isOpen)
    }

    func testTheBassChangesHandsOnceAtThePlannedBeat() {
        let ride = TransitionFilterRide(style: .djBlend, bassSwap: true, bassSwapFraction: 0.5)
        let before = ride.cutoffs(at: 0.3)
        XCTAssertGreaterThanOrEqual(before.incoming.highPassHz, 199, "the incoming low end is held out before the swap")
        XCTAssertEqual(before.outgoing.highPassHz, off, accuracy: 0.01, "the outgoing track keeps its bass until then")
        let after = ride.cutoffs(at: 0.7)
        XCTAssertEqual(after.outgoing.highPassHz, 200, accuracy: 0.5, "the outgoing bass is lifted after the swap")
        XCTAssertEqual(after.incoming.highPassHz, off, accuracy: 0.01, "and the incoming track has its own back")
        XCTAssertEqual(ride.cutoffs(at: 0.2).outgoing.lowPassHz, open, accuracy: 0.5, "the outgoing top stays open until 30%")
        XCTAssertEqual(ride.cutoffs(at: 1).outgoing.lowPassHz, 2_200, accuracy: 1)
    }

    func testAVocalClashDeepensTheBlendExit() {
        let calm = TransitionFilterRide(style: .djBlend, bassSwap: true, vocalOverlap: 0)
        let clash = TransitionFilterRide(style: .djBlend, bassSwap: true, vocalOverlap: 1)
        XCTAssertLessThan(clash.cutoffs(at: 1).outgoing.lowPassHz, calm.cutoffs(at: 1).outgoing.lowPassHz)
        XCTAssertEqual(clash.cutoffs(at: 1).outgoing.lowPassHz, 1_100, accuracy: 1)
        XCTAssertGreaterThan(clash.cutoffs(at: 0.2).incoming.highPassHz, calm.cutoffs(at: 0.2).incoming.highPassHz)
    }

    func testVocalSeparationOnlyActsOnAMeasuredCollision() {
        let none = TransitionFilterRide(style: .equalPower, vocalOverlap: 0)
        XCTAssertTrue(none.cutoffs(at: 0.5).outgoing.isOpen)
        XCTAssertTrue(none.cutoffs(at: 0.5).incoming.isOpen)
        let full = TransitionFilterRide(style: .equalPower, vocalOverlap: 1)
        XCTAssertEqual(full.cutoffs(at: 1).outgoing.lowPassHz, 1_600, accuracy: 1)
        XCTAssertEqual(full.cutoffs(at: 0).incoming.highPassHz, 700, accuracy: 1)
        let blendWithoutSwap = TransitionFilterRide(style: .djBlend, bassSwap: false, vocalOverlap: 1)
        XCTAssertEqual(blendWithoutSwap.cutoffs(at: 1).outgoing.lowPassHz, 1_600, accuracy: 1)
    }

    func testGaplessIsNeverFiltered() {
        let ride = TransitionFilterRide(style: .gapless, filterSweep: 1, vocalOverlap: 1)
        for progress in [0, 0.3, 0.7, 1] as [Float] {
            XCTAssertTrue(ride.cutoffs(at: progress).incoming.isOpen)
            XCTAssertTrue(ride.cutoffs(at: progress).outgoing.isOpen)
        }
    }

    func testKeyframedFiltersInterpolateInPitch() {
        let automation = TransitionFilterAutomation.keyframes(
            incoming: [
                .init(progress: 0, cutoffs: .init(lowPassHz: 20_000, highPassHz: 1_000)),
                .init(progress: 1, cutoffs: .init(lowPassHz: 20_000, highPassHz: 10)),
            ],
            outgoing: [.init(progress: 0.5, cutoffs: .init(lowPassHz: 500, highPassHz: 20))]
        )
        let mid = automation.cutoffs(at: 0.5)
        XCTAssertEqual(mid.incoming.highPassHz, 100, accuracy: 0.1, "sqrt(1000 × 10)")
        XCTAssertEqual(mid.outgoing.lowPassHz, 500)
        XCTAssertEqual(automation.cutoffs(at: 0).outgoing.lowPassHz, 500, "held before the first keyframe")
        XCTAssertTrue(TransitionFilterAutomation.none.cutoffs(at: 0.5).incoming.isOpen)
    }
}
