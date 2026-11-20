import Foundation
import VibraMusicCore
#if canImport(XCTest)
import XCTest
#endif

/// A `UserDefaults` suite of its own, emptied when released. Hand ``defaults`` to `AppSettings`,
/// `SearchHistory` or anything else that takes an injectable suite.
public final class EphemeralDefaults: @unchecked Sendable {
    public let suiteName: String
    public let defaults: UserDefaults

    public init(prefix: String = "VibraMusicTests") {
        suiteName = "\(prefix).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("UserDefaults refused suite \(suiteName)")
        }
        self.defaults = defaults
    }

    /// Deletes everything in the suite.
    public func removeAll() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    deinit { removeAll() }
}

/// A fresh directory under the system temporary directory, deleted when released.
public final class TemporaryDirectory: @unchecked Sendable {
    public let url: URL

    public init(prefix: String = "VibraMusicTests") throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Deletes the directory and everything in it.
    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    deinit { remove() }
}

/// Loads files from a test target's `Fixtures/` folder (copied as a resource).
///
/// ```swift
/// let fixtures = FixtureLoader(bundle: .module)
/// let data = try fixtures.data("search_songs.json")
/// ```
public struct FixtureLoader: Sendable {
    public enum FixtureError: Error, CustomStringConvertible {
        case notFound(String)

        public var description: String {
            switch self {
            case .notFound(let name): return "No fixture named \(name) in Fixtures/"
            }
        }
    }

    public let bundle: Bundle
    public let folder: String

    public init(bundle: Bundle, folder: String = "Fixtures") {
        self.bundle = bundle
        self.folder = folder
    }

    /// The fixture's URL. `name` includes the extension and may include subfolders.
    public func url(_ name: String) throws -> URL {
        if let root = bundle.resourceURL {
            let candidate = root.appending(path: folder, directoryHint: .isDirectory).appending(path: name)
            if FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) { return candidate }
        }
        if let found = bundle.url(forResource: name, withExtension: nil, subdirectory: folder) { return found }
        throw FixtureError.notFound(name)
    }

    public func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    public func string(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }

    public func decode<T: Decodable>(_ type: T.Type, from name: String, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(T.self, from: data(name))
    }
}

/// A ``NetworkStatusProviding`` you drive by hand.
public final class FakeNetworkMonitor: NetworkStatusProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var current: NetworkStatus
    private var continuations: [UUID: AsyncStream<NetworkStatus>.Continuation] = [:]

    public init(_ status: NetworkStatus = .wifi) {
        current = status
    }

    public var status: NetworkStatus { lock.withLock { current } }

    /// Changes the status and notifies every ``statusUpdates()`` stream.
    public func send(_ status: NetworkStatus) {
        let listeners = lock.withLock {
            current = status
            return Array(continuations.values)
        }
        listeners.forEach { $0.yield(status) }
    }

    public func statusUpdates() -> AsyncStream<NetworkStatus> {
        AsyncStream { continuation in
            let id = UUID()
            // The first value goes out while the lock is still held: a `send` can only reach
            // this continuation after taking the same lock, so it can't yield a newer status
            // ahead of this snapshot and leave the stream ending on the stale one.
            lock.withLock {
                continuations[id] = continuation
                continuation.yield(current)
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                _ = self.lock.withLock { self.continuations.removeValue(forKey: id) }
            }
        }
    }
}

#if canImport(XCTest)
extension XCTestCase {
    /// An ephemeral `UserDefaults` suite, deleted when the test ends.
    public func makeEphemeralDefaults() -> UserDefaults {
        let suite = EphemeralDefaults()
        addTeardownBlock { suite.removeAll() }
        return suite.defaults
    }

    /// A fresh temporary directory, deleted when the test ends.
    public func makeTemporaryDirectory() throws -> URL {
        let directory = try TemporaryDirectory()
        addTeardownBlock { directory.remove() }
        return directory.url
    }
}
#endif
