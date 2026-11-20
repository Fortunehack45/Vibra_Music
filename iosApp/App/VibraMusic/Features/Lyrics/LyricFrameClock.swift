import VibraMusicCore
import Lyrics
import QuartzCore
import UIKit

/// Something drawn off the lyric clock: told on every frame the clock advances.
@MainActor
protocol LyricClockListener: AnyObject {
    func lyricClockDidTick(_ positionMs: Int)
}

/// The song position, ticking every frame (Android: `rememberLyricClock` in PlayerLyrics.kt).
///
/// The player reports where it is a few times a second, which is fine for a scrubber and far too
/// coarse for a highlight that has to keep up with a singer. This carries the last report forward
/// on a display link between reports; ``LyricClockReconciler`` decides when a report is a
/// correction to hold through and when it is a seek to jump to.
///
/// Deliberately not observable: a value that changes sixty times a second must not invalidate
/// SwiftUI bodies. The line views that draw from it register as listeners and redraw their own
/// layers; the panel's line-level state (which row is playing) is updated through `onTick` and only
/// published when it actually changes.
@MainActor
final class LyricFrameClock {
    /// The lyric position (offset already applied), in ms.
    private(set) var positionMs: Int = 0
    private(set) var isPlaying = false

    /// Called on every advance with the new position, before listeners draw.
    var onTick: ((Int) -> Void)?

    private var reconciler: LyricClockReconciler
    private var reportedMs = 0
    private var reportedAt: CFTimeInterval = 0
    private var displayLink: CADisplayLink?
    private let listeners = NSHashTable<AnyObject>.weakObjects()
    /// Frames the clock must keep ticking for even while paused (the translation particles).
    private var animatingUntil: CFTimeInterval = 0
    /// Whether the panel is on screen and the app is in the foreground. The loop is a request to
    /// render continuously; that is right for a lyric being read and wrong for a phone in a pocket.
    /// Coming back re-syncs at once (Android restarts its clock effect on `foreground`).
    var isRunnable = true {
        didSet {
            if isRunnable, !oldValue { resync() }
            if !isRunnable { lastFrameAt = nil }
            updateLink()
        }
    }

    /// Reads the engine's position and play state (offset applied) directly, without waiting for
    /// the next report to make its way through SwiftUI. Used to re-sync the moment frames resume.
    var source: (@MainActor () -> (positionMs: Int, isPlaying: Bool))?

    /// When the last frame arrived; a longer silence than ``frameGap`` means frames stopped (the
    /// window was covered, the app was inactive) and the clock re-syncs before carrying on.
    private var lastFrameAt: CFTimeInterval?
    static let frameGap: CFTimeInterval = 0.25

    private var comparedWithPlayer = false
    private static let comparisonAtMs = 5_000

    /// A monotonic clock in seconds; injectable for tests.
    var now: () -> CFTimeInterval = { CACurrentMediaTime() }

    init(positionMs: Int = 0, isPlaying: Bool = false) {
        self.positionMs = positionMs
        self.isPlaying = isPlaying
        reportedMs = positionMs
        reconciler = LyricClockReconciler(initialReportedMs: positionMs, initialObservedAtMs: 0, initialPlaying: isPlaying)
    }

    /// A new track: forget the last one's reports so its position can't be taken for a seek.
    func reset(positionMs: Int, isPlaying: Bool) {
        let at = now()
        reconciler = LyricClockReconciler(initialReportedMs: positionMs, initialObservedAtMs: Int((at * 1_000).rounded()), initialPlaying: isPlaying)
        self.positionMs = positionMs
        self.isPlaying = isPlaying
        reportedMs = positionMs
        reportedAt = at
        comparedWithPlayer = false
        publish()
        updateLink()
    }

    /// A position report from the player, already shifted by the lyrics offset.
    func report(positionMs reported: Int, isPlaying: Bool) {
        let at = now()
        let displayed = positionMs
        positionMs = reconciler.reconcile(
            displayedMs: displayed,
            reportedMs: reported,
            observedAtMs: Int((at * 1_000).rounded()),
            isPlaying: isPlaying
        )
        logComparison(displayed: displayed, reported: reported)
        reportedMs = reported
        reportedAt = at
        self.isPlaying = isPlaying
        publish()
        updateLink()
    }

    /// Reconciles with the engine's current position right now: on resume, on reappearing, and
    /// when frames restart after a gap. Small corrections hold, discontinuities (a seek, a pause
    /// while nobody was looking) jump. A playing engine that hasn't reported anything new since the
    /// last report is itself stale, so the report plus the time since it stays the best estimate.
    func resync() {
        guard let source else { return }
        let current = source()
        if current.isPlaying, isPlaying, current.positionMs == reportedMs { return }
        report(positionMs: current.positionMs, isPlaying: current.isPlaying)
    }

    /// One frame: advance from the authoritative report, not the held display value — otherwise
    /// each small correction would accumulate into permanent drift.
    func advance() {
        let at = now()
        let resumed = lastFrameAt.map { at - $0 > Self.frameGap } ?? true
        lastFrameAt = at
        if resumed { resync() }
        if reconciler.isAdvancing {
            let elapsed = Int(((now() - reportedAt) * 1_000).rounded())
            positionMs = max(positionMs, reportedMs + max(elapsed, 0))
        }
        publish()
        if !isPlaying && now() >= animatingUntil { updateLink() }
    }

    /// Once a song, some seconds in with the lyrics showing: the words against the player they follow.
    /// Against the sound the player's clock can't be read, so this says which side an early lyric is on.
    private func logComparison(displayed: Int, reported: Int) {
        // Advancing: not paused, and this report isn't a seek.
        guard !comparedWithPlayer, reconciler.isAdvancing, isRunnable, reported >= Self.comparisonAtMs else { return }
        comparedWithPlayer = true
        TrackLog.i("Lyrics", "lyric clock \(displayed)ms, player \(reported)ms: the words are \(displayed - reported)ms ahead of the player")
    }

    /// Keeps frames coming for `seconds` even while paused.
    func animate(for seconds: CFTimeInterval) {
        animatingUntil = max(animatingUntil, now() + seconds)
        updateLink()
    }

    func addListener(_ listener: LyricClockListener) {
        listeners.add(listener)
    }

    func removeListener(_ listener: LyricClockListener) {
        listeners.remove(listener)
    }

    var isTicking: Bool { displayLink != nil }

    private func publish() {
        onTick?(positionMs)
        for case let listener as LyricClockListener in listeners.allObjects {
            listener.lyricClockDidTick(positionMs)
        }
    }

    private func updateLink() {
        let wanted = isRunnable && (isPlaying || now() < animatingUntil)
        if wanted, displayLink == nil {
            let link = CADisplayLink(target: LyricDisplayLinkTarget(self), selector: #selector(LyricDisplayLinkTarget.step))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else if !wanted, let link = displayLink {
            link.invalidate()
            displayLink = nil
        }
    }

    /// The view reappeared: catch up with the engine and restart the frame loop if it's wanted.
    func resume() {
        resync()
        updateLink()
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        lastFrameAt = nil
    }
}

/// Holds the clock weakly, so the display link (which retains its target) can't keep it alive.
private final class LyricDisplayLinkTarget {
    weak var clock: LyricFrameClock?

    init(_ clock: LyricFrameClock) { self.clock = clock }

    @objc func step(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            guard let clock else { return link.invalidate() }
            clock.advance()
        }
    }
}
