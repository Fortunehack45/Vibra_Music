import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import AudioCache

/// Fetched ranges go to a sparse file plus a range index, survive reopening, and serve reads with
/// the network gone.
final class CachePersistenceTests: XCTestCase {
    func testFetchedRangesSurviveReopening() async throws {
        let directory = try makeTemporaryDirectory()
        let server = RangeServer()
        let body = patternData(count: 3_000_000)
        let url = googlevideoURL(client: "IOS", length: body.count)
        server.host(body, at: url)
        let key = AudioCacheKey.youtube(videoId: "persist")
        do {
            let cache = try makeCache(directory: directory)
            let source = HTTPAudioSource(stream: stream(url, length: body.count), session: server.session)
            _ = try await readThroughCache(cache, key: key, source: source, range: 0..<500_000)
            _ = try await readThroughCache(cache, key: key, source: source, range: 2_000_000..<2_600_000)
            await cache.flush()
        }

        let reopened = try makeCache(directory: directory)
        let ranges = await reopened.cachedRanges(of: key)
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertGreaterThanOrEqual(ranges.first?.upperBound ?? 0, 500_000)
        XCTAssertTrue(ranges.contains { $0.lowerBound == 2_000_000 && $0.upperBound >= 2_600_000 })
        let length = await reopened.contentLength(of: key)
        XCTAssertEqual(length, 3_000_000)

        server.offline = true
        let head = try await readThroughCache(reopened, key: key, source: nil, range: 0..<500_000)
        let middle = try await readThroughCache(reopened, key: key, source: nil, range: 2_000_000..<2_600_000)
        XCTAssertEqual(head, body.subdata(in: 0..<500_000))
        XCTAssertEqual(middle, body.subdata(in: 2_000_000..<2_600_000), "bytes sit at their real offsets in the sparse file")
    }

    func testFullyCachedTrackReplaysWithTheNetworkGone() async throws {
        let directory = try makeTemporaryDirectory()
        let server = RangeServer()
        let body = patternData(count: 1_700_000)
        let url = googlevideoURL(client: "ANDROID_VR", length: body.count)
        server.host(body, at: url)
        let key = AudioCacheKey.youtube(videoId: "airplane")
        let source = HTTPAudioSource(stream: stream(url, length: body.count), session: server.session)
        let cache = try makeCache(directory: directory)

        let first = try await readThroughCache(cache, key: key, source: source, range: 0..<Int64(body.count))
        XCTAssertEqual(first, body)
        server.offline = true
        let requestsBefore = server.requests.count

        let replay = try await readThroughCache(cache, key: key, source: source, range: 0..<Int64(body.count))
        let reopened = try makeCache(directory: directory)
        let afterRestart = try await readThroughCache(reopened, key: key, source: source, range: 0..<Int64(body.count))

        XCTAssertEqual(replay, body)
        XCTAssertEqual(afterRestart, body)
        XCTAssertEqual(server.requests.count, requestsBefore, "nothing was asked of the network")
    }

    func testUncachedBytesOfflineFailWithTheNetworkError() async throws {
        let server = RangeServer()
        // Long enough that reading the opening (and the megabyte a fetch reads on) leaves a hole.
        let body = patternData(count: 4_000_000)
        let url = googlevideoURL(client: "IOS", length: body.count)
        server.host(body, at: url)
        let key = AudioCacheKey.youtube(videoId: "partial")
        let source = HTTPAudioSource(stream: stream(url, length: body.count), session: server.session)
        let cache = try makeCache()
        _ = try await readThroughCache(cache, key: key, source: source, range: 0..<100_000)
        await eventually { !(await cache.store.isFetching(key)) }
        let opening = await cache.cachedRanges(of: key)
        XCTAssertEqual(opening, [0..<AudioCacheStore.lingerBytes])
        server.offline = true

        let cached = try await readThroughCache(cache, key: key, source: source, range: 0..<100_000)
        XCTAssertEqual(cached, body.subdata(in: 0..<100_000))
        do {
            _ = try await readThroughCache(cache, key: key, source: source, range: 3_900_000..<4_000_000)
            XCTFail("a hole can't be read offline")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    func testUnknownTrackWithoutASourceIsNotCached() async throws {
        let cache = try makeCache()
        do {
            _ = try await readThroughCache(cache, key: AudioCacheKey(rawValue: "never"), source: nil, range: 0..<10)
            XCTFail("expected notCached")
        } catch {
            XCTAssertEqual(error as? AudioCacheError, .notCached(AudioCacheKey(rawValue: "never")))
        }
    }

    func testReopeningDropsSpansPastTheEndOfATruncatedFile() async throws {
        let directory = try makeTemporaryDirectory()
        let source = MemoryAudioSource(patternData(count: 2_000_000))
        let key = AudioCacheKey.youtube(videoId: "truncated")
        do {
            let cache = try makeCache(directory: directory)
            _ = try await readThroughCache(cache, key: key, source: source, range: 0..<2_000_000)
            await cache.flush()
        }
        let dataFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.pathExtension == "audio" })
        let handle = try FileHandle(forWritingTo: dataFile)
        try handle.truncate(atOffset: 1_200_000)
        try handle.close()

        let reopened = try makeCache(directory: directory)
        let ranges = await reopened.cachedRanges(of: key)

        XCTAssertFalse(ranges.isEmpty)
        XCTAssertLessThanOrEqual(ranges.last?.upperBound ?? .max, 1_200_000)
        let data = try await readThroughCache(reopened, key: key, source: source, range: 0..<2_000_000)
        XCTAssertEqual(data, source.data, "what was dropped is fetched again")
    }

    func testReopeningForgetsEntriesWhoseBytesWerePurged() async throws {
        let directory = try makeTemporaryDirectory()
        let source = MemoryAudioSource(patternData(count: 400_000))
        let key = AudioCacheKey.youtube(videoId: "purged")
        do {
            let cache = try makeCache(directory: directory)
            _ = try await readThroughCache(cache, key: key, source: source, range: 0..<400_000)
            await cache.flush()
        }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "audio" {
            try FileManager.default.removeItem(at: file)
        }

        let reopened = try makeCache(directory: directory)
        let ranges = await reopened.cachedRanges(of: key)
        let usage = await reopened.usage()

        XCTAssertTrue(ranges.isEmpty)
        XCTAssertEqual(usage.entryCount, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)), [], "the stale index goes too")
    }

    func testSourceServingADifferentFileDiscardsTheEntry() async throws {
        let server = RangeServer()
        let url = googlevideoURL(client: "IOS", length: 3_000_000)
        server.host(patternData(count: 3_000_000), at: url)
        let cache = try makeCache()
        let key = AudioCacheKey.youtube(videoId: "reencoded")
        let source = HTTPAudioSource(stream: stream(url, length: 3_000_000), session: server.session)
        _ = try await readThroughCache(cache, key: key, source: source, range: 0..<100_000)
        await eventually { !(await cache.store.isFetching(key)) }
        let before = await cache.cachedRanges(of: key)
        XCTAssertFalse(before.isEmpty)

        // The same URL now serves a different file (a re-encode): its bytes must not be spliced
        // onto the prefix already on disk.
        server.host(patternData(count: 2_900_000, seed: 3), at: url)
        do {
            _ = try await readThroughCache(cache, key: key, source: source, range: 2_500_000..<2_600_000)
            XCTFail("a different file must not be written into the entry")
        } catch {
            XCTAssertEqual(error as? AudioCacheError, .contentChanged(key: key, expected: 3_000_000, actual: 2_900_000))
        }
        let after = await cache.cachedRanges(of: key)
        XCTAssertTrue(after.isEmpty, "the old prefix is gone, so the next open starts clean")
    }

    /// The same videoId can name a different file: cellular quality set to Low gets a
    /// 64 kbps rendition under the key a Wi-Fi play part-cached at 128 kbps. A new source only
    /// compared its responses with each other, never with the entry, so its bytes filled the old
    /// file's holes and the seam stayed on disk.
    ///
    /// The new source states its length before it is asked anything, so the entry is dropped
    /// when it is opened. Answered from the index instead, the player was handed the old file's
    /// length and opening, and the new copy failed at the first hole: mid-track, a working copy lost.
    func testANewSourceServingADifferentFileDiscardsTheEntry() async throws {
        let server = RangeServer()
        let wifi = googlevideoURL(client: "IOS", length: 3_000_000)
        let cellular = googlevideoURL(client: "IOS", length: 2_900_000, itag: 139)
        let wifiBody = patternData(count: 3_000_000)
        let cellularBody = patternData(count: 2_900_000, seed: 3)
        server.host(wifiBody, at: wifi)
        server.host(cellularBody, at: cellular)
        let cache = try makeCache()
        let key = AudioCacheKey.youtube(videoId: "lowered")
        let first = HTTPAudioSource(stream: stream(wifi, length: 3_000_000), session: server.session)
        _ = try await readThroughCache(cache, key: key, source: first, range: 0..<100_000)
        await eventually { !(await cache.store.isFetching(key)) }

        let later = HTTPAudioSource(stream: stream(cellular, length: 2_900_000), session: server.session)
        let info = try await cache.store.contentInfo(for: key, source: later, opening: true)
        let opening = try await readThroughCache(cache, key: key, source: later, range: 0..<100_000)
        let tail = try await readThroughCache(cache, key: key, source: later, range: 2_500_000..<2_600_000)

        XCTAssertEqual(info.contentLength, 2_900_000, "the player is told the new file's length")
        XCTAssertEqual(opening, cellularBody.subdata(in: 0..<100_000), "not the old file's opening off disk")
        XCTAssertEqual(tail, cellularBody.subdata(in: 2_500_000..<2_600_000), "and the rest reads on without failing")
    }

    /// Read-ahead finding another add-on's file for a row doesn't replace the partial copy: a player
    /// may already hold that copy's header, and replaced under it, played in silence. The
    /// bytes stay as they were; only a player opening the key afresh may replace them.
    func testReadAheadWithAnotherFileLeavesThePartialCopyAlone() async throws {
        let server = RangeServer()
        let first = googlevideoURL(client: "IOS", length: 3_000_000)
        let other = googlevideoURL(client: "IOS", length: 2_900_000, itag: 139)
        let firstBody = patternData(count: 3_000_000)
        server.host(firstBody, at: first)
        server.host(patternData(count: 2_900_000, seed: 3), at: other)
        let cache = try makeCache()
        let key = AudioCacheKey.youtube(videoId: "heldCopy")
        let opened = HTTPAudioSource(stream: stream(first, length: 3_000_000), session: server.session)
        _ = try await readThroughCache(cache, key: key, source: opened, range: 0..<100_000)
        await eventually { !(await cache.store.isFetching(key)) }

        let found = HTTPAudioSource(stream: stream(other, length: 2_900_000), session: server.session)
        let info = try await cache.store.contentInfo(for: key, source: found)
        XCTAssertEqual(info.contentLength, 3_000_000, "the copy on disk stays what the key holds")
        // Its fetch finds the other file's length: it stops there, and the entry stays.
        await cache.warmRange(key, source: found, range: 2_500_000..<2_600_000)
        let kept = await cache.contentLength(of: key)
        XCTAssertEqual(kept, 3_000_000, "the fetch only stopped")
        let opening = try await readThroughCache(cache, key: key, source: opened, range: 0..<100_000)
        XCTAssertEqual(opening, firstBody.subdata(in: 0..<100_000), "a player holding that copy reads the same file")
    }

    /// An entry whole on disk is not thrown away for a source that states another length: it plays
    /// as the file it is, with nothing of it fetched, so nothing can be spliced into it.
    func testAWholeEntryOutlivesASourceOfAnotherLength() async throws {
        let server = RangeServer()
        let wifi = googlevideoURL(client: "IOS", length: 1_500_000)
        let cellular = googlevideoURL(client: "IOS", length: 1_400_000, itag: 139)
        let wifiBody = patternData(count: 1_500_000)
        server.host(wifiBody, at: wifi)
        server.host(patternData(count: 1_400_000, seed: 3), at: cellular)
        let cache = try makeCache()
        let key = AudioCacheKey.youtube(videoId: "kept")
        let first = HTTPAudioSource(stream: stream(wifi, length: 1_500_000), session: server.session)
        _ = try await readThroughCache(cache, key: key, source: first, range: 0..<1_500_000)
        await eventually { await cache.isFullyCached(key) }
        let requestsBefore = server.requests.count

        let later = HTTPAudioSource(stream: stream(cellular, length: 1_400_000), session: server.session)
        let whole = try await readThroughCache(cache, key: key, source: later, range: 0..<1_500_000)

        XCTAssertEqual(whole, wifiBody)
        XCTAssertEqual(server.requests.count, requestsBefore, "not one byte fetched again")
    }

    /// A captive portal answers a plain-HTTP stream with its sign-in page (200, text/html).
    /// The page's length became the track's, the page was stored as a complete entry, and every
    /// later play served it from disk without asking the network again.
    func testACaptivePortalPageIsNeverStoredAsAudio() async throws {
        // Labelled as a page; unlabelled (URLSession then sniffs it as one); and mislabelled as a binary.
        for label in ["text/html", nil, "application/octet-stream"] as [String?] {
            let server = RangeServer()
            let url = URL(string: "http://cdn.example.com/track.m4a")!
            server.host(Data("<!DOCTYPE html><html><body>Sign in to the Wi-Fi</body></html>".utf8), at: url, mimeType: label)
            server.ignoreRanges = true
            let cache = try makeCache()
            let key = AudioCacheKey.source("addon-1", track: "portal")
            let source = HTTPAudioSource(stream: stream(url, length: nil, mimeType: nil), session: server.session)
            do {
                _ = try await readThroughCache(cache, key: key, source: source, range: 0..<100)
                XCTFail("\(label ?? "unlabelled"): a web page must not be read as the track")
            } catch {
                guard case .badResponse(let why)? = error as? AudioCacheError, why.contains("web page") else {
                    XCTFail("\(label ?? "unlabelled"): refused as a page, not for another reason: \(error)")
                    continue
                }
            }
            let ranges = await cache.cachedRanges(of: key)
            let usage = await cache.usage()
            XCTAssertTrue(ranges.isEmpty, "\(label ?? "unlabelled"): no bytes of the page are kept")
            XCTAssertEqual(usage.entryCount, 0, "\(label ?? "unlabelled"): nothing about the page is recorded")
        }
    }

    /// A refused page's stated length is not the track's. Left behind, the same source's next
    /// contentInfo answered with it from memory (the resolver gave a type but no length), and the
    /// store recorded the page's length as the track's.
    func testARefusedPageLeavesNoLengthBehind() async throws {
        let server = RangeServer()
        let url = URL(string: "http://cdn.example.com/track.m4a")!
        server.host(Data("<!DOCTYPE html><html><body>Sign in to the Wi-Fi</body></html>".utf8), at: url, mimeType: "application/octet-stream")
        server.ignoreRanges = true
        let source = HTTPAudioSource(stream: stream(url, length: nil, mimeType: "audio/mp4"), session: server.session)
        for ask in 1...2 {
            do {
                let info = try await source.contentInfo()
                XCTFail("ask \(ask): a refused page's length came back as the track's: \(info.contentLength)")
            } catch {
                guard case .badResponse(let why)? = error as? AudioCacheError, why.contains("web page") else {
                    XCTFail("ask \(ask): refused as a page, not for another reason: \(error)")
                    continue
                }
            }
        }
    }

    /// The rule behind the refusal above, both ways: a page or XML document opens with `<` (after
    /// whitespace or a byte-order mark), and no audio stream does, so none is thrown away.
    func testOnlyMarkupReadsAsAWebPage() {
        let pages = ["<!DOCTYPE html><html>", "  \n<html lang=\"en\">", "\u{FEFF}<!-- portal --><head>", "<?xml version=\"1.0\"?><html>"]
        for page in pages {
            XCTAssertTrue(HTTPAudioSource.isWebPage(opening: Data(page.utf8)), page)
        }
        let audio: [String: Data] = [
            "mp4": Data([0x00, 0x00, 0x00, 0x20]) + Data("ftypM4A ".utf8),
            "mp3 with ID3": Data("ID3".utf8) + Data([0x04, 0x00]),
            "mp3 frame": Data([0xFF, 0xFB, 0x90, 0x64]),
            "flac": Data("fLaC".utf8),
            "ogg": Data("OggS".utf8),
            "wav": Data("RIFF".utf8),
            "webm": Data([0x1A, 0x45, 0xDF, 0xA3]),
            "adts": Data([0xFF, 0xF1, 0x50, 0x80]),
        ]
        for (name, opening) in audio {
            XCTAssertFalse(HTTPAudioSource.isWebPage(opening: opening + patternData(count: 60)), name)
        }
    }

    func testIndexRecordsTypeAndLength() async throws {
        let directory = try makeTemporaryDirectory()
        let key = AudioCacheKey.source("addon-1", track: "42")
        do {
            let cache = try makeCache(directory: directory)
            let flac = MemoryAudioSource(Data("fLaC".utf8) + patternData(count: 5_000), mimeType: nil)
            _ = try await readThroughCache(cache, key: key, source: flac, range: 0..<100)
        }
        let reopened = try makeCache(directory: directory)
        let info = try await reopened.store.contentInfo(for: key, source: nil)
        XCTAssertEqual(info.contentLength, 5_004)
        XCTAssertEqual(info.contentType, AudioContentType.flac, "sniffed from the first bytes and remembered")
    }

    /// Opening the cache must not read entry files on the constructing thread: measured at ~86 ms
    /// for 500 entries and ~1.83 s for 5000 on the old synchronous load. The index load now runs
    /// off the launch thread, and queries issued right after construction wait for it.
    func testConstructionDoesNotWalkTheIndex() async throws {
        let directory = try makeTemporaryDirectory()
        let entriesCount = 2_000
        do {
            let seeded = try makeCache(directory: directory)
            for index in 0..<entriesCount {
                let key = AudioCacheKey.youtube(videoId: "seed-\(index)")
                _ = await seeded.cacheCompletely(key, source: MemoryAudioSource(patternData(count: 1_024, seed: UInt8(index % 256))))
            }
            await seeded.flush()
        }

        let started = ContinuousClock.now
        let reopened = try makeCache(directory: directory)
        let elapsed = ContinuousClock.now - started

        XCTAssertLessThan(elapsed, .milliseconds(250), "construction walked \(entriesCount) entry indexes on the calling thread")
        let usage = await reopened.usage()
        XCTAssertEqual(usage.entryCount, entriesCount)
        let fullyCached = await reopened.isFullyCached(AudioCacheKey.youtube(videoId: "seed-7"))
        XCTAssertTrue(fullyCached)
    }

    // MARK: Moving out of Caches

    /// The cache built in `Library/Caches` moves to its new home whole, by rename: the same files
    /// (not copies), every entry still on disk, played back with the network gone.
    func testMovingTheCacheKeepsEveryEntryWithoutFetchingIt() async throws {
        let root = try makeTemporaryDirectory()
        let legacy = root.appending(path: "Caches/AudioCache", directoryHint: .isDirectory)
        let moved = root.appending(path: "Application Support/Vibra Music/AudioCache", directoryHint: .isDirectory)
        let whole = AudioCacheKey.youtube(videoId: "movedWhole")
        let partial = AudioCacheKey.substitute(videoId: "movedPart", atmosAllowed: true)
        let body = patternData(count: 600_000)
        var partialBefore: [Range<Int64>] = []
        do {
            let cache = try makeCache(directory: legacy)
            await assertCachesCompletely(cache, whole, source: MemoryAudioSource(body))
            await cache.warmRange(partial, source: MemoryAudioSource(patternData(count: 900_000)), range: 0..<200_000)
            await cache.flush()
            partialBefore = await cache.cachedRanges(of: partial)
        }
        XCTAssertFalse(partialBefore.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: legacy.path(percentEncoded: false)).sorted()
        let inodes = try files.map { try fileNumber(legacy.appending(path: $0)) }

        AudioStreamCache.moveCache(from: legacy, to: moved)

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path(percentEncoded: false)), "nothing is left in Caches")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: moved.path(percentEncoded: false)).sorted(), files)
        XCTAssertEqual(try files.map { try fileNumber(moved.appending(path: $0)) }, inodes, "moved, not copied")
        let reopened = try makeCache(directory: moved)
        let replay = try await readThroughCache(reopened, key: whole, source: nil, range: 0..<Int64(body.count))
        XCTAssertEqual(replay, body, "the whole entry plays off disk")
        let partialRanges = await reopened.cachedRanges(of: partial)
        XCTAssertEqual(partialRanges, partialBefore, "a partial entry keeps what it had")
        AudioStreamCache.moveCache(from: legacy, to: moved)
        let afterSecondRun = await reopened.isFullyCached(whole)
        XCTAssertTrue(afterSecondRun, "a second run has nothing to move and touches nothing")
    }

    /// A move cut short (an older build ran in between, so the new home already exists, and the
    /// app was killed with one entry's bytes moved and its index not) is finished on the next
    /// launch: no entry is lost or has to be fetched again.
    func testAMoveCutShortIsFinishedOnTheNextLaunch() async throws {
        let root = try makeTemporaryDirectory()
        let legacy = root.appending(path: "old", directoryHint: .isDirectory)
        let moved = root.appending(path: "new", directoryHint: .isDirectory)
        let keys = [AudioCacheKey.youtube(videoId: "cutShortA"), AudioCacheKey.youtube(videoId: "cutShortB")]
        do {
            let cache = try makeCache(directory: legacy)
            for key in keys { await assertCachesCompletely(cache, key, source: MemoryAudioSource(patternData(count: 300_000))) }
            await cache.flush()
        }
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        let audio = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: legacy.path(percentEncoded: false)).first { $0.hasSuffix(".audio") })
        try FileManager.default.moveItem(at: legacy.appending(path: audio), to: moved.appending(path: audio))

        AudioStreamCache.moveCache(from: legacy, to: moved)

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path(percentEncoded: false)))
        let reopened = try makeCache(directory: moved)
        for key in keys {
            let whole = await reopened.isFullyCached(key)
            XCTAssertTrue(whole, "\(key) survived the interrupted move")
        }
    }

    /// The cache is kept out of the listener's iCloud backup: everything in it can be fetched again.
    func testTheCacheIsExcludedFromBackup() throws {
        let directory = try makeTemporaryDirectory().appending(path: "AudioCache", directoryHint: .isDirectory)
        _ = try makeCache(directory: directory)
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    private func fileNumber(_ url: URL) throws -> UInt64 {
        let number = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.systemFileNumber] as? NSNumber
        return try XCTUnwrap(number).uint64Value
    }
}
