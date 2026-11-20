import XCTest
import VibraMusicTestSupport
import VibraMusicCore
@testable import Replay

// Backup round-trips, Android-format import, and refusal of anything that isn't one of ours.

final class ReplayBackupTests: XCTestCase {
    func testRoundTrip() throws {
        let bucket = ReplayStoredBucket(
            month: "2026-08",
            tracks: [ReplayTrackEntry(id: "a", title: "Song", artist: "Artist", ms: 60_000, plays: 2, last: 1)],
            artists: [ReplayNameEntry(name: "Artist", ms: 60_000, plays: 2)],
            hours: (0..<24).map { $0 == 17 ? 60_000 : 0 },
            days: [14: 60_000]
        )
        let settings: [String: SettingValue] = [
            "autoplay": .bool(true),
            "crossfade_seconds": .int(6),
            "audio_cache_limit_bytes": .long(1_073_741_824),
            "playback_speed": .float(1.5),
            "theme_mode": .string("DARK"),
            "pinned": .stringSet(["PLabc", "PLdef"]),
        ]
        let data = try ReplayBackup.encode(
            versionName: "1.0", exportedAt: "2026-08-14T10:00:00Z",
            settings: settings, listening: [bucket]
        )
        let decoded = try ReplayBackup.decode(data)
        XCTAssertEqual(decoded.versionName, "1.0")
        XCTAssertEqual(decoded.settings, settings)
        XCTAssertEqual(decoded.listening, [bucket])
        XCTAssertEqual(decoded.summary.months, 1)
        XCTAssertEqual(decoded.summary.settings, 6)
    }

    func testAndroidFormatImports() throws {
        let fixtures = FixtureLoader(bundle: .module)
        let data = try fixtures.data("android-backup.json")
        let backup = try ReplayBackup.decode(data)
        XCTAssertEqual(backup.versionName, "3.2.1")
        XCTAssertEqual(backup.summary.months, 1)
        // Every typed preference survives the platform hop with its type.
        XCTAssertEqual(backup.settings["autoplay"], .bool(true))
        XCTAssertEqual(backup.settings["crossfade_seconds"], .int(6))
        XCTAssertEqual(backup.settings["playback_speed"], .float(1.5))
        XCTAssertEqual(backup.settings["replay_genres"], .bool(false))
        // Listening lands with its totals, hours and days intact.
        let bucket = try XCTUnwrap(backup.listening.first)
        XCTAssertEqual(bucket.month, "2026-07")
        XCTAssertEqual(bucket.tracks.first?.title, "Never Gonna Give You Up")
        XCTAssertEqual(bucket.tracks.first?.plays, 5)
        XCTAssertEqual(bucket.hours[17], 1_250_000)
        XCTAssertEqual(bucket.days[14], 1_250_000)

        // And the restored device draws the same Replay.
        let dir = try makeTemporaryDirectory()
        let stats = ReplayListeningStats(store: JSONFileStore(directory: dir), calendar: replayUTCCalendar())
        try stats.importAll(backup.listening)
        let summary = stats.summary(for: .allTime, today: replayUTCDate(2026, 8, 14))
        XCTAssertEqual(summary.songs.map(\.song.title), ["Never Gonna Give You Up"])
        XCTAssertEqual(summary.artists.map(\.title), ["Rick Astley"])
        XCTAssertEqual(summary.albums.map(\.title), ["Whenever You Need Somebody"])
        XCTAssertEqual(summary.peakHour, 17)
    }

    func testAndroidSettingsApplyToAppSettings() async throws {
        let fixtures = FixtureLoader(bundle: .module)
        let backup = try ReplayBackup.decode(fixtures.data("android-backup.json"))
        let defaults = makeEphemeralDefaults()
        let applied: Int = await MainActor.run {
            let settings = AppSettings(defaults: defaults, credentials: InMemoryCredentialStore())
            let count = settings.importPrefs(backup.settings)
            XCTAssertTrue(settings.autoplay)
            XCTAssertEqual(settings.crossfadeSeconds, 6)
            XCTAssertFalse(settings.replayGenres)
            // Current Android writes pins comma-joined; a string set (older backups) restores too,
            // sorted since a set carries no order.
            // (The fixture lists them out of order, so only a real sort puts them right.)
            XCTAssertEqual(settings.pinnedPlaylists, ["PLabc", "PLdef"])
            return count
        }
        XCTAssertEqual(applied, 6)
    }

    func testRefusals() {
        XCTAssertThrowsError(try ReplayBackup.decode(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? ReplayBackupError, .notAVibraMusicBackup)
        }
        XCTAssertThrowsError(try ReplayBackup.decode(Data("{}".utf8))) { error in
            XCTAssertEqual(error as? ReplayBackupError, .notAVibraMusicBackup)
        }
        XCTAssertThrowsError(try ReplayBackup.decode(Data(#"{"app":"otherapp"}"#.utf8))) { error in
            XCTAssertEqual(error as? ReplayBackupError, .foreignBackup(app: "otherapp"))
        }
        XCTAssertThrowsError(try ReplayBackup.decode(Data(#"{"app":"vibramusic","version":99,"versionName":"9.9","exportedAt":"now"}"#.utf8))) { error in
            XCTAssertEqual(error as? ReplayBackupError, .newerSchema(version: 99))
        }
    }

    func testUnknownSettingTypesSurviveAsUnsupported() throws {
        let data = Data(#"{"app":"vibramusic","version":1,"versionName":"x","exportedAt":"y","settings":{"mystery":{"type":"double","value":"1.5"}}}"#.utf8)
        let backup = try ReplayBackup.decode(data)
        XCTAssertEqual(backup.settings["mystery"], .unsupported(type: "double"))
    }

    func testSuggestedName() {
        XCTAssertEqual(
            ReplayBackup.suggestedName(on: replayUTCDate(2026, 8, 14), calendar: replayUTCCalendar()),
            "vibramusic-backup-2026-08-14.json"
        )
    }
}
