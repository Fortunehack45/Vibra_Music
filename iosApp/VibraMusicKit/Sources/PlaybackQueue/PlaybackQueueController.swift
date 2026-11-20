import Foundation
import Observation
import VibraMusicCore

// Ports the queue half of playback/PlaybackService.kt (transition bookkeeping, AutoPlay, repeat,
// shuffle toggle, restart persistence, stations, the session's queue-jump rule), the queue
// operations MainActivity.kt performs through the MediaController (play, play next, add to queue,
// start radio, jump, remove, move, clear, dislike skip) and PlayerConnection.kt's playSongs.

/// The playback queue: the one owner of what plays next.
///
/// On Android the queue lives in ExoPlayer, and the service reacts to its callbacks. Here the queue
/// is a plain model the playback engine follows: the engine loads whatever
/// ``onCurrentItemChange`` names, and reports back through ``trackDidFinish()`` and
/// ``recordPlayhead(positionMs:isPlaying:)``. Every rule the service applied on a transition —
/// bounded history, consuming played user-queue entries, topping AutoPlay up, persisting the
/// restart snapshot — runs here, whichever path moved the queue.
///
/// Two kinds of edit, as on Android:
/// - **User intents** (``playFrom(_:index:source:)``, ``playNext(_:)``, ``jump(to:)``,
///   ``removeFromQueue(at:)`` …) are refused while a party's host has locked control, and report
///   ``onLocalIntent`` so a party can publish them.
/// - **Programmatic edits** (``setItems(_:startIndex:startPositionMs:playback:)``,
///   ``insertItems(_:at:)``, ``removeItems(in:)``, ``moveItem(from:to:)``,
///   ``replaceItems(in:with:)``, ``seek(toItem:positionMs:)``) are what a sync layer uses to
///   reconcile the queue with a party's. They are never refused and never reported.
///
/// Set ``onCurrentItemChange`` before calling ``restore()``, and call
/// ``flushPersistence(positionMs:isPlaying:)`` when the app leaves the foreground.
@MainActor
@Observable
public final class PlaybackQueueController {

    /// The queue. Replaced as a whole on every change.
    public private(set) var state: PlaybackQueueState {
        didSet {
            let now = state.currentSong
            if now != currentSong { currentSong = now }
        }
    }

    /// The playing row, the same as `state.currentSong` but observed on its own: every visible list
    /// row asks whether it is the one playing, and reading that through ``state`` re-rendered them
    /// all on any queue edit, an append or a reorder far down the list included.
    public private(set) var currentSong: Song?

    /// The Listen Together party this device is in, if any. The app keeps it current.
    public var party: AutoplayPartyContext = .solo {
        didSet { partyDidChange(from: oldValue) }
    }

    /// The localised generic source name ("Queue") for entries with no page of their own.
    public var queueLabel = "Queue"

    /// The engine's hook: load and play (or not) the entry named. See ``QueueItemChange``.
    @ObservationIgnored public var onCurrentItemChange: (@MainActor (QueueItemChange) -> Void)?

    /// Called for every queue edit the user asked for, so a party can publish it (Android's
    /// `onUserIntent`). Programmatic edits and AutoPlay's own appends don't call it.
    @ObservationIgnored public var onLocalIntent: (@MainActor () -> Void)?

    /// In a party, AutoPlay's tracks go to the party rather than straight into this queue: the
    /// server's state broadcast then reconciles every device, this one included, so the AutoPlay
    /// section is identical for all listeners. Return true once the party's queue shows the tracks
    /// (Android waits up to ``AutoplayPolicy/partyQueueEchoTimeout``); false means refused, and the
    /// seed is released so AutoPlay can try again.
    @ObservationIgnored public var partyAutoplaySupplier: (@MainActor ([Song]) async -> Bool)?

    /// In a party the AutoPlay switch is the party's: this forwards a toggle to it.
    @ObservationIgnored public var partyAutoplayToggle: (@MainActor (Bool) -> Void)?

    public let settings: AppSettings
    public let sleepTimer: SleepTimer?
    private let lastPlayed: LastPlayedStore?
    private let partyStash: PartyPersonalQueueStash?
    private let autoplayLoader: AutoplayLoader?

    // Test seams.
    @ObservationIgnored var shuffler: QueueShuffle.Shuffler = QueueShuffle.randomShuffler
    @ObservationIgnored var autoplayEmptyRefreshDelay: Duration = AutoplayPolicy.emptyRefreshDelay

    /// Entry ids in their pre-shuffle order. Empty while shuffle is off.
    @ObservationIgnored private var shuffleOriginal: [String] = []
    /// Index in the live queue that entry zero of the persisted window stands for.
    @ObservationIgnored private var persistedQueueStart = 0
    @ObservationIgnored private var playheadMs: Int64 = 0
    @ObservationIgnored private var isPlaying = false
    /// The last track finished with nothing after it. Tracks appended now play on by themselves.
    @ObservationIgnored private var queueEnded = false
    /// Invalidates an in-flight "Start radio" when a later play request wins.
    @ObservationIgnored private var playRequestGeneration = 0

    @ObservationIgnored private var autoplayTask: Task<Void, Never>?
    @ObservationIgnored private var autoplayGeneration = 0
    @ObservationIgnored private var autoplayLoading = false
    /// The track AutoPlay last loaded for, so the several callbacks one edit causes load once.
    @ObservationIgnored private var autoplaySeed: String?
    /// What AutoPlay had queued when repeat-all was switched on, and the track it followed.
    ///
    /// Repeat-all loops the queue as it stands, so AutoPlay's endless supply of new tracks comes out
    /// of it first. Fetching a replacement mix when repeat goes off again is the obvious thing and
    /// the wrong one: the track queued next has usually been analysed for the transition into it by
    /// then, and a different track there spends that analysis again. Turning repeat on and back off
    /// should leave the queue where it found it.
    @ObservationIgnored private var repeatAllStash: [Song] = []
    @ObservationIgnored private var repeatAllStashSeed: String?
    /// Every song AutoPlay has offered or played this session, for "Don't repeat suggestions" once
    /// a song scrolls out of the live queue. Never persisted: a fresh launch is a fresh session.
    @ObservationIgnored private var sessionSongHistory: [Song] = []

    /// - Parameters:
    ///   - settings: shuffle, repeat and AutoPlay are read from and written back to it.
    ///   - lastPlayed: the restart snapshot; nil keeps nothing across launches.
    ///   - partyStash: the personal queue put aside during a party.
    ///   - radioSource: where AutoPlay and "Start radio" get related songs; nil disables both.
    ///   - sleepTimer: consulted when a track finishes ("end of this track").
    public init(
        settings: AppSettings,
        lastPlayed: LastPlayedStore? = nil,
        partyStash: PartyPersonalQueueStash? = nil,
        radioSource: (any AutoplayRadioSource)? = nil,
        sleepTimer: SleepTimer? = nil
    ) {
        self.settings = settings
        self.lastPlayed = lastPlayed
        self.partyStash = partyStash
        self.autoplayLoader = radioSource.map(AutoplayLoader.init(source:))
        self.sleepTimer = sleepTimer
        // Shuffle and repeat are restored from settings on launch; the queue itself by restore().
        state = PlaybackQueueState(repeatMode: settings.repeatMode, shuffleEnabled: settings.shuffleEnabled)
    }

    // MARK: - Derived

    /// Whether AutoPlay is on for what this device plays: the party's switch in a party, the
    /// user's own otherwise. What the toggle should draw.
    public var isAutoplayEnabled: Bool {
        AutoplayPolicy.isEnabled(party: party, localPreference: settings.autoplay)
    }

    /// Whether queue edits are refused because the party's host holds control.
    public var controlsLocked: Bool { party.controlsLocked }

    /// Where "Playing from" goes back to for the playing entry.
    public var playingFrom: QueueSource? {
        state.currentSong.map { QueueSource.playingFrom($0, queueLabel: queueLabel) }
    }

    // MARK: - Launch

    /// Installs the queue from the last run, paused at its saved position: a personal queue stashed
    /// for a party that never ended (the app was killed mid-party) wins over the ordinary restart
    /// snapshot. Returns whether anything was restored. No stream is resolved here; the engine
    /// receives a ``QueueItemChange`` with reason ``QueueItemChange/Reason/restored``.
    @discardableResult
    public func restore() -> Bool {
        if let partyStash, partyStash.hasStash() {
            let stashed = partyStash.load()
            partyStash.clear()
            if let stashed, !stashed.songs.isEmpty {
                persistedQueueStart = 0
                install(stashed.songs, startIndex: stashed.index, positionMs: stashed.positionMs, reason: .restored, playback: .pause)
                return true
            }
        }
        guard let snapshot = lastPlayed?.load() else { return false }
        persistedQueueStart = 0
        install(snapshot.songs, startIndex: snapshot.index, positionMs: snapshot.positionMs, reason: .restored, playback: .pause)
        return true
    }

    // MARK: - Starting queues (user intents)

    /// Plays `songs` (an album, playlist, artist's songs, history…) from `index`.
    ///
    /// Outside a party: the list becomes the context — the tapped track plays, the tracks before it
    /// sit in history, the tracks after it follow — and whatever the user queued by hand is kept
    /// right after the tapped track. In a party: only the tapped track, followed by the party's own
    /// manual queue; the list around it is not pushed on everyone else.
    @discardableResult
    public func playFrom(_ songs: [Song], index: Int, source: QueueSource) -> QueueEditResult {
        playRequestGeneration += 1
        guard !controlsLocked else { return .refusedByHost }
        let fresh = songs.map(\.freshEntry)
        if party.inParty {
            guard fresh.indices.contains(index) else { return .ignored }
            let timeline = QueueCoordinator.buildPartyPlaybackQueue(
                tappedSong: fresh[index],
                source: source,
                upcomingPartyTracks: party.upcomingTracks
            )
            return playSongs(timeline, startIndex: 0)
        }
        let result = QueueCoordinator.buildContextQueue(
            currentTimeline: state.songs,
            currentIndex: state.currentIndex,
            newContextSongs: fresh,
            selectedIndex: index,
            contextSource: source
        )
        return playSongs(result.timeline, startIndex: result.startIndex)
    }

    /// ``playFrom(_:index:source:)`` for entry points whose rows already carry their origin: the
    /// tapped row's source, else its album, else ``queueLabel``.
    @discardableResult
    public func play(_ songs: [Song], index: Int) -> QueueEditResult {
        let tapped = songs.indices.contains(index) ? songs[index] : nil
        return playFrom(songs, index: index, source: .inferred(from: tapped, queueLabel: queueLabel))
    }

    /// Plays a song picked on its own — a home card, a search hit, a shared link — as a one-off:
    /// it plays, the user's own queue follows, and AutoPlay carries on from it. Searching "Perfect"
    /// and tapping the top hit would otherwise queue twenty covers of the same song.
    @discardableResult
    public func playSong(_ song: Song, source: QueueSource) -> QueueEditResult {
        playRequestGeneration += 1
        guard !controlsLocked else { return .refusedByHost }
        let queue = QueueCoordinator.buildOneOffQueue(
            currentTimeline: state.songs,
            currentIndex: state.currentIndex,
            tappedSong: song.freshEntry,
            source: source
        )
        return playSongs(queue, startIndex: 0)
    }

    /// Replaces the queue with `songs` and starts playing (PlayerConnection's `playSongs`).
    ///
    /// A queue started while shuffle is on goes in shuffled rather than being played out of order:
    /// the track at `startIndex` still leads, so it ends up at the top.
    @discardableResult
    public func playSongs(_ songs: [Song], startIndex: Int) -> QueueEditResult {
        guard !songs.isEmpty else { return .ignored }
        guard !controlsLocked else { return .refusedByHost }
        // A queue started directly (not through playFrom) still outranks a station still loading.
        playRequestGeneration += 1
        let shuffled = state.shuffleEnabled
        // Entry ids first: the pre-shuffle order is remembered by them, so ids handed out later (by
        // install) would match nothing in it and turning shuffle off would restore nothing.
        var queue = songs.map(\.withEntryId)
        if shuffled {
            let ordered = QueueShuffle.startingOrder(queue, startIndex: startIndex, shuffler: shuffler)
            queue = ordered.queue
            shuffleOriginal = ordered.original
        }
        onLocalIntent?()
        let start = QueueShuffle.queueStartIndex(requestedIndex: startIndex, itemCount: queue.count, shuffled: shuffled)
        install(queue, startIndex: start, positionMs: 0, reason: .newQueue, playback: .play)
        return .done
    }

    /// Turns shuffle on without touching the current queue — the Shuffle button on an album or
    /// playlist page, where the queue it applies to is the one about to replace this one. Call
    /// ``playFrom(_:index:source:)`` (with a random index) right after; that queue is built shuffled.
    public func enableShuffleForNextQueue() {
        shuffleOriginal = []
        state.shuffleEnabled = true
        settings.shuffleEnabled = true
    }

    // MARK: - Stations

    /// "Start radio" from a song's menu: replaces the queue with YouTube Music's radio for `song`.
    ///
    /// The station loads before the queue is touched, so a failed request can't destroy the queue
    /// already playing; and a play request or a hand-made queue change that lands meanwhile wins
    /// (``RadioStartResult/superseded``). AutoPlay's own growth meanwhile doesn't count as a change.
    /// If `song` is the one playing, it carries on uninterrupted and the station is built around it.
    /// The new queue is written to disk before this returns, so a relaunch never brings back the
    /// queue from before the station.
    public func startRadio(from song: Song) async -> RadioStartResult {
        guard let autoplayLoader, song.canStartStation else { return .unavailable }
        guard !controlsLocked else { return .refusedByHost }
        playRequestGeneration += 1
        let request = playRequestGeneration
        let originalManualQueue = manualQueueIds()

        var seed = song.freshEntry
        seed.radioName = song.title
        seed.playbackSource = song.title
        seed.playbackSourceType = .sharedLink
        seed.playbackSourceId = song.videoId

        let related: [Song]
        do {
            related = try await autoplayLoader.loadTracks(existing: [seed], seedSong: seed, limit: AutoplayLoader.initialStationTracks)
        } catch {
            DebugLog.w("PlaybackQueue", "radio for \(song.videoId) failed", error: error)
            return request == playRequestGeneration ? .failed : .superseded
        }
        guard !related.isEmpty else { return request == playRequestGeneration ? .failed : .superseded }
        guard request == playRequestGeneration, manualQueueIds() == originalManualQueue else { return .superseded }
        guard !controlsLocked else { return .refusedByHost }

        beginRadioQueue()
        if let current = state.currentSong, current.videoId == song.videoId {
            onLocalIntent?()
            // The playing entry itself stays, so the track carries on where it is. Android can't
            // relabel a live MediaItem without restarting it and draws the station name from a
            // UI-side overlay instead; this model can, so the entry is relabelled in place.
            var kept = current
            kept.radioName = seed.radioName
            kept.playbackSource = seed.playbackSource
            kept.playbackSourceType = seed.playbackSourceType
            kept.playbackSourceId = seed.playbackSourceId
            commit([kept] + related, currentIndex: 0)
        } else {
            playSongs([seed.asQueueEntry(.context)] + related, startIndex: 0)
        }
        commitRadioQueue()
        return .started(name: song.title)
    }

    /// Starts a station from the playing track, keeping it playing (CarPlay's and Android Auto's
    /// "Start radio" for the current track). Like ``startRadio(from:)`` but seeded on what is
    /// playing, and a system action rather than a party-visible edit.
    public func startStationFromCurrentTrack() async -> RadioStartResult {
        guard let autoplayLoader, let current = state.currentSong, current.canStartStation else { return .unavailable }
        guard !controlsLocked else { return .refusedByHost }
        let originalManualQueue = manualQueueIds()
        var seed = current
        seed.radioName = current.title

        let related: [Song]
        do {
            related = try await autoplayLoader.loadTracks(existing: [seed], seedSong: seed, limit: AutoplayLoader.initialStationTracks)
        } catch {
            TrackLog.w("PlaybackQueue", "station failed", error: error, about: current.videoId)
            return .failed
        }
        guard !related.isEmpty else { return .failed }
        guard let active = state.currentSong, active.queueEntryId == current.queueEntryId,
              manualQueueIds() == originalManualQueue else { return .superseded }
        guard !controlsLocked else { return .refusedByHost }

        beginRadioQueue()
        var kept = active
        kept.radioName = seed.radioName
        commit([kept] + related, currentIndex: 0)
        commitRadioQueue()
        return .started(name: current.title)
    }

    // MARK: - Adding (user intents)

    /// "Play next": straight after the playing track, ahead of anything else queued.
    @discardableResult
    public func playNext(_ song: Song) -> QueueEditResult {
        queue([song], next: true, startIfEmpty: false)
    }

    /// "Add to queue": after everything else the user queued, but ahead of the album and AutoPlay.
    @discardableResult
    public func addToQueue(_ song: Song) -> QueueEditResult {
        queue([song], next: false, startIfEmpty: false)
    }

    /// A whole album, playlist or library list onto the queue in one go, at "play next" or
    /// "add to queue". The list keeps its own running order: this adds a release, it doesn't start
    /// one, so shuffle has no say. On an empty queue it starts playing the list instead — adding
    /// without playing would leave the list sitting in a player that never gets round to it.
    @discardableResult
    public func queueSongs(_ songs: [Song], next: Bool) -> QueueEditResult {
        queue(songs, next: next, startIfEmpty: true)
    }

    /// A swipe on a song row: "play next" or "add to queue", per the user's setting.
    @discardableResult
    public func queueFromSwipe(_ song: Song) -> QueueEditResult {
        settings.swipeToPlayNext ? playNext(song) : addToQueue(song)
    }

    private func queue(_ songs: [Song], next: Bool, startIfEmpty: Bool) -> QueueEditResult {
        guard !songs.isEmpty else { return .ignored }
        guard !controlsLocked else { return .refusedByHost }
        if startIfEmpty, state.isEmpty {
            return play(songs, index: 0)
        }
        var toAdd = songs
        if party.inParty {
            let slots = AutoplayPolicy.maxPartyUpcoming - state.upcomingCount
            guard slots > 0 else { return .partyQueueFull(limit: AutoplayPolicy.maxPartyUpcoming) }
            // A single song is refused outright rather than trimmed; a list takes what fits.
            toAdd = Array(songs.prefix(slots))
        }
        let current = state.currentSong
        let at = QueueCoordinator.findUserQueueInsertionIndex(timeline: state.songs, currentIndex: state.currentIndex, isNext: next)
        let entries = toAdd.map { song -> Song in
            // Queued under the playing entry's station and source, so "Playing from" keeps naming
            // what the listener is in the middle of.
            var queued = song.freshEntry
            queued.radioName = current?.radioName
            queued.playbackSource = current?.playbackSource ?? queueLabel
            queued.playbackSourceType = current?.playbackSourceType ?? .queue
            queued.playbackSourceId = current?.playbackSourceId
            return queued.asQueueEntry(.userQueue)
        }
        onLocalIntent?()
        insertItems(entries, at: at)
        return .added(count: entries.count)
    }

    // MARK: - Editing (user intents)

    /// A tap on queue row `index`. A later row plays now: rows it jumped over within the manual
    /// queue are consumed, a row from the album or AutoPlay starts from there (see
    /// ``QueueCoordinator/buildJumpQueue(currentTimeline:currentIndex:targetIndex:)``), and history
    /// is kept. An earlier row, or the playing one, is a seek within the queue as it stands.
    @discardableResult
    public func jump(to index: Int) -> QueueEditResult {
        guard !controlsLocked else { return .refusedByHost }
        guard let plan = QueueCoordinator.jumpPlan(timeline: state.songs, currentIndex: state.currentIndex, targetIndex: index) else {
            return .ignored
        }
        onLocalIntent?()
        commit(plan.timeline, currentIndex: plan.startIndex, change: .init(reason: .jump, playback: .play, force: true))
        return .done
    }

    /// A queue row chosen from a system surface (CarPlay's Up Next). See
    /// ``QueueCoordinator/systemSeekPlan(timeline:currentIndex:targetIndex:)``.
    @discardableResult
    public func seekToItemFromSystem(_ index: Int) -> QueueEditResult {
        guard !controlsLocked else { return .refusedByHost }
        guard let plan = QueueCoordinator.systemSeekPlan(timeline: state.songs, currentIndex: state.currentIndex, targetIndex: index) else {
            return .ignored
        }
        onLocalIntent?()
        commit(plan.timeline, currentIndex: plan.startIndex, change: .init(reason: .jump, playback: .keep, force: true))
        return .done
    }

    /// Removes queue row `index`. Removing the playing row moves on to the next one.
    @discardableResult
    public func removeFromQueue(at index: Int) -> QueueEditResult {
        guard !controlsLocked else { return .refusedByHost }
        guard state.songs.indices.contains(index) else { return .ignored }
        onLocalIntent?()
        removeItems(in: index..<(index + 1))
        return .done
    }

    /// Drags queue row `from` to where row `to` is. Only within its own section: the user queue,
    /// the album or AutoPlay; the playing row doesn't move. Call once per neighbour crossed, as the
    /// row crosses it.
    @discardableResult
    public func moveInQueue(from: Int, to: Int) -> QueueEditResult {
        guard !controlsLocked else { return .refusedByHost }
        guard state.sections.canMove(from: from, to: to) else { return .ignored }
        onLocalIntent?()
        moveItem(from: from, to: to)
        return .done
    }

    /// "Clear": drops the tracks the user queued by hand. What's playing, the album and AutoPlay stay.
    @discardableResult
    public func clearUserQueue() -> QueueEditResult {
        guard !controlsLocked else { return .refusedByHost }
        let indices = QueueCoordinator.userQueueIndicesToClear(timeline: state.songs, currentIndex: state.currentIndex)
        guard !indices.isEmpty else { return .ignored }
        onLocalIntent?()
        var songs = state.songs
        for index in indices.reversed() { songs.remove(at: index) }
        commit(songs, currentIndex: state.currentIndex)
        return .done
    }

    /// "Next" (the button, the lock screen, a headset, CarPlay). Repeat-all wraps to the top.
    @discardableResult
    public func skipToNext() -> QueueEditResult {
        guard !controlsLocked else { return .refusedByHost }
        guard let next = state.nextIndex else { return .ignored }
        onLocalIntent?()
        commit(state.songs, currentIndex: next, change: .init(reason: .skipNext, playback: .keep, force: true))
        return .done
    }

    /// "Previous": back to the previous track within the first ``restartThresholdMs`` of a track,
    /// otherwise back to the start of this one.
    ///
    /// - Parameter positionMs: the engine's playhead right now. Pass it: the decision is only as
    ///   good as the playhead it is made on, and without it the controller falls back to the last
    ///   ``recordPlayhead(positionMs:isPlaying:)``, which a 5 s progress loop can leave seconds
    ///   behind (Android's `seekToPrevious` reads the player's own position).
    @discardableResult
    public func skipToPrevious(positionMs: Int64? = nil) -> QueueEditResult {
        guard !controlsLocked else { return .refusedByHost }
        guard let current = state.currentSong else { return .ignored }
        onLocalIntent?()
        if let positionMs { playheadMs = max(positionMs, 0) }
        if let previous = state.previousIndex, playheadMs <= Self.restartThresholdMs {
            commit(state.songs, currentIndex: previous, change: .init(reason: .skipPrevious, playback: .keep, force: true))
        } else {
            playheadMs = 0
            // Playing again, so no longer a queue that ran out: AutoPlay tracks arriving now queue up
            // behind this track instead of cutting it off (a player that restarts its last track
            // leaves the ended state the same way).
            queueEnded = false
            onCurrentItemChange?(QueueItemChange(song: current, index: state.currentIndex, startPositionMs: 0, reason: .restartCurrent, playback: .keep))
            savePlaybackState()
        }
        return .done
    }

    /// Past this point in a track, "previous" restarts it instead of going to the previous one.
    public static let restartThresholdMs: Int64 = 10_000

    /// Call after toggling dislike on `videoId` (with the status before the toggle): disliking the
    /// song that's playing skips it. See ``DislikeSkipPolicy``.
    @discardableResult
    public func dislikeToggled(previousStatus: LikeStatus, videoId: String) -> Bool {
        guard DislikeSkipPolicy.shouldSkip(previousStatus: previousStatus, targetVideoId: videoId, currentVideoId: state.currentSong?.videoId) else {
            return false
        }
        return skipToNext() == .done
    }

    // MARK: - Modes

    /// The shuffle button. On: everything after the playing track is rearranged (the user queue
    /// stays put at the front; the album and AutoPlay shuffle within themselves). Off: the tracks
    /// still to come go back to the order they were queued in, and tracks queued since trail
    /// behind. The state persists in settings.
    public func toggleShuffle() {
        if state.shuffleEnabled { restoreUnshuffledOrder() } else { shuffleUpcoming() }
        settings.shuffleEnabled = state.shuffleEnabled
    }

    /// Off → all → one → off, persisted.
    public func cycleRepeatMode() {
        switch state.repeatMode {
        case .off: setRepeatMode(.all)
        case .all: setRepeatMode(.one)
        case .one: setRepeatMode(.off)
        }
    }

    /// Sets the repeat mode and persists it.
    ///
    /// Repeat-all loops the queue as it stands; AutoPlay's tracks are the opposite of that — an
    /// endless supply of new ones — so they come out while it is on, and go back in when it ends,
    /// or a listener who cycles repeat on and straight back off would be left with a queue that
    /// simply stops after the playing track.
    public func setRepeatMode(_ mode: RepeatMode) {
        let previous = state.repeatMode
        settings.repeatMode = mode
        guard mode != previous else { return }
        state.repeatMode = mode
        if mode == .all {
            stashAutoplayTracks()
        } else if previous == .all {
            restoreAutoplayTracks()
        }
        // Leaving repeat-all can leave the playing track at the end of the queue.
        loadAutoplayForCurrentTrack()
    }

    /// The AutoPlay button. In a party it flips the party's switch; otherwise the user's own, and
    /// switching it off takes back what AutoPlay queued and hasn't played yet.
    public func toggleAutoplay() {
        let enabled = party.inParty ? !party.partyAutoplayEnabled : !settings.autoplay
        settings.autoplay = enabled
        if party.inParty {
            // The party owns the setting while connected; its state frame wakes whichever member
            // won the supplier election.
            partyAutoplayToggle?(enabled)
            return
        }
        cancelAutoplayLoad()
        if enabled {
            loadAutoplayForCurrentTrack()
        } else {
            _ = dropAutoplayTracks()
            // Switching AutoPlay off is the listener saying they don't want those tracks; a stash
            // left behind would put them back the next time repeat-all ended.
            repeatAllStash = []
            repeatAllStashSeed = nil
        }
    }

    // MARK: - Engine hooks

    /// The playing track finished by itself. Moves the queue on per the repeat mode and reports the
    /// new entry through ``onCurrentItemChange``. If the sleep timer was set to "end of this track",
    /// the next entry is loaded paused and the timer is spent.
    @discardableResult
    public func trackDidFinish() -> TrackFinishOutcome {
        guard let current = state.currentSong else { return .ended }
        guard let target = state.finishTargetIndex else {
            // Nothing follows, so there is no transition to pause on: the queue simply runs out and
            // the timer is spent. A missed AutoPlay response can let the last track finish before
            // anything was appended; with no transition to run the ordinary refill, try again here.
            //
            // Tracks that arrive now play on by themselves — unless the listener asked to stop after
            // this very track. Android spends the timer here and then plays on regardless when
            // AutoPlay's late batch lands; the batch still queues, it just waits for them.
            let sleepAfterThisTrack = sleepTimer?.consumeAfterTrack() ?? false
            queueEnded = !sleepAfterThisTrack
            sleepTimer?.cancel()
            refreshAutoplayIfQueueEmpty()
            return .ended
        }
        // REPEAT counts too, or "end of this track" would never fire with repeat-one on.
        let pause = sleepTimer?.consumeAfterTrack() ?? false
        let repeats = state.songs[target].queueEntryId == current.queueEntryId
        commit(state.songs, currentIndex: target, change: .init(
            reason: repeats ? .repeatCurrent : .autoAdvance,
            playback: pause ? .pause : .keep,
            force: true
        ))
        return repeats ? .repeated : .advanced(index: state.currentIndex)
    }

    /// The engine's playhead and play state. Persisted as the restart position (a cheap write that
    /// never touches the song list, but still a file write): call it from a slow progress loop —
    /// Android samples every 5 s — and on pause and seek, not from the scrubber's own ticker.
    public func recordPlayhead(positionMs: Int64, isPlaying: Bool) {
        playheadMs = max(positionMs, 0)
        self.isPlaying = isPlaying
        savePlaybackState()
    }

    /// Records the playhead and waits until the restart snapshot is on disk.
    ///
    /// Ordinary saves are asynchronous, like SharedPreferences' `apply()`. Android flushes those when
    /// its service stops; iOS gives no such guarantee — a suspended app can be killed with the write
    /// still queued — so the app calls this when it moves to the background and before it
    /// terminates.
    public func flushPersistence(positionMs: Int64? = nil, isPlaying: Bool? = nil) {
        if let positionMs { playheadMs = max(positionMs, 0) }
        if let isPlaying { self.isPlaying = isPlaying }
        savePlaybackState()
        lastPlayed?.flush()
    }

    // MARK: - Listen Together

    /// Puts the personal queue aside on joining a party. Returns whether anything was stashed.
    ///
    /// Call it before the party's queue is installed (it stashes ``state`` as it stands), and before
    /// or after setting ``party`` — the stash doesn't depend on it. Pass the engine's playhead and
    /// play state as they are now; without them the last ``recordPlayhead(positionMs:isPlaying:)``
    /// is stashed.
    @discardableResult
    public func stashPersonalQueueForParty(positionMs: Int64? = nil, isPlaying: Bool? = nil) -> Bool {
        guard let partyStash else { return false }
        if let positionMs { playheadMs = max(positionMs, 0) }
        if let isPlaying { self.isPlaying = isPlaying }
        return partyStash.stash(
            queue: state.songs,
            currentIndex: state.currentIndex,
            positionMs: playheadMs,
            wasPlaying: self.isPlaying,
            lastPlayed: lastPlayed
        )
    }

    /// Gives the personal queue back on leaving a party, playing or paused as it was when stashed.
    /// Returns whether there was one.
    ///
    /// Set ``party`` back to ``AutoplayPartyContext/solo`` first: the restart snapshot is not written
    /// while in a party, and the returning personal queue should become it again.
    @discardableResult
    public func restorePersonalQueueAfterParty() -> Bool {
        guard let partyStash, let stashed = partyStash.load() else { return false }
        install(stashed.songs, startIndex: stashed.index, positionMs: stashed.positionMs, reason: .newQueue, playback: stashed.wasPlaying ? .play : .pause)
        partyStash.clear()
        return true
    }

    // MARK: - Programmatic edits

    /// Replaces the whole queue and loads `startIndex` (Media3's `setMediaItems`).
    public func setItems(_ songs: [Song], startIndex: Int, startPositionMs: Int64 = 0, playback: QueueItemChange.Playback = .keep) {
        install(songs, startIndex: startIndex, positionMs: startPositionMs, reason: .newQueue, playback: playback)
    }

    /// Inserts `songs` at `index` (clamped). Inserting at or before the playing entry pushes it down;
    /// the playing entry itself never changes, except that an empty queue starts at the first new one.
    public func insertItems(_ songs: [Song], at index: Int) {
        guard !songs.isEmpty else { return }
        let at = min(max(index, 0), state.songs.count)
        var timeline = state.songs
        timeline.insert(contentsOf: songs.map(\.withEntryId), at: at)
        if state.isEmpty {
            commit(timeline, currentIndex: 0, change: .init(reason: .queueEdit, playback: .keep, force: true))
            return
        }
        var current = state.currentIndex
        if at <= current { current += songs.count }
        commit(timeline, currentIndex: current)
        resumeIfEnded()
    }

    /// Appends `songs` to the end of the queue.
    public func appendItems(_ songs: [Song]) {
        insertItems(songs, at: state.songs.count)
    }

    /// Removes the entries in `range` (clamped). Removing the playing entry moves on to the one that
    /// followed it; if none did, repeat-all wraps to the top and otherwise the queue stops at its first
    /// entry.
    public func removeItems(in range: Range<Int>) {
        let bounds = range.clamped(to: 0..<state.songs.count)
        guard !bounds.isEmpty else { return }
        var timeline = state.songs
        timeline.removeSubrange(bounds)
        let current = state.currentIndex
        if current < bounds.lowerBound {
            commit(timeline, currentIndex: current)
        } else if current >= bounds.upperBound {
            commit(timeline, currentIndex: current - bounds.count)
        } else {
            replacePlayingEntry(timeline, from: bounds.lowerBound)
        }
    }

    /// Moves the entry at `from` to `to` (Media3's `moveMediaItem`); the playing entry keeps playing.
    public func moveItem(from: Int, to: Int) {
        guard state.songs.indices.contains(from), state.songs.indices.contains(to), from != to else { return }
        var timeline = state.songs
        let moved = timeline.remove(at: from)
        timeline.insert(moved, at: to)
        var current = state.currentIndex
        if from == current {
            current = to
        } else if from < current, to >= current {
            current -= 1
        } else if from > current, to <= current {
            current += 1
        }
        commit(timeline, currentIndex: current)
    }

    /// Replaces the entries in `range` with `songs` (Media3's `replaceMediaItems`). The playing entry
    /// keeps playing if it is among `songs` (matched by ``Song/queueEntryId``); otherwise this acts
    /// as a removal of it. So a quality upgrade or version swap of the playing track keeps the
    /// entry's id, and no ``QueueItemChange`` is reported for it.
    public func replaceItems(in range: Range<Int>, with songs: [Song]) {
        let bounds = range.clamped(to: 0..<state.songs.count)
        let replacement = songs.map(\.withEntryId)
        var timeline = state.songs
        timeline.replaceSubrange(bounds, with: replacement)
        let current = state.currentIndex
        if current < bounds.lowerBound || state.isEmpty {
            commit(timeline, currentIndex: state.isEmpty ? 0 : current, change: state.isEmpty ? .init(reason: .queueEdit, playback: .keep, force: true) : nil)
        } else if current >= bounds.upperBound {
            commit(timeline, currentIndex: current + replacement.count - bounds.count)
        } else if let entry = state.currentSong?.queueEntryId,
                  let found = replacement.firstIndex(where: { $0.queueEntryId == entry }) {
            commit(timeline, currentIndex: bounds.lowerBound + found)
        } else {
            replacePlayingEntry(timeline, from: bounds.lowerBound)
        }
    }

    /// Makes `index` the playing entry at `positionMs`, keeping the play state (Media3's
    /// `seekTo(index, position)` on the player itself). The engine's own moves go through here —
    /// skipping past an unplayable track to ``PlaybackQueueState/nextIndex`` (Android's
    /// `skipPastUnplayable`), or replaying a queue that ran out — since they are neither refused in
    /// a locked party nor reported as the user's.
    public func seek(toItem index: Int, positionMs: Int64 = 0) {
        guard state.songs.indices.contains(index) else { return }
        commit(state.songs, currentIndex: index, change: .init(reason: .jump, playback: .keep, force: true, positionMs: positionMs))
    }

    // MARK: - Core

    private struct ChangeRequest {
        var reason: QueueItemChange.Reason
        var playback: QueueItemChange.Playback
        /// Report the change even when the same entry stays current (a replay, a seek to it).
        var force: Bool
        var positionMs: Int64 = 0
    }

    private func install(_ songs: [Song], startIndex: Int, positionMs: Int64, reason: QueueItemChange.Reason, playback: QueueItemChange.Playback) {
        let timeline = songs.map(\.withEntryId)
        let start = timeline.isEmpty ? 0 : min(max(startIndex, 0), timeline.count - 1)
        commit(timeline, currentIndex: start, change: .init(reason: reason, playback: playback, force: true, positionMs: positionMs))
    }

    /// The playing entry was removed; `timeline` no longer has it. What took its place plays on, as
    /// Media3 resolves the "subsequent period".
    private func replacePlayingEntry(_ timeline: [Song], from lowerBound: Int) {
        if timeline.isEmpty {
            commit([], currentIndex: 0, change: .init(reason: .queueEdit, playback: .pause, force: true))
        } else if lowerBound < timeline.count {
            commit(timeline, currentIndex: lowerBound, change: .init(reason: .queueEdit, playback: .keep, force: true))
        } else if state.repeatMode == .all {
            commit(timeline, currentIndex: 0, change: .init(reason: .queueEdit, playback: .keep, force: true))
        } else {
            commit(timeline, currentIndex: 0, change: .init(reason: .queueEdit, playback: .pause, force: true))
            queueEnded = true
        }
    }

    /// Publishes a new timeline. When the playing entry changes (or `change.force`), runs the
    /// transition bookkeeping and tells the engine; then persists and re-checks AutoPlay.
    private func commit(_ songs: [Song], currentIndex: Int, change: ChangeRequest? = nil) {
        let previousEntry = state.currentSong?.queueEntryId
        let clampedIndex = songs.isEmpty ? 0 : min(max(currentIndex, 0), songs.count - 1)
        var next = state
        next.songs = songs
        next.currentIndex = clampedIndex
        let newEntry = next.currentSong?.queueEntryId
        let entryChanged = previousEntry != newEntry || (next.isEmpty != state.isEmpty)

        guard entryChanged || change?.force == true else {
            state = next
            timelineDidChange()
            return
        }

        queueEnded = false
        if !next.isEmpty { applyTransitionBookkeeping(&next) }
        state = next
        let request = change ?? ChangeRequest(reason: .queueEdit, playback: .keep, force: false)
        playheadMs = request.positionMs
        onCurrentItemChange?(QueueItemChange(
            song: state.currentSong,
            index: state.currentIndex,
            startPositionMs: request.positionMs,
            reason: request.reason,
            playback: next.isEmpty ? .pause : request.playback
        ))
        // A different track is a fresh start for AutoPlay: it tops the queue back up to its ten
        // suggestions on every transition, so a freshly played suggestion is replaced by a new one
        // appended after those still waiting, instead of everything arriving at once at the end.
        cancelAutoplayLoad()
        loadAutoplayForCurrentTrack()
        timelineDidChange()
        savePlaybackState()
    }

    /// What the service did on every transition: bounded history, then consumed user-queue entries.
    private func applyTransitionBookkeeping(_ next: inout PlaybackQueueState) {
        // A real, bounded history rather than old rows merely hidden: see QueueHistory.maxEntries.
        let expired = QueueHistory.trimCount(currentIndex: next.currentIndex)
        if expired > 0 {
            let head = next.songs[..<expired]
            next.songs.removeFirst(expired)
            if next.repeatMode == .all {
                // Repeat-all still means the whole queue: history that has fallen out of the window
                // rotates to the end instead of being deleted, so it becomes upcoming again in the
                // same order and the loop can go on indefinitely.
                next.songs.append(contentsOf: head)
            }
            next.currentIndex -= expired
        }
        // Once playback is in the album, the user-queue entries played on the way are gone, so
        // repeat-all only ever loops the album.
        let played = QueueCoordinator.playedUserQueueIndices(timeline: next.songs, currentIndex: next.currentIndex)
        for index in played.reversed() { next.songs.remove(at: index) }
        next.currentIndex -= played.count
    }

    /// Every timeline change: the restart snapshot, and AutoPlay's empty-tail check.
    private func timelineDidChange() {
        saveQueueSnapshot()
        // Queue edits can remove AutoPlay's whole tail while leaving its old seed memoized; detect
        // that state at its source and make the current track eligible for a fresh load.
        refreshAutoplayIfQueueEmpty()
    }

    /// The queue ran out and something was added after it: play on, as the player would.
    private func resumeIfEnded() {
        guard queueEnded, state.currentIndex + 1 < state.songs.count else { return }
        commit(state.songs, currentIndex: state.currentIndex + 1, change: .init(reason: .autoAdvance, playback: .play, force: true))
    }

    private func manualQueueIds() -> [String] {
        state.songs.filter { !$0.fromAutoplay }.map(\.videoId)
    }

    // MARK: - Shuffle

    /// Rearranges everything after the playing track. That track keeps playing, and whatever sits
    /// above it stays there — those have had their turn.
    private func shuffleUpcoming() {
        shuffleOriginal = state.songs.map(\.shuffleIdentity)
        let from = state.currentIndex + 1
        let upcoming = Array(state.upcoming)
        state.shuffleEnabled = true
        guard !upcoming.isEmpty else { return }
        applyOrder(from: from, order: QueueShuffle.shuffledOrder(upcoming: upcoming, shuffler: shuffler))
    }

    /// Puts the tracks still to come back into the order they were queued in.
    private func restoreUnshuffledOrder() {
        let from = state.currentIndex + 1
        let upcoming = Array(state.upcoming)
        let original = shuffleOriginal
        shuffleOriginal = []
        state.shuffleEnabled = false
        guard !upcoming.isEmpty else { return }
        let restored = QueueShuffle.restoreOrder(upcoming: upcoming.map(\.shuffleIdentity), original: original)
        applyOrder(from: from, order: QueueShuffle.sectioned(restored, upcoming: upcoming))
    }

    /// Rearranges the queue from `from` onwards in one edit, `order` naming where each slot's new
    /// occupant stands now. Refused outright when the queue no longer has room for it, rather than
    /// applied as far as it goes, which would drop the tail from the queue.
    private func applyOrder(from: Int, order: [Int]) {
        guard !order.isEmpty, from >= 0, from + order.count <= state.songs.count else { return }
        var timeline = state.songs
        for (slot, source) in order.enumerated() {
            timeline[from + slot] = state.songs[from + source]
        }
        commit(timeline, currentIndex: state.currentIndex)
    }

    // MARK: - AutoPlay

    /// Tops the queue back up to ``AutoplayLoader/maxQueuedAutoplay`` suggestions ahead of the
    /// playing track.
    private func loadAutoplayForCurrentTrack() {
        guard autoplayLoader != nil, autoplayWanted() else { return }
        guard let current = state.currentSong else { return }
        if settings.dontRepeatSuggestions { sessionSongHistory.append(current) }
        let queued = state.upcoming.filter(\.fromAutoplay).count
        let needed = AutoplayLoader.maxQueuedAutoplay - queued
        guard needed > 0, autoplaySeed != current.videoId else { return }
        autoplaySeed = current.videoId
        autoplayGeneration += 1
        let generation = autoplayGeneration
        autoplayLoading = true
        autoplayTask = Task { [weak self] in
            await self?.runAutoplayLoad(for: current, needed: needed, generation: generation)
        }
    }

    private func runAutoplayLoad(for current: Song, needed: Int, generation: Int) async {
        defer {
            if autoplayGeneration == generation { autoplayLoading = false }
        }
        guard let autoplayLoader else { return }
        var remaining = needed
        var emptyRefreshesRemaining = AutoplayPolicy.maxEmptyRefreshes
        while !Task.isCancelled {
            guard autoplayWanted(), state.currentSong?.videoId == current.videoId else { return }
            let existing = settings.dontRepeatSuggestions ? state.songs + sessionSongHistory : state.songs
            var resolved: [Song] = []
            do {
                resolved = try await autoplayLoader.loadTracks(existing: existing, seedSong: current, limit: remaining)
            } catch {
                TrackLog.w("PlaybackQueue", "autoplay failed", error: error, about: current.videoId)
            }
            guard !Task.isCancelled, autoplayWanted(), state.currentSong?.videoId == current.videoId else { return }

            if !resolved.isEmpty {
                if party.inParty {
                    // Not into this queue directly: the party's broadcast reconciles every device,
                    // this one included. A party control is a request, not a write, and the server
                    // refuses some (a full queue, a party locked to another host); the party's own
                    // queue is the only confirmation, and a refusal must release the seed or AutoPlay
                    // sits visibly on and silently idle until the queue moves on.
                    let landed = await partyAutoplaySupplier?(resolved) ?? false
                    guard landed else {
                        TrackLog.w("PlaybackQueue", "party did not take AutoPlay's tracks; releasing the seed to retry", about: current.videoId)
                        if autoplayGeneration == generation { autoplaySeed = nil }
                        return
                    }
                } else {
                    appendItems(resolved)
                }
                if settings.dontRepeatSuggestions { sessionSongHistory += resolved }
                return
            }

            // An empty or failed response used to leave the seed latched to this track, with
            // AutoPlay visibly on and no queue. While the current track is genuinely the end of the
            // queue, make one delayed fresh request — bounded, so a radio with no usable songs
            // doesn't become permanent polling.
            let at = state.currentIndex
            guard at == state.songs.count - 1, emptyRefreshesRemaining > 0 else { return }
            emptyRefreshesRemaining -= 1
            do {
                try await Task.sleep(for: autoplayEmptyRefreshDelay)
            } catch {
                return
            }
            remaining = AutoplayLoader.maxQueuedAutoplay
        }
    }

    /// AutoPlay's preconditions: on, not under repeat-all, and — in a party — this device is the
    /// elected supplier.
    private func autoplayWanted() -> Bool {
        guard isAutoplayEnabled, state.repeatMode != .all else { return false }
        if party.inParty { return isElectedSupplier(party) }
        return true
    }

    /// Whether this device is the party's elected AutoPlay supplier. Both ids must be known:
    /// Android compares them as nullables, so a device that doesn't know its own member id yet
    /// (before the party's welcome frame) in a party that elected nobody counted itself elected —
    /// the opposite of "nil lets AutoPlay wait".
    private func isElectedSupplier(_ party: AutoplayPartyContext) -> Bool {
        guard let supplier = AutoplayPolicy.supplierId(party: party), let you = party.yourMemberId else { return false }
        return supplier == you
    }

    /// Re-arms AutoPlay when an edit exposes an empty tail.
    private func refreshAutoplayIfQueueEmpty() {
        guard AutoplayPolicy.queueNeedsRefresh(
            enabled: isAutoplayEnabled,
            repeatAll: state.repeatMode == .all,
            currentIndex: state.isEmpty ? -1 : state.currentIndex,
            itemCount: state.songs.count,
            loadInProgress: autoplayLoading
        ) else { return }
        autoplayTask = nil
        autoplaySeed = nil
        loadAutoplayForCurrentTrack()
    }

    private func cancelAutoplayLoad() {
        autoplayTask?.cancel()
        autoplayTask = nil
        autoplaySeed = nil
        autoplayLoading = false
        autoplayGeneration += 1
    }

    /// Takes back what AutoPlay queued and hasn't played yet, returned in queue order.
    private func dropAutoplayTracks() -> [Song] {
        let from = state.currentIndex + 1
        guard from < state.songs.count else { return [] }
        let dropped = state.songs[from...].filter(\.fromAutoplay)
        guard !dropped.isEmpty else { return [] }
        let kept = Array(state.songs[..<from]) + state.songs[from...].filter { !$0.fromAutoplay }
        commit(kept, currentIndex: state.currentIndex)
        return dropped
    }

    /// Clears the AutoPlay tail for the duration of repeat-all, keeping it to put back.
    private func stashAutoplayTracks() {
        // Taken once per stretch of repeat-all: cycling off → all → one → off sets the mode three
        // times, and the later ones must not overwrite a full stash with the empty tail the first left.
        guard repeatAllStash.isEmpty else { return }
        let dropped = dropAutoplayTracks()
        guard !dropped.isEmpty else { return }
        repeatAllStash = dropped
        repeatAllStashSeed = state.currentSong?.videoId
    }

    /// Puts the stashed AutoPlay tracks back when repeat-all ends — unless the stash no longer
    /// describes the queue (AutoPlay was switched off, or the loop played on past the track it was
    /// taken behind), in which case AutoPlay fills the queue the ordinary way.
    private func restoreAutoplayTracks() {
        let stashed = repeatAllStash
        let seed = repeatAllStashSeed
        repeatAllStash = []
        repeatAllStashSeed = nil
        // The seed is stale either way, so the queue can be topped up again for this track —
        // without this a refused stash left the queue with nothing after it at all.
        cancelAutoplayLoad()
        guard !stashed.isEmpty, isAutoplayEnabled, state.currentSong?.videoId == seed else { return }
        // A track queued by hand during the loop isn't queued twice for having been in the mix.
        let present = Set(state.songs.map(\.videoId))
        let restored = stashed.filter { !present.contains($0.videoId) }
        guard !restored.isEmpty else { return }
        appendItems(restored)
    }

    private func partyDidChange(from old: AutoplayPartyContext) {
        let before = (old.code, old.partyAutoplayEnabled, AutoplayPolicy.supplierId(party: old))
        let after = (party.code, party.partyAutoplayEnabled, AutoplayPolicy.supplierId(party: party))
        guard before != after else { return }
        if old.inParty, !party.inParty {
            // Out of the party, the queue held here is this user's own again, and the snapshot has to
            // describe it before the next playhead sample writes an index into it: nothing was
            // saved while in the party, so the file still holds the queue from before it.
            saveQueueSnapshot()
        }
        // This device just became the one that tops the party's queue up.
        if party.inParty, party.partyAutoplayEnabled, isElectedSupplier(party) {
            cancelAutoplayLoad()
            loadAutoplayForCurrentTrack()
        }
    }

    // MARK: - Stations and persistence

    /// Drops everything that could resurrect the former queue before a station replaces it.
    private func beginRadioQueue() {
        cancelAutoplayLoad()
        repeatAllStash = []
        repeatAllStashSeed = nil
        sessionSongHistory = []
        persistedQueueStart = 0
        // In a party the snapshot on disk is the personal queue, which this station doesn't
        // replace (commitRadioQueue won't write the party's): Android cleared it here regardless.
        if !party.inParty { lastPlayed?.clearImmediately() }
    }

    /// Makes the station the durable restart boundary, synchronously.
    private func commitRadioQueue() {
        guard !party.inParty, let lastPlayed else { return }
        guard !state.isEmpty else {
            persistedQueueStart = 0
            lastPlayed.clearImmediately()
            return
        }
        persistedQueueStart = LastPlayedStore.window(size: state.songs.count, index: state.currentIndex).lowerBound
        lastPlayed.saveQueueImmediately(state.songs, index: state.currentIndex, positionMs: playheadMs)
    }

    /// Serializes only the bounded window needed for a restart. Skipped in a party: the party's
    /// queue isn't this user's to come back to.
    private func saveQueueSnapshot() {
        guard !party.inParty, let lastPlayed else { return }
        guard !state.isEmpty else {
            persistedQueueStart = 0
            lastPlayed.clear()
            return
        }
        let range = LastPlayedStore.window(size: state.songs.count, index: state.currentIndex)
        persistedQueueStart = range.lowerBound
        lastPlayed.saveQueue(Array(state.songs[range]), index: state.currentIndex - range.lowerBound)
        savePlaybackState()
    }

    /// The index and playhead of the saved window. Skipped in a party like the queue itself: Android
    /// wrote the party's index over the personal snapshot here, which left a restart after a party
    /// whose stash was lost on the wrong track of the personal queue.
    private func savePlaybackState() {
        guard !state.isEmpty, !party.inParty else { return }
        lastPlayed?.savePlaybackState(index: state.currentIndex - persistedQueueStart, positionMs: playheadMs)
    }

    // MARK: - Test seams

    /// Waits for the in-flight AutoPlay load, if any.
    func waitForAutoplay() async {
        while let task = autoplayTask {
            await task.value
            if autoplayTask == task { break }
        }
    }
}

private extension Song {
    /// A new entry: songs entering the queue from a page, a menu or a search get their own entry
    /// id, even when the row they came from was itself a queue entry (the same track queued twice
    /// is two entries, and the queue panel and shuffle tell them apart by id).
    var freshEntry: Song {
        var song = self
        song.queueEntryId = nil
        return song
    }

    /// Every entry in the live queue has an id; songs arriving from a sync layer or an old snapshot
    /// without one get it here, once.
    var withEntryId: Song {
        queueEntryId == nil ? asQueueEntry(queueTier) : self
    }
}
