import Foundation
import Observation
import VibraMusicCore

// Ports data/sources/SourceRegistry.kt. Android kept the list in EncryptedSharedPreferences; here it
// is a JSON file (``SourceConfigStore``), file-protected and excluded from backups, since an addon
// URL can carry a private token in its path.

/// The user's sources, tried in the order ``SourceKind/rank`` declares: their own addons first (in
/// the order they dragged them into), then JioSaavn, then YouTube Music.
///
/// YouTube is seeded on first run and can be neither deleted nor switched off: nothing else supplies
/// a home feed, radio or related tracks, and a YouTube-queued track whose substitutes all miss still
/// falls back to it. JioSaavn is present but off until the user accepts its catalogue-matching risk.
///
/// UI state (``configs``) is main-actor; the resolver reads the same state from any thread through
/// the nonisolated accessors (``active()``, ``instance(_:)``…), which see a locked snapshot.
@MainActor
@Observable
public final class SourceRegistry {
    /// Every configured source, enabled or not, in stored (priority) order.
    public private(set) var configs: [SourceConfig] = []

    @ObservationIgnored nonisolated let environment: SourceEnvironment
    @ObservationIgnored private let store: SourceConfigStore?
    @ObservationIgnored private let factory: @Sendable (SourceConfig, SourceEnvironment) -> MusicSource
    @ObservationIgnored nonisolated private let snapshot = LockedBox(Snapshot())
    /// False when the stored file exists but could not be read (a transient filesystem error, or
    /// file protection before the first unlock). Nothing is written then: the seeded list would
    /// replace every source the user configured, addon tokens included.
    @ObservationIgnored private var storeIsReadable = true

    private struct Snapshot {
        var configs: [SourceConfig] = []
        var instances: [String: MusicSource] = [:]
    }

    /// Loads the stored list (seeding the built-in kinds and running the one-time JioSaavn opt-in
    /// migration). `store` nil keeps everything in memory (tests, previews).
    public init(
        store: SourceConfigStore? = .standard,
        environment: SourceEnvironment,
        factory: (@Sendable (SourceConfig, SourceEnvironment) -> MusicSource)? = nil
    ) {
        self.store = store
        self.environment = environment
        self.factory = factory ?? { config, environment in SourceRegistry.build(config, environment) }
        var loaded = SourceConfigStore.Contents()
        do {
            loaded = try store?.load() ?? loaded
        } catch is DecodingError {
            // Not recoverable by this build, so starting over from the built-ins is the repair.
            SourcesLog.w("stored sources are corrupt; starting from the built-ins")
        } catch {
            SourcesLog.w("stored sources unreadable; keeping the file untouched this session", error: error)
            storeIsReadable = false
        }
        let after = Self.sourcesForInit(loaded.sources, forceJioSaavnOff: !loaded.jioSaavnOptInV1)
        publish(after, persist: false)
        // Written in one go with the marker: a process dying between recording the marker and the
        // disabled source would otherwise let the next launch silently restore the old on state.
        if storeIsReadable, after != loaded.sources || !loaded.jioSaavnOptInV1 {
            store?.save(.init(sources: after, jioSaavnOptInV1: true))
        }
    }

    /// Built-in seeding and one-time migrations, pure for tests.
    ///
    /// `forceJioSaavnOff` is true exactly once per install (the first run of this version): existing
    /// users must opt in again; after that a deliberate "on" stays on.
    public nonisolated static func sourcesForInit(_ stored: [SourceConfig], forceJioSaavnOff: Bool) -> [SourceConfig] {
        // Seeded rather than persisted-on-first-write, so a new built-in kind reaches existing
        // installs too. SourceConfig's default is the policy: JioSaavn off, YouTube on.
        let seeded = stored + builtInKinds.filter { kind in !stored.contains { $0.kind == kind } }.map { SourceConfig(kind: $0) }
        // The retired built-in module is removed; a custom module the user entered is kept.
        return seeded.filter { $0.kind != .module }.map { config in
            var config = config
            if config.kind == .youtube, !config.enabled { config.enabled = true }
            if config.kind == .jioSaavn, forceJioSaavnOff { config.enabled = false }
            return config
        }
    }

    // MARK: Reading (any thread)

    /// The enabled sources, sorted by rank (stable, so addons keep their stored order). The user's
    /// standing choice and nothing else: both playback and downloads start here.
    public nonisolated func active() -> [MusicSource] {
        let current = snapshot.value
        return Self.enabledConfigs(current.configs)
            .enumerated()
            .sorted { $0.element.kind.rank != $1.element.kind.rank ? $0.element.kind.rank < $1.element.kind.rank : $0.offset < $1.offset }
            .compactMap { current.instances[$0.element.id] }
    }

    /// The common eligibility gate for playback and download walks.
    public nonisolated static func enabledConfigs(_ configs: [SourceConfig]) -> [SourceConfig] {
        configs.filter { $0.enabled && $0.isComplete }
    }

    /// ``active()``, minus the kinds the connection's ceiling doesn't pay for (the request's
    /// `permittedSources`, from ``AudioQuality/permits(_:)``). Every path that starts a *stream*
    /// asks this; downloads keep asking ``active()``.
    public nonisolated func activeForPlayback(_ request: StreamRequest) -> [MusicSource] {
        active().filter { request.permits($0.kind) }
    }

    public nonisolated func instance(_ configId: String) -> MusicSource? {
        snapshot.value.instances[configId]
    }

    public nonisolated func config(_ configId: String) -> SourceConfig? {
        snapshot.value.configs.first { $0.id == configId }
    }

    /// Drops completed addon answers for an explicit quality retry: an addon whose upstream was
    /// briefly down can say so as HTTP 200 with no rows, and "Upgrade quality" means "ask again now".
    public nonisolated func clearCompletedTrackCalls() async {
        for source in snapshot.value.instances.values {
            await source.clearCompletedTrackCalls()
        }
    }

    // MARK: Editing

    public func add(_ config: SourceConfig) {
        publish(configs + [Self.tidied(config)])
    }

    public func update(_ config: SourceConfig) {
        let tidied = Self.tidied(config)
        publish(configs.map { $0.id == tidied.id ? tidied : $0 })
    }

    /// Removes a user-added source. The built-in kinds can't be removed.
    public func remove(_ configId: String) {
        guard let target = configs.first(where: { $0.id == configId }), !Self.builtInKinds.contains(target.kind) else { return }
        publish(configs.filter { $0.id != configId })
    }

    /// Turns one source on or off. YouTube silently ignores "off": a switch that can't honour its
    /// own off position is worse than no switch, so the screen shouldn't offer one.
    public func setEnabled(_ configId: String, _ enabled: Bool) {
        if !enabled, configs.first(where: { $0.id == configId })?.kind == .youtube { return }
        publish(configs.map { config in
            guard config.id == configId else { return config }
            var changed = config
            changed.enabled = enabled
            return changed
        })
    }

    /// Puts the user-added sources in `orderedIds`, the order they will be asked in. The stored
    /// list *is* the priority (``active()`` sorts stably by rank), so there is no rank field to
    /// drift. Unknown ids are dropped and forgotten ones appended, so a list that moved under the
    /// drag reorders what it can; everything else keeps its place.
    public func reorderAddons(_ orderedIds: [String]) {
        let addons = configs.filter { $0.kind.isUserAdded }
        guard addons.count >= 2 else { return }
        let byId = Dictionary(addons.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var moved: [SourceConfig] = []
        for id in orderedIds {
            if let config = byId[id], !moved.contains(where: { $0.id == id }) { moved.append(config) }
        }
        let missed = addons.filter { config in !moved.contains { $0.id == config.id } }
        let reordered = moved + missed
        guard reordered.map(\.id) != addons.map(\.id) else { return }
        publish(reordered + configs.filter { !$0.kind.isUserAdded })
    }

    /// The URL as stored, not as typed: an addon's root and its `manifest.json` are one server.
    private static func tidied(_ config: SourceConfig) -> SourceConfig {
        guard config.kind == .addon else { return config }
        var tidied = config
        tidied.baseUrl = AddonClient.normalizeBase(config.baseUrl)
        return tidied
    }

    private func publish(_ next: [SourceConfig], persist: Bool = true) {
        configs = next
        // Rebuilt against the previous map so an untouched source keeps its warm instance.
        let previous = snapshot.value.instances
        var instances: [String: MusicSource] = [:]
        for config in next {
            if let existing = previous[config.id], existing.config == config {
                instances[config.id] = existing
            } else {
                instances[config.id] = factory(config, environment)
            }
        }
        snapshot.value = Snapshot(configs: next, instances: instances)
        // Whatever the rebuild left behind is told so: an edited or removed addon holds a manifest,
        // answers and stream URLs describing the server it used to point at.
        for (id, old) in previous where instances[id] !== old {
            old.release()
        }
        if persist, storeIsReadable { store?.save(.init(sources: next, jioSaavnOptInV1: true)) }
    }

    // MARK: Identifying a pasted URL

    /// Works out what is at `url` and returns a config that speaks to it, or throws a refusal
    /// saying what was found instead. The kind is detected, not chosen: an addon's root, its
    /// `manifest.json`, or a module index all end here. `existing` keeps an edited source's id and
    /// on/off state.
    ///
    /// iOS difference (PORTING Q4): a module index is accepted only when editing a source that is
    /// already a custom module. Legacy configs keep running; new ones can't be added.
    public nonisolated func identify(_ url: String, editing existing: SourceConfig? = nil) async throws -> SourceConfig {
        let environment = environment
        let detected = try await SourceFormats.identify(url, session: environment.session, atmosWanted: {
            await environment.atmosWanted()
        })
        switch detected {
        case .addon(let manifest, let baseUrl):
            var config = existing ?? SourceConfig(kind: .addon)
            config.kind = .addon
            config.baseUrl = baseUrl
            config.label = manifest.displayName
            return config
        case .moduleIndex(_, let indexUrl):
            guard var config = existing, config.kind == .customModule else {
                throw AddonError.rejected(
                    "That is a module index. Module sources are no longer supported — existing ones keep working, but new ones can't be added. Ask for an addon link instead."
                )
            }
            // The index URL itself, not a base: a module index is the document.
            config.baseUrl = indexUrl
            return config
        case .unsupported(let reason):
            throw AddonError.rejected(reason)
        }
    }

    /// The configured source already pointing at `url`, compared after normalisation: an addon's root
    /// and its manifest, a trailing slash, a differently-cased host are all one source. The path is
    /// not case-folded — it can carry a token. `exceptId` is the source being edited.
    public nonisolated func duplicateOf(_ url: String, exceptId: String? = nil) -> SourceConfig? {
        let wanted = Self.canonicalUrl(url)
        guard !wanted.isEmpty else { return nil }
        return snapshot.value.configs.first { $0.id != exceptId && Self.canonicalUrl($0.baseUrl) == wanted }
    }

    nonisolated static func canonicalUrl(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingTrailing("/")
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = components.host?.lowercased(), !host.isEmpty else {
            return trimmed
        }
        let defaultPort = scheme == "https" ? 443 : 80
        let port = components.port.map { $0 == defaultPort ? "" : ":\($0)" } ?? ""
        let path = components.percentEncodedPath.trimmingTrailing("/")
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)\(path)\(query)"
    }

    /// Health-checks a config that hasn't been saved — the editor's Test button. Built fresh: the
    /// stored instance would report on the old address, which is what the user is correcting.
    public nonisolated func probeCandidate(_ config: SourceConfig) async -> SourceHealth {
        let source = factory(config, environment)
        defer { source.release() }
        return await source.health()
    }

    /// Test and Save ask the same question: identify, refuse a duplicate, then probe. `save` stores
    /// a success — even when the probe was unhappy, since a server that is asleep is still worth
    /// keeping, while a URL nothing can be made of is not.
    public func check(_ url: String, editing existing: SourceConfig? = nil, save: Bool) async -> SourceCheck {
        let found: SourceConfig
        do {
            found = try await identify(url, editing: existing)
        } catch {
            return SourceCheck(config: nil, health: nil, message: error.localizedDescription, isGood: false, saved: false)
        }
        if let duplicate = duplicateOf(found.baseUrl, exceptId: existing?.id) {
            return SourceCheck(config: found, health: nil, message: "\(duplicate.displayName) is already added", isGood: false, saved: false)
        }
        let health = await probeCandidate(found)
        let message: String
        switch health {
        case .ok(let detail): message = (["Connected", found.kind.label] + [detail].compactMap { $0 }).joined(separator: " · ")
        case .rejected(let reason), .unreachable(let reason): message = reason
        }
        if save {
            if existing == nil { add(found) } else { update(found) }
        }
        return SourceCheck(config: found, health: health, message: message, isGood: health.isOk, saved: save)
    }

    /// Probes every configured server-backed source, for the Sources screen's status lines, and
    /// stores an addon's own name as its label when it publishes one (settles after one pass).
    public func refreshHealth() async -> [String: SourceHealth] {
        var results: [String: SourceHealth] = [:]
        for config in configs where config.kind.needsServer && config.isComplete {
            guard let source = instance(config.id) else { continue }
            results[config.id] = await source.health()
            if let addon = source as? AddonSource, let named = await addon.manifestName(),
               let current = self.configs.first(where: { $0.id == config.id }), named != current.label {
                var renamed = current
                renamed.label = named
                update(renamed)
            }
        }
        return results
    }

    private nonisolated static func build(_ config: SourceConfig, _ environment: SourceEnvironment) -> MusicSource {
        switch config.kind {
        case .addon:
            return AddonSource(config: config, environment: environment)
        case .customModule, .module:
            // Same protocol, same implementation — the kinds differ only in rank.
            return ModuleSource(config: config, environment: environment)
        case .jioSaavn:
            return JioSaavnSource(config: config, service: JioSaavnService(session: environment.session))
        case .youtube:
            return YouTubeSource(config: config, search: environment.youTubeSearch, streams: environment.youTubeStreams)
        }
    }

    private nonisolated static let builtInKinds: [SourceKind] = [.jioSaavn, .youtube]

    // MARK: Track identity

    /// A source-backed track's id as it travels through the queue, packed into ``Song/videoId`` —
    /// the app's media id everywhere — rather than beside it, where every place that forgot a second
    /// field would silently treat the track as YouTube's.
    public nonisolated static func trackKey(configId: String, trackId: String) -> String {
        "\(trackKeyPrefix)\(configId)\(trackKeySeparator)\(trackId)"
    }

    /// The `(configId, trackId)` inside a ``trackKey(configId:trackId:)``, or nil for a YouTube id.
    /// The first separator splits, so track ids may themselves contain `::`.
    public nonisolated static func parseTrackKey(_ key: String) -> (configId: String, trackId: String)? {
        guard key.hasPrefix(trackKeyPrefix) else { return nil }
        let body = key.dropFirst(trackKeyPrefix.count)
        guard let cut = body.range(of: trackKeySeparator), cut.lowerBound > body.startIndex else { return nil }
        return (String(body[..<cut.lowerBound]), String(body[cut.upperBound...]))
    }

    /// `vibramusic://source?s=…&t=…` for a source-backed track (the same URI PlaybackPolicy's
    /// `PlaybackURI.source` builds, minus the match tail).
    public nonisolated static func trackURI(configId: String, trackId: String) -> String {
        var components = URLComponents()
        components.scheme = "vibramusic"
        components.host = "source"
        components.queryItems = [URLQueryItem(name: "s", value: configId), URLQueryItem(name: "t", value: trackId)]
        return components.string ?? "vibramusic://source"
    }

    nonisolated static let trackKeyPrefix = "src:"
    nonisolated static let trackKeySeparator = "::"
}

/// The outcome of the editor's Test/Save.
public struct SourceCheck: Hashable, Sendable {
    /// What the URL was identified as; nil when it couldn't be.
    public var config: SourceConfig?
    public var health: SourceHealth?
    /// The status line to show.
    public var message: String
    public var isGood: Bool
    public var saved: Bool
}

/// Where the source list lives: one JSON file, written atomically, file-protected until first
/// unlock and excluded from backups (it can hold a private addon token).
public struct SourceConfigStore: Sendable {
    public struct Contents: Codable, Hashable, Sendable {
        public var sources: [SourceConfig]
        /// The one-shot migration marker: existing users must opt in to JioSaavn again.
        public var jioSaavnOptInV1: Bool

        public init(sources: [SourceConfig] = [], jioSaavnOptInV1: Bool = false) {
            self.sources = sources
            self.jioSaavnOptInV1 = jioSaavnOptInV1
        }

        /// One entry at a time: an entry naming a kind this build no longer has must not take every
        /// other entry — the user's working addon among them — down with it.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyCodingKey.self)
            let entries = (try? c.decodeIfPresent([LossyElement<SourceConfig>].self, forKey: AnyCodingKey("sources"))) ?? []
            let dropped = entries.filter { $0.value == nil }.count
            if dropped > 0 { SourcesLog.w("dropping \(dropped) unreadable stored source(s)") }
            sources = entries.compactMap(\.value)
            jioSaavnOptInV1 = c.lenientBool("jioSaavnOptInV1") ?? false
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: AnyCodingKey.self)
            try c.encode(sources, forKey: AnyCodingKey("sources"))
            try c.encode(jioSaavnOptInV1, forKey: AnyCodingKey("jioSaavnOptInV1"))
        }
    }

    public let store: JSONFileStore
    public static let fileName = "sources.json"

    public init(store: JSONFileStore) {
        self.store = store
    }

    public static var standard: SourceConfigStore {
        SourceConfigStore(store: .applicationSupport("Sources", excludedFromBackup: true))
    }

    /// What is stored; nil when nothing is yet. Throws a `DecodingError` when the file is corrupt
    /// and any other error when it exists but can't be read, which a caller must not mistake for a
    /// first run.
    public func load() throws -> Contents? {
        try store.load(Contents.self, from: Self.fileName)
    }

    public func save(_ contents: Contents) {
        do {
            let data = try JSONFileStore.makeEncoder().encode(contents)
            try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
            #endif
            try data.write(to: store.url(for: Self.fileName), options: options)
        } catch {
            SourcesLog.e("could not save sources", error: error)
        }
    }
}
