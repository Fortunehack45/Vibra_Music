import Foundation
import VibraMusicCore

// Ports download/Downloader.kt, plus the fetching half of OfflineHls.kt / OfflineDash.kt.

/// What a transfer reports back to the queue while it runs. Everything here is called from the
/// transfer's own task and must not block.
struct TransferHooks: Sendable {
    /// Holds until the Wi-Fi-only policy allows the current connection (returns at once otherwise).
    let waitForNetwork: @Sendable () async throws -> Void
    /// Whether requests may use expensive/constrained networks right now (false under Wi-Fi only).
    let allowsMeteredNetwork: @Sendable () async -> Bool
    /// Bytes (or segments) done so far, and the total.
    let progress: @Sendable (_ done: Int64, _ total: Int64) -> Void
    /// A durable point to resume from after a relaunch; persisted by the queue.
    let checkpoint: @Sendable (TransferCheckpoint) async -> Void
    /// Resolves the track again, at the same request as the first time.
    let reresolve: @Sendable () async throws -> ResolvedStream
    /// Tells the resolver a URL it handed over has been refused mid-download.
    var refused: @Sendable (_ url: URL, _ statusCode: Int) async -> Void = { _, _ in }
}

/// Where a transfer had got to, as much as a relaunch needs to carry on from there.
struct TransferCheckpoint: Codable, Hashable, Sendable {
    /// Bytes in the part file that are known good.
    var written: Int64
    /// The stream currently being read (it changes after a re-resolve).
    var stream: ResolvedStream
    /// Whether the one re-resolve a refusal is allowed has been spent.
    var reresolved: Bool
    /// Packages: the next segment to fetch, and every segment URL (init first).
    var nextSegment: Int = 0
    var segments: [URL]? = nil
}

/// What a probe of a source URL found at the front of the file (Android `isDirectAudioFile`).
enum ProbedContainer: Equatable {
    case hlsPlaylist
    case dashManifest
    case flac
    case mp4
    case mp3
    case wav
    /// Bytes arrived but nothing here recognises them.
    case unknown
    /// The server refused the probe.
    case refused(status: Int)
}

/// Pulls a resolved stream onto disk.
///
/// Two things are not obvious and both are load-bearing (from the Android original):
///
/// - **Bounded ranges, not one long GET, for googlevideo.** googlevideo paces a continuous response
///   down to roughly playback speed — about 15 kB/s against 5.7 MB/s for the same bytes asked for
///   as ranges. So YouTube audio is fetched as a run of ranged requests, each one its own download
///   task (which also makes each a resumable unit: a relaunch picks up at the last whole range).
/// - **The client's own headers.** googlevideo compares the identity baked into a URL (`c=`,
///   `cver=`) against the request that comes back for the bytes, and anything else is a 403. The
///   resolver hands those headers over as ``ResolvedStream/headers``; every request carries them.
///
/// Sequential rather than parallel within a track: ranges are served at line rate and splitting a
/// four-megabyte track across connections buys nothing a user could perceive.
///
/// None of that is true of a stream from a configured source, which is what ``fetchDirect`` is for.
struct Downloader: Sendable {
    let transport: any DownloadTransport
    /// For the small requests — length probes, container sniffing, manifests — that aren't worth a
    /// background task.
    let http: URLSession
    /// The largest range asked for at once; matches the read-ahead size. Large enough to amortise,
    /// small enough to cancel promptly.
    let chunkBytes: Int64
    /// Waits between attempts at one request after a transient network failure.
    let retryDelays: [Double]
    /// The text of a playlist that lives on this device rather than on a server: a source's DASH
    /// manifest is converted to an HLS playlist under an app-private scheme for the player, and
    /// URLSession can't fetch that scheme ("unsupported URL", -1002). Nil for any other URL.
    var localPlaylist: (@Sendable (URL) -> String?)?

    static let refusalCodes: Set<Int> = [403, 404, 410]

    // MARK: Progressive, ranged (googlevideo)

    /// Fetches `stream` into `part` from `checkpoint.written` onwards, as bounded ranges.
    ///
    /// - Parameter total: how many bytes the whole track is; see ``contentLength(of:)``.
    /// - Returns: how many bytes the part file holds when done.
    func fetchRanged(
        jobKey: String,
        part: URL,
        total: Int64,
        from checkpoint: TransferCheckpoint,
        hooks: TransferHooks
    ) async throws -> Int64 {
        var state = checkpoint
        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(state.written))

        while state.written < total {
            try Task.checkCancellation()
            try await hooks.waitForNetwork()

            // A URL that sat out a long Wi-Fi wait, or a relaunch days later, has expired: resolve
            // again before asking, and hold the new stream to the same length.
            if state.stream.isExpired() {
                let fresh = try await hooks.reresolve()
                guard try await contentLength(of: fresh) == total else {
                    throw DownloadError("The stream changed mid-download — try again")
                }
                state.stream = fresh
            }

            let url = state.stream.url
            let length = min(chunkBytes, Self.rangeBytes(for: url), total - state.written)
            var request = URLRequest(url: url)
            for (name, value) in state.stream.headers { request.setValue(value, forHTTPHeaderField: name) }
            request.setValue("bytes=\(state.written)-\(state.written + length - 1)", forHTTPHeaderField: "Range")
            let base = state.written
            let result = try await transfer(request, key: "\(jobKey)@\(state.written)", hooks: hooks) { received, _ in
                hooks.progress(base + min(received, length), total)
            }
            defer { try? FileManager.default.removeItem(at: result.fileURL) }
            // The range's own status in the shareable log (what was *requested*; a stopped-short
            // range is asked for again from where it truly stopped): a paste then shows where
            // the transfer got to and what the server said, not just the row's one-line verdict.
            TrackLog.d("Downloads", "range \(base)+\(length) requested: HTTP \(result.statusCode)")

            // A URL that served its opening and then refuses is the one failure worth a second
            // attempt: the identity behind it was stood down mid-download, not the track gone.
            if Self.refusalCodes.contains(result.statusCode) {
                // Told first, whether or not a retry is left: it is what stops the next track, or
                // this one's second attempt, being handed the same identity.
                await hooks.refused(url, result.statusCode)
                if state.reresolved {
                    throw DownloadError("Download refused after \(state.written)B (HTTP \(result.statusCode))")
                }
                state.reresolved = true
                TrackLog.w("Downloads", "re-resolving \(jobKey) after HTTP \(result.statusCode) at \(state.written)")
                let fresh = try await hooks.reresolve()
                // Resolving again can land on a different format. Resuming one stream into the
                // middle of another produces a file that is the right length and unplayable, so a
                // length that has moved is a failure rather than something to work around.
                guard try await contentLength(of: fresh) == total else {
                    throw DownloadError("The stream changed mid-download — try again")
                }
                state.stream = fresh
                await hooks.checkpoint(state)
                continue
            }
            guard (200..<300).contains(result.statusCode) else {
                throw DownloadError("Download failed (HTTP \(result.statusCode))")
            }
            // A server that ignores Range answers 200 with the whole file. From the start that is
            // simply the file; anywhere else it would splice the opening into the middle.
            let limit: Int64
            if result.statusCode == 200 {
                guard state.written == 0 else { throw DownloadError("The server ignored the requested range — try again") }
                limit = total
            } else {
                limit = length
            }
            let appended = try Self.append(result.fileURL, to: handle, limit: limit)
            // A range that stops short is not fatal — the next pass asks for what is left — but one
            // that yields nothing at all would loop here forever.
            guard appended > 0 else { throw DownloadError("Download stalled at \(state.written)B") }
            state.written += appended
            hooks.progress(state.written, total)
            await hooks.checkpoint(state)
        }
        try handle.synchronize()
        return state.written
    }

    /// How many bytes the whole track is.
    ///
    /// Every progressive googlevideo URL carries it as `clen`, which costs no request at all; a
    /// resolver may state it too. The `bytes=0-0` probe behind those is for the URLs that don't, and
    /// reads the total out of the `Content-Range` header of a one-byte response.
    func contentLength(of stream: ResolvedStream) async throws -> Int64? {
        if let clen = URLComponents(url: stream.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "clen" })?.value.flatMap({ Int64($0) }), clen > 0 {
            return clen
        }
        if let stated = stream.contentLength, stated > 0 { return stated }
        var request = URLRequest(url: stream.url)
        for (name, value) in stream.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        do {
            let (_, response) = try await http.data(for: request)
            let range = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range")
            guard let total = range?.split(separator: "/").last.flatMap({ Int64($0) }), total > 0 else { return nil }
            return total
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            DebugLog.w("Downloads", "could not measure the track", error: error)
            return nil
        }
    }

    /// The largest single range googlevideo reliably serves for `url`'s client (Android
    /// `PlayerClient.rangeBytesFor`): half a megabyte for ANDROID_VR and TVHTML5_SIMPLY URLs, a
    /// megabyte for the rest, and no limit off googlevideo.
    static func rangeBytes(for url: URL) -> Int64 {
        guard isGoogleVideo(url) else { return .max }
        let client = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "c" })?.value?.uppercased()
        if client == "ANDROID_VR" || client?.hasPrefix("TVHTML5_SIMPLY") == true { return 512 * 1024 }
        return 1024 * 1024
    }

    static func isGoogleVideo(_ url: URL) -> Bool {
        url.host()?.lowercased().hasSuffix("googlevideo.com") == true
    }

    // MARK: Progressive, one GET (sources)

    /// Fetches `url` into `part` in one GET, for a stream that isn't googlevideo's.
    ///
    /// Deliberately not a parameterised ``fetchRanged``: the chunk loop exists to defeat googlevideo's
    /// pacing and nothing else paces bytes that way, while a server that ignores `Range` would have
    /// that loop write the opening of the file into the middle. There is no re-resolve on a refusal
    /// either: a source's URL that stops working has a server behind it with its own reasons.
    ///
    /// - Returns: how many bytes were written.
    func fetchDirect(jobKey: String, stream: ResolvedStream, part: URL, hooks: TransferHooks) async throws -> Int64 {
        try await hooks.waitForNetwork()
        var request = URLRequest(url: stream.url)
        for (name, value) in stream.headers { request.setValue(value, forHTTPHeaderField: name) }
        let result = try await transfer(request, key: "\(jobKey)@direct", hooks: hooks) { received, expected in
            // Only with a stated length to measure against: an unstated one leaves the progress
            // indeterminate rather than dividing by zero.
            if let expected { hooks.progress(received, expected) }
        }
        defer { try? FileManager.default.removeItem(at: result.fileURL) }
        guard (200..<300).contains(result.statusCode) else {
            throw DownloadError("Download failed (HTTP \(result.statusCode))")
        }
        // A captive portal answers a plain-HTTP source with its sign-in page, a 200 that passes
        // every other check here. Saved, it became a finished track that can't play.
        if Self.isWebPage(contentType: result.header("Content-Type"), file: result.fileURL) {
            throw DownloadError("The network sent a web page, not the song. Sign in to the Wi-Fi, then try again")
        }
        let total = result.header("Content-Length").flatMap { Int64($0) }.flatMap { $0 > 0 ? $0 : nil }
        let written = result.byteCount
        // A stated length that didn't all arrive: nothing threw, so committing would publish a file
        // that looks whole and stops halfway through the song.
        if let total, written < total {
            throw DownloadError("Download stopped at \(written)B of \(total) — try again")
        }
        guard written > 0 else { throw DownloadError("Download failed: nothing was sent") }
        try? FileManager.default.removeItem(at: part)
        try FileManager.default.moveItem(at: result.fileURL, to: part)
        hooks.progress(written, written)
        return written
    }

    /// Whether a downloaded body is a web page (a captive portal's) rather than media: by its type,
    /// or, when that is missing or wrong, by its first byte. No audio file opens with `<` (ID3,
    /// an MPEG frame, `fLaC`, `RIFF`, an MP4 box size), and every page or XML document does.
    static func isWebPage(contentType: String?, file: URL) -> Bool {
        let type = contentType?.lowercased() ?? ""
        if type.hasPrefix("text/html") || type.hasPrefix("application/xhtml") { return true }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 64)) ?? Data(), as: UTF8.self)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        return head.hasPrefix("<")
    }

    /// Looks at the first bytes of a source URL before it is allowed to become a download route.
    ///
    /// Some module backends label an HLS master playlist as FLAC; downloading that text faithfully
    /// produces a tiny `.flac` no player can open. On Android a mismatch sent the download to YouTube
    /// instead; on iOS the resolver has already made that choice, so the probe decides how to save
    /// what the URL really is (``DownloadManager`` routes a sniffed playlist to the package saver).
    func probe(_ stream: ResolvedStream) async throws -> ProbedContainer {
        var request = URLRequest(url: stream.url)
        for (name, value) in stream.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=0-31", forHTTPHeaderField: "Range")
        // Streamed, not `data(for:)`: a server that ignores the Range sends the whole track, and
        // only the first 32 bytes are wanted.
        let (bytes, response) = try await http.bytes(for: request)
        defer { bytes.task.cancel() }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { return .refused(status: status) }
        let type = ((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if type.contains("mpegurl") { return .hlsPlaylist }
        if type.contains("dash+xml") { return .dashManifest }
        var head = Data()
        for try await byte in bytes {
            head.append(byte)
            if head.count == 32 { break }
        }
        return Self.sniff(head)
    }

    static func sniff(_ head: Data) -> ProbedContainer {
        let bytes = [UInt8](head)
        func starts(_ text: String) -> Bool { bytes.starts(with: Array(text.utf8)) }
        let trimmed = Array(bytes.drop { $0 == 0xEF || $0 == 0xBB || $0 == 0xBF || $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 })
        if starts("#EXTM3U") { return .hlsPlaylist }
        if trimmed.starts(with: Array("<?xml".utf8)) || trimmed.starts(with: Array("<MPD".utf8)) { return .dashManifest }
        if starts("fLaC") { return .flac }
        if bytes.count >= 8, Array(bytes[4..<8]) == Array("ftyp".utf8) { return .mp4 }
        if starts("RIFF") { return .wav }
        if starts("ID3") || (bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0) { return .mp3 }
        return bytes.isEmpty ? .refused(status: 0) : .unknown
    }

    // MARK: Offline packages (HLS / DASH)

    /// The segment list for a manifest, init segment first.
    func packageSegments(_ stream: ResolvedStream, dash: Bool) async throws -> [URL] {
        if dash {
            let manifest = try await text(stream.url, headers: stream.headers, what: "DASH manifest")
            let plan = try OfflineDash.parse(manifest)
            return try ([plan.initialization] + plan.media).map { remote in
                guard let url = URL(string: remote, relativeTo: stream.url)?.absoluteURL else {
                    throw OfflinePackageError("Invalid DASH segment")
                }
                return url
            }
        }
        var playlistURL = stream.url
        // One level of indirection at most: a master playlist names media playlists.
        for _ in 0..<2 {
            let playlist = try await text(playlistURL, headers: stream.headers, what: "HLS playlist")
            // Segments cut out of one file by byte range: the saver fetches whole URLs, so it
            // would write the same media many times over. Refused rather than saved wrong.
            if playlist.range(of: "BYTERANGE", options: .caseInsensitive) != nil {
                throw OfflinePackageError("Byte-range playlists cannot be saved")
            }
            switch try OfflineHls.parse(playlist, base: playlistURL) {
            case .segments(let urls): return urls
            case .variant(let next): playlistURL = next
            }
        }
        throw OfflinePackageError("HLS playlist has no fragments")
    }

    /// Fetches every segment from `checkpoint.nextSegment` on and appends it to `part`, flattened
    /// into one fragmented MP4 — see ``OfflineDash`` for why iOS saves packages that way.
    func fetchPackage(jobKey: String, part: URL, dash: Bool, from checkpoint: TransferCheckpoint, hooks: TransferHooks) async throws {
        var state = checkpoint
        guard let segments = state.segments, !segments.isEmpty else { throw OfflinePackageError("HLS playlist has no fragments") }
        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(state.written))
        let count = Int64(segments.count)

        while state.nextSegment < segments.count {
            try Task.checkCancellation()
            try await hooks.waitForNetwork()
            let index = state.nextSegment
            var request = URLRequest(url: segments[index])
            for (name, value) in state.stream.headers { request.setValue(value, forHTTPHeaderField: name) }
            let result = try await transfer(request, key: "\(jobKey)@seg\(index)", hooks: hooks, progress: nil)
            defer { try? FileManager.default.removeItem(at: result.fileURL) }
            guard (200..<300).contains(result.statusCode) else {
                throw OfflinePackageError(dash
                    ? "DASH segment failed (HTTP \(result.statusCode))"
                    : "HLS fragment failed (HTTP \(result.statusCode))")
            }
            let body = try Data(contentsOf: result.fileURL)
            guard !body.isEmpty else { throw OfflinePackageError("Empty segment") }
            let flattened = try Self.flatten(body, isInitialization: index == 0)
            try handle.write(contentsOf: flattened)
            state.written += Int64(flattened.count)
            state.nextSegment = index + 1
            hooks.progress(Int64(state.nextSegment), count)
            await hooks.checkpoint(state)
        }
        try handle.synchronize()
    }

    /// The bytes of one segment that belong in a single fragmented MP4.
    ///
    /// The initialisation segment goes in whole (`ftyp` + `moov`). A media segment contributes only
    /// its `moof`/`mdat` pairs: `styp` and `sidx` describe the segment as a separate file and mean
    /// nothing mid-stream. Sample offsets inside a `moof` are relative to it (CMAF requires
    /// default-base-is-moof), so the pairs are position-independent and concatenate cleanly.
    static func flatten(_ segment: Data, isInitialization: Bool) throws -> Data {
        let bytes = [UInt8](segment)
        if bytes.first == 0x47 {
            // MPEG-TS sync byte: AVPlayer won't open concatenated TS from disk.
            throw OfflinePackageError("This stream's format can't be saved on this device")
        }
        let boxes = Mp4Tagger.parseBoxes(bytes, 0, bytes.count)
        if isInitialization {
            guard boxes.contains(where: { $0.type == "moov" }) else {
                throw OfflinePackageError("This stream's format can't be saved on this device")
            }
            return segment
        }
        var out = Data()
        for box in boxes where box.type == "moof" || box.type == "mdat" {
            out.append(contentsOf: bytes[box.offset..<box.end])
        }
        guard !out.isEmpty else { throw OfflinePackageError("This stream's format can't be saved on this device") }
        return out
    }

    private func text(_ url: URL, headers: [String: String], what: String) async throws -> String {
        if let local = localPlaylist?(url) { return local }
        // Nothing but http(s) can be fetched: said plainly rather than as URLSession's -1002.
        guard ["http", "https"].contains(url.scheme?.lowercased()) else {
            throw OfflinePackageError("This stream's playlist can't be read on this device — try again")
        }
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await http.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw OfflinePackageError("\(what) failed (HTTP \(status))") }
        guard !data.isEmpty else { throw OfflinePackageError("Empty \(what)") }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: One request, with the waits it deserves

    /// One transfer, retried after transient network failures, and held (not counted as a failure)
    /// while the Wi-Fi-only policy keeps it off the current connection.
    private func transfer(
        _ base: URLRequest,
        key: String,
        hooks: TransferHooks,
        progress: (@Sendable (Int64, Int64?) -> Void)?
    ) async throws -> TransportResult {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            var request = base
            let metered = await hooks.allowsMeteredNetwork()
            request.allowsExpensiveNetworkAccess = metered
            request.allowsConstrainedNetworkAccess = metered
            do {
                return try await transport.download(request, key: key, progress: progress)
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as URLError where error.networkUnavailableReason != nil {
                // Refused a metered network under Wi-Fi only: wait for one that's allowed. The pause
                // keeps this from spinning if the system and the monitor briefly disagree.
                try await Task.sleep(for: .seconds(1))
                try await hooks.waitForNetwork()
            } catch let error as URLError where Self.isTransient(error) && attempt < retryDelays.count {
                let delay = retryDelays[attempt]
                attempt += 1
                DebugLog.d("Downloads", "retrying \(key) in \(delay)s after \(error.code.rawValue)")
                try await Task.sleep(for: .seconds(delay))
                try await hooks.waitForNetwork()
            }
        }
    }

    static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed,
             .secureConnectionFailed, .backgroundSessionWasDisconnected:
            return true
        default:
            return false
        }
    }

    /// Appends up to `limit` bytes of `file` to `handle`, in 64 kB reads.
    static func append(_ file: URL, to handle: FileHandle, limit: Int64) throws -> Int64 {
        let source = try FileHandle(forReadingFrom: file)
        defer { try? source.close() }
        var copied: Int64 = 0
        while copied < limit {
            let wanted = Int(min(Int64(64 * 1024), limit - copied))
            guard let chunk = try source.read(upToCount: wanted), !chunk.isEmpty else { break }
            try handle.write(contentsOf: chunk)
            copied += Int64(chunk.count)
        }
        return copied
    }
}
