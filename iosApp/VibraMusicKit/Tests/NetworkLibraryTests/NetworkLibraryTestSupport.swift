import VibraMusicTestSupport
import XCTest
@testable import NetworkLibrary

/// Shared fakes for the NetworkLibrary tests: an in-memory SMB share and
/// small binary builders for tagged audio.
final class FakeSmbShare: SmbShareSession, @unchecked Sendable {
    var directories: [String: [SmbDirectoryEntry]] = [:]
    var files: [String: Data] = [:]
    var listCalls: [String] = []
    var readCalls: [(path: String, range: Range<Int64>)] = []
    var listError: Error?
    var readError: Error?
    var readDelay: Duration?
    var closedCount = 0
    /// The most reads under way at once. Reads from several covers arrive on several threads, so
    /// the counters below are guarded.
    private(set) var peakConcurrentReads = 0
    private var readsInFlight = 0
    private let lock = NSLock()

    func listDirectory(_ path: String) async throws -> [SmbDirectoryEntry] {
        listCalls.append(path)
        if let error = listError { throw error }
        return directories[path] ?? directories[path.lowercased()] ?? []
    }

    func fileSize(_ path: String) async throws -> Int64 {
        if let error = readError { throw error }
        guard let data = files[path] ?? files[path.lowercased()] else { throw SmbError.notAFile(path) }
        return Int64(data.count)
    }

    func readFile(_ path: String, range: Range<Int64>) async throws -> Data {
        lock.withLock {
            readCalls.append((path, range))
            readsInFlight += 1
            peakConcurrentReads = max(peakConcurrentReads, readsInFlight)
        }
        defer { lock.withLock { readsInFlight -= 1 } }
        if let readDelay { try await Task.sleep(for: readDelay) }
        if let error = readError { throw error }
        guard let data = files[path] ?? files[path.lowercased()] else { throw SmbError.notAFile(path) }
        let lower = max(Int(range.lowerBound), 0)
        let upper = min(Int(range.upperBound), data.count)
        guard lower < upper else { return Data() }
        return data[lower..<upper]
    }

    func close() async {
        lock.withLock { closedCount += 1 }
    }
}

final class FakeSmbFactory: SmbSessionFactory, @unchecked Sendable {
    var share = FakeSmbShare()
    var connectError: Error?
    var connects = 0

    func connect(_ credentials: SmbCredentials) async throws -> any SmbShareSession {
        connects += 1
        if let error = connectError { throw error }
        return share
    }
}

/// A live-test gate in the style of the other modules: local servers only
/// run with `VIBRAMUSIC_LIVE_TESTS=1`.
func requireLiveTests() throws {
    guard ProcessInfo.processInfo.environment["VIBRAMUSIC_LIVE_TESTS"] == "1" else {
        throw XCTSkip("Set VIBRAMUSIC_LIVE_TESTS=1 to run tests against the local SMB/WebDAV servers")
    }
}

func makeSmbStack(
    credentials: SmbCredentials = SmbCredentials(host: "nas.local", share: "Music"),
    factory: FakeSmbFactory = FakeSmbFactory(),
    configure: (FakeSmbShare) -> Void = { _ in }
) -> (SmbClient, FakeSmbShare, FakeSmbFactory) {
    configure(factory.share)
    let pool = SmbConnectionPool(credentials: credentials, factory: factory)
    return (SmbClient(credentials: credentials, pool: pool), factory.share, factory)
}
