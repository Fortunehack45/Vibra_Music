import Foundation

/// What the home-screen widget shows: the current track and the player's state, written by the app
/// into the App Group whenever either changes (Android's widget RemoteViews update).
///
/// Compiled into both the app and the widget. The app writes with ``save(to:)``; the widget reads
/// with ``load(from:)`` in its timeline provider. The artwork is copied into the group container
/// (``artworkFileName``) because a widget renders from local data and should not wait on the
/// network for a cover.
struct NowPlayingSnapshot: Codable, Hashable {
    /// Bumped when the shape changes incompatibly; a reader ignores a snapshot it doesn't know.
    static let currentVersion = 1

    var version: Int = NowPlayingSnapshot.currentVersion
    var videoId: String
    var title: String
    var artist: String
    var albumName: String?
    /// The remote cover, sized for the widget.
    var artworkURL: String?
    /// A JPEG of the cover in the App Group container (relative to its root), when one was saved.
    var artworkFileName: String?
    var isPlaying: Bool
    var isLiked: Bool
    var shuffleEnabled: Bool
    /// "OFF" / "ALL" / "ONE".
    var repeatMode: String
    var hasNext: Bool
    var hasPrevious: Bool
    var positionMs: Int64
    var durationMs: Int64
    /// When ``positionMs`` was sampled, so a widget can extrapolate a progress bar while playing.
    var updatedAt: Date

    /// Where snapshots live: the App Group's defaults.
    static let defaultsKey = "now_playing_snapshot"
    static let artworkFileName = "now_playing_artwork.jpg"

    static var sharedDefaults: UserDefaults? { UserDefaults(suiteName: SharedConstants.appGroup) }

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedConstants.appGroup)
    }

    /// The snapshot last written, or nil (nothing played yet, or an unknown version).
    static func load(from defaults: UserDefaults? = sharedDefaults) -> NowPlayingSnapshot? {
        guard let data = defaults?.data(forKey: defaultsKey),
              let snapshot = try? JSONDecoder().decode(NowPlayingSnapshot.self, from: data),
              snapshot.version == currentVersion else { return nil }
        return snapshot
    }

    func save(to defaults: UserDefaults? = NowPlayingSnapshot.sharedDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults?.set(data, forKey: Self.defaultsKey)
    }

    /// Nothing is playing any more (the queue was cleared).
    static func clear(from defaults: UserDefaults? = sharedDefaults) {
        defaults?.removeObject(forKey: defaultsKey)
    }

    /// The saved cover, when there is one.
    var artworkFileURL: URL? {
        guard let artworkFileName, let root = Self.containerURL else { return nil }
        return root.appending(path: artworkFileName)
    }
}
