import XCTest
import VibraMusicCore
@testable import PlaybackQueue

/// Ports the queue-building half of DetailScreenQueueTest: what a tap on a playlist or album page
/// row queues, filtered or not, in a party or not. The page's text filter itself is UI; it is
/// mirrored here (title, artist or album, case-insensitive, rows keep their original positions) only
/// to produce the list the page hands to the queue.
final class DetailPageQueueTests: XCTestCase {

    private func matching(_ songs: [Song], _ query: String) -> [(index: Int, value: Song)] {
        let all = songs.enumerated().map { (index: $0.offset, value: $0.element) }
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return all }
        return all.filter { entry in
            entry.value.title.localizedCaseInsensitiveContains(query)
                || entry.value.artist.localizedCaseInsensitiveContains(query)
                || (entry.value.albumName?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private let playlistSource = QueueSource(title: "My Playlist", type: .browse, id: "playlist-123")

    func testAnUnfilteredPlaylistBecomesTheContextQueueStartingAtTheTappedRow() {
        let playlist = (0..<50).map { testSong("track-\($0)", title: "Song \($0)", artist: "Artist \($0)") }
        let queue = matching(playlist, "").map(\.value)
        XCTAssertEqual(queue, playlist)

        let result = QueueCoordinator.buildContextQueue(
            currentTimeline: [testSong("current"), testSong("u1", tier: .userQueue, entryId: "entry-u1")],
            currentIndex: 0,
            newContextSongs: queue,
            selectedIndex: 20,
            contextSource: playlistSource
        )
        XCTAssertEqual(result.startIndex, 20)
        XCTAssertEqual(result.timeline[20].videoId, "track-20")
        for i in 0..<20 { XCTAssertEqual(result.timeline[i].videoId, "track-\(i)") }
        XCTAssertEqual(result.timeline[21].videoId, "u1")
        XCTAssertEqual(result.timeline[21].queueTier, .userQueue)
        for i in 21..<50 { XCTAssertEqual(result.timeline[i + 1].videoId, "track-\(i)") }
    }

    func testFilteredSearchResultsBecomeTheContextQueueNotTheWholePlaylist() {
        let playlist: [Song] = (0..<100).map { i in
            switch i {
            case 11: return testSong("track-12", title: "Love Story", artist: "Taylor Swift")
            case 46: return testSong("track-47", title: "Blank Space", artist: "Taylor Swift")
            case 82: return testSong("track-83", title: "Cardigan", artist: "Taylor Swift")
            default: return testSong("track-\(i + 1)", title: "Other Song \(i)", artist: "Other Artist")
            }
        }
        let matches = matching(playlist, "Taylor")
        XCTAssertEqual(matches.map(\.index), [11, 46, 82])
        let queue = matches.map(\.value)

        let result = QueueCoordinator.buildContextQueue(
            currentTimeline: [testSong("current"), testSong("u1", tier: .userQueue, entryId: "entry-u1")],
            currentIndex: 0,
            newContextSongs: queue,
            selectedIndex: 1,
            contextSource: playlistSource
        )
        XCTAssertEqual(result.startIndex, 1)
        XCTAssertEqual(result.timeline.map(\.videoId), ["track-12", "track-47", "u1", "track-83"])
        XCTAssertEqual(result.timeline.map(\.queueTier), [.context, .context, .userQueue, .context])
    }

    func testTheFilterMatchesTitleArtistOrAlbumCaseInsensitively() {
        let songs = [
            testSong("1", title: "Midnight City", artist: "M83", album: "Hurry Up"),
            testSong("2", title: "City Lights", artist: "Various", album: "Soundtrack"),
            testSong("3", title: "Something Else", artist: "City High", album: "Self-Titled"),
            testSong("4", title: "Unrelated", artist: "Unknown", album: "Unknown"),
        ]
        XCTAssertEqual(matching(songs, "city").map(\.value.videoId), ["1", "2", "3"])
    }

    func testInAPartyATapQueuesOnlyTheSongAndThePartysManualQueue() {
        let playlist = (0..<50).map { testSong("track-\($0)") }
        let timeline = QueueCoordinator.buildPartyPlaybackQueue(
            tappedSong: playlist[20],
            source: playlistSource,
            upcomingPartyTracks: [
                testSong("party-manual-1", tier: .userQueue, title: "Manual 1"),
                testSong("party-manual-2", tier: .userQueue, title: "Manual 2"),
            ]
        )
        XCTAssertEqual(timeline.map(\.videoId), ["track-20", "party-manual-1", "party-manual-2"])
        XCTAssertEqual(timeline[0].queueTier, .context)
        XCTAssertEqual(timeline[0].playbackSource, "My Playlist")
        XCTAssertEqual(timeline[0].playbackSourceType, .browse)
        XCTAssertEqual(timeline[1].queueTier, .userQueue)
        XCTAssertEqual(timeline[2].queueTier, .userQueue)
    }

    func testInAPartyStaleAutoplayFromThePreviousTrackIsDropped() {
        let timeline = QueueCoordinator.buildPartyPlaybackQueue(
            tappedSong: testSong("new-track"),
            source: QueueSource(title: "Album", type: .browse, id: "album-1"),
            upcomingPartyTracks: [
                testSong("manual-1", tier: .userQueue),
                testSong("stale-auto-1", tier: .autoplay),
                testSong("stale-auto-2", tier: .autoplay),
            ]
        )
        XCTAssertEqual(timeline.map(\.videoId), ["new-track", "manual-1"])
        XCTAssertEqual(timeline.map(\.queueTier), [.context, .userQueue])
    }

    func testJoiningWithAnEmptyPartyQueueProducesASingleSongQueue() {
        let timeline = QueueCoordinator.buildPartyPlaybackQueue(
            tappedSong: testSong("first-track"),
            source: QueueSource(title: "Search", type: .search),
            upcomingPartyTracks: [Song]()
        )
        XCTAssertEqual(timeline.map(\.videoId), ["first-track"])
        XCTAssertEqual(timeline[0].queueTier, .context)
        XCTAssertEqual(timeline[0].playbackSource, "Search")
    }

    /// The same, through the controller: in a party, a row tap uses the party's upcoming tracks.
    @MainActor
    func testTheControllerUsesThePartyQueueForARowTapInAParty() {
        let controller = PlaybackQueueController(settings: makeSettings())
        controller.setItems([testSong("old-1"), testSong("old-2")], startIndex: 0)
        controller.party = AutoplayPartyContext(
            code: "ABC123",
            yourMemberId: "me",
            members: [.init(memberId: "me", isHost: true)],
            upcomingTracks: [testSong("m1", tier: .userQueue), testSong("a1", tier: .autoplay)]
        )
        let playlist = (0..<10).map { testSong("t\($0)") }
        XCTAssertEqual(controller.playFrom(playlist, index: 4, source: playlistSource), .done)
        XCTAssertEqual(controller.state.ids, ["t4", "m1"])
    }
}
