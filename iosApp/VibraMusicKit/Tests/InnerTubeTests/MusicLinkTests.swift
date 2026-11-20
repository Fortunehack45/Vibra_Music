import XCTest
@testable import InnerTube

/// YouTube and YouTube Music links, shared text and voice queries turned into what the app should
/// do, and the relays that hold a request until the app can act on it.
final class MusicLinkTests: XCTestCase {
    private func parse(_ text: String) -> MusicLinkRequest? {
        MusicLink.parse(URL(string: text)!)
    }

    func testWatchLinksOnEveryYouTubeHostPlayTheVideo() {
        for link in [
            "https://music.youtube.com/watch?v=5NV6Rdv1a3I",
            "https://www.youtube.com/watch?v=5NV6Rdv1a3I&t=42",
            "https://m.youtube.com/watch?v=5NV6Rdv1a3I",
            "https://youtube.com/watch?feature=share&v=5NV6Rdv1a3I",
            "https://WWW.YOUTUBE.COM/watch?v=5NV6Rdv1a3I",
        ] {
            XCTAssertEqual(parse(link), .track(videoId: "5NV6Rdv1a3I"), link)
        }
    }

    func testTheVideoWinsOverThePlaylistItWasOpenedFrom() {
        XCTAssertEqual(parse("https://music.youtube.com/watch?v=5NV6Rdv1a3I&list=RDAMVM5NV6Rdv1a3I"), .track(videoId: "5NV6Rdv1a3I"))
        // YT Music's "play this album" link names no video: the list stands in.
        XCTAssertEqual(parse("https://music.youtube.com/watch?list=OLAK5uy_mz6eafmqdRHSaR4IwG0ll6J6rgv0_ZpGw"),
                       .page(browseId: "VLOLAK5uy_mz6eafmqdRHSaR4IwG0ll6J6rgv0_ZpGw"))
        XCTAssertNil(parse("https://music.youtube.com/watch"))
    }

    func testShortLinksShortsAndEmbedsAreABareIdInThePath() {
        XCTAssertEqual(parse("https://youtu.be/5NV6Rdv1a3I?si=abc"), .track(videoId: "5NV6Rdv1a3I"))
        XCTAssertEqual(parse("https://www.youtube.com/shorts/abcdefghijk"), .track(videoId: "abcdefghijk"))
        XCTAssertEqual(parse("https://www.youtube.com/embed/abcdefghijk?autoplay=1"), .track(videoId: "abcdefghijk"))
        XCTAssertEqual(parse("https://www.youtube.com/v/abcdefghijk"), .track(videoId: "abcdefghijk"))
        XCTAssertNil(parse("https://youtu.be/"))
        XCTAssertNil(parse("https://www.youtube.com/shorts/"))
    }

    func testPlaylistLinksBecomeVLBrowseIds() {
        XCTAssertEqual(parse("https://music.youtube.com/playlist?list=PL8-o_KZwk58yx2eTIGcK1EvHZkMI__Th4"),
                       .page(browseId: "VLPL8-o_KZwk58yx2eTIGcK1EvHZkMI__Th4"))
        XCTAssertEqual(parse("https://www.youtube.com/playlist?list=VLPLabc"), .page(browseId: "VLPLabc"), "no double prefix")
        XCTAssertNil(parse("https://music.youtube.com/playlist?list="))
        XCTAssertNil(parse("https://music.youtube.com/playlist"))
    }

    func testChannelAndBrowseLinksAreBrowseIdsAlready() {
        XCTAssertEqual(parse("https://music.youtube.com/channel/UCRr1xG_2WIDs18a6cIiCxeA"), .page(browseId: "UCRr1xG_2WIDs18a6cIiCxeA"))
        XCTAssertEqual(parse("https://music.youtube.com/browse/MPREb_7ltM34kr0mH"), .page(browseId: "MPREb_7ltM34kr0mH"))
        XCTAssertNil(parse("https://music.youtube.com/channel/"))
    }

    func testASearchLinkShowsResultsRatherThanPlaying() {
        XCTAssertEqual(parse("https://music.youtube.com/search?q=daft+punk"), .search(query: "daft punk", play: false))
        XCTAssertEqual(parse("https://music.youtube.com/search?q=caf%C3%A9%20tacvba"), .search(query: "café tacvba", play: false))
        XCTAssertNil(parse("https://music.youtube.com/search?q=%20"))
    }

    func testLinksToNothingInParticularAskForNothing() {
        XCTAssertNil(parse("https://music.youtube.com/"))
        XCTAssertNil(parse("https://music.youtube.com/library"))
        XCTAssertEqual(parse("https://music.youtube.com/library?list=PLx"), .page(browseId: "VLPLx"))
        XCTAssertNil(parse("https://open.spotify.com/track/abc"))
        XCTAssertNil(parse("https://notyoutube.com/watch?v=5NV6Rdv1a3I"))
        XCTAssertNil(parse("vibramusic://player"))
    }

    func testSharedTextIsReadForItsFirstLink() {
        let shared = "Get Lucky (feat. Pharrell Williams)\nhttps://music.youtube.com/watch?v=5NV6Rdv1a3I&si=xyz"
        XCTAssertEqual(MusicLink.parse(sharedText: shared), .track(videoId: "5NV6Rdv1a3I"))
        XCTAssertEqual(MusicLink.parse(sharedText: "listen to this https://youtu.be/abcdefghijk it's great"), .track(videoId: "abcdefghijk"))
        XCTAssertNil(MusicLink.parse(sharedText: "no link here"))
        XCTAssertNil(MusicLink.parse(sharedText: "https://example.com/watch?v=abcdefghijk"))
    }

    func testAVoiceRequestPlaysItsBestMatchAndAnEmptyOneResumes() {
        XCTAssertEqual(MusicLink.request(forVoiceQuery: " blinding lights "), .search(query: "blinding lights", play: true))
        XCTAssertEqual(MusicLink.request(forVoiceQuery: ""), .resume)
        XCTAssertEqual(MusicLink.request(forVoiceQuery: nil), .resume)
    }

    // MARK: - Relays

    @MainActor
    func testTheLinkRelayHoldsARequestUntilItIsHandled() {
        let relay = MusicLinkRelay()
        XCTAssertFalse(relay.consume(url: URL(string: "https://example.com")!))
        XCTAssertNil(relay.pending)
        XCTAssertTrue(relay.consume(url: URL(string: "https://youtu.be/abcdefghijk")!))
        XCTAssertEqual(relay.pending, .track(videoId: "abcdefghijk"))
        XCTAssertTrue(relay.consume(sharedText: "see https://music.youtube.com/browse/MPREb_x"))
        XCTAssertEqual(relay.pending, .page(browseId: "MPREb_x"), "the newest request is the one outstanding")
        relay.consume(voiceQuery: nil)
        XCTAssertEqual(relay.pending, .resume)
        relay.handled()
        XCTAssertNil(relay.pending)
    }

    @MainActor
    func testThePlayerDeepLinkIsTheWidgetsURLOnly() {
        let link = PlayerDeepLink()
        XCTAssertTrue(PlayerDeepLink.isOpenPlayer(PlayerDeepLink.url))
        XCTAssertTrue(PlayerDeepLink.isOpenPlayer(URL(string: "Vibra Music://Player")!))
        XCTAssertFalse(link.consume(url: URL(string: "https://music.youtube.com/watch?v=abcdefghijk")!))
        XCTAssertFalse(link.pending)
        XCTAssertTrue(link.consume(url: PlayerDeepLink.url))
        XCTAssertTrue(link.pending)
        link.handled()
        XCTAssertFalse(link.pending)
    }
}
