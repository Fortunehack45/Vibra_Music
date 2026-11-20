Fixtures for InnerTubeTests. Load with FixtureLoader(bundle: .module) (see ../InnerTubeTestSupport.swift).

Recorded live (signed out) on 2026-09-26 from music.youtube.com with the WEB_REMIX client, hl=en gl=US.
The capture machine's visitor id is region IN, which is why Home leads with "India's biggest hits".
  home.json, home_continuation.json   FEmusic_home and its continuation (signed out, the continuation
                                      answers with no shelves - as the Android comment says)
  new_releases.json, explore.json     FEmusic_new_releases, FEmusic_explore (Home supplements)
  moods_and_genres.json               FEmusic_moods_and_genres
  mood_chill.json                     FEmusic_moods_and_genres_category, params of the "Chill" button
  search_{all,songs,videos,albums,artists,playlists}.json
                                      search "daft punk" with each filter's params
  search_songs_continuation.json      the Songs page's continuation
  search_suggestions.json             music/get_search_suggestions "daft p"
  album.json                          MPREb_7ltM34kr0mH (Discovery)
  album_playlist.json                 VLOLAK5uy_mz6eafmqdRHSaR4IwG0ll6J6rgv0_ZpGw (its backing playlist)
  playlist.json                       VLPL8-o_KZwk58yx2eTIGcK1EvHZkMI__Th4 (53 tracks)
  playlist_continuation.json          that page's section-list continuation ("Related playlists")
  playlist_long.json                  VLPLciALUPf8sIJlvH350O8PWh4UbSbOffSJ (496 tracks)
  playlist_long_continuation.json     its shelf continuation (arrives as onResponseReceivedActions)
  artist.json                         UCRr1xG_2WIDs18a6cIiCxeA (Daft Punk)
  next.json                           next for 5NV6Rdv1a3I (RDAMVM radio)
  lyrics.json                         the Lyrics tab of khnokW3Mw24 (browse MPLYt_K8qWMWVqXGi-5)
  lyrics_unavailable.json             the Lyrics tab of 5NV6Rdv1a3I ("Lyrics not available")
  sw_js_data.txt                      www.youtube.com/sw.js_data (visitor id bootstrap)
  music_shell_signed_out.html         the ytcfg.set(...) script of the signed-out music.youtube.com shell

Edits made to recorded responses (none change what the parser reads):
  - tracking-only keys removed: trackingParams, clickTrackingParams, loggingContext, frameworkUpdates,
    serviceTrackingParams, mainAppWebResponseContext, loggingDirectives, accessibility, accessibilityData;
  - long lists capped to their first N items to keep the fixtures small (home 10, explore/new releases
    8, mood 6, artist carousels 8, next queue 15, playlist rows 20-25); continuation items are kept;
  - lyrics.json keeps only the first two lines of the song's lyrics (copyright);
  - the capture machine's IP address (remoteHost) replaced with 2001:db8::1.

signed_in/ holds signed-in responses, which can't be captured without a Google account. They are built
from the Android parser's expectations and the Kotlin unit tests, wrapping real signed-out renderers
where possible: account menu, accounts_list / account switcher (the AccountChannelTest items), history,
Liked Music (+continuation), library feeds, a signed-in next with like buttons and library toggles, the
signed-in shell's ytcfg keys, a signed-in Home continuation, edit/create/like responses, a transcript and
a player response with playbackTracking.
