import XCTest
@testable import Automix

/// The planner over analyses of real songs, recorded by ``AutomixLiveTests`` (SoundHelix songs 1
/// and 2, analysed with both models) and loaded through the store's own file format.
final class RecordedAnalysisPlanningTests: XCTestCase {

    private func recorded(_ id: String) throws -> TrackAnalysis {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(id).analysis", withExtension: "json"))
        let directory = try SyntheticAudio.temporaryDirectory(for: self)
        try FileManager.default.copyItem(at: fixture, to: directory.appendingPathComponent(AutomixAnalysisStore.fileName(for: id)))
        return try XCTUnwrap(AutomixAnalysisStore(directory: directory).load(id))
    }

    func testRecordedAnalysesLoadThroughTheStore() throws {
        let first = try recorded("soundhelix-song-1")
        let second = try recorded("soundhelix-song-2")
        for analysis in [first, second] {
            XCTAssertTrue(analysis.isUsable)
            XCTAssertEqual(analysis.vocalActivityMask.count, analysis.energyCurve.count)
            XCTAssertEqual(analysis.lowEnergyCurve.count, analysis.energyCurve.count)
            XCTAssertLessThan(analysis.contentEndTime, analysis.duration)
            XCTAssertEqual(analysis.downbeats, analysis.downbeats.sorted())
        }
        XCTAssertEqual(second.key, "B♭ minor", "accidentals survive analysis, the bridge and the store")
    }

    func testTwoRealSongsBlendOnTheBeat() throws {
        let outgoing = try recorded("soundhelix-song-1")
        let incoming = try recorded("soundhelix-song-2")
        let verdict = TransitionPolicy.assessTier(outgoing, incoming)
        XCTAssertEqual(verdict.tier, .beatmatched, "both grids trusted, tempi within 4% once octave-folded")

        let plan = TransitionPlanner.plan(
            analysis: outgoing,
            nextAnalysis: incoming,
            currentTrack: TransitionTrackInfo(id: outgoing.trackId, durationMs: Int64(outgoing.duration * 1000)),
            nextTrack: TransitionTrackInfo(id: incoming.trackId, durationMs: Int64(incoming.duration * 1000)),
            currentTime: 30,
            duration: outgoing.duration,
            mode: .smart
        )
        XCTAssertFalse(plan.blocked)
        XCTAssertEqual(plan.transitionStyle, .djBlend)
        XCTAssertEqual(plan.reason, "before-smart-duration")
        XCTAssertTrue(plan.bassSwap)
        XCTAssertEqual(plan.filterSweep, 0)

        // The incoming track is stretched onto the outgoing tempo, within the transparent window.
        let expectedRate = (1 / (incoming.bpm / outgoing.bpm) * 10000).rounded() / 10000
        XCTAssertEqual(plan.incomingPlaybackRate, expectedRate)
        XCTAssertLessThanOrEqual(abs(plan.incomingPlaybackRate - 1), 0.05)

        // The blend is eight beats long and ends before the outgoing content does, leaving the
        // arrangement overlap; the incoming track is cued into its intro, not at 0:00.
        XCTAssertEqual(plan.transitionBeats, 8)
        XCTAssertGreaterThan(plan.fadeSeconds, 2)
        XCTAssertLessThanOrEqual(plan.fadeSeconds, 12)
        XCTAssertLessThanOrEqual(plan.transitionEnd, outgoing.contentEndTime)
        XCTAssertGreaterThan(plan.incomingCueTime, TransitionPolicy.audibleStart(of: incoming))
        XCTAssertLessThan(plan.incomingCueTime, plan.incomingHandoffTime)
        XCTAssertEqual(plan.vocalOverlap, 0, "no moment where both are singing")

        // What the live run planned from the same numbers.
        XCTAssertEqual(plan.transitionStart, 361.810, accuracy: 0.01)
        XCTAssertEqual(plan.fadeSeconds, 5.329, accuracy: 0.01)
        XCTAssertEqual(plan.incomingCueTime, 40.576, accuracy: 0.01)
    }

    func testKeysThisUncertainKeepThePairOffThePhraseSwitch() throws {
        let outgoing = try recorded("soundhelix-song-1")
        let incoming = try recorded("soundhelix-song-2")
        // The analyzer named keys but barely preferred them; below 0.25 a key is no key, and the
        // phrase switch — the one move that lays two arrangements over each other for bars at a
        // time — needs two it can trust.
        XCTAssertLessThan(outgoing.keyConfidence, 0.25)
        XCTAssertEqual(TransitionPlanner.trustedKey(outgoing), "")
        XCTAssertFalse(TransitionPlanner.harmonicallyCompatible(TransitionPlanner.trustedKey(outgoing), TransitionPlanner.trustedKey(incoming)))

        // With the key gate set aside, the beat-matched plan itself exists and keeps its rules.
        guard case let .planned(wsola) = TransitionPlanner.planWsolaTransition(outgoing, incoming) else {
            return XCTFail("the grids and intros support a phrase switch")
        }
        print("RECORDED wsola beats=\(wsola.beats) start=\(wsola.transitionStart) cue=\(wsola.incomingCueTime) clash=\(wsola.vocalClash)")
        XCTAssertEqual(wsola.beats % 4, 0)
        XCTAssertGreaterThanOrEqual(wsola.transitionStart, 5)
        XCTAssertLessThanOrEqual(wsola.transitionEnd, outgoing.duration)
        // This song's grid covers only its opening; the blend must still sit at its end, not be
        // snapped back to the last downbeat the model found five minutes earlier.
        let beat = 60 / outgoing.bpm
        XCTAssertGreaterThanOrEqual(outgoing.contentEndTime - wsola.transitionEnd, 0, "the blend must not run into the trailing silence")
        XCTAssertLessThanOrEqual(outgoing.contentEndTime - wsola.transitionEnd, 12 * beat + 1e-6, "arrangement overlap plus at most a bar")
        XCTAssertLessThanOrEqual(wsola.incomingResumeTime + 5, incoming.duration)
    }
}
