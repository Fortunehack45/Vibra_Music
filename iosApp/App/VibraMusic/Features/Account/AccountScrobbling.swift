import VibraMusicCore
import Foundation
import Integrations

/// The decisions behind AccountAndScrobblingScreen.kt's rows, apart from the view so they can be
/// tested: what each row says, what its switch does, and what signing in or out of Last.fm writes.
@MainActor
enum AccountScrobbling {
    /// What the ListenBrainz switch does when flipped: enabling it without a token opens the token
    /// alert instead of turning on a scrobbler that can't send anything.
    enum SwitchOutcome: Equatable {
        case set(Bool)
        case openLogin
    }

    static func listenBrainzSwitch(to checked: Bool, settings: AppSettings) -> SwitchOutcome {
        checked && settings.listenBrainzToken.isBlankText ? .openLogin : .set(checked)
    }

    /// Same rule for Last.fm: no session key means the sign-in alert.
    static func lastfmSwitch(to checked: Bool, settings: AppSettings) -> SwitchOutcome {
        checked && settings.lastfmSessionKey.isBlankText ? .openLogin : .set(checked)
    }

    static func listenBrainzConnected(_ settings: AppSettings) -> Bool {
        settings.listenBrainzEnabled && !settings.listenBrainzToken.isBlankText
    }

    static func lastfmSignedIn(_ settings: AppSettings) -> Bool {
        !settings.lastfmSessionKey.isBlankText
    }

    /// Last.fm's sub-rows and the timing group show only while it is on and signed in.
    static func lastfmActive(_ settings: AppSettings) -> Bool {
        settings.lastfmEnabled && lastfmSignedIn(settings)
    }

    static func listenBrainzSubtitle(_ settings: AppSettings) -> String {
        listenBrainzConnected(settings) ? L10n.connected : L10n.enterTokenToEnable
    }

    static func lastfmSubtitle(_ settings: AppSettings) -> String {
        lastfmSignedIn(settings) ? L10n.signedInAs(settings.lastfmUsername) : L10n.tapToSignIn
    }

    /// The Discord row's subtitle under "Rich presence".
    static func discordSubtitle(_ settings: AppSettings) -> String {
        if settings.discordToken.isEmpty { return L10n.tapToConnect }
        if !settings.discordRpcEnabled { return L10n.connectedPresenceOff }
        if !settings.discordUsername.isEmpty { return L10n.sharingAs(settings.discordUsername) }
        return L10n.sharingListens
    }

    /// Tapping the Last.fm row: signed in, it signs out (everything Last.fm is cleared and switched
    /// off); signed out, it asks for the login. Returns whether the login should open.
    static func tapLastfmRow(settings: AppSettings) -> Bool {
        guard lastfmSignedIn(settings) else { return true }
        settings.lastfmSessionKey = ""
        settings.lastfmUsername = ""
        settings.lastfmEnabled = false
        settings.lastfmScrobbleEnabled = false
        settings.lastfmNowPlaying = false
        return false
    }

    /// A successful Last.fm login: the session is stored and scrobbling to it is switched on.
    static func didSignInToLastfm(_ session: LastFMSessionInfo, settings: AppSettings) {
        settings.lastfmSessionKey = session.sessionKey
        settings.lastfmUsername = session.username
        settings.lastfmEnabled = true
    }

    /// What a failed login says: Last.fm's own message, else the error's, else "Login failed".
    static func loginErrorMessage(_ error: Error) -> String {
        if let lastfm = error as? LastFMError, !lastfm.message.isBlankText { return lastfm.message }
        let described = (error as NSError).localizedDescription
        return described.isBlankText ? L10n.loginFailed : described
    }

    /// The live Last.fm sign-in: the client is initialised with the configured key and secret (the
    /// app's bundled pair unless the user set their own) and asked for a mobile session.
    static func liveLastfmSignIn(settings: AppSettings) -> (String, String) async throws -> LastFMSessionInfo {
        let configuration = LastFMConfiguration.resolved(settings: settings)
        return { username, password in
            let client = LastFMClient(configuration: configuration, session: VibraMusicHTTP.session)
            return try await client.fetchMobileSession(username: username, password: password)
        }
    }

    // MARK: Timing sliders (Android SliderRow ranges and steps)

    /// Minimum song duration: 15–120 s. Android's 20 steps split the range into 21 intervals.
    static let minDurationRange: ClosedRange<Double> = 15...120
    static let minDurationStep: Double = (120 - 15) / 21
    /// Scrobble at this share of the track: 10–100 %, in tens.
    static let delayPercentRange: ClosedRange<Double> = 0.1...1.0
    static let delayPercentStep: Double = 0.1
    /// …or after this many seconds: 30–300 s, in tens.
    static let maxDelayRange: ClosedRange<Double> = 30...300
    static let maxDelayStep: Double = 10

    static func percentLabel(_ fraction: Float) -> String { "\(Int((fraction * 100).rounded()))%" }
    static func secondsLabel(_ seconds: Int) -> String { "\(seconds)s" }
}

extension String {
    /// Empty or only whitespace (Kotlin's `isBlank`).
    fileprivate var isBlankText: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
