import AVFoundation
import VibraMusicCore
import Canvas
import Foundation
import MediaPlayer
import Observation
import UIKit
import Playback

/// The lock-screen animated cover: the playing track's Canvas clip, resolved here and handed to
/// the engine for `MPMediaItemAnimatedArtwork`. Follows the player from `start()`
/// like ``CurrentTrackLyrics`` does, and deliberately not the player screen — the lock screen is
/// where the motion shows, whether or not Now Playing is open.
///
/// iOS-only on purpose: Android's engine publishes no animated artwork, so there is no port to
/// mirror. iOS 26+ takes it (`NowPlayingInfoBuilder` gates the publish); below that the still
/// cover stays as it always was and nothing here is even asked for.
///
/// What makes it onto the lock screen is decided by the pure key choice in
/// `NowPlayingInfoBuilder.animatedArtworkKey` — this side's job is only to fetch under
/// ``CanvasPolicy``, read the clip's true pixel size, and publish nothing when any part fails:
/// a miss, a metered network under Wi-Fi-only, a 9:16 clip, or a fetch that ends a stream
/// instead of a file all leave the still artwork exactly as it was.
/// Why the lock screen has (or lacks) an animated cover, for the nerd-stats overlay.
/// Diagnostic only: one test on a device shows which link in the chain broke.
@MainActor
@Observable
final class LockArtDiagnostic {
    var decision = "idle"
}

@MainActor
final class CurrentTrackCanvas {
    /// The last decision, for the nerd-stats overlay.
    let diagnostic = LockArtDiagnostic()
    /// Publishes to the engine: `app.player.engine.nowPlayingAnimatedArtworks`.
    private let publish: @MainActor ([NowPlayingAnimatedArtwork]) -> Void
    private let lookup: PlayerCanvasLookup
    private let cache: CanvasClipCache
    /// Downloads go through the app's HTTP session; tests stub it.
    private let session: URLSession
    /// Reads the clip's real pixel size off the asset (never from the URL), injectable so tests
    /// answer without decoding a video.
    private let videoSize: @Sendable (URL) async -> CGSize?
    /// Why the 3:4 tall clip is not wanted here, nil when it is (an iPhone whose system lists
    /// the 3x4 key): it is only fetched when it has somewhere to go. Injectable for tests.
    private let tallSkip: @MainActor () -> String?

    /// What the resolution belongs to: the track and the policy inputs. A change drops the clip
    /// at once, before the new lookup even starts.
    struct Key: Equatable {
        /// The engine's item, not only the song: a rendition swap (a quality upgrade) or the same
        /// song in another queue slot is a new item, and the engine drops the clip on every item
        /// change, so the resolver has to run again for it.
        var itemID: String?
        var videoId: String?
        /// Whether the album is known yet: it often lands a beat after the track opens, and a
        /// lookup run without it is only a provisional miss in CanvasRepository, retried once
        /// asked again with the album (as the player screen's canvas key does).
        var hasAlbum: Bool
        var allowed: Bool
        var spotifyFirst: Bool
    }

    /// The key for what one turn of policy and track state asks about, as the tracker reads it.
    static func key(itemID: String? = nil, song: Song?, allowed: Bool, spotifyFirst: Bool) -> Key {
        Key(itemID: itemID, videoId: song?.videoId, hasAlbum: song?.albumName?.isEmpty == false,
            allowed: allowed, spotifyFirst: spotifyFirst)
    }

    private var tracker: ChangeTracker?
    private var networkTask: Task<Void, Never>?
    private var wanted: Key?
    private var loader: Task<Void, Never>?


    init(
        lookup: PlayerCanvasLookup,
        cache: CanvasClipCache,
        session: URLSession = VibraMusicHTTP.session,
        videoSize: @escaping @Sendable (URL) async -> CGSize? = CurrentTrackCanvas.assetSize,
        tallSkip: @escaping @MainActor () -> String? = CurrentTrackCanvas.systemTallSkip,
        publish: @escaping @MainActor ([NowPlayingAnimatedArtwork]) -> Void
    ) {
        self.lookup = lookup
        self.cache = cache
        self.session = session
        self.videoSize = videoSize
        self.tallSkip = tallSkip
        self.publish = publish
    }

    convenience init(app: AppModel) {
        self.init(
            lookup: app.canvas,
            cache: PlayerCanvasClips.cache
        ) { [weak app] in app?.player.engine.nowPlayingAnimatedArtworks = $0 }
    }

    /// Follows `player` from now on, resolving as the track or the policy changes — through the
    /// settings the canvas switch and Wi-Fi-only rule read, and the network, whose changes are
    /// tracked separately (``NetworkStatusProviding/statusUpdates()``) because the network is
    /// not itself observed.
    func follow(app: AppModel) {
        tracker?.cancel()
        tracker = ChangeTracker.track({ [weak app] in
            Self.key(itemID: app?.player.engine.currentItem?.id,
                     song: app?.player.currentSong,
                     allowed: Self.allowed(for: app),
                     spotifyFirst: app?.settings.prioritizeSpotifyCanvas ?? false)
        }) { [weak self, weak app] key in
            guard let self, let app else { return }
            // Re-keyed here, in the same turn as the change, not in the task below: a resolve
            // still in flight for the last track must stop counting as wanted before it can
            // land its clip on this one.
            self.rekey(key)
            Task { [weak self] in await self?.apply(from: app) }
        }
        // The network is not an observable AppModel member, so a metered flip re-applies here.
        // A flutter of statuses resolves a burst of tasks; each is idempotent, and the loader's
        // tag check keeps only the newest one's answer.
        networkTask?.cancel()
        let network = app.network
        networkTask = Task { [weak self, weak app] in
            for await _ in network.statusUpdates() {
                guard let app else { return }
                Task { [weak self] in await self?.apply(from: app) }
            }
        }
    }

    func stopFollowing() {
        tracker?.cancel()
        tracker = nil
        networkTask?.cancel()
        networkTask = nil
    }

    // MARK: - Resolving

    /// Re-resolves for what is playing now. Called when the tracked key changes or the network
    /// status does; idempotent across repeats of the same key.
    func apply(from app: AppModel) async {
        let song = app.player.currentSong
        let allowed = Self.allowed(for: app)
        await update(itemID: app.player.engine.currentItem?.id, song: song, allowed: allowed,
                     spotifyFirst: app.settings.prioritizeSpotifyCanvas)
    }

    /// Makes `key` the wanted one; on a change, drops the in-flight resolve and the last clip.
    private func rekey(_ key: Key) {
        guard key != wanted else { return }
        wanted = key
        loader?.cancel()
        loader = nil
        // First act, before anything is looked up again: the last track's clip must not stand
        // in for this one's while the lookup runs.
        publish([])
    }

    /// What one turn of policy and track state resolves to. Test entry point.
    func update(itemID: String? = nil, song: Song?, allowed: Bool, spotifyFirst: Bool) async {
        let key = Self.key(itemID: itemID, song: song, allowed: allowed, spotifyFirst: spotifyFirst)
        rekey(key)
        // Nothing without canvas: the switch off, Wi-Fi-only on a metered network, or a local
        // file (the same rule the player screen's canvas follows). Nothing at all is reached,
        // let alone downloaded.
        guard let song else { diagnostic.decision = "no song"; return }
        guard allowed else { diagnostic.decision = "skipped: canvas off or Wi-Fi-only on a metered network"; return }
        guard song.localUri == nil else { diagnostic.decision = "skipped: a local file"; return }
        // Nor below iOS 26, where the system takes no animated artwork at all: resolving here
        // would only spend downloads the dictionary has nowhere to put.
        guard #available(iOS 26.0, *) else { diagnostic.decision = "skipped: iOS below 26"; return }
        diagnostic.decision = "looking up a clip"
        let tag = key
        let loader = Task { [weak self] in
            guard let self else { return }
            await self.resolve(song, spotifyFirst: spotifyFirst, for: tag)
        }
        self.loader = loader
        await loader.value
    }

    private func resolve(_ song: Song, spotifyFirst: Bool, for tag: Key) async {
        let canvas = await lookup.lookUpCanvas(for: song, spotifyFirst: spotifyFirst)
        guard stillWanted(tag) else { return }
        guard let canvas else { diagnostic.decision = "no clip for this track"; return }
        let (main, mainNote) = await localClip(canvas, song: song, for: tag)
        guard stillWanted(tag) else { return }
        // The builder puts each clip under the key its own shape selects; a shape it can't
        // place (a 9:16 Spotify Canvas) stays out there. The main clip goes out at once, not
        // behind the tall one's download.
        var published = main != nil
        if let main { publish([main]) }
        // Ready before the player is next opened, so the sheet rises with the clip's own frame.
        await PlayerCanvasPosters.load(for: canvas)
        guard stillWanted(tag) else { return }
        // The 3:4 rendition beside it, for the iPhone's full-screen lock screen, under the same
        // switch and Wi-Fi rule the gate above already applied.
        var tallNote = "no tall clip"
        if let skip = tallSkip() {
            tallNote = skip
        } else if let tallUrl = canvas.tallUrl {
            let (tall, note) = await localClip(CanvasArtwork(url: tallUrl), song: song, for: tag)
            guard stillWanted(tag) else { return }
            tallNote = note
            if let tall {
                publish([main, tall].compactMap { $0 })
                published = true
            }
        }
        diagnostic.decision = "clip \(mainNote) · 3x4: \(tallNote)"
            + (published ? " · handed to the engine" : ": skipped")
    }

    /// One clip as a local file with its real pixel size, or nil and the step that failed.
    private func localClip(
        _ canvas: CanvasArtwork, song: Song, for tag: Key
    ) async -> (NowPlayingAnimatedArtwork?, String) {
        let host = URL(string: canvas.url)?.host ?? "?"
        // The local file under the system's rule: progressive MP4s download once to
        // CanvasClipCache and loop from disk; Apple's HLS is joined into one local MP4 there.
        guard let url = await cache.fetchLocalClip(for: canvas, session: session) else {
            return (nil, canvas.isHLS ? "HLS from \(host) could not be joined into a file" : "from \(host) did not download")
        }
        // A size that answers non-positively (corrupt video, audio-only) is as good as none:
        // no key can be chosen from it.
        guard let size = await videoSize(url), size.width > 0, size.height > 0 else {
            return (nil, "from \(host) has no readable video size")
        }
        let artwork = NowPlayingAnimatedArtwork(
            fileURL: url,
            pixels: size,
            artworkID: Self.artworkID(for: url, still: song.thumbnailUrl),
            itemID: tag.itemID
        )
        return (artwork, "\(Int(size.width))x\(Int(size.height)) from \(host)")
    }

    /// Still this key's turn, in the loader: a change of track, policy or network cancels and
    /// re-keys, and a stale resolution never lands.
    private func stillWanted(_ tag: Key) -> Bool {
        wanted == tag && !Task.isCancelled
    }

    /// The clip's identity together with its preview, per the system's rule that artworkID
    /// changes whenever either changes: the cache file name is itself a hash of the clip URL,
    /// which also names the preview (the clip's first frame); the cover URL stands for the still
    /// a square clip falls back to. "frame0" retires ids whose preview was the still cover, so
    /// the system drops the square previews it holds under them.
    static func artworkID(for clipFile: URL, still cover: String?) -> String {
        let clip = clipFile.deletingPathExtension().lastPathComponent
        return "\(clip)/frame0/\(cover ?? "none")"
    }

    /// The tall clip is for iPhone only (by design: iPad lists 1x1 alone, and Apple lays
    /// out the lock screen), and only where the system lists the 3x4 key. Nil when it is wanted,
    /// else why not, for the nerd-stats line.
    static func tallSkip(isPhone: Bool, offers3x4: Bool) -> String? {
        if !isPhone { return "iPad" }
        if !offers3x4 { return "not offered" }
        return nil
    }

    static func systemTallSkip() -> String? {
        guard #available(iOS 26.0, *) else { return "not offered" }
        return tallSkip(
            isPhone: UIDevice.current.userInterfaceIdiom == .phone,
            offers3x4: MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys.contains(MPNowPlayingInfoProperty3x4AnimatedArtwork))
    }

    private static func allowed(for app: AppModel?) -> Bool {
        guard let app else { return false }
        return CanvasPolicy.isAllowed(
            animatedCanvas: app.settings.animatedCanvas,
            canvasOverCellular: app.settings.canvasOverCellular,
            network: app.network.status)
    }

    /// The real pixel size of the video at `url`, from the asset's own track — width, height and
    /// any rotation note it carries — never guessed from the URL. Nil when it reads as no video.
    static func assetSize(of url: URL) async -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform),
              size.width > 0, size.height > 0 else { return nil }
        let applied = CGRect(origin: .zero, size: size).applying(transform).size
        return CGSize(width: abs(applied.width), height: abs(applied.height))
    }
}

