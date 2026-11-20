import VibraMusicCore
import Integrations
import Playback
import SwiftUI
import XCTest
@testable import VibraMusic

/// PORTING §2.9 "Discord Rich Presence": signing in (the web login's token harvest, or a pasted
/// token verified first), the card's settings, and the live preview of what Discord will show.
@MainActor
final class DiscordPresenceScreenTests: XCTestCase {
    private let user = DiscordUserInfo(id: "1", username: "maya", name: "Maya", avatar: "https://cdn.discordapp.com/avatars/1/a.png")

    /// The login screen tears its web view down whenever it disappears, and returning mid-flow must
    /// not leave it stopped.
    func testLeavingAndReturningMidDiscordLoginResumesTheStoppedPage() {
        let controller = DiscordLoginWebController()
        controller.start()

        controller.tearDown()
        XCTAssertTrue(controller.isTornDown)

        controller.resume()
        XCTAssertFalse(controller.isTornDown, "back on screen the page is live again")
        controller.tearDown()
    }

    func testAPastedTokenIsVerifiedBeforeItIsSaved() async {
        let settings = makeAccountTestSettings()
        let rejected = await DiscordTokenCheck.verifyAndSave("bad", settings: settings) { _ in nil }
        XCTAssertFalse(rejected)
        XCTAssertEqual(settings.discordToken, "", "a token Discord refuses is never stored")

        var asked: String?
        let accepted = await DiscordTokenCheck.verifyAndSave("  good-token \n", settings: settings) { token in
            asked = token
            return self.user
        }
        XCTAssertTrue(accepted)
        XCTAssertEqual(asked, "good-token")
        XCTAssertEqual(settings.discordToken, "good-token")
        XCTAssertEqual(settings.discordUsername, "maya")
        XCTAssertEqual(DiscordCard.accountTitle(settings), "Maya")
        XCTAssertEqual(DiscordCard.accountSubtitle(settings), "@maya")
    }

    func testTheWebLoginReadsTheTokenOnlyOnceTheSignInFlowIsLeft() {
        XCTAssertFalse(DiscordLogin.isSignedIn(URL(string: "https://discord.com/login")))
        XCTAssertFalse(DiscordLogin.isSignedIn(URL(string: "https://discord.com/register")))
        XCTAssertFalse(DiscordLogin.isSignedIn(URL(string: "https://example.com/app")))
        XCTAssertTrue(DiscordLogin.isSignedIn(URL(string: "https://discord.com/app")))
        XCTAssertTrue(DiscordLogin.isSignedIn(URL(string: "https://discord.com/channels/@me")))
        XCTAssertNil(DiscordLogin.token(fromScriptResult: ""))
        XCTAssertNil(DiscordLogin.token(fromScriptResult: "undefined"))
        XCTAssertNil(DiscordLogin.token(fromScriptResult: nil))
        XCTAssertEqual(DiscordLogin.token(fromScriptResult: "abc.def"), "abc.def")
        XCTAssertEqual(DiscordLogin.maxTokenAttempts, 12)
    }

    func testTheCardFollowsTheStatusActivityAndButtons() {
        let settings = makeAccountTestSettings()
        XCTAssertEqual(DiscordPresenceStatus(stored: "weird"), .online)
        XCTAssertEqual(DiscordActivityKind(stored: ""), .listening)
        XCTAssertFalse(DiscordCard.showsCustomization(settings), "not connected")
        settings.discordToken = "t"
        settings.discordAdvancedMode = true
        XCTAssertTrue(DiscordCard.showsCustomization(settings))
        settings.discordRpcEnabled = false
        XCTAssertFalse(DiscordCard.presenceOptionsEnabled(settings))

        settings.discordActivityType = "playing"
        settings.discordActivityName = "Night Drive"
        XCTAssertEqual(DiscordCard.heading(settings), "\(L10n.verbPlaying) Night Drive".uppercased())

        let song = Song(videoId: "khnokW3Mw24", title: "Instant Crush", artist: "Daft Punk")
        XCTAssertEqual(DiscordCard.buttonLabel("", fallback: DiscordPresenceClient.defaultButton1, song: nil),
                       DiscordPresenceClient.defaultButton1)
        XCTAssertEqual(DiscordCard.buttonLabel("Hear {title}", fallback: "", song: song),
                       DiscordPresenceClient.resolveVariables("Hear {title}", song: song))
        XCTAssertEqual(DiscordCard.clock(83_900), "1:23")
        XCTAssertEqual(DiscordCard.progress(positionMs: 50, durationMs: 0), 0)
    }

    /// Only premium formats earn the preview's quality line, from what the engine measured.
    func testTheQualityLineComesFromMeasuredStats() {
        let lossless = PlaybackStats(itemID: "x", codec: "flac", sampleRateHz: 96_000, channels: 2, bitDepth: 24)
        XCTAssertEqual(DiscordCard.snapshot(lossless)?.mimeType, "audio/flac")
        XCTAssertNotNil(DiscordCard.audioQualityLine(lossless, enabled: true))
        XCTAssertNil(DiscordCard.audioQualityLine(lossless, enabled: false))
        XCTAssertNil(DiscordCard.audioQualityLine(PlaybackStats(itemID: "y", codec: "aac", sampleRateHz: 44_100), enabled: true))
        XCTAssertNil(DiscordCard.audioQualityLine(nil, enabled: true))
    }

    /// Opening the screen with a connected token refreshes who it belongs to.
    func testTheScreenRefreshesTheConnectedAccount() {
        let settings = makeAccountTestSettings()
        settings.discordToken = "t"
        settings.discordAdvancedMode = true
        let app = makeAccountTestApp(settings: settings)
        let host = accountHostAndLayOut(NavigationStack { DiscordScreen { _ in self.user } }.accountTestEnvironment(app))
        accountWait { settings.discordName == "Maya" }
        XCTAssertEqual(settings.discordName, "Maya")
        XCTAssertEqual(settings.discordAvatar, user.avatar)
        _ = host
    }

    func testTheScreenAndItsAlertsRenderConnectedAndNot() {
        let app = makeAccountTestApp()
        accountHostAndLayOut(NavigationStack { DiscordScreen { _ in nil } }.accountTestEnvironment(app))
        accountHostAndLayOut(DiscordTokenAlert(onDismiss: {}, fetchUser: { _ in nil }).accountTestEnvironment(app))
        accountHostAndLayOut(ChoiceAlert(title: L10n.status, message: L10n.statusDialogMessage,
                                         options: DiscordPresenceStatus.allCases, selected: .idle,
                                         label: \.label, detail: { $0.detail },
                                         onSelect: { _ in }, onDismiss: {}).accountTestEnvironment(app))
        accountHostAndLayOut(TextValueAlert(title: L10n.name, message: "", placeholder: "Vibra Music", initial: "",
                                            onSave: { _ in }, onDismiss: {}).accountTestEnvironment(app))
        accountHostAndLayOut(DiscordLoginScreen(startsLoading: false).accountTestEnvironment(app))
    }
}
