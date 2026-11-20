import XCTest
import VibraMusicCore
@testable import PlaybackQueue

/// Ports PartyAutoplayTest: the two questions AutoPlay asks before it does anything in a party —
/// whether it is on at all, and whose job it is to top the queue up.
final class PartyAutoplayTests: XCTestCase {

    private typealias Member = AutoplayPartyContext.Member

    private func member(_ id: String, host: Bool = false, connected: Bool = true) -> Member {
        Member(memberId: id, isHost: host, connected: connected)
    }

    private func party(
        _ members: [Member],
        you: Member? = nil,
        partyAutoplay: Bool = true,
        hostOnly: Bool = false,
        code: String? = "ABC123"
    ) -> AutoplayPartyContext {
        AutoplayPartyContext(
            code: code,
            yourMemberId: (you ?? members.first)?.memberId,
            members: members,
            partyAutoplayEnabled: partyAutoplay,
            hostOnlyControl: hostOnly
        )
    }

    // MARK: enabled

    func testAloneAutoplayIsThisPhonesOwnSetting() {
        XCTAssertTrue(AutoplayPolicy.isEnabled(party: .solo, localPreference: true))
        XCTAssertFalse(AutoplayPolicy.isEnabled(party: .solo, localPreference: false))
    }

    func testInAPartyThePartysSettingWinsOverThePhones() {
        // A listener whose own switch is on, in a party with AutoPlay off: nothing is queued, so
        // the toggle must not draw as on.
        let off = party([member("a", host: true)], partyAutoplay: false)
        XCTAssertFalse(AutoplayPolicy.isEnabled(party: off, localPreference: true))
        // And the other direction: tracks keep coming for a listener whose own switch is off.
        let on = party([member("a", host: true)], partyAutoplay: true)
        XCTAssertTrue(AutoplayPolicy.isEnabled(party: on, localPreference: false))
    }

    // MARK: supplier

    func testNobodySuppliesOutsideAParty() {
        XCTAssertNil(AutoplayPolicy.supplierId(party: .solo))
    }

    func testTheHostSuppliesWhileItIsConnected() {
        XCTAssertEqual(AutoplayPolicy.supplierId(party: party([member("zz", host: true), member("aa")])), "zz")
    }

    func testAnOfflineHostHandsOverToTheLowestConnectedMember() {
        let state = party([member("zz", host: true, connected: false), member("mm"), member("aa")])
        XCTAssertEqual(AutoplayPolicy.supplierId(party: state), "aa")
    }

    func testEveryDeviceElectsTheSameSupplier() {
        let members = [member("zz", host: true, connected: false), member("mm"), member("aa")]
        let answers = [members, members.reversed(), [members[1], members[2], members[0]]]
            .map { AutoplayPolicy.supplierId(party: party($0)) }
        XCTAssertEqual(answers, ["aa", "aa", "aa"])
    }

    func testALockedPartyHasNoStandInSupplier() {
        let state = party([member("zz", host: true, connected: false), member("aa")], hostOnly: true)
        XCTAssertNil(AutoplayPolicy.supplierId(party: state))
    }

    func testALockedPartyStillSuppliesThroughItsOwnHost() {
        XCTAssertEqual(AutoplayPolicy.supplierId(party: party([member("zz", host: true), member("aa")], hostOnly: true)), "zz")
    }

    func testAPartyWithNobodyConnectedSuppliesNothing() {
        let state = party([member("zz", host: true, connected: false), member("aa", connected: false)])
        XCTAssertNil(AutoplayPolicy.supplierId(party: state))
    }

    // MARK: Through the controller

    @MainActor
    func testTheElectedSupplierSendsAutoplayToThePartyNotItsOwnQueue() async {
        let radio = FakeRadioSource()
        radio.setStation("now", station("r", count: 3))
        let controller = PlaybackQueueController(settings: makeSettings(autoplay: false), radioSource: radio)
        var offered: [[Song]] = []
        controller.partyAutoplaySupplier = { songs in
            offered.append(songs)
            return true
        }
        controller.party = party([member("me", host: true), member("other")])
        controller.setItems([testSong("now")], startIndex: 0)
        await controller.waitForAutoplay()

        XCTAssertEqual(offered.count, 1)
        XCTAssertEqual(offered.first?.map(\.videoId), ["r1", "r2", "r3"])
        XCTAssertTrue(offered.first?.allSatisfy { $0.queueTier == .autoplay } ?? false)
        XCTAssertEqual(controller.state.ids, ["now"], "the party's broadcast adds them, not this device")
    }

    @MainActor
    func testANonSupplierLeavesAutoplayToTheElectedMember() async {
        let radio = FakeRadioSource()
        radio.setStation("now", station("r", count: 3))
        let controller = PlaybackQueueController(settings: makeSettings(), radioSource: radio)
        var offered = 0
        controller.partyAutoplaySupplier = { _ in offered += 1; return true }
        controller.party = party([member("host", host: true), member("me")], you: member("me"))
        controller.setItems([testSong("now")], startIndex: 0)
        await controller.waitForAutoplay()
        XCTAssertEqual(offered, 0)
        XCTAssertTrue(radio.requests.isEmpty)
    }

    @MainActor
    func testARefusedPartyTopUpReleasesTheSeedSoItCanRetry() async {
        let radio = FakeRadioSource()
        radio.setStation("now", station("r", count: 2))
        let controller = PlaybackQueueController(settings: makeSettings(), radioSource: radio)
        var accept = false
        var offers = 0
        controller.partyAutoplaySupplier = { _ in offers += 1; return accept }
        controller.party = party([member("me", host: true)])
        controller.setItems([testSong("now")], startIndex: 0)
        await controller.waitForAutoplay()
        XCTAssertEqual(offers, 1)

        // Any later edit re-arms it because the seed was released, not latched.
        accept = true
        controller.insertItems([testSong("x", tier: .userQueue)], at: 0)
        await controller.waitForAutoplay()
        XCTAssertEqual(offers, 2)
    }

    @MainActor
    func testBecomingTheSupplierStartsTopingUp() async {
        let radio = FakeRadioSource()
        radio.setStation("now", station("r", count: 2))
        let controller = PlaybackQueueController(settings: makeSettings(), radioSource: radio)
        var offers = 0
        controller.partyAutoplaySupplier = { _ in offers += 1; return true }
        controller.party = party([member("host", host: true), member("me")], you: member("me"))
        controller.setItems([testSong("now")], startIndex: 0)
        await controller.waitForAutoplay()
        XCTAssertEqual(offers, 0)

        // The host drops off; "me" is now the lowest connected member.
        controller.party = party([member("host", host: true, connected: false), member("me")], you: member("me"))
        await controller.waitForAutoplay()
        XCTAssertEqual(offers, 1)
    }

    /// Nobody elected (the only members are offline) and this device doesn't know its own member id
    /// yet: two unknowns are not a match, so it must not start supplying.
    @MainActor
    func testADeviceThatDoesntKnowItsIdNeverSuppliesForAPartyThatElectedNobody() async {
        let radio = FakeRadioSource()
        radio.setStation("now", station("r", count: 2))
        let controller = PlaybackQueueController(settings: makeSettings(), radioSource: radio)
        var offers = 0
        controller.partyAutoplaySupplier = { _ in offers += 1; return true }
        var nobody = party([member("host", host: true, connected: false), member("other", connected: false)])
        nobody.yourMemberId = nil
        XCTAssertNil(AutoplayPolicy.supplierId(party: nobody))
        controller.party = nobody
        controller.setItems([testSong("now")], startIndex: 0)
        await controller.waitForAutoplay()
        XCTAssertEqual(offers, 0)
        XCTAssertTrue(radio.requests.isEmpty)
    }

    @MainActor
    func testTheToggleInAPartyFlipsThePartysSwitch() {
        let settings = makeSettings(autoplay: true)
        let controller = PlaybackQueueController(settings: settings)
        var forwarded: [Bool] = []
        controller.partyAutoplayToggle = { forwarded.append($0) }
        controller.party = party([member("me", host: true)], partyAutoplay: false)
        XCTAssertFalse(controller.isAutoplayEnabled, "the party's switch, not the phone's")
        controller.toggleAutoplay()
        XCTAssertEqual(forwarded, [true])
    }
}
