import XCTest
import VibraMusicTestSupport
@testable import VibraMusicCore

/// Settings export/import, the half of Backup.kt that Core owns.
@MainActor
final class SettingsBackupTests: XCTestCase {
    /// The part of Android's BackupFile these tests read.
    private struct BackupFile: Decodable {
        let settings: [String: SettingValue]
    }

    private let fixtures = FixtureLoader(bundle: .module)

    private func makeSettings(_ defaults: UserDefaults, _ credentials: CredentialStoring = InMemoryCredentialStore()) -> AppSettings {
        AppSettings(defaults: defaults, credentials: credentials)
    }

    func testExportThenImportRestoresSettingsOnAnotherDevice() {
        let source = makeSettings(makeEphemeralDefaults())
        source.audioQualityCellular = .low
        source.crossfadeSeconds = 8
        source.equalizerBalance = 0.25
        source.audioCacheLimitBytes = 4 * 1_024 * 1_024 * 1_024
        source.themeMode = .system
        source.lyricsSources = [.genius]
        source.togglePinnedPlaylist("VLPL9")

        let target = makeSettings(makeEphemeralDefaults())
        let applied = target.importPrefs(source.exportPrefs())
        XCTAssertGreaterThan(applied, 0)
        XCTAssertEqual(target.audioQualityCellular, .low)
        XCTAssertEqual(target.crossfadeSeconds, 8)
        XCTAssertEqual(target.equalizerBalance, 0.25)
        XCTAssertEqual(target.audioCacheLimitBytes, 4 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(target.themeMode, .system)
        XCTAssertEqual(target.lyricsSources, [.genius])
        XCTAssertEqual(target.pinnedPlaylists, ["VLPL9"])
    }

    func testExportedValuesCarryTheirTypes() {
        let s = makeSettings(makeEphemeralDefaults())
        s.autoplay = false
        s.crossfadeSeconds = 3
        s.audioCacheLimitBytes = 1_024 * 1_024 * 1_024
        s.scrobbleDelayPercent = 0.5
        s.themeMode = .light
        let exported = s.exportPrefs()
        XCTAssertEqual(exported["autoplay"], .bool(false))
        XCTAssertEqual(exported["crossfade_seconds"], .int(3))
        XCTAssertEqual(exported["audio_cache_limit_bytes"], .long(1_024 * 1_024 * 1_024))
        XCTAssertEqual(exported["scrobble_delay_percent"], .float(0.5))
        XCTAssertEqual(exported["theme_mode"], .string("LIGHT"))
    }

    func testEveryKindOfSettingIsExported() {
        // A key declared with the wrong kind would silently fall out of every backup.
        let defaults = makeEphemeralDefaults()
        let s = makeSettings(defaults)
        s.audioQualityWifi = .high
        s.lyricsOffsetMs = 100
        s.playbackSpeed = 1.25
        s.audioCacheLimitBytes = 1_024 * 1_024 * 1_024
        s.discordStatus = "dnd"
        s.hideVolumeBar = true
        let exported = s.exportPrefs()
        for key in AppSettings.Key.allCases where !key.isDeviceLocal {
            if defaults.object(forKey: key.rawValue) != nil {
                XCTAssertNotNil(exported[key.rawValue], "\(key.rawValue) is stored but not exported (wrong kind?)")
            }
        }
    }

    func testCredentialsAndDeviceLocalKeysAreNeverExported() {
        let s = makeSettings(makeEphemeralDefaults())
        s.lastfmSessionKey = "session"
        s.listenBrainzToken = "token"
        s.spotifySpdcToken = "spdc"
        s.setPaxSenixApiKey("pax")
        s.discordToken = "discord"
        s.configureSMB(host: "h", share: "s", basePath: "", username: "u", password: "pw")
        _ = s.consumeVersionUpdate(currentVersionCode: 5)
        s.keepDiagnosticLog = false
        let exported = s.exportPrefs()
        for key in AppSettings.CredentialKey.allCases {
            XCTAssertNil(exported[key.rawValue], "\(key.rawValue) must not leave the device")
        }
        XCTAssertNil(exported["last_version_code"])
        XCTAssertNil(exported["keep_diagnostic_log"], "the log file belongs to this device")
        XCTAssertEqual(exported["smb_host"], .string("h"))
        let values = exported.values.compactMap(\.stringValue)
        XCTAssertFalse(values.contains("session") || values.contains("pw") || values.contains("discord"))
    }

    func testImportReplacesRatherThanMerges() {
        let s = makeSettings(makeEphemeralDefaults())
        s.crossfadeSeconds = 5
        s.hideVolumeBar = true
        s.importPrefs(["theme_mode": .string("LIGHT")])
        XCTAssertEqual(s.themeMode, .light)
        XCTAssertEqual(s.crossfadeSeconds, 0, "a setting absent from the backup returns to its default")
        XCTAssertFalse(s.hideVolumeBar)
    }

    func testImportKeepsCredentialsAndDeviceLocalState() {
        let defaults = makeEphemeralDefaults()
        let credentials = InMemoryCredentialStore()
        let s = makeSettings(defaults, credentials)
        s.lastfmSessionKey = "session"
        _ = s.consumeVersionUpdate(currentVersionCode: 7)
        s.importPrefs(["last_version_code": .int(1), "lastfm_session_key": .string("attacker")])
        XCTAssertEqual(s.lastfmSessionKey, "session")
        XCTAssertEqual(defaults.integer(forKey: "last_version_code"), 7)
        XCTAssertNil(defaults.object(forKey: "lastfm_session_key"))
    }

    /// A backup written by the Android app restores here: typed values, Android-only keys skipped,
    /// device-local keys ignored, search history carried along.
    func testRestoresABackupWrittenByAndroid() throws {
        let file = try fixtures.decode(BackupFile.self, from: "android_backup.json")
        XCTAssertEqual(file.settings["from_a_newer_build"], .unsupported(type: "double"))
        XCTAssertEqual(file.settings["downloaded_tracks"], .stringSet(["dQw4w9WgXcQ"]))

        let defaults = makeEphemeralDefaults()
        let s = makeSettings(defaults)
        s.importPrefs(file.settings)

        XCTAssertEqual(s.audioQualityWifi, .high)
        XCTAssertEqual(s.audioQualityCellular, .low)
        XCTAssertEqual(s.downloadQuality, .standard)
        XCTAssertFalse(s.wifiOnlyDownloads)
        XCTAssertEqual(s.crossfadeSeconds, 6)
        XCTAssertEqual(s.equalizerBalance, 0.25)
        XCTAssertEqual(s.equalizerBands, [6, 4, 1.5, 0, 0, 0, 0])
        XCTAssertEqual(s.audioCacheLimitBytes, 1_073_741_824)
        XCTAssertEqual(s.playbackSpeed, 1.0)
        XCTAssertEqual(s.repeatMode, .all)
        XCTAssertFalse(s.autoplay)
        XCTAssertEqual(s.themeMode, .light)
        XCTAssertEqual(s.lyricsSources, [.lrcLib, .genius])
        XCTAssertEqual(s.detailSongSort(for: "MPREb_abc"), .titleDesc)
        XCTAssertEqual(s.pinnedPlaylists, ["VLPL1", "VLPL2"])
        XCTAssertEqual(s.scrobbleDelayPercent, 0.75)
        XCTAssertNil(defaults.object(forKey: "output_pcm_mode"), "Android-only settings are not imported")
        XCTAssertNil(defaults.object(forKey: "downloaded_tracks"))
        XCTAssertNil(defaults.object(forKey: "last_version_code"))

        let history = SearchHistory(defaults: defaults)
        XCTAssertEqual(history.recent.map(\.id), ["MPREb_abc"])
    }

    func testSettingValueEncodesAsAndroidsPrefValue() throws {
        let values: [String: SettingValue] = [
            "b": .bool(true), "i": .int(-3), "l": .long(10_737_418_240), "f": .float(0.5),
            "s": .string("x"), "set": .stringSet(["b", "a"]),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(values), as: UTF8.self)
        XCTAssertEqual(json, #"{"b":{"type":"bool","value":"true"},"f":{"type":"float","value":"0.5"},"i":{"type":"int","value":"-3"},"l":{"type":"long","value":"10737418240"},"s":{"type":"string","value":"x"},"set":{"type":"stringSet","values":["a","b"]}}"#)
        XCTAssertEqual(try JSONDecoder().decode([String: SettingValue].self, from: Data(json.utf8)), values)
    }

    func testMalformedValuesDecodeAsUnsupportedAndAreSkipped() throws {
        let json = #"{"autoplay":{"type":"bool","value":"yes"},"crossfade_seconds":{"type":"int","value":"x"},"theme_mode":{"type":"string"}}"#
        let values = try JSONDecoder().decode([String: SettingValue].self, from: Data(json.utf8))
        XCTAssertEqual(values["autoplay"], .unsupported(type: "bool"))
        let s = makeSettings(makeEphemeralDefaults())
        XCTAssertEqual(s.importPrefs(values), 0)
        XCTAssertTrue(s.autoplay)
    }

    func testNumericTypesAreCoercedToTheKeysKind() {
        let s = makeSettings(makeEphemeralDefaults())
        s.importPrefs(["crossfade_seconds": .long(4), "audio_cache_limit_bytes": .int(1_073_741_824), "playback_speed": .int(2)])
        XCTAssertEqual(s.crossfadeSeconds, 4)
        XCTAssertEqual(s.audioCacheLimitBytes, 1_073_741_824)
        XCTAssertEqual(s.playbackSpeed, 2)
    }

    func testBackupKeysListEveryConfigurationKeyButNotDeviceState() {
        XCTAssertTrue(AppSettings.backupKeys.contains("search_history"))
        XCTAssertTrue(AppSettings.backupKeys.contains("audio_quality_wifi"))
        XCTAssertFalse(AppSettings.backupKeys.contains("last_version_code"))
        XCTAssertFalse(AppSettings.backupKeys.contains("lastfm_session_key"))
    }
}
