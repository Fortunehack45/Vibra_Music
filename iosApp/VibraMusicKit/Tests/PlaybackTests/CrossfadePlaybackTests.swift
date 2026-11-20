import AVFoundation
import XCTest
@testable import Playback

/// Crossfades and Automix transitions executed on the engine's two real players.
@MainActor
final class CrossfadePlaybackTests: EngineTestCase {
    struct Sample {
        var phase: CrossfadeController.Phase
        var volumeA: Float
        var volumeB: Float
        var playingA: Bool
        var playingB: Bool
        var currentID: String?
        var rateA: Float
        var rateB: Float
    }

    /// Samples both decks every 10 ms until `until` holds.
    func sample(_ h: EngineHarness, timeout: TimeInterval = 10, until done: @MainActor () -> Bool) async -> [Sample] {
        var samples: [Sample] = []
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !done() {
            let a = h.engine.deck(.a), b = h.engine.deck(.b)
            samples.append(Sample(
                phase: h.engine.crossfade.phase,
                volumeA: a.volume,
                volumeB: b.volume,
                playingA: a.isPlaying,
                playingB: b.isPlaying,
                currentID: h.engine.currentItem?.id,
                rateA: a.player.rate,
                rateB: b.player.rate
            ))
            try? await Task.sleep(for: .milliseconds(10))
        }
        return samples
    }

    func testBothTracksOverlapWithEqualPowerGains() async throws {
        // A fade long enough that a machine busy enough to start the incoming player late still
        // leaves most of it to measure.
        let first = try tone(6, frequency: 440, name: "xfade-1")
        let second = try tone(6, frequency: 660, name: "xfade-2")
        let h = harness(queue: [first, second])
        h.engine.crossfadeDuration = 2
        h.engine.load(first, playWhenReady: true)
        let outgoing = h.engine.activeDeckID
        let incoming: PlaybackDeckID = outgoing == .a ? .b : .a

        let samples = await sample(h) {
            h.engine.currentItem?.id == second.id && !h.engine.isTransitioning
        }
        XCTAssertEqual(h.delegate.changes.map(\.reason), [.requested, .crossfade])
        XCTAssertEqual(h.engine.activeDeckID, incoming, "the session moved onto the deck that started the incoming track")

        let fading = samples.filter { $0.phase == .fading }
        XCTAssertGreaterThan(fading.count, 50, "a 2 s fade sampled every 10 ms")
        func volumes(_ s: Sample) -> (out: Float, in: Float) {
            outgoing == .a ? (s.volumeA, s.volumeB) : (s.volumeB, s.volumeA)
        }
        // Both audible at once, both players running.
        let overlapping = fading.filter { volumes($0).out > 0.2 && volumes($0).in > 0.2 && $0.playingA && $0.playingB }
        XCTAssertGreaterThan(overlapping.count, 20, "the two tracks are heard together for a real stretch of the fade")
        // Equal power throughout: rise² + fall² = 1, so no dip in the middle.
        for (index, s) in fading.enumerated() {
            let v = volumes(s)
            XCTAssertEqual(v.out * v.out + v.in * v.in, 1, accuracy: 0.02, "sample \(index) of \(fading.count): \(s)")
        }
        // The incoming track rises and the outgoing one falls, monotonically.
        let incomingVolumes = fading.map { volumes($0).in }
        let outgoingVolumes = fading.map { volumes($0).out }
        XCTAssertEqual(incomingVolumes, incomingVolumes.sorted())
        XCTAssertEqual(outgoingVolumes, outgoingVolumes.sorted(by: >))
        XCTAssertLessThan(incomingVolumes.first ?? 1, 0.25)
        XCTAssertGreaterThan(incomingVolumes.last ?? 0, 0.85)

        // Metadata flipped as the incoming track became audible, not when the blend ended.
        let firstFading = try XCTUnwrap(fading.first)
        XCTAssertEqual(firstFading.currentID, second.id)
        // Arming happened, silently, before the fade.
        let arming = samples.filter { $0.phase == .arming }
        XCTAssertFalse(arming.isEmpty)
        for s in arming { XCTAssertEqual(outgoing == .a ? s.volumeB : s.volumeA, 0, "the standby is silent while it arms") }

        // Afterwards the outgoing deck is retired: emptied and back at full volume.
        XCTAssertNil(h.engine.deck(outgoing).current)
        XCTAssertEqual(h.engine.deck(outgoing).volume, 1)
        XCTAssertEqual(h.engine.deck(incoming).volume, 1)
        XCTAssertTrue(h.engine.isPlaying)
        XCTAssertFalse(h.engine.isSmartMixInProgress, "a plain crossfade is not advertised as a mix")
    }

    /// Taking the queued item off a player this near its item's end cuts the outgoing track's sound
    /// just as the incoming one starts. It stays on the player, unused, until the deck retires.
    func testTheHandoffLeavesTheOutgoingPlayersQueueInPlace() async throws {
        let first = try tone(4, name: "xfade-queue-1")
        let second = try tone(4, frequency: 550, name: "xfade-queue-2")
        let h = harness(queue: [first, second])
        h.engine.crossfadeDuration = 1
        h.engine.load(first, playWhenReady: true)
        let deck = h.engine.deck(h.engine.activeDeckID)
        await waitUntil("preloaded") { deck.queued?.item.id == second.id }
        let queuedItem = try XCTUnwrap(deck.queued).playerItem

        await waitUntil("handoff", timeout: 8) { h.engine.currentItem?.id == second.id }

        XCTAssertTrue(deck.player.items().contains(queuedItem), "still on the player while the outgoing track is heard")
        XCTAssertNil(deck.queued)
        XCTAssertEqual(deck.player.actionAtItemEnd, .pause, "and it never goes on to it")

        await waitUntil("the fade over", timeout: 8) { !h.engine.isTransitioning }
        XCTAssertTrue(deck.player.items().isEmpty, "gone with the deck")
    }

    func testTheFadeStartsWhereTheOutgoingTrackHasOverlapLeft() async throws {
        let first = try tone(4, name: "xfade-timing-1")
        let second = try tone(4, frequency: 550, name: "xfade-timing-2")
        let h = harness(queue: [first, second])
        h.engine.crossfadeDuration = 1
        h.engine.load(first, playWhenReady: true)
        let outgoing = h.engine.activeDeckID
        await waitUntil("handoff", timeout: 8) { h.engine.currentItem?.id == second.id }
        // Handed off with about a second of the outgoing track left.
        let at = h.engine.deck(outgoing).position
        XCTAssertEqual(at, 3, accuracy: 0.25)
    }

    func testASkipDuringTheFadeRampsTheOutgoingTrackAway() async throws {
        let first = try tone(4, name: "xfade-skip-1")
        let second = try tone(5, frequency: 550, name: "xfade-skip-2")
        let third = try tone(3, frequency: 770, name: "xfade-skip-3")
        let h = harness(queue: [first, second, third])
        h.engine.crossfadeDuration = 2
        h.engine.load(first, playWhenReady: true)
        let outgoing = h.engine.activeDeckID
        await waitUntil("fading", timeout: 8) { h.engine.crossfade.phase == .fading }
        await pause(for: 0.3)

        // Next pressed mid-blend: crossfade is for tracks running out, not for skips.
        XCTAssertTrue(h.engine.skipToNext())
        XCTAssertEqual(h.engine.currentItem?.id, third.id)
        XCTAssertEqual(h.engine.crossfade.phase, .bailing)
        await waitUntil("bail finished", timeout: 2) { !h.engine.isTransitioning }
        XCTAssertNil(h.engine.deck(outgoing).current, "the old tail is gone")
        await waitUntil("third playing") { h.engine.isPlaying }
        XCTAssertEqual(h.engine.deck(h.engine.activeDeckID).volume, 1)
    }

    func testASeekDuringTheFadeEndsIt() async throws {
        let first = try tone(4, name: "xfade-seek-1")
        let second = try tone(6, frequency: 550, name: "xfade-seek-2")
        let h = harness(queue: [first, second])
        h.engine.crossfadeDuration = 2
        h.engine.load(first, playWhenReady: true)
        await waitUntil("fading", timeout: 8) { h.engine.crossfade.phase == .fading }
        h.engine.seek(to: 3)
        await waitUntil("bail finished", timeout: 2) { !h.engine.isTransitioning }
        XCTAssertEqual(h.engine.currentItem?.id, second.id)
        XCTAssertEqual(h.engine.deck(h.engine.activeDeckID).volume, 1)
        await waitUntil("playing from the seek") { h.engine.isPlaying && h.engine.position > 3 }
    }

    func testPausingMidFadeParksBothDecks() async throws {
        let first = try tone(4, name: "xfade-pause-1")
        let second = try tone(6, frequency: 550, name: "xfade-pause-2")
        let h = harness(queue: [first, second])
        h.engine.crossfadeDuration = 2.5
        h.engine.load(first, playWhenReady: true)
        await waitUntil("fading", timeout: 8) { h.engine.crossfade.phase == .fading }
        await pause(for: 0.4)
        h.engine.pause()
        await waitUntil("both decks stopped") { !h.engine.deck(.a).isPlaying && !h.engine.deck(.b).isPlaying }
        // A paused AVPlayer settles its reported position onto the audio it had rendered, which
        // moves the fade one last small step; after that it holds.
        await pause(for: 0.3)
        let parked = (h.engine.deck(.a).volume, h.engine.deck(.b).volume)
        await pause(for: 0.5)
        XCTAssertEqual(h.engine.crossfade.phase, .fading, "a pause parks the fade rather than ending it")
        XCTAssertEqual(h.engine.deck(.a).volume, parked.0, accuracy: 0.03)
        XCTAssertEqual(h.engine.deck(.b).volume, parked.1, accuracy: 0.03)

        h.engine.play()
        await waitUntil("both decks running again") { h.engine.deck(.a).isPlaying && h.engine.deck(.b).isPlaying }
        await waitUntil("fade completes", timeout: 6) { !h.engine.isTransitioning }
    }

    func testAnAutomixSpecIsExecutedWithItsCueRateAndFilters() async throws {
        let first = try tone(5, name: "automix-1")
        let second = try tone(8, frequency: 550, name: "automix-2")
        let h = harness(queue: [first, second])
        let planner = FixedPlanner(spec: TransitionSpec(
            startTime: 2.5,
            overlap: 1.5,
            incomingCueTime: 1.0,
            incomingRate: 1.25,
            filters: .keyframes(
                incoming: [
                    TransitionFilterKeyframe(progress: 0, cutoffs: .init(lowPassHz: 20_000, highPassHz: 800)),
                    TransitionFilterKeyframe(progress: 1, cutoffs: .open),
                ],
                outgoing: [
                    TransitionFilterKeyframe(progress: 0, cutoffs: .open),
                    TransitionFilterKeyframe(progress: 1, cutoffs: .init(lowPassHz: 400, highPassHz: 20)),
                ]
            ),
            markerVisible: true
        ))
        h.engine.transitionPlanner = planner
        h.engine.automixEnabled = true
        h.engine.load(first, playWhenReady: true)
        let outgoing = h.engine.activeDeckID
        let incoming: PlaybackDeckID = outgoing == .a ? .b : .a

        await waitUntil("window shown") { h.engine.transitionWindow != nil }
        XCTAssertEqual(h.engine.transitionWindow?.start ?? 0, 0.5, accuracy: 0.01)
        XCTAssertEqual(h.engine.transitionWindow?.end ?? 0, 0.8, accuracy: 0.01)

        let samples = await sample(h) { h.engine.currentItem?.id == second.id && !h.engine.isTransitioning }
        let fading = samples.filter { $0.phase == .fading }
        XCTAssertFalse(fading.isEmpty)
        // The beatmatch stretch stacks on the listener's speed while the tracks overlap…
        let incomingRates = fading.map { incoming == .a ? $0.rateA : $0.rateB }.filter { $0 > 0 }
        XCTAssertFalse(incomingRates.isEmpty)
        for rate in incomingRates { XCTAssertEqual(rate, 1.25, accuracy: 0.01) }
        // …and is undone when the transition finishes.
        XCTAssertEqual(h.engine.deck(incoming).player.defaultRate, 1, accuracy: 0.001)
        XCTAssertEqual(h.delegate.changes.last?.reason, .crossfade)
        XCTAssertNil(h.engine.transitionWindow, "the marker goes as the queue moves on")

        // The incoming track opened at its cue, not at 0:00. The first buffers after a seek start
        // a little before it: the time-pitch stage renders ~0.19 s of look-back (measured at rates
        // 0.8, 1 and 1.25 alike).
        let incomingProcessor = try XCTUnwrap(h.processors[incoming])
        let firstFrame = Double(try XCTUnwrap(incomingProcessor.framePositions.first)) / ToneFile.sampleRate
        XCTAssertGreaterThan(firstFrame, 0.65)
        XCTAssertLessThan(firstFrame, 1.1)
        // Filter automation reached both decks' processors, and both were opened at the end.
        XCTAssertTrue(incomingProcessor.filters.contains { $0.highPassHz > 100 })
        XCTAssertTrue(h.processors[outgoing]?.filters.contains { $0.lowPassHz < 5_000 } == true)
        XCTAssertEqual(incomingProcessor.filters.last, .open)
        XCTAssertEqual(h.processors[outgoing]?.filters.last, .open)
        XCTAssertFalse(planner.contexts.isEmpty)
        XCTAssertEqual(planner.contexts.first?.outgoing.id, first.id)
        XCTAssertEqual(planner.contexts.first?.incoming.id, second.id)
    }

    func testAPlanMarkedAsARealMixLightsTheScrubber() async throws {
        let first = try tone(4, name: "automix-real-1")
        let second = try tone(6, frequency: 550, name: "automix-real-2")
        let h = harness(queue: [first, second])
        let planner = FixedPlanner(spec: TransitionSpec(startTime: 2.5, overlap: 1.2, incomingCueTime: 0.5))
        h.engine.transitionPlanner = planner
        h.engine.automixEnabled = true
        h.engine.load(first, playWhenReady: true)
        await waitUntil("fading", timeout: 8) { h.engine.crossfade.phase == .fading }
        XCTAssertTrue(h.engine.isSmartMixInProgress)
        await waitUntil("done", timeout: 4) { !h.engine.isTransitioning }
        XCTAssertFalse(h.engine.isSmartMixInProgress)
        withExtendedLifetime(planner) {}
    }
}

/// A planner that always answers with the same spec, and remembers what it was asked.
@MainActor
final class FixedPlanner: TransitionPlanning {
    var spec: TransitionSpec?
    var contexts: [TransitionContext] = []

    init(spec: TransitionSpec?) {
        self.spec = spec
    }

    func transitionSpec(for context: TransitionContext) -> TransitionSpec? {
        contexts.append(context)
        return spec
    }
}
