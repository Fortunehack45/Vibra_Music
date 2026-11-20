import VibraMusicCore
import Foundation

// Ports data/smb/SmbConfig.kt: SMB file-share music library configuration and
// mapping — the same shape as WebDavConfig, for a protocol that has no URLs
// of its own.
//
// Tracks are addressed as `smb://host/share/path/to/file`. Credentials never
// ride in the URI (it is logged, cached and keyed on); readers authenticate
// from the live credentials at open time instead.

/// SMB share configuration, paths and row mapping.
public enum SmbConfig {
    /// The browse id the library page is filed under (matches VibraMusicCore's
    /// `LocalBrowseID.smb`).
    public static let browseID = "local:smb"
    public static let scheme = "smb"
    public static let defaultPort = 445

    public static let audioExtensions: Set<String> = [
        "mp3", "m4a", "flac", "ogg", "opus", "aac", "wav", "wma", "aif", "aiff", "webm",
    ]

    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp"]

    public static func normalizeHost(_ raw: String) -> String {
        splitHostPort(raw).host
    }

    /// `host`, `host:port` or `smb://host:port/…` — the port defaults to 445.
    /// Bracketed IPv6 (`[::1]:445`) keeps its colons.
    public static func splitHostPort(_ raw: String) -> (host: String, port: Int) {
        var authority = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if authority.hasPrefix("smb://") { authority = String(authority.dropFirst("smb://".count)) }
        else if authority.hasPrefix("\\\\") { authority = String(authority.dropFirst(2)) }
        authority = String(authority.split(separator: "/", maxSplits: 1).first ?? Substring(authority))
        authority = String(authority.split(separator: "\\", maxSplits: 1).first ?? Substring(authority))
        if authority.hasPrefix("[") {
            let host = authority.split(separator: "]").first.map { String($0.dropFirst()).lowercased() } ?? ""
            let port = authority.split(separator: ":", maxSplits: .max).last.flatMap { Int($0) }
            return (host, validPort(port))
        }
        let port: Int? = authority.contains(":")
            ? Int(authority.split(separator: ":").last.map(String.init) ?? "")
            : nil
        let host: String
        if authority.contains(":") {
            host = String(authority.split(separator: ":").dropLast().joined(separator: ":"))
                .lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            host = authority.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (host, validPort(port))
    }

    private static func validPort(_ port: Int?) -> Int {
        guard let port, (1...65535).contains(port) else { return defaultPort }
        return port
    }

    public static func isConfigured(host: String, share: String) -> Bool {
        !normalizeHost(host).isEmpty && !share.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func isAudioFile(_ name: String) -> Bool {
        audioExtensions.contains(name.split(separator: ".").last.map { $0.lowercased() } ?? "")
    }

    public static func isImageFile(_ name: String) -> Bool {
        imageExtensions.contains(name.split(separator: ".").last.map { $0.lowercased() } ?? "")
    }

    /// Stable track id. Prefixed so it never collides with a YouTube id, a
    /// local URI, a module key or a WebDAV id.
    public static func idFor(host: String, share: String, path: String) -> String {
        "smb:\(normalizeHost(host))/\(share.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public static func isSmbId(_ videoId: String) -> Bool {
        videoId.hasPrefix("smb:")
    }

    public static func isSmbUrl(_ url: String) -> Bool {
        url.hasPrefix("smb://")
    }

    /// `smb://host/share/a/b.mp3` back to the share-relative path `a/b.mp3`.
    /// Pure string work so it stays unit-testable. The share segment must
    /// name `share`: a URL baked under a previous share fails loudly rather
    /// than opening a same-named stranger.
    public static func relativePath(_ streamUrl: String, share: String) -> String? {
        // These URIs never carry userinfo, so there is nothing to strip.
        guard streamUrl.hasPrefix("smb://") else { return nil }
        let segments = streamUrl.dropFirst("smb://".count).split(separator: "/").filter { !$0.isEmpty }
        guard segments.count >= 3 else { return nil }
        guard segments[1].lowercased() == share.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() else {
            return nil
        }
        let path = segments.dropFirst(2).joined(separator: "/")
            .split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        let clean = String(path.split(separator: "#", maxSplits: 1).first ?? Substring(path))
        return clean.isEmpty ? nil : clean
    }

    public static func songFor(host: String, share: String, path: String, albumName: String? = nil) -> Song {
        let fileName = String(path.split(separator: "/").last ?? Substring(path))
        let fileNameBackslash = String(fileName.split(separator: "\\").last ?? Substring(fileName))
        let streamUrl = "smb://\(normalizeHost(host))/\(share.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
        return RemoteSong.build(
            videoId: idFor(host: host, share: share, path: path),
            streamUrl: streamUrl,
            fileName: fileNameBackslash,
            albumName: albumName,
            source: "SMB",
            browseId: browseID
        )
    }
}

/// Live SMB connection parameters.
///
/// Held outside UserDefaults so the network layer never touches storage: the
/// app publishes the settings here on init and on every edit (which also
/// drops the pooled connection — a server or credential change must never
/// keep reading on the old session). Credentials themselves live in Core's
/// `KeychainStore` (via `AppSettings`); this value only carries them to the
/// wire. Replaces Android's `SmbAuth` object.
public struct SmbCredentials: Hashable, Sendable {
    public var host: String
    public var port: Int
    public var share: String
    public var basePath: String
    public var username: String
    public var password: String

    public init(host: String, share: String, basePath: String = "", username: String = "", password: String = "") {
        let parsed = SmbConfig.splitHostPort(host)
        self.host = parsed.host
        self.port = parsed.port
        self.share = share.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.basePath = basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).replacingOccurrences(of: "\\", with: "/")
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.password = password
    }

    public var isConfigured: Bool {
        SmbConfig.isConfigured(host: host, share: share)
    }

    /// Blank credentials log in as guest (a real NTLM exchange landing on the
    /// server's guest path), never as anonymous — anonymous sessions derive
    /// no session key on servers that don't flag them as null (Samba).
    public var isGuest: Bool {
        username.isEmpty && password.isEmpty
    }
}
