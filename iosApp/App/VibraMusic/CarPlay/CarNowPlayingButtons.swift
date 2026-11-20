import VibraMusicCore
import Foundation
import PlaybackPolicy

/// The buttons the car's Now Playing screen carries (PlaybackService.carButtons): Favorite and
/// Shuffle, as on the phone's notification, plus Radio and Revert for a car with room for them.
enum CarNowPlayingButton: Equatable {
    case favorite(liked: Bool)
    case shuffle(on: Bool)
    /// Start a station from the song (`canStartStation`: a catalogue id, not a file on the phone).
    case radio
    /// Go back to YouTube's own upload after a substitute source took over (`hasYouTubeOriginal`,
    /// not a download, not already pinned).
    case revert

    static func buttons(for song: Song?, liked: Bool, shuffle: Bool, isPinnedToOriginal: (String) -> Bool) -> [CarNowPlayingButton] {
        var buttons: [CarNowPlayingButton] = [.favorite(liked: liked), .shuffle(on: shuffle)]
        guard let song else { return buttons }
        if canStartStation(song) { buttons.append(.radio) }
        if PlaybackFallback.hasYouTubeOriginal(song), song.localUri == nil, !isPinnedToOriginal(song.videoId) {
            buttons.append(.revert)
        }
        return buttons
    }

    /// PlaybackService.kt `Song.canStartStation()`.
    static func canStartStation(_ song: Song) -> Bool {
        !song.videoId.trimmingCharacters(in: .whitespaces).isEmpty
            && !song.videoId.hasPrefix("content://")
            && !song.videoId.hasPrefix("file://")
    }

    var symbol: String {
        switch self {
        case .favorite(let liked): return liked ? "heart.fill" : "heart"
        case .shuffle: return "shuffle"
        case .radio: return "dot.radiowaves.left.and.right"
        case .revert: return "arrow.triangle.2.circlepath"
        }
    }
}
