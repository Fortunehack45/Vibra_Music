# Features

The app's screens, one folder per area. A folder holds the area's screens and sheets, the view
models and stores behind them, and the helpers only that area uses. Views shared across areas
live in `Components/`; app-wide services such as `AppModel` and `PlayerController` live in
`Services/`.

| Folder | What it holds | Android counterpart |
|---|---|---|
| Account | Account screen, Google sign-in, profile switcher, Discord, the shared top bar items | AccountAndScrobblingScreen.kt, auth/, DiscordScreen.kt |
| Browse | Home, Explore, mood and genre pages, Search | HomeScreen.kt, ExploreScreen.kt, SearchScreen.kt |
| Collections | Album, playlist and artist pages, Library, History, the song and item menus, the playlist picker | DetailScreen.kt, LibraryScreen.kt, HistoryScreen.kt, SongActionsSheet.kt |
| Downloads | Downloads and Local music, the download manager, SMB and WebDAV libraries, offline backup | LocalMusicScreen.kt, DownloadManagerSheet.kt |
| Lyrics | The lyrics panel and its sheets (sources, provider, offset, translation), lyrics sharing | ui/player/PlayerLyrics.kt and its dialogs |
| NowPlaying | The full player, its dock, the queue panel, the audio output and pipeline sheets | ui/player/ |
| Settings | Settings, equalizer, sources, app icon and language pickers | SettingsSheet.kt, EqualizerScreen.kt, SourcesScreen.kt |
| Social | Listen Together and Replay | ListenTogether*.kt, ui/replay/ |

Android paths are relative to `app/src/main/java/com/music/vibramusic/` in the upstream Android
app. Most Swift files name the Kotlin file they port in their first comment.

## How a screen is reached

`Navigation/RootTabView.swift` maps every destination to its view:

- `TabStack` holds each tab's root screen and its navigation stack.
- `RouteDestination` maps an `AppRoute` to the screen pushed onto a stack.
- `SheetDestination` maps an `AppSheet` to the sheet it presents.

To add a screen, add a case to `AppRoute` or `AppSheet` and map it there. Open it with
`AppRouter.open(_:)` or `AppRouter.present(_:)`.

Views read shared state from the environment: `AppModel`, `AppRouter`, `PlayerController`,
`AppSettings`, `LikeState` and `SearchHistory` (set up in `App/RootView.swift`).

## Other files

- `*DebugLaunch.swift`, `*DemoService.swift` and `LyricsDemo.swift`: debug-build launch arguments
  and sample data that open a screen in a known state, for screenshots, UI tests and manual checks.
- `*.xcstrings` inside a folder: strings used only by that area.

Tests for an area go in `App/VibraMusicTests/<Folder>`.
