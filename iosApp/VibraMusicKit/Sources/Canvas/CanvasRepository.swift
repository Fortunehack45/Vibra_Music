import VibraMusicCore
import Foundation

/// Whether canvas lookups may run at all, mirroring `AppSettings.animatedCanvasAllowed(on:)`
/// so the player can gate without reaching into settings itself:
///
/// - `animatedCanvas` is the master switch (Settings > Animated canvas).
/// - `canvasOverCellular` lets clips stream on a metered connection; off by default, because a
///   clip loops for the whole track and a metered loop is an expensive loop.
public enum CanvasPolicy: Sendable {
    public static func isAllowed(
        animatedCanvas: Bool, canvasOverCellular: Bool, network: NetworkStatus
    ) -> Bool {
        animatedCanvas && (canvasOverCellular || network.isMetered != true)
    }
}

/// Finds the looping video that belongs behind a track's or a release's cover art — Spotify's
/// Canvas, Apple's motion artwork (Android: `CanvasRepository` in
/// `data/canvas/CanvasRepository.kt`).
///
/// Four sources, asked in turn until one answers. They cover genuinely different ground rather
/// than being four routes to the same catalogue: Apple has the most, Tidal has square covers
/// on a lot of what Apple misses, the community index is the only one that reaches back
/// catalogue, and Spotify has the original Canvas but needs the listener's own session cookie
/// to reach (see `CanvasSpotifyTokenStore`) and is a free no-op without one. Spotify goes
/// last by default even once it's set up: it's the heaviest of the four to reach (a web-view
/// harvest, not just a request) and the other three between them already cover most of what
/// it would have answered. Pass `spotifyFirst: true` (the Spotify integration setting) to put
/// it first when its original Canvas matters more than that lookup cost.
///
/// Every source is a public endpoint belonging to someone else, reached without an account,
/// and all of them will confidently answer a search with the wrong record. So the shape of
/// this is: ask, then re-check the answer against what was asked for
/// (`CanvasArtwork.matches`), and treat any failure — network, parse, mismatch — as simply
/// no canvas. The still art is always underneath, so nothing here can break the player or the
/// album page.
///
/// Results are cached, misses included: nothing having a canvas is the common case, and
/// without negative caching every revisit would pay for three lookups again to learn the same
/// thing.
///
/// An actor, but a reentrant one: while a lookup waits on the network, the next call gets in.
/// What keeps the requests down is `inFlight`: a second ask for a key that is already being
/// looked up waits for that lookup instead of starting its own, so the player and the lock
/// screen asking about the same track share one round of requests.
public actor CanvasRepository {
    /// The player mounts this when a lookup misses and there is nothing to animate.
    public static let cacheCapacity = 64

    /// A settled answer for one track or release.
    ///
    /// `withAlbum` records whether the album name was known when this was worked out. It is
    /// the one thing that can turn a miss into a hit later: the album is what makes the
    /// catalogue searches land, and on the player it resolves a beat after the track starts. A
    /// miss reached without it is therefore provisional; everything else is final.
    struct Entry: Sendable {
        var artwork: CanvasArtwork?
        var withAlbum: Bool

        /// Whether this answer can stand in for a lookup that now knows `withAlbum`.
        /// A hit is a hit — the album could only have confirmed it. A miss stands too, unless
        /// it was reached blind and there is now an album name to try, which is the one case
        /// worth spending a second round of requests on.
        func isReusable(nowWithAlbum: Bool) -> Bool {
            artwork != nil || withAlbum || !nowWithAlbum
        }
    }

    private let apple: AppleMusicCanvas
    private let tidal: TidalCanvas
    private let community: CommunityCanvas
    private let spotify: SpotifyCanvas

    private var cache: [String: Entry] = [:]
    private var recency: [String] = []

    /// A lookup that has started and not yet stored its answer. It runs to completion even if
    /// the caller that started it is cancelled (the player moves on): a cancelled network call
    /// reads as "no canvas", and that miss must not be cached as the track's answer.
    private struct InFlight {
        var id = UUID()
        var task: Task<CanvasArtwork?, Never>
        var withAlbum: Bool
    }
    private var inFlight: [String: InFlight] = [:]

    public init(
        session: URLSession = VibraMusicHTTP.session,
        tokens: CanvasSpotifyTokenStore? = nil,
        appleTokens: CanvasAppleTokenStore? = nil,
        storefront: String? = nil,
        countryCode: String? = nil
    ) {
        let session = session
        apple = AppleMusicCanvas(session: session, storefront: storefront, tokens: appleTokens)
        tidal = TidalCanvas(session: session, countryCode: countryCode)
        community = CommunityCanvas(session: session)
        spotify = SpotifyCanvas(
            session: session,
            tokens: tokens ?? CanvasSpotifyTokenStore(session: session))
    }

    /// Test seam: fixed answers per source instead of the network.
    init(
        apple: AppleMusicCanvas,
        tidal: TidalCanvas,
        community: CommunityCanvas,
        spotify: SpotifyCanvas
    ) {
        self.apple = apple
        self.tidal = tidal
        self.community = community
        self.spotify = spotify
    }

    /// The canvas for `song`, or nil when there isn't one. Never throws.
    ///
    /// A local file with no catalogue identity (no `Song.videoId`) is answered as a miss
    /// without a request — there is nothing to search on. Downloaded tracks carry a videoId
    /// and full metadata, so they get the same canvas lookup as streaming ones; the
    /// Wi-Fi-only guard lives in the caller (see `CanvasPolicy`), which checks it before
    /// asking.
    public func canvasFor(_ song: Song, spotifyFirst: Bool = false) async -> CanvasArtwork? {
        // Only skip when there is no catalogue identity to search on.
        if song.videoId.isBlankForCanvas, song.localUri != nil || song.localPath != nil { return nil }

        let title = CanvasText.cleanedTrackText(song.title)
        let artist = CanvasText.cleanedTrackText(song.artist)
        if title.isBlankForCanvas || artist.isBlankForCanvas { return nil }

        // Keyed on the track alone. The album is deliberately not part of this: it arrives
        // after the player opens, and keying on it made the late arrival look like a different
        // question and run the whole chain a second time. `Entry.isReusable` decides when the
        // earlier answer still stands instead.
        let album = song.albumName
        let key = Self.cacheKey(base: "song|\(song.videoId)", spotifyFirst: spotifyFirst)
        return await resolve(key: key, withAlbum: album != nil) {
            if spotifyFirst {
                await self.firstHit(
                    { await self.spotify.search(title: title, artist: artist, album: album) },
                    { await self.apple.search(title: title, artist: artist, album: album) },
                    { await self.tidal.search(title: title, artist: artist, album: album) },
                    { await self.community.search(title: title, artist: artist, album: album) },
                    accept: { $0.matches(title: title, artist: artist, album: album) })
            } else {
                await self.firstHit(
                    { await self.apple.search(title: title, artist: artist, album: album) },
                    { await self.tidal.search(title: title, artist: artist, album: album) },
                    { await self.community.search(title: title, artist: artist, album: album) },
                    { await self.spotify.search(title: title, artist: artist, album: album) },
                    accept: { $0.matches(title: title, artist: artist, album: album) })
            }
        }
    }

    /// A canvas already worked out for `song`, without going near the network.
    ///
    /// Lets a caller paint what it knows before it starts waiting on anything — reopening the
    /// player on a track resolved a minute ago should not go through the settling delay again
    /// to arrive back at the same clip.
    public func cached(_ song: Song, spotifyFirst: Bool = false) -> CanvasArtwork? {
        cache[Self.cacheKey(base: "song|\(song.videoId)", spotifyFirst: spotifyFirst)]?.artwork
    }

    /// The canvas for a release, for the album page's header artwork.
    ///
    /// A separate lookup rather than the first track's: the services hang motion artwork off
    /// the album, so asking for it directly is both fewer requests and a better match than
    /// picking a song and hoping it sits on the right edition.
    public func canvasForAlbum(_ album: String, artist: String, spotifyFirst: Bool = false) async -> CanvasArtwork? {
        let name = CanvasText.cleanedTrackText(album)
        let credit = CanvasText.cleanedTrackText(artist)
        if name.isBlankForCanvas || credit.isBlankForCanvas { return nil }

        return await resolve(key: Self.cacheKey(
            base: "album|\(name)|\(credit)", spotifyFirst: spotifyFirst), withAlbum: true)
        {
            if spotifyFirst {
                await self.firstHit(
                    { await self.spotify.searchAlbum(album: name, artist: credit) },
                    { await self.apple.searchAlbum(album: name, artist: credit) },
                    { await self.tidal.searchAlbum(album: name, artist: credit) },
                    { await self.community.searchAlbum(album: name, artist: credit) },
                    accept: { $0.matches(title: name, artist: credit, album: name) })
            } else {
                await self.firstHit(
                    { await self.apple.searchAlbum(album: name, artist: credit) },
                    { await self.tidal.searchAlbum(album: name, artist: credit) },
                    { await self.community.searchAlbum(album: name, artist: credit) },
                    { await self.spotify.searchAlbum(album: name, artist: credit) },
                    accept: { $0.matches(title: name, artist: credit, album: name) })
            }
        }
    }

    /// Priority is part of the question, so toggling the Spotify-first setting never reuses
    /// the other order's answer.
    static func cacheKey(base: String, spotifyFirst: Bool) -> String {
        "\(base)|spotifyFirst=\(spotifyFirst)"
    }

    private func resolve(
        key: String, withAlbum: Bool, lookUp: @escaping @Sendable () async -> CanvasArtwork?
    ) async -> CanvasArtwork? {
        if let entry = cache[key], entry.isReusable(nowWithAlbum: withAlbum) {
            touch(key)
            return entry.artwork
        }
        // A blind lookup can't answer for one that now knows the album, same as a stored miss.
        if let running = inFlight[key], running.withAlbum || !withAlbum {
            return await running.task.value
        }
        let id = UUID()
        let task = Task { () -> CanvasArtwork? in
            let found = await lookUp()
            self.settle(key: key, id: id, entry: Entry(artwork: found, withAlbum: withAlbum))
            return found
        }
        inFlight[key] = InFlight(id: id, task: task, withAlbum: withAlbum)
        return await task.value
    }

    private func settle(key: String, id: UUID, entry: Entry) {
        if inFlight[key]?.id == id { inFlight[key] = nil }
        // A lookup that began blind can finish after the album-aware one; its miss must not
        // replace a clip already found, or an answer reached knowing more.
        if entry.artwork == nil, let held = cache[key], held.artwork != nil || held.withAlbum {
            touch(key)
            return
        }
        store(key: key, entry: entry)
    }

    /// The first source that answers with something that survives `accept`.
    ///
    /// Sources run one at a time so each is only reached — and only paid for — if the ones
    /// before it came up empty. A source never throws (each returns nil on any failure), but
    /// the lookup is still guarded: none of these hosts are ours, and a missing canvas is not
    /// worth surfacing as an error.
    private func firstHit(
        _ sources: () async -> CanvasArtwork?...,
        accept: (CanvasArtwork) -> Bool
    ) async -> CanvasArtwork? {
        for source in sources {
            guard let found = await source() else { continue }
            if !accept(found) {
                canvasLogDebug("CanvasRepository: rejected '\(found.title ?? "?")' by '\(found.artist ?? "?")'")
                continue
            }
            return found
        }
        return nil
    }

    private func store(key: String, entry: Entry) {
        cache[key] = entry
        touch(key)
        while recency.count > Self.cacheCapacity, let oldest = recency.first {
            recency.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    private func touch(_ key: String) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    /// Test hook: how many settled answers are held.
    var cacheCount: Int { cache.count }

    /// Test hook: drop every settled answer.
    func clearCache() {
        cache.removeAll()
        recency.removeAll()
    }
}
