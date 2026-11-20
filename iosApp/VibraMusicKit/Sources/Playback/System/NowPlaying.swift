import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import MediaPlayer
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Where the engine publishes what is playing. The default writes to `MPNowPlayingInfoCenter`,
/// which feeds the lock screen, Control Center, CarPlay, AirPods and the watch — the iOS side of the
/// Android media notification. Tests inject a recorder.
@MainActor
public protocol NowPlayingPublishing: AnyObject {
    /// The full info dictionary (`MPMediaItemProperty…` / `MPNowPlayingInfoProperty…` keys), or nil
    /// to clear it.
    func publish(_ info: [String: Any]?)
    /// Whether playback is running. On macOS the system reads this separately from the info.
    func publishPlaybackState(isPlaying: Bool, hasItem: Bool)
}

/// The system Now Playing center.
@MainActor
public final class SystemNowPlayingCenter: NowPlayingPublishing {
    private let center: MPNowPlayingInfoCenter

    public init(center: MPNowPlayingInfoCenter = .default()) {
        self.center = center
    }

    public func publish(_ info: [String: Any]?) {
        center.nowPlayingInfo = info
    }

    public func publishPlaybackState(isPlaying: Bool, hasItem: Bool) {
        #if os(macOS)
        center.playbackState = hasItem ? (isPlaying ? .playing : .paused) : .stopped
        #endif
    }
}

/// The track's animated cover for the lock screen — what Spotify calls a Canvas and Apple calls
/// motion artwork (Android has nothing to port: its engine publishes no animated artwork, so
/// this is a deliberate iOS addition). The app resolves the clip for the item now playing —
/// through `CanvasRepository` and `CanvasClipCache`, under ``CanvasPolicy`` — and hands it to the
/// engine; `NowPlayingInfoBuilder` puts it in the dictionary under one of the two keys the
/// system supports.
///
/// iOS 26+ only: below that, the builder publishes nothing and the still cover stays as it was.
public struct NowPlayingAnimatedArtwork: Equatable, Sendable {
    /// The clip's on-disk file (`CanvasClipCache`): the only kind of asset URL the system accepts.
    public var fileURL: URL
    /// The clip's real pixel size, read off the asset itself — never guessed from a URL, because
    /// the shape decides which key the system may be given it under.
    public var pixels: CGSize
    /// Changes whenever the clip changes; the system re-reads both the preview and the video
    /// behind a changed id, so a changed clip must always land here with a different id.
    public var artworkID: String
    /// The engine item this clip was resolved for, when the resolver knows it. The engine
    /// publishes the clip only while that item is current, so a resolve that finishes just after
    /// a track change can never show the last track's motion under the new one.
    public var itemID: String?

    public init(fileURL: URL, pixels: CGSize, artworkID: String, itemID: String? = nil) {
        self.fileURL = fileURL
        self.pixels = pixels
        self.artworkID = artworkID
        self.itemID = itemID
    }
}

/// Builds the Now Playing dictionary. Pure, so its contents can be tested.
enum NowPlayingInfoBuilder {
    struct Snapshot {
        var item: PlayableItem
        var position: TimeInterval
        var duration: TimeInterval
        var isPlaying: Bool
        var rate: Float
        var subtitleOverride: String?
        var artwork: MPMediaItemArtwork?
        /// The resolved clips for the lock screen, empty with none. Each is placed under the
        /// animated-artwork key its shape selects, on iOS 26+ only (``NowPlayingAnimatedArtwork``);
        /// the first clip of a shape wins its key.
        var animatedArtworks: [NowPlayingAnimatedArtwork] = []
    }

    static func info(_ snapshot: Snapshot) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.item.title,
            // What the lock screen draws under the title. A synced lyric line may stand in for the
            // artist here, as it did on the Android notification.
            MPMediaItemPropertyArtist: snapshot.subtitleOverride.flatMap { $0.isEmpty ? nil : $0 } ?? snapshot.item.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(snapshot.position, 0),
            // 0 while paused: the system extrapolates the elapsed time from this rate, so a paused
            // item reporting 1 would keep counting on the lock screen.
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.isPlaying ? Double(snapshot.rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(snapshot.rate),
            // Surfaces classify a session by media type; untyped ones get the generic card.
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyExternalContentIdentifier: opaqueIdentifier(snapshot.item.id),
        ]
        if let album = snapshot.item.album, !album.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if snapshot.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = snapshot.duration
        }
        if let file = snapshot.item.fileURL {
            info[MPNowPlayingInfoPropertyAssetURL] = file
        }
        if let artwork = snapshot.artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        if !snapshot.animatedArtworks.isEmpty, #available(iOS 26.0, *) {
            // iOS only: the engine's macOS slice builds this file too, and animated artwork is
            // an iOS lock-screen surface there is no equivalent of. Available keys are read from
            // the system at runtime; tests inject the set instead (see `animatedArtworkKey`).
            #if os(iOS)
            let supported = runtimeSupportedKeys()
            for animated in snapshot.animatedArtworks {
                guard let key = animatedArtworkKey(for: animated.pixels, isAllowed: true, supportedKeys: supported),
                      let dictionaryKey = systemKey(for: key), info[dictionaryKey] == nil else { continue }
                info[dictionaryKey] = mediaItemAnimatedArtwork(animated, previewing: snapshot.artwork)
            }
            #endif
        }
        return info
    }

    /// The identifier the system hands back to this app (documented as opaque). YouTube ids (video
    /// ids, playlist slot ids, queue entry UUIDs, and the `row|video#rendition` form the engine uses:
    /// only letters, digits, `-`, `_`, `|` and `#`) are published as they are. Anything else (WebDAV,
    /// SMB, Files and media-library ids embed a URL, a server or a share name) becomes a short stable
    /// hash, since a system-visible identifier should not carry those.
    static func opaqueIdentifier(_ id: String) -> String {
        if id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_|#".contains($0)) }) { return id }
        let digest = SHA256.hash(data: Data(id.utf8)).prefix(8)
        return "h-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Animated artwork (iOS 26+)

    /// The two keys the system can be handed an animated artwork under, as shapes rather than
    /// dictionary strings — pure, so the key choice is testable without the system's runtime
    /// list (`MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys`, iOS 26+).
    enum AnimatedArtworkKey: Hashable, Sendable, CaseIterable {
        /// 1:1 — `MPNowPlayingInfoProperty1x1AnimatedArtwork`. Tidal's 1280x1280 clips land here.
        case square
        /// 3:4 tall portrait — `MPNowPlayingInfoProperty3x4AnimatedArtwork`.
        case tall

        /// How far an aspect may drift from the key's own and still be given to the system.
        /// The headers say they may reject assets that "diverge significantly"; a 10% drift is
        /// encoder rounding, a Spotify Canvas' 9:16 against the tall key is more than 30% and
        /// stays out (no cropping in this pass).
        static let aspectTolerance: CGFloat = 0.1

        #if os(iOS)
        /// Which key shape a string out of the system's supported list names. The comparison is
        /// against the dictionary constants themselves, so iOS 26+.
        @available(iOS 26.0, *)
        init?(systemKey string: String) {
            if string == MPNowPlayingInfoProperty1x1AnimatedArtwork { self = .square }
            else if string == MPNowPlayingInfoProperty3x4AnimatedArtwork { self = .tall }
            else { return nil }
        }
        #endif
    }

    /// Which key the clip is allowed under, given its shape, whether canvas use is allowed
    /// (``CanvasPolicy``'s switch and Wi-Fi-only rule decide that before any download), and the
    /// keys the system actually supports here. The pure half of the lock-screen decision, so the
    /// whole of it is testable without the OS in the loop.
    static func animatedArtworkKey(
        for pixels: CGSize, isAllowed: Bool, supportedKeys: Set<AnimatedArtworkKey>
    ) -> AnimatedArtworkKey? {
        guard isAllowed, let shape = clipShape(of: pixels), supportedKeys.contains(shape) else { return nil }
        return shape
    }

    /// The key shape a clip matches, or nil for any other aspect — a 9:16 Spotify Canvas, a
    /// community upload's odd box. Decided by the pixel size the asset reported, in
    /// ``NowPlayingAnimatedArtwork/pixels``.
    static func clipShape(of pixels: CGSize) -> AnimatedArtworkKey? {
        guard pixels.width > 0, pixels.height > 0 else { return nil }
        let aspect = pixels.width / pixels.height
        if abs(aspect - 1) <= AnimatedArtworkKey.aspectTolerance { return .square }
        if abs(aspect - 0.75) <= AnimatedArtworkKey.aspectTolerance * 0.75 { return .tall }
        return nil
    }

    /// The clip's first frame, upright, scaled to fit `size` (pixels) at the clip's own aspect.
    /// Nil when the file has no readable video.
    static func firstFrame(of clip: URL, fitting size: CGSize) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = size
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try? await generator.image(at: .zero).image
    }

    // The rest of the animated-artwork work is iOS-only: on macOS the module builds for a
    // deployment this API (macOS 26) is not offered in, and macOS has no lock screen to carry it.
    #if os(iOS)

    /// The keys the running system supports here, from `MPNowPlayingInfoCenter`'s list of
    /// supported animated-artwork keys (iOS 26+). Tests inject a set into
    /// ``animatedArtworkKey`` instead of going through this.
    @available(iOS 26.0, *)
    static func runtimeSupportedKeys() -> Set<AnimatedArtworkKey> {
        let list = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys
        return Set(list.compactMap { AnimatedArtworkKey(systemKey: $0) })
    }

    /// The dictionary key a supported key shape is published under. Nil for one the system does
    /// not list — publishing it would be ignored, and a nil makes that explicit in tests.
    @available(iOS 26.0, *)
    static func systemKey(for key: AnimatedArtworkKey) -> String? {
        switch key {
        case .square: MPNowPlayingInfoProperty1x1AnimatedArtwork
        case .tall: MPNowPlayingInfoProperty3x4AnimatedArtwork
        }
    }

    /// The system's animated artwork for the clip: the preview handler answers with the clip's
    /// own first frame, and the video handler with the local file. Built per publish — the
    /// system only re-reads the assets it does not already hold, and a re-offered URL costs
    /// nothing next to the tick it sits inside.
    @available(iOS 26.0, *)
    static func mediaItemAnimatedArtwork(
        _ animated: NowPlayingAnimatedArtwork, previewing still: MPMediaItemArtwork?
    ) -> MPMediaItemAnimatedArtwork {
        MPMediaItemAnimatedArtwork(
            artworkID: animated.artworkID,
            // The headers want the preview to match the video's first frame and its shape: a
            // square still cover under a 3:4 clip is what the iPhone's tall lock screen refused.
            // The still stands in only for a square clip whose frame can't be read.
            previewImageRequestHandler: { size, completion in
                Task {
                    if let frame = await firstFrame(of: animated.fileURL, fitting: size) {
                        completion(UIImage(cgImage: frame))
                    } else {
                        completion(clipShape(of: animated.pixels) == .square ? still?.image(at: size) : nil)
                    }
                }
            },
            // CanvasClipCache files answer instantly and stay valid for the artwork's lifetime;
            // the download itself was finished (and Wi-Fi-gated) by the resolving side.
            videoAssetFileURLRequestHandler: { _, completion in
                completion(animated.fileURL)
            })
    }

    #endif
}

/// Fetches lock-screen artwork. One request at a time: a newer item cancels the older fetch, so a
/// skipped-through queue can't land its covers out of order.
@MainActor
final class NowPlayingArtworkLoader {
    private let session: URLSession
    private var task: Task<Void, Never>?
    private(set) var loadedURL: URL?
    private(set) var artwork: MPMediaItemArtwork?
    /// A cover that could not be fetched or decoded: settled, so it is not retried on every
    /// publish, and nothing waits on it any longer.
    private(set) var failedURL: URL?

    init(session: URLSession) {
        self.session = session
    }

    /// Loads `url` unless it is already this loader's subject (loaded, loading, or failed): the
    /// engine calls this on every publish, and restarting an in-flight fetch on each tick would
    /// never let a slow cover finish. Calls `completion` once it settles: with the artwork on
    /// success, with nil when the cover cannot be fetched or decoded.
    func load(_ url: URL?, completion: @escaping @MainActor (MPMediaItemArtwork?) -> Void) {
        guard url != loadedURL else { return }
        task?.cancel()
        loadedURL = url
        artwork = nil
        failedURL = nil
        guard let url else { return }
        let session = self.session
        task = Task { [weak self] in
            let data = try? await session.data(from: url).0
            guard !Task.isCancelled, let self, self.loadedURL == url else { return }
            guard let data, let artwork = Self.artwork(from: data) else {
                self.failedURL = url
                completion(nil)
                return
            }
            self.artwork = artwork
            completion(artwork)
        }
    }

    /// A new item gets its own try at a cover that failed for an earlier one (say the network
    /// dropped on an album's first song): failure is settled per item, not for good.
    func forgetFailure() {
        guard failedURL != nil else { return }
        failedURL = nil
        loadedURL = nil
    }

    func cancel() {
        task?.cancel()
        task = nil
        loadedURL = nil
        artwork = nil
        failedURL = nil
    }

    nonisolated static func artwork(from data: Data) -> MPMediaItemArtwork? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let size = CGSize(width: image.width, height: image.height)
        #if canImport(UIKit)
        let platformImage = UIImage(cgImage: image)
        #else
        let platformImage = NSImage(cgImage: image, size: size)
        #endif
        return MPMediaItemArtwork(boundsSize: size) { _ in platformImage }
    }
}
