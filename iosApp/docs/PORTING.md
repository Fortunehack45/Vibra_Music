# Porting Vibra Music to iOS

These are the notes the iOS port was planned and checked against. Code comments cite their sections (for example "PORTING.md §4") and the open questions in section 6 (for example "Q8").

Target: native iOS app in SwiftUI, iOS 17+.
Source: [Vibra Music for Android](https://github.com/kushagrasinghx/Vibra Music), in Kotlin and Jetpack Compose (`app/`), plus a Go party server (`backend/`). The checklist was written against Android 1.7 ([tag v1.7](https://github.com/kushagrasinghx/Vibra Music/tree/v1.7)); items added from later Android releases say so, for example the app icon picker from 1.8.2.

Android paths below are relative to [`app/src/main/java/com/music/vibramusic/`](https://github.com/kushagrasinghx/Vibra Music/tree/v1.7/app/src/main/java/com/music/vibramusic) in the upstream repository, unless they start with `app/`, `backend/`, `native/`, `docs/` or `res/` (short for `app/src/main/res/`), which are relative to the upstream repository root. Paths that start with `App/` or name an iOS test (`VibraMusicTests/…`, `LyricsTests/…`) are in this repository.

---

## 1. App summary

Vibra Music is an unofficial YouTube Music client for Android.
It lets people search, browse and stream the YouTube Music catalogue, with or without a Google sign-in.
On top of that it adds lossless add-on sources, crossfade and Automix, synced lyrics, animated cover art, downloads and a yearly-recap screen.
Social extras: Listen Together parties, Discord Rich Presence and scrobbling.
It is aimed at music fans who want a nicer-looking, more tweakable YouTube Music experience.

---

## 2. Feature checklist

Core features come first. Each item has: what the user can do, the source files, and a "done" test.

### 2.1 Core streaming engine

- [x] **YouTube Music API client (Innertube)**
  - User can load feeds, search, and resolve playable streams without signing in.
  - Files: `data/innertube/*`, `data/YtMusicRepository.kt`, `data/Http.kt`
  - Done: a signed-out user searches "Daft Punk" and a song plays.
  - Tests: InnerTubeTests/InnerTubeRequestTests.testSignedOutBrowseIsAPlainWebRemixRequest, InnerTubeTests/YTMusicRepositoryTests.testEachFilterSendsItsParamsAndVideosOnlyAppearUnderVideos, VibraMusicTests/HomeFeedTests.testSupplementsJoinTheFeedWithoutRepeatingATitle
  - Note: The live search-and-play run (`VibraMusicUITests/SearchAndPlayE2ETests.testSearchingDaftPunkAndTappingTheFirstSongPlaysIt`) is in `VibraMusicE2E.xctestplan`, which the default test plan does not include; the offline tests above carry the coverage.
- [x] **Stream resolving (signature, `n` throttling, PoToken)**
  - The app gets a playable audio URL for any track.
  - Files: `data/innertube/StreamResolver.kt`, `PlayerClient.kt`, `InnerTubeXResolver.kt`, `potoken/*`, `app/src/main/assets/po_token.html`
  - Done: 20 random tracks all start playing within 3 s.
  - Tests: StreamResolutionTests/ClientCatalogWalkTests.testVisionOSAnswersFirstWithDirectAAC, StreamResolutionTests/StreamResolverTests.testCipherTierResolvesWhenTheDirectClientsCannot, StreamResolutionTests/ClientCatalogWalkTests.testPoTokensAreAttachedToWebIdentitiesOnly, StreamResolutionTests/StreamCipherSolverTests.testRecordedWebRemixFormatDeciphersToTheGoldenURL
  - Note: No test asserts "20 tracks start within 3 s": `StreamResolutionLiveTests.testResolvesTenLiveSearchResultsToWholeMP4Streams` resolves 10 tracks, only prints the timing, and runs only with `VIBRAMUSIC_LIVE_TESTS=1`.
- [ ] **Background playback and lock-screen controls**
  - User can lock the phone and keep listening, and control playback from the lock screen, Control Center and headphones.
  - Files: `playback/PlaybackService.kt`, `playback/PlayerConnection.kt`
  - Done: music keeps playing with the screen locked, and play/pause/next work from the lock screen and AirPods.
  - Tests (what exists): PlaybackTests/RemoteCommandTests.testTheDefaultActionsDriveTheEngine, PlaybackTests/NowPlayingInfoTests.testTheInfoDescribesTheItemAndItsProgress, PlaybackTests/AudioSessionEventTests.testPullingTheHeadphonesPausesForGood
  - Gap: device-only: playing with the screen locked and the real lock screen, Control Center and AirPods controls can't be exercised from tests. The audio background mode, remote commands and now-playing info are implemented and their logic is tested (tests above).
- [x] **Queue**
  - User can play next, add to queue, jump to a row, drag to reorder, remove and clear. The queue survives an app restart.
  - Files: `playback/QueueCoordinator.kt`, `QueueBuilder.kt`, `QueueHistory.kt`, `LastPlayed.kt`, `ui/player/PlayerQueue.kt`
  - Done: user adds 3 songs, reorders them, kills the app, reopens it and sees the same queue.
  - Tests: PlaybackQueueTests/QueueRestartTests.testAQueueBuiltAndReorderedSurvivesARestart, PlaybackQueueTests/QueueCoordinatorTests.testPlayNextInsertsRightAfterTheCurrentEntry, PlaybackQueueTests/PlaybackQueueControllerTests.testDraggingMovesRowsWithinTheirOwnSectionOnly, VibraMusicTests/QueuePanelTests.testTheUserJumpsReordersRemovesAndClearsTheirQueue
- [x] **Shuffle and repeat**
  - Shuffle reorders the queue and restores the old order when turned off. Repeat is off, all or one.
  - Files: `playback/QueueShuffle.kt`, `ui/player/PlayerControls.kt`
  - Done: turning shuffle on then off puts the queue back in its original order.
  - Tests: PlaybackQueueTests/QueueShuffleToggleTests.testTurningShuffleOnThenOffPutsTheQueueBackInItsOriginalOrder, PlaybackQueueTests/QueueShuffleTests.testShufflingThenRestoringReturnsTheOriginalRunningOrder, PlaybackQueueTests/PlaybackQueueControllerTests.testRepeatCyclesOffAllOneAndPersists, VibraMusicTests/QualityUpgradeWiringTests.testARepeatOnePlayKeepsItsResolvedStream
- [x] **Autoplay and radio**
  - When the queue ends, the app keeps playing related songs. "Start radio" works from any song.
  - Files: `playback/Autoplay.kt`, `playback/PlayerConnection.kt`
  - Done: the last song in a playlist ends and a related song starts on its own.
  - Tests: PlaybackQueueTests/AutoplayQueueTests.testTheLastSongOfAPlaylistIsFollowedByRelatedSongs, VibraMusicTests/PlayerControllerWiringTests.testWhenTheLastSongEndsAutoplayFetchesRelatedSongsAndPlaysOn, PlaybackQueueTests/RadioTests.testRadioFromAnotherSongReplacesTheQueueAndNamesTheStation
  - Note: No test drives `PlayerController.startRadio` or the song sheet's radio row; the radio queue logic itself is covered by `RadioTests`.
- [x] **Audio quality per network**
  - User sets separate quality limits for Wi-Fi and mobile data (Low, Medium, High, Lossless).
  - Files: `data/settings/AppSettings.kt`, `data/sources/SourceResolver.kt`, `ui/screens/SettingsSheet.kt`
  - Done: on cellular with "Low" set, stats for nerds shows about 64 kbps.
  - Tests: PlaybackPolicyTests/QualityCeilingTests.testOnCellularWithLowSetStatsShowAbout64Kbps, VibraMusicCoreTests/AudioQualityTests.testLowOnCellularAsksYouTubeForAbout64Kbps, VibraMusicTests/PlayerControllerWiringTests.testTheResolverIsAskedUnderThePerNetworkCeiling
- [x] **Audio cache**
  - Played audio is cached on disk. The next track is fetched ahead. User sets the cache size (up to 10 GB) and can clear it.
  - Files: `playback/AudioCache.kt`, `DynamicLruCacheEvictor.kt`, `ChunkedDataSource.kt`
  - Done: replaying a cached song in airplane mode works.
  - Tests: AudioCacheTests/ResourceLoaderPlaybackTests.testFullyCachedTrackDecodesCompletelyInAirplaneMode, AudioCacheTests/ReadAheadTests.testNextTrackIsCachedWholeAndTheOneAfterOnlyWarmed, AudioCacheTests/CacheStorageControlTests.testClearFreesTheSpaceItReports, VibraMusicTests/SongCacheLimitTests.testTheSliderRunsFrom512MBTo10GBIn512MBNotches

### 2.2 Navigation and main screens

- [x] **Tab bar**
  - Four tabs: Home, Explore, Library, Search. A mini player sits above the tabs.
  - Files: `MainActivity.kt`, `ui/MainViewModel.kt`, `ui/components/FloatingBottomBar.kt`, `MiniPlayer.kt`
  - Done: user switches tabs, and tapping the mini player opens Now Playing.
  - Tests: VibraMusicTests/TabNavigationTests.testTabsKeepTheirOwnPagesAndReselectingPopsToTheRoot, VibraMusicTests/MiniPlayerTests.testTappingTheMiniPlayerOpensNowPlaying, VibraMusicTests/MiniPlayerTests.testTheMiniPlayerSitsAboveTheTabBar
  - Note: a SwiftUI tap gesture can't be sent from a test, so `MiniPlayerTests.testTappingTheMiniPlayerOpensNowPlaying` fires the mini player's "Now playing" accessibility action, which `MiniPlayer` wires to the same request as the tap.
- [x] **Mini player**
  - User can play/pause, skip, and swipe left or right to change track.
  - Files: `ui/components/MiniPlayer.kt`
  - Done: swiping the mini player left plays the next song.
  - Tests: VibraMusicTests/MiniPlayerTests.testSwipingTheMiniPlayerLeftPlaysTheNextSong, VibraMusicTests/MiniPlayerTests.testTheSwipeDecidesOnReleasePastTheThreshold
  - Note: Swipe right and the play/pause button are tested only as the swipe-to-action mapping, not by driving the view.
- [x] **Home feed**
  - User sees YouTube Music shelves (Quick picks, Listen again, Mixed for you, Charts, New releases and so on). "Recently played" comes first when signed in. Scrolling loads more. Pull to refresh.
  - Files: `ui/screens/HomeScreen.kt`, `ui/MainViewModel.kt`
  - Done: Home loads shelves; tapping a song starts a radio; tapping an album opens it.
  - Tests: VibraMusicTests/HomeFeedTests.testHomeRendersItsShelvesFromAStubbedInnerTube, VibraMusicTests/HomeFeedTests.testRecentsLeadWhenSignedInAndReplaceAStaleCopyFromTheFeed, VibraMusicTests/HomeFeedTests.testMoreShelvesAreAppendedFromTheContinuation, VibraMusicTests/HomeFeedTests.testPullToRefreshKeepsTheFeedOnScreenAndSwapsItInPlace
  - Note: Tapping a song card is tested through `player.playSong`, not through the card's tap handler. Album taps: `HomeFeedTests.testTappingAnAlbumCardOpensItAndHoldingItOpensItsMenu`.
- [x] **Explore**
  - User browses a Moods and Genres grid and opens a category's playlists.
  - Files: `ui/screens/ExploreScreen.kt`, `ui/MainViewModel.kt`
  - Done: tapping "Chill" shows a list of playlists.
  - Tests: VibraMusicTests/ExploreTests.testMoodsAndGenresLoadFromAStubbedInnerTubeAndBorrowTheirCovers, VibraMusicTests/ExploreTests.testACategoryOpensItsPlaylistShelves
- [x] **Search**
  - Suggestions while typing; filters for All, Songs, Videos, Albums, Artists and Playlists; a top-result card; paging; up to 20 recent searches that can be removed.
  - Files: `ui/screens/SearchScreen.kt`, `data/settings/SearchHistory.kt`, `data/model/Models.kt`
  - Done: user filters by Albums, opens one, and sees it in recent searches afterwards.
  - Tests: VibraMusicTests/SearchTests.testTypingShowsTheTypedTextThenCompletions, VibraMusicTests/SearchTests.testSubmittingASearchShowsTheTopResultAndGroupedSectionsFromAStubbedInnerTube, VibraMusicTests/SearchTests.testTheNextPageIsFetchedAtTheEndAndMergedWithoutRepeats, VibraMusicTests/SearchTests.testFilteringByAlbumsOpeningOneAndFindingItInRecentSearches
- [x] **Album and playlist pages**
  - User can play, shuffle, save to library, filter tracks, sort, and expand the description.
  - Files: `ui/screens/DetailScreen.kt`
  - Done: user opens an album, taps Shuffle, and the queue is that album shuffled.
  - Tests: VibraMusicTests/AlbumPlaylistPageTests.testOpeningAnAlbumAndTappingShuffleQueuesThatAlbumShuffled, VibraMusicTests/AlbumPlaylistPageTests.testSavingToTheLibraryIsOptimisticAndRolledBackOnRefusal, VibraMusicTests/DetailPageLogicTests.testFilteringKeepsTheReleasesOwnTrackNumbers, VibraMusicTests/SortOptionsTests.testSortingAPlaylistByTitleAToZReordersIt
  - Note: "Expand the description" is a view-local toggle with no test, and the shuffle test calls `player.shufflePlay` rather than tapping the button.
- [x] **Artist pages**
  - User sees top songs and releases, and can subscribe.
  - Files: `ui/screens/DetailScreen.kt`
  - Done: user opens an artist, sees top songs, and subscribing survives a refresh.
  - Tests: VibraMusicTests/ArtistPageTests.testSubscribingToAnArtistSurvivesARefresh, VibraMusicTests/ArtistPageTests.testTopSongsAndReleaseShelvesAreCapped, InnerTubeTests/YTMusicRepositoryTests.testArtistPageFillsTopSongsAndEveryShelfWithAMoreLink
- [x] **Song actions menu**
  - Like, dislike, add to or remove from playlist, download, start radio, play next, add to queue, open album, open artist, sleep timer, lyrics offset, share.
  - Files: `ui/components/SongActionsSheet.kt`
  - Done: every row works on a song from Search.
  - Tests: VibraMusicTests/SongActionsMenuTests.testEveryRowWorksOnASongFromSearch, VibraMusicTests/SongActionsMenuTests.testTheSleepTimerPickerArmsAndCancels, VibraMusicTests/SongActionsMenuTests.testRemoveFromPlaylistIsOfferedOnlyOnTheAccountsOwnPlaylist, VibraMusicTests/LikesAndDislikesTests.testDislikingThePlayingSongFromTheMenuSkipsIt
  - Note: The tests host the sheet but call the underlying player, store and router actions instead of tapping rows. Radio, add-to-playlist and lyrics offset are covered only at their own level (`RadioTests`, `PlaylistManagementTests`, `LyricsOffsetUITests`).
- [x] **Album and playlist actions menu**
  - Play, shuffle, play next, add to queue, download all, share, pin, rename, delete.
  - Files: `ui/components/BrowseActionsSheet.kt`
  - Done: "Download all" on an album saves every track.
  - Tests: VibraMusicTests/BrowseActionsMenuTests.testDownloadAllOnAnAlbumCardQueuesEveryTrack, VibraMusicTests/BrowseActionsMenuTests.testQueueRowsFetchTheListingForACard, VibraMusicTests/PlaylistManagementTests.testPinningIsCappedAtFive, VibraMusicTests/PlaylistManagementTests.testRemovingASongAndDeletingAPlaylist
  - Note: Rename is covered by `PlaylistManagementTests.testCreatingAddingTwoSongsAndRenamingShowsEverywhere`. The sheet's Play, Shuffle and Share rows are not driven individually; the sheet is only rendered (`BrowseActionsMenuTests.testTheSheetFromThePageUsesThePagesRows`).
- [x] **Swipe to queue**
  - Swiping a song row runs "play next" or "add to queue", depending on a setting.
  - Files: `ui/screens/SearchScreen.kt`, `MainActivity.kt`
  - Done: swiping a search result adds it to the queue.
  - Tests: VibraMusicTests/SearchTests.testSwipingASearchHitQueuesItNextOrLastPerTheSetting
  - Note: The test calls `PlayerController.queueFromSwipe` directly rather than performing the row gesture.
- [x] **Sort options**
  - Library grids can be sorted by title. Album and playlist pages can be sorted by title or by date added.
  - Files: `data/settings/AppSettings.kt` (`LibrarySort`, `SongSort`), `MainActivity.kt`
  - Done: sorting a playlist by Title A–Z reorders it.
  - Tests: VibraMusicTests/SortOptionsTests.testSortingAPlaylistByTitleAToZReordersIt, VibraMusicTests/SortOptionsTests.testDateAddedUsesTheRunningOrderUnlessRowsAreDated, VibraMusicTests/SortOptionsTests.testALibraryGridSortsByTitleAndAnExplicitSortOutranksPins, VibraMusicTests/SortOptionsTests.testTheSortIsRememberedPerPageAndTheDateRowFlips
  - Note: Description corrected: on Android `LibrarySort` is only DEFAULT, TITLE_ASC and TITLE_DESC (`data/settings/AppSettings.kt:161`); date added exists only in `SongSort`, for album and playlist pages. iOS matches.

### 2.3 Now Playing

- [x] **Now Playing screen**
  - Artwork, seek bar, controls, quality badge, "Playing from", and a drawer that holds the lyrics and queue panels.
  - Files: `ui/player/NowPlayingScreen.kt`, `PlayerControls.kt`, `PlayerDrawer.kt`, `ThinSlider.kt`
  - Done: user can scrub, skip and open the lyrics and queue panels.
  - Tests: VibraMusicTests/NowPlayingScreenTests.testTheUserCanScrubSkipAndOpenTheLyricsAndQueuePanels, VibraMusicTests/NowPlayingScreenTests.testAReleasedScrubHoldsTheDropPointUntilThePlayerCatchesUp, VibraMusicTests/NowPlayingScreenTests.testThePlayerRendersOnEverySurface, VibraMusicTests/StatsForNerdsTests.testDolbyAtmosAndLossyTiersGetTheirBadges
  - Note: "Playing from" is asserted on `PlayerController.playingFrom`, not on the drawn label.
- [x] **Artwork-driven background**
  - A colour mesh taken from the album art, which crossfades when the track changes.
  - Files: `ui/player/MeshGradient.kt`, `ArtworkMeshBackdrop.kt`, `ui/theme/ArtworkPalette.kt`
  - Done: the background colours change with each new song.
  - Tests: VibraMusicTests/ArtworkBackgroundTests.testTheBackgroundColoursChangeWithEachNewSong, VibraMusicTests/CanvasBackdropTests.testTheCrossfadeKeepsTheOldMeshOpaqueUnderTheNewOne, VibraMusicTests/CanvasBackdropTests.testAChangeMidFadeStartsFromWhatIsOnScreen, ThemingTests/ArtworkMeshCrossfadeTests.testNewMeshFadesInOverTheOldOne
- [x] **Landscape layout**
  - Artwork and lyrics side by side.
  - Files: `ui/player/LandscapePlayer.kt`
  - Done: rotating the iPhone shows artwork and lyrics side by side.
  - Tests: VibraMusicTests/LandscapeLayoutTests.testRotatingShowsTheArtworkBesideTheLyrics, VibraMusicTests/LandscapeLayoutTests.testASidewaysPhoneGetsTheTwoColumnPlayerAndAnUprightTabletDoesNot
  - Note: The rotation test checks that the two-column view lays out, not where artwork and lyrics sit; the portrait/landscape choice is asserted in the second test.
- [x] **Stats for nerds**
  - Shows codec, bitrate, sample rate and bit depth, plus Lossless and Hi-Res badges.
  - Files: `data/NerdStats.kt`, `ui/player/PlayerControls.kt`
  - Done: turning on the toggle shows real stream stats.
  - Tests: VibraMusicTests/StatsForNerdsTests.testTurningOnTheToggleShowsRealStreamStatsOnTheSleeve, VibraMusicTests/StatsForNerdsTests.testAHiResFlacReadsAsHiResLosslessWithItsFigures, PlaybackPolicyTests/NerdStatsTests.testALosslessMeasurementReportsItsPCMRate
- [x] **Animated cover art (Canvas)**
  - A looping video over the cover, from Spotify, Apple Music, Tidal or a community index. It can be turned off, or allowed on Wi-Fi only.
  - Files: `data/canvas/*`, `ui/player/CanvasArtworkPlayer.kt`, `ui/screens/SpotifyCanvasAuthScreen.kt`
  - Done: a popular track shows motion artwork on Wi-Fi.
  - Tests: VibraMusicTests/AnimatedCoverArtTests.testAPopularTrackShowsItsClipOnWiFiAndNothingOnceItIsNotAllowed, VibraMusicTests/AnimatedCoverArtTests.testTheClipIsOffWhenSwitchedOffAndWiFiOnlyKeepsItOffCellular, CanvasTests/CanvasRepositoryTests.testFirstHitWinsAndHitsAreCached, CanvasTests/CanvasPolicyTests.testCellularNeedsTheOptIn
  - Note: Real clips need the network and the Spotify web login screen has no UI test; the provider logic is tested per provider in `CanvasTests`.

### 2.4 Lyrics

- [x] **Synced lyrics**
  - Line and word-level highlighting, duet sides, backing vocals, instrumental gaps, and blur on lines that aren't focused.
  - Files: `data/lyrics/*`, `ui/player/PlayerLyrics.kt`, `LyricClock.kt`, `LyricFocus.kt`
  - Done: a known track shows word-by-word highlighting in time with the music.
  - Tests: VibraMusicTests/SyncedLyricsPanelTests.testAKnownTrackHighlightsWordByWordInTimeWithTheMusic, VibraMusicTests/SyncedLyricsPanelTests.testInstrumentalBreaksDuetSidesAndBackingVocals, VibraMusicTests/SyncedLyricsPanelTests.testUnfocusedLinesFallAwayAndBlurUnlessBrowsingOrSwitchedOff, LyricsTests/WordSyncTests.testLaysADuetOutOnAlternatingSides
- [x] **Lyrics providers**
  - 16 providers that the user can turn on or off and reorder, plus a picker to choose a provider for the current track.
  - Files: `data/lyrics/LyricsSource.kt`, `LyricsRepository.kt`, `ui/components/LyricsSourcesDialog.kt`, `ui/player/LyricsProviderSheet.kt`
  - Done: turning off the top provider makes lyrics load from the next one.
  - Tests: VibraMusicTests/LyricsProviderUITests.testTurningOffTheTopProviderLoadsFromTheNextOne, VibraMusicTests/LyricsProviderUITests.testTheLastSourceStandingCantBeUntickedAndOrderIsIndependent, VibraMusicTests/LyricsProviderUITests.testPickingAFoundProviderSwitchesTheLyrics, LyricsTests/LyricsProviderPriorityTests.testTurningOffTheTopProviderLoadsFromTheNextOne
  - Note: Providers are tested with recorded answers; the live provider tests are opt-in.
- [x] **Lyrics offset**
  - User shifts lyric timing.
  - Files: `ui/player/LyricsOffsetSheet.kt`
  - Done: +500 ms moves the highlight later.
  - Tests: VibraMusicTests/LyricsOffsetUITests.testPlusFiveHundredMillisecondsMovesTheHighlightLater, VibraMusicTests/LyricsOffsetUITests.testTheButtonsClampAndTheSliderSnapsToTheStep, LyricsTests/LyricsOffsetTests.testPlusFiveHundredMillisecondsMovesTheHighlightLater
- [x] **Lyrics translation and romanization**
  - Translate into the app's language, or into a chosen one from about 130 languages.
  - Files: `data/lyrics/LyricsTranslation.kt`, `TranslationLanguages.kt`, `ui/components/TranslationLanguageDialog.kt`, [`docs/LYRICS_TRANSLATION.md`](https://github.com/kushagrasinghx/Vibra Music/blob/v1.7/docs/LYRICS_TRANSLATION.md)
  - Done: Japanese lyrics become English, and the timing still matches.
  - Tests: VibraMusicTests/LyricsTranslationUITests.testJapaneseLyricsBecomeEnglishAndTheTimingStillMatches, VibraMusicTests/LyricsTranslationUITests.testTheLanguagePickerListsAboutOneHundredThirtyAndFiltersInEitherLanguage, LyricsTests/LyricsTranslationTests.testRomanizationKeepsTheTimingToo
  - Note: Translation is tested against recorded answers; a live translation needs the network.

### 2.5 Account and library

- [x] **Google sign-in**
  - User signs in on Google's real web page and picks a Personal or Brand profile.
  - Files: `auth/YtMusicLoginScreen.kt`, `auth/WebSession.kt`, `auth/AuthStore.kt`
  - Done: user logs in and sees their own "Recently played" on Home.
  - Tests: VibraMusicTests/GoogleSignInTests.testTheSignInPageIsGooglesOwnAndReturnsToYouTubeMusic, VibraMusicTests/GoogleSignInTests.testAnAcceptedSignInLandsOnLibraryWithTheAccountPagesClosed, InnerTubeTests/YouTubeAccountManagerTests.testAValidatedSignInIsStoredAndActsAsTheCapturedIdentity, VibraMusicTests/HomeFeedTests.testRecentsLeadWhenSignedInAndReplaceAStaleCopyFromTheFeed
  - Note: Signing in on Google's real page with a real account can't run in an automated test (network and a real account).
- [x] **Multiple accounts and profiles**
  - Add accounts, switch profile, remove an account, sign out. Swiping on the avatar changes profile.
  - Files: `auth/AccountSessions.kt`, `ui/components/AccountProfileSelector.kt`, `ui/screens/AccountAndScrobblingScreen.kt`
  - Done: switching profile reloads Home and Library with the other profile's content.
  - Tests: VibraMusicTests/ProfileSwitchingTests.testSwitchingProfileChangesTheListenerHomeAndLibraryReloadFor, VibraMusicTests/ProfileSwitchingTests.testSwipingTheAvatarStepsThroughProfilesAndStopsAtTheEnds, VibraMusicTests/ProfileSwitchingTests.testRemovingAnAccountFallsBackToTheOtherAndSigningOutTheLastSignsOut, VibraMusicTests/LibraryTests.testAStaleOrSomeoneElsesLibraryIsFetchedAgain
  - Note: The view-level `.task(id:)` that starts the Home/Library reload is not exercised; tests cover the listener-key change and the reload rules.
  - Beyond Android: switching back to a listener paints their Home from the shelves they had when we left (Android blanks Home to Loading on every switch); the fresh first page merges into it shelf by shelf, and signing out drops the snapshots. Tests: VibraMusicTests/HomeFeedTests.testSwitchingBackPaintsTheListenersHomeFromTheirSnapshot, VibraMusicTests/HomeFeedTests.testOverASnapshotTheShelvesThatLandBeforeTheCoreFeedStay, VibraMusicTests/HomeFeedTests.testOverASnapshotTheCoreFeedLandingFirstLeavesRoomForTheRest, VibraMusicTests/HomeFeedTests.testSigningOutDropsTheHomeSnapshots
- [x] **Library**
  - Playlists, Albums, Artists and Subscriptions shelves, each with "Show all". Liked Music appears as a playlist. Signed-out users see a sign-in prompt.
  - Files: `ui/screens/LibraryScreen.kt`, `ui/MainViewModel.kt`
  - Done: a signed-in user sees the same playlists as in the official app.
  - Tests: VibraMusicTests/LibraryTests.testASignedInListenerSeesTheirShelvesWithLikedMusicAsAPlaylist, VibraMusicTests/LibraryTests.testSignedOutTheLibraryIsNotFetched, VibraMusicTests/LibraryTests.testShowAllRendersTheWholeShelf, VibraMusicTests/LibraryShelfLogicTests.testAShelfRowStopsAtFiveCardsWithShowAllBeyond
- [x] **Likes and dislikes**
  - Like and dislike sync with the account. Disliking the song that's playing skips it.
  - Files: `data/LikeState.kt`, `ui/MainViewModel.kt`
  - Done: a song liked in the app shows as liked on music.youtube.com.
  - Tests: InnerTubeTests/AccountWriteTests.testRatingsUseTheLikeEndpointsWithAVideoTarget, VibraMusicTests/LikesAndDislikesTests.testDislikingThePlayingSongFromTheMenuSkipsIt, PlaybackQueueTests/DislikeSkipPolicyTests.testDislikingThePlayingSongMovesTheQueueOn, VibraMusicTests/RatingsReachTheAccountTests.testLikingAndDislikingASongSendsTheRatingToYouTubeMusic
- [x] **Playlist management**
  - Create (Private, Unlisted or Public), rename, delete, pin, add or remove songs, add from the suggested songs.
  - Files: `ui/components/PlaylistPickerSheet.kt`, `BrowseActionsSheet.kt`, `ui/MainViewModel.kt`
  - Done: user creates a playlist, adds 2 songs, renames it, and the changes appear on the web.
  - Tests: VibraMusicTests/PlaylistManagementTests.testCreatingAddingTwoSongsAndRenamingShowsEverywhere, VibraMusicTests/PlaylistManagementTests.testRemovingASongAndDeletingAPlaylist, VibraMusicTests/PlaylistManagementTests.testAddingASuggestedSongMovesItIntoThePlaylist, InnerTubeTests/AccountWriteTests.testCreatingAPlaylistSendsPrivacyAndSeedsAndReadsTheId
  - Note: Only an Unlisted create is tested end to end; Private and Public use the same code path. Pinning: `PlaylistManagementTests.testPinningIsCappedAtFive`.
- [x] **History**
  - The account's listening history. Tapping a row plays from that point.
  - Files: `ui/screens/HistoryScreen.kt`
  - Done: the last song played appears at the top.
  - Tests: VibraMusicTests/HistoryTests.testTheHistoryLoadsAndTappingARowPlaysFromThere, VibraMusicTests/HistoryTests.testSignedOutOrEmptyHistorySaysSo

### 2.6 Downloads and offline

- [x] **Download songs, albums and playlists**
  - A download queue with progress, cancel and retry. Metadata, cover art and lyrics are embedded in the files.
  - Files: `download/*`, `ui/components/DownloadManagerSheet.kt`
  - Done: user downloads an album, turns on airplane mode, and plays it with lyrics.
  - Tests: DownloadsTests/DownloadTransferTests.testARangedDownloadReportsProgressAndSavesEveryByte, DownloadsTests/DownloadTransferTests.testCancellingARunningDownloadDeletesItsPartFileAndItsRow, DownloadsTests/DownloadTransferTests.testRetryingAFailedTrackReplacesItsRowAndFinishes, DownloadsTests/DownloadEmbeddingTests.testAYouTubeShapedDownloadReadsAtItsTrueLengthWithItsTags
  - Note: No test plays a download in airplane mode end to end; offline lyrics (`LyricsTests/LyricsProviderPickerTests.testADownloadedFilesOwnLyricsComeFirstAndWorkOffline`) and the embedded tags are covered.
- [x] **Downloads screen**
  - Songs, Artists and Albums tabs; search; sort; multi-select delete.
  - Files: `ui/screens/LocalMusicScreen.kt`, `download/DownloadStore.kt`
  - Done: user selects 3 downloads, deletes them, and the storage is freed.
  - Tests: VibraMusicTests/DownloadsScreenTests.testSelectingThreeDownloadsAndDeletingThemFreesTheirStorage, VibraMusicTests/DownloadsScreenTests.testTheTabsGroupSortAndFilterTheFolder, DownloadsTests/DownloadLibraryStorageTests.testMultiSelectDeleteFreesTheStorageItReports
- [x] **Download settings**
  - Download quality (Standard, High, Lossless) and Wi-Fi only.
  - Files: `ui/screens/SettingsSheet.kt`, `data/settings/AppSettings.kt`
  - Done: with Wi-Fi only on, downloads wait while on cellular.
  - Tests: DownloadsTests/DownloadQualityRequestTests.testEachRungAsksTheResolverForTheMatchingRequest, DownloadsTests/DownloadWiFiOnlyTests.testADownloadWaitsOnCellularAndStartsOnWifi, DownloadsTests/DownloadWiFiOnlyTests.testWifiOnlyRefusesMeteredConnectionsAndNothingElse

### 2.7 Playback extras

- [x] **Crossfade (0–12 s)**
  - Two tracks overlap during the transition.
  - Files: `playback/CrossfadeController.kt`
  - Done: with a 6 s crossfade, the songs audibly overlap.
  - Tests: PlaybackTests/CrossfadePlaybackTests.testBothTracksOverlapWithEqualPowerGains, PlaybackTests/CrossfadeCurveTests.testEqualPowerGainsHoldConstantPowerAcrossTheFade, VibraMusicCoreTests/AppSettingsTests.testRangesAreClamped
  - Note: Overlap is asserted on the gains of two real decks; hearing it is a device check.
- [x] **Automix (beta)**
  - DJ-style transitions chosen by beat, tempo and vocal analysis.
  - Files: `playback/smart/*`, `playback/TransitionFilterProcessor.kt`, `native/analyzer/*`, `app/src/main/assets/*.onnx`
  - Done: two songs in a row blend on the beat, without two vocals clashing.
  - Tests: AutomixTests/TransitionPlannerTests.testBeatMatchedPairGetsAPhraseSwitchThatRespectsThePolicy, AutomixTests/TransitionPlannerTests.testBothSidesSingingShrinksTheOverlapAndReportsTheClash, AutomixTests/VocalTrackerTests.testTheShippedModelHearsWhenTheVoiceIsThere, PlaybackTests/CrossfadePlaybackTests.testAnAutomixSpecIsExecutedWithItsCueRateAndFilters
  - Note: Blending on the beat is asserted on the planner's output and the executed transition spec; hearing it is a device check.
- [x] **Equalizer**
  - Dynamic tone pad, or 7 manual bands with 16 presets; balance; automatic preamp.
  - Files: `playback/EqualizerProcessor.kt`, `EqualizerPreset.kt`, `EqualizerCurve.kt`, `ui/screens/EqualizerScreen.kt`
  - Done: the "Bass Boost" preset audibly boosts the low end.
  - Tests: AudioDSPTests/EqualizerFrequencyResponseTests.testBassBoostRaisesTheLowEndAgainstA4kHzSine, AudioDSPTests/EqualizerFrequencyResponseTests.testBalanceTrimsOneSideOnly, AudioDSPTests/EqualizerPresetTests.testThereAreSixteenPresetsPlusCustom, VibraMusicTests/EqualizerScreenTests.testTheAutomaticPreampTakesBackBoost
- [x] **Spatial audio (stereo widen)**
  - The app's own stereo widening, turned on with a toggle.
  - Files: `playback/SpatialAudioProcessor.kt`
  - Done: the toggle audibly widens the stereo image.
  - Tests: AudioDSPTests/StereoWidenTests.testTheSideSignalGrowsAndTheMidSignalDoesNot, AudioDSPTests/StereoWidenTests.testTogglingTakesEffectAtTheNextBlock
- [x] **Loudness normalization**
  - Files: `playback/PlaybackService.kt`
  - Done: quiet and loud tracks play at a similar volume.
  - Tests: AudioDSPTests/LoudnessNormalizationTests.testQuietAndLoudTracksPlayAtASimilarVolume, AudioDSPTests/LoudnessNormalizationTests.testGainIsHeldBetweenMinusFifteenAndPlusThreeDecibels
- [x] **Skip silence**
  - Files: `ui/screens/SettingsSheet.kt`, `playback/PlaybackService.kt`
  - Done: silent intros and outros are skipped.
  - Tests: PlaybackTests/SkipSilenceEngineTests.testAFileWithATwoSecondSilentIntroStartsAtAboutTwoSeconds, PlaybackTests/SkipSilenceEngineTests.testAGapInTheMiddleIsJumped, PlaybackTests/SkipSilenceEngineTests.testASilentOutroEndsTheTrackEarlyAndTheNextFollows
- [x] **Sleep timer**
  - 15, 30, 45 or 60 minutes, or "end of this track".
  - Files: `playback/SleepTimer.kt`, `ui/components/SongActionsSheet.kt`
  - Done: playback pauses when the 15 min timer runs out.
  - Tests: PlaybackQueueTests/SleepTimerTests.testThePresetsAreTheFourTheMenuOffers, PlaybackTests/SleepTimerEngineTests.testTheTimerPausesAtItsDeadline, PlaybackTests/SleepTimerEngineTests.testEndOfTrackPausesOnTheNextTrackWithoutPlayingIt, VibraMusicTests/SleepTimerTests.testPlaybackPausesWhenTheTimerRunsOut
- [x] **Quality upgrade and revert to original**
  - The app switches to a better copy of the same track while it plays. User can pin a track back to the YouTube original.
  - Files: `playback/QualityUpgrade.kt`, `OriginalVersion.kt`, `StreamChoice.kt`, `PlaybackFallback.kt`
  - Done: "Revert to original" plays YouTube's own upload, and stays that way after a relaunch.
  - Tests: VibraMusicTests/QualityUpgradeWiringTests.testABelowRequestStreamIsSwappedForTheBetterCopyOnce, VibraMusicTests/RevertToOriginalTests.testRevertToOriginalPinsTheTrackAndTheMenuThenOffersTheWayBack, PlaybackPolicyTests/OriginalVersionPinTests.testAPinSurvivesARelaunch
- [x] **Switch between song and music video**
  - Changes version and lines up the playback position across the two.
  - Files: `playback/smart/VersionAudioAligner.kt`, `playback/PlayerConnection.kt`
  - Done: switching versions carries on from about the same spot in the song.
  - Tests: VibraMusicTests/VersionSwitchWiringTests.testSwitchingVersionsLandsAtTheAlignedPosition, VibraMusicTests/VersionSwitchTests.testConvertingToVideoCarriesOnFromAboutTheSameSpot, AutomixTests/VersionAudioAlignerTests.testAMusicVideoWithAnIntroSkitLinesUpWithTheSong
- [ ] **Audio output picker**
  - Lists outputs with a volume control.
  - Files: `ui/player/AudioOutputSheet.kt`, `ui/player/AudioOutput.kt`, `playback/AudioRouting.kt`
  - Done on iOS: the system route picker opens and switches to AirPods.
  - Tests (what exists): VibraMusicTests/AudioOutputPickerTests.testTheSheetCarriesTheSystemRoutePickerAndTheVolume, PlaybackPolicyTests/AudioRoutingTests.testOneRowPerDeviceWithTheMediaProfilePreferred
  - Gap: device-only: switching to AirPods through the system route picker needs hardware. The sheet with the `AVRoutePickerView` and the volume control, and the output listing, are tested (tests above).
- [x] **Audio pipeline dialog**
  - Shows the chain from source to output, and whether the audio is changed along the way.
  - Files: `ui/components/AudioPipelineDialog.kt`, `playback/AudioOutputStatus.kt`
  - Done: the Resampler stage compares the source with the rate the app hands iOS, so a 44.1 kHz
    track on a 48 kHz route reads "Passthrough"; the route's own rate and its conversion sit on
    Output Device's "System" row, and the verdict names iOS as the converter. With EQ on, the
    dialog shows the signal as altered. A tap-less item's DSP rows read "Bypassed" / "—".
  - Tests: PlaybackPolicyTests/AudioPipelineTests.testTheResamplerStageSeparatesTheAppStageFromTheRoute, VibraMusicTests/AudioPipelineDialogTests.testWithTheEqualizerOnTheSignalReadsAsAltered, VibraMusicTests/AudioPipelineDialogTests.testTheDialogRendersAndMarksAnAlteredSignal, PlaybackPolicyTests/AudioSignalAlterationTests.testTheEqualizerAltersTheSignal

### 2.8 Sources

- [x] **Add-on sources (lossless)**
  - User adds HTTP add-on URLs, tests them, and drags to reorder.
  - Files: `data/sources/AddonSource.kt`, `data/sources/addon/*`, `ui/screens/SourcesScreen.kt`
  - Done: with a working add-on, stats for nerds shows FLAC.
  - Tests: VibraMusicTests/SourcesScreenModelTests.testAddingAnAddonTestsItThenSavesItUnderItsOwnName, SourcesTests/AddonSourceTests.testCheckIdentifiesProbesAndSavesAnAddon, SourcesTests/AddonSourceTests.testTheRoutingFieldsBecomeTheFormatThePlayerIsToldAbout, SourcesTests/AddonOrderTests.testReorderingPutsTheAddonsInTheOrderGiven
- [x] **JioSaavn source**
  - Optional source for AAC up to 320 kbps.
  - Files: `data/jiosaavn/JioSaavnService.kt`, `data/sources/JioSaavnSource.kt`
  - Done: with the toggle on and quality set to "High", some tracks play at 320 kbps.
  - Tests: SourcesTests/JioSaavnTests.testStreamDecryptsTheDetailsAnswerIntoA320AacStream, SourcesTests/JioSaavnTests.testDecryptsTheRecordedMediaURLAndPicksThe320Rendition, SourcesTests/SourceRegistryTests.testThePlaybackListFollowsTheConnectionsCeiling, VibraMusicTests/SourcesScreenModelTests.testTurningJioSaavnOnAsksFirstThenEnablesIt
- [x] **Legacy JS module sources**
  - Existing module configs still run, in JavaScriptCore on iOS (QuickJS on Android). New ones can't be added.
  - Files: `data/sources/ModuleSource.kt`, `data/sources/module/*`
  - Done: see open question Q4.
  - Tests: SourcesTests/ModuleSourceTests.testTheEngineKeepsModuleStateBetweenCallsAndPassesArgumentsAsValues, SourcesTests/ModuleSourceTests.testSearchFansOutToEveryModuleAndInterleavesTheirAnswers, SourcesTests/SourceFormatDetectionTests.testTheRegistryRefusesToAddANewModuleIndexButKeepsEditingAnExistingOne, VibraMusicTests/SourcesScreenModelTests.testAStoredLegacyModuleIsListedEditableAndRemovable
  - Note: Description corrected: the iOS engine runs module configs in JavaScriptCore (`ModuleScriptEngine.swift`), not QuickJS (see section 4). Q4 recommended dropping them, but they were ported.
- [x] **SMB network library**
  - Browse and stream from an SMB share.
  - Files: `data/smb/*`, `playback/SmbDataSource.kt`
  - Done: user connects to a NAS and plays a FLAC file.
  - Tests: NetworkLibraryTests/RemoteAudioSourceTests.testSmbSourceReadsRanges, VibraMusicTests/NetworkLibraryScreenTests.testAnSmbShareListsItsFlacFilesAsAlbums, AudioCacheTests/ResourceLoaderPlaybackTests.testCustomDataSourcePlugsIn, VibraMusicTests/NetworkSourceWiringTests.testAnSmbRowGetsASourceOnlyWhileAShareIsSaved
  - Note: the SMB test stops at the source, because a share can't be stood up in a test; reading from a real server is only in the opt-in `NetworkLibraryLiveTests` (macOS, `VIBRAMUSIC_LIVE_TESTS=1`).
- [x] **WebDAV network library**
  - Browse and stream from a WebDAV server, and upload local tracks to it.
  - Files: `data/webdav/*`
  - Done: user connects, plays a track, and uploads a download.
  - Tests: NetworkLibraryTests/RemoteAudioSourceTests.testWebDavSourceReadsRanges, NetworkLibraryTests/WebDavUploadsTests.testBatchUploadsNewFiles, VibraMusicTests/NetworkLibraryScreenTests.testUploadingADownloadAsksAboutAClashAndReportsTheSummary, VibraMusicTests/NetworkSourceWiringTests.testAWebDavRowIsReadFromItsServerWithTheSavedLogin

### 2.9 Social and integrations

- [x] **Listen Together**
  - Create or join a party with a 6-character code, a QR code or a link. Up to 5 devices share playback and queue. The host can lock controls, kick members and set the party size. Custom server supported.
  - Files: `data/listentogether/*`, `playback/PartySync.kt`, `PartyPersonalQueueStash.kt`, `ui/screens/ListenTogetherScreen.kt`, `ListenTogetherSheets.kt`, `PartyServerEditor.kt`, `ui/player/ListenTogetherMembersSheet.kt`, `ui/components/QrCode.kt`, `backend/`
  - Done: an iPhone and an Android phone join the same party, and play, pause and skip stay in sync.
  - Tests: VibraMusicTests/ListenTogetherFlowTests.testTheHostSetsTheSizeWithinItsBoundsLocksControlsAndRemovesPeople, VibraMusicTests/ListenTogetherFlowTests.testATypedCodeIsLettersAndDigitsUpperCasedAndSixLong, ListenTogetherTests/PartySyncCoordinatorTests.testFollowsHostPause, ListenTogetherTests/JamInviteLinkTests.testSchemeRoundTrip
  - Note: The QR code and custom server are covered by `ListenTogetherFlowTests.testTheInviteQRCodeDrawsOneDotPerDarkModule` and `PartyServerEditorTests.testTestSaysWhetherTheServerAnswersAndSaveStoresIt`. An iPhone and an Android phone in one party is a manual check; the only live end-to-end test (`ListenTogetherTests/PartyLiveE2ETests.testHostAndGuestStayInSync`) is opt-in and macOS-only.
- [x] **Scrobbling**
  - Last.fm and Libre.fm (username/password or browser login) and ListenBrainz (token), with timing options.
  - Files: `data/scrobbling/*`, `ui/screens/AccountAndScrobblingScreen.kt`
  - Done: a played track appears on the user's Last.fm profile.
  - Tests: IntegrationsTests/ScrobbleTimingTests.testHalfDurationBelowTheCap, IntegrationsTests/LastFMRequestTests.testScrobbleEncodingUsesIndexedKeys, IntegrationsTests/ListenBrainzPayloadTests.testSubmitSendsTokenHeader, VibraMusicTests/ScrobblingSettingsTests.testTheTimingOptionsStepLikeAndroid, VibraMusicTests/ScrobblingWiringTests.testThePasswordLoginSendsASignedMobileSessionRequestAndReturnsTheSession, VibraMusicTests/ScrobblingWiringTests.testAPlayedTrackIsSentToLastfmAsNowPlayingThenScrobbled, VibraMusicTests/ScrobblingWiringTests.testPlayingNowAndTheFinishedListenReachListenBrainzWithTheToken
  - Note: "Browser login" is not in the Android UI either (`LastFM.kt` defines `getToken`/`getSession`/`getAuthUrl` but nothing calls them), and Libre.fm works only through the `lastfmEndpoint` setting on both platforms (`LastFMRequestTests.testLibreFmAuthURL`).
- [ ] **Discord Rich Presence**
  - Shows the current song as a Discord status.
  - Files: `data/discord/*`, `com/my/kizzy/*`, `auth/DiscordLoginScreen.kt`, `ui/screens/DiscordScreen.kt`
  - Done: see open question Q3.
  - Tests (what exists): IntegrationsTests/DiscordGatewayHandshakeTests.testHelloIdentifyHeartbeatPresence, IntegrationsTests/DiscordGatewayCloseCodeTests.testRejectedTokenStopsTheGatewayForGood, IntegrationsTests/DiscordGatewayCloseCodeTests.testANewSessionPublishesThePresenceOnce, IntegrationsTests/DiscordPresenceBuildingTests.testButtonsResolveVariablesAndCarryURLs, VibraMusicTests/DiscordPresenceScreenTests.testAPastedTokenIsVerifiedBeforeItIsSaved
  - Gap: device-only: a real status on a Discord account needs a live account and gateway, and iOS suspends the socket in the background (section 4). The gateway handshake is tested against a local fake server. Nothing tests `DiscordPresenceObserver`. `DiscordGatewayHandshakeTests.testAReadyOverOneMebibyteStillOpensTheSession` used to flake because the fake gateway's 100 ms heartbeat interval raced its 3 MiB READY. Q3 recommends not shipping this in v1, though it is built.

### 2.10 Replay (listening recap)

- [x] **Replay stats**
  - Top songs, artists, albums and genres, plus listening habits, for this month, this year or all time.
  - Files: `ui/replay/ReplayScreen.kt`, `ReplayModel.kt`, `ReplayCard.kt`, `data/stats/*`
  - Done: after an hour of listening, Replay shows the right top artist.
  - Tests: ReplayTests/ReplayAggregationTests.testPeriodsFilterMonths, ReplayTests/ReplayAggregationTests.testRanksByMinutesThenPlays, ReplayTests/ReplayRecorderThresholdTests.testPlayCountedOnceAtThreshold, VibraMusicTests/ReplayStatsPageTests.testThePageOpensOnThisYearAndSwitchingPeriodReadsThatPeriod
- [x] **Replay stories**
  - 8 full-screen cards. Tap to move, hold to pause.
  - Files: `ui/replay/ReplayStories.kt`
  - Done: user taps through all 8 cards.
  - Tests: VibraMusicTests/ReplayStoriesTests.testTappingOnTheRightWalksThroughAllEightCardsAndTheLeftGoesBack, VibraMusicTests/ReplayStoriesTests.testHoldingStopsTheClockAndACardMovesOnAfterFourteenSeconds
- [x] **Share Replay poster**
  - Share the poster as an image, or save it to Photos.
  - Files: `ui/replay/ReplayPoster.kt`, `ReplayShareSheet.kt`
  - Done: the poster opens in the iOS share sheet and saves to Photos.
  - Tests: VibraMusicTests/ReplayPosterShareTests.testThePosterIsNineBySixteenAtTenEightyByNineteenTwenty, VibraMusicTests/ReplayPosterShareTests.testSaveDrawsThePosterAndSavesItOnceToPhotos, VibraMusicTests/ReplayPosterShareTests.testARefusedSaveCanBeTriedAgain
  - Note: The photo saver is injected and the system share sheet is only render-tested; the real Photos write and share sheet are a device check.
- [x] **"Play your Replay"**
  - Files: `ui/replay/ReplayScreen.kt`
  - Done: tapping it opens the Replay stories at the first card.
  - Tests: VibraMusicTests/PlayYourReplayTests.testPlayYourReplayOpensTheStoriesAtTheIntro, VibraMusicTests/ReplayStatsPageTests.testAPeriodWithNothingPlayedShowsTheEmptyState
  - Note: Done line corrected: on Android the button runs `onOpenStory(ReplayStoryPage.INTRO)` (`ui/replay/ReplayScreen.kt:183-185`), so it opens the stories at the first card and queues nothing. iOS matches. `replayQueueSongs` exists and is tested (`ReplayTests/ReplayStoryContentTests.testReplayQueueIsRankedSongs`) but nothing calls it.

### 2.11 Settings and app-level

- [x] **Settings screen with search**
  - Sections: Audio quality, Downloads, Playback, Appearance, Performance, Local music, Storage, Your data, Miscellaneous, Language, Advanced.
  - Files: `ui/screens/SettingsSheet.kt`, `data/settings/AppSettings.kt`
  - Done: searching "crossfade" finds the setting.
  - Tests: VibraMusicTests/SettingsSearchTests.testSearchingCrossfadeFindsTheSetting, VibraMusicTests/SettingsSearchTests.testABlankQueryShowsEveryGroupInAndroidsOrder, VibraMusicTests/SettingsSearchTests.testAHiddenRowsKeywordFindsTheSwitchThatShowsIt
  - Note: iOS has no Performance or Local music groups, by design (section 3: the system handles ProMotion, and MediaStore scanning is out of scope); `SettingsSearchTests.testAndroidOnlyRowsAreNotListed` pins that.
- [x] **Theme**
  - System, Light or Dark. Reduce animation, reduce blur, full-screen cover art.
  - Files: `ui/theme/Theme.kt`, `ui/screens/SettingsSheet.kt`
  - Done: switching to Light changes every screen.
  - Tests: VibraMusicTests/SettingsThemeTests.testTheThemeRowOffersSystemLightAndDarkAndLightForcesLight, VibraMusicTests/ThemeModeTests.testThemeModesMapOntoTheColorScheme, VibraMusicTests/CanvasBackdropTests.testReducedMotionCuts, VibraMusicTests/ThemeWiringTests.testLightAndDarkAreForcedOnEveryScreenWhateverTheDeviceUses, VibraMusicTests/ThemeWiringTests.testReduceBlurTakesTheBlurOffTheLyricsLikeSwitchingTheLyricsBlurOff
  - Note: Reduce blur is checked on the lyrics panel. The other places that read the setting (the mini player, the sheet and alert backgrounds, the player backdrop) are not each asserted.
- [x] **App icon** (Android 1.8.2)
  - Settings → Advanced → App icon: Default, Monochrome, Liquid Glass Dark, Liquid Glass Clear, Liquid Glass Clear Dark.
  - Files: `AppIcon.kt`, `ui/screens/SettingsSheet.kt`, `AndroidManifest.xml` (activity-aliases)
  - Done: picking a tile changes the home-screen icon after the system's confirmation.
  - Tests: VibraMusicTests/AppIconPickerTests.testEveryChoiceShipsAsAnAlternateIcon, VibraMusicTests/AppIconPickerTests.testEveryChoiceHasItsPreviewTileInLightAndDark, VibraMusicTests/AppIconPickerTests.testTheRowSitsInAdvancedAndAnswersAndroidsKeywords
  - Note: Android's Liquid Glass (light) is the iOS default icon, and its light, dark and clear forms are also the home screen's own Dark, Clear and Tinted styles. The Samsung and Pixel variants differ only in their mask, and iOS draws one shape, so they aren't ported, and the three Neon icons are left out on size (each icon is about 6 MB of pre-rendered images in the IPA). Mac Catalyst has no row (`supportsAlternateIcons` is false). Device-only: the icon change itself and the system alert can't be driven from tests.
- [x] **App language**
  - English plus 15 languages: de, es, fr, he (right-to-left), hi, id, it, ja, pl, pt, ru, th, tr, vi, zh.
  - Files: `res/values-*/strings.xml`, `ui/components/AppLanguageDialog.kt`
  - Done: switching to Hebrew mirrors the layout right to left.
  - Tests: VibraMusicTests/AppLanguageTests.testTheSixteenLanguagesInAndroidsOrderAllShip, VibraMusicTests/AppLanguageTests.testChoosingHebrewMirrorsTheLayoutAndRebuildsTheUI, VibraMusicTests/LocalizationTests.testEveryShippedLanguageHasALocalizationBundle
- [x] **Backup and restore**
  - Export or import settings and listening stats as JSON. Credentials are not included.
  - Files: `data/stats/Backup.kt`
  - Done: a file exported on one iPhone restores stats on another.
  - Tests: VibraMusicTests/SettingsBackupTests.testAFileExportedOnOnePhoneRestoresStatsAndSettingsOnAnother, VibraMusicCoreTests/SettingsBackupTests.testCredentialsAndDeviceLocalKeysAreNeverExported, VibraMusicCoreTests/SettingsBackupTests.testRestoresABackupWrittenByAndroid, ReplayTests/ReplayBackupTests.testRoundTrip
  - Note: The `.fileExporter`/`.fileImporter` UI is not driven; the export and restore logic is.
- [x] **Storage controls**
  - Song cache limit, clear song cache, clear image cache.
  - Files: `ui/screens/SettingsSheet.kt`, `playback/AudioCache.kt`
  - Done: "Clear song cache" frees the space it reports.
  - Tests: VibraMusicTests/SettingsStorageTests.testClearSongCacheFreesTheSpaceItReports, VibraMusicTests/SettingsStorageTests.testClearImageCacheEmptiesTheDiskCache, VibraMusicTests/SongCacheLimitTests.testTheSliderRunsFrom512MBTo10GBIn512MBNotches
- [ ] **Deep links and sharing into the app**
  - Opens `music.youtube.com`, `youtube.com` and `youtu.be` links, shared text, and party invites.
  - Files: `playback/MusicLink.kt`, `data/listentogether/JamInviteLink.kt`, `MainActivity.kt`
  - Done: tapping a YouTube Music album link in Messages opens that album in the app.
  - Tests (what exists): VibraMusicTests/DeepLinkRoutingTests.testAYouTubeMusicAlbumLinkOpensThatAlbum, VibraMusicTests/DeepLinkRoutingTests.testAPartyInviteOpensListenTogetherWithTheCodeWaiting, VibraMusicTests/DeepLinkShareTests.testSharedTextWithALinkInItOpensTheSong, InnerTubeTests/MusicLinkTests.testWatchLinksOnEveryYouTubeHostPlayTheVideo
  - Gap: Universal Links are not set up: `App/Config/Vibra Music.entitlements` has no associated-domains entry, so `https://vibramusic.kushagrasingh.in/...` party invites can't open the app (Q13: needs the `apple-app-site-association` file hosted). Only the `vibramusic://` scheme and the share extension work. Tapping a YouTube Music link in Messages can't open the app on iOS (section 4), so the share extension is the equivalent; the extension is tested only at the handoff logic level.
- [x] **Haptics**
  - Named haptic patterns that respect the system setting.
  - Files: `ui/haptics/Haptics.kt`
  - Done: liking a song gives a light tap.
  - Tests: VibraMusicTests/HapticPatternTests.testLikingASongIsALightTap, VibraMusicTests/HapticNamedPatternTests.testOppositePatternsMirrorEachOther
  - Note: The like button's call into `Haptics` isn't tested; respecting the system haptics setting is left to the system feedback generators and can't be tested.

### 2.12 System surfaces

- [ ] **Home-screen widgets**
  - Android has 3 sizes (2×2, 4×2, 4×1) with play/pause, previous, next, like and shuffle.
  - Files: `widget/*`, `res/xml/widget_media_*.xml`
  - Done: the small and medium widgets show the current song, and play/pause works.
  - Tests (what exists): VibraMusicTests/HomeScreenWidgetTests.testTheWidgetsButtonsDriveThePlayer, VibraMusicTests/HomeScreenWidgetTests.testEachWidgetIntentReachesTheAppsHandler, VibraMusicTests/HomeScreenWidgetTests.testTheWidgetShowsTheCurrentSongAndTheToggleFollowsPlayWhenReady, VibraMusicTests/WidgetSnapshotTests.testPlayingWritesWhatTheWidgetShows
  - Gap: device-only: the widgets' timelines and the extension-to-app intent hop need a device (or a widget-capable simulator session). The app-side logic and a render smoke test are covered (tests above).
- [ ] **Car integration**
  - Android Auto has a browse tree (Recents, Quick picks, Playlists, Liked, Downloads, Local), search, and Radio and Revert buttons.
  - Files: `playback/PlaybackService.kt`, `res/xml/automotive_app_desc.xml`, `app/src/androidTest/.../AndroidAutoMediaLibraryTest.kt`
  - Done: see open question Q7.
  - Tests (what exists): VibraMusicTests/CarIntegrationTests.testTheRootHasTheAndroidAutoFoldersInOrder, VibraMusicTests/CarIntegrationTests.testSearchListsSongsThenPagesOnceEachAndIsCached, VibraMusicTests/CarIntegrationTests.testNowPlayingCarriesFavoriteShuffleRadioAndRevert, VibraMusicTests/CarIntegrationTests.testTheTemplatesAreBuiltForEveryFolder
  - Gap: device-only: nothing has been run in the CarPlay simulator or a head unit, and `Vibra Music.entitlements` has no `com.apple.developer.carplay-audio` entitlement (Q7: request it from Apple). The browse tree, search and now-playing templates are built and tested.
- [ ] **Voice "play X"**
  - A spoken request plays the best match. A bare "play music" resumes.
  - Files: `playback/MusicLink.kt`
  - Done: "Hey Siri, play Daft Punk in Vibra Music" plays a Daft Punk song.
  - Tests (what exists): VibraMusicTests/VoicePlayTests.testPlayDaftPunkPlaysTheBestMatch, VibraMusicTests/VoicePlayTests.testABarePlayMusicResumesWhatWasPlaying, VibraMusicTests/VoicePlayTests.testSirisMediaSearchBecomesTheQuery, InnerTubeTests/MusicLinkTests.testAVoiceRequestPlaysItsBestMatchAndAnEmptyOneResumes
  - Gap: the free-text path ("play Daft Punk in Vibra Music") goes through `INPlayMediaIntent`, but neither `Vibra Music.entitlements` nor the project has the Siri capability (`com.apple.developer.siri`), so Siri probably won't hand the app a spoken request; add the capability. The real Siri round trip is also device-only. The query parsing, best-match playing and bare "play music" resume are tested.

---

## 3. Out of scope

- **In-app APK updates** (`data/AppUpdateChecker.kt`, `UpdateAvailableDialog.kt`): iOS can't sideload APKs. Updates come from the App Store or TestFlight.
- **USB DAC direct / bit-perfect** (`playback/audio/usb/*`): it's a stub on Android too, and iOS already treats DACs as normal outputs.
- **Bluetooth codec readout** (`playback/audio/bluetooth/*`): iOS doesn't expose the codec, sample rate or bit depth.
- **16-bit vs float output precision and "Prefer USB DAC"** (`AudioOutputPolicy.kt`, `OutputNegotiator.kt`): these are Android output rules. iOS doesn't expose this choice.
- **AAudio evaluation** (`playback/audio/AAudioEvaluation.kt`): design note only, not wired up.
- **Device music scanning via MediaStore** (`data/LocalMediaRepository.kt`): iOS has no open file system. See Platform gaps for the replacement.
- **Export downloads to `Music/Vibra Music`**: iOS has no shared Music folder.
- **High performance mode and refresh-rate setting** (`ui/performance/DisplayRefreshRates.kt`): ProMotion is handled by the system.
- **Samsung Now Bar metadata** and **`APP_MUSIC` / `MUSIC_PLAYER` intents**: Android launcher and OEM hooks.
- **Liquid Glass custom bar, and the Haze blur backdrop** (`ui/components/backdrop/*`, `LiquidGlass.kt`, `GlassNavBar.kt`): rebuild with SwiftUI materials instead of porting the shaders.
- **`AccountChannelDialog.kt`**: nothing calls it (dead code).
- **Dev/prod/benchmark build variants and the `verifyDevInstall` task**: Android build tooling.
- **Playback speed**: the setting exists (`AppSettings.setPlaybackSpeed`) but has no UI, even though the README advertises 0.5×–2×. Don't port unless you decide to add it (Q10).

---

## 4. Platform gaps

| Android piece | Problem on iOS | iOS equivalent |
|---|---|---|
| Media3 ExoPlayer and `MediaLibraryService` | Not available | `AVPlayer` / `AVQueuePlayer`, `MPNowPlayingInfoCenter`, `MPRemoteCommandCenter` |
| Two-player crossfade and custom audio processors (EQ, spatial, transition filter, `PrecisionAudioSink`) | ExoPlayer audio processors don't exist | `AVAudioEngine` with `AVAudioUnitEQ`, custom `AVAudioUnit`s, or `MTAudioProcessingTap` on `AVPlayerItem` |
| Opus/WebM streams from YouTube | `AVPlayer` can't play WebM/Opus in a streaming container | Request the AAC/M4A (itag 140) formats, or decode Opus with a library into `AVAudioEngine` |
| DASH `.mpd` from add-ons | `AVPlayer` has no DASH support | Prefer HLS or progressive from add-ons, or convert DASH to HLS in the app |
| FLAC in a progressive stream | Supported by `AVPlayer` on iOS 11+ | Check high-res FLAC and ALAC on real devices |
| `LoudnessEnhancer` (normalization) | Android-only | Use a gain from track loudness metadata, or `AVAudioUnitEffect` dynamics |
| Skip silence | No built-in on iOS | Silence detection in an audio tap or `AVAudioEngine` |
| Foreground service for playback | No foreground services | "Audio" background mode with `AVAudioSession` `.playback` |
| Foreground service for downloads | Can't run long jobs in the background | Background `URLSession` download tasks |
| WebView login (Google, Discord, Spotify cookie) | Cookie access works differently | `WKWebView` plus `WKHTTPCookieStore`. Google may block embedded sign-in; `ASWebAuthenticationSession` doesn't give cookies |
| PoToken via WebView BotGuard (`po_token.html`) | Needs a hidden WebView running JS | Hidden `WKWebView` with `evaluateJavaScript`; check it runs while the app is in the background |
| NewPipe and Rhino signature solving | Java-only libraries | `JavaScriptCore` running the player JS, or a Swift port of the solver |
| QuickJS module sources | Android library | `JavaScriptCore` (built into iOS) |
| EncryptedSharedPreferences and Keystore | Android-only | Keychain for secrets, `UserDefaults` for settings |
| JNI and C++ analyzer (`native/analyzer`) | JNI glue is Android-only | Keep the C++17, bridge through Swift C++ interop or an Objective-C++ wrapper |
| ONNX models (Beat This!, open-unmix) | `onnxruntime-android` | ONNX Runtime iOS, or convert to Core ML with `coremltools` |
| Automix analysis in the background | iOS limits background CPU | Analyse only while playing (the audio background mode helps), or use a `BGProcessingTask` |
| MediaStore local music | No file system access | `MPMediaQuery` (non-DRM Apple Music library items only) and/or Files import with `UIDocumentPickerViewController` |
| `READ_MEDIA_AUDIO` permission | Different model | `NSAppleMusicUsageDescription` for the media library; no permission needed for Files import |
| SAF pickers (backup, folder choice) | Not available | `.fileExporter` / `.fileImporter` in SwiftUI |
| FileProvider share of the Replay poster | Not available | `ShareLink` or `UIActivityViewController` with an image; `PHPhotoLibrary` to save (needs `NSPhotoLibraryAddUsageDescription`) |
| RemoteViews widgets | Not available | WidgetKit with App Intents buttons (iOS 17 interactive widgets) |
| Android Auto | Not available | CarPlay audio app (needs an Apple CarPlay entitlement) |
| Intent filters for links | Not available | Universal Links (`apple-app-site-association` on `vibramusic.kushagrasingh.in`) and a `vibramusic://` URL scheme |
| YouTube link "Open with" | iOS doesn't let apps claim someone else's domain | Share Extension that accepts URLs and text |
| `MEDIA_PLAY_FROM_SEARCH` voice intent | Not available | App Intents / SiriKit `INPlayMediaIntent` |
| Audio output picker (`setPreferredAudioDevice`) | Apps can't list or pick outputs directly | `AVRoutePickerView` |
| Network type (Wi-Fi vs cellular) | Different API | `NWPathMonitor` (`isExpensive`, `usesInterfaceType(.cellular)`) |
| Haptics | Different API | `UIImpactFeedbackGenerator`, `.sensoryFeedback`, Core Haptics |
| Dolby Atmos check (E-AC-3 decoder) | Different API | `AVAudioSession` spatial and multichannel output checks |
| Per-app language | Handled differently | Localizable String Catalog; iOS Settings holds the per-app language |
| POST_NOTIFICATIONS (download and upload progress) | No ongoing notifications | Progress shown in the app; optional local notification when done; Live Activity if wanted |
| Discord gateway WebSocket, kept open in the background | iOS suspends sockets | Update the presence only while playing audio in the background; expect drops |
| Listen Together socket in the background | Same | Keep it alive while audio plays; reconnect on resume (the server's 45 s grace period helps) |

---

## 5. Dependencies

| Android library | Used for | iOS replacement |
|---|---|---|
| Jetpack Compose, Material 3, Navigation Compose | UI | SwiftUI, `NavigationStack` |
| Lifecycle, ViewModel | State | `@Observable` (Observation framework) |
| Media3 ExoPlayer, session, HLS, DASH, OkHttp datasource | Playback | AVFoundation, MediaPlayer framework |
| Coil 3 | Image loading and cache | Nuke (`kean/Nuke`) or `AsyncImage` plus `URLCache` |
| AndroidX Palette | Artwork colours | Custom Core Image code, or a Swift package such as `DominantColors` |
| Haze | Blur bars | SwiftUI `Material` / `.ultraThinMaterial` |
| ZXing core | Invite QR code | Core Image `CIQRCodeGenerator` |
| compose-richtext (Markdown) | Release notes in the update dialog | Not needed (the update dialog is out of scope). If ever needed: `AttributedString(markdown:)` |
| Ktor client, OkHttp, content negotiation | HTTP | `URLSession` with async/await |
| kotlinx.serialization | JSON | `Codable` |
| Ktor WebSockets | Discord gateway, party socket | `URLSessionWebSocketTask` |
| InnerTubeX (Metrolist) | YouTube stream client catalogue and ciphers | No Swift version. Port the needed parts, or use `YouTubeKit` (`alexeichhorn/YouTubeKit`) as a starting point |
| NewPipeExtractor, nanojson, jsoup | Signature and `n` solving, parsing | `JavaScriptCore` plus custom code; SwiftSoup if HTML parsing is needed |
| Rhino | JS for NewPipe | `JavaScriptCore` |
| protobuf-javalite | Innertube protobuf fields | `apple/swift-protobuf` |
| QuickJS (quickjs-kt) | Module sources | `JavaScriptCore` |
| AndroidX security-crypto | Encrypted prefs | Keychain (directly, or `kishikawakatsumi/KeychainAccess`) |
| SMBJ and BouncyCastle | SMB shares | `AMSMB2` (`amosavian/AMSMB2`, LGPL) |
| (hand-written) WebDAV client | WebDAV | Keep hand-written on `URLSession`; the logic ports directly |
| ONNX Runtime Android | Automix models | `onnxruntime-objc` (Swift Package) or Core ML |
| Kizzy (vendored in `com/my/kizzy`) | Discord RPC | Port by hand on `URLSessionWebSocketTask` |
| (hand-written) MP4, WebM and FLAC taggers | Tags in downloads | Port the MP4 tagger, or use `AVAssetExportSession` metadata; FLAC/WebM need custom code (see Q9) |
| Go backend (`gorilla/websocket`) | Listen Together server | No change needed |

---

## 6. Risks and open questions

### Risks

- **App Store review.** An unofficial YouTube client that downloads streams breaks YouTube's terms of service and App Store guideline 5.2.3. Rejection is likely.
- **Unofficial APIs break often.** Innertube, PoToken, signature ciphers, Spotify, Apple amp-api, Tidal, JioSaavn and the scraped lyrics sites can change without notice. The Android app leans on libraries (InnerTubeX, NewPipe) that have no Swift versions.
- **The Discord user-token login breaks Discord's terms of service.** The account can be banned.
- **Opus streams.** `AVPlayer` can't play YouTube's Opus/WebM, so quality on iOS may top out at AAC around 128 kbps unless you add a decoder.
- **Google sign-in inside a `WKWebView`** may be blocked as an "insecure browser".
- **Licences.** The app is GPLv3 and the analyzer C++ is AGPLv3. GPL and App Store terms are widely seen as conflicting.
- **Background limits.** Automix analysis, the party socket and the Discord socket all need to keep running in the background, which iOS restricts.
- **Size.** `MainActivity.kt` and `PlaybackService.kt` are several thousand lines each, so estimates are uncertain.

### Open questions and recommendations

These were the questions and recommendations recorded before the port. Code comments cite them by number as Q1 to Q15. Several were later decided differently, as the checklist notes in section 2 say: Discord presence (Q3), legacy module sources (Q4), Automix (Q6) and downloads with embedded tags (Q9) were all ported.

Each question has a recommendation and a short reason. Several depend on Q1, so decide that first.

1. **Distribution: App Store, TestFlight only, or sideload / AltStore?**
   - Recommendation: don't target the App Store. Use TestFlight internal testing for development (up to 100 internal testers, no review). Distribute through sideloading (AltStore, or AltStore PAL in the EU).
   - Why: an unofficial YouTube client with downloads will very likely be rejected under guideline 5.2.3. Sideloading also avoids the GPL conflict (Q11).

2. **Stream extraction: Swift port, JavaScriptCore, or a server-side resolver?**
   - Recommendation: write the Innertube client in Swift. Use the `IOS` player client first (already modelled in `data/innertube/PlayerClient.kt`). Fall back to running the player JS in `JavaScriptCore` for signature and `n` solving. No server.
   - Why: iOS client formats are usually AAC/HLS that `AVPlayer` plays natively and often need no cipher. A server adds cost, rate limits and a single point of failure. Look at `YouTubeKit` before writing the JS fallback from scratch.

3. **Discord Rich Presence: port it?**
   - Recommendation: not in v1. Look again after launch.
   - Why: the user-token login risks Discord bans, and iOS suspends the gateway socket in the background, so presence would be unreliable.

4. **Legacy JS module sources: port them?**
   - Recommendation: drop them and support HTTP add-ons only.
   - Why: the Android app already blocks new modules and keeps them only for old configs. Add-ons run no code on the device.

5. **AAC vs an Opus decoder?**
   - Recommendation: AAC in v1 (itag 140 or the `IOS` client's HLS). Use add-ons for lossless. Add Opus only if users ask.
   - Why: AAC plays in `AVPlayer` with lock screen and AirPlay for free. Opus needs an `AVAudioEngine` player plus a decoder library, which is a large chunk of work.

6. **Automix and the ONNX models: v1 or later? ONNX Runtime or Core ML?**
   - Recommendation: v2. Ship plain crossfade in v1. When Automix comes, start with ONNX Runtime (`onnxruntime-objc`) and reuse the existing `.onnx` files; move to Core ML later if speed or battery needs it.
   - Why: it depends on the C++ analyzer bridge, both models and a custom audio engine. ONNX Runtime means no model conversion. Converting the int8 models to Core ML may need the original float weights.

7. **CarPlay in v1?**
   - Recommendation: request the CarPlay audio entitlement now. Build it in v1.1, once playback and library (2.1–2.5) are stable.
   - Why: approval takes time. The CarPlay browse tree can mirror the Android Auto one in `PlaybackService.kt`. Note that the entitlement may be harder to get for a sideloaded app.

8. **Local music on iOS?**
   - Recommendation: v1 has Files import only, feeding the same library screen as downloads. Skip `MPMediaQuery`.
   - Why: Apple Music library items are often DRM-protected and can't be played through `AVPlayer`. Files import covers people with their own FLAC/MP3 files. SMB and WebDAV cover NAS users later.

9. **Downloads: embedded tags or in-app storage?**
   - Recommendation: store audio in the app container and keep metadata, artwork and lyrics in SwiftData. No custom taggers in v1.
   - Why: iOS has no shared Music folder to export to, so embedded tags help nobody in v1. Add MP4 tagging later only if you add "export to Files".

10. **Playback speed: add the UI or drop it?**
    - Recommendation: add it, as a small menu in Now Playing (0.5×–2×).
    - Why: the README already promises it, and on iOS it's cheap (`AVPlayer.rate`, or `AVAudioUnitTimePitch` if you move to `AVAudioEngine`).

11. **Licence: keep GPLv3 or relicense?**
    - Recommendation: keep GPLv3 and publish the iOS source.
    - Why: relicensing needs every contributor's consent, and the analyzer C++ is AGPLv3 code ported from another project. With sideloading (Q1) the App Store conflict doesn't apply.

12. **What goes in v1?**
    - Recommendation:
      - v1: 2.1–2.6, plus sleep timer, crossfade, playback speed, deep links, theme and language.
      - v1.1: Listen Together, scrobbling, widgets, CarPlay, add-on sources.
      - v2: Automix, EQ and spatial, Replay, Canvas, SMB and WebDAV.
    - Why: v1 then needs only `AVPlayer`, not a custom audio engine. EQ, spatial and Automix all need `AVAudioEngine`, so they can move together.

13. **Can you host `apple-app-site-association` on `vibramusic.kushagrasingh.in`?**
    - Recommendation: ask the maintainer who owns the domain to host it. Also support `vibramusic://party/...` as a fallback.
    - Why: it's one static JSON file. The custom scheme works even without it, and already exists for custom servers (`JamInviteLink.kt`).

14. **Last.fm keys for iOS?**
    - Recommendation: register a separate Last.fm API app for iOS. Load the key from an `.xcconfig` that is gitignored, the same way `local.properties` works on Android.
    - Current state: the app reads `LASTFM_API_KEY` and `LASTFM_API_SECRET` build settings into its `Info.plist`, but no `.xcconfig` is attached to the project yet. The README explains how to pass them.
    - Why: separate keys can be revoked or rate-limited without affecting Android users.

15. **Canvas sources: all four or only no-login ones?**
    - Recommendation: when Canvas comes (v2), ship Apple Music and the community index only. Leave out Spotify.
    - Why: the Spotify source needs users to paste their `sp_dc` cookie, and a hidden WebView to harvest a token. That is the most fragile and most privacy-sensitive path.
