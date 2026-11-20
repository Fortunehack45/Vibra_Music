import VibraMusicCore
import Foundation

/// What the controller needs of a deck. The engine's ``PlaybackDeck`` is one; the tests drive fakes.
@MainActor
protocol TransitionDeck: AnyObject {
    var volume: Float { get set }
    /// Position in the deck's current item, seconds.
    var position: TimeInterval { get }
    /// The current item's length, when known.
    var knownDuration: TimeInterval? { get }
    var playWhenReady: Bool { get set }
    var isPlaying: Bool { get }
    /// Loaded and buffered at its position (Media3's `STATE_READY`).
    var isReadyToPlay: Bool { get }
    /// Stopped at the end of its item (`STATE_ENDED`).
    var hasEnded: Bool { get }
    /// Nothing loaded, or it failed (`STATE_IDLE`).
    var isIdle: Bool { get }
    func setTransitionFilter(_ cutoffs: TransitionFilterCutoffs)
}

/// What the controller needs of the engine that owns it.
@MainActor
protocol CrossfadeHost: AnyObject {
    /// The deck the session is on right now. Swaps with the standby at every handoff.
    var activeTransitionDeck: TransitionDeck { get }
    /// The idle deck the next transition loads the incoming track onto.
    var standbyTransitionDeck: TransitionDeck { get }
    var transitionCurrentItem: PlayableItem? { get }
    var transitionUpcomingItem: PlayableItem? { get }
    /// Where the current item ends, allowing for a silent outro that skip silence trims.
    var transitionCurrentEnd: TimeInterval? { get }
    var transitionUpcomingDuration: TimeInterval? { get }
    /// The listener's crossfade length in seconds; 0 is off.
    var crossfadeSeconds: TimeInterval { get }
    var automixActive: Bool { get }
    var transitionPlanner: TransitionPlanning? { get }
    /// True in a Listen Together party or while a version swap owns the standby deck.
    var transitionsSuspended: Bool { get }
    var sleepsAfterCurrentTrack: Bool { get }
    var playbackSpeed: Float { get }
    var now: TimeInterval { get }

    /// Loads `item` onto the standby deck at `cue`, silent and paused, at `rate`.
    func armIncoming(_ item: PlayableItem, cue: TimeInterval, rate: Float)
    /// Moves the session onto the standby deck, which has just started the incoming track, and
    /// stops the outgoing deck advancing into it by itself.
    func handOffToStandby()
    /// Empties a deck and resets its volume, rate and filter.
    func retire(_ deck: TransitionDeck)
    func setRate(_ rate: Float, on deck: TransitionDeck)
    /// The sleep timer's fade-out finished: pause and disarm the timer.
    func finishSleepFade(on deck: TransitionDeck)
    func transitionStateChanged(isTransitioning: Bool)
    func mixInProgressChanged(_ inProgress: Bool)
    func transitionWindowChanged(_ window: TransitionWindow?)
}

/// A real crossfade: two tracks audible at once, the outgoing one falling as the incoming one rises
/// (port of the Android `CrossfadeController`).
///
/// ## Two decks, and which plays what
///
/// One player renders one item at a time, so at a track boundary the only gains available are 1 (no
/// fade) or 0 (silence). Overlap needs a second decoder. The two decks are peers: at any instant one
/// *is* the session and the other is idle, and they swap roles at every transition. To arm a
/// transition the standby is loaded with the **incoming** track, cued and silent. Loading the
/// incoming (never the outgoing) track on the standby means the two players never hold the same
/// audio, so there is nothing to align and no instant of audio rendered twice.
///
/// ## The handoff
///
/// Finishing the swap is a role change, not a seek: nothing is re-buffered. It happens as the
/// incoming track's first note sounds, not at the end of the blend, so the queue, the metadata and
/// the lock screen flip to the incoming song the moment it becomes audible. From then on the
/// outgoing deck is the idle one, still audible, being faded out.
///
/// ## Rules
///
/// - Crossfade is a property of tracks *running out*. A skip or a seek drops any blend in flight:
///   the point of pressing next is to stop hearing the current track.
/// - A pause parks the fade where it stands, because progress is read off the incoming track's
///   position rather than a clock, and the other deck follows the session's play/pause every tick.
/// - The fade is capped at a third of either track, so a long crossfade into a short track tightens
///   rather than swallowing it.
/// - Repeat-one never crossfades a track into itself; a Listen Together party never crossfades
///   (every member would start the next song at a different moment).
/// - With "sleep after this track" armed there is no next track: the outgoing one fades to silence
///   over the same span and pauses.
@MainActor
final class CrossfadeController {
    enum Phase: Equatable {
        /// Nothing in flight; watching for the next transition.
        case idle
        /// The standby is loading the incoming track at its cue. Silent and uncommitted.
        case arming
        /// Incoming rising on one deck, outgoing falling on the other.
        case fading
        /// The sleep timer is due at this track's end: fading it to silence with nothing to follow.
        case sleepFade
        /// Something interrupted the fade; the outgoing track is being ramped away.
        case bailing
    }

    /// Ramp used when a fade is interrupted, so an interruption has no click in it.
    static let bailDuration: TimeInterval = 0.12
    /// Head start the standby gets to open the incoming track and buffer to its cue.
    static let armLead: TimeInterval = 4
    /// Longest a transition waits on an incoming track that won't become ready; past this the queue
    /// moves on plainly — a missed crossfade rather than a broken one.
    static let armTimeout: TimeInterval = 12
    /// Automix's overlap before analysis lands, when the listener has no crossfade length set.
    static let defaultSmartFallback: TimeInterval = 6
    /// Where ``startLatency`` starts before anything has been measured: what an `AVPlayer` with a
    /// post-effects tap measures on a Mac.
    static let initialStartLatency: TimeInterval = 0.25
    /// A measurement above this is a stall (the incoming deck buffering), not output latency.
    static let maxStartLatency: TimeInterval = 0.6

    /// Tick cadence per phase: arming only waits on a buffer; a fade steps its gains every 30 ms.
    static func step(for phase: Phase) -> TimeInterval {
        switch phase {
        case .idle: return 0.25
        case .arming: return 0.04
        case .fading, .sleepFade: return 0.03
        case .bailing: return 0.015
        }
    }

    private(set) var phase: Phase = .idle
    private unowned let host: CrossfadeHost

    /// The deck the transition began on — the one being left. Held explicitly because the handoff
    /// moves it out from under the "active" name halfway through the fade.
    private var outgoing: TransitionDeck?
    /// The deck carrying the arriving track. Becomes the session at the handoff.
    private var incoming: TransitionDeck?
    /// Whether the handoff has happened, which decides who owns what if the transition is unwound.
    private var handedOff = false
    private var spec = TransitionSpec(startTime: 0, overlap: 0)
    /// Which setting armed this transition, so switching the *other* one off isn't read as the fade
    /// being turned off (an Automix transition normally runs with the crossfade length at zero).
    private var smart = false
    private var armedItemID: String?
    private var armDeadline: TimeInterval = 0
    private var bailStartedAt: TimeInterval = 0
    private var bailFromGain: Float = 0
    private var sleepFadeLength: TimeInterval = 0
    private var sleepFadeStartPosition: TimeInterval = 0
    private var sleepFadeStartGain: Float = 1
    private var settledAt: TimeInterval?
    /// When the incoming deck was told to play, and whether its start latency has been measured yet
    /// for this transition.
    private var fadeStartedAt: TimeInterval = 0
    private var latencyMeasured = true
    /// Where the incoming deck stood when it was told to play: the spec's cue, or past it when the
    /// engine opened the track past a silent intro.
    private var fadeCue: TimeInterval = 0

    /// How long a deck told to play takes to be *heard*, in seconds of wall time: the fade is started
    /// this much early so the incoming track sounds at the planned point rather than after it.
    ///
    /// ExoPlayer starts a prepared player within a few milliseconds, so the Android controller never
    /// needed this. `AVPlayer` with a processing tap does not: it renders the tap ahead and reports
    /// the position of what is audible, which on a Mac runs about a quarter of a second behind
    /// `play()`. Uncompensated, the outgoing track reaches its end with the incoming one still well
    /// short of full volume. Measured on every transition (see ``driveFade()``) and smoothed; the
    /// engine seeds it, and it stays 0 for a host that never measures one.
    var startLatency: TimeInterval = 0

    init(host: CrossfadeHost) {
        self.host = host
    }

    var isTransitioning: Bool { phase != .idle }

    /// The item the standby is being loaded with, while arming.
    var armedIncomingID: String? { phase == .arming ? armedItemID : nil }

    /// How long since the last transition finished, or nil if none has. For callers (a mid-track
    /// quality swap) that must stay off the session deck for a moment *after* a blend as well.
    func timeSinceTransition() -> TimeInterval? {
        settledAt.map { host.now - $0 }
    }

    /// The spec in flight (tests and diagnostics).
    var currentSpec: TransitionSpec? { phase == .idle ? nil : spec }

    // MARK: - Entry points

    /// A skip the listener asked for: drop any blend in flight and get out of the way. Called
    /// before the skip is carried out, so the outgoing track is already on its way down.
    func onSkipRequested() {
        if phase != .idle { bail() }
    }

    /// The listener moved the playhead. No half-finished crossfade survives that.
    func onSeek() {
        if phase != .idle { bail() }
    }

    /// The session deck failed.
    func onError() {
        if phase != .idle { bail() }
    }

    /// What follows the current item changed. A transition armed for the old next item is loading
    /// the wrong track now; once handed off, the queue beyond the incoming track is irrelevant.
    func onUpcomingChanged(to id: String?) {
        if phase == .arming, id != armedItemID { bail() }
    }

    /// The session deck moved on by itself while a transition was being armed: the standby never
    /// got ready in time and the queue went on plainly.
    func onActiveAdvanced() {
        if phase == .arming { bail() }
    }

    /// Loading the incoming track failed; there is nothing to fade up.
    func onArmFailed(itemID: String) {
        if phase == .arming, armedItemID == itemID { bail() }
    }

    /// The sleep timer is gone — spent by the track ending before the fade-out did, or turned off.
    /// A fade-out in flight hands the deck back at full volume now rather than on the next tick, so
    /// the track the engine has just cued (paused) can't start turned down.
    func onSleepTimerCleared() {
        guard phase == .sleepFade else { return }
        outgoing?.volume = 1
        outgoing = nil
        phase = .idle
        host.transitionStateChanged(isTransitioning: false)
    }

    /// Mirrors the session's play/pause onto the other audible deck. Run every tick, and at once
    /// when the engine changes transport, so audio-session interruptions, the sleep timer and the
    /// pause button all take the other half of a blend with them.
    func syncTransport() {
        guard phase == .fading || phase == .bailing, let outgoing else { return }
        let want = incoming?.playWhenReady ?? true
        if outgoing.playWhenReady != want { outgoing.playWhenReady = want }
    }

    /// Advances the state machine. Returns how long to wait before the next tick.
    @discardableResult
    func tick() -> TimeInterval {
        syncTransport()
        switch phase {
        case .idle: considerAutoTransition()
        case .arming: driveArming()
        case .fading: driveFade()
        case .sleepFade: driveSleepFade()
        case .bailing: driveBail()
        }
        return Self.step(for: phase)
    }

    /// Stops everything and hands the session deck back at full volume.
    func release() {
        if phase != .idle { finish() }
        host.activeTransitionDeck.volume = 1
        host.activeTransitionDeck.setTransitionFilter(.open)
    }

    // MARK: - Planning

    private func considerAutoTransition() {
        let active = host.activeTransitionDeck
        // Only Automix marks a window; one it drew before being switched off would otherwise stay,
        // and a paused deck is exactly when it is switched off with no tick getting past the next line.
        if !host.automixActive { host.transitionWindowChanged(nil) }
        guard active.isPlaying else { return }
        if host.transitionsSuspended {
            host.transitionWindowChanged(nil)
            host.mixInProgressChanged(false)
            return
        }
        guard let current = host.transitionCurrentItem, let upcoming = host.transitionUpcomingItem else {
            host.transitionWindowChanged(nil)
            return
        }
        guard let end = host.transitionCurrentEnd, end > 0 else { return }
        // Repeat-one would crossfade the track into itself.
        if upcoming.id == current.id {
            host.transitionWindowChanged(nil)
            return
        }
        if host.automixActive {
            considerSmartTransition(current: current, upcoming: upcoming, end: end)
            return
        }
        let configured = host.crossfadeSeconds
        guard configured > 0 else { return }
        let fade = Self.fadeLength(configured: configured, duration: end)
        guard fade > 0 else { return }
        let remaining = end - active.position
        if host.sleepsAfterCurrentTrack {
            // No next track to fade into: run the same fade against silence. No arm lead, since
            // nothing is buffering.
            guard remaining <= fade else { return }
            beginSleepFadeOut(fade)
            return
        }
        // Arm early: the standby has to open the incoming track and buffer to its cue before the
        // fade is due, not start then.
        guard remaining <= fade + Self.armLead else { return }
        begin(.crossfade(endingAt: end, overlap: fade), smart: false, incoming: upcoming)
    }

    private func considerSmartTransition(current: PlayableItem, upcoming: PlayableItem, end: TimeInterval) {
        // Automix's analysis and cueing never apply to either side of a video row.
        if current.isVideoOrigin || upcoming.isVideoOrigin {
            host.transitionWindowChanged(nil)
            host.mixInProgressChanged(false)
            return
        }
        let active = host.activeTransitionDeck
        let fallback = host.crossfadeSeconds > 0 ? host.crossfadeSeconds : Self.defaultSmartFallback
        let planned: TransitionSpec?
        if let planner = host.transitionPlanner {
            planned = planner.transitionSpec(for: TransitionContext(
                outgoing: current,
                incoming: upcoming,
                position: active.position,
                duration: end,
                incomingDuration: host.transitionUpcomingDuration,
                fallbackOverlap: fallback
            ))
        } else {
            // No planner wired: what the planner answers for a pair with no analysis — a plain fade
            // of the fallback length.
            let fade = Self.fadeLength(configured: fallback, duration: end)
            planned = fade > 0 ? .crossfade(endingAt: end, overlap: fade) : nil
        }
        guard let spec = planned else {
            host.transitionWindowChanged(nil)
            return
        }
        host.transitionWindowChanged(spec.markerVisible ? TransitionWindow(
            start: min(max(spec.startTime / end, 0), 1),
            end: min(max(spec.endTime / end, 0), 1)
        ) : nil)
        guard spec.overlap > 0 else { return }
        let remaining = spec.startTime - active.position
        if host.sleepsAfterCurrentTrack {
            guard remaining <= 0 else { return }
            beginSleepFadeOut(spec.overlap)
            return
        }
        // Same arm-ahead margin, measured against the plan's own start: an analysed mix-out point
        // can sit well before the file ends.
        guard remaining <= Self.armLead else { return }
        begin(spec, smart: true, incoming: upcoming)
    }

    /// The configured length, kept off tracks too short to spend it on: a fade that swallows a
    /// third of a song stops being a transition and starts being the arrangement.
    static func fadeLength(configured: TimeInterval, duration: TimeInterval?) -> TimeInterval {
        guard let duration, duration > 0 else { return configured }
        return max(min(configured, duration / 3), 0)
    }

    // MARK: - Transition lifecycle

    /// Loads the standby with the incoming track at the cue, silent. Nothing is committed: a skip,
    /// a queue edit or a pause during arming costs only the standby's decoder.
    private func begin(_ spec: TransitionSpec, smart: Bool, incoming item: PlayableItem) {
        let out = host.activeTransitionDeck
        let into = host.standbyTransitionDeck
        guard out !== into else { return }
        self.spec = spec
        self.smart = smart
        armedItemID = item.id
        armDeadline = host.now + Self.armTimeout
        handedOff = false
        outgoing = out
        incoming = into
        PlaybackLog.debug(
            "arm \(smart ? "smart" : "standard") fade=\(spec.overlap)s start=\(spec.startTime)s cue=\(spec.incomingCueTime)s rate=\(spec.incomingRate) at=\(out.position)s",
            about: item.trackID
        )
        phase = .arming
        host.transitionStateChanged(isTransitioning: true)
        // Stacks the beatmatch stretch on the listener's speed rather than replacing it.
        host.armIncoming(item, cue: spec.incomingCueTime, rate: host.playbackSpeed * Float(spec.incomingRate))
    }

    /// Waits for the standby to be ready at its cue and for the outgoing track to reach the fade.
    private func driveArming() {
        guard let out = outgoing, let into = incoming else { return bail() }
        guard stillWorthFading() else { return bail() }
        // Paused while armed: the transition is no longer imminent, and holding a prepared decoder
        // open against a stopped player is worse than arming again on resume.
        guard out.playWhenReady else { return bail() }
        let ready = into.isReadyToPlay
        if host.now > armDeadline, !ready { return bail() }
        // Early by the start latency, converted to the outgoing track's own time.
        let lead = startLatency * Double(max(host.playbackSpeed, 0))
        let atFadePoint = spec.endTime <= 0 || spec.endTime - out.position <= spec.overlap + lead
        guard atFadePoint, ready else { return }
        startFade()
    }

    /// Starts the incoming track and moves the session onto it, as its first note sounds.
    private func startFade() {
        guard let into = incoming else { return bail() }
        into.volume = spec.incomingGain.gain(at: 0)
        fadeCue = into.position
        into.playWhenReady = true
        fadeStartedAt = host.now
        latencyMeasured = false
        handedOff = true
        // Fading before the host hears of it: the handoff asks the queue what follows the incoming
        // track, and that answer arriving while this still read as arming would bail the very
        // transition it completes — snapping the incoming track to full volume for a tick.
        phase = .fading
        host.handOffToStandby()
        host.mixInProgressChanged(smart && spec.isRealMix)
        // The queue has moved on, so a window drawn on the old track's scrubber is stale.
        host.transitionWindowChanged(nil)
    }

    /// The crossfade proper, driven off the incoming track's position so a pause parks it.
    private func driveFade() {
        guard let out = outgoing, let into = incoming else { return bail() }
        // Measured from the cue, not from zero: a track cued at 0:45 is not 45 s into its fade.
        let remainingIncoming = into.knownDuration.map { max($0 - fadeCue, 0) }
        let cap = remainingIncoming.map { $0 / 3 } ?? .infinity
        let span = max(min(spec.overlap, cap), 0.001)
        let elapsed = max(into.position - fadeCue, 0)
        let progress = min(max(elapsed / span, 0), 1)
        if !latencyMeasured, elapsed > 0 { measureStartLatency(contentElapsed: elapsed) }

        into.volume = spec.incomingGain.gain(at: progress)
        out.volume = spec.outgoingGain.gain(at: progress)
        rideFilters(progress)

        let switchedOff = smart ? !host.automixActive : host.crossfadeSeconds <= 0
        if progress >= 1 || out.hasEnded || out.isIdle || switchedOff {
            finish()
        }
    }

    /// The first tick the incoming track is heard: how much of the wall time since `play()` its
    /// position does not account for is the latency.
    private func measureStartLatency(contentElapsed: TimeInterval) {
        latencyMeasured = true
        let rate = Double(host.playbackSpeed) * spec.incomingRate
        guard rate > 0 else { return }
        let measured = (host.now - fadeStartedAt) - contentElapsed / rate
        guard measured.isFinite else { return }
        let clamped = min(max(measured, 0), Self.maxStartLatency)
        startLatency = startLatency > 0 ? (startLatency + clamped) / 2 : clamped
    }

    private func rideFilters(_ progress: Double) {
        let cutoffs = spec.filters.cutoffs(at: progress)
        incoming?.setTransitionFilter(cutoffs.incoming)
        outgoing?.setTransitionFilter(cutoffs.outgoing)
    }

    /// Fades the track playing now to silence over `fade` and pauses — the span a real transition
    /// would have spent on this side of the blend. Deliberately not ``begin`` with no incoming
    /// track: preparing a second decoder only to throw it away is the work this exists to skip.
    private func beginSleepFadeOut(_ fade: TimeInterval) {
        let out = host.activeTransitionDeck
        sleepFadeLength = max(fade, 0.001)
        sleepFadeStartPosition = out.position
        sleepFadeStartGain = out.volume
        outgoing = out
        incoming = nil
        handedOff = false
        PlaybackLog.debug("sleep timer due: fading out over \(fade)s instead of transitioning")
        phase = .sleepFade
        host.transitionStateChanged(isTransitioning: true)
    }

    private func driveSleepFade() {
        guard let out = outgoing else { return finishSleepFade() }
        // The timer was turned off mid-fade: hand the track back at full volume.
        guard host.sleepsAfterCurrentTrack else {
            out.volume = 1
            outgoing = nil
            phase = .idle
            host.transitionStateChanged(isTransitioning: false)
            return
        }
        let elapsed = max(out.position - sleepFadeStartPosition, 0)
        let progress = min(max(elapsed / sleepFadeLength, 0), 1)
        out.volume = sleepFadeStartGain * TransitionGainCurve.equalPowerFall.gain(at: progress)
        if progress >= 1 || out.hasEnded || out.isIdle {
            finishSleepFade()
        }
    }

    private func finishSleepFade() {
        let out = outgoing
        outgoing = nil
        phase = .idle
        if let out { host.finishSleepFade(on: out) }
        host.transitionStateChanged(isTransitioning: false)
    }

    private func driveBail() {
        guard let out = outgoing else { return finish() }
        let progress = (host.now - bailStartedAt) / Self.bailDuration
        if progress < 1 {
            out.volume = bailFromGain * TransitionGainCurve.equalPowerFall.gain(at: progress)
            return
        }
        finish()
    }

    /// Abandons whatever is in flight. Before the handoff the session deck is untouched and the
    /// standby is a silent scratch deck: just retire it. After it, the session has moved and can't
    /// move back, so the outgoing track is taken away gracefully.
    private func bail() {
        guard phase != .idle, phase != .bailing else { return }
        PlaybackLog.debug("bail from \(phase)")
        host.mixInProgressChanged(false)
        guard handedOff else { return finish() }
        // Glided open rather than snapped (the processor glides): a bail can catch a bass swap
        // mid-handover with the incoming track's low end lifted out.
        incoming?.setTransitionFilter(.open)
        outgoing?.setTransitionFilter(.open)
        incoming?.volume = 1
        bailFromGain = outgoing?.volume ?? 0
        bailStartedAt = host.now
        phase = .bailing
    }

    private func finish() {
        if phase != .idle { settledAt = host.now }
        host.mixInProgressChanged(false)
        incoming?.setTransitionFilter(.open)
        outgoing?.setTransitionFilter(.open)
        if handedOff {
            if let incoming {
                incoming.volume = 1
                // Undoes the beatmatch stretch; idempotent when there was none.
                host.setRate(host.playbackSpeed, on: incoming)
            }
            if let outgoing { host.retire(outgoing) }
        } else {
            outgoing?.volume = 1
            if let incoming { host.retire(incoming) }
        }
        outgoing = nil
        incoming = nil
        handedOff = false
        armedItemID = nil
        phase = .idle
        host.transitionStateChanged(isTransitioning: false)
    }

    /// Still a next track, and still switched on by whichever setting armed this one.
    private func stillWorthFading() -> Bool {
        let stillOn = smart ? host.automixActive : host.crossfadeSeconds > 0
        return stillOn && host.transitionUpcomingItem?.id == armedItemID
    }
}
