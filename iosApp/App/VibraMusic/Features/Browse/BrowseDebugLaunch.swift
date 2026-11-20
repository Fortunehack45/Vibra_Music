import VibraMusicCore
import Foundation

#if DEBUG
/// Debug-build launch arguments that drive the Browse screens for screenshots and manual checks:
/// `-browseOpen explore`, `-browseOpen moodGenre` (Explore, then its first category),
/// `-browseOpen search:<query>` (runs a search; `+` for spaces), `-browseOpen typing:<text>` (types
/// without searching, so the completions show) and `-browseOpen recents` (seeds recent searches).
/// Release builds ignore them.
enum BrowseDebugLaunch {
    static var target: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-browseOpen"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// `-browseOpen recents` records these as recent searches, then opens Search.
    static let sampleRecents = [
        Song(videoId: "khnokW3Mw24", title: "Instant Crush", artist: "Daft Punk", thumbnailUrl: "https://i.ytimg.com/vi/khnokW3Mw24/hqdefault.jpg"),
        Song(videoId: "5NV6Rdv1a3I", title: "Get Lucky", artist: "Daft Punk", thumbnailUrl: "https://i.ytimg.com/vi/5NV6Rdv1a3I/hqdefault.jpg"),
    ]

    /// Consumed once, by the first screen that acts on it.
    @MainActor private static var consumed: Set<String> = []

    @MainActor static func take(_ prefix: String) -> String? {
        guard let target, target.hasPrefix(prefix), !consumed.contains(prefix) else { return nil }
        consumed.insert(prefix)
        return String(target.dropFirst(prefix.count)).replacingOccurrences(of: "+", with: " ")
    }
}
#endif
