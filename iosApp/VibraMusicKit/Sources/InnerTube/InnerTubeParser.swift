import Foundation
import VibraMusicCore

// Ports data/innertube/InnertubeParser.kt.

/// Turns Innertube responses into the app's models.
///
/// Innertube responses are deeply nested and their shape drifts between layouts (single-column vs
/// two-column browse, shelf vs carousel). Rather than hard-coding every path, structured parsing is
/// used where the layout is stable (search, home) and a recursive scan where it is not (playlists,
/// library) — see ``collectSongsDeep(_:)``.
public enum InnerTubeParser {

    // MARK: - Search

    /// One page of search rows, plus the token for the next page if YouTube offers one.
    public struct SearchPage: Hashable, Sendable {
        public var rows: [SearchResult]
        public var continuation: String?

        public init(rows: [SearchResult], continuation: String?) {
            self.rows = rows
            self.continuation = continuation
        }
    }

    static func parseSearchSongs(_ response: InnerTubeJSON) -> [Song] {
        parseSearch(response).compactMap { result in
            if case .track(let song) = result { return song }
            return nil
        }
    }

    /// Search results are heterogeneous: songs carry a videoId, while albums, artists and playlists
    /// carry a browseId plus a page type. Both arrive as `musicResponsiveListItemRenderer`, so each
    /// row is classified on the way out.
    static func parseSearch(_ response: InnerTubeJSON) -> [SearchResult] {
        parseSearchPage(response).rows
    }

    static func parseSearchPage(_ response: InnerTubeJSON, includeVideos: Bool = false) -> SearchPage {
        let cards = collectRenderers(response, "musicCardShelfRenderer")
        // The "All" tab spreads results across several shelf types (card shelf for the top result,
        // then one shelf per category). Its promoted top result lives on the card itself, not in a
        // responsive row, so read it first before walking the ordinary result rows.
        let topResults: [SearchResult] = includeVideos ? [] : cards.compactMap { card in
            if let song = parseCardShelfSong(card) { return .topTrack(song) }
            if let item = parseCardShelfBrowse(card) { return .browse(item) }
            return nil
        }
        // The rows tucked inside an artist's promoted card carry the credit that card bills them
        // to — see cardShelfCredit. Android matched them by object identity against the card's own
        // rows; here each row is collected together with the credit of the card it sits in.
        let rows = collectRowsWithCardCredit(response, includeCardCredit: !includeVideos)

        var seen = Set<String>()
        var parsed: [SearchResult] = []
        for result in topResults {
            switch result {
            case .topTrack(let song):
                // The mixed All page stays music-only; music-video uploads belong exclusively to
                // the dedicated Videos tab.
                if !song.isVideo, seen.insert("v:\(song.videoId)").inserted { parsed.append(result) }
            case .browse(let item):
                if seen.insert("b:\(item.browseId)").inserted { parsed.append(result) }
            case .track:
                break
            }
        }
        for (renderer, cardCredit) in rows {
            // Browse rows are tested first: an album row also carries a "play album" videoId in its
            // overlay, so checking for a track first would misread every album as a single song.
            if let browse = parseBrowseItem(renderer) {
                if seen.insert("b:\(browse.browseId)").inserted { parsed.append(.browse(browse)) }
            } else if let song = parseResponsiveListItem(renderer, fallback: cardCredit ?? Credits()) {
                // The mixed All page stays music-only; the dedicated Videos filter is the one place
                // music-video uploads belong.
                if song.isVideo == includeVideos, seen.insert("v:\(song.videoId)").inserted {
                    parsed.append(.track(song))
                }
            }
        }
        return SearchPage(rows: parsed, continuation: continuationToken(response))
    }

    /// The typeahead queries out of a `music/get_search_suggestions` response.
    ///
    /// Two sections come back. The first is what this reads: query strings, as
    /// `searchSuggestionRenderer`. The second — present signed in, and for some terms signed out —
    /// is entity rows for songs and artists. Those are deliberately ignored: what the field is being
    /// filled in with is a query, and a row that navigates straight to a track instead is a
    /// different feature with a different tap target.
    ///
    /// `searchEndpoint.query` is preferred over the display text because the display text arrives
    /// split into runs purely so the typed prefix can be bold-faced, with no separator of its own to
    /// rejoin on.
    static func parseSearchSuggestions(_ response: InnerTubeJSON) -> [String] {
        collectRenderers(response, "searchSuggestionRenderer")
            .compactMap { renderer -> String? in
                let query = renderer.o("navigationEndpoint").o("searchEndpoint").s("query")
                    ?? renderer.o("suggestion").runs()
                return query.isBlankText ? nil : query
            }
            .distinctElements()
    }

    /// Depth-first collection of a named renderer, preserving document order.
    static func collectRenderers(_ root: InnerTubeJSON, _ name: String) -> [InnerTubeJSON] {
        var out: [InnerTubeJSON] = []
        func walk(_ node: InnerTubeJSON) {
            switch node {
            case .object(let object):
                if let found = object[name], case .object = found { out.append(found) }
                for value in object.values { walk(value) }
            case .array(let array):
                for value in array { walk(value) }
            default:
                break
            }
        }
        walk(root)
        return out
    }

    static func collectRenderers(_ root: InnerTubeJSON?, _ name: String) -> [InnerTubeJSON] {
        guard let root else { return [] }
        return collectRenderers(root, name)
    }

    /// Every `musicResponsiveListItemRenderer` in document order, each paired with the credit of the
    /// outermost artist card it sits inside (nil outside one).
    private static func collectRowsWithCardCredit(
        _ root: InnerTubeJSON,
        includeCardCredit: Bool
    ) -> [(InnerTubeJSON, Credits?)] {
        var out: [(InnerTubeJSON, Credits?)] = []
        func walk(_ node: InnerTubeJSON, credit: Credits?) {
            switch node {
            case .object(let object):
                var inherited = credit
                if let row = object["musicResponsiveListItemRenderer"], case .object = row {
                    out.append((row, credit))
                }
                // A card's own key is walked with its credit in force, so its rows pick it up.
                for (key, value) in object.entries {
                    if key == "musicCardShelfRenderer", case .object = value, includeCardCredit {
                        inherited = credit ?? cardShelfCredit(value)
                        walk(value, credit: inherited)
                        inherited = credit
                    } else {
                        walk(value, credit: inherited)
                    }
                }
            case .array(let array):
                for value in array { walk(value, credit: credit) }
            default:
                break
            }
        }
        walk(root, credit: nil)
        return out
    }

    private static func parseBrowseItem(_ renderer: InnerTubeJSON) -> BrowseItem? {
        guard let endpoint = renderer.o("navigationEndpoint").o("browseEndpoint"),
              let browseId = endpoint.s("browseId") else { return nil }
        let pageType = pageTypeOf(endpoint)

        let columns = renderer.a("flexColumns") ?? []
        let title = columns.first.o("musicResponsiveListItemFlexColumnRenderer").o("text").runs()
        if title.isBlankText { return nil }

        let subtitle = columns.element(at: 1).o("musicResponsiveListItemFlexColumnRenderer").o("text").runs()
        // A playlist/album billed as a video chart/compilation — "N videos" in the subtitle, or
        // "video" right in the title, e.g. "Daily Top Music Videos" — would have every row dropped by
        // parseResponsiveListItem anyway, so skip the dead-end card rather than link to an empty page.
        if Patterns.videoWord.containsMatch(in: title) || Patterns.videoWord.containsMatch(in: subtitle) { return nil }

        return BrowseItem(
            browseId: browseId,
            title: title,
            subtitle: subtitle,
            thumbnailUrl: renderer.o("thumbnail").o("musicThumbnailRenderer").o("thumbnail").a("thumbnails").bestThumbnail(),
            type: browseType(forPageType: pageType)
        )
    }

    private static func browseType(forPageType pageType: String) -> BrowseType {
        if pageType.contains("ALBUM") { return .album }
        if pageType.contains("ARTIST") { return .artist }
        if pageType.contains("PLAYLIST") { return .playlist }
        return .other
    }

    private static func pageTypeOf(_ browseEndpoint: InnerTubeJSON?) -> String {
        browseEndpoint.o("browseEndpointContextSupportedConfigs")
            .o("browseEndpointContextMusicConfig").s("pageType") ?? ""
    }

    // MARK: - Home feed

    static func parseHome(_ response: InnerTubeJSON) -> [HomeShelf] {
        sectionListContents(response).compactMap { section in
            if let carousel = section.o("musicCarouselShelfRenderer"), let shelf = carouselShelf(carousel) { return shelf }
            if let plain = section.o("musicShelfRenderer") { return plainShelf(plain) }
            return nil
        }
    }

    /// `contents.singleColumnBrowseResultsRenderer.tabs[0].tabRenderer.content.sectionListRenderer.contents`.
    private static func sectionListContents(_ response: InnerTubeJSON) -> [InnerTubeJSON] {
        response.o("contents").o("singleColumnBrowseResultsRenderer").a("tabs")?.first
            .o("tabRenderer").o("content").o("sectionListRenderer").a("contents") ?? []
    }

    /// The Moods & genres browse page is a set of navigation-button grids, not a normal carousel.
    /// Keep the browse params on every button: they select the playlist shelves that belong to that
    /// exact mood or genre.
    static func parseMoodAndGenres(_ response: InnerTubeJSON) -> [MoodGenreSection] {
        sectionListContents(response).compactMap { section in
            guard let grid = section.o("gridRenderer") else { return nil }
            let title = grid.o("header").o("gridHeaderRenderer").o("title").runs()
            let items: [MoodGenre] = (grid.a("items") ?? []).compactMap { item in
                guard let button = item.o("musicNavigationButtonRenderer"),
                      let endpoint = button.o("clickCommand").o("browseEndpoint")
                        ?? button.o("navigationEndpoint").o("browseEndpoint"),
                      let browseId = endpoint.s("browseId") else { return nil }
                let label = button.o("buttonText").runs()
                if label.isBlankText { return nil }
                return MoodGenre(title: label, browseId: browseId, params: endpoint.s("params"))
            }
            if title.isBlankText || items.isEmpty { return nil }
            return MoodGenreSection(title: title, items: items)
        }
    }

    /// More Home shelves off a continuation response.
    ///
    /// Unlike the first page, a continuation envelope doesn't repeat the tabs/section-list wrapper
    /// ``parseHome(_:)`` reads off a fixed path — so the shelves are walked out wherever they land
    /// instead, the same tradeoff ``collectSongsDeep(_:)`` makes for song rows. Preserves the order
    /// they were found in, since a carousel and a plain shelf never share a parent node.
    static func parseHomeContinuation(_ root: InnerTubeJSON) -> [HomeShelf] {
        var out: [HomeShelf] = []
        func walk(_ node: InnerTubeJSON) {
            switch node {
            case .object(let object):
                if let carousel = object["musicCarouselShelfRenderer"], case .object = carousel,
                   let shelf = carouselShelf(carousel) {
                    out.append(shelf)
                }
                if let plain = object["musicShelfRenderer"], case .object = plain, let shelf = plainShelf(plain) {
                    out.append(shelf)
                }
                for value in object.values { walk(value) }
            case .array(let array):
                for value in array { walk(value) }
            default:
                break
            }
        }
        walk(root)
        return out
    }

    private static func carouselShelf(_ carousel: InnerTubeJSON) -> HomeShelf? {
        let header = carousel.o("header").o("musicCarouselShelfBasicHeaderRenderer")
        let title = header.o("title").runs()
        let strapline = header.o("strapline").runs()
        // Whole shelves like "Video charts" carry nothing but video compilations — each card would
        // fail its own video check on the way to a dead-end page, so the shelf is dropped outright.
        if Patterns.videoWord.containsMatch(in: title) { return nil }
        let items: [ShelfItem] = (carousel.a("contents") ?? []).compactMap { item in
            if let card = parseTwoRowItem(item.o("musicTwoRowItemRenderer")) { return card }
            if let song = parseResponsiveListItem(item.o("musicResponsiveListItemRenderer")), !song.isVideo {
                return ShelfItem(title: song.title, subtitle: song.artist, thumbnailUrl: song.thumbnailUrl, videoId: song.videoId, browseId: nil)
            }
            // A chart row with nothing to play — "Top artists" lists the artist alone, no track —
            // falls through parseResponsiveListItem (it demands a videoId) and used to drop the
            // whole shelf.
            return parseArtistRow(item.o("musicResponsiveListItemRenderer"))
        }
        if items.isEmpty { return nil }
        return HomeShelf(title: title.isBlankText ? "For you" : title, items: items, subtitle: strapline)
    }

    private static func plainShelf(_ shelf: InnerTubeJSON) -> HomeShelf? {
        let title = shelf.o("title").runs()
        if Patterns.videoWord.containsMatch(in: title) { return nil }
        let items = (shelf.a("contents") ?? [])
            .compactMap { parseResponsiveListItem($0.o("musicResponsiveListItemRenderer")) }
            .filter { !$0.isVideo }
            .map { ShelfItem(title: $0.title, subtitle: $0.artist, thumbnailUrl: $0.thumbnailUrl, videoId: $0.videoId, browseId: nil) }
        if items.isEmpty { return nil }
        return HomeShelf(title: title.isBlankText ? "For you" : title, items: items)
    }

    // MARK: - Artist page

    /// Artist landing page: a "Top songs" shelf (only ~5 rows, but its header links to a playlist
    /// with the full list) plus carousels for Albums, Singles & EPs and friends.
    static func parseArtistPage(_ response: InnerTubeJSON) -> ArtistPage {
        var songs: [Song] = []
        var moreSongs: String?
        var shelves: [HomeShelf] = []
        let header = response["header"]
        // "Top songs" rows are billed by the page they sit on: the subtitle beside them counts plays
        // where a search row names the artist.
        let credit = Credits(artistName: artistName(header))

        for section in sectionListContents(response) {
            if let shelf = section.o("musicShelfRenderer") {
                for row in shelf.a("contents") ?? [] {
                    if let song = parseResponsiveListItem(row.o("musicResponsiveListItemRenderer"), fallback: credit) {
                        songs.append(song)
                    }
                }
                if moreSongs == nil {
                    moreSongs = shelf.o("title").a("runs")?.first
                        .o("navigationEndpoint").o("browseEndpoint").s("browseId")
                }
            }
            if let carousel = section.o("musicCarouselShelfRenderer") {
                let carouselHeader = carousel.o("header").o("musicCarouselShelfBasicHeaderRenderer")
                let title = carouselHeader.o("title").runs()
                if Patterns.videoWord.containsMatch(in: title) { continue }
                let items = (carousel.a("contents") ?? [])
                    .compactMap { parseTwoRowItem($0.o("musicTwoRowItemRenderer")) }
                    .filter { $0.browseId != nil }
                let moreEndpoint: InnerTubeJSON? =
                    carouselHeader.o("title").a("runs")?.lazy.compactMap { $0.o("navigationEndpoint").o("browseEndpoint") }.first
                    ?? carouselHeader.o("moreContentButton").o("buttonRenderer").o("navigationEndpoint").o("browseEndpoint")
                    ?? carouselHeader.o("moreContentButton").o("musicMoreContentButtonRenderer").o("navigationEndpoint").o("browseEndpoint")
                    ?? carouselHeader.a("endIcons")?.lazy.compactMap {
                        $0.o("musicNavigationButtonRenderer").o("clickCommand").o("browseEndpoint")
                            ?? $0.o("musicNavigationButtonRenderer").o("navigationEndpoint").o("browseEndpoint")
                    }.first
                    ?? carouselHeader.o("navigationEndpoint").o("browseEndpoint")
                if !title.isBlankText, !items.isEmpty {
                    shelves.append(HomeShelf(
                        title: title,
                        items: items,
                        moreBrowseId: moreEndpoint.s("browseId"),
                        moreParams: moreEndpoint.s("params")
                    ))
                }
            }
        }
        return ArtistPage(
            songs: songs,
            moreSongsBrowseId: moreSongs,
            sections: shelves,
            thumbnailUrl: artistThumbnail(header),
            name: credit.artistName,
            description: parseDescription(response),
            subscriberCountText: subscriberCount(header),
            monthlyListenerCount: monthlyListeners(header),
            subscription: subscription(header)
        )
    }

    /// The header's subscribe button, as state rather than as a label — see ``SubscriptionState``.
    ///
    /// Same two shapes ``subscriberCount(_:)`` has to cope with, read in the same order. The channel
    /// id is taken off the button rather than off the browse id the page was fetched with: they are
    /// usually the same `UC…`, but a page reached through one of YouTube's aliases is the case where
    /// they aren't, and the button is the side that knows what it would act on.
    private static func subscription(_ header: InnerTubeJSON?) -> SubscriptionState? {
        guard let immersive = header.o("musicImmersiveHeaderRenderer") else { return nil }
        // Both shapes are tried rather than the first one found being trusted: the newer button is
        // sometimes only the count, and a page that ships both is one where the state is on the
        // other one.
        let buttons = [
            immersive.o("subscriptionButton2").o("subscribeButtonRenderer"),
            immersive.o("subscriptionButton").o("subscribeButtonRenderer"),
        ].compactMap { $0 }
        for button in buttons {
            // Absent on a signed-out response, where the button is only ever an invitation to sign
            // in and toggling it would be a write with nothing behind it.
            // Kotlin reads this with JsonPrimitive.booleanOrNull, which also accepts the
            // string-encoded "true"/"false" YouTube sometimes ships, so the string form is
            // accepted here too (case-insensitively, like kotlinx.serialization).
            let subscribed: Bool
            if case .bool(let flag)? = button["subscribed"] {
                subscribed = flag
            } else if let raw = button["subscribed"]?.primitiveContent?.lowercased(),
                      raw == "true" || raw == "false" {
                subscribed = raw == "true"
            } else {
                continue
            }
            let channelId = button.s("channelId")
                ?? button.a("serviceEndpoints")?.lazy.compactMap {
                    $0.o("subscribeEndpoint").a("channelIds")?.first?.primitiveContent
                }.first
            guard let channelId else { continue }
            return SubscriptionState(channelId: channelId, subscribed: subscribed)
        }
        return nil
    }

    /// "1.2M subscribers" off the artist header's subscribe button — YouTube ships two shapes of it
    /// depending on how the page was served, and the button carries the count under one of three
    /// keys across those shapes.
    private static func subscriberCount(_ header: InnerTubeJSON?) -> String? {
        guard let immersive = header.o("musicImmersiveHeaderRenderer") else { return nil }
        let button2 = immersive.o("subscriptionButton2").o("subscribeButtonRenderer")
        let button1 = immersive.o("subscriptionButton").o("subscribeButtonRenderer")
        return button2.o("subscriberCountWithSubscribeText").firstRunText()
            ?? button1.o("longSubscriberCountText").firstRunText()
            ?? button1.o("shortSubscriberCountText").firstRunText()
    }

    /// "3.4M monthly listeners", off the same header as ``subscriberCount(_:)``.
    private static func monthlyListeners(_ header: InnerTubeJSON?) -> String? {
        header.o("musicImmersiveHeaderRenderer").o("monthlyListenerCount").firstRunText()
    }

    /// The name the page bills itself under. A track credited to a trio hands its callers all three
    /// names at once, so the page's own header is what says which of them is actually open.
    private static func artistName(_ header: InnerTubeJSON?) -> String? {
        guard let renderer = header.o("musicImmersiveHeaderRenderer") ?? header.o("musicVisualHeaderRenderer") else {
            return nil
        }
        let title = renderer.o("title").runs()
        return title.isBlankText ? nil : title
    }

    /// The artist's own picture, off whichever header shape came back — the immersive header serves
    /// it as `thumbnail`, the visual header as `foregroundThumbnail` over a banner. Callers that
    /// arrive from a track only know that track's cover art, so this is what a page is meant to
    /// show instead.
    private static func artistThumbnail(_ header: InnerTubeJSON?) -> String? {
        guard let header else { return nil }
        let immersive = header.o("musicImmersiveHeaderRenderer")
        let visual = header.o("musicVisualHeaderRenderer")
        let renderer = (immersive.o("thumbnail") ?? visual.o("foregroundThumbnail") ?? visual.o("thumbnail"))
            .o("musicThumbnailRenderer")
            // Header shapes drift; fall back to the first image anywhere under the header rather
            // than to the caller's album art.
            ?? collectRenderers(header, "musicThumbnailRenderer").first
        return renderer.o("thumbnail").a("thumbnails").bestThumbnail()
    }

    // MARK: - Generic / robust

    /// Walks the whole response collecting any `musicResponsiveListItemRenderer` that carries a
    /// videoId. Layout-agnostic, so it survives the differences between playlist, album, library
    /// and history pages. One row per video id, in the order each id was first seen, holding the
    /// last row read for it (Android's LinkedHashMap).
    static func collectSongsDeep(_ root: InnerTubeJSON) -> [Song] {
        var order: [String] = []
        var byId: [String: Song] = [:]
        // A release's own rows are credited by its header, not one by one.
        let credit = pageCredit(root)
        func walk(_ node: InnerTubeJSON) {
            switch node {
            case .object(let object):
                if let renderer = object["musicResponsiveListItemRenderer"],
                   let song = parseResponsiveListItem(renderer, fallback: credit) {
                    if byId.updateValue(song, forKey: song.videoId) == nil { order.append(song.videoId) }
                }
                for value in object.values { walk(value) }
            case .array(let array):
                for value in array { walk(value) }
            default:
                break
            }
        }
        walk(root)
        return order.compactMap { byId[$0] }
    }

    /// A playlist page's own tracks, the ones YouTube suggests adding, and the token for the rest.
    public struct PlaylistShelfPage: Hashable, Sendable {
        public var songs: [Song]
        public var suggested: [Song]
        public var continuation: String?
    }

    /// A playlist page's own track list, scoped rather than walked — plus whatever YouTube offers
    /// alongside it to round the playlist out.
    ///
    /// A playlist the account owns can carry a "Suggestions" shelf below the list actually built by
    /// hand. Its continuation lands as a plain `sectionListContinuation` carrying a
    /// `musicShelfRenderer` titled "Suggestions", structurally unrelated to the shelf the real tracks
    /// came from, so the scope here is the whole secondary column (or, for a continuation response,
    /// the whole `continuationContents`). What tells a suggested row from a real one is which shelf
    /// it sits in. ``collectSongsDeep(_:)`` has no notion of any of this, so a plain walk reads
    /// suggestions as songs the user added.
    ///
    /// Returns nil off a page with nothing playlist-shaped in scope (an album, say, or a
    /// continuation delivered as `onResponseReceivedActions`), so callers fall back to the generic
    /// walk.
    static func parsePlaylistShelf(_ root: InnerTubeJSON) -> PlaylistShelfPage? {
        guard let scope = root.o("continuationContents")
            ?? root.o("contents").o("twoColumnBrowseResultsRenderer").o("secondaryContents") else { return nil }
        let playlistScope = scope.o("musicPlaylistShelfContinuation")
            ?? collectRenderers(scope, "musicPlaylistShelfRenderer").first
        let suggestionShelves = collectRenderers(scope, "musicShelfRenderer")
            .filter { $0.o("title").runs() == "Suggestions" }
        if playlistScope == nil && suggestionShelves.isEmpty { return nil }

        let credit = pageCredit(root)
        let songs = playlistScope.map { playlist in
            collectRenderers(playlist, "musicResponsiveListItemRenderer")
                .compactMap { parseResponsiveListItem($0, fallback: credit) }
                .distinct(by: \.videoId)
        } ?? []
        let known = Set(songs.map(\.videoId))
        let suggested = suggestionShelves
            .flatMap { collectRenderers($0, "musicResponsiveListItemRenderer") }
            .compactMap { parseResponsiveListItem($0, fallback: credit) }
            .filter { !known.contains($0.videoId) }
            .distinct(by: \.videoId)
        // The "Suggestions" shelf's own continuation reloads it with a fresh batch rather than
        // paging it (see its "Refresh" button, wired to a `reloadContinuationData` token). Only the
        // playlist shelf's own continuation means more real tracks.
        let token = playlistScope.flatMap { playlist in
            collectRenderers(playlist, "continuationItemRenderer").first
                .o("continuationEndpoint").o("continuationCommand").s("token")
                ?? collectRenderers(playlist, "nextContinuationData").first.s("continuation")
        }
        return PlaylistShelfPage(songs: songs, suggested: suggested, continuation: token)
    }

    /// One page of saved library cards, plus the token for the next page.
    public struct LibraryItemPage: Hashable, Sendable {
        public var items: [ShelfItem]
        public var continuation: String?
    }

    /// The cards on a library feed — saved playlists, albums, artists, podcasts.
    ///
    /// Library pages remember whether the account last used the grid or the list view, and serve
    /// `musicTwoRowItemRenderer` cards for one and `musicResponsiveListItemRenderer` rows for the
    /// other, so both are read.
    static func parseLibraryItems(_ root: InnerTubeJSON) -> [ShelfItem] {
        parseLibraryItemPage(root).items
    }

    static func parseLibraryItemPage(_ root: InnerTubeJSON) -> LibraryItemPage {
        var order: [String] = []
        var byId: [String: ShelfItem] = [:]
        func keep(_ key: String, _ item: ShelfItem) {
            guard byId[key] == nil else { return }
            byId[key] = item
            order.append(key)
        }
        for renderer in collectRenderers(root, "musicTwoRowItemRenderer") {
            guard let item = parseTwoRowItem(renderer), let browseId = item.browseId else { continue }
            keep(browseId, item)
        }
        for renderer in collectRenderers(root, "musicResponsiveListItemRenderer") {
            guard let item = parseBrowseItem(renderer) else { continue }
            keep(item.browseId, ShelfItem(title: item.title, subtitle: item.subtitle, thumbnailUrl: item.thumbnailUrl, videoId: nil, browseId: item.browseId))
        }
        return LibraryItemPage(items: order.compactMap { byId[$0] }, continuation: continuationToken(root))
    }

    /// Token for the next page of a paged response, or nil once it has run out. Both the modern
    /// `continuationItemRenderer` and the older `continuations` array are in circulation, sometimes
    /// within the same account.
    static func continuationToken(_ root: InnerTubeJSON) -> String? {
        if let token = collectRenderers(root, "continuationItemRenderer").first
            .o("continuationEndpoint").o("continuationCommand").s("token") {
            return token
        }
        return collectRenderers(root, "nextContinuationData").first.s("continuation")
    }

    // MARK: - Renderers

    /// One track row. `fallback` is what the page it came from is billed to — see pageCredit — and
    /// is used only where the row itself says nothing.
    static func parseResponsiveListItem(_ renderer: InnerTubeJSON?, fallback: Credits = Credits()) -> Song? {
        guard let renderer,
              let videoId = renderer.o("playlistItemData").s("videoId")
                ?? renderer.o("overlay").o("musicItemThumbnailOverlayRenderer").o("content")
                    .o("musicPlayButtonRenderer").o("playNavigationEndpoint").o("watchEndpoint").s("videoId")
        else { return nil }

        let columns = renderer.a("flexColumns") ?? []
        let title = columns.first.o("musicResponsiveListItemFlexColumnRenderer").o("text").runs()
        if title.isBlankText { return nil }

        let subtitleRuns = columns.element(at: 1).o("musicResponsiveListItemFlexColumnRenderer").o("text").a("runs") ?? []
        let subtitle = subtitleRuns.map { $0.s("text") ?? "" }.joined()
        let parts = subtitle.splitText(" • ").filter { !$0.isBlankText }
        // A search row states its runtime in the subtitle; an album's own rows do not — the release
        // is billed once in the header and the per-track duration sits in a `fixedColumns` entry off
        // to the right instead. Without it, lyrics matching falls back to title and artist alone
        // against providers that key on runtime, and version matching loses the one check that
        // separates the album cut from the extended mix beside it.
        let duration = parts.last.flatMap { Patterns.duration.matches($0) ? $0 : nil }
            ?? (renderer.a("fixedColumns") ?? []).lazy.compactMap { column -> String? in
                let text = column.o("musicResponsiveListItemFixedColumnRenderer").o("text").runs()
                return Patterns.duration.matches(text) ? text : nil
            }.first
        // On the "All" tab the first segment is the row type ("Song", "Video"), not the artist — skip
        // those so the subtitle reads like a credit.
        let rowType = parts.first { typeWords.contains($0.lowercased()) }?.lowercased()
        // A track row on an album lists its play count where a search row lists the artist, so a
        // segment that reads as a tally is no credit.
        let artist = parts.first {
            !Patterns.duration.matches($0) && !typeWords.contains($0.lowercased()) && !Patterns.tally.matches($0)
        }

        // The artist/album names in the subtitle carry browse endpoints; pull them out so the
        // long-press menu can open those pages.
        let credits = creditsOf(columns.flatMap {
            $0.o("musicResponsiveListItemFlexColumnRenderer").o("text").a("runs") ?? []
        })
        let creditedArtists = artistNamesFromRuns(subtitleRuns)

        let thumbnails = renderer.o("thumbnail").o("musicThumbnailRenderer").o("thumbnail").a("thumbnails")

        return Song(
            videoId: videoId,
            title: title,
            // Preserve the whole artist segment even when only some of its names link to artist
            // pages. The "All" tab can list only "Song • 4:30" instead, and an album's own rows can
            // carry no credit at all, so retain the linked and page-level fallbacks.
            artist: creditedArtists
                ?? credits.artistName.flatMap { $0.isBlankText ? nil : $0 }
                ?? artist
                ?? fallback.artistName
                ?? "Unknown artist",
            thumbnailUrl: thumbnails.bestThumbnail(),
            durationText: duration,
            artistId: credits.artistId ?? fallback.artistId,
            albumId: credits.albumId ?? fallback.albumId,
            albumName: credits.albumName ?? fallback.albumName,
            // The row type word is the clean signal when present ("All" tab); otherwise a
            // music-video upload gives itself away with widescreen art where a catalogue track has
            // square album cover art.
            isVideo: rowType == "video" || thumbnails.isNotSquare(),
            // Only playlist rows carry one; on an album or a search hit this is simply absent, which
            // is what makes "remove from playlist" offer itself exactly where it means something.
            setVideoId: renderer.o("playlistItemData").s("playlistSetVideoId"),
            isExplicit: hasExplicitBadge(renderer)
        )
    }

    /// The promoted result at the top of an unfiltered search is a `musicCardShelfRenderer`. Unlike
    /// the rows below it, its playable id and credits are placed directly on the card, so it would
    /// otherwise vanish from the All tab while remaining first in the Songs tab.
    private static func parseCardShelfSong(_ renderer: InnerTubeJSON) -> Song? {
        guard let videoId = renderer.o("onTap").o("watchEndpoint").s("videoId") else { return nil }
        let title = renderer.o("title").runs()
        if title.isBlankText { return nil }

        let subtitleRuns = renderer.o("subtitle").a("runs") ?? []
        let subtitle = subtitleRuns.map { $0.s("text") ?? "" }.joined()
        let parts = subtitle.splitText(" • ").filter { !$0.isBlankText }
        let duration = parts.last.flatMap { Patterns.duration.matches($0) ? $0 : nil }
        let rowType = parts.first { typeWords.contains($0.lowercased()) }?.lowercased()
        let credits = creditsOf(subtitleRuns)
        let creditedArtists = artistNamesFromRuns(subtitleRuns)
        let artist = parts.first {
            !Patterns.duration.matches($0) && !typeWords.contains($0.lowercased()) && !Patterns.tally.matches($0)
        }
        let thumbnails = renderer.o("thumbnail").o("musicThumbnailRenderer").o("thumbnail").a("thumbnails")

        return Song(
            videoId: videoId,
            title: title,
            artist: creditedArtists
                ?? credits.artistName.flatMap { $0.isBlankText ? nil : $0 }
                ?? artist
                ?? "Unknown artist",
            thumbnailUrl: thumbnails.bestThumbnail(),
            durationText: duration,
            artistId: credits.artistId,
            albumId: credits.albumId,
            albumName: credits.albumName,
            isVideo: rowType == "video" || thumbnails.isNotSquare(),
            isExplicit: hasExplicitBadge(renderer["subtitleBadges"])
        )
    }

    /// Who the rows inside a promoted card are by, or nil if the card isn't one that bills them.
    ///
    /// An artist card is a header with a track list under it, the same shape a release page has:
    /// searching "mc stan" promotes the artist and hangs three of their songs off the card, and those
    /// rows say only "Song • 3:16" — the credit is on the card, stated once.
    ///
    /// Only artist cards, which is why this reads `onTap` rather than the subtitle. A song or video
    /// card's rows are *related* uploads rather than its own — "Shape of You" promotes the track and
    /// lists a dance cover under it, by other people entirely — so lending them the card's credit
    /// would put the wrong name on rows that are not missing one to begin with.
    private static func cardShelfCredit(_ card: InnerTubeJSON) -> Credits? {
        guard let endpoint = card.o("onTap").o("browseEndpoint"), pageTypeOf(endpoint).contains("ARTIST") else {
            return nil
        }
        let name = card.o("title").runs()
        if name.isBlankText { return nil }
        // Deliberately no album: the card says who the song is by and nothing about which release
        // it came off, and a guess there would show up as a wrong "go to album".
        return Credits(artistId: endpoint.s("browseId"), artistName: name)
    }

    /// Artist, album and playlist cards use the same promoted-search container as a song.
    private static func parseCardShelfBrowse(_ renderer: InnerTubeJSON) -> BrowseItem? {
        guard let endpoint = renderer.o("onTap").o("browseEndpoint"), let browseId = endpoint.s("browseId") else {
            return nil
        }
        let title = renderer.o("title").runs()
        if title.isBlankText { return nil }
        let subtitle = renderer.o("subtitle").runs()
        if Patterns.videoWord.containsMatch(in: title) || Patterns.videoWord.containsMatch(in: subtitle) { return nil }
        return BrowseItem(
            browseId: browseId,
            title: title,
            subtitle: subtitle,
            thumbnailUrl: renderer.o("thumbnail").o("musicThumbnailRenderer").o("thumbnail").a("thumbnails").bestThumbnail(),
            type: browseType(forPageType: pageTypeOf(endpoint))
        )
    }

    /// A chart row that names an artist rather than a track — "Top artists" on the Charts page lists
    /// 40 of them with no song attached, so there is no `videoId` for parseResponsiveListItem to key
    /// off. Read here off the row's own `navigationEndpoint` instead and pointed at the artist page
    /// rather than dropped.
    private static func parseArtistRow(_ renderer: InnerTubeJSON?) -> ShelfItem? {
        guard let renderer else { return nil }
        let endpoint = renderer.o("navigationEndpoint").o("browseEndpoint")
        guard pageTypeOf(endpoint).contains("ARTIST"), let browseId = endpoint.s("browseId") else { return nil }
        let columns = renderer.a("flexColumns") ?? []
        let title = columns.first.o("musicResponsiveListItemFlexColumnRenderer").o("text").runs()
        if title.isBlankText { return nil }
        let subtitle = columns.element(at: 1).o("musicResponsiveListItemFlexColumnRenderer").o("text").runs()
        return ShelfItem(
            title: title,
            subtitle: subtitle,
            thumbnailUrl: renderer.o("thumbnail").o("musicThumbnailRenderer").o("thumbnail").a("thumbnails").bestThumbnail(),
            videoId: nil,
            browseId: browseId
        )
    }

    /// The artist / album pages a run list links out to, and their names.
    struct Credits: Hashable, Sendable {
        var artistId: String?
        var artistName: String?
        var albumId: String?
        var albumName: String?
    }

    private static func creditsOf(_ runs: [InnerTubeJSON]) -> Credits {
        var credits = Credits()
        for run in runs {
            let browse = run.o("navigationEndpoint").o("browseEndpoint")
            guard let id = browse.s("browseId") else { continue }
            let pageType = pageTypeOf(browse)
            if pageType.contains("ARTIST"), credits.artistId == nil {
                credits.artistId = id
                credits.artistName = run.s("text")
            } else if pageType.contains("ALBUM"), credits.albumId == nil {
                credits.albumId = id
                credits.albumName = run.s("text")
            }
        }
        return credits
    }

    /// Every name in the artist segment, including names without a browse link. YouTube alternates
    /// name and separator runs inside a bullet-delimited segment, but only some names are guaranteed
    /// to carry an artist endpoint.
    private static func artistNamesFromRuns(_ runs: [InnerTubeJSON]) -> String? {
        var groups: [[InnerTubeJSON]] = [[]]
        for run in runs {
            if run.s("text")?.trimmedText == "•" {
                groups.append([])
            } else {
                groups[groups.count - 1].append(run)
            }
        }
        guard let artistGroup = groups.first(where: { group in
            group.contains { pageTypeOf($0.o("navigationEndpoint").o("browseEndpoint")).contains("ARTIST") }
        }) else { return nil }
        let names = artistGroup.enumerated().compactMap { index, run -> String? in
            guard index % 2 == 0, let text = run.s("text")?.trimmedText, !text.isBlankText else { return nil }
            return text
        }.distinctElements()
        let joined = names.joined(separator: ", ")
        return joined.isBlankText ? nil : joined
    }

    /// Who a release page is billed to, off its own header.
    ///
    /// An album or single doesn't repeat the credit on every track — it says "Single • Dhanda
    /// Nyoliwala" once at the top and then lists bare titles, so every row read on its own comes back
    /// as "Unknown artist". The header is that missing credit, and carries the artist's browse id
    /// with it, so the long-press menu can still open the artist page from those rows.
    ///
    /// Only releases, never playlists: a playlist's header names whoever put it together, which is
    /// not what its tracks are by. Playlist rows carry their own credits anyway.
    static func pageCredit(_ root: InnerTubeJSON) -> Credits {
        guard let header = headerRenderer(root) else { return Credits() }
        // The current header hangs the artist off a strapline above the title; the older one packs
        // it into the subtitle, "Album • Artist • 2024".
        let lines = headerCreditLines.map { header.o($0).a("runs") ?? [] }
        // Split per line, not across them: the strapline and the subtitle are separate sentences,
        // and running them together would weld the artist onto the word that says this is a release.
        let parts = lines.flatMap { line in
            line.map { $0.s("text") ?? "" }.joined().splitText(anyOf: [" • ", " · "]).map(\.trimmedText)
        }
        if !parts.contains(where: { releaseWords.contains($0.lowercased()) }) { return Credits() }

        var credits = creditsOf(lines.flatMap { $0 })
        if let creditedArtists = lines.lazy.compactMap({ artistNamesFromRuns($0) }).first {
            credits.artistName = creditedArtists
            return credits
        }
        // An artist YouTube has no page for is named in the same line without a link to follow,
        // leaving the name as the only thing to go on.
        credits.artistName = parts.first {
            !$0.isBlankText && !typeWords.contains($0.lowercased()) && !Patterns.tally.matches($0)
                && !Patterns.year.matches($0) && !Patterns.duration.matches($0)
        }
        return credits
    }

    private static func headerRenderer(_ root: InnerTubeJSON) -> InnerTubeJSON? {
        headerRenderers.lazy.compactMap { collectRenderers(root, $0).first }.first
    }

    /// How an album or playlist page bills itself, off its own header.
    public struct BrowseHeader: Hashable, Sendable {
        public var title: String
        /// The line under it — "Album • Artist • 2024", or a playlist's blurb.
        public var subtitle: String
        public var thumbnailUrl: String?

        public init(title: String, subtitle: String, thumbnailUrl: String?) {
            self.title = title
            self.subtitle = subtitle
            self.thumbnailUrl = thumbnailUrl
        }
    }

    /// What a release or playlist page calls itself.
    ///
    /// Every other way into a detail page comes from a card that already carried the name and the
    /// cover. A YouTube Music link tapped outside the app carries a browse id and nothing else — see
    /// ``MusicLink`` — and a page with a blank title over a track list reads as half-loaded.
    static func parseBrowseHeader(_ root: InnerTubeJSON) -> BrowseHeader? {
        guard let header = headerRenderer(root) else { return nil }
        let title = header.o("title").runs()
        if title.isBlankText { return nil }
        // Current headers split the artist and release details across these two lines: the
        // strapline has the artist, while the subtitle holds "Album • 2024". Keep both; taking only
        // the first silently loses the release year on album pages.
        let subtitle = headerCreditLines
            .map { header.o($0).runs() }
            .filter { !$0.isBlankText }
            .distinctElements()
            .joined(separator: " • ")
        return BrowseHeader(
            title: title,
            subtitle: subtitle,
            // Header shapes drift — a cropped square here, a plain thumbnail there — so the first
            // image under the header is the cover.
            thumbnailUrl: collectRenderers(header, "musicThumbnailRenderer").first.o("thumbnail").a("thumbnails").bestThumbnail()
        )
    }

    /// The playlist that contains a catalogue album's complete track listing.
    ///
    /// Album browse pages can expose only a short preview even though their header reports the
    /// release's full song count. The play action points at the playlist that backs the release,
    /// which is the authoritative listing. The search stays scoped to the page header:
    /// recommendation shelves contain play actions for other releases too.
    static func parseAlbumPlaylistId(_ root: InnerTubeJSON) -> String? {
        if let header = headerRenderer(root) {
            if let id = collectRenderers(header, "musicPlayButtonRenderer").lazy.compactMap(playlistIdFromPlayAction).first {
                return id
            }
            if let id = collectRenderers(header, "buttonRenderer").lazy.compactMap(playlistIdFromPlayAction).first {
                return id
            }
        }
        // Some album layouts omit the header play button but repeat the same playlist in the
        // canonical album URL.
        guard let canonical = root.o("microformat").o("microformatDataRenderer").s("urlCanonical") else { return nil }
        let id = canonical.substring(after: "list=", missing: "").substring(before: "&")
        return id.isBlankText ? nil : id
    }

    private static func playlistIdFromPlayAction(_ element: InnerTubeJSON) -> String? {
        let endpoint = element.o("playNavigationEndpoint") ?? element.o("navigationEndpoint") ?? element
        return endpoint.o("watchPlaylistEndpoint").s("playlistId") ?? endpoint.o("watchEndpoint").s("playlistId")
    }

    /// The editorial blurb YouTube Music writes for a release or an artist — "About the album" /
    /// "About the artist" on the web player.
    ///
    /// It arrives as its own shelf (`musicDescriptionShelfRenderer`) on a current-layout page, but
    /// the field also turns up directly on the header on some responses, so both are tried. Absent
    /// from a playlist page, which is why callers only surface it for albums and artists.
    static func parseDescription(_ root: InnerTubeJSON) -> String? {
        let shelf = collectRenderers(root, "musicDescriptionShelfRenderer").first.o("description").runs()
        if !shelf.isBlankText { return shelf }
        for name in headerRenderers + ["musicImmersiveHeaderRenderer"] {
            let onHeader = collectRenderers(root, name).first.o("description").runs()
            if !onHeader.isBlankText { return onHeader }
        }
        return nil
    }

    // MARK: - Account

    /// The account header buried in the `account_menu` popup. Not every client gets an `email` back
    /// — some return only the @handle — so whichever is present is used as the secondary line.
    static func parseAccount(_ response: InnerTubeJSON) -> Account? {
        guard let header = collectRenderers(response, "activeAccountHeaderRenderer").first else { return nil }
        let name = header.o("accountName").runs()
        if name.isBlankText { return nil }
        var email = header.o("email").runs()
        if email.isBlankText { email = header.o("email").s("simpleText") ?? "" }
        if email.isBlankText { email = header.o("channelHandle").runs() }
        return Account(name: name, email: email, thumbnailUrl: header.o("accountPhoto").a("thumbnails").bestThumbnail())
    }

    /// The channels a switcher response offers, in the order YouTube lists them.
    ///
    /// Read by scanning for `accountItem` rather than by walking a fixed path: the two endpoints that
    /// produce this list (`account/accounts_list` and `getAccountSwitcherEndpoint`) wrap the same
    /// item renderer in different envelopes.
    ///
    /// The two tokens are likewise found by name anywhere inside the item. They arrive as a list of
    /// single-key objects under `supportedTokens`, in no promised order and alongside tokens meant
    /// for other purposes, so a positional read of that list would be a guess.
    ///
    /// An entry with neither token is dropped: there would be nothing to send for it, and offering a
    /// channel that silently keeps the current one is worse than not listing it.
    static func parseAccountChannels(_ root: InnerTubeJSON) -> [AccountChannel] {
        collectRenderers(root, "accountItem").compactMap { item -> AccountChannel? in
            var name = item.o("accountName").runs()
            if name.isBlankText { name = item.o("accountName").s("simpleText") ?? "" }
            if name.isBlankText { return nil }
            let pageId = item.findString("pageId")
            let dataSyncId = YouTubeWebLogin.normalizeDataSyncId(item.findString("datasyncIdToken"))
            if pageId == nil && dataSyncId == nil { return nil }
            var subtitle = item.o("channelHandle").runs()
            if subtitle.isBlankText { subtitle = item.o("channelHandle").s("simpleText") ?? "" }
            if subtitle.isBlankText { subtitle = item.o("accountByline").runs() }
            if subtitle.isBlankText { subtitle = item.o("accountByline").s("simpleText") ?? "" }
            return AccountChannel(
                name: name,
                subtitle: subtitle,
                thumbnailUrl: item.o("accountPhoto").a("thumbnails").bestThumbnail(),
                pageId: pageId,
                dataSyncId: dataSyncId,
                activeOnWeb: item["isSelected"]?.primitiveContent == "true"
            )
        }.distinct(by: \.key)
    }

    // MARK: - Watch queue

    /// Tracks of a watch queue (`next` response) — the AutoPlay radio mix.
    static func parseWatchQueue(_ root: InnerTubeJSON) -> [Song] {
        var order: [String] = []
        var byId: [String: Song] = [:]
        for renderer in collectRenderers(root, "playlistPanelVideoRenderer") {
            guard let videoId = renderer.s("videoId") else { continue }
            let title = renderer.o("title").runs()
            if title.isBlankText { continue }
            // The byline packs artist, views and likes into one run list; only the leading runs
            // before the first bullet are the credit.
            let bylineRuns = renderer.o("longBylineText").a("runs") ?? []
            let byline = bylineRuns.map { $0.s("text") ?? "" }
            let artist = byline.prefix { !$0.contains("•") }.joined().trimmedText
            // Those same runs link out to the artist and album pages, which is how a track started
            // from the queue knows where it came from.
            let credits = creditsOf(bylineRuns)
            let length = renderer.o("lengthText").runs()
            let song = Song(
                videoId: videoId,
                title: title,
                artist: artist,
                thumbnailUrl: renderer.o("thumbnail").a("thumbnails").bestThumbnail(),
                durationText: length.isBlankText ? nil : length,
                artistId: credits.artistId,
                albumId: credits.albumId,
                albumName: credits.albumName,
                // A catalogue track is credited "Artist • Album • Year"; the matching music video is
                // "Artist • 417M views • 2.4M likes".
                isVideo: byline.contains { $0.range(of: "views", options: .caseInsensitive) != nil },
                isExplicit: hasExplicitBadge(renderer)
            )
            if byId.updateValue(song, forKey: videoId) == nil { order.append(videoId) }
        }
        return order.compactMap { byId[$0] }
    }

    /// The account's own state for one track, read off the watch queue's row menu: the thumbs rating,
    /// and the tokens that toggle library membership.
    ///
    /// Read from `next` because there is nowhere cheaper — no endpoint answers "is this liked" on its
    /// own, and library membership is only ever expressed as a pair of opaque tokens attached to a
    /// rendered row. Scoped to `videoId`'s row: reading the first `likeButtonRenderer` in the
    /// response would answer for whichever track happened to be rendered first.
    static func parseSongMenu(_ root: InnerTubeJSON, videoId: String) -> SongMenu? {
        guard let row = collectRenderers(root, "playlistPanelVideoRenderer").first(where: { $0.s("videoId") == videoId }) else {
            return nil
        }
        // Nil, not .indifferent, for anything this row doesn't actually say — see
        // SongMenu.likeStatus. A missing like button and a stated "no rating" are different answers.
        let likeStatus: LikeStatus?
        switch collectRenderers(row, "likeButtonRenderer").first.s("likeStatus") {
        case "LIKE": likeStatus = .like
        case "DISLIKE": likeStatus = .dislike
        case "INDIFFERENT": likeStatus = .indifferent
        default: likeStatus = nil
        }

        // A row's menu carries several toggles that all hang a feedback token off the same endpoint
        // — "Don't recommend this", "Remove from history". Only the one wearing a library icon is
        // this one; taking the first token that turned up meant reading a stranger's state.
        let toggle = collectRenderers(row, "toggleMenuServiceItemRenderer").first {
            feedbackToken($0, "defaultServiceEndpoint") != nil && isLibraryToggle($0)
        }
        // A toggle states the action available *now* as its default and the way back as its toggled
        // half, so which icon leads also says whether the track is in the library already.
        let defaultAdds = toggle.o("defaultIcon").s("iconType") == "LIBRARY_ADD"
        let defaultToken = toggle.flatMap { feedbackToken($0, "defaultServiceEndpoint") }
        let toggledToken = toggle.flatMap { feedbackToken($0, "toggledServiceEndpoint") }
        return SongMenu(
            likeStatus: likeStatus,
            inLibrary: toggle != nil && !defaultAdds,
            addToLibraryToken: defaultAdds ? defaultToken : toggledToken,
            removeFromLibraryToken: defaultAdds ? toggledToken : defaultToken
        )
    }

    private static func feedbackToken(_ element: InnerTubeJSON, _ endpoint: String) -> String? {
        element.o(endpoint).o("feedbackEndpoint").s("feedbackToken")
    }

    /// Whether a toggle menu item is the library one, told by its icons rather than by its label —
    /// the label is localised, the icon type never is.
    private static func isLibraryToggle(_ element: InnerTubeJSON) -> Bool {
        libraryIcons.contains { element.o("defaultIcon").s("iconType") == $0 || element.o("toggledIcon").s("iconType") == $0 }
    }

    private static let libraryIcons = ["LIBRARY_ADD", "LIBRARY_REMOVE", "LIBRARY_SAVED"]

    // MARK: - Library state and ownership

    /// Whether the album or playlist a browse response describes is in the library, and the id that
    /// would change that — see ``LibraryState``.
    ///
    /// A release's save control is a `toggleButtonRenderer` wearing YouTube's bookmark icons, *not* a
    /// like button: every track row on the page carries a `likeButtonRenderer` aimed at its own
    /// video, and the release carries none at all.
    ///
    /// The id is read from the header's *play* button, because it isn't the browse id the page was
    /// fetched with: an `MPREb…` album is backed by an `OLAK5uy_…` playlist. Scoped to the header
    /// rather than walked for: an album page's "more from this artist" carousel is full of *other*
    /// releases' playlist ids, ahead of the header in document order.
    ///
    /// Nil when the header has no save button to read: a continuation, a signed-out page, an
    /// auto-playlist, or a release YouTube marks unsaveable.
    static func parseLibraryState(_ root: InnerTubeJSON) -> LibraryState? {
        let buttons = collectRenderers(root, "musicResponsiveHeaderRenderer").first.a("buttons") ?? []
        guard let save = buttons.lazy.compactMap({ button -> InnerTubeJSON? in
            guard let toggle = button.o("toggleButtonRenderer"), isSaveToggle(toggle) else { return nil }
            return toggle
        }).first else { return nil }
        if save.s("isDisabled") == "true" { return nil }
        // A play button states the release as a playlist, which is the one thing on the page that
        // names what saving would act on.
        let play = buttons.lazy.compactMap { $0.o("musicPlayButtonRenderer").o("playNavigationEndpoint") }.first
        guard let playlistId = play.o("watchPlaylistEndpoint").s("playlistId") ?? play.o("watchEndpoint").s("playlistId") else {
            return nil
        }
        // The toggle carries the answer directly: a button that is *shown* toggled is one whose
        // release is already saved.
        return LibraryState(playlistId: playlistId, saved: save.s("isToggled") == "true")
    }

    /// Whether a header toggle is the save-to-library one rather than the description's expander,
    /// told by its icons. Bookmarks, not the `LIBRARY_*` icons a track's menu uses.
    private static func isSaveToggle(_ element: InnerTubeJSON?) -> Bool {
        element.o("defaultIcon").s("iconType") == "BOOKMARK_BORDER" || element.o("toggledIcon").s("iconType") == "BOOKMARK"
    }

    /// Whether a playlist page is one the account *made*, rather than one it merely saved — nil when
    /// the response doesn't say either way.
    ///
    /// The library feed lists a stranger's playlist this account saved in exactly the same shape as
    /// one it created, which is how Rename and Delete came to be offered on someone else's playlist.
    /// The page answers three ways over:
    ///  - An own playlist's header comes wrapped in `musicEditablePlaylistDetailHeaderRenderer`.
    ///  - Its header menu carries the Edit and Delete rows (read by icon, not label).
    ///  - Its header carries no save bookmark, and a saved playlist's always does.
    ///
    /// Any one of the three is enough: reading "saved" as "own" offers a Delete the edit endpoint
    /// then refuses, while reading "own" as "saved" silently takes Rename and Delete away.
    static func parsePlaylistOwned(_ root: InnerTubeJSON) -> Bool? {
        if !collectRenderers(root, "musicEditablePlaylistDetailHeaderRenderer").isEmpty { return true }
        // Scoped to the header, not walked for: every track row carries its own menu, and a row's
        // "Remove from playlist" would answer for the row rather than for the playlist.
        guard let header = collectRenderers(root, "musicResponsiveHeaderRenderer").first else { return nil }
        if collectRenderers(header, "menuNavigationItemRenderer").contains(where: {
            ownerIcons.contains($0.o("icon").s("iconType") ?? "")
        }) {
            return true
        }
        return !(header.a("buttons") ?? []).contains { isSaveToggle($0.o("toggleButtonRenderer")) }
    }

    private static let ownerIcons: Set<String> = ["DELETE", "EDIT"]

    /// The playlists the account can be asked to add a track to.
    ///
    /// `FEmusic_liked_playlists` also carries the "New playlist" tile (no browse id), the Liked Music
    /// auto-playlist and YouTube's own generated mixes — none of which take an edit. Filtered by
    /// exclusion rather than by requiring a `PL` prefix: a list that quietly drops the user's own
    /// playlist is worse than one that offers a playlist the edit endpoint then refuses. Ownership
    /// isn't decided here — see ``parsePlaylistOwned(_:)``.
    static func parseUserPlaylists(_ root: InnerTubeJSON) -> [UserPlaylist] {
        parseUserPlaylists(parseLibraryItems(root))
    }

    static func parseUserPlaylists(_ items: [ShelfItem]) -> [UserPlaylist] {
        items.compactMap { item in
            guard let browseId = item.browseId, browseId.hasPrefix("VL") else { return nil }
            if notEditable.contains(where: { browseId.hasPrefix("VL\($0)") }) { return nil }
            return UserPlaylist(playlistId: browseId.removingPrefix("VL"), title: item.title, subtitle: item.subtitle, thumbnailUrl: item.thumbnailUrl)
        }
    }

    private static func parseTwoRowItem(_ renderer: InnerTubeJSON?) -> ShelfItem? {
        guard let renderer else { return nil }
        let title = renderer.o("title").runs()
        if title.isBlankText { return nil }
        let endpoint = renderer.o("navigationEndpoint")
        let browseId = endpoint.o("browseEndpoint").s("browseId")
        // History/"Listen again" cards for tracks YouTube never catalogued as a proper Song carry no
        // watchEndpoint at all — just a browseId to a "non-music audio track page" prefixed
        // MPED<videoId>. That's the actual video id, not a real browsable page.
        let videoId = endpoint.o("watchEndpoint").s("videoId")
            ?? browseId.flatMap { $0.hasPrefix("MPED") ? $0.removingPrefix("MPED") : nil }
        let resolvedBrowseId = browseId.flatMap { $0.hasPrefix("MPED") ? nil : $0 }
        let thumbnails = renderer.o("thumbnailRenderer").o("musicThumbnailRenderer").o("thumbnail").a("thumbnails")
        let subtitle = renderer.o("subtitle").runs()
        // A card with no browse target is a playable track; widescreen art on one of those means
        // it's a music-video upload rather than the catalogue track — drop it.
        if resolvedBrowseId == nil, videoId != nil, thumbnails.isNotSquare() { return nil }
        // An album/playlist billed as a video chart/compilation is the same dead-end as in
        // parseBrowseItem. A plain track card is exempt: a song can legitimately be titled "Video
        // Games" without being a music-video upload.
        if let resolvedBrowseId,
           !resolvedBrowseId.hasPrefix("VL"), !resolvedBrowseId.hasPrefix("PL"),
           !resolvedBrowseId.hasPrefix("MPRE"), !resolvedBrowseId.hasPrefix("UC"),
           Patterns.videoWord.containsMatch(in: title) || Patterns.videoWord.containsMatch(in: subtitle) {
            return nil
        }
        return ShelfItem(title: title, subtitle: subtitle, thumbnailUrl: thumbnails.bestThumbnail(), videoId: videoId, browseId: resolvedBrowseId)
    }

    /// The credit out of a shelf card's subtitle, which reads "Song • Chelsea Wolfe" rather than just
    /// the artist. The card keeps the whole line because it shows it as billed, but starting a radio
    /// off the card and carrying that line into ``Song/artist`` would print the label everywhere the
    /// field is read afterwards: the player, a shared link, a scrobble.
    public static func artistFromSubtitle(_ subtitle: String) -> String {
        let parts = subtitle.splitText(" • ").map(\.trimmedText).filter { !$0.isBlankText }
        return parts.first {
            !typeWords.contains($0.lowercased()) && !Patterns.tally.matches($0) && !Patterns.duration.matches($0)
        } ?? subtitle
    }

    /// Playlist-id prefixes nothing can be added to: `LM` is Liked Music (a song joins it by being
    /// liked), `SE` is Episodes for Later, `RD` is a generated radio mix, and `OLAK`/`MPRE` are
    /// albums wearing a playlist id.
    private static let notEditable = ["LM", "SE", "RD", "OLAK", "MPRE"]

    /// YouTube nests this badge differently across search, album and queue renderers. Nil (not
    /// false) when absent: several renderer shapes simply omit badges, which is no proof of a clean
    /// edition.
    private static func hasExplicitBadge(_ element: InnerTubeJSON?) -> Bool? {
        func contains(_ node: InnerTubeJSON) -> Bool {
            switch node {
            case .string(let text): return text == "MUSIC_EXPLICIT_BADGE"
            case .array(let array): return array.contains(where: contains)
            case .object(let object): return object.values.contains(where: contains)
            default: return false
            }
        }
        guard let element, contains(element) else { return nil }
        return true
    }

    // MARK: - Lyrics

    /// The Lyrics tab's browse endpoint out of a `next` response, if the track has one.
    ///
    /// Found by the tab's title rather than its position (the tabs are Up next, Lyrics, Related),
    /// falling back to the first browse endpoint on any tab after the first.
    static func lyricsEndpoint(_ next: InnerTubeJSON) -> (browseId: String, params: String?)? {
        let tabs = objectsNamed(next, "tabRenderer")
        let endpoint = tabs.first { tab in youtubeStrings(tab).contains { $0.caseInsensitiveCompare("Lyrics") == .orderedSame } }
            .flatMap { objectsNamed($0, "browseEndpoint").first }
            ?? tabs.dropFirst().lazy.compactMap { objectsNamed($0, "browseEndpoint").first }.first
        guard let browseId = endpoint.s("browseId") else { return nil }
        return (browseId, endpoint.s("params"))
    }

    /// Objects stored under `name` anywhere in the tree, each yielded where its key sits among its
    /// siblings (the lyrics code's walk, which differs from ``collectRenderers(_:_:)`` only in that
    /// ordering detail).
    static func objectsNamed(_ root: InnerTubeJSON, _ name: String) -> [InnerTubeJSON] {
        var out: [InnerTubeJSON] = []
        func walk(_ node: InnerTubeJSON) {
            switch node {
            case .object(let object):
                for (key, value) in object.entries {
                    if key == name, case .object = value { out.append(value) }
                    walk(value)
                }
            case .array(let array):
                for value in array { walk(value) }
            default:
                break
            }
        }
        walk(root)
        return out
    }

    /// The plain lyrics text on a Lyrics-tab browse page, one entry per non-blank line; nil when the
    /// page says "Lyrics not available".
    static func parseLyrics(_ page: InnerTubeJSON) -> [String]? {
        guard let shelf = objectsNamed(page, "musicDescriptionShelfRenderer").first,
              let description = shelf["description"] else { return nil }
        let text = youtubeStrings(description).joined().trimmedText
        let lines = text.components(separatedBy: CharacterSet(charactersIn: "\r\n")).map(\.trimmedText).filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines
    }

    /// The source line under a lyrics page ("Source: Musixmatch"), when it names one.
    static func parseLyricsSource(_ page: InnerTubeJSON) -> String? {
        let footer = objectsNamed(page, "musicDescriptionShelfRenderer").first.o("footer").runs()
        return footer.isBlankText ? nil : footer
    }

    /// Timed caption cues out of a `get_transcript` response, sorted by start.
    static func parseTranscript(_ response: InnerTubeJSON) -> [InnerTubeTranscriptCue]? {
        let cues = objectsNamed(response, "transcriptCueRenderer").compactMap { cue -> InnerTubeTranscriptCue? in
            guard let start = cue.s("startOffsetMs").flatMap({ Int64($0) }) else { return nil }
            let text = cue["cue"].map { youtubeStrings($0).joined() } ?? ""
            let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: " \n♪"))
            return trimmed.isEmpty ? nil : InnerTubeTranscriptCue(startMs: start, text: trimmed)
        }.sorted { $0.startMs < $1.startMs }
        return cues.isEmpty ? nil : cues
    }

    /// Every text a subtree says: an object's own `text`/`simpleText` when it has one, else its
    /// children's, in order.
    static func youtubeStrings(_ element: InnerTubeJSON) -> [String] {
        switch element {
        case .string, .number, .bool:
            return element.primitiveContent.map { [$0] } ?? []
        case .null:
            return []
        case .array(let array):
            return array.flatMap(youtubeStrings)
        case .object(let object):
            if let direct = object["text"]?.primitiveContent ?? object["simpleText"]?.primitiveContent { return [direct] }
            return object.values.flatMap(youtubeStrings)
        }
    }

    // MARK: - Patterns and word lists

    enum Patterns {
        static let duration = TextPattern(#"\d+:\d{2}"#)
        static let year = TextPattern(#"\d{4}"#)
        /// A counted quantity rather than a name — "12.4M plays", "13 songs", "1 hour, 4 minutes".
        /// Deliberately narrow: it has to leave "21 Savage" and "50 Cent" alone, so a number only
        /// disqualifies a segment when it is counting one of the words YouTube counts with.
        static let tally = TextPattern(
            #"[\d.,]+\s*[KMB]?\s+(plays|views|likes|songs|tracks|subscribers|hours?|minutes?|seconds?)\b.*"#,
            caseInsensitive: true
        )
        /// Flags a browse card as video content: "50 videos" in a subtitle (instead of "50 songs"),
        /// or the word right in a title like "Daily Top Music Videos".
        static let videoWord = TextPattern(#"\bvideos?\b"#, caseInsensitive: true)
    }

    /// Header words that mark a page as a release, whose rows share its credit.
    private static let releaseWords: Set<String> = ["album", "single", "ep"]
    private static let headerRenderers = ["musicResponsiveHeaderRenderer", "musicDetailHeaderRenderer"]
    /// Header lines that name the artist, in either header shape.
    private static let headerCreditLines = ["straplineTextOne", "subtitle"]
    private static let typeWords: Set<String> = [
        "song", "video", "album", "single", "ep", "artist", "playlist", "podcast", "episode",
    ]
}

/// One timed line of a YouTube caption transcript.
public struct InnerTubeTranscriptCue: Hashable, Sendable {
    public var startMs: Int64
    public var text: String

    public init(startMs: Int64, text: String) {
        self.startMs = startMs
        self.text = text
    }
}

extension Array {
    /// Kotlin's `getOrNull`.
    func element(at index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
