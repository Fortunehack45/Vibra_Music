import Foundation
import Observation
import VibraMusicCore

// Ports the account and profile logic of ui/MainViewModel.kt (onWebSession, selectProfile,
// stepProfile, removeAccount, loadChannels/persistDetectedProfiles, loadAccount's name upgrade,
// signOut) and the session restore in VibraMusicApplication.onCreate. Screen state that belongs to a
// listener (library, history, hearts) is the app's: it reacts to `onIdentityChange`.

/// How the identity requests act as just changed. Everything on screen that answers "who is asking"
/// — library, likes, playlists, history, Home — belongs to the identity being left, and stream
/// verdicts reached under one session say nothing about another.
public enum YouTubeIdentityChange: Hashable, Sendable {
    /// A login captured from the web view was validated and is now active (a fresh sign-in, or the
    /// same login pointed at another channel). `replacedListener` is true when someone was signed in
    /// before.
    case signedIn(YouTubeProfileRef, replacedListener: Bool)
    /// Another stored profile was selected.
    case profileSelected(YouTubeProfileRef)
    /// Nobody is signed in any more.
    case signedOut
}

/// The signed-in Google accounts, their YouTube identities, and which one requests act as.
///
/// One Google login can hold a Personal channel and several Brand channels, each a separate listener
/// on YouTube Music with its own library, likes and history. The manager keeps the registry (in
/// ``YouTubeAuthStore``), installs the active identity on the ``InnerTubeClient``, validates a
/// captured login before persisting any of it, and reports every identity change so the app can
/// clear and reload listener state.
@MainActor
@Observable
public final class YouTubeAccountManager {
    /// Every stored Google login.
    public private(set) var accounts: [GoogleAccountSession] = []
    public private(set) var activeAccountId: String?
    public private(set) var activeProfileId: String?
    /// Whether a login that can sign requests is active.
    public private(set) var isSignedIn = false
    /// The active identity's profile as YouTube Music reports it (name, email/handle, avatar).
    public private(set) var account: Account?
    /// Channels the active login can act as, as last listed by ``loadChannels(force:)``.
    public private(set) var channels: [AccountChannel] = []
    public private(set) var channelsLoading = false
    /// The chosen profile id, or nil while acting as whatever YouTube Music serves by default.
    public private(set) var selectedChannelKey: String?
    public private(set) var selectedChannelName: String?

    /// Told after every identity change, once the client already acts as the new identity.
    @ObservationIgnored public var onIdentityChange: (@MainActor (YouTubeIdentityChange) -> Void)?

    @ObservationIgnored private let client: InnerTubeClient
    @ObservationIgnored private let repository: YTMusicRepository
    @ObservationIgnored private let store: YouTubeAuthStore
    @ObservationIgnored private let clearBrowserCookies: @MainActor () async -> Void
    @ObservationIgnored private let validationTimeout: Duration
    @ObservationIgnored private let validationRetryDelay: Duration

    /// - Parameters:
    ///   - clearBrowserCookies: forgets the in-app browser's Google login on sign-out (the app passes
    ///     `YouTubeBrowserCookies.clearGoogleCookies(in: .defaultStore)`), so the next sign-in can
    ///     choose another account instead of being waved through as the one just signed out of.
    ///   - validationTimeout: how long a captured login may take to prove itself.
    public init(
        client: InnerTubeClient,
        repository: YTMusicRepository,
        store: YouTubeAuthStore,
        clearBrowserCookies: @escaping @MainActor () async -> Void = {},
        validationTimeout: Duration = .seconds(20),
        validationRetryDelay: Duration = .milliseconds(750)
    ) {
        self.client = client
        self.repository = repository
        self.store = store
        self.clearBrowserCookies = clearBrowserCookies
        self.validationTimeout = validationTimeout
        self.validationRetryDelay = validationRetryDelay
    }

    /// `accountId:profileId` of the active identity — the key listener caches are partitioned by.
    public var listenerKey: String? {
        guard let activeAccountId, let activeProfileId else { return nil }
        return "\(activeAccountId):\(activeProfileId)"
    }

    public var activeSession: GoogleAccountSession? {
        accounts.first { $0.accountId == activeAccountId }
    }

    public var activeProfile: YouTubeProfile? {
        activeSession?.profiles.first { $0.profileId == activeProfileId }
    }

    /// Profiles in selector order, with their accounts.
    public var profileRefs: [YouTubeProfileRef] { YouTubeAccounts.flattenedProfiles(accounts) }

    // MARK: - Startup

    /// Restores the stored session at launch and installs it on the client.
    ///
    /// The cookie first, then the chosen channel: setting the cookie clears any channel the last
    /// session was acting as. Which account that cookie acts as is then read in the background, so
    /// the answer is usually in hand before the first request needs it.
    public func restore() async {
        let restored = store.activeSession
        if let restored, store.activeAccountId == nil {
            store.select(accountId: restored.accountId, profileId: restored.activeProfileId)
        }
        accounts = store.sessions
        activeAccountId = restored?.accountId
        activeProfileId = store.activeProfileId
        isSignedIn = store.isSignedIn
        selectedChannelKey = restored?.activeProfileId
        selectedChannelName = restored?.activeProfile?.name
        await client.activate(cookie: restored?.cookie, profile: restored?.activeProfile)
        if restored != nil {
            let client = self.client
            Task.detached { await client.ensureSessionScope() }
        }
    }

    // MARK: - Web sessions

    /// A session lifted out of the in-app browser — a fresh sign-in, or the same login now pointed at
    /// a different channel. Returns whether it was accepted.
    ///
    /// The captured cookie/profile pair is validated (the account menu must answer as it) *before*
    /// anything is written: persisting first once turned a half-finished channel chooser into a
    /// durable, broken "Personal" account. A rejected candidate puts request signing back exactly as
    /// it was.
    @discardableResult
    public func handleWebSession(_ session: CapturedSession, mode: WebSessionMode) async -> Bool {
        guard session.loggedIn else { return false }
        let oldAccountId = activeAccountId
        let oldProfileId = activeProfileId
        await client.adoptWebSession(session)

        guard let account = await validatedAccount() else {
            await restoreActiveSession(accountId: oldAccountId, profileId: oldProfileId)
            return false
        }

        // A channel switch is another identity under the same Google login, never a new account. For
        // a fresh sign-in, matching a non-empty email upgrades the existing entry instead of adding a
        // duplicate after cookies rotate.
        let accountId: String?
        switch mode {
        case .switchChannel:
            accountId = oldAccountId
        case .signIn:
            accountId = store.sessions.first {
                !account.email.isBlankText && $0.email.caseInsensitiveCompare(account.email) == .orderedSame
            }?.accountId ?? YouTubeAccounts.sessionId(cookie: session.cookie, dataSyncId: nil)
        }
        guard let accountId else {
            await restoreActiveSession(accountId: oldAccountId, profileId: oldProfileId)
            return false
        }

        let previous = store.sessions.first { $0.accountId == accountId }
        let profile = YouTubeProfile(
            profileId: YouTubeAccounts.profileId(pageId: session.pageId, dataSyncId: session.dataSyncId, name: account.name),
            name: account.name,
            handle: account.email,
            avatar: account.thumbnailUrl,
            pageId: session.pageId,
            dataSyncId: session.dataSyncId,
            authUser: session.authUser,
            isBrandAccount: session.pageId != nil
        )
        // A real identity retires any provisional profile captured before the channel existed.
        let hasRealIdentity = profile.pageId != nil || profile.dataSyncId != nil
        let profiles = (previous?.profiles ?? [])
            .filter { known in !(hasRealIdentity && known.isPlaceholder && known.profileId != profile.profileId) }
            .replacingOrAppending(profile, by: \.profileId)
        let stored = GoogleAccountSession(
            accountId: accountId,
            cookie: session.cookie,
            name: account.name,
            email: account.email,
            profiles: profiles,
            activeProfileId: profile.profileId
        )

        let wasSignedIn = isSignedIn
        store.upsertSession(stored)
        accounts = store.sessions
        activeAccountId = accountId
        activeProfileId = profile.profileId
        selectedChannelKey = profile.profileId
        selectedChannelName = account.name
        self.account = account
        channels = []
        isSignedIn = true

        onIdentityChange?(.signedIn(YouTubeProfileRef(accountId: accountId, profileId: profile.profileId), replacedListener: wasSignedIn))
        // Not awaited: the login screen can close while the channel list arrives.
        Task { await self.loadChannels(force: true) }
        return true
    }

    /// The account menu as the candidate session, retried once after a short pause, within the
    /// validation timeout.
    private func validatedAccount() async -> Account? {
        let repository = self.repository
        let retryDelay = validationRetryDelay
        return await Self.withTimeout(validationTimeout) {
            if let account = try? await repository.account() { return account }
            try? await Task.sleep(for: retryDelay)
            return try? await repository.account()
        } ?? nil
    }

    /// Puts request signing back exactly as it was after a rejected candidate.
    private func restoreActiveSession(accountId: String?, profileId: String?) async {
        let account = store.sessions.first { $0.accountId == accountId }
        let profile = account?.profiles.first { $0.profileId == profileId }
        await client.activate(cookie: account?.cookie, profile: profile)
    }

    // MARK: - Profiles

    /// Selects an identity. `supplied` stands in for (and replaces) the stored profile with the same
    /// id — how a freshly listed channel is selected.
    public func selectProfile(accountId: String, profileId: String, supplied: YouTubeProfile? = nil) async {
        guard let source = accounts.first(where: { $0.accountId == accountId }),
              let profile = supplied ?? source.profiles.first(where: { $0.profileId == profileId }) else { return }
        if accountId == activeAccountId && profile.profileId == activeProfileId { return }
        var updated = source
        // In place, so the selector order stays put (see YouTubeAuthStore.upsertSession).
        updated.profiles = source.profiles.replacingOrAppending(profile, by: \.profileId)
        updated.activeProfileId = profile.profileId
        store.upsertSession(updated)
        store.select(accountId: accountId, profileId: profile.profileId)
        accounts = store.sessions
        activeAccountId = accountId
        activeProfileId = profile.profileId
        selectedChannelKey = profile.profileId
        selectedChannelName = profile.name
        account = nil
        await client.activate(cookie: updated.cookie, profile: profile)
        onIdentityChange?(.profileSelected(YouTubeProfileRef(accountId: accountId, profileId: profile.profileId)))
    }

    /// Acts as `channel` (from ``channels``) under the active login.
    public func selectChannel(_ channel: AccountChannel) async {
        guard let accountId = activeAccountId else { return }
        let profile = YouTubeProfile(
            profileId: YouTubeAccounts.profileId(pageId: channel.pageId, dataSyncId: channel.dataSyncId, name: channel.name),
            name: channel.name,
            handle: channel.subtitle,
            avatar: channel.thumbnailUrl,
            pageId: channel.pageId,
            dataSyncId: channel.dataSyncId,
            isBrandAccount: channel.pageId != nil
        )
        await selectProfile(accountId: accountId, profileId: profile.profileId, supplied: profile)
    }

    /// Swipes to the next or previous profile. Returns false at an edge, so the avatar can play its
    /// elastic cue.
    @discardableResult
    public func stepProfile(forward: Bool) async -> Bool {
        guard let target = YouTubeAccounts.adjacentProfile(accounts, accountId: activeAccountId, profileId: activeProfileId, forward: forward) else {
            return false
        }
        await selectProfile(accountId: target.accountId, profileId: target.profileId)
        return true
    }

    /// Forgets one login; another becomes active, or everyone is signed out when none remain.
    public func removeAccount(_ accountId: String) async {
        let fallback = store.removeAccount(accountId)
        accounts = store.sessions
        guard let fallback else {
            await signOutCompletely()
            return
        }
        guard let profileId = fallback.activeProfileId ?? fallback.profiles.first?.profileId else { return }
        await selectProfile(accountId: fallback.accountId, profileId: profileId)
    }

    /// Signs out. With several logins stored only the current one is removed and another restored;
    /// a single login signs out entirely.
    public func signOut() async {
        if let current = activeAccountId, store.sessions.count > 1 {
            await removeAccount(current)
            return
        }
        await signOutCompletely()
    }

    private func signOutCompletely() async {
        store.signOut()
        await clearBrowserCookies()
        await client.setCookie(nil)
        await client.selectChannel(pageId: nil, dataSyncId: nil)
        isSignedIn = false
        account = nil
        channels = []
        selectedChannelKey = nil
        selectedChannelName = nil
        accounts = []
        activeAccountId = nil
        activeProfileId = nil
        onIdentityChange?(.signedOut)
    }

    // MARK: - Channels and profile details

    /// Lists the channels the active login can act as, and folds them into the stored profiles.
    public func loadChannels(force: Bool = false) async {
        guard isSignedIn, !channelsLoading else { return }
        if !force && !channels.isEmpty { return }
        channelsLoading = true
        defer { channelsLoading = false }
        let identity = listenerKey
        guard let listed = try? await repository.accountChannels(), identity == listenerKey else { return }
        channels = listed
        persistDetectedProfiles(listed)
    }

    /// Merges listed channels into the active login's profiles.
    ///
    /// A profile captured before its channel existed carries a provisional name-hash id rather than
    /// the pageId/dataSyncId Google reports once the channel is live. When Google reports channels,
    /// that placeholder is stale and dropped. An empty response (no channel yet, or a transient miss)
    /// must never drop it — nor erase the active selection.
    func persistDetectedProfiles(_ listed: [AccountChannel]) {
        guard let accountId = activeAccountId,
              let current = store.sessions.first(where: { $0.accountId == accountId }) else { return }
        let detected = listed.map { channel in
            YouTubeProfile(
                profileId: YouTubeAccounts.profileId(pageId: channel.pageId, dataSyncId: channel.dataSyncId, name: channel.name),
                name: channel.name,
                handle: channel.subtitle,
                avatar: channel.thumbnailUrl,
                pageId: channel.pageId,
                dataSyncId: channel.dataSyncId,
                isBrandAccount: channel.pageId != nil
            )
        }
        let stalePlaceholders: Set<String> = detected.isEmpty
            ? []
            : Set(current.profiles.filter(\.isPlaceholder).map(\.profileId))
        // The same set of profiles Android keeps, merged in place rather than re-appended so the
        // selector order stays put. A listed channel carries no jar entry; the one captured for it
        // (if any) still applies — the list only ever names channels of this same login.
        var profiles = current.profiles.filter { !stalePlaceholders.contains($0.profileId) }
        for var channel in detected {
            if let known = profiles.first(where: { $0.profileId == channel.profileId }) {
                channel.authUser = channel.authUser ?? known.authUser
            }
            profiles = profiles.replacingOrAppending(channel, by: \.profileId)
        }
        let selected: String?
        if let active = current.activeProfileId, !stalePlaceholders.contains(active) {
            selected = active
        } else if let active = current.activeProfileId, stalePlaceholders.contains(active) {
            selected = detected.count == 1 ? detected[0].profileId : nil
        } else {
            selected = nil
        }
        var updated = current
        updated.profiles = profiles
        updated.activeProfileId = selected ?? profiles.first?.profileId
        store.upsertSession(updated, activate: false)
        accounts = store.sessions
    }

    /// Fetches the active identity's profile, and names the chosen channel with it.
    ///
    /// A channel picked in the in-app browser arrives as ids and nothing else — the page's `ytcfg`
    /// never says what the channel is called. The account menu, asked *as* that channel, answers with
    /// its name, which the stored profile then keeps.
    public func refreshAccount() async {
        let identity = listenerKey
        let fetched = try? await repository.account()
        guard identity == listenerKey else { return }
        account = fetched
        guard let fetched, selectedChannelKey != nil else { return }
        selectedChannelName = fetched.name
        guard let accountId = activeAccountId,
              var session = store.sessions.first(where: { $0.accountId == accountId }) else { return }
        session.name = fetched.name
        session.email = fetched.email
        session.profiles = session.profiles.map { profile in
            guard profile.profileId == activeProfileId else { return profile }
            var named = profile
            named.name = fetched.name
            named.handle = fetched.email
            named.avatar = fetched.thumbnailUrl
            return named
        }
        store.upsertSession(session, activate: false)
        accounts = store.sessions
    }

    // MARK: - Helpers

    /// `operation`'s result, or nil when it doesn't finish within `limit`.
    static func withTimeout<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
