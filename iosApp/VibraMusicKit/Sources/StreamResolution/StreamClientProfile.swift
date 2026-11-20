import Foundation

/// One identity the resolver can ask YouTube's `player` endpoint as, and everything the request
/// and the later media fetch have to say to be that identity.
///
/// Android got its catalog from InnerTubeX (a Kotlin library with no Swift version) and fell
/// back to NewPipe's extractor; this is the part of both this app needs, written down as data.
/// The catalog is walked in order and each entry answers on its own, so reordering it or adding
/// a profile is a data change, not a code change.
public struct StreamClientProfile: Sendable, Hashable, Identifiable {
    /// Catalog id; what exclusions and the walk's skip set key on.
    public let id: String
    public let clientName: String
    public let clientVersion: String
    /// The numeric `X-YouTube-Client-Name`.
    public let clientNameId: String
    public let userAgent: String
    /// Host the `player` request goes to.
    public let endpointHost: String
    /// Browser-shaped clients send an Origin/Referer; app clients must not.
    public let origin: String?
    public let clientScreen: String?
    public let platform: String?
    public let deviceMake: String?
    public let deviceModel: String?
    public let osName: String?
    public let osVersion: String?
    public let androidSdkVersion: Int?
    /// Sent on the `player` request only (never on media fetches).
    public let extraHeaders: [String: String]
    /// Without a visitor id this client is answered `LOGIN_REQUIRED` (measured for ANDROID_VR).
    public let requiresVisitorData: Bool
    /// Browser/TV identities prove they run the current player by quoting its
    /// `signatureTimestamp`; without it Google answers `UNPLAYABLE` "The page needs to be
    /// reloaded". Their formats come back as `signatureCipher` + `n`, so they also need the
    /// cipher tier (`StreamCipherSolver`).
    public let usesPlayerScript: Bool
    /// Whether the signed-in session is sent. Device clients are deliberately sent none: Google
    /// refuses them a session they could not have, so auth goes only to web identities.
    public let sendsAuth: Bool
    /// Whether a BotGuard PoToken is attached when a `StreamPoTokenProvider` is available.
    public let usesPoToken: Bool
    /// The embedded player (WEB_EMBEDDED_PLAYER): its `player` request needs the embed page's own
    /// config (visitor id, encrypted embed context, host flags) and a third-party embed URL.
    public let embedsPage: Bool

    public init(
        id: String, clientName: String, clientVersion: String, clientNameId: String, userAgent: String,
        endpointHost: String, origin: String? = nil, clientScreen: String? = nil, platform: String? = nil,
        deviceMake: String? = nil, deviceModel: String? = nil, osName: String? = nil, osVersion: String? = nil,
        androidSdkVersion: Int? = nil, extraHeaders: [String: String] = [:], requiresVisitorData: Bool = false,
        usesPlayerScript: Bool = false, sendsAuth: Bool = false, usesPoToken: Bool = false, embedsPage: Bool = false
    ) {
        self.id = id
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.clientNameId = clientNameId
        self.userAgent = userAgent
        self.endpointHost = endpointHost
        self.origin = origin
        self.clientScreen = clientScreen
        self.platform = platform
        self.deviceMake = deviceMake
        self.deviceModel = deviceModel
        self.osName = osName
        self.osVersion = osVersion
        self.androidSdkVersion = androidSdkVersion
        self.extraHeaders = extraHeaders
        self.requiresVisitorData = requiresVisitorData
        self.usesPlayerScript = usesPlayerScript
        self.sendsAuth = sendsAuth
        self.usesPoToken = usesPoToken
        self.embedsPage = embedsPage
    }

    /// Headers the media fetch for a URL this profile minted must carry.
    public var mediaHeaders: [String: String] {
        StreamPlayerClient(clientName: clientName, clientVersion: clientVersion, userAgent: userAgent, origin: origin)
            .mediaHeaders
    }

    // MARK: Catalog

    /// NewPipe's visionOS client, asked the way NewPipe asks it (youtubei.googleapis.com with the
    /// `t`/`id` parameters and `X-Goog-Api-Format-Version: 2`).
    ///
    /// First in the catalog because it is what works today. Measured 2026-09-26 against 15
    /// tracks from a live YouTube Music search: direct `url` formats (139/140/249/250/251), no
    /// `n`, no PoToken, and the whole file readable — a range at the last 100 KB answers 206.
    public static let visionOS = StreamClientProfile(
        id: "visionos",
        clientName: "VISIONOS",
        clientVersion: "1.02",
        clientNameId: "101",
        userAgent: StreamPlayerClient.visionOSUserAgent,
        endpointHost: "youtubei.googleapis.com",
        clientScreen: "WATCH",
        platform: "MOBILE",
        deviceMake: "Apple",
        deviceModel: "RealityDevice14,1",
        osName: "visionOS",
        osVersion: "25.6.0.23O471",
        extraHeaders: ["X-Goog-Api-Format-Version": "2"]
    )

    /// The Quest's YouTube app. Answers with direct URLs, but only with a visitor id.
    ///
    /// Second, not first. Measured 2026-09-26: its URLs serve roughly the first minute of audio
    /// (140: ~1,071,265 bytes, 251: ~980,726, 139: ~466,061 — ~60–76 s whatever the bitrate)
    /// and then 403 every range past it. A token range at the start passes; listening dies a
    /// minute in. The probe's past-the-first-megabyte range is what catches it, and the walk
    /// moves on. Kept because this is the kind of verdict Google reverses without notice.
    public static let androidVR = StreamClientProfile(
        id: "android_vr",
        clientName: "ANDROID_VR",
        clientVersion: "1.65.10",
        clientNameId: "28",
        userAgent: StreamPlayerClient.androidVR.userAgent,
        endpointHost: "www.youtube.com",
        deviceMake: "Oculus",
        deviceModel: "Quest 3",
        osName: "Android",
        osVersion: "12L",
        androidSdkVersion: 32,
        requiresVisitorData: true
    )

    /// YouTube Music's own web client — the cipher tier. `signatureCipher` + `n` formats, so it
    /// needs the player script. The only identity here that takes the signed-in session, which
    /// is what an age-gated track needs.
    public static let webRemix = StreamClientProfile(
        id: "web_remix",
        clientName: "WEB_REMIX",
        clientVersion: "1.20260922.09.00",
        clientNameId: "67",
        userAgent: StreamPlayerClient.webUserAgent,
        endpointHost: "music.youtube.com",
        origin: StreamPlayerClient.musicOrigin,
        usesPlayerScript: true,
        sendsAuth: true,
        usesPoToken: true
    )

    /// The TV "simply" client — cipher tier, no PoToken, no auth.
    public static let tvSimply = StreamClientProfile(
        id: "tv_simply",
        clientName: "TVHTML5_SIMPLY",
        clientVersion: "1.0",
        clientNameId: "75",
        userAgent: "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version",
        endpointHost: "www.youtube.com",
        origin: StreamPlayerClient.youtubeOrigin,
        usesPlayerScript: true
    )

    /// Mobile web — cipher tier; the last resort.
    public static let mweb = StreamClientProfile(
        id: "mweb",
        clientName: "MWEB",
        clientVersion: "2.20260922.00.00",
        clientNameId: "2",
        userAgent: "Mozilla/5.0 (iPad; CPU OS 16_7_10 like Mac OS X) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1,gzip(gfe)",
        endpointHost: "www.youtube.com",
        origin: "https://m.youtube.com",
        usesPlayerScript: true,
        sendsAuth: true,
        usesPoToken: true
    )

    /// The iPhone app. Not in the default walk: measured 2026-09-26 it answers `OK` with only a
    /// SABR (`serverAbrStreamingUrl`) session and no usable `url` on any format, which neither
    /// AVPlayer nor this resolver speaks. Kept so a caller can put it back when that changes.
    public static let ios = StreamClientProfile(
        id: "ios",
        clientName: "IOS",
        clientVersion: "21.29.1",
        clientNameId: "5",
        userAgent: StreamPlayerClient.iosRecent.userAgent,
        endpointHost: "www.youtube.com",
        deviceMake: "Apple",
        deviceModel: "iPhone16,2",
        osName: "iPhone",
        osVersion: "18.5.0.22F76",
        requiresVisitorData: true
    )

    /// The embedded web player — cipher tier, but no PoToken. Measured 2026-09-26: for YouTube
    /// Music songs (art tracks) every other identity here wants a GVS PoToken googlevideo enforces
    /// (android_vr, tv_simply, mweb and web_remix all answered 403), while the embedded
    /// player's URLs serve the whole file, as yt-dlp's `web_embedded` does. Its request is built
    /// from the embed page's ytcfg (see `InnerTubeStreamExtractor.embedConfig`). Videos whose owner
    /// disabled embedding answer UNPLAYABLE and the walk moves on.
    public static let webEmbedded = StreamClientProfile(
        id: "web_embedded",
        clientName: "WEB_EMBEDDED_PLAYER",
        clientVersion: "2.20260925.01.00",
        clientNameId: "56",
        userAgent: StreamPlayerClient.webUserAgent,
        endpointHost: "www.youtube.com",
        origin: StreamPlayerClient.youtubeOrigin,
        usesPlayerScript: true,
        embedsPage: true
    )

    /// The default walk: direct-URL clients first, then the cipher tier.
    public static let defaultCatalog: [StreamClientProfile] = [.visionOS, .webEmbedded, .androidVR, .webRemix, .tvSimply, .mweb]
}
