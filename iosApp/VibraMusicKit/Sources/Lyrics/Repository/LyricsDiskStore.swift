import CryptoKit
import Foundation

/// The lyrics last found for each track, kept on disk so a track still has them with no
/// connection (the offline backup plays without one). Written whenever a lookup succeeds, read
/// only when one comes back empty: the network's answer always wins.
public final class LyricsDiskStore: Sendable {
    /// How many tracks are kept; the oldest go first.
    static let limit = 3_000

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `Application Support/Vibra Music/Lyrics`, kept out of device backups: everything in it can be
    /// fetched again.
    public static var standard: LyricsDiskStore {
        LyricsDiskStore(directory: URL.applicationSupportDirectory.appending(path: "Vibra Music", directoryHint: .isDirectory)
            .appending(path: "Lyrics", directoryHint: .isDirectory))
    }

    /// Bumped when the saved shape changes; a file of another version is treated as not saved.
    private static let version = 1

    private struct Saved: Codable {
        var version: Int
        var source: String
        var lines: [LyricLine]
    }

    /// A digest of the id: no two ids share a file, and no id can name a path outside the directory.
    private func file(for videoId: String) -> URL? {
        guard !videoId.isEmpty else { return nil }
        let name = SHA256.hash(data: Data(videoId.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: name + ".json")
    }

    public func save(_ result: LyricsResult, for videoId: String) {
        guard let file = file(for: videoId),
              let data = try? JSONEncoder().encode(Saved(version: Self.version, source: result.source.rawValue, lines: result.lines)) else { return }
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var folder = directory
            try? folder.setResourceValues(values)
        }
        try? data.write(to: file, options: .atomic)
        // ponytail: pruned on a random one in fifty saves, off the caller's thread; an index if
        // the listing ever shows up in a profile.
        if Int.random(in: 0..<50) == 0 { Task.detached(priority: .utility) { self.prune() } }
    }

    public func load(_ videoId: String) -> LyricsResult? {
        guard let file = file(for: videoId), let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.version == Self.version,
              let source = LyricsSource(rawValue: saved.source), !saved.lines.isEmpty else { return nil }
        return LyricsResult(source: source, lines: saved.lines)
    }

    func prune() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        guard files.count > Self.limit else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - Self.limit) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
