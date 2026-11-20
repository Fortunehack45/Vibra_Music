import VibraMusicCore
import InnerTube
import SwiftUI
import XCTest
@testable import Vibra Music

/// PORTING §2.2 "Multiple accounts and profiles": the selector lists every login's Personal and
/// Brand profiles; switching, swiping the avatar, removing an account and signing out move the
/// identity requests act as — which is what Home and Library reload on (their `listenerKey`).
@MainActor
final class ProfileSwitchingTests: XCTestCase {
    func testSwitchingProfileChangesTheListenerHomeAndLibraryReloadFor() async {
        let manager = await makeAccountTestManager()
        var changes: [YouTubeIdentityChange] = []
        manager.onIdentityChange = { changes.append($0) }
        XCTAssertEqual(manager.listenerKey, "acct-a:p-personal")

        await manager.selectProfile(accountId: "acct-a", profileId: "p-brand")
        XCTAssertEqual(manager.listenerKey, "acct-a:p-brand")
        XCTAssertEqual(manager.selectedChannelName, "Night Drive")
        XCTAssertEqual(changes, [.profileSelected(YouTubeProfileRef(accountId: "acct-a", profileId: "p-brand"))])
    }

    func testSwipingTheAvatarStepsThroughProfilesAndStopsAtTheEnds() async {
        // Down is forward, up is back; a short drag is no swipe.
        XCTAssertEqual(AvatarSwipe.direction(forVerticalDrag: 40), true)
        XCTAssertEqual(AvatarSwipe.direction(forVerticalDrag: -40), false)
        XCTAssertNil(AvatarSwipe.direction(forVerticalDrag: 20))
        XCTAssertEqual(AvatarSwipe.edgeNudge(forward: true), 9)

        let manager = await makeAccountTestManager()
        let backAtStart = await manager.stepProfile(forward: false)
        XCTAssertFalse(backAtStart, "the first profile has nothing before it")
        let first = await manager.stepProfile(forward: true)
        XCTAssertTrue(first)
        XCTAssertEqual(manager.listenerKey, "acct-a:p-brand")
        let second = await manager.stepProfile(forward: true)
        XCTAssertTrue(second, "swiping crosses into the next Google account")
        XCTAssertEqual(manager.listenerKey, "acct-b:p-work")
        let pastEnd = await manager.stepProfile(forward: true)
        XCTAssertFalse(pastEnd)
    }

    func testRemovingAnAccountFallsBackToTheOtherAndSigningOutTheLastSignsOut() async {
        let manager = await makeAccountTestManager()
        await manager.removeAccount("acct-a")
        XCTAssertEqual(manager.accounts.map(\.accountId), ["acct-b"])
        XCTAssertEqual(manager.listenerKey, "acct-b:p-work")
        XCTAssertTrue(manager.isSignedIn)

        await manager.signOut()
        XCTAssertFalse(manager.isSignedIn)
        XCTAssertNil(manager.listenerKey)
    }

    func testTheSelectorLabelsAccountsAndProfilesWithFallbacks() {
        let sessions = makeAccountTestSessions()
        XCTAssertEqual(ProfileSelectorText.accountHeading(sessions[0]), "maya@example.com")
        XCTAssertEqual(ProfileSelectorText.accountHeading(sessions[1]), "Maya Work", "no email: the name")
        XCTAssertEqual(ProfileSelectorText.accountHeading(GoogleAccountSession(accountId: "x", cookie: "")), L10n.accounts)
        XCTAssertEqual(ProfileSelectorText.profileSubtitle(sessions[0].profiles[0]), "@maya")
        XCTAssertEqual(ProfileSelectorText.profileSubtitle(sessions[0].profiles[1]), L10n.brandAccount)
        XCTAssertEqual(ProfileSelectorText.profileSubtitle(sessions[1].profiles[0]), L10n.personal)
    }

    /// The avatar, Download and History items are Android's: none under Settings or the account
    /// page, History only on Library's own page.
    func testTheTopBarItemsShowWhereAndroidShowsThem() {
        let library = TopBarPlacement(tab: .library, route: nil, path: [])
        XCTAssertTrue(library.showsItems)
        XCTAssertTrue(library.showsHistory)
        XCTAssertFalse(TopBarPlacement(tab: .home, route: nil, path: []).showsHistory)
        let album = AppRoute.album(browseId: "MPREb_1", seed: nil)
        XCTAssertTrue(TopBarPlacement(tab: .library, route: album, path: [album]).showsItems)
        XCTAssertFalse(TopBarPlacement(tab: .library, route: album, path: [album]).showsHistory)
        XCTAssertFalse(TopBarPlacement(tab: .home, route: .settings, path: [.settings]).showsItems)
        XCTAssertFalse(TopBarPlacement(tab: .home, route: .discord, path: [.settings, .account, .discord]).showsItems)
    }

    /// Android's bar has the sort left of the photo, on album and playlist pages and "Show all" grids.
    func testTheSortButtonIsTheBarsOnAlbumsPlaylistsAndShowAllOnly() {
        func sort(_ route: AppRoute, path: [AppRoute]? = nil) -> TopBarPlacement.SortButton? {
            TopBarPlacement(tab: .library, route: route, path: path ?? [route]).sortButton
        }
        XCTAssertEqual(sort(.album(browseId: "MPREb_1", seed: nil)), .songs(browseId: "MPREb_1"))
        XCTAssertEqual(sort(.playlist(browseId: "VL1", seed: nil)), .songs(browseId: "VL1"))
        let local = LocalBrowseID.playlistPrefix + "1"
        XCTAssertEqual(sort(.playlist(browseId: local, seed: nil)), .songs(browseId: local))
        XCTAssertEqual(sort(.libraryShowAll(browseId: "x", title: "Albums")), .library)
        XCTAssertNil(sort(.settings))
        XCTAssertNil(TopBarPlacement(tab: .library, route: nil, path: []).sortButton)
        let album = AppRoute.album(browseId: "MPREb_1", seed: nil)
        XCTAssertNil(sort(album, path: [.settings, album]), "nothing shows under Settings")
    }

    /// Android's selector "Settings" row sets `showSettings = true`, which is a no-op when Settings is
    /// already open under the account page (the page stays), so it must not push a second Settings.
    func testTheSelectorsSettingsRowDoesNotStackSettingsOnSettings() {
        let router = AppRouter()
        router.present(.profileSwitcher)
        router.setPath([.settings, .account], for: router.selectedTab)
        ProfileSwitcher.openSettings(router)
        XCTAssertNil(router.sheet)
        XCTAssertEqual(router.path(for: router.selectedTab), [.settings, .account])

        router.setPath([], for: router.selectedTab)
        ProfileSwitcher.openSettings(router)
        XCTAssertEqual(router.path(for: router.selectedTab), [.settings], "from anywhere else it opens Settings")
    }

    func testTheSelectorRendersInBothModes() {
        let sessions = makeAccountTestSessions()
        let selector = AccountProfileSelector(accounts: sessions, activeAccountId: "acct-a", activeProfileId: "p-personal",
                                              onSelect: { _, _ in }, onAddAccount: {}, onRemoveAccount: { _ in },
                                              onOpenSettings: {})
        accountHostAndLayOut(selector)
        let app = makeAccountTestApp()
        accountHostAndLayOut(ProfileSwitcher().accountTestEnvironment(app))
        accountHostAndLayOut(NavigationStack {
            Text("Library").appTopBar(TopBarPlacement(tab: .library, route: nil, path: []))
        }.accountTestEnvironment(app))
    }
}
