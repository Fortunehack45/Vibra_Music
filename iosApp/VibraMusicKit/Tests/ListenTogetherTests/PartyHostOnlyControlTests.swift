import XCTest
@testable import ListenTogether

/// Ports `PartyHostOnlyControlTest`: what "only the host controls the music" means on this
/// side of the wire. Enforcement is the server's (`backend/party.MayControl`); what is
/// pinned here is the derivation every player surface reads, and the compatibility cases
/// that decide locked-or-not when the answer is missing.
final class PartyHostOnlyControlTests: XCTestCase {
    private func member(_ id: String, host: Bool) -> PartyMember {
        PartyMember(memberId: id, displayName: id, isHost: host)
    }

    private func state(
        code: String? = "ABC123",
        you: PartyMember? = PartyMember(memberId: "me", displayName: "me"),
        hostOnly: Bool = false
    ) -> PartySessionState {
        PartySessionState(
            code: code, you: you,
            members: [you].compactMap { $0 },
            hostOnlyControl: hostOnly)
    }

    func testListenerIsLockedOutWhileHostHoldsControls() {
        XCTAssertTrue(state(hostOnly: true).controlsLocked)
    }

    func testHostIsNeverLockedOutOfOwnParty() {
        XCTAssertFalse(state(you: member("me", host: true), hostOnly: true).controlsLocked)
    }

    func testOpenPartyLocksNobody() {
        XCTAssertFalse(state(hostOnly: false).controlsLocked)
    }

    func testNoPartyIsNotALockedParty() {
        // The setting is meaningless outside a party; a stale true here would silently
        // disable the transport for somebody listening alone.
        XCTAssertFalse(state(code: nil, hostOnly: true).controlsLocked)
    }

    func testPromotionToHostUnlocksControls() {
        // The server hands the role to an arbitrary survivor when a host leaves, announced
        // only by reissuing the member list.
        XCTAssertTrue(state(hostOnly: true).controlsLocked)
        XCTAssertFalse(state(you: member("me", host: true), hostOnly: true).controlsLocked)
    }

    func testSnapshotWithoutSettingReadsAsUnlocked() throws {
        // Old server, new app: the field is simply absent, and the party has to behave
        // exactly as it did before the feature existed.
        let snapshot = try JSONDecoder().decode(
            PartySnapshot.self,
            from: #"{"code":"ABC123","maxMembers":5,"members":[]}"#.data(using: .utf8)!)
        XCTAssertFalse(snapshot.hostOnlyControl)
    }

    func testSnapshotCarryingSettingKeepsIt() throws {
        let snapshot = try JSONDecoder().decode(
            PartySnapshot.self,
            from: #"{"code":"ABC123","maxMembers":5,"hostOnlyControl":true,"members":[]}"#.data(using: .utf8)!)
        XCTAssertTrue(snapshot.hostOnlyControl)
        XCTAssertEqual("ABC123", snapshot.code)
    }

    func testControlPolicyMirrorsServer() {
        // Playback and queue actions are refused from listeners while locked…
        XCTAssertTrue(PartyControlPolicy.isRefusedFromListener(.play, hostOnlyControl: true))
        XCTAssertTrue(PartyControlPolicy.isRefusedFromListener(.queueMove, hostOnlyControl: true))
        XCTAssertTrue(PartyControlPolicy.isRefusedFromListener(.setAutoplay, hostOnlyControl: true))
        // …but not in an open party…
        XCTAssertFalse(PartyControlPolicy.isRefusedFromListener(.play, hostOnlyControl: false))
        // …and kick/setMaxMembers are host-only regardless of the lock.
        XCTAssertTrue(PartyControlPolicy.isRefusedFromListener(.kick, hostOnlyControl: false))
        XCTAssertTrue(PartyControlPolicy.isRefusedFromListener(.setMaxMembers, hostOnlyControl: false))
    }
}
