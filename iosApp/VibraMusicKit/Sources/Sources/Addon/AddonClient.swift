import Foundation
import VibraMusicCore

// Ports data/sources/addon/AddonClient.kt.

/// Why an addon call didn't produce an answer. The split mirrors ``SourceHealth``: a rejection is
/// something retrying won't fix, unavailability is a server having a bad minute, and not-found is
/// the protocol's way of saying "I don't hold that" — a miss, not a fault.
public enum AddonError: LocalizedError, Hashable, Sendable {
    /// Android `AddonException`: the addon or its URL is wrong in a way retrying won't fix.
    case rejected(String)
    /// Android `AddonUnavailable`: down, overloaded, rate limiting. Worth asking again next track.
    case unavailable(String)
    /// Android `AddonNotFound`: the addon answered and does not have what was asked for.
    case notFound

    public var errorDescription: String? {
        switch self {
        case .rejected(let reason), .unavailable(let reason): return reason
        case .notFound: return "Not held by this addon"
        }
    }
}

/// One addon server, and every question the app knows how to ask it.
///
/// Three endpoints, all GETs returning JSON. One instance is held per configured source, so the
/// manifest and the answers shaped by it survive across tracks; everything goes through
/// ``SharedCalls`` so a caller that gives up (the resolver races sources and cancels the losers)
/// doesn't waste a request that already reached somebody's server.
final class AddonClient: @unchecked Sendable {
    /// Where this addon lives, with `/manifest.json` and trailing slashes off.
    let baseUrl: String

    private let session: URLSession
    private let atmosWanted: @Sendable () async -> Bool
    private let manifests: SharedCalls<AddonManifest>
    private let searches: SharedCalls<AddonSearchResponse>
    private let streams: SharedCalls<AddonStream>

    /// When this addon may be spoken to again after a 429. Per instance, not per request: a 429 is
    /// a statement about the server, so a search drawing one holds back the stream lookup queued
    /// behind it too, and the addon gets the quiet it asked for.
    private let quietLock = NSLock()
    private var quietUntil: Date = .distantPast
    /// The derived request parameters, per tier, with when they were derived. See `settings(for:)`.
    private var settingsMemo: [String: (at: Date, params: [(String, String)])] = [:]
    /// Long enough to cover one resolve's burst of settings calls, short enough that a fresh
    /// manifest (new TTL) is picked up on the very next look.
    private static let settingsMemoLifetime: TimeInterval = 1

    init(
        baseUrl rawBaseUrl: String,
        session: URLSession,
        atmosWanted: @escaping @Sendable () async -> Bool
    ) {
        baseUrl = Self.normalizeBase(rawBaseUrl)
        self.session = session
        self.atmosWanted = atmosWanted
        let log: @Sendable (String) -> Void = { SourcesLog.d($0) }
        manifests = SharedCalls(ttl: Self.manifestTTL, log: log)
        searches = SharedCalls(ttl: Self.searchTTL, log: log)
        streams = SharedCalls(ttl: Self.streamTTL, log: log)
    }

    // MARK: Manifest

    /// What the addon says it is, or a failure explaining why it can't be used.
    ///
    /// Strict about two things: an addon with no `id` can't be stored or told apart from another,
    /// and one that can't be searched can't take a track from a query to audio. Failing here means
    /// the Sources screen can say so while the user is still looking at the URL they pasted.
    func manifest() async -> Result<AddonManifest, Error> {
        let base = baseUrl
        return await manifests.get(base, describe: { "▶ addon manifest(\(Self.redact(base)))" }) { [self] in
            let fetched: Result<AddonManifest, Error> = await fetch(Self.manifestURL(base), as: AddonManifest.self)
            switch fetched {
            case .success(let manifest):
                if manifest.id.nonBlank == nil {
                    return .failure(AddonError.rejected("That URL answered, but not with an addon manifest"))
                }
                if !manifest.isPlayable {
                    let declared = manifest.resources.joined(separator: ", ")
                    return .failure(AddonError.rejected("This addon declares \(declared) — Vibra Music needs search"))
                }
                return .success(manifest)
            case .failure(AddonError.notFound):
                // A manifest 404 is not "no such track", it is "no addon here".
                return .failure(AddonError.rejected("No manifest at that URL"))
            case .failure(let error):
                return .failure(error)
            }
        }
    }

    /// Whether `/search` answers, asked without reference to a manifest — the second opinion for
    /// an addon that never published one. Returns the row count; zero is a success.
    func probeSearch() async -> Result<Int, Error> {
        guard let url = endpoint(["search"], [("q", Self.probeQuery)]) else {
            return .failure(AddonError.rejected("That is not a usable address"))
        }
        return await fetch(url, as: AddonSearchResponse.self).map(\.tracks.count)
    }

    // MARK: Search and stream

    /// Tracks the addon holds for `query`. The protocol has no limit parameter; trimming is the
    /// caller's job.
    func search(_ query: String, tier: String) async -> Result<[AddonTrack], Error> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .success([]) }
        let params = await settings(for: tier)
        guard let url = endpoint(["search"], params + [("q", trimmed)]) else {
            return .failure(AddonError.rejected("That is not a usable address"))
        }
        let base = baseUrl
        // The parameters are in the key because they are in the request: the same query at a
        // different quality is a different question.
        return await searches.get(
            sharedCallKey(trimmed, Self.describe(params)),
            describe: { "▶ addon search(\(Self.redact(base))) q=\"\(trimmed)\" tier=\(tier)" }
        ) { [self] in
            await fetch(url, as: AddonSearchResponse.self)
        }.map(\.tracks)
    }

    /// A playable URL for one of this addon's own track ids. The id goes in as one path segment, so
    /// an id holding `/` or `?` can't rewrite the request into another endpoint.
    func stream(_ trackId: String, tier: String) async -> Result<AddonStream, Error> {
        let params = await settings(for: tier)
        guard let url = endpoint(["stream", trackId], params) else {
            return .failure(AddonError.rejected("That is not a usable address"))
        }
        let base = baseUrl
        return await streams.get(
            sharedCallKey(trackId, Self.describe(params)),
            describe: { "▶ addon stream(\(Self.redact(base))) id=\(trackId) tier=\(tier)" }
        ) { [self] in
            await fetch(url, as: AddonStream.self)
        }
    }

    // MARK: Settings passthrough

    /// The query parameters that travel with every request.
    ///
    /// The addon's declared defaults go on first, because that is what the reference host sends
    /// when the user changed nothing. Then `quality` is set to what is actually being asked for,
    /// negotiated against the addon's own option list when it enumerates one (an addon whose
    /// options are `high|normal|low` understands none of `LOSSLESS/HIGH/LOW`). The manifest is read
    /// best-effort: a briefly unreachable manifest costs a tier hint, not the search. Last comes the
    /// `atmos` hint.
    private func settings(for tier: String) async -> [(String, String)] {
        var params = await derivedSettings(for: tier)
        // Exactly `auto`: `1`/`true` select the spec's strict mode, where a track with no immersive
        // mix is an error rather than a stereo answer. Never an override: an addon that declared
        // its own `atmos` setting has said what it wants. Only sent when an Atmos answer would be
        // accepted (the device decodes it and the listener wants it). Asked on every call rather
        // than memoised with the rest, so a listener switching Atmos, or the audio route changing
        // to one that decodes it, is heard by the next request.
        if !params.contains(where: { $0.0 == Self.atmosKey }), await atmosWanted() {
            params.append((Self.atmosKey, Self.atmosAuto))
        }
        return params
    }

    /// What the manifest and the tier decide, without the `atmos` hint.
    private func derivedSettings(for tier: String) async -> [(String, String)] {
        // The derived parameters change only when the manifest does, and the manifest is fetched
        // once per TTL — so deriving them once per tier, briefly, is the same answer. A single
        // match asks several times (searches, streams, retries) and used to re-derive each time.
        if let memo = quietLock.withLock({ settingsMemo[tier] }),
           Date().timeIntervalSince(memo.at) < Self.settingsMemoLifetime {
            return memo.params
        }
        let declared = (try? await manifest().get())?.settings ?? []
        var params: [(String, String)] = []
        func set(_ key: String, _ value: String) {
            if let index = params.firstIndex(where: { $0.0 == key }) {
                params[index].1 = value
            } else {
                params.append((key, value))
            }
        }
        for setting in declared {
            guard let key = setting.key.nonBlank, let value = setting.defaultValue else { continue }
            set(key, value)
        }
        if tier.nonBlank != nil {
            let options = declared.first { $0.key == Self.qualityKey }?.options ?? []
            set(Self.qualityKey, Self.matchTier(tier, options: options) ?? tier)
        }
        quietLock.withLock { settingsMemo[tier] = (Date(), params) }
        return params
    }

    /// The option that best answers a request for `tier`, matched on what an option says rather
    /// than its position; failing a word match, the first listed.
    static func matchTier(_ tier: String, options: [String]) -> String? {
        guard !options.isEmpty else { return nil }
        if let exact = options.first(where: { $0.caseInsensitiveCompare(tier) == .orderedSame }) { return exact }
        let wanted: [String]
        switch tier.uppercased() {
        case tierLossless: wanted = losslessWords
        case tierLow: wanted = lowWords
        default: wanted = highWords
        }
        return options.first { option in wanted.contains { option.lowercased().contains($0) } } ?? options.first
    }

    // MARK: Transport

    /// `{base}/{segments…}?{params}`, every part properly encoded.
    func endpoint(_ segments: [String], _ params: [(String, String)]) -> URL? {
        guard var components = URLComponents(string: baseUrl), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", components.host?.isEmpty == false else { return nil }
        var path = components.percentEncodedPath.trimmingTrailing("/")
        for segment in segments {
            path += "/" + (segment.addingPercentEncoding(withAllowedCharacters: Self.segmentAllowed) ?? segment)
        }
        components.percentEncodedPath = path
        var query = components.percentEncodedQuery.map { $0.isEmpty ? [] : [$0] } ?? []
        for (key, value) in params {
            query.append(Self.queryEncode(key) + "=" + Self.queryEncode(value))
        }
        components.percentEncodedQuery = query.isEmpty ? nil : query.joined(separator: "&")
        return components.url
    }

    private func fetch<T: Decodable>(_ url: URL, as type: T.Type) async -> Result<T, Error> {
        let started = ContinuousClock.now
        // The host and the endpoint (`/search`, `/stream/<id>`), never the token-bearing base path.
        let call = Self.redact(url.absoluteString) + endpoint(of: url)
        do {
            let data = try await body(url)
            let decoded = try JSONDecoder().decode(T.self, from: data)
            SourcesLog.d("  ✓ addon call \(call) answered in \(TrackLog.ms(since: started))ms")
            return .success(decoded)
        } catch {
            if !(error is CancellationError), (error as? AddonError) != .notFound {
                // A miss is not worth a line; everything else is — this is the only place that
                // knows why an addon didn't answer.
                SourcesLog.w("  ✗ addon call failed \(call) after \(TrackLog.ms(since: started))ms: \(error.localizedDescription)")
            }
            return .failure(error)
        }
    }

    /// The part of `url`'s path after this addon's base: the endpoint, without the token.
    private func endpoint(of url: URL) -> String {
        let full = url.absoluteString.before("?")
        return full.hasPrefix(baseUrl) ? String(full.dropFirst(baseUrl.count)) : ""
    }

    /// One GET, with the addon's own back-pressure honoured. A 429 is waited out rather than
    /// surfaced (every caller reads a failure as "doesn't have the track", which is wrong for a
    /// busy addon); `Retry-After` is believed, otherwise the wait doubles, both capped.
    private func body(_ url: URL) async throws -> Data {
        var attempt = 0
        while true {
            let wait = quietLock.withLock { quietUntil.timeIntervalSinceNow }
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }

            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(VibraMusicHTTP.UserAgent.addon, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = Self.callTimeout
            let (data, response) = try await withDeadline(Self.callTimeout) { [session, request] in
                try await session.data(for: request)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            switch status {
            case 200..<300:
                guard let text = String(data: data, encoding: .utf8), text.nonBlank != nil else {
                    throw AddonError.rejected("Empty response")
                }
                return data
            case 404:
                throw AddonError.notFound
            // A 5xx is a bad minute and will be tried again next track; a 4xx is the app asking for
            // something it will never be given. The Sources screen renders the two differently.
            case 500...:
                throw AddonError.unavailable("HTTP \(status)")
            case 429 where attempt < Self.maxRetries:
                let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
                let delay = Self.retryAfter(header, attempt: attempt)
                quietLock.withLock { quietUntil = Date().addingTimeInterval(delay) }
                attempt += 1
            case 429:
                throw AddonError.unavailable("This addon is rate limiting Vibra Music")
            default:
                throw AddonError.rejected("HTTP \(status)")
            }
        }
    }

    /// Seconds to wait after a 429, from the header when it sent one.
    static func retryAfter(_ header: String?, attempt: Int) -> TimeInterval {
        let stated = header.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        let backoff = backoffBase * Double(1 << attempt)
        return min(max(stated ?? backoff, backoffBase), backoffCap)
    }

    // MARK: Lifecycle

    /// Everything held about this addon, dropped: reached when the source is edited or removed.
    func clear() async {
        await manifests.clear()
        await searches.clear()
        await streams.clear()
        quietLock.withLock {
            quietUntil = .distantPast
            settingsMemo = [:]
        }
    }

    /// Makes the next catalogue and stream lookups real requests without disturbing one in flight —
    /// the listener's explicit "Upgrade quality", which must recover from a cached empty answer.
    func clearCompletedTrackCalls() async {
        await searches.clearCompleted()
        await streams.clearCompleted()
    }

    // MARK: Constants and URL helpers

    static let tierLossless = "LOSSLESS"
    static let tierHigh = "HIGH"
    static let tierLow = "LOW"

    private static let qualityKey = "quality"
    private static let atmosKey = "atmos"
    private static let atmosAuto = "auto"
    private static let losslessWords = ["lossless", "flac", "hifi", "hi-res", "hires", "max", "best"]
    private static let highWords = ["high", "320", "normal", "standard"]
    private static let lowWords = ["low", "96", "128", "min"]

    /// How long a manifest is trusted. The spec's update story is "just update your server", so not
    /// for the session; ten minutes picks up a new settings schema within one sitting.
    static let manifestTTL: TimeInterval = 10 * 60
    /// Whether a catalogue holds a recording doesn't turn over minute to minute.
    static let searchTTL: TimeInterval = 10 * 60
    /// Short, because a stream URL's expiry is not ours to set; covers the two candidates one match
    /// tries in turn and the second look moments later.
    static let streamTTL: TimeInterval = 5 * 60
    private static let maxRetries = 2
    private static let backoffBase: TimeInterval = 0.5
    private static let backoffCap: TimeInterval = 8
    /// A ceiling on the whole call: a server dribbling a byte at a time never trips an idle timeout.
    /// The spec asks addons to answer search in under 5 s and streams in under 3.
    static let callTimeout: TimeInterval = 20
    /// An ordinary word: a probe that usually comes back full proves more than one that can't.
    private static let probeQuery = "music"

    /// A base URL from whatever was pasted. `https://host/` and `https://host/manifest.json` are
    /// both what people copy; any `.json` filename comes off (a manifest served as `addon.json`
    /// gives the same base), and a token-bearing path is otherwise left intact.
    static func normalizeBase(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingTrailing("/")
        let lastSegment = trimmed.afterLast("/", missing: "")
        if lastSegment.lowercased().hasSuffix(".json"), trimmed.contains("://") {
            return String(trimmed.dropLast(lastSegment.count)).trimmingTrailing("/")
        }
        return trimmed
    }

    static func manifestURL(_ base: String) -> URL {
        URL(string: base + "/manifest.json") ?? URL(string: "about:blank")!
    }

    /// An addon URL with its path hidden, for logging. The protocol puts a user's private token in
    /// the path, so the path is what a log line must not carry; the host is kept for traceability.
    static func redact(_ url: String) -> String {
        guard let parsed = URL(string: url), let scheme = parsed.scheme, let host = parsed.host(), !host.isEmpty else {
            return "***"
        }
        return "\(scheme)://\(host)/***"
    }

    private static func describe(_ params: [(String, String)]) -> String {
        params.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    /// RFC 3986 unreserved plus the sub-delims OkHttp leaves alone in a path segment; `/`, `?` and
    /// `#` are encoded.
    private static let segmentAllowed: CharacterSet = {
        var set = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        set.insert(charactersIn: "!$&'()*+,;=:@")
        return set
    }()

    private static let queryAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
    )

    private static func queryEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? value
    }
}

/// Runs `operation`, failing with `URLError(.timedOut)` if it hasn't finished within `seconds`.
func withDeadline<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw URLError(.timedOut)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw URLError(.timedOut) }
        return first
    }
}
