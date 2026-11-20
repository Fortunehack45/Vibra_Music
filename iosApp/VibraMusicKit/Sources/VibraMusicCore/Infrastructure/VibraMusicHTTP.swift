import Foundation

// Ports data/Http.kt: one HTTP stack for the whole app.

/// The app's shared `URLSession` configuration and the User-Agent strings the services expect.
///
/// Every module takes a `URLSession` in its initializer (so tests can inject
/// `URLProtocolStub`); the app passes ``session``.
///
/// On Android sharing one client also kept googlevideo happy, because it binds a stream URL to the
/// connection context of the `player` request that minted it (v4 vs v6). AVPlayer uses its own HTTP
/// stack and can't share this session, so StreamResolution has to live with that (for example by
/// preferring the IOS client, whose URLs aren't bound that way, or a resource loader).
public enum VibraMusicHTTP {
    /// Idle time allowed between bytes before a request fails (OkHttp's read timeout was 30 s,
    /// its connect timeout 20 s; URLSession has one knob for both).
    public static let requestTimeout: TimeInterval = 30

    /// Parallel connections to one host. OkHttp's stock 5 queued a resolve behind a playing
    /// track's chunk downloads, invisibly — a request stuck in a queue and a slow server look the
    /// same. Sized well past anything this app drives at once.
    public static let maxConnectionsPerHost = 16

    /// The configuration every app session should start from.
    ///
    /// Cookies are neither stored nor sent automatically: Android's client had no cookie jar, and
    /// InnerTube sets the account's `Cookie` header itself per request. An automatic jar would let
    /// Set-Cookie responses from one profile leak into another's requests. No URL cache either:
    /// API responses are not reusable, and artwork has its own cache.
    public static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.httpMaximumConnectionsPerHost = maxConnectionsPerHost
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return configuration
    }

    /// The app's shared session, built from ``makeConfiguration()``.
    public static let session = URLSession(configuration: makeConfiguration())

    /// User-Agent strings. Several services 403 an unknown agent, and some bind their answers to it.
    public enum UserAgent {
        /// Desktop Chrome, as Innertube's WEB/WEB_REMIX clients, NewPipe-style extraction and
        /// JioSaavn expect.
        public static let chromeDesktop =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"

        /// The plain app name, which Genius is sent.
        public static let app = "Vibra Music"

        /// What add-ons are sent: the string Android 1.8 sends (`Vibra Music/v` + its version name),
        /// so an add-on that accepts the Android app accepts this one with no change to its
        /// allow-list. Not this app's own version on purpose.
        public static let addon = "Vibra Music/v1.8"

        /// `Vibra Music/<version>` for services that ask callers to identify themselves (MusicBrainz,
        /// ListenBrainz). `version` defaults to the main bundle's short version.
        public static func versioned(_ version: String? = nil) -> String {
            let resolved = version
                ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            guard let resolved, !resolved.isEmpty else { return app }
            return "\(app)/\(resolved)"
        }
    }
}
