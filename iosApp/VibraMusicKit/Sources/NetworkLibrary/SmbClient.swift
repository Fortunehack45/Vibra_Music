import Foundation

// Ports data/smb/SmbClient.kt: listing (and only listing) over the pooled
// session — the recursive walk that turns a share into audio rows plus the
// pictures filed beside them — plus whole-file reads for covers.
//
// Server paths are backslash-joined on the wire in smbj; this client works
// in display paths (forward slashes, share-relative) throughout, and the
// session adapter normalises at the boundary. Anything with a forward slash
// in it is a client-side display path and never goes out raw.

/// The audio files and the pictures filed beside them in one share walk.
public struct SmbListing: Hashable, Sendable {
    /// One row in the walk.
    public struct Entry: Hashable, Sendable {
        /// Display path with forward slashes, relative to the share.
        public var path: String
        public var isDirectory: Bool
        public var size: Int64

        public init(path: String, isDirectory: Bool, size: Int64) {
            self.path = path
            self.isDirectory = isDirectory
            self.size = size
        }
    }

    public var audio: [Entry]
    public var images: [Entry]

    public init(audio: [Entry], images: [Entry]) {
        self.audio = audio
        self.images = images
    }
}

/// Lists an SMB share and reads small files off it.
public struct SmbClient: Sendable {
    /// Reads too large to be a cover are refused before they balloon the
    /// heap on a list scroll.
    public static let maxCoverBytes: Int64 = 16 * 1024 * 1024

    private let pool: SmbConnectionPool
    private let credentials: SmbCredentials

    public init(credentials: SmbCredentials, pool: SmbConnectionPool) {
        self.credentials = credentials
        self.pool = pool
    }

    /// The share these credentials point at, for path validation.
    public var share: String { credentials.share }

    /// The length of the file at `path` (display form), from its entry.
    public func fileSize(path: String) async throws -> Int64 {
        try await pool.withSession { session in
            try await session.fileSize(path)
        }
    }

    /// Connects and lists the base path once, to prove the settings work.
    /// Throws when the server or share is missing, or when authentication fails.
    public func testConnection() async throws {
        guard credentials.isConfigured else { throw SmbError.notConfigured }
        _ = try await pool.withSession { session in
            try await session.listDirectory(credentials.basePath)
        }
    }

    /// The recursive walk from the base path down: audio rows plus the
    /// pictures filed beside them.
    public func listLibrary(maxFiles: Int = 10_000) async throws -> SmbListing {
        guard credentials.isConfigured else { throw SmbError.notConfigured }
        return try await pool.withSession { session in
            var audio: [SmbListing.Entry] = []
            var images: [SmbListing.Entry] = []
            var stack = [credentials.basePath]
            var visited = Set<String>()
            while let dir = stack.popLast(), audio.count < maxFiles {
                guard visited.insert(dir.lowercased()).inserted else { continue }
                let children = try await session.listDirectory(dir)
                for child in children {
                    let childPath = dir.isEmpty ? child.name : "\(dir)/\(child.name)"
                    if child.isDirectory {
                        if !visited.contains(childPath.lowercased()) { stack.append(childPath) }
                    } else {
                        let name = child.name.split(separator: "/").last.map(String.init) ?? child.name
                        if SmbConfig.isAudioFile(name) {
                            audio.append(SmbListing.Entry(path: childPath, isDirectory: false, size: child.size))
                        } else if SmbConfig.isImageFile(name) {
                            images.append(SmbListing.Entry(path: childPath, isDirectory: false, size: child.size))
                        }
                    }
                }
            }
            return SmbListing(audio: audio, images: images)
        }
    }

    /// Reads a whole small file — a cover, never audio. Capped so a
    /// mislabeled video file can't balloon the heap on a list scroll.
    public func readFully(streamUrl: String, maxBytes: Int64 = maxCoverBytes) async throws -> Data {
        guard let path = SmbConfig.relativePath(streamUrl, share: credentials.share) else {
            throw SmbError.notAFile(streamUrl)
        }
        return try await pool.withSession { session in
            let length = try await session.fileSize(path)
            var out = Data()
            out.reserveCapacity(Int(min(max(length, 0), maxBytes)))
            var offset: Int64 = 0
            // Bounded by the known length: some servers answer a read past
            // EOF with bytes no parser accepts instead of an empty one, so
            // the end of the file is taken from the entry, never probed for.
            while length < 0 || offset < length {
                try Task.checkCancellation()
                let chunk = try await session.readFile(path, range: offset..<(length < 0 ? offset + 64 * 1024 : min(offset + 64 * 1024, length)))
                if chunk.isEmpty { break }
                offset += Int64(chunk.count)
                guard offset <= maxBytes else { throw SmbError.fileTooLargeForCover }
                out.append(chunk)
            }
            return out
        }
    }

    /// Opens `path` (display form) for ranged reading. Each open takes its
    /// own read path through the pooled session, so seeks never share a
    /// cursor and concurrent opens of the same track cannot tread on each
    /// other.
    public func openFile(_ path: String) async -> SmbFileHandle {
        SmbFileHandle(
            read: { offset, length in
                try await self.pool.withSession { session in
                    try await session.readFile(path, range: offset..<(offset + Int64(length)))
                }
            },
            close: {}
        )
    }

    /// Display path back to the wire form.
    public static func smbPath(_ displayPath: String) -> String {
        let converted = displayPath.replacingOccurrences(of: "/", with: "\\")
        let trimmed = converted.trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
        return trimmed
    }
}

/// One open file for ranged reading: absolute-offset reads, no shared
/// cursor. Ports the per-open handle in `SmbDataSource` / `RemoteArtReader`.
public struct SmbFileHandle: Sendable {
    public var read: @Sendable (Int64, Int) async throws -> Data
    public var close: @Sendable () async -> Void

    public init(
        read: @escaping @Sendable (Int64, Int) async throws -> Data,
        close: @escaping @Sendable () async -> Void
    ) {
        self.read = read
        self.close = close
    }
}
