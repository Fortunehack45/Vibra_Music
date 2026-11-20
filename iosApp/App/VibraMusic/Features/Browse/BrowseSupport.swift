import VibraMusicCore
import Foundation
import InnerTube
import SwiftUI

// Shared plumbing for the Browse screens (Home, Explore, a mood/genre page, Search): the slice of
// YTMusicRepository they call, Android's `friendly()` error text, the page metrics of
// ui/components/Common.kt, and the few strings Android hard-codes in English.

/// What the Browse screens ask of YouTube Music.
///
/// A protocol only so the view models can be driven by a scripted catalogue in tests; the app
/// passes ``YTMusicRepository`` (which conforms as is), and the app-hosted tests also run the real
/// repository over a stubbed `URLSession`.
protocol BrowseCatalog: Sendable {
    func home() async throws -> HomeFeed
    func homeRecentlyPlayed() async throws -> HomeShelf?
    func homeSupplement(browseId: String) async throws -> [HomeShelf]
    func moreHome(token: String) async throws -> HomeFeed
    func moodAndGenres() async throws -> [MoodGenreSection]
    func moodGenreShelves(browseId: String, params: String?) async throws -> [HomeShelf]
    func moodGenreArtwork(browseId: String, params: String?) async throws -> String?
    func searchPage(query: String, filter: SearchFilter) async throws -> InnerTubeParser.SearchPage
    func searchContinuation(token: String, filter: SearchFilter) async throws -> InnerTubeParser.SearchPage
    func searchSuggestions(input: String) async throws -> [String]
    func searchTypeahead(input: String) async throws -> InnerTubeParser.SearchPage
}

extension YTMusicRepository: BrowseCatalog {}

enum BrowseCatalogDefaults {
    /// MainViewModel's `HOME_SUPPLEMENT_BROWSE_IDS`, read from the repository that fetches them.
    static var homeSupplementBrowseIds: [String] { YTMusicRepository.homeSupplementBrowseIds }
}

/// MainViewModel's `Throwable.friendly()`: a failure as the listener should read it.
enum BrowseErrorText {
    static func friendly(_ error: Error) -> String {
        if let url = error as? URLError {
            switch url.code {
            // "Unable to resolve host" on Android: no connection or no DNS.
            case .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost,
                 .dataNotAllowed, .internationalRoamingOff:
                return L10n.noInternetConnection
            default:
                break
            }
        }
        if let innerTube = error as? InnerTubeError, case .httpStatus(let status, _) = innerTube,
           status == 401 || status == 403 {
            return L10n.youtubeRequestRejected
        }
        let message = error.localizedDescription
        return message.isEmpty ? L10n.somethingWentWrong : message
    }
}

/// Strings Android draws as English literals (SearchScreen.kt's "Top result", the section titles,
/// `SearchFilter.label`) and so has no resource for. They live in this folder's own string catalog
/// (Browse.xcstrings) rather than as literals, so they can be translated like everything else.
enum BrowseStrings {
    static func tr(_ key: String) -> String {
        // Android shows these in English whatever the language, and so does this table (English
        // only). An in-app language override looks in that language's .lproj, which has no Browse
        // table, and would hand back the bare key; the English text is the fallback.
        let fallback = Self.english.localizedString(forKey: key, value: key, table: "Browse")
        return LanguageBundle.current.localizedString(forKey: key, value: fallback, table: "Browse")
    }

    private static let english: Bundle = Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main

    static var topResult: String { tr("search_top_result") }
    static var sectionMore: String { tr("search_section_more") }

    static func filterLabel(_ filter: SearchFilter) -> String {
        switch filter {
        case .all: return tr("search_filter_all")
        case .songs: return L10n.songs
        case .videos: return tr("search_filter_videos")
        case .albums: return L10n.albums
        case .artists: return L10n.artists
        case .playlists: return L10n.playlists
        }
    }
}

/// Page metrics from ui/components/Common.kt, in points.
enum BrowseMetrics {
    /// `PAGE_GUTTER`: every heading, row and shelf lines up on it. The app's own gutter rather than
    /// Android's 10 dp, so these pages line up with the shared rows (SongRow) and every other tab.
    static let gutter: CGFloat = AppTheme.gutter
    /// `SHELF_CARD_WIDTH`.
    static let shelfCardWidth: CGFloat = 150
    /// Space between cards in a shelf.
    static let cardSpacing: CGFloat = 14
    /// `HERO_CARD_RATIO` (width / height).
    static let heroCardRatio: CGFloat = 0.92
    /// Space under a shelf (`padding(bottom = 26.dp)`).
    static let shelfBottom: CGFloat = 26
    /// Where a divider under a search row starts (`ROW_DIVIDER_INSET`).
    static let rowDividerInset: CGFloat = gutter + 60

    /// `heroCardWidth`: 70% of the row, never past 320 pt, so the next card peeks in.
    static func heroCardWidth(_ available: CGFloat) -> CGFloat { min(available * 0.70, 320) }

    /// `trackColumnWidth`: 88% of the row, never past 400 pt.
    static func trackColumnWidth(_ available: CGFloat) -> CGFloat { min(available * 0.88, 400) }
}

/// The Material type roles the Android screens use, as Dynamic Type text styles so they scale with
/// the reader's text size (Theme.kt's sizes are the default-size equivalents).
enum BrowseFont {
    /// `headlineMedium`: section headings.
    static let headline = Font.title2.weight(.bold)
    /// `titleLarge`: hero card and top-result titles.
    static let titleLarge = Font.title3.weight(.bold)
    /// `titleMedium`: row and card titles.
    static let title = Font.body.weight(.semibold)
    /// `titleSmall`: the "Show all" link and search section titles.
    static let titleSmall = Font.subheadline.weight(.semibold)
    /// `bodyMedium`: subtitles.
    static let body = Font.subheadline
    /// `labelLarge`: filter pills and the "Top result" label.
    static let label = Font.subheadline.weight(.semibold)
}

extension ShelfItem {
    /// MainActivity's `shelfSong`: the track a card stands for, credited to the artist alone
    /// ("Song • Chelsea Wolfe" → "Chelsea Wolfe"), or nil when the card is a collection.
    var shelfSong: Song? {
        guard let videoId, !videoId.isEmpty else { return nil }
        return Song(videoId: videoId, title: title, artist: InnerTubeParser.artistFromSubtitle(subtitle), thumbnailUrl: thumbnailUrl)
    }

    /// The page a collection card opens, typed from its browse id (MainViewModel.browseTypeOf).
    var shelfBrowseItem: BrowseItem? {
        guard let browseId, !browseId.isEmpty else { return nil }
        return BrowseItem(browseId: browseId, title: title, subtitle: subtitle, thumbnailUrl: thumbnailUrl,
                          type: BrowseType.of(browseId: browseId))
    }
}

/// A search history entry for what was tapped (MainActivity's `recordEntity` payloads).
extension SearchHistoryEntity {
    init(song: Song) {
        self.init(id: song.videoId, title: song.title, subtitle: song.artist, artworkUrl: song.thumbnailUrl, entityType: .track)
    }

    init(item: BrowseItem) {
        let type: EntityType = switch item.type {
        case .album: .album
        case .artist: .artist
        // MainActivity files anything else as a track, which a later tap then tries to play by its
        // browse id; a page is what it is, so it's filed as one.
        case .playlist, .other: .playlist
        }
        self.init(id: item.browseId, title: item.title, subtitle: item.subtitle, artworkUrl: item.thumbnailUrl, entityType: type)
    }
}

/// Artwork cropped to exactly `width` × `height`.
///
/// The shared ArtworkImage fills with `scaledToFill` and so takes the size of a non-square
/// picture (a video's 16:9 thumbnail) rather than its frame, spilling past the row's gutter. Here
/// the frame is set first and the picture cropped to it.
struct CroppedArtwork: View {
    let raw: String?
    let pixels: Int
    let width: CGFloat
    var height: CGFloat?
    var cornerRadius: CGFloat = AppTheme.artCorner
    var placeholderSymbol: String = AppSymbol.musicNote

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Color.clear
            .frame(width: width, height: height ?? width)
            .overlay { ArtworkImage(raw, pixels: pixels, cornerRadius: 0, placeholderSymbol: placeholderSymbol) }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}
