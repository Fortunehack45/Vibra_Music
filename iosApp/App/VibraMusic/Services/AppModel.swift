import AudioCache
import AudioDSP
import Automix
import AVFoundation
import VibraMusicCore
import Canvas
import Downloads
import Foundation
import InnerTube
import Integrations
import ListenTogether
import Lyrics
import MediaPlayer
import NetworkLibrary
import Observation
import Playback
import PlaybackPolicy
import PlaybackQueue
import Replay
import SwiftUI
import Sources
import StreamResolution
import Theming
import WebKit

// Ports VibraMusicApplication.kt (process-wide setup) and the service graph MainActivity.kt and
// PlaybackService.kt reached through singletons: one container, created at launch and handed to
// every view through the environment.

/// How the app was launched, for the parts of startup a test run changes.
struct AppLaunchOptions: Hashable {
    /// Restore last session's queue (paused) at launch.
    var restoresQueue = true
    /// Publish Now Playing, take remote commands and own the audio session.
    var integratesWithSystem = true
    /// A UI test run: start from an empty queue so what the test plays is what it sees.
    var isUITest = false

    static let standard = AppLaunchOptions()

    /// Read from the process: `-uitesting` is passed by the XCUITests.
    static var current: AppLaunchOptions {
        var options = AppLaunchOptions()
        if ProcessInfo.processInfo.arguments.contains("-uitesting") {
            options.isUITest = true
            options.restoresQueue = false
        }
        return options
    }
}

/// Everything the app is made of, built once.
///
/// Construction is cheap: the network-facing pieces are lazy, and nothing here talks to the network
/// until a screen or the player asks. What VibraMusicApplication.kt did eagerly on a background
/// thread (opening the source registry, the stream resolver's disk caches) happens on first use.
@MainActor
@Observable
final class AppModel {
    /// The instance the running app uses, for entry points SwiftUI doesn't reach (App Intents,
    /// CarPlay, the widget's audio intents). Nil in unit tests that build their own.
    private(set) static var current: AppModel?

    // MARK: Core state

    let settings: AppSettings
    let likeState: LikeState
    let searchHistory: SearchHistory
    let router: AppRouter
    let player: PlayerController
    let accounts: YouTubeAccountManager
    let sourceRegistry: SourceRegistry
    /// Whether the app is on screen (ui/ForegroundState.kt): work that only feeds the screen
    /// (position polling, canvas video) stops while it isn't.
    private(set) var isInForeground = true
    /// Bumped after the in-app language changes (LanguageBundle.override), so the whole tree is
    /// rebuilt with the new strings and layout direction without a relaunch.
    var languageRevision = 0

    // MARK: Services

    /// The connection, as the quality ceilings, the Wi-Fi-only gate and the canvas switch see it
    /// (`NetworkStatusProviding`, so a test can stand in `NetworkMonitor`).
    @ObservationIgnored let network: any NetworkStatusProviding
    @ObservationIgnored let innerTube: InnerTubeClient
    @ObservationIgnored let repository: YTMusicRepository
    @ObservationIgnored let streamResolver: StreamResolver
    /// YouTube's own streams (the StreamResolution walk) as a StreamResolving.
    @ObservationIgnored let youTubeStreams: YouTubeStreamResolving
    /// The app's StreamResolving: add-ons, JioSaavn, modules and YouTube raced (Sources).
    @ObservationIgnored let sourceResolver: SourceResolver
    @ObservationIgnored let audioCache: AudioStreamCache?
    @ObservationIgnored let offlineBackup: OfflineBackup
    @ObservationIgnored let qualityCeiling: PlaybackQualityCeiling
    @ObservationIgnored let engine: AudioPlayerEngine
    @ObservationIgnored let queue: PlaybackQueueController
    @ObservationIgnored let streamFacts: StreamFactsBook
    @ObservationIgnored let dspProcessors: [AudioDSPProcessor]
    @ObservationIgnored let palettes: ArtworkPaletteCache
    @ObservationIgnored let launch: AppLaunchOptions

    /// Lyrics from the sixteen providers, with InnerTube's signed-in client behind the two YouTube ones.
    @ObservationIgnored private(set) lazy var lyrics = LyricsRepository(
        session: VibraMusicHTTP.session,
        innerTube: InnerTubeLyricsClient(client: innerTube),
        store: launch.integratesWithSystem && !launch.isUITest ? .standard : nil
    )

    /// The playing track's lyrics, looked up as the track changes and shared by everything that
    /// shows them (Android: MainViewModel's lyrics state). Follows the player from ``start()``.
    @ObservationIgnored private(set) lazy var currentLyrics = CurrentTrackLyrics(repository: lyrics)

    /// The playing track's animated cover for the lock screen: the engine needs its
    /// `MPMediaItemAnimatedArtwork` resolved as the track and the ``CanvasPolicy`` inputs change,
    /// whether or not Now Playing is open. Follows the player from ``start()`` like
    /// ``currentLyrics`` does.
    @ObservationIgnored private(set) lazy var currentCanvas = CurrentTrackCanvas(app: self)

    /// Lyrics for a download's tags.
    @ObservationIgnored private lazy var downloadLyrics: DownloadLyricsProvider = { [lyrics, settings] song in
        let preferences = await MainActor.run { LyricsPreferences(settings: settings) }
        let track = LyricsTrack(videoId: song.videoId, title: song.title, artist: song.artist, album: song.albumName, durationMs: song.durationMillis)
        guard let result = await lyrics.lyrics(for: track, preferences: preferences, onEvent: { _ in }) else { return nil }
        return DownloadLyrics(plain: LRCFormat.lrc(from: result.lines), enhanced: result.isWordSynced ? LRCFormat.enhancedLRC(from: result.lines) : nil)
    }

    /// Downloads: a background URLSession plus the library in Application Support. Created on
    /// first use, and at the latest shortly after launch (``start()``), before iOS can ask about
    /// finished background transfers.
    @ObservationIgnored private(set) lazy var downloads: DownloadManager = {
        let resolver = streamResolver
        let manager = DownloadManager.live(
            settings: settings,
            resolver: sourceResolver,
            network: network,
            library: downloadLibrary,
            lyricsProvider: downloadLyrics,
            refusalHandler: { url, status in await resolver.onPlaybackRefused(url: url, statusCode: status) }
        )
        // An add-on's DASH stream arrives as a converted playlist on this device (`vibramusic-hls://`).
        manager.localPlaylist = { SourceManifestFiles.standard.playlistText(for: $0) }
        return manager
    }()

    /// What is saved on this device (downloads and Files imports). Opened on first use: the
    /// first track that needs to know whether it is saved.
    @ObservationIgnored private(set) lazy var downloadLibrary = DownloadLibrary.live()

    /// Artist pictures, pages and genres, kept on this device. Loaded at launch (`start()`).
    @ObservationIgnored private(set) lazy var replayFacts = ReplayArtistFacts.standard(
        genresEnabled: ReplayText.genresAvailable(settings: settings)
    )
    @ObservationIgnored private(set) lazy var replayStats = ReplayListeningStats.standard(facts: replayFacts)
    @ObservationIgnored private(set) lazy var replayRecorder = ReplayListeningRecorder(sink: replayStats)
    /// The lookups behind Replay: the album a track belongs to, and each artist's picture, page
    /// and genres.
    @ObservationIgnored private(set) lazy var replayEnrichment: ReplayEnrichment = {
        let repository = self.repository
        let lastFMKey = (Bundle.main.object(forInfoDictionaryKey: "LASTFM_API_KEY") as? String) ?? ""
        return ReplayEnrichment(
            stats: replayStats,
            facts: replayFacts,
            trackLinks: { try await repository.trackLinks(videoId: $0) },
            searchArtist: { name in
                let rows = (try? await repository.search(query: name, filter: .artists)) ?? []
                for case .browse(let item) in rows {
                    return ReplayArtistCard(title: item.title, imageUrl: item.thumbnailUrl, browseId: item.browseId)
                }
                return nil
            },
            topTags: { await LastFMArtistTags.fetch(artist: $0, apiKey: lastFMKey, session: VibraMusicHTTP.session) }
        )
    }()

    /// Animated cover art (Apple Music, Tidal, community, Spotify).
    @ObservationIgnored private(set) lazy var canvas = CanvasRepository(
        session: VibraMusicHTTP.session,
        tokens: CanvasSpotifyTokenStore(
            session: VibraMusicHTTP.session,
            cookie: { [settings] in await settings.spotifySpdcToken },
            harvester: SpotifyTokenHarvester()))

    /// Listen Together: party membership and the socket. The sync coordinator starts once a party
    /// is joined (see ``partySync``).
    @ObservationIgnored private(set) lazy var partyStore = PartyServerStore.standard(defaultServer: Self.defaultPartyServer)
    @ObservationIgnored private(set) lazy var party = PartyClient(
        store: partyStore,
        urlSession: VibraMusicHTTP.session,
        identityProvider: PartyIdentityFromAccount(accounts: accounts, store: partyStore)
    )
    @ObservationIgnored private(set) lazy var partyBridge = PartyPlaybackBridge(player: player)
    @ObservationIgnored private(set) lazy var partySync = PartySyncCoordinator(
        client: party,
        bridge: partyBridge,
        stash: PartyQueueStashAdapter(queue: queue)
    )
    /// Listen Together for the Social screens: create/join/leave, members, host controls. Starting
    /// and stopping ``partySync``, the queue's party context and the personal-queue stash follow
    /// from its state by themselves.
    @ObservationIgnored private(set) lazy var listenTogether = ListenTogetherSession(client: party, sync: partySync, player: player)

    // MARK: Automix, versions, upgrades

    /// The playback cache's renditions as files Automix can decode (nil without a cache).
    @ObservationIgnored let automixRenditions: AudioCacheRenditions?
    /// Automix's planner behind the engine's transitions (the engine holds it weakly).
    @ObservationIgnored let automix: AutomixTransitionPlanner
    /// Song ↔ music video alignment behind ``PlayerController/switchVersion()``.
    @ObservationIgnored let versionAlignment: VersionAlignmentService
    /// The second look for a better copy of a track that started below the request.
    @ObservationIgnored let qualityUpgrades: QualityUpgradeController
    /// Read off the main actor by the analyzer: whether it may measure, and how hard.
    @ObservationIgnored private let automixStopped: AtomicFlag
    @ObservationIgnored private let automixBudget: LockedValue<AutomixAnalysisBudget>

    /// Play-history pings, so plays show in the account's YouTube Music history.
    @ObservationIgnored private(set) lazy var historyTracker: PlaybackHistoryTracker = {
        let resolver = streamResolver
        let network = self.network
        return PlaybackHistoryTracker(
            session: VibraMusicHTTP.session,
            auth: InnerTubeStreamAuth(client: innerTube),
            signatureTimestamp: { await resolver.signatureTimestamp() },
            isNetworkAvailable: { network.status.isOnline },
            language: { InnerTubeLocale.currentLanguage() }
        )
    }()

    /// Where Listen Together's party server lives unless the listener typed another (Android's
    /// `LISTEN_TOGETHER_SERVER` build default).
    static let defaultPartyServer = "https://vibramusic-listen-together.onrender.com"

    @ObservationIgnored private var started = false
    @ObservationIgnored private var observers: [PlaybackEventObserver] = []
    @ObservationIgnored private var trackers: [ChangeTracker] = []
    @ObservationIgnored private let artworkWarmer = PlayerArtworkWarmer()

    init(
        settings: AppSettings,
        likeState: LikeState,
        searchHistory: SearchHistory,
        network: any NetworkStatusProviding,
        innerTube: InnerTubeClient,
        audioCache: AudioStreamCache?,
        launch: AppLaunchOptions
    ) {
        self.settings = settings
        self.likeState = likeState
        self.searchHistory = searchHistory
        self.network = network
        self.innerTube = innerTube
        self.audioCache = audioCache
        self.launch = launch
        palettes = .shared
        router = AppRouter()

        let repository = YTMusicRepository(client: innerTube, likeState: likeState)
        self.repository = repository
        accounts = YouTubeAccountManager(
            client: innerTube,
            repository: repository,
            store: YouTubeAuthStore(credentials: KeychainStore()),
            clearBrowserCookies: { await YouTubeBrowserCookies.clearGoogleCookies(in: WKWebsiteDataStore.default().httpCookieStore) }
        )

        let ceiling = PlaybackQualityCeiling(settings: settings, network: network)
        qualityCeiling = ceiling
        streamResolver = StreamResolver.standard(
            session: VibraMusicHTTP.session,
            configuration: Self.streamConfiguration(ceiling: ceiling),
            poTokens: WebViewPoTokenProvider(),
            auth: InnerTubeStreamAuth(client: innerTube)
        )
        youTubeStreams = YouTubeStreamResolving(resolver: streamResolver)
        sourceRegistry = SourceRegistry(environment: .live(
            settings: settings,
            youTubeSearch: InnerTubeSongSearch(repository: repository),
            youTubeStreams: youTubeStreams
        ))
        sourceResolver = SourceResolver(registry: sourceRegistry)

        // Tests share no figures through the real defaults.
        let facts = StreamFactsBook(defaults: launch.integratesWithSystem ? .standard : nil)
        streamFacts = facts
        let processors = PlaybackDeckID.allCases.map { _ in AudioDSPProcessor(facts: facts) }
        dspProcessors = processors
        engine = AudioPlayerEngine(configuration: AudioPlayerEngine.Configuration(
            audioProcessorFactory: { deck in processors[deck == .a ? 0 : 1] },
            integratesWithSystem: launch.integratesWithSystem,
            remoteCommandCenter: launch.integratesWithSystem ? SystemRemoteCommandCenter(showsSkipIntervals: false, showsFeedbackCommands: true) : nil,
            artworkSession: VibraMusicHTTP.session
        ))
        queue = PlaybackQueueController(
            settings: settings,
            lastPlayed: .standard(),
            partyStash: .standard(),
            radioSource: InnerTubeRadioSource(repository: repository),
            sleepTimer: SleepTimer()
        )
        let resolver = streamResolver
        let sources = PlaybackSourceFactory(
            resolver: sourceResolver,
            youTube: youTubeStreams,
            cache: audioCache,
            facts: facts,
            request: { ceiling.currentRequest },
            atmosAllowed: { DeviceCodecs.shared.playsDolbyAtmos && Self.atmosSetting.value },
            onRefused: { url, status in Task { await resolver.onPlaybackRefused(url: url, statusCode: status) } }
        )
        sources.isOffline = { [network] in !network.status.isOnline }
        // An add-on's lossless and Atmos arrive as playlists: laid out as one file each, so the
        // cache fetches them once and keeps them.
        sources.segmented = SegmentedSources(session: VibraMusicHTTP.session) { SourceManifestFiles.standard.playlistText(for: $0) }
        sources.isUnmetered = { [network] in network.status.isOnline && network.status.isMetered != true }
        player = PlayerController(engine: engine, queue: queue, settings: settings, sources: sources, likeState: likeState, processors: processors)
        sources.isPlaying = { [weak player = self.player] videoId in player?.currentSong?.videoId == videoId }
        // A couple of seconds of sound: the track playing has its start before anything ahead is looked up.
        sources.isSounding = { [weak player = self.player] in player.map { $0.isPlaying && $0.position >= 2 } ?? true }
        // Off: JioSaavn, quick enough to ask for the next track before it plays.
        let quickSources = sourceResolver
        sources.quickCopy = { song, request in try await quickSources.prefetchSubstitute(TrackMatcher.targetOf(song), request: request) }
        offlineBackup = OfflineBackup(cache: audioCache, file: launch.integratesWithSystem && !launch.isUITest ? OfflineBackup.defaultFile : nil)

        // Automix: the analyzer reads the cache's renditions; the planner answers the engine.
        let youTube = youTubeStreams
        let headSource: @Sendable (String) -> (any AudioRangeDataSource)? = { videoId in
            HTTPAudioSource(onRefused: { url, status in Task { await resolver.onPlaybackRefused(url: url, statusCode: status) } }) {
                try await youTube.resolveStream(for: Song(videoId: videoId, title: "", artist: ""), request: ceiling.currentRequest)
            }
        }
        let playingKeys = sources.playingKeys
        let renditions = audioCache.map { cache in
            AudioCacheRenditions(cache: cache, headSource: headSource, playingKey: { playingKeys.key(for: $0) })
        }
        automixRenditions = renditions
        let stopped = AtomicFlag(false)
        let budget = LockedValue(AutomixAnalysisBudget.balanced)
        automixStopped = stopped
        automixBudget = budget
        let search = InnerTubeSongSearch(repository: repository)
        automix = AutomixTransitionPlanner(isStopped: { stopped.value }) {
            TrackAnalyzer(
                renditions: renditions,
                store: AutomixAnalysisStore(),
                catalogMatcher: AutomixYouTubeMatcher(search: { try await search.searchSongs($0) }),
                isStopped: { stopped.value },
                budget: { budget.value }
            )
        }

        versionAlignment = VersionAlignmentService(
            aligner: VersionAlignmentService.makeAligner(renditions: renditions, session: VibraMusicHTTP.session),
            cache: audioCache,
            renditions: renditions,
            headSource: headSource,
            remoteStream: { videoId in
                try? await youTube.resolveStream(for: Song(videoId: videoId, title: "", artist: ""), request: ceiling.currentRequest)
            }
        )

        let upgradeSearch = SourceUpgradeSearch(resolver: sourceResolver, registry: sourceRegistry, request: { ceiling.currentRequest })
        qualityUpgrades = QualityUpgradeController(
            upgrade: QualityUpgrade(search: upgradeSearch, requestForNow: { ceiling.currentRequest }),
            search: upgradeSearch,
            settings: settings
        )

        sources.savedFile = { [weak self] song in self?.savedFile(for: song) }
        sources.forgetMissing = { [weak self] song in self?.downloadLibrary.forgetMissing(song.videoId) }
        // One pass that also drops records whose file is gone, so those tracks stay in the backup.
        offlineBackup.savedSongs = { [weak self] in self?.downloadLibrary.songs(includeImported: false) ?? [] }
        offlineBackup.atmosAllowed = sources.atmosAllowed
        sources.networkSource = { [weak self] song in self?.networkSource(for: song) }
        sources.canSubstitute = { [sourceResolver] request in sourceResolver.canSubstituteForYouTube(request) }
        player.rate = { [weak self] videoId, status in
            guard let self, await self.innerTube.isSignedIn else { return }
            try await self.repository.rate(videoId: videoId, status: status)
        }
        player.versionFinder = { [weak self] song in await self?.otherVersion(of: song) }
        engine.transitionPlanner = automix
        player.automix = automix
        player.qualityUpgrades = qualityUpgrades
        qualityUpgrades.follow(ceiling)
        let alignment = versionAlignment
        player.versionAligner = { source, target in await alignment.offset(from: source, to: target) }
        alignment.publishStatus(to: player)
    }

    /// The live app: shared settings, the Keychain, the shared InnerTube client, the disk cache.
    static func live(launch: AppLaunchOptions = .current) -> AppModel {
        // Before anything that logs: the file opens with the build and the device, or stays off.
        DiagnosticLog.shared.setEnabled(AppSettings.shared.keepDiagnosticLog, header: DiagnosticLog.launchHeader())
        // First, before any cache opens: the first launch of a new build drops what the old one
        // wrote, the audio cache an earlier build left in Caches included.
        VersionUpdateWipe.run(settings: .shared)
        // Then whatever is still in Caches (where iOS may purge it) moves to the audio cache's home.
        AudioStreamCache.moveCache()
        let cache: AudioStreamCache?
        do {
            let opened = try AudioStreamCache(configuration: .standard(limitBytes: AppSettings.shared.audioCacheLimitBytes))
            cache = opened
            // Nothing plays yet, so no partial add-on copy has anyone to finish it (Android's start-up
            // `dropForeignEntries(keep = emptySet())`). Whole ones stay.
            Task { await opened.dropPartialAddonEntries(keepingTracks: []) }
        } catch {
            DebugLog.e("App", "the audio cache could not be opened; streaming uncached", error: error)
            cache = nil
        }
        let model = AppModel(
            settings: .shared,
            likeState: .shared,
            searchHistory: .shared,
            network: NetworkMonitor(),
            innerTube: .shared,
            audioCache: cache,
            launch: launch
        )
        current = model
        return model
    }

    /// The resolver's walk (StreamResolution's default catalog: VISIONOS first, then the embedded
    /// player and the cipher tier) and the playback ceiling read live from the per-network setting.
    nonisolated static func streamConfiguration(ceiling: PlaybackQualityCeiling) -> StreamResolver.Configuration {
        var configuration = StreamResolver.Configuration()
        configuration.catalog = streamCatalog
        configuration.playbackCeilingKbps = { ceiling.effectiveQuality.maxKbps ?? Int.max }
        configuration.language = { InnerTubeLocale.currentLanguage() }
        return configuration
    }

    /// StreamResolution's default walk, in its order.
    nonisolated static var streamCatalog: [StreamClientProfile] {
        StreamClientProfile.defaultCatalog
    }

    // MARK: - Startup

    /// Everything that can wait until the first frame: restoring the signed-in session and last
    /// session's queue, the cache following its size setting, playback observers.
    func start() {
        guard !started else { return }
        started = true
        Self.atmosSetting.value = settings.dolbyAtmos
        trackers.append(ChangeTracker.track({ [settings] in settings.dolbyAtmos }) { on in Self.atmosSetting.value = on })
        if let audioCache { _ = audioCache.followLimit(of: settings) }
        // The settings switch: off deletes the log file, on starts a fresh one.
        trackers.append(ChangeTracker.track({ [settings] in settings.keepDiagnosticLog }, initial: false) { on in
            DiagnosticLog.shared.setEnabled(on, header: DiagnosticLog.launchHeader())
        })

        // Automix measures nothing while it is off or a party is on (every device then moves
        // through the plain transition together), and at the CPU budget the listener chose.
        trackers.append(ChangeTracker.track({ [settings, player] in !settings.smartFadeEnabled || player.isInParty }) { [automixStopped] stopped in
            automixStopped.value = stopped
        })
        // Direct source stream stands aside during a party: every member starts where the host is.
        trackers.append(ChangeTracker.track({ [player] in player.isInParty }) { [qualityCeiling] inParty in qualityCeiling.setInParty(inParty) })
        trackers.append(ChangeTracker.track({ [settings] in settings.automixPerformanceMode }) { [automixBudget] mode in
            automixBudget.value = AutomixAnalysisBudget(mode)
        })
        listenTogether.start()
        // What Replay already knows about each artist, and whether it may ask Last.fm for genres.
        let facts = replayFacts
        Task.detached { facts.load() }
        trackers.append(ChangeTracker.track({ [settings] in ReplayText.genresAvailable(settings: settings) }) { facts.genresEnabled = $0 })
        // Lyrics load when the track changes, whether or not the player is open.
        currentLyrics.follow(player: player, settings: settings)
        // And the lock screen's animated cover is resolved on the same trigger, for the
        // `MPMediaItemAnimatedArtwork` the engine publishes.
        currentCanvas.follow(app: self)
        // The covers a skip lands on are warmed while this track plays.
        trackers.append(ChangeTracker.track({ [player] in
            PlayerArtworkWarmer.neighbours(in: player.queueState).map(\.videoId)
        }) { [player, artworkWarmer] _ in
            artworkWarmer.schedule(PlayerArtworkWarmer.neighbours(in: player.queueState))
        })

        let observers: [PlaybackEventObserver] = [
            ScrobblingObserver(settings: settings),
            DiscordPresenceObserver(
                settings: settings,
                speed: { [weak self] in self?.player.speed ?? 1 },
                stats: { [weak self] song in
                    // Only the figures measured on this row's own copy: after a track change the
                    // engine still reports the outgoing one's until the sampler runs again.
                    guard let player = self?.player, let stats = player.stats,
                          stats.itemID == player.sources.engineItemID(for: song) else { return nil }
                    return stats
                }
            ),
            ReplayObserver(recorder: replayRecorder, enrichment: replayEnrichment),
            YouTubeHistoryObserver(tracker: historyTracker),
            WidgetSnapshotObserver(player: player),
            OfflineBackupObserver(backup: offlineBackup, upcoming: { [weak self] in
                Array((self?.player.queue.state.upcoming ?? []).prefix(AudioStreamCache.queueDepth))
            }),
        ]
        observers.forEach(player.addObserver)
        self.observers = observers

        if launch.restoresQueue {
            player.restore()
        }
        Task { [weak self] in
            guard let self else { return }
            await self.accounts.restore()
            // Downloads re-attach to their background session soon after launch, off the first frame.
            try? await Task.sleep(for: .seconds(2))
            _ = self.downloads
        }
        Task.detached(priority: .utility) { [streamResolver] in
            await streamResolver.prewarm()
        }
    }

    /// The app went to the background: write the restart snapshot now.
    func didEnterBackground() {
        player.flushPersistence()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        isInForeground = phase == .active
        if phase == .active {
            // Activation diagnostics. One cheap line per activation so a user's pasted log can answer:
            // which build, which kind of in-app page was on top (for example the sign-in web view),
            // whether the app published anything to the system, and where the audio is
            // routed. It is kept in Release builds, so it carries no titles, ids or device names.
            let top = router.path(for: router.selectedTab).last.map { route in
                // The case name only: describing the whole route would build its payload (ids, titles) just to cut it off.
                Mirror(reflecting: route).children.first?.label ?? String(describing: route)
            } ?? "root"
            let nowPlayingSet = MPNowPlayingInfoCenter.default().nowPlayingInfo != nil
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.prefix(4).map(\.portType.rawValue)
            TrackLog.i("Activation", "bundle=\(Bundle.main.bundleIdentifier ?? "?") top=\(top) np=\(nowPlayingSet) route=\(outputs)")
        }
        if phase == .background {
            // Held open until the list is on disk: the process may be suspended a moment from now.
            let token = UIApplication.shared.beginBackgroundTask(withName: "offline-backup")
            Task {
                await offlineBackup.flush()
                UIApplication.shared.endBackgroundTask(token)
            }
            didEnterBackground()
        }
    }

    /// Changes the in-app language (nil follows the system) and rebuilds the UI in it.
    func setLanguage(_ code: String?) {
        LanguageBundle.override = code
        languageRevision += 1
    }

    // MARK: - Links

    /// A URL opened into the app (`onOpenURL`, a Universal Link, the Share Extension).
    func open(_ url: URL) {
        guard let link = DeepLink.parse(url) else { return }
        handle(link)
    }

    func handle(_ link: DeepLink) {
        let repository = self.repository
        router.handle(link, player: player) { videoId in
            try? await repository.trackLinks(videoId: videoId)
        }
    }

    // MARK: - Files and shares behind rows

    private func savedFile(for song: Song) -> SavedAudioFile? {
        let library = downloadLibrary
        guard let url = library.savedFileURL(for: song.videoId) else { return nil }
        let record = library.records[song.videoId]
        let isYouTube = record.map { $0.origin == .download && url.pathExtension.lowercased() == "m4a" && ($0.downloadFormat?.hasPrefix("AAC") ?? true) } ?? false
        return SavedAudioFile(url: url, isYouTubeOrigin: isYouTube)
    }

    private func networkSource(for song: Song) -> (any AudioRangeDataSource)? {
        if SmbConfig.isSmbId(song.videoId), let stream = song.localUri, SmbConfig.isSmbUrl(stream), settings.isSMBConfigured {
            let credentials = SmbCredentials(host: settings.smbHost, share: settings.smbShare, basePath: settings.smbBasePath,
                                             username: settings.smbUsername, password: settings.smbPassword)
            let client = SmbClient(credentials: credentials, pool: smbPool(for: credentials))
            let source = SmbAudioSource(streamURL: stream, client: client)
            return NetworkShareAudioSource(contentInfo: { try await source.contentInfo() }, read: { try await source.read($0) })
        }
        if WebDavConfig.isWebDavId(song.videoId), let file = WebDavConfig.fileUrlOf(song.videoId), settings.isWebDAVConfigured {
            let credentials = WebDavCredentials(url: settings.webdavUrl, username: settings.webdavUsername, password: settings.webdavPassword)
            let source = WebDavAudioSource(fileURL: file, client: WebDavClient(), credentials: credentials)
            return NetworkShareAudioSource(contentInfo: { try await source.contentInfo() }, read: { try await source.read($0) })
        }
        return nil
    }

    @ObservationIgnored private var smbPools: [SmbCredentials: SmbConnectionPool] = [:]
    /// What dials a share; tests stand in a share held in memory. Set before the first read.
    @ObservationIgnored var smbSessionFactory: any SmbSessionFactory = AmSmbSessionFactory()

    /// One pooled SMB session per credentials set, as NetworkLibrary expects.
    func smbPool(for credentials: SmbCredentials) -> SmbConnectionPool {
        if let pool = smbPools[credentials] { return pool }
        let pool = SmbConnectionPool(credentials: credentials, factory: smbSessionFactory)
        smbPools[credentials] = pool
        return pool
    }

    // MARK: - Versions

    /// The music video for a song, or the song for a music video (InnerTube's resolveAudio /
    /// resolveVideo with Sources' track matcher).
    private func otherVersion(of song: Song) async -> Song? {
        if song.isVideo {
            let audio = await repository.resolveAudio(for: song, using: TrackMatcherVersions())
            return audio.videoId == song.videoId ? nil : audio
        }
        return await repository.resolveVideo(for: song, using: TrackMatcherVersions())
    }

    /// The Dolby Atmos switch, readable from the stream factory's background closures.
    nonisolated static let atmosSetting = AtomicFlag(true)
}

/// A Bool readable from any thread.
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool

    init(_ value: Bool) { stored = value }

    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// A value readable and writable from any thread.
final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// NetworkLibrary's SMB and WebDAV byte sources behind AudioCache's protocol ("the app adapts in
/// one line" — NetworkLibrary report): the module can't import AudioCache, so the shapes meet here.
struct NetworkShareAudioSource: AudioRangeDataSource {
    let contentInfoProvider: @Sendable () async throws -> RemoteContentInfo
    let reader: @Sendable (Range<Int64>) async throws -> Data

    init(contentInfo: @escaping @Sendable () async throws -> RemoteContentInfo, read: @escaping @Sendable (Range<Int64>) async throws -> Data) {
        contentInfoProvider = contentInfo
        reader = read
    }

    func contentInfo() async throws -> AudioContentInfo {
        let info = try await contentInfoProvider()
        return AudioContentInfo(contentLength: info.contentLength, mimeType: info.mimeType ?? RemoteMimeTypes.mimeType(forExtension: info.fileExtension))
    }

    func read(_ range: Range<Int64>) async throws -> Data {
        try await reader(range)
    }
}

/// Sources' track matcher as InnerTube's version matcher (song ↔ music video).
struct TrackMatcherVersions: SongVersionMatching {
    func searchQueries(for song: Song) -> [String] {
        TrackMatcher.queries(TrackMatcher.targetOf(song))
    }

    func bestMatch(among candidates: [Song], for song: Song) -> Song? {
        TrackMatcher.best(candidates, TrackMatcher.targetOf(song))
    }

    func bestOfficialAudio(forVideo song: Song, among candidates: [Song]) -> Song? {
        TrackMatcher.bestOfficialAudioForVideo(candidates, TrackMatcher.targetOf(song))
    }
}

extension LyricsPreferences {
    /// The listener's lyric settings as the Lyrics module reads them.
    @MainActor
    init(settings: AppSettings) {
        // Core and Lyrics each declare `LyricsSource` with the same raw values (Android's enum
        // names); settings hold Core's, the repository takes its own.
        self.init(
            syncedLyricsEnabled: settings.syncedLyrics,
            enabledSources: Set(settings.lyricsSources.compactMap { Lyrics.LyricsSource(rawValue: $0.rawValue) }),
            sourceOrder: settings.lyricsSourceOrder.compactMap { Lyrics.LyricsSource(rawValue: $0.rawValue) },
            prioritizeSyllableSync: settings.prioritizeSyllableSync,
            offsetMs: settings.lyricsOffsetMs,
            translationLanguage: settings.translationLanguage,
            blurUnfocusedLines: settings.lyricsBlur,
            paxSenixAPIKey: settings.paxSenixApiKey
        )
    }
}
