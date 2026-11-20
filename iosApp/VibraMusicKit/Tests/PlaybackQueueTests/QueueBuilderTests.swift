import XCTest
import VibraMusicCore
@testable import PlaybackQueue

/// Ports QueueBuilderTest: which of a radio's tracks are worth queueing.
final class QueueBuilderTests: XCTestCase {

    private func song(_ id: String, _ title: String, _ artist: String = "Arijit Singh") -> Song {
        Song(videoId: id, title: title, artist: artist)
    }

    private func video(_ id: String, _ title: String, _ artist: String = "Arijit Singh") -> Song {
        var s = song(id, title, artist)
        s.isVideo = true
        return s
    }

    func testTheMusicVideoCutOfAMixIsLeftOut() {
        let extra = QueueBuilder.extend(
            existing: [],
            candidates: [
                song("aaa", "Dildaara (Stand By Me)", "Vishal-Shekhar"),
                video("bbb", "Lyrical Video: Dildara Song", "Shafqat Amanat Ali"),
                song("ccc", "Sajni"),
            ],
            limit: 10
        )
        XCTAssertEqual(extra.map(\.videoId), ["aaa", "ccc"])
    }

    func testAMixOfNothingButVideosStillPlays() {
        let extra = QueueBuilder.extend(existing: [], candidates: [video("aaa", "One", "A"), video("bbb", "Two", "B")], limit: 10)
        XCTAssertEqual(extra.map(\.videoId), ["aaa", "bbb"])
    }

    func testTheVideoCutOfATrackIsTheSameRecordingAsItsAudio() {
        XCTAssertTrue(QueueBuilder.isSameRecording(song("aaa", "Kesariya"), song("bbb", "Kesariya (Official Video)")))
    }

    func testMatchesAcrossALongerBillingOfTheSameCredit() {
        XCTAssertTrue(QueueBuilder.isSameRecording(
            song("aaa", "Kesariya", "Arijit Singh"),
            song("bbb", "Kesariya | Official Video", "Arijit Singh, Pritam")
        ))
    }

    func testARemixIsNotTheOriginal() {
        XCTAssertFalse(QueueBuilder.isSameRecording(song("aaa", "Kesariya"), song("bbb", "Kesariya (Remix)")))
    }

    func testSameTitleFromADifferentArtistIsADifferentSong() {
        XCTAssertFalse(QueueBuilder.isSameRecording(song("aaa", "Perfect", "Ed Sheeran"), song("bbb", "Perfect", "One Direction")))
    }

    func testAReorderedCreditIsTheSameRecording() {
        XCTAssertTrue(QueueBuilder.isSameRecording(
            song("aaa", "Kalank (Duet)", "Pritam, Arijit Singh & Shilpa Rao"),
            song("bbb", "Kalank (Duet)", "Shilpa Rao, Arijit Singh, & Pritam")
        ))
    }

    func testTopicChannelsAndCasingDoNotAffectTheCredit() {
        XCTAssertEqual(QueueBuilder.artistSet("Arijit Singh - Topic"), ["arijit singh"])
        XCTAssertEqual(QueueBuilder.artistSet("Pritam feat. Arijit Singh"), ["pritam", "arijit singh"])
    }

    func testExtendDropsTheSeedAndAnythingAlreadyQueued() {
        let seed = song("aaa", "Kesariya")
        let extra = QueueBuilder.extend(existing: [seed], candidates: [seed, song("bbb", "Tum Hi Ho"), song("aaa", "Kesariya")], limit: 10)
        XCTAssertEqual(extra.map(\.videoId), ["bbb"])
    }

    func testExtendDropsADuplicateThatOnlyDiffersByVideoCut() {
        let extra = QueueBuilder.extend(
            existing: [],
            candidates: [song("aaa", "Channa Mereya"), song("bbb", "Channa Mereya (Official Video)"), song("ccc", "Ae Dil Hai Mushkil")],
            limit: 10
        )
        XCTAssertEqual(extra.map(\.videoId), ["aaa", "ccc"])
    }

    func testExtendHonoursTheLimit() {
        let candidates = (1...10).map { song("v\($0)", "Song \($0)", "Artist \($0)") }
        XCTAssertEqual(QueueBuilder.extend(existing: [], candidates: candidates, limit: 3).count, 3)
    }

    func testOneArtistCannotTakeOverTheStation() {
        let candidates = (1...6).map { song("v\($0)", "Song \($0)", "Badshah") }
        let extra = QueueBuilder.extend(existing: [song("seed", "Seed", "Diljit Dosanjh")], candidates: candidates, limit: 10)
        XCTAssertEqual(extra.count, 2)
    }

    func testTheSeedsOwnArtistGetsMoreRoomThanTheRest() {
        let seed = song("seed", "Seed", "Diljit Dosanjh")
        let candidates = (1...8).map { song("v\($0)", "Song \($0)", "Diljit Dosanjh") }
        XCTAssertEqual(QueueBuilder.extend(existing: [seed], candidates: candidates, limit: 10).count, 4)
    }

    func testTheCapCountsAReorderedCreditAsOneArtist() {
        let seed = song("seed", "Seed", "Nucleya")
        let candidates = [
            song("v1", "One", "Pritam, Arijit Singh"),
            song("v2", "Two", "Arijit Singh, Pritam"),
            song("v3", "Three", "Pritam & Arijit Singh"),
        ]
        XCTAssertEqual(QueueBuilder.extend(existing: [seed], candidates: candidates, limit: 10).map(\.videoId), ["v1", "v2"])
    }

    // MARK: Beyond the Kotlin tests

    func testTitleNoiseIsStrippedButRemixMarkersStay() {
        XCTAssertEqual(QueueBuilder.normalisedTitle(#"Kesariya (From "Brahmastra") | Official Video"#), "kesariya")
        XCTAssertEqual(QueueBuilder.normalisedTitle("Tum Hi Ho [Full Video] (Lyrics)"), "tum hi ho")
        XCTAssertEqual(QueueBuilder.normalisedTitle("Blinding Lights (Official Audio)"), "blinding lights")
        XCTAssertEqual(QueueBuilder.normalisedTitle("Levitating (Visualizer)"), "levitating")
        XCTAssertEqual(QueueBuilder.normalisedTitle("Levitating (Remix)"), "levitating remix")
        XCTAssertEqual(QueueBuilder.normalisedTitle("Ghungroo Official Music Video 4K"), "ghungroo 4k")
    }

    func testNonLatinTitlesAndCreditsSurviveNormalisation() {
        // Combining vowel signs aren't letters to either regex engine, so Devanagari normalises to
        // its consonants on both platforms. What matters is that the two cuts still match and a
        // different title doesn't.
        XCTAssertTrue(QueueBuilder.isSameRecording(song("a", "तुम ही हो", "अरिजीत सिंह"), song("b", "तुम ही हो (Official Video)", "अरिजीत सिंह")))
        XCTAssertFalse(QueueBuilder.isSameRecording(song("a", "तुम ही हो", "अरिजीत सिंह"), song("b", "चन्ना मेरेया", "अरिजीत सिंह")))
        XCTAssertEqual(QueueBuilder.normalisedTitle("米津玄師 - Lemon (Official Video)"), "米津玄師 lemon")
        XCTAssertEqual(QueueBuilder.artistSet("アイナ・ジ・エンド × 米津玄師"), ["アイナ ジ エンド 米津玄師"])
        XCTAssertEqual(QueueBuilder.artistSet("Diljit Dosanjh x Sia"), ["diljit dosanjh", "sia"])
        XCTAssertEqual(QueueBuilder.artistSet("Coldplay with BTS"), ["coldplay", "bts"])
        XCTAssertEqual(QueueBuilder.artistSet("A · B • C; D ft. E"), ["a", "b", "c", "d", "e"])
    }

    func testAnEmptyTitleNeverMatchesByTitle() {
        XCTAssertFalse(QueueBuilder.isSameRecording(song("a", "(Official Video)"), song("b", "(Official Video)")))
    }

    func testMissingCreditsMatchOnTitleAlone() {
        XCTAssertTrue(QueueBuilder.isSameRecording(song("a", "Kesariya", ""), song("b", "Kesariya (Lyric Video)", "Arijit Singh")))
    }
}
