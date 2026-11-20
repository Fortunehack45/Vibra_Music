@preconcurrency import AVFoundation
import Foundation
import VibraMusicCore

/// Serves one custom-scheme asset from the cache, fetching what's missing from its source.
///
/// This is the iOS shape of Android's `CacheDataSource` wrapped around the resolving data source:
/// AVFoundation asks for byte ranges of `vibramusic-cache://…`, and every answer comes off disk,
/// with holes filled from the source as they're reached (and written to disk on the way through).
/// Content information (type, length, byte-range support) comes from the entry's index when the
/// track has been opened before, so a cached track opens with no network at all.
///
/// Retained by its asset (see ``AudioStreamCache/makeAsset(for:source:options:)``), because an
/// `AVAssetResourceLoader` holds its delegate weakly.
///
/// **Network failures.** A hole whose fetch fails for want of a network is retried after each of
/// `retryDelays` before the request is failed, as ExoPlayer's load-error policy retried a failed
/// read. Two cases need it: a connection that drops for a moment mid-track, and AVFoundation's
/// habit of asking for the whole file and cancelling once it has read the header. Offline, with the
/// header cached, failing that request at the first hole fails the asset even though AVFoundation
/// was about to cancel it; waiting gives it the chance to.
final class AudioCacheResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let key: AudioCacheKey
    let source: (any AudioRangeDataSource)?
    let store: AudioCacheStore
    let queue: DispatchQueue
    let retryDelays: [Duration]

    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// The patched opening of a source served without caching (see ``serveDirect(_:from:)``).
    private var directHead: Task<Data, Error>?
    /// The byte ranges AVFoundation asked for and hasn't been handed in full yet.
    private var openReads: [ObjectIdentifier: Range<Int64>] = [:]
    private var hasOpened = false

    init(key: AudioCacheKey, source: (any AudioRangeDataSource)?, store: AudioCacheStore, retryDelays: [Duration] = []) {
        self.key = key
        self.source = source
        self.store = store
        self.retryDelays = retryDelays
        self.queue = DispatchQueue(label: "com.fortune.vibramusic.ios.AudioCache.loader", qos: .userInitiated)
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard loadingRequest.request.url?.scheme == AudioStreamCache.urlScheme else { return false }
        let request = LoadingRequest(loadingRequest, queue: queue)
        let id = ObjectIdentifier(loadingRequest)
        // Registered before the task can finish and unregister itself.
        lock.withLock {
            tasks[id] = Task { [weak self] in
                guard let self else { return }
                await self.serve(request)
                self.lock.withLock { _ = self.tasks.removeValue(forKey: id) }
            }
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let task = lock.withLock { tasks.removeValue(forKey: ObjectIdentifier(loadingRequest)) }
        task?.cancel()
    }

    /// What's on disk and what the player is still waiting on: an end reported with a read open
    /// means AVFoundation didn't wait for it, as no read here ever finishes short.
    func readReport() async -> String {
        let open = lock.withLock { openReads.values.sorted { $0.lowerBound < $1.lowerBound } }
        let disk = AudioCacheStore.merge(await store.spans(of: key))
        return "\(key) on disk \(disk.map { "[\($0.lowerBound),\($0.upperBound))" }.joined(separator: " ")), "
            + "reads open \(open.map { "[\($0.lowerBound),\($0.upperBound))" }.joined(separator: " "))"
    }

    deinit {
        let running = lock.withLock { tasks.values }
        for task in running { task.cancel() }
    }

    // MARK: Serving

    private func serve(_ request: LoadingRequest) async {
        do {
            if let source, !source.isCacheable {
                try await serveDirect(request, from: source)
            } else {
                try await serveCached(request)
            }
            request.finish()
        } catch {
            guard !Task.isCancelled, !AudioCacheStore.isCancellation(error) else { return }
            TrackLog.w(AudioCacheStore.category, "loading \(key) failed", error: error, about: key.trackID)
            request.finish(with: error)
        }
    }
    /// How near the end of a file a read counts as looking for a tag: AVFoundation's reads come in
    /// 64 KB blocks, so this holds the last block however the file's length falls.
    private static let tailProbeBytes: Int64 = 128 * 1_024

    private func serveCached(_ request: LoadingRequest) async throws {
        // The first request is this asset opening; after that it has read the file it holds.
        let opening = lock.withLock {
            defer { hasOpened = true }
            return !hasOpened
        }
        let info = try await TrackLog.about(key.trackID) {
            try await store.contentInfo(for: key, source: source, opening: opening)
        }
        let fullyCached = await store.cachedLength(key, position: 0, length: info.contentLength) >= info.contentLength
        request.answer(info, entireLengthAvailable: fullyCached)
        guard let range = request.dataRange(length: info.contentLength) else { return }
        let read = ObjectIdentifier(request)
        lock.withLock { openReads[read] = range }
        defer { lock.withLock { openReads[read] = nil } }
        do {
            try await serveBytes(range, info: info) { request.respond(with: $0) }
        } catch {
            // A precisely timed FLAC or MP3 won't open until it has looked for a tag at the file's
            // end. With those bytes out of reach (offline, on a copy only partly here), a read that
            // ends short lets it open and play what is here; failing it would fail the asset.
            guard !Task.isCancelled, !AudioCacheStore.isCancellation(error), range.lowerBound > 0,
                  info.contentLength - range.lowerBound <= Self.tailProbeBytes else { throw error }
        }
    }

    /// Hands `range` to `respond` piece by piece: off disk where it's cached, from the source (and
    /// onto disk) where it isn't, retrying a hole the network failed on (see the type's doc).
    func serveBytes(_ range: Range<Int64>, info known: AudioContentInfo? = nil, respond: (Data) -> Void) async throws {
        let info: AudioContentInfo
        if let known {
            info = known
        } else {
            info = try await store.contentInfo(for: key, source: source)
        }
        let range = range.clamped(to: 0..<info.contentLength)
        // Lines name the request's range: AVFoundation often has two requests waiting on the same
        // bytes. They share one fetch (and one retried fetch), but each logs its own retries.
        let request = "\(key) [\(range.lowerBound), \(range.upperBound))"
        var position = range.lowerBound
        var retries = retryDelays[...]
        // Retries since bytes last arrived. Every outage's lines end in one saying how it ended:
        // resumed, cancelled, or given up on.
        var retried = 0
        func arrived() {
            guard retried > 0 else { return }
            TrackLog.d(AudioCacheStore.category, "\(request) resumed at \(position) after \(retried) \(retried == 1 ? "retry" : "retries")", about: key.trackID)
            // Progress earns the full set of retries back: they are for one outage, not a budget
            // for the whole track.
            retries = retryDelays[...]
            retried = 0
        }
        do {
            while position < range.upperBound {
                try Task.checkCancellation()
                if let data = await store.read(key, at: position, maxLength: range.upperBound - position) {
                    arrived()
                    respond(data)
                    position += Int64(data.count)
                    continue
                }
                do {
                    let subscription = try await store.subscribe(key, at: position, wantEnd: range.upperBound, source: source, info: info)
                    do {
                        for try await piece in subscription.stream {
                            arrived()
                            let take = min(Int64(piece.count), range.upperBound - position)
                            respond(take == Int64(piece.count) ? piece : piece.prefix(Int(take)))
                            position += take
                            if position >= range.upperBound { break }
                        }
                    } catch {
                        await store.release(subscription, cancelled: Task.isCancelled)
                        throw error
                    }
                    await store.release(subscription, cancelled: Task.isCancelled)
                } catch {
                    guard Self.isTransientNetworkError(error), let delay = retries.popFirst() else { throw error }
                    retried += 1
                    TrackLog.d(AudioCacheStore.category, "\(request) at \(position): \(error.localizedDescription); retry \(retried) of \(retried + retries.count) in \(delay)", about: key.trackID)
                    try await Task.sleep(for: delay)
                }
            }
        } catch {
            if Task.isCancelled || AudioCacheStore.isCancellation(error) {
                // A skip, a seek, or the asset let go: nobody wants the bytes any more.
                if retried > 0 {
                    TrackLog.d(AudioCacheStore.category, "\(request) at \(position): cancelled while retrying", about: key.trackID)
                }
            } else if retried > 0 || Self.isTransientNetworkError(error) {
                TrackLog.w(AudioCacheStore.category, "\(request) gave up at \(position) after \(retried) \(retried == 1 ? "retry" : "retries")", error: error, about: key.trackID)
            }
            throw error
        }
    }

    /// Gets `ahead` seconds' worth of bytes onto disk, from the first hole around `seconds` into a
    /// resource `length` seconds long. For a player that has run out and may not read on by itself:
    /// the cache is filled whether it does or not, joining any fetch already bringing those bytes, so
    /// none comes twice. Bytes are placed by the average bitrate, so the search starts `ahead` before
    /// the playhead: a louder opening puts the real position behind the estimate.
    ///
    /// Throws what the reads throw once their retries are spent, and `URLError(.timedOut)` when
    /// nothing has arrived for `stallLimit`: a link that hangs ends rather than leaving a wait open.
    func fetchAhead(at seconds: TimeInterval, of length: TimeInterval, ahead: TimeInterval, stallLimit: Duration) async throws {
        guard let source, source.isCacheable, length > 0 else { return }
        let info = try await store.contentInfo(for: key, source: source)
        let total = info.contentLength
        let perSecond = Double(total) / length
        let from = min(total, max(0, Int64((seconds - ahead) * perSecond)))
        let cachedRun = await store.cachedLength(key, position: from, length: total - from)
        let start = from + max(0, cachedRun)
        let range = start..<min(total, start + Int64(ahead * perSecond))
        guard !range.isEmpty else { return }
        let arrival = LastArrival()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.serveBytes(range, info: info) { _ in arrival.mark() } }
            group.addTask {
                while true {
                    try await Task.sleep(for: min(stallLimit, .seconds(1)))
                    if arrival.elapsed >= stallLimit { throw URLError(.timedOut) }
                }
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    /// Errors that say the network is (for now) not there, as opposed to a server's answer.
    static func isTransientNetworkError(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff,
             .callIsActive, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    /// A source not worth caching (a file already on this device): answered straight from it.
    private func serveDirect(_ request: LoadingRequest, from source: any AudioRangeDataSource) async throws {
        var info = try await source.contentInfo()
        if info.contentType == nil {
            if let type = AudioContentType.uti(mimeType: info.mimeType) {
                info.contentType = type
            } else {
                let prefix = try await source.read(0..<min(16, info.contentLength))
                info.contentType = AudioContentType.sniff(prefix) ?? AudioContentType.mpeg4Audio
            }
        }
        request.answer(info, entireLengthAvailable: true)
        guard let range = request.dataRange(length: info.contentLength) else { return }
        var position = range.lowerBound
        // The opening goes out patched for a YouTube stream, as a cached copy's would (see
        // FragmentedMP4Durations): a downloaded YouTube file is the same fragmented MP4. Anything
        // else goes out byte-identical.
        let head = try await patchedHead(of: source, length: info.contentLength)
        if position < Int64(head.count) {
            let end = min(range.upperBound, Int64(head.count))
            request.respond(with: head.subdata(in: Int(position)..<Int(end)))
            position = end
        }
        let step = max(1, min(source.maxRangeBytes, AudioCacheStore.readPieceBytes * 4))
        while position < range.upperBound {
            try Task.checkCancellation()
            let end = min(range.upperBound, position + step)
            let data = try await source.read(position..<end)
            guard !data.isEmpty else { throw AudioCacheError.unexpectedEndOfStream(key: key, position: position) }
            request.respond(with: data)
            position += Int64(data.count)
        }
    }

    /// The opening of the source up to the end of its init segment, durations fixed for a YouTube
    /// stream (or, for anything else, whatever of the opening was read to find that out). Read
    /// once per asset, however many requests start inside it.
    private func patchedHead(of source: any AudioRangeDataSource, length: Int64) async throws -> Data {
        let task: Task<Data, Error> = lock.withLock {
            if let directHead { return directHead }
            let task = Task {
                var gate = InitSegmentGate()
                var position: Int64 = 0
                let limit = min(length, Int64(FragmentedMP4Durations.maxInitSegmentBytes))
                while position < limit {
                    let end = min(limit, position + max(1, min(source.maxRangeBytes, 64 * 1_024)))
                    let piece = try await source.read(position..<end)
                    guard !piece.isEmpty else { break }
                    position += Int64(piece.count)
                    // Released as soon as it's decided: patched, or the plain opening read so far.
                    let patch: (inout Data) -> Int = source.requiresYouTubeDurationFix
                        ? FragmentedMP4Durations.patchYouTubeInitSegment : { _ in 0 }
                    if let released = gate.feed(piece, patch: patch) { return released }
                }
                return gate.release()
            }
            directHead = task
            return task
        }
        return try await task.value
    }
}

/// When bytes last arrived for a ``AudioCacheResourceLoader/fetchAhead(at:of:ahead:stallLimit:)``.
private final class LastArrival: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ContinuousClock.now

    func mark() { lock.withLock { last = .now } }
    var elapsed: Duration { lock.withLock { last.duration(to: .now) } }
}

/// An `AVAssetResourceLoadingRequest` handed across tasks. Every call on it is made on the
/// loader's serial queue, in the order the serving task issued them.
private final class LoadingRequest: @unchecked Sendable {
    private let request: AVAssetResourceLoadingRequest
    private let queue: DispatchQueue

    init(_ request: AVAssetResourceLoadingRequest, queue: DispatchQueue) {
        self.request = request
        self.queue = queue
    }

    /// The byte range the data request wants, clamped to the resource; nil without a data request.
    func dataRange(length: Int64) -> Range<Int64>? {
        guard let dataRequest = request.dataRequest else { return nil }
        let start = max(0, dataRequest.requestedOffset)
        let end = dataRequest.requestsAllDataToEndOfResource
            ? length
            : min(length, start + Int64(dataRequest.requestedLength))
        return start < end ? start..<end : nil
    }

    func answer(_ info: AudioContentInfo, entireLengthAvailable: Bool) {
        queue.async { [request] in
            guard let content = request.contentInformationRequest else { return }
            content.contentType = info.contentType ?? AudioContentType.mpeg4Audio
            content.contentLength = info.contentLength
            content.isByteRangeAccessSupported = true
            content.isEntireLengthAvailableOnDemand = entireLengthAvailable
        }
    }

    func respond(with data: Data) {
        queue.async { [request] in
            guard !request.isCancelled, !request.isFinished else { return }
            request.dataRequest?.respond(with: data)
        }
    }

    func finish() {
        queue.async { [request] in
            guard !request.isCancelled, !request.isFinished else { return }
            request.finishLoading()
        }
    }

    func finish(with error: Error) {
        queue.async { [request] in
            guard !request.isCancelled, !request.isFinished else { return }
            request.finishLoading(with: error)
        }
    }
}

