import Foundation
import os
#if canImport(UserNotifications)
import UserNotifications
#endif

// Ports data/webdav/WebDavUploads.kt and WebDavUploadNotifications.kt:
// copies on-device tracks to the configured WebDAV server. Copy, not move:
// the local file stays where it was, so this never needs delete permission
// — the server copy simply shows up in the WebDAV library on its next
// listing.
//
// One batch runs sequentially. Parallel PUTs would finish sooner on Wi-Fi
// and fall over on a metered connection, and ordering is what makes a
// multi-conflict batch answerable: each clash suspends on `onConflict`, the
// app's dialog answers it, and an "apply to all" answer carries the rest of
// the batch without another popup.
//
// Android posts an ongoing notification row while bytes move; iOS has no
// ongoing notifications (PORTING.md §4), so progress stays in-app — `states`
// streams per-track fractions for the upload sheet — and only the batch
// result may surface as a local notification, when the app opts in via a
// ``WebDavUploadNotifying`` and the user granted notification permission.

private let uploadLog = Logger(subsystem: "com.fortune.vibramusic.ios", category: "NetworkLibrary")

/// Copies local audio files to the configured WebDAV server.
public actor WebDavUploads {
    /// What one track in the batch is doing.
    public enum TrackState: Sendable {
        case queued
        /// Uploading, with the fraction done when the length is known.
        case running(Double?)
        case done
        case failed(String)
        case skipped
    }

    public enum Choice: Sendable {
        case overwrite
        case keepBoth
        case skip
    }

    public struct Resolution: Sendable {
        public var choice: Choice
        public var applyToAll: Bool

        public init(choice: Choice, applyToAll: Bool = false) {
            self.choice = choice
            self.applyToAll = applyToAll
        }
    }

    /// A name clash waiting on the app's answer.
    public struct ConflictRequest: Sendable {
        /// The local file that clashed.
        public var item: UploadItem
        public var fileName: String
        /// Tracks still queued behind this one — whether "apply to all"
        /// means anything.
        public var remaining: Int

        public init(item: UploadItem, fileName: String, remaining: Int) {
            self.item = item
            self.fileName = fileName
            self.remaining = remaining
        }
    }

    /// One local file to send.
    public struct UploadItem: Hashable, Sendable {
        /// Stable identity for progress rows (the song's videoId when the
        /// upload starts from a library row).
        public var id: String
        public var fileURL: URL
        public var title: String
        public var artist: String

        public init(id: String, fileURL: URL, title: String, artist: String) {
            self.id = id
            self.fileURL = fileURL
            self.title = title
            self.artist = artist
        }

        public var fileExtension: String {
            String(fileURL.pathExtension.lowercased())
        }
    }

    public struct Summary: Sendable {
        public var uploaded: Int
        public var skipped: Int
        public var failed: Int

        public init(uploaded: Int, skipped: Int, failed: Int) {
            self.uploaded = uploaded
            self.skipped = skipped
            self.failed = failed
        }

        public var total: Int { uploaded + skipped + failed }

        public var message: String {
            "Uploaded \(uploaded) · skipped \(skipped) · failed \(failed)"
        }
    }

    private let client: WebDavClient
    private let credentials: WebDavCredentials
    private let notifier: (any WebDavUploadNotifying)?

    private var active: [String: TrackState] = [:]
    private var continuations: [UUID: AsyncStream<[String: TrackState]>.Continuation] = [:]

    public init(
        client: WebDavClient,
        credentials: WebDavCredentials,
        notifier: (any WebDavUploadNotifying)? = nil
    ) {
        self.client = client
        self.credentials = credentials
        self.notifier = notifier
    }

    /// Whether `item` can be sent at all: a file on this device, not a
    /// track already living on the server. Readability itself is checked at
    /// upload time and reported per track — this is only the cheap gate for
    /// showing the row.
    public static func isUploadable(_ item: UploadItem) -> Bool {
        if WebDavConfig.isWebDavId(item.id) { return false }
        return item.fileURL.isFileURL
    }

    /// The current per-track states, for the upload sheet's first paint.
    public func states() -> [String: TrackState] {
        active
    }

    /// Per-track states as they change, for the upload sheet.
    public func stateUpdates() -> AsyncStream<[String: TrackState]> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(active)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.dropContinuation(id) }
            }
        }
    }

    private func dropContinuation(_ id: UUID) {
        continuations[id]?.finish()
        continuations[id] = nil
    }

    private func set(_ id: String, state: TrackState?) {
        if let state {
            active[id] = state
        } else {
            active.removeValue(forKey: id)
        }
        for continuation in continuations.values {
            continuation.yield(active)
        }
    }

    /// Sends `items` to the server, answering clashes through `onConflict`.
    public func upload(
        _ items: [UploadItem],
        onConflict: (ConflictRequest) async -> Resolution = { _ in Resolution(choice: .skip, applyToAll: true) }
    ) async -> Summary {
        let root = credentials.rootUrl
        guard credentials.isConfigured else {
            uploadLog.error("WebDAV upload with no server configured")
            return Summary(uploaded: 0, skipped: 0, failed: items.count)
        }
        let queue = items.filter { Self.isUploadable($0) }
        // Fresh state for the tracks about to run; anything left over from
        // an earlier batch for them is stale.
        for item in queue { set(item.id, state: nil) }
        if queue.isEmpty {
            await notifier?.uploadFinished(summary: Summary(uploaded: 0, skipped: 0, failed: 0), title: nil)
            return Summary(uploaded: 0, skipped: 0, failed: 0)
        }
        var uploaded = 0
        var skipped = 0
        var failed = 0
        var standing: Resolution?
        // Names claimed by this batch, so two locals with the same title
        // don't both aim at one target.
        var taken = Set<String>()

        for (index, item) in queue.enumerated() {
            set(item.id, state: .queued)
            let remaining = queue.count - index - 1
            await notifier?.uploadProgress(title: item.title, body: item.artist, fraction: nil)
            let outcome: Outcome
            do {
                outcome = try await uploadOne(item, root: root, taken: &taken, remaining: remaining) { request in
                    if let standing { return standing }
                    let answer = await onConflict(request)
                    if answer.applyToAll { standing = answer }
                    return answer
                }
            } catch {
                set(item.id, state: .failed(errorMessage(for: error)))
                failed += 1
                continue
            }
            switch outcome {
            case .uploaded:
                set(item.id, state: .done)
                uploaded += 1
            case .skipped:
                set(item.id, state: .skipped)
                skipped += 1
            }
        }
        let summary = Summary(uploaded: uploaded, skipped: skipped, failed: failed)
        await notifier?.uploadFinished(summary: summary, title: queue.first?.title)
        return summary
    }

    private enum Outcome { case uploaded, skipped }

    private func uploadOne(
        _ item: UploadItem,
        root: String,
        taken: inout Set<String>,
        remaining: Int,
        resolve: (ConflictRequest) async -> Resolution
    ) async throws -> Outcome {
        let ext = item.fileExtension.isEmpty ? "mp3" : item.fileExtension
        guard FileManager.default.isReadableFile(atPath: item.fileURL.path(percentEncoded: false)) else {
            throw WebDavError("Could not read this file")
        }
        var fileName = WebDavClient.resolveNumberedName(
            base: WebDavClient.uploadFileName(title: item.title, artist: item.artist, fileExtension: ext)
                .split(separator: ".").dropLast().joined(separator: "."),
            fileExtension: ext,
            taken: taken
        )
        taken.insert(fileName.lowercased())

        var target = WebDavClient.joinUrl(root: root, segment: fileName)
        // Only an overwrite writes over an existing file; every other path
        // keeps `If-None-Match`, so a race after the check below 412s
        // instead of clobbering.
        var overwrite = false
        if try await client.exists(fileUrl: target, credentials: credentials) {
            switch await resolve(ConflictRequest(item: item, fileName: fileName, remaining: remaining)).choice {
            case .skip:
                return .skipped
            case .overwrite:
                overwrite = true
            case .keepBoth:
                // Number past whatever the server holds, checking each
                // candidate — the batch set above only knows about itself.
                var attempts = 0
                while attempts < 25 {
                    attempts += 1
                    taken.insert(fileName.lowercased())
                    fileName = WebDavClient.resolveNumberedName(
                        base: WebDavClient.uploadFileName(title: item.title, artist: item.artist, fileExtension: ext)
                            .split(separator: ".").dropLast().joined(separator: "."),
                        fileExtension: ext,
                        taken: taken
                    )
                    target = WebDavClient.joinUrl(root: root, segment: fileName)
                    if try await client.exists(fileUrl: target, credentials: credentials) == false { break }
                }
                taken.insert(fileName.lowercased())
            }
        }
        let id = item.id
        switch try await client.putFile(
            targetUrl: target,
            fileURL: item.fileURL,
            mimeType: RemoteMimeTypes.mimeType(forExtension: ext),
            credentials: credentials,
            overwrite: overwrite,
            onProgress: { written in
                Task { await self.progress(itemId: id, written: written, total: nil) }
            }
        ) {
        case .alreadyExists:
            // Lost a race with something else writing the same name after
            // the check above. The bytes on the server aren't ours, so this
            // is a skip rather than a success.
            return .skipped
        case .uploaded:
            return .uploaded
        }
    }

    private func progress(itemId: String, written: Int64, total: Int64?) {
        // A trailing progress callback can land after the track already
        // finished (it hops through a Task); terminal states win.
        switch active[itemId] {
        case .done, .failed, .skipped: return
        default: break
        }
        if let total, total > 0 {
            set(itemId, state: .running(min(max(Double(written) / Double(total), 0), 1)))
        } else {
            set(itemId, state: .running(nil))
        }
    }

    private func errorMessage(for error: Error) -> String {
        RemoteListing.message(for: error)
    }
}

// MARK: - Upload presence

/// The app-facing side of an upload batch: in-app progress plus the optional
/// local notification when it lands.
public protocol WebDavUploadNotifying: Sendable {
    /// Progress for the current track. Upload sheets observe
    /// `WebDavUploads.stateUpdates()` for per-track fractions; this is the
    /// hook for any extra presence (a Live Activity, a status line).
    func uploadProgress(title: String, body: String, fraction: Double?) async
    /// The batch result. The default implementation posts a local
    /// notification, but only when the user granted permission — without it
    /// the batch simply ends silently and must not fail.
    func uploadFinished(summary: WebDavUploads.Summary, title: String?) async
}

/// Posts the batch result as a local notification when permitted, and
/// otherwise stays silent. Progress itself is in-app only: iOS has no
/// ongoing notifications.
public struct WebDavUploadLocalNotifier: WebDavUploadNotifying {
    public init() {}

    public func uploadProgress(title: String, body: String, fraction: Double?) async {}

    public func uploadFinished(summary: WebDavUploads.Summary, title: String?) async {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "WebDAV upload"
        content.body = summary.message
        content.sound = nil
        let request = UNNotificationRequest(
            identifier: "webdav-upload-done",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
        #endif
    }
}
