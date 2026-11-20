import AVFoundation
import VibraMusicCore
import XCTest
@testable import Playback

/// With crossfade off, the next item is preloaded on the same queue player and follows without a
/// gap; the app hears about the change so it can move its queue.
@MainActor
final class GaplessAdvanceTests: EngineTestCase {
    func testTheNextItemIsPreloadedAndFollowsGaplessly() async throws {
        let first = try tone(1.2, frequency: 440, name: "gapless-1")
        let second = try tone(2, frequency: 660, name: "gapless-2")
        let h = harness(queue: [first, second])
        h.engine.load(first, playWhenReady: true)
        XCTAssertEqual(h.engine.upcomingItem?.id, second.id, "the delegate is asked what follows at once")

        // Preloaded behind the playing item on the same player, long before the boundary.
        let deckID = h.engine.activeDeckID
        await waitUntil("preloaded") { h.engine.deck(deckID).queued?.item.id == second.id }
        XCTAssertLessThan(h.engine.position, 1.0)

        await waitUntil("advanced", timeout: 5) { h.engine.currentItem?.id == second.id }
        XCTAssertEqual(h.delegate.changes.map(\.reason), [.requested, .ended])
        XCTAssertEqual(h.engine.activeDeckID, deckID, "a gapless advance stays on the same player")
        XCTAssertTrue(h.engine.playWhenReady)
        // The queue player moved on by itself, so the new item is already playing from its start.
        await waitUntil("second playing") { h.engine.isPlaying }
        XCTAssertLessThan(h.engine.position, 0.6)
        XCTAssertEqual(h.engine.duration, 2, accuracy: 0.05)

        // Both items went through the same deck's processor, each announced before its audio.
        let processor = try XCTUnwrap(h.processors[deckID])
        await waitUntil("second announced to the processor") { processor.begunItems.contains { $0.id == second.id } }
        XCTAssertEqual(processor.begunItems.first?.id, first.id)
        // Nothing was loaded on the other deck.
        XCTAssertEqual(h.processors[deckID == .a ? .b : .a]?.frames, 0)
    }

    func testRepeatOneLoopsTheItemGaplessly() async throws {
        let item = try tone(1, name: "gapless-repeat")
        let h = harness(queue: [item])
        h.delegate.repeatOne = true
        h.engine.crossfadeDuration = 5 // Repeat-one must never crossfade a track into itself.
        h.engine.load(item, playWhenReady: true)
        await waitUntil("looped", timeout: 5) { h.delegate.changes.count >= 2 }
        XCTAssertEqual(h.delegate.changes.map(\.reason).prefix(2), [.requested, .repeated])
        XCTAssertEqual(h.engine.currentItem?.id, item.id)
        XCTAssertFalse(h.engine.isTransitioning)
        await waitUntil("playing the loop") { h.engine.isPlaying }
    }

    func testLoadingThePreloadedItemUsesItAtOnce() async throws {
        // "Next" pressed with the next item already preloaded: no reopening, no buffering.
        let first = try tone(5, name: "gapless-skip-1")
        let second = try tone(5, frequency: 550, name: "gapless-skip-2")
        let h = harness(queue: [first, second])
        h.engine.load(first, playWhenReady: true)
        let deckID = h.engine.activeDeckID
        await waitUntil("preloaded") { h.engine.deck(deckID).queued?.item.id == second.id }

        let preloaded = try XCTUnwrap(h.engine.deck(deckID).queued)
        XCTAssertTrue(h.engine.skipToNext())
        XCTAssertEqual(h.engine.currentItem?.id, second.id)
        XCTAssertTrue(h.engine.deck(deckID).current === preloaded, "the preloaded copy starts without reopening")
        XCTAssertFalse(h.engine.isLoadingItem)
        XCTAssertEqual(h.delegate.changes.last?.reason, .requested)
        await waitUntil("second playing") { h.engine.isPlaying }
        XCTAssertFalse(h.engine.skipToNext(), "nothing follows the last item")
    }

    /// Skip timing is measured from this log line. A preloaded start used to log "at once" as the
    /// skip happened, before anything sounded (a playlist's row was still waiting a second later).
    func testAPreloadedStartLogsItsFirstAudioWhenItPlaysWithTheDelay() async throws {
        let first = try tone(5, name: "gapless-timed-1")
        let second = try tone(5, frequency: 550, name: "gapless-timed-2")
        let h = harness(queue: [first, second])
        h.engine.load(first, playWhenReady: true)
        let deckID = h.engine.activeDeckID
        await waitUntil("preloaded") { h.engine.deck(deckID).queued?.item.id == second.id }
        await waitUntil("first playing") { h.engine.isPlaying }

        XCTAssertTrue(h.engine.skipToNext())

        let logged = { TrackLog.shared.heldLines.map(\.text).filter { $0.contains("first audio for \(second.id) ") } }
        await waitUntil("its first audio is logged") { !logged().isEmpty }
        XCTAssertTrue(h.engine.deck(deckID).isPlaying, "logged only once the player plays")
        XCTAssertEqual(logged().count, 1)
        XCTAssertTrue(logged().first?.hasSuffix("ms after it was asked for") == true, "the real delay: \(logged())")
    }

    func testASeekStillLandingWhenTheNextItemStartsLeavesThePositionToTheNextItem() async throws {
        let first = try tone(5, name: "gapless-seek-1")
        let second = try tone(5, frequency: 550, name: "gapless-seek-2")
        let h = harness(queue: [first, second])
        h.engine.load(first, playWhenReady: true)
        let deckID = h.engine.activeDeckID
        await waitUntil("preloaded") { h.engine.deck(deckID).queued?.item.id == second.id }

        // The seek's completion runs on a later main-queue turn, so "next" lands before it.
        h.engine.seek(to: 3)
        XCTAssertTrue(h.engine.skipToNext())
        await waitUntil("second playing") { h.engine.isPlaying }
        await waitUntil("the old seek's completion ran") { h.engine.deck(deckID).player.currentTime().seconds > 0.2 }
        XCTAssertLessThan(h.engine.deck(deckID).position, 2, "the first item's seek target is not the second item's position")
    }

    func testAQueueEditReplacesThePreloadedItem() async throws {
        let first = try tone(5, name: "gapless-edit-1")
        let second = try tone(2, frequency: 550, name: "gapless-edit-2")
        let inserted = try tone(2, frequency: 770, name: "gapless-edit-3")
        let h = harness(queue: [first, second])
        h.engine.load(first, playWhenReady: true)
        let deckID = h.engine.activeDeckID
        await waitUntil("preloaded") { h.engine.deck(deckID).queued?.item.id == second.id }

        // "Play next".
        h.delegate.queue = [first, inserted, second]
        h.engine.upcomingItemDidChange()
        XCTAssertEqual(h.engine.upcomingItem?.id, inserted.id)
        await waitUntil("re-preloaded") { h.engine.deck(deckID).queued?.item.id == inserted.id }

        // End of queue: nothing preloaded.
        h.delegate.queue = [first]
        h.engine.upcomingItemDidChange()
        XCTAssertNil(h.engine.upcomingItem)
        XCTAssertNil(h.engine.deck(deckID).queued)
    }
}
