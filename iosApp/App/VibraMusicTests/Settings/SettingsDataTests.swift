import VibraMusicCore
import Replay
import SwiftUI
import XCTest
@testable import VibraMusic

/// PORTING §2.11 "Backup and restore": settings and listening stats as JSON, credentials left out.
@MainActor
final class SettingsBackupTests: XCTestCase {
    private func makeStats() -> ReplayListeningStats {
        let directory = FileManager.default.temporaryDirectory.appending(path: "settings-replay-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ReplayListeningStats(store: JSONFileStore(directory: directory))
    }

    private func history() -> SearchHistory {
        SearchHistory(defaults: UserDefaults(suiteName: "vibramusic.settings.backup.\(UUID().uuidString)")!)
    }

    /// The done criterion: a file exported on one iPhone restores stats (and settings) on another.
    func testAFileExportedOnOnePhoneRestoresStatsAndSettingsOnAnother() throws {
        let phoneA = makeSettingsTestSettings()
        phoneA.crossfadeSeconds = 7
        phoneA.themeMode = .light
        phoneA.lastfmSessionKey = "secret-session"
        let statsA = makeStats()
        try statsA.importAll([ReplayStoredBucket(month: "2026-08", days: [3: 60_000]),
                          ReplayStoredBucket(month: "2026-09", days: [1: 120_000])])
        let exported = try SettingsBackup(settings: phoneA, stats: statsA, searchHistory: history(), versionName: "2.0").export()
        XCTAssertEqual(exported.months, 2)
        // Credentials never travel.
        XCTAssertFalse(String(decoding: exported.data, as: UTF8.self).contains("secret-session"))

        let phoneB = makeSettingsTestSettings()
        let statsB = makeStats()
        let summary = try SettingsBackup(settings: phoneB, stats: statsB, searchHistory: history()).restore(from: exported.data)
        XCTAssertEqual(summary.months, 2)
        XCTAssertEqual(summary.from, "2.0")
        XCTAssertEqual(statsB.exportAll().map(\.month).sorted(), ["2026-08", "2026-09"])
        XCTAssertEqual(phoneB.crossfadeSeconds, 7)
        XCTAssertEqual(phoneB.themeMode, .light)
        XCTAssertEqual(phoneB.lastfmSessionKey, "")
        XCTAssertEqual(SettingsBackup.importStatus(.success(summary)), L10n.importSucceeded(L10n.listeningMonthCount(2), "2.0"))
    }

    func testARefusedFileChangesNothingAndSaysWhy() throws {
        let settings = makeSettingsTestSettings()
        settings.crossfadeSeconds = 4
        let stats = makeStats()
        try stats.importAll([ReplayStoredBucket(month: "2026-07", days: [2: 1_000])])
        let backup = SettingsBackup(settings: settings, stats: stats, searchHistory: history())
        let result = Result { try backup.restore(from: Data("{\"hello\":1}".utf8)) }
        guard case .failure = result else { return XCTFail("a non-backup must be refused") }
        XCTAssertEqual(settings.crossfadeSeconds, 4)
        XCTAssertEqual(stats.exportAll().map(\.month), ["2026-07"])
        XCTAssertEqual(SettingsBackup.importStatus(result.map { $0 }), L10n.importFailed("That doesn't look like a Vibra Music backup"))
    }

    func testTheRowsSayHowManyMonthsWent() {
        XCTAssertEqual(SettingsBackup.exportStatus(.success(0)), L10n.exportSucceeded(L10n.noListeningHistory))
        XCTAssertEqual(SettingsBackup.exportStatus(.success(3)), L10n.exportSucceeded(L10n.listeningMonthCount(3)))
    }

    func testTheDocumentCarriesTheBytes() throws {
        let document = SettingsBackupDocument(data: Data("{}".utf8))
        XCTAssertEqual(document.data, Data("{}".utf8))
        XCTAssertTrue(SettingsBackupDocument.writableContentTypes.contains(.json))
    }
}

/// PORTING §2.11 "App language": sixteen languages; Hebrew mirrors the layout.
@MainActor
final class AppLanguageTests: XCTestCase {
    override func tearDown() {
        LanguageBundle.override = nil
        super.tearDown()
    }

    func testTheSixteenLanguagesInAndroidsOrderAllShip() {
        XCTAssertEqual(AppLanguage.all.map(\.code),
                       ["en", "es", "fr", "de", "pl", "pt", "id", "hi", "ja", "ru", "zh-Hans", "he", "it", "tr", "th", "vi"])
        XCTAssertEqual(Set(AppLanguage.all.map(\.code)), Set(LanguageBundle.supported))
    }

    func testTheCurrentLanguageIsTheChoiceElseTheSystemsElseEnglish() {
        XCTAssertEqual(AppLanguage.current(override: "ja", preferred: ["de-DE"]).code, "ja")
        XCTAssertEqual(AppLanguage.current(override: nil, preferred: ["pt-BR", "en"]).code, "pt")
        XCTAssertEqual(AppLanguage.current(override: nil, preferred: ["zh-Hans-CN"]).code, "zh-Hans")
        XCTAssertEqual(AppLanguage.current(override: nil, preferred: ["zh-Hant-TW", "ko"]).code, "en")
        XCTAssertEqual(AppLanguage.current(override: nil, preferred: ["ko-KR"]).code, "en")
    }

    /// The done criterion: switching to Hebrew mirrors the layout right to left.
    func testChoosingHebrewMirrorsTheLayoutAndRebuildsTheUI() {
        let app = makeSettingsTestApp(settings: makeSettingsTestSettings())
        let revision = app.languageRevision
        app.setLanguage("he")
        XCTAssertEqual(app.languageRevision, revision + 1)
        XCTAssertEqual(LanguageBundle.layoutDirection, .rightToLeft)
        XCTAssertEqual(AppLanguage.current().code, "he")
        app.setLanguage("en")
        XCTAssertEqual(LanguageBundle.layoutDirection, .leftToRight)
    }

    func testThePickerAndTheScreenRenderRightToLeft() {
        settingsHostAndLayOut(AppLanguagePicker(selected: AppLanguage.all[11], onSelect: { _ in })
            .environment(\.layoutDirection, .rightToLeft))
        let app = makeSettingsTestApp(settings: makeSettingsTestSettings())
        LanguageBundle.override = "he"
        settingsHostAndLayOut(NavigationStack { SettingsScreen() }
            .settingsTestEnvironment(app)
            .environment(\.layoutDirection, .rightToLeft))
    }
}
