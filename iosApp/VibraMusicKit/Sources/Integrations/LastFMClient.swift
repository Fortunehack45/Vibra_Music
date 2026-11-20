import VibraMusicCore
import Foundation

/// Runtime configuration for the Last.fm / Libre.fm API (ports `LastFM.kt`'s
/// `RuntimeConfig`).
///
/// On Android the key/secret come from `local.properties` via `BuildConfig`;
/// on iOS they come from the app's `Info.plist` keys `LASTFM_API_KEY` /
/// `LASTFM_API_SECRET`, filled from the build settings of the same names,
/// which are empty unless passed to the build. Per-account overrides in
/// `AppSettings` (`lastfmApiKey`, `lastfmSecret`, `lastfmEndpoint`,
/// `lastfmSessionKey`) win over the bundled values when non-empty; the bundled
/// values are the fallback.
public struct LastFMConfiguration: Hashable, Sendable {
    public static let defaultEndpoint = "https://ws.audioscrobbler.com/2.0/"
    public static let libreFmEndpoint = "https://libre.fm/2.0/"

    public var endpoint: String
    public var apiKey: String
    public var secret: String
    public var sessionKey: String?

    public init(endpoint: String = defaultEndpoint, apiKey: String = "", secret: String = "", sessionKey: String? = nil) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.secret = secret
        self.sessionKey = sessionKey
    }

    /// Resolves the effective configuration from bundled `Info.plist` values
    /// and the account's `AppSettings` overrides.
    ///
    /// - Parameters:
    ///   - settings: the account settings holding endpoint/key/secret/session overrides.
    ///   - bundle: the bundle whose `Info.plist` carries `LASTFM_API_KEY` / `LASTFM_API_SECRET`.
    @MainActor
    public static func resolved(settings: AppSettings, bundle: Bundle = .main) -> LastFMConfiguration {
        let bundledKey = (bundle.object(forInfoDictionaryKey: "LASTFM_API_KEY") as? String) ?? ""
        let bundledSecret = (bundle.object(forInfoDictionaryKey: "LASTFM_API_SECRET") as? String) ?? ""
        let apiKey = settings.lastfmApiKey.isEmpty ? bundledKey : settings.lastfmApiKey
        let secret = settings.lastfmSecret.isEmpty ? bundledSecret : settings.lastfmSecret
        let endpoint = settings.lastfmEndpoint.isEmpty ? defaultEndpoint : settings.lastfmEndpoint
        let sessionKey = settings.lastfmSessionKey.isEmpty ? nil : settings.lastfmSessionKey
        return LastFMConfiguration(
            endpoint: (try? normalizeEndpoint(endpoint)) ?? defaultEndpoint,
            apiKey: apiKey,
            secret: secret,
            sessionKey: sessionKey
        )
    }

    /// Whether API calls can be signed: both the key and the secret are present.
    public var isConfigured: Bool { !apiKey.isEmpty && !secret.isEmpty }

    /// Normalises a user-supplied endpoint the way `LastFM.normalizeEndpoint`
    /// does: requires http/https with a host and no query/fragment, drops a
    /// bare `/` path in favour of `/2.0`, and guarantees a trailing slash.
    public static func normalizeEndpoint(_ endpoint: String) throws -> String {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = components.host, !host.isEmpty,
              components.query == nil, components.fragment == nil
        else {
            throw LastFMError(code: -1, message: "Invalid Last.fm endpoint: \(endpoint)")
        }
        var path = components.path
        if path.isEmpty || path == "/" {
            path = "/2.0"
        } else {
            while path.hasSuffix("/") { path.removeLast() }
            if path.isEmpty { path = "/2.0" }
        }
        var rebuilt = URLComponents()
        rebuilt.scheme = scheme
        rebuilt.host = host
        rebuilt.port = components.port
        rebuilt.path = path + "/"
        guard let url = rebuilt.url else {
            throw LastFMError(code: -1, message: "Invalid Last.fm endpoint: \(endpoint)")
        }
        return url.absoluteString
    }
}

/// Whether the scrobbler can do anything right now. When the key/secret are
/// absent the scrobbler is inert: calls fail fast with
/// `LastFMError.missingCredentials` instead of hitting the network.
public enum LastFMStatus: Hashable, Sendable {
    /// Ready; `sessionKey` tells whether a session (login) exists yet.
    case ready(sessionKey: String?)
    /// No API key/secret: register a Last.fm API app and pass the `LASTFM_API_KEY`
    /// and `LASTFM_API_SECRET` build settings to the build.
    case missingCredentials
}

/// Errors from the Last.fm API.
public struct LastFMError: Error, Hashable, Sendable {
    public var code: Int
    public var message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    /// Thrown client-side when no key/secret is configured.
    public static var missingCredentials: LastFMError {
        LastFMError(code: -2, message: "Last.fm API key/secret are not configured (LASTFM_API_KEY / LASTFM_API_SECRET)")
    }

    /// Thrown client-side when a session-keyed call has no session (login first).
    public static var missingSession: LastFMError {
        LastFMError(code: 9, message: "Session key missing")
    }
}

private struct LastFMErrorBody: Decodable {
    var error: Int
    var message: String
}

private struct LastFMTokenResponse: Decodable {
    var token: String
}

private struct LastFMSession: Decodable {
    var name: String
    var key: String
    var subscriber: Int
}

private struct LastFMAuthentication: Decodable {
    var session: LastFMSession
}

/// An authenticated Last.fm session (user name + session key).
public struct LastFMSessionInfo: Hashable, Sendable {
    public var username: String
    public var sessionKey: String
    public init(username: String, sessionKey: String) {
        self.username = username
        self.sessionKey = sessionKey
    }
}

/// Last.fm / Libre.fm API client (ports `LastFM.kt`).
///
/// Browser login is `requestToken()`, then the user approves
/// `authorizationURL(for:)` in a browser, then `fetchSession(token:)`; the
/// username/password path is `fetchMobileSession(username:password:)`.
/// `updateNowPlaying` / `scrobble` require a session key and throw
/// `LastFMError.missingSession` without one, mirroring `requireSessionKey()`.
public actor LastFMClient {
    public static let userAgent = "Vibra Music (https://github.com/kushagrasinghx/Vibra Music)"

    private var configuration: LastFMConfiguration
    private let session: URLSession
    private let decoder: JSONDecoder

    public init(configuration: LastFMConfiguration, session: URLSession = VibraMusicHTTP.session) {
        self.configuration = configuration
        self.session = session
        let decoder = JSONDecoder()
        self.decoder = decoder
    }

    public func updateConfiguration(_ configuration: LastFMConfiguration) {
        self.configuration = configuration
    }

    public func currentConfiguration() -> LastFMConfiguration { configuration }

    public func status() -> LastFMStatus {
        configuration.isConfigured ? .ready(sessionKey: configuration.sessionKey) : .missingCredentials
    }

    // MARK: - Auth

    /// `auth.getToken` — the first step of browser login.
    public func requestToken() async throws -> String {
        guard configuration.isConfigured else { throw LastFMError.missingCredentials }
        let body: LastFMTokenResponse = try await postAndDecode(method: "auth.getToken")
        return body.token
    }

    /// The URL the user approves the token at (Last.fm or Libre.fm variant).
    public func authorizationURL(for token: String) -> URL? {
        let base = configuration.endpoint == LastFMConfiguration.libreFmEndpoint
            ? "https://libre.fm/api/auth"
            : "https://www.last.fm/api/auth/"
        var components = URLComponents(string: base)
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: configuration.apiKey),
            URLQueryItem(name: "token", value: token),
        ]
        return components?.url
    }

    /// `auth.getSession` — the second step of browser login.
    public func fetchSession(token: String) async throws -> LastFMSessionInfo {
        guard configuration.isConfigured else { throw LastFMError.missingCredentials }
        let auth: LastFMAuthentication = try await postAndDecode(method: "auth.getSession", extra: ["token": token])
        return LastFMSessionInfo(username: auth.session.name, sessionKey: auth.session.key)
    }

    /// `auth.getMobileSession` — username/password login.
    public func fetchMobileSession(username: String, password: String) async throws -> LastFMSessionInfo {
        guard configuration.isConfigured else { throw LastFMError.missingCredentials }
        let auth: LastFMAuthentication = try await postAndDecode(
            method: "auth.getMobileSession",
            extra: ["username": username, "password": password]
        )
        return LastFMSessionInfo(username: auth.session.name, sessionKey: auth.session.key)
    }

    // MARK: - Scrobbling

    public func updateNowPlaying(
        artist: String,
        track: String,
        album: String? = nil,
        trackNumber: Int? = nil,
        durationSeconds: Int? = nil
    ) async throws {
        guard configuration.isConfigured else { throw LastFMError.missingCredentials }
        guard configuration.sessionKey != nil else { throw LastFMError.missingSession }
        var extra = ["artist": artist, "track": track]
        if let album { extra["album"] = album }
        if let trackNumber { extra["trackNumber"] = String(trackNumber) }
        if let durationSeconds { extra["duration"] = String(durationSeconds) }
        _ = try await postRaw(method: "track.updateNowPlaying", extra: extra)
    }

    public func scrobble(
        artist: String,
        track: String,
        timestamp: Int64,
        album: String? = nil,
        trackNumber: Int? = nil,
        durationSeconds: Int? = nil
    ) async throws {
        guard configuration.isConfigured else { throw LastFMError.missingCredentials }
        guard configuration.sessionKey != nil else { throw LastFMError.missingSession }
        var extra = ["artist[0]": artist, "track[0]": track, "timestamp[0]": String(timestamp)]
        if let album { extra["album[0]"] = album }
        if let trackNumber { extra["trackNumber[0]"] = String(trackNumber) }
        if let durationSeconds { extra["duration[0]"] = String(durationSeconds) }
        _ = try await postRaw(method: "track.scrobble", extra: extra)
    }

    // MARK: - Request building (public for tests)

    /// Builds the `application/x-www-form-urlencoded` body for a call, signing
    /// the parameters first and appending `api_sig` + `format` unsigned, like
    /// Kotlin's `lastfmParams`.
    public static func formFields(
        method: String,
        apiKey: String,
        secret: String,
        sessionKey: String? = nil,
        extra: [String: String] = [:]
    ) -> [(name: String, value: String)] {
        var signed: [String: String] = ["method": method, "api_key": apiKey]
        if let sessionKey { signed["sk"] = sessionKey }
        for (key, value) in extra { signed[key] = value }
        let apiSig = LastFMSignature.signature(params: signed, secret: secret)
        var fields = signed.map { (name: $0.key, value: $0.value) }
        fields.append((name: "api_sig", value: apiSig))
        fields.append((name: "format", value: "json"))
        return fields
    }

    /// Percent-encodes `formFields` into a request body.
    public static func formBody(
        method: String,
        apiKey: String,
        secret: String,
        sessionKey: String? = nil,
        extra: [String: String] = [:]
    ) -> Data {
        var components = URLComponents()
        components.queryItems = formFields(
            method: method, apiKey: apiKey, secret: secret, sessionKey: sessionKey, extra: extra
        ).map { URLQueryItem(name: $0.name, value: $0.value) }
        // A form decoder reads a bare `+` as a space, which URLComponents leaves alone.
        let query = (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        return Data(query.utf8)
    }

    private func postAndDecode<T: Decodable>(method: String, extra: [String: String] = [:]) async throws -> T {
        let text = try await postRaw(method: method, extra: extra)
        do {
            return try decoder.decode(T.self, from: Data(text.utf8))
        } catch {
            if let errorBody = try? decoder.decode(LastFMErrorBody.self, from: Data(text.utf8)) {
                throw LastFMError(code: errorBody.error, message: errorBody.message)
            }
            throw error
        }
    }

    @discardableResult
    private func postRaw(method: String, extra: [String: String] = [:]) async throws -> String {
        let config = configuration
        guard let url = URL(string: config.endpoint) else {
            throw LastFMError(code: -1, message: "Invalid Last.fm endpoint: \(config.endpoint)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(
            method: method, apiKey: config.apiKey, secret: config.secret,
            sessionKey: config.sessionKey, extra: extra
        )
        let (data, response) = try await session.data(for: request)
        let text = String(data: data, encoding: .utf8) ?? ""
        if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
            if let errorBody = try? decoder.decode(LastFMErrorBody.self, from: data) {
                throw LastFMError(code: errorBody.error, message: errorBody.message)
            }
            throw LastFMError(code: http.statusCode, message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        if text.contains("\"error\""), let errorBody = try? decoder.decode(LastFMErrorBody.self, from: data) {
            throw LastFMError(code: errorBody.error, message: errorBody.message)
        }
        return text
    }
}
