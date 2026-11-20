import Foundation
import VibraMusicCore

// Ports auth/AuthStore.kt (the YouTube Music part) onto the Keychain. Android kept these in
// EncryptedSharedPreferences (auth/EncryptedPrefs.kt), repairing the file when a restore left a
// keyset the device couldn't unwrap; the Keychain has no such failure mode, so that machinery has
// no iOS counterpart. Discord, WebDAV and SMB credentials live in AppSettings' credential store.

/// The durable Google account registry: every captured login's cookie and its identities, and which
/// one is active.
///
/// Credentials never go in `UserDefaults`: a session cookie grants full access to the account. Reads
/// never throw — a Keychain that can't be read reads as signed out (logged), which is what Android's
/// degrade-don't-crash store did too.
public final class YouTubeAuthStore: Sendable {
    private let credentials: any CredentialStoring
    private static let log = "InnerTube"

    enum Key {
        static let sessions = "google_account_sessions_v2"
        static let activeAccount = "active_google_account_id_v2"
        static let activeProfile = "active_youtube_profile_id_v2"
    }

    public init(credentials: any CredentialStoring = KeychainStore()) {
        self.credentials = credentials
    }

    /// Every stored Google login, in the order they were added.
    public var sessions: [GoogleAccountSession] {
        YouTubeAccounts.decode(read(Key.sessions))
    }

    public var activeAccountId: String? { read(Key.activeAccount).nonBlank }
    public var activeProfileId: String? { read(Key.activeProfile).nonBlank }

    /// The active login, falling back to the first one.
    public var activeSession: GoogleAccountSession? {
        let all = sessions
        return all.first { $0.accountId == activeAccountId } ?? all.first
    }

    /// Whether the active login can sign requests at all — see ``SAPISIDAuth/hasSigningSecret(_:)``.
    public var isSignedIn: Bool {
        activeSession.map { Self.hasApiSid($0.cookie) } ?? false
    }

    public func replaceSessions(_ value: [GoogleAccountSession]) {
        write(YouTubeAccounts.encode(value), Key.sessions)
    }

    /// Adds a login at the end, or replaces the one with the same account id where it stands, and
    /// optionally makes it active.
    ///
    /// Android removed and re-appended on every update, which moved an account to the end of the
    /// profile selector each time one of its profiles was picked — contradicting the "stable
    /// selector order" `flattenedProfiles` promises (swiping forward twice could land back where it
    /// started). Replacing in place keeps that promise.
    public func upsertSession(_ session: GoogleAccountSession, activate: Bool = true) {
        replaceSessions(sessions.replacingOrAppending(session, by: \.accountId))
        if activate { select(accountId: session.accountId, profileId: session.activeProfileId) }
    }

    public func select(accountId: String?, profileId: String?) {
        write(accountId, Key.activeAccount)
        write(profileId, Key.activeProfile)
    }

    /// Forgets one login and makes the first remaining one active; returns it (nil when none remain).
    @discardableResult
    public func removeAccount(_ accountId: String) -> GoogleAccountSession? {
        let remaining = sessions.filter { $0.accountId != accountId }
        replaceSessions(remaining)
        let fallback = remaining.first
        select(accountId: fallback?.accountId, profileId: fallback?.activeProfileId)
        return fallback
    }

    /// Signs out of YouTube Music only. The in-app browser's own copy of the Google login is cleared
    /// by ``YouTubeAccountManager`` (it lives in WebKit, not here).
    public func signOut() {
        for key in [Key.sessions, Key.activeAccount, Key.activeProfile] { write(nil, key) }
    }

    /// Whether a cookie header carries a secret Innertube requests can be signed with.
    public static func hasApiSid(_ cookieHeader: String) -> Bool {
        SAPISIDAuth.hasSigningSecret(cookieHeader)
    }

    private func read(_ key: String) -> String? {
        do {
            return try credentials.string(forKey: key)
        } catch {
            DebugLog.w(Self.log, "could not read \(key) from the keychain", error: error)
            return nil
        }
    }

    private func write(_ value: String?, _ key: String) {
        do {
            try credentials.setString(value, forKey: key)
        } catch {
            DebugLog.e(Self.log, "could not write \(key) to the keychain", error: error)
        }
    }
}
