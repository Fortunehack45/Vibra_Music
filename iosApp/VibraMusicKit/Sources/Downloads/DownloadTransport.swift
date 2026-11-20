import CryptoKit
import Foundation
import VibraMusicCore

/// One finished HTTP transfer: the body on disk, and what the server said about it.
public struct TransportResult: Sendable {
    /// The body. The caller owns it and must move or delete it.
    public let fileURL: URL
    public let statusCode: Int
    /// Response headers, names as the server sent them. Use ``header(_:)`` to look one up.
    public let headers: [String: String]

    public init(fileURL: URL, statusCode: Int, headers: [String: String]) {
        self.fileURL = fileURL
        self.statusCode = statusCode
        self.headers = headers
    }

    /// A response header, case-insensitively.
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Bytes in the body file.
    public var byteCount: Int64 { DownloadStore.fileSize(fileURL) }
}

/// Moves bytes for the download queue.
///
/// The seam between the queue and `URLSession`. The app uses ``URLSessionDownloadTransport`` over a
/// *background* session (PORTING.md §4: "Foreground service for downloads" → background `URLSession`
/// download tasks), so transfers carry on while the app is suspended and even after the system has
/// terminated it. Tests use the same class over a foreground session routed through
/// `URLProtocolStub` (custom protocols don't work in background sessions).
///
/// Every transfer is named by a `key` that is stable across launches. That is what "resume after
/// relaunch" hangs on: a task that was still running, or that finished while the app was not, is
/// found again by its key rather than started a second time.
public protocol DownloadTransport: AnyObject, Sendable {
    /// Fetches `request` and returns the body on disk.
    ///
    /// If a transfer with this `key` is already in flight (started before a relaunch) it is joined
    /// rather than repeated, and if one already finished while nobody was waiting, its result is
    /// returned at once. Cancelling the calling task cancels the transfer.
    ///
    /// - Parameter progress: called with bytes received so far and the expected total (nil when the
    ///   server didn't say), from an arbitrary thread.
    func download(
        _ request: URLRequest,
        key: String,
        progress: (@Sendable (_ received: Int64, _ expected: Int64?) -> Void)?
    ) async throws -> TransportResult

    /// Releases every waiter without cancelling its transfer — what the process dying looks like to
    /// a background session. Transfers that finish afterwards are kept for the next launch.
    func detachAll()

    /// Deletes kept results whose key doesn't start with one of `prefixes` (jobs that no longer
    /// exist, for example ones cancelled while the app wasn't running).
    func discardResults(keepingPrefixes prefixes: Set<String>)

    /// Hand over the completion handler from
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`. It is called once the
    /// session has delivered every pending event.
    func handleBackgroundEvents(completion: @escaping @Sendable () -> Void)
}

/// ``DownloadTransport`` over `URLSessionDownloadTask`s.
///
/// Completed bodies are moved out of the system's temporary location synchronously (it deletes the
/// file when the delegate call returns) into the staging directory, named by a hash of the key,
/// with a small JSON beside it holding the status and headers. That pair *is* the durable result:
/// if nobody is waiting for it — the app was suspended or killed when it landed — the next
/// ``download(_:key:progress:)`` for that key picks it up from disk instead of asking the network
/// again.
public final class URLSessionDownloadTransport: NSObject, DownloadTransport, URLSessionDownloadDelegate, @unchecked Sendable {
    /// The identifier the app's background session uses.
    public static let defaultBackgroundIdentifier = "com.fortune.vibramusic.ios.downloads"

    /// What a finished transfer whose body couldn't be kept is told as (both places that surface it).
    private static let storageFailure = DownloadError("Couldn't save the download to this device's storage")

    private struct Waiter {
        let continuation: CheckedContinuation<TransportResult, Error>
        let progress: (@Sendable (Int64, Int64?) -> Void)?
    }

    private struct StagedMeta: Codable {
        let key: String
        let statusCode: Int
        let headers: [String: String]
    }

    private let stagingDirectory: URL
    private let lock = NSLock()
    private var session: URLSession!
    private var waiters: [String: Waiter] = [:]
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var detached = false
    private var backgroundCompletion: (@Sendable () -> Void)?
    private var reattach: Task<Void, Never>?

    /// A transport over a background session (the app's). Only one may exist per identifier per
    /// process.
    public static func background(
        identifier: String = defaultBackgroundIdentifier,
        stagingDirectory: URL
    ) -> URLSessionDownloadTransport {
        URLSessionDownloadTransport(configuration: backgroundConfiguration(identifier: identifier), stagingDirectory: stagingDirectory)
    }

    /// The app's background session configuration.
    static func backgroundConfiguration(identifier: String) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        // A background session retries a stalled or cut-off transfer on its own until this, seven
        // days by default: a download on a dead connection sat on "running" for a week.
        // An hour is ample for one transfer (a 1 MB range, or a whole 200 MB file at ~450 kbps);
        // past it the downloader's own retries, then a visible failure, take over.
        configuration.timeoutIntervalForResource = 60 * 60
        // Relaunch the app in the background when transfers finish, so the queue can append the
        // chunk, start the next one and tag the finished file without the user opening it.
        configuration.sessionSendsLaunchEvents = true
        // A download the user asked for now is not something for the system to defer to overnight.
        configuration.isDiscretionary = false
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = VibraMusicHTTP.maxConnectionsPerHost
        return configuration
    }

    /// A transport over any configuration. Foreground configurations get `waitsForConnectivity`, so
    /// a request the Wi-Fi-only policy keeps off cellular waits instead of failing (background
    /// sessions always wait).
    public init(configuration: URLSessionConfiguration, stagingDirectory: URL) {
        self.stagingDirectory = stagingDirectory
        super.init()
        if configuration.identifier == nil {
            configuration.waitsForConnectivity = true
        }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.fortune.vibramusic.ios.downloads.transport"
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        try? FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        // Transfers started by an earlier launch of the app are still running in a background
        // session; learn their keys so they are joined, not duplicated.
        reattach = Task { [weak self] in
            guard let self else { return }
            let running = await self.session.allTasks
            self.lock.withLock {
                for case let task as URLSessionDownloadTask in running {
                    guard let key = task.taskDescription, self.tasks[key] == nil else { continue }
                    self.tasks[key] = task
                }
            }
        }
    }

    /// Cancels every transfer and releases the session (tests; the app's lives for the process).
    public func invalidate() {
        session.invalidateAndCancel()
    }

    /// Lets running transfers finish, then releases the session.
    public func finishAndInvalidate() {
        session.finishTasksAndInvalidate()
    }

    // MARK: DownloadTransport

    public func download(
        _ request: URLRequest,
        key: String,
        progress: (@Sendable (Int64, Int64?) -> Void)?
    ) async throws -> TransportResult {
        try Task.checkCancellation()
        await reattach?.value
        if let staged = lock.withLock({ takeStaged(key) }) { return staged }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TransportResult, Error>) in
                enum Next { case staged(TransportResult), cancelled, wait }
                let next: Next = lock.withLock {
                    if Task.isCancelled { return .cancelled }
                    if let staged = takeStaged(key) { return .staged(staged) }
                    waiters[key] = Waiter(continuation: continuation, progress: progress)
                    if tasks[key] == nil {
                        let task = session.downloadTask(with: request)
                        task.taskDescription = key
                        tasks[key] = task
                        task.resume()
                    }
                    return .wait
                }
                switch next {
                case .staged(let result): continuation.resume(returning: result)
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .wait: break
                }
            }
        } onCancel: {
            let (waiter, task): (Waiter?, URLSessionDownloadTask?) = lock.withLock {
                let waiter = waiters.removeValue(forKey: key)
                // Detached means the process is "dying": the transfer outlives its waiter.
                let task = detached ? nil : tasks.removeValue(forKey: key)
                return (waiter, task)
            }
            task?.cancel()
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    public func detachAll() {
        let released: [Waiter] = lock.withLock {
            detached = true
            let all = Array(waiters.values)
            waiters.removeAll()
            return all
        }
        released.forEach { $0.continuation.resume(throwing: CancellationError()) }
    }

    public func discardResults(keepingPrefixes prefixes: Set<String>) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: stagingDirectory.path(percentEncoded: false)) else { return }
        lock.withLock {
            for name in names where name.hasSuffix(".json") {
                let metaURL = stagingDirectory.appending(path: name)
                let key = (try? JSONDecoder().decode(StagedMeta.self, from: Data(contentsOf: metaURL)))?.key
                if let key, prefixes.contains(where: { key.hasPrefix($0) }) { continue }
                try? fileManager.removeItem(at: metaURL)
                try? fileManager.removeItem(at: stagingDirectory.appending(path: String(name.dropLast(5)) + ".body"))
            }
            // Bodies whose metadata never got written belong to nobody.
            for name in names where name.hasSuffix(".body") {
                let stem = String(name.dropLast(5))
                if !fileManager.fileExists(atPath: stagingDirectory.appending(path: stem + ".json").path(percentEncoded: false)) {
                    try? fileManager.removeItem(at: stagingDirectory.appending(path: name))
                }
            }
        }
    }

    public func handleBackgroundEvents(completion: @escaping @Sendable () -> Void) {
        lock.withLock { backgroundCompletion = completion }
    }

    // MARK: URLSessionDownloadDelegate

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let key = downloadTask.taskDescription else { return }
        let handler = lock.withLock { waiters[key]?.progress }
        handler?(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let key = downloadTask.taskDescription else { return }
        // The system deletes `location` as soon as this returns, so the move has to happen here.
        let response = downloadTask.response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (name, value) in response?.allHeaderFields ?? [:] {
            if let name = name as? String { headers[name] = "\(value)" }
        }
        let body = bodyURL(key)
        let fileManager = FileManager.default
        do {
            // Under the lock so ``discardResults(keepingPrefixes:)`` at launch never sees the body
            // before its metadata and deletes it as belonging to nobody.
            try lock.withLock {
                try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
                try? fileManager.removeItem(at: body)
                try fileManager.moveItem(at: location, to: body)
                let meta = StagedMeta(key: key, statusCode: response?.statusCode ?? 0, headers: headers)
                try JSONEncoder().encode(meta).write(to: metaURL(key), options: .atomic)
            }
        } catch {
            DebugLog.w("Downloads", "could not keep a finished transfer", error: error)
            try? fileManager.removeItem(at: body)
            // Told here, not left to the task's own completion: a finished transfer that couldn't
            // be kept is a storage fault, and a failure that names the network would send the
            // user chasing a connection problem that isn't there.
            if let waiter = waiter(key) {
                waiter.continuation.resume(throwing: Self.storageFailure)
            }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let key = task.taskDescription else { return }
        let waiter: Waiter? = lock.withLock {
            if tasks[key] === task { tasks.removeValue(forKey: key) }
            return waiters.removeValue(forKey: key)
        }
        if let error {
            // A failed transfer leaves nothing worth keeping; the next attempt asks again.
            try? FileManager.default.removeItem(at: bodyURL(key))
            try? FileManager.default.removeItem(at: metaURL(key))
            waiter?.continuation.resume(throwing: error)
            return
        }
        guard let waiter else {
            // Nobody is waiting: the app was suspended or killed when this landed. The staged
            // body and its metadata stay on disk for the next launch to pick up.
            return
        }
        if let staged = lock.withLock({ takeStaged(key) }) {
            waiter.continuation.resume(returning: staged)
        } else {
            // Says storage, not network: the transfer arrived whole and nothing could be kept of it.
            waiter.continuation.resume(throwing: Self.storageFailure)
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { backgroundCompletion = nil }
            return backgroundCompletion
        }
        guard let completion else { return }
        DispatchQueue.main.async { completion() }
    }

    // MARK: Staging

    /// The waiter left for `key`, removed from the table, so a transfer resumed in one place can't
    /// be resumed again.
    private func waiter(_ key: String) -> Waiter? {
        lock.withLock { waiters.removeValue(forKey: key) }
    }

    private func stem(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func bodyURL(_ key: String) -> URL {
        stagingDirectory.appending(path: stem(key) + ".body", directoryHint: .notDirectory)
    }

    private func metaURL(_ key: String) -> URL {
        stagingDirectory.appending(path: stem(key) + ".json", directoryHint: .notDirectory)
    }

    /// A result already on disk for `key`, handed over (its metadata is consumed; the body is the
    /// caller's). Call with the lock held.
    private func takeStaged(_ key: String) -> TransportResult? {
        let metaURL = metaURL(key)
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(StagedMeta.self, from: data),
              meta.key == key else { return nil }
        let body = bodyURL(key)
        try? FileManager.default.removeItem(at: metaURL)
        guard FileManager.default.fileExists(atPath: body.path(percentEncoded: false)) else { return nil }
        return TransportResult(fileURL: body, statusCode: meta.statusCode, headers: meta.headers)
    }
}
