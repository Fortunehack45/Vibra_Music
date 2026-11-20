import VibraMusicCore
import Foundation
import Observation
import PlaybackQueue
import UIKit

// Ports MainActivity.kt's navigation state: the selected tab, what is open over each tab, the
// sheets, Now Playing, and the tab handler that clears every overlay (`onTabSelected`).

/// The app's navigation: one NavigationStack path per tab, one sheet, Now Playing.
@MainActor
@Observable
final class AppRouter {
    var selectedTab: AppTab = .home
    /// Each tab's pushed pages. Kept per tab so switching tabs and back keeps your place.
    var paths: [AppTab: [AppRoute]] = [:]
    var sheet: AppSheet?
    let nowPlaying = PlayerDock()

    /// A search the Search tab should run (a deep link, "Hey Siri, play …", an artist chip).
    /// SearchScreen takes it and clears it.
    var pendingSearch: PendingSearch?
    /// Bumped every time the Search tab is tapped: the field resets and takes focus, as on
    /// Android ("every search tab tap resets the field, focuses it, and opens the keyboard").
    private(set) var searchFocusRequest = 0
    /// A party invite waiting for the Listen Together screen to offer joining it.
    var pendingPartyInvite: ParsedInvite?

    struct PendingSearch: Hashable {
        var query: String
        /// Start the best match rather than showing the list (a spoken request).
        var play: Bool
    }

    struct ParsedInvite: Hashable {
        var code: String
        var server: String?
    }

    /// Opens a web page outside the app (a shared link's "Playing from").
    @ObservationIgnored var openExternalURL: @MainActor (URL) -> Void = { UIApplication.shared.open($0) }

    init() {}

    /// The path of `tab`, bindable for its NavigationStack.
    func path(for tab: AppTab) -> [AppRoute] {
        paths[tab] ?? []
    }

    func setPath(_ path: [AppRoute], for tab: AppTab) {
        paths[tab] = path
    }

    /// The tab bar: selects `tab`. Tapping the tab already showing pops it to its root, as iOS
    /// does; tapping Search always resets and focuses its field.
    func select(_ tab: AppTab) {
        // Search always starts fresh, as Android's tab handler does: a page pushed over the last
        // search is not where tapping Search should land you.
        if tab == selectedTab || tab == .search {
            paths[tab] = []
        }
        selectedTab = tab
        if tab == .search { searchFocusRequest += 1 }
    }

    /// Pushes `route` on the current tab.
    func open(_ route: AppRoute) {
        paths[selectedTab, default: []].append(route)
    }

    /// Pushes `route` on `tab`, switching to it.
    func open(_ route: AppRoute, in tab: AppTab) {
        selectedTab = tab
        paths[tab, default: []].append(route)
    }

    func present(_ sheet: AppSheet) {
        self.sheet = sheet
    }

    func dismissSheet() {
        sheet = nil
    }

    func popToRoot() {
        paths[selectedTab] = []
    }

    /// The page "Playing from" goes back to (MainActivity's `onOpenPlaybackSource`).
    func openPlaybackSource(_ source: QueueSource) {
        nowPlaying.close()
        switch source.type {
        case .search:
            // Android only selects the tab. The title is the word "Search" (or a tapped recent's
            // own title), not a query to run again.
            selectedTab = .search
            paths[.search] = []
        case .home:
            selectedTab = .home
        case .explore:
            selectedTab = .explore
        case .history:
            returnTo(.history)
        case .replay:
            returnTo(.replay)
        case .sharedLink:
            // The id is a video id, not a browse id: Android sends it to the track's own page on
            // YouTube Music.
            guard let id = source.id, !id.isEmpty,
                  let url = URL(string: "https://music.youtube.com/watch?v=\(id)") else { return }
            openExternalURL(url)
        case .browse, .queue:
            guard let id = source.id, !id.isEmpty else { return }
            returnTo(AppRoute.browse(id))
        }
    }

    /// Goes back to `route` when it is already in this tab's history (usually the page a song was
    /// played from, right under the player) rather than stacking a second copy; opens it otherwise.
    private func returnTo(_ route: AppRoute) {
        if let index = paths[selectedTab]?.lastIndex(where: { $0.page == route.page }) {
            paths[selectedTab]?.removeSubrange((index + 1)...)
        } else {
            open(route)
        }
    }

    /// Routes a deep link. Playback requests go to `player` through `resolveTrack`, which looks
    /// the track up so it has a title and artwork before it starts.
    func handle(
        _ link: DeepLink,
        player: PlayerController?,
        resolveTrack: @escaping @MainActor (String) async -> Song?
    ) {
        switch link {
        case .page(let browseId):
            nowPlaying.close()
            sheet = nil
            open(AppRoute.browse(browseId))
        case .route(let route):
            nowPlaying.close()
            sheet = nil
            open(route)
        case .search(let query, let play):
            nowPlaying.close()
            sheet = nil
            selectedTab = .search
            paths[.search] = []
            pendingSearch = PendingSearch(query: query, play: play)
        case .party(let code, let server):
            nowPlaying.close()
            sheet = nil
            pendingPartyInvite = ParsedInvite(code: code, server: server)
            if paths[selectedTab]?.last != .listenTogether { open(.listenTogether) }
        case .player:
            if player?.currentSong != nil { nowPlaying.open() }
        case .resume:
            player?.play()
        case .track(let videoId):
            Task { @MainActor in
                let song = await resolveTrack(videoId) ?? Song(videoId: videoId, title: "", artist: "")
                player?.playSong(song, source: QueueSource(title: L10n.sharedLink, type: .sharedLink, id: videoId))
                self.nowPlaying.open()
            }
        }
    }
}
