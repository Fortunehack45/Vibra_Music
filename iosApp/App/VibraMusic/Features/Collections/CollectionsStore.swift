import VibraMusicCore
import Downloads
import Foundation
import InnerTube
import Observation
import Replay

// Ports the parts of ui/MainViewModel.kt the Collections screens stand on: the library feed and its
// refresh rules, the account's playlists and who owns them, the album/artist/playlist pages that are
// open (so an edit made from a sheet shows on the page behind it), listening history, and every
// playlist, library and rating write — each optimistic where Android's is, and rolled back where
// Android rolls back.

/// How a batch of adds went, per playlist (MainViewModel's `AddOutcome` counts).
struct PlaylistAddSummary: Equatable {
    var added = 0
    var alreadyThere = 0
    var failed = 0
}

@MainActor
@Observable
final class CollectionsStore {
    @ObservationIgnored let service: CollectionsService
    @ObservationIgnored let likeState: LikeState
    /// Shows a one-line confirmation above the mini player (Android's queue-notice toast).
    @ObservationIgnored var notify: (String, String?) -> Void = { _, _ in }
    /// Hands a batch to the download queue (MainActivity's `startDownload`).
    @ObservationIgnored var enqueueDownloads: ([Song], DownloadTarget?) -> Void = { _, _ in }
    /// Takes a deleted playlist's page off every tab's stack.
    @ObservationIgnored var closePages: (String) -> Void = { _ in }

    init(service: CollectionsService, likeState: LikeState) {
        self.service = service
        self.likeState = likeState
    }

    // MARK: - Registry

    /// Each store beside the model it was made for, held weakly: an identifier is only an address,
    /// and a model made where a released one used to live must not inherit its store (whose service
    /// reaches back into that model unowned).
    private struct Entry {
        weak var model: AppModel?
        let store: CollectionsStore
    }

    @ObservationIgnored private static var stores: [ObjectIdentifier: Entry] = [:]

    /// The store for the running app. One per AppModel, made on first use and wired to its player,
    /// router and downloads.
    static func shared(for model: AppModel) -> CollectionsStore {
        let key = ObjectIdentifier(model)
        if let entry = stores[key], entry.model === model { return entry.store }
        stores = stores.filter { $0.value.model != nil }
        let live = LiveCollectionsService(repository: model.repository, accounts: model.accounts,
                                          downloadLibrary: { [unowned model] in model.downloadLibrary },
                                          downloads: { [unowned model] in model.downloads },
                                          replayStats: { [unowned model] in model.replayStats },
                                          canvas: { [unowned model] in model.canvas })
        var service: CollectionsService = live
        #if DEBUG
        if CollectionsDemoService.isRequested { service = CollectionsDemoService(live: live, repository: model.repository) }
        #endif
        let store = CollectionsStore(service: service, likeState: model.likeState)
        store.notify = { [weak model] message, symbol in model?.player.notice = QueueNotice(message: message, symbol: symbol) }
        // The store itself is weak here: a closure held by the store that captured the store back
        // would outlive every model.
        store.enqueueDownloads = { [weak model, weak store] songs, target in
            guard let model, let store else { return }
            // The queue reports its own progress (the top bar's download button, the manager
            // sheet, each row's badge); the outcome is only what those already show. What they
            // can't show is the hold or batch the tap needs said once, above the mini player
            // (MainActivity's `startDownload` toasts), through the store's own notice seam.
            // The queue this tap lands in is read before it: a hold it's in is the tap's story.
            let holding = model.downloads.isWaitingForWiFi
            let outcome = model.downloads.download(songs, as: target)
            if let line = DownloadNotice.make(for: outcome, requested: songs.count, queueHoldingForWiFi: holding) {
                store.notify(line.message, line.symbol)
            }
        }
        store.closePages = { [weak model] browseId in
            guard let router = model?.router else { return }
            for tab in AppTab.allCases {
                let path = router.path(for: tab)
                let kept = path.filter { $0.browseId != browseId }
                if kept.count != path.count { router.setPath(kept, for: tab) }
            }
        }
        stores[key] = Entry(model: model, store: store)
        return store
    }

    /// Puts `store` in place for `model` (tests and the screenshot fixtures).
    static func install(_ store: CollectionsStore, for model: AppModel) {
        stores[ObjectIdentifier(model)] = Entry(model: model, store: store)
    }

    // MARK: - Library

    private(set) var library: LoadState<LibraryPage> = .loading
    private(set) var libraryRefreshing = false
    /// Whose library `library` is; a different listener's must be fetched again.
    @ObservationIgnored private var libraryListener: String?
    @ObservationIgnored private var libraryFetched = false
    /// Android's `listenerCache` (MainViewModel.kt): the page each listener had when we left them,
    /// keyed by `listenerKey` (`accountId:profileId`), so switching back paints at once while the
    /// refresh runs behind it. Cleared on sign-out; `libraryListener` is the key, so
    /// one listener's page is never filed under another's.
    @ObservationIgnored private var librarySnapshots: [String: LibraryPage] = [:]
    /// Set by every write; acted on when the tab is next shown, because rearranging a page under
    /// whoever is reading it is worse than showing it a moment out of date.
    var libraryStale = false
    @ObservationIgnored private var likedSync: Task<Void, Never>?

    /// Loads the library if it has never been loaded for the listener signed in now.
    func loadLibraryIfNeeded() async {
        guard service.isSignedIn else { clearLibrarySnapshots(); return }
        let listener = service.listenerKey
        if libraryFetched, libraryListener == listener, !library.isLoading { return }
        cacheCurrentListener()
        // No `libraryListener != listener` here: after switching away while the other listener's
        // first fetch is still out, `libraryListener` is still this listener but the page on screen
        // is that fetch's spinner. The early return above already covers a loaded page.
        if let listener, let snapshot = librarySnapshots[listener] {
            // Android's `clearListenerState(restoreCached = true)`: the listener's own page is up
            // at once; the fetch below refreshes it behind the reader.
            library = .success(snapshot)
            libraryListener = listener
            libraryFetched = true
            await fetchLibrary()
            return
        }
        await loadLibrary()
    }

    /// Files the outgoing listener's page under their own key as the identity changes
    /// (Android's `cacheCurrentListener()`). The key is `libraryListener` — who the page was
    /// fetched for — so a page in flight for one listener is never filed under another's.
    private func cacheCurrentListener() {
        guard let leaving = libraryListener, leaving != service.listenerKey, let page = library.value else { return }
        librarySnapshots[leaving] = page
    }

    /// Signing out drops every snapshot: nothing that was on screen survives a
    /// sign-out, and whoever signs in next starts from their own fetch.
    private func clearLibrarySnapshots() {
        librarySnapshots.removeAll()
        libraryListener = nil
        libraryFetched = false
        // A write's pending refresh belongs to the listener who left.
        libraryStale = false
        library = .loading
    }

    /// MainViewModel's `loadLibrary`: the spinner, then the feed.
    func loadLibrary() async {
        guard service.isSignedIn else { return }
        library = .loading
        await fetchLibrary()
    }

    /// Pull to refresh: the page stays up while the feed is fetched again.
    func refreshLibrary() async {
        guard service.isSignedIn else { return }
        libraryRefreshing = true
        defer { libraryRefreshing = false }
        await fetchLibrary()
    }

    /// MainViewModel's `onLibraryShown`: the picker's list is refreshed every visit, and a library a
    /// write has made stale is fetched again.
    func libraryShown() async {
        await loadPlaylists()
        guard libraryStale else { return }
        libraryStale = false
        if library.value != nil { await refreshLibrary() }
    }

    private func fetchLibrary() async {
        let listener = service.listenerKey
        let next: LoadState<LibraryPage>
        do {
            var page = try await service.library()
            if let token = page.likedContinuation {
                likedSync?.cancel()
                likedSync = Task { [service] in
                    // Stops rather than seeding one account's likes into the next one's session.
                    guard service.listenerKey == listener else { return }
                    await service.syncLikedMusic(from: token)
                }
            }
            page.likedContinuation = nil
            next = page.isEmpty ? .error(L10n.libraryEmpty) : .success(page)
        } catch is CancellationError {
            return
        } catch {
            next = .error(error.localizedDescription)
        }
        guard listener == service.listenerKey else { return }
        library = next
        libraryListener = listener
        libraryFetched = true
    }

    /// The library feed's Playlists shelf, rewritten by `edit` (MainViewModel's
    /// `editPlaylistShelf`). YouTube's playlist feed is eventually consistent — a fetch fired the
    /// moment an edit returns answers with the state from before it — so every edit restates the
    /// shelf by hand, and the re-fetch waits for `libraryStale`.
    private func editPlaylistShelf(_ edit: ([ShelfItem]) -> [ShelfItem]) {
        guard var page = library.value else { return }
        let title = YTMusicRepository.playlistsShelfTitle
        let index = page.shelves.firstIndex { $0.title == title }
        let existing = index.map { page.shelves[$0].items } ?? []
        let items = edit(existing)
        if let index {
            if items == existing { return }
            if items.isEmpty {
                // Emptied by deleting the last playlist: the heading goes, the create tile stays.
                page.shelves.remove(at: index)
            } else {
                page.shelves[index].items = items
            }
        } else {
            guard !items.isEmpty else { return }
            // The account's first playlist: the feed never had a shelf to send, and it leads.
            page.shelves.insert(HomeShelf(title: title, items: items), at: 0)
        }
        library = .success(page)
    }

    // MARK: - The account's playlists

    /// The playlists a track can be added to (the picker), newest first.
    private(set) var playlists: [UserPlaylist] = []
    private(set) var playlistsLoading = false
    /// Which playlists the account made, by browse id; absent means nobody has asked yet.
    private(set) var playlistOwned: [String: Bool] = [:]
    @ObservationIgnored private var ownershipInFlight: Set<String> = []
    /// Whose `playlists` and `playlistOwned` these are.
    @ObservationIgnored private var playlistsListener: String?
    /// The load that is out, joined by anyone who asks meanwhile rather than turned away empty.
    @ObservationIgnored private var playlistsLoad: Task<Void, Never>?
    /// Bumped each time another listener's playlists are dropped. A load that began before the bump
    /// is stale even when the listener has come back (A → B → A): its answer predates the newer load.
    @ObservationIgnored private var playlistsGeneration = 0

    /// Android's `clearListenerState`: the playlists and who made them answer "who is asking", so
    /// another listener's are dropped before this one's are read or written. A load still out for
    /// the listener who left never clears `playlistsLoading`, so that goes too.
    private func dropAnotherListenersPlaylists() {
        let listener = service.listenerKey
        guard listener != playlistsListener else { return }
        playlistsListener = listener
        playlistsGeneration += 1
        playlists = []
        playlistsLoading = false
        playlistsLoad = nil
        playlistOwned = [:]
        ownershipInFlight = []
    }

    /// Re-fetched rather than cached for the session: playlists are edited here.
    /// A call while a load is out waits for that load, so whoever reads `playlists` next sees it.
    func loadPlaylists() async {
        dropAnotherListenersPlaylists()
        guard service.isSignedIn else { return }
        if let playlistsLoad { return await playlistsLoad.value }
        let listener = service.listenerKey
        let generation = playlistsGeneration
        playlistsLoading = true
        let load = Task {
            let loaded = try? await service.userPlaylists()
            // A switch while this was out has already dropped it, and may have started the next
            // listener's load.
            guard listener == service.listenerKey, generation == playlistsGeneration else { return }
            if let loaded { playlists = loaded }
            playlistsLoading = false
            playlistsLoad = nil
        }
        playlistsLoad = load
        await load.value
    }

    /// Loads the playlists unless this listener's are already here.
    func loadPlaylistsIfNeeded() async {
        dropAnotherListenersPlaylists()
        if playlists.isEmpty { await loadPlaylists() }
    }

    /// Whether `browseId` is a playlist this account can edit — only ever yes for one confirmed
    /// as the account's own (MainViewModel's `editablePlaylist`). Saved-from-someone-else
    /// playlists are listed exactly like owned ones, so membership alone would offer Rename and
    /// Delete on a stranger's playlist.
    func editablePlaylist(_ browseId: String?) -> UserPlaylist? {
        guard let browseId, playlistsListener == service.listenerKey, playlistOwned[browseId] == true else { return nil }
        return playlists.first { $0.browseId == browseId }
    }

    /// Finds out who made the playlist at `browseId` if nobody has asked yet — only for playlists
    /// in this library, the only ones that could turn out editable.
    func resolvePlaylistOwnership(_ browseId: String?) async {
        dropAnotherListenersPlaylists()
        guard service.isSignedIn, let browseId else { return }
        guard playlistOwned[browseId] == nil, !ownershipInFlight.contains(browseId) else { return }
        guard playlists.contains(where: { $0.browseId == browseId }) else { return }
        let listener = service.listenerKey
        ownershipInFlight.insert(browseId)
        defer { if listener == service.listenerKey { ownershipInFlight.remove(browseId) } }
        // `try?` flattens: nil is a failed lookup or a page that didn't say, both "ask again later".
        if let owned = try? await service.playlistOwned(browseId), listener == service.listenerKey {
            playlistOwned[browseId] = owned
        }
    }

    /// `listener` is who asked: a verdict that lands after a switch is the last listener's, not this one's.
    func setPlaylistOwned(_ browseId: String, _ owned: Bool, askedBy listener: String?) {
        guard listener == service.listenerKey else { return }
        dropAnotherListenersPlaylists()
        playlistOwned[browseId] = owned
    }

    /// Adds `songs` to `playlist` from the picker. Not optimistic: YouTube has no objection to a
    /// duplicate, so the playlist is checked first (its open page, or a fresh fetch) and a track
    /// already in it is never sent. Returns whether everything was already there, for the notice;
    /// nil when the write failed.
    @discardableResult
    func addToPlaylist(_ playlist: UserPlaylist, songs: [Song]) async -> Bool? {
        guard service.isSignedIn, !songs.isEmpty else { return nil }
        var known = pages[playlist.browseId]?.songs.value
        if known == nil { known = try? await service.allSongs(playlist.browseId) }
        let knownIds = Set((known ?? []).map(\.videoId))
        let fresh = songs.filter { !knownIds.contains($0.videoId) }
        if fresh.isEmpty { return true }
        do {
            let added = try await service.addToPlaylist(playlistId: playlist.playlistId, videoIds: fresh.map(\.videoId))
            libraryStale = true
            for song in fresh { appendToOpenPlaylist(playlist.browseId, song: song, setVideoId: added[song.videoId]) }
            return false
        } catch {
            return nil
        }
    }

    /// Adds `songs` to every playlist in `playlists` — the picker's ticked rows — and reports how
    /// each went, once, when they all have (MainViewModel's `addToPlaylists`).
    ///
    /// One at a time rather than all at once: each check reads the playlist it is about, and a
    /// burst of parallel edits is exactly what YouTube answers with a rate limit. The duplicate
    /// check is per playlist, so a track already in one of them is skipped there and still added
    /// to the rest. Nil when there is nothing to add or nobody signed in, which is also when
    /// Android leaves no notice.
    func addToPlaylists(_ playlists: [UserPlaylist], songs: [Song]) async -> PlaylistAddSummary? {
        guard service.isSignedIn, !songs.isEmpty, !playlists.isEmpty else { return nil }
        var summary = PlaylistAddSummary()
        for playlist in playlists {
            switch await addToPlaylist(playlist, songs: songs) {
            case true?: summary.alreadyThere += 1
            case false?: summary.added += 1
            case nil: summary.failed += 1
            }
        }
        return summary
    }

    /// Creates a playlist, seeded with the tracks that opened the picker in the same request, so it
    /// can't half-succeed into an empty playlist (MainViewModel's `createPlaylist`).
    func createPlaylist(title: String, privacy: PlaylistPrivacy, songs: [Song]) async {
        guard service.isSignedIn else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? L10n.newPlaylist : trimmed
        let listener = service.listenerKey
        guard let playlistId = try? await service.createPlaylist(title: name, privacy: privacy, videoIds: songs.map(\.videoId)),
              listener == service.listenerKey else { return }
        let created = UserPlaylist(
            playlistId: playlistId,
            title: name,
            subtitle: songs.isEmpty ? "" : L10n.songCountPlural(songs.count),
            thumbnailUrl: songs.first?.thumbnailUrl
        )
        // The owner by construction, so its card is editable the moment it appears.
        setPlaylistOwned(created.browseId, true, askedBy: listener)
        libraryStale = true
        playlists = [created] + playlists.filter { $0.playlistId != created.playlistId }
        editPlaylistShelf { items in
            [ShelfItem(title: created.title, subtitle: created.subtitle, thumbnailUrl: created.thumbnailUrl, videoId: nil, browseId: created.browseId)]
                + items.filter { $0.browseId != created.browseId }
        }
    }

    /// Drops `song` from the playlist page it is being read on, taking the row out from under the
    /// reader rather than waiting for a re-fetch.
    func removeFromPlaylist(_ browseId: String, song: Song) async {
        guard let setVideoId = song.setVideoId, service.isSignedIn else { return }
        let playlistId = browseId.hasPrefix("VL") ? String(browseId.dropFirst(2)) : browseId
        do {
            try await service.removeFromPlaylist(playlistId: playlistId, entries: [PlaylistEntryRef(setVideoId: setVideoId, videoId: song.videoId)])
            libraryStale = true
            updatePage(browseId) { page in
                guard let songs = page.songs.value else { return }
                page.songs = .success(songs.filter { $0.setVideoId != setVideoId })
            }
        } catch {}
    }

    /// Adds one of a playlist's suggestions to it: out of the Suggested section and into the
    /// track list, per-entry id included so "Remove from this playlist" works on it at once.
    func addSuggestedSong(_ browseId: String, song: Song) async {
        guard service.isSignedIn else { return }
        let playlistId = browseId.hasPrefix("VL") ? String(browseId.dropFirst(2)) : browseId
        guard let added = try? await service.addToPlaylist(playlistId: playlistId, videoIds: [song.videoId]) else { return }
        libraryStale = true
        updatePage(browseId) { page in
            page.suggestedSongs.removeAll { $0.videoId == song.videoId }
        }
        appendToOpenPlaylist(browseId, song: song, setVideoId: added[song.videoId])
    }

    /// Puts `song` at the end of the open playlist page — where YouTube puts it. An empty playlist
    /// counts as open (its "No tracks here" is replaced); a failed or loading page is left alone.
    private func appendToOpenPlaylist(_ browseId: String, song: Song, setVideoId: String?) {
        updatePage(browseId) { page in
            let songs: [Song]
            switch page.songs {
            case .success(let loaded): songs = loaded
            case .error(let message) where message == L10n.noTracksHere: songs = []
            default: return
            }
            guard !songs.contains(where: { $0.videoId == song.videoId }) else { return }
            var row = song
            row.setVideoId = setVideoId
            if row.thumbnailUrl == nil { row.thumbnailUrl = page.thumbnailUrl }
            page.songs = .success(songs + [row])
        }
    }

    /// Renames a playlist and restates the name everywhere it is drawn: the picker, the library
    /// card, and its open page.
    func renamePlaylist(_ playlist: UserPlaylist, to title: String) async {
        guard service.isSignedIn else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != playlist.title else { return }
        guard (try? await service.renamePlaylist(playlistId: playlist.playlistId, title: name)) != nil else { return }
        playlists = playlists.map { entry in
            guard entry.playlistId == playlist.playlistId else { return entry }
            var renamed = entry
            renamed.title = name
            return renamed
        }
        editPlaylistShelf { items in
            items.map { item in
                guard item.browseId == playlist.browseId else { return item }
                var renamed = item
                renamed.title = name
                return renamed
            }
        }
        updatePage(playlist.browseId) { $0.title = name }
        libraryStale = true
    }

    func deletePlaylist(_ playlist: UserPlaylist) async {
        guard service.isSignedIn else { return }
        guard (try? await service.deletePlaylist(playlistId: playlist.playlistId)) != nil else { return }
        playlists.removeAll { $0.playlistId == playlist.playlistId }
        editPlaylistShelf { items in items.filter { $0.browseId != playlist.browseId } }
        // Its page may be the one open; a deleted playlist has nothing left to show.
        pages[playlist.browseId] = nil
        closePages(playlist.browseId)
        libraryStale = true
    }

    // MARK: - Pages

    /// The album, artist and playlist pages that are open, by browse id.
    private(set) var pages: [String: DetailPage] = [:]
    @ObservationIgnored private var pageGeneration: [String: Int] = [:]

    func page(_ browseId: String) -> DetailPage? { pages[browseId] }

    private func updatePage(_ browseId: String, _ change: (inout DetailPage) -> Void) {
        guard var page = pages[browseId] else { return }
        change(&page)
        pages[browseId] = page
    }

    /// Opens a page: drawn at once from what the card or row knew, then filled in (MainViewModel's
    /// `openDetail`), and a long track list followed to its end behind the reader (`fillIn`).
    func openPage(_ browseId: String, seed: BrowseItem?, type fallback: BrowseType) async {
        let type = BrowseType.of(browseId: browseId, fallback: seed?.type ?? fallback)
        let generation = (pageGeneration[browseId] ?? 0) + 1
        pageGeneration[browseId] = generation
        let title = seed?.title ?? pages[browseId]?.title ?? ""
        let subtitle = seed?.subtitle ?? pages[browseId]?.subtitle ?? ""
        let thumbnail = seed?.thumbnailUrl ?? pages[browseId]?.thumbnailUrl
        pages[browseId] = DetailPage(browseId: browseId, title: title, subtitle: subtitle, thumbnailUrl: thumbnail, songs: .loading, type: type)

        var loaded = DetailPage(browseId: browseId, title: title, subtitle: subtitle, thumbnailUrl: thumbnail, songs: .loading, type: type)
        var more: String?
        if let downloaded = service.downloadedPlaylistSongs(browseId) {
            loaded.songs = downloaded.isEmpty ? .error(L10n.downloadedPlaylistEmpty) : .success(downloaded)
        } else if type == .artist {
            do {
                let artist = try await service.artistPage(browseId)
                loaded.sections = artist.sections
                if let art = artist.thumbnailUrl { loaded.thumbnailUrl = art }
                if let name = artist.name, !name.isEmpty { loaded.title = name }
                loaded.description = artist.description
                loaded.subscriberCountText = artist.subscriberCountText
                loaded.monthlyListenerCount = artist.monthlyListenerCount
                loaded.subscription = artist.subscription
                loaded.songs = artist.songs.isEmpty ? .error(L10n.noTracksHere) : .success(artist.songs.withArtwork(thumbnail ?? artist.thumbnailUrl))
            } catch is CancellationError {
                return
            } catch {
                loaded.songs = .error(error.localizedDescription)
            }
        } else {
            do {
                let listener = service.listenerKey
                let first = try await service.browseSongs(browseId)
                if let owned = first.owned { setPlaylistOwned(browseId, owned, askedBy: listener) }
                if let header = first.header {
                    if title.isEmpty { loaded.title = header.title }
                    // Album cards often carry only the artist; the header adds the year.
                    if type == .album, !header.subtitle.isEmpty {
                        loaded.subtitle = header.subtitle
                    } else if subtitle.isEmpty {
                        loaded.subtitle = header.subtitle
                    }
                    if thumbnail == nil { loaded.thumbnailUrl = header.thumbnailUrl }
                }
                loaded.description = first.description
                if first.songs.isEmpty {
                    loaded.songs = .error(L10n.noTracksHere)
                } else {
                    more = first.continuation
                    loaded.suggestedSongs = first.suggested.withArtwork(loaded.thumbnailUrl)
                    loaded.library = first.library
                    loaded.songs = .success(first.songs.withArtwork(loaded.thumbnailUrl))
                }
            } catch is CancellationError {
                return
            } catch {
                loaded.songs = .error(error.localizedDescription)
            }
        }
        guard pageGeneration[browseId] == generation else { return }
        pages[browseId] = loaded
        if let more { await fillIn(browseId, token: more, generation: generation) }
    }

    /// Follows a page's continuations, appending each to what is already on screen; stops when the
    /// page is reopened or a page adds nothing new (a feed looping back on itself).
    private func fillIn(_ browseId: String, token: String, generation: Int) async {
        var next: String? = token
        while let current = next {
            guard let fetched = try? await service.moreSongs(current) else { return }
            guard pageGeneration[browseId] == generation, let page = pages[browseId], let existing = page.songs.value else { return }
            var known = Set(existing.map(\.videoId))
            let added = fetched.songs.filter { known.insert($0.videoId).inserted }.withArtwork(page.thumbnailUrl)
            var knownSuggested = Set(page.suggestedSongs.map(\.videoId))
            let addedSuggested = fetched.suggested
                .filter { !known.contains($0.videoId) && knownSuggested.insert($0.videoId).inserted }
                .withArtwork(page.thumbnailUrl)
            if added.isEmpty && addedSuggested.isEmpty { return }
            updatePage(browseId) { page in
                page.songs = .success(existing + added)
                page.suggestedSongs += addedSuggested
            }
            next = fetched.continuation
        }
    }

    /// Saves the release to the library or takes it out — optimistic, rolled back if YouTube
    /// refuses; a page YouTube never offered to save has no control and this is a no-op.
    func toggleLibrary(_ browseId: String) async {
        guard service.isSignedIn, let current = pages[browseId]?.library else { return }
        let target = !current.saved
        updatePage(browseId) { $0.library?.saved = target }
        do {
            try await service.setSaved(playlistId: current.playlistId, saved: target)
            libraryStale = true
        } catch {
            updatePage(browseId) { $0.library?.saved = current.saved }
        }
    }

    /// Subscribes to the artist or unsubscribes, the same way. Surviving a refresh is YouTube's:
    /// the page read afterwards states the new answer.
    func toggleSubscription(_ browseId: String) async {
        guard service.isSignedIn, let current = pages[browseId]?.subscription else { return }
        let target = !current.subscribed
        updatePage(browseId) { $0.subscription?.subscribed = target }
        do {
            try await service.setSubscribed(channelId: current.channelId, subscribed: target)
            libraryStale = true
        } catch {
            updatePage(browseId) { $0.subscription?.subscribed = current.subscribed }
        }
    }

    // MARK: - Likes

    /// The open track menu's account state; nil while it is fetched.
    private(set) var songMenu: SongMenu?

    /// Loads the account state behind an opening track menu. A stated LIKE or DISLIKE is taken; the
    /// watch queue's silence is not read as "not liked" (MainViewModel's `loadSongMenu`).
    func loadSongMenu(_ videoId: String) async {
        songMenu = nil
        guard service.isSignedIn, let menu = try? await service.songMenu(videoId: videoId) else { return }
        songMenu = menu
        likeState.rememberStated(menu.likeStatus, for: videoId)
    }

    /// What a rating change does beyond the rating (MainViewModel's `setLike`): Liked Music is out of
    /// date; a song no longer liked leaves the lists that exist because it was; and clearing the
    /// heart also takes the song out of the library, since liking and saving are two flags on
    /// YouTube's side and clearing one would leave it saved with no way left to reach it.
    func ratingChanged(_ videoId: String, from previous: LikeStatus, to status: LikeStatus) async {
        guard service.isSignedIn, previous != status else { return }
        libraryStale = true
        if status != .like { dropFromLikedLists(videoId) }
        if previous == .like && status == .indifferent { await forgetFromLibrary(videoId) }
    }

    private func dropFromLikedLists(_ videoId: String) {
        if var page = library.value, page.likedSongs.contains(where: { $0.videoId == videoId }) {
            page.likedSongs.removeAll { $0.videoId == videoId }
            library = .success(page)
        }
        updatePage(YTMusicRepository.likedMusicBrowseId) { page in
            guard let songs = page.songs.value else { return }
            page.songs = .success(songs.filter { $0.videoId != videoId })
        }
    }

    @discardableResult
    private func forgetFromLibrary(_ videoId: String) async -> Bool {
        guard let menu = try? await service.songMenu(videoId: videoId), menu.inLibrary,
              let token = menu.removeFromLibraryToken else { return false }
        guard (try? await service.setLibraryStatus(token: token)) != nil else { return false }
        if songMenu != nil { songMenu?.inLibrary = false }
        return true
    }

    // MARK: - Replay

    /// Replay's headline cards at the top of the Library; empty until there is listening to show.
    private(set) var replayCards: [ReplayHeroCard] = []
    private(set) var replayMemberSince: String?

    func loadReplay() async {
        let loaded = await service.replayCards()
        replayCards = loaded.cards
        replayMemberSince = loaded.memberSince
    }

    // MARK: - History

    private(set) var history: LoadState<[Song]> = .loading

    /// Loaded on each visit: a page whose subject is what happened most recently must not open on
    /// the state it was in last time.
    func loadHistory() async {
        guard service.isSignedIn else {
            history = .error(L10n.historySignInRequired)
            return
        }
        let listener = service.listenerKey
        history = .loading
        let next: LoadState<[Song]>
        do {
            let songs = try await service.history()
            next = songs.isEmpty ? .error(L10n.historyEmpty) : .success(songs)
        } catch is CancellationError {
            return
        } catch {
            next = .error(error.localizedDescription)
        }
        if listener == service.listenerKey { history = next }
    }

    // MARK: - Whole releases

    /// The tracks a release page hands its own overflow menu: the sheet opened from the page it
    /// would navigate to has the rows already, and leaves off Play, Shuffle and Open — the buttons
    /// beside the one that opened it (BrowseTarget's `fromCard = false`). Set just before the page
    /// presents the sheet; a card's long-press never sets it.
    @ObservationIgnored var pageMenuContext: (browseId: String, songs: [Song])?

    /// Hands `action` the release's whole track list (MainActivity's `withBrowseSongs`): the rows
    /// already in hand, or the full listing fetched for a card whose page was never opened. Album
    /// rows are stamped with the album's name and every row with where it was queued from.
    func songs(for item: BrowseItem, known: [Song]) async -> Result<[Song], BrowseSongsError> {
        let songs: [Song]
        if !known.isEmpty {
            songs = known
        } else if let local = service.localSongs(item.browseId) {
            guard !local.isEmpty else { return .failure(.message(L10n.noTracksHere)) }
            songs = local
        } else if LocalBrowseID.isLocal(item.browseId) {
            return .failure(.message(L10n.noTracksHere))
        } else {
            do {
                songs = try await service.allSongs(item.browseId).withArtwork(item.thumbnailUrl)
            } catch {
                let message = error.localizedDescription
                return .failure(.message(message.isEmpty ? L10n.couldntLoadTracks : message))
            }
        }
        return .success(songs.map { song in
            var stamped = song
            if item.type == .album, stamped.albumName == nil { stamped.albumName = item.title }
            stamped.playbackSource = item.title
            stamped.playbackSourceType = .browse
            stamped.playbackSourceId = item.browseId
            return stamped
        })
    }

    enum BrowseSongsError: Error, Equatable {
        case message(String)

        var text: String {
            switch self {
            case .message(let text): return text
            }
        }
    }

    /// Queues a whole release for download, filed under the release (MainActivity's
    /// `startDownload` with a `DownloadTarget`). The release's cover is stamped onto any row that
    /// has none: an album bills its artwork once, in the header, and a row saved without one is a
    /// file with no cover forever.
    func downloadAll(_ songs: [Song], item: BrowseItem) {
        let rows = songs.withArtwork(item.thumbnailUrl)
        let target = item.type == .artist ? nil : DownloadTarget(
            id: item.browseId, title: item.title, subtitle: item.subtitle,
            thumbnailUrl: item.thumbnailUrl, playlist: item.type == .playlist
        )
        enqueueDownloads(rows, target)
    }

    /// One track (the song menu's Download row).
    func download(_ song: Song) {
        enqueueDownloads([song], nil)
    }
}

extension AppRoute {
    /// The browse id a page route shows, for closing a deleted playlist's page.
    var browseId: String? {
        switch self {
        case .album(let id, _), .playlist(let id, _), .artist(let id, _): return id
        default: return nil
        }
    }
}
