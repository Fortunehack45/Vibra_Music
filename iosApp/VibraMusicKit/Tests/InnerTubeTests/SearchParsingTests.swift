import XCTest
import VibraMusicCore
@testable import InnerTube

/// Ports SearchPagingTest.kt: credits, promoted cards, paging and the library/playlist helpers that
/// share its row parsing.
final class SearchParsingTests: XCTestCase {

    func testSearchSongKeepsArtistsThatHaveNoBrowseLink() {
        let response = json(#"""
        {
          "contents": [{
            "musicResponsiveListItemRenderer": {
              "playlistItemData": { "videoId": "pull-me-closer" },
              "flexColumns": [
                { "musicResponsiveListItemFlexColumnRenderer": {
                  "text": { "runs": [{ "text": "Pull Me Closer (feat. JDP)" }] }
                } },
                { "musicResponsiveListItemFlexColumnRenderer": {
                  "text": { "runs": [
                    { "text": "Song" }, { "text": " • " },
                    { "text": "BBYX", "navigationEndpoint": { "browseEndpoint": {
                      "browseId": "UC_BBYX", "browseEndpointContextSupportedConfigs": {
                        "browseEndpointContextMusicConfig": { "pageType": "MUSIC_PAGE_TYPE_ARTIST" }
                      }
                    } } },
                    { "text": ", " },
                    { "text": "Kenny Can't Dance", "navigationEndpoint": { "browseEndpoint": {
                      "browseId": "UC_KENNY", "browseEndpointContextSupportedConfigs": {
                        "browseEndpointContextMusicConfig": { "pageType": "MUSIC_PAGE_TYPE_ARTIST" }
                      }
                    } } },
                    { "text": ", " }, { "text": "Carla Frigo" },
                    { "text": " & " }, { "text": "Vinny Vibe" },
                    { "text": " • " }, { "text": "3:03" }
                  ] }
                } }
              ]
            }
          }]
        }
        """#)

        let songs = InnerTubeParser.parseSearchSongs(response)
        XCTAssertEqual(songs.count, 1)
        XCTAssertEqual(songs.first?.artist, "BBYX, Kenny Can't Dance, Carla Frigo, Vinny Vibe")
        XCTAssertEqual(songs.first?.artistId, "UC_BBYX")
        XCTAssertEqual(songs.first?.durationText, "3:03")
    }

    func testPromotedSongKeepsEveryArtistInAPartiallyLinkedCredit() {
        let response = json(#"""
        {
          "contents": [{ "musicCardShelfRenderer": {
            "title": { "runs": [{ "text": "Pull Me Closer (feat. JDP)" }] },
            "subtitle": { "runs": [
              { "text": "Song" }, { "text": " • " },
              { "text": "BBYX", "navigationEndpoint": { "browseEndpoint": {
                "browseId": "UC_BBYX", "browseEndpointContextSupportedConfigs": {
                  "browseEndpointContextMusicConfig": { "pageType": "MUSIC_PAGE_TYPE_ARTIST" }
                }
              } } },
              { "text": ", " }, { "text": "Kenny Can't Dance" },
              { "text": ", " }, { "text": "Carla Frigo" },
              { "text": " & " }, { "text": "Vinny Vibe" },
              { "text": " • " }, { "text": "3:03" }
            ] },
            "onTap": { "watchEndpoint": { "videoId": "pull-me-closer" } }
          } }]
        }
        """#)

        let tops = InnerTubeParser.parseSearchPage(response).rows.compactMap(\.topSong)
        XCTAssertEqual(tops.count, 1)
        XCTAssertEqual(tops.first?.artist, "BBYX, Kenny Can't Dance, Carla Frigo, Vinny Vibe")
    }

    func testShelfSubtitleConversionPreservesTheCompleteArtistSegment() {
        XCTAssertEqual(
            InnerTubeParser.artistFromSubtitle("Song • BBYX, Kenny Can't Dance, Carla Frigo & Vinny Vibe • 3:03"),
            "BBYX, Kenny Can't Dance, Carla Frigo & Vinny Vibe"
        )
        // Nothing but labels and counts: the whole line is kept rather than an empty credit.
        XCTAssertEqual(InnerTubeParser.artistFromSubtitle("Single • 1.2M plays"), "Single • 1.2M plays")
        // A name that merely starts with a number is a name.
        XCTAssertEqual(InnerTubeParser.artistFromSubtitle("Song • 21 Savage • 3:30"), "21 Savage")
    }

    func testAlbumRowsInheritEveryArtistFromTheReleaseHeader() {
        let response = json(#"""
        {
          "header": { "musicResponsiveHeaderRenderer": {
            "title": { "runs": [{ "text": "Pull Me Closer" }] },
            "straplineTextOne": { "runs": [
              { "text": "BBYX", "navigationEndpoint": { "browseEndpoint": {
                "browseId": "UC_BBYX", "browseEndpointContextSupportedConfigs": {
                  "browseEndpointContextMusicConfig": { "pageType": "MUSIC_PAGE_TYPE_ARTIST" }
                }
              } } },
              { "text": ", " }, { "text": "Kenny Can't Dance" },
              { "text": ", " }, { "text": "Carla Frigo" },
              { "text": " & " }, { "text": "Vinny Vibe" }
            ] },
            "subtitle": { "runs": [
              { "text": "Album" }, { "text": " • " }, { "text": "2026" }
            ] }
          } },
          "contents": [{ "musicResponsiveListItemRenderer": {
            "playlistItemData": { "videoId": "pull-me-closer" },
            "flexColumns": [{ "musicResponsiveListItemFlexColumnRenderer": {
              "text": { "runs": [{ "text": "Pull Me Closer (feat. JDP)" }] }
            } }]
          } }]
        }
        """#)

        let songs = InnerTubeParser.collectSongsDeep(response)
        XCTAssertEqual(songs.count, 1)
        XCTAssertEqual(songs.first?.artist, "BBYX, Kenny Can't Dance, Carla Frigo, Vinny Vibe")
        XCTAssertEqual(songs.first?.artistId, "UC_BBYX")
    }

    func testAPlaylistHeaderNeverCreditsItsRows() {
        // A playlist's header names whoever put it together, which is not what its tracks are by.
        let response = json(#"""
        {
          "header": { "musicResponsiveHeaderRenderer": {
            "title": { "runs": [{ "text": "Road songs" }] },
            "subtitle": { "runs": [{ "text": "Playlist" }, { "text": " • " }, { "text": "Ada" }] }
          } },
          "contents": [{ "musicResponsiveListItemRenderer": {
            "playlistItemData": { "videoId": "abc" },
            "flexColumns": [{ "musicResponsiveListItemFlexColumnRenderer": {
              "text": { "runs": [{ "text": "Untitled" }] }
            } }]
          } }]
        }
        """#)
        XCTAssertEqual(InnerTubeParser.collectSongsDeep(response).first?.artist, "Unknown artist")
    }

    func testWatchQueueKeepsTheFullArtistBylineForAutoplayAndLinkLookup() {
        let response = json(#"""
        {
          "contents": [{ "playlistPanelVideoRenderer": {
            "videoId": "pull-me-closer",
            "title": { "runs": [{ "text": "Pull Me Closer (feat. JDP)" }] },
            "longBylineText": { "runs": [
              { "text": "BBYX" }, { "text": ", " },
              { "text": "Kenny Can't Dance" }, { "text": ", " },
              { "text": "Carla Frigo" }, { "text": " & " },
              { "text": "Vinny Vibe" }, { "text": " • " },
              { "text": "Pull Me Closer" }
            ] },
            "lengthText": { "runs": [{ "text": "3:03" }] },
            "thumbnail": { "thumbnails": [{ "url": "https://example.test/cover.jpg" }] }
          } }]
        }
        """#)

        let queue = InnerTubeParser.parseWatchQueue(response)
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.first?.artist, "BBYX, Kenny Can't Dance, Carla Frigo & Vinny Vibe")
        XCTAssertEqual(queue.first?.durationText, "3:03")
        XCTAssertEqual(queue.first?.isVideo, false)
    }

    func testYouTubeExplicitBadgeIsCarriedOntoTheSong() {
        func row(_ id: String, _ badge: String) -> String {
            #"""
            {
              "musicResponsiveListItemRenderer": {
                "playlistItemData": { "videoId": "\#(id)" },
                "flexColumns": [
                  { "musicResponsiveListItemFlexColumnRenderer": {
                    "text": { "runs": [{ "text": "Starboy" }] }
                  } },
                  { "musicResponsiveListItemFlexColumnRenderer": {
                    "text": { "runs": [{ "text": "The Weeknd" }, { "text": " • " }, { "text": "3:50" }] }
                  } }
                ],
                "badges": \#(badge)
              }
            }
            """#
        }
        let explicitBadge = #"[{"musicInlineBadgeRenderer":{"icon":{"iconType":"MUSIC_EXPLICIT_BADGE"}}}]"#
        let response = json(#"{"contents":[\#(row("explicit", explicitBadge)),\#(row("clean", "[]"))]}"#)

        let songs = InnerTubeParser.parseSearchSongs(response)
        XCTAssertEqual(songs.first { $0.videoId == "explicit" }?.isExplicit, true)
        // No badge is not proof of a clean edition: several renderer shapes simply omit badges.
        XCTAssertEqual(songs.count, 2)
        XCTAssertNil(songs.first { $0.videoId == "clean" }?.isExplicit)
    }

    /// Searching an artist promotes them to a card and hangs three of their songs off it. Those rows
    /// state only "Song • 3:16" — the credit is on the card, said once.
    func testSongsUnderAnArtistCardInheritTheCardsCredit() {
        let response = json(#"""
        {
          "contents": [
            {
              "musicCardShelfRenderer": {
                "title": { "runs": [{ "text": "MC STAN" }] },
                "subtitle": { "runs": [{ "text": "Artist • 12.3M monthly audience" }] },
                "onTap": {
                  "browseEndpoint": {
                    "browseId": "UCXPnAUkxJtng8M_5yWuSTjw",
                    "browseEndpointContextSupportedConfigs": {
                      "browseEndpointContextMusicConfig": { "pageType": "MUSIC_PAGE_TYPE_ARTIST" }
                    }
                  }
                },
                "contents": [
                  {
                    "musicResponsiveListItemRenderer": {
                      "playlistItemData": { "videoId": "basti" },
                      "flexColumns": [
                        { "musicResponsiveListItemFlexColumnRenderer": {
                          "text": { "runs": [{ "text": "Basti Ka Hasti" }] }
                        } },
                        { "musicResponsiveListItemFlexColumnRenderer": {
                          "text": { "runs": [{ "text": "Song" }, { "text": " • " }, { "text": "3:16" }] }
                        } }
                      ]
                    }
                  }
                ]
              }
            }
          ]
        }
        """#)

        let page = InnerTubeParser.parseSearchPage(response)
        XCTAssertEqual(page.rows.compactMap(\.browseItem).first?.type, .artist)
        let songs = page.rows.compactMap(\.trackSong)
        XCTAssertEqual(songs.count, 1)
        XCTAssertEqual(songs.first?.videoId, "basti")
        XCTAssertEqual(songs.first?.artist, "MC STAN")
        XCTAssertEqual(songs.first?.artistId, "UCXPnAUkxJtng8M_5yWuSTjw")
        // The card names who, never off which release.
        XCTAssertNil(songs.first?.albumId)
    }

    /// The other card shape lists *related* uploads rather than its own, so the promoted track's
    /// credit must not be lent to rows that carry their own.
    func testRowsUnderASongCardKeepTheirOwnCredit() {
        let response = json(#"""
        {
          "contents": [
            {
              "musicCardShelfRenderer": {
                "title": { "runs": [{ "text": "Shape of You" }] },
                "subtitle": { "runs": [
                  { "text": "Song" }, { "text": " • " },
                  { "text": "Ed Sheeran", "navigationEndpoint": { "browseEndpoint": {
                    "browseId": "UC_ED",
                    "browseEndpointContextSupportedConfigs": {
                      "browseEndpointContextMusicConfig": { "pageType": "MUSIC_PAGE_TYPE_ARTIST" }
                    }
                  } } },
                  { "text": " • " }, { "text": "4:24" }
                ] },
                "onTap": { "watchEndpoint": { "videoId": "shape" } },
                "contents": [
                  {
                    "musicResponsiveListItemRenderer": {
                      "playlistItemData": { "videoId": "cover" },
                      "flexColumns": [
                        { "musicResponsiveListItemFlexColumnRenderer": {
                          "text": { "runs": [{ "text": "Shape of you (Classical Dance)" }] }
                        } },
                        { "musicResponsiveListItemFlexColumnRenderer": {
                          "text": { "runs": [
                            { "text": "Pratibimb Productions" }, { "text": " • " }, { "text": "3:37" }
                          ] }
                        } }
                      ]
                    }
                  }
                ]
              }
            }
          ]
        }
        """#)

        let page = InnerTubeParser.parseSearchPage(response)
        let songs = page.rows.compactMap(\.trackSong) + page.rows.compactMap(\.topSong)
        XCTAssertEqual(songs.first { $0.videoId == "shape" }?.artist, "Ed Sheeran")
        XCTAssertEqual(songs.first { $0.videoId == "cover" }?.artist, "Pratibimb Productions")
        XCTAssertNil(songs.first { $0.videoId == "cover" }?.artistId)
        // The promoted track comes first.
        XCTAssertEqual(page.rows.first?.topSong?.videoId, "shape")
    }

    func testSearchPageKeepsRowsAndNextContinuation() {
        let response = json(#"""
        {
          "contents": {
            "sectionListRenderer": {
              "contents": [
                {
                  "musicShelfRenderer": {
                    "contents": [
                      {
                        "musicResponsiveListItemRenderer": {
                          "navigationEndpoint": {
                            "browseEndpoint": {
                              "browseId": "VLPL123",
                              "browseEndpointContextSupportedConfigs": {
                                "browseEndpointContextMusicConfig": {
                                  "pageType": "MUSIC_PAGE_TYPE_PLAYLIST"
                                }
                              }
                            }
                          },
                          "flexColumns": [
                            {
                              "musicResponsiveListItemFlexColumnRenderer": {
                                "text": { "runs": [{ "text": "One hundred songs" }] }
                              }
                            },
                            {
                              "musicResponsiveListItemFlexColumnRenderer": {
                                "text": { "runs": [{ "text": "Playlist" }] }
                              }
                            }
                          ],
                          "thumbnail": {
                            "musicThumbnailRenderer": {
                              "thumbnail": { "thumbnails": [{ "url": "https://example.test/art.jpg" }] }
                            }
                          }
                        }
                      }
                    ]
                  }
                },
                {
                  "continuationItemRenderer": {
                    "continuationEndpoint": {
                      "continuationCommand": { "token": "SEARCH_MORE" }
                    }
                  }
                }
              ]
            }
          }
        }
        """#)

        let page = InnerTubeParser.parseSearchPage(response)
        XCTAssertEqual(page.continuation, "SEARCH_MORE")
        XCTAssertEqual(page.rows.count, 1)
        let item = page.rows.first?.browseItem
        XCTAssertEqual(item?.browseId, "VLPL123")
        XCTAssertEqual(item?.title, "One hundred songs")
        XCTAssertEqual(item?.type, .playlist)
        XCTAssertEqual(item?.thumbnailUrl, "https://example.test/art.jpg")
    }

    func testSearchPageDeduplicatesRepeatedRowsBeforePagination() {
        let row = #"""
        {
          "musicResponsiveListItemRenderer": {
            "navigationEndpoint": {
              "browseEndpoint": {
                "browseId": "VLPL123",
                "browseEndpointContextSupportedConfigs": {
                  "browseEndpointContextMusicConfig": {
                    "pageType": "MUSIC_PAGE_TYPE_PLAYLIST"
                  }
                }
              }
            },
            "flexColumns": [
              {
                "musicResponsiveListItemFlexColumnRenderer": {
                  "text": { "runs": [{ "text": "Repeated playlist" }] }
                }
              }
            ]
          }
        }
        """#
        let response = json(#"""
        {
          "contents": [ \#(row), \#(row) ],
          "continuations": [
            { "nextContinuationData": { "continuation": "NEXT_PAGE" } }
          ]
        }
        """#)

        let page = InnerTubeParser.parseSearchPage(response)
        XCTAssertEqual(page.continuation, "NEXT_PAGE")
        XCTAssertEqual(page.rows.count, 1)
        XCTAssertNotNil(page.rows.first?.browseItem)
    }

    func testPlaylistContinuationRowsAreRealTracksEvenWithoutSetVideoIds() throws {
        let response = json(#"""
        {
          "continuationContents": {
            "musicPlaylistShelfContinuation": {
              "contents": [
                {
                  "musicResponsiveListItemRenderer": {
                    "playlistItemData": { "videoId": "song-2" },
                    "flexColumns": [
                      {
                        "musicResponsiveListItemFlexColumnRenderer": {
                          "text": { "runs": [{ "text": "Second page song" }] }
                        }
                      },
                      {
                        "musicResponsiveListItemFlexColumnRenderer": {
                          "text": { "runs": [{ "text": "Artist" }, { "text": " • " }, { "text": "3:21" }] }
                        }
                      }
                    ]
                  }
                }
              ],
              "continuations": [
                { "nextContinuationData": { "continuation": "PLAYLIST_MORE" } }
              ]
            }
          }
        }
        """#)

        let page = try XCTUnwrap(InnerTubeParser.parsePlaylistShelf(response))
        XCTAssertEqual(page.songs.map(\.videoId), ["song-2"])
        XCTAssertEqual(page.suggested.map(\.videoId), [])
        XCTAssertEqual(page.continuation, "PLAYLIST_MORE")
    }

    func testAlbumBackingPlaylistComesFromTheHeaderInsteadOfRecommendationShelves() {
        let response = json(#"""
        {
          "contents": {
            "musicResponsiveHeaderRenderer": {
              "title": { "runs": [{ "text": "Full album" }] },
              "buttons": [{
                "musicPlayButtonRenderer": {
                  "playNavigationEndpoint": {
                    "watchPlaylistEndpoint": { "playlistId": "OLAK5uy_album" }
                  }
                }
              }]
            },
            "musicCarouselShelfRenderer": {
              "contents": [{
                "musicPlayButtonRenderer": {
                  "playNavigationEndpoint": {
                    "watchPlaylistEndpoint": { "playlistId": "OLAK5uy_recommendation" }
                  }
                }
              }]
            }
          }
        }
        """#)
        XCTAssertEqual(InnerTubeParser.parseAlbumPlaylistId(response), "OLAK5uy_album")
    }

    func testAlbumBackingPlaylistFallsBackToItsCanonicalURL() {
        let response = json(#"""
        {
          "microformat": {
            "microformatDataRenderer": {
              "urlCanonical": "https://music.youtube.com/playlist?list=OLAK5uy_complete&feature=share"
            }
          }
        }
        """#)
        XCTAssertEqual(InnerTubeParser.parseAlbumPlaylistId(response), "OLAK5uy_complete")
    }

    func testLibraryItemPageKeepsSavedCardsAndNextContinuation() {
        let response = json(#"""
        {
          "contents": [
            {
              "musicTwoRowItemRenderer": {
                "title": { "runs": [{ "text": "Road songs" }] },
                "subtitle": { "runs": [{ "text": "Playlist" }] },
                "navigationEndpoint": { "browseEndpoint": { "browseId": "VLPLROAD" } },
                "thumbnailRenderer": {
                  "musicThumbnailRenderer": {
                    "thumbnail": { "thumbnails": [{ "url": "https://example.test/road.jpg" }] }
                  }
                }
              }
            }
          ],
          "continuations": [
            { "nextContinuationData": { "continuation": "LIBRARY_MORE" } }
          ]
        }
        """#)

        let page = InnerTubeParser.parseLibraryItemPage(response)
        XCTAssertEqual(page.continuation, "LIBRARY_MORE")
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items.first?.browseId, "VLPLROAD")
        XCTAssertEqual(page.items.first?.title, "Road songs")
    }

    func testUserPlaylistsFilterStillExcludesNonEditableAutoPlaylistsAfterPaging() {
        let playlists = InnerTubeParser.parseUserPlaylists([
            ShelfItem(title: "Road songs", subtitle: "Playlist", thumbnailUrl: nil, videoId: nil, browseId: "VLPLROAD"),
            ShelfItem(title: "Liked Music", subtitle: "Auto playlist", thumbnailUrl: nil, videoId: nil, browseId: "VLLM"),
            ShelfItem(title: "Album", subtitle: "Album", thumbnailUrl: nil, videoId: nil, browseId: "MPREb_album"),
            ShelfItem(title: "Mix", subtitle: "Mix", thumbnailUrl: nil, videoId: nil, browseId: "VLRDTMAK5uy_mix"),
            ShelfItem(title: "Album playlist", subtitle: "Album", thumbnailUrl: nil, videoId: nil, browseId: "VLOLAK5uy_x"),
            ShelfItem(title: "New playlist", subtitle: "", thumbnailUrl: nil, videoId: nil, browseId: nil),
        ])
        XCTAssertEqual(playlists.map(\.playlistId), ["PLROAD"])
        XCTAssertEqual(playlists.first?.browseId, "VLPLROAD")
    }

    // MARK: - Recorded responses

    func testSongsFilterFixture() throws {
        let page = InnerTubeParser.parseSearchPage(try Fixtures.json("search_songs.json"))
        let songs = page.rows.compactMap(\.trackSong)
        XCTAssertEqual(songs.count, page.rows.count, "the Songs tab is all tracks")
        XCTAssertEqual(songs.count, 20)
        XCTAssertTrue(songs.allSatisfy { !$0.isVideo })
        let first = try XCTUnwrap(songs.first)
        XCTAssertEqual(first.videoId, "khnokW3Mw24")
        XCTAssertEqual(first.title, "Instant Crush (feat. Julian Casablancas)")
        XCTAssertEqual(first.artist, "Daft Punk, Julian Casablancas")
        XCTAssertEqual(first.artistId, "UCRr1xG_2WIDs18a6cIiCxeA")
        XCTAssertEqual(first.albumId, "MPREb_K8qWMWVqXGi")
        XCTAssertEqual(first.albumName, "Random Access Memories")
        XCTAssertEqual(first.durationText, "5:38")
        XCTAssertNotNil(first.thumbnailUrl)
        XCTAssertNotNil(page.continuation)
    }

    func testSongsContinuationFixture() throws {
        let page = InnerTubeParser.parseSearchPage(try Fixtures.json("search_songs_continuation.json"))
        XCTAssertEqual(page.rows.count, 20)
        XCTAssertEqual(page.rows.first?.trackSong?.videoId, "52fNscjkST4")
        XCTAssertEqual(page.rows.first?.trackSong?.albumName, "Discovery")
        XCTAssertNotNil(page.continuation)
    }

    func testVideosFilterFixtureKeepsOnlyVideos() throws {
        let music = InnerTubeParser.parseSearchPage(try Fixtures.json("search_videos.json"))
        XCTAssertTrue(music.rows.isEmpty, "video rows never reach a music-only page")
        let page = InnerTubeParser.parseSearchPage(try Fixtures.json("search_videos.json"), includeVideos: true)
        let videos = page.rows.compactMap(\.trackSong)
        XCTAssertEqual(videos.count, 20)
        XCTAssertTrue(videos.allSatisfy(\.isVideo))
        XCTAssertEqual(videos.first?.videoId, "a5uQMwRMHcs")
        XCTAssertEqual(videos.first?.artist, "Daft Punk")
        XCTAssertEqual(videos.first?.durationText, "5:40")
    }

    func testAlbumsFilterFixture() throws {
        let page = InnerTubeParser.parseSearchPage(try Fixtures.json("search_albums.json"))
        let albums = page.rows.compactMap(\.browseItem)
        XCTAssertEqual(albums.count, 20)
        XCTAssertTrue(albums.allSatisfy { $0.type == .album })
        XCTAssertEqual(albums.first?.browseId, "MPREb_K8qWMWVqXGi")
        XCTAssertEqual(albums.first?.title, "Random Access Memories")
        XCTAssertEqual(albums.first?.subtitle, "Album • Daft Punk • 2013")
        XCTAssertNotNil(page.continuation)
    }

    func testArtistsFilterFixture() throws {
        let page = InnerTubeParser.parseSearchPage(try Fixtures.json("search_artists.json"))
        let artists = page.rows.compactMap(\.browseItem)
        XCTAssertEqual(artists.count, 10)
        XCTAssertTrue(artists.allSatisfy { $0.type == .artist })
        XCTAssertEqual(artists.first?.browseId, "UCRr1xG_2WIDs18a6cIiCxeA")
        XCTAssertEqual(artists.first?.title, "Daft Punk")
        XCTAssertNil(page.continuation)
    }

    func testPlaylistsFilterFixture() throws {
        let page = InnerTubeParser.parseSearchPage(try Fixtures.json("search_playlists.json"))
        let playlists = page.rows.compactMap(\.browseItem)
        XCTAssertFalse(playlists.isEmpty)
        XCTAssertTrue(playlists.allSatisfy { $0.type == .playlist && $0.browseId.hasPrefix("VL") })
        XCTAssertEqual(playlists.first?.browseId, "VLPLar0gUcrS11gS7cG8LoP_GiJqlPS4LcQB")
        XCTAssertNotNil(page.continuation)
    }

    func testAllTabFixtureLeadsWithThePromotedArtistAndCreditsItsSongs() throws {
        let page = InnerTubeParser.parseSearchPage(try Fixtures.json("search_all.json"))
        let top = try XCTUnwrap(page.rows.first?.browseItem)
        XCTAssertEqual(top.browseId, "UCRr1xG_2WIDs18a6cIiCxeA")
        XCTAssertEqual(top.type, .artist)
        // The card's own rows ("Song • 5:35") take the card's credit.
        let daFunk = try XCTUnwrap(page.rows.compactMap(\.trackSong).first { $0.videoId == "32J7bZHva9M" })
        XCTAssertEqual(daFunk.artist, "Daft Punk")
        XCTAssertEqual(daFunk.artistId, "UCRr1xG_2WIDs18a6cIiCxeA")
        // Music-only, and every row once.
        XCTAssertTrue(page.rows.compactMap(\.trackSong).allSatisfy { !$0.isVideo })
        XCTAssertEqual(Set(page.rows.map(\.id)).count, page.rows.count)
        XCTAssertTrue(page.rows.contains { $0.browseItem?.type == .album })
        XCTAssertTrue(page.rows.contains { $0.browseItem?.type == .playlist })
    }

    func testSuggestionsFixture() throws {
        XCTAssertEqual(
            InnerTubeParser.parseSearchSuggestions(try Fixtures.json("search_suggestions.json")),
            ["daft punk", "daft punk instant crush", "daft punk veridis quo", "daft punk giorgio moroder", "daft punk get lucky", "daft punk tron"]
        )
    }

    func testSuggestionsFallBackToDisplayRunsAndDeduplicate() {
        let response = json(#"""
        {"contents":[
          {"searchSuggestionRenderer":{"suggestion":{"runs":[{"text":"daft","bold":true},{"text":" punk"}]}}},
          {"searchSuggestionRenderer":{"navigationEndpoint":{"searchEndpoint":{"query":"daft punk"}}}},
          {"searchSuggestionRenderer":{"suggestion":{"runs":[{"text":" "}]}}}
        ]}
        """#)
        XCTAssertEqual(InnerTubeParser.parseSearchSuggestions(response), ["daft punk"])
    }
}
