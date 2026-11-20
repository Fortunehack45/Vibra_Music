import VibraMusicCore
import Foundation

// Ports data/remote/RemoteArtReader.kt: EmbeddedArt.Reader backends, one per
// remote protocol. Both stay dumb byte fetchers — all format knowledge lives
// in EmbeddedArt.

/// Random-access readers into remote audio files for embedded-art extraction.
public enum RemoteArtReader {
    /// Where extraction runs. It blocks its thread on every read, and an SMB read needs a thread
    /// of the shared async pool to finish, so a list's worth of covers extracting on that pool at
    /// once deadlocked it, and every async task in the app with it. The queue also caps
    /// how many run at a time. A few at once, so one stalled WebDAV read (up to its 30 s timeout)
    /// doesn't hold up every other cover.
    private static let extractionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.fortune.vibramusic.ios.remote-art"
        queue.maxConcurrentOperationCount = 3
        return queue
    }()

    /// Reads `url` over HTTP byte ranges through `session`, so the server's
    /// auth applies exactly as it does for playback. Servers that ignore
    /// Range answer 200 with the whole file; the read is sliced down rather
    /// than failing, because a cover at the front is still reachable that
    /// way.
    public static func http(url: URL, session: URLSession, credentials: WebDavCredentials? = nil) -> any EmbeddedArt.Reader {
        HTTPRangeReader(url: url, session: session, credentials: credentials)
    }

    /// Reads an `smb://` URL through the pooled session. The handle opens on
    /// the first read and closes with the reader — one pooled session, one
    /// read path per extraction, never shared across threads.
    public static func smb(streamUrl: String, client: SmbClient, share: String) -> any EmbeddedArt.Reader {
        SMBRangeReader(streamUrl: streamUrl, client: client, share: share)
    }

    /// Extracts the embedded picture at `url`, or nil when there is none.
    /// Never throws: a missing cover must never fail whatever asked for one.
    public static func picture(
        url: String,
        isSmb: Bool,
        session: URLSession,
        smbClient: SmbClient?,
        smbShare: String,
        webdavCredentials: WebDavCredentials? = nil
    ) async -> EmbeddedArt.Picture? {
        let reader: (any EmbeddedArt.Reader)?
        if isSmb {
            guard let smbClient else { return nil }
            reader = smb(streamUrl: url, client: smbClient, share: smbShare)
        } else {
            guard let parsed = URL(string: url) else { return nil }
            reader = http(url: parsed, session: session, credentials: webdavCredentials)
        }
        guard let reader else { return nil }
        return await withCheckedContinuation { continuation in
            extractionQueue.addOperation {
                let picture: EmbeddedArt.Picture?
                do {
                    defer { reader.close() }
                    picture = EmbeddedArt.extract(reader)
                }
                continuation.resume(returning: picture)
            }
        }
    }
}

/// HTTP byte ranges as an EmbeddedArt.Reader.
final class HTTPRangeReader: EmbeddedArt.Reader, @unchecked Sendable {
    let size: Int64 = .max
    private let url: URL
    private let session: URLSession
    private let credentials: WebDavCredentials?

    init(url: URL, session: URLSession, credentials: WebDavCredentials? = nil) {
        self.url = url
        self.session = session
        self.credentials = credentials
    }

    func read(offset: Int64, length: Int) -> Data {
        guard length > 0, offset >= 0 else { return Data() }
        var request = URLRequest(url: url)
        request.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
        if let credentials, let host = url.host, credentials.shouldAuthorize(requestHost: host),
           let auth = credentials.authHeader
        {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        var result = Data()
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let response = response as? HTTPURLResponse else { return }
            guard response.statusCode == 206 || response.statusCode == 200 else { return }
            if response.statusCode == 200, offset > 0 {
                // No range support: only the front is usable.
                return
            }
            // Bounded either way: a 200 answer carries the whole file, and
            // only the requested window is ever kept.
            result = Data((data ?? Data()).prefix(length))
        }
        task.resume()
        semaphore.wait()
        return result
    }

    func close() {}
}

/// SMB offsets as an EmbeddedArt.Reader.
///
/// Extraction is synchronous while the share is async, so reads bridge
/// through a semaphore like any blocking-IO backend. Run extractions on
/// `RemoteArtReader.extractionQueue`, never on the caller's executor: blocking
/// a thread of the async pool is what deadlocked it.
final class SMBRangeReader: EmbeddedArt.Reader, @unchecked Sendable {
    let size: Int64 = .max
    private let streamUrl: String
    private let client: SmbClient
    private let lock = NSLock()
    private var handle: SmbFileHandle?

    init(streamUrl: String, client: SmbClient, share: String) {
        self.streamUrl = streamUrl
        self.client = client
        // `share` is validated at open time against the client's own
        // credentials; it is kept in the signature so callers name the share
        // they mean, mirroring SmbConfig.relativePath's loud mismatch.
        _ = share
    }

    func read(offset: Int64, length: Int) -> Data {
        guard length > 0, offset >= 0 else { return Data() }
        guard let handle = openHandle() else { return Data() }
        return bridge {
            var out = Data()
            var remaining = length
            var pos = offset
            while remaining > 0 {
                let chunk = try await handle.read(pos, remaining)
                if chunk.isEmpty { break }
                out.append(chunk)
                remaining -= chunk.count
                pos += Int64(chunk.count)
            }
            return out
        } ?? Data()
    }

    func close() {
        let handle = lock.withLock { () -> SmbFileHandle? in
            defer { self.handle = nil }
            return self.handle
        }
        guard handle != nil else { return }
        bridge { await handle?.close() }
    }

    private func openHandle() -> SmbFileHandle? {
        if let existing = lock.withLock({ handle }) { return existing }
        guard let path = SmbConfig.relativePath(streamUrl, share: client.share) else { return nil }
        guard let opened = bridge({ await self.client.openFile(path) }) else { return nil }
        return lock.withLock {
            if let existing = handle { return existing }
            handle = opened
            return opened
        }
    }

    /// Runs async work to completion from this synchronous reader.
    private func bridge<T>(_ work: @escaping @Sendable () async throws -> T) -> T? {
        var result: Result<T, Error>?
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                result = .success(try await work())
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try? result?.get()
    }
}
