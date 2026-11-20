import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import Downloads

/// Ports DownloadStoreTest: the decisions a download makes before a byte is fetched — what the file
/// is called, whether this device will keep one of it at all, and what goes into the record.
final class DownloadNamingTests: XCTestCase {
    func testOldDownloadMetadataRemainsReadableWithoutAnAddedDate() throws {
        let old = try JSONDecoder().decode(SavedTrackRecord.self, from: Data(#"{"videoId":"abc","title":"Song","artist":"Artist","path":"Tracks/song.m4a"}"#.utf8))
        XCTAssertNil(old.dateAddedSeconds)
        XCTAssertNil(old.albumName)
        XCTAssertEqual(old.origin, .download)
    }

    func testExistingDownloadsUseFileTimeWhenNoCreationTimeWasRecorded() {
        let dates = resolvedDownloadDates(persistedAddedSeconds: nil, fileModifiedMillis: 1_725_000_123_999)
        XCTAssertEqual(dates.added, 1_725_000_123)
        XCTAssertEqual(dates.modified, 1_725_000_123)
    }

    func testPersistedCreationTimeSurvivesLaterFileModifications() {
        let dates = resolvedDownloadDates(persistedAddedSeconds: 1_700_000_000, fileModifiedMillis: 1_725_000_123_999)
        XCTAssertEqual(dates.added, 1_700_000_000)
        XCTAssertEqual(dates.modified, 1_725_000_123)
    }

    func testFlacAndWavMapToTheTypesTheyAre() {
        XCTAssertEqual(DownloadStore.storable("flac")?.fileExtension, "flac")
        XCTAssertEqual(DownloadStore.storable("flac")?.mimeType, "audio/flac")
        // The x- prefix is on the MIME type and not on the extension.
        XCTAssertEqual(DownloadStore.storable("wav")?.fileExtension, "wav")
        XCTAssertEqual(DownloadStore.storable("wav")?.mimeType, "audio/x-wav")
    }

    func testAlacIsFiledAsTheMp4ItActuallyIs() {
        XCTAssertEqual(DownloadStore.storable("alac")?.fileExtension, "m4a")
        XCTAssertEqual(DownloadStore.storable("alac")?.mimeType, "audio/mp4")
        XCTAssertEqual(DownloadStore.storable("eac3-joc")?.fileExtension, "m4a")
    }

    func testCodecsAreMatchedHoweverASourceSpellsThem() {
        XCTAssertEqual(DownloadStore.storable("FLAC")?.fileExtension, "flac")
        XCTAssertEqual(DownloadStore.storable(" x-flac ")?.fileExtension, "flac")
    }

    /// Opus and WebM are nothing to file on iOS for a stronger reason than on Android: AVPlayer
    /// can't play them at all.
    func testAnUnknownOrAbsentCodecIsNothingToFile() {
        XCTAssertNil(DownloadStore.storable(nil))
        XCTAssertNil(DownloadStore.storable(""))
        XCTAssertNil(DownloadStore.storable("opus"))
        XCTAssertNil(DownloadStore.storable("webm"))
        XCTAssertNil(DownloadStore.storable("dsf"))
    }

    func testYoutubeDownloadsRetainTheirCodecAndResolvedBitrate() {
        XCTAssertEqual(youtubeDownloadBadge(extension: "webm", kbps: 160), "OPUS · 160 kbps")
        XCTAssertEqual(youtubeDownloadBadge(extension: "m4a", kbps: 128), "AAC · 128 kbps")
        XCTAssertNil(youtubeDownloadBadge(extension: "webm", kbps: 0))
    }

    func testPremiumSourceBadges() {
        XCTAssertEqual(StreamFormat(codec: "flac").downloadBadge, "FLAC")
        XCTAssertEqual(StreamFormat(codec: "eac3-joc").downloadBadge, "DOLBY")
        XCTAssertNil(StreamFormat(codec: "aac").downloadBadge)
    }

    func testTheNameIsArtistThenTitleAndCarriesTheExtensionAskedFor() {
        XCTAssertEqual(DownloadStore.fileName(for: song("abc123", title: "Kesariya", artist: "Arijit Singh"), extension: "flac"),
                       "Arijit Singh - Kesariya.flac")
    }

    func testCharactersAVolumeOrAShellWouldObjectToAreReplaced() {
        XCTAssertEqual(DownloadStore.fileName(for: song("abc123", title: "A/B: C?", artist: "D|E"), extension: "m4a"), "D E - A B C.m4a")
    }

    func testARowWithNothingToNameItFallsBackToTheVideoId() {
        XCTAssertEqual(DownloadStore.fileName(for: song("xyz789", title: "", artist: ""), extension: "m4a"), "xyz789.m4a")
        XCTAssertEqual(DownloadStore.fileName(for: song("xyz789", title: "Only", artist: ""), extension: "m4a"), "Only.m4a")
    }

    func testVeryLongNamesAreCutShortOfTheFilenameCeiling() {
        let name = DownloadStore.fileName(for: song("x", title: String(repeating: "a", count: 300), artist: "B"), extension: "m4a")
        XCTAssertEqual(name.count, 120 + ".m4a".count)
    }

    func testPathsAreRecordedRelativeToTheStoreRoot() throws {
        let store = DownloadStore(root: try makeTemporaryDirectory())
        let file = store.tracksDirectory.appending(path: "A - B.m4a")
        XCTAssertEqual(store.relativePath(of: file), "Tracks/A - B.m4a")
        XCTAssertEqual(store.url(forRelativePath: "Tracks/A - B.m4a").standardizedFileURL, file.standardizedFileURL)
        XCTAssertNil(store.relativePath(of: URL(fileURLWithPath: "/tmp/elsewhere.m4a")))
    }

    /// Re-fetchable folders are kept out of backups; imports, which can't be fetched again, are not.
    func testBackupExclusionFollowsWhetherAFileCanBeFetchedAgain() throws {
        let store = DownloadStore(root: try makeTemporaryDirectory())
        try store.prepare()
        func excluded(_ url: URL) -> Bool? { try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup }
        XCTAssertEqual(excluded(store.tracksDirectory), true)
        XCTAssertEqual(excluded(store.artworkDirectory), true)
        XCTAssertEqual(excluded(store.importedDirectory), false)
    }

    func testAPendingFileIsInvisibleUntilCommittedAndGoneWhenAborted() throws {
        let store = DownloadStore(root: try makeTemporaryDirectory())
        let pending = try store.begin(name: "A - B.m4a", token: "t1")
        try Data("abc".utf8).write(to: pending.partURL)
        XCTAssertNil(store.existing(name: "A - B.m4a"))
        let url = try pending.commit()
        XCTAssertEqual(store.existing(name: "A - B.m4a")?.standardizedFileURL, url.standardizedFileURL)

        let second = try store.begin(name: "C - D.m4a", token: "t2")
        second.abort()
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.partURL.path(percentEncoded: false)))
    }

    func testResumingKeepsExactlyTheCheckpointedBytes() throws {
        let store = DownloadStore(root: try makeTemporaryDirectory())
        let first = try store.begin(name: "X.m4a", token: "j")
        try Data(repeating: 1, count: 1_000).write(to: first.partURL)
        let resumed = try store.begin(name: "X.m4a", token: "j", resumeAt: 600)
        XCTAssertEqual(resumed.partSize, 600, "bytes past the checkpoint may be half a range")
        let fresh = try store.begin(name: "X.m4a", token: "j")
        XCTAssertEqual(fresh.partSize, 0)
    }
}

/// What quality a download asks the resolver for, and that the streaming ceilings have no say.
@MainActor
final class DownloadQualityRequestTests: XCTestCase {
    /// Only the top rung is worth a source's own file; Standard is YouTube's capped AAC rung.
    func testEachRungAsksTheResolverForTheMatchingRequest() async throws {
        let cases: [(DownloadQuality, StreamRequest.Tier)] = [(.lossless, .lossless), (.high, .best), (.standard, .capped(kbps: 128))]
        for (quality, tier) in cases {
            let harness = DownloadHarness(root: try makeTemporaryDirectory())
            harness.settings.downloadQuality = quality
            harness.manager.enqueue(song("q"))
            await harness.manager.waitUntilIdle()
            XCTAssertEqual(harness.resolver.requests.first?.tier, tier, "\(quality)")
            XCTAssertEqual(harness.resolver.requests.first?.purpose, .download)
        }
    }

    /// High means "the best rung there is": no cap, rather than a very high one.
    func testHighIsUncappedRatherThanCappedVeryHigh() {
        XCTAssertNil(DownloadQuality.high.maxKbps)
        XCTAssertNil(StreamRequest.download(.high).maxKbps)
    }

    func testEveryDownloadRungIsDescribable() {
        for quality in DownloadQuality.allCases {
            XCTAssertFalse(quality.label.isEmpty)
            XCTAssertFalse(quality.detail.isEmpty)
            XCTAssertFalse(quality.perTrack.isEmpty)
        }
    }

    /// A capped mobile-data *stream* must not quietly downgrade a *file*: someone with their own
    /// FLAC server once streamed the FLAC and downloaded a transcode of the same recording.
    func testACappedStreamingCeilingDoesNotDecideWhatADownloadKeeps() async throws {
        let harness = DownloadHarness(root: try makeTemporaryDirectory(), network: .cellular)
        harness.settings.audioQualityCellular = .low
        harness.settings.wifiOnlyDownloads = false
        harness.settings.downloadQuality = .lossless
        XCTAssertEqual(harness.settings.effectiveAudioQuality(for: .cellular), .low)
        harness.manager.enqueue(song("q"))
        await harness.manager.waitUntilIdle()
        XCTAssertEqual(harness.resolver.requests.first?.tier, .lossless)
    }

    /// Read once per track: a setting changed while a track is in flight applies to the next one,
    /// and a re-resolve asks for the rung the track started on.
    func testTheQualityIsPinnedForTheWholeOfATrack() async throws {
        let body = Data((0..<3_000).map { UInt8(truncatingIfNeeded: $0) })
        let refusedOnce = LockedFlag()
        let harness = DownloadHarness(root: try makeTemporaryDirectory(), chunkBytes: 1_000)
        harness.settings.downloadQuality = .high
        harness.resolver.answer { song, _ in
            ResolvedStream(url: googleVideoURL(song.videoId, length: body.count), origin: .youtube, mimeType: "audio/mp4", format: StreamFormat(codec: "aac", kbps: 128))
        }
        harness.stub.register(host: "rr1---sn-test.googlevideo.com") { request in
            if request.value(forHTTPHeaderField: "Range") == "bytes=1000-1999", refusedOnce.set() {
                // Change the setting between the first request and the re-resolve.
                DispatchQueue.main.sync { MainActor.assumeIsolated { harness.settings.downloadQuality = .standard } }
                return .status(403)
            }
            return try rangeResponder(body)(request)
        }
        harness.manager.enqueue(song("pin"))
        await harness.manager.waitUntilIdle()
        XCTAssertEqual(harness.resolver.requests.map(\.tier), [.best, .best])
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    /// Sets the flag; true only the first time.
    func set() -> Bool {
        lock.withLock {
            defer { value = true }
            return !value
        }
    }

    var isSet: Bool { lock.withLock { value } }
}
