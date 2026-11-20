import Foundation

/// The log file on the device: every ``TrackLog`` line and every ``DebugLog`` line, at all four
/// levels and in release builds too, appended to `Library/Application Support/Logs/vibramusic.log`.
///
/// The in-memory ``TrackLog`` dies with the app and the system log is nearly empty in a Release
/// build, so a crash or a bad session left nothing to read. This file survives both, and can be
/// pulled over USB (`xcrun devicectl device copy from --domain-type appDataContainer`).
///
/// One line per entry: `2026-11-01 14:03:22.123 W Resolver [dQw4w9WgXcQ] message`, the video id
/// being `-` for a line about nothing in particular. A multi-line message keeps its first line on
/// that line and indents the rest, so every line that starts with a date starts an entry.
///
/// Callers only pay for a lock and a queue hop: formatting, redaction and the write happen on a
/// serial queue. Each line is written with `write(2)` as it is dequeued, with no buffer of our own,
/// so a crash loses nothing the queue had reached (at most the last moments still waiting in it).
/// When the file passes ``maxFileBytes`` it becomes `vibramusic.1.log` (replacing any older one), so
/// the disk holds at most about twice that.
public final class DiagnosticLog: @unchecked Sendable {
    /// The sink ``TrackLog`` and ``DebugLog`` write to. Replaceable only so tests can point it at a
    /// temporary directory.
    public internal(set) static var shared = DiagnosticLog(directory: DiagnosticLog.standardDirectory)

    public static let fileName = "vibramusic.log"
    public static let rotatedFileName = "vibramusic.1.log"

    /// `Library/Application Support/Logs`.
    public static var standardDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Logs", directoryHint: .isDirectory)
    }

    /// Enough for a stack trace or a response's opening; the same cap ``TrackLog`` applies.
    public let maxMessageCharacters: Int
    public let maxFileBytes: Int
    public let directory: URL

    public var fileURL: URL { directory.appending(path: Self.fileName) }
    public var rotatedFileURL: URL { directory.appending(path: Self.rotatedFileName) }
    /// The files that exist, newest first: what "Share diagnostic log" hands over.
    public var existingFileURLs: [URL] {
        [fileURL, rotatedFileURL].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private let queue = DispatchQueue(label: "com.fortune.vibramusic.ios.diagnostic-log", qos: .utility)
    private let now: @Sendable () -> Date
    private let timeZone: TimeZone
    private let lock = NSLock()
    private var enabled = true

    // Touched only on `queue`.
    private var handle: FileHandle?
    private var size = 0
    private lazy var formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.timeZone = timeZone
        return formatter
    }()

    public init(
        directory: URL,
        maxFileBytes: Int = 8 * 1_024 * 1_024,
        maxMessageCharacters: Int = 2_000,
        timeZone: TimeZone = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.maxFileBytes = maxFileBytes
        self.maxMessageCharacters = maxMessageCharacters
        self.timeZone = timeZone
        self.now = now
    }

    public var isEnabled: Bool { lock.withLock { enabled } }

    /// Turns the file on or off. Off stops writing and deletes both files; on writes `header` first
    /// (the build, the device and the time zone, which a log pulled later has to say for itself).
    public func setEnabled(_ on: Bool, header: String? = nil) {
        lock.withLock { enabled = on }
        if !on {
            queue.async { [self] in
                closeFile()
                for url in [fileURL, rotatedFileURL] { try? FileManager.default.removeItem(at: url) }
            }
        } else if let header {
            record(.info, category: "App", track: nil, message: header)
        }
    }

    /// Queues one line. Does nothing, and costs a lock, while the log is off.
    public func record(_ level: TrackLog.Level, category: String, track: String?, message: String) {
        guard isEnabled else { return }
        let at = now()
        queue.async { [self] in
            append(Self.format(at: at, formatter: formatter, level: level, category: category,
                               track: track, message: Self.scrub(Self.cap(message, to: maxMessageCharacters))))
        }
    }

    /// Returns once everything queued so far is on disk. For tests, and for reading the files.
    public func waitUntilWritten() { queue.sync {} }

    // MARK: Formatting

    static func format(at: Date, formatter: DateFormatter, level: TrackLog.Level, category: String,
                       track: String?, message: String) -> String {
        let body = message.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\n    ")
        return "\(formatter.string(from: at)) \(level.rawValue) \(category) [\(track ?? "-")] \(body)\n"
    }

    /// `message` cut to `limit` characters, with a note of how many went.
    static func cap(_ message: String, to limit: Int) -> String {
        message.count > limit ? String(message.prefix(limit)) + "…(\(message.count - limit) more)" : message
    }

    private static let queryString = try! NSRegularExpression(pattern: #"(https?://[^\s"'<>?#]*)\?[^\s"'<>]*"#)
    private static let secretPair = try! NSRegularExpression(
        pattern: #"(?i)\b((?:[a-z_]*(?:token|cookie|password|passwd|secret|sapisid|spdc|api[_-]?key|authorization|session[_-]?key))["']?\s*[:=]\s*["']?)[^\s"',;&)\]}]+"#
    )
    private static let bearer = try! NSRegularExpression(pattern: #"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]+"#)

    /// Takes what must not sit in a file the owner shares: a URL's query string (signatures and
    /// tokens ride there; a reflected `URLError` carries the whole URL), `token=`-style pairs, and
    /// bearer credentials. Call sites already keep these out; this is the net under them.
    static func scrub(_ text: String) -> String {
        var out = text
        for (expression, template) in [(queryString, "$1?***"), (bearer, "$1 ***"), (secretPair, "$1***")] {
            out = expression.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }

    // MARK: Files (on `queue`)

    private func append(_ line: String) {
        let data = Data(line.utf8)
        if handle == nil { openFile() }
        if size > 0, size + data.count > maxFileBytes { rotate() }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            size += data.count
        } catch {
            // A full disk or a vanished directory: drop the handle so the next line retries.
            closeFile()
        }
    }

    private func openFile() {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            if !manager.fileExists(atPath: fileURL.path) {
                guard manager.createFile(atPath: fileURL.path, contents: nil) else { return }
            }
            Self.excludeFromBackup(directory)
            Self.excludeFromBackup(fileURL)
            let opened = try FileHandle(forWritingTo: fileURL)
            size = Int(try opened.seekToEnd())
            handle = opened
        } catch {
            handle = nil
        }
    }

    private func rotate() {
        closeFile()
        let manager = FileManager.default
        try? manager.removeItem(at: rotatedFileURL)
        try? manager.moveItem(at: fileURL, to: rotatedFileURL)
        Self.excludeFromBackup(rotatedFileURL)
        openFile()
    }

    private func closeFile() {
        try? handle?.close()
        handle = nil
        size = 0
    }

    private static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: Start-up

    /// The line that opens the log: which build, on which device, in which time zone.
    public static func launchHeader() -> String {
        "log started: Vibra Music \(TrackLog.buildDescription()) · \(TrackLog.deviceDescription()) · tz \(TimeZone.current.identifier)"
    }
}
