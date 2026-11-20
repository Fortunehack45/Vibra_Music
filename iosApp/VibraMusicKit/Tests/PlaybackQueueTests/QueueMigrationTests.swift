import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import PlaybackQueue

/// Ports QueueMigrationTest: snapshots written before queue tiers existed still restore with the
/// right tier, and tiered entries round-trip. The iOS snapshot stores Core's Song JSON, whose
/// pre-tier form carried a `fromAutoplay` flag (Android's snapshot called it `auto`).
final class QueueMigrationTests: XCTestCase {

    private func restore(_ json: String) throws -> LastPlayedSnapshot? {
        let directory = try makeTemporaryDirectory()
        try Data(json.utf8).write(to: directory.appending(path: LastPlayedStore.queueFile))
        return LastPlayedStore(store: JSONFileStore(directory: directory)).load()
    }

    func testALegacySnapshotWithAutoplayOffRestoresAsContext() throws {
        let snapshot = try XCTUnwrap(restore(#"{"tracks":[{"videoId":"v1","title":"Song 1","artist":"Artist 1","fromAutoplay":false}]}"#))
        XCTAssertEqual(snapshot.songs.first?.queueTier, .context)
    }

    func testALegacySnapshotWithAutoplayOnRestoresAsAutoplay() throws {
        let snapshot = try XCTUnwrap(restore(#"{"tracks":[{"videoId":"v2","title":"Song 2","artist":"Artist 2","fromAutoplay":true}]}"#))
        XCTAssertEqual(snapshot.songs.first?.queueTier, .autoplay)
    }

    func testAUserQueueEntryAndItsEntryIdRoundTrip() throws {
        let directory = try makeTemporaryDirectory()
        let song = Song(videoId: "v3", title: "Song 3", artist: "Artist 3", queueTier: .userQueue, queueEntryId: "uuid-entry-3")
        LastPlayedStore(store: JSONFileStore(directory: directory)).saveQueueImmediately([song], index: 0, positionMs: 0)
        let decoded = try XCTUnwrap(LastPlayedStore(store: JSONFileStore(directory: directory)).load()).songs[0]
        XCTAssertEqual(decoded.queueTier, .userQueue)
        XCTAssertEqual(decoded.queueEntryId, "uuid-entry-3")
    }

    func testIndexAndPositionFromBeforeTheyMovedToTheirOwnFileStillRestore() throws {
        let json = #"{"tracks":[{"videoId":"a","title":"A","artist":"X"},{"videoId":"b","title":"B","artist":"X"}],"index":1,"positionMs":61000}"#
        let snapshot = try XCTUnwrap(restore(json))
        XCTAssertEqual(snapshot.index, 1)
        XCTAssertEqual(snapshot.positionMs, 61_000)
    }

    func testUnknownTiersKeysAndAnOutOfRangeIndexStillRestore() throws {
        let json = #"{"tracks":[{"videoId":"a","title":"A","artist":"X","queueTier":"SOMETHING_NEW","future":1}],"index":9,"extra":true}"#
        let snapshot = try XCTUnwrap(restore(json))
        XCTAssertEqual(snapshot.songs.first?.queueTier, .context)
        XCTAssertEqual(snapshot.index, 0)
    }

    func testACorruptOrEmptySnapshotRestoresNothing() throws {
        XCTAssertNil(try restore("{not json"))
        XCTAssertNil(try restore(#"{"tracks":[]}"#))
    }

    /// A snapshot recorded from this store, checked in: if this breaks, queues saved by a shipped
    /// build stop restoring.
    func testTheRecordedSnapshotShapeRestores() throws {
        let fixtures = FixtureLoader(bundle: .module)
        let directory = try makeTemporaryDirectory()
        try fixtures.data("last_played_queue.json").write(to: directory.appending(path: LastPlayedStore.queueFile))
        try fixtures.data("last_played_state.json").write(to: directory.appending(path: LastPlayedStore.stateFile))
        let snapshot = try XCTUnwrap(LastPlayedStore(store: JSONFileStore(directory: directory)).load())
        XCTAssertEqual(snapshot.songs.map(\.videoId), ["kffacxfA7G4", "2Vv-BfVoq4g", "JGwWNGJdvx8"])
        XCTAssertEqual(snapshot.songs.map(\.queueTier), [.context, .userQueue, .autoplay])
        XCTAssertEqual(snapshot.songs[1].queueEntryId, "8c1f0f55-4f5a-4c1e-9d0b-2b4b9d6f3a10")
        XCTAssertEqual(snapshot.songs[0].playbackSource, "Divide")
        XCTAssertEqual(snapshot.songs[0].playbackSourceType, .browse)
        XCTAssertEqual(snapshot.songs[2].radioName, "Perfect")
        XCTAssertEqual(snapshot.index, 1)
        XCTAssertEqual(snapshot.positionMs, 83_500)
    }
}
