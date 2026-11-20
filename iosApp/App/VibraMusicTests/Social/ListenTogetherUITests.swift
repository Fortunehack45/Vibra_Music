import VibraMusicCore
import ListenTogether
import SwiftUI
import XCTest
@testable import Vibra Music

/// Listen Together (PORTING.md §2.9): create or join with a 6-character code, a QR code or a link;
/// the host locks controls, removes people and sets the size; a custom server.
@MainActor
final class ListenTogetherFlowTests: XCTestCase {
    private func model(_ service: FakePartyService) -> ListenTogetherModel {
        let model = ListenTogetherModel(service: service)
        model.inviteDelay = .zero
        model.sheetDismissDelay = .zero
        return model
    }

    func testATypedCodeIsLettersAndDigitsUpperCasedAndSixLong() {
        let model = model(FakePartyService())
        model.failure = "No party with that code"
        model.setCode("ab-c 12x9z")
        XCTAssertEqual(model.codeInput, "ABC12X")
        XCTAssertNil(model.failure, "typing is the retry")
    }

    func testJoiningByCodeLooksThePartyUpFirstThenJoinsFromTheConfirmSheet() async {
        let service = FakePartyService()
        let model = model(service)
        model.openJoin()
        model.setCode("abc12")
        await model.submitCode()
        XCTAssertTrue(service.previews.isEmpty, "five characters are not a code")

        model.setCode("abc123")
        await model.submitCode()
        XCTAssertEqual(service.previews.first?.code, "ABC123")
        guard case .confirm(let preview, let server)? = model.sheet else { return XCTFail("expected the confirm sheet") }
        XCTAssertNil(server)
        XCTAssertTrue(service.joins.isEmpty, "a preview is not a join")

        await model.confirmJoin(preview, server: server)
        XCTAssertEqual(service.joins, ["ABC123"])
        XCTAssertNil(model.sheet)
        XCTAssertEqual(model.codeInput, "")
        XCTAssertTrue(model.inParty)
    }

    func testARefusedJoinStaysInTheSheetThatAskedAndLeavesWithIt() async {
        let service = FakePartyService()
        service.joinResult = .failure(PartyClientError(code: "party_full", message: "That party is full."))
        let model = model(service)
        await model.openPartyPreview(code: "ABC123", server: nil)
        guard case .confirm(let preview, _)? = model.sheet else { return XCTFail() }
        await model.confirmJoin(preview, server: nil)
        XCTAssertEqual(model.failure, "That party is full.")
        XCTAssertNotNil(model.sheet)
        XCTAssertNil(model.pageError, "a sheet shows its own failure, not the page under it")
        model.sheetDismissed()
        XCTAssertNil(model.pageError)
    }

    func testCreatingAPartyHandsTheCreateSheetOverToTheInvite() async {
        let service = FakePartyService()
        let model = model(service)
        model.openCreate()
        model.setNewPartySize(12)
        XCTAssertEqual(model.maxMembers, 10)
        model.setNewPartySize(1)
        XCTAssertEqual(model.maxMembers, 2)
        model.setNewPartySize(4)
        await model.createParty()
        XCTAssertEqual(service.creates, [4])
        XCTAssertEqual(model.sheet, .invite)
        XCTAssertEqual(model.state.code, "NEW123")
        XCTAssertEqual(model.shareMessage, "https://vibramusic.kushagrasingh.in/invite/NEW123\n\n" + L10n.listenTogetherShareText("NEW123"))
    }

    func testAnInviteLinkOpensTheConfirmSheetWithoutJoining() async {
        let service = FakePartyService()
        let model = model(service)
        let consumed = await model.handleInvite(code: "ABC123", server: nil)
        XCTAssertTrue(consumed)
        XCTAssertEqual(service.previews.first?.code, "ABC123")
        XCTAssertTrue(service.joins.isEmpty)
        if case .confirm? = model.sheet {} else { XCTFail("expected the confirm sheet") }
    }

    func testAnInviteHandedOverTwiceAtOnceIsLookedUpOnce() async {
        // The page hands an invite over on appearing and again when the router's value changes;
        // both can be in flight before either has raised `busy`.
        let service = FakePartyService()
        service.lookupDelay = .milliseconds(50)
        let model = model(service)
        async let first = model.handleInvite(code: "ABC123", server: nil)
        async let second = model.handleInvite(code: "ABC123", server: nil)
        let taken = await [first, second]
        XCTAssertEqual(taken.filter { $0 }.count, 1, "one of the two takes the invite")
        XCTAssertEqual(service.previews.count, 1, "the party is looked up once")
        if case .confirm? = model.sheet {} else { XCTFail("expected the confirm sheet") }
        // Once the first is done, a later invite is taken as usual.
        model.sheetDismissed()
        let later = await model.handleInvite(code: "XYZ789", server: nil)
        XCTAssertTrue(later)
        XCTAssertEqual(service.previews.count, 2)
    }

    func testAnInviteArrivingWhileALookupRunsIsTakenWhenItEnds() async {
        let service = FakePartyService()
        service.previewDelay = .milliseconds(80)
        let model = model(service)
        let lookup = Task { await model.openPartyPreview(code: "ABC123", server: nil) }
        await waitUntil("the lookup is running") { model.busy }

        let taken = await model.handleInvite(code: "XYZ789", server: nil)
        XCTAssertTrue(taken, "the page can let go of it: the model holds it")

        await lookup.value
        await waitUntil("the held invite is looked up") { service.previews.count == 2 }
        XCTAssertEqual(service.previews.last?.code, "XYZ789")
    }

    func testASignedOutDeviceKeepsTheInviteWaitingWithTheCodeFilledIn() async {
        let service = FakePartyService()
        service.signedIn = false
        let model = model(service)
        let consumed = await model.handleInvite(code: "ABC123", server: nil)
        XCTAssertFalse(consumed)
        XCTAssertEqual(model.codeInput, "ABC123")
        XCTAssertTrue(service.previews.isEmpty)
    }

    func testAnInviteOnAnotherServerAsksFirstAndThenJoinsThere() async {
        let service = FakePartyService()
        let model = model(service)
        await model.handleInvite(code: "ABC123", server: "https://party.friend.example/")
        XCTAssertEqual(model.pendingServerSwitch, PendingServerSwitch(code: "ABC123", server: "https://party.friend.example"))
        XCTAssertTrue(service.previews.isEmpty, "consent comes before talking to another server")

        await model.acceptServerSwitch()
        XCTAssertEqual(service.previews.first?.server, "https://party.friend.example")
        guard case .confirm(let preview, let server)? = model.sheet else { return XCTFail() }
        await model.confirmJoin(preview, server: server)
        XCTAssertEqual(service.switches.first?.server, "https://party.friend.example", "the server named on the invite wins")
        XCTAssertTrue(service.joins.isEmpty)
    }

    func testAnOfficialInviteWhileOnACustomServerAsksToSwitchBack() async {
        let service = FakePartyService()
        service.customServer = "https://mine.example"
        service.idle = "https://mine.example"
        let model = model(service)
        await model.handleInvite(code: "ABC123", server: nil)
        XCTAssertEqual(model.pendingServerSwitch?.isSwitchToOfficial, true)
        model.declineServerSwitch()
        XCTAssertNil(model.pendingServerSwitch)
        XCTAssertTrue(service.previews.isEmpty)
    }

    func testJoiningWhileInAPartyIsASwitchThatKeepsThisPartyOnRefusal() async {
        let service = FakePartyService()
        service.state = FakePartyService.party(code: "OLD111", host: false)
        service.switchResult = .targetFailedRecovered(partyCode: "OLD111", targetError: "No party with that code")
        let model = model(service)
        await model.openPartyPreview(code: "ABC123", server: nil)
        guard case .confirm(let preview, _)? = model.sheet else { return XCTFail() }
        await model.confirmJoin(preview, server: nil)
        XCTAssertEqual(service.switches.first?.server, service.idle)
        XCTAssertEqual(model.failure, "No party with that code")
        XCTAssertEqual(model.state.code, "OLD111")
    }

    func testTheHostSetsTheSizeWithinItsBoundsLocksControlsAndRemovesPeople() {
        let service = FakePartyService()
        service.state = FakePartyService.party(code: "ABC123", host: true, members: 3)
        service.state.maxMembers = 3
        let model = model(service)
        XCTAssertTrue(model.isHost)
        XCTAssertFalse(model.canShrinkParty, "never below the people already in")
        XCTAssertTrue(model.canGrowParty)
        model.setPartySize(4)
        model.setHostOnlyControl(true)
        model.kick(service.state.members[2])
        XCTAssertEqual(service.sizes, [4])
        XCTAssertEqual(service.hostOnly, [true])
        XCTAssertEqual(service.kicked, ["m2"])

        service.state.maxMembers = 10
        XCTAssertFalse(model.canGrowParty)
    }

    func testTheInviteLinkPointsAtTheServerHoldingTheParty() async {
        let service = FakePartyService()
        let model = model(service)
        XCTAssertEqual(model.inviteLink(for: "ABC123"), "https://vibramusic.kushagrasingh.in/invite/ABC123")
        service.active = "https://party.friend.example"
        await model.refreshServer()
        XCTAssertEqual(model.inviteLink(for: "ABC123"), "https://party.friend.example/invite/ABC123")
    }

    func testLeavingEndsThePartyOnThisDevice() async {
        let service = FakePartyService()
        service.state = FakePartyService.party(code: "ABC123", host: false)
        let model = model(service)
        await model.leave()
        XCTAssertEqual(service.left, 1)
        XCTAssertFalse(model.inParty)
    }

    func testTheNowPlayingLineAndTheActivityLog() {
        var state = FakePartyService.party(code: "ABC123", host: true)
        XCTAssertEqual(PartyText.nowPlayingSubtitle(state, positionMs: 0), L10n.listenTogetherInSync(12))
        state.playback.track = PartyTrack(videoId: "v", title: "Song", artist: "Artist", durationMs: 200_000)
        XCTAssertEqual(PartyText.nowPlayingSubtitle(state, positionMs: 61_500), "Artist · 1:01 / 3:20\n" + L10n.listenTogetherInSync(12))
        state.connection = .connecting
        XCTAssertTrue(PartyText.nowPlayingSubtitle(state, positionMs: 0).hasSuffix(L10n.listenTogetherReconnecting))

        let entry = PartyActivity(action: "skip", by: "Sam", atMs: 3_723_000, detail: "")
        XCTAssertEqual(PartyText.activityLine(entry, timeZone: TimeZone(identifier: "UTC")!), "[01:02:03] Sam: skip")
    }

    func testTheMembersDrawerSaysWhoIsHostYouAndAway() {
        let host = PartyMember(memberId: "a", displayName: "A", isHost: true, connected: true)
        let away = PartyMember(memberId: "b", displayName: "B", connected: false)
        XCTAssertEqual(PartyMembersDrawer.subtitle(for: host, isYou: true), L10n.listenTogetherHost)
        XCTAssertEqual(PartyMembersDrawer.subtitle(for: away, isYou: true), L10n.listenTogetherYou)
        XCTAssertEqual(PartyMembersDrawer.subtitle(for: away, isYou: false), L10n.listenTogetherAway)
        XCTAssertEqual(PartyMembersDrawer.subtitle(for: host, isYou: false), L10n.listenTogetherHost)
    }

    func testTheInviteQRCodeDrawsOneDotPerDarkModule() throws {
        let matrix = try XCTUnwrap(PartyInviteQRMatrix.make(content: "https://vibramusic.kushagrasingh.in/invite/ABC123"))
        let rects = PartyQRModules.moduleRects(matrix, side: 132)
        XCTAssertEqual(rects.count, matrix.darkModuleCount)
        let cell = 132 / CGFloat(matrix.dimension)
        XCTAssertEqual(rects[0].width, cell * 0.86, accuracy: 0.001, "dots are smaller than their cells so a rounded code still scans")
        XCTAssertTrue(rects.allSatisfy { $0.maxX <= 132 && $0.maxY <= 132 })
    }
}

/// The custom server editor (PartyServerEditor.kt).
@MainActor
final class PartyServerEditorTests: XCTestCase {
    func testABadAddressIsExplainedInTheCardAndNotSaved() async {
        let service = FakePartyService()
        let editor = PartyServerEditorModel(service: service)
        editor.input = "ftp://party.example.com"
        let closed = await editor.save()
        XCTAssertTrue(closed == nil, "the card stays open")
        XCTAssertEqual(editor.status?.message, L10n.listenTogetherInvalidServerUrl)
        XCTAssertEqual(editor.status?.good, false)
        XCTAssertTrue(service.savedServers.isEmpty)
        editor.input = "https://party.example.com"
        XCTAssertNil(editor.status, "a result describes the address it was run against")
    }

    func testTestSaysWhetherTheServerAnswersAndSaveStoresIt() async {
        let service = FakePartyService()
        let editor = PartyServerEditorModel(service: service)
        editor.input = "https://party.example.com"
        await editor.test()
        XCTAssertEqual(editor.status?.message, L10n.listenTogetherServerOnline(33))
        XCTAssertEqual(editor.status?.good, true)
        service.probeResult = PartyProbeResult(isOnline: false)
        await editor.test()
        XCTAssertEqual(editor.status?.message, L10n.listenTogetherServerOffline)

        let toast = await editor.save()
        XCTAssertEqual(toast, .some(L10n.listenTogetherCustomServerConnected))
        XCTAssertEqual(service.savedServers, ["https://party.example.com"])
    }

    func testRemoveIsOfferedOnlyForAStoredServerOutsideAParty() async {
        let service = FakePartyService()
        XCTAssertFalse(PartyServerEditorModel(service: service).canRemove)
        service.customServer = "https://mine.example"
        XCTAssertTrue(PartyServerEditorModel(service: service).canRemove)
        service.state = FakePartyService.party(code: "ABC123", host: true)
        XCTAssertFalse(PartyServerEditorModel(service: service).canRemove, "never under a live membership")
        service.state = PartySessionState()
        let toast = await PartyServerEditorModel(service: service).remove()
        XCTAssertEqual(toast, L10n.listenTogetherSwitchedToDefault)
        XCTAssertEqual(service.savedServers, [""])
    }
}

/// Render smoke tests: each Listen Together surface hosted in a window and laid out.
@MainActor
final class ListenTogetherRenderTests: XCTestCase {
    func testTheLandingAndThePartyPageRender() {
        let app = makeSocialApp()
        let landing = FakePartyService()
        assertSocialRendered(hostSocial(NavigationStack { ListenTogetherPage(service: landing) }.socialEnvironment(app)))

        let signedOut = FakePartyService()
        signedOut.signedIn = false
        assertSocialRendered(hostSocial(NavigationStack { ListenTogetherPage(service: signedOut) }.socialEnvironment(app)))

        let host = FakePartyService()
        host.state = FakePartyService.party(code: "ABC123", host: true, members: 3)
        host.activity = [PartyActivity(action: "skip", by: "B", atMs: 0)]
        assertSocialRendered(hostSocial(NavigationStack { ListenTogetherPage(service: host) }.socialEnvironment(app)
            .environment(\.layoutDirection, .rightToLeft).environment(\.dynamicTypeSize, .accessibility2)))
    }

    func testTheSheetsTheEditorAndTheMembersDrawerRender() {
        let app = makeSocialApp()
        let service = FakePartyService()
        service.state = FakePartyService.party(code: "ABC123", host: true)
        let model = ListenTogetherModel(service: service)
        assertSocialRendered(hostSocial(CreatePartySheet(model: model).socialEnvironment(app)))
        assertSocialRendered(hostSocial(JoinPartySheet(model: model).socialEnvironment(app)))
        let preview = PartyPreview(code: "ABC123", hostName: "Host", memberCount: 6, maxMembers: 10,
                                   members: [PartyPreviewMember(displayName: "A"), PartyPreviewMember(displayName: "B")])
        assertSocialRendered(hostSocial(JoinConfirmSheet(model: model, preview: preview, server: nil).socialEnvironment(app)))
        assertSocialRendered(hostSocial(InviteSheet(code: "ABC123", link: "https://vibramusic.kushagrasingh.in/invite/ABC123",
                                                    shareMessage: "hi", onCopyCode: {}).socialEnvironment(app)))
        assertSocialRendered(hostSocial(PartyServerEditor(service: service) { _ in }.socialEnvironment(app)))
        assertSocialRendered(hostSocial(PartyMembersDrawer(session: service.state) {}.socialEnvironment(app)))
    }
}
