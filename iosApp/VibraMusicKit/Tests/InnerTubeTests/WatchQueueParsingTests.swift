import XCTest
import VibraMusicCore
@testable import InnerTube

/// What a `next` response yields: the radio queue, the track's own menu, and its Lyrics tab; plus the
/// lyrics page, the caption transcript and the player's tracking block.
final class WatchQueueParsingTests: XCTestCase {

    func testRecordedRadioQueueStartsWithTheSeedAndCarriesCredits() throws {
        let queue = InnerTubeParser.parseWatchQueue(try Fixtures.json("next.json"))
        XCTAssertEqual(queue.count, 15)
        let seed = try XCTUnwrap(queue.first)
        XCTAssertEqual(seed.videoId, "5NV6Rdv1a3I")
        XCTAssertEqual(seed.artist, "Daft Punk")
        XCTAssertEqual(seed.artistId, "UCRr1xG_2WIDs18a6cIiCxeA")
        XCTAssertEqual(seed.durationText, "4:09")
        // The byline counts views, which is how a music-video entry gives itself away.
        XCTAssertTrue(seed.isVideo)
        XCTAssertEqual(queue[1].artist, "The Weeknd")
        XCTAssertEqual(Set(queue.map(\.videoId)).count, queue.count)
    }

    func testRecordedSignedOutQueueHasNoMenuState() throws {
        let menu = try XCTUnwrap(InnerTubeParser.parseSongMenu(try Fixtures.json("next.json"), videoId: "5NV6Rdv1a3I"))
        XCTAssertEqual(menu, SongMenu(likeStatus: nil, inLibrary: false, addToLibraryToken: nil, removeFromLibraryToken: nil))
        XCTAssertNil(InnerTubeParser.parseSongMenu(try Fixtures.json("next.json"), videoId: "notInQueue1"))
    }

    func testSignedInMenusAreReadOffEachTracksOwnRow() throws {
        let next = try Fixtures.json("signed_in/next_signed_in.json")
        let queue = InnerTubeParser.parseWatchQueue(next)
        XCTAssertEqual(queue.map(\.videoId), ["DISLIKED123", "FGBhQbmPwH8", "INDIFF12345"])
        XCTAssertEqual(queue[1].isExplicit, true)
        XCTAssertEqual(queue[1].albumName, "Discovery")

        // A liked track not in the library: the default action adds.
        XCTAssertEqual(InnerTubeParser.parseSongMenu(next, videoId: "FGBhQbmPwH8"), SongMenu(
            likeStatus: .like, inLibrary: false, addToLibraryToken: "ADD_TOKEN", removeFromLibraryToken: "REMOVE_TOKEN"
        ))
        // The neighbour rendered first answers for itself only — its toggle leads with "remove".
        XCTAssertEqual(InnerTubeParser.parseSongMenu(next, videoId: "DISLIKED123"), SongMenu(
            likeStatus: .dislike, inLibrary: true, addToLibraryToken: "NEIGHBOUR_ADD", removeFromLibraryToken: "NEIGHBOUR_REMOVE"
        ))
        XCTAssertEqual(InnerTubeParser.parseSongMenu(next, videoId: "INDIFF12345")?.likeStatus, .indifferent)
    }

    func testOnlyTheLibraryToggleSpeaksForLibraryMembership() {
        // "Don't recommend" hangs a feedback token off the same endpoint and comes first; reading it
        // made every song claim to be in the library.
        let response = json(#"""
        {"contents":[{"playlistPanelVideoRenderer":{"videoId":"abcdefghijk","title":{"runs":[{"text":"T"}]},"menu":{"menuRenderer":{"items":[
          {"toggleMenuServiceItemRenderer":{"defaultIcon":{"iconType":"NOT_INTERESTED"},
            "defaultServiceEndpoint":{"feedbackEndpoint":{"feedbackToken":"DONT_RECOMMEND"}}}},
          {"toggleMenuServiceItemRenderer":{"defaultIcon":{"iconType":"LIBRARY_ADD"},"toggledIcon":{"iconType":"LIBRARY_SAVED"},
            "defaultServiceEndpoint":{"feedbackEndpoint":{"feedbackToken":"ADD"}},
            "toggledServiceEndpoint":{"feedbackEndpoint":{"feedbackToken":"REMOVE"}}}}
        ]}}}}]}
        """#)
        XCTAssertEqual(InnerTubeParser.parseSongMenu(response, videoId: "abcdefghijk"), SongMenu(
            likeStatus: nil, inLibrary: false, addToLibraryToken: "ADD", removeFromLibraryToken: "REMOVE"
        ))
    }

    // MARK: - Lyrics

    func testTheLyricsTabIsFoundByItsTitle() throws {
        let endpoint = try XCTUnwrap(InnerTubeParser.lyricsEndpoint(try Fixtures.json("next.json")))
        XCTAssertEqual(endpoint.browseId, "MPLYt_dYXkoPsE0o6")
        XCTAssertNil(endpoint.params)
    }

    func testTheLyricsTabFallsBackToTheFirstBrowsableTabAfterUpNext() {
        let response = json(#"""
        {"tabs":[
          {"tabRenderer":{"title":"A seguir","content":{}}},
          {"tabRenderer":{"title":"Letra","endpoint":{"browseEndpoint":{"browseId":"MPLYt_x","params":"p"}}}},
          {"tabRenderer":{"title":"Relacionado","endpoint":{"browseEndpoint":{"browseId":"MPTRt_y"}}}}
        ]}
        """#)
        let endpoint = InnerTubeParser.lyricsEndpoint(response)
        XCTAssertEqual(endpoint?.browseId, "MPLYt_x")
        XCTAssertEqual(endpoint?.params, "p")
        XCTAssertNil(InnerTubeParser.lyricsEndpoint(json(#"{"tabs":[{"tabRenderer":{"title":"Up next"}}]}"#)))
    }

    func testRecordedLyricsPage() throws {
        let page = try Fixtures.json("lyrics.json")
        XCTAssertEqual(InnerTubeParser.parseLyrics(page), [
            "Paint plain'n meadow shadow helmet press brick shadow patient",
            "Paint rub fast busy Tidy's leaf hill",
        ])
        XCTAssertEqual(InnerTubeParser.parseLyricsSource(page), "Source: Musixmatch")
    }

    func testRecordedLyricsNotAvailablePageHasNoLyrics() throws {
        XCTAssertNil(InnerTubeParser.parseLyrics(try Fixtures.json("lyrics_unavailable.json")))
    }

    func testLyricsLinesAreTrimmedAndBlankLinesDropped() {
        let page = json(#"{"x":{"musicDescriptionShelfRenderer":{"description":{"runs":[{"text":"  one \r\n\r\ntwo\n"},{"text":"three  "}]}}}}"#)
        XCTAssertEqual(InnerTubeParser.parseLyrics(page), ["one", "two", "three"])
    }

    // MARK: - Transcript

    func testTranscriptCuesAreSortedTrimmedOfNotesAndEmptyOnesDropped() throws {
        XCTAssertEqual(InnerTubeParser.parseTranscript(try Fixtures.json("signed_in/transcript.json")), [
            InnerTubeTranscriptCue(startMs: 1000, text: "first line"),
            InnerTubeTranscriptCue(startMs: 4200, text: "second line"),
        ])
        XCTAssertNil(InnerTubeParser.parseTranscript(json(#"{"actions":[]}"#)))
    }

    func testTranscriptParamsAreTheTinyProtobufGetTranscriptExpects() throws {
        let params = InnerTubeClient.transcriptParams(videoId: "khnokW3Mw24")
        let bytes = try XCTUnwrap(Data(base64Encoded: params))
        XCTAssertEqual(Array(bytes.prefix(2)), [10, 11], "field 1, length 11")
        XCTAssertEqual(String(decoding: bytes.dropFirst(2), as: UTF8.self), "khnokW3Mw24")
    }

    // MARK: - Playback tracking

    func testPlaybackTrackingNamesTheThreeStatsEndpointsAndTheAtrSchedule() throws {
        let tracking = try XCTUnwrap(InnerTubeClient.playbackTracking(from: try Fixtures.json("signed_in/player_tracking.json"), videoId: "FGBhQbmPwH8", signatureTimestamp: 20717))
        XCTAssertTrue(tracking.playbackUrl.hasPrefix("https://s.youtube.com/api/stats/playback?"))
        XCTAssertTrue(try XCTUnwrap(tracking.watchtimeUrl).hasPrefix("https://s.youtube.com/api/stats/watchtime?"))
        XCTAssertTrue(try XCTUnwrap(tracking.atrUrl).hasPrefix("https://s.youtube.com/api/stats/atr?"))
        XCTAssertEqual(tracking.atrAfterSeconds, 7)
    }

    func testAnUnplayableResponseHasNoTracking() throws {
        XCTAssertNil(InnerTubeClient.playbackTracking(from: try Fixtures.json("signed_in/player_unplayable.json"), videoId: "x", signatureTimestamp: nil))
        // Without its own schedule, atr is due after YouTube Music's usual five seconds.
        let bare = json(#"{"playbackTracking":{"videostatsPlaybackUrl":{"baseUrl":"https://s.youtube.com/p"},"atrUrl":{"baseUrl":"https://s.youtube.com/a"}}}"#)
        XCTAssertEqual(InnerTubeClient.playbackTracking(from: bare, videoId: "x", signatureTimestamp: nil)?.atrAfterSeconds, 5)
    }
}
