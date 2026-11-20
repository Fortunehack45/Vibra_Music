import VibraMusicCore
import Foundation

// MARK: - Bridge

/// A point-in-time read of the local player for the party sync engine.
public struct PartyPlayerSnapshot: Sendable {
    public var songs: [Song]
    public var currentIndex: Int
    public var positionMs: Int64
    /// The decoder's length for the current item when the player has one; the queue's
    /// metadata can name a different cut of the same track.
    public var currentDurationMs: Int64?
    public var isPlaying: Bool
    /// Only a settled player can be measured: while buffering, `positionMs` is where it
    /// will resume rather than where it is.
    public var isReady: Bool
    /// The audio is transiently held elsewhere (a notification chime): the playhead is
    /// frozen meanwhile and reads as drift that is not there.
    public var audioSuppressed: Bool

    public init(
        songs: [Song] = [],
        currentIndex: Int = -1,
        positionMs: Int64 = 0,
        currentDurationMs: Int64? = nil,
        isPlaying: Bool = false,
        isReady: Bool = true,
        audioSuppressed: Bool = false
    ) {
        self.songs = songs
        self.currentIndex = currentIndex
        self.positionMs = positionMs
        self.currentDurationMs = currentDurationMs
        self.isPlaying = isPlaying
        self.isReady = isReady
        self.audioSuppressed = audioSuppressed
    }
}

/// What the party needs to read and command on the player. The app adapts its AVPlayer
/// engine; the module declares this protocol so the package never depends on the player.
/// (Ports the `Player` surface `PartySync` uses in `playback/PartySync.kt`.)
public protocol PartyPlayerBridge: AnyObject, Sendable {
    func snapshot() async -> PartyPlayerSnapshot?
    /// Loads the party's running order and starts at its position. False when the player was not
    /// there to take it, so the sync engine tries again instead of believing it is on its way.
    func load(tracks: [PartyTrack], index: Int, positionMs: Int64, startPlaying: Bool) async -> Bool
    func play() async
    func pause() async
    func seek(to positionMs: Int64) async
    /// Replaces everything after the current item in one atomic edit.
    func setUpcoming(_ tracks: [PartyTrack]) async
    func appendUpcoming(_ tracks: [PartyTrack]) async
    func trimUpcoming(toCount: Int) async
    func moveUpcoming(from: Int, to: Int) async
}

/// Personal-queue hand-off across a party visit. The app adapts
/// `PlaybackQueue.PartyPersonalQueueStash` (which owns the file); the sync engine only
/// needs these three verbs, so neither module depends on the other.
public protocol PartyQueueStashing: Sendable {
    func stash(songs: [Song], index: Int, positionMs: Int64, isPlaying: Bool) async
    func loadStash() async -> PartyStashedQueue?
    func clearStash() async
}

public struct PartyStashedQueue: Sendable {
    public var songs: [Song]
    public var index: Int
    public var positionMs: Int64
    public var wasPlaying: Bool

    public init(songs: [Song], index: Int, positionMs: Int64, wasPlaying: Bool) {
        self.songs = songs
        self.index = index
        self.positionMs = positionMs
        self.wasPlaying = wasPlaying
    }
}

// MARK: - Drift policy

/// When an over-limit playhead difference is worth an audible seek. Pure, so the rule is
/// unit-testable without a player: a correction has to be asked for twice in a row before
/// it happens (one reading taken while the pipeline catches up cannot trigger anything),
/// and after one the player is left alone long enough to settle. A party a second out for
/// a few seconds is fine; a party seeking every 1.4 s is not listenable.
/// (Ports the drift branch of `PartySync.reconcile`.)
public struct PartyDriftPolicy: Sendable {
    public var strikes = 0
    public var cooldownUntilMs: Int64 = 0

    public init() {}

    /// - Returns: whether to seek now.
    public mutating func evaluate(driftMs: Int64, nowMs: Int64) -> Bool {
        guard abs(driftMs) > PartyLimits.driftLimitMs else {
            strikes = 0
            return false
        }
        guard nowMs >= cooldownUntilMs else { return false }
        strikes += 1
        guard strikes >= PartyLimits.driftStrikes else { return false }
        strikes = 0
        cooldownUntilMs = nowMs + PartyLimits.driftCooldownMs
        return true
    }
}

// MARK: - Coordinator

/// Makes the player obey the party, and the party obey this player.
///
/// The hard part is not moving the playhead, it is knowing *who moved it*. A binder that
/// reacts to player events and republishes them echoes its own corrections around the party
/// forever. This one never guesses, because the two directions arrive through physically
/// different doors: outbound is `noteLocalIntent()`, called only for *user* actions (and
/// the queue moving on by itself at the end of a track); inbound is `reconcile()`, which
/// commands the bridge directly. So nothing this class does to the player can ever come
/// back to it as an intent.
///
/// One deliberate consequence: a pause this app did not ask for — audio focus lost to
/// another app, a call — is *not* published. One person taking a call does not stop the
/// music for everyone else. That device also stops *following* until its own user asks to
/// come back (`noteExternalPause()` / `noteLocalIntent()`), as a catch-up rather than a
/// control: the gap opened by being away belongs to the device that was away, and
/// publishing it as a seek would haul four other people back to where one of them took a
/// phone call. (Ports `PartySync` in `playback/PartySync.kt`.)
public actor PartySyncCoordinator {
    private let client: PartyClient
    private let bridge: any PartyPlayerBridge
    private let stash: (any PartyQueueStashing)?
    private let monotonicMs: () -> Int64

    private var tickTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var publishTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    /// Pauses the user has pressed, and how many there had been when the latest play was
    /// pressed. A play still suspended in `shouldDeferPlay` can then tell that a pause landed
    /// after it, whenever the actor happened to run each: that pause is the last word.
    private var pauseIntents = 0
    private var pausesAtLastPlayPress = 0

    /// Until when `reconcile` should keep its hands off: set on every local intent, so the
    /// party state — which still describes the world before the button was pressed until
    /// the server's echo lands — is not reconciled against in that window.
    private var reconcileQuietUntilMs: Int64 = 0
    /// The party seqs at which this device's own controls will all have landed. Not "the
    /// seq before I published": choosing a track publishes *two* controls (queue, then
    /// track), and the party is torn between them — clearing on the first let reconcile
    /// haul the player back off the song the user just picked.
    private var awaitPlaybackSeq = Int64.max
    private var awaitQueueSeq = Int64.max
    /// The last party control this device put itself exactly on: a discontinuity everybody
    /// lands on precisely, matched without regard to the drift limit — including on the
    /// device that issued it, which otherwise keeps the head start issuing it gave it.
    private var alignedSeq: Int64 = -1
    private var lastAnchorMs: Int64 = 0
    private var lastPositionMs: Int64 = 0
    private var lastTrackId: String?
    private var lastIsPlaying = false
    private var loadingVideoId: String?
    private var drift = PartyDriftPolicy()
    /// Another app has the audio: follow nothing until this device's own user asks back.
    private var focusLost = false
    /// The user asked to come back after `focusLost`: behind by however long they were away,
    /// a gap this device closes by saying nothing and letting reconcile catch it up.
    private var rejoining = false
    /// A listener in a locked party paused their own device. The party plays on without
    /// them; reconcile still follows in every respect that is not audible and simply does
    /// not start the player or chase the playhead.
    private var locallyPaused = false
    private var queueDragActive = false
    private var queueDragDirty = false
    private var lastPartyCode: String?

    /// What makes a party state worth reconciling at once: a control landing, joining or
    /// leaving, the first pong. Not the round-trip counter every pong moves.
    private struct ReconcileKey: Equatable {
        var seq: Int64
        var queueSeq: Int64
        var code: String?
        var clockSynced: Bool
    }

    private var lastReconcileKey: ReconcileKey?

    public init(
        client: PartyClient,
        bridge: any PartyPlayerBridge,
        stash: (any PartyQueueStashing)? = nil,
        monotonicMs: @escaping () -> Int64 = PartyServerClock.systemMonotonicMs
    ) {
        self.client = client
        self.bridge = bridge
        self.stash = stash
        self.monotonicMs = monotonicMs
    }

    public func start() {
        stop()
        lastReconcileKey = nil
        // The tick alone leaves a remote control, or the first pong that lets a device joining a
        // playing party start, waiting out the rest of the tick. (Ports the state collector in
        // `PartySync.start()`.)
        stateTask = Task { [weak self] in
            guard let self else { return }
            for await state in await self.client.stateStream() {
                if Task.isCancelled { return }
                await self.reconcileIfChanged(state)
            }
        }
        tickTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(PartyLimits.tickMs) * 1_000_000)
                if Task.isCancelled { return }
                await self.tick()
            }
        }
    }

    public func stop() {
        tickTask?.cancel()
        tickTask = nil
        stateTask?.cancel()
        stateTask = nil
        publishTask?.cancel()
        startTask?.cancel()
    }

    private func reconcileIfChanged(_ state: PartySessionState) async {
        let key = ReconcileKey(
            seq: state.playback.seq, queueSeq: state.queue.seq,
            code: state.code, clockSynced: state.clockSynced)
        guard key != lastReconcileKey else { return }
        lastReconcileKey = key
        await reconcile(party: state)
    }

    private func tick() async {
        let party = await client.state
        if party.inParty { await client.ensureConnected() }
        await reconcile(party: party)
    }

    // MARK: - Outbound

    /// The user did something to playback on this device — or the queue moved on by itself.
    /// Debounced, because one gesture is several calls (load, prepare, play); publishing each
    /// would put three controls on the wire for one tap.
    ///
    /// - Parameter paused: the user asked for silence. A play still waiting on the party's start
    ///   dies with it, or the fallback would start the player under the pause.
    public func noteLocalIntent(paused: Bool = false) async {
        // Before the first suspension, so the order the actor sees presses in is the order they
        // were made: a later `notePlayPress` can never be counted before this pause.
        if paused {
            pauseIntents += 1
            startTask?.cancel()
            await client.setAwaitingStart(false)
        }
        let party = await client.state
        guard party.inParty, !party.controlsLocked else { return }
        if focusLost {
            focusLost = false
            rejoining = true
        }
        reconcileQuietUntilMs = monotonicMs() + PartyLimits.intentQuietMs
        awaitPlaybackSeq = .max
        awaitQueueSeq = .max
        // A row dragged through the queue calls this once per neighbour it crosses: parked
        // here and published once, when the row lands.
        if queueDragActive {
            queueDragDirty = true
            publishTask?.cancel()
            return
        }
        publishTask?.cancel()
        publishTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(PartyLimits.publishDebounceMs) * 1_000_000)
            if Task.isCancelled { return }
            await self.publish()
        }
    }

    public func beginQueueDrag() { queueDragActive = true }

    /// The row was dropped (or the drag cancelled): flushes anything parked by intents.
    public func endQueueDrag() async {
        queueDragActive = false
        if queueDragDirty {
            queueDragDirty = false
            await noteLocalIntent()
        }
    }

    /// The player's audibility moved for a reason only visible as it happens: another app
    /// took the audio permanently. While set, nothing follows and nothing is published.
    public func noteExternalPause() async {
        guard (await client.state).inParty else { return }
        focusLost = true
        await client.setAwaitingStart(false)
        startTask?.cancel()
    }

    /// Audible again by some route — a rejoin, a headset button. Following is right again.
    public func noteAudibleAgain() {
        focusLost = false
    }

    /// Play or pause for a listener whose party is locked to its host. Returns true when it
    /// handled it: the press moves this device and nothing else, publishes nothing, and is
    /// never deferred. Resuming rejoins wherever the party has *got to* — the radio model.
    public func onLockedTransport(playing: Bool) async -> Bool {
        let party = await client.state
        guard party.controlsLocked else { return false }
        guard await bridge.snapshot() != nil else { return false }
        if playing {
            locallyPaused = false
            // Pressing play is asking to come back, whatever took the audio away.
            focusLost = false
            // Nothing to join while the party itself is paused: starting here would play
            // alone for the tick it takes reconcile to notice and pause again.
            guard party.playback.isPlaying else { return true }
            if party.clockSynced, let want = party.positionMs(serverNowMs: await clientClockNow()) {
                await bridge.seek(to: want)
            }
            await bridge.play()
        } else {
            locallyPaused = true
            // A play deferred before the lock is still waiting; its fallback would start the
            // player under this pause, so the wait dies with it.
            startTask?.cancel()
            await client.setAwaitingStart(false)
            await bridge.pause()
        }
        return true
    }

    /// The user pressed play. Called first, with nothing awaited before it, so the pause count
    /// it takes is the one at the press: `shouldDeferPlay` then knows whether a pause came later.
    public func notePlayPress() {
        pausesAtLastPlayPress = pauseIntents
    }

    /// Whether a `play()` from this device should be held back for the party. True means the
    /// caller must *not* start the player: this class will, at the instant the server
    /// schedules for everyone — a few hundred milliseconds out, and the difference between
    /// honouring it and not is the difference between a party and a device permanently ahead
    /// of one. False whenever the party could not schedule anything, so play behaves exactly
    /// as it does outside this feature; the press is never swallowed.
    public func shouldDeferPlay() async -> Bool {
        let party = await client.state
        guard party.inParty, party.connection == .live, party.clockSynced else { return false }
        // Already going: `play()` on a player that never stopped does nothing anywhere, and
        // swallowing it here would arm a wait that nothing can end.
        if await bridge.snapshot()?.isPlaying == true { return false }
        // A pause pressed after this play is the last word: the press is swallowed, and no
        // wait is armed for the fallback to start the player under it.
        if pauseIntents != pausesAtLastPlayPress { return true }
        await client.setAwaitingStart(true)
        if pauseIntents != pausesAtLastPlayPress {
            await client.setAwaitingStart(false)
            return true
        }
        deferredPlayFallback()
        return true
    }

    /// The press must do something even if the party cannot answer: a control can be lost,
    /// and a socket can be up in name only. Left to the echo alone, that case is a play
    /// button that does nothing — far worse than being briefly out of step.
    private func deferredPlayFallback() {
        startTask?.cancel()
        startTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(PartyLimits.deferredPlayTimeoutMs) * 1_000_000)
            if Task.isCancelled { return }
            await self.endDeferredWait()
        }
    }

    private func endDeferredWait() async {
        guard await client.awaitingStart else { return }
        await client.setAwaitingStart(false)
        // Every pause route cancels this task before it awaits anything.
        if await bridge.snapshot()?.isPlaying == false, !Task.isCancelled {
            await bridge.play()
        }
    }

    // MARK: - Inbound

    /// Puts a player that is not where the party is back where the party is.
    public func reconcile() async {
        await reconcile(party: client.state)
    }

    public func reconcile(party: PartySessionState) async {
        let party = party
        guard party.inParty else {
            loadingVideoId = nil
            focusLost = false
            rejoining = false
            await client.setAwaitingStart(false)
            locallyPaused = false
            lastAnchorMs = 0; lastPositionMs = 0; lastTrackId = nil; lastIsPlaying = false
            return
        }
        // Before every early return below, so a local pause cannot outlive the lock.
        if locallyPaused, !party.controlsLocked { locallyPaused = false }
        // Every control this device sent has come back around (or somebody has moved the
        // party on past ours): the party describes the world the user made.
        if party.playback.seq >= awaitPlaybackSeq, party.queue.seq >= awaitQueueSeq {
            reconcileQuietUntilMs = 0
        }
        if monotonicMs() < reconcileQuietUntilMs { return }
        if focusLost { return }
        guard let track = party.playback.track else {
            await seedEmptyParty(party)
            return
        }
        guard let snap = await bridge.snapshot() else { return }
        // Playing something off this device: the party cannot follow a local URI and this
        // device should not be yanked off the file somebody deliberately chose.
        if let current = snap.songs[safe: snap.currentIndex], current.isPartyDeviceFile { return }
        if audioSuppressed(snap) { return }

        if currentTrackId(of: snap) != track.videoId {
            await load(party: party, track: track)
            return
        }
        loadingVideoId = nil
        await reconcileQueue(party: party, snapshot: snap)

        // Muted by its own listener while the party plays on: everything above still applies
        // (track loads, queue keeps), everything below is sound.
        if locallyPaused {
            await client.setAwaitingStart(false)
            return
        }

        if !party.playback.isPlaying {
            await client.setAwaitingStart(false)
            if snap.isPlaying { await bridge.pause() }
            // Held where the party paused it, so everybody resumes from the same place.
            if abs(snap.positionMs - party.playback.positionMs) > PartyLimits.pausedToleranceMs {
                await bridge.seek(to: party.playback.positionMs)
            }
            return
        }

        // A playing party cannot be joined *in time* without a measured clock: `positionMs`
        // is the position at an anchor that may be minutes old. Loading needs no clock; only
        // the position does — and `load` prepares without starting for exactly that reason.
        guard party.clockSynced else { return }

        let serverNow = await clientClockNow()
        let want = party.positionMs(serverNowMs: serverNow)
        if !snap.isPlaying {
            let wait = party.msUntilStart(serverNowMs: serverNow)
            if wait > 0 {
                // The party's resume is scheduled, not immediate: wake up for it rather than
                // waiting for the next tick, which could be most of a tick late.
                startTask?.cancel()
                startTask = Task { [weak self] in
                    guard let self else { return }
                    // At most a minute, then reconcile and wait again: the start is the server's
                    // number, and a far one overflowed UInt64 nanoseconds, which traps.
                    try? await Task.sleep(nanoseconds: UInt64(min(wait, 60_000)) * 1_000_000)
                    if Task.isCancelled { return }
                    await self.reconcile()
                }
                return
            }
            if let want { await bridge.seek(to: want) }
            await client.setAwaitingStart(false)
            startTask?.cancel()
            await bridge.play()
            alignedSeq = party.playback.seq
            return
        }

        await client.setAwaitingStart(false)
        guard let want else { return }
        guard snap.isReady else {
            drift.strikes = 0
            return
        }

        let driftMs = snap.positionMs - want
        if party.playback.seq != alignedSeq {
            // Everyone lands on a control exactly — including the device that issued it.
            // But a seq bump with no anchor/position/track/playing change (a queue op or a
            // metadata update) must not force an audible seek flush.
            let anchorChanged = lastAnchorMs != party.playback.anchorMs
                || lastPositionMs != party.playback.positionMs
                || lastTrackId != track.videoId
                || lastIsPlaying != party.playback.isPlaying
            alignedSeq = party.playback.seq
            lastAnchorMs = party.playback.anchorMs
            lastPositionMs = party.playback.positionMs
            lastTrackId = track.videoId
            lastIsPlaying = party.playback.isPlaying
            if anchorChanged, abs(driftMs) > PartyLimits.alignToleranceMs {
                await bridge.seek(to: want)
                return
            }
        }
        if drift.evaluate(driftMs: driftMs, nowMs: monotonicMs()) {
            await bridge.seek(to: want)
        }
    }

    /// Puts the party's running order on this player and starts at its position. The queue
    /// comes across as well as the track so that next/previous work locally and the next
    /// track prefetches. Not started here even when the party is playing: the resume may be
    /// scheduled a moment out, and reconcile owns that wait.
    private func load(party: PartySessionState, track: PartyTrack) async {
        guard loadingVideoId != track.videoId else { return }
        loadingVideoId = track.videoId
        // The queue is only usable if the track is actually in it: queue and track are two
        // controls, and between them the party holds a new running order with the old song
        // still current. Falling back to the track alone is always right; falling back to
        // position zero never is.
        let partyQueue = party.queue.items
        let index = partyQueue.firstIndex(where: { $0.videoId == track.videoId })
        let queue = index.map { _ in partyQueue } ?? [track]
        let startIndex = index ?? 0
        // Read after the (potentially slow) queue assembly: the party's playhead has moved
        // on by exactly that much, and taking it beforehand would start every track change
        // a little behind, then haul it forward with a correcting seek.
        let startAt = await client.partyPositionMs() ?? party.playback.positionMs
        let wait = await client.msUntilStart()
        let startPlaying = party.playback.isPlaying && party.clockSynced && wait <= 0 && !locallyPaused
        let applied = await bridge.load(
            tracks: queue, index: startIndex, positionMs: startAt, startPlaying: startPlaying)
        // Nothing was applied, so the next tick has to be free to try again rather than believing
        // this track is already on its way. (Ports the null-player branch of `PartySync.load`.)
        guard applied else {
            loadingVideoId = nil
            return
        }
        await reconcile()
    }

    private func reconcileQueue(party: PartySessionState, snapshot: PartyPlayerSnapshot) async {
        let partyQueue = party.queue.items
        guard !partyQueue.isEmpty else { return }
        guard snapshot.songs.indices.contains(snapshot.currentIndex) else { return }
        let currentId = snapshot.songs[snapshot.currentIndex].videoId
        guard let partyIndex = partyQueue.firstIndex(where: { $0.videoId == currentId }) else { return }

        let desired = Array(partyQueue[(partyIndex + 1)...].prefix(PartyLimits.maxUpcomingQueue))
        let desiredIds = desired.map(\.videoId)
        let upcoming = Array(snapshot.songs[(snapshot.currentIndex + 1)...])
        let upcomingIds = upcoming.map(\.videoId)
        guard upcomingIds != desiredIds else { return }

        // The normal case (a listener appending a song) must never rewrite the timeline:
        // adding after the active item keeps its decoder untouched on every device.
        if desiredIds.starts(with: upcomingIds) {
            await bridge.appendUpcoming(Array(desired[upcomingIds.count...]))
            return
        }
        // Likewise, trimming only the tail leaves the active source alone.
        if upcomingIds.starts(with: desiredIds) {
            await bridge.trimUpcoming(toCount: desiredIds.count)
            return
        }
        if upcomingIds.count == desiredIds.count,
           let move = partyDetectSingleMove(oldList: upcomingIds, newList: desiredIds)
        {
            await bridge.moveUpcoming(from: move.fromIndex, to: move.toIndex)
        } else {
            // One atomic timeline edit; the active item stays outside the replacement.
            await bridge.setUpcoming(desired)
        }
    }

    // MARK: - Party entry / exit

    /// Call when the membership code changes (the app observes `PartyClient.stateStream`
    /// and forwards the code): stashes the personal queue on entry, restores it on exit.
    public func notePartyCodeChanged(previous: String?, current: String?) async {
        if previous == nil, let current, current != previous {
            await onEnteredParty()
        } else if previous != nil, current == nil {
            await onLeftParty()
        }
        lastPartyCode = current
    }

    private func onEnteredParty() async {
        guard let snap = await bridge.snapshot() else { return }
        let kept = snap.songs.filter { !$0.isPartyDeviceFile }
        guard !kept.isEmpty else { return }
        // The index is into `kept`, so count only the kept songs ahead of the current one: a
        // device file before it would otherwise push the stash onto the wrong track.
        let keptBefore = snap.songs.prefix(max(0, snap.currentIndex)).filter { !$0.isPartyDeviceFile }.count
        let safeIndex = min(keptBefore, kept.count - 1)
        await stash?.stash(
            songs: kept, index: safeIndex,
            positionMs: max(0, snap.positionMs), isPlaying: snap.isPlaying)
    }

    private func onLeftParty() async {
        loadingVideoId = nil
        focusLost = false
        rejoining = false
        // The coordinator stops with the party, so reconcile's own reset may never run.
        locallyPaused = false
        guard let stashed = await stash?.loadStash() else { return }
        let tracks = stashed.songs.map { PartyTrackMapping.toPartyTrack($0, playerDurationMs: 0) }
        _ = await bridge.load(
            tracks: tracks, index: stashed.index,
            positionMs: stashed.positionMs, startPlaying: stashed.wasPlaying)
        if !stashed.wasPlaying { await bridge.pause() }
        await stash?.clearStash()
    }

    // MARK: - Outbound publish

    private func publish() async {
        let party = await client.state
        guard party.inParty else { return }
        // Coming back from having lost the audio: behind, possibly on a track the party left
        // minutes ago — everything it could say right now is stale, and every one of those
        // is a control that would move four other people backwards. Say nothing; reconcile,
        // no longer held off, brings it to the party.
        if rejoining {
            rejoining = false
            reconcileQuietUntilMs = 0
            return
        }
        guard let snap = await bridge.snapshot(),
              snap.songs.indices.contains(snap.currentIndex)
        else { return }
        let song = snap.songs[snap.currentIndex]
        guard !song.isPartyDeviceFile else { return }
        let track = PartyTrackMapping.toPartyTrack(song, playerDurationMs: snap.currentDurationMs ?? 0)
        let position = max(0, snap.positionMs)
        // What the user asked for, which during a deferred resume is not what the player is
        // doing yet — that is the whole point of the deferral.
        let wantsPlaying = (await client.awaitingStart) || snap.isPlaying
        let basePlayback = party.playback.seq
        let baseQueue = party.queue.seq
        var playbackControls = 0
        var queueControls = 0

        let rawLocal = snap.songs.filter { !$0.isPartyDeviceFile }
        let rawIds = rawLocal.map(\.videoId)
        let rawTrackIndex = rawIds.firstIndex(of: track.videoId)
        let local: [Song]
        if let at = rawTrackIndex {
            let pastAndCurrent = Array(rawLocal[...at])
            let upcoming = rawLocal[(at + 1)...].filter { $0.queueTier != .context }
            local = pastAndCurrent + upcoming
        } else {
            local = rawLocal.filter { $0.queueTier != .context }
        }
        let localIds = local.map(\.videoId)
        let trackIndex = localIds.firstIndex(of: track.videoId)
        let clampedIds: [String]
        if let at = trackIndex {
            clampedIds = Array(localIds.prefix(min(at + 1 + PartyLimits.maxUpcomingQueue, localIds.count)))
        } else {
            clampedIds = Array(localIds.prefix(1 + PartyLimits.maxUpcomingQueue))
        }

        let partyIds = party.queue.items.map(\.videoId)
        let partyIndex = party.queue.items.firstIndex(where: { $0.videoId == party.playback.track?.videoId })
        let upcomingPartyTracks: [PartyTrack] = partyIndex.map {
            Array(party.queue.items[($0 + 1)...])
        } ?? []

        if party.playback.track?.videoId != track.videoId, clampedIds.count == 1, !upcomingPartyTracks.isEmpty {
            let toPreserve = upcomingPartyTracks.filter { !$0.fromAutoplay }.prefix(PartyLimits.maxUpcomingQueue)
            await client.setQueue(Array([track] + toPreserve), index: 0)
            queueControls += 1
        } else if clampedIds != partyIds {
            let singleMove: PartyQueueMoveDelta? = if partyIds.count == clampedIds.count,
                let at = trackIndex, at < partyIds.count, partyIds[at] == clampedIds[at]
            {
                partyDetectSingleMove(oldList: partyIds, newList: clampedIds)
            } else {
                nil
            }
            if let move = singleMove, move.fromIndex > (trackIndex ?? -1), move.toIndex > (trackIndex ?? -1) {
                await client.queueMove(from: move.fromIndex, to: move.toIndex, videoId: move.videoId)
                queueControls += 1
            } else {
                let queue = clampedIds.compactMap { id in local.first(where: { $0.videoId == id }) }
                    .filter { !$0.isPartyDeviceFile }
                    .map { PartyTrackMapping.toPartyTrack($0, playerDurationMs: 0) }
                await client.setQueue(queue, index: trackIndex ?? 0)
                queueControls += 1
            }
        }

        if party.playback.track?.videoId != track.videoId {
            // After the queue, never before: a track change arriving pointing into a
            // running order nobody has yet is the bug that played the wrong song.
            await client.setTrack(track, positionMs: position, isPlaying: wantsPlaying)
            playbackControls += 1
        } else if party.playback.isPlaying != wantsPlaying {
            if wantsPlaying { await client.play(at: position) } else { await client.pause(at: position) }
            playbackControls += 1
        } else {
            // Same track, same playing state — so the user moved the playhead. Unless it did
            // not move far, in which case this is two devices being normally, slightly apart.
            // The case that matters is two devices reaching the end of a track together: both
            // report the advance, the second finds the party already on the new track and would
            // otherwise publish its own position as a seek — dragging the first, which
            // republishes, and so on. Nobody asked for any of it.
            let partyPosition = await client.partyPositionMs()
            if let partyPosition {
                if abs(position - partyPosition) > PartyLimits.seekReportFloorMs {
                    await client.seek(to: position)
                    playbackControls += 1
                }
            } else {
                await client.seek(to: position)
                playbackControls += 1
            }
        }

        // The party has caught up once every control sent has come back around. Nothing sent
        // means nothing to wait for, and the quiet window stops holding reconcile off now.
        awaitPlaybackSeq = basePlayback + Int64(playbackControls)
        awaitQueueSeq = baseQueue + Int64(queueControls)
        if playbackControls == 0, queueControls == 0 { reconcileQuietUntilMs = 0 }
    }

    /// Hands a party with nothing in it the music this device is already playing. Only the
    /// host, and only while the party has no track of its own — with exactly one device
    /// allowed to seed there is no race for the last write to win. Retried on the next tick:
    /// being in a party and having a socket to say so on are two different moments.
    private func seedEmptyParty(_ party: PartySessionState) async {
        guard party.connection == .live, party.you?.isHost == true else { return }
        guard let snap = await bridge.snapshot(),
              snap.songs.indices.contains(snap.currentIndex)
        else { return }
        let song = snap.songs[snap.currentIndex]
        guard !song.isPartyDeviceFile else { return }
        await publish()
    }

    // MARK: - Helpers

    private func clientClockNow() async -> Int64? {
        await client.serverClockNow()
    }

    private func currentTrackId(of snap: PartyPlayerSnapshot) -> String? {
        guard snap.songs.indices.contains(snap.currentIndex) else { return nil }
        return snap.songs[snap.currentIndex].videoId
    }

    private func audioSuppressed(_ snap: PartyPlayerSnapshot) -> Bool {
        snap.audioSuppressed
    }
}

// MARK: - Party-local queue helpers

/// Whether `newList` is `oldList` with exactly one item moved: the move, or nil when the
/// lists cannot be explained by a single move. A party publishes a drag as one delta
/// rather than as a whole new queue.
///
/// Module-local on purpose: `PlaybackQueue` owns the canonical `detectSingleMove` for
/// local queues (this module cannot depend on it — see `Package.swift`), and party wire
/// indices need no queue-entry semantics, just ids.
struct PartyQueueMoveDelta {
    var fromIndex: Int
    var toIndex: Int
    var videoId: String
}

func partyDetectSingleMove(
    oldList: [String],
    newList: [String],
    baseOffset: Int = 0
) -> PartyQueueMoveDelta? {
    guard oldList.count == newList.count, oldList != newList, !oldList.isEmpty else { return nil }
    func counts(_ list: [String]) -> [String: Int] {
        list.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }
    guard counts(oldList) == counts(newList) else { return nil }
    for from in oldList.indices {
        let item = oldList[from]
        var without = oldList
        without.remove(at: from)
        for to in oldList.indices where to != from {
            var simulated = without
            simulated.insert(item, at: to)
            if simulated == newList {
                return PartyQueueMoveDelta(
                    fromIndex: baseOffset + from, toIndex: baseOffset + to, videoId: item)
            }
        }
    }
    return nil
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension Song {
    /// A file on this device rather than a catalogue track: handing one out would have
    /// every other member fail to resolve it, so local playback says nothing. Asked of the
    /// *id*, not of where the bytes come from — a downloaded catalogue track plays off
    /// disk but has a real id everybody else can stream. (Ports `Song.isDeviceFile` in
    /// `playback/PartySync.kt`; `ipod-library://` is the iOS media-library equivalent.)
    var isPartyDeviceFile: Bool {
        videoId.hasPrefix("content://") || videoId.hasPrefix("file://")
            || videoId.hasPrefix("ipod-library://")
    }
}
