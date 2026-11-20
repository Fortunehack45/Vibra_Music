import Foundation
import VibraMusicCore

// Ports data/sources/module/ModuleManager.kt.

/// Fetches a module index, downloads and loads module JS, and calls the module's exported search
/// and stream functions. One per ``ModuleSource``, so loaded engines survive across calls.
final class ModuleManager: @unchecked Sendable {
    struct LoadedModule: Sendable {
        let module: SpineModule
        let jsCode: String
        let baseUrl: String
    }

    private let session: URLSession
    let engines: ModuleScriptPool
    private let now: @Sendable () -> TimeInterval

    private let loads: SharedCalls<LoadedModule>
    private let searches: SharedCalls<ModuleSearchResponse>
    private let streams: SharedCalls<ModuleStreamResponse>

    /// Downloaded sources by module id. The engine pool evicts on its own schedule; the source is
    /// what this really holds, so a revived engine costs an evaluation, not a download.
    private let loadedLock = NSLock()
    private var loadedModules: [String: LoadedModule] = [:]

    /// Parsed indexes by URL. Substituting one track asks for the index twice (search, then stream)
    /// and every track after asks again — measured at ~460 ms of a ~2.1 s substitution on Android,
    /// re-fetching a document that changes when someone publishes a module.
    private let indexes: SharedCalls<[SpineModule]>

    init(session: URLSession, now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.session = session
        self.now = now
        engines = ModuleScriptPool(session: session)
        let log: @Sendable (String) -> Void = { SourcesLog.d($0) }
        // Loads are shared only while running, never by time: whether an engine still exists is
        // the pool's to say, and a cached answer could name an engine already closed.
        loads = SharedCalls(ttl: 0, log: log, now: now)
        searches = SharedCalls(ttl: Self.searchTTL, log: log, now: now)
        streams = SharedCalls(ttl: Self.streamTTL, log: log, now: now)
        indexes = SharedCalls(ttl: Self.indexTTL, log: log, now: now)
    }

    // MARK: Index

    /// Every module in the index at `sourceUrl`. A failed fetch is never cached: a briefly
    /// unreachable index is retried next track.
    func fetchIndex(_ sourceUrl: String) async -> Result<[SpineModule], Error> {
        await indexes.get(sourceUrl, describe: { "▶ fetchIndex(\(Self.redact(sourceUrl)))" }) { [session] in
            do {
                guard let url = URL(string: sourceUrl) else { throw URLError(.badURL) }
                let (data, response) = try await session.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                guard (200..<300).contains(status) else {
                    throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(status) from \(Self.redact(sourceUrl))"])
                }
                let modules = try ModuleIndex.parseModules(data)
                SourcesLog.d("  Parsed \(modules.count) modules")
                return .success(modules)
            } catch {
                SourcesLog.e("  ✗ fetchIndex FAILED for \(Self.redact(sourceUrl)): \(error.localizedDescription)")
                return .failure(error)
            }
        }
    }

    // MARK: Load

    /// Downloads a module's JS (relative `download` names resolve against `indexBase`) and
    /// initialises an engine for it.
    func loadModule(_ module: SpineModule, indexBase: String) async -> Result<LoadedModule, Error> {
        await loads.get(module.id, describe: { "▶ loadModule(\(module.id))" }) { [self] in
            await loadModuleNow(module, indexBase: indexBase)
        }
    }

    private func loadModuleNow(_ module: SpineModule, indexBase: String) async -> Result<LoadedModule, Error> {
        if let cached = loadedLock.withLock({ loadedModules[module.id] }) {
            if await engines.isLoaded(module.id) {
                SourcesLog.d("▶ loadModule(\(module.id)) — CACHE HIT")
                return .success(cached)
            }
            do {
                try await engines.load(module.id, jsCode: cached.jsCode, fetchBase: cached.baseUrl)
                return .success(cached)
            } catch {
                _ = loadedLock.withLock { loadedModules.removeValue(forKey: module.id) }
            }
        }
        SourcesLog.d("▶ loadModule(\(module.id)) download=\(module.download)")
        do {
            let downloadUrl = module.download.hasPrefix("http") ? module.download : "\(indexBase)/\(module.download)"
            guard let url = URL(string: downloadUrl) else { throw URLError(.badURL) }
            let (data, response) = try await session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            guard (200..<300).contains(status) else {
                throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(status) downloading module \(module.id)"])
            }
            let jsCode = String(decoding: data, as: UTF8.self)
            let baseUrl = downloadUrl.beforeLast("/")
            try await engines.load(module.id, jsCode: jsCode, fetchBase: baseUrl)
            let loaded = LoadedModule(module: module, jsCode: jsCode, baseUrl: baseUrl)
            loadedLock.withLock { loadedModules[module.id] = loaded }
            SourcesLog.d("  ✓ Loaded module \(module.id): \(jsCode.count) chars, baseUrl=\(Self.redact(baseUrl))")
            return .success(loaded)
        } catch {
            SourcesLog.e("  ✗ loadModule FAILED for \(module.id): \(error.localizedDescription)")
            return .failure(error)
        }
    }

    // MARK: Search and stream

    func searchTracks(_ loaded: LoadedModule, query: String, limit: Int = 50, settings: [(String, String)] = []) async -> Result<ModuleSearchResponse, Error> {
        let arguments = Self.json([query, limit, Self.contextArgument(settings)])
        // Everything the module is told can change its answer, settings included.
        return await searches.get(
            sharedCallKey(loaded.module.id, query, String(limit), Self.describe(settings)),
            describe: { "▶ searchTracks() module=\(loaded.module.id) query=\"\(query)\" limit=\(limit)" }
        ) { [engines] in
            await Self.decode(
                engines.call(loaded.module.id, function: "searchTracks", argumentsJSON: arguments),
                as: ModuleSearchResponse.self,
                what: "searchTracks for \(loaded.module.id) query='\(query)'"
            )
        }
    }

    /// `quality` goes as the export's second argument *and* as a setting: modules read it from
    /// whichever they were written against, and sending only one left the better-featured modules
    /// on their own default.
    func streamURL(_ loaded: LoadedModule, trackId: String, quality: String, settings: [(String, String)] = []) async -> Result<ModuleStreamResponse, Error> {
        let arguments = Self.json([trackId, quality, Self.contextArgument(settings)])
        return await streams.get(
            sharedCallKey(loaded.module.id, trackId, quality, Self.describe(settings)),
            describe: { "▶ getStreamUrl() module=\(loaded.module.id) trackId=\(trackId) quality=\(quality)" }
        ) { [engines] in
            await Self.decode(
                engines.call(loaded.module.id, function: "getTrackStreamUrl", argumentsJSON: arguments),
                as: ModuleStreamResponse.self,
                what: "getStreamUrl for \(loaded.module.id) trackId=\(trackId)"
            )
        }
    }

    private static func decode<T: Decodable>(_ raw: Result<String, Error>, as type: T.Type, what: String) -> Result<T, Error> {
        switch raw {
        case .success(let text):
            do {
                return .success(try JSONDecoder().decode(T.self, from: Data(text.utf8)))
            } catch {
                SourcesLog.e("  ✗ \(what) FAILED: unreadable answer \(text.prefix(200))")
                return .failure(error)
            }
        case .failure(let error):
            SourcesLog.e("  ✗ \(what) FAILED: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    /// The `context` argument every export takes. A module reads a setting as
    /// `context.settings.<key>.value` — the host hands back the shape of the module's own settings
    /// schema. (Android once built this one level short, and no module could read any setting.)
    static func contextArgument(_ settings: [(String, String)]) -> [String: Any] {
        var values: [String: Any] = [:]
        for (key, value) in settings { values[key] = ["value": value] }
        return ["settings": values]
    }

    private static func json(_ arguments: [Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func describe(_ settings: [(String, String)]) -> String {
        settings.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    // MARK: Lifecycle

    /// Everything held, dropped with the engines: reached when the source is edited or removed, and
    /// a cached answer afterwards would describe the old index.
    func unloadAll() async {
        loadedLock.withLock { loadedModules.removeAll() }
        await loads.clear()
        await searches.clear()
        await streams.clear()
        await indexes.clear()
        await engines.unloadAll()
    }

    /// A module or index URL with its host hidden, for logging. The index a build secret supplied
    /// never appears on screen, so the log shouldn't hand it out; the path stays for traceability.
    static func redact(_ url: String) -> String {
        guard let components = URLComponents(string: url), let scheme = components.scheme else { return "***" }
        return "\(scheme)://***\(components.percentEncodedPath)"
    }

    /// Long enough that a run of tracks costs one index fetch, short enough that a module
    /// published today is picked up without restarting.
    static let indexTTL: TimeInterval = 10 * 60
    static let searchTTL: TimeInterval = 10 * 60
    /// Module URLs are signed for about five hours; five minutes covers what repeats.
    static let streamTTL: TimeInterval = 5 * 60
}
