import Foundation
import VibraMusicCore

// Ports `shouldSkipAfterDislike` from MainActivity.kt.

/// Disliking the song that's playing skips it.
public enum DislikeSkipPolicy {
    /// Whether toggling dislike on `targetVideoId` should skip to the next track.
    ///
    /// Only when the toggle *set* a dislike (the previous status wasn't already one — toggling an
    /// existing dislike undoes it, and undoing must not skip) and only for the track that is
    /// actually playing; disliking a row elsewhere leaves playback alone.
    public static func shouldSkip(previousStatus: LikeStatus, targetVideoId: String, currentVideoId: String?) -> Bool {
        previousStatus != .dislike && targetVideoId == currentVideoId
    }
}
