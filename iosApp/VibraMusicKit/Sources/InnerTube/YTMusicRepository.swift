import Foundation
import VibraMusicCore

// Ports data/YtMusicRepository.kt.

/// Finds a track's other version — the catalogue audio of a music video, or the video of a catalogue
/// track — among search candidates.
///
/// Android does this with `TrackMatcher` from the Sources module; InnerTube can't depend on that
/// module, so the app passes its matcher in.
public protocol SongVersionMatching: Sendable {
    /// The search queries to try, most specific first.
    func searchQueries(for song: Song) -> [String]
    /// The candidate that is really `song` (same recording), or nil.
    func bestMatch(among candidates: [Song], for song: Song) -> Song?
    /// The official catalogue audio for a music video when only runtime disagrees (videos carry
    /// visual intros and outros), or nil.
    func bestOfficialAudio(forVideo song: Song, among candidates: [Song]) -> Song?
}

extension SongVersionMatching {
    public func bestOfficialAudio(forVideo song: Song, among candidates: [Song]) -> Song? { nil }
}

/// The YouTube Music API as the app uses it: feeds, search, pages, library and account writes.
///
/// Android returned `Result<T>` from every call so the UI could show a real error; here calls are
/// `async throws` (``InnerTubeError`` for Innertube's own failures, `URLError` for transport), and
/// cancellation propagates as `CancellationError` rather than being reported as a failure. A call
/// whose session is rejected (HTTP 401/403) refreshes the session scope once and retries — cookies
/// rotate while the app is alive — but never loops and never signs the listener out.
public final class YTMusicRepository: Sendable {
    public let client: InnerTubeClient
    private let likeState: LikeState?
    private let caches = RepositoryCaches()
    static let log = "InnerTube"

    /// - Parameters:
    ///   - client: the Innertube session to call through.
    ///   - likeState: where liked ids are seeded; nil means ``LikeState/shared``.
    public init(client: InnerTubeClient = .shared, likeState: LikeState? = nil) {
        self.client = client
        self.likeState = likeState
    }

    // MARK: - Home

    /// The core personalised feed, with FEmusic_home's own continuation for ``moreHome(token:)``.
    /// Deliberately independent from the optional shelves below, so it can be painted immediately.
    /// Signed in, the continuation keeps paging into mood mixes and more personalised shelves;
    /// signed out it comes back empty.
    public func home() async throws -> HomeFeed {
        try await call("home") {
            let home = try await self.client.browse("FEmusic_home")
            return HomeFeed(shelves: InnerTubeParser.parseHome(home), continuation: InnerTubeParser.continuationToken(home))
        }
    }

    /// "Recently played", rendered independently at the top of the Home page. Nil signed out, and
    /// when the history is empty.
    public func homeRecentlyPlayed() async throws -> HomeShelf? {
        try await call("home:recent") { try await self.recentlyPlayed() }
    }

    /// Extra Home shelves, independently fetchable so each can appear as soon as it arrives.
    public func homeSupplement(browseId: String) async throws -> [HomeShelf] {
        try await call("home:\(browseId)") { try await self.shelves(of: browseId) }
    }

    public static let homeSupplementBrowseIds = ["FEmusic_new_releases", "FEmusic_explore"]

    /// More Home shelves past ``home()``'s first page, following FEmusic_home's own continuation.
    /// "Recently played" and the supplements are one-shot and don't participate.
    public func moreHome(token: String) async throws -> HomeFeed {
        try await call("home:more") {
            let response = try await self.client.browseContinuation(token)
            return HomeFeed(
                shelves: InnerTubeParser.parseHomeContinuation(response),
                continuation: InnerTubeParser.continuationToken(response)
            )
        }
    }

    /// The lead shelf: the account's listening history, newest first.
    ///
    /// YouTube's home already carries a "Listen again", but it ranks by how *often* something has
    /// been played rather than how recently, so it keeps leading with last month's favourites for
    /// days after a change of mood. The history feed reflects a play the moment it's registered.
    private func recentlyPlayed() async throws -> HomeShelf? {
        let songs: [Song]
        if await client.isSignedIn {
            songs = (try? await fetchHistory()) ?? []
        } else {
            songs = []
        }
        let recent = Array(songs.distinct(by: \.videoId).prefix(Self.recentLimit))
        if recent.isEmpty { return nil }
        return HomeShelf(
            title: Self.recentTitle,
            items: recent.map { ShelfItem(title: $0.title, subtitle: $0.artist, thumbnailUrl: $0.thumbnailUrl, videoId: $0.videoId, browseId: nil) }
        )
    }

    /// The raw fetch behind the recents shelf and ``history()``: one row per track, newest first.
    /// A track played three times today is three rows in the feed; the dedupe costs the times, which
    /// is fine for "what you have been listening to".
    private func fetchHistory() async throws -> [Song] {
        InnerTubeParser.collectSongsDeep(try await client.browse(Self.historyBrowseId)).distinct(by: \.videoId)
    }

    /// The account's listening history, in the order YouTube Music keeps it — the page opened when
    /// the recents shelf's twenty is not enough.
    public func history() async throws -> [Song] {
        try await call("history") { try await self.fetchHistory() }
    }

    /// Account listening history for the Recents feed (CarPlay's browse tree); empty signed out.
    public func recents() async throws -> [Song] {
        try await call("recents") {
            if await self.client.isSignedIn, let history = try? await self.fetchHistory(), !history.isEmpty {
                return history
            }
            return []
        }
    }

    /// Recommended discovery tracks for Quick Picks, excluding `excludedIds` (the recents).
    ///
    /// Tried in order until something is left: a "quick picks"/"mix"/"recommend" shelf on Home; every
    /// Home shelf but the first and anything history-flavoured; any Home track; New releases; and
    /// finally whatever was found even if all of it was excluded.
    public func quickPicks(excluding excludedIds: Set<String> = []) async throws -> [Song] {
        try await call("quickPicks") {
            let shelves = (try? await self.client.browse("FEmusic_home")).map(InnerTubeParser.parseHome) ?? []
            func songs(_ shelves: [HomeShelf], excluding: Set<String>) -> [Song] {
                shelves.flatMap { shelf in
                    shelf.items.compactMap { item -> Song? in
                        guard let id = item.videoId, !excluding.contains(id) else { return nil }
                        return Song(videoId: id, title: item.title, artist: InnerTubeParser.artistFromSubtitle(item.subtitle), thumbnailUrl: item.thumbnailUrl)
                    }
                }
            }
            if let shelf = shelves.first(where: { shelf in
                ["quick", "pick", "mix", "recommend"].contains { shelf.title.range(of: $0, options: .caseInsensitive) != nil }
            }) {
                let picks = songs([shelf], excluding: excludedIds)
                if !picks.isEmpty { return picks }
            }
            let candidates = shelves.count > 1
                ? shelves.dropFirst().filter { shelf in
                    !["recent", "history", "listen again"].contains { shelf.title.range(of: $0, options: .caseInsensitive) != nil }
                }
                : shelves
            let fromHome = songs(Array(candidates), excluding: excludedIds).distinct(by: \.videoId)
            if !fromHome.isEmpty { return fromHome }

            let allHome = songs(shelves, excluding: []).distinct(by: \.videoId)
            let unique = allHome.filter { !excludedIds.contains($0.videoId) }
            if !unique.isEmpty { return unique }

            let explore = (try? await self.shelves(of: "FEmusic_new_releases")) ?? []
            let fromExplore = songs(explore, excluding: excludedIds).distinct(by: \.videoId)
            if !fromExplore.isEmpty { return fromExplore }

            return allHome.isEmpty ? fromExplore : allHome
        }
    }

    static let historyBrowseId = "FEmusic_history"
    static let recentTitle = "Recents"
    /// Enough to scroll through, short of turning the shelf into the history page.
    static let recentLimit = 20

    private func shelves(of browseId: String) async throws -> [HomeShelf] {
        InnerTubeParser.parseHome(try await client.browse(browseId))
    }

    // MARK: - Explore

    /// The server-defined mood and genre categories shown on Explore.
    public func moodAndGenres() async throws -> [MoodGenreSection] {
        try await call("moods-and-genres") {
            InnerTubeParser.parseMoodAndGenres(try await self.client.browse("FEmusic_moods_and_genres"))
        }
    }

    /// The playlist shelves behind one mood/genre category. Cached: the result also supplies the
    /// category tile's artwork, so a tap on a category whose cover already appeared costs nothing.
    public func moodGenreShelves(browseId: String, params: String?) async throws -> [HomeShelf] {
        let key = "\(browseId):\(params ?? "")"
        if let cached = await caches.moodGenre(key) { return cached }
        let shelves = try await call("mood-genre:\(browseId)") {
            InnerTubeParser.parseHome(try await self.client.browse(browseId, params: params))
        }
        await caches.storeMoodGenre(shelves, for: key)
        return shelves
    }

    /// A category card borrows the first real cover from the playlists it opens.
    public func moodGenreArtwork(browseId: String, params: String?) async throws -> String? {
        try await moodGenreShelves(browseId: browseId, params: params)
            .lazy.flatMap(\.items).compactMap(\.thumbnailUrl).first
    }

    // MARK: - Search

    /// Fetches only the first search page. Publishing it immediately keeps search responsive; the
    /// UI asks ``searchContinuation(token:filter:)`` for later pages as the list nears its end.
    public func searchPage(query: String, filter: SearchFilter) async throws -> InnerTubeParser.SearchPage {
        try await call("search:\(filter.rawValue)") {
            Self.deduplicated(InnerTubeParser.parseSearchPage(
                try await self.client.search(query, params: filter.params),
                includeVideos: filter == .videos
            ))
        }
    }

    /// The next page of a search, only when the result list needs it.
    public func searchContinuation(token: String, filter: SearchFilter) async throws -> InnerTubeParser.SearchPage {
        try await call("search:continuation") {
            Self.deduplicated(InnerTubeParser.parseSearchPage(
                try await self.client.searchContinuation(token),
                includeVideos: filter == .videos
            ))
        }
    }

    /// The first, most relevant page only — for callers that need candidates rather than a
    /// scrolling result screen (autoplay fallbacks, version matching).
    public func search(query: String, filter: SearchFilter) async throws -> [SearchResult] {
        try await searchPage(query: query, filter: filter).rows
    }

    /// What YouTube Music would suggest completing `input` to. Unfiltered on purpose: a suggestion
    /// is a query, and which tab it runs against is the user's to pick afterwards.
    public func searchSuggestions(input: String) async throws -> [String] {
        try await call("suggest") {
            InnerTubeParser.parseSearchSuggestions(try await self.client.searchSuggestions(input))
        }
    }

    /// Live media results for the typeahead phase, so the dropdown can show playable cards beside
    /// the text completions. Deliberately unauthenticated (see
    /// ``InnerTubeClient/searchTypeahead(_:)``); confirmed searches go through
    /// ``searchPage(query:filter:)`` and are recorded properly.
    public func searchTypeahead(input: String) async throws -> InnerTubeParser.SearchPage {
        try await call("typeahead") {
            Self.deduplicated(InnerTubeParser.parseSearchPage(try await self.client.searchTypeahead(input), includeVideos: false))
        }
    }

    private static func deduplicated(_ page: InnerTubeParser.SearchPage) -> InnerTubeParser.SearchPage {
        InnerTubeParser.SearchPage(rows: page.rows.distinct(by: identityKey), continuation: page.continuation)
    }

    private static func identityKey(_ result: SearchResult) -> String {
        switch result {
        case .topTrack(let song), .track(let song): return "v:\(song.videoId)"
        case .browse(let item): return "b:\(item.browseId)"
        }
    }

    // MARK: - Versions (song ↔ music video)

    public func cachedAudioVersion(videoId: String) async -> Song? { await caches.audioVersion(videoId) }
    public func cachedVideoVersion(videoId: String) async -> Song? { await caches.videoVersion(videoId)?.song }

    /// The catalogue (audio-only) release of a music-video upload, found the way the "Switch to
    /// audio" toggle in the official app lands on it: searching the title and artist and taking the
    /// closest song match through `matcher`.
    ///
    /// Returns `song` unchanged when it isn't a video, or when nothing better turns up — playing the
    /// video's own audio beats guessing at a substitute (a Telugu folk video once resolved to an
    /// unrelated devotional track from exactly this path). The answer is remembered either way, so
    /// the prefetcher and the eventual player switch agree on the same rendition. Search already
    /// drops video rows outside the Videos filter, so every candidate is audio-only.
    public func resolveAudio(for song: Song, using matcher: some SongVersionMatching) async -> Song {
        guard song.isVideo else { return song }
        if let cached = await caches.audioVersion(song.videoId) { return cached }
        for query in matcher.searchQueries(for: song) {
            let candidates = ((try? await search(query: query, filter: .songs)) ?? []).compactMap { result -> Song? in
                if case .track(let found) = result { return found }
                return nil
            }
            if let match = matcher.bestMatch(among: candidates, for: song) {
                DebugLog.d(Self.log, "audio switch: '\(song.title)' -> '\(match.title)' (\(query))")
                await caches.storeAudioVersion(match, for: song.videoId)
                return match
            }
            // Music-video timing is visual timing, not the audio release's timing, so the manual
            // switch may use the exact official song/artist match despite a long intro or outro.
            if let match = matcher.bestOfficialAudio(forVideo: song, among: candidates) {
                DebugLog.d(Self.log, "audio switch: accepted video/runtime drift '\(song.title)' -> '\(match.title)' (\(query))")
                await caches.storeAudioVersion(match, for: song.videoId)
                return match
            }
        }
        DebugLog.w(Self.log, "audio switch: no official song match for '\(song.title)' by '\(song.artist)'")
        await caches.storeAudioVersion(song, for: song.videoId)
        return song
    }

    /// The inverse of ``resolveAudio(for:using:)``: the music video of a catalogue track, or nil when
    /// there isn't one (also remembered).
    public func resolveVideo(for song: Song, using matcher: some SongVersionMatching) async -> Song? {
        guard !song.isVideo else { return nil }
        if let cached = await caches.videoVersion(song.videoId) { return cached.song }
        for query in matcher.searchQueries(for: song) {
            let candidates = ((try? await search(query: query, filter: .videos)) ?? []).compactMap { result -> Song? in
                if case .track(let found) = result { return found }
                return nil
            }
            if let match = matcher.bestMatch(among: candidates, for: song) {
                DebugLog.d(Self.log, "video switch: '\(song.title)' -> '\(match.title)' (\(query))")
                await caches.storeVideoVersion(match, for: song.videoId)
                return match
            }
        }
        DebugLog.w(Self.log, "video switch: no video match for '\(song.title)' by '\(song.artist)'")
        await caches.storeVideoVersion(nil, for: song.videoId)
        return nil
    }

    // MARK: - Account

    /// Signed-in profile for the settings header.
    public func account() async throws -> Account {
        try await call("account") {
            guard let account = InnerTubeParser.parseAccount(try await self.client.accountMenu()) else {
                throw InnerTubeError.missingData("No account details")
            }
            return account
        }
    }

    /// The channels this login can act as — its own, plus any brand channels.
    ///
    /// Two endpoints are asked in turn because either can come back with no `accountItem` at all, and
    /// the two do not fail together. An empty list from the first is not an answer — it is a shape
    /// the parser didn't recognise — so it is treated the same as a failure.
    public func accountChannels() async throws -> [AccountChannel] {
        try await call("channels") {
            do {
                let viaInnertube = InnerTubeParser.parseAccountChannels(try await self.client.accountsList())
                if !viaInnertube.isEmpty { return viaInnertube }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                DebugLog.w(Self.log, "accounts_list unavailable: \(error.localizedDescription)")
            }
            return InnerTubeParser.parseAccountChannels(try await self.client.accountSwitcher())
        }
    }

    // MARK: - Library

    /// Liked Music: the `LM` auto-playlist, addressed as a playlist browse id. Also the page a track
    /// has to disappear from the moment it stops being liked.
    public static let likedMusicBrowseId = "VLLM"
    /// Songs explicitly added to the library — distinct from Liked Music.
    static let librarySongsBrowseId = "FEmusic_liked_videos"
    /// Saved and own playlists; also what the "add to playlist" picker lists.
    static let libraryPlaylistsBrowseId = "FEmusic_liked_playlists"
    /// What the playlists shelf is called in a ``LibraryPage`` — the one shelf anything else looks for
    /// by name (the create tile leads it; rename and delete reach into it).
    public static let playlistsShelfTitle = "Playlists"
    /// Library shelves in display order.
    public static let libraryFeeds: [(title: String, browseId: String)] = [
        (playlistsShelfTitle, libraryPlaylistsBrowseId),
        ("Albums", "FEmusic_liked_albums"),
        ("Artists", "FEmusic_library_corpus_track_artists"),
        ("Subscriptions", "FEmusic_library_corpus_artists"),
        ("Podcasts", "FEmusic_library_non_music_audio_list"),
    ]
    /// A runaway feed can't hold a background load open forever.
    public static let maxPages = 10

    /// The whole library in one shot — requires a signed-in session.
    ///
    /// YouTube Music has no single "my library" feed: Liked Music is the `LM` auto-playlist, library
    /// songs are a separate feed, and every saved collection has its own browse id. They're fetched
    /// in parallel, and a feed that fails or is simply empty is dropped rather than failing the page.
    ///
    /// Liked Music is read one page at a time: the first page fills the Library tab and seeds
    /// ``LikeState``; the rest is synced in the background with ``syncLikedMusic(from:loadNext:)``
    /// using ``LibraryPage/likedContinuation``, so a liked track past the first page still reads as
    /// liked without holding this page open.
    public func library() async throws -> LibraryPage {
        try await call("library") {
            async let liked = try? self.browseSongs(browseId: Self.likedMusicBrowseId)
            async let added = (try? self.songsPaged(Self.librarySongsBrowseId)) ?? []
            let shelves = await withTaskGroup(of: (Int, HomeShelf).self) { group -> [HomeShelf] in
                for (index, feed) in Self.libraryFeeds.enumerated() {
                    group.addTask {
                        (index, HomeShelf(title: feed.title, items: (try? await self.itemsPaged(feed.browseId)) ?? []))
                    }
                }
                var collected: [(Int, HomeShelf)] = []
                for await result in group { collected.append(result) }
                return collected.sorted { $0.0 < $1.0 }.map(\.1).filter { !$0.items.isEmpty }
            }
            let likedPage = await liked
            let likedSongs = likedPage?.songs ?? []
            let likedIds = Set(likedSongs.map(\.videoId))
            await self.seedLiked(likedIds)
            return LibraryPage(
                likedSongs: likedSongs,
                // Thumbs-up'd tracks are also in the library feed; only what Liked Music doesn't
                // already cover is worth a second section.
                librarySongs: await added.filter { !likedIds.contains($0.videoId) },
                shelves: shelves,
                likedContinuation: likedPage?.continuation
            )
        }
    }

    /// Finishes syncing the liked collection into ``LikeState``, following `firstToken` page by page
    /// until the feed runs dry.
    ///
    /// Deliberately unbounded, unlike ``maxPages``: it seeds only video ids, so a long Liked Music
    /// library stays cheap, and stopping at a page cap would leave every liked track past that page
    /// reading as "not liked" (kushagrasinghx/Vibra Music#219). Guards only against a token repeating: a page
    /// pointing back at one already read would otherwise spin forever. A failed page (nil) ends the
    /// sync quietly; cancellation stops it before the next page is seeded.
    ///
    /// - Parameter loadNext: reads one page; defaults to ``moreSongs(token:)`` with failures read as
    ///   the end of the feed. Injectable so the loop is testable.
    public func syncLikedMusic(
        from firstToken: String?,
        loadNext: (@Sendable (String) async -> SongPage?)? = nil
    ) async {
        guard let firstToken else { return }
        let load = loadNext ?? { [self] token in try? await self.moreSongs(token: token) }
        var seen = Set<String>()
        var next: String? = firstToken
        while let token = next, seen.insert(token).inserted {
            guard let page = await load(token) else { return }
            if Task.isCancelled { return }
            await seedLiked(Set(page.songs.map(\.videoId)))
            next = page.continuation
        }
    }

    private func seedLiked(_ ids: Set<String>) async {
        let target = likeState
        await MainActor.run { (target ?? LikeState.shared).seedLiked(ids) }
    }

    /// The playlists a track can be added to. Paged, because accounts with long playlist collections
    /// otherwise lose everything past YouTube's first library-feed response.
    public func userPlaylists() async throws -> [UserPlaylist] {
        try await call("playlists") {
            InnerTubeParser.parseUserPlaylists(try await self.itemsPaged(Self.libraryPlaylistsBrowseId))
        }
    }

    /// Every playlist in the library, Liked Music and saved playlists included (first page).
    public func libraryPlaylists() async throws -> [ShelfItem] {
        try await call("libraryPlaylists") {
            InnerTubeParser.parseLibraryItems(try await self.client.browse(Self.libraryPlaylistsBrowseId))
        }
    }

    /// Every card behind a feed or "more" browse id (an artist's full Albums or Singles shelf, a
    /// library feed), following continuations up to ``maxPages`` — the "Show all" page.
    public func shelfItems(browseId: String, params: String? = nil) async throws -> [ShelfItem] {
        try await call("items:\(browseId)") { try await self.itemsPaged(browseId, params: params) }
    }

    // MARK: - Pages

    /// One page of a browse feed's tracks, and the token for the page after it.
    public struct SongPage: Hashable, Sendable {
        public var songs: [Song]
        public var continuation: String?
        /// Only ever non-empty for a playlist page — see ``InnerTubeParser/parsePlaylistShelf(_:)``.
        public var suggested: [Song]
        /// Whether the release is in the library. Only the first page can answer — a continuation
        /// carries rows and nothing else — so it is nil from ``moreSongs(token:)`` and must not
        /// overwrite what ``browseSongs(browseId:)`` established.
        public var library: LibraryState?
        /// Whether this page's playlist is one the account made rather than saved. Nil for an album,
        /// a continuation, or a page that doesn't say.
        public var owned: Bool?
        /// What the page calls itself — needed by callers that opened it with nothing but a browse
        /// id (a tapped link). Nil on a continuation.
        public var header: InnerTubeParser.BrowseHeader?
        /// The editorial blurb for the release, when it has one. Nil on a continuation.
        public var description: String?

        public init(
            songs: [Song],
            continuation: String?,
            suggested: [Song] = [],
            library: LibraryState? = nil,
            owned: Bool? = nil,
            header: InnerTubeParser.BrowseHeader? = nil,
            description: String? = nil
        ) {
            self.songs = songs
            self.continuation = continuation
            self.suggested = suggested
            self.library = library
            self.owned = owned
            self.header = header
            self.description = description
        }
    }

    /// The first page of an album/playlist's tracks, and nothing more. Following every continuation
    /// before returning meant a long playlist spent up to ten round trips on a spinner; the rest
    /// arrives through ``moreSongs(token:)`` behind a page that is already being read.
    public func browseSongs(browseId: String) async throws -> SongPage {
        try await call("browse:\(browseId)") {
            let response = try await self.client.browse(browseId)
            var page = browseId.hasPrefix("MPREb") ? try await self.albumPage(response) : Self.page(of: response)
            // Only a playlist has an owner in the sense that matters, and only its own first
            // response can be asked.
            if browseId.hasPrefix("VL") { page.owned = InnerTubeParser.parsePlaylistOwned(response) }
            return page
        }
    }

    /// Joins an album's metadata page to its authoritative track listing. Catalogue album pages
    /// sometimes carry only a handful of preview rows; their header play action names a backing
    /// playlist containing every track, so songs and paging come from there while the richer album
    /// header and controls come from the album response.
    private func albumPage(_ albumResponse: InnerTubeJSON) async throws -> SongPage {
        let metadata = Self.page(of: albumResponse)
        guard let playlistId = InnerTubeParser.parseAlbumPlaylistId(albumResponse) else { return metadata }
        var tracks = Self.page(of: try await client.browse("VL\(playlistId.removingPrefix("VL"))"))
        tracks.library = metadata.library
        tracks.header = metadata.header
        tracks.description = metadata.description
        return tracks
    }

    /// The page ``SongPage/continuation`` points at.
    public func moreSongs(token: String) async throws -> SongPage {
        try await call("browse:more") { Self.page(of: try await self.client.browseContinuation(token)) }
    }

    /// Whether `browseId` is a playlist the account made — asked on its own by whatever needs it
    /// without a page open (holding a playlist card offers Rename and Delete, and the card itself
    /// cannot say whether either applies).
    public func playlistOwned(browseId: String) async throws -> Bool? {
        try await call("owner:\(browseId)") { InnerTubeParser.parsePlaylistOwned(try await self.client.browse(browseId)) }
    }

    static func page(of response: InnerTubeJSON) -> SongPage {
        let library = InnerTubeParser.parseLibraryState(response)
        let header = InnerTubeParser.parseBrowseHeader(response)
        // A playlist page is scoped to its own shelf so its suggestions never read as songs the user
        // added. Anything else (album, library, history, or a continuation delivered as
        // onResponseReceivedActions) falls back to the layout-agnostic walk.
        if let shelf = InnerTubeParser.parsePlaylistShelf(response) {
            return SongPage(songs: shelf.songs, continuation: shelf.continuation, suggested: shelf.suggested, library: library, header: header)
        }
        return SongPage(
            // One response can name the same track twice — an album page with a "you might also
            // like" shelf, say.
            songs: InnerTubeParser.collectSongsDeep(response).distinct(by: \.videoId),
            continuation: InnerTubeParser.continuationToken(response),
            library: library,
            header: header,
            description: InnerTubeParser.parseDescription(response)
        )
    }

    /// The complete track listing behind an album or playlist browse id — for callers that act on
    /// all of it at once ("Add to queue" on a card whose page was never opened). Queueing the first
    /// hundred rows of a three-hundred-track playlist and calling it the playlist would be a quieter
    /// kind of wrong than failing outright.
    public func allSongs(browseId: String) async throws -> [Song] {
        try await call("all:\(browseId)") {
            let songs = try await self.songsPaged(browseId)
            if songs.isEmpty { throw InnerTubeError.missingData("No tracks here") }
            return songs
        }
    }

    /// Every track behind a browse id, following continuations up to ``maxPages``. A failed page
    /// keeps whatever was already collected.
    func songsPaged(_ browseId: String) async throws -> [Song] {
        var order: [String] = []
        var byId: [String: Song] = [:]
        var response = try await client.browse(browseId)
        if browseId.hasPrefix("MPREb"), let playlistId = InnerTubeParser.parseAlbumPlaylistId(response) {
            response = try await client.browse("VL\(playlistId.removingPrefix("VL"))")
        }
        var page = 1
        while true {
            // Same shelf-scoping as page(of:): a playlist (Liked Music and the library songs feed
            // included) is read from its own shelf so a trailing suggestions shelf never joins in.
            let shelf = InnerTubeParser.parsePlaylistShelf(response)
            for song in shelf?.songs ?? InnerTubeParser.collectSongsDeep(response) {
                if byId.updateValue(song, forKey: song.videoId) == nil { order.append(song.videoId) }
            }
            guard let token = shelf?.continuation ?? InnerTubeParser.continuationToken(response), page < Self.maxPages else { break }
            page += 1
            guard let next = try? await client.browseContinuation(token) else { break }
            try Task.checkCancellation()
            response = next
        }
        return order.compactMap { byId[$0] }
    }

    /// Every saved library card behind a feed browse id, following continuations. Library shelves
    /// often stop at about twenty-five rows unless their continuation is followed; these are
    /// background loads, so collecting the full bounded set beats a shelf that looks complete and
    /// silently is not.
    func itemsPaged(_ browseId: String, params: String? = nil) async throws -> [ShelfItem] {
        var order: [String] = []
        var byKey: [String: ShelfItem] = [:]
        var response = try await client.browse(browseId, params: params)
        var page = 1
        while true {
            let parsed = InnerTubeParser.parseLibraryItemPage(response)
            for item in parsed.items {
                let key = item.browseId ?? item.videoId ?? "\(item.title)\n\(item.subtitle)"
                if byKey[key] == nil {
                    byKey[key] = item
                    order.append(key)
                }
            }
            guard let token = parsed.continuation, page < Self.maxPages else { break }
            page += 1
            guard let next = try? await client.browseContinuation(token) else { break }
            try Task.checkCancellation()
            response = next
        }
        return order.compactMap { byKey[$0] }
    }

    /// Artist page. The landing page only lists ~5 songs, so the linked "Top songs" playlist is
    /// fetched to fill the list out, and every release shelf with a "more" link (Albums, Singles &
    /// EPs) is fetched in full.
    public func artistPage(browseId: String) async throws -> ArtistPage {
        try await call("artist:\(browseId)") {
            var page = InnerTubeParser.parseArtistPage(try await self.client.browse(browseId))
            let moreSongs = page.moreSongsBrowseId
            async let fullSongs: [Song]? = self.fullSongList(moreSongs)
            let sections = page.sections
            let fullShelves = await withTaskGroup(of: (Int, HomeShelf).self) { group -> [HomeShelf] in
                for (index, shelf) in sections.enumerated() {
                    group.addTask {
                        guard let more = shelf.moreBrowseId,
                              let items = try? await self.itemsPaged(more, params: shelf.moreParams),
                              !items.isEmpty else { return (index, shelf) }
                        var full = shelf
                        full.items = items
                        return (index, full)
                    }
                }
                var collected: [(Int, HomeShelf)] = []
                for await result in group { collected.append(result) }
                return collected.sorted { $0.0 < $1.0 }.map(\.1)
            }
            if let songs = await fullSongs, !songs.isEmpty { page.songs = songs }
            page.sections = fullShelves
            return page
        }
    }

    private func fullSongList(_ playlistBrowseId: String?) async -> [Song]? {
        guard let playlistBrowseId else { return nil }
        return try? await songsPaged(playlistBrowseId)
    }

    // MARK: - Radio and track metadata

    /// What YouTube Music would play on after `videoId`. Feeds AutoPlay; the seed track itself comes
    /// back first, so callers filter what they already have.
    public func radio(videoId: String) async throws -> [Song] {
        try await call("radio:\(videoId)") { InnerTubeParser.parseWatchQueue(try await self.client.next(videoId: videoId)) }
    }

    /// The artist and album pages a track links out to. Search rows carry them, but home cards and
    /// anything sitting in a queue often don't; a track's own watch queue entry always names both.
    public func trackLinks(videoId: String) async throws -> Song {
        try await call("links:\(videoId)") {
            guard let song = InnerTubeParser.parseWatchQueue(try await self.client.next(videoId: videoId)).first(where: { $0.videoId == videoId }) else {
                throw InnerTubeError.missingData("no watch entry for \(videoId)")
            }
            return song
        }
    }

    /// The lyrics YouTube Music's Lyrics tab shows for exactly this video: `next` → the Lyrics tab's
    /// browse id → `browse`. Plain lines (the tab is untimed); nil when the track has no lyrics, the
    /// id isn't a YouTube video id, or any step fails — a lyrics source answers "none", it doesn't
    /// throw.
    public func lyrics(videoId: String) async -> YouTubeMusicLyrics? {
        guard Self.youtubeVideoId.matches(videoId) else { return nil }
        guard let next = try? await client.next(videoId: videoId),
              let endpoint = InnerTubeParser.lyricsEndpoint(next),
              let page = try? await client.browse(endpoint.browseId, params: endpoint.params),
              let lines = InnerTubeParser.parseLyrics(page) else { return nil }
        return YouTubeMusicLyrics(lines: lines, source: InnerTubeParser.parseLyricsSource(page))
    }

    /// Timed caption cues for the video, a last-resort lyrics source; nil when there are none or the
    /// request fails.
    public func transcriptLyrics(videoId: String) async -> [InnerTubeTranscriptCue]? {
        guard Self.youtubeVideoId.matches(videoId),
              let response = try? await client.transcript(videoId: videoId) else { return nil }
        return InnerTubeParser.parseTranscript(response)
    }

    /// A YouTube video id, as opposed to anything else that can be a media id (a local file's URI, a
    /// source's own key).
    static let youtubeVideoId = TextPattern(#"[A-Za-z0-9_-]{11}"#)

    // MARK: - Writes

    /// The account's own state for one track — rating and library membership. A lookup rather than
    /// something cached with the song: the feedback tokens are per-row, and a queued track carries
    /// an id and little else. Fetched when a menu is opened, the only moment the answer is looked at.
    public func songMenu(videoId: String) async throws -> SongMenu {
        try await call("menu:\(videoId)") {
            guard let menu = InnerTubeParser.parseSongMenu(try await self.client.next(videoId: videoId), videoId: videoId) else {
                throw InnerTubeError.missingData("no menu for \(videoId)")
            }
            return menu
        }
    }

    public func rate(videoId: String, status: LikeStatus) async throws {
        try await call("rate:\(videoId)") { try await self.client.rate(videoId: videoId, status: status) }
    }

    /// Adds or removes a track from the library; `token` (from ``SongMenu``) says which.
    public func setLibraryStatus(token: String) async throws {
        try await call("library:feedback") { try await self.client.sendFeedback(token: token) }
    }

    /// Saves an album or playlist to the library, or removes it. `playlistId` is the one the page
    /// named — see ``LibraryState``.
    public func setSaved(playlistId: String, saved: Bool) async throws {
        try await call("library:\(playlistId)") { try await self.client.ratePlaylist(playlistId: playlistId, saved: saved) }
    }

    /// Subscribes to an artist's channel, or unsubscribes. `channelId` is the one the page's own
    /// subscribe button named — see ``SubscriptionState``.
    public func setSubscribed(channelId: String, subscribed: Bool) async throws {
        try await call("subscription:\(channelId)") { try await self.client.setSubscribed(channelId: channelId, subscribed: subscribed) }
    }

    /// Creates a playlist, optionally seeded with `videoIds`; returns its id.
    public func createPlaylist(title: String, privacy: PlaylistPrivacy, videoIds: [String] = []) async throws -> String {
        try await call("playlist:create") { try await self.client.createPlaylist(title: title, privacy: privacy, videoIds: videoIds) }
    }

    /// Adds tracks to a playlist; returns video id → the set-video-id YouTube minted, for splicing
    /// the row into a playlist on screen (its "remove" needs it).
    @discardableResult
    public func addToPlaylist(playlistId: String, videoIds: [String]) async throws -> [String: String] {
        try await call("playlist:add") { try await self.client.addToPlaylist(playlistId: playlistId, videoIds: videoIds) }
    }

    public func removeFromPlaylist(playlistId: String, entries: [PlaylistEntryRef]) async throws {
        try await call("playlist:remove") { try await self.client.removeFromPlaylist(playlistId: playlistId, entries: entries) }
    }

    public func renamePlaylist(playlistId: String, title: String) async throws {
        try await call("playlist:rename") { try await self.client.renamePlaylist(playlistId: playlistId, title: title) }
    }

    public func deletePlaylist(playlistId: String) async throws {
        try await call("playlist:delete") { try await self.client.deletePlaylist(playlistId: playlistId) }
    }

    // MARK: - Plumbing

    private func call<T: Sendable>(_ label: String, _ block: @Sendable () async throws -> T) async throws -> T {
        do {
            let value = try await block()
            DebugLog.d(Self.log, "\(label) ok")
            return value
        } catch let error as InnerTubeError where error.isAuthRejection {
            // Context cookies can rotate while the app is alive. Refresh once and retry.
            guard await client.isSignedIn else {
                DebugLog.w(Self.log, "\(label) failed: \(error.localizedDescription)")
                throw error
            }
            DebugLog.w(Self.log, "\(label) rejected; refreshing active session context once")
            await client.refreshSessionScope()
            do {
                return try await block()
            } catch {
                DebugLog.w(Self.log, "\(label) failed: \(error.localizedDescription)")
                throw error
            }
        } catch {
            if !(error is CancellationError) { DebugLog.w(Self.log, "\(label) failed: \(error.localizedDescription)") }
            throw error
        }
    }
}

/// The Lyrics tab's text for one video.
public struct YouTubeMusicLyrics: Hashable, Sendable {
    /// Non-blank lines, in order. The tab is untimed.
    public var lines: [String]
    /// The credit line under the lyrics ("Source: Musixmatch"), when present.
    public var source: String?

    public init(lines: [String], source: String?) {
        self.lines = lines
        self.source = source
    }
}

/// The repository's in-memory caches, behind an actor so concurrent screens can share them.
private actor RepositoryCaches {
    private var moodGenreShelves: [String: [HomeShelf]] = [:]
    /// Includes unchanged video fallbacks as well as matches: the queue prefetcher asks before a
    /// track becomes current, and remembering its answer makes the player switch use the exact
    /// rendition whose bytes were warmed.
    private var audioVersions: [String: Song] = [:]
    /// Video lookups from audio tracks; a stored nil means "no video found".
    private var videoVersions: [String: VideoLookup] = [:]

    struct VideoLookup { let song: Song? }

    func moodGenre(_ key: String) -> [HomeShelf]? { moodGenreShelves[key] }
    func storeMoodGenre(_ shelves: [HomeShelf], for key: String) {
        if moodGenreShelves[key] == nil { moodGenreShelves[key] = shelves }
    }
    func audioVersion(_ id: String) -> Song? { audioVersions[id] }
    func storeAudioVersion(_ song: Song, for id: String) { audioVersions[id] = song }
    func videoVersion(_ id: String) -> VideoLookup? { videoVersions[id] }
    func storeVideoVersion(_ song: Song?, for id: String) { videoVersions[id] = VideoLookup(song: song) }
}
