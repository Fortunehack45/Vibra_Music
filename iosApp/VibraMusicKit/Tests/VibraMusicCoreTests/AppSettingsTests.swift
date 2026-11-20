import XCTest
import VibraMusicTestSupport
@testable import VibraMusicCore

@MainActor
final class AppSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var credentials: InMemoryCredentialStore!

    override func setUp() async throws {
        defaults = makeEphemeralDefaults()
        credentials = InMemoryCredentialStore()
    }

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: defaults, credentials: credentials)
    }

    // MARK: Defaults

    func testAFreshInstallHasAndroidsDefaults() {
        let s = makeSettings()
        XCTAssertEqual(s.audioQualityWifi, .lossless)
        XCTAssertEqual(s.audioQualityCellular, .lossless)
        XCTAssertEqual(s.downloadQuality, .lossless)
        XCTAssertTrue(s.wifiOnlyDownloads)
        XCTAssertEqual(s.upgradeLengthSlackSeconds, 3)
        XCTAssertEqual(s.crossfadeSeconds, 0)
        XCTAssertFalse(s.smartFadeEnabled)
        XCTAssertEqual(s.automixPerformanceMode, .balanced)
        XCTAssertFalse(s.skipSilence)
        XCTAssertTrue(s.loudnessNormalization)
        XCTAssertTrue(s.dolbyAtmos)
        XCTAssertFalse(s.spatialAudio)
        XCTAssertEqual(s.playbackSpeed, 1.0)
        XCTAssertTrue(s.autoplay)
        XCTAssertFalse(s.shuffleEnabled)
        XCTAssertEqual(s.repeatMode, .off)
        XCTAssertFalse(s.swipeToPlayNext)
        XCTAssertFalse(s.dontRepeatSuggestions)
        XCTAssertFalse(s.preferMusicOnly)
        XCTAssertTrue(s.smartVersionAlignment)
        XCTAssertEqual(s.audioCacheLimitBytes, 512 * 1_024 * 1_024)
        XCTAssertFalse(s.equalizerEnabled)
        XCTAssertEqual(s.equalizerMode, .dynamic)
        XCTAssertEqual(s.equalizerToneX, 0)
        XCTAssertEqual(s.equalizerToneY, 0)
        XCTAssertFalse(s.equalizerFocused)
        XCTAssertEqual(s.equalizerBalance, 0)
        XCTAssertEqual(s.equalizerBands, Array(repeating: 0, count: 7))
        XCTAssertEqual(s.themeMode, .dark)
        XCTAssertFalse(s.showNerdStats)
        XCTAssertTrue(s.keepDiagnosticLog, "the log is on until the owner turns it off")
        XCTAssertFalse(s.reduceAnimation)
        XCTAssertFalse(s.reduceDynamicBlur)
        XCTAssertFalse(s.hideVolumeBar)
        XCTAssertFalse(s.showQueueHistory)
        XCTAssertFalse(s.hideSongStatus)
        XCTAssertTrue(s.fullBleedArtwork)
        XCTAssertFalse(s.legacyMeshGradient)
        XCTAssertEqual(s.lastPlayerScreen, .main)
        XCTAssertTrue(s.animatedCanvas)
        XCTAssertFalse(s.canvasOverCellular)
        XCTAssertTrue(s.spotifyCanvasAutoHide)
        XCTAssertFalse(s.prioritizeSpotifyCanvas)
        XCTAssertEqual(s.directSourceStream, .off)
        XCTAssertTrue(s.syncedLyrics)
        XCTAssertTrue(s.lyricsBlur)
        XCTAssertEqual(s.lyricsOffsetMs, 0)
        XCTAssertEqual(s.translationLanguage, "")
        XCTAssertEqual(s.lyricsSources, Set(LyricsSource.allCases))
        XCTAssertEqual(s.lyricsSourceOrder, LyricsSource.allCases)
        XCTAssertFalse(s.prioritizeSyllableSync)
        XCTAssertEqual(s.paxSenixApiKey, "")
        XCTAssertTrue(s.replayGenres)
        XCTAssertEqual(s.localMusicSort, .titleAsc)
        XCTAssertEqual(s.downloadedMusicSort, .titleAsc)
        XCTAssertEqual(s.localMusicViewType, .list)
        XCTAssertEqual(s.downloadedMusicViewType, .list)
        XCTAssertEqual(s.homeRecentsViewType, .list)
        XCTAssertEqual(s.librarySort, .default)
        XCTAssertTrue(s.detailSongSorts.isEmpty)
        XCTAssertTrue(s.pinnedPlaylists.isEmpty)
        XCTAssertFalse(s.isWebDAVConfigured)
        XCTAssertFalse(s.isSMBConfigured)
        XCTAssertFalse(s.lastfmEnabled)
        XCTAssertFalse(s.lastfmScrobbleEnabled)
        XCTAssertFalse(s.lastfmNowPlaying)
        XCTAssertEqual(s.scrobbleMinDuration, 30)
        XCTAssertEqual(s.scrobbleDelayPercent, 0.5)
        XCTAssertEqual(s.scrobbleDelaySeconds, 180)
        XCTAssertFalse(s.listenBrainzEnabled)
        XCTAssertEqual(s.discordToken, "")
        XCTAssertTrue(s.discordRpcEnabled)
        XCTAssertFalse(s.discordUseDetails)
        XCTAssertTrue(s.discordShowAudioQuality)
        XCTAssertEqual(s.discordStatus, "online")
        XCTAssertEqual(s.discordActivityType, "listening")
        XCTAssertTrue(s.discordButton1Visible)
        XCTAssertTrue(s.discordButton2Visible)
        XCTAssertFalse(s.discordInfoDismissed)
    }

    func testAFreshInstallRecordsTheDownloadQualityItWasAlreadyUsing() {
        _ = makeSettings()
        XCTAssertEqual(defaults.string(forKey: "audio_quality_download"), "LOSSLESS")
    }

    func testAnExistingDownloadQualityChoiceIsKeptThroughTheMigration() {
        defaults.set("STANDARD", forKey: "audio_quality_download")
        let s = makeSettings()
        XCTAssertEqual(s.downloadQuality, .standard)
        XCTAssertEqual(defaults.string(forKey: "audio_quality_download"), "STANDARD")
    }

    // MARK: Persistence

    func testEverySettingSurvivesARelaunch() {
        let s = makeSettings()
        s.audioQualityWifi = .high
        s.audioQualityCellular = .low
        s.upgradeLengthSlackSeconds = 7
        s.downloadQuality = .standard
        s.wifiOnlyDownloads = false
        s.crossfadeSeconds = 6
        s.smartFadeEnabled = true
        s.automixPerformanceMode = .performance
        s.skipSilence = true
        s.loudnessNormalization = false
        s.dolbyAtmos = false
        s.spatialAudio = true
        s.playbackSpeed = 1.5
        s.autoplay = false
        s.shuffleEnabled = true
        s.repeatMode = .all
        s.swipeToPlayNext = true
        s.dontRepeatSuggestions = true
        s.preferMusicOnly = true
        s.smartVersionAlignment = false
        s.audioCacheLimitBytes = 2 * 1_024 * 1_024 * 1_024
        s.equalizerEnabled = true
        s.equalizerMode = .manual
        s.equalizerToneX = 3
        s.equalizerToneY = -2
        s.equalizerFocused = true
        s.equalizerBalance = -0.5
        s.equalizerBands = [6, 4, 1.5, 0, 0, 0, 0]
        s.themeMode = .light
        s.showNerdStats = true
        s.reduceAnimation = true
        s.reduceDynamicBlur = true
        s.hideVolumeBar = true
        s.showQueueHistory = true
        s.hideSongStatus = true
        s.fullBleedArtwork = false
        s.legacyMeshGradient = true
        s.lastPlayerScreen = .lyrics
        s.animatedCanvas = false
        s.canvasOverCellular = true
        s.spotifyCanvasAutoHide = false
        s.prioritizeSpotifyCanvas = true
        s.directSourceStream = .queueOnly
        s.syncedLyrics = false
        s.lyricsBlur = false
        s.lyricsOffsetMs = 500
        s.translationLanguage = "es"
        s.lyricsSources = [.lrcLib, .genius]
        s.lyricsSourceOrder = [.genius] + LyricsSource.allCases.filter { $0 != .genius }
        s.prioritizeSyllableSync = true
        s.setPaxSenixApiKey("key")
        s.replayGenres = false
        s.localMusicSort = .dateAdded
        s.downloadedMusicSort = .titleDesc
        s.localMusicViewType = .grid
        s.downloadedMusicViewType = .grid
        s.homeRecentsViewType = .grid
        s.librarySort = .titleAsc
        s.setDetailSongSort(.dateAddedDesc, for: "VLPL1")
        s.togglePinnedPlaylist("VLPL1")
        s.configureWebDAV(url: "https://dav.example.com/music", username: "me", password: "pw")
        s.configureSMB(host: "nas.local", share: "music", basePath: "flac", username: "me", password: "pw2")
        s.lastfmEnabled = true
        s.lastfmUsername = "user"
        s.lastfmSessionKey = "session"
        s.lastfmApiKey = "api"
        s.lastfmSecret = "secret"
        s.lastfmEndpoint = "https://libre.fm/2.0/"
        s.lastfmScrobbleEnabled = true
        s.lastfmNowPlaying = true
        s.lastfmPrimaryArtistOnly = true
        s.scrobbleMinDuration = 45
        s.scrobbleDelayPercent = 0.75
        s.scrobbleDelaySeconds = 240
        s.listenBrainzEnabled = true
        s.listenBrainzToken = "lb"
        s.listenBrainzPrimaryArtistOnly = true
        s.spotifySpdcToken = "spdc"
        s.discordToken = "discord"
        s.setDiscordAccount(username: "u", name: "N", avatar: "a")
        s.discordRpcEnabled = false
        s.discordUseDetails = true
        s.discordShowAudioQuality = false
        s.discordAdvancedMode = true
        s.discordStatus = "idle"
        s.discordActivityType = "playing"
        s.discordActivityName = "Music"
        s.discordButton1Text = "Listen"
        s.discordButton1Visible = false
        s.discordButton2Text = "App"
        s.discordButton2Visible = false
        s.discordInfoDismissed = true

        let r = makeSettings()
        XCTAssertEqual(r.audioQualityWifi, .high)
        XCTAssertEqual(r.audioQualityCellular, .low)
        XCTAssertEqual(r.upgradeLengthSlackSeconds, 7)
        XCTAssertEqual(r.downloadQuality, .standard)
        XCTAssertFalse(r.wifiOnlyDownloads)
        XCTAssertEqual(r.crossfadeSeconds, 6)
        XCTAssertTrue(r.smartFadeEnabled)
        XCTAssertEqual(r.automixPerformanceMode, .performance)
        XCTAssertTrue(r.skipSilence)
        XCTAssertFalse(r.loudnessNormalization)
        XCTAssertFalse(r.dolbyAtmos)
        XCTAssertTrue(r.spatialAudio)
        XCTAssertEqual(r.playbackSpeed, 1.5)
        XCTAssertFalse(r.autoplay)
        XCTAssertTrue(r.shuffleEnabled)
        XCTAssertEqual(r.repeatMode, .all)
        XCTAssertTrue(r.swipeToPlayNext)
        XCTAssertTrue(r.dontRepeatSuggestions)
        XCTAssertTrue(r.preferMusicOnly)
        XCTAssertFalse(r.smartVersionAlignment)
        XCTAssertEqual(r.audioCacheLimitBytes, 2 * 1_024 * 1_024 * 1_024)
        XCTAssertTrue(r.equalizerEnabled)
        XCTAssertEqual(r.equalizerMode, .manual)
        XCTAssertEqual(r.equalizerToneX, 3)
        XCTAssertEqual(r.equalizerToneY, -2)
        XCTAssertTrue(r.equalizerFocused)
        XCTAssertEqual(r.equalizerBalance, -0.5)
        XCTAssertEqual(r.equalizerBands, [6, 4, 1.5, 0, 0, 0, 0])
        XCTAssertEqual(r.themeMode, .light)
        XCTAssertTrue(r.showNerdStats)
        XCTAssertTrue(r.reduceAnimation)
        XCTAssertTrue(r.reduceDynamicBlur)
        XCTAssertTrue(r.hideVolumeBar)
        XCTAssertTrue(r.showQueueHistory)
        XCTAssertTrue(r.hideSongStatus)
        XCTAssertFalse(r.fullBleedArtwork)
        XCTAssertTrue(r.legacyMeshGradient)
        XCTAssertEqual(r.lastPlayerScreen, .lyrics)
        XCTAssertFalse(r.animatedCanvas)
        XCTAssertTrue(r.canvasOverCellular)
        XCTAssertFalse(r.spotifyCanvasAutoHide)
        XCTAssertTrue(r.prioritizeSpotifyCanvas)
        XCTAssertEqual(r.directSourceStream, .queueOnly)
        XCTAssertFalse(r.syncedLyrics)
        XCTAssertFalse(r.lyricsBlur)
        XCTAssertEqual(r.lyricsOffsetMs, 500)
        XCTAssertEqual(r.translationLanguage, "es")
        XCTAssertEqual(r.lyricsSources, [.lrcLib, .genius])
        XCTAssertEqual(r.lyricsSourceOrder.first, .genius)
        XCTAssertEqual(r.lyricsSourceOrder.count, LyricsSource.allCases.count)
        XCTAssertTrue(r.prioritizeSyllableSync)
        XCTAssertEqual(r.paxSenixApiKey, "key")
        XCTAssertFalse(r.replayGenres)
        XCTAssertEqual(r.localMusicSort, .dateAdded)
        XCTAssertEqual(r.downloadedMusicSort, .titleDesc)
        XCTAssertEqual(r.localMusicViewType, .grid)
        XCTAssertEqual(r.downloadedMusicViewType, .grid)
        XCTAssertEqual(r.homeRecentsViewType, .grid)
        XCTAssertEqual(r.librarySort, .titleAsc)
        XCTAssertEqual(r.detailSongSort(for: "VLPL1"), .dateAddedDesc)
        XCTAssertEqual(r.detailSongSort(for: "never-touched"), .default)
        XCTAssertEqual(r.pinnedPlaylists, ["VLPL1"])
        XCTAssertEqual(r.webdavUrl, "https://dav.example.com/music")
        XCTAssertEqual(r.webdavUsername, "me")
        XCTAssertEqual(r.webdavPassword, "pw")
        XCTAssertEqual(r.smbHost, "nas.local")
        XCTAssertEqual(r.smbShare, "music")
        XCTAssertEqual(r.smbBasePath, "flac")
        XCTAssertEqual(r.smbUsername, "me")
        XCTAssertEqual(r.smbPassword, "pw2")
        XCTAssertTrue(r.lastfmEnabled)
        XCTAssertEqual(r.lastfmUsername, "user")
        XCTAssertEqual(r.lastfmSessionKey, "session")
        XCTAssertEqual(r.lastfmApiKey, "api")
        XCTAssertEqual(r.lastfmSecret, "secret")
        XCTAssertEqual(r.lastfmEndpoint, "https://libre.fm/2.0/")
        XCTAssertTrue(r.lastfmScrobbleEnabled)
        XCTAssertTrue(r.lastfmNowPlaying)
        XCTAssertTrue(r.lastfmPrimaryArtistOnly)
        XCTAssertEqual(r.scrobbleMinDuration, 45)
        XCTAssertEqual(r.scrobbleDelayPercent, 0.75)
        XCTAssertEqual(r.scrobbleDelaySeconds, 240)
        XCTAssertTrue(r.listenBrainzEnabled)
        XCTAssertEqual(r.listenBrainzToken, "lb")
        XCTAssertTrue(r.listenBrainzPrimaryArtistOnly)
        XCTAssertEqual(r.spotifySpdcToken, "spdc")
        XCTAssertEqual(r.discordToken, "discord")
        XCTAssertEqual(r.discordUsername, "u")
        XCTAssertEqual(r.discordName, "N")
        XCTAssertEqual(r.discordAvatar, "a")
        XCTAssertFalse(r.discordRpcEnabled)
        XCTAssertTrue(r.discordUseDetails)
        XCTAssertFalse(r.discordShowAudioQuality)
        XCTAssertTrue(r.discordAdvancedMode)
        XCTAssertEqual(r.discordStatus, "idle")
        XCTAssertEqual(r.discordActivityType, "playing")
        XCTAssertEqual(r.discordActivityName, "Music")
        XCTAssertEqual(r.discordButton1Text, "Listen")
        XCTAssertFalse(r.discordButton1Visible)
        XCTAssertEqual(r.discordButton2Text, "App")
        XCTAssertFalse(r.discordButton2Visible)
        XCTAssertTrue(r.discordInfoDismissed)
    }

    func testValuesAreStoredUnderAndroidsKeysAndTypes() {
        let s = makeSettings()
        s.audioQualityCellular = .medium
        s.repeatMode = .one
        s.equalizerBands = [1, 2, 3, 4, 5, 6, 7]
        s.lyricsSourceOrder = LyricsSource.allCases
        XCTAssertEqual(defaults.string(forKey: "audio_quality_cellular"), "MEDIUM")
        XCTAssertEqual(defaults.integer(forKey: "repeat_mode"), 1)
        XCTAssertEqual(defaults.string(forKey: "equalizer_bands"), "1.0,2.0,3.0,4.0,5.0,6.0,7.0")
        XCTAssertEqual(defaults.string(forKey: "lyrics_source_order")?.hasPrefix("BINI_LYRICS,BETTER_LYRICS,"), true)
    }

    func testCredentialsGoToTheCredentialStoreNotUserDefaults() {
        let s = makeSettings()
        s.lastfmSessionKey = "secret-session"
        s.lastfmApiKey = "secret-api-key"
        s.lastfmSecret = "secret-lastfm-secret"
        s.listenBrainzToken = "secret-token"
        s.spotifySpdcToken = "secret-spdc"
        s.setPaxSenixApiKey("secret-paxsenix")
        s.discordToken = "secret-discord"
        s.configureWebDAV(url: "https://x", username: "u", password: "secret-webdav")
        s.configureSMB(host: "nas", share: "music", basePath: "", username: "u", password: "secret-smb")
        let expected = [
            "lastfm_session_key": "secret-session",
            "lastfm_api_key": "secret-api-key",
            "lastfm_secret": "secret-lastfm-secret",
            "listenbrainz_token": "secret-token",
            "spotify_spdc_token": "secret-spdc",
            "paxsenix_api_key": "secret-paxsenix",
            "discord_token": "secret-discord",
            "webdav_password": "secret-webdav",
            "smb_password": "secret-smb",
        ]
        XCTAssertEqual(expected.count, AppSettings.CredentialKey.allCases.count, "every credential key is covered")
        for (key, value) in expected {
            XCTAssertEqual(try credentials.string(forKey: key), value, key)
        }
        let stored = defaults.dictionaryRepresentation()
        for secret in expected.values {
            XCTAssertFalse(stored.values.contains { ($0 as? String) == secret }, "\(secret) leaked into UserDefaults")
        }
        s.discordToken = ""
        XCTAssertNil(try credentials.string(forKey: "discord_token"), "an empty value forgets the credential")
    }

    func testBundledLastfmKeysApplyUntilTheUserSetsTheirOwn() {
        let bundled = AppSettings(defaults: defaults, credentials: credentials, bundledLastfmAPIKey: "build-key", bundledLastfmSecret: "build-secret")
        XCTAssertEqual(bundled.lastfmApiKey, "build-key")
        XCTAssertEqual(bundled.lastfmSecret, "build-secret")
        bundled.lastfmApiKey = "mine"
        XCTAssertEqual(AppSettings(defaults: defaults, credentials: credentials, bundledLastfmAPIKey: "build-key").lastfmApiKey, "mine")
    }

    // MARK: Normalisation

    func testRangesAreClamped() {
        let s = makeSettings()
        s.lyricsOffsetMs = 9_000
        XCTAssertEqual(s.lyricsOffsetMs, 5_000)
        s.lyricsOffsetMs = -9_000
        XCTAssertEqual(s.lyricsOffsetMs, -5_000)
        s.upgradeLengthSlackSeconds = 99
        XCTAssertEqual(s.upgradeLengthSlackSeconds, 10)
        s.crossfadeSeconds = 30
        XCTAssertEqual(s.crossfadeSeconds, 12)
        s.playbackSpeed = 3
        XCTAssertEqual(s.playbackSpeed, 2)
        s.equalizerToneX = 9
        s.equalizerToneY = -9
        XCTAssertEqual([s.equalizerToneX, s.equalizerToneY], [5, -5])
        s.equalizerBalance = 4
        XCTAssertEqual(s.equalizerBalance, 1)
        s.audioCacheLimitBytes = 1
        XCTAssertEqual(s.audioCacheLimitBytes, AppSettings.defaultAudioCacheLimitBytes, "the floor is the default, not zero")
        s.audioCacheLimitBytes = .max
        XCTAssertEqual(s.audioCacheLimitBytes, AppSettings.maxAudioCacheLimitBytes)
        XCTAssertEqual(makeSettings().lyricsOffsetMs, -5_000, "the clamped value is what persisted")
    }

    func testEqualizerBandsAreAlwaysSevenClampedGains() {
        let s = makeSettings()
        s.equalizerBands = [20, -20, 3]
        XCTAssertEqual(s.equalizerBands, [12, -12, 3, 0, 0, 0, 0])
        s.equalizerBands = Array(repeating: 1, count: 10)
        XCTAssertEqual(s.equalizerBands, Array(repeating: 1, count: 7))
    }

    func testAStoredBandListOfTheWrongLengthIsPaddedNotRejected() {
        defaults.set("1.5,2.5", forKey: "equalizer_bands")
        XCTAssertEqual(makeSettings().equalizerBands, [1.5, 2.5, 0, 0, 0, 0, 0])
    }

    func testNowPlayingNeedsScrobblingOn() {
        let s = makeSettings()
        s.lastfmNowPlaying = true
        XCTAssertFalse(s.lastfmNowPlaying, "refused while scrobbling is off")
        s.lastfmScrobbleEnabled = true
        s.lastfmNowPlaying = true
        XCTAssertTrue(s.lastfmNowPlaying)
        s.lastfmScrobbleEnabled = false
        XCTAssertFalse(s.lastfmNowPlaying, "turning scrobbling off turns now-playing off")
        XCTAssertFalse(makeSettings().lastfmNowPlaying)
    }

    func testNetworkLibraryFieldsAreNormalised() {
        let s = makeSettings()
        s.configureWebDAV(url: "  https://dav.example.com/music///  ", username: " me ", password: " secret ")
        XCTAssertEqual(s.webdavUrl, "https://dav.example.com/music")
        XCTAssertEqual(s.webdavUsername, "me")
        XCTAssertEqual(s.webdavPassword, " secret ", "passwords are kept as typed")
        XCTAssertTrue(s.isWebDAVConfigured)
        s.configureSMB(host: " nas.local ", share: " /music/ ", basePath: "/a/b/", username: " me ", password: "pw")
        XCTAssertEqual([s.smbHost, s.smbShare, s.smbBasePath, s.smbUsername], ["nas.local", "music", "a/b", "me"])
        XCTAssertTrue(s.isSMBConfigured)
        s.clearWebDAV()
        s.clearSMB()
        XCTAssertFalse(s.isWebDAVConfigured)
        XCTAssertFalse(s.isSMBConfigured)
        XCTAssertEqual(s.smbPassword, "")
    }

    func testPaxSenixKeyDropsAPastedBearerPrefix() {
        let s = makeSettings()
        s.setPaxSenixApiKey("  Bearer abc123 ")
        XCTAssertEqual(s.paxSenixApiKey, "abc123")
        s.setPaxSenixApiKey("bearer  xyz")
        XCTAssertEqual(s.paxSenixApiKey, "xyz")
        s.setPaxSenixApiKey("plain")
        XCTAssertEqual(s.paxSenixApiKey, "plain")
    }

    func testClearingDiscordForgetsTokenAndProfile() {
        let s = makeSettings()
        s.discordToken = "t"
        s.setDiscordAccount(username: "u", name: "n", avatar: nil)
        s.clearDiscordAccount()
        XCTAssertEqual([s.discordToken, s.discordUsername, s.discordName, s.discordAvatar], ["", "", "", ""])
    }

    // MARK: Pins and sorts

    func testPinningIsCappedAtFiveAndRefusesRatherThanEvicts() {
        let s = makeSettings()
        for index in 1...5 { XCTAssertTrue(s.togglePinnedPlaylist("VLPL\(index)")) }
        XCTAssertFalse(s.togglePinnedPlaylist("VLPL6"), "a sixth pin is refused")
        XCTAssertEqual(s.pinnedPlaylists, (1...5).map { "VLPL\($0)" }, "pin order is kept")
        XCTAssertFalse(s.togglePinnedPlaylist("VLPL3"), "toggling a pinned one unpins it")
        XCTAssertEqual(s.pinnedPlaylists, ["VLPL1", "VLPL2", "VLPL4", "VLPL5"])
        XCTAssertEqual(makeSettings().pinnedPlaylists, ["VLPL1", "VLPL2", "VLPL4", "VLPL5"])
    }

    func testDetailSortsReadAndroidsEncoding() {
        defaults.set("MPREb_abc=TITLE_DESC,=TITLE_ASC,VLPL1=NOT_A_SORT,VLPL2=DATE_ADDED_ASC", forKey: "detail_song_sorts")
        XCTAssertEqual(makeSettings().detailSongSorts, ["MPREb_abc": .titleDesc, "VLPL2": .dateAddedAsc])
    }

    // MARK: Lyrics sources

    func testLyricsSourcesDefaultToAllInDeclarationOrder() {
        let s = makeSettings()
        XCTAssertEqual(s.enabledLyricsSourcesInOrder, LyricsSource.allCases)
        s.syncedLyrics = false
        XCTAssertTrue(s.enabledLyricsSourcesInOrder.isEmpty)
    }

    func testASourceAddedByAnUpgradeIsEnabledNotSilentlyOff() {
        // An old build saved a choice from the legacy list and never wrote the "seen" key.
        defaults.set("LRCLIB,GENIUS", forKey: "lyrics_sources")
        let s = makeSettings()
        XCTAssertTrue(s.lyricsSources.contains(.lrcLib))
        XCTAssertFalse(s.lyricsSources.contains(.kuGou), "a legacy source left out was switched off on purpose")
        XCTAssertTrue(s.lyricsSources.contains(.biniLyrics), "a source the user never saw is enabled")
        XCTAssertTrue(s.lyricsSources.contains(.unison))
    }

    func testASourceSwitchedOffAfterSeeingItStaysOff() {
        let s = makeSettings()
        s.lyricsSources = Set(LyricsSource.allCases).subtracting([.biniLyrics])
        XCTAssertFalse(makeSettings().lyricsSources.contains(.biniLyrics))
    }

    func testTheSourceOrderDropsUnknownNamesAndAppendsNewSources() {
        defaults.set("GENIUS,GONE_PROVIDER,LRCLIB", forKey: "lyrics_source_order")
        let order = makeSettings().lyricsSourceOrder
        XCTAssertEqual(Array(order.prefix(2)), [.genius, .lrcLib])
        XCTAssertEqual(order.count, LyricsSource.allCases.count)
        XCTAssertEqual(Array(order.dropFirst(2)), LyricsSource.allCases.filter { $0 != .genius && $0 != .lrcLib })
    }

    func testResettingLyricsSourcesLeavesSyncedLyricsAlone() {
        let s = makeSettings()
        s.syncedLyrics = false
        s.lyricsSources = [.genius]
        s.lyricsSourceOrder = [.genius]
        s.prioritizeSyllableSync = true
        s.resetLyricsSourceSettings()
        XCTAssertEqual(s.lyricsSources, Set(LyricsSource.allCases))
        XCTAssertEqual(s.lyricsSourceOrder, LyricsSource.allCases)
        XCTAssertFalse(s.prioritizeSyllableSync)
        XCTAssertFalse(s.syncedLyrics)
    }

    // MARK: Migrations

    func testASingleLegacyCeilingAppliesToBothConnections() {
        defaults.set("LOW", forKey: "audio_quality")
        let s = makeSettings()
        XCTAssertEqual(s.audioQualityWifi, .low)
        XCTAssertEqual(s.audioQualityCellular, .low)
        XCTAssertNil(defaults.object(forKey: "audio_quality"))
    }

    /// Direct source stream was a switch before Queue only, and still is on Android: on keeps
    /// waiting for the sources (Always), off stays Off, on a relaunch and from a backup made
    /// before the change or on Android.
    func testTheOldDirectSourceSwitchBecomesAlwaysOrOff() {
        defaults.set(true, forKey: "direct_source_stream")
        XCTAssertEqual(makeSettings().directSourceStream, .always)
        XCTAssertEqual(defaults.string(forKey: "direct_source_stream_mode"), "ALWAYS")

        let s = makeSettings()
        s.importPrefs(["direct_source_stream": .bool(false)])
        XCTAssertEqual(s.directSourceStream, .off)
        s.importPrefs(["direct_source_stream": .bool(true)])
        XCTAssertEqual(s.directSourceStream, .always)
    }

    /// Android's switch is kept written, on for Always only, so a backup restores there; the
    /// three-way choice wins over it here.
    func testTheDirectSourceChoiceKeepsAndroidsSwitchInStep() {
        let s = makeSettings()
        s.directSourceStream = .always
        XCTAssertEqual(defaults.object(forKey: "direct_source_stream") as? Bool, true)
        s.directSourceStream = .queueOnly
        XCTAssertEqual(defaults.object(forKey: "direct_source_stream") as? Bool, false)
        XCTAssertEqual(makeSettings().directSourceStream, .queueOnly)
    }

    func testUnknownStoredEnumValuesFallBackToDefaults() {
        defaults.set("ULTRA", forKey: "audio_quality_wifi")
        defaults.set("NEON", forKey: "theme_mode")
        defaults.set(7, forKey: "repeat_mode")
        let s = makeSettings()
        XCTAssertEqual(s.audioQualityWifi, .lossless)
        XCTAssertEqual(s.themeMode, .dark)
        XCTAssertEqual(s.repeatMode, .off)
    }

    func testVersionUpdateIsReportedOncePerUpgrade() {
        let s = makeSettings()
        XCTAssertTrue(s.consumeVersionUpdate(currentVersionCode: 10),
                      "no build on record is an update: 0.9.0 never recorded one, and its caches are still there")
        XCTAssertFalse(s.consumeVersionUpdate(currentVersionCode: 10))
        XCTAssertTrue(s.consumeVersionUpdate(currentVersionCode: 11))
        XCTAssertFalse(s.consumeVersionUpdate(currentVersionCode: 11))
        XCTAssertTrue(s.consumeVersionUpdate(currentVersionCode: 9),
                      "a downgrade installed over a newer build didn't write its caches either")
        XCTAssertFalse(s.consumeVersionUpdate(currentVersionCode: 9))
    }

    // MARK: Observation

    func testAssigningASettingNotifiesObservers() {
        let s = makeSettings()
        let changed = expectation(description: "observer notified")
        withObservationTracking {
            _ = s.crossfadeSeconds
        } onChange: {
            changed.fulfill()
        }
        s.crossfadeSeconds = 4
        wait(for: [changed], timeout: 1)
    }
}
