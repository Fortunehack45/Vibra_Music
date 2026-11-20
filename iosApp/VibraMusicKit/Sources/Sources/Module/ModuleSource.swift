import Foundation
import VibraMusicCore

// Ports data/sources/ModuleSource.kt. Legacy (PORTING Q4): configs from before addons keep working;
// the registry refuses to add new ones.

/// A ``MusicSource`` backed by the JS plugins a module index lists.
///
/// The config's `baseUrl` is the index JSON. Each plugin ships a JS file exporting `searchTracks()`
/// and `getTrackStreamUrl()`, run in JavaScriptCore with nothing but a wired-in `fetch()`. Track ids
/// are `<moduleId>::<upstreamId>` so ``stream(trackId:tier:)`` knows which module to call.
public final class ModuleSource: MusicSource, @unchecked Sendable {
    public let config: SourceConfig?
    private let sourceConfig: SourceConfig
    private let environment: SourceEnvironment
    let manager: ModuleManager

    public var configId: String { sourceConfig.id }
    /// Every module kind reports ``SourceKind/module``, as on Android: the kinds differ only in rank.
    public var kind: SourceKind { .module }
    public var displayName: String { sourceConfig.displayName }

    public init(config: SourceConfig, environment: SourceEnvironment) {
        self.config = config
        sourceConfig = config
        self.environment = environment
        manager = ModuleManager(session: environment.session)
    }

    // MARK: Health

    public func health() async -> SourceHealth {
        guard sourceConfig.baseUrl.nonBlank != nil else { return .rejected("A module index URL is required") }
        switch await manager.fetchIndex(sourceConfig.baseUrl) {
        case .success(let modules) where modules.isEmpty:
            return .rejected("The index answered but listed no modules — check the URL")
        case .success(let modules):
            return .ok(detail: "\(modules.count) module\(modules.count == 1 ? "" : "s")")
        case .failure(let error):
            SourcesLog.w("module index fetch failed for \(displayName): \(error.localizedDescription)")
            return .unreachable(error.localizedDescription.nonBlank ?? "Could not reach the module index")
        }
    }

    // MARK: Search

    /// Every module in the index, asked at once, answers interleaved, nobody waited on past the
    /// point of usefulness.
    ///
    /// - **At once**: one after another, a three-module index spent three times as long.
    /// - **Interleaved**: filled module by module and cut at `limit`, the first module's tail
    ///   crowded out every other module's best hit.
    /// - **Not to the last straggler**: the slowest module (7.5 s against 1.5 s on the same query)
    ///   became the price of every track, so the fan-out closes a grace period after the first
    ///   useful answer. The patient pass (`waitForAll`) gives everyone longer, but not forever.
    public func search(_ query: String, limit: Int, waitForAll: Bool, tier: StreamRequest.Tier?) async throws -> [Song] {
        if query.nonBlank == nil { return [] }
        let indexUrl = sourceConfig.baseUrl
        let indexBase = indexUrl.beforeLast("/")
        let modules: [SpineModule]
        switch await manager.fetchIndex(indexUrl) {
        case .success(let found): modules = found
        case .failure(let error):
            SourcesLog.w("\(displayName): index fetch failed — \(error.localizedDescription)")
            return []
        }
        if modules.isEmpty { return [] }

        let collector = FanOut(count: modules.count)
        let tasks = modules.enumerated().map { index, module in
            Task { [self] in
                let songs = await searchOne(module, query: query, limit: limit, indexBase: indexBase)
                await collector.record(songs, at: index)
            }
        }
        let budget = Self.searchBudget
        let grace = waitForAll ? Self.searchPatientGrace : Self.searchGrace
        let ceiling = waitForAll ? Self.searchPatient : budget + grace
        // The module tasks are unstructured (their calls finish into the shared caches either way),
        // so a caller that gives up has to stop the wait itself.
        await withTaskCancellationHandler {
            await collector.wait(firstWithin: budget, thenGrace: grace, ceiling: ceiling)
        } onCancel: {
            Task { await collector.abandon() }
        }
        tasks.forEach { $0.cancel() }
        try Task.checkCancellation()
        return Array(Self.interleave(await collector.answers).prefix(max(limit, 0)))
    }

    /// One module's answers, or nothing if it couldn't give any.
    private func searchOne(_ module: SpineModule, query: String, limit: Int, indexBase: String) async -> [Song] {
        let loaded: ModuleManager.LoadedModule
        switch await manager.loadModule(module, indexBase: indexBase) {
        case .success(let found): loaded = found
        case .failure(let error):
            SourcesLog.w("\(displayName): load failed for \(module.id) — \(error.localizedDescription)")
            return []
        }
        switch await manager.searchTracks(loaded, query: query, limit: limit) {
        case .success(let response):
            return response.tracks.map { track in
                Song(
                    videoId: SourceRegistry.trackKey(configId: configId, trackId: "\(module.id)\(Self.moduleSeparator)\(track.id)"),
                    title: track.title,
                    artist: track.artist,
                    thumbnailUrl: track.albumCover,
                    durationText: track.duration > 0 ? TrackMatcher.durationText(track.duration) : nil,
                    albumName: track.album.nonBlank,
                    sourceQuality: Self.rowTier(track)
                )
            }
        case .failure(let error):
            SourcesLog.w("\(displayName): search failed for \(module.id) — \(error.localizedDescription)")
            return []
        }
    }

    /// What a row can be had at, from what the module said about *it*. The stated quality first;
    /// the menu of possibilities (`availableQualities`) only when nothing was stated — the
    /// aggregator module publishes that menu on rows whose lossless backend then declines.
    static func rowTier(_ track: ModuleSearchResult) -> SourceQuality? {
        if let stated = sourceQuality("\(track.audioQuality) \(track.format)") { return stated }
        let best = track.availableQualities.max { tiers.firstIndex(of: qualityTier($0) ?? "") ?? -1 < tiers.firstIndex(of: qualityTier($1) ?? "") ?? -1 }
        return best.flatMap(sourceQuality)
    }

    /// First of each, then second of each: nth place everywhere beats second place anywhere.
    static func interleave(_ lists: [[Song]]) -> [Song] {
        var merged: [Song] = []
        var rank = 0
        while lists.contains(where: { $0.count > rank }) {
            for list in lists where list.count > rank { merged.append(list[rank]) }
            rank += 1
        }
        return merged
    }

    // MARK: Stream

    public func stream(trackId: String, tier: StreamRequest.Tier) async throws -> ResolvedStream? {
        guard let cut = trackId.range(of: Self.moduleSeparator) else {
            SourcesLog.w("\(displayName): malformed trackId '\(trackId)'")
            return nil
        }
        let moduleId = String(trackId[..<cut.lowerBound])
        let upstreamId = String(trackId[cut.upperBound...])

        let modules: [SpineModule]
        switch await manager.fetchIndex(sourceConfig.baseUrl) {
        case .success(let found): modules = found
        case .failure(let error):
            SourcesLog.w("\(displayName): index fetch failed — \(error.localizedDescription)")
            return nil
        }
        guard let module = modules.first(where: { $0.id == moduleId }) else {
            SourcesLog.w("\(displayName): module '\(moduleId)' not found in index")
            return nil
        }
        let loaded: ModuleManager.LoadedModule
        switch await manager.loadModule(module, indexBase: sourceConfig.baseUrl.beforeLast("/")) {
        case .success(let found): loaded = found
        case .failure(let error):
            SourcesLog.w("\(displayName): load failed for \(moduleId) — \(error.localizedDescription)")
            return nil
        }
        let tierName = Self.tierName(tier)
        let atmos = await environment.atmosWanted()
        let response: ModuleStreamResponse
        switch await manager.streamURL(loaded, trackId: upstreamId, quality: tierName, settings: Self.settings(tier, atmos: atmos)) {
        case .success(let found): response = found
        case .failure(let error):
            SourcesLog.w("\(displayName): getStreamUrl failed for \(upstreamId) — \(error.localizedDescription)")
            return nil
        }
        try Task.checkCancellation()
        guard let url = response.streamUrl?.nonBlank else {
            SourcesLog.w("\(displayName): empty stream URL for \(upstreamId)")
            return nil
        }
        if Self.malformed(url) {
            SourcesLog.w("\(displayName): \(moduleId) returned a malformed URL for \(upstreamId); skipping it — \(url.prefix(120))")
            return nil
        }
        let meta = response.track
        let format = StreamFormat(
            codec: Self.codec(mimeType: meta?.mimeType, quality: meta?.audioQuality, url: url),
            kbps: meta?.bitrate ?? Self.kbps(quality: meta?.audioQuality, url: url),
            sampleRateHz: meta?.sampleRate.map { $0 < 1_000 ? Int($0 * 1_000) : Int($0) }.flatMap { $0 > 0 ? $0 : nil },
            bitDepth: meta?.bitDepth.flatMap { $0 > 0 ? $0 : nil }
        )
        let playsAtmos = environment.deviceCodecs.playsDolbyAtmos
        if Self.unplayable(format, atmosAllowed: atmos) {
            let why = playsAtmos ? "which is switched off in Settings" : "which this device has no decoder for"
            SourcesLog.w("\(displayName): \(moduleId) answered a \(tierName) request with \(format.summary), \(why) — passing")
            return nil
        }
        guard let streamURL = URL(string: url) else { return nil }
        // Module URLs are signed for about five hours.
        let stream = ResolvedStream(
            url: streamURL,
            origin: .module,
            mimeType: meta?.mimeType?.nonBlank,
            format: format,
            expiresAt: Date().addingTimeInterval(5 * 60 * 60)
        )
        // ExoPlayer sniffed a DASH answer and played it; AVPlayer can't, so it is converted.
        if DashToHLS.looksLikeDash(url: url, mimeType: stream.mimeType) {
            return await DashToHLS.playable(stream, environment: environment, atmosAllowed: atmos, label: "\(displayName) \(moduleId)")
        }
        return stream
    }

    /// Codec from the mime type, then an Atmos or lossless label, then the URL's extension. Nil when
    /// none knows — `kbps` carries what is known instead.
    static func codec(mimeType: String?, quality: String?, url: String) -> String? {
        if let fromMime = mimeType?.afterLast("/").before(";").trimmingCharacters(in: .whitespaces).lowercased(), !fromMime.isEmpty {
            return fromMime
        }
        let text = (quality ?? "").uppercased()
        // Tidal's MAX endpoint names its Atmos HLS rendition EAC3_JOC; older answers say "Dolby Atmos".
        if text.contains("ATMOS") || text.contains("EAC3_JOC") || text.contains("EC-3") { return "eac3-joc" }
        if qualityTier(quality ?? "") == lossless { return "flac" }
        let ext = url.before("?").afterLast(".").lowercased()
        return audioExtensions.contains(ext) ? ext : nil
    }

    /// The bitrate a module committed to: the number in its label, in its URL (`….128.mp3`), or the
    /// tier's published meaning (`HIGH` is a stated 320).
    static func kbps(quality: String?, url: String) -> Int? {
        if let fromLabel = kbpsIn(quality) { return fromLabel }
        if let fromURL = kbpsIn(url) { return fromURL }
        switch qualityTier(quality ?? "") {
        case high: return 320
        case low: return 128
        default: return nil
        }
    }

    private static func kbpsIn(_ text: String?) -> Int? {
        guard let text, text.nonBlank != nil else { return nil }
        let found = kbpsLabel.firstGroup(in: text) ?? kbpsURL.firstGroup(in: text)
        return found.flatMap(Int.init).flatMap { (8...2_000).contains($0) ? $0 : nil }
    }

    /// The settings a module is handed. `fallbackMode: strict` whenever lossless was asked for: left
    /// flexible, a module walks its own fallback chain and returns a 128 kbps MP3 ten seconds later.
    /// `dolbyAtmos` says outright whether an immersive rendition is wanted — the polite ask;
    /// ``unplayable(_:atmosAllowed:)`` on the way back is the guarantee.
    static func settings(_ tier: StreamRequest.Tier, atmos: Bool) -> [(String, String)] {
        [
            ("quality", tierName(tier)),
            ("fallbackMode", tier == .lossless ? "strict" : "flexible"),
            ("dolbyAtmos", atmos ? "true" : "false"),
        ]
    }

    // MARK: Lifecycle

    public func release() {
        let manager = manager
        Task { await manager.unloadAll() }
    }

    public func clearCompletedTrackCalls() async {}

    // MARK: Constants

    private static let audioExtensions: Set<String> = ["flac", "alac", "wav", "aiff", "mp3", "m4a", "aac", "ogg", "opus", "webm"]
    private static let kbpsLabel = Pattern(#"(\d{2,4})\s*kbps"#, caseInsensitive: true)
    private static let kbpsURL = Pattern(#"\.(\d{2,4})\.(?:mp3|m4a|aac|ogg)"#, caseInsensitive: true)

    /// How long the fan-out waits for a first useful answer, and how much longer the rest get.
    static let searchBudget: TimeInterval = 8
    static let searchGrace: TimeInterval = 2.5
    /// The background pass's ceiling, and its grace after the first answer.
    static let searchPatient: TimeInterval = 25
    static let searchPatientGrace: TimeInterval = 8

    /// Between the module id and the upstream id inside a track id.
    static let moduleSeparator = "::"
}

/// Collects per-module answers and tells the search when to stop waiting: at the first useful
/// answer plus a grace period, or when everyone has answered, or at the ceiling.
private actor FanOut {
    private var slots: [[Song]?]
    private var remaining: Int
    private var firstUseful = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var phase = 0

    init(count: Int) {
        slots = Array(repeating: nil, count: count)
        remaining = count
    }

    var answers: [[Song]] { slots.compactMap { $0 } }

    func record(_ songs: [Song], at index: Int) {
        slots[index] = songs
        remaining -= 1
        if !songs.isEmpty { firstUseful = true }
        wake()
    }

    /// Android's two phases: until someone answers usefully (or everyone has answered) within
    /// `budget`, then up to `grace` more for the rest — never past `ceiling` in total. (Android
    /// waited out the whole budget when every module answered empty; this stops once all have.)
    func wait(firstWithin budget: TimeInterval, thenGrace grace: TimeInterval, ceiling: TimeInterval) async {
        if abandoned { return }
        let started = Date()
        func elapsed() -> TimeInterval { Date().timeIntervalSince(started) }
        while !abandoned, !firstUseful, remaining > 0, elapsed() < min(budget, ceiling) {
            await sleep(min(budget, ceiling) - elapsed())
        }
        let graceEnds = min(elapsed() + grace, ceiling)
        while !abandoned, remaining > 0, elapsed() < graceEnds {
            await sleep(graceEnds - elapsed())
        }
    }

    private func sleep(_ seconds: TimeInterval) async {
        phase += 1
        let mine = phase
        await withCheckedContinuation { continuation in
            waiter = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                await self?.timeout(mine)
            }
        }
    }

    /// The caller gave up: stop waiting now.
    func abandon() {
        abandoned = true
        wake()
    }

    private var abandoned = false

    private func timeout(_ which: Int) {
        guard which == phase else { return }
        wake()
    }

    private func wake() {
        let current = waiter
        waiter = nil
        current?.resume()
    }
}
