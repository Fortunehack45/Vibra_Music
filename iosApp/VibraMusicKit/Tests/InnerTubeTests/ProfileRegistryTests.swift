import XCTest
import VibraMusicCore
@testable import InnerTube

/// The Google account registry: selector order (Android's AccountSessionsTest), ids, the persisted
/// JSON shape, and the Keychain-backed store.
final class ProfileRegistryTests: XCTestCase {
    private let a = GoogleAccountSession(accountId: "a", cookie: "cookie-a", profiles: [
        YouTubeProfile(profileId: "a-personal", name: "Personal"), YouTubeProfile(profileId: "a-brand", name: "Brand"),
    ])
    private let b = GoogleAccountSession(accountId: "b", cookie: "cookie-b", profiles: [
        YouTubeProfile(profileId: "b-personal", name: "Personal"), YouTubeProfile(profileId: "b-brand", name: "Brand"),
    ])

    private func ref(_ account: String, _ profile: String) -> YouTubeProfileRef {
        YouTubeProfileRef(accountId: account, profileId: profile)
    }

    // MARK: - Selector order (AccountSessionsTest)

    func testProfilesRetainAccountThenProfileOrdering() {
        XCTAssertEqual(
            YouTubeAccounts.flattenedProfiles([a, b]),
            [ref("a", "a-personal"), ref("a", "a-brand"), ref("b", "b-personal"), ref("b", "b-brand")]
        )
    }

    func testNextPreviousAndBoundariesDoNotWrap() {
        XCTAssertEqual(YouTubeAccounts.adjacentProfile([a, b], accountId: "a", profileId: "a-personal", forward: true), ref("a", "a-brand"))
        XCTAssertEqual(YouTubeAccounts.adjacentProfile([a, b], accountId: "b", profileId: "b-brand", forward: false), ref("b", "b-personal"))
        // Crossing from one account into the next is a step like any other.
        XCTAssertEqual(YouTubeAccounts.adjacentProfile([a, b], accountId: "a", profileId: "a-brand", forward: true), ref("b", "b-personal"))
        XCTAssertNil(YouTubeAccounts.adjacentProfile([a, b], accountId: "a", profileId: "a-personal", forward: false))
        XCTAssertNil(YouTubeAccounts.adjacentProfile([a, b], accountId: "b", profileId: "b-brand", forward: true))
    }

    func testOneProfileHasNoAdjacentProfile() {
        let only = GoogleAccountSession(accountId: "a", cookie: "cookie", profiles: [YouTubeProfile(profileId: "p", name: "Personal")])
        XCTAssertNil(YouTubeAccounts.adjacentProfile([only], accountId: "a", profileId: "p", forward: true))
        XCTAssertNil(YouTubeAccounts.adjacentProfile([only], accountId: "a", profileId: "p", forward: false))
    }

    func testAnUnknownCurrentProfileStepsForwardToTheFirst() {
        // Kotlin's indexOf is -1 for a missing pair, so "next" lands on the first profile.
        XCTAssertEqual(YouTubeAccounts.adjacentProfile([a, b], accountId: nil, profileId: nil, forward: true), ref("a", "a-personal"))
        XCTAssertNil(YouTubeAccounts.adjacentProfile([a, b], accountId: nil, profileId: nil, forward: false))
    }

    // MARK: - Ids

    func testSessionIdIsTheDataSyncIdOrACookieHash() {
        XCTAssertEqual(YouTubeAccounts.sessionId(cookie: "c", dataSyncId: "SYNC"), "SYNC")
        let hashed = YouTubeAccounts.sessionId(cookie: "SAPISID=x", dataSyncId: nil)
        XCTAssertEqual(hashed.count, 24)
        XCTAssertEqual(hashed, YouTubeAccounts.sessionId(cookie: "SAPISID=x", dataSyncId: " "), "a blank id is no id")
        XCTAssertNotEqual(hashed, YouTubeAccounts.sessionId(cookie: "SAPISID=y", dataSyncId: nil))
        // SHA-256("SAPISID=x"), first 24 hex digits — the same id Android derives.
        XCTAssertEqual(hashed, "1d40fbb9738f48a802857732")
    }

    func testProfileIdPrefersPageIdThenDataSyncIdThenAProvisionalNameHash() {
        XCTAssertEqual(YouTubeAccounts.profileId(pageId: "113355", dataSyncId: "SESSION_B", name: "Brand"), "113355")
        XCTAssertEqual(YouTubeAccounts.profileId(pageId: nil, dataSyncId: "SESSION_A", name: "Ada"), "SESSION_A")
        let provisional = YouTubeAccounts.profileId(pageId: nil, dataSyncId: nil, name: "Personal")
        // SHA-256("Personal"), first 16 hex digits.
        XCTAssertEqual(provisional, "profile:845f9286400f4269")
        XCTAssertTrue(YouTubeProfile(profileId: provisional, name: "Personal").isPlaceholder)
        XCTAssertFalse(YouTubeProfile(profileId: "SESSION_A", name: "Ada").isPlaceholder)
    }

    // MARK: - Persisted JSON

    func testRegistryRoundTripsThroughItsJSON() {
        let session = GoogleAccountSession(
            accountId: "acct",
            cookie: "SID=1; SAPISID=secret",
            name: "Ada",
            email: "ada@example.com",
            profiles: [
                YouTubeProfile(profileId: "SESSION_A", name: "Ada", handle: "@ada", avatar: "https://a", dataSyncId: "SESSION_A", authUser: "1"),
                YouTubeProfile(profileId: "113355", name: "Radio", pageId: "113355", dataSyncId: "113355", isBrandAccount: true),
            ],
            activeProfileId: "113355"
        )
        let decoded = YouTubeAccounts.decode(YouTubeAccounts.encode([session, b]))
        XCTAssertEqual(decoded, [session, b])
    }

    func testRegistryUsesAndroidsKeyNames() throws {
        let encoded = YouTubeAccounts.encode([GoogleAccountSession(
            accountId: "acct", cookie: "c", profiles: [YouTubeProfile(profileId: "p", name: "n", pageId: "pg", isBrandAccount: true)], activeProfileId: "p"
        )])
        let object = try XCTUnwrap(try InnerTubeJSON.parse(encoded).arrayValue?.first)
        XCTAssertEqual(object.s("id"), "acct")
        XCTAssertEqual(object.s("cookie"), "c")
        XCTAssertEqual(object.s("activeProfileId"), "p")
        let profile = try XCTUnwrap(object.a("profiles")?.first)
        XCTAssertEqual(profile.s("id"), "p")
        XCTAssertEqual(profile.s("pageId"), "pg")
        XCTAssertEqual(profile.s("brand"), "true")
    }

    func testDecodingIsLenient() {
        // Android's `optString` shapes: missing fields default, a missing profile id is the name
        // hash, blanks read as absent, and an entry with no cookie is dropped.
        let raw = #"""
        [{"cookie":"SAPISID=x","profiles":[{"name":"Personal","avatar":"","pageId":"","brand":false}]},
         {"id":"nocookie","cookie":""},
         {"id":"b","cookie":"k","activeProfileId":""}]
        """#
        let decoded = YouTubeAccounts.decode(raw)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].accountId, YouTubeAccounts.sessionId(cookie: "SAPISID=x", dataSyncId: nil))
        XCTAssertEqual(decoded[0].profiles.first?.profileId, YouTubeAccounts.profileId(pageId: nil, dataSyncId: nil, name: "Personal"))
        XCTAssertNil(decoded[0].profiles.first?.avatar)
        XCTAssertNil(decoded[0].profiles.first?.pageId)
        XCTAssertNil(decoded[1].activeProfileId)
        XCTAssertTrue(YouTubeAccounts.decode("not json").isEmpty)
        XCTAssertTrue(YouTubeAccounts.decode(nil).isEmpty)
        XCTAssertTrue(YouTubeAccounts.decode(#"{"an":"object"}"#).isEmpty)
    }

    // MARK: - Store

    func testStoreKeepsSessionsInTheCredentialStoreAndTracksTheActiveOne() throws {
        let credentials = InMemoryCredentialStore()
        let store = YouTubeAuthStore(credentials: credentials)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertFalse(store.isSignedIn)

        let signed = GoogleAccountSession(accountId: "a", cookie: "SID=1; __Secure-3PAPISID=s", profiles: [YouTubeProfile(profileId: "p", name: "P")], activeProfileId: "p")
        store.upsertSession(signed)
        XCTAssertEqual(store.activeAccountId, "a")
        XCTAssertEqual(store.activeProfileId, "p")
        XCTAssertTrue(store.isSignedIn)
        XCTAssertNotNil(try credentials.string(forKey: "google_account_sessions_v2"))

        // Adding without activating leaves the selection alone; the order is insertion order.
        store.upsertSession(b, activate: false)
        XCTAssertEqual(store.sessions.map(\.accountId), ["a", "b"])
        XCTAssertEqual(store.activeSession?.accountId, "a")

        // Replacing an entry keeps its place, so the profile selector's order is stable.
        var renamed = signed
        renamed.name = "Ada"
        store.upsertSession(renamed, activate: false)
        XCTAssertEqual(store.sessions.map(\.accountId), ["a", "b"])
        XCTAssertEqual(store.sessions.first?.name, "Ada")

        // A fresh store over the same Keychain sees the same registry.
        XCTAssertEqual(YouTubeAuthStore(credentials: credentials).sessions.map(\.accountId), ["a", "b"])
    }

    func testRemovingTheActiveAccountFallsBackToTheFirstRemaining() {
        let store = YouTubeAuthStore(credentials: InMemoryCredentialStore())
        store.upsertSession(a)
        store.upsertSession(GoogleAccountSession(accountId: "b", cookie: "cookie-b", profiles: b.profiles, activeProfileId: "b-brand"))
        XCTAssertEqual(store.activeAccountId, "b")
        let fallback = store.removeAccount("b")
        XCTAssertEqual(fallback?.accountId, "a")
        XCTAssertEqual(store.activeAccountId, "a")
        XCTAssertNil(store.removeAccount("a"))
        XCTAssertNil(store.activeAccountId)
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testActiveSessionFallsBackToTheFirstWhenNothingIsSelected() {
        let store = YouTubeAuthStore(credentials: InMemoryCredentialStore())
        store.replaceSessions([a, b])
        XCTAssertNil(store.activeAccountId)
        XCTAssertEqual(store.activeSession?.accountId, "a")
        // "cookie-a" carries no signing secret, so the app is not signed in on it.
        XCTAssertFalse(store.isSignedIn)
    }

    func testSignOutForgetsEverything() {
        let store = YouTubeAuthStore(credentials: InMemoryCredentialStore())
        store.upsertSession(a)
        store.signOut()
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(store.activeAccountId)
        XCTAssertNil(store.activeProfileId)
    }
}
