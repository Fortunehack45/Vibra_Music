import AudioCache
import AVFoundation
import VibraMusicCore
import XCTest
@testable import VibraMusic

/// A playlist stream (an add-on's lossless or Atmos) played through the audio cache as one
/// fragmented MP4: laid out from a kilobyte of each segment, each segment's audio fetched once,
/// and the entry whole afterwards.
final class SegmentedAudioSourceTests: XCTestCase {
    /// An MP4 box: 32-bit size, type, payload.
    private static func box(_ type: String, _ payload: [UInt8]) -> Data {
        let size = UInt32(8 + payload.count)
        return Data([UInt8(size >> 24), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)]) + Data(type.utf8) + Data(payload)
    }

    private static let initSegment = box("ftyp", Array("isom".utf8) + [0, 0, 0, 1]) + box("moov", Array(repeating: 1, count: 64))
    /// What belongs in the file: the `moof`/`mdat` pair.
    private static func fragment(_ n: UInt8, bytes: Int) -> Data {
        box("moof", Array(repeating: n, count: 32)) + box("mdat", Array(repeating: n, count: bytes))
    }
    /// A segment as served: `styp` and `sidx` in front of the fragment.
    private static func segment(_ n: UInt8, bytes: Int) -> Data {
        box("styp", Array("msdh".utf8)) + box("sidx", [0, 0, 0, 0, 0, 0]) + fragment(n, bytes: bytes)
    }

    private let playlistURL = URL(string: "vibramusic-hls://playlist/abc.m3u8")!
    private let sizes = [3_000, 5_000, 1_200]
    private var playlist: String {
        var text = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:4\n#EXT-X-MAP:URI=\"https://cdn.example/init.mp4\"\n"
        for index in sizes.indices { text += "#EXTINF:4,\nhttps://cdn.example/seg\(index).m4s\n" }
        return text + "#EXT-X-ENDLIST\n"
    }
    private var expectedFile: Data {
        sizes.enumerated().reduce(Self.initSegment) { $0 + Self.fragment(UInt8($1.offset + 1), bytes: $1.element) }
    }

    private var stream: ResolvedStream {
        ResolvedStream(url: playlistURL, origin: .addon, mimeType: "application/x-mpegURL", format: StreamFormat(codec: "flac"))
    }

    /// The fake CDN: ranged answers carry the whole size, as a 206's Content-Range does.
    private func server(_ bodies: [String: Data], log: RequestLog) -> SegmentedAudioSource.Fetch {
        { url, _, range in
            guard let body = bodies[url.lastPathComponent] else { throw URLError(.fileDoesNotExist) }
            log.record(url.lastPathComponent, range)
            guard let range else { return (body, Int64(body.count)) }
            let slice = range.clamped(to: 0..<Int64(body.count))
            return (body.subdata(in: Int(slice.lowerBound)..<Int(slice.upperBound)), Int64(body.count))
        }
    }

    private var bodies: [String: Data] {
        var bodies = ["init.mp4": Self.initSegment]
        for (index, size) in sizes.enumerated() { bodies["seg\(index).m4s"] = Self.segment(UInt8(index + 1), bytes: size) }
        return bodies
    }

    private func layOut(log: RequestLog = RequestLog(), bodies: [String: Data]? = nil) async throws -> SegmentedAudioSource {
        let text = playlist
        return try await SegmentedAudioSource.make(stream, playlistText: { _, _ in text }, fetch: server(bodies ?? self.bodies, log: log))
    }

    func testThePlaylistIsLaidOutAsOneFile() async throws {
        let source = try await layOut()
        XCTAssertEqual(source.contentLength, Int64(expectedFile.count), "the init segment and every moof/mdat, nothing else")
        let info = try await source.contentInfo()
        XCTAssertEqual(info.contentLength, Int64(expectedFile.count))
        // A range across segment boundaries reads what the flattened file holds there.
        let range: Range<Int64> = 50..<Int64(expectedFile.count - 40)
        let read = try await source.read(range)
        XCTAssertEqual(read, expectedFile.subdata(in: 50..<(expectedFile.count - 40)))
    }

    func testPlayedThroughTheCacheEachSegmentIsFetchedOnceAndKeptWhole() async throws {
        let directory = makeTemporaryDirectory(self)
        let cache = try makeTestCache(in: directory)
        let key = AudioCacheKey.substitute(videoId: "segmented01", atmosAllowed: true)
        let log = RequestLog()
        let source = try await layOut(log: log)

        let whole = await cache.cacheCompletely(key, source: source)

        XCTAssertTrue(whole)
        let complete = await cache.reader(for: key, requireComplete: true)
        let reader = try XCTUnwrap(complete, "whole, readable with no connection")
        let onDisk = await reader.read(at: 0, count: expectedFile.count)
        XCTAssertEqual(onDisk, expectedFile)
        for index in sizes.indices {
            let audio = log.requests(for: "seg\(index).m4s").filter { ($0?.count ?? .max) > SegmentedAudioSource.headBytes }
            XCTAssertEqual(audio.count, 1, "segment \(index)'s audio is fetched once")
        }

        // Played again: all from disk.
        let before = log.count
        _ = await cache.cacheCompletely(key, source: source)
        XCTAssertEqual(log.count, before)
    }

    /// A played copy's missing parts are fetched once it has played a while, but only while the row
    /// still plays that copy: one a quality upgrade swapped `#hifi` in for meanwhile is never read
    /// again, so its parts aren't paid for.
    @MainActor
    func testOnlyTheCopyStillPlayingIsCompletedLater() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let factory = PlaybackSourceFactory(resolver: FakeStreamResolver(), youTube: nil, cache: cache, facts: StreamFactsBook(),
                                            request: { .playback(.lossless) }, atmosAllowed: { true })
        factory.completionDelay = .milliseconds(100)
        factory.isUnmetered = { true }
        factory.isPlaying = { _ in true }
        let kept = AudioCacheKey.substitute(videoId: "segmented08", atmosAllowed: true)
        let swapped = AudioCacheKey.substitute(videoId: "segmented09", atmosAllowed: true)
        let log = RequestLog()
        let keptSource = try await layOut()
        let swappedSource = try await layOut(log: log)
        let laidOut = log.count
        factory.playingKeys.set(kept.rawValue, for: kept.trackID, item: kept.trackID)
        factory.playingKeys.set(swapped.rawValue, for: swapped.trackID, item: swapped.trackID)

        factory.completeLater(swapped, source: swappedSource, videoId: swapped.trackID)
        factory.completeLater(kept, source: keptSource, videoId: kept.trackID)
        // Within the delay an upgrade puts the second row on its `#hifi` copy.
        factory.playingKeys.set(AudioCacheKey(trackID: swapped.trackID, rendition: "hifi").rawValue, for: swapped.trackID,
                                item: "\(swapped.trackID)#hifi")

        var keptWhole = false
        let deadline = ContinuousClock.now + .seconds(10)
        while !keptWhole, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            keptWhole = await cache.isFullyCached(kept)
        }
        XCTAssertTrue(keptWhole, "the copy still playing is whole")
        // Both waits ended together; give the swapped copy's fetch, were there one, time to show.
        try await Task.sleep(for: .milliseconds(300))
        let swappedBytes = await cache.cachedPrefixBytes(of: swapped)
        XCTAssertEqual(swappedBytes, 0, "the copy swapped out is left as it was")
        XCTAssertEqual(log.count, laidOut, "and nothing more of it is fetched")
    }

    /// The copy playing is still known to be playing however many rows have opened before it:
    /// the map of playing keys was wiped on its 65th video id, which is usually the next
    /// track's preload, so the playing copy's parts were never fetched for the offline backup.
    @MainActor
    func testThePlayingCopyIsCompletedAfterSixtyFourRowsHaveOpened() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let factory = PlaybackSourceFactory(resolver: FakeStreamResolver(), youTube: nil, cache: cache, facts: StreamFactsBook(),
                                            request: { .playback(.lossless) }, atmosAllowed: { true })
        factory.completionDelay = .milliseconds(100)
        factory.isUnmetered = { true }
        factory.isPlaying = { _ in true }
        let playing = AudioCacheKey.substitute(videoId: "segmented10", atmosAllowed: true)
        let source = try await layOut()
        for index in 0..<(PlayingCacheKeys.limit - 1) {
            factory.playingKeys.set("earlier\(index)", for: "earlier\(index)", item: "earlier\(index)")
        }
        factory.playingKeys.set(playing.rawValue, for: playing.trackID, item: playing.trackID)
        factory.playingKeys.becameCurrent(playing.trackID, videoId: playing.trackID)
        // The next track's preload, the sixty-fifth.
        factory.playingKeys.set("next", for: "next", item: "next")

        factory.completeLater(playing, source: source, videoId: playing.trackID)

        var whole = false
        let deadline = ContinuousClock.now + .seconds(10)
        while !whole, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            whole = await cache.isFullyCached(playing)
        }
        XCTAssertTrue(whole, "the copy playing is whole")
    }

    /// An entry already holding part of another file (the add-on's FLAC, now its Atmos mix) is
    /// never spliced: the layout states its length, so the entry is dropped before anything is read
    /// from it, and the copy is cached clean from its first byte.
    func testAnotherFilesPartialEntryIsNotSpliced() async throws {
        let directory = makeTemporaryDirectory(self)
        let cache = try makeTestCache(in: directory)
        let key = AudioCacheKey.substitute(videoId: "segmented02", atmosAllowed: true)
        let other = InMemoryAudioSource(data: Data(repeating: 9, count: 50_000), mimeType: "audio/mp4")
        await cache.warmRange(key, source: other, range: 0..<1_000)
        let before = await cache.contentLength(of: key)
        XCTAssertEqual(before, 50_000)

        let source = try await layOut()
        // Read-ahead doesn't replace it: a player may hold that file's header. A player opening
        // the key afresh does, which `CachePersistenceTests` covers.
        let replacedAhead = await cache.cacheCompletely(key, source: source)
        XCTAssertFalse(replacedAhead)
        let kept = await cache.contentLength(of: key)
        XCTAssertEqual(kept, 50_000, "the file a player may hold stays whole in its length")
        let reader = await cache.reader(for: key, requireComplete: false)
        let opening = await reader?.read(at: 0, count: 1_000)
        XCTAssertEqual(opening, Data(repeating: 9, count: 1_000), "its bytes aren't spliced with the other file's")
    }

    func testAStreamThatIsNotFragmentedMP4PlaysTheOldWay() async throws {
        var ts = bodies
        ts["seg1.m4s"] = Data([0x47] + Array(repeating: 0, count: 187))
        do {
            _ = try await layOut(bodies: ts)
            XCTFail("an MPEG-TS segment can't be laid out")
        } catch let error as SegmentedSourceError {
            XCTAssertTrue(error.description.hasPrefix("no moof"), "refused for another reason: \(error)")
        } catch {
            XCTFail("refused with \(error), not as a stream that isn't fragmented MP4")
        }

        let text = playlist
        let sources = SegmentedSources(playlistText: { _, _ in text }, fetch: server(ts, log: RequestLog()))
        let none = await sources.source(for: stream)
        XCTAssertNil(none, "the caller plays it as a playlist, uncached")
    }

    /// The copy's length is known before its bytes are: the playlist's, failing that the track's.
    func testTheKnownLengthIsThePlaylistsFailingThatTheTracks() async throws {
        let stated = try await layOut()
        XCTAssertEqual(stated.knownDuration, 12, "three segments of 4 s")

        let silent = playlist.replacingOccurrences(of: "#EXTINF:4,\n", with: "")
        var track = stream
        track.durationSeconds = 187
        let unstated = try await SegmentedAudioSource.make(track, playlistText: { _, _ in silent }, fetch: server(bodies, log: RequestLog()))
        XCTAssertEqual(unstated.knownDuration, 187)
    }

    /// AVFoundation can't tell a fragmented file's length from its opening (neither `mehd`, a
    /// `sidx` nor an edit list moved it on CI), so it counted only the fragments it had read: 0:24
    /// of a 3:07 song still arriving. The engine, and so the seek bar, shows the playlist's length.
    @MainActor
    func testACopyStillArrivingShowsThePlaylistsLength() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let harness = PlayerHarness(test: self, cache: cache)
        let seconds = 38.0
        let copy = try await fragmentedHLS(of: TestAudio.tone(seconds: seconds, in: harness.directory, name: "arrivingBody"), every: 4)
        let count = copy.bodies.count - 1
        // Every segment 4 s but a shorter last one, as a converted DASH manifest states them.
        var text = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:4\n#EXT-X-MAP:URI=\"https://cdn.example/init.mp4\"\n"
        for index in 0..<count {
            text += "#EXTINF:\(index < count - 1 ? 4 : seconds - 4 * Double(count - 1)),\nhttps://cdn.example/seg\(index).m4s\n"
        }
        let playlist = text + "#EXT-X-ENDLIST\n"
        let bodies = copy.bodies
        // Only the opening arrives: past the first segment, audio never comes.
        harness.factory.segmented = SegmentedSources(playlistText: { _, _ in playlist }, fetch: { url, _, range in
            guard let body = bodies[url.lastPathComponent] else { throw URLError(.fileDoesNotExist) }
            if let range, range != 0..<SegmentedAudioSource.headBytes, url.lastPathComponent != "seg0.m4s" {
                try await Task.sleep(for: .seconds(600))
            }
            let slice = (range ?? 0..<Int64(body.count)).clamped(to: 0..<Int64(body.count))
            return (body.subdata(in: Int(slice.lowerBound)..<Int(slice.upperBound)), Int64(body.count))
        })
        harness.resolver.serve("arriving01", from: URL(string: "vibramusic-hls://playlist/arriving01.m3u8")!, format: StreamFormat(codec: "flac"))

        harness.player.play([Song(videoId: "arriving01", title: "Arriving", artist: "Artist")], startAt: 0)

        await waitUntil("the playlist's length shows with only the opening there", timeout: 20) {
            abs(harness.engine.duration - seconds) < 0.01
        }
    }

    /// A skip to a track read ahead minutes earlier plays the stream read-ahead found, and its
    /// layout is still there: not made again (it took 1.4 s in a logged run).
    func testALayoutAskedForAgainThreeMinutesLaterIsReused() async throws {
        let log = RequestLog()
        let clock = Locked(ContinuousClock.now)
        let current = Locked(playlist)
        let sources = SegmentedSources(playlistText: { _, _ in current.value }, fetch: server(bodies, log: log), now: { clock.value })
        var layouts: Int { log.requests(for: "init.mp4").count }

        let first = await sources.source(for: stream)
        clock.value = clock.value.advanced(by: .seconds(180))
        let again = await sources.source(for: stream)

        XCTAssertNotNil(first)
        XCTAssertEqual(again?.parts, first?.parts)
        XCTAssertEqual(layouts, 1, "laid out once")

        // The converted playlist rewritten in place, same URL, with fresh segment links.
        current.value = playlist.replacingOccurrences(of: ".m4s", with: ".m4s?token=fresh")
        let fresh = await sources.source(for: stream)
        XCTAssertEqual(layouts, 2, "a rewritten playlist is laid out afresh")
        XCTAssertEqual(fresh?.parts.first?.url.query, "token=fresh")

        clock.value = clock.value.advanced(by: .seconds(301))
        _ = await sources.source(for: stream)
        XCTAssertEqual(layouts, 3, "past the stream's five minutes it is laid out afresh")
    }

    /// A link too slow to size the copy by the deadline: each segment's head read is held until
    /// `open`. Cancelled, a held read throws, as URLSession's does (`-999`).
    private func holdingHeads(_ serve: @escaping SegmentedAudioSource.Fetch, until open: Locked<Bool>) -> SegmentedAudioSource.Fetch {
        { url, headers, range in
            while range != nil, !open.value { try await Task.sleep(for: .milliseconds(5)) }
            return try await serve(url, headers, range)
        }
    }

    /// Asks until the layout is there, each ask under its short deadline.
    private func landed(_ sources: SegmentedSources, _ stream: ResolvedStream) async -> SegmentedAudioSource? {
        let giveUp = ContinuousClock.now + .seconds(10)
        var source: SegmentedAudioSource?
        while source == nil, ContinuousClock.now < giveUp { source = await sources.source(for: stream) }
        return source
    }

    /// On a slow link the deadline cancelled the layout and threw its work away, so the next
    /// open started from nothing and hit the same deadline: most copies were never saved.
    /// Now the wait ends at the deadline, and the one layout lands for the next open.
    func testALayoutPastTheDeadlineIsKeptForTheNextOpenWhichGoesThroughTheCache() async throws {
        let log = RequestLog()
        let open = Locked(false)
        let text = playlist
        let stream = self.stream
        let sources = SegmentedSources(playlistText: { _, _ in text }, fetch: holdingHeads(server(bodies, log: log), until: open),
                                       layoutDeadline: .milliseconds(50))

        async let one = sources.source(for: stream)
        async let two = sources.source(for: stream)
        let (first, second) = await (one, two)
        XCTAssertNil(first, "the row starts now, on the playlist")
        XCTAssertNil(second)
        XCTAssertEqual(log.requests(for: "init.mp4").count, 1, "asked for together, laid out once")

        open.value = true
        let laidOut = await landed(sources, stream)
        let source = try XCTUnwrap(laidOut, "it lands")
        XCTAssertEqual(log.requests(for: "init.mp4").count, 1, "the same layout, not one started again from nothing")

        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let key = AudioCacheKey.substitute(videoId: "segmented11", atmosAllowed: true)
        let whole = await cache.cacheCompletely(key, source: source)
        XCTAssertTrue(whole, "and that open is saved")
        for index in sizes.indices {
            XCTAssertEqual(log.requests(for: "seg\(index).m4s").filter { $0 == 0..<SegmentedAudioSource.headBytes }.count, 1,
                           "segment \(index) is sized once")
        }
    }

    /// A layout's links are as old as its start, however late it landed.
    func testALayoutThatLandedLateIsKeptOnlyForItsFreshnessFromWhenItStarted() async throws {
        let log = RequestLog()
        let open = Locked(false)
        let start = ContinuousClock.now
        let clock = Locked(start)
        let text = playlist
        let stream = self.stream
        let sources = SegmentedSources(playlistText: { _, _ in text }, fetch: holdingHeads(server(bodies, log: log), until: open),
                                       now: { clock.value }, layoutDeadline: .milliseconds(50))
        let first = await sources.source(for: stream)
        XCTAssertNil(first)

        open.value = true
        clock.value = start.advanced(by: .seconds(299))
        let reused = await landed(sources, stream)
        XCTAssertNotNil(reused)
        XCTAssertEqual(log.requests(for: "init.mp4").count, 1, "still fresh")

        clock.value = start.advanced(by: .seconds(301))
        _ = await landed(sources, stream)
        XCTAssertEqual(log.requests(for: "init.mp4").count, 2, "past five minutes from its start it is laid out afresh")
    }

    /// One that fails after nobody is waiting isn't remembered either: there is no waiter left to
    /// forget it, and kept, every open for five minutes would have played uncached.
    func testALayoutThatFailsPastTheDeadlineIsTriedAgain() async throws {
        let log = RequestLog()
        let open = Locked(false)
        let text = playlist
        let stream = self.stream
        let serve = server(bodies, log: log)
        let sources = SegmentedSources(playlistText: { _, _ in text }, fetch: holdingHeads({ url, headers, range in
            if range != nil, log.requests(for: "init.mp4").count == 1 { throw URLError(.timedOut) }
            return try await serve(url, headers, range)
        }, until: open), layoutDeadline: .milliseconds(50))
        let first = await sources.source(for: stream)
        XCTAssertNil(first)

        open.value = true
        let again = await landed(sources, stream)
        XCTAssertNotNil(again, "laid out by a later open")
        XCTAssertEqual(log.requests(for: "init.mp4").count, 2)
    }

    /// A factory opening `songs` as segmented copies, with each layout's head reads held until `open`.
    @MainActor
    private func factoryWithHeldLayouts(serving songs: [Song], until open: Locked<Bool>, log: RequestLog) throws -> PlaybackSourceFactory {
        let resolver = FakeStreamResolver()
        let factory = PlaybackSourceFactory(resolver: resolver, youTube: nil, cache: try makeTestCache(in: makeTemporaryDirectory(self)),
                                            facts: StreamFactsBook(), request: { .playback(.lossless) }, atmosAllowed: { true })
        let text = playlist
        factory.segmented = SegmentedSources(playlistText: { _, _ in text }, fetch: holdingHeads(server(bodies, log: log), until: open),
                                             layoutDeadline: .milliseconds(50))
        for song in songs {
            resolver.serve(song.videoId, from: URL(string: "vibramusic-hls://playlist/\(song.videoId).m3u8")!, format: StreamFormat(codec: "flac"))
        }
        return factory
    }

    /// A row playing starts on the playlist at the deadline. A row opened ahead (the gapless
    /// preload) doesn't settle for it: preloaded rows that did were uncached for the
    /// whole play, and still waiting a second after being skipped to.
    @MainActor
    func testARowAheadWaitsForItsLayoutWhereARowPlayingStartsAtTheDeadline() async throws {
        let open = Locked(false)
        let playing = Song(videoId: "segmented12", title: "Playing", artist: "Artist")
        let ahead = Song(videoId: "segmented13", title: "Ahead", artist: "Artist")
        let factory = try factoryWithHeldLayouts(serving: [playing, ahead], until: open, log: RequestLog())
        factory.isPlaying = { $0 == playing.videoId }
        guard case .resolvedAsset(let openPlaying) = factory.item(for: playing).source,
              case .resolvedAsset(let openAhead) = factory.item(for: ahead).source else { return XCTFail("streamed rows open assets") }

        let started = try await openPlaying()
        XCTAssertNil(AudioStreamCache.knownDuration(of: started.asset), "on the playlist, uncached")

        let finished = Locked(false)
        let opening = Task { () -> AVURLAsset in
            defer { finished.value = true }
            return try await openAhead().asset
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(finished.value, "still waiting, well past the deadline")

        open.value = true
        let asset = try await opening.value
        XCTAssertNotNil(AudioStreamCache.knownDuration(of: asset), "through the cache")
    }

    /// A queue edit lets go of a row ahead while it waits. The engine keeps whatever an open
    /// answers, even one nobody waits for now, so a playlist answered here would be what the row
    /// plays when it is reached, long after its layout landed.
    @MainActor
    func testARowLetGoOfWhileItWaitsForItsLayoutDoesNotAnswerWithThePlaylist() async throws {
        let log = RequestLog()
        let ahead = Song(videoId: "segmented14", title: "Ahead", artist: "Artist")
        let factory = try factoryWithHeldLayouts(serving: [ahead], until: Locked(false), log: log)
        factory.isPlaying = { _ in false }
        guard case .resolvedAsset(let openAhead) = factory.item(for: ahead).source else { return XCTFail("a streamed row opens an asset") }

        let opening = Task { try await openAhead().asset }
        await waitUntil("its layout is under way") { !log.requests(for: "init.mp4").isEmpty }
        opening.cancel()

        do {
            _ = try await opening.value
            XCTFail("answered with the playlist")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    /// The CDN once the playlist's `token=stale` links are dead: their audio is refused with a
    /// 403, past the first segment (sizing them still works, as it did when they were laid out).
    private func refusingStaleLinks(_ serve: @escaping SegmentedAudioSource.Fetch, refusals: Locked<Int>) -> SegmentedAudioSource.Fetch {
        { url, headers, range in
            if url.query == "token=stale", (range?.count ?? .max) > SegmentedAudioSource.headBytes, url.lastPathComponent != "seg0.m4s" {
                refusals.value += 1
                throw AudioCacheError.httpStatus(403, url: url)
            }
            return try await serve(url, headers, range)
        }
    }

    /// Found again, the converted playlist is rewritten in place with fresh links.
    private func linked(_ token: String, _ text: String) -> String {
        text.replacingOccurrences(of: ".m4s", with: ".m4s?token=\(token)")
    }

    /// A long track on mobile data outlives its segment links: the stream is found again, laid
    /// out again, and the read carries on at the same byte, as an HTTP copy's would.
    func testAnExpiredSegmentMidReadIsFoundAgainAndTheReadGetsEveryByte() async throws {
        let current = Locked(linked("stale", playlist))
        let refusals = Locked(0)
        let finds = Locked(0)
        let sources = SegmentedSources(playlistText: { _, _ in current.value }, fetch: refusingStaleLinks(server(bodies, log: RequestLog()), refusals: refusals))
        let fresh = linked("fresh", playlist)
        let resolved = stream
        let made = await sources.source(for: stream) { finds.value += 1; current.value = fresh; return resolved }
        let source = try XCTUnwrap(made)

        let read = try await source.read(0..<source.contentLength)

        XCTAssertEqual(read, expectedFile, "every byte, the first segment's from the old links and the rest from the new")
        XCTAssertEqual(refusals.value, 1)
        XCTAssertEqual(finds.value, 1, "found again once, not once per segment")
    }

    /// Found again as another copy (another representation: other segment sizes), the read fails
    /// rather than carrying on in the middle of a different file, and the player's recovery falls
    /// back to YouTube.
    func testAStreamFoundAgainWithAnotherLayoutFailsTheReadRatherThanSplicing() async throws {
        let current = Locked(linked("stale", playlist))
        var served = bodies
        served["seg1.m4s"] = Self.segment(2, bytes: 4_000)
        let other = served
        let log = RequestLog()
        let original = server(bodies, log: log)
        let reencoded = server(other, log: log)
        let switched = Locked(false)
        let fetch = refusingStaleLinks({ url, headers, range in
            try await (switched.value ? reencoded : original)(url, headers, range)
        }, refusals: Locked(0))
        let sources = SegmentedSources(playlistText: { _, _ in current.value }, fetch: fetch)
        let fresh = linked("fresh", playlist)
        let resolved = stream
        let made = await sources.source(for: stream) { switched.value = true; current.value = fresh; return resolved }
        let source = try XCTUnwrap(made)

        do {
            _ = try await source.read(0..<source.contentLength)
            XCTFail("a different layout is not spliced in")
        } catch AudioCacheError.contentChanged {
        } catch {
            XCTFail("failed with \(error), not as another copy")
        }
        let audio = log.requests(for: "seg1.m4s").filter { ($0?.count ?? .max) > SegmentedAudioSource.headBytes }
        XCTAssertTrue(audio.isEmpty, "none of the other copy's audio is fetched")
    }

    /// Links past the stream's expiry (a copy found ahead counts as expired past its freshness)
    /// are found again before they are used, not after a refusal.
    func testLinksPastTheStreamsExpiryAreFoundAgainBeforeTheyAreUsed() async throws {
        let current = Locked(linked("stale", playlist))
        let refusals = Locked(0)
        let finds = Locked(0)
        let sources = SegmentedSources(playlistText: { _, _ in current.value }, fetch: refusingStaleLinks(server(bodies, log: RequestLog()), refusals: refusals))
        var expiring = stream
        expiring.expiresAt = Date().addingTimeInterval(30)
        let fresh = linked("fresh", playlist)
        let resolved = stream
        let made = await sources.source(for: expiring) { finds.value += 1; current.value = fresh; return resolved }
        let source = try XCTUnwrap(made)

        let read = try await source.read(0..<source.contentLength)

        XCTAssertEqual(read, expectedFile)
        XCTAssertEqual(refusals.value, 0, "the stale links are never asked")
        XCTAssertEqual(finds.value, 1)
    }

    /// An add-on that signs only the segment links again hands back the same playlist URL: the
    /// stream found again is laid out from its playlist anew, not taken from the layout kept for
    /// that URL, whose links are the ones just refused.
    func testARemotePlaylistFoundAgainAtTheSameURLIsLaidOutAfresh() async throws {
        let current = Locked(linked("stale", playlist))
        let refusals = Locked(0)
        let sources = SegmentedSources(playlistText: { _, _ in current.value }, fetch: refusingStaleLinks(server(bodies, log: RequestLog()), refusals: refusals))
        let remote = ResolvedStream(url: URL(string: "https://addon.example/abc.m3u8")!, origin: .addon, mimeType: "application/x-mpegURL", format: StreamFormat(codec: "flac"))
        let fresh = linked("fresh", playlist)
        let made = await sources.source(for: remote) { current.value = fresh; return remote }
        let source = try XCTUnwrap(made)

        let read = try await source.read(0..<source.contentLength)

        XCTAssertEqual(read, expectedFile)
        XCTAssertEqual(refusals.value, 1, "the stale links are asked once, not again after the stream is found again")
    }

    /// Links renewed for their expiry can be refused too: found again once more, as an HTTP copy
    /// whose stream expired can still re-mint a refused range.
    func testLinksRenewedForTheirExpiryAndThenRefusedAreFoundAgain() async throws {
        let current = Locked(linked("stale", playlist))
        let refusals = Locked(0)
        let finds = Locked(0)
        let serve = server(bodies, log: RequestLog())
        // Only the third links work; sizing (a head's kilobyte) works with any.
        let sources = SegmentedSources(playlistText: { _, _ in current.value }, fetch: { url, headers, range in
            if let query = url.query, query != "token=fresher", (range?.count ?? .max) > SegmentedAudioSource.headBytes {
                refusals.value += 1
                throw AudioCacheError.httpStatus(403, url: url)
            }
            return try await serve(url, headers, range)
        })
        var expiring = stream
        expiring.expiresAt = Date().addingTimeInterval(30)
        let fresh = linked("fresh", playlist), fresher = linked("fresher", playlist)
        let resolved = stream
        let made = await sources.source(for: expiring) {
            finds.value += 1
            current.value = finds.value == 1 ? fresh : fresher
            return resolved
        }
        let source = try XCTUnwrap(made)

        let read = try await source.read(0..<source.contentLength)

        XCTAssertEqual(read, expectedFile)
        XCTAssertEqual(refusals.value, 1, "the links renewed for their expiry, refused once")
        XCTAssertEqual(finds.value, 2, "once for the expiry, once for the refusal")
    }

    // MARK: A segment's bytes as they arrive

    /// The fake CDN's audio as it arrives: the `reads` first reads of `name` send `sent` bytes and
    /// then hang until they are cut, or throw `failure`. Reads are logged in `log`, apart from the
    /// layout's heads, which are `fetch`'s.
    private func audio(_ bodies: [String: Data], log: RequestLog, hanging name: String? = nil, after sent: Int = 0, reads: Int = 1,
                       failure: Error? = nil) -> SegmentedAudioSource.ReadSegment {
        { url, _, range, deliver in
            let body = try XCTUnwrap(bodies[url.lastPathComponent])
            log.record(url.lastPathComponent, range)
            func bytes(_ count: Int64) -> Data { body.subdata(in: Int(range.lowerBound)..<Int(range.lowerBound + count)) }
            guard url.lastPathComponent == name, log.requests(for: url.lastPathComponent).count <= reads else {
                deliver(bytes(Int64(range.count)))
                return
            }
            deliver(bytes(Int64(sent)))
            if let failure { throw failure }
            // Cut, it ends quietly, as a read of URLSession's events does.
            try? await Task.sleep(for: .seconds(3_600))
        }
    }

    private func layOut(reading readSegment: @escaping SegmentedAudioSource.ReadSegment, windows: StallWindows = StallWindows(),
                        bodies: [String: Data]? = nil) async throws -> SegmentedAudioSource {
        let text = playlist
        return try await SegmentedAudioSource.make(stream, playlistText: { _, _ in text }, fetch: server(bodies ?? self.bodies, log: RequestLog()),
                                                   readSegment: readSegment, stallTimer: { try await windows.wait() })
    }

    /// Where the second segment's bytes start in the file.
    private var secondSegment: Int { Self.initSegment.count + Self.fragment(1, bytes: sizes[0]).count }

    /// AVPlayer reads every fragment's `moof` before it starts. On macOS at 2 Mbps, handed only whole
    /// slices it read a whole file and never started; handed bytes as they came it started in 17 s.
    func testASegmentsBytesReachTheReaderBeforeItIsWhole() async throws {
        let source = try await layOut(reading: audio(bodies, log: RequestLog(), hanging: "seg1.m4s", after: 1_000))
        let count = secondSegment + 1_000
        let expected = expectedFile.prefix(count)

        let received: Data? = await withDeadline(.seconds(10)) {
            var bytes = Data()
            do {
                for try await piece in source.stream(0..<source.contentLength) {
                    bytes.append(piece)
                    if bytes.count >= count { return bytes }
                }
            } catch {}
            return nil
        }

        XCTAssertEqual(received, expected, "what arrived of the hung segment, while it is still hung")
    }

    /// One segment hung at 1.75 MB of 2.54 MB for five minutes, and a timeout started it again from
    /// its first byte. The read is cut at the end of a window and asks only for the rest.
    @MainActor
    func testAStalledReadResumesFromTheByteReachedAndAsksOnlyForTheRest() async throws {
        let reads = RequestLog()
        let windows = StallWindows()
        let source = try await layOut(reading: audio(bodies, log: reads, hanging: "seg1.m4s", after: 1_000), windows: windows)

        let reading = Task { try await source.read(0..<source.contentLength) }
        await waitUntil("the second segment is being read") { !reads.requests(for: "seg1.m4s").isEmpty }
        windows.end()
        let read = try await reading.value

        XCTAssertEqual(read, expectedFile, "every byte, in order, once")
        let asked = reads.requests(for: "seg1.m4s").compactMap { $0 }
        XCTAssertEqual(asked.count, 2, "one cut, one resume")
        XCTAssertEqual(asked.last?.lowerBound, asked.first.map { $0.lowerBound + 1_000 }, "from the byte reached")
        XCTAssertEqual(asked.last?.upperBound, asked.first?.upperBound, "to the same end")
    }

    /// A read bringing the floor in a window is slow, not stuck, and a new request wouldn't help.
    /// The first window with less is the one that cuts it.
    @MainActor
    func testAReadBringingTheFloorInAWindowIsLeftAlone() async throws {
        let floor = Int(SegmentedAudioSource.stallFloorBytes)
        var bodies = self.bodies
        bodies["seg0.m4s"] = Self.segment(1, bytes: floor * 2)
        let reads = RequestLog()
        let windows = StallWindows()
        let source = try await layOut(reading: audio(bodies, log: reads, hanging: "seg0.m4s", after: floor), windows: windows, bodies: bodies)

        let reading = Task { try await source.read(0..<source.contentLength) }
        await waitUntil("the first segment is being read") { !reads.requests(for: "seg0.m4s").isEmpty }
        windows.end()
        await waitUntil("that window is judged and the next begins") { windows.started >= 2 }
        XCTAssertEqual(reads.requests(for: "seg0.m4s").count, 1, "not cut")

        windows.end()
        let read = try await reading.value

        XCTAssertEqual(reads.requests(for: "seg0.m4s").count, 2, "cut by the window that brought nothing")
        XCTAssertEqual(Int64(read.count), source.contentLength)
    }

    /// A read that keeps stalling fails as timed out, which the loader retries from where it got to.
    /// The next pass of read-ahead also asks only for what is still missing.
    @MainActor
    func testAReadThatKeepsStallingFailsAfterItsCutsAndKeepsWhatArrived() async throws {
        let reads = RequestLog()
        let windows = StallWindows()
        let attempts = SegmentedAudioSource.maxCuts + 1
        let source = try await layOut(reading: audio(bodies, log: reads, hanging: "seg1.m4s", after: 100, reads: attempts), windows: windows)
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let key = AudioCacheKey.substitute(videoId: "segmented15", atmosAllowed: true)

        let first = Task { await cache.cacheCompletely(key, source: source) }
        for attempt in 1...attempts {
            await waitUntil("read \(attempt) of the second segment") { reads.requests(for: "seg1.m4s").count == attempt }
            windows.end()
        }
        let firstWhole = await first.value
        XCTAssertFalse(firstWhole)
        let kept = await cache.cachedRanges(of: key)
        XCTAssertEqual(kept, [0..<Int64(secondSegment + 100 * attempts)], "everything that arrived")

        let secondWhole = await cache.cacheCompletely(key, source: source)

        XCTAssertTrue(secondWhole)
        let reader = await cache.reader(for: key, requireComplete: true)
        let onDisk = await reader?.read(at: 0, count: expectedFile.count)
        XCTAssertEqual(onDisk, expectedFile)
        let asked = reads.requests(for: "seg1.m4s").compactMap { $0 }
        XCTAssertEqual(asked.count, attempts + 1)
        for (earlier, later) in zip(asked, asked.dropFirst()) {
            XCTAssertEqual(later.lowerBound, earlier.lowerBound + 100, "each from where the last stopped")
        }
    }

    /// A connection lost mid-segment: what came before it stays on disk, and isn't asked for again.
    func testAFailedReadKeepsWhatArrivedAndTheNextReadAsksOnlyForTheRest() async throws {
        let reads = RequestLog()
        let source = try await layOut(reading: audio(bodies, log: reads, hanging: "seg1.m4s", after: 1_000, failure: URLError(.networkConnectionLost)))
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let key = AudioCacheKey.substitute(videoId: "segmented16", atmosAllowed: true)

        let firstWhole = await cache.cacheCompletely(key, source: source)

        XCTAssertFalse(firstWhole)
        let kept = await cache.cachedRanges(of: key)
        XCTAssertEqual(kept, [0..<Int64(secondSegment + 1_000)])

        let secondWhole = await cache.cacheCompletely(key, source: source)

        XCTAssertTrue(secondWhole)
        let asked = reads.requests(for: "seg1.m4s").compactMap { $0 }
        XCTAssertEqual(asked.count, 2)
        XCTAssertEqual(asked.last?.lowerBound, asked.first.map { $0.lowerBound + 1_000 })
        XCTAssertEqual(reads.requests(for: "seg0.m4s").count, 1, "the segment already there isn't read again")
    }

    /// The player and read-ahead on one range share one read, through a stall too: one request for
    /// the opening and one for the rest, however many are listening.
    @MainActor
    func testTwoReadersOfOneRangeShareOneReadAcrossAStall() async throws {
        let reads = RequestLog()
        let windows = StallWindows()
        let source = try await layOut(reading: audio(bodies, log: reads, hanging: "seg1.m4s", after: 1_000), windows: windows)
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let key = AudioCacheKey.substitute(videoId: "segmented17", atmosAllowed: true)

        let one = Task { await cache.cacheCompletely(key, source: source) }
        await waitUntil("the second segment is being read") { !reads.requests(for: "seg1.m4s").isEmpty }
        let two = Task { await cache.cacheCompletely(key, source: source) }
        // Time for the second reader to reach the hung read. A second request would show here.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(reads.requests(for: "seg1.m4s").count, 1, "the second reader joins")
        windows.end()
        let (oneWhole, twoWhole) = await (one.value, two.value)

        XCTAssertTrue(oneWhole)
        XCTAssertTrue(twoWhole)
        let asked = reads.requests(for: "seg1.m4s").compactMap { $0 }
        XCTAssertEqual(asked.count, 2)
        XCTAssertEqual(asked.last?.lowerBound, asked.first.map { $0.lowerBound + 1_000 })
        XCTAssertEqual(reads.requests(for: "seg0.m4s").count, 1)
    }

    /// Links can go stale during a stall. The stream is found again and the read carries on from
    /// the byte reached, on the fresh link.
    @MainActor
    func testAResumeRefusedForItsLinkFindsTheStreamAgainAndCarriesOnFromTheByteReached() async throws {
        let current = Locked(linked("stale", playlist))
        let reads = RequestLog()
        let windows = StallWindows()
        let serve = audio(bodies, log: reads, hanging: "seg1.m4s", after: 1_000)
        let sources = SegmentedSources(playlistText: { _, _ in current.value }, fetch: server(bodies, log: RequestLog()), readSegment: { url, headers, range, deliver in
            if url.lastPathComponent == "seg1.m4s", url.query == "token=stale", !reads.requests(for: "seg1.m4s").isEmpty {
                throw AudioCacheError.httpStatus(403, url: url)
            }
            try await serve(url, headers, range, deliver)
        }, stallTimer: { try await windows.wait() })
        let finds = Locked(0)
        let fresh = linked("fresh", playlist)
        let resolved = stream
        let made = await sources.source(for: stream) { finds.value += 1; current.value = fresh; return resolved }
        let source = try XCTUnwrap(made)

        let reading = Task { try await source.read(0..<source.contentLength) }
        await waitUntil("the second segment is being read") { !reads.requests(for: "seg1.m4s").isEmpty }
        windows.end()
        let read = try await reading.value

        XCTAssertEqual(read, expectedFile)
        XCTAssertEqual(finds.value, 1)
        let asked = reads.requests(for: "seg1.m4s").compactMap { $0 }
        XCTAssertEqual(asked.count, 2, "the refused ask brings nothing and isn't logged")
        XCTAssertEqual(asked.last?.lowerBound, asked.first.map { $0.lowerBound + 1_000 })
    }

    /// A skip or a seek stops the request. A read ended by cancelling isn't taken for one that
    /// ended early, which would ask for the rest.
    @MainActor
    func testCancellingAReadStopsItsRequestAndAsksForNothingMore() async throws {
        let reads = RequestLog()
        let serve = audio(bodies, log: reads, hanging: "seg1.m4s", after: 1_000)
        let stopped = Locked(false)
        let source = try await layOut(reading: { url, headers, range, deliver in
            try await serve(url, headers, range, deliver)
            if url.lastPathComponent == "seg1.m4s" { stopped.value = true }
        })

        let reading = Task { for try await _ in source.stream(0..<source.contentLength) {} }
        await waitUntil("the second segment is being read") { !reads.requests(for: "seg1.m4s").isEmpty }
        reading.cancel()

        await waitUntil("the request is stopped") { stopped.value }
        // Time for a wrong second request to show.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reads.requests(for: "seg1.m4s").count, 1)
        XCTAssertTrue(reads.requests(for: "seg2.m4s").isEmpty)
    }

    // MARK: The same over HTTP

    private func http(_ answer: @escaping ScriptedCDN.Script, windows: StallWindows = StallWindows()) async throws -> SegmentedAudioSource {
        let text = playlist
        let sources = SegmentedSources(session: ScriptedCDN.session(answer), localPlaylist: { _ in text }, stallTimer: { try await windows.wait() })
        let made = await sources.source(for: stream)
        return try XCTUnwrap(made)
    }

    @MainActor
    func testOverHTTPAHungSegmentArrivesAsItComesAndResumesWithARangeForTheRest() async throws {
        let bodies = self.bodies
        let log = RequestLog()
        let hung = Locked(false)
        let windows = StallWindows()
        let source = try await http({ request in
            let answer = ScriptedCDN.ranged(request, bodies, log: log)
            // The first audio read of the second segment sends a kilobyte and hangs.
            guard request.url?.lastPathComponent == "seg1.m4s", answer.body.count > SegmentedAudioSource.headBytes, !hung.value else { return answer }
            hung.value = true
            var hanging = answer
            hanging.body = answer.body.prefix(1_000)
            hanging.hangs = true
            return hanging
        }, windows: windows)

        let received = Locked(Data())
        let reading = Task {
            for try await piece in source.stream(0..<source.contentLength) { received.value.append(piece) }
        }
        let reached = secondSegment + 1_000
        await waitUntil("what arrived is handed over while the segment hangs") { received.value.count == reached }
        windows.end()
        try await reading.value

        XCTAssertEqual(received.value, expectedFile)
        let audio = log.requests(for: "seg1.m4s").compactMap { $0 }.filter { $0.count > SegmentedAudioSource.headBytes }
        XCTAssertEqual(audio.count, 2)
        XCTAssertEqual(audio.last?.lowerBound, audio.first.map { $0.lowerBound + 1_000 }, "the Range header asks from the byte reached")
        XCTAssertEqual(audio.last?.upperBound, audio.first?.upperBound)
    }

    /// A server sending the whole segment for any range: only the bytes asked for go on.
    func testOverHTTPAServerIgnoringRangesStillGivesTheBytesAskedFor() async throws {
        let bodies = self.bodies
        let source = try await http({ request in
            ScriptedCDN.Answer(status: 200, headers: [:], body: bodies[request.url?.lastPathComponent ?? ""] ?? Data())
        })

        let read = try await source.read(0..<source.contentLength)

        XCTAssertEqual(read, expectedFile)
    }

    /// A refusal still reads as one, so the link refresh sees it, and a portal's page isn't audio.
    func testOverHTTPARefusalAndAPortalsPageAreNotTakenForAudio() async throws {
        let bodies = self.bodies
        let served = Locked(ScriptedCDN.Answer?.none)
        let source = try await http({ request in
            let answer = ScriptedCDN.ranged(request, bodies, log: RequestLog())
            return answer.body.count > SegmentedAudioSource.headBytes ? (served.value ?? answer) : answer
        })

        served.value = ScriptedCDN.Answer(status: 403, headers: [:], body: Data())
        do {
            _ = try await source.read(0..<source.contentLength)
            XCTFail("a refused segment fails the read")
        } catch AudioCacheError.httpStatus(let code, _) {
            XCTAssertEqual(code, 403)
        }

        served.value = ScriptedCDN.Answer(status: 200, headers: ["Content-Type": "text/html"], body: Data("<html>sign in</html>".utf8))
        do {
            _ = try await source.read(0..<source.contentLength)
            XCTFail("a page is not a segment")
        } catch AudioCacheError.badResponse {
        }
    }

    func testOnlyPlaylistsAreLaidOut() {
        XCTAssertTrue(SegmentedAudioSource.handles(stream))
        let file = ResolvedStream(url: URL(string: "https://cdn.example/track.flac")!, origin: .addon, mimeType: "audio/flac", format: StreamFormat(codec: "flac"))
        XCTAssertFalse(SegmentedAudioSource.handles(file))
    }
}

final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(name: String, range: Range<Int64>?)] = []
    func record(_ name: String, _ range: Range<Int64>?) { lock.withLock { entries.append((name, range)) } }
    func requests(for name: String) -> [Range<Int64>?] { lock.withLock { entries.filter { $0.name == name }.map(\.range) } }
    var count: Int { lock.withLock { entries.count } }
}

/// Stall windows a test ends by hand, so a read is judged when the test says, not on a clock.
private final class StallWindows: @unchecked Sendable {
    private let lock = NSLock()
    private var ends = 0
    private var startedCount = 0

    /// How many windows have begun.
    var started: Int { lock.withLock { startedCount } }

    /// Ends the window running now, or the next to begin.
    func end() { lock.withLock { ends += 1 } }

    func wait() async throws {
        lock.withLock { startedCount += 1 }
        while !takeEnd() { try await Task.sleep(for: .milliseconds(1)) }
    }

    private func takeEnd() -> Bool {
        lock.withLock {
            guard ends > 0 else { return false }
            ends -= 1
            return true
        }
    }
}

/// A CDN behind a session, answering as the test's script says, up to hanging mid-body.
private final class ScriptedCDN: URLProtocol, @unchecked Sendable {
    struct Answer: Sendable {
        var status: Int
        var headers: [String: String]
        var body: Data
        var hangs = false
    }
    typealias Script = @Sendable (URLRequest) -> Answer

    private static let lock = NSLock()
    nonisolated(unsafe) private static var script: Script?

    /// One script at a time: XCTest runs a class's tests one after another.
    static func session(_ answer: @escaping Script) -> URLSession {
        lock.withLock { script = answer }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedCDN.self]
        return URLSession(configuration: configuration)
    }

    /// `bodies` answered by name, as a CDN answers: a 206 for a range, stating the whole size.
    static func ranged(_ request: URLRequest, _ bodies: [String: Data], log: RequestLog) -> Answer {
        let name = request.url?.lastPathComponent ?? ""
        let body = bodies[name] ?? Data()
        guard let header = request.value(forHTTPHeaderField: "Range") else {
            log.record(name, nil)
            return Answer(status: 200, headers: [:], body: body)
        }
        let bounds = header.dropFirst("bytes=".count).split(separator: "-").compactMap { Int64($0) }
        let range = bounds[0]..<min(bounds[1] + 1, Int64(body.count))
        log.record(name, range)
        return Answer(status: 206, headers: ["Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(body.count)"],
                      body: body.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let answer = Self.lock.withLock({ Self.script })?(request),
              let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !answer.body.isEmpty { client?.urlProtocol(self, didLoad: answer.body) }
        if !answer.hangs { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() {}
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
