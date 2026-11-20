import VibraMusicCore
import Intents
import XCTest
@testable import Vibra Music

/// PORTING.md "Voice “play X”": a spoken request plays the best match; a bare "play music" resumes
/// (MusicLink.kt `MEDIA_PLAY_FROM_SEARCH`, MainActivity's `LinkRequest.Search(play = true)`).
@MainActor
final class VoicePlayTests: XCTestCase {
    func testPlayDaftPunkPlaysTheBestMatch() async throws {
        let harness = PlayerHarness(test: self)
        let top = try harness.song("dddddddddd1")
        let other = try harness.song("dddddddddd2")
        let router = AppRouter()
        var asked: [String] = []
        let outcome = await VoicePlayback.play(request: "  Daft Punk ", player: harness.player, router: router) { query in
            asked.append(query)
            return [top, other]
        }
        XCTAssertEqual(outcome, .playing)
        XCTAssertEqual(asked, ["Daft Punk"])
        XCTAssertEqual(harness.player.currentSong?.videoId, top.videoId)
        XCTAssertEqual(harness.player.playingFromSource?.type, .search)
        await waitUntil("playing") { harness.engine.isPlaying }
    }

    func testABarePlayMusicResumesWhatWasPlaying() async throws {
        let harness = PlayerHarness(test: self)
        let songs = try (1...2).map { try harness.song("rrrrrrrrrr\($0)") }
        harness.player.play(songs, startAt: 0)
        await waitUntil("playing") { harness.engine.isPlaying }
        harness.player.pause()
        XCTAssertFalse(harness.player.playWhenReady)

        var searched = false
        let outcome = await VoicePlayback.play(request: nil, player: harness.player, router: AppRouter()) { _ in searched = true; return [] }
        XCTAssertEqual(outcome, .resumed)
        XCTAssertFalse(searched)
        XCTAssertTrue(harness.player.playWhenReady)
        XCTAssertEqual(harness.player.currentSong?.videoId, songs[0].videoId)
    }

    func testNothingToResumeAndNoMatchAreAnsweredHonestly() async {
        let harness = PlayerHarness(test: self)
        let router = AppRouter()
        let nothing = await VoicePlayback.play(request: "", player: harness.player, router: router) { _ in [] }
        XCTAssertEqual(nothing, .nothingToPlay)

        let noMatch = await VoicePlayback.play(request: "zzzz", player: harness.player, router: router) { _ in [] }
        XCTAssertEqual(noMatch, .showedSearch, "the results are a better answer than silence")
        XCTAssertEqual(router.selectedTab, .search)
        XCTAssertEqual(router.pendingSearch, AppRouter.PendingSearch(query: "zzzz", play: false))
    }

    /// "Hey Siri, play Get Lucky by Daft Punk in Vibra Music" arrives as a SiriKit media search.
    func testSirisMediaSearchBecomesTheQuery() async {
        let named = INPlayMediaIntent(mediaSearch: INMediaSearch(mediaType: .song, mediaName: "Get Lucky", artistName: "Daft Punk"))
        XCTAssertEqual(PlayMediaIntentHandler.query(of: named), "Get Lucky Daft Punk")
        let artistOnly = INPlayMediaIntent(mediaSearch: INMediaSearch(mediaType: .artist, artistName: "Daft Punk"))
        XCTAssertEqual(PlayMediaIntentHandler.query(of: artistOnly), "Daft Punk")
        XCTAssertNil(PlayMediaIntentHandler.query(of: INPlayMediaIntent()), "\"play music\" names nothing")

        XCTAssertEqual(PlayMediaIntentHandler.code(for: .playing), .success)
        XCTAssertEqual(PlayMediaIntentHandler.code(for: .resumed), .success)
        XCTAssertEqual(PlayMediaIntentHandler.code(for: .showedSearch), .continueInApp)
        XCTAssertEqual(PlayMediaIntentHandler.code(for: .nothingToPlay), .failureNoUnplayedContent)

        RecordingIntentHandler.requests = []
        RecordingIntentHandler.outcome = .playing
        SystemIntentBridge.handlerOverride = RecordingIntentHandler.self
        defer { SystemIntentBridge.handlerOverride = nil }
        let response = await PlayMediaIntentHandler().handle(intent: named)
        XCTAssertEqual(response.code, .success)
        XCTAssertEqual(RecordingIntentHandler.requests, ["Get Lucky Daft Punk"])
    }

    func testTheAppShortcutsAskForMusic() async throws {
        RecordingIntentHandler.requests = []
        RecordingIntentHandler.outcome = .resumed
        SystemIntentBridge.handlerOverride = RecordingIntentHandler.self
        defer { SystemIntentBridge.handlerOverride = nil }
        _ = try await PlayMusicIntent().perform()
        _ = try await PlayMusicIntent(query: "Daft Punk").perform()
        XCTAssertEqual(RecordingIntentHandler.requests, [nil, "Daft Punk"])
        XCTAssertEqual(VibraMusicShortcuts.appShortcuts.count, 2)
    }

    func testTheAppShortcutsFailWhenNothingPlays() async {
        SystemIntentBridge.handlerOverride = RecordingIntentHandler.self
        defer { SystemIntentBridge.handlerOverride = nil }
        for outcome in [SystemPlayOutcome.nothingToPlay, .unavailable] {
            RecordingIntentHandler.outcome = outcome
            do {
                _ = try await PlayMusicIntent().perform()
                XCTFail("\(outcome) reported success")
            } catch {
                XCTAssertTrue(error is NothingPlayedError, "\(outcome): \(error)")
            }
        }
    }
}
