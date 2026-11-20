import VibraMusicCore
import Integrations
import SwiftUI
import XCTest
@testable import VibraMusic

/// PORTING §2.9 "Scrobbling": ListenBrainz by token, Last.fm by username and password, the
/// switches that ask for credentials first, signing out of Last.fm, and the timing options.
@MainActor
final class ScrobblingSettingsTests: XCTestCase {
    func testTurningAScrobblerOnWithoutCredentialsAsksForThemFirst() {
        let settings = makeAccountTestSettings()
        XCTAssertEqual(AccountScrobbling.listenBrainzSwitch(to: true, settings: settings), .openLogin)
        XCTAssertEqual(AccountScrobbling.lastfmSwitch(to: true, settings: settings), .openLogin)
        XCTAssertEqual(AccountScrobbling.listenBrainzSwitch(to: false, settings: settings), .set(false))
        XCTAssertEqual(AccountScrobbling.listenBrainzSubtitle(settings), L10n.enterTokenToEnable)
        XCTAssertEqual(AccountScrobbling.lastfmSubtitle(settings), L10n.tapToSignIn)

        settings.listenBrainzToken = "lb-token"
        XCTAssertEqual(AccountScrobbling.listenBrainzSwitch(to: true, settings: settings), .set(true))
        settings.listenBrainzEnabled = true
        XCTAssertEqual(AccountScrobbling.listenBrainzSubtitle(settings), L10n.connected)
    }

    /// ListenBrainz gets a finished listen for a track that played to its end, never for a skip,
    /// as on Android. A skip now reports how far it got, so without the check it read as a listen.
    func testListenBrainzSubmitsAFinishedListenOnlyForATrackThatEnded() async throws {
        let stub = HTTPRecordingStub { _ in .json("{\"status\":\"ok\"}") }
        let settings = makeAccountTestSettings()
        settings.listenBrainzToken = "lb-token"
        settings.listenBrainzEnabled = true
        let observer = ScrobblingObserver(settings: settings, session: stub.session)
        let skipped = Song(videoId: "lbSkipped", title: "Skipped", artist: "Artist", durationText: "3:00")
        let ended = Song(videoId: "lbEnded", title: "Ended", artist: "Artist", durationText: "3:00")
        let next = Song(videoId: "lbNext", title: "Next", artist: "Artist", durationText: "3:00")
        let singles = { stub.requests.filter { String(decoding: $0.body, as: UTF8.self).contains("\"single\"") } }

        observer.playback(didStart: next, durationMs: 180_000, isPlaying: true, previous: skipped, previousListened: false, previousPositionMs: 10_000)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(singles().isEmpty, "a skip ten seconds in is not a listen")

        observer.playback(didStart: next, durationMs: 180_000, isPlaying: true, previous: ended, previousListened: true, previousPositionMs: 180_000)
        let deadline = Date().addingTimeInterval(5)
        while singles().isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(singles().count, 1, "a track that played to its end is")
    }

    func testALastfmSignInStoresTheSessionAndTurnsScrobblingOn() {
        let settings = makeAccountTestSettings()
        AccountScrobbling.didSignInToLastfm(LastFMSessionInfo(username: "maya", sessionKey: "sk-1"), settings: settings)
        XCTAssertEqual(settings.lastfmSessionKey, "sk-1")
        XCTAssertEqual(settings.lastfmUsername, "maya")
        XCTAssertTrue(settings.lastfmEnabled)
        XCTAssertTrue(AccountScrobbling.lastfmActive(settings), "the sub-switches and timing group show")
        XCTAssertEqual(AccountScrobbling.lastfmSubtitle(settings), L10n.signedInAs("maya"))
        XCTAssertEqual(AccountScrobbling.lastfmSwitch(to: false, settings: settings), .set(false))
    }

    func testTappingTheSignedInLastfmRowSignsOutAndSwitchesEverythingOff() {
        let settings = makeAccountTestSettings()
        AccountScrobbling.didSignInToLastfm(LastFMSessionInfo(username: "maya", sessionKey: "sk-1"), settings: settings)
        settings.lastfmScrobbleEnabled = true
        settings.lastfmNowPlaying = true
        XCTAssertFalse(AccountScrobbling.tapLastfmRow(settings: settings), "signing out opens nothing")
        XCTAssertEqual(settings.lastfmSessionKey, "")
        XCTAssertEqual(settings.lastfmUsername, "")
        XCTAssertFalse(settings.lastfmEnabled)
        XCTAssertFalse(settings.lastfmScrobbleEnabled)
        XCTAssertFalse(settings.lastfmNowPlaying)
        XCTAssertTrue(AccountScrobbling.tapLastfmRow(settings: settings), "signed out, the row asks for the login")
    }

    func testAFailedLoginSaysWhatLastfmSaid() {
        XCTAssertEqual(AccountScrobbling.loginErrorMessage(LastFMError(code: 4, message: "Invalid credentials")),
                       "Invalid credentials")
        XCTAssertEqual(AccountScrobbling.loginErrorMessage(LastFMError(code: 4, message: " ")).isEmpty, false)
    }

    /// Android's sliders: 15–120 s in fives, 10–100 % in tens, 30–300 s in tens.
    func testTheTimingOptionsStepLikeAndroid() {
        XCTAssertEqual(AccountScrobbling.minDurationStep, 5, accuracy: 0.0001)
        XCTAssertEqual(AccountScrobbling.minDurationRange, 15...120)
        XCTAssertEqual(AccountScrobbling.delayPercentStep, 0.1, accuracy: 0.0001)
        XCTAssertEqual(AccountScrobbling.maxDelayRange, 30...300)
        XCTAssertEqual(AccountScrobbling.maxDelayStep, 10)
        XCTAssertEqual(AccountScrobbling.percentLabel(0.5), "50%")
        XCTAssertEqual(AccountScrobbling.secondsLabel(180), "180s")
    }

    func testTheDiscordRowSaysWhetherPresenceIsShared() {
        let settings = makeAccountTestSettings()
        XCTAssertEqual(AccountScrobbling.discordSubtitle(settings), L10n.tapToConnect)
        settings.discordToken = "t"
        XCTAssertEqual(AccountScrobbling.discordSubtitle(settings), L10n.sharingListens)
        settings.setDiscordAccount(username: "maya", name: "Maya", avatar: nil)
        XCTAssertEqual(AccountScrobbling.discordSubtitle(settings), L10n.sharingAs("maya"))
        settings.discordRpcEnabled = false
        XCTAssertEqual(AccountScrobbling.discordSubtitle(settings), L10n.connectedPresenceOff)
    }

    /// Android: `account?.email?.takeIf { it.isNotBlank() }`, so a blank email reads as none.
    func testTheAccountCardFallsBackWhenTheEmailIsBlank() {
        let named = Account(name: "Maya", email: "maya@example.com", thumbnailUrl: nil)
        XCTAssertEqual(AccountCard.subtitle(signedIn: true, account: named), "maya@example.com")
        let blank = Account(name: "Maya", email: " ", thumbnailUrl: nil)
        XCTAssertEqual(AccountCard.subtitle(signedIn: true, account: blank), L10n.youtubeMusicAccount)
        XCTAssertEqual(AccountCard.subtitle(signedIn: false, account: nil), L10n.tapToSignInGoogle)
    }

    func testTheAccountScreenRendersSignedOutAndWithEveryScrobblerOn() {
        let plain = makeAccountTestApp()
        accountHostAndLayOut(NavigationStack { AccountScreen() }.accountTestEnvironment(plain))

        let settings = makeAccountTestSettings()
        settings.listenBrainzToken = "lb"
        settings.listenBrainzEnabled = true
        AccountScrobbling.didSignInToLastfm(LastFMSessionInfo(username: "maya", sessionKey: "sk"), settings: settings)
        let busy = makeAccountTestApp(settings: settings)
        accountHostAndLayOut(NavigationStack { AccountScreen() }.accountTestEnvironment(busy))
    }

    func testTheScrobblingAlertsRender() {
        let app = makeAccountTestApp()
        accountHostAndLayOut(ListenBrainzTokenAlert(onDismiss: {}).accountTestEnvironment(app))
        accountHostAndLayOut(LastfmLoginAlert(onDismiss: {}, signIn: { _, _ in
            throw LastFMError(code: 4, message: "nope")
        }).accountTestEnvironment(app))
    }
}
