import XCTest
@testable import Automix

/// Analyses persisted as one JSON file per track in an injectable directory.
final class AutomixAnalysisStoreTests: XCTestCase {

    private func makeStore(maxEntries: Int = 2_000) throws -> AutomixAnalysisStore {
        AutomixAnalysisStore(directory: try SyntheticAudio.temporaryDirectory(for: self), maxEntries: maxEntries)
    }

    func testARoundTripKeepsWhatThePlannerReadsAtMillisecondPrecision() throws {
        let store = try makeStore()
        var analysis = AnalysisFixtures.track(id: "abc", vocal: { $0.truncatingRemainder(dividingBy: 7) / 7 })
        analysis.downbeats = [0.123456, 2.0004]
        analysis.energyCurve = [EnergySample(time: 1.00049, energy: 0.3333333)]
        analysis.vocalActivityMask = [0.87654321]
        analysis.lowEnergyCurve = [EnergySample(time: 2, energy: 0.5)]
        analysis.pickupTime = nil
        store.save("abc", analysis)

        let loaded = try XCTUnwrap(AutomixAnalysisStore(directory: store.directory).load("abc"))
        XCTAssertEqual(loaded.status, TrackAnalysis.statusReady)
        XCTAssertEqual(loaded.trackId, "abc")
        XCTAssertEqual(loaded.bpm, analysis.bpm)
        XCTAssertEqual(loaded.beatConfidence, analysis.beatConfidence)
        XCTAssertEqual(loaded.key, "A minor")
        XCTAssertEqual(loaded.downbeats, [0.123, 2.0])
        XCTAssertEqual(loaded.energyCurve, [EnergySample(time: 1.0, energy: 0.333)])
        XCTAssertEqual(loaded.vocalActivityMask, [0.877])
        XCTAssertEqual(loaded.lowEnergyCurve, [EnergySample(time: 2, energy: 0.5)])
        XCTAssertEqual(loaded.mixInCandidates.map(\.type), analysis.mixInCandidates.map(\.type))
        XCTAssertEqual(loaded.audibleStartTime, analysis.audibleStartTime)
        XCTAssertNil(loaded.pickupTime)
        XCTAssertEqual(loaded.contentEndTime, analysis.contentEndTime)
    }

    func testAResultWithoutATempoIsNotStored() throws {
        let store = try makeStore()
        store.save("x", TrackAnalysis(status: TrackAnalysis.statusReady, trackId: "x", duration: 200))
        store.save("  ", AnalysisFixtures.track())
        XCTAssertNil(store.load("x"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).isEmpty)
    }

    func testAnUnreadableFileIsDiscardedRatherThanHalfLoaded() throws {
        let store = try makeStore()
        let file = store.fileURL(for: "broken")
        try Data("{\"bpm\": 12".utf8).write(to: file)
        XCTAssertNil(store.load("broken"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAnEntryFromAnotherSchemaIsDroppedNotMigrated() throws {
        let store = try makeStore()
        let file = store.fileURL(for: "old")
        try Data(#"{"version": 0, "bpm": 120, "beatConfidence": 0.9}"#.utf8).write(to: file)
        XCTAssertNil(store.load("old"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testMissingKeysReadAsDefaultsAndUnknownKeysAreIgnored() throws {
        let store = try makeStore()
        try Data(#"{"version": 1, "bpm": 128.5, "someFutureField": [1, 2]}"#.utf8).write(to: store.fileURL(for: "sparse"))
        let loaded = try XCTUnwrap(store.load("sparse"))
        XCTAssertEqual(loaded.bpm, 128.5)
        XCTAssertEqual(loaded.beatConfidence, 0)
        XCTAssertTrue(loaded.energyCurve.isEmpty)
        XCTAssertTrue(loaded.isUsable)
    }

    func testFileNamesAreJavaStringHashesSoTheyAreStableAcrossLaunches() {
        // Values Java's String.hashCode gives, as Android names the same entries.
        XCTAssertEqual(AutomixAnalysisStore.fileName(for: "hello"), "99162322_5.json")
        XCTAssertEqual(AutomixAnalysisStore.fileName(for: "polygenelubricants"), "2147483648_18.json", "Integer.MIN_VALUE as unsigned")
        XCTAssertEqual(AutomixAnalysisStore.fileName(for: "dQw4w9WgXcQ/a b"), "2785303070_15.json")
        XCTAssertFalse(AutomixAnalysisStore.fileName(for: "a/b").contains("/"))
    }

    func testTheDirectoryIsPrunedOldestFirst() throws {
        let store = try makeStore(maxEntries: 3)
        for index in 0..<5 {
            store.save("track-\(index)", AnalysisFixtures.track(id: "track-\(index)"))
            // Distinct modification times regardless of filesystem timestamp resolution.
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_000_000 + Double(index) * 10)],
                ofItemAtPath: store.fileURL(for: "track-\(index)").path
            )
        }
        let reopened = AutomixAnalysisStore(directory: store.directory)
        XCTAssertNil(reopened.load("track-0"))
        XCTAssertNil(reopened.load("track-1"))
        XCTAssertNotNil(reopened.load("track-2"))
        XCTAssertNotNil(reopened.load("track-4"))
    }

    func testAKnownAbsenceIsRememberedUntilAWrite() throws {
        let store = try makeStore()
        XCTAssertNil(store.load("later"))
        // Written behind the store's back: the cached absence still answers nil…
        let other = AutomixAnalysisStore(directory: store.directory)
        other.save("later", AnalysisFixtures.track(id: "later"))
        XCTAssertNil(store.load("later"))
        // …until this store writes it itself.
        store.save("later", AnalysisFixtures.track(id: "later"))
        XCTAssertNotNil(store.load("later"))
    }
}
