import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import InnerTube

/// Everything that changes the account: ratings, saves, subscriptions, library feedback and playlist
/// edits — what each sends, and how a refusal that still answers HTTP 200 is noticed.
final class AccountWriteTests: XCTestCase {
    private var stub: InnerTubeStub!
    private var client: InnerTubeClient!

    override func setUp() async throws {
        stub = InnerTubeStub()
        stub.stub.register(host: "music.youtube.com", path: "/", response: .text(try Fixtures.text("signed_in/music_shell_signed_in_personal.html")))
        client = stub.makeClient()
        await client.setCookie("SID=1; SAPISID=secret")
    }

    private func body(_ endpoint: String) throws -> InnerTubeJSON {
        InnerTubeStub.body(of: try XCTUnwrap(stub.requests(to: endpoint).last, "no request to \(endpoint)"))
    }

    // MARK: - Signed out

    func testEveryWriteNeedsASession() async {
        let guest = InnerTubeStub().makeClient()
        let writes: [(String, () async throws -> Void)] = [
            ("rate", { try await guest.rate(videoId: "v", status: .like) }),
            ("save", { try await guest.ratePlaylist(playlistId: "p", saved: true) }),
            ("subscribe", { try await guest.setSubscribed(channelId: "c", subscribed: true) }),
            ("feedback", { try await guest.sendFeedback(token: "t") }),
            ("create", { _ = try await guest.createPlaylist(title: "t", privacy: .private) }),
            ("delete", { try await guest.deletePlaylist(playlistId: "p") }),
            ("add", { try await guest.addToPlaylist(playlistId: "p", videoIds: ["v"]) }),
            ("remove", { try await guest.removeFromPlaylist(playlistId: "p", entries: [PlaylistEntryRef(setVideoId: "s", videoId: "v")]) }),
            ("rename", { try await guest.renamePlaylist(playlistId: "p", title: "t") }),
        ]
        for (name, write) in writes {
            do {
                try await write()
                XCTFail("\(name) went through signed out")
            } catch {
                XCTAssertEqual(error as? InnerTubeError, .notSignedIn, name)
            }
        }
        XCTAssertEqual(InnerTubeError.notSignedIn.localizedDescription, "Sign in to YouTube Music to do that")
    }

    // MARK: - Ratings

    func testRatingsUseTheLikeEndpointsWithAVideoTarget() async throws {
        let endpoints: [(LikeStatus, String)] = [(.like, "like/like"), (.dislike, "like/dislike"), (.indifferent, "like/removelike")]
        for (_, endpoint) in endpoints { try stub.on(endpoint, fixture: "signed_in/like_ok.json") }
        for (status, endpoint) in endpoints {
            try await client.rate(videoId: "FGBhQbmPwH8", status: status)
            // Exactly the one endpoint for this status was hit — a swapped case lands on another path.
            XCTAssertEqual(stub.requests(to: endpoint).count, 1, "\(status) goes to \(endpoint)")
            XCTAssertEqual(try body(endpoint).o("target").s("videoId"), "FGBhQbmPwH8", endpoint)
            // Every write is signed as the session's identity.
            XCTAssertEqual(try body(endpoint).o("context").o("user").s("onBehalfOfUser"), "SYNC_PERSONAL")
        }
    }

    func testARefusedRatingIsAnErrorEvenThoughItAnswered200() async throws {
        try stub.on("like/like", fixture: "signed_in/like_refused.json")
        do {
            try await client.rate(videoId: "v", status: .like)
            XCTFail("a refusal must not read as a rating")
        } catch let error as InnerTubeError {
            XCTAssertEqual(error, .refused("YouTube Music refused the rating: Precondition check failed."))
        }
    }

    func testSavingAReleaseLikesItsPlaylist() async throws {
        try stub.on("like/like", fixture: "signed_in/like_ok.json")
        try stub.on("like/removelike", fixture: "signed_in/like_ok.json")
        try await client.ratePlaylist(playlistId: "OLAK5uy_mz6eafmqdRHSaR4IwG0ll6J6rgv0_ZpGw", saved: true)
        XCTAssertEqual(try body("like/like").o("target").s("playlistId"), "OLAK5uy_mz6eafmqdRHSaR4IwG0ll6J6rgv0_ZpGw")
        try await client.ratePlaylist(playlistId: "OLAK5uy_x", saved: false)
        XCTAssertEqual(try body("like/removelike").o("target").s("playlistId"), "OLAK5uy_x")

        try stub.on("like/like", fixture: "signed_in/like_refused.json")
        do {
            try await client.ratePlaylist(playlistId: "p", saved: true)
            XCTFail("expected a refusal")
        } catch let error as InnerTubeError {
            XCTAssertEqual(error, .refused("YouTube Music refused the change: Precondition check failed."))
        }
    }

    func testSubscribingNamesTheChannel() async throws {
        stub.on("subscription/subscribe", "{}")
        stub.on("subscription/unsubscribe", #"{"error":{"code":403}}"#)
        try await client.setSubscribed(channelId: "UC_kRDKYrUlrbtrSiyu5Tflg", subscribed: true)
        XCTAssertEqual(try body("subscription/subscribe").a("channelIds")?.map(\.primitiveContent), ["UC_kRDKYrUlrbtrSiyu5Tflg"])
        do {
            try await client.setSubscribed(channelId: "UC_x", subscribed: false)
            XCTFail("expected a refusal")
        } catch let error as InnerTubeError {
            // No message: the error object itself is quoted.
            XCTAssertEqual(error, .refused(#"YouTube Music refused the change: {"code":403}"#))
        }
    }

    func testLibraryFeedbackSendsTheToken() async throws {
        stub.on("feedback", "{}")
        try await client.sendFeedback(token: "ADD_TOKEN")
        XCTAssertEqual(try body("feedback").a("feedbackTokens")?.map(\.primitiveContent), ["ADD_TOKEN"])
    }

    func testALibraryTokenYouTubeDidNotProcessIsAnErrorEvenThoughItAnswered200() async throws {
        stub.on("feedback", #"{"feedbackResponses":[{"isProcessed":false}]}"#)
        do {
            try await client.sendFeedback(token: "STALE_TOKEN")
            XCTFail("an unprocessed token must not read as a saved track")
        } catch let error as InnerTubeError {
            XCTAssertEqual(error, .refused("YouTube Music refused the change: the library token was not accepted"))
        }
        stub.on("feedback", #"{"feedbackResponses":[{"isProcessed":true}]}"#)
        try await client.sendFeedback(token: "ADD_TOKEN")
    }

    func testAFeedbackErrorBodyIsRefusedToo() async throws {
        stub.on("feedback", #"{"error":{"code":400,"message":"Precondition check failed."}}"#)
        do {
            try await client.sendFeedback(token: "ADD_TOKEN")
            XCTFail("a refusal must not read as a saved track")
        } catch let error as InnerTubeError {
            XCTAssertEqual(error, .refused("YouTube Music refused the change: Precondition check failed."))
        }
    }

    // MARK: - Playlists

    func testCreatingAPlaylistSendsPrivacyAndSeedsAndReadsTheId() async throws {
        try stub.on("playlist/create", fixture: "signed_in/create_playlist.json")
        let id = try await client.createPlaylist(title: "Road songs", privacy: .unlisted, videoIds: ["a", "b"])
        XCTAssertEqual(id, "PLnew0001")
        let sent = try body("playlist/create")
        XCTAssertEqual(sent.s("title"), "Road songs")
        XCTAssertEqual(sent.s("description"), "")
        XCTAssertEqual(sent.s("privacyStatus"), "UNLISTED")
        XCTAssertEqual(sent.a("videoIds")?.map(\.primitiveContent), ["a", "b"])

        _ = try await client.createPlaylist(title: "Empty", privacy: .public, description: "notes")
        XCTAssertNil(try body("playlist/create").a("videoIds"), "no seed, no videoIds key")
        XCTAssertEqual(try body("playlist/create").s("privacyStatus"), "PUBLIC")
        XCTAssertEqual(try body("playlist/create").s("description"), "notes")
    }

    func testACreatedPlaylistsIdIsFoundInsideTheNavigationCommand() async throws {
        try stub.on("playlist/create", fixture: "signed_in/create_playlist_nested.json")
        let id = try await client.createPlaylist(title: "x", privacy: .private)
        XCTAssertEqual(id, "PLnested02")
        stub.on("playlist/create", "{}")
        do {
            _ = try await client.createPlaylist(title: "x", privacy: .private)
            XCTFail("expected missing data")
        } catch let error as InnerTubeError {
            XCTAssertEqual(error, .missingData("playlist created but no id came back"))
        }
    }

    func testDeletingTakesTheRawId() async throws {
        stub.on("playlist/delete", "{}")
        try await client.deletePlaylist(playlistId: "VLPLroad123")
        XCTAssertEqual(try body("playlist/delete").s("playlistId"), "PLroad123")
    }

    func testAddingReportsTheEntryIdsYouTubeMinted() async throws {
        try stub.on("browse/edit_playlist", fixture: "signed_in/edit_playlist_added.json")
        let added = try await client.addToPlaylist(playlistId: "VLPLroad123", videoIds: ["FGBhQbmPwH8", "d7woYjGWs6k"])
        // Only the entries the response named; a missing one is normal, not an error.
        XCTAssertEqual(added, ["FGBhQbmPwH8": "56B44F6D10557CC6"])
        let sent = try body("browse/edit_playlist")
        XCTAssertEqual(sent.s("playlistId"), "PLroad123")
        XCTAssertEqual(sent.a("actions")?.map { $0.s("action") }, ["ACTION_ADD_VIDEO", "ACTION_ADD_VIDEO"])
        XCTAssertEqual(sent.a("actions")?.map { $0.s("addedVideoId") }, ["FGBhQbmPwH8", "d7woYjGWs6k"])
    }

    func testRemovingNamesEachEntryByBothIds() async throws {
        stub.on("browse/edit_playlist", #"{"status":"STATUS_SUCCEEDED"}"#)
        try await client.removeFromPlaylist(playlistId: "PLroad123", entries: [
            PlaylistEntryRef(setVideoId: "56B44F6D10557CC6", videoId: "FGBhQbmPwH8"),
            PlaylistEntryRef(setVideoId: "289F4A46DF0A30D2", videoId: "FGBhQbmPwH8"),
        ])
        let actions = try XCTUnwrap(try body("browse/edit_playlist").a("actions"))
        XCTAssertEqual(actions.map { $0.s("action") }, ["ACTION_REMOVE_VIDEO", "ACTION_REMOVE_VIDEO"])
        XCTAssertEqual(actions.map { $0.s("setVideoId") }, ["56B44F6D10557CC6", "289F4A46DF0A30D2"])
        XCTAssertEqual(actions.map { $0.s("removedVideoId") }, ["FGBhQbmPwH8", "FGBhQbmPwH8"])
    }

    func testRenaming() async throws {
        stub.on("browse/edit_playlist", #"{"status":"STATUS_SUCCEEDED"}"#)
        try await client.renamePlaylist(playlistId: "PLroad123", title: "Night drive")
        let action = try XCTUnwrap(try body("browse/edit_playlist").a("actions")?.first)
        XCTAssertEqual(action.s("action"), "ACTION_SET_PLAYLIST_NAME")
        XCTAssertEqual(action.s("playlistName"), "Night drive")
    }

    func testAnEditThatAnswers200WithAFailedStatusIsRefused() async throws {
        try stub.on("browse/edit_playlist", fixture: "signed_in/edit_playlist_failed.json")
        do {
            try await client.renamePlaylist(playlistId: "PLfriend456", title: "Mine now")
            XCTFail("a saved playlist can't be edited")
        } catch let error as InnerTubeError {
            XCTAssertEqual(error, .refused("YouTube Music refused the edit (STATUS_FAILED)"))
        }
    }
}
