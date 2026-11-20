import Foundation

/// The identity a googlevideo URL says minted it, as far as its media fetch has to repeat it.
/// Port of `PlayerClient.kt`.
///
/// googlevideo bakes the client into the URL as `c=`/`cver=` and compares it against the headers
/// of the request that comes back for the bytes, so the fetch has to be dressed as that client.
/// URLs this module mints carry their own exact headers (`StreamResolver.mediaHeaders(for:)`);
/// this covers everything else — a URL restored from disk, or one minted before a relaunch.
public struct StreamPlayerClient: Sendable, Hashable {
    public let clientName: String
    public let clientVersion: String
    public let userAgent: String
    /// The host this client runs on, for browser-shaped clients only. Native app clients send
    /// none, and sending one anyway is as wrong as omitting it from a web client.
    public let origin: String?

    public init(clientName: String, clientVersion: String, userAgent: String, origin: String? = nil) {
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.userAgent = userAgent
        self.origin = origin
    }

    public var referer: String? { origin.map { "\($0)/" } }

    /// Headers the *media* request must carry for a URL this client minted.
    ///
    /// googlevideo treats a mismatch between the request that produced the URL and the one
    /// fetching it as reason enough to throttle the response to a crawl or refuse it with 403.
    public var mediaHeaders: [String: String] {
        var headers = ["User-Agent": userAgent]
        if let origin { headers["Origin"] = origin }
        if let referer { headers["Referer"] = referer }
        return headers
    }

    static let musicOrigin = "https://music.youtube.com"
    static let youtubeOrigin = "https://www.youtube.com"

    static let webUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"

    static let ios = StreamPlayerClient(
        clientName: "IOS",
        clientVersion: "21.26.4",
        userAgent: "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"
    )

    static let iosRecent = StreamPlayerClient(
        clientName: "IOS",
        clientVersion: "21.29.1",
        userAgent: "com.google.ios.youtube/21.29.1 (iPhone16,2; U; CPU iOS 18_5 like Mac OS X;)"
    )

    static let android = StreamPlayerClient(
        clientName: "ANDROID",
        clientVersion: "21.26.364",
        userAgent: "com.google.android.youtube/21.26.364 "
            + "(Linux; U; Android 15; en_US; Pixel 9 Pro; Build/AP4A.250205.002; Cronet/132.0.6834.79) gzip"
    )

    static let androidMusic = StreamPlayerClient(
        clientName: "ANDROID_MUSIC",
        clientVersion: "8.39.42",
        userAgent: "com.google.android.apps.youtube.music/8.39.42 "
            + "(Linux; U; Android 15; en_US; Pixel 9 Pro; Build/AP4A.250205.002) gzip"
    )

    static let androidVR = StreamPlayerClient(
        clientName: "ANDROID_VR",
        clientVersion: "1.65.10",
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 "
            + "(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"
    )

    static let androidVRLegacy = StreamPlayerClient(
        clientName: "ANDROID_VR",
        clientVersion: "1.43.32",
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.43.32 "
            + "(Linux; U; Android 12; en_US; Quest 3; Build/SQ3A.220605.009.A1; Cronet/107.0.5284.2)"
    )

    static let webRemix = StreamPlayerClient(
        clientName: "WEB_REMIX",
        clientVersion: "1.20260707.12.00",
        userAgent: webUserAgent,
        origin: musicOrigin
    )

    static let web = StreamPlayerClient(
        clientName: "WEB",
        clientVersion: "2.20260708.00.00",
        userAgent: webUserAgent,
        origin: youtubeOrigin
    )

    static let tvhtml5 = StreamPlayerClient(
        clientName: "TVHTML5",
        clientVersion: "7.20260707.07.00",
        userAgent: "Mozilla/5.0(SMART-TV; Linux; Tizen 4.0.0.2) AppleWebkit/605.1.15 "
            + "(KHTML, like Gecko) SamsungBrowser/9.2 TV Safari/605.1.15",
        origin: youtubeOrigin
    )

    /// visionOS's user agent, as NewPipe builds it (`YoutubeParsingHelper.getVisionOsUserAgent`).
    /// On Android the agent was read from NewPipe so the two could not drift; here it is shared
    /// with the request-side profile (`StreamClientProfile.visionOS`) for the same reason.
    static let visionOSUserAgent =
        "com.google.visionos.youtube/1.02(RealityDevice14,1; U; CPU visionOS 25_6_0 like Mac OS X; US)"

    static func visionOS(version: String?) -> StreamPlayerClient {
        StreamPlayerClient(clientName: "VISIONOS", clientVersion: version ?? "1.02", userAgent: visionOSUserAgent)
    }

    /// The client a googlevideo URL says minted it, so the media fetch can be dressed as that
    /// client whatever produced the URL.
    ///
    /// Falls back to IOS when the URL names a client we don't model: being approximately right
    /// beats sending a smart TV's headers for a URL an iPhone asked for.
    public static func forStreamURL(_ url: URL) -> StreamPlayerClient {
        guard url.scheme == "http" || url.scheme == "https", url.host != nil,
              let name = url.streamQueryValue("c")?.uppercased()
        else { return ios }
        let version = url.streamQueryValue("cver")
        if name.hasPrefix("IOS") { return version == iosRecent.clientVersion ? iosRecent : ios }
        if name == "ANDROID_VR" { return version == androidVRLegacy.clientVersion ? androidVRLegacy : androidVR }
        if name == "ANDROID_MUSIC" { return androidMusic }
        if name.hasPrefix("ANDROID") { return android }
        if name.hasPrefix("TVHTML5") { return tvhtml5 }
        if name == "WEB_REMIX" { return webRemix }
        if name.hasPrefix("WEB") || name == "MWEB" { return web }
        if name == "VISIONOS" { return visionOS(version: version) }
        return ios
    }

    /// String convenience for `forStreamURL(_:)`; an unparseable string gets the IOS fallback.
    public static func forStreamURL(_ string: String) -> StreamPlayerClient {
        URL(string: string).map(forStreamURL) ?? ios
    }

    /// Largest single range googlevideo reliably serves for `url`'s client; mirrors InnerTubeX's
    /// `mediaRangeChunkSize`. Non-googlevideo URLs are not capped.
    public static func rangeBytes(for url: URL) -> Int64 {
        guard url.isGoogleVideo else { return Int64.max }
        let name = url.streamQueryValue("c")?.uppercased()
        if name == "ANDROID_VR" || name?.hasPrefix("TVHTML5_SIMPLY") == true { return narrowRangeBytes }
        return wideRangeBytes
    }

    /// String convenience for `rangeBytes(for:)`; anything that is not a URL is not capped.
    public static func rangeBytes(for string: String) -> Int64 {
        URL(string: string).map { rangeBytes(for: $0) } ?? Int64.max
    }

    static let wideRangeBytes: Int64 = 1024 * 1024
    static let narrowRangeBytes: Int64 = 512 * 1024
}
