import XCTest
@testable import Lyrics

/// The per-track lookup and provider picker (Android: the lyrics half of `MainViewModel`).
@MainActor
final class LyricsProviderPickerTests: XCTestCase {
    private let track = LyricsTrack(videoId: "4D7u5KF7SP8", title: "Get Lucky", artist: "Daft Punk", durationMs: 248_000)

    private func session(_ providers: [LyricsSource: any LyricsProvider], embedded: @escaping @Sendable (URL) async -> [LyricLine]? = { _ in nil }) -> LyricsSession {
        var all = [LyricsSource: any LyricsProvider]()
        for source in LyricsSource.allCases { all[source] = FakeLyricsProvider(lines: nil) }
        providers.forEach { all[$0.key] = $0.value }
        let repository = LyricsRepository(session: StubURLProtocol.session { _ in nil }.0, overrides: all, identifier: NoIdentifier())
        return LyricsSession(repository: repository, embedded: embedded)
    }

    private func settle(_ session: LyricsSession, until condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    private var preferences: LyricsPreferences {
        LyricsPreferences(enabledSources: [.lrcLib, .kuGou, .musixmatch], sourceOrder: [.lrcLib, .kuGou, .musixmatch])
    }

    func testLoadsTheWinnerAndMarksEveryProvidersRow() async {
        let session = session([.lrcLib: FakeLyricsProvider(lines: nil), .kuGou: FakeLyricsProvider(lines: lineSynced("kugou"))])
        session.load(track, preferences: preferences)
        XCTAssertFalse(session.isChecked)
        await settle(session) { session.isChecked }
        XCTAssertEqual(session.source, .kuGou)
        XCTAssertEqual(session.lines?.map(\.text), ["kugou"])
        XCTAssertEqual(session.providerStates[.lrcLib], .notFound)
        XCTAssertEqual(session.providerStates[.kuGou], .found)
        XCTAssertEqual(session.providerStates[.genius], .notFetched)
    }

    func testChoosingAFoundProviderAppliesItFromMemory() async {
        let musixmatch = FakeLyricsProvider(lines: lineSynced("musixmatch"))
        // LRCLIB is first in the order but answers second, so Musixmatch's hit is held.
        let session = session([.lrcLib: FakeLyricsProvider(lines: lineSynced("lrclib"), delay: 0.2), .musixmatch: musixmatch])
        session.load(track, preferences: LyricsPreferences(enabledSources: [.lrcLib, .musixmatch], sourceOrder: [.lrcLib, .musixmatch]))
        await settle(session) { session.isChecked }
        XCTAssertEqual(session.source, .lrcLib)
        XCTAssertEqual(session.providerStates[.musixmatch], .found)
        session.selectProvider(.musixmatch)
        XCTAssertEqual(session.source, .musixmatch)
        XCTAssertEqual(session.lines?.map(\.text), ["musixmatch"])
        XCTAssertEqual(musixmatch.calls, 1, "a completed hit is applied without going online")
    }

    func testChoosingAnUntouchedProviderFetchesItAlone() async {
        let genius = FakeLyricsProvider(lines: [LyricLine(timeMs: 0, text: "from genius")])
        let session = session([.lrcLib: FakeLyricsProvider(lines: lineSynced("lrclib")), .genius: genius])
        session.load(track, preferences: LyricsPreferences(enabledSources: [.lrcLib, .genius], sourceOrder: [.lrcLib, .genius]))
        await settle(session) { session.isChecked }
        XCTAssertEqual(session.providerStates[.genius], .notFetched)
        session.selectProvider(.genius)
        XCTAssertEqual(session.selectedSource, .genius)
        await settle(session) { session.source == .genius }
        XCTAssertEqual(session.lines?.map(\.text), ["from genius"])
        XCTAssertEqual(session.providerStates[.genius], .found)
        XCTAssertEqual(genius.calls, 1)
    }

    func testChoosingAProviderThatMissedDoesNothing() async {
        let session = session([.lrcLib: FakeLyricsProvider(lines: nil), .kuGou: FakeLyricsProvider(lines: lineSynced("kugou"))])
        session.load(track, preferences: preferences)
        await settle(session) { session.isChecked && session.providerStates[.lrcLib] == .notFound }
        session.selectProvider(.lrcLib)
        XCTAssertNil(session.selectedSource)
        XCTAssertEqual(session.source, .kuGou)
    }

    func testChoosingAProviderStillFetchingAppliesItWhenItLands() async {
        // Syllable sync prioritised, so the race keeps waiting on KuGou after LRCLIB's
        // line-synced answer.
        let session = session([.lrcLib: FakeLyricsProvider(lines: lineSynced("lrclib")), .kuGou: FakeLyricsProvider(lines: lineSynced("slow kugou"), delay: 0.3)])
        session.load(track, preferences: LyricsPreferences(enabledSources: [.lrcLib, .kuGou], sourceOrder: [.lrcLib, .kuGou], prioritizeSyllableSync: true))
        await settle(session) { session.providerStates[.kuGou] == .fetching && session.providerStates[.lrcLib] == .found }
        XCTAssertEqual(session.providerStates[.kuGou], .fetching)
        session.selectProvider(.kuGou)
        await settle(session) { session.isChecked }
        XCTAssertEqual(session.source, .kuGou)
        XCTAssertEqual(session.lines?.map(\.text), ["slow kugou"])
    }

    func testChoosingARaceLoserBeforeItIsCancelledRefetchesIt() async {
        // KuGou wins at 0.2 s, which cancels LRCLIB mid-flight; the tap on LRCLIB is honoured
        // with a request of its own instead of leaving the row stuck at "Fetching".
        let lrclib = FakeLyricsProvider(lines: lineSynced("slow lrclib"), delay: 0.4)
        let session = session([.kuGou: FakeLyricsProvider(lines: lineSynced("kugou"), delay: 0.2), .lrcLib: lrclib])
        session.load(track, preferences: LyricsPreferences(enabledSources: [.lrcLib, .kuGou], sourceOrder: [.kuGou, .lrcLib]))
        await settle(session) { session.providerStates[.lrcLib] == .fetching }
        session.selectProvider(.lrcLib)
        await settle(session) { session.source == .lrcLib }
        XCTAssertEqual(session.lines?.map(\.text), ["slow lrclib"])
        XCTAssertEqual(session.providerStates[.lrcLib], .found)
        XCTAssertEqual(lrclib.calls, 2)
    }

    func testTheSameTrackAndSettingsIsANoOpButChangedSourcesReload() async {
        let lrclib = FakeLyricsProvider(lines: lineSynced("lrclib"))
        let session = session([.lrcLib: lrclib])
        let settings = LyricsPreferences(enabledSources: [.lrcLib], sourceOrder: [.lrcLib])
        session.load(track, preferences: settings)
        await settle(session) { session.isChecked }
        session.load(track, preferences: settings)
        XCTAssertTrue(session.isChecked)
        XCTAssertEqual(lrclib.calls, 1)

        session.load(track, preferences: LyricsPreferences(enabledSources: [.lrcLib, .kuGou], sourceOrder: [.lrcLib, .kuGou]))
        await settle(session) { session.isChecked }
        XCTAssertEqual(lrclib.calls, 2)
    }

    func testSwitchedOffIsCheckedWithNothingToShow() {
        let session = session([.lrcLib: FakeLyricsProvider(lines: lineSynced("x"))])
        session.load(track, preferences: LyricsPreferences(syncedLyricsEnabled: false))
        XCTAssertTrue(session.isChecked)
        XCTAssertNil(session.lines)
    }

    func testSwitchedOffIsCheckedEvenBeforeTheDurationArrives() {
        let session = session([.lrcLib: FakeLyricsProvider(lines: lineSynced("x"))])
        var unknown = track
        unknown.durationMs = 0
        session.load(unknown, preferences: LyricsPreferences(syncedLyricsEnabled: false))
        XCTAssertTrue(session.isChecked, "nothing will be looked up, so there is no duration to wait for")
        XCTAssertNil(session.lines)
    }

    func testWaitsForTheDurationBeforeMatchingByName() async {
        let lrclib = FakeLyricsProvider(lines: lineSynced("lrclib"))
        let session = session([.lrcLib: lrclib])
        var unknown = track
        unknown.durationMs = 0
        session.load(unknown, preferences: LyricsPreferences(enabledSources: [.lrcLib], sourceOrder: [.lrcLib]))
        XCTAssertFalse(session.isChecked)
        XCTAssertEqual(lrclib.calls, 0)
        // The re-trigger carrying the duration is not dropped as a duplicate.
        session.load(track, preferences: LyricsPreferences(enabledSources: [.lrcLib], sourceOrder: [.lrcLib]))
        await settle(session) { session.isChecked }
        XCTAssertEqual(session.lines?.map(\.text), ["lrclib"])
    }

    func testADownloadedFilesOwnLyricsComeFirstAndWorkOffline() async {
        let lrclib = FakeLyricsProvider(lines: lineSynced("network"))
        let session = session([.lrcLib: lrclib], embedded: { _ in lineSynced("from the file") })
        var local = track
        local.durationMs = 0
        local.localFileURL = URL(fileURLWithPath: "/tmp/song.m4a")
        session.load(local, preferences: LyricsPreferences(enabledSources: [.lrcLib], sourceOrder: [.lrcLib]))
        await settle(session) { session.isChecked }
        XCTAssertEqual(session.lines?.map(\.text), ["from the file"])
        XCTAssertNil(session.source, "the file names no provider")
        XCTAssertEqual(lrclib.calls, 0)
    }

    func testANewTrackDiscardsTheOldLookup() async {
        let byVideo = FakeLyricsProvider { request in
            if request.videoId == "4D7u5KF7SP8" { try await Task.sleep(nanoseconds: 300_000_000) }
            return LyricsProviderAnswer(lines: lineSynced("for " + request.videoId))
        }
        let session = session([.lrcLib: byVideo])
        let settings = LyricsPreferences(enabledSources: [.lrcLib], sourceOrder: [.lrcLib])
        session.load(track, preferences: settings)
        var next = track
        next.videoId = "dQw4w9WgXcQ"
        session.load(next, preferences: settings)
        await settle(session) { session.isChecked }
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(session.lines?.map(\.text), ["for dQw4w9WgXcQ"], "the old track's late answer never lands")
        session.reset()
        XCTAssertNil(session.lines)
        XCTAssertFalse(session.isChecked)
    }

    private struct NoIdentifier: LyricsRecordingIdentifier {
        func identify(_ request: LyricsProviderRequest) async throws -> String? { nil }
    }
}
