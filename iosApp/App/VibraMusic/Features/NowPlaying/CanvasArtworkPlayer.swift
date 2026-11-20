import AVFoundation
import VibraMusicCore
import Canvas
import CoreImage
import Observation
import SwiftUI
import Theming
import UIKit

// Ports ui/player/PlayerState.kt's `rememberCanvasArtwork` (which clip belongs to the playing
// track) and ui/player/PlayerCanvasView.kt (the silent looping video over the sleeve). Android
// used a second ExoPlayer on a TextureView; iOS loops an AVPlayerLayer: AVPlayerLooper for a
// progressive MP4 served from CanvasClipCache, seek-to-zero for Apple's HLS.

// MARK: - Which clip

/// Where a canvas comes from; the repository in the app, a fake in tests.
protocol PlayerCanvasLookup: Sendable {
    /// Anything already settled for this track, without a network request.
    func cachedCanvas(for song: Song, spotifyFirst: Bool) async -> CanvasArtwork?
    func lookUpCanvas(for song: Song, spotifyFirst: Bool) async -> CanvasArtwork?
}

extension CanvasRepository: PlayerCanvasLookup {
    func cachedCanvas(for song: Song, spotifyFirst: Bool) async -> CanvasArtwork? {
        cached(song, spotifyFirst: spotifyFirst)
    }

    func lookUpCanvas(for song: Song, spotifyFirst: Bool) async -> CanvasArtwork? {
        await canvasFor(song, spotifyFirst: spotifyFirst)
    }
}

/// The looping clip some releases publish alongside their cover, for the playing track, or nil —
/// a miss is the normal answer.
@MainActor
@Observable
final class PlayerCanvasModel {
    /// How long a lookup waits for the track's album name before going without it: long enough to
    /// cover the album lookup on a normal connection, short enough not to be noticed.
    nonisolated static let albumSettle: TimeInterval = 0.7

    private(set) var canvas: CanvasArtwork?
    /// Whether the clip has a frame on screen right now.
    var rendered = false
    /// The decoded clip's width over height, 0 until known.
    var aspect: CGFloat = 0

    /// The identity a clip is kept across: title and artist, not the video id. A version switch
    /// swaps the video id for another cut of the same song, and a canvas is searched for by title
    /// and artist — resetting on the id threw a playing clip out mid-loop.
    @ObservationIgnored private var identity: String?
    @ObservationIgnored private let albumSettle: TimeInterval

    init(albumSettle: TimeInterval = PlayerCanvasModel.albumSettle) {
        self.albumSettle = albumSettle
    }

    /// Finds the clip for `song`. Call from `.task(id:)` keyed on the song's id, album and the
    /// policy inputs.
    ///
    /// - Parameter allowed: the switch and the Wi-Fi-only rule (``CanvasPolicy``) together.
    func load(for song: Song?, allowed: Bool, spotifyFirst: Bool, lookup: PlayerCanvasLookup) async {
        guard let song, allowed, song.localUri == nil else {
            setCanvas(nil)
            identity = nil
            return
        }
        let key = "\(song.title)\u{1F}\(song.artist)"
        if key != identity {
            identity = key
            setCanvas(nil)
        }
        // Anything settled for this track paints at once. Across a version switch the clip found
        // for the last cut is carried over — but only while it still answers to what is playing:
        // `matches` is what stops a preserved clip from being a different song's that shares a title.
        let cached = await lookup.cachedCanvas(for: song, spotifyFirst: spotifyFirst)
        let carried = canvas?.matches(title: song.title, artist: song.artist, album: song.albumName) == true ? canvas : nil
        // A skip during the lookup: the next track's load has taken over.
        guard !Task.isCancelled, identity == key else { return }
        setCanvas(cached ?? carried)

        // The album name lands a moment after the player opens and is what makes the catalogue
        // searches match. Give it that moment; if it arrives the task restarts, and a track with
        // no album still gets its search a beat later.
        if canvas == nil, song.albumName == nil, albumSettle > 0 {
            try? await Task.sleep(for: .seconds(albumSettle))
            guard !Task.isCancelled else { return }
        }
        let found = await lookup.lookUpCanvas(for: song, spotifyFirst: spotifyFirst)
        guard !Task.isCancelled, identity == key else { return }
        // Keep what an earlier pass found if this one comes back empty, rather than pulling a
        // playing clip out from under itself.
        if let found { setCanvas(found) }
    }

    private func setCanvas(_ next: CanvasArtwork?) {
        guard next != canvas else { return }
        if next?.url != canvas?.url {
            rendered = false
            aspect = 0
        }
        canvas = next
    }
}

// MARK: - The clip on screen

/// Clips downloaded once and looped from disk: a five-second clip behind a four-minute track loops
/// fifty times, and every loop re-downloading it was Android's "40 MB for one song".
enum PlayerCanvasClips {
    static let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "com.fortune.vibramusic.ios/canvas", directoryHint: .isDirectory)
    static let cache = CanvasClipCache(directory: directory)
}

/// A clip's first frame, shown under the clip. A player takes about 0.4 s to show its first frame,
/// and a clip is framed unlike the still cover, so a sheet opening from the mini player had the
/// picture change as it reached the top. With the frame up from the start, the clip arriving over
/// it changes nothing.
@MainActor
enum PlayerCanvasPosters {
    private static let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 8
        return cache
    }()

    static func cached(for canvas: CanvasArtwork) -> UIImage? {
        images.object(forKey: canvas.url as NSString)
    }

    /// Nil until the clip is on disk: an HLS stream has no frame to read until it has been joined.
    @discardableResult
    static func load(for canvas: CanvasArtwork) async -> UIImage? {
        if let image = cached(for: canvas) { return image }
        guard let file = PlayerCanvasClips.cache.cachedLocalClip(for: canvas),
              let frame = await firstFrame(of: file) else { return nil }
        let image = UIImage(cgImage: frame)
        images.setObject(image, forKey: canvas.url as NSString)
        return image
    }

    private nonisolated static func firstFrame(of file: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1200, height: 1200)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try? await generator.image(at: .zero).image
    }
}

/// The looping video over a track's cover, filling and clipped by whatever lays it out.
///
/// Silent, and it follows the transport: pausing the track stops the sleeve moving too. Nothing is
/// drawn until the first frame arrives and it fades in from there, so a failed or slow clip simply
/// leaves the still art showing. The fallback rendition gets one try if the first won't play.
struct PlayerCanvasView: View {
    let canvas: CanvasArtwork
    var isPlaying: Bool
    /// Halts decoding while the sleeve collapses into a panel and back; the last frame stays up.
    var pausedForTransition = false
    var contentMode: ContentMode = .fill
    var onRenderedChange: (Bool) -> Void = { _ in }
    var onAspectChange: (CGFloat) -> Void = { _ in }
    /// A frame off the clip as soon as it is displayed, then every
    /// ``ArtworkMeshBackdropStyle/canvasRefreshInterval`` while it plays, for a backdrop that
    /// re-tints around it; never a black or empty one. Nil when nothing wants one.
    var onFrame: ((ArtworkPixels) -> Void)?

    @Environment(AppModel.self) private var app
    @State private var rendered = false
    @State private var source: URL?
    @State private var poster: UIImage?

    var body: some View {
        PlayerCanvasClipView(
            url: source,
            fallback: canvas.fallbackUrl.flatMap(URL.init(string:)),
            playing: isPlaying && app.isInForeground && !pausedForTransition,
            gravity: contentMode == .fill ? .resizeAspectFill : .resizeAspect,
            captureFrames: onFrame != nil,
            onRendered: { value in
                rendered = value
                onRenderedChange(value)
            },
            onAspect: onAspectChange,
            onFrame: { onFrame?($0) }
        )
        .opacity(rendered ? 1 : 0)
        .animation(.easeOut(duration: 0.32), value: rendered)
        .background {
            if let poster {
                Image(uiImage: poster)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.32), value: poster == nil)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: canvas.url) {
            // A new clip starts hidden: the last one's `rendered` would show an empty layer.
            rendered = false
            source = nil
            poster = PlayerCanvasPosters.cached(for: canvas)
            if poster == nil { await showPoster() }
            guard !Task.isCancelled else { return }
            let fetched = await PlayerCanvasClips.cache.fetchClip(for: canvas, session: VibraMusicHTTP.session)
            // A cancelled fetch still answers (with the remote URL); the next clip's task owns `source`.
            guard !Task.isCancelled else { return }
            source = fetched
            // A clip this fetch brought down.
            if poster == nil { await showPoster() }
        }
        .onDisappear { onRenderedChange(false) }
    }

    private func showPoster() async {
        let image = await PlayerCanvasPosters.load(for: canvas)
        if !Task.isCancelled { poster = image }
    }
}

/// The AVPlayerLayer behind ``PlayerCanvasView``.
private struct PlayerCanvasClipView: UIViewRepresentable {
    let url: URL?
    let fallback: URL?
    let playing: Bool
    let gravity: AVLayerVideoGravity
    let captureFrames: Bool
    let onRendered: (Bool) -> Void
    let onAspect: (CGFloat) -> Void
    let onFrame: (ArtworkPixels) -> Void

    func makeUIView(context: Context) -> PlayerCanvasUIView {
        let view = PlayerCanvasUIView()
        view.playerLayer.videoGravity = gravity
        return view
    }

    func updateUIView(_ view: PlayerCanvasUIView, context: Context) {
        view.playerLayer.videoGravity = gravity
        view.onRendered = onRendered
        view.onAspect = onAspect
        view.onFrame = captureFrames ? onFrame : nil
        view.mount(url, fallback: fallback)
        view.setPlaying(playing)
    }

    static func dismantleUIView(_ view: PlayerCanvasUIView, coordinator: ()) {
        view.tearDown()
    }
}

/// The small state machine behind ``PlayerCanvasUIView/mount(_:fallback:)``: which clip the view
/// was asked for, which rendition is actually playing, and whether the fallback has had its one
/// try.
///
/// Kept apart from the player so the mount/fallback churn that flickered the artwork can be tested
/// without an AVPlayer. The bug it fixes: SwiftUI calls `mount` on every update, including the
/// twice-a-second position ticks, and the view compared the request against the rendition actually
/// playing. Once a failure had moved playback to the fallback, the next update saw the original
/// request differ from the mounted fallback, tore the player down and restarted the original,
/// which failed again — a rebuild several times a second. Remembering the *requested* url instead
/// makes a repeated request a no-op, exactly as Android's own `url` state does.
struct PlayerCanvasMountState: Equatable {
    /// What the view last asked for. A repeated request for this is a no-op however the player
    /// ended up — on the fallback, or given up — so a SwiftUI update cannot disturb a playing clip.
    private(set) var requested: URL?
    /// The rendition actually playing: the requested url until it fails, then the fallback.
    private(set) var playing: URL?
    private(set) var fallback: URL?
    private(set) var triedFallback = false

    enum Change: Equatable {
        /// The player already holds this request.
        case unchanged
        /// Tear down and start from this url; nil is a request for nothing.
        case start(URL?)
        /// Nothing left to try: stop, leave the still art up, and retry nothing.
        case stop
    }

    /// A SwiftUI update asking for `url` with `fallback`.
    mutating func mount(_ url: URL?, fallback: URL?) -> Change {
        guard url != requested else { return .unchanged }
        requested = url
        playing = url
        self.fallback = fallback
        triedFallback = false
        return .start(url)
    }

    /// The rendition playing failed: one try at the fallback, then nothing.
    mutating func failed() -> Change {
        guard !triedFallback, let fallback, fallback != playing else { return .stop }
        triedFallback = true
        playing = fallback
        return .start(fallback)
    }

    /// The view was dismantled; the next mount starts fresh.
    mutating func reset() {
        self = PlayerCanvasMountState()
    }
}

/// Owns the silent player, its looper, the ready-for-display observation and the frame reads.
///
/// `onRendered(true)` is reported only once `AVPlayerLayer.isReadyForDisplay` says a decoded frame
/// is on the layer — until then the view above keeps the layer transparent and the still art is
/// what shows. Frame reads for the backdrop follow ``CanvasFrameReadSchedule``: the first as soon
/// as the clip is displayed, then every few seconds while it plays; black or missing reads are
/// dropped here, before they can reach a mesh.
final class PlayerCanvasUIView: UIView {
    /// A sublayer, not the view's own layer, so its resize happens here with actions off. The dock
    /// resizes this view on every frame of an open or close, and a player layer resized outside
    /// an animation moves its picture with an implicit one: the clip trailed the sleeve, held
    /// still, jumped, and landed oversized over the mini player before settling, where a still
    /// cover flew smoothly.
    let playerLayer = AVPlayerLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        // The video inside is laid out now, under the same no-actions transaction.
        playerLayer.layoutIfNeeded()
        CATransaction.commit()
    }

    var onRendered: (Bool) -> Void = { _ in }
    var onAspect: (CGFloat) -> Void = { _ in }
    var onFrame: ((ArtworkPixels) -> Void)?

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var mountState = PlayerCanvasMountState()
    private var wantsPlay = false
    private var displayed = false
    private var schedule = CanvasFrameReadSchedule()
    private var readTimer: Timer?
    private var readyObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var videoOutput: AVPlayerItemVideoOutput?
    private weak var attachedItem: AVPlayerItem?
    private var endObserver: NSObjectProtocol?
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    func mount(_ url: URL?, fallback: URL?) {
        switch mountState.mount(url, fallback: fallback) {
        case .unchanged:
            break
        case .start(let next):
            tearDownPlayer()
            guard let next else { return }
            start(next)
        case .stop:
            break
        }
    }

    private func start(_ url: URL) {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOutput = output
        let player = AVQueuePlayer()
        // Silent, and never the app's audio: taking focus here would duck the music it decorates.
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.allowsExternalPlayback = false
        if url.pathExtension.lowercased() == "m3u8" {
            // AVPlayerLooper can't loop an HLS playlist; going back to zero at the end can, as long
            // as the queue keeps the finished item rather than advancing past it.
            player.actionAtItemEnd = .none
            player.insert(item, after: nil)
            endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak player] _ in
                player?.seek(to: .zero)
                player?.play()
            }
        } else {
            looper = AVPlayerLooper(player: player, templateItem: item)
        }
        self.player = player

        // The looper plays copies of its template item; the output follows whichever is current,
        // attached before that copy decodes so a read on first display finds a buffer waiting.
        itemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
            let current = player.currentItem
            DispatchQueue.main.async { self?.attachOutput(to: current) }
        }
        attachOutput(to: player.currentItem)
        statusObservation = player.observe(\.currentItem?.status, options: [.new]) { [weak self] player, _ in
            guard player.currentItem?.status == .failed else { return }
            DispatchQueue.main.async { self?.failed() }
        }
        playerLayer.player = player
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            let ready = layer.isReadyForDisplay
            DispatchQueue.main.async { self?.displayChanged(ready) }
        }
        if wantsPlay { player.play() }
    }

    private func attachOutput(to item: AVPlayerItem?) {
        guard let output = videoOutput, let item, item !== attachedItem else { return }
        if let attachedItem, attachedItem.outputs.contains(where: { $0 === output }) { attachedItem.remove(output) }
        if !item.outputs.contains(where: { $0 === output }) { item.add(output) }
        attachedItem = item
    }

    private func displayChanged(_ ready: Bool) {
        guard player != nil, ready != displayed else { return }
        displayed = ready
        onRendered(ready)
        if ready { reportAspect() }
        apply(schedule.displayChanged(ready))
    }

    private func failed() {
        switch mountState.failed() {
        case .start(let next):
            tearDownPlayer()
            guard let next else { return }
            start(next)
        case .stop:
            setUndisplayed()
        case .unchanged:
            break
        }
    }

    func setPlaying(_ playing: Bool) {
        wantsPlay = playing
        if playing { player?.play() } else { player?.pause() }
        // Called on every SwiftUI update; only a real change may touch the pending read.
        guard playing != schedule.playing else { return }
        apply(schedule.playingChanged(playing))
    }

    private func reportAspect() {
        guard let track = player?.currentItem?.presentationSize, track.height > 0 else { return }
        onAspect(track.width / track.height)
    }

    // MARK: Frame reads

    private func apply(_ next: CanvasFrameReadSchedule.Next) {
        readTimer?.invalidate()
        readTimer = nil
        switch next {
        case .none:
            break
        case .now:
            // One run-loop turn, so the frame that just made the layer ready is the one read
            // (Android's `withFrameMillis {}` before its first capture).
            DispatchQueue.main.async { [weak self] in self?.readFrame() }
        case .after(let delay):
            readTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                self?.readFrame()
            }
        }
    }

    private func readFrame() {
        guard displayed, player != nil else { return }
        let pixels = onFrame == nil ? nil : captureFrame()
        let valid = pixels.map { !$0.isLikelyBlackFrame } ?? false
        if valid, let pixels { onFrame?(pixels) }
        apply(schedule.readFinished(valid: valid || onFrame == nil))
    }

    /// One small frame off the clip at its current time. Small is the whole cost: the one caller
    /// averages the frame down to a handful of colours.
    private func captureFrame() -> ArtworkPixels? {
        guard let output = videoOutput, let item = player?.currentItem else { return nil }
        attachOutput(to: item)
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        // Not gated on hasNewPixelBuffer: a paused clip still has the frame on screen worth reading.
        guard let buffer = output.copyPixelBuffer(forItemTime: time.isValid ? time : item.currentTime(), itemTimeForDisplay: nil)
            ?? output.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil) else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = 128 / max(image.extent.width, image.extent.height, 1)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = Self.ciContext.createCGImage(small, from: small.extent) else { return nil }
        return ArtworkPixels(image: cgImage)
    }

    // MARK: Teardown

    private func setUndisplayed() {
        if displayed { onRendered(false) }
        displayed = false
        apply(schedule.displayChanged(false))
    }

    private func tearDownPlayer() {
        setUndisplayed()
        readyObservation = nil
        statusObservation = nil
        itemObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        looper?.disableLooping()
        looper = nil
        player?.pause()
        if let output = videoOutput, let attachedItem, attachedItem.outputs.contains(where: { $0 === output }) {
            attachedItem.remove(output)
        }
        attachedItem = nil
        player?.removeAllItems()
        player = nil
        videoOutput = nil
        playerLayer.player = nil
    }

    func tearDown() {
        tearDownPlayer()
        mountState.reset()
    }
}
