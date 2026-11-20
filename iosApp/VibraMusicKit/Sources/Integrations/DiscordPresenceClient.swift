import VibraMusicCore
import Foundation
import os

/// Options for one presence push, mirroring the `DiscordRPC.updateSong`
/// parameters (and the `AppSettings` discord keys that feed them).
public struct DiscordPresenceOptions: Hashable, Sendable {
    public var useDetails: Bool
    public var status: String
    public var button1Text: String
    public var button1Visible: Bool
    public var button2Text: String
    public var button2Visible: Bool
    public var activityType: String
    public var activityName: String
    public var audioQuality: String?

    public init(
        useDetails: Bool = false,
        status: String = "online",
        button1Text: String = "",
        button1Visible: Bool = true,
        button2Text: String = "",
        button2Visible: Bool = true,
        activityType: String = "listening",
        activityName: String = "",
        audioQuality: String? = nil
    ) {
        self.useDetails = useDetails
        self.status = status
        self.button1Text = button1Text
        self.button1Visible = button1Visible
        self.button2Text = button2Text
        self.button2Visible = button2Visible
        self.activityType = activityType
        self.activityName = activityName
        self.audioQuality = audioQuality
    }
}

/// Publishes what's playing to Discord as a Rich Presence activity (ports
/// `DiscordRPC.kt`).
///
/// This talks to Discord as a *user* over the same gateway its own client
/// uses — there is no official API for a third-party app to set a user's
/// presence, so the token is the account's own bearer token and the socket
/// identifies as Discord's mobile client. That is the only way this feature
/// can exist, and it is why the settings screen warns about it before asking
/// for a login (and why Discord may ban accounts that use it).
///
/// The presence Discord renders from one `updateSong` call:
///
/// ```
///   Listening to Vibra Music          <- activityName, or the app's own name
///   ┌────┐  Song title             <- details
///   │art │  Artist                 <- state
///   └────┘  Hi-Res Lossless · FLAC · 4608 kbps · 24-bit · 96 kHz
///           ▁▁▁▁▁▁ 1:04 / 3:47     <- from the timestamps
///   [ Listen on YouTube Music ]    <- button 1
///   [ Visit Vibra Music           ]   <- button 2
/// ```
public final class DiscordPresenceClient: Sendable {
    /// The Discord application this presence is attributed to. Needed for the
    /// endpoint that mirrors artwork onto Discord's CDN and for buttons, which
    /// Discord drops from an activity with no application id. Register an
    /// application at https://discord.com/developers/applications and swap in
    /// its id to attribute artwork and buttons under your own app.
    public static let applicationId = "1411019391843172514"
    public static let projectURL = "https://github.com/kushagrasinghx/Vibra Music"
    public static let defaultButton1 = "Listen on YouTube Music"
    public static let defaultButton2 = "Visit Vibra Music"
    /// Discord draws the sleeve at roughly 96dp; 480px covers it on any density.
    public static let artworkPixels = 480
    /// Sleeve for tracks with no usable artwork. Must be fetchable by
    /// Discord's mirroring endpoint, so it points at the launcher icon in the
    /// repo rather than an asset bundled in the app.
    public static let fallbackArtworkURL =
        "https://raw.githubusercontent.com/kushagrasinghx/Vibra Music/main/app/src/main/ic_launcher-playstore.png"

    public let token: String
    public let appName: String
    private let socket: DiscordGatewaySocket
    let session: URLSession
    private let artworkCache = DiscordArtworkCache()
    private let logger = Logger(subsystem: "com.fortune.vibramusic.ios", category: "Integrations")

    public init(
        token: String,
        appName: String = "Vibra Music",
        session: URLSession = VibraMusicHTTP.session,
        socket: DiscordGatewaySocket? = nil
    ) {
        self.token = token
        self.appName = appName
        self.session = session
        self.socket = socket ?? DiscordGatewaySocket(token: token)
    }

    public func isConnected() async -> Bool {
        await socket.isConnected()
    }

    /// Whether Discord refused the token. Nothing is retried once it has; the user has to sign in again.
    public func isTokenRejected() async -> Bool {
        await socket.isAuthenticationRejected()
    }

    /// Tells the gateway conditions changed and it is worth trying again now
    /// (typically: the network came back).
    public func wakeUp() async {
        await socket.connect()
        await socket.retryNow()
    }

    /// Clears the card by publishing a presence with no activities.
    public func clear() async {
        await socket.clearActivity()
    }

    public func close() async {
        await socket.close()
    }

    /// Pushes `song` to Discord as the current activity.
    ///
    /// `currentPositionMs` and `durationMs` become a start/end timestamp pair
    /// rather than a progress value, because Discord counts the bar down on
    /// its own clock from those two instants. A presence set once therefore
    /// stays correct for the rest of the track; another is only sent when
    /// something about the track *changed* — which is also why
    /// `playbackSpeed` is divided out of both: at 1.5x the wall-clock time
    /// left is not the media time left.
    public func updateSong(
        _ song: Song,
        currentPositionMs: Int64,
        durationMs: Int64,
        playbackSpeed: Double = 1.0,
        options: DiscordPresenceOptions = DiscordPresenceOptions(),
        at now: Date = Date()
    ) async {
        let presence = await makePresence(
            song, currentPositionMs: currentPositionMs, durationMs: durationMs,
            playbackSpeed: playbackSpeed, options: options, at: now
        )
        await socket.connect()
        await socket.retryNow()
        await socket.sendActivity(presence)
    }

    // MARK: - Presence building (public for tests)

    public func makePresence(
        _ song: Song,
        currentPositionMs: Int64,
        durationMs: Int64,
        playbackSpeed: Double = 1.0,
        options: DiscordPresenceOptions = DiscordPresenceOptions(),
        at now: Date = Date()
    ) async -> DiscordPresence {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let speed = playbackSpeed > 0 ? playbackSpeed : 1.0
        let adjustedPosition = Int64(Double(currentPositionMs) / speed)
        let startTime = nowMs - adjustedPosition
        let remaining = max(durationMs - currentPositionMs, 0)
        let endTime = nowMs + Int64(Double(remaining) / speed)

        let title: String
        if speed != 1.0 {
            title = "\(song.title) [\(String(format: "%.2fx", speed))]"
        } else {
            title = song.title
        }

        var buttons: [(label: String, url: String)] = []
        if options.button1Visible {
            buttons.append((
                label: Self.resolveVariables(options.button1Text.isEmpty ? Self.defaultButton1 : options.button1Text, song: song),
                url: Self.watchURL(for: song)
            ))
        }
        if options.button2Visible {
            buttons.append((
                label: Self.resolveVariables(options.button2Text.isEmpty ? Self.defaultButton2 : options.button2Text, song: song),
                url: Self.projectURL
            ))
        }

        let artworkURL = song.artworkURL(at: Self.artworkPixels)?.absoluteString
        let external = artworkURL.flatMap { $0.hasPrefix("http") ? $0 : nil } ?? Self.fallbackArtworkURL
        let largeImage = await DiscordRpcImage.external(external).resolve(
            cache: artworkCache,
            resolveExternal: { [session] image in
                await fetchDiscordExternalAsset(
                    session: session,
                    applicationId: Self.applicationId,
                    token: self.token,
                    imageUrl: image,
                    userAgent: DiscordSuperProperties.userAgent,
                    superPropertiesBase64: DiscordSuperProperties.base64()
                )
            }
        )

        let type = DiscordActivityType(name: options.activityType)
        let name = options.activityName.isEmpty ? appName : options.activityName
        return DiscordPresence(
            activities: [
                DiscordActivity(
                    name: name,
                    state: song.artist,
                    details: title,
                    detailsUrl: Self.watchURL(for: song),
                    type: type.rawValue,
                    statusDisplayType: (options.useDetails ? DiscordStatusDisplayType.details : DiscordStatusDisplayType.state).rawValue,
                    timestamps: DiscordTimestamps(start: startTime, end: endTime),
                    assets: DiscordAssets(
                        largeImage: largeImage,
                        largeText: options.audioQuality
                    ),
                    buttons: buttons.isEmpty ? nil : buttons.map { $0.label },
                    metadata: DiscordActivityMetadata(buttonUrls: buttons.isEmpty ? nil : buttons.map { $0.url }),
                    applicationId: buttons.isEmpty ? nil : Self.applicationId
                ),
            ],
            afk: true,
            since: nowMs,
            status: options.status
        )
    }

    public static func watchURL(for song: Song) -> String {
        "https://music.youtube.com/watch?v=\(song.videoId)"
    }

    /// Resolves `{song_name}`, `{artist_name}`, `{album_name}` template
    /// variables in button text.
    public static func resolveVariables(_ text: String, song: Song) -> String {
        text.replacingOccurrences(of: "{song_name}", with: song.title)
            .replacingOccurrences(of: "{artist_name}", with: song.artist)
            .replacingOccurrences(of: "{album_name}", with: song.albumName ?? "")
    }
}
