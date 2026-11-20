import VibraMusicCore
import XCTest
@testable import Lyrics

/// Lyrics uses Core's `LyricsSource` rather than a copy, so settings pass straight through.
final class LyricsSourceIdentityTests: XCTestCase {

    func testLyricsAndCoreNameTheSameType() {
        XCTAssertTrue(Lyrics.LyricsSource.self == VibraMusicCore.LyricsSource.self)
        // A file importing both modules can still write the bare name.
        let source: LyricsSource = .youtubeMusic
        XCTAssertEqual(source.rawValue, "YOUTUBE_MUSIC")
    }

    @MainActor
    func testSettingsFeedPreferencesWithoutConversion() {
        let core: [VibraMusicCore.LyricsSource] = [.genius, .lrcLib]
        let preferences = LyricsPreferences(enabledSources: Set(core), sourceOrder: core)
        XCTAssertEqual(preferences.sourceOrder, core)
        XCTAssertEqual(LyricsSource.sourceOrder(stored: LyricsSource.storageString(core)).prefix(2), [.genius, .lrcLib])
    }
}
