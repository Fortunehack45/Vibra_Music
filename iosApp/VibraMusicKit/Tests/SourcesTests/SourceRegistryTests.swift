import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import Sources

@MainActor
private func makeRegistry(store: SourceConfigStore? = nil) -> SourceRegistry {
    SourceRegistry(
        store: store,
        environment: SourceEnvironment(session: URLProtocolStub().makeSession(), deviceCodecs: .fixed(false), dolbyAtmosEnabled: { false }),
        factory: { config, _ in FakeSource(config.id, after: 0, format: nil, kind: config.kind, config: config) }
    )
}

/// The addon priority order and duplicate detection. Ported from Android's AddonOrderTest: the
/// ordering is implicit (the stored order is the priority, and `active()` sorts stably by rank), so
/// an unstable sort or a rebuild through a map would break it silently.
@MainActor
final class AddonOrderTests: XCTestCase {

    private func addon(_ name: String) -> SourceConfig {
        SourceConfig(kind: .addon, label: name, baseUrl: "https://\(name).example.com")
    }

    private func seed(_ registry: SourceRegistry, _ names: String...) -> [SourceConfig] {
        let addons = names.map(addon)
        addons.forEach(registry.add)
        return addons
    }

    private func addonLabels(_ registry: SourceRegistry) -> [String] {
        registry.configs.filter(\.kind.isUserAdded).map(\.label)
    }

    func testReorderingPutsTheAddonsInTheOrderGiven() {
        let registry = makeRegistry()
        let addons = seed(registry, "a", "b", "c")
        registry.reorderAddons([addons[2].id, addons[0].id, addons[1].id])
        XCTAssertEqual(addonLabels(registry), ["c", "a", "b"])
        // And that is the order they are asked in.
        XCTAssertEqual(registry.active().prefix(3).map(\.configId), [addons[2].id, addons[0].id, addons[1].id])
    }

    func testReorderingLeavesTheFixedRankSourcesAlone() {
        let registry = makeRegistry()
        let addons = seed(registry, "a", "b")
        registry.reorderAddons([addons[1].id, addons[0].id])
        XCTAssertEqual(registry.configs.map(\.kind), [.addon, .addon, .jioSaavn, .youtube])
    }

    func testAnAddonMissingFromTheOrderIsKeptRatherThanDropped() {
        let registry = makeRegistry()
        let addons = seed(registry, "a", "b", "c")
        registry.reorderAddons([addons[2].id, addons[0].id])
        XCTAssertEqual(addonLabels(registry), ["c", "a", "b"])
    }

    func testAnUnknownIdInTheOrderIsIgnored() {
        let registry = makeRegistry()
        let addons = seed(registry, "a", "b")
        registry.reorderAddons(["not-an-id", addons[1].id, addons[0].id])
        XCTAssertEqual(addonLabels(registry), ["b", "a"])
    }

    func testASingleAddonIsLeftUntouched() {
        let registry = makeRegistry()
        let addons = seed(registry, "only")
        registry.reorderAddons([addons[0].id])
        XCTAssertEqual(addonLabels(registry), ["only"])
    }

    /// Every search and stream lookup run twice per track against one server is the "you are
    /// spamming me" shape an addon operator notices.
    func testAnExactRepeatOfAConfiguredURLIsADuplicate() {
        let registry = makeRegistry()
        let addons = seed(registry, "a")
        XCTAssertEqual(registry.duplicateOf(addons[0].baseUrl)?.id, addons[0].id)
    }

    func testATrailingSlashDoesNotMakeANewSource() {
        let registry = makeRegistry()
        let addons = seed(registry, "a")
        XCTAssertEqual(registry.duplicateOf(addons[0].baseUrl + "/")?.id, addons[0].id)
    }

    func testADifferentlyCasedHostIsTheSameSource() {
        let registry = makeRegistry()
        _ = seed(registry, "a")
        XCTAssertNotNil(registry.duplicateOf("https://A.EXAMPLE.COM"))
    }

    /// The path is not case-folded: it can carry a token, and two tokens differing only in case are
    /// two credentials.
    func testPathsDifferingOnlyInCaseAreDifferentSources() {
        let registry = makeRegistry()
        registry.add(SourceConfig(kind: .addon, baseUrl: "https://host.example.com/AbC"))
        XCTAssertNil(registry.duplicateOf("https://host.example.com/abc"))
        XCTAssertNotNil(registry.duplicateOf("https://host.example.com/AbC"))
    }

    func testASourceIsNotItsOwnDuplicateWhenItIsTheOneBeingEdited() {
        let registry = makeRegistry()
        let addons = seed(registry, "a")
        XCTAssertNil(registry.duplicateOf(addons[0].baseUrl, exceptId: addons[0].id))
    }

    func testAnUnconfiguredURLIsNotADuplicate() {
        let registry = makeRegistry()
        _ = seed(registry, "a")
        XCTAssertNil(registry.duplicateOf("https://b.example.com"))
    }

    func testABlankURLNeverMatchesTheBuiltInSources() {
        let registry = makeRegistry()
        _ = seed(registry, "a")
        XCTAssertNil(registry.duplicateOf(""))
        XCTAssertNil(registry.duplicateOf("   "))
    }

    /// An addon's root and its manifest.json are one server typed two ways: stored normalised, so
    /// the two spellings compare equal.
    func testAnAddonURLIsStoredNormalised() {
        let registry = makeRegistry()
        registry.add(SourceConfig(kind: .addon, baseUrl: "https://b.example.com/tok/manifest.json"))
        XCTAssertEqual(registry.configs.first { $0.kind == .addon }?.baseUrl, "https://b.example.com/tok")
        XCTAssertNotNil(registry.duplicateOf(AddonClient.normalizeBase("https://b.example.com/tok/manifest.json")))
    }
}

/// Seeding, the JioSaavn opt-in, editing rules, persistence and track identity.
@MainActor
final class SourceRegistryTests: XCTestCase {

    func testJioSaavnIsOffByDefaultOnAFreshInstall() {
        XCTAssertFalse(SourceConfig(kind: .jioSaavn).enabled)
        let sources = SourceRegistry.sourcesForInit([], forceJioSaavnOff: true)
        XCTAssertEqual(sources.filter { $0.kind == .jioSaavn }.map(\.enabled), [false])
        XCTAssertEqual(sources.filter { $0.kind == .youtube }.map(\.enabled), [true])
    }

    func testTheOptInMigrationDisablesJioSaavnOnceForExistingInstalls() {
        let migrated = SourceRegistry.sourcesForInit([SourceConfig(kind: .jioSaavn, enabled: true)], forceJioSaavnOff: true)
        XCTAssertFalse(migrated.first { $0.kind == .jioSaavn }!.enabled)
        let userEnabledAgain = migrated.map { config -> SourceConfig in
            var config = config
            if config.kind == .jioSaavn { config.enabled = true }
            return config
        }
        let nextLaunch = SourceRegistry.sourcesForInit(userEnabledAgain, forceJioSaavnOff: false)
        XCTAssertTrue(nextLaunch.first { $0.kind == .jioSaavn }!.enabled)
    }

    func testTheRetiredBuiltInModuleIsDroppedAndACustomModuleKept() {
        let stored = [
            SourceConfig(kind: .module, baseUrl: "https://secret.example/index.json"),
            SourceConfig(kind: .customModule, baseUrl: "https://mine.example/index.json"),
            SourceConfig(kind: .youtube, enabled: false),
        ]
        let after = SourceRegistry.sourcesForInit(stored, forceJioSaavnOff: false)
        XCTAssertEqual(after.map(\.kind), [.customModule, .youtube, .jioSaavn])
        XCTAssertTrue(after.first { $0.kind == .youtube }!.enabled, "YouTube can't stay off")
    }

    func testDisabledJioSaavnAndAddonsAreExcludedFromTheSourceListUsedByDownloads() {
        let disabledJio = SourceConfig(kind: .jioSaavn, enabled: false)
        let disabledAddon = SourceConfig(kind: .addon, baseUrl: "https://disabled.example", enabled: false)
        let enabledAddon = SourceConfig(kind: .addon, baseUrl: "https://enabled.example", enabled: true)
        let incompleteAddon = SourceConfig(kind: .addon, baseUrl: "  ", enabled: true)
        let youtube = SourceConfig(kind: .youtube)
        let enabled = SourceRegistry.enabledConfigs([disabledJio, disabledAddon, enabledAddon, incompleteAddon, youtube])
        XCTAssertEqual(enabled.map(\.id), [enabledAddon.id, youtube.id])
    }

    func testYouTubeCanBeNeitherSwitchedOffNorRemoved() {
        let registry = makeRegistry()
        let youtube = registry.configs.first { $0.kind == .youtube }!
        registry.setEnabled(youtube.id, false)
        registry.remove(youtube.id)
        XCTAssertEqual(registry.config(youtube.id)?.enabled, true)
        let jio = registry.configs.first { $0.kind == .jioSaavn }!
        registry.remove(jio.id)
        XCTAssertNotNil(registry.config(jio.id), "built-in kinds can't be removed")
        registry.setEnabled(jio.id, true)
        XCTAssertEqual(registry.active().map(\.kind), [.jioSaavn, .youtube])
    }

    func testThePlaybackListFollowsTheConnectionsCeiling() {
        let registry = makeRegistry()
        registry.add(SourceConfig(kind: .addon, baseUrl: "https://a.example"))
        registry.setEnabled(registry.configs.first { $0.kind == .jioSaavn }!.id, true)
        XCTAssertEqual(registry.activeForPlayback(.playback(.lossless)).map(\.kind), [.addon, .jioSaavn, .youtube])
        XCTAssertEqual(registry.activeForPlayback(.playback(.high)).map(\.kind), [.jioSaavn, .youtube])
        XCTAssertEqual(registry.activeForPlayback(.playback(.low)).map(\.kind), [.youtube])
    }

    /// An untouched source keeps its warm instance; an edit that changes where it points gets a
    /// new one, and the old one is released.
    func testEditingRebuildsOnlyTheSourceThatChanged() {
        let registry = makeRegistry()
        registry.add(SourceConfig(id: "a", kind: .addon, baseUrl: "https://a.example"))
        registry.add(SourceConfig(id: "b", kind: .addon, baseUrl: "https://b.example"))
        let a = registry.instance("a")
        let b = registry.instance("b")
        registry.update(SourceConfig(id: "b", kind: .addon, baseUrl: "https://b2.example"))
        XCTAssertTrue(registry.instance("a") === a)
        XCTAssertFalse(registry.instance("b") === b)
    }

    func testTheListSurvivesARelaunchAndAnUnreadableEntryDropsAlone() throws {
        let directory = try makeTemporaryDirectory()
        let store = SourceConfigStore(store: JSONFileStore(directory: directory))
        let registry = makeRegistry(store: store)
        registry.add(SourceConfig(id: "mine", kind: .addon, label: "Mine", baseUrl: "https://mine.example/tok"))
        registry.setEnabled(registry.configs.first { $0.kind == .jioSaavn }!.id, true)

        let relaunched = makeRegistry(store: store)
        XCTAssertEqual(relaunched.configs, registry.configs)
        XCTAssertTrue(relaunched.configs.first { $0.kind == .jioSaavn }!.enabled, "the opt-in ran once and stays done")

        // A kind this build doesn't know, from a newer or older build.
        let file = store.store.url(for: SourceConfigStore.fileName)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var sources = try XCTUnwrap(json["sources"] as? [[String: Any]])
        sources.insert(["id": "future", "kind": "HOLOGRAM", "baseUrl": "x"], at: 0)
        json["sources"] = sources
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let afterFuture = makeRegistry(store: store)
        XCTAssertEqual(afterFuture.configs.map(\.id), registry.configs.map(\.id))
    }

    func testAStoredListThatCannotBeReadIsNotOverwrittenWithTheSeeds() throws {
        let directory = try makeTemporaryDirectory()
        let store = SourceConfigStore(store: JSONFileStore(directory: directory))
        let mine = SourceConfig(id: "mine", kind: .addon, label: "Mine", baseUrl: "https://mine.example/tok")
        let original = try JSONFileStore.makeEncoder().encode(SourceConfigStore.Contents(sources: [mine], jioSaavnOptInV1: true))
        let file = store.store.url(for: SourceConfigStore.fileName)
        try original.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }

        let registry = makeRegistry(store: store)
        registry.add(SourceConfig(id: "other", kind: .addon, baseUrl: "https://other.example"))

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertEqual(try Data(contentsOf: file), original, "an unreadable file is left as it was")
    }

    /// Android stored the list under the same field names; a config written by an older build with
    /// missing fields still loads with the Android defaults.
    func testAStoredConfigMissingFieldsGetsTheAndroidDefaults() throws {
        let decoded = try JSONDecoder().decode(SourceConfigStore.Contents.self, from: Data("""
        {"sources":[{"kind":"JIOSAAVN"},{"kind":"ADDON","baseUrl":"https://x.example","id":"x"}],"jioSaavnOptInV1":true}
        """.utf8))
        XCTAssertEqual(decoded.sources.map(\.kind), [.jioSaavn, .addon])
        XCTAssertFalse(decoded.sources[0].enabled)
        XCTAssertTrue(decoded.sources[1].enabled)
        XCTAssertEqual(decoded.sources[1].displayName, "x.example")
    }

    // MARK: Track identity

    func testTrackKeyRoundTrips() {
        let key = SourceRegistry.trackKey(configId: "cfg-1", trackId: "track-42")
        XCTAssertEqual(SourceRegistry.parseTrackKey(key)?.configId, "cfg-1")
        XCTAssertEqual(SourceRegistry.parseTrackKey(key)?.trackId, "track-42")
    }

    func testTrackKeySurvivesSeparatorsInsideTheTrackId() {
        let parsed = SourceRegistry.parseTrackKey(SourceRegistry.trackKey(configId: "cfg-1", trackId: "al::bum::7"))
        XCTAssertEqual(parsed?.configId, "cfg-1")
        XCTAssertEqual(parsed?.trackId, "al::bum::7")
    }

    func testPlainVideoIdsAreNotSourceKeys() {
        XCTAssertNil(SourceRegistry.parseTrackKey("dQw4w9WgXcQ"))
        XCTAssertNil(SourceRegistry.parseTrackKey(""))
    }

    func testTrackURIsCarryTheConfigAndTrack() {
        let uri = SourceRegistry.trackURI(configId: "c 1", trackId: "tidal:42")
        let items = URLComponents(string: uri)?.queryItems
        XCTAssertTrue(uri.hasPrefix("vibramusic://source?"))
        XCTAssertEqual(items?.first { $0.name == "s" }?.value, "c 1")
        XCTAssertEqual(items?.first { $0.name == "t" }?.value, "tidal:42")
    }

    func testDisplayNameFallsBackToTheHostThenTheKind() {
        XCTAssertEqual(SourceConfig(kind: .addon, label: "Unified", baseUrl: "https://u.example").displayName, "Unified")
        XCTAssertEqual(SourceConfig(kind: .addon, baseUrl: "https://u.example/tok").displayName, "u.example")
        XCTAssertEqual(SourceConfig(kind: .jioSaavn).displayName, "JioSaavn")
    }
}
