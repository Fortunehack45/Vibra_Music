import VibraMusicCore
import Foundation

/// The cipher tier: turns web clients' `signatureCipher` formats into URLs googlevideo serves,
/// and knows the current player's `signatureTimestamp`.
///
/// Replaces two Android libraries with no Swift version: NewPipe's signature/`n` solving (Rhino)
/// and InnerTubeX's zemer-cipher tier (a WebView). The approach is zemer's: download the player
/// script, look its version up in the remote `player_configs.json` table (or derive the config
/// from the script when the table does not know it yet), and run the player's own code to do
/// the work — here in JavaScriptCore (`PlayerScriptRuntime`).
///
/// Cached per player version, in memory (the evaluated runtime) and on disk (the script, newest
/// three kept, as Android's `KEPT_PLAYERS`), because the script is ~3 MB and rotates only every
/// few days. Verified live on 2026-09-26: WEB_REMIX, TVHTML5_SIMPLY and MWEB formats deciphered
/// here serve the whole file without a PoToken.
public actor StreamCipherSolver {
    private let session: URLSession
    private let cacheDirectory: URL?
    private let remoteConfigURL: URL?
    private let defaults: UserDefaults?
    private let now: @Sendable () -> Date
    private let fallbackHash: @Sendable () async -> String?

    private var runtime: PlayerScriptRuntime?
    private var currentHash: (hash: String, at: Date)?
    private var remoteTable: [String: PlayerScriptConfig]?
    private var remoteFetchedAt: Date?
    private var lastForcedRefresh: Date?
    private var loading: Task<PlayerScriptRuntime, Error>?
    private var loadingHash: String?
    /// Bumped by each forced refresh, so a build started before one is not kept.
    private var rejections = 0

    /// zemer-cipher's live table, which InnerTubeX also reads (Android's `PLAYER_CONFIG_URL`).
    public static let defaultRemoteConfigURL =
        URL(string: "https://raw.githubusercontent.com/ZemerTeam/zemer-cipher/master/library/src/main/assets/player_configs.json")!

    static let remoteTTL: TimeInterval = 6 * 3600
    static let forcedRefreshCooldown: TimeInterval = 10 * 60
    /// How long a failed forced refresh waits before the next try. Short, so a table that is back
    /// is picked up soon, but not zero: every refused URL would otherwise wait out the fetch's
    /// 10 s timeout on a network that cannot reach the table.
    static let failedRefreshBackoff: TimeInterval = 60
    static let hashTTL: TimeInterval = 30 * 60
    static let keptPlayers = 3
    static let defaultsTableKey = "streamresolution.playerConfigs.json"
    static let defaultsTableDateKey = "streamresolution.playerConfigs.fetchedAt"
    static let defaultsTableETagKey = "streamresolution.playerConfigs.etag"

    public enum CipherError: Error, LocalizedError, Equatable {
        case noPlayerVersion
        case malformedCipher
        case unsupportedPlayer(String)

        public var errorDescription: String? {
            switch self {
            case .noPlayerVersion: return "could not find YouTube's current player"
            case .malformedCipher: return "format carries no usable signatureCipher"
            case .unsupportedPlayer(let detail): return "cannot run this player version: \(detail)"
            }
        }
    }

    /// - Parameters:
    ///   - cacheDirectory: where player scripts are kept across launches; nil keeps nothing on disk.
    ///     Defaults to `Caches/StreamResolution/players`.
    ///   - remoteConfigURL: the per-player table; nil derives every config from the script alone.
    ///   - fallbackHash: another way to learn the player version (the music shell's `jsUrl`),
    ///     used when the iframe API loader cannot be read.
    public init(
        session: URLSession = VibraMusicHTTP.session,
        cacheDirectory: URL? = StreamCipherSolver.defaultCacheDirectory,
        remoteConfigURL: URL? = StreamCipherSolver.defaultRemoteConfigURL,
        defaults: UserDefaults? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        fallbackHash: @escaping @Sendable () async -> String? = { nil }
    ) {
        self.session = session
        self.cacheDirectory = cacheDirectory
        self.remoteConfigURL = remoteConfigURL
        self.defaults = defaults
        self.now = now
        self.fallbackHash = fallbackHash
        if let data = defaults?.data(forKey: Self.defaultsTableKey),
           case .success(let configs, _) = PlayerConfigTable.parse(data) {
            remoteTable = configs
            remoteFetchedAt = defaults?.object(forKey: Self.defaultsTableDateKey) as? Date
        }
    }

    public static var defaultCacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("StreamResolution/players", isDirectory: true)
    }

    /// YouTube's current player revision, as the number a web client quotes to prove it runs
    /// that player. Memoised with the player; nil when no player could be loaded.
    ///
    /// Shared rather than fetched per caller because `PlaybackHistoryTracker` needs one too:
    /// without it the tracking request is answered `UNPLAYABLE` and history silently stays empty.
    public func signatureTimestamp() async -> Int? {
        do {
            return try await loadedRuntime().config.signatureTimestamp
        } catch {
            streamLog.warning("no signature timestamp: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Pays the cold costs (player download, evaluation) before a track needs them.
    public func prewarm() async {
        _ = try? await loadedRuntime()
    }

    /// A playable URL from a format's `signatureCipher` (`s`, `sp`, `url`), with `n` transformed.
    func decipher(signatureCipher: String) async throws -> URL {
        var components = URLComponents()
        components.percentEncodedQuery = signatureCipher
        let items = components.queryItems ?? []
        guard let base = items.first(where: { $0.name == "url" })?.value, let url = URL(string: base),
              let scrambled = items.first(where: { $0.name == "s" })?.value
        else { throw CipherError.malformedCipher }
        let parameter = items.first(where: { $0.name == "sp" })?.value ?? "signature"
        let runtime = try await loadedRuntime()
        let signature = try runtime.decipherSignature(scrambled)
        return try transformN(in: url.settingStreamQuery(parameter, signature), runtime: runtime)
    }

    /// `url` with its `n` parameter transformed; unchanged when it has none.
    func transformN(in url: URL) async throws -> URL {
        guard url.streamQueryValue("n") != nil else { return url }
        return try transformN(in: url, runtime: try await loadedRuntime())
    }

    private func transformN(in url: URL, runtime: PlayerScriptRuntime) throws -> URL {
        guard let n = url.streamQueryValue("n") else { return url }
        let transformed = try runtime.transformN(n)
        if transformed == n {
            // Unchanged means throttled: googlevideo serves an untransformed `n` at a crawl, or
            // not past the first megabyte. The probe will judge it; say why here.
            streamLog.warning("n transform left the value unchanged for player \(runtime.hash, privacy: .public)")
        }
        return url.settingStreamQuery("n", transformed)
    }

    /// A deciphered URL was refused: the table entry may be stale. Refresh it (with a cooldown)
    /// and rebuild the runtime on next use. Port of `refreshAfterStreamRejection`.
    func refreshAfterStreamRejection() async {
        if let last = lastForcedRefresh, now().timeIntervalSince(last) < Self.forcedRefreshCooldown { return }
        lastForcedRefresh = now()
        currentHash = nil
        runtime = nil
        // A build already in flight read the table this rejection doubts; it must not become `runtime`.
        loading = nil
        loadingHash = nil
        rejections += 1
        let refreshed = await refreshRemoteTable(force: true)
        // Builds that started during the fetch read the old table too.
        runtime = nil
        loading = nil
        loadingHash = nil
        rejections += 1
        if !refreshed { backOffAfterFailedRefresh() }
    }

    /// Leaves only ``failedRefreshBackoff`` of the cooldown to wait.
    private func backOffAfterFailedRefresh() {
        lastForcedRefresh = now().addingTimeInterval(Self.failedRefreshBackoff - Self.forcedRefreshCooldown)
    }

    // MARK: - Loading

    func loadedRuntime() async throws -> PlayerScriptRuntime {
        let hash = try await playerHash()
        if let runtime, runtime.hash == hash { return runtime }
        if let loading, loadingHash == hash { return try await loading.value }
        let task = Task { try await self.buildRuntime(hash: hash) }
        let generation = rejections
        loading = task
        loadingHash = hash
        defer {
            if loading == task {
                loading = nil
                loadingHash = nil
            }
        }
        let built = try await task.value
        if generation == rejections { runtime = built }
        return built
    }

    private func buildRuntime(hash: String) async throws -> PlayerScriptRuntime {
        let started = now()
        let source = try await playerSource(hash: hash)
        var candidates: [PlayerScriptConfig] = []
        if remoteConfigURL != nil {
            if let config = await remoteConfig(for: hash) { candidates.append(config) }
        }
        if let derived = PlayerScriptConfig.derive(fromPlayerSource: source), !candidates.contains(derived) {
            candidates.append(derived)
        }
        guard !candidates.isEmpty else { throw CipherError.unsupportedPlayer("no config for player \(hash)") }
        var failures: [String] = []
        for config in candidates {
            do {
                let runtime = try PlayerScriptRuntime(hash: hash, playerSource: source, config: config)
                let ms = Int(now().timeIntervalSince(started) * 1000)
                streamLog.debug("player \(hash, privacy: .public) ready in \(ms)ms (sts \(config.signatureTimestamp))")
                return runtime
            } catch {
                failures.append("\(config.sigExpression)/\(config.nClass): \(error.localizedDescription)")
            }
        }
        throw CipherError.unsupportedPlayer(failures.joined(separator: "; "))
    }

    /// The current player's 8-hex version, from the iframe API loader (a few hundred bytes).
    func playerHash() async throws -> String {
        if let currentHash, now().timeIntervalSince(currentHash.at) < Self.hashTTL { return currentHash.hash }
        var found: String?
        do {
            var request = URLRequest(url: PlayerScriptLocator.iframeAPIURL)
            request.setValue(StreamPlayerClient.webUserAgent, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10
            let (data, _) = try await session.data(for: request)
            found = PlayerScriptLocator.hash(inIframeAPI: String(decoding: data, as: UTF8.self))
        } catch {
            streamLog.warning("iframe API fetch failed: \(error.localizedDescription, privacy: .public)")
        }
        if found == nil { found = await fallbackHash() }
        if found == nil, let runtime { found = runtime.hash }
        guard let hash = found else { throw CipherError.noPlayerVersion }
        currentHash = (hash, now())
        return hash
    }

    private func playerSource(hash: String) async throws -> String {
        let file = cacheDirectory?.appendingPathComponent("\(hash).js")
        if let file, let data = try? Data(contentsOf: file) {
            let source = String(decoding: data, as: UTF8.self)
            if source.contains(PlayerScriptRuntime.closingMarker) { return source }
            try? FileManager.default.removeItem(at: file)
        }
        var request = URLRequest(url: PlayerScriptLocator.scriptURL(hash: hash))
        request.setValue(StreamPlayerClient.webUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
            throw CipherError.unsupportedPlayer("player \(hash) download failed")
        }
        let source = String(decoding: data, as: UTF8.self)
        // A 200 that isn't the player (a consent or captive-portal page, a truncated body) would
        // otherwise be reused from disk until the cache is cleared.
        if let file, source.contains(PlayerScriptRuntime.closingMarker) { store(data, at: file) }
        return source
    }

    /// Writes atomically, then keeps only the newest few players: they rotate every few days and
    /// only the current ones are worth their megabytes.
    private func store(_ data: Data, at file: URL) {
        let directory = file.deletingLastPathComponent()
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            let players = try manager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
            ).filter { $0.pathExtension == "js" }
            let sorted = players.sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            for stale in sorted.dropFirst(Self.keptPlayers) { try? manager.removeItem(at: stale) }
        } catch {
            streamLog.warning("could not cache player script: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Remote table

    private func remoteConfig(for hash: String) async -> PlayerScriptConfig? {
        let stale = remoteFetchedAt.map { now().timeIntervalSince($0) >= Self.remoteTTL } ?? true
        if remoteTable == nil || stale { await refreshRemoteTable(force: false) }
        if let config = remoteTable?[hash] { return config }
        // A player the table does not know yet: it may have been added minutes ago. One forced
        // refresh per cooldown, so an unknown player does not refetch on every track.
        if lastForcedRefresh.map({ now().timeIntervalSince($0) >= Self.forcedRefreshCooldown }) ?? true {
            lastForcedRefresh = now()
            if !(await refreshRemoteTable(force: true)) { backOffAfterFailedRefresh() }
        }
        return remoteTable?[hash]
    }

    /// - Returns: whether the table is now confirmed current (a 304, or a 200 that parsed).
    @discardableResult
    private func refreshRemoteTable(force: Bool) async -> Bool {
        guard let remoteConfigURL else { return false }
        var request = URLRequest(url: remoteConfigURL)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if !force, remoteTable != nil, let etag = defaults?.string(forKey: Self.defaultsTableETagKey) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            if http?.statusCode == 304 {
                remoteFetchedAt = now()
                defaults?.set(remoteFetchedAt, forKey: Self.defaultsTableDateKey)
                return true
            }
            guard http?.statusCode == 200 else { return false }
            switch PlayerConfigTable.parse(data) {
            case .success(let configs, let skipped):
                remoteTable = configs
                remoteFetchedAt = now()
                defaults?.set(data, forKey: Self.defaultsTableKey)
                defaults?.set(remoteFetchedAt, forKey: Self.defaultsTableDateKey)
                if let etag = http?.value(forHTTPHeaderField: "ETag") {
                    defaults?.set(etag, forKey: Self.defaultsTableETagKey)
                }
                if !skipped.isEmpty {
                    streamLog.debug("player config table skipped \(skipped.count) invalid entries")
                }
                return true
            case .failure(let reason):
                // Keep the last good table rather than trust a broken one.
                streamLog.warning("rejected player config table: \(reason, privacy: .public)")
            }
        } catch {
            streamLog.warning("player config table fetch failed: \(error.localizedDescription, privacy: .public)")
        }
        return false
    }
}
