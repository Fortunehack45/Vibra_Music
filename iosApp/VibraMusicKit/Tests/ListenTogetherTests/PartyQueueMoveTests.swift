import VibraMusicCore
import XCTest
@testable import ListenTogether

/// Ports `PartyQueueMoveTest` (party-state parts; pure queue logic itself belongs to
/// PlaybackQueue): the autoplay section marker on the wire, single-move deltas, the
/// playback/queue sequence contract, and track↔song tier mapping.
final class PartyQueueMoveTests: XCTestCase {
    func testPartyTrackKeepsAutoplaySectionMetadataOnTheWire() throws {
        let encoded = try JSONEncoder().encode(PartyTrack(videoId: "A", fromAutoplay: true))
        let decoded = try JSONDecoder().decode(PartyTrack.self, from: encoded)
        XCTAssertTrue(decoded.fromAutoplay)
    }

    func testDetectSingleMoveForward() {
        let delta = partyDetectSingleMove(oldList: ["A", "B", "C", "D"], newList: ["A", "C", "D", "B"])
        XCTAssertEqual(1, delta?.fromIndex)
        XCTAssertEqual(3, delta?.toIndex)
        XCTAssertEqual("B", delta?.videoId)
    }

    func testDetectSingleMoveBackward() {
        let delta = partyDetectSingleMove(oldList: ["A", "C", "D", "B"], newList: ["A", "B", "C", "D"])
        XCTAssertEqual(3, delta?.fromIndex)
        XCTAssertEqual(1, delta?.toIndex)
        XCTAssertEqual("B", delta?.videoId)
    }

    func testDetectSingleMoveWithBaseOffset() {
        let delta = partyDetectSingleMove(oldList: ["B", "C", "D"], newList: ["D", "B", "C"], baseOffset: 5)
        XCTAssertEqual(7, delta?.fromIndex)
        XCTAssertEqual(5, delta?.toIndex)
        XCTAssertEqual("D", delta?.videoId)
    }

    func testIdenticalListsReturnNil() {
        XCTAssertNil(partyDetectSingleMove(oldList: ["A", "B", "C"], newList: ["A", "B", "C"]))
    }

    func testDifferentSizesReturnNil() {
        XCTAssertNil(partyDetectSingleMove(oldList: ["A", "B"], newList: ["A", "B", "C"]))
    }

    func testMultipleSwapsReturnNil() {
        XCTAssertNil(partyDetectSingleMove(
            oldList: ["A", "B", "C", "D"], newList: ["B", "A", "D", "C"]))
    }

    func testDuplicatesInList() {
        let oldList = ["A", "B", "A", "C"]
        let newList = ["A", "A", "B", "C"]
        let delta = partyDetectSingleMove(oldList: oldList, newList: newList)
        XCTAssertNotNil(delta)
        // Applying the detected delta must reproduce the new list.
        var applied = oldList
        let item = applied.remove(at: delta!.fromIndex)
        applied.insert(item, at: delta!.toIndex)
        XCTAssertEqual(newList, applied)
    }

    func testPlaybackSerializationPreservesSeparateSequences() throws {
        let playback = PartyPlayback(
            seq: 10, queueSeq: 25, queueIndex: 2, isPlaying: true,
            positionMs: 5_000, anchorMs: 100_000)
        let decoded = try JSONDecoder().decode(
            PartyPlayback.self, from: try JSONEncoder().encode(playback))
        XCTAssertEqual(10, decoded.seq)
        XCTAssertEqual(25, decoded.queueSeq)
        XCTAssertTrue(decoded.isPlaying)
        XCTAssertEqual(5_000, decoded.positionMs)
        XCTAssertEqual(100_000, decoded.anchorMs)
    }

    func testAQueueFrameLeavesThePlaybackSeqAlone() async throws {
        let (store, _) = try PartyTestFixtures.makeStore()
        let client = PartyTestFixtures.makeClient(store: store)
        await client.commitMembershipForTesting(
            serverBase: "https://default.example.com",
            membership: PartyTestFixtures.membership(
                playback: PartyPlayback(seq: 5, queueSeq: 1, isPlaying: true, positionMs: 12_000, anchorMs: 50_000),
                queue: PartyQueue(seq: 1, index: 0, items: [PartyTestFixtures.track("a")])))

        await client.receiveForTesting(
            #"{"type":"queue","queue":{"seq":2,"index":0,"items":[{"videoId":"a"},{"videoId":"b"}]}}"#)

        let state = await client.state
        XCTAssertEqual(2, state.queue.seq)
        XCTAssertEqual(5, state.playback.seq)
        XCTAssertEqual(50_000, state.playback.anchorMs)
        XCTAssertEqual(12_000, state.playback.positionMs)
    }

    func testPartyTrackToSongMapsTiersCorrectly() {
        XCTAssertEqual(
            QueueTier.userQueue,
            PartyTrackMapping.toSong(PartyTrack(videoId: "manual", fromAutoplay: false)).queueTier)
        XCTAssertEqual(
            QueueTier.autoplay,
            PartyTrackMapping.toSong(PartyTrack(videoId: "auto", fromAutoplay: true)).queueTier)
    }

    func testSongToPartyTrackMapsAutoplayFlagCorrectly() {
        XCTAssertTrue(PartyTrackMapping.toPartyTrack(
            Song(videoId: "1", title: "1", artist: "A", queueTier: .autoplay),
            playerDurationMs: 1_000).fromAutoplay)
        XCTAssertFalse(PartyTrackMapping.toPartyTrack(
            Song(videoId: "2", title: "2", artist: "A", queueTier: .userQueue),
            playerDurationMs: 1_000).fromAutoplay)
        XCTAssertFalse(PartyTrackMapping.toPartyTrack(
            Song(videoId: "3", title: "3", artist: "A", queueTier: .context),
            playerDurationMs: 1_000).fromAutoplay)
    }

    func testTrackRoundTripPreservesDurationTextForMatching() {
        // `durationText` is what a cross-source match is made on: it must survive the trip.
        let song = Song(videoId: "v", title: "T", artist: "A", durationText: "3:32")
        let track = PartyTrackMapping.toPartyTrack(song, playerDurationMs: 0)
        XCTAssertEqual(212_000, track.durationMs)
        XCTAssertEqual("3:32", PartyTrackMapping.toSong(track).durationText)
    }

    func testPlayerDurationWinsOverRowClaim() {
        let song = Song(videoId: "v", title: "T", artist: "A", durationText: "3:32")
        let track = PartyTrackMapping.toPartyTrack(song, playerDurationMs: 215_000)
        XCTAssertEqual(215_000, track.durationMs)
    }
}
