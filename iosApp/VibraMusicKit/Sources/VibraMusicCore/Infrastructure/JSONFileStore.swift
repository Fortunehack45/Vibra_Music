import Foundation

/// Codable values as JSON files in one directory: the persistence for data (queues, download
/// records, listening stats, caches), as `UserDefaults` is for settings.
///
/// Writes are atomic (write to a temporary file, then rename), so a crash mid-write leaves the old
/// file intact rather than half a new one. The store does no locking of its own: give each file one
/// owner (typically an actor) and serialise that owner's writes.
public struct JSONFileStore: Sendable {
    /// The directory files live in. Created on first write.
    public let directory: URL

    /// `directory` is used as given, which is how tests point a store at a temporary folder.
    public init(directory: URL) {
        self.directory = directory
    }

    /// A store in `Application Support/Vibra Music/<subdirectory>`, the app's default for data.
    /// Pass `excludedFromBackup: true` for re-fetchable caches.
    public static func applicationSupport(_ subdirectory: String, excludedFromBackup: Bool = false) -> JSONFileStore {
        var url = URL.applicationSupportDirectory
            .appending(path: "Vibra Music", directoryHint: .isDirectory)
            .appending(path: subdirectory, directoryHint: .isDirectory)
        if excludedFromBackup {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        return JSONFileStore(directory: url)
    }

    /// The file a value named `name` is stored in. `name` may include an extension; `.json` is not
    /// added for you.
    public func url(for name: String) -> URL {
        directory.appending(path: name, directoryHint: .notDirectory)
    }

    public func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: name).path(percentEncoded: false))
    }

    /// The decoded value, or nil when no file exists. Throws when the file exists but can't be read
    /// or decoded, so a caller can tell "never saved" from "corrupt".
    public func load<Value: Decodable>(_ type: Value.Type, from name: String, decoder: JSONDecoder = JSONFileStore.makeDecoder()) throws -> Value? {
        let file = url(for: name)
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        return try decoder.decode(Value.self, from: data)
    }

    /// Encodes and writes `value` atomically, creating the directory if needed.
    public func save<Value: Encodable>(_ value: Value, to name: String, encoder: JSONEncoder = JSONFileStore.makeEncoder()) throws {
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(for: name), options: [.atomic])
    }

    /// Deletes the file; no error when it doesn't exist.
    public func remove(_ name: String) throws {
        do {
            try FileManager.default.removeItem(at: url(for: name))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }

    /// Names of the files currently stored, sorted.
    public func fileNames() throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    /// Sorted keys (stable diffs) and ISO-8601 dates.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// ISO-8601 dates, matching ``makeEncoder()``.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
