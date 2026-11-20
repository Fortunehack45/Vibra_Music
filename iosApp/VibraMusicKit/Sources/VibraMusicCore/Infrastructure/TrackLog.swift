import Foundation
import os

// Ports data/TrackLog.kt.

/// The app's own record of how each track came to be playing, as text a user can paste ("Copy
/// log" in the player).
///
/// Diagnosing why a track played from the wrong source, at the wrong bitrate, or not at all used to
/// mean reading the system log, and the answer is usually in a few seconds that scrolled past before
/// anyone noticed. This keeps those lines, in memory, bounded by size.
///
/// **What to log here:** only the paths that decide how a track plays — the resolver, the source
/// ladder, the cache and the player. Not feeds, artwork, lyrics or the library (use ``DebugLog``):
/// a paste that includes everything is one nobody reads to the end of.
///
/// **Whose line is it.** Every line is filed against the track it is about, because a track's work
/// happens nowhere near the moment it plays: it is resolved while the one before it plays, and the
/// first seconds of every track are spent resolving the next. Wrap a track's work in
/// ``about(_:operation:)`` (a task-local, so it follows every child task) instead of threading ids
/// through every layer:
///
/// ```swift
/// try await TrackLog.about(song.videoId) { try await resolver.resolveStream(for: song, request: r) }
/// ```
///
/// Lines are mirrored to `os.Logger` (subsystem `com.fortune.vibramusic.ios`, the given category) in debug
/// builds, and every line of ``shared`` goes to the log file in every build (``DiagnosticLog``).
public final class TrackLog: @unchecked Sendable {
    public enum Level: Character, Sendable {
        case debug = "D", info = "I", warning = "W", error = "E"
    }

    public struct Line: Hashable, Sendable {
        public let at: Date
        public let level: Level
        public let text: String
        /// The video id this line is about, or nil for lines about nothing in particular.
        public let track: String?
    }

    /// The instance the static helpers write to.
    public static let shared = TrackLog(writesDiagnosticLog: true)

    /// The track whose work the current task is doing, if any. Set with ``about(_:operation:)``.
    @TaskLocal public static var currentTrack: String?

    /// Total characters held. Bounded by size rather than line count: one line carrying a search
    /// response is worth hundreds of ordinary ones.
    public let maxHeldCharacters: Int
    /// Enough for a stack trace or a response's opening; not a catalogue page.
    public let maxLineCharacters: Int
    /// How far back of a track's start to reach when nothing was ever filed against it (a track
    /// served whole from the disk cache, or the one a cold start resumes on).
    public let leadIn: TimeInterval

    private let lock = NSLock()
    private var lines: [Line] = []
    private var held = 0
    private var startedAt: [String: Date] = [:]
    private let maxRemembered = 32
    private let now: @Sendable () -> Date
    /// Only the app's own instance writes the log file; the ones tests build must not.
    private let writesDiagnosticLog: Bool

    public init(
        maxHeldCharacters: Int = 512_000,
        maxLineCharacters: Int = 2_000,
        leadIn: TimeInterval = 20,
        writesDiagnosticLog: Bool = false,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.writesDiagnosticLog = writesDiagnosticLog
        self.maxHeldCharacters = maxHeldCharacters
        self.maxLineCharacters = maxLineCharacters
        self.leadIn = leadIn
        self.now = now
    }

    // MARK: Writing

    /// Runs `operation` with every line it logs (including from child tasks) filed against `id`.
    public static func about<T>(
        _ id: String?,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await $currentTrack.withValue(id, operation: operation)
    }

    public static func d(_ category: String, _ message: String, about: String? = currentTrack) {
        shared.log(.debug, category, message, about: about)
    }

    public static func i(_ category: String, _ message: String, about: String? = currentTrack) {
        shared.log(.info, category, message, about: about)
    }

    public static func w(_ category: String, _ message: String, error: Error? = nil, about: String? = currentTrack) {
        shared.log(.warning, category, DebugLog.describe(message, error), about: about)
    }

    public static func e(_ category: String, _ message: String, error: Error? = nil, about: String? = currentTrack) {
        shared.log(.error, category, DebugLog.describe(message, error), about: about)
    }

    /// Records a line (and mirrors it to os.Logger in debug builds and, for ``shared``, to the log file).
    public func log(_ level: Level, _ category: String, _ message: String, about: String? = TrackLog.currentTrack) {
        #if DEBUG
        let logger = VibraMusicLogging.logger(category)
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
        #endif
        if writesDiagnosticLog {
            DiagnosticLog.shared.record(level, category: category, track: about, message: message)
        }
        let text = DiagnosticLog.cap(message, to: maxLineCharacters)
        let line = Line(at: now(), level: level, text: text, track: about)
        lock.withLock {
            lines.append(line)
            held += text.count
            var drop = 0
            while held > maxHeldCharacters, drop < lines.count {
                held -= lines[drop].text.count
                drop += 1
            }
            if drop > 0 { lines.removeFirst(drop) }
        }
    }

    /// Whole milliseconds since `start`: the unit every timing in this log is written in.
    public static func ms(since start: ContinuousClock.Instant) -> Int64 {
        let elapsed = ContinuousClock.now - start
        return elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000
    }

    /// Notes that `videoId` became the current track: a floor for tracks with no lines of their own.
    public func trackStarted(_ videoId: String) {
        let at = now()
        lock.withLock {
            // Only the oldest goes: emptying the map would forget the start of every track the
            // listener has just heard, and each of those logs would fall back to "everything held".
            if startedAt.count >= maxRemembered, startedAt[videoId] == nil,
               let oldest = startedAt.min(by: { $0.value < $1.value })?.key {
                startedAt[oldest] = nil
            }
            startedAt[videoId] = at
        }
    }

    /// See ``trackStarted(_:)``.
    public static func trackStarted(_ videoId: String) { shared.trackStarted(videoId) }

    // MARK: Reading

    /// Every line held, oldest first.
    public var heldLines: [Line] { lock.withLock { lines } }

    public func clear() {
        lock.withLock {
            lines.removeAll()
            held = 0
            startedAt.removeAll()
        }
    }

    /// The log for `song`: the lines about that track plus the ones about nothing in particular,
    /// from where its own story starts (its first line, or its start minus ``leadIn``, whichever is
    /// earlier). Lines about other tracks in that stretch are left out and counted in the header —
    /// the difference between "nothing happened" and "nothing happened *to this track*".
    ///
    /// - Parameter context: extra header lines only the caller knows, e.g. what the player reports
    ///   it is playing ("playing: flac · 24-bit · 96000 Hz") and the source settings in force.
    public func forTrack(_ song: Song, context: [String] = []) -> String {
        let (snapshot, started) = lock.withLock { (lines, startedAt[song.videoId]) }
        let candidates = [
            snapshot.first(where: { $0.track == song.videoId })?.at,
            started?.addingTimeInterval(-leadIn),
        ].compactMap { $0 }
        let from = candidates.min()
        let since = snapshot.filter { from == nil || $0.at >= from! }
        let window = since.filter { $0.track == nil || $0.track == song.videoId }
        let elsewhere = since.count - window.count

        var out = "Vibra Music log — \(song.title) — \(song.artist)\n"
        out += "id=\(song.videoId) duration=\(song.durationText ?? "?") album=\(song.albumName ?? "?")\n"
        for line in context { out += line + "\n" }
        let windowStart = from.map(Self.clock) ?? "everything held"
        out += "window: \(windowStart) → \(Self.clock(now())) (\(window.count) lines"
            + (elsewhere > 0 ? ", \(elsewhere) for other tracks left out)\n" : ")\n")
        out += "build: \(Self.buildDescription())\n"
        out += "device: \(Self.deviceDescription())\n"
        out += "\n"
        for line in window {
            out += "\(Self.clock(line.at)) \(line.level.rawValue) \(line.text)\n"
        }
        return out
    }

    // MARK: Header helpers

    /// `HH:mm:ss.SSS` in the device's time zone. A formatter per call: this only runs for a paste.
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    static func buildDescription() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        #if DEBUG
        let type = "debug"
        #else
        let type = "release"
        #endif
        return "\(version) (\(build), \(type))"
    }

    static func deviceDescription() -> String {
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return "\(machine), \(os)"
    }
}
