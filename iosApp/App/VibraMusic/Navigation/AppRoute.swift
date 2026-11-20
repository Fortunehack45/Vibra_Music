import VibraMusicCore
import Foundation

// Ports the navigation state MainActivity.kt kept as a pile of flags (`selectedTab`, `detail`,
// `showSettings`, `showHistory`, `libraryShowAll`…) as typed values a NavigationStack can hold.

/// The four tabs, in Android's order (MainActivity's `TAB_HOME`…`TAB_SEARCH`).
enum AppTab: Int, CaseIterable, Identifiable, Hashable, Codable {
    case home = 0
    case explore = 1
    case library = 2
    case search = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .home: return L10n.home
        case .explore: return L10n.explore
        case .library: return L10n.library
        case .search: return L10n.search
        }
    }

    /// Vibra MusicIcons.Home / Explore / Library / Search as SF Symbols.
    var symbol: String {
        switch self {
        case .home: return AppSymbol.home
        case .explore: return AppSymbol.explore
        case .library: return AppSymbol.library
        case .search: return AppSymbol.search
        }
    }

    /// Stable identifier for UI tests.
    var accessibilityID: String { "tab.\(self)" }
}

/// Which network share `NetworkLibraryScreen` browses. The NetworkLibrary module has SMB and
/// WebDAV clients but no enum naming the two, so the app defines it.
enum NetworkLibraryKind: String, Hashable, Codable, CaseIterable, Identifiable {
    case smb
    case webDAV

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smb: return L10n.smb
        case .webDAV: return L10n.webdav
        }
    }

    /// The Core browse id Android used for the page (`local:smb` / `local:webdav`).
    var browseId: String {
        switch self {
        case .smb: return LocalBrowseID.smb
        case .webDAV: return LocalBrowseID.webDAV
        }
    }
}

/// A page pushed onto a tab's NavigationStack.
///
/// Android drew every one of these as an overlay over the tab (`detail`, `showSettings`, …); on iOS
/// they are ordinary pushes, so the back gesture and the tab's own history work as expected.
enum AppRoute: Hashable {
    /// An album page. `seed` is the card or row it was opened from, drawn while the page loads.
    case album(browseId: String, seed: BrowseItem?)
    /// A playlist page (including Liked Music and the local download playlists).
    case playlist(browseId: String, seed: BrowseItem?)
    case artist(browseId: String, seed: BrowseItem?)
    case moodGenre(MoodGenre)
    case history
    /// Offline backup: every song already whole on this device.
    case offlineBackup
    /// An on-device folder's page: Downloads over `.downloads`, Local Music (`local:all`) over
    /// `.localMusic`. The folder rides in the route, so browse id → route → folder is one mapping
    /// (`LocalFolder.browseId`) instead of two that drift — which is how the Local music card
    /// opened Downloads.
    case folder(LocalFolder)
    case networkLibrary(NetworkLibraryKind)
    case settings
    case equalizer
    case sources
    case account
    case discord
    case listenTogether
    case replay
    /// "Show all" on a library shelf.
    case libraryShowAll(browseId: String, title: String)

    /// The Downloads folder's page: `.folder(.downloads)`, spelled the way every caller already does.
    static var downloads: AppRoute { .folder(.downloads) }
    /// The Local Music folder's page: `.folder(.localMusic)`.
    static var localMusic: AppRoute { .folder(.localMusic) }

    /// The page this route shows, without the card it was drawn from while loading: two routes to
    /// the same album opened from different cards are the same page.
    var page: AppRoute {
        switch self {
        case .album(let id, _): return .album(browseId: id, seed: nil)
        case .playlist(let id, _): return .playlist(browseId: id, seed: nil)
        case .artist(let id, _): return .artist(browseId: id, seed: nil)
        default: return self
        }
    }

    /// The page a browse id opens, by the id's shape (Core's `BrowseType.of`), the way
    /// MainActivity's `openBrowse` picked a destination.
    static func browse(_ browseId: String, seed: BrowseItem? = nil) -> AppRoute {
        if browseId == LocalBrowseID.smb { return .networkLibrary(.smb) }
        if browseId == LocalBrowseID.webDAV { return .networkLibrary(.webDAV) }
        if browseId == LocalBrowseID.offlineBackup { return .offlineBackup }
        // The device folders are read back out of `LocalFolder.browseId`, so this and the
        // destination's folder can't disagree.
        if let folder = LocalFolder(browseId: browseId) { return .folder(folder) }
        switch BrowseType.of(browseId: browseId, fallback: seed?.type ?? .other) {
        case .artist: return .artist(browseId: browseId, seed: seed)
        case .album: return .album(browseId: browseId, seed: seed)
        case .playlist, .other: return .playlist(browseId: browseId, seed: seed)
        }
    }

    /// For a BrowseItem card: its own type decides.
    static func item(_ item: BrowseItem) -> AppRoute {
        switch item.type {
        case .artist: return .artist(browseId: item.browseId, seed: item)
        case .album: return .album(browseId: item.browseId, seed: item)
        case .playlist: return .playlist(browseId: item.browseId, seed: item)
        case .other: return browse(item.browseId, seed: item)
        }
    }
}

/// A sheet over the whole app.
enum AppSheet: Identifiable, Hashable {
    case songActions(Song)
    case browseActions(BrowseItem)
    case playlistPicker([Song])
    case downloadManager
    case lyricsSources
    case lyricsProvider
    case lyricsOffset
    case translationLanguage
    case profileSwitcher
    case googleSignIn
    /// A party invite opened from a link, awaiting confirmation on the Listen Together screen.
    case partyInvite(code: String, server: String?)

    var id: String {
        switch self {
        case .songActions(let song): return "song:\(song.id)"
        case .browseActions(let item): return "browse:\(item.browseId)"
        case .playlistPicker(let songs): return "picker:\(songs.map(\.id).joined(separator: ","))"
        case .downloadManager: return "downloadManager"
        case .lyricsSources: return "lyricsSources"
        case .lyricsProvider: return "lyricsProvider"
        case .lyricsOffset: return "lyricsOffset"
        case .translationLanguage: return "translationLanguage"
        case .profileSwitcher: return "profileSwitcher"
        case .googleSignIn: return "googleSignIn"
        case .partyInvite(let code, _): return "party:\(code)"
        }
    }
}
