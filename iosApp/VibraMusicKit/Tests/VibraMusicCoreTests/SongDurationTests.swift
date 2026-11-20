import XCTest
@testable import VibraMusicCore

/// Ported from SongDurationTest.kt.
///
/// A row's duration arrives as a display string, and lyrics lookups need it back as a quantity.
/// Every way of getting this wrong is silent: LRCLIB ranks on length, so a duration that parses to
/// zero matches the shortest edit of the song and embeds timings for a different recording.
final class SongDurationTests: XCTestCase {
    private func song(_ durationText: String?) -> Song {
        Song(videoId: "id", title: "Title", artist: "Artist", thumbnailUrl: nil, durationText: durationText)
    }

    func testMinutesAndSeconds() {
        XCTAssertEqual(song("3:45").durationMillis, 225_000)
    }

    func testASingleDigitMinuteField() {
        XCTAssertEqual(song("1:02").durationMillis, 62_000)
    }

    func testHoursMinutesAndSeconds() {
        // The long-mix case, which two of Android's older parsers returned 0 for.
        XCTAssertEqual(song("1:02:33").durationMillis, 3_753_000)
    }

    func testSurroundingAndInteriorWhitespaceIsTolerated() {
        XCTAssertEqual(song(" 3 : 45 ").durationMillis, 225_000)
    }

    func testARowWithNoDurationIsZero() {
        XCTAssertEqual(song(nil).durationMillis, 0)
    }

    func testAnythingThatIsNotADurationIsZero() {
        XCTAssertEqual(song("").durationMillis, 0)
        XCTAssertEqual(song("LIVE").durationMillis, 0)
        XCTAssertEqual(song("3:45:xx").durationMillis, 0)
        XCTAssertEqual(song("225").durationMillis, 0)
        XCTAssertEqual(song("1:2:3:4").durationMillis, 0)
    }

    func testANegativeFieldCannotProduceANegativeDuration() {
        XCTAssertEqual(song("-3:45").durationMillis, 0)
    }

    func testFormattingMatchesTheAndroidSourceFormatters() {
        XCTAssertEqual(DurationText.format(millis: 225_999), "3:45")
        XCTAssertEqual(DurationText.format(seconds: 62), "1:02")
        XCTAssertEqual(DurationText.format(seconds: 0), "0:00")
        XCTAssertEqual(DurationText.format(seconds: 4_500), "75:00", "minutes are not rolled into hours")
        XCTAssertEqual(DurationText.format(millis: -5), "0:00")
    }

    func testFormatAndParseRoundTrip() {
        for seconds in [0, 9, 59, 60, 213, 3_599] {
            XCTAssertEqual(DurationText.millis(from: DurationText.format(seconds: seconds)), seconds * 1_000)
        }
    }
}
