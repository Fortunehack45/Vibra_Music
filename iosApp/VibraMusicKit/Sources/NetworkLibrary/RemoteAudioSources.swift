import Foundation

// What AudioCache's pluggable data-source protocol needs from a remote file:
// a length, a type and ranged reads. NetworkLibrary can't import AudioCache
// (both depend only on VibraMusicCore), so it exposes the same shape under its
// own names and the app adapts each source to `AudioRangeDataSource` in one
// line: `contentInfo()` → `AudioContentInfo`, `read(_:)` → `read(_:)` and
// `stream(_:)` → `stream(_:)`.

/// What a remote file says about the resource it serves.
public struct RemoteContentInfo: Hashable, Sendable {
    /// Total size in bytes.
    public var contentLength: Int64
    /// The MIME type as served, when known.
    public var mimeType: String?
    /// The file extension (without dot), for the content-type mapping.
    public var fileExtension: String

    public init(contentLength: Int64, mimeType: String? = nil, fileExtension: String = "") {
        self.contentLength = contentLength
        self.mimeType = mimeType
        self.fileExtension = fileExtension
    }
}

/// MIME types for audio file extensions, shared by streaming and uploads.
public enum RemoteMimeTypes {
    /// The MIME type for `fileExtension` (with or without a leading dot).
    public static func mimeType(forExtension fileExtension: String) -> String {
        var ext = fileExtension.lowercased()
        while ext.hasPrefix(".") { ext = String(ext.dropFirst()) }
        switch ext {
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "flac": return "audio/flac"
        case "ogg", "opus": return "audio/ogg"
        case "aac": return "audio/aac"
        case "wav": return "audio/wav"
        case "webm": return "audio/webm"
        case "aif", "aiff": return "audio/aiff"
        case "wma": return "audio/x-ms-wma"
        default: return "application/octet-stream"
        }
    }

    /// The MIME type for a file name or URL string, from its extension.
    public static func mimeType(forFileName name: String) -> String {
        let ext = name.split(separator: ".").last.map(String.init) ?? ""
        return mimeType(forExtension: ext)
    }
}

/// An SMB file as a byte source: length, type and ranged reads for the
/// audio cache. Ports the read path of `playback/SmbDataSource.kt` — seeks
/// are close-and-reopen there; here each `read` carries an absolute offset
/// through the pooled session, so no cursor is ever shared and concurrent
/// reads of the same track cannot tread on each other.
public struct SmbAudioSource: Sendable {
    /// The `smb://host/share/path` stream URL (as on the song row).
    public var streamURL: String
    private let client: SmbClient

    /// The largest range the cache asks for at once.
    public var maxRangeBytes: Int64 = 1 * 1024 * 1024

    public init(streamURL: String, client: SmbClient, maxRangeBytes: Int64 = 1 * 1024 * 1024) {
        self.streamURL = streamURL
        self.client = client
        self.maxRangeBytes = maxRangeBytes
    }

    public func contentInfo() async throws -> RemoteContentInfo {
        guard let path = SmbConfig.relativePath(streamURL, share: client.share) else {
            throw SmbError.notAFile(streamURL)
        }
        let handle = await client.openFile(path)
        defer { Task { await handle.close() } }
        // The length comes from the file entry, which is what makes the
        // seek bar determinate.
        let size = try await readSize(path: path)
        return RemoteContentInfo(
            contentLength: size,
            mimeType: RemoteMimeTypes.mimeType(forFileName: streamURL),
            fileExtension: streamURL.split(separator: ".").last.map { $0.lowercased() } ?? ""
        )
    }

    public func read(_ range: Range<Int64>) async throws -> Data {
        guard let path = SmbConfig.relativePath(streamURL, share: client.share) else {
            throw SmbError.notAFile(streamURL)
        }
        guard !range.isEmpty else { return Data() }
        let handle = await client.openFile(path)
        defer { Task { await handle.close() } }
        var out = Data()
        var pos = range.lowerBound
        while pos < range.upperBound {
            try Task.checkCancellation()
            let chunk = try await handle.read(pos, min(Int(range.upperBound - pos), 256 * 1024))
            if chunk.isEmpty { break }
            out.append(chunk)
            pos += Int64(chunk.count)
        }
        return out
    }

    /// `range` as a sequence of pieces, so the player can be fed while a
    /// range is still arriving.
    public func stream(_ range: Range<Int64>) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var pos = range.lowerBound
                    while pos < range.upperBound {
                        try Task.checkCancellation()
                        let piece = try await read(pos..<(min(pos + maxRangeBytes, range.upperBound)))
                        if piece.isEmpty { break }
                        pos += Int64(piece.count)
                        continuation.yield(piece)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func readSize(path: String) async throws -> Int64 {
        // Length via a zero-length read path would probe EOF; the pooled
        // session answers it from the entry instead.
        try await client.fileSize(path: path)
    }
}

/// A WebDAV file as a byte source: length, type and ranged reads for the
/// audio cache.
public struct WebDavAudioSource: Sendable {
    /// The `https://` file URL (as on the song row).
    public var fileURL: String
    private let client: WebDavClient
    private let credentials: WebDavCredentials

    /// The largest range the cache asks for at once.
    public var maxRangeBytes: Int64 = 1 * 1024 * 1024

    public init(fileURL: String, client: WebDavClient, credentials: WebDavCredentials, maxRangeBytes: Int64 = 1 * 1024 * 1024) {
        self.fileURL = fileURL
        self.client = client
        self.credentials = credentials
        self.maxRangeBytes = maxRangeBytes
    }

    public func contentInfo() async throws -> RemoteContentInfo {
        try await client.audioContentInfo(fileURL: fileURL, credentials: credentials)
    }

    public func read(_ range: Range<Int64>) async throws -> Data {
        try await client.readRange(fileURL: fileURL, range: range, credentials: credentials)
    }

    /// `range` as a sequence of pieces, so the player can be fed while a
    /// range is still arriving.
    public func stream(_ range: Range<Int64>) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var pos = range.lowerBound
                    while pos < range.upperBound {
                        try Task.checkCancellation()
                        let piece = try await read(pos..<(min(pos + maxRangeBytes, range.upperBound)))
                        if piece.isEmpty { break }
                        pos += Int64(piece.count)
                        continuation.yield(piece)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
