import VibraMusicCore
import Canvas
import Downloads
import InnerTube
import Replay
import SwiftUI
import XCTest
@testable import VibraMusic

// A fake of the Collections screens' outside world (YouTube Music, the account, downloads), and the
// helpers that put a Collections screen on screen in the unit-test host.

/// Canned YouTube Music. Writes succeed (or throw, when `failWrites` is set) and change the canned
/// "server" state the next read returns, so a test can check that something survives a refresh.
@MainActor
final class FakeCollectionsService: CollectionsService {
    struct Failure: LocalizedError {
        var errorDescription: String? { "The request failed" }
    }

    var isSignedIn = true
    var listenerKey: String? = "listener-1"
    var accountName = "Test Listener"
    var failWrites = false
    /// Playlists whose add is refused, leaving the rest of the batch alone.
    var addFailures: Set<String> = []

    var libraryPage = LibraryPage(likedSongs: [], librarySongs: [], shelves: [])
    var playlists: [UserPlaylist] = []
    var historySongs: [Song] = []
    /// Album and playlist pages by browse id; `continuations` hands out the pages after the first.
    var songPages: [String: YTMusicRepository.SongPage] = [:]
    var continuations: [String: YTMusicRepository.SongPage] = [:]
    var artistPages: [String: ArtistPage] = [:]
    var allSongsById: [String: [Song]] = [:]
    var owned: [String: Bool] = [:]
    var menus: [String: SongMenu] = [:]
    var localSongsById: [String: [Song]] = [:]
    var savedPlaylists: [SavedCollection] = []
    var cards: [ReplayHeroCard] = []
    var downloads: [String: DownloadState] = [:]
    var downloaded: Set<String> = []

    private(set) var calls: [String] = []
    private(set) var createdPlaylists: [(title: String, privacy: PlaylistPrivacy, videoIds: [String])] = []
    private(set) var added: [(playlistId: String, videoIds: [String])] = []
    private(set) var removed: [(playlistId: String, entries: [PlaylistEntryRef])] = []
    private(set) var renamed: [(playlistId: String, title: String)] = []
    private(set) var deleted: [String] = []
    private(set) var libraryTokens: [String] = []
    private var created = 0

    private func write(_ name: String) throws {
        calls.append(name)
        if failWrites { throw Failure() }
    }

    /// When `holdLibrary` is set, `library()` fulfills `libraryEntered` and then waits for
    /// `releaseLibrary()` before answering — a test can hold a fetch open and look at what the
    /// store paints while the fetch is still in flight.
    var holdLibrary = false
    var libraryEntered: XCTestExpectation?
    private var libraryWaits: [CheckedContinuation<Void, Never>] = []

    func library() async throws -> LibraryPage {
        calls.append("library")
        if holdLibrary {
            libraryEntered?.fulfill()
            await withCheckedContinuation { libraryWaits.append($0) }
        }
        return libraryPage
    }

    func releaseLibrary() {
        holdLibrary = false
        let waits = libraryWaits
        libraryWaits = []
        waits.forEach { $0.resume() }
    }
    func syncLikedMusic(from token: String) async { calls.append("syncLiked:\(token)") }
    /// When `holdNextPlaylists` is set, the next `userPlaylists()` answers with the playlists as
    /// they are now, but only after `releasePlaylists()`: a slow request a later one overtakes.
    var holdNextPlaylists = false
    var playlistsEntered: XCTestExpectation?
    private var playlistWaits: [CheckedContinuation<Void, Never>] = []

    func userPlaylists() async throws -> [UserPlaylist] {
        calls.append("playlists")
        let answer = playlists
        if holdNextPlaylists {
            holdNextPlaylists = false
            playlistsEntered?.fulfill()
            await withCheckedContinuation { playlistWaits.append($0) }
        }
        return answer
    }

    func releasePlaylists() {
        let waits = playlistWaits
        playlistWaits = []
        waits.forEach { $0.resume() }
    }
    func history() async throws -> [Song] { calls.append("history"); return historySongs }

    func browseSongs(_ browseId: String) async throws -> YTMusicRepository.SongPage {
        calls.append("browse:\(browseId)")
        guard let page = songPages[browseId] else { throw Failure() }
        return page
    }

    func moreSongs(_ token: String) async throws -> YTMusicRepository.SongPage {
        calls.append("more:\(token)")
        guard let page = continuations[token] else { throw Failure() }
        return page
    }

    func artistPage(_ browseId: String) async throws -> ArtistPage {
        calls.append("artist:\(browseId)")
        guard let page = artistPages[browseId] else { throw Failure() }
        return page
    }

    func allSongs(_ browseId: String) async throws -> [Song] {
        calls.append("all:\(browseId)")
        guard let songs = allSongsById[browseId], !songs.isEmpty else { throw Failure() }
        return songs
    }

    func shelfItems(_ browseId: String) async throws -> [ShelfItem] { [] }
    func playlistOwned(_ browseId: String) async throws -> Bool? { calls.append("owned:\(browseId)"); return owned[browseId] }

    func setSaved(playlistId: String, saved: Bool) async throws {
        try write("saved:\(playlistId):\(saved)")
        for (id, page) in songPages where page.library?.playlistId == playlistId {
            songPages[id]?.library?.saved = saved
        }
    }

    func setSubscribed(channelId: String, subscribed: Bool) async throws {
        try write("subscribed:\(channelId):\(subscribed)")
        for (id, page) in artistPages where page.subscription?.channelId == channelId {
            artistPages[id]?.subscription?.subscribed = subscribed
        }
    }

    func createPlaylist(title: String, privacy: PlaylistPrivacy, videoIds: [String]) async throws -> String {
        try write("create:\(title)")
        created += 1
        createdPlaylists.append((title, privacy, videoIds))
        return "PLnew\(created)"
    }

    func addToPlaylist(playlistId: String, videoIds: [String]) async throws -> [String: String] {
        calls.append("add:\(playlistId)")
        if failWrites || addFailures.contains(playlistId) { throw Failure() }
        added.append((playlistId, videoIds))
        allSongsById["VL\(playlistId)", default: []] += videoIds.map { Song(videoId: $0, title: $0, artist: "") }
        return Dictionary(uniqueKeysWithValues: videoIds.map { ($0, "set-\($0)") })
    }

    func removeFromPlaylist(playlistId: String, entries: [PlaylistEntryRef]) async throws {
        try write("remove:\(playlistId)")
        removed.append((playlistId, entries))
    }

    func renamePlaylist(playlistId: String, title: String) async throws {
        try write("rename:\(playlistId)")
        renamed.append((playlistId, title))
    }

    func deletePlaylist(playlistId: String) async throws {
        try write("delete:\(playlistId)")
        deleted.append(playlistId)
    }

    func songMenu(videoId: String) async throws -> SongMenu {
        calls.append("menu:\(videoId)")
        guard let menu = menus[videoId] else { throw Failure() }
        return menu
    }

    func setLibraryStatus(token: String) async throws {
        try write("libraryStatus:\(token)")
        libraryTokens.append(token)
    }

    func downloadedPlaylistSongs(_ browseId: String) -> [Song]? {
        browseId.hasPrefix(LocalBrowseID.playlistPrefix) ? localSongsById[browseId] ?? [] : nil
    }

    func localSongs(_ browseId: String) -> [Song]? { localSongsById[browseId] }
    var downloadedPlaylists: [SavedCollection] { savedPlaylists }
    func replayCards() async -> (cards: [ReplayHeroCard], memberSince: String?) { (cards, cards.isEmpty ? nil : "01/26") }

    /// What `albumCanvas` answers, and the album/artist pairs it was asked about.
    var albumCanvasResult: CanvasArtwork?
    var albumCanvasRequests: [String] = []
    func albumCanvas(_ album: String, artist: String, spotifyFirst: Bool) async -> CanvasArtwork? {
        albumCanvasRequests.append("\(album)|\(artist)")
        return albumCanvasResult
    }

    func downloadState(_ videoId: String) -> DownloadState? { downloads[videoId] }
    func isDownloaded(_ videoId: String) -> Bool { downloaded.contains(videoId) }
    func cancelDownload(_ videoId: String) { downloads[videoId] = nil }
    func deleteDownload(_ videoId: String) { downloaded.remove(videoId) }
    func dismissDownloadFailure(_ videoId: String) { downloads[videoId] = nil }
    func downloadRecordId(for browseId: String) -> String? { nil }
    func deleteDownloadedCollection(_ recordId: String) {}
    func releaseIsDownloading(_ browseId: String) -> Bool { false }
    var isWaitingForWiFi = false
}

/// A few tracks and pages the tests share.
enum CollectionsFixtures {
    static func song(_ id: String, _ title: String, artist: String = "Daft Punk", duration: String? = "3:30",
                     album: String? = nil, setVideoId: String? = nil) -> Song {
        var song = Song(videoId: id, title: title, artist: artist, durationText: duration)
        song.albumName = album
        song.setVideoId = setVideoId
        song.artistId = "UCartist"
        return song
    }

    static let albumId = "MPREb_album"
    static let albumSongs: [Song] = [
        song("v1", "One More Time", duration: "5:20"),
        song("v2", "Aerodynamic", duration: "3:32"),
        song("v3", "Digital Love", duration: "5:01"),
        song("v4", "Harder, Better, Faster, Stronger", duration: "3:45"),
    ]

    static var albumPage: YTMusicRepository.SongPage {
        YTMusicRepository.SongPage(
            songs: albumSongs, continuation: nil,
            library: LibraryState(playlistId: "OLAK5uy_album", saved: false),
            header: InnerTubeParser.BrowseHeader(title: "Discovery", subtitle: "Album • Daft Punk • 2001", thumbnailUrl: nil),
            description: "Discovery is the second studio album by French electronic music duo Daft Punk."
        )
    }

    static let playlistId = "VLPLmine"
    static let playlistSongs: [Song] = [
        song("p1", "Zebra", setVideoId: "s1"),
        song("p2", "apple", setVideoId: "s2"),
        song("p3", "Mango", setVideoId: "s3"),
    ]

    static let artistId = "UCartist"
    static var artistPage: ArtistPage {
        ArtistPage(
            songs: (1...25).map { song("a\($0)", "Track \($0)") },
            moreSongsBrowseId: nil,
            sections: [HomeShelf(title: "Albums", items: (1...7).map {
                ShelfItem(title: "Album \($0)", subtitle: "2001", thumbnailUrl: nil, videoId: nil, browseId: "MPREb_\($0)")
            })],
            name: "Daft Punk",
            description: "French electronic duo.",
            subscriberCountText: "9.8M subscribers",
            monthlyListenerCount: "40M monthly listeners",
            subscription: SubscriptionState(channelId: "UCartist", subscribed: false)
        )
    }

    static func card(_ id: String, _ title: String) -> ShelfItem {
        ShelfItem(title: title, subtitle: "Playlist", thumbnailUrl: nil, videoId: nil, browseId: id)
    }
}

@MainActor
func makeCollectionsStore(_ given: FakeCollectionsService? = nil) -> (CollectionsStore, FakeCollectionsService) {
    let service = given ?? FakeCollectionsService()
    return (CollectionsStore(service: service, likeState: LikeState()), service)
}

/// An app to host screens in: settings on a throwaway suite, nothing restored, nothing integrated
/// with the system, and the fake service installed as its Collections store.
@MainActor
func makeCollectionsTestModel(_ test: XCTestCase, service given: FakeCollectionsService? = nil) -> (AppModel, CollectionsStore, FakeCollectionsService) {
    let service = given ?? FakeCollectionsService()
    let suite = "vibramusic.collections.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    var launch = AppLaunchOptions()
    launch.restoresQueue = false
    launch.integratesWithSystem = false
    let model = AppModel(
        settings: makeTestSettings(),
        likeState: LikeState(),
        searchHistory: SearchHistory(defaults: defaults),
        network: NetworkMonitor(),
        innerTube: InnerTubeClient(),
        audioCache: nil,
        launch: launch
    )
    let store = CollectionsStore(service: service, likeState: model.likeState)
    CollectionsStore.install(store, for: model)
    let engine = model.engine
    test.addTeardownBlock { @MainActor in engine.shutdown() }
    return (model, store, service)
}

extension XCTestCase {
    /// Hosts `view` the way the app does (in a navigation stack, with every environment value the
    /// shell injects), lays it out in a window at iPhone size, lets its tasks run a moment, and
    /// returns the hosting controller.
    ///
    /// `player` stands in for the app's own player, for a test that needs one with a fake stream
    /// resolver behind it.
    ///
    /// `inScene` puts the window on the app's own scene. SwiftUI builds the accessibility tree a
    /// VoiceOver user (and a test that taps what they tap) reads only for a view in a live scene,
    /// so a test that reads labels or sends an accessibility tap needs it.
    @MainActor
    @discardableResult
    func host<V: View>(_ view: V, model: AppModel, player: PlayerController? = nil, colorScheme: ColorScheme = .dark,
                       inNavigation: Bool = true, inScene: Bool = false, settle: TimeInterval = 0.4) async -> UIHostingController<AnyView> {
        let content: AnyView = inNavigation ? AnyView(NavigationStack { view }) : AnyView(view)
        let root = AnyView(content
            .environment(model)
            .environment(model.router)
            .environment(player ?? model.player)
            .environment(model.settings)
            .environment(model.likeState)
            .environment(model.searchHistory)
            .environment(\.colorScheme, colorScheme))
        let controller = UIHostingController(rootView: root)
        let frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let scene = inScene ? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first : nil
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = frame
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try? await Task.sleep(for: .seconds(settle))
        controller.view.layoutIfNeeded()
        addTeardownBlock { @MainActor in window.isHidden = true }
        return controller
    }
}

extension UIView {
    /// Every accessibility identifier in the hierarchy SwiftUI built, for asserting what rendered.
    var renderedIdentifiers: Set<String> {
        var found = Set<String>()
        func walk(_ element: Any) {
            if let view = element as? UIView {
                if let id = view.accessibilityIdentifier, !id.isEmpty { found.insert(id) }
                view.subviews.forEach(walk)
            }
            if let object = element as? NSObject {
                if let id = (object as? UIAccessibilityIdentification)?.accessibilityIdentifier, !id.isEmpty { found.insert(id) }
                for child in object.accessibilityElements ?? [] { walk(child) }
            }
        }
        walk(self)
        return found
    }

    /// Every accessibility label in the hierarchy, for asserting which rows a sheet drew.
    var renderedLabels: [String] {
        var found: [String] = []
        func walk(_ element: Any) {
            if let object = element as? NSObject {
                if let label = object.accessibilityLabel, !label.isEmpty { found.append(label) }
                for child in object.accessibilityElements ?? [] { walk(child) }
            }
            if let view = element as? UIView { view.subviews.forEach(walk) }
        }
        walk(self)
        return found
    }
}
