import XCTest
@testable import Automix

/// Two analysed tracks in, a plan out: the plan has to respect every constraint the policy sets.
final class TransitionPlannerTests: XCTestCase {

    private func smartPlan(
        _ outgoing: TrackAnalysis,
        _ incoming: TrackAnalysis,
        at time: Double = 100,
        outgoingInfo: TransitionTrackInfo? = nil,
        incomingInfo: TransitionTrackInfo? = nil,
        albumSequential: Bool = false
    ) -> TransitionPlan {
        TransitionPlanner.plan(
            analysis: outgoing,
            nextAnalysis: incoming,
            currentTrack: outgoingInfo ?? AnalysisFixtures.info(outgoing),
            nextTrack: incomingInfo ?? AnalysisFixtures.info(incoming),
            currentTime: time,
            duration: outgoing.duration,
            fadeSeconds: 6,
            mode: .smart,
            albumSequential: albumSequential
        )
    }

    private var matchedPair: (TrackAnalysis, TrackAnalysis) {
        (
            AnalysisFixtures.track(id: "out", bpm: 124, confidence: 0.9, duration: 210, key: "A minor"),
            AnalysisFixtures.track(id: "in", bpm: 126, confidence: 0.85, duration: 200, key: "E minor")
        )
    }

    // MARK: - Beat-matched phrase switch

    func testBeatMatchedPairGetsAPhraseSwitchThatRespectsThePolicy() throws {
        let (outgoing, incoming) = matchedPair
        let plan = smartPlan(outgoing, incoming)

        XCTAssertFalse(plan.blocked)
        XCTAssertEqual(plan.transitionStyle, .djBlend)
        XCTAssertEqual(plan.reason, "before-phrase-switch")
        XCTAssertFalse(plan.shouldStart)
        XCTAssertTrue(plan.policyReasons.isEmpty)

        // Tempo: the incoming deck is stretched onto the outgoing grid, inside the transparent window.
        XCTAssertEqual(plan.incomingPlaybackRate, (124.0 / 126.0 * 10000).rounded() / 10000)
        XCTAssertLessThanOrEqual(abs(plan.incomingPlaybackRate - 1), TransitionPolicy.maxStretchDeviation)
        XCTAssertEqual(plan.outgoingBPM, 124)
        XCTAssertEqual(plan.incomingBPM, 126)

        // Length: counted in whole bars, between one and four of them, never past 16 s.
        XCTAssertEqual(plan.transitionBeats % 4, 0)
        XCTAssertTrue((4...16).contains(plan.transitionBeats))
        XCTAssertEqual(plan.transitionBeats, 16, "an instrumental 32-beat intro affords the full four bars")
        XCTAssertLessThanOrEqual(plan.fadeSeconds, 16)
        XCTAssertEqual(plan.fadeSeconds, plan.transitionEnd - plan.transitionStart, accuracy: 1e-9)
        XCTAssertEqual(plan.fadeSeconds, Double(plan.transitionBeats) * 60 / 124, accuracy: 1e-9)

        // Placement: the blend opens on an outgoing downbeat, leaves clearance, never overruns.
        XCTAssertTrue(outgoing.downbeats.contains(plan.transitionStart))
        XCTAssertGreaterThanOrEqual(plan.transitionStart, 5)
        XCTAssertLessThanOrEqual(plan.transitionEnd, outgoing.duration)
        // A content-end exit is moved eight beats earlier, so the incoming arrangement lands inside the blend.
        XCTAssertLessThanOrEqual(plan.transitionEnd, outgoing.contentEndTime - 8 * 60 / 124 + 1e-9)

        // The incoming side: cued after it makes sound, with its drop inside the overlap and room after.
        let incomingOverlap = Double(plan.transitionBeats) * 60 / 126
        XCTAssertGreaterThanOrEqual(plan.incomingCueTime, TransitionPolicy.audibleStart(of: incoming) - 0.05)
        XCTAssertEqual(plan.incomingHandoffTime - plan.incomingCueTime, incomingOverlap, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(plan.incomingHandoffTime + 5, incoming.duration)
        let drop = try XCTUnwrap(TransitionPlanner.incomingMixInPoint(incoming))
        XCTAssertEqual(plan.incomingHandoffTime, drop + 8 * 60 / 126, accuracy: 1e-9)

        // Render: a bass swap on a shared beat, no filter ride, no vocals to separate.
        XCTAssertTrue(plan.bassSwap)
        XCTAssertEqual(plan.filterSweep, 0)
        XCTAssertTrue((0.5...0.85).contains(plan.bassSwapFraction))
        XCTAssertEqual((plan.bassSwapFraction * Double(plan.transitionBeats)).rounded(), plan.bassSwapFraction * Double(plan.transitionBeats), accuracy: 1e-9, "the swap lands on a beat")
        XCTAssertEqual(plan.vocalOverlap, 0)
        XCTAssertTrue(plan.isRealMix)
    }

    func testPlanStartsOnceThePlayheadReachesIt() {
        let (outgoing, incoming) = matchedPair
        let before = smartPlan(outgoing, incoming)
        let during = smartPlan(outgoing, incoming, at: before.transitionStart + 0.5)
        XCTAssertTrue(during.shouldStart)
        XCTAssertEqual(during.reason, "smart-phrase-switch")
        XCTAssertEqual(during.transitionStart, before.transitionStart)
    }

    func testBothSidesSingingShrinksTheOverlapAndReportsTheClash() {
        let outgoing = AnalysisFixtures.track(id: "out", bpm: 124, duration: 210, key: "A minor", vocal: { _ in 0.9 })
        let incoming = AnalysisFixtures.track(id: "in", bpm: 126, duration: 200, key: "A minor", vocal: { _ in 0.9 })
        let clean = smartPlan(matchedPair.0, matchedPair.1)
        let clashing = smartPlan(outgoing, incoming)

        XCTAssertEqual(clashing.transitionStyle, .djBlend)
        XCTAssertEqual(clashing.transitionBeats, 4, "shrunk bar by bar down to the one-bar floor")
        XCTAssertLessThan(clashing.fadeSeconds, clean.fadeSeconds)
        XCTAssertGreaterThan(clashing.vocalOverlap, TransitionPolicy.vocalClashTolerance)

        if case let .planned(wsola) = TransitionPlanner.planWsolaTransition(outgoing, incoming) {
            XCTAssertTrue(wsola.vocalClash)
        } else {
            XCTFail("a clash shortens the phrase switch, it does not refuse it")
        }
    }

    func testAVocalClashOnlyWhereTheOutgoingTrackStillSingsIsAvoidedByShortening() {
        // Outgoing stops singing 14 beats before its shifted exit; incoming's intro sings.
        let beat = 60.0 / 124
        let exit = 210 - 8 * beat
        let outgoing = AnalysisFixtures.track(id: "out", bpm: 124, duration: 210, key: "A minor", vocal: { $0 < exit - 14 * beat ? 0.9 : 0.1 })
        let incoming = AnalysisFixtures.track(id: "in", bpm: 126, duration: 200, key: "A minor", vocal: { _ in 0.9 })
        let plan = smartPlan(outgoing, incoming)
        XCTAssertEqual(plan.transitionBeats, 12, "16 beats reach back into the outgoing vocal; 12 do not")
        XCTAssertLessThanOrEqual(plan.vocalOverlap, TransitionPolicy.vocalClashTolerance)
    }

    // MARK: - Degraded tiers

    func testTempiTooFarApartGetAFilterRideWithoutStretching() {
        let outgoing = AnalysisFixtures.track(id: "out", bpm: 100, duration: 210)
        let incoming = AnalysisFixtures.track(id: "in", bpm: 128, duration: 200)
        let plan = smartPlan(outgoing, incoming)

        XCTAssertEqual(plan.transitionStyle, .djFilter)
        XCTAssertEqual(plan.filterSweep, TransitionPlanner.filterSweep)
        XCTAssertEqual(plan.incomingPlaybackRate, 1, "a 28% stretch is not transparent")
        XCTAssertEqual(plan.policyReasons, ["tempo-distance"])
        XCTAssertEqual(plan.transitionBeats, 16)
        XCTAssertLessThanOrEqual(plan.fadeSeconds, 12)
        XCTAssertGreaterThan(plan.fadeSeconds, 0)
        XCTAssertLessThanOrEqual(plan.transitionEnd, outgoing.contentEndTime)
        XCTAssertEqual(plan.reason, "before-smart-duration")
    }

    func testIncompatibleKeysSkipThePhraseSwitchButStillBlendOnTheBeat() {
        let outgoing = AnalysisFixtures.track(id: "out", bpm: 124, duration: 210, key: "A minor")
        let incoming = AnalysisFixtures.track(id: "in", bpm: 126, duration: 200, key: "D♯ major")
        let plan = smartPlan(outgoing, incoming)

        XCTAssertEqual(plan.transitionStyle, .djBlend)
        XCTAssertEqual(plan.reason, "before-smart-duration", "the adaptive overlap, not the phrase switch")
        XCTAssertEqual(plan.filterSweep, 0)
        XCTAssertEqual(plan.incomingPlaybackRate, (1 / (126.0 / 124.0) * 10000).rounded() / 10000)
        XCTAssertTrue(plan.bassSwap)
    }

    func testLowConfidenceGetsAPlainFadeAtTheAnalyzedAnchor() {
        let outgoing = AnalysisFixtures.track(id: "out", confidence: 0.1, duration: 210, contentEnd: 205)
        let incoming = AnalysisFixtures.track(id: "in", confidence: 0.05, duration: 200, audibleStart: 1.2)
        let plan = smartPlan(outgoing, incoming)

        XCTAssertEqual(plan.transitionStyle, .equalPower)
        XCTAssertEqual(plan.reason, "before-plain-crossfade-window")
        XCTAssertEqual(plan.policyReasons, ["beat-confidence"])
        XCTAssertEqual(plan.transitionEnd, 205, "the fade ends where the music does, not the file")
        XCTAssertEqual(plan.transitionStart, 199)
        XCTAssertEqual(plan.incomingCueTime, 1.2, "cued past the incoming track's lead-in silence")
        XCTAssertTrue(plan.isRealMix, "cueing the incoming track past 0:00 is something a plain fade does not do")
    }

    func testAnInteriorAnchorThePlayheadHasPassedFallsBackToTheEndOfContent() {
        let outgoing = AnalysisFixtures.track(
            id: "out", bpm: 124, duration: 200,
            mixOut: [MixCandidate(time: 150, score: 0.95, type: "energy_cliff"), MixCandidate(time: 200, score: 0.75, type: "content_end")],
            energy: { $0 < 150 ? 1 : 0.001 }
        )
        let incoming = AnalysisFixtures.track(id: "in", bpm: 124, duration: 200, key: "A minor")
        let early = smartPlan(outgoing, incoming, at: 60)
        XCTAssertLessThanOrEqual(early.transitionEnd, 150.05, "mixes out at the energy cliff")

        let late = smartPlan(outgoing, incoming, at: 151)
        XCTAssertGreaterThan(late.transitionEnd, 190, "past the cliff, the anchor is the end of the content")
    }

    // MARK: - Guards

    func testStandardModeIsAFixedFadeBeforeTheEnd() {
        let plan = TransitionPlanner.plan(duration: 200, fadeSeconds: 6, mode: .standard)
        XCTAssertEqual(plan.transitionStart, 194)
        XCTAssertEqual(plan.transitionEnd, 200)
        XCTAssertEqual(plan.fadeMs, 6000)
        XCTAssertEqual(plan.reason, "before-standard-window")
        XCTAssertFalse(plan.isRealMix)
        let started = TransitionPlanner.plan(currentTime: 195, duration: 200, fadeSeconds: 30, mode: .standard)
        XCTAssertTrue(started.shouldStart)
        XCTAssertEqual(started.fadeSeconds, 12, "clamped to twelve seconds")
    }

    func testNothingToPlanWithoutADuration() {
        let plan = TransitionPlanner.plan(mode: .smart)
        XCTAssertTrue(plan.blocked)
        XCTAssertEqual(plan.reason, "no-duration")
        XCTAssertNil(plan.markerWindow(durationSeconds: 100))
    }

    func testShortTracksAreNotMixed() {
        let plan = TransitionPlanner.plan(duration: 40, mode: .smart)
        XCTAssertTrue(plan.blocked)
        XCTAssertEqual(plan.reason, "short-duration-guard")
    }

    func testSpeechAndLiveRecordingsAreNeverMixed() {
        let (outgoing, incoming) = matchedPair
        for title in ["Live at Wembley", "Daily Podcast", "Episode 4", "The Concert"] {
            let plan = smartPlan(outgoing, incoming, outgoingInfo: AnalysisFixtures.info(outgoing, title: title))
            XCTAssertTrue(plan.blocked, title)
            XCTAssertEqual(plan.reason, "blocked-speech-or-live")
        }
        XCTAssertFalse(smartPlan(outgoing, incoming, outgoingInfo: AnalysisFixtures.info(outgoing, title: "Alive")).blocked)
    }

    func testAnAlbumPlayedThroughIsGapless() {
        let (outgoing, incoming) = matchedPair
        let outInfo = AnalysisFixtures.info(outgoing, album: "Record", albumId: "MPRE1")
        let inInfo = AnalysisFixtures.info(incoming, album: "Record", albumId: "MPRE1")
        let gapless = smartPlan(outgoing, incoming, outgoingInfo: outInfo, incomingInfo: inInfo, albumSequential: true)
        XCTAssertEqual(gapless.transitionStyle, .gapless)
        XCTAssertEqual(gapless.fadeSeconds, 0.12)
        XCTAssertEqual(gapless.transitionStart, 210 - 0.45, accuracy: 1e-9)

        let shuffled = smartPlan(outgoing, incoming, outgoingInfo: outInfo, incomingInfo: inInfo, albumSequential: false)
        XCTAssertNotEqual(shuffled.transitionStyle, .gapless, "album siblings in a playlist are mixed")
    }

    func testAStaleAnalysisFallsBackToAStandardFade() {
        let (outgoing, incoming) = matchedPair
        var stale = outgoing
        stale.trackId = "some-other-track"
        let plan = smartPlan(stale, incoming, outgoingInfo: TransitionTrackInfo(id: "out", durationMs: 210_000))
        XCTAssertEqual(plan.reason, "before-smart-analysis-fallback-window")
        XCTAssertEqual(plan.transitionStyle, .equalPower)
    }

    func testMarkerWindowIsTheTransitionAsFractionsOfTheTrack() throws {
        let (outgoing, incoming) = matchedPair
        let plan = smartPlan(outgoing, incoming)
        let window = try XCTUnwrap(plan.markerWindow(durationSeconds: outgoing.duration))
        XCTAssertEqual(window.start, plan.transitionStart / 210, accuracy: 1e-9)
        XCTAssertEqual(window.end, plan.transitionEnd / 210, accuracy: 1e-9)
    }

    // MARK: - WSOLA refusals and keys

    func testWsolaRefusalsAreRoutingDecisions() {
        let (outgoing, incoming) = matchedPair
        var lengthless = outgoing
        lengthless.duration = 0
        var lengthlessNext = incoming
        lengthlessNext.duration = 0
        XCTAssertEqual(TransitionPlanner.planWsolaTransition(lengthless, lengthlessNext), .refused("missing-duration"))

        let farApart = AnalysisFixtures.track(bpm: 100)
        XCTAssertEqual(TransitionPlanner.planWsolaTransition(farApart, incoming), .refused("tempo-distance"))

        let coldOpen = AnalysisFixtures.track(id: "in", bpm: 126, duration: 200, mixIn: [MixCandidate(time: 0.5, score: 0.9, type: "pickup")])
        XCTAssertEqual(TransitionPlanner.planWsolaTransition(outgoing, coldOpen), .refused("incoming-no-intro"))
    }

    func testAGridThatStopsEarlyCannotDragThePhraseSwitchBackIntoTheSong() throws {
        // Downbeats only over the opening (the model's head window), none near the exit.
        var outgoing = matchedPair.0
        outgoing.downbeats = outgoing.downbeats.filter { $0 < 30 }
        guard case let .planned(plan) = TransitionPlanner.planWsolaTransition(outgoing, matchedPair.1) else {
            return XCTFail("still a phrase switch")
        }
        let beat = 60.0 / 124
        XCTAssertEqual(plan.transitionEnd, outgoing.contentEndTime - 8 * beat, accuracy: 1e-9, "at the exit, unsnapped")
        XCTAssertGreaterThan(plan.transitionStart, 190)
    }

    func testTheStartSnapsBackToADownbeatWithinABar() throws {
        let (outgoing, incoming) = matchedPair
        guard case let .planned(plan) = TransitionPlanner.planWsolaTransition(outgoing, incoming) else {
            return XCTFail("a phrase switch")
        }
        let beat = 60.0 / 124
        let target = outgoing.contentEndTime - 8 * beat - Double(plan.beats) * beat
        XCTAssertTrue(outgoing.downbeats.contains(plan.transitionStart))
        XCTAssertLessThanOrEqual(target - plan.transitionStart, 4 * beat)
        XCTAssertGreaterThanOrEqual(target - plan.transitionStart, 0)
    }

    func testKeyCompatibilityFollowsTheCircleOfFifths() {
        XCTAssertTrue(TransitionPlanner.harmonicallyCompatible("C major", "G major"), "a fifth")
        XCTAssertTrue(TransitionPlanner.harmonicallyCompatible("C major", "D major"), "a tone")
        XCTAssertTrue(TransitionPlanner.harmonicallyCompatible("E♭ major", "D♯ major"), "enharmonic spellings")
        XCTAssertTrue(TransitionPlanner.harmonicallyCompatible("A minor", "B♭ major"), "a semitone across modes")
        XCTAssertFalse(TransitionPlanner.harmonicallyCompatible("C major", "A minor"), "relative keys differ in mode by three")
        XCTAssertFalse(TransitionPlanner.harmonicallyCompatible("C major", "F♯ major"), "a tritone")
        XCTAssertFalse(TransitionPlanner.harmonicallyCompatible("", "C major"), "no key is no evidence")
        XCTAssertEqual(TransitionPlanner.keyDistance("C major", "C minor"), 1)
        XCTAssertNil(TransitionPlanner.keyDistance("H major", "C major"))
    }

    func testAnUntrustedKeyIsNoKey() {
        let analysis = AnalysisFixtures.track(key: "C major", keyConfidence: 0.2)
        XCTAssertEqual(TransitionPlanner.trustedKey(analysis), "")
    }

    func testIncomingCuePointFallsBackThroughTheScalarFields() {
        var analysis = AnalysisFixtures.track(bpm: 120, firstBeat: 0.5, mixIn: [])
        analysis.mixInTime = 16.4
        XCTAssertEqual(TransitionPlanner.incomingCuePoint(analysis), 16.5, "snapped to the nearest downbeat")
        analysis.mixInTime = 0
        analysis.introEndTime = 9
        XCTAssertEqual(TransitionPlanner.incomingCuePoint(analysis), 10.5, "the first downbeat after the intro")
    }
}
