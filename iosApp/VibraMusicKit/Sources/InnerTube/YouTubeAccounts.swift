import Foundation
import CryptoKit

// Ports auth/AccountSessions.kt.

/// A Google login kept independently from every other captured login: its own cookie snapshot, and
/// the Personal/Brand identities found under it.
public struct GoogleAccountSession: Hashable, Sendable, Identifiable {
    public var accountId: String
    public var cookie: String
    public var name: String
    public var email: String
    public var profiles: [YouTubeProfile]
    public var activeProfileId: String?

    public init(
        accountId: String,
        cookie: String,
        name: String = "",
        email: String = "",
        profiles: [YouTubeProfile] = [],
        activeProfileId: String? = nil
    ) {
        self.accountId = accountId
        self.cookie = cookie
        self.name = name
        self.email = email
        self.profiles = profiles
        self.activeProfileId = activeProfileId
    }

    public var id: String { accountId }

    /// The profile this account last acted as.
    public var activeProfile: YouTubeProfile? {
        profiles.first { $0.profileId == activeProfileId }
    }
}

/// One Personal or Brand identity available under a Google login.
public struct YouTubeProfile: Hashable, Sendable, Identifiable {
    public var profileId: String
    public var name: String
    public var handle: String
    public var avatar: String?
    /// `X-Goog-PageId`; set only for a Brand account.
    public var pageId: String?
    /// `onBehalfOfUser`.
    public var dataSyncId: String?
    /// `X-Goog-AuthUser` — which Google account in the cookie jar.
    public var authUser: String?
    public var isBrandAccount: Bool

    public init(
        profileId: String,
        name: String,
        handle: String = "",
        avatar: String? = nil,
        pageId: String? = nil,
        dataSyncId: String? = nil,
        authUser: String? = nil,
        isBrandAccount: Bool = false
    ) {
        self.profileId = profileId
        self.name = name
        self.handle = handle
        self.avatar = avatar
        self.pageId = pageId
        self.dataSyncId = dataSyncId
        self.authUser = authUser
        self.isBrandAccount = isBrandAccount
    }

    public var id: String { profileId }

    /// Whether this profile's id is the provisional, name-derived one (``YouTubeAccounts/profileId(pageId:dataSyncId:name:)``)
    /// rather than an id Google reported.
    public var isPlaceholder: Bool { profileId.hasPrefix("profile:") }
}

/// An (account, profile) pair: one position in the profile selector.
public struct YouTubeProfileRef: Hashable, Sendable {
    public var accountId: String
    public var profileId: String

    public init(accountId: String, profileId: String) {
        self.accountId = accountId
        self.profileId = profileId
    }
}

/// Helpers over the account registry.
public enum YouTubeAccounts {
    /// Stable selector/swipe order: account insertion order, then profile order.
    public static func flattenedProfiles(_ accounts: [GoogleAccountSession]) -> [YouTubeProfileRef] {
        accounts.flatMap { account in account.profiles.map { YouTubeProfileRef(accountId: account.accountId, profileId: $0.profileId) } }
    }

    /// The profile before or after the given one, or nil at either end (no wrapping — the avatar
    /// plays its elastic cue instead).
    public static func adjacentProfile(
        _ accounts: [GoogleAccountSession],
        accountId: String?,
        profileId: String?,
        forward: Bool
    ) -> YouTubeProfileRef? {
        let items = flattenedProfiles(accounts)
        let index = items.firstIndex { $0.accountId == accountId && $0.profileId == profileId } ?? -1
        return items.element(at: index + (forward ? 1 : -1))
    }

    /// A stable id for a captured login: its dataSyncId when known, else a hash of the cookie.
    public static func sessionId(cookie: String, dataSyncId: String?) -> String {
        dataSyncId.nonBlank ?? String(sha256(cookie).prefix(24))
    }

    /// A profile's id: the page id for a brand channel, the dataSyncId for the account's own, and a
    /// provisional name hash (`profile:…`) for a channel captured before Google reported either.
    public static func profileId(pageId: String?, dataSyncId: String?, name: String) -> String {
        pageId ?? dataSyncId ?? "profile:\(sha256(name).prefix(16))"
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Persistence (Android's JSON shape, so the keys read the same)

    /// The registry as JSON.
    public static func encode(_ sessions: [GoogleAccountSession]) -> String {
        let array: [InnerTubeJSON] = sessions.map { session in
            var object = InnerTubeJSONObject([
                "id": .string(session.accountId),
                "cookie": .string(session.cookie),
                "name": .string(session.name),
                "email": .string(session.email),
            ])
            if let active = session.activeProfileId { object["activeProfileId"] = .string(active) }
            object["profiles"] = .array(session.profiles.map { profile in
                var value = InnerTubeJSONObject([
                    "id": .string(profile.profileId),
                    "name": .string(profile.name),
                    "handle": .string(profile.handle),
                ])
                if let avatar = profile.avatar { value["avatar"] = .string(avatar) }
                if let pageId = profile.pageId { value["pageId"] = .string(pageId) }
                if let dataSyncId = profile.dataSyncId { value["dataSyncId"] = .string(dataSyncId) }
                if let authUser = profile.authUser { value["authUser"] = .string(authUser) }
                value["brand"] = .bool(profile.isBrandAccount)
                return .object(value)
            })
            return .object(object)
        }
        return String(decoding: InnerTubeJSON.array(array).serialized(), as: UTF8.self)
    }

    /// The registry from JSON: lenient (missing fields default, entries without a cookie are
    /// dropped), and empty for anything unreadable rather than a failure.
    public static func decode(_ raw: String?) -> [GoogleAccountSession] {
        guard let raw, let root = try? InnerTubeJSON.parse(raw), let items = root.arrayValue else { return [] }
        return items.compactMap { item in
            guard let cookie = item.s("cookie"), !cookie.isBlankText else { return nil }
            let profiles: [YouTubeProfile] = (item.a("profiles") ?? []).map { value in
                let name = value.s("name") ?? ""
                return YouTubeProfile(
                    profileId: value.s("id") ?? profileId(pageId: nil, dataSyncId: nil, name: name),
                    name: name,
                    handle: value.s("handle") ?? "",
                    avatar: value.s("avatar").nonBlank,
                    pageId: value.s("pageId").nonBlank,
                    dataSyncId: value.s("dataSyncId").nonBlank,
                    authUser: value.s("authUser").nonBlank,
                    isBrandAccount: value.s("brand") == "true"
                )
            }
            return GoogleAccountSession(
                accountId: item.s("id") ?? sessionId(cookie: cookie, dataSyncId: nil),
                cookie: cookie,
                name: item.s("name") ?? "",
                email: item.s("email") ?? "",
                profiles: profiles,
                activeProfileId: item.s("activeProfileId").nonBlank
            )
        }
    }
}

extension Array {
    /// This array with the element sharing `element`'s key replaced where it stands, or `element`
    /// appended when none does.
    func replacingOrAppending<Key: Equatable>(_ element: Element, by key: (Element) -> Key) -> [Element] {
        var copy = self
        if let index = copy.firstIndex(where: { key($0) == key(element) }) {
            copy[index] = element
        } else {
            copy.append(element)
        }
        return copy
    }
}
