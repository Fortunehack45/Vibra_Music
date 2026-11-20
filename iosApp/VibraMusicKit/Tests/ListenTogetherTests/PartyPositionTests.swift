import XCTest
@testable import ListenTogether

/// The playhead arithmetic: anchor + elapsed while playing, frozen while paused, clamped
/// to the track, and the scheduled-resume wait. Mirrors the server's `PositionAt` plus the
/// client's clock translation.
final class PartyPositionTests: XCTestCase {
    private func playingState(anchorMs: Int64 = 1_757_630_001_234) -> PartySessionState {
        PartySessionState(
            code: "J4M001",
            playback: PartyPlayback(
                track: PartyTrack(videoId: "v", durationMs: 212_000),
                isPlaying: true, positionMs: 42_000, anchorMs: anchorMs,
                effectivePositionMs: 42_350),
            clockSynced: true)
    }

    func testPlayingPositionAdvancesWithServerClock() {
        let state = playingState()
        // 350 ms after the anchor: exactly where the song has got to.
        XCTAssertEqual(42_350, state.positionMs(serverNowMs: 1_757_630_001_584))
    }

    func testPositionNeverRunsBeforeTheAnchor() {
        // A resume scheduled into the future holds at the position until the instant.
        let state = playingState()
        XCTAssertEqual(42_000, state.positionMs(serverNowMs: 1_757_630_001_000))
    }

    func testPositionClampsToDuration() {
        let state = playingState()
        XCTAssertEqual(212_000, state.positionMs(serverNowMs: 1_757_630_001_234 + 300_000))
    }

    func testPausedPositionIsFrozen() {
        var state = playingState()
        state.playback.isPlaying = false
        XCTAssertEqual(42_000, state.positionMs(serverNowMs: 1_757_630_009_999))
    }

    func testNoTrackIsNoPosition() {
        var state = playingState()
        state.playback.track = nil
        XCTAssertNil(state.positionMs(serverNowMs: 1_757_630_001_584))
    }

    /// Through the client, whose clock is what makes `serverNowMs` nil: until the first pong
    /// there is no offset, so the playhead is the server's own reading, and the first sample
    /// switches it to anchor-plus-elapsed.
    func testUnsyncedClockFallsBackToServerReading() async throws {
        let anchor: Int64 = 1_757_630_001_234
        let (store, _) = try PartyTestFixtures.makeStore()
        let clock = PartyServerClock(monotonicMs: { 0 })
        let client = PartyClient(store: store, urlSession: .shared, clock: clock)
        await client.commitMembershipForTesting(
            serverBase: "https://default.example.com",
            membership: PartyTestFixtures.membership(playback: PartyPlayback(
                seq: 1, track: PartyTrack(videoId: "v", durationMs: 212_000),
                isPlaying: true, positionMs: 42_000, anchorMs: anchor, effectivePositionMs: 42_350)))

        let before = await client.partyPositionMs()
        XCTAssertEqual(42_350, before)

        clock.record(sentAtLocalMs: 0, serverMs: anchor + 1_000, receivedAtLocalMs: 0)
        let after = await client.partyPositionMs()
        XCTAssertEqual(43_000, after)
    }

    /// A member's seek goes out to the whole party with an upper bound nobody checks (the
    /// server only floors it at 0), and a seek to just under Int64.max made `positionMs + elapsed`
    /// overflow a second later on every iOS client in the party. A custom server can also send
    /// numbers past Int64 (`1e19`, `-9.3e18`), which trapped in decoding.
    func testHostileNumbersInAStateFrameNeitherTrapNorOverflow() throws {
        let anchor: Int64 = 1_757_630_001_234
        let seek = #"{"type":"state","playback":{"isPlaying":true,"positionMs":9223372036854774784,"anchorMs":\#(anchor),"track":{"videoId":"v"}}}"#
        let seeked = try PartySessionState(code: "J4M001", playback: decodePlayback(seek), clockSynced: true)
        XCTAssertEqual(partyMaxExactInteger + 5_000, seeked.positionMs(serverNowMs: anchor + 5_000))

        let wild = #"{"type":"state","serverMs":1e300,"playback":{"seq":1e19,"isPlaying":true,"positionMs":1e19,"anchorMs":-9.3e18,"track":{"videoId":"v","durationMs":9223372036854775807}}}"#
        let state = try PartySessionState(code: "J4M001", playback: decodePlayback(wild), clockSynced: true)
        XCTAssertEqual(partyMaxExactInteger, state.playback.seq)
        XCTAssertEqual(-partyMaxExactInteger, state.playback.anchorMs)
        XCTAssertEqual(partyMaxExactInteger, state.playback.track?.durationMs)
        XCTAssertEqual(partyMaxExactInteger, state.positionMs(serverNowMs: anchor), "clamped to the (clamped) duration")
        XCTAssertEqual(0, state.msUntilStart(serverNowMs: anchor))
    }

    private func decodePlayback(_ frame: String) throws -> PartyPlayback {
        try XCTUnwrap(JSONDecoder().decode(PartyServerMessage.self, from: Data(frame.utf8)).playback)
    }

    func testMsUntilStart() {
        let state = playingState()
        // 234 ms before the scheduled instant.
        XCTAssertEqual(234, state.msUntilStart(serverNowMs: 1_757_630_001_000))
        XCTAssertEqual(0, state.msUntilStart(serverNowMs: 1_757_630_001_584))
        var paused = state
        paused.playback.isPlaying = false
        XCTAssertEqual(0, paused.msUntilStart(serverNowMs: 1_757_630_001_000))
        XCTAssertEqual(0, state.msUntilStart(serverNowMs: nil))
    }
}
