import VibraMusicCore
import Foundation

/// The Discord account behind a user token (ports `UserInfo.kt`).
public struct DiscordUserInfo: Hashable, Sendable, Codable {
    public var id: String
    public var username: String
    public var name: String
    public var avatar: String?

    public init(id: String, username: String, name: String, avatar: String?) {
        self.id = id
        self.username = username
        self.name = name
        self.avatar = avatar
    }
}

private struct DiscordMeResponse: Decodable {
    var id: String
    var username: String
    var globalName: String?
    var avatar: String?

    enum CodingKeys: String, CodingKey {
        case id, username, avatar
        case globalName = "global_name"
    }
}

/// What the UI wave's `WKWebView` token-login screen needs (ports the
/// `KizzyRPC.getUserInfo` companion): fetching the account profile for a
/// pasted/captured token, and validating a token before it is saved.
///
/// A token that does not work is rejected *before* it is stored, because a
/// dead token saved as "connected" would silently publish nothing.
public enum DiscordAccountService {
    /// Fetches the profile for `token`, or `nil` when the token is rejected
    /// or the request fails.
    public static func fetchUserInfo(
        session: URLSession = VibraMusicHTTP.session,
        token: String,
        userAgent: String? = nil,
        superPropertiesBase64: String? = nil
    ) async -> DiscordUserInfo? {
        guard !token.isEmpty,
              let url = URL(string: "https://discord.com/api/v9/users/@me")
        else { return nil }
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue(userAgent ?? DiscordSuperProperties.userAgent, forHTTPHeaderField: "User-Agent")
        if let superPropertiesBase64 {
            request.setValue(superPropertiesBase64, forHTTPHeaderField: "X-Super-Properties")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse).map({ (200 ... 299).contains($0.statusCode) }) ?? false else {
                return nil
            }
            let me = try JSONDecoder().decode(DiscordMeResponse.self, from: data)
            let avatar: String?
            if let hash = me.avatar, !hash.isEmpty, hash != "null" {
                avatar = "https://cdn.discordapp.com/avatars/\(me.id)/\(hash).png"
            } else {
                avatar = nil
            }
            let displayName: String
            if let global = me.globalName, !global.isEmpty, global != "null" {
                displayName = global
            } else {
                displayName = me.username
            }
            return DiscordUserInfo(id: me.id, username: me.username, name: displayName, avatar: avatar)
        } catch {
            return nil
        }
    }

    /// Whether `token` authenticates (a thin wrapper over `fetchUserInfo`).
    public static func validateToken(
        session: URLSession = VibraMusicHTTP.session,
        token: String,
        userAgent: String? = nil,
        superPropertiesBase64: String? = nil
    ) async -> Bool {
        await fetchUserInfo(session: session, token: token, userAgent: userAgent, superPropertiesBase64: superPropertiesBase64) != nil
    }
}
