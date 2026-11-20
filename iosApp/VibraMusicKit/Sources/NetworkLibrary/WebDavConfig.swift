import VibraMusicCore
import Foundation

// Ports data/webdav/WebDavConfig.kt: WebDAV music library configuration and
// mapping.
//
// A WebDAV server is treated as a remote folder of audio files: tracks are
// listed with PROPFIND, streamed over plain HTTPS with Basic auth, and shown
// in the same Songs / Artists / Albums view as on-device files.

/// WebDAV server configuration, auth and row mapping.
public enum WebDavConfig {
    public static let browseID = "local:webdav"

    public static let audioExtensions: Set<String> = [
        "mp3", "m4a", "flac", "ogg", "opus", "aac", "wav", "wma", "aif", "aiff", "webm",
    ]

    public static func normalizeUrl(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed = String(trimmed.dropLast()) }
        guard !trimmed.isEmpty else { return "" }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return trimmed }
        return "https://\(trimmed)"
    }

    public static func isConfigured(_ url: String) -> Bool {
        let normalized = normalizeUrl(url)
        let lower = normalized.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return false }
        // "not a url" normalizes to "https://not a url" — only a parseable
        // host counts as configured.
        return hostOf(normalized) != nil
    }

    public static func basicAuthHeader(username: String, password: String) -> String? {
        guard !username.isEmpty || !password.isEmpty else { return nil }
        let encoded = Data("\(username):\(password)".utf8).base64EncodedString()
        return "Basic \(encoded)"
    }

    public static func hostOf(_ url: String) -> String? {
        guard let host = URLComponents(string: normalizeUrl(url))?.host?.lowercased(),
              !host.isEmpty
        else { return nil }
        return host
    }

    public static func isAudioFile(_ name: String) -> Bool {
        audioExtensions.contains(name.split(separator: ".").last.map { $0.lowercased() } ?? "")
    }

    /// Stable track id for a remote file. Prefixed so it never collides with
    /// a YouTube id, a local URI, or a module source key.
    public static func idFor(fileUrl: String) -> String {
        "webdav:\(fileUrl)"
    }

    public static func isWebDavId(_ videoId: String) -> Bool {
        videoId.hasPrefix("webdav:")
    }

    public static func fileUrlOf(_ videoId: String) -> String? {
        guard isWebDavId(videoId) else { return nil }
        let url = String(videoId.dropFirst("webdav:".count))
        return url.hasPrefix("http") ? url : nil
    }

    /// A row for a remote file. Title/artist come from the filename —
    /// "Artist - Title.ext" splits, anything else is a title by an unknown
    /// artist — and the parent folder names the album when there is one.
    public static func songFor(fileUrl: String, albumName: String? = nil) -> Song {
        let last = fileUrl.split(separator: "/").last.map(String.init) ?? fileUrl
        let decoded = last.removingPercentEncoding ?? last
        return RemoteSong.build(
            videoId: idFor(fileUrl: fileUrl),
            streamUrl: fileUrl,
            fileName: decoded,
            albumName: albumName,
            source: "WebDAV",
            browseId: browseID
        )
    }
}

/// Live WebDAV credentials for one server.
///
/// Held outside UserDefaults so the network layer never touches storage: the
/// app publishes the settings here on init and on every WebDAV edit.
/// Passwords themselves live in Core's `KeychainStore` (via `AppSettings`);
/// this value only carries them to the wire. Replaces Android's `WebDavAuth`
/// object.
public struct WebDavCredentials: Hashable, Sendable {
    /// The normalised server root (no trailing slash).
    public var rootUrl: String
    public var username: String
    public var password: String

    public init(url: String, username: String = "", password: String = "") {
        self.rootUrl = WebDavConfig.normalizeUrl(url)
        self.username = username
        self.password = password
    }

    public var isConfigured: Bool {
        WebDavConfig.isConfigured(rootUrl)
    }

    public var host: String? {
        WebDavConfig.hostOf(rootUrl)
    }

    public var authHeader: String? {
        WebDavConfig.basicAuthHeader(username: username, password: password)
    }

    /// Whether requests to `requestHost` should carry this credential.
    public func shouldAuthorize(requestHost: String) -> Bool {
        guard let expected = host, let header = authHeader, !header.isEmpty else { return false }
        return requestHost.lowercased() == expected.lowercased()
    }
}
