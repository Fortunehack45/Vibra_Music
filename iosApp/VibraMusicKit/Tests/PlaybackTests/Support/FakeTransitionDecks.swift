import VibraMusicCore
import Foundation
@testable import Playback

/// A deck whose position, readiness and end state the test sets by hand.
@MainActor
final class FakeDeck: TransitionDeck {
    let name: String
    var volume: Float = 1
    var position: TimeInterval = 0
    var knownDuration: TimeInterval?
    var playWhenReady = false
    var isReadyToPlay = false
    var hasEnded = false
    var isIdle = false
    var rate: Float = 1
    var filters: [TransitionFilterCutoffs] = []
    var retiredCount = 0
    var loadedItemID: String?
    var loadedCue: TimeInterval?

    init(name: String) {
        self.name = name
    }

    var isPlaying: Bool { playWhenReady && !hasEnded && !isIdle }

    var filter: TransitionFilterCutoffs { filters.last ?? .open }

    func setTransitionFilter(_ cutoffs: TransitionFilterCutoffs) {
        filters.append(cutoffs)
    }
}

/// Plays the engine's part for the controller: two fake decks, a queue of two items and a clock.
@MainActor
final class FakeCrossfadeHost: CrossfadeHost {
    var deckA = FakeDeck(name: "A")
    var deckB = FakeDeck(name: "B")
    lazy var active: FakeDeck = deckA
    lazy var standby: FakeDeck = deckB
    var current: PlayableItem?
    var upcoming: PlayableItem?
    var currentEnd: TimeInterval?
    var upcomingDuration: TimeInterval?
    var crossfadeSeconds: TimeInterval = 6
    var automixActive = false
    var planner: TransitionPlanning?
    var transitionsSuspended = false
    var sleepsAfterCurrentTrack = false
    var playbackSpeed: Float = 1
    var now: TimeInterval = 100

    var armed: [(item: PlayableItem, cue: TimeInterval, rate: Float)] = []
    var handoffs = 0
    var sleepFadesFinished = 0
    var transitioning = false
    var mixInProgress = false
    var window: TransitionWindow?
    var windowUpdates = 0

    var activeTransitionDeck: TransitionDeck { active }
    var standbyTransitionDeck: TransitionDeck { standby }
    var transitionCurrentItem: PlayableItem? { current }
    var transitionUpcomingItem: PlayableItem? { upcoming }
    var transitionCurrentEnd: TimeInterval? { currentEnd }
    var transitionUpcomingDuration: TimeInterval? { upcomingDuration }
    var transitionPlanner: TransitionPlanning? { planner }

    func armIncoming(_ item: PlayableItem, cue: TimeInterval, rate: Float) {
        armed.append((item, cue, rate))
        standby.loadedItemID = item.id
        standby.loadedCue = cue
        standby.position = cue
        standby.volume = 0
        standby.rate = rate
        standby.playWhenReady = false
        standby.knownDuration = upcomingDuration
    }

    func handOffToStandby() {
        handoffs += 1
        swap(&active, &standby)
        current = upcoming
        currentEnd = active.knownDuration
        upcoming = nil
    }

    func retire(_ deck: TransitionDeck) {
        guard let deck = deck as? FakeDeck else { return }
        deck.retiredCount += 1
        deck.playWhenReady = false
        deck.volume = 1
        deck.rate = playbackSpeed
        deck.loadedItemID = nil
        deck.hasEnded = false
        deck.isReadyToPlay = false
    }

    func setRate(_ rate: Float, on deck: TransitionDeck) {
        (deck as? FakeDeck)?.rate = rate
    }

    func finishSleepFade(on deck: TransitionDeck) {
        sleepFadesFinished += 1
        deck.playWhenReady = false
        deck.volume = 1
        sleepsAfterCurrentTrack = false
    }

    func transitionStateChanged(isTransitioning: Bool) {
        transitioning = isTransitioning
    }

    func mixInProgressChanged(_ inProgress: Bool) {
        mixInProgress = inProgress
    }

    func transitionWindowChanged(_ window: TransitionWindow?) {
        self.window = window
        windowUpdates += 1
    }

    static func item(_ id: String, duration: TimeInterval? = nil, videoOrigin: Bool = false) -> PlayableItem {
        PlayableItem(id: id, title: id, artist: "Artist", duration: duration, source: .file(URL(fileURLWithPath: "/tmp/\(id).caf")), isVideoOrigin: videoOrigin)
    }

    /// A host mid-way through a 30 s track, playing, with a 30 s track queued after it.
    static func playing(duration: TimeInterval = 30, incoming: TimeInterval = 30) -> FakeCrossfadeHost {
        let host = FakeCrossfadeHost()
        host.current = item("one", duration: duration)
        host.upcoming = item("two", duration: incoming)
        host.currentEnd = duration
        host.upcomingDuration = incoming
        host.deckA.knownDuration = duration
        host.deckA.playWhenReady = true
        return host
    }
}

/// Returns the spec it was given, and records what it was asked.
@MainActor
final class StubPlanner: TransitionPlanning {
    var spec: TransitionSpec?
    var contexts: [TransitionContext] = []

    init(spec: TransitionSpec?) {
        self.spec = spec
    }

    func transitionSpec(for context: TransitionContext) -> TransitionSpec? {
        contexts.append(context)
        return spec
    }
}
