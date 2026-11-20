import VibraMusicCore
import PlaybackQueue
import StreamResolution
import SwiftUI
import XCTest
@testable import VibraMusic

/// Deep links (PORTING.md "Deep links and sharing into the app"): each link lands on its screen.
@MainActor
final class DeepLinkRoutingTests: XCTestCase {
    func testAYouTubeMusicAlbumLinkOpensThatAlbum() throws {
        let url = try XCTUnwrap(URL(string: "https://music.youtube.com/browse/MPREb_4pL8gzRtw1p"))
        let link = try XCTUnwrap(DeepLink.parse(url))
        XCTAssertEqual(link, .page(browseId: "MPREb_4pL8gzRtw1p"))

        let router = AppRouter()
        router.handle(link, player: nil) { _ in nil }
        XCTAssertEqual(router.path(for: router.selectedTab).last, .album(browseId: "MPREb_4pL8gzRtw1p", seed: nil))
    }

    func testAnAlbumsShareLinkThroughItsPlaylistIdAlsoOpensAnAlbum() throws {
        let url = try XCTUnwrap(URL(string: "https://music.youtube.com/playlist?list=OLAK5uy_nfQzzqXOaZhe8S7w0dLlKT1_Jmf8Ci8Yc&si=abc"))
        let router = AppRouter()
        router.handle(try XCTUnwrap(DeepLink.parse(url)), player: nil) { _ in nil }
        XCTAssertEqual(router.path(for: .home).last, .album(browseId: "VLOLAK5uy_nfQzzqXOaZhe8S7w0dLlKT1_Jmf8Ci8Yc", seed: nil))
    }

    func testAPlaylistAndAnArtistLinkOpenTheirPages() throws {
        let router = AppRouter()
        router.handle(try XCTUnwrap(DeepLink.parse(URL(string: "https://www.youtube.com/playlist?list=PLabc")!)), player: nil) { _ in nil }
        XCTAssertEqual(router.path(for: .home).last, .playlist(browseId: "VLPLabc", seed: nil))
        router.handle(try XCTUnwrap(DeepLink.parse(URL(string: "https://music.youtube.com/channel/UCabc")!)), player: nil) { _ in nil }
        XCTAssertEqual(router.path(for: .home).last, .artist(browseId: "UCabc", seed: nil))
    }

    func testAPartyInviteOpensListenTogetherWithTheCodeWaiting() throws {
        let router = AppRouter()
        router.selectedTab = .explore
        let link = try XCTUnwrap(DeepLink.parse(URL(string: "https://vibramusic.kushagrasingh.in/invite/ABC234")!))
        XCTAssertEqual(link, .party(code: "ABC234", server: nil))

        router.handle(link, player: nil) { _ in nil }
        XCTAssertEqual(router.path(for: .explore).last, .listenTogether)
        XCTAssertEqual(router.pendingPartyInvite?.code, "ABC234")
    }

    func testTheAppSchemesPartyInviteCarriesItsServer() throws {
        let link = try XCTUnwrap(DeepLink.parse(URL(string: "vibramusic://party/XYZ789?server=https%3A%2F%2Fparty.example.com")!))
        guard case .party(let code, let server) = link else { return XCTFail("not a party link: \(link)") }
        XCTAssertEqual(code, "XYZ789")
        XCTAssertEqual(server, "https://party.example.com")
    }

    func testTrackLinksPlayAndSearchLinksSearch() throws {
        XCTAssertEqual(DeepLink.parse(URL(string: "https://youtu.be/dQw4w9WgXcQ")!), .track(videoId: "dQw4w9WgXcQ"))
        XCTAssertEqual(DeepLink.parse(URL(string: "https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=RDAMVM")!), .track(videoId: "dQw4w9WgXcQ"))
        XCTAssertEqual(DeepLink.parse(URL(string: "https://music.youtube.com/search?q=daft+punk")!), .search(query: "daft punk", play: false))
        XCTAssertEqual(DeepLink.parse(URL(string: "vibramusic://player")!), .player)
        XCTAssertEqual(DeepLink.parse(URL(string: "vibramusic://settings")!), .route(.settings))
        XCTAssertEqual(DeepLink.parse(sharedText: "Listen on YouTube Music: https://music.youtube.com/watch?v=abcdefghijk"), .track(videoId: "abcdefghijk"))

        let router = AppRouter()
        router.handle(.search(query: "daft punk", play: false), player: nil) { _ in nil }
        XCTAssertEqual(router.selectedTab, .search)
        XCTAssertEqual(router.pendingSearch, AppRouter.PendingSearch(query: "daft punk", play: false))
    }

    func testATrackLinkPlaysTheTrackAndOpensTheFullPlayer() async throws {
        let harness = PlayerHarness(test: self)
        let song = try harness.song("lllllllllll")
        let router = AppRouter()
        router.handle(.track(videoId: song.videoId), player: harness.player) { _ in song }
        await waitUntil("the linked track plays") { harness.player.currentSong?.videoId == song.videoId }
        XCTAssertTrue(router.nowPlaying.isPresented)
        XCTAssertEqual(harness.player.currentSong?.playbackSourceType, .sharedLink)
    }
}

/// The tab bar and page stacks (PORTING.md "Tab bar").
@MainActor
final class TabNavigationTests: XCTestCase {
    func testTabsKeepTheirOwnPagesAndReselectingPopsToTheRoot() {
        let router = AppRouter()
        XCTAssertEqual(AppTab.allCases.map(\.title), [L10n.home, L10n.explore, L10n.library, L10n.search], "Android's order")
        router.open(.settings)
        router.select(.explore)
        router.open(.history)
        XCTAssertEqual(router.path(for: .home), [.settings])
        XCTAssertEqual(router.path(for: .explore), [.history])

        router.select(.explore)
        XCTAssertEqual(router.path(for: .explore), [], "tapping the current tab pops it to its root")
        XCTAssertEqual(router.path(for: .home), [.settings], "other tabs keep their place")
    }

    func testTheSearchTabAsksForFocusEveryTimeItIsTapped() {
        let router = AppRouter()
        let before = router.searchFocusRequest
        router.select(.search)
        router.select(.search)
        XCTAssertEqual(router.searchFocusRequest, before + 2)
    }

    func testTappingSearchFromAnotherTabLandsOnItsRoot() {
        let router = AppRouter()
        router.select(.search)
        router.open(.album(browseId: "MPREb_x", seed: nil))
        router.select(.home)
        XCTAssertEqual(router.path(for: .search).count, 1, "leaving a tab keeps its place")

        router.select(.search)
        XCTAssertEqual(router.path(for: .search), [], "Android's tab handler clears the page over the last search")
    }

    func testPlayingFromSearchOpensTheSearchTabWithoutSearchingForItsName() {
        let router = AppRouter()
        router.open(.album(browseId: "MPREb_x", seed: nil), in: .search)
        router.selectedTab = .home
        router.nowPlaying.open()
        router.openPlaybackSource(QueueSource(title: L10n.search, type: .search))
        XCTAssertFalse(router.nowPlaying.isPresented)
        XCTAssertEqual(router.selectedTab, .search)
        XCTAssertNil(router.pendingSearch, "the source's title is the word \"Search\", not a query")
        XCTAssertEqual(router.path(for: .search), [])
    }

    func testPlayingFromASharedLinkOpensItOnYouTubeMusicInsteadOfAPlaylistPage() {
        let router = AppRouter()
        var opened: [URL] = []
        router.openExternalURL = { opened.append($0) }
        router.openPlaybackSource(QueueSource(title: L10n.sharedLink, type: .sharedLink, id: "dQw4w9WgXcQ"))
        XCTAssertEqual(opened, [URL(string: "https://music.youtube.com/watch?v=dQw4w9WgXcQ")!])
        XCTAssertEqual(router.path(for: router.selectedTab), [], "a video id is not a playlist to push")
    }

    func testPlayingFromGoesBackToThePageItCameFrom() {
        let router = AppRouter()
        router.nowPlaying.open()
        router.openPlaybackSource(QueueSource(title: "Discovery", type: .browse, id: "MPREb_x"))
        XCTAssertFalse(router.nowPlaying.isPresented)
        XCTAssertEqual(router.path(for: .home).last, .album(browseId: "MPREb_x", seed: nil))
    }

    func testPlayingFromTheAlbumAlreadyOpenReturnsToItInsteadOfOpeningItAgain() {
        let router = AppRouter()
        let card = BrowseItem(browseId: "MPREb_x", title: "Discovery", subtitle: "", thumbnailUrl: nil, type: .album)
        router.open(.artist(browseId: "UC_a", seed: nil))
        router.open(.album(browseId: "MPREb_x", seed: card))
        router.nowPlaying.open()
        router.openPlaybackSource(QueueSource(title: "Discovery", type: .browse, id: "MPREb_x"))
        XCTAssertFalse(router.nowPlaying.isPresented)
        XCTAssertEqual(router.path(for: .home), [.artist(browseId: "UC_a", seed: nil), .album(browseId: "MPREb_x", seed: card)],
                       "the album the song was played from, not a second copy of it")

        router.open(.artist(browseId: "UC_b", seed: nil))
        router.openPlaybackSource(QueueSource(title: "Discovery", type: .browse, id: "MPREb_x"))
        XCTAssertEqual(router.path(for: .home).count, 2, "further back in the tab: popped back to it")
    }

    func testEveryRouteAndSheetHasAScreen() {
        let routes: [AppRoute] = [
            .album(browseId: "MPREb", seed: nil), .playlist(browseId: "VLPL", seed: nil), .artist(browseId: "UC", seed: nil),
            .moodGenre(MoodGenre(title: "Chill", browseId: "FEmusic_moods", params: "p", thumbnailUrl: nil)), .history, .downloads,
            .localMusic,
            .networkLibrary(.smb), .networkLibrary(.webDAV), .settings, .equalizer, .sources, .account, .discord,
            .listenTogether, .replay, .libraryShowAll(browseId: "FE", title: "All"),
        ]
        for route in routes { _ = RouteDestination(route: route).body }
        let song = Song(videoId: "v", title: "t", artist: "a")
        let item = BrowseItem(browseId: "MPREb", title: "t", subtitle: "s", thumbnailUrl: nil, type: .album)
        let sheets: [AppSheet] = [.songActions(song), .browseActions(item), .playlistPicker([song]), .downloadManager, .lyricsSources,
                                  .lyricsProvider, .lyricsOffset, .translationLanguage, .profileSwitcher, .googleSignIn,
                                  .partyInvite(code: "ABC234", server: nil)]
        for sheet in sheets { _ = SheetDestination(sheet: sheet).body }
        XCTAssertEqual(Set(sheets.map(\.id)).count, sheets.count, "sheet ids are distinct")
    }

    func testBrowseIdsPickTheirPage() {
        XCTAssertEqual(AppRoute.browse("MPREb_1"), .album(browseId: "MPREb_1", seed: nil))
        XCTAssertEqual(AppRoute.browse("UC1"), .artist(browseId: "UC1", seed: nil))
        XCTAssertEqual(AppRoute.browse("VLPL1"), .playlist(browseId: "VLPL1", seed: nil))
        XCTAssertEqual(AppRoute.browse(LocalBrowseID.smb), .networkLibrary(.smb))
        XCTAssertEqual(AppRoute.browse(LocalBrowseID.downloads), .downloads)
    }

    /// A device folder's own browse id opens the route carrying that folder: browse id → route →
    /// folder is one mapping (`LocalFolder.browseId`) instead of two that can drift apart again —
    /// the drift behind the Local music card opening Downloads.
    func testEveryDeviceFolderOpensTheRouteCarryingThatFolder() {
        for folder in LocalFolder.allCases {
            XCTAssertEqual(AppRoute.browse(folder.browseId), .folder(folder), "\(folder.browseId) carries its folder")
        }
    }
}

/// The mini player (PORTING.md "Mini player"): swipe left plays the next song.
@MainActor
final class MiniPlayerTests: XCTestCase {
    func testTheSwipeDecidesOnReleasePastTheThreshold() {
        XCTAssertEqual(MiniPlayerSwipe.action(forTranslation: -100, locked: false), .next)
        XCTAssertEqual(MiniPlayerSwipe.action(forTranslation: 100, locked: false), .previous)
        XCTAssertEqual(MiniPlayerSwipe.action(forTranslation: -40, locked: false), .none, "short of the threshold")
        XCTAssertEqual(MiniPlayerSwipe.action(forTranslation: -100, verticalTranslation: 200, locked: false), .none, "a scroll")
        XCTAssertEqual(MiniPlayerSwipe.action(forTranslation: -100, locked: true), .blocked, "a party host holds the controls")
    }

    func testSwipingTheMiniPlayerLeftPlaysTheNextSong() async throws {
        let harness = PlayerHarness(test: self)
        let songs = try (1...2).map { try harness.song("mmmmmmmmmm\($0)") }
        harness.player.play(songs, startAt: 0)
        Haptics.shared.isMotorEnabled = false
        defer { Haptics.shared.isMotorEnabled = true }

        MiniPlayer.perform(MiniPlayerSwipe.action(forTranslation: -120, locked: false), on: harness.player)

        XCTAssertEqual(harness.player.currentSong?.videoId, songs[1].videoId)
        XCTAssertEqual(harness.engine.currentItem?.song?.videoId, songs[1].videoId)
        XCTAssertEqual(Haptics.shared.played.last, .skipNext)
        await waitUntil("the next song plays") { harness.engine.isPlaying }
    }

    /// The tab shell with a song loaded, hosted on the app's scene, and the mini player's
    /// accessibility element once it is drawn: the one that holds its "Next" button.
    private func shellWithMiniPlayer() async throws -> (host: UIViewController, router: AppRouter, mini: NSObject) {
        await enableAccessibilityTree()
        let harness = PlayerHarness(test: self)
        let app = makeAppModel(self, settings: harness.settings)
        harness.player.play([try harness.song("miniShell001")], startAt: 0)
        let host = hostInScene(RootTabView().nowPlayingEnvironment(app: app, harness: harness), test: self)
        var mini: NSObject?
        await waitUntil("the mini player is drawn") {
            mini = host.view.accessibilityParent(ofLabel: L10n.widgetNext)
            return mini != nil
        }
        if mini == nil {
            XCTFail("labels on screen: \(host.view.renderedLabels)")
        }
        return (host, app.router, try XCTUnwrap(mini))
    }

    /// A tap can't be sent to a SwiftUI gesture from a test, so this fires the mini player's
    /// "Now playing" accessibility action, which `MiniPlayer` wires to the same request as the tap.
    func testTappingTheMiniPlayerOpensNowPlaying() async throws {
        let shell = try await shellWithMiniPlayer()
        XCTAssertFalse(shell.router.nowPlaying.isPresented)
        XCTAssertNil(shell.host.presentedViewController)

        let action = try XCTUnwrap(shell.mini.accessibilityCustomActions?.first { $0.name == L10n.nowPlaying }, "the mini player offers no Now Playing action")
        if let handler = action.actionHandler {
            _ = handler(action)
        } else if let target = action.target as? NSObject {
            _ = target.perform(action.selector, with: action)
        } else {
            XCTFail("the action \(action) has nothing to run")
        }

        await waitUntil("Now Playing is asked for") { shell.router.nowPlaying.isPresented }
        await waitUntil("the full-screen player is on screen") { shell.host.presentedViewController != nil }
    }

    func testTheMiniPlayerSitsAboveTheTabBar() async throws {
        let shell = try await shellWithMiniPlayer()
        let window = try XCTUnwrap(shell.host.view.window)
        let tabBar = try XCTUnwrap(shell.host.view.allSubviews.compactMap { $0 as? UITabBar }.first, "no tab bar")
        let screen = try XCTUnwrap(window.windowScene?.screen)
        let mini = window.convert(shell.mini.accessibilityFrame, from: screen.coordinateSpace)
        let bar = tabBar.convert(tabBar.bounds, to: window)

        XCTAssertGreaterThan(mini.height, 0, "the mini player has no frame: \(mini)")
        XCTAssertLessThanOrEqual(mini.maxY, bar.minY + 1, "the mini player \(mini) overlaps the tab bar \(bar)")
    }
}

private extension UIView {
    /// The accessibility element that directly holds the one labelled `label`: SwiftUI's container
    /// for a group of controls, which is what a tap on the group lands on.
    func accessibilityParent(ofLabel label: String) -> NSObject? {
        func find(_ element: Any, parent: NSObject?) -> NSObject? {
            if let object = element as? NSObject {
                if object.accessibilityLabel == label, let parent { return parent }
                for child in object.accessibilityElements ?? [] {
                    if let found = find(child, parent: object) { return found }
                }
            }
            if let view = element as? UIView {
                for child in view.subviews {
                    if let found = find(child, parent: parent) { return found }
                }
            }
            return nil
        }
        return find(self, parent: nil)
    }
}

/// Theme.kt's modes (PORTING.md "Theme").
final class ThemeModeTests: XCTestCase {
    func testThemeModesMapOntoTheColorScheme() {
        XCTAssertNil(ThemeMode.system.colorScheme, "System follows the device")
        XCTAssertEqual(ThemeMode.light.colorScheme, .light)
        XCTAssertEqual(ThemeMode.dark.colorScheme, .dark)
        XCTAssertEqual(ThemeMode.light.interfaceStyle, .light)
        XCTAssertEqual(ThemeMode.system.interfaceStyle, .unspecified)
    }
}

/// Haptics.kt (PORTING.md "Haptics"): liking a song gives a light tap.
@MainActor
final class HapticPatternTests: XCTestCase {
    func testLikingASongIsALightTap() {
        XCTAssertTrue(Haptic.toggleOn.beats.allSatisfy { $0.style == .light })
        let span = Haptic.allCases.map { $0.beats.reduce(0) { $0 + $1.delay } }.max() ?? 0
        XCTAssertLessThanOrEqual(span, 0.065, "no pattern outlasts the finger")

        Haptics.shared.isMotorEnabled = false
        defer { Haptics.shared.isMotorEnabled = true }
        Haptics.shared.play(.toggleOn)
        XCTAssertEqual(Haptics.shared.played.last, .toggleOn)
    }
}

/// The app's resolver configuration follows StreamResolution's default walk: VISIONOS first (whole
/// AAC files, fastest start), then the embedded player, then the cipher tier.
final class StreamCatalogTests: XCTestCase {
    func testTheResolverWalksTheDefaultCatalogInOrder() {
        XCTAssertEqual(AppModel.streamCatalog.map(\.clientName), StreamClientProfile.defaultCatalog.map(\.clientName))
        XCTAssertEqual(AppModel.streamCatalog.first?.clientName, "VISIONOS")
        XCTAssertTrue(AppModel.streamCatalog.contains { $0.clientName == "WEB_EMBEDDED_PLAYER" })
    }
}
