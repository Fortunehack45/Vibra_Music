import VibraMusicCore
import Foundation
import Observation
import Sources

// The state and rules of ui/screens/SourcesScreen.kt and its editors (SourceEditorAlert,
// ServerEditorHost as MainActivity.kt configured it for WebDAV and SMB), apart from the views.

/// The Sources screen's list: the order sources are tried in, their switches, and what each row's
/// second line says.
@MainActor
@Observable
final class SourcesModel {
    let registry: SourceRegistry
    /// Last known reachability per source, filled in as the probes come back.
    private(set) var health: [String: SourceHealth] = [:]

    init(registry: SourceRegistry) {
        self.registry = registry
    }

    /// Addons first, in the user's drag order: they are the only rows whose order is theirs.
    var addons: [SourceConfig] { registry.configs.filter { $0.kind.isUserAdded } }

    /// Everything else, ranked by kind, which is fixed and not something a drag should argue with.
    var fixed: [SourceConfig] {
        registry.configs.filter { !$0.kind.isUserAdded }.sorted { $0.kind.rank < $1.kind.rank }
    }

    /// Probes every server-backed source so an addon gets a reachability line (the only feedback
    /// that a pasted URL was any good) and takes its manifest's own name.
    func refreshHealth() async {
        let results = await registry.refreshHealth()
        health.merge(results) { _, new in new }
    }

    /// The ceiling in force right now: the only one this screen can speak for.
    static func ceiling(settings: AppSettings, metered: Bool?) -> AudioQuality {
        metered == true ? settings.audioQualityCellular : settings.audioQualityWifi
    }

    /// Switched on, but not reached on this connection. Said on the row rather than by moving the
    /// switch, so the switch keeps meaning "I want this source".
    static func skippedByQuality(_ config: SourceConfig, ceiling: AudioQuality) -> Bool {
        config.enabled && !ceiling.permits(config.kind)
    }

    /// The group's footer: the order rule, then what caps lossless today if anything does.
    func footer(ceiling: AudioQuality) -> String {
        var text = L10n.sourcesOrderFooter
        let anyLosslessSource = registry.configs.contains { $0.enabled && $0.isComplete && $0.kind.canServeLossless }
        if ceiling != .lossless {
            text += "\n\n" + L10n.sourcesQualityCapped
        } else if !anyLosslessSource {
            text += "\n\n" + L10n.sourcesNoLossless
        }
        return text
    }

    /// The second line of a row: what the source is, or what is wrong with it. The ceiling outranks
    /// the health line — a source that won't be asked isn't described by whether it answered.
    func statusLine(_ config: SourceConfig, ceiling: AudioQuality, metered: Bool) -> String {
        if Self.skippedByQuality(config, ceiling: ceiling) {
            return L10n.sourceSkippedByQuality(metered ? L10n.mobileData : L10n.wifi, ceiling.settingsLabel)
        }
        return Self.statusLine(config, health: health[config.id])
    }

    static func statusLine(_ config: SourceConfig, health: SourceHealth?) -> String {
        let labels = config.kind.labels.prefix(3).joined(separator: " · ")
        if !config.isComplete { return L10n.sourceSetupRequired }
        if config.kind == .jioSaavn { return L10n.jiosaavnMismatchWarning }
        switch health {
        case .ok(let detail): return ([detail].compactMap { $0 } + [labels]).joined(separator: " · ")
        case .rejected(let reason): return reason
        case .unreachable(let reason): return L10n.sourceUnreachable(reason)
        case nil: return config.kind.needsServer ? L10n.checking : labels
        }
    }

    /// Only a rejection is coloured: a server that is merely down will be up again on its own.
    func isRejected(_ config: SourceConfig) -> Bool {
        if case .rejected = health[config.id] { return true }
        return false
    }

    /// YouTube gets no switch at all: it can't be switched off.
    static func hasSwitch(_ config: SourceConfig) -> Bool { config.kind != .youtube }

    /// Anything the user configured is theirs to edit; JioSaavn and YouTube have no address.
    static func isEditable(_ config: SourceConfig) -> Bool { config.kind.needsServer }

    /// Flips a source. Returns true instead when turning JioSaavn on needs the mismatch warning
    /// confirmed first (then call ``confirmJioSaavn()``).
    func setEnabled(_ config: SourceConfig, _ on: Bool) -> Bool {
        if config.kind == .jioSaavn && on && !config.enabled { return true }
        registry.setEnabled(config.id, on)
        return false
    }

    func confirmJioSaavn() {
        if let jioSaavn = registry.configs.first(where: { $0.kind == .jioSaavn }) {
            registry.setEnabled(jioSaavn.id, true)
        }
    }

    /// A drag within the addons.
    func moveAddons(from source: IndexSet, to destination: Int) {
        var ids = addons.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        registry.reorderAddons(ids)
    }
}

/// Add or edit a source that has an address (SourcesScreen.kt `SourceEditorAlert`).
///
/// Test is offered rather than required: a server that happens to be asleep is still worth saving.
/// Both buttons identify what is at the URL, refuse a duplicate and probe it; Save then stores a
/// success even when the probe was unhappy, but never a URL nothing can be made of.
@MainActor
@Observable
final class AddonEditorModel {
    let registry: SourceRegistry
    let original: SourceConfig
    let isNew: Bool
    /// Changing the address clears the result: it described the address it was run against.
    var url: String { didSet { if url != oldValue { status = nil } } }
    private(set) var busy = false
    private(set) var status: String?
    private(set) var statusIsGood = false

    init(registry: SourceRegistry, config: SourceConfig) {
        self.registry = registry
        original = config
        isNew = registry.config(config.id) == nil
        url = config.baseUrl
    }

    var title: String { isNew ? L10n.addAddon : original.displayName }
    var canSubmit: Bool { !url.trimmingCharacters(in: .whitespaces).isEmpty && !busy }

    /// Runs the check; returns true when the source was stored.
    @discardableResult
    func run(save: Bool) async -> Bool {
        busy = true
        status = nil
        defer { busy = false }
        let editing = isNew ? nil : original
        let found: SourceConfig
        do {
            found = try await registry.identify(url.trimmingCharacters(in: .whitespacesAndNewlines), editing: editing)
        } catch {
            statusIsGood = false
            let message = error.localizedDescription
            status = message.isEmpty ? L10n.sourceUnrecognised : message
            return false
        }
        // Checked against the identified base rather than the typed text, so an addon's root and
        // its manifest.json are recognised as the one source they are.
        if let existing = registry.duplicateOf(found.baseUrl, exceptId: editing?.id) {
            statusIsGood = false
            status = L10n.sourceAlreadyAdded(existing.displayName)
            return false
        }
        let health = await registry.probeCandidate(found)
        statusIsGood = health.isOk
        switch health {
        case .ok(let detail): status = ([L10n.connected, found.kind.label] + [detail].compactMap { $0 }).joined(separator: " · ")
        case .rejected(let reason), .unreachable(let reason): status = reason
        }
        guard save else { return false }
        if isNew { registry.add(found) } else { registry.update(found) }
        return true
    }

    func remove() {
        registry.remove(original.id)
    }
}

/// One personal library behind a server: WebDAV or SMB.
@MainActor
enum RemoteLibraryKind: String, Identifiable {
    case webDAV, smb
    nonisolated var id: String { rawValue }

    var title: String { self == .webDAV ? L10n.webdav : L10n.smb }
    var description: String { self == .webDAV ? L10n.webdavDescription : L10n.smbDescription }
    var symbol: String { self == .webDAV ? "cloud" : "externaldrive.connected.to.line.below" }
    var listSubtitle: String { self == .webDAV ? L10n.webdavSubtitle : L10n.smbSubtitle }
    var disconnectTitle: String { self == .webDAV ? L10n.webdavDisconnect : L10n.smbDisconnect }

    func testFailed(_ reason: String) -> String {
        self == .webDAV ? L10n.webdavTestFailed(reason) : L10n.smbTestFailed(reason)
    }

    func isConfigured(_ settings: AppSettings) -> Bool {
        self == .webDAV ? settings.isWebDAVConfigured : settings.isSMBConfigured
    }

    /// "server · user", "host · share · user", or "not set up".
    func summary(_ settings: AppSettings) -> String {
        switch self {
        case .webDAV:
            if settings.webdavUrl.isEmpty { return L10n.webdavNotConfigured }
            return settings.webdavUsername.isEmpty ? settings.webdavUrl : "\(settings.webdavUrl) · \(settings.webdavUsername)"
        case .smb:
            if !settings.isSMBConfigured { return L10n.smbNotConfigured }
            let base = "\(settings.smbHost) · \(settings.smbShare)"
            return settings.smbUsername.isEmpty ? base : "\(base) · \(settings.smbUsername)"
        }
    }

    /// The editor's fields, opening on the saved values.
    func fields(_ settings: AppSettings) -> [ServerField] {
        switch self {
        case .webDAV:
            return [
                ServerField(placeholder: L10n.webdavServerUrlHint, value: settings.webdavUrl, kind: .url),
                ServerField(placeholder: L10n.username, value: settings.webdavUsername),
                ServerField(placeholder: L10n.password, value: settings.webdavPassword, kind: .password),
            ]
        case .smb:
            return [
                ServerField(placeholder: L10n.smbServerHint, value: settings.smbHost, kind: .url),
                ServerField(placeholder: L10n.smbShareHint, value: settings.smbShare),
                ServerField(placeholder: L10n.smbFolderHint, value: settings.smbBasePath),
                ServerField(placeholder: L10n.username, value: settings.smbUsername),
                ServerField(placeholder: L10n.password, value: settings.smbPassword, kind: .password),
            ]
        }
    }

    /// WebDAV needs its URL; SMB its host and share.
    func canSubmit(_ values: [String]) -> Bool {
        let filled = values.map { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return self == .webDAV ? filled.first == true : filled.count >= 2 && filled[0] && filled[1]
    }

    /// Stores the fields, trimmed (passwords as typed).
    func save(_ values: [String], to settings: AppSettings) {
        let v = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        switch self {
        case .webDAV:
            settings.configureWebDAV(url: v[0], username: v[1], password: values[2])
        case .smb:
            settings.configureSMB(host: v[0], share: v[1], basePath: v[2], username: v[3], password: values[4])
        }
    }

    func disconnect(_ settings: AppSettings) {
        self == .webDAV ? settings.clearWebDAV() : settings.clearSMB()
    }
}

/// One field of a server editor.
struct ServerField: Hashable {
    enum Kind { case text, url, password }
    let placeholder: String
    var value: String
    var kind: Kind = .text
}

/// Runs a connection test against the values in an editor or the saved ones. Injected so tests
/// don't need a server.
typealias RemoteLibraryTester = @MainActor (RemoteLibraryKind, [String]) async throws -> Void

/// The result line of a Test action: "Connected" or "<kind> test failed: <reason>".
@MainActor
func remoteLibraryTestResult(_ kind: RemoteLibraryKind, values: [String], tester: RemoteLibraryTester) async -> (message: String, ok: Bool) {
    do {
        try await tester(kind, values)
        return (L10n.connected, true)
    } catch {
        let reason = error.localizedDescription
        return (kind.testFailed(reason.isEmpty ? L10n.failed : reason), false)
    }
}
