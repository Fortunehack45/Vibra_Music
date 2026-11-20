import Foundation
import Observation
import VibraMusicCore

// Ports the queue half of download/Downloads.kt (enqueue, cancel, run, prepare, transfer, routeFor)
// and download/DownloadService.kt (the workers), onto background URLSession transfers.

/// How one download's bytes are fetched and filed.
struct DownloadRoute: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// googlevideo: bounded ranged requests (see ``Downloader``).
        case ranged
        /// Any other progressive file: one GET.
        case direct
        /// A manifest, flattened into one fragmented `.m4a` (see ``OfflineDash``).
        case hls
        case dash
    }

    var kind: Kind
    var fileExtension: String
    /// The badge shown in the Downloads list.
    var downloadFormat: String?
    /// For the log line, so a download's provenance is on the record.
    var describe: String
}

/// Everything decided about a job before its first byte, plus where its transfer has got to —
/// persisted so a relaunch carries on rather than starting over.
struct DownloadProgressRecord: Codable, Hashable, Sendable {
    /// Read once for the whole of this track: a setting changed mid-download applies to the next
    /// track, not to the second half of this one (a re-resolve must ask for the same rung).
    var quality: DownloadQuality
    var route: DownloadRoute
    var fileName: String
    /// Whole-file length for ranged fetches.
    var total: Int64?
    var transfer: TransferCheckpoint
}

/// One track in the queue.
struct DownloadJob: Codable, Hashable, Sendable {
    var id: UUID
    var song: Song
    var from: String?
    var progress: DownloadProgressRecord?

    /// Stable across launches; every transfer for this job is named from it.
    var key: String { "\(song.videoId)#\(id.uuidString)" }
    /// Distinguishes this job's part file from another job's for the same name.
    var token: String { String(id.uuidString.prefix(8)) }
}

/// A job a worker has taken, and the task doing it.
private struct RunningJob {
    var job: DownloadJob
    let task: Task<Void, Never>
}

/// The download queue.
///
/// ### What happens to a tap
///
/// ``enqueue(_:from:)`` (or ``download(_:as:)`` for a whole album or playlist) puts the track in the
/// queue and returns. Up to ``Configuration/workers`` tracks run at once (four, as on Android:
/// working out where a lossless track's bytes come from is tens of seconds of *latency*, so the
/// answer is overlap). Each job:
///
/// 1. waits for a connection the Wi-Fi-only setting allows (``isWaitingForWiFi``);
/// 2. resolves a stream through the injected `StreamResolving` at
///    `StreamRequest.download(settings.downloadQuality)` — Standard is capped at 128 kbps, High is
///    the best lossy rung, Lossless asks sources for their bit-exact file;
/// 3. decides how to save it (``DownloadRoute``): googlevideo as ranged requests, a source's file in
///    one GET, an HLS or DASH manifest flattened into one fragmented `.m4a`;
/// 4. transfers through background `URLSession` download tasks while the lyrics lookup and the
///    cover fetch run alongside;
/// 5. tags the part file (``Mp4Tagger`` / ``FlacTagger``), renames it into place, and records it
///    in the ``library``.
///
/// ### iOS differences
///
/// - **No foreground service.** Transfers are background download tasks (PORTING.md §4), so they
///   continue while the app is suspended, and the queue itself is persisted (`queue.json`) with a
///   checkpoint after every range or segment. Constructing the manager at launch restores it: a job
///   picks up at its last whole range, joining a transfer still in flight or collecting one that
///   finished while the app wasn't running. Forward
///   `application(_:handleEventsForBackgroundURLSession:completionHandler:)` to
///   ``handleBackgroundEvents(identifier:completion:)``.
/// - **Wi-Fi only waits instead of refusing.** Android failed the row with "Downloads are set to
///   Wi-Fi only". PORTING.md's acceptance test is "with Wi-Fi only on, downloads wait while on
///   cellular": the queue holds (``isWaitingForWiFi``) and every request is sent with
///   `allowsExpensiveNetworkAccess`/`allowsConstrainedNetworkAccess` off, so even a transfer the
///   system runs while the app is suspended waits for Wi-Fi. Offline is let through, as on Android:
///   refusing there would blame a Wi-Fi setting for an outage.
/// - **No catalogue swap and no source fallback here.** The composed resolver the app injects
///   already walks the sources and falls back to YouTube.
/// - **No notification.** Progress is state on this object for the app to draw (PORTING.md §4).
@MainActor
@Observable
public final class DownloadManager {
    public struct Configuration: Sendable {
        /// Tracks fetched at once.
        public var workers: Int
        /// The largest googlevideo range asked for at once.
        public var chunkBytes: Int64
        /// Waits between attempts after a transient network failure, per request.
        public var retryDelays: [Double]
        /// How long a finished transfer may wait for its lyrics (Android's `LyricsTag.LOOKUP_MS`).
        public var lyricsTimeout: Double

        public init(workers: Int = 4, chunkBytes: Int64 = 2 * 1024 * 1024, retryDelays: [Double] = [1, 2, 4],
                    lyricsTimeout: Double = 30) {
            self.workers = max(1, workers)
            self.chunkBytes = max(1, chunkBytes)
            self.retryDelays = retryDelays
            self.lyricsTimeout = lyricsTimeout
        }
    }

    /// What is happening now — queued, running, just failed — by videoId. Empty for a track that is
    /// either not downloaded or already saved (ask ``library`` which).
    public private(set) var active: [String: DownloadState] = [:]
    /// Everything asked for in this sitting, and whether the user has seen how it went.
    public let session: DownloadSession
    /// What is on the device.
    public let library: DownloadLibrary
    /// The connection as the Wi-Fi-only gate last saw it.
    public private(set) var networkStatus: NetworkStatus
    /// Supplies lyrics to embed; the Lyrics module is wired in by the app. Nil embeds none.
    @ObservationIgnored public var lyricsProvider: DownloadLyricsProvider?
    /// Told about a googlevideo refusal before the track is resolved again; see
    /// ``DownloadStreamRefusalHandler``.
    @ObservationIgnored public var refusalHandler: DownloadStreamRefusalHandler?

    /// Whether the queue is holding because Wi-Fi only is on and the connection is metered.
    public var isWaitingForWiFi: Bool {
        !downloadsAllowed && active.values.contains { $0.isInFlight }
    }

    /// Whether the Wi-Fi-only setting lets downloads use the current connection.
    public var downloadsAllowed: Bool { settings.downloadsAllowed(on: networkStatus) }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let resolver: any StreamResolving
    @ObservationIgnored private let network: any NetworkStatusProviding
    @ObservationIgnored private let transport: any DownloadTransport
    @ObservationIgnored private var downloader: Downloader
    /// Answers a playlist kept on this device (a source's converted DASH manifest); see
    /// ``Downloader/localPlaylist``. The app wires the Sources module's manifest files here.
    @ObservationIgnored public var localPlaylist: (@Sendable (URL) -> String?)? {
        didSet { downloader.localPlaylist = localPlaylist }
    }
    @ObservationIgnored private let tagger: MediaTagger
    @ObservationIgnored private let configuration: Configuration
    @ObservationIgnored private var pending: [DownloadJob] = []
    @ObservationIgnored private var running: [String: RunningJob] = [:]
    /// Which job picked each file name, so a same-name job running beside it picks another before
    /// either has a progress record.
    @ObservationIgnored private var chosenNames: [String: String] = [:]
    @ObservationIgnored private var networkWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var lastProgress: [String: Double] = [:]
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var terminated = false

    private static let queueFile = "queue.json"
    /// The extensions a saved file can carry that say, on their own, that a lossless request has
    /// already been answered. `m4a` is deliberately absent: it may be ALAC or the AAC a High
    /// download wrote, and adopting the wrong one would answer a request for lossless with a
    /// transcode.
    private static let losslessExtensions = ["flac", "wav"]

    public init(
        settings: AppSettings,
        resolver: any StreamResolving,
        network: any NetworkStatusProviding,
        transport: any DownloadTransport,
        library: DownloadLibrary,
        http: URLSession = VibraMusicHTTP.session,
        session: DownloadSession? = nil,
        lyricsProvider: DownloadLyricsProvider? = nil,
        refusalHandler: DownloadStreamRefusalHandler? = nil,
        configuration: Configuration = Configuration()
    ) {
        self.settings = settings
        self.resolver = resolver
        self.network = network
        self.transport = transport
        self.library = library
        self.session = session ?? DownloadSession()
        self.lyricsProvider = lyricsProvider
        self.refusalHandler = refusalHandler
        self.configuration = configuration
        self.networkStatus = network.status
        self.downloader = Downloader(transport: transport, http: http, chunkBytes: configuration.chunkBytes,
                                     retryDelays: configuration.retryDelays)
        self.tagger = MediaTagger(store: library.store, http: http)
        try? library.store.prepare()

        monitorTask = Task { [weak self, network] in
            for await status in network.statusUpdates() {
                guard let self else { return }
                self.networkChanged(status)
            }
        }
        observeSettings()
        restoreQueue()
    }

    /// The app's queue: a background `URLSession` and the library in Application Support. Create
    /// one at launch, before the app delegate is asked about background session events.
    public static func live(
        settings: AppSettings? = nil,
        resolver: any StreamResolving,
        network: any NetworkStatusProviding,
        library: DownloadLibrary? = nil,
        lyricsProvider: DownloadLyricsProvider? = nil,
        refusalHandler: DownloadStreamRefusalHandler? = nil
    ) -> DownloadManager {
        let settings = settings ?? .shared
        let library = library ?? .live()
        let transport = URLSessionDownloadTransport.background(stagingDirectory: library.store.stagingDirectory)
        return DownloadManager(settings: settings, resolver: resolver, network: network, transport: transport,
                               library: library, lyricsProvider: lyricsProvider, refusalHandler: refusalHandler)
    }

    // MARK: Asking

    /// Queue `song`. A track already queued or running is left alone rather than doubled — a second
    /// tap before the row updates is a no-op. (A saved track isn't checked here; see
    /// ``download(_:as:)``.)
    ///
    /// - Parameter from: what release this track was asked for as part of, when it was one of many.
    ///   Carried no further than ``session``, which is the only thing that has to say *why* forty
    ///   tracks are in the queue.
    public func enqueue(_ song: Song, from: String? = nil) {
        let id = song.videoId
        guard !isQueuedOrRunning(id) else { return }
        pending.append(DownloadJob(id: UUID(), song: song, from: from, progress: nil))
        active[id] = .queued
        session.queued(song, from: from)
        persistQueue()
        startWorkers()
    }

    /// Download a track, or a whole album or playlist ("Download all").
    ///
    /// Tracks already on the device and ones already in the queue are skipped. The release's cover
    /// is stamped onto any row that hasn't one — an album page's rows carry no artwork of their own,
    /// and a row saved without a cover stays without one. When `target` is given, the batch is
    /// recorded as that release (``DownloadLibrary/rememberCollection(_:songs:)``) — for every track
    /// asked for, including ones already saved, since the point of the record is to group them — and
    /// its cover is cached for offline display.
    @discardableResult
    public func download(_ requested: [Song], as target: DownloadTarget? = nil) -> DownloadRequestOutcome {
        var outcome = DownloadRequestOutcome()
        var toQueue: [Song] = []
        var seen = Set<String>()
        for var song in requested where seen.insert(song.videoId).inserted {
            if library.savedFileURL(for: song.videoId) != nil {
                outcome.alreadyDownloaded += 1
                continue
            }
            if isQueuedOrRunning(song.videoId) {
                outcome.alreadyQueued += 1
                continue
            }
            if song.thumbnailUrl?.isBlank ?? true, let cover = target?.thumbnailUrl, !cover.isBlank {
                song.thumbnailUrl = cover
            }
            toQueue.append(song)
        }
        for song in toQueue { enqueue(song, from: target?.title) }
        outcome.queued = toQueue.count

        if let target {
            library.markRequested(target.id, videoIds: toQueue.map(\.videoId))
            library.rememberCollection(target, songs: requested)
            if let cover = target.thumbnailUrl, !cover.isBlank {
                let allowsMetered = !settings.wifiOnlyDownloads || downloadsAllowed
                Task { [tagger, library] in
                    if let path = await tagger.cacheArtwork(sourceUrl: cover, allowsMeteredNetwork: allowsMetered) {
                        library.rememberCollectionArtwork(id: target.id, artworkPath: path)
                    }
                }
            }
        }
        outcome.waitingForWiFi = outcome.queued > 0 && !downloadsAllowed
        return outcome
    }

    /// Drop `videoId` from the queue, or stop it if it is running (deleting its partial file). A
    /// download the user called off leaves the session list too, rather than sitting in it as a
    /// permanent "cancelled" row.
    public func cancel(_ videoId: String) {
        pending.removeAll { $0.song.videoId == videoId }
        if let entry = running.removeValue(forKey: videoId) {
            entry.task.cancel()
        }
        active.removeValue(forKey: videoId)
        lastProgress.removeValue(forKey: videoId)
        session.forget(videoId)
        persistQueue()
        startWorkers()
        notifyIfIdle()
    }

    /// Cancel everything queued or running.
    public func cancelAll() {
        let ids = active.filter { $0.value.isInFlight }.map(\.key)
        ids.forEach(cancel)
    }

    /// Ask again for a failed track, as it was asked the first time.
    public func retry(_ videoId: String) {
        guard let item = session.item(videoId) else { return }
        enqueue(item.song, from: item.from)
    }

    /// Clear a failure off its row; a failure is worth showing once.
    public func dismissFailure(_ videoId: String) {
        if case .failed = active[videoId] { active.removeValue(forKey: videoId) }
    }

    /// Hand over the completion handler iOS passes to
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    public func handleBackgroundEvents(identifier: String, completion: @escaping @Sendable () -> Void) {
        guard identifier == URLSessionDownloadTransport.defaultBackgroundIdentifier else {
            completion()
            return
        }
        transport.handleBackgroundEvents(completion: completion)
    }

    /// Returns once nothing is queued or running.
    public func waitUntilIdle() async {
        while !pending.isEmpty || !running.isEmpty {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
    }

    // MARK: Workers

    private func isQueuedOrRunning(_ videoId: String) -> Bool {
        running[videoId] != nil || pending.contains { $0.song.videoId == videoId }
    }

    private func startWorkers() {
        guard !terminated else { return }
        while running.count < configuration.workers, downloadsAllowed, !pending.isEmpty {
            let job = pending.removeFirst()
            let task = Task { [weak self] in
                guard let self else { return }
                await self.run(job)
            }
            running[job.song.videoId] = RunningJob(job: job, task: task)
        }
    }

    private func isCurrent(_ job: DownloadJob) -> Bool {
        running[job.song.videoId]?.job.id == job.id
    }

    private func run(_ job: DownloadJob) async {
        let id = job.song.videoId
        guard isCurrent(job) else { return }
        // Set before the lookup, not after it: resolving is the long part of a lossless download,
        // and leaving the row on "Queued" for all of it reads as a queue that has stopped.
        if case .running = active[id] {} else { setProgress(job, 0) }
        do {
            // The whole track's work is filed against it in the shareable TrackLog (the in-app
            // "Copy log"): what was resolved, what was fetched and why something failed, so a
            // pasted log carries the download's part of the story.
            try await TrackLog.about(id) { try await perform(job) }
        } catch {
            if terminated { return }
            if isCurrent(job) {
                if Task.isCancelled || error is CancellationError {
                    active.removeValue(forKey: id)
                } else {
                    // Full fidelity stays in the unified log; the shareable line carries the
                    // user-language reason only: a reflected URLSession error can name the
                    // stream URL (and its session token), and a paste must not copy that.
                    DebugLog.w("Downloads", "download failed for \(id)", error: error)
                    TrackLog.w("Downloads", "download failed for \(id) — \(Self.friendly(error))", about: id)
                    let reason = Self.friendly(error)
                    active[id] = .failed(reason: reason)
                    session.failed(id, reason: reason)
                }
            }
        }
        guard !terminated else { return }
        if isCurrent(job) { running.removeValue(forKey: id) }
        lastProgress.removeValue(forKey: id)
        persistQueue()
        startWorkers()
        notifyIfIdle()
    }

    /// One track, start to finish.
    private func perform(_ original: DownloadJob) async throws {
        var job = original
        let song = job.song
        let store = library.store

        let record: DownloadProgressRecord
        if let saved = job.progress {
            record = saved
        } else {
            try await waitForAllowedNetwork()
            let quality = settings.downloadQuality
            // A file already saved under a lossless-only extension is the answer to the whole
            // question; spending a module search to arrive at a name we could have guessed is the
            // difference between re-running a 300-track queue in seconds and in hours.
            if quality.keepsLossless {
                for ext in Self.losslessExtensions {
                    if let existing = store.existing(name: fileName(for: song, extension: ext)) {
                        adopt(job, file: existing)
                        return
                    }
                }
            }
            let stream = try await resolver.resolveStream(for: song, request: .download(quality))
            try Task.checkCancellation()
            let route = try await route(for: stream)
            let name = fileName(for: song, extension: route.fileExtension)
            TrackLog.d("Downloads", "downloading \(song.videoId) as .\(route.fileExtension) (\(route.describe), \(quality.label))")
            // Already there from a run the record lost track of: adopt it rather than writing a
            // second copy beside it. Not for a lossless or Atmos stream: the name carries no
            // quality, so the file there may be the AAC an earlier download wrote.
            if stream.format.isLossless != true, !stream.format.isDolbyAtmos, let existing = store.existing(name: name) {
                adopt(job, file: existing)
                return
            }
            var transfer = TransferCheckpoint(written: 0, stream: stream, reresolved: false)
            var total: Int64?
            switch route.kind {
            case .ranged:
                guard let length = try await downloader.contentLength(of: stream) else {
                    throw DownloadError("Track unavailable: no length to fetch")
                }
                total = length
            case .hls, .dash:
                transfer.segments = try await downloader.packageSegments(stream, dash: route.kind == .dash)
            case .direct:
                break
            }
            record = DownloadProgressRecord(quality: quality, route: route, fileName: name, total: total, transfer: transfer)
            job.progress = record
            guard isCurrent(original) else { throw CancellationError() }
            running[song.videoId]?.job = job
            persistQueue()
        }

        let route = record.route
        // A resumed job skipped the wait above, and the lyric services don't honour Wi-Fi only.
        try await waitForAllowedNetwork()
        // Started before the transfer, so the lyric services are raced while the bytes move. Done
        // after it instead, every download would pay the slowest of them in dead time.
        let wantsLyrics = MediaTagger.carriesTags(route.fileExtension)
            && settings.syncedLyrics && !settings.lyricsSources.isEmpty
        let provider = wantsLyrics ? lyricsProvider : nil
        let timeout = configuration.lyricsTimeout
        let lyricsTask = Task { await LyricsEmbedding.fetch(provider, track: song, timeout: timeout) }
        let allowsMetered = !settings.wifiOnlyDownloads
        let artworkTask = Task { [tagger] in await tagger.artwork(for: song, allowsMeteredNetwork: allowsMetered) }
        defer {
            lyricsTask.cancel()
            artworkTask.cancel()
        }

        let pendingFile = try store.begin(name: record.fileName, token: job.token, resumeAt: record.transfer.written)
        // A part file that lost its bytes (purged, or not restored from a backup) starts over;
        // carrying on from the checkpoint would leave a hole of zeros at the front of the song.
        var transfer = record.transfer
        if pendingFile.partSize != transfer.written {
            transfer.written = 0
            transfer.nextSegment = 0
        }
        do {
            let hooks = hooks(for: job, quality: record.quality)
            switch route.kind {
            case .ranged:
                _ = try await downloader.fetchRanged(jobKey: job.key, part: pendingFile.partURL, total: record.total ?? 0,
                                                     from: transfer, hooks: hooks)
            case .direct:
                _ = try await downloader.fetchDirect(jobKey: job.key, stream: transfer.stream,
                                                     part: pendingFile.partURL, hooks: hooks)
            case .hls, .dash:
                try await downloader.fetchPackage(jobKey: job.key, part: pendingFile.partURL, dash: route.kind == .dash,
                                                  from: transfer, hooks: hooks)
            }
            try Task.checkCancellation()
            // YouTube's AAC (and every flattened package) is fragmented MP4, whose header declares
            // a duration AVFoundation then adds the fragments to: patched before anything reads it.
            if route.fileExtension == "m4a" {
                do {
                    let patched = try FragmentedMP4Durations.patchFile(at: pendingFile.partURL)
                    if patched > 0 { DebugLog.d("Downloads", "zeroed \(patched) declared durations in \(record.fileName)") }
                } catch {
                    DebugLog.w("Downloads", "could not check \(record.fileName)'s declared duration", error: error)
                }
            }
            let lyrics = await lyricsTask.value
            let artwork = await artworkTask.value
            // Publish only after the metadata is part of the file, so concurrent album workers
            // never expose an untagged track.
            await tagger.embed(file: pendingFile.partURL, track: song, extension: route.fileExtension,
                               lyrics: lyrics, artwork: artwork)
            let artworkPath = tagger.persistArtwork(sourceUrl: song.thumbnailUrl, artwork: artwork)
            try Task.checkCancellation()
            guard isCurrent(original) else { throw CancellationError() }
            let file = try pendingFile.commit()
            library.remember(asked: song, fetched: song, file: file, downloadFormat: route.downloadFormat, artworkPath: artworkPath)
            session.done(song.videoId)
            active.removeValue(forKey: song.videoId)
            TrackLog.d("Downloads", "saved \(record.fileName)")
        } catch {
            // A terminated process keeps its part file: the next launch resumes into it.
            if !terminated { pendingFile.abort() }
            throw error
        }
    }

    /// `Artist - Title.ext`, with the video id added when another track already holds that name,
    /// saved or still downloading: two albums' "Intro" by one artist must neither share one file
    /// nor overwrite it.
    private func fileName(for song: Song, extension ext: String) -> String {
        let name = DownloadStore.fileName(for: song, extension: ext)
        let store = library.store
        let path = store.relativePath(of: store.tracksDirectory.appending(path: name, directoryHint: .notDirectory))
        let saved = library.saved.contains { $0.key != song.videoId && $0.value == path }
        let downloading = running.values.contains { $0.job.song.videoId != song.videoId && $0.job.progress?.fileName == name }
            || chosenNames[name].map { $0 != song.videoId && running[$0] != nil } == true
        guard saved || downloading else {
            chosenNames[name] = song.videoId
            return name
        }
        return "\(name.dropLast(ext.count + 1)) [\(DownloadStore.sanitise(song.videoId))].\(ext)"
    }

    private func adopt(_ job: DownloadJob, file: URL) {
        DebugLog.d("Downloads", "\(file.lastPathComponent) is already saved; adopting it")
        library.remember(asked: job.song, fetched: job.song, file: file)
        session.done(job.song.videoId)
        active.removeValue(forKey: job.song.videoId)
    }

    /// Where this download's bytes come from and what to call the file.
    private func route(for stream: ResolvedStream) async throws -> DownloadRoute {
        let mime = stream.mimeType?.lowercased() ?? ""
        let badge = stream.format.downloadBadge
        if OfflineDash.handles(stream.url) || mime.contains("dash+xml") {
            return DownloadRoute(kind: .dash, fileExtension: "m4a", downloadFormat: badge, describe: stream.format.summary)
        }
        if stream.isHLS {
            return DownloadRoute(kind: .hls, fileExtension: "m4a", downloadFormat: badge, describe: stream.format.summary)
        }
        if stream.origin == .youtube || Downloader.isGoogleVideo(stream.url) {
            // What googlevideo sends is what lands on disk — nothing here remuxes — so the extension
            // follows the container. YouTube's Opus is WebM, which AVPlayer can't play; the resolver
            // must hand downloads the AAC rendition.
            let isMP4 = mime.contains("mp4") || mime.contains("m4a")
                || (mime.isEmpty && stream.url.query()?.contains("mime=audio%2Fmp4") == true)
            guard isMP4 else {
                throw DownloadError(mime.contains("webm") ? "Can't save WebM audio on this device — try again" : "Can't save \(mime) — try again")
            }
            let kbps = stream.format.kbps ?? 0
            return DownloadRoute(kind: Downloader.isGoogleVideo(stream.url) ? .ranged : .direct, fileExtension: "m4a",
                                 downloadFormat: youtubeDownloadBadge(extension: "m4a", kbps: kbps),
                                 describe: "\(kbps)kbps \(mime)")
        }
        // A configured source: look at the bytes before trusting the label.
        let probed = try await downloader.probe(stream)
        let sniffed: String?
        switch probed {
        case .hlsPlaylist:
            return DownloadRoute(kind: .hls, fileExtension: "m4a", downloadFormat: badge, describe: stream.format.summary)
        case .dashManifest:
            return DownloadRoute(kind: .dash, fileExtension: "m4a", downloadFormat: badge, describe: stream.format.summary)
        case .refused(let status):
            throw DownloadError("Download failed (HTTP \(status))")
        case .flac: sniffed = "flac"
        case .mp4: sniffed = "m4a"
        case .mp3: sniffed = "mp3"
        case .wav: sniffed = "wav"
        case .unknown: sniffed = nil
        }
        guard let ext = sniffed ?? DownloadStore.storable(stream.format.codec)?.fileExtension ?? Self.fileExtension(forMime: mime) else {
            throw DownloadError("This track's format can't be saved on this device")
        }
        return DownloadRoute(kind: .direct, fileExtension: ext, downloadFormat: badge, describe: stream.format.summary)
    }

    private static func fileExtension(forMime mime: String) -> String? {
        if mime.contains("flac") { return "flac" }
        if mime.contains("mp4") || mime.contains("m4a") || mime.contains("aac") { return "m4a" }
        if mime.contains("mpeg") || mime.contains("mp3") { return "mp3" }
        if mime.contains("wav") { return "wav" }
        return nil
    }

    private func hooks(for job: DownloadJob, quality: DownloadQuality) -> TransferHooks {
        let song = job.song
        let resolver = self.resolver
        let refusalHandler = self.refusalHandler
        return TransferHooks(
            waitForNetwork: { [weak self] in try await self?.waitForAllowedNetwork() },
            allowsMeteredNetwork: { [weak self] in await self?.allowsMeteredRequests ?? false },
            progress: { [weak self] done, total in
                guard total > 0 else { return }
                let fraction = min(max(Double(done) / Double(total), 0), 1)
                Task { @MainActor [weak self] in self?.setProgress(job, fraction) }
            },
            checkpoint: { [weak self] checkpoint in await self?.saveCheckpoint(job, checkpoint) },
            reresolve: { try await resolver.resolveStream(for: song, request: .download(quality)) },
            refused: { url, status in await refusalHandler?(url, status) }
        )
    }

    private var allowsMeteredRequests: Bool { !settings.wifiOnlyDownloads }

    private func setProgress(_ job: DownloadJob, _ fraction: Double) {
        let id = job.song.videoId
        guard isCurrent(job) else { return }
        // Several tracks post progress a few times a second each; a row only needs to move when
        // the change is visible.
        if let last = lastProgress[id], fraction < 1, fraction - last < 0.005, fraction >= last { return }
        lastProgress[id] = fraction
        active[id] = .running(fraction: fraction)
        session.running(id, fraction: fraction)
    }

    private func saveCheckpoint(_ job: DownloadJob, _ checkpoint: TransferCheckpoint) {
        guard !terminated, var entry = running[job.song.videoId], entry.job.id == job.id else { return }
        entry.job.progress?.transfer = checkpoint
        running[job.song.videoId] = entry
        persistQueue()
    }

    // MARK: Wi-Fi only

    private func networkChanged(_ status: NetworkStatus) {
        guard status != networkStatus else { return }
        networkStatus = status
        reevaluateGate()
    }

    private func observeSettings() {
        withObservationTracking {
            _ = settings.wifiOnlyDownloads
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.reevaluateGate()
                self?.observeSettings()
            }
        }
    }

    private func reevaluateGate() {
        guard downloadsAllowed else { return }
        let waiters = networkWaiters.values
        networkWaiters.removeAll()
        waiters.forEach { $0.resume() }
        startWorkers()
    }

    /// Holds until the Wi-Fi-only setting allows the connection in hand.
    func waitForAllowedNetwork() async throws {
        while !downloadsAllowed {
            try Task.checkCancellation()
            let token = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume()
                    } else {
                        networkWaiters[token] = continuation
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.networkWaiters.removeValue(forKey: token)?.resume() }
            }
        }
        try Task.checkCancellation()
    }

    // MARK: Persistence and relaunch

    private func persistQueue() {
        guard !terminated else { return }
        let jobs = running.values.map(\.job).sorted { $0.id.uuidString < $1.id.uuidString } + pending
        do {
            if jobs.isEmpty {
                try library.store.records.remove(Self.queueFile)
            } else {
                try library.store.records.save(jobs, to: Self.queueFile)
            }
        } catch {
            DebugLog.e("Downloads", "could not save the download queue", error: error)
        }
    }

    /// Picks the queue back up after a relaunch: every job that was queued or running is queued
    /// again, and the running ones resume from their checkpoint.
    private func restoreQueue() {
        let jobs: [DownloadJob]
        do {
            jobs = try library.store.records.load([DownloadJob].self, from: Self.queueFile) ?? []
        } catch {
            DebugLog.e("Downloads", "download queue unreadable; dropping it", error: error)
            jobs = []
        }
        transport.discardResults(keepingPrefixes: Set(jobs.map { $0.key + "@" }))
        removeStrayPartFiles(keeping: jobs)
        guard !jobs.isEmpty else { return }
        // Resumable ones first: they have bytes on disk already.
        let ordered = jobs.filter { $0.progress != nil } + jobs.filter { $0.progress == nil }
        for job in ordered where !isQueuedOrRunning(job.song.videoId) {
            pending.append(job)
            active[job.song.videoId] = .queued
            session.queued(job.song, from: job.from)
        }
        DebugLog.i("Downloads", "resuming \(pending.count) downloads")
        startWorkers()
    }

    /// Part files no job will resume are what a crash between an abort and its delete leaves.
    private func removeStrayPartFiles(keeping jobs: [DownloadJob]) {
        let directory = library.store.tracksDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) else { return }
        let keep = Set(jobs.compactMap { job in job.progress.map { DownloadStore.partName(for: $0.fileName, token: job.token) } })
        for name in names where name.hasSuffix(".part") && !keep.contains(name) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    /// Stops every job the way the process dying would: nothing is cleaned up, the persisted queue
    /// and part files stay, transfers keep running for the next launch. For tests.
    func simulateTermination() {
        terminated = true
        transport.detachAll()
        monitorTask?.cancel()
        for entry in running.values { entry.task.cancel() }
        let waiters = networkWaiters.values
        networkWaiters.removeAll()
        waiters.forEach { $0.resume() }
        running.removeAll()
        pending.removeAll()
        notifyIfIdle()
    }

    private func notifyIfIdle() {
        guard pending.isEmpty, running.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    // MARK: Errors

    /// A failure a user can read. Errors raised in this module are already written for them;
    /// anything else is a network fault with a class name for a message.
    static func friendly(_ error: Error) -> String {
        if let error = error as? DownloadError { return error.message }
        if let error = error as? OfflinePackageError { return error.message }
        // Named by its fault, not one message for all of them (Android's per-check messages): a
        // reader is acting on the difference between "nothing to connect to" and "timed out".
        if let error = error as? URLError { return "Download failed — \(error.localizedDescription) (\(error.code.rawValue))" }
        if let described = (error as? LocalizedError)?.errorDescription, !described.isBlank { return described }
        return "Download failed — check your connection"
    }
}
