import AMSMB2
import Foundation
import os

// The AMSMB2-backed SmbShareSession: the one open session to the configured
// server, behind the SmbShareSession seam so tests never touch the wire.
//
// iOS ships no public SMB client, so this module dials through AMSMB2
// (LGPL-2.1, wraps libsmb2) instead of a hand-rolled SMB2 stack: NTLMv2,
// signing and leases stay in audited C. Single-server, like the rest of the
// app's remote libraries — SmbConnectionPool drops the session whenever the
// credentials change, so a changed password can never keep reading on the
// old one.

private let smbLog = Logger(subsystem: "com.fortune.vibramusic.ios", category: "NetworkLibrary")

/// A connected AMSMB2 share as a ``SmbShareSession``.
///
/// Paths are display form (forward slashes, share-relative); AMSMB2 takes
/// the same form, so only blank segments and backslashes are normalised.
final class AmSmbShareSession: SmbShareSession, @unchecked Sendable {
    private let manager: SMB2Manager
    private let lock = NSLock()

    init(manager: SMB2Manager) {
        self.manager = manager
    }

    func listDirectory(_ path: String) async throws -> [SmbDirectoryEntry] {
        let native = Self.nativePath(path)
        let rows = try await manager.contentsOfDirectory(atPath: native)
        return rows.compactMap { row in
            guard let name = row[.nameKey] as? String, name != ".", name != ".." else { return nil }
            let isDirectory = (row[.isDirectoryKey] as? Bool)
                ?? (row[.isDirectoryKey] as? NSNumber)?.boolValue
                ?? false
            let size = (row[.fileSizeKey] as? Int64)
                ?? (row[.fileSizeKey] as? NSNumber)?.int64Value
                ?? 0
            return SmbDirectoryEntry(name: name, isDirectory: isDirectory, size: size)
        }
    }

    func fileSize(_ path: String) async throws -> Int64 {
        let attributes = try await manager.attributesOfItem(atPath: Self.nativePath(path))
        if let size = attributes[.fileSizeKey] as? Int64 { return size }
        if let size = (attributes[.fileSizeKey] as? NSNumber)?.int64Value { return size }
        throw SmbError.transport("No size for \(path)")
    }

    func readFile(_ path: String, range: Range<Int64>) async throws -> Data {
        guard !range.isEmpty else { return Data() }
        return try await manager.contents(
            atPath: Self.nativePath(path),
            range: UInt64(max(range.lowerBound, 0))..<UInt64(max(range.upperBound, 0))
        )
    }

    func close() async {
        try? await manager.disconnectShare()
    }

    /// Display path to the form AMSMB2 lists and reads.
    static func nativePath(_ displayPath: String) -> String {
        let cleaned = displayPath.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/").filter { !$0.isEmpty }.joined(separator: "/")
        return cleaned
    }
}

/// Dials shares through AMSMB2.
public struct AmSmbSessionFactory: SmbSessionFactory {
    /// Seconds before an operation fails. Android's pool used 20 s to
    /// connect and 30 s to read.
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 30) {
        self.timeout = timeout
    }

    /// The credential handed to AMSMB2: nil logs in as guest (a real NTLM
    /// exchange landing on the server's guest path), never as anonymous —
    /// smbj-derived stacks crash on anonymous sessions against servers
    /// that don't flag them as null (Samba), and libsmb2 likewise needs a
    /// user. Blank credentials therefore mean guest, mirroring
    /// `SmbCredentials.isGuest`.
    public static func urlCredential(for credentials: SmbCredentials) -> URLCredential? {
        guard !credentials.isGuest else { return nil }
        return URLCredential(user: credentials.username, password: credentials.password, persistence: .forSession)
    }

    public func connect(_ credentials: SmbCredentials) async throws -> any SmbShareSession {
        guard credentials.isConfigured else { throw SmbError.notConfigured }
        var components = URLComponents()
        components.scheme = SmbConfig.scheme
        components.host = credentials.host
        if credentials.port != SmbConfig.defaultPort { components.port = credentials.port }
        guard let url = components.url,
              let manager = SMB2Manager(url: url, credential: Self.urlCredential(for: credentials))
        else { throw SmbError.notConfigured }
        manager.timeout = timeout
        do {
            try await manager.connectShare(name: credentials.share)
        } catch {
            smbLog.error("SMB connect to \(credentials.host, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        return AmSmbShareSession(manager: manager)
    }
}
