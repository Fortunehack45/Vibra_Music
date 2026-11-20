import XCTest
import VibraMusicCore
@testable import InnerTube

/// Telling a playlist this account made from one it merely saved (Android's PlaylistOwnershipTest).
///
/// The distinction only exists on the playlist's own page — the library feed lists the two
/// identically — and getting it wrong is silent either way: a Delete button YouTube refuses, or a
/// Rename that quietly vanishes from the user's own playlist. Each of the three readings is pinned to
/// a response shaped like the one it was written for.
final class PlaylistOwnershipTests: XCTestCase {

    private func owned(_ text: String) -> Bool? {
        InnerTubeParser.parsePlaylistOwned(json(text))
    }

    // MARK: - Own playlists

    /// The renderer YouTube wraps a header in when it belongs to the caller.
    func testEditableHeaderRendererMeansOwnPlaylist() {
        let response = #"""
        {"header":{"musicEditablePlaylistDetailHeaderRenderer":{
          "header":{"musicResponsiveHeaderRenderer":{"buttons":[
            {"toggleButtonRenderer":{
              "defaultIcon":{"iconType":"BOOKMARK_BORDER"},
              "toggledIcon":{"iconType":"BOOKMARK"}}}
          ]}}
        }}}
        """#
        // Decided before the buttons are read, so a stray bookmark inside an editable header cannot
        // talk it back out of being the account's.
        XCTAssertEqual(owned(response), true)
    }

    /// Edit and Delete in the header menu are offered to nobody else.
    func testDeleteInTheHeaderMenuMeansOwnPlaylist() {
        let response = #"""
        {"header":{"musicResponsiveHeaderRenderer":{
          "buttons":[{"menuRenderer":{"items":[
            {"menuNavigationItemRenderer":{"icon":{"iconType":"DELETE"}}}
          ]}}]
        }}}
        """#
        XCTAssertEqual(owned(response), true)
    }

    func testEditInTheHeaderMenuMeansOwnPlaylistEvenBesideABookmark() {
        let response = #"""
        {"header":{"musicResponsiveHeaderRenderer":{
          "buttons":[
            {"toggleButtonRenderer":{"defaultIcon":{"iconType":"BOOKMARK_BORDER"}}},
            {"menuRenderer":{"items":[{"menuNavigationItemRenderer":{"icon":{"iconType":"EDIT"}}}]}}
          ]
        }}}
        """#
        XCTAssertEqual(owned(response), true)
    }

    /// Nothing to save a playlist already yours into, so there is no bookmark.
    func testHeaderWithNoSaveBookmarkMeansOwnPlaylist() {
        let response = #"""
        {"header":{"musicResponsiveHeaderRenderer":{
          "buttons":[
            {"musicPlayButtonRenderer":{}},
            {"menuRenderer":{"items":[
              {"menuNavigationItemRenderer":{"icon":{"iconType":"SHARE"}}}
            ]}}
          ]
        }}}
        """#
        XCTAssertEqual(owned(response), true)
    }

    // MARK: - Saved playlists

    /// The reported bug: a saved playlist offering Rename and Delete.
    func testSaveBookmarkMeansSavedRatherThanOwn() {
        let response = #"""
        {"header":{"musicResponsiveHeaderRenderer":{
          "buttons":[
            {"musicPlayButtonRenderer":{}},
            {"toggleButtonRenderer":{
              "isToggled":"true",
              "defaultIcon":{"iconType":"BOOKMARK_BORDER"},
              "toggledIcon":{"iconType":"BOOKMARK"}}}
          ]
        }}}
        """#
        XCTAssertEqual(owned(response), false)
    }

    /// A track row's own menu never answers for the playlist: on a page of anyone's playlist a row
    /// can be removed from a queue, so a page-wide walk for DELETE would call every playlist the
    /// account's own.
    func testATrackRowsDeleteDoesNotMakeThePlaylistOwn() {
        let response = #"""
        {"header":{"musicResponsiveHeaderRenderer":{
          "buttons":[{"toggleButtonRenderer":{
            "defaultIcon":{"iconType":"BOOKMARK_BORDER"}}}]
        }},
         "contents":[{"musicResponsiveListItemRenderer":{"menu":{"menuRenderer":{"items":[
           {"menuNavigationItemRenderer":{"icon":{"iconType":"DELETE"}}}
         ]}}}}]}
        """#
        XCTAssertEqual(owned(response), false)
    }

    // MARK: - No answer

    /// A continuation carries rows and nothing else, so it must not guess.
    func testAHeaderlessResponseSaysNothing() {
        let response = #"""
        {"continuationContents":{"musicPlaylistShelfContinuation":{"contents":[
          {"musicResponsiveListItemRenderer":{}}
        ]}}}
        """#
        XCTAssertNil(owned(response))
    }

    // MARK: - Recorded pages

    func testAStrangersPlaylistRecordedSignedOutIsSaved() throws {
        // Signed out, the header still carries its save bookmark (an invitation to sign in).
        XCTAssertEqual(InnerTubeParser.parsePlaylistOwned(try Fixtures.json("playlist.json")), false)
        XCTAssertEqual(InnerTubeParser.parsePlaylistOwned(try Fixtures.json("playlist_long.json")), false)
    }

    func testAContinuationRecordedLiveSaysNothing() throws {
        XCTAssertNil(InnerTubeParser.parsePlaylistOwned(try Fixtures.json("playlist_long_continuation.json")))
    }

    func testTheSaveStateAndThePlaylistItActsOnComeFromTheHeader() throws {
        let playlist = try XCTUnwrap(InnerTubeParser.parseLibraryState(try Fixtures.json("playlist.json")))
        XCTAssertEqual(playlist, LibraryState(playlistId: "PL8-o_KZwk58yx2eTIGcK1EvHZkMI__Th4", saved: false))
        // An album is saved as the playlist backing it, never as its MPREb browse id.
        let album = try XCTUnwrap(InnerTubeParser.parseLibraryState(try Fixtures.json("album.json")))
        XCTAssertEqual(album, LibraryState(playlistId: "OLAK5uy_mz6eafmqdRHSaR4IwG0ll6J6rgv0_ZpGw", saved: false))
        XCTAssertNil(InnerTubeParser.parseLibraryState(try Fixtures.json("playlist_long_continuation.json")))
    }

    func testAToggledSaveButtonReadsAsSavedAndADisabledOneAsNothing() {
        let saved = json(#"""
        {"header":{"musicResponsiveHeaderRenderer":{"buttons":[
          {"musicPlayButtonRenderer":{"playNavigationEndpoint":{"watchEndpoint":{"videoId":"x","playlistId":"PLmine"}}}},
          {"toggleButtonRenderer":{"isToggled":true,"defaultIcon":{"iconType":"BOOKMARK_BORDER"},"toggledIcon":{"iconType":"BOOKMARK"}}}
        ]}}}
        """#)
        XCTAssertEqual(InnerTubeParser.parseLibraryState(saved), LibraryState(playlistId: "PLmine", saved: true))
        let disabled = json(#"""
        {"header":{"musicResponsiveHeaderRenderer":{"buttons":[
          {"musicPlayButtonRenderer":{"playNavigationEndpoint":{"watchEndpoint":{"playlistId":"PLmine"}}}},
          {"toggleButtonRenderer":{"isDisabled":true,"defaultIcon":{"iconType":"BOOKMARK_BORDER"}}}
        ]}}}
        """#)
        XCTAssertNil(InnerTubeParser.parseLibraryState(disabled))
    }
}
