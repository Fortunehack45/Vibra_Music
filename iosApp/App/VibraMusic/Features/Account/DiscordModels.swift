import VibraMusicCore
import Foundation
import Integrations
import Playback

// The value types and rules behind ui/screens/DiscordScreen.kt: which dot and which verb the card
// carries, and how the live preview reads the playing track.

/// Which dot Discord draws on the avatar, and what it tells other people.
enum DiscordPresenceStatus: String, CaseIterable, Identifiable {
    case online
    case idle
    case dnd

    var id: String { rawValue }

    /// The stored value, or Online for anything unrecognised (Android `statusOf`).
    init(stored: String) { self = DiscordPresenceStatus(rawValue: stored) ?? .online }

    var label: String {
        switch self {
        case .online: return L10n.statusOnline
        case .idle: return L10n.statusIdle
        case .dnd: return L10n.statusDnd
        }
    }

    var detail: String {
        switch self {
        case .online: return L10n.statusOnlineDetail
        case .idle: return L10n.statusIdleDetail
        case .dnd: return L10n.statusDndDetail
        }
    }
}

/// The verb on the profile. All four render the same card; only the line above it changes.
enum DiscordActivityKind: String, CaseIterable, Identifiable {
    case listening
    case playing
    case watching
    case competing

    var id: String { rawValue }

    /// The stored value, or Listening for anything unrecognised (Android `kindOf`).
    init(stored: String) { self = DiscordActivityKind(rawValue: stored) ?? .listening }

    var label: String {
        switch self {
        case .listening: return L10n.activityListening
        case .playing: return L10n.activityPlaying
        case .watching: return L10n.activityWatching
        case .competing: return L10n.activityCompeting
        }
    }

    var verb: String {
        switch self {
        case .listening: return L10n.verbListening
        case .playing: return L10n.verbPlaying
        case .watching: return L10n.verbWatching
        case .competing: return L10n.verbCompeting
        }
    }
}

/// What the Discord screen shows, from settings and the playing track.
@MainActor
enum DiscordCard {
    /// The app's own name, minus a development build's suffix (Android `appName()`; DiscordRPC uses
    /// the same).
    static var appName: String {
        let name = L10n.appName
        return name.hasSuffix(" Dev") ? String(name.dropLast(4)) : name
    }

    static func connected(_ settings: AppSettings) -> Bool { !settings.discordToken.isEmpty }

    /// The presence rows under "Rich presence" are live only while connected (and, below the
    /// master switch, while it is on).
    static func presenceOptionsEnabled(_ settings: AppSettings) -> Bool {
        connected(settings) && settings.discordRpcEnabled
    }

    /// The Presence and Buttons groups show while connected, on, and "Customize the card" is on.
    static func showsCustomization(_ settings: AppSettings) -> Bool {
        presenceOptionsEnabled(settings) && settings.discordAdvancedMode
    }

    /// The account card's two lines.
    static func accountTitle(_ settings: AppSettings) -> String {
        guard connected(settings) else { return L10n.notConnected }
        return settings.discordName.isEmpty ? L10n.connected : settings.discordName
    }

    static func accountSubtitle(_ settings: AppSettings) -> String {
        if !settings.discordUsername.isEmpty { return "@\(settings.discordUsername)" }
        return connected(settings) ? L10n.discordAccount : L10n.tapToSignInDiscord
    }

    /// The preview's small caps heading: "LISTENING TO VIBRA MUSIC".
    static func heading(_ settings: AppSettings) -> String {
        let name = settings.discordActivityName.isEmpty ? appName : settings.discordActivityName
        let verb = DiscordActivityKind(stored: settings.discordActivityType).verb
        return "\(verb) \(name)".uppercased(with: Locale(identifier: "en_US_POSIX"))
    }

    /// A button's label as Discord will show it: the chosen text or the default, with `{title}`-style
    /// variables filled from the playing track.
    static func buttonLabel(_ text: String, fallback: String, song: Song?) -> String {
        let chosen = text.isEmpty ? fallback : text
        guard let song else { return chosen }
        return DiscordPresenceClient.resolveVariables(chosen, song: song)
    }

    /// The quality line, from what the engine measured — only premium formats earn one.
    static func audioQualityLine(_ stats: PlaybackStats?, enabled: Bool) -> String? {
        guard enabled else { return nil }
        return discordAudioQualityLine(snapshot(stats))
    }

    /// The engine's measured figures in the shape the Discord module reads.
    static func snapshot(_ stats: PlaybackStats?) -> DiscordAudioSnapshot? {
        guard let stats else { return nil }
        let codec = stats.codec?.lowercased()
        let mime: String?
        switch codec {
        case nil: mime = nil
        case "ec-3", "eac3", "ec+3":
            mime = stats.declared?.isDolbyAtmos == true ? "audio/eac3-joc" : "audio/eac3"
        case "lpcm": mime = "audio/raw"
        case let other?: mime = "audio/\(other)"
        }
        return DiscordAudioSnapshot(
            mimeType: mime,
            bitrateKbps: stats.indicatedBitrateKbps ?? stats.estimatedBitrateKbps,
            sampleRateHz: stats.sampleRateHz,
            channels: stats.channels,
            bitDepth: stats.bitDepth
        )
    }

    /// `m:ss`, as Discord's own bar prints it.
    static func clock(_ milliseconds: Int64) -> String {
        let total = max(0, milliseconds / 1000)
        return String(format: "%d:%02d", locale: Locale(identifier: "en_US_POSIX"), total / 60, total % 60)
    }

    static func progress(positionMs: Int64, durationMs: Int64) -> Double {
        guard durationMs > 0 else { return 0 }
        return min(max(Double(positionMs) / Double(durationMs), 0), 1)
    }
}

/// When the in-app Discord login has left the sign-in flow — the moment the token is in
/// `localStorage` and worth reading (auth/DiscordLoginScreen.kt `isSignedIn`). Deliberately not a
/// match on one path: a completed login lands on `/app` or `/channels/@me` depending on how the
/// session was established.
enum DiscordLogin {
    static let loginURL = URL(string: "https://discord.com/login")!

    /// Twelve reads at half-second intervals cover a slow client boot without spinning forever on
    /// an account that never signed in.
    static let maxTokenAttempts = 12
    static let tokenRetry: Duration = .milliseconds(500)

    static func isSignedIn(_ url: URL?) -> Bool {
        guard let text = url?.absoluteString else { return false }
        return text.hasPrefix("https://discord.com/") && !text.contains("/login") && !text.contains("/register")
    }

    /// Reads the token out of a completed login by dropping an iframe into the page and reading
    /// `localStorage.token` from it. Discord takes `localStorage` away from the top-level window once
    /// the app boots, specifically so a snippet like this can't read it; a fresh same-origin iframe
    /// gets an untouched handle on the same store. It answers `''` rather than throwing on a miss,
    /// because the caller retries. (Android had to send the answer through `alert`; WebKit returns it.)
    static let tokenScript = """
    (function () {
      try {
        var frame = document.createElement('iframe');
        document.body.appendChild(frame);
        var token = frame.contentWindow.localStorage.token;
        document.body.removeChild(frame);
        return token ? token.slice(1, -1) : '';
      } catch (e) {
        return '';
      }
    })()
    """

    /// The token in a script result, or nil for "not written yet".
    static func token(fromScriptResult result: Any?) -> String? {
        guard let text = result as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "null" || trimmed == "undefined" { return nil }
        return trimmed
    }
}
