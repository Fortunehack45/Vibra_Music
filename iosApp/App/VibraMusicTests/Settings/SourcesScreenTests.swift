import VibraMusicCore
import Sources
import SwiftUI
import XCTest
@testable import Vibra Music

/// PORTING §2.8 "Add-on sources (lossless)", "JioSaavn source", "Legacy JS module sources", and the
/// SMB / WebDAV connection setup, as the Sources screen drives them.
@MainActor
final class SourcesScreenModelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SettingsStubURLProtocol.reset()
    }

    private let manifest = #"{"id":"com.test.addon","name":"Test Addon","version":"2.1.0","resources":["search","stream"]}"#

    // MARK: Add-on sources

    func testAddingAnAddonTestsItThenSavesItUnderItsOwnName() async {
        SettingsStubURLProtocol.reply("addon.test/manifest.json", json: manifest)
        let registry = makeSettingsTestRegistry()
        let editor = AddonEditorModel(registry: registry, config: SourceConfig(kind: .addon))
        XCTAssertTrue(editor.isNew)
        XCTAssertEqual(editor.title, L10n.addAddon)
        XCTAssertFalse(editor.canSubmit)

        editor.url = "https://addon.test/manifest.json"
        let stored = await editor.run(save: false)
        XCTAssertFalse(stored)
        XCTAssertTrue(editor.statusIsGood)
        XCTAssertEqual(editor.status?.hasPrefix(L10n.connected), true)
        XCTAssertFalse(registry.configs.contains { $0.kind == .addon }, "Test must not store anything")

        // Editing the address clears a result that no longer describes it.
        editor.url = "https://addon.test"
        XCTAssertNil(editor.status)
        let saved = await editor.run(save: true)
        XCTAssertTrue(saved)
        XCTAssertEqual(registry.configs.first { $0.kind == .addon }?.label, "Test Addon")

        // The same addon again is refused, by name.
        let again = AddonEditorModel(registry: registry, config: SourceConfig(kind: .addon))
        again.url = "https://addon.test/"
        let savedAgain = await again.run(save: true)
        XCTAssertFalse(savedAgain)
        XCTAssertEqual(again.status, L10n.sourceAlreadyAdded("Test Addon"))
        XCTAssertEqual(registry.configs.filter { $0.kind == .addon }.count, 1)
    }

    func testAnAddressThatIsNothingIsNotSaved() async {
        let registry = makeSettingsTestRegistry()
        let editor = AddonEditorModel(registry: registry, config: SourceConfig(kind: .addon))
        editor.url = "https://nothing.test"
        let saved = await editor.run(save: true)
        XCTAssertFalse(saved)
        XCTAssertFalse(editor.statusIsGood)
        XCTAssertNotNil(editor.status)
        XCTAssertFalse(registry.configs.contains { $0.kind == .addon })
    }

    func testAddonsComeFirstInTheirDragOrderAndTheRestByRank() {
        let a = SourceConfig(id: "a", kind: .addon, label: "A", baseUrl: "https://a.test")
        let b = SourceConfig(id: "b", kind: .addon, label: "B", baseUrl: "https://b.test")
        let c = SourceConfig(id: "c", kind: .addon, label: "C", baseUrl: "https://c.test")
        let model = SourcesModel(registry: makeSettingsTestRegistry([a, b, c]))
        XCTAssertEqual(model.fixed.map(\.kind), [.jioSaavn, .youtube])
        let before = model.addons.map(\.id)
        XCTAssertEqual(Set(before), ["a", "b", "c"])
        // Drag the last addon to the top.
        model.moveAddons(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(model.addons.map(\.id), [before[2], before[0], before[1]])
    }

    func testRowsSayWhatIsWrongOrWhatTheSourceIs() {
        let addon = SourceConfig(id: "a", kind: .addon, label: "A", baseUrl: "https://a.test")
        XCTAssertEqual(SourcesModel.statusLine(addon, health: nil), L10n.checking)
        XCTAssertEqual(SourcesModel.statusLine(addon, health: .ok(detail: "v2")), "v2 · FLAC · Lossless · Hi-Res")
        XCTAssertEqual(SourcesModel.statusLine(addon, health: .unreachable("timed out")), L10n.sourceUnreachable("timed out"))
        XCTAssertEqual(SourcesModel.statusLine(addon, health: .rejected("no stream resource")), "no stream resource")
        XCTAssertEqual(SourcesModel.statusLine(SourceConfig(kind: .addon), health: nil), L10n.sourceSetupRequired)
        XCTAssertEqual(SourcesModel.statusLine(SourceConfig(kind: .youtube), health: nil), "Lossy · Full catalogue · Radio")
    }

    /// Under a High ceiling addons are skipped: the row says so and the footer says what caps it.
    func testTheCeilingInForceSkipsSourcesItDoesNotPermit() {
        let addon = SourceConfig(id: "a", kind: .addon, label: "A", baseUrl: "https://a.test")
        let model = SourcesModel(registry: makeSettingsTestRegistry([addon]))
        XCTAssertTrue(SourcesModel.skippedByQuality(addon, ceiling: .high))
        XCTAssertFalse(SourcesModel.skippedByQuality(addon, ceiling: .lossless))
        XCTAssertEqual(model.statusLine(addon, ceiling: .high, metered: true), L10n.sourceSkippedByQuality(L10n.mobileData, L10n.high))
        XCTAssertTrue(model.footer(ceiling: .high).hasSuffix(L10n.sourcesQualityCapped))
        XCTAssertFalse(model.footer(ceiling: .lossless).contains(L10n.sourcesNoLossless))
        XCTAssertTrue(SourcesModel(registry: makeSettingsTestRegistry()).footer(ceiling: .lossless).hasSuffix(L10n.sourcesNoLossless))
    }

    func testAnAddonCanBeSwitchedOffAndYouTubeCannot() {
        let addon = SourceConfig(id: "a", kind: .addon, label: "A", baseUrl: "https://a.test")
        let model = SourcesModel(registry: makeSettingsTestRegistry([addon]))
        XCTAssertFalse(model.setEnabled(addon, false))
        XCTAssertEqual(model.registry.config("a")?.enabled, false)
        let youtube = model.fixed.first { $0.kind == .youtube }!
        XCTAssertFalse(SourcesModel.hasSwitch(youtube))
        XCTAssertFalse(SourcesModel.isEditable(youtube))
    }

    // MARK: JioSaavn

    func testTurningJioSaavnOnAsksFirstThenEnablesIt() {
        let model = SourcesModel(registry: makeSettingsTestRegistry())
        let jioSaavn = model.fixed.first { $0.kind == .jioSaavn }!
        XCTAssertFalse(jioSaavn.enabled, "off until opted into")
        XCTAssertEqual(SourcesModel.statusLine(jioSaavn, health: nil), L10n.jiosaavnMismatchWarning)
        XCTAssertTrue(model.setEnabled(jioSaavn, true), "needs the warning confirmed")
        XCTAssertEqual(model.registry.config(jioSaavn.id)?.enabled, false)
        model.confirmJioSaavn()
        XCTAssertEqual(model.registry.config(jioSaavn.id)?.enabled, true)
        // Switching it off again needs no warning.
        XCTAssertFalse(model.setEnabled(model.registry.config(jioSaavn.id)!, false))
    }

    // MARK: Legacy JS modules

    /// A stored module still runs and is listed, editable and removable; there is no way to add
    /// one (the add row makes an addon).
    func testAStoredLegacyModuleIsListedEditableAndRemovable() {
        let module = SourceConfig(id: "m", kind: .customModule, label: "Old module", baseUrl: "https://modules.test/index.json")
        let registry = makeSettingsTestRegistry([module])
        let model = SourcesModel(registry: registry)
        XCTAssertEqual(model.addons.map(\.id), ["m"])
        XCTAssertTrue(SourcesModel.isEditable(module))
        XCTAssertTrue(SourcesModel.hasSwitch(module))
        let editor = AddonEditorModel(registry: registry, config: module)
        XCTAssertFalse(editor.isNew)
        XCTAssertEqual(editor.title, "Old module")
        editor.remove()
        XCTAssertNil(registry.config("m"))
    }

    // MARK: WebDAV and SMB

    func testServerEditorsOpenOnTheSavedValuesAndSaveTrimmed() {
        let settings = makeSettingsTestSettings()
        XCTAssertEqual(RemoteLibraryKind.webDAV.summary(settings), L10n.webdavNotConfigured)
        XCTAssertEqual(RemoteLibraryKind.smb.summary(settings), L10n.smbNotConfigured)

        XCTAssertFalse(RemoteLibraryKind.smb.canSubmit(["nas.local", "", "", "", ""]))
        XCTAssertTrue(RemoteLibraryKind.smb.canSubmit(["nas.local", "Music", "", "", ""]))
        RemoteLibraryKind.smb.save([" nas.local ", "Music", "Albums", "me", " pw "], to: settings)
        XCTAssertTrue(RemoteLibraryKind.smb.isConfigured(settings))
        XCTAssertEqual(RemoteLibraryKind.smb.summary(settings), "nas.local · Music · me")
        XCTAssertEqual(RemoteLibraryKind.smb.fields(settings).map(\.value), ["nas.local", "Music", "Albums", "me", " pw "])

        XCTAssertFalse(RemoteLibraryKind.webDAV.canSubmit(["", "u", "p"]))
        RemoteLibraryKind.webDAV.save(["https://dav.test/music", "", "pw"], to: settings)
        XCTAssertEqual(RemoteLibraryKind.webDAV.summary(settings), settings.webdavUrl)
        RemoteLibraryKind.webDAV.disconnect(settings)
        XCTAssertFalse(RemoteLibraryKind.webDAV.isConfigured(settings))
    }

    func testATestSaysConnectedOrWhyNot() async {
        struct Refused: LocalizedError { var errorDescription: String? { "login refused" } }
        let ok = await remoteLibraryTestResult(.smb, values: []) { _, _ in }
        XCTAssertEqual(ok.message, L10n.connected)
        XCTAssertTrue(ok.ok)
        let failed = await remoteLibraryTestResult(.webDAV, values: []) { _, _ in throw Refused() }
        XCTAssertEqual(failed.message, L10n.webdavTestFailed("login refused"))
        XCTAssertFalse(failed.ok)
    }

    // MARK: Rendering

    /// Rows only drag in edit mode; a list that never enters it has an onMove nothing can fire.
    func testTheAddonsListIsInEditModeSoItsRowsCanBeDragged() throws {
        let app = makeSettingsTestApp(settings: makeSettingsTestSettings())
        let registry = makeSettingsTestRegistry([
            SourceConfig(id: "a", kind: .addon, label: "A", baseUrl: "https://a.test"),
            SourceConfig(id: "b", kind: .addon, label: "B", baseUrl: "https://b.test"),
        ])
        let host = settingsHostAndLayOut(NavigationStack {
            SourcesList(model: SourcesModel(registry: registry), metered: false, editing: .constant(nil),
                        editingLibrary: .constant(nil), confirmJioSaavn: .constant(false), tester: { _, _ in })
        }.settingsTestEnvironment(app))
        let list = try XCTUnwrap(host.view.allSubviews.compactMap { $0 as? UICollectionView }.first, "the sources are a List")
        XCTAssertTrue(list.isEditing)
    }

    func testTheScreenAndItsEditorsRender() {
        let settings = makeSettingsTestSettings()
        settings.configureSMB(host: "nas.local", share: "Music", basePath: "", username: "", password: "")
        let app = makeSettingsTestApp(settings: settings)
        let registry = makeSettingsTestRegistry([
            SourceConfig(id: "a", kind: .addon, label: "A", baseUrl: "https://a.test"),
            SourceConfig(id: "b", kind: .addon, label: "B", baseUrl: "https://b.test"),
        ])
        settingsHostAndLayOut(NavigationStack {
            SourcesList(model: SourcesModel(registry: registry), metered: false, editing: .constant(nil),
                        editingLibrary: .constant(nil), confirmJioSaavn: .constant(false), tester: { _, _ in })
        }.settingsTestEnvironment(app))
        settingsHostAndLayOut(NavigationStack { SourcesScreen() }.settingsTestEnvironment(app))
        settingsHostAndLayOut(AddonEditorSheet(model: AddonEditorModel(registry: registry, config: SourceConfig(kind: .addon))))
        settingsHostAndLayOut(ServerEditorSheet(kind: .smb, fields: RemoteLibraryKind.smb.fields(settings), test: { _ in }, onSave: { _ in }))
    }
}
