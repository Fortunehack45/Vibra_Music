import Foundation
import os

// Ports data/DebugLog.kt onto os.Logger.

/// The app's logging conventions: subsystem `com.fortune.vibramusic.ios`, category = module name.
public enum VibraMusicLogging {
    public static let subsystem = "com.fortune.vibramusic.ios"

    /// A logger for `category` (use your module name: "Lyrics", "Downloads", …).
    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}

/// Debug-build logging for call sites outside the playback/resolve path that ``TrackLog`` covers:
/// feeds, artwork, library scans, scrobbling.
///
/// Only the log file (``DiagnosticLog``) takes `d` and `i` in a release build; they skip the
/// unified log there, and cost nothing but a flag check while the file is off. Warnings and errors
/// reach the unified log too (as `.public`, since they carry no user data by convention — don't log
/// tokens or cookies; the file scrubs the obvious ones, but that is a net, not a licence).
///
/// Every line is filed against the track the current task is working on, as ``TrackLog`` does.
public enum DebugLog {
    public static func d(_ category: String, _ message: @autoclosure () -> String) {
        #if DEBUG
        let text = message()
        VibraMusicLogging.logger(category).debug("\(text, privacy: .public)")
        DiagnosticLog.shared.record(.debug, category: category, track: TrackLog.currentTrack, message: text)
        #else
        file(.debug, category, message)
        #endif
    }

    public static func i(_ category: String, _ message: @autoclosure () -> String) {
        #if DEBUG
        let text = message()
        VibraMusicLogging.logger(category).info("\(text, privacy: .public)")
        DiagnosticLog.shared.record(.info, category: category, track: TrackLog.currentTrack, message: text)
        #else
        file(.info, category, message)
        #endif
    }

    public static func w(_ category: String, _ message: @autoclosure () -> String, error: Error? = nil) {
        let text = describe(message(), error)
        VibraMusicLogging.logger(category).warning("\(text, privacy: .public)")
        DiagnosticLog.shared.record(.warning, category: category, track: TrackLog.currentTrack, message: text)
    }

    public static func e(_ category: String, _ message: @autoclosure () -> String, error: Error? = nil) {
        let text = describe(message(), error)
        VibraMusicLogging.logger(category).error("\(text, privacy: .public)")
        DiagnosticLog.shared.record(.error, category: category, track: TrackLog.currentTrack, message: text)
    }

    /// Evaluates `message` only when the log file will take it.
    private static func file(_ level: TrackLog.Level, _ category: String, _ message: () -> String) {
        let sink = DiagnosticLog.shared
        guard sink.isEnabled else { return }
        sink.record(level, category: category, track: TrackLog.currentTrack, message: message())
    }

    static func describe(_ message: String, _ error: Error?) -> String {
        guard let error else { return message }
        return "\(message)\n\(String(reflecting: error))"
    }
}
