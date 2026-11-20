import XCTest
@testable import Automix

/// The confidence ladder, vocal-clash measures and anchor ranking in ``TransitionPolicy``.
final class TransitionPolicyTests: XCTestCase {

    // MARK: - Tier ladder

    func testTempoOutsidePlausibleRangeDropsToPlainCrossfade() {
        let verdict = TransitionPolicy.assessTier(
            AnalysisFixtures.track(bpm: 30),
            AnalysisFixtures.track(bpm: 250)
        )
        XCTAssertEqual(verdict.tier, .plainCrossfade)
        XCTAssertEqual(verdict.reasons, ["outgoing-tempo", "incoming-tempo"])
    }

    func testUnanalysedTracksLandOnTheBottomRung() {
        let verdict = TransitionPolicy.assessTier(TrackAnalysis(), TrackAnalysis())
        XCTAssertEqual(verdict.tier, .plainCrossfade)
        XCTAssertEqual(verdict.reasons.first, "outgoing-tempo")
    }

    func testLowConfidenceOnBothSidesIsAPlainCrossfade() {
        let verdict = TransitionPolicy.assessTier(
            AnalysisFixtures.track(confidence: 0.1),
            AnalysisFixtures.track(confidence: 0.19)
        )
        XCTAssertEqual(verdict.tier, .plainCrossfade)
        XCTAssertEqual(verdict.reasons, ["beat-confidence"])
        XCTAssertEqual(verdict.beatConfidence, 0.1)
    }

    func testCatalogTempoAtZeroConfidenceCannotAuthorizeBeatMatching() {
        let verdict = TransitionPolicy.assessTier(
            AnalysisFixtures.track(confidence: 0.9),
            AnalysisFixtures.track(confidence: 0)
        )
        XCTAssertEqual(verdict.tier, .djAssisted)
        XCTAssertEqual(verdict.reasons, ["beat-confidence"])
    }

    func testTempiBeyondTheStretchWindowAreDJAssisted() {
        let verdict = TransitionPolicy.assessTier(
            AnalysisFixtures.track(bpm: 120),
            AnalysisFixtures.track(bpm: 128)
        )
        XCTAssertEqual(verdict.tier, .djAssisted)
        XCTAssertEqual(verdict.reasons, ["tempo-distance"])
    }

    func testTrustedGridsWithinFourPercentAreBeatMatched() {
        let verdict = TransitionPolicy.assessTier(
            AnalysisFixtures.track(bpm: 124, confidence: 0.8),
            AnalysisFixtures.track(bpm: 126, confidence: 0.7)
        )
        XCTAssertEqual(verdict.tier, .beatmatched)
        XCTAssertTrue(verdict.reasons.isEmpty)
        XCTAssertEqual(verdict.beatConfidence, 0.7)
    }

    func testHalfTimeTrackIsCountedInTheOutgoingOctave() {
        XCTAssertEqual(TransitionPolicy.alignTempoOctave(outgoingBPM: 126, incomingBPM: 63), 126)
        XCTAssertEqual(TransitionPolicy.alignTempoOctave(outgoingBPM: 90, incomingBPM: 176), 88)
        XCTAssertEqual(TransitionPolicy.alignTempoOctave(outgoingBPM: 0, incomingBPM: 120), 120)
        let verdict = TransitionPolicy.assessTier(AnalysisFixtures.track(bpm: 126), AnalysisFixtures.track(bpm: 63))
        XCTAssertEqual(verdict.tier, .beatmatched)
    }

    // MARK: - Vocals

    func testVocalActivityAveragesTheMaskOverAWindow() {
        let analysis = AnalysisFixtures.track(vocal: { $0 < 10 ? 1.0 : 0.0 })
        XCTAssertEqual(TransitionPolicy.vocalActivity(analysis, from: 0, to: 9) ?? -1, 1, accuracy: 1e-9)
        XCTAssertEqual(TransitionPolicy.vocalActivity(analysis, from: 5, to: 14) ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertNil(TransitionPolicy.vocalActivity(analysis, from: 5, to: 5))
    }

    func testAMaskOfTheWrongLengthIsNoEvidence() {
        var analysis = AnalysisFixtures.track(vocal: { _ in 1 })
        analysis.vocalActivityMask.removeLast()
        XCTAssertNil(TransitionPolicy.vocalActivity(analysis, from: 0, to: 30))
        XCTAssertFalse(TransitionPolicy.isVocalClash(nil, 1))
    }

    func testClashNeedsBothSidesSinging() {
        XCTAssertTrue(TransitionPolicy.isVocalClash(0.6, 0.9))
        XCTAssertFalse(TransitionPolicy.isVocalClash(0.59, 0.9))
        // A fallback analyzer's flat 0.5 never trips vocal logic.
        XCTAssertFalse(TransitionPolicy.isVocalClash(0.5, 0.5))
    }

    func testVocalOverlapAmountIsGovernedByTheQuieterSide() {
        XCTAssertEqual(TransitionPolicy.vocalOverlapAmount(1, 1), 1, accuracy: 1e-9)
        XCTAssertEqual(TransitionPolicy.vocalOverlapAmount(1, 0.8), 0.5, accuracy: 1e-9)
        XCTAssertEqual(TransitionPolicy.vocalOverlapAmount(0.6, 1), 0)
        XCTAssertEqual(TransitionPolicy.vocalOverlapAmount(nil, 1), 0)
    }

    func testSimultaneousFractionCatchesAClashAMeanWouldAverageAway() {
        // Outgoing sings throughout; incoming only for its last three of twelve seconds.
        let outgoing = AnalysisFixtures.track(vocal: { _ in 0.9 })
        let incoming = AnalysisFixtures.track(vocal: { $0 >= 9 && $0 < 12 ? 0.9 : 0.1 })
        let mean = TransitionPolicy.vocalActivity(incoming, from: 0, to: 11)!
        XCTAssertLessThan(mean, TransitionPolicy.vocalActiveThreshold, "the mean reads the window as clear")

        let fraction = TransitionPolicy.simultaneousVocalFraction(
            outgoing: outgoing, incoming: incoming, outStart: 100, outEnd: 111, inStart: 0, rate: 1
        )!
        XCTAssertEqual(fraction, 3.0 / 12.0, accuracy: 1e-9)
        XCTAssertGreaterThan(fraction, TransitionPolicy.vocalClashTolerance)
    }

    func testSimultaneousFractionMapsTheIncomingTimelineThroughThePlaybackRate() {
        let outgoing = AnalysisFixtures.track(vocal: { _ in 0.9 })
        // Incoming sings only after 10 s. At rate 1 outgoing 100...105 maps to incoming 5...10;
        // at rate 2 it maps to 5...15.
        let incoming = AnalysisFixtures.track(vocal: { $0 > 10 ? 0.9 : 0.1 })
        let atUnity = TransitionPolicy.simultaneousVocalFraction(outgoing: outgoing, incoming: incoming, outStart: 100, outEnd: 105, inStart: 5, rate: 1)!
        let stretched = TransitionPolicy.simultaneousVocalFraction(outgoing: outgoing, incoming: incoming, outStart: 100, outEnd: 105, inStart: 5, rate: 2)!
        XCTAssertEqual(atUnity, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(stretched, 0.3)
        XCTAssertNil(TransitionPolicy.simultaneousVocalFraction(outgoing: outgoing, incoming: AnalysisFixtures.track(), outStart: 0, outEnd: 5, inStart: 0, rate: 1))
    }

    // MARK: - Audible music and starts

    func testAudibleSecondsCountsMusicNotSilence() {
        let analysis = AnalysisFixtures.track(duration: 100, contentEnd: 80)
        XCTAssertEqual(TransitionPolicy.audibleSeconds(analysis, from: 70, to: 100) ?? -1, 10, accuracy: 1e-9)
        XCTAssertEqual(TransitionPolicy.audibleSeconds(analysis, from: 85, to: 100) ?? -1, 0, accuracy: 1e-9)
        XCTAssertNil(TransitionPolicy.audibleSeconds(TrackAnalysis(), from: 0, to: 10))
    }

    func testAZeroFirstBeatDoesNotOverrideAMeasuredAudibleStart() {
        var analysis = TrackAnalysis(firstBeat: 0)
        analysis.audibleStartTime = 3.2
        XCTAssertEqual(TransitionPolicy.audibleStart(of: analysis), 3.2)
        analysis.pickupTime = 2.9
        XCTAssertEqual(TransitionPolicy.audibleStart(of: analysis), 2.9)
        XCTAssertEqual(TransitionPolicy.audibleStart(of: TrackAnalysis()), 0)
    }

    // MARK: - Ranking

    func testDropsOutrankPickupsAndColdOpensArePenalized() {
        let analysis = AnalysisFixtures.track(bpm: 120, firstBeat: 0.5, mixIn: [
            MixCandidate(time: 0.5, score: 0.8, type: "pickup"),
            MixCandidate(time: 16.5, score: 0.9, type: "intro_drop"),
            MixCandidate(time: 32.5, score: 0.95, type: "main_drop"),
        ])
        let ranked = TransitionPolicy.rankMixInCandidates(analysis)
        XCTAssertEqual(ranked.map(\.type), ["main_drop", "intro_drop", "pickup"])
        // pickup: 0.8 + 0.15 + downbeat 0.1 − cold open 0.2
        XCTAssertEqual(ranked.last!.rankScore, 0.85, accuracy: 1e-9)
    }

    func testAnEntryWhoseRunUpSingsRanksLower() {
        let candidates = [
            MixCandidate(time: 40.5, score: 0.9, type: "intro_drop"),
            MixCandidate(time: 80.5, score: 0.9, type: "intro_drop"),
        ]
        let analysis = AnalysisFixtures.track(bpm: 120, mixIn: candidates, vocal: { $0 < 45 ? 0.95 : 0.05 })
        let ranked = TransitionPolicy.rankMixInCandidates(analysis)
        XCTAssertEqual(ranked.first?.time, 80.5)
    }

    func testMixOutCandidatesThatCutTheSongShortAreDropped() {
        let analysis = AnalysisFixtures.track(duration: 200, contentEnd: 200, mixOut: [
            MixCandidate(time: 150, score: 0.95, type: "energy_cliff"),
            MixCandidate(time: 190, score: 0.9, type: "outro_start"),
            MixCandidate(time: 200, score: 0.75, type: "content_end"),
        ])
        let ranked = TransitionPolicy.rankMixOutCandidates(analysis)
        XCTAssertEqual(ranked.map(\.type), ["outro_start", "content_end"], "fifty seconds of music is not a tail")
        XCTAssertEqual(ranked.first!.discardedMusicSeconds, 10, accuracy: 1e-9)
    }

    func testSilenceIsFreeSoAGenuineInteriorGapWinsTheAnchor() {
        // Music stops at 150 s and the file runs to 200 s: the cliff skips nothing audible.
        let analysis = AnalysisFixtures.track(duration: 200, contentEnd: 200, mixOut: [
            MixCandidate(time: 150, score: 0.95, type: "energy_cliff"),
            MixCandidate(time: 200, score: 0.75, type: "content_end"),
        ], energy: { $0 < 150 ? 1 : 0.001 })
        let anchor = TransitionPolicy.resolveMixOutAnchor(analysis)
        XCTAssertEqual(anchor.time, 150)
        XCTAssertEqual(anchor.type, "energy_cliff")
        XCTAssertEqual(anchor.discardedMusicSeconds, 0)
    }

    func testScalarFieldsStandInForAMissingCandidateList() {
        var analysis = AnalysisFixtures.track(duration: 200, contentEnd: 195, mixOut: [])
        analysis.mixOutTime = 190
        analysis.outroStartTime = 188
        let types = TransitionPolicy.rankMixOutCandidates(analysis).map(\.type)
        XCTAssertEqual(Set(types), ["energy_cliff", "outro_start", "content_end"])
    }

    func testWithNoEnergyCurveTheRawGapIsCharged() {
        var analysis = AnalysisFixtures.track(duration: 200, contentEnd: 200, mixOut: [
            MixCandidate(time: 185, score: 0.95, type: "energy_cliff"),
        ])
        analysis.energyCurve = []
        let ranked = TransitionPolicy.rankMixOutCandidates(analysis)
        XCTAssertEqual(ranked.map(\.type), ["content_end"], "15 s charged in full exceeds the 12 s budget")
        // With a curve, every candidate short of the end is measured rather than charged in full.
        let withCurve = AnalysisFixtures.track(duration: 200, contentEnd: 200, mixOut: [MixCandidate(time: 192, score: 0.9, type: "outro_start")])
        XCTAssertTrue(TransitionPolicy.rankMixOutCandidates(withCurve).filter { $0.time < 200 }.allSatisfy(\.measured))
    }

    func testAnchorFallsBackToContentEnd() {
        let anchor = TransitionPolicy.resolveMixOutAnchor(TrackAnalysis(), duration: 180)
        XCTAssertEqual(anchor, MixOutAnchor(time: 180, type: "content_end", discardedMusicSeconds: 0))
    }
}
