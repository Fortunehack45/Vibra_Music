import Foundation
import Observation

// Ports data/LikeState.kt.

/// Ratings changed during this app session, shared by the UI and playback (lock screen, CarPlay).
///
/// The library remains the source for ratings known at load time; these overrides win over it so a
/// tap on the lock screen and a tap in Now Playing paint the same result immediately.
@MainActor
@Observable
public final class LikeState {
    /// The app-wide instance (Android's `object LikeState`). Tests create their own.
    public static let shared = LikeState()

    public private(set) var overrides: [String: LikeStatus] = [:]

    public init() {}

    /// The session's rating for `videoId`, if one is known.
    public func status(for videoId: String) -> LikeStatus? { overrides[videoId] }

    public func set(_ status: LikeStatus, for videoId: String) {
        overrides[videoId] = status
    }

    /// Records a rating read off a track's own menu, only when the menu actually states one. A
    /// missing like button (nil) must never overwrite what this session knows — kept nil rather
    /// than `.indifferent` so the two stay distinct — and an override already made this session
    /// always wins.
    public func rememberStated(_ stated: LikeStatus?, for videoId: String) {
        guard let stated, stated != .indifferent, overrides[videoId] == nil else { return }
        overrides[videoId] = stated
    }

    /// Seeds `.like` for ids not already rated explicitly this session.
    public func seedLiked(_ videoIds: Set<String>) {
        guard !videoIds.isEmpty else { return }
        var next = overrides
        for id in videoIds where next[id] == nil { next[id] = .like }
        if next != overrides { overrides = next }
    }

    public func clear() {
        overrides = [:]
    }
}
