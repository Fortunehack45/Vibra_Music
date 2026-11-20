import XCTest
@testable import Lyrics

/// Priority, fallback and racing across providers, with fake providers standing in for the
/// network.
final class LyricsProviderPriorityTests: XCTestCase {
    private let track = LyricsTrack(videoId: "4D7u5KF7SP8", title: "Get Lucky (Official Audio)", artist: "Daft Punk - Topic", durationMs: 248_000)

    private func repository(_ providers: [LyricsSource: any LyricsProvider], identifier: (any LyricsRecordingIdentifier)? = nil) -> LyricsRepository {
        // Every source not named here misses instantly.
        var all = [LyricsSource: any LyricsProvider]()
        for source in LyricsSource.allCases { all[source] = FakeLyricsProvider(lines: nil) }
        providers.forEach { all[$0.key] = $0.value }
        return LyricsRepository(session: StubURLProtocol.session { _ in nil }.0, overrides: all, identifier: identifier ?? NoIdentifier())
    }

    /// Lyrics found once are still there with no connection: the lookup that finds nothing falls
    /// back to what was saved, word timings included; a track never looked up has none.
    func testLyricsFoundOnceAreServedWhenNothingAnswers() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "lyrics-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        func repo(_ lines: [LyricLine]?) -> LyricsRepository {
            var all = [LyricsSource: any LyricsProvider]()
            for source in LyricsSource.allCases { all[source] = FakeLyricsProvider(lines: nil) }
            all[.betterLyrics] = FakeLyricsProvider(lines: lines)
            return LyricsRepository(session: StubURLProtocol.session { _ in nil }.0, overrides: all, identifier: NoIdentifier(),
                                    store: LyricsDiskStore(directory: directory))
        }
        let online = await repo(wordSynced("kept for later")).lyrics(for: track, preferences: LyricsPreferences())
        XCTAssertEqual(online?.source, .betterLyrics)

        // A new process, and every source misses.
        let offline = await repo(nil).lyrics(for: track, preferences: LyricsPreferences())
        XCTAssertEqual(offline, online, "the same lines, with their word timings")
        XCTAssertTrue(offline?.isWordSynced == true)

        let other = LyricsTrack(videoId: "neverLooked1", title: "Other", artist: "Artist", durationMs: 200_000)
        let none = await repo(nil).lyrics(for: other, preferences: LyricsPreferences())
        XCTAssertNil(none)

        var off = LyricsPreferences()
        off.syncedLyricsEnabled = false
        let disabled = await repo(nil).lyrics(for: track, preferences: off)
        XCTAssertNil(disabled, "lyrics switched off stay off")
    }

    func testTheHighestPrioritySourceThatAnswersWins() async throws {
        let repo = repository([.lrcLib: FakeLyricsProvider(lines: lineSynced("from lrclib")), .kuGou: FakeLyricsProvider(lines: lineSynced("from kugou"))])
        let result = await repo.lyrics(for: track, sources: [.lrcLib, .kuGou], order: [.kuGou, .lrcLib])
        XCTAssertEqual(result?.source, .kuGou)
        XCTAssertEqual(result?.lines.map(\.text), ["from kugou"])
    }

    /// PORTING.md's done-test: turning off the top provider makes lyrics load from the next one.
    func testTurningOffTheTopProviderLoadsFromTheNextOne() async throws {
        let top = FakeLyricsProvider(lines: wordSynced("from the top"))
        let next = FakeLyricsProvider(lines: lineSynced("from the next"))
        let repo = repository([.betterLyrics: top, .lrcLib: next])
        var preferences = LyricsPreferences()
        let first = await repo.lyrics(for: track, preferences: preferences)
        XCTAssertEqual(first?.source, .betterLyrics)

        preferences.enabledSources.remove(.betterLyrics)
        let second = await repo.lyrics(for: track, preferences: preferences)
        XCTAssertEqual(second?.source, .lrcLib)
        XCTAssertEqual(top.calls, 1, "a source that is switched off is not contacted")
    }

    func testALowerPrioritySourceFinishingFirstNeverPreemptsOneStillPending() async throws {
        let slowTop = FakeLyricsProvider(lines: lineSynced("slow but first"), delay: 0.3)
        let fastLow = FakeLyricsProvider(lines: wordSynced("fast but second"))
        let repo = repository([.lrcLib: slowTop, .kuGou: fastLow])
        let result = await repo.lyrics(for: track, sources: [.lrcLib, .kuGou], order: [.lrcLib, .kuGou])
        XCTAssertEqual(result?.source, .lrcLib)
    }

    func testEverySourceIsAskedAtOnceNotOneAfterAnother() async throws {
        let providers: [LyricsSource: any LyricsProvider] = [
            .lrcLib: FakeLyricsProvider(lines: nil, delay: 0.4),
            .kuGou: FakeLyricsProvider(lines: nil, delay: 0.4),
            .musixmatch: FakeLyricsProvider(lines: lineSynced("third"), delay: 0.4),
        ]
        let start = Date()
        let result = await repository(providers).lyrics(for: track, sources: [.lrcLib, .kuGou, .musixmatch], order: [.lrcLib, .kuGou, .musixmatch])
        XCTAssertEqual(result?.source, .musixmatch)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testAWordTimedAnswerWinsOutrightOverALineTimedOneWhenPrioritised() async throws {
        let repo = repository([.lrcLib: FakeLyricsProvider(lines: lineSynced("line")), .unison: FakeLyricsProvider(lines: wordSynced("word synced"))])
        let plain = await repo.lyrics(for: track, sources: [.lrcLib, .unison], order: [.lrcLib, .unison], prioritizeSyllableSync: false)
        XCTAssertEqual(plain?.source, .lrcLib, "priority is priority when syllable sync isn't prioritised")
        let prioritised = await repo.lyrics(for: track, sources: [.lrcLib, .unison], order: [.lrcLib, .unison], prioritizeSyllableSync: true)
        XCTAssertEqual(prioritised?.source, .unison)
    }

    func testAPlainAnswerHeldAsFallbackGivesWayToATimedOneBehindItWhenPrioritised() async throws {
        let repo = repository([.youtubeMusic: FakeLyricsProvider(lines: [LyricLine(timeMs: 0, text: "tab text")]), .lrcLib: FakeLyricsProvider(lines: lineSynced("timed"))])
        let result = await repo.lyrics(for: track, sources: [.youtubeMusic, .lrcLib], order: [.youtubeMusic, .lrcLib], prioritizeSyllableSync: true)
        XCTAssertEqual(result?.source, .lrcLib)
        let plainOnly = await repository([.youtubeMusic: FakeLyricsProvider(lines: [LyricLine(timeMs: 0, text: "tab text")])])
            .lyrics(for: track, sources: [.youtubeMusic, .lrcLib], order: [.youtubeMusic, .lrcLib], prioritizeSyllableSync: true)
        XCTAssertEqual(plainOnly?.source, .youtubeMusic, "still the fallback when nothing timed turns up")
    }

    func testALineTimedFallbackIsKeptWhenNobodyHasWordTiming() async throws {
        let repo = repository([.lrcLib: FakeLyricsProvider(lines: lineSynced("line")), .kuGou: FakeLyricsProvider(lines: lineSynced("other"))])
        let result = await repo.lyrics(for: track, sources: [.lrcLib, .kuGou], order: [.lrcLib, .kuGou], prioritizeSyllableSync: true)
        XCTAssertEqual(result?.source, .lrcLib)
    }

    func testGeniusIsOnlyContactedWhenEverySyncedSourceMissed() async throws {
        let genius = FakeLyricsProvider(lines: [LyricLine(timeMs: 0, text: "plain words")])
        let hit = repository([.lrcLib: FakeLyricsProvider(lines: lineSynced("synced")), .genius: genius])
        _ = await hit.lyrics(for: track, sources: [.lrcLib, .genius], order: [.genius, .lrcLib])
        XCTAssertEqual(genius.calls, 1, "ahead of the synced source in the order, it is still asked")

        let lazy = FakeLyricsProvider(lines: [LyricLine(timeMs: 0, text: "plain words")])
        let behind = repository([.lrcLib: FakeLyricsProvider(lines: lineSynced("synced")), .genius: lazy])
        let result = await behind.lyrics(for: track, sources: [.lrcLib, .genius], order: [.lrcLib, .genius])
        XCTAssertEqual(result?.source, .lrcLib)
        XCTAssertEqual(lazy.calls, 0, "behind a hit, Genius is never started")

        let fallback = FakeLyricsProvider(lines: [LyricLine(timeMs: 0, text: "plain words")])
        let missed = repository([.genius: fallback])
        let plain = await missed.lyrics(for: track, sources: [.lrcLib, .genius], order: [.lrcLib, .genius])
        XCTAssertEqual(plain?.source, .genius)
        XCTAssertEqual(fallback.calls, 1)
    }

    func testAPlainAnswerIsHeldAsTheFallbackAndSkipsGenius() async throws {
        let genius = FakeLyricsProvider(lines: [LyricLine(timeMs: 0, text: "genius")])
        let repo = repository([.youtubeMusic: FakeLyricsProvider(lines: [LyricLine(timeMs: 0, text: "tab text")]), .genius: genius])
        let result = await repo.lyrics(for: track, sources: [.youtubeMusic, .genius], order: [.youtubeMusic, .genius])
        XCTAssertEqual(result?.source, .youtubeMusic)
        XCTAssertEqual(genius.calls, 0)
    }

    func testAnEmptySelectionIsNoLyricsAndNoRequests() async throws {
        let provider = FakeLyricsProvider(lines: lineSynced("x"))
        let repo = repository([.lrcLib: provider])
        let none = await repo.lyrics(for: track, sources: [])
        XCTAssertNil(none)
        let off = await repo.lyrics(for: track, preferences: LyricsPreferences(syncedLyricsEnabled: false))
        XCTAssertNil(off)
        XCTAssertEqual(provider.calls, 0)
    }

    func testASourceMissingFromTheOrderFallsInAfterEverythingNamed() async throws {
        let repo = repository([.lrcLib: FakeLyricsProvider(lines: lineSynced("lrclib")), .biniLyrics: FakeLyricsProvider(lines: lineSynced("bini"))])
        let result = await repo.lyrics(for: track, sources: [.lrcLib, .biniLyrics], order: [.lrcLib])
        XCTAssertEqual(result?.source, .lrcLib)
    }

    func testProvidersAreAskedForTheCleanedName() async throws {
        let seen = LockedBox<LyricsProviderRequest?>(nil)
        let provider = FakeLyricsProvider { request in
            seen.set(request)
            return nil
        }
        _ = await repository([.lrcLib: provider]).lyrics(for: track, sources: [.lrcLib])
        XCTAssertEqual(seen.value?.title, "Get Lucky")
        XCTAssertEqual(seen.value?.artist, "Daft Punk")
        XCTAssertEqual(seen.value?.durationMs, 248_000)
    }

    func testTheWinnersBracketedAnswerIsSplitIntoABackgroundLine() async throws {
        let repo = repository([.lrcLib: FakeLyricsProvider(lines: [LyricLine(timeMs: 1_000, text: "lead (echo)")])])
        let result = await repo.lyrics(for: track, sources: [.lrcLib])
        XCTAssertEqual(result?.lines.first?.text, "lead")
        XCTAssertEqual(result?.lines.first?.background?.text, "(echo)")
    }

    func testAThrowingProviderIsAMiss() async throws {
        struct Boom: Error {}
        let repo = repository([.lrcLib: FakeLyricsProvider { _ in throw Boom() }, .kuGou: FakeLyricsProvider(lines: lineSynced("kugou"))])
        let log = LyricsEventLog()
        let result = await repo.lyrics(for: track, sources: [.lrcLib, .kuGou], order: [.lrcLib, .kuGou], onEvent: log.handler)
        XCTAssertEqual(result?.source, .kuGou)
        XCTAssertTrue(log.events.contains(.finished(.lrcLib, nil)))
    }

    // MARK: Events

    func testEventsReportStartsResultsAndCancelledRaceLosers() async throws {
        let repo = repository([
            .lrcLib: FakeLyricsProvider(lines: lineSynced("winner")),
            .kuGou: FakeLyricsProvider(lines: nil),
            .musixmatch: FakeLyricsProvider(lines: lineSynced("too slow"), delay: 5),
        ])
        let log = LyricsEventLog()
        let start = Date()
        let result = await repo.lyrics(for: track, sources: [.lrcLib, .kuGou, .musixmatch], order: [.lrcLib, .kuGou, .musixmatch], onEvent: log.handler)
        XCTAssertEqual(result?.source, .lrcLib)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "the loser is cancelled, not waited out")
        let events = log.events
        for source in [LyricsSource.lrcLib, .kuGou, .musixmatch] {
            XCTAssertTrue(events.contains(.started(source)), "\(source) started")
        }
        XCTAssertTrue(events.contains { if case .finished(.lrcLib, let found?) = $0 { return found.source == .lrcLib }; return false })
        XCTAssertTrue(events.contains(.cancelled(.musixmatch)), "a cancelled loser is not reported as a miss")
        XCTAssertFalse(events.contains(.finished(.musixmatch, nil)))
        // Each provider reports its start before its outcome.
        for source in [LyricsSource.lrcLib, .musixmatch] {
            let started = try XCTUnwrap(events.firstIndex(of: .started(source)))
            let ended = try XCTUnwrap(events.firstIndex { $0.source == source && $0 != .started(source) })
            XCTAssertLessThan(started, ended)
        }
    }

    func testCancellingTheLookupCancelsEveryProvider() async throws {
        let repo = repository([.lrcLib: FakeLyricsProvider(lines: lineSynced("never"), delay: 5), .kuGou: FakeLyricsProvider(lines: lineSynced("never"), delay: 5)])
        let log = LyricsEventLog()
        let task = Task { await repo.lyrics(for: track, sources: [.lrcLib, .kuGou], onEvent: log.handler) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertTrue(log.events.contains(.cancelled(.lrcLib)))
        XCTAssertTrue(log.events.contains(.cancelled(.kuGou)))
    }

    // MARK: Matching on the recording

    func testTheRecordingIsIdentifiedOnceAndHandedToEveryProvider() async throws {
        let identifier = CountingIdentifier(isrc: "USQX91300809")
        let seen = LockedBox<String?>(nil)
        let lyricsPlus = FakeLyricsProvider { request in
            seen.set(request.isrc)
            return LyricsProviderAnswer(lines: wordSynced("found"))
        }
        let repo = repository([.lyricsPlus: lyricsPlus], identifier: identifier)
        _ = await repo.lyrics(for: track, sources: [.biniLyrics, .lyricsPlus], order: [.biniLyrics, .lyricsPlus])
        XCTAssertEqual(seen.value, "USQX91300809")
        XCTAssertEqual(repo.rememberedISRC(forVideoId: track.videoId), "USQX91300809")
        // Asked about twice, the track pays for identification once.
        _ = await repo.lyrics(for: track, sources: [.biniLyrics, .lyricsPlus], order: [.biniLyrics, .lyricsPlus])
        XCTAssertEqual(identifier.calls, 1)
    }

    func testIdentificationIsSkippedWhenBiniLyricsIsSwitchedOff() async throws {
        let identifier = CountingIdentifier(isrc: "USQX91300809")
        let repo = repository([.lrcLib: FakeLyricsProvider(lines: lineSynced("x"))], identifier: identifier)
        _ = await repo.lyrics(for: track, sources: [.lrcLib])
        XCTAssertEqual(identifier.calls, 0, "a source that is switched off is not contacted, not even to help the others")
    }

    func testTheCallersISRCBeatsAskingAgain() async throws {
        let identifier = CountingIdentifier(isrc: "WRONG")
        let seen = LockedBox<String?>(nil)
        let provider = FakeLyricsProvider { request in
            seen.set(request.isrc)
            return nil
        }
        var local = track
        local.isrc = "FROMTHEFILE1"
        _ = await repository([.lyricsPlus: provider], identifier: identifier).lyrics(for: local, sources: [.biniLyrics, .lyricsPlus])
        XCTAssertEqual(seen.value, "FROMTHEFILE1")
        XCTAssertEqual(identifier.calls, 0)
    }

    func testASlowIdentificationIsGivenUpOnRatherThanWaitedOut() async throws {
        let identifier = CountingIdentifier(isrc: "LATE", delay: 10)
        let repo = repository([.lrcLib: FakeLyricsProvider(lines: lineSynced("x"))], identifier: identifier)
        let start = Date()
        let result = await repo.lyrics(for: track, sources: [.biniLyrics, .lrcLib])
        XCTAssertEqual(result?.source, .lrcLib)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        XCTAssertNil(repo.rememberedISRC(forVideoId: track.videoId))
    }

    func testTheISRCMemoryIsBoundedLeastRecentlyUsed() {
        let memory = LyricsISRCMemory(capacity: 2)
        memory["a"] = "A"
        memory["b"] = "B"
        _ = memory["a"]
        memory["c"] = "C"
        XCTAssertEqual(memory["a"], "A")
        XCTAssertNil(memory["b"])
        XCTAssertEqual(memory["c"], "C")
        memory["d"] = "  "
        XCTAssertNil(memory["d"])
    }

    // MARK: Helpers

    private struct NoIdentifier: LyricsRecordingIdentifier {
        func identify(_ request: LyricsProviderRequest) async throws -> String? { nil }
    }

    private final class CountingIdentifier: LyricsRecordingIdentifier, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        let isrc: String
        let delay: TimeInterval
        init(isrc: String, delay: TimeInterval = 0) {
            self.isrc = isrc
            self.delay = delay
        }
        var calls: Int { lock.withLock { count } }
        func identify(_ request: LyricsProviderRequest) async throws -> String? {
            lock.withLock { count += 1 }
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            return isrc
        }
    }
}

/// A tiny thread-safe box for values captured by fake providers.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func set(_ value: Value) { lock.withLock { stored = value } }
}
