import VibraMusicCore
import Canvas
import MediaPlayer
import Observation
import PlaybackQueue
import SwiftUI
import Theming

// Ports PlayerState.kt's PlayerArtwork (one cover for every surface, whether it has loaded, and
// the bounded retries after a failure) and the artwork halves of NowPlayingScreen.kt: the sleeve,
// the full-bleed banner it dissolves into, and the stats for nerds on its foot.

// MARK: - The cover

/// The player's cover: loaded once at the player's size and shared by the sleeve, the banner, the
/// thumbnail over a panel and the landscape sleeve, so none of them reloads it.
///
/// A cover that fails gets a few more goes, spaced out: the usual reason is no network at all,
/// and past a few tries the placeholder tile is the honest thing to draw.
@MainActor
@Observable
final class PlayerArtworkLoader {
    nonisolated static let retries = 3
    nonisolated static let retryDelay: TimeInterval = 1.5

    private(set) var url: URL?
    private(set) var image: UIImage?
    /// Which go at this cover we are on.
    private(set) var attempt = 0

    var loaded: Bool { image != nil }

    typealias Fetch = @Sendable (URL) async -> UIImage?

    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let retryDelay: TimeInterval

    init(retryDelay: TimeInterval = PlayerArtworkLoader.retryDelay, fetch: @escaping Fetch = { await ArtworkImageCache.shared.image(for: $0) }) {
        self.retryDelay = retryDelay
        self.fetch = fetch
    }

    /// The cover for `song` at the player's size (the widget and the lock screen ask for the same
    /// rung, so one fetch serves all of them).
    static func url(for song: Song?) -> URL? {
        Artwork.resized(song?.thumbnailUrl, to: ArtworkSize.player).flatMap(URL.init(string:))
    }

    /// The mini player's cover: what the first frames of a flight show while the player's own
    /// 1200 px cover is still loading, instead of the placeholder tile over a cover the mini player
    /// is plainly showing. From memory, else decoded from its file now: the memory cache is purged
    /// behind the mini player's back (a stay in the background does it) while the bar keeps
    /// drawing its copy, and a flight that waited for a task started with the tile.
    static func standIn(for song: Song?) -> UIImage? {
        guard let url = Artwork.resized(song?.thumbnailUrl, to: ArtworkSize.row).flatMap(URL.init(string:)) else { return nil }
        let cache = ArtworkImageCache.shared
        return cache.memoryImage(for: url, pixels: ArtworkSize.row) ?? cache.diskImage(for: url, pixels: ArtworkSize.row)
    }

    /// Loads `url`, retrying a failure up to ``retries`` times. Call from `.task(id: url)`.
    func load(_ url: URL?) async {
        if url != self.url {
            self.url = url
            attempt = 0
            // Two tracks off one album share a cover: keep it on screen rather than blanking it.
            if url == nil { image = nil }
        }
        guard let url else { return }
        if let cached = ArtworkImageCache.shared.memoryImage(for: url) {
            image = cached
            return
        }
        while !Task.isCancelled {
            if let fetched = await fetch(url) {
                guard url == self.url else { return }
                image = fetched
                return
            }
            guard url == self.url, attempt < Self.retries else {
                if url == self.url { image = nil }
                return
            }
            attempt += 1
            try? await Task.sleep(for: .seconds(retryDelay))
        }
    }
}

// MARK: - Warming

/// Warms the covers a skip is about to show: the next and previous queue entries' player cover,
/// mesh, tint and blurred backdrop, so the swap paints them on its first frame. Everything is read
/// at the URL and size the player itself asks for, and the colour reads take the cover's bytes from
/// the image cache, so each neighbour costs one download and nothing is fetched twice.
///
/// Like the list prefetch it has no data-saver gate: the app has no such setting to read.
@MainActor
final class PlayerArtworkWarmer {
    /// Skipping through several tracks in a row warms only where it comes to rest.
    static let settleDelay: Duration = .seconds(1.5)

    private let images: ArtworkImageCache
    private let palettes: ArtworkPaletteCache
    private let delay: Duration
    private var pending: Task<Void, Never>?

    init(images: ArtworkImageCache = .shared, palettes: ArtworkPaletteCache = .shared, delay: Duration = PlayerArtworkWarmer.settleDelay) {
        self.images = images
        self.palettes = palettes
        self.delay = delay
    }

    /// The entries a skip back or forward lands on.
    static func neighbours(in state: PlaybackQueueState) -> [Song] {
        [state.previousIndex, state.nextIndex].compactMap { $0.flatMap { state.songs.indices.contains($0) ? state.songs[$0] : nil } }
    }

    /// Warms `songs` once the queue has stayed put for ``settleDelay``.
    func schedule(_ songs: [Song]) {
        pending?.cancel()
        pending = Task { [self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await warm(songs)
        }
    }

    func warm(_ songs: [Song]) async {
        let urls = songs.compactMap(PlayerArtworkLoader.url(for:))
        let size = ArtworkSize.player
        for url in urls {
            // Unsized, the key the player draws its cover from.
            async let cover = images.image(for: url)
            async let mesh = palettes.mesh(for: url, artPixels: size)
            async let seed = palettes.seed(for: url, artPixels: size)
            async let blur = palettes.blurredArtwork(for: url, artPixels: size)
            _ = await (cover, mesh, seed, blur)
        }
    }
}

// MARK: - Sleeve

/// The square cover card: the picture or the placeholder tile, and the clip over it. Its size,
/// corners and shadow are the dock's (`.docked`). The shadow is only cast once there is a picture:
/// on the flat placeholder tile a shadow reads as a second, darker square.
struct PlayerSleeve: View {
    let image: UIImage?
    /// The clip, when it plays inside the sleeve rather than as the banner.
    var canvas: CanvasArtwork?
    var isPlaying = false
    var pausedForTransition = false
    var onCanvasRendered: (Bool) -> Void = { _ in }
    var onCanvasFrame: ((ArtworkPixels) -> Void)?

    var body: some View {
        // Overlays of a flexible base, so a filled picture can't size the sleeve: `scaledToFill`
        // reports the size that covers the box, so a 16:9 cover laid out in a ZStack made the
        // sleeve wider than its square, and the frame around it then centred the overflow.
        Color.black.opacity(0.18)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    Image(systemName: AppSymbol.musicNote)
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .overlay {
                if let canvas {
                    PlayerCanvasView(
                        canvas: canvas,
                        isPlaying: isPlaying,
                        pausedForTransition: pausedForTransition,
                        onRenderedChange: onCanvasRendered,
                        onFrame: onCanvasFrame
                    )
                }
            }
            .animation(.easeOut(duration: 0.25), value: image == nil)
    }
}

// MARK: - Full-bleed banner

/// The artwork edge to edge, running up behind the status bar and dissolving into the backdrop
/// where the sleeve's bottom edge would have been — so the screen carries on in the colours the
/// artwork ended in. The clip, when there is one, plays here instead of in the sleeve. Its size,
/// dissolve and corners are the dock's (`.docked`).
struct PlayerHeroBanner: View {
    let image: UIImage?
    var canvas: CanvasArtwork?
    var isPlaying = false
    var pausedForTransition = false
    var onCanvasRendered: (Bool) -> Void = { _ in }
    var onCanvasFrame: ((ArtworkPixels) -> Void)?

    var body: some View {
        // Overlays of a flexible clear base, so the filled picture can't size the banner.
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .overlay {
                if let canvas {
                    PlayerCanvasView(
                        canvas: canvas,
                        isPlaying: isPlaying,
                        pausedForTransition: pausedForTransition,
                        onRenderedChange: onCanvasRendered,
                        onFrame: onCanvasFrame
                    )
                    .dockClipFade()
                }
            }
            .animation(.easeOut(duration: 0.3), value: image == nil)
    }
}

// MARK: - Stats for nerds

/// The measured stream on the foot of the sleeve, and under it what Automix's analysis is doing.
/// A shadow keeps the white line legible over a pale stretch of cover.
struct PlayerNerdStatsOverlay: View {
    let statsLine: String?
    let automixLine: String?
    /// The lock screen's animated-cover chain, when the player passes it.
    var lockArt: LockArtDiagnostic? = nil

    var body: some View {
        VStack(spacing: 1) {
            if let statsLine {
                Text(statsLine)
                    .foregroundStyle(.white.opacity(0.65))
                    .accessibilityIdentifier("nowPlaying.nerdStats")
            }
            if let automixLine {
                Text(automixLine).foregroundStyle(.white.opacity(0.5))
            }
            if let lockArt {
                // Re-read every second: what the system lists and what it actually holds now.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(Self.lockArtLine(lockArt.decision))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(3)
                }
            }
        }
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .multilineTextAlignment(.center)
        .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .allowsHitTesting(false)
    }

    /// Lock art: the keys the system lists for this app, our last decision, and whether the live
    /// Now Playing info holds an animated cover right now.
    static func lockArtLine(_ decision: String) -> String {
        let keySquare = "MPNowPlayingInfoProperty1x1AnimatedArtwork"
        let keyTall = "MPNowPlayingInfoProperty3x4AnimatedArtwork"
        let names = [keySquare: "1x1", keyTall: "3x4"]
        let listed: [String] = []
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        let held = names.keys.filter { info[$0] != nil }.compactMap { names[$0] }.sorted()
        let keys = listed.isEmpty ? "none" : listed.joined(separator: ",")
        let inInfo = held.isEmpty ? "no" : held.joined(separator: ",")
        return "Lock art: system keys \(keys) · \(decision) · in Now Playing: \(inInfo)"
    }
}
