import VibraMusicCore

/// Log lines for the Playback module, filed under the track they are about when there is one.
enum PlaybackLog {
    static let category = "Playback"

    static func debug(_ message: String, about item: String? = nil) {
        TrackLog.d(category, message, about: item)
    }

    static func info(_ message: String, about item: String? = nil) {
        TrackLog.i(category, message, about: item)
    }

    static func warning(_ message: String, about item: String? = nil, error: Error? = nil) {
        TrackLog.w(category, message, error: error, about: item)
    }
}
