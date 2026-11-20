import AVFoundation
import VibraMusicCore
import Observation

/// The playback engine: AVFoundation in place of the Android service's ExoPlayer pair.
///
/// Plays one ``PlayableItem`` at a time on one of two `AVQueuePlayer` decks, preloading the item
/// after it for a gapless advance, or loading it on the other deck for a crossfade or an Automix
/// transition (``TransitionSpec``). Every item carries an `MTAudioProcessingTap` that runs the
/// app's DSP chain (``PlaybackAudioProcessor``) and a silence detector. The engine publishes Now
/// Playing info, takes remote commands, manages the iOS audio session (interruptions, "headphones
/// unplugged" pauses), executes the sleep timer, skips silence, retries failed streams through
/// ``sourceRecovery``, and samples stream stats.
///
/// It does not own the queue: the app answers ``AudioPlayerEngineDelegate/audioPlayerEngine(_:itemAfter:)``
/// and moves its queue when told the item changed. All state is `@Observable`; ``position`` is kept
/// apart from everything else so only a scrubber that reads it redraws four times a second.
@MainActor
@Observable
public final class AudioPlayerEngine {
    /// Past this point, "previous" restarts the track instead of going back one (Android's
    /// `BACK_RESTARTS_AFTER_MS`).
    public static let backRestartsAfter: TimeInterval = 10
    public static let speedRange: ClosedRange<Float> = 0.5...2
    public static let crossfadeRange: ClosedRange<TimeInterval> = 0...12

    public struct Configuration {
        /// Makes each deck's audio processor (the AudioDSP chain). Nil plays unprocessed.
        public var audioProcessorFactory: PlaybackAudioProcessorFactory?
        /// Publish Now Playing, take remote commands and (iOS) manage the audio session. Off for
        /// previews and tests; the two overrides below still apply when it is off.
        public var integratesWithSystem: Bool
        public var nowPlayingPublisher: NowPlayingPublishing?
        public var remoteCommandCenter: RemoteCommandRegistering?
        /// Fetches lock-screen artwork.
        public var artworkSession: URLSession
        public var skipSilencePolicy: SkipSilencePolicy
        /// Decode each track ahead with `AVAssetReader` to find silent spans before the playhead
        /// reaches them. Off leaves skip silence to the tap's live detector alone.
        public var scansAheadForSilence: Bool
        /// How often ``position`` updates while playing.
        public var positionUpdateInterval: TimeInterval
        /// How often checkpoints, stats and Now Playing's elapsed time refresh while playing
        /// (Android's `PROGRESS_SAMPLE_MS`).
        public var sampleInterval: TimeInterval
        var clock: PlaybackClock = ContinuousPlaybackClock()

        public init(
            audioProcessorFactory: PlaybackAudioProcessorFactory? = nil,
            integratesWithSystem: Bool = true,
            nowPlayingPublisher: NowPlayingPublishing? = nil,
            remoteCommandCenter: RemoteCommandRegistering? = nil,
            artworkSession: URLSession = VibraMusicHTTP.session,
            skipSilencePolicy: SkipSilencePolicy = .standard,
            scansAheadForSilence: Bool = true,
            positionUpdateInterval: TimeInterval = 0.25,
            sampleInterval: TimeInterval = 5
        ) {
            self.audioProcessorFactory = audioProcessorFactory
            self.integratesWithSystem = integratesWithSystem
            self.nowPlayingPublisher = nowPlayingPublisher
            self.remoteCommandCenter = remoteCommandCenter
            self.artworkSession = artworkSession
            self.skipSilencePolicy = skipSilencePolicy
            self.scansAheadForSilence = scansAheadForSilence
            self.positionUpdateInterval = positionUpdateInterval
            self.sampleInterval = sampleInterval
        }
    }

    // MARK: - Observable state

    /// The item the session is on. Changes the moment a crossfaded track becomes audible.
    public internal(set) var currentItem: PlayableItem?
    /// What plays next, as the delegate last answered.
    public internal(set) var upcomingItem: PlayableItem?
    /// The listener's intent — what the play/pause button shows. True while buffering towards play.
    public internal(set) var playWhenReady = false
    /// Audio is actually advancing.
    public internal(set) var isPlaying = false
    /// Waiting on a stream: opening the item (including the source's own resolution) or a stall.
    public internal(set) var isBuffering = false
    /// The last item finished with nothing after it; ``play()`` starts it over.
    public internal(set) var hasEnded = false
    /// Seconds into ``currentItem``.
    public internal(set) var position: TimeInterval = 0
    /// Length of ``currentItem``: the decoder's once known, else the catalogue's; 0 when unknown.
    public internal(set) var duration: TimeInterval = 0
    public internal(set) var lastError: PlaybackError?
    public internal(set) var stats: PlaybackStats?
    /// How ``currentItem``'s audio reaches the output: through the DSP tap, bit-transparent
    /// (lossless with nothing to process), or passed through for spatial rendering (Atmos). Nil
    /// until the item has opened. What the audio pipeline dialog reports.
    public internal(set) var signalPath: PlaybackSignalPath?
    public internal(set) var sleepTimer: SleepTimerState?
    /// A crossfade or Automix transition (or the sleep timer's fade-out) is in flight.
    public internal(set) var isTransitioning = false
    /// The transition in flight does something a plain crossfade couldn't (see
    /// ``TransitionSpec/isRealMix``); what the Android scrubber lit up for.
    public internal(set) var isSmartMixInProgress = false
    /// Where the planned Automix transition sits on the current track, when the planner lets it show.
    public internal(set) var transitionWindow: TransitionWindow?

    var storedRate: Float = 1
    var storedCrossfade: TimeInterval = 0
    var storedSkipSilence = false
    var storedSubtitle: String?
    var storedTransitionsSuspended = false
    /// The resolved animated covers for the current item; the app sets them, item changes clear them.
    var storedAnimatedArtworks: [NowPlayingAnimatedArtwork] = []

    // MARK: - Settings

    /// Playback speed, 0.5×–2×, pitch preserved. Not applied to a deck mid-transition — an Automix
    /// beatmatch stacks its stretch on top of it, and writing the raw value over that would drop the
    /// incoming track back to its own tempo halfway through a blend — but applied as it finishes.
    public var rate: Float {
        get { storedRate }
        set { applyRate(newValue) }
    }

    /// Crossfade length in seconds, 0 (off) to 12.
    public var crossfadeDuration: TimeInterval {
        get { storedCrossfade }
        set { storedCrossfade = min(max(newValue, Self.crossfadeRange.lowerBound), Self.crossfadeRange.upperBound) }
    }

    /// Let ``transitionPlanner`` time each transition. Independent of ``crossfadeDuration``, which it
    /// only uses as the fallback length.
    public var automixEnabled = false

    /// Skip silent intros, outros and gaps of a second or more.
    public var skipSilence: Bool {
        get { storedSkipSilence }
        set {
            guard newValue != storedSkipSilence else { return }
            storedSkipSilence = newValue
            skipSilenceChanged()
        }
    }

    /// No transitions while true: a Listen Together party (every member would start the next song
    /// at a different moment), or a version swap that owns the standby deck. Also true, whatever it
    /// was set to, while ``replaceCurrent(with:)`` holds the standby deck.
    public var transitionsSuspended: Bool {
        get { storedTransitionsSuspended || swapTask != nil }
        set { storedTransitionsSuspended = newValue }
    }

    /// Replaces the artist line on the lock screen, e.g. with the current synced lyric ("♪ …"), as
    /// the Android notification did. Nil shows the artist.
    public var nowPlayingSubtitle: String? {
        get { storedSubtitle }
        set {
            guard newValue != storedSubtitle else { return }
            storedSubtitle = newValue
            publishNowPlaying()
        }
    }

    /// The item's animated covers for the lock screen (``NowPlayingAnimatedArtwork``): the app
    /// resolves its clips (Canvas on Wi-Fi terms; a square and a 3:4 tall one when the provider
    /// has both) and hands them in; the builder places each under the system's animated-artwork
    /// key its shape selects on iOS 26+, and changes of item clear them. Nothing
    /// here on Android — the engine over there publishes no animated artwork, so this is a
    /// deliberate iOS improvement.
    public var nowPlayingAnimatedArtworks: [NowPlayingAnimatedArtwork] {
        get { storedAnimatedArtworks }
        set {
            guard newValue != storedAnimatedArtworks else { return }
            storedAnimatedArtworks = newValue
            publishNowPlaying()
        }
    }

    @ObservationIgnored public weak var delegate: AudioPlayerEngineDelegate?
    @ObservationIgnored public weak var transitionPlanner: TransitionPlanning?
    /// Called when an item fails, to get a fresh source for it (see ``RecoveryReason``).
    @ObservationIgnored public var sourceRecovery: PlaybackSourceRecovery?
    /// Told of every audio-session event after the engine has acted on it, so a host that follows
    /// something else (Listen Together) can tell a pause the user asked for from one the system did.
    @ObservationIgnored public var onAudioSessionEvent: ((AudioSessionEvent) -> Void)?

    // MARK: - Internals

    @ObservationIgnored let configuration: Configuration
    @ObservationIgnored let clock: PlaybackClock
    @ObservationIgnored var deckA: PlaybackDeck
    @ObservationIgnored var deckB: PlaybackDeck
    @ObservationIgnored var active: PlaybackDeck
    @ObservationIgnored var standby: PlaybackDeck
    @ObservationIgnored var crossfade: CrossfadeController!
    @ObservationIgnored var recovery = RecoveryLedger()
    @ObservationIgnored let processors: [PlaybackDeckID: PlaybackAudioProcessor]
    @ObservationIgnored var nowPlaying: NowPlayingPublishing?
    @ObservationIgnored var remoteCommands: RemoteCommandRegistering?
    @ObservationIgnored let artwork: NowPlayingArtworkLoader
    @ObservationIgnored var feedbackStatus: LikeStatus = .indifferent
    #if os(iOS)
    @ObservationIgnored var audioSession: AudioSessionControlling?
    #endif
    @ObservationIgnored var resumeAfterInterruption = false

    @ObservationIgnored var isLoadingItem = false
    /// The item opened last and when it was asked for, until its first audio is logged: the one
    /// figure a slow start or a swap's silence is measured by.
    @ObservationIgnored var awaitingFirstAudio: (itemID: String, since: ContinuousClock.Instant)?
    /// The player said it was playing at `from` and its clock hasn't been seen to move since.
    @ObservationIgnored var clockWatch: (entry: DeckEntry, from: TimeInterval, since: ContinuousClock.Instant, after: String)?
    @ObservationIgnored var loadGeneration = 0
    @ObservationIgnored var loadTask: Task<Void, Never>?
    /// The ``loadTask`` waiting to reopen after a media-services reset an item reported, which the
    /// other items reporting the same reset don't start again.
    @ObservationIgnored var resetWait: Task<Void, Never>?
    /// A ``replaceCurrent(with:)`` in flight, and which one (a newer swap supersedes it).
    @ObservationIgnored var swapTask: Task<Void, Never>?
    @ObservationIgnored var swapGeneration = 0
    /// How the last swap's crossover began: how far the better copy was from the playing one, in
    /// the track's seconds (positive is ahead, a span skipped; negative behind, a span heard twice),
    /// and whether it was started in step by the host clock. Nil until the latest swap has crossed over
    /// (not when it was cut over instead).
    /// For the log and the tests.
    @ObservationIgnored var lastSwap: (skew: TimeInterval, inStep: Bool)?
    @ObservationIgnored var preloadTask: Task<Void, Never>?
    /// The item ``preloadTask`` is opening, so a refresh that asks for the same one leaves it be.
    @ObservationIgnored var preloadingItemID: String?
    @ObservationIgnored var preloadGeneration = 0
    @ObservationIgnored var armTask: Task<Void, Never>?
    @ObservationIgnored var statsTask: Task<Void, Never>?
    @ObservationIgnored var sleepTask: Task<Void, Never>?
    @ObservationIgnored var tickerTask: Task<Void, Never>?
    @ObservationIgnored var samplerTask: Task<Void, Never>?
    @ObservationIgnored var openedAudio: [String: OpenedAudio] = [:]
    /// Opens still running, by item id, so a second caller waits on the first instead of resolving again.
    @ObservationIgnored var openingAudio: [String: AudioOpenFlight] = [:]
    @ObservationIgnored var restreamedMissingFiles: Set<String> = []
    /// Where the current item was last reopened for bytes it ran out of, and how many of them were
    /// on disk then (see ``itemEnded(_:genuine:)``).
    @ObservationIgnored var shortEnd: (itemID: String, at: TimeInterval, bytes: Int64)?
    @ObservationIgnored var silenceMaps: [String: SilenceMap] = [:]
    @ObservationIgnored var silenceScans: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var silenceScanFailures: Set<String> = []
    /// The deck and entry the live skip-silence fallback is fast-forwarding, if it is.
    @ObservationIgnored var liveSkip: (deck: PlaybackDeck, entry: DeckEntry)?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.clock = configuration.clock
        var processors: [PlaybackDeckID: PlaybackAudioProcessor] = [:]
        for id in PlaybackDeckID.allCases {
            if let processor = configuration.audioProcessorFactory?(id) { processors[id] = processor }
        }
        self.processors = processors
        deckA = PlaybackDeck(id: .a, processor: processors[.a])
        deckB = PlaybackDeck(id: .b, processor: processors[.b])
        active = deckA
        standby = deckB
        artwork = NowPlayingArtworkLoader(session: configuration.artworkSession)
        nowPlaying = configuration.nowPlayingPublisher
            ?? (configuration.integratesWithSystem ? SystemNowPlayingCenter() : nil)
        remoteCommands = configuration.remoteCommandCenter
            ?? (configuration.integratesWithSystem ? SystemRemoteCommandCenter() : nil)
        crossfade = CrossfadeController(host: self)
        crossfade.startLatency = CrossfadeController.initialStartLatency
        wire(deckA)
        wire(deckB)
        remoteCommands?.activate { [weak self] command in
            self?.dispatchRemoteCommand(command) ?? .noActionableNowPlayingItem
        }
        #if os(iOS)
        if configuration.integratesWithSystem {
            audioSession = AudioSessionController { [weak self] event in self?.handleAudioSessionEvent(event) }
        }
        #endif
        startTicker()
        startSampler()
    }

    /// Stops playback and releases the players, the system registrations and every background task.
    /// The engine is unusable afterwards.
    public func shutdown() {
        checkpoint()
        cancelSwap()
        crossfade.release()
        [loadTask, preloadTask, armTask, statsTask, sleepTask, tickerTask, samplerTask].forEach { $0?.cancel() }
        silenceScans.values.forEach { $0.cancel() }
        silenceScans.removeAll()
        deckA.invalidate()
        deckB.invalidate()
        remoteCommands?.deactivate()
        nowPlaying?.publish(nil)
        nowPlaying?.publishPlaybackState(isPlaying: false, hasItem: false)
        artwork.cancel()
    }

    func wire(_ deck: PlaybackDeck) {
        deck.onEvent = { [weak self] deck, event in self?.handle(event, from: deck) }
        deck.observePeriodically(every: configuration.positionUpdateInterval) { [weak self] deck in
            self?.positionTick(deck)
        }
    }

    /// The crossfade controller's clock: its phase decides how soon it wants to be asked again.
    private func startTicker() {
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                let step: TimeInterval
                do {
                    guard let engine = self else { return }
                    step = engine.crossfade.tick()
                }
                try? await Task.sleep(for: .seconds(step))
            }
        }
    }

    /// The five-second sampler: checkpoints, stats, and a Now Playing refresh so the lock screen's
    /// extrapolated clock can't drift.
    private func startSampler() {
        let interval = configuration.sampleInterval
        samplerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let engine = self else { return }
                guard engine.isPlaying else { continue }
                engine.checkpoint()
                engine.sampleStats()
                engine.publishNowPlaying()
            }
        }
    }

    // MARK: - Transport

    /// Makes `item` current, at `start` seconds. `playWhenReady` nil keeps the current intent; pass
    /// false to restore a queue on launch without starting it. If `item` is the preloaded next
    /// item, it starts at once from the preloaded copy.
    public func load(_ item: PlayableItem, startingAt start: TimeInterval = 0, playWhenReady play: Bool? = nil) {
        cancelSwap()
        crossfade.onSkipRequested()
        if let play { setPlayWhenReady(play) }
        hasEnded = false
        if start <= 0, active.current?.item.id == currentItem?.id, let queued = active.queued, queued.item.id == item.id,
           let entry = active.advanceToQueued() {
            if playWhenReady {
                // Opened ahead isn't buffered: a playlist's item can still have nothing to play.
                awaitingFirstAudio = (item.id, .now)
                active.play()
                // What the player made of the preloaded copy a second in: an empty buffer, an item
                // not ready, or one that won't render look the same from here otherwise.
                let deck = active
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    guard deck.current === entry else { return }
                    PlaybackLog.debug(deck.bufferReport(entry) + " (a second after a preloaded start)", about: entry.item.trackID)
                }
            } else {
                awaitingFirstAudio = nil
                active.pause()
            }
            itemBecameCurrent(entry.item, reason: .requested)
            entryBecameCurrent(entry)
            return
        }
        openItem(item, at: start, reason: .requested)
    }

    public func play() {
        guard let item = currentItem else { return }
        setPlayWhenReady(true)
        hasEnded = false
        // Parked after its retries ran out (offline, say): the last attempt emptied the deck, so
        // there is nothing to resume. Play opens it again where it stopped, with a fresh budget.
        if active.current == nil, !isLoadingItem {
            cancelSwap()
            openItem(item, at: position, reason: nil)
            return
        }
        active.play()
        crossfade.syncTransport()
        updatePlayingState()
        publishNowPlaying()
    }

    public func pause() {
        resumeAfterInterruption = false
        pausePlayback()
    }

    public func togglePlayPause() {
        playWhenReady ? pause() : play()
    }

    /// Moves the playhead. Drops any crossfade in flight.
    public func seek(to time: TimeInterval) {
        guard currentItem != nil else { return }
        crossfade.onSeek()
        endLiveSkip()
        shortEnd = nil
        let upper = duration > 0 ? duration : max(time, 0)
        let target = min(max(time, 0), upper)
        position = target
        hasEnded = false
        // Sought mid-song as it was opened, this entry's clock would be off from the sound for the
        // rest of the track. Opened afresh it walks its frames first: a silent wait, once per item.
        if target > 0, let item = currentItem, let entry = active.current, entry.item.id == item.id, !entry.isPreciselyTimed {
            PlaybackLog.info("\(item.id): reopening it precisely timed for a seek to \(String(format: "%.3f", target))s", about: item.trackID)
            cancelSwap()
            openItem(item, at: target, reason: nil)
            publishNowPlaying()
            checkpoint()
            return
        }
        let seeking = ContinuousClock.now
        active.seek(to: target) { [weak self] _ in
            guard let self else { return }
            self.position = self.active.position
            self.publishNowPlaying()
            self.logClock("a seek to \(String(format: "%.3f", target))s, \(TrackLog.ms(since: seeking))ms after it was asked for", on: self.active)
        }
        publishNowPlaying()
        checkpoint()
    }

    /// Seeks by `delta` seconds from the current position.
    public func skip(by delta: TimeInterval) {
        seek(to: position + delta)
    }

    /// Goes to ``upcomingItem`` now, cutting any blend. Returns false when nothing follows.
    @discardableResult
    public func skipToNext() -> Bool {
        guard let next = upcomingItem else { return false }
        load(next)
        return true
    }

    /// Whether "previous" should restart the current track rather than go back one.
    public var restartsOnPrevious: Bool { position > Self.backRestartsAfter }

    /// Stops and forgets the current item, and the sleep timer with it.
    public func stop() {
        cancelSwap()
        crossfade.onSkipRequested()
        crossfade.release()
        loadGeneration += 1
        [loadTask, preloadTask, armTask, statsTask].forEach { $0?.cancel() }
        active.pause()
        active.clear()
        standby.retire(rate: rate)
        setPlayWhenReady(false)
        currentItem = nil
        upcomingItem = nil
        isPlaying = false
        isBuffering = false
        isLoadingItem = false
        position = 0
        duration = 0
        stats = nil
        signalPath = nil
        lastError = nil
        if sleepTimer != nil { cancelSleepTimer() }
        publishNowPlaying()
    }

    /// Ask the delegate again what follows the current item — call after any queue edit (reorder,
    /// play next, shuffle, repeat mode, AutoPlay appending).
    public func upcomingItemDidChange() {
        refreshUpcoming()
    }

    /// Call when a DSP setting changes (EQ, widening, normalization, Automix): each loaded item is
    /// asked again whether it needs its tap, so a lossless track gains one the moment the EQ goes
    /// on and loses it again when the EQ goes off.
    public func audioProcessingDidChange() {
        for (entry, deck) in [(active.current, active), (active.queued, active), (standby.current, standby)] {
            guard let entry else { continue }
            applySignalPath(to: entry, on: deck)
        }
        if let entry = active.current, entry.item.id == currentItem?.id { signalPath = entry.signalPath }
    }

    /// Lights the lock screen's like/dislike for the current item.
    public func setFeedback(_ status: LikeStatus) {
        feedbackStatus = status
        remoteCommands?.updateFeedback(isLiked: status == .like, isDisliked: status == .dislike)
    }

    // MARK: - Sleep timer

    public func startSleepTimer(_ request: SleepTimerRequest) {
        sleepTask?.cancel()
        sleepTask = nil
        switch request {
        case .minutes(let minutes):
            sleepTimer = SleepTimerState(presetMinutes: minutes, deadline: clock.now + TimeInterval(minutes) * 60)
        case .duration(let seconds):
            sleepTimer = SleepTimerState(deadline: clock.now + max(seconds, 0))
        case .endOfTrack:
            sleepTimer = SleepTimerState(afterTrack: true)
        }
        if let deadline = sleepTimer?.deadline { scheduleSleep(at: deadline) }
        updateAdvancePolicy()
    }

    public func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimer = nil
        updateAdvancePolicy()
        crossfade.onSleepTimerCleared()
    }

    /// How long until the sleep timer pauses playback; nil when none is set or it waits for the
    /// end of the track. Read it on a timeline (it is not observable, it changes continuously).
    public var sleepTimerRemaining: TimeInterval? {
        sleepTimer?.remaining(at: clock.now)
    }

    private func scheduleSleep(at deadline: TimeInterval) {
        let clock = self.clock
        sleepTask = Task { [weak self] in
            let wait = deadline - clock.now
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, let self, self.sleepTimer?.deadline == deadline else { return }
            PlaybackLog.info("sleep timer ran out; pausing", about: self.currentItem?.trackID)
            self.pause()
            self.cancelSleepTimer()
        }
    }

    // MARK: - Settings application

    func applyRate(_ value: Float) {
        let clamped = min(max(value, Self.speedRange.lowerBound), Self.speedRange.upperBound)
        endLiveSkip()
        storedRate = clamped
        if !crossfade.isTransitioning {
            active.rate = clamped
            standby.rate = clamped
        }
        publishNowPlaying()
    }

    /// "Sleep after this track" must stop the queue player moving on by itself, so the next track
    /// is never heard.
    func updateAdvancePolicy() {
        let advances = sleepTimer?.afterTrack != true
        active.advancesAutomatically = advances
        standby.advancesAutomatically = advances
    }

    func setPlayWhenReady(_ value: Bool) {
        playWhenReady = value
        #if os(iOS)
        if value { audioSession?.activate() }
        #endif
    }

    func pausePlayback() {
        endLiveSkip()
        setPlayWhenReady(false)
        active.pause()
        crossfade.syncTransport()
        updatePlayingState()
        publishNowPlaying()
        checkpoint()
    }

    func updatePlayingState() {
        let playing = active.isPlaying && active.current?.item.id == currentItem?.id
        // Not only on a change: a skip onto a preloaded item can go from playing to playing. And
        // only on a ready item: just after the skip the player still says it is playing, about an
        // item with nothing to play yet.
        if playing, let item = currentItem, let opened = awaitingFirstAudio, opened.itemID == item.id,
           active.current?.playerItem.status == .readyToPlay {
            PlaybackLog.info("first audio for \(item.id) \(TrackLog.ms(since: opened.since))ms after it was asked for", about: item.trackID)
            awaitingFirstAudio = nil
            logClock("first audio", on: active)
        }
        if playing != isPlaying {
            isPlaying = playing
            if playing, let item = currentItem {
                recovery.itemBecameAudible(item.id)
                // A retry that worked, or the track after one that was skipped, is playing: the
                // error has been dealt with and comes off the screen.
                lastError = nil
            }
            publishNowPlaying()
            checkpoint()
        }
        isBuffering = currentItem != nil && (isLoadingItem || (playWhenReady && !hasEnded && active.isWaiting))
    }

    func checkpoint() {
        guard let item = currentItem else { return }
        delegate?.audioPlayerEngine(self, checkpoint: PlaybackCheckpoint(itemID: item.id, position: position, isPlaying: isPlaying))
    }

    func sampleStats() {
        guard let entry = active.current, entry.item.id == currentItem?.id else { return }
        publishPipelineFacts(for: entry)
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            let sampled = await PlaybackStatsSampler.sample(
                itemID: entry.item.id,
                playerItem: entry.playerItem,
                declared: entry.declaredFormat
            )
            guard !Task.isCancelled, let self, self.active.current === entry else { return }
            self.stats = sampled
        }
    }

    // MARK: - Test and diagnostics access

    func deck(_ id: PlaybackDeckID) -> PlaybackDeck { id == .a ? deckA : deckB }
    var activeDeckID: PlaybackDeckID { active.id }
    /// How long since the last transition finished (for a caller about to cut into the session
    /// deck, such as a mid-track quality swap, which should wait a few seconds after a blend).
    public var timeSinceLastTransition: TimeInterval? { crossfade.timeSinceTransition() }
}
