import Foundation

/// Reads from a URL before trusting it. Port of `StreamResolver.probe`.
///
/// This is the whole difference between a track that fails and a track that fails *visibly and
/// instantly*. A URL that 403s is indistinguishable from a good one until something reads from
/// it; handed to AVPlayer, the failure surfaces as a track that spins and never starts.
///
/// The range has to be as large as the real fetch will ask for, not a token one: a URL minted
/// for a session Google has reservations about serves small ranges to anybody and then refuses
/// the multi-megabyte ranges listening is made of. It starts past the first megabyte when the
/// file is that long, because some clients' URLs serve the opening and 403 everything after —
/// measured today for ANDROID_VR, whose URLs stop at about a minute of audio. Sixteen kilobytes
/// of the answer still have to actually arrive, so a response that stalls after its headers is
/// a failure too. The headers are the ones the media fetch will really use.
struct StreamURLProbe: Sendable {
    enum Verdict: Equatable, Sendable {
        /// Served media bytes; safe to play and to cache.
        case ok
        /// Answered, but refused this request — the client is the problem.
        case refused
        /// Never got an answer worth interpreting; blame nothing in particular.
        case unreachable
    }

    let session: URLSession
    /// Short, because waiting out a long timeout is indistinguishable from the stall being tested for.
    var timeout: TimeInterval = 6

    /// Where googlevideo stops authorising some clients' URLs (InnerTubeX: "CDN 403 after 1 MiB").
    static let authBoundaryBytes: Int64 = 1024 * 1024
    /// How much of the answer must actually arrive, to catch a stalled body.
    static let readBytes: Int64 = 16 * 1024
    static let refusalCodes: Set<Int> = [403, 404, 410]

    /// The byte range the probe asks for: past the auth boundary when the file is long enough,
    /// and as wide as one real range request for this client.
    static func probeRange(for url: URL) -> ClosedRange<Int64> {
        let length = url.streamQueryValue("clen").flatMap { Int64($0) }
        let start: Int64 = (length.map { $0 > authBoundaryBytes + readBytes } ?? false) ? authBoundaryBytes : 0
        let chunk = StreamPlayerClient.rangeBytes(for: url)
        let (sum, overflow) = start.addingReportingOverflow(chunk)
        let limit = overflow ? Int64.max : sum
        let end = min(limit, length ?? Int64.max) - 1
        return start...max(start, end)
    }

    func probe(_ url: URL, headers: [String: String]) async -> Verdict {
        let range = Self.probeRange(for: url)
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = timeout
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        let session = self.session
        let timeout = self.timeout

        return await withTaskGroup(of: Verdict?.self) { group in
            group.addTask { await Self.read(request, session: session) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            guard let verdict = first else {
                streamLog.warning("probe timed out after \(timeout, privacy: .public)s")
                return .unreachable
            }
            return verdict
        }
    }

    private static func read(_ request: URLRequest, session: URLSession) async -> Verdict {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            let code = http.statusCode
            if refusalCodes.contains(code) { return .refused }
            if !(200...299).contains(code) && code != 416 { return .unreachable }
            // A refusal dressed as a success: an error page, or the consent/captcha
            // interstitial, rather than audio.
            let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            if !type.hasPrefix("audio/") { return .refused }
            // Headers can arrive long before a body that never does. Insisting on the bytes is
            // the point: a trickle that yields its first byte and stalls is a failure too.
            var received: Int64 = 0
            for try await _ in bytes {
                received += 1
                if received >= readBytes { return .ok }
            }
            return .unreachable
        } catch {
            if !(error is CancellationError) {
                streamLog.warning("probe failed: \(error.localizedDescription, privacy: .public)")
            }
            return .unreachable
        }
    }
}
