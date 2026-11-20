import AVFoundation
import XCTest
@testable import Playback

/// A quality upgrade's swap moves the track onto another copy of the same recording while it plays
/// (``AudioPlayerEngine/replaceCurrent(with:)``). Where the copy stands when the crossover begins is
/// the whole of whether the listener hears a moment twice (behind the playhead) or misses one (ahead).
@MainActor
final class UpgradeSwapTests: EngineTestCase {
    /// Plays a track, swaps another copy of it in, and answers how that copy stood against the
    /// playing one as the crossover began.
    private func swap(copyHasTap: Bool) async throws -> (skew: TimeInterval, inStep: Bool) {
        let current = try tone(20, frequency: 440, name: "swap-current-\(copyHasTap)")
        let better = PlayableItem.file(try ToneFile.tone(20, frequency: 660, in: directory, name: "swap-better-\(copyHasTap)"),
                                       id: "swap-better-\(copyHasTap)")
        let h = harness(queue: [current])
        h.engine.load(current, playWhenReady: true)
        await waitUntil("playing", timeout: 10) { h.engine.isPlaying && h.engine.position > 0.5 }
        // A lossless copy runs with no processing tap where the lossy one has one, so the two decks
        // take different times to sound once told to play.
        let standby: PlaybackDeckID = h.engine.activeDeckID == .a ? .b : .a
        h.processors[standby]?.alters = copyHasTap

        h.engine.replaceCurrent(with: better)
        await waitUntil("the copy is swapped in", timeout: 20) { h.engine.currentItem?.id == better.id }
        return try XCTUnwrap(h.engine.lastSwap, "the swap cut over instead of crossing over")
    }

    func testTheCopyIsStartedInStepWithThePlayingOneWhenItHasNoTap() async throws {
        let landed = try await swap(copyHasTap: false)
        XCTAssertTrue(landed.inStep, "the copy was started by the host clock")
        XCTAssertEqual(landed.skew, 0, accuracy: 0.04, "the copy began \(Int(landed.skew * 1_000)) ms off the playhead (negative: a repeat)")
    }

    func testTheCopyIsStartedInStepWithThePlayingOneWhenItHasATap() async throws {
        let landed = try await swap(copyHasTap: true)
        XCTAssertTrue(landed.inStep, "the copy was started by the host clock")
        XCTAssertEqual(landed.skew, 0, accuracy: 0.04, "the copy began \(Int(landed.skew * 1_000)) ms off the playhead (negative: a repeat)")
    }
}
