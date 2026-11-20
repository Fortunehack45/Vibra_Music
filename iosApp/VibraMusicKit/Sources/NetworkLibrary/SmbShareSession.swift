import Foundation

// The test seam under SmbClient and the SMB streaming sources: one connected
// share, addressed with display paths (forward slashes, relative to the
// share, "" for the root). The AMSMB2-backed implementation converts to the
// wire form; fakes answer from memory.

/// One entry in a share listing.
public struct SmbDirectoryEntry: Hashable, Sendable {
    /// Display path segment (a bare name, never containing a slash).
    public var name: String
    public var isDirectory: Bool
    public var size: Int64

    public init(name: String, isDirectory: Bool, size: Int64) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
    }
}

/// One connected share. Implementations must be safe to call concurrently —
/// the player and read-ahead can be fetching different parts of one track —
/// and should respond to task cancellation.
public protocol SmbShareSession: Sendable {
    /// The direct children of `path` ("" for the share root). Never includes
    /// `.` or `..`.
    func listDirectory(_ path: String) async throws -> [SmbDirectoryEntry]
    /// The length of the file at `path`.
    func fileSize(_ path: String) async throws -> Int64
    /// The bytes in `range` of the file at `path`.
    func readFile(_ path: String, range: Range<Int64>) async throws -> Data
    /// Releases the session. The pool — not individual readers — owns the
    /// lifetime, so this is a no-op for pooled sessions.
    func close() async
}

/// Builds connected sessions for credentials. The production factory dials
/// the server through AMSMB2; tests substitute a fake.
public protocol SmbSessionFactory: Sendable {
    func connect(_ credentials: SmbCredentials) async throws -> any SmbShareSession
}

/// Why an SMB operation failed.
public enum SmbError: Error, LocalizedError, Sendable {
    case notConfigured
    case notAShare(String)
    case notAFile(String)
    case fileTooLargeForCover
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "SMB is not configured"
        case .notAShare(let share): return "\"\(share)\" is not a file share"
        case .notAFile(let url): return "Not an SMB file: \(url)"
        case .fileTooLargeForCover: return "File too large for a cover"
        case .transport(let message): return message
        }
    }
}
