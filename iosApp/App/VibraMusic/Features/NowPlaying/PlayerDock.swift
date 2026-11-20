import VibraMusicCore
import SwiftUI
import UIKit

/// The mini player's cover as one tab's bar last placed it, in window points.
struct MiniArt: Equatable {
    var rect: CGRect
    var corner: CGFloat
}

/// One frame of the player between the mini player and fully open: everything a view needs, as a
/// value. Built by ``PlayerDock/frame(miniOn:)``; pure from here down.
struct DockFrame: Equatable {
    /// 1 fully open, 0 down on the mini player. The real position: the player is offset by it.
    var fraction: CGFloat
    /// Window height, the whole of the player's travel.
    var travel: CGFloat
    /// Where the artwork docks this frame. Nil: nothing to dock into.
    var mini: MiniArt?
    /// A player is up, there is a cover to dock into, and Reduce animation is off.
    var docks: Bool
    /// How strong the top edge's dissolve is this frame, 0 to 1. Built by the dock; see
    /// ``PlayerDock/edgeShare``.
    var edgeShare: CGFloat = 0

    /// What the artwork and the fade read: held at 1 while not docking (Android's `dockT`).
    var t: CGFloat { docks ? fraction : 1 }
    /// How far below fully open the player is drawn (Android's `position()`). Docked on the mini
    /// player the player is invisible (fade 0), so it stays laid out on screen instead: a view
    /// parked below the window gets no geometry updates, and its first layout was the one the
    /// whole flight landed on (verify 53 and 57).
    var stageOffset: CGFloat { docks && fraction == 0 ? 0 : (1 - fraction) * travel }
    /// Never quite 0: a view at opacity 0 is dropped from the render tree and stops reporting its
    /// geometry, so a player docked on the mini player would keep its first layout (Android's 1/255).
    var fade: Double { max(Double(PlayerDockMotion.fade(t)), 1.0 / 255) }
    var scrim: Double { PlayerDockMotion.scrimAlpha * Double(fraction) }
    /// How deep the sheet's top edge has dissolved this frame, in points: up as soon as it moves,
    /// clear as it lands. 0 when not docking (Reduce animation, nothing to dock into).
    var edge: CGFloat { docks ? edgeShare * PlayerDockMotion.edgeBand(travel: travel) : 0 }
    /// `edge` as a share of the band at full strength: 0 to 1.
    var edgeStrength: CGFloat { docks ? edgeShare : 0 }
    /// The nerd stats are drawn at the artwork's open place, not flown with it, so while the
    /// artwork is in flight to the mini cover they hang in the air: shown only at rest. Not
    /// docking, the stats ride the stage with the artwork.
    var showsStats: Bool { !docks || fraction == 1 }

    /// Where and how the artwork is drawn this frame, in window points. At t = 1 it is `open`
    /// with the rest shape and pose. Not docking, it rides the stage: `open` pushed down by the
    /// player's own offset, with nothing blended.
    func artwork(open: CGRect, shape: ArtworkShape, pose: ArtworkPose) -> ArtworkPlacement {
        guard docks, let mini else {
            return ArtworkPlacement(
                rect: open.offsetBy(dx: 0, dy: stageOffset),
                corner: shape.dissolves ? 0 : shape.corner,
                shadow: shape.castsShadow && !shape.dissolves ? 1 : 0,
                dissolve: shape.dissolves ? 1 : 0,
                scale: pose.scale, offset: pose.offset
            )
        }
        let shown = shape.dissolves ? t : 0
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a * (1 - t) + b * t }
        return ArtworkPlacement(
            rect: PlayerDockMotion.rect(open: open, mini: mini.rect, t: t, travel: travel),
            corner: lerp(mini.corner, shape.dissolves ? PlayerDockMotion.cardCorner * (1 - shown) : shape.corner),
            shadow: shape.castsShadow ? max(1 - 2 * shown, 0) * t : 0,
            dissolve: shown,
            scale: 1 - t + pose.scale * t,
            offset: CGSize(width: pose.offset.width * t, height: pose.offset.height * t)
        )
    }
}

/// The artwork's resting look on one surface.
struct ArtworkShape: Equatable {
    /// 8 on the card, 6 on the collapsed thumb, 10 in landscape. The banner computes its own.
    var corner: CGFloat
    /// A picture is showing: the placeholder tile casts no shadow.
    var castsShadow: Bool
    /// The full-bleed banner: its gradient foot and its square corners belong to rest.
    var dissolves = false

    var role: ArtworkRole { dissolves ? .banner : .sleeve }
}

/// Which drawn artwork this is: the sleeve and the banner are told apart in the probe.
enum ArtworkRole: Hashable { case sleeve, banner }

/// The artwork's own moves at rest (paused shrink, skip nudge, queue-pull lift), blended out by t.
struct ArtworkPose: Equatable {
    var scale: CGFloat = 1
    var offset: CGSize = .zero
    static let rest = ArtworkPose()
}

struct ArtworkPlacement: Equatable {
    /// Window points.
    var rect: CGRect
    var corner: CGFloat
    /// Share of the rest shadow (0.35 / r14 / y8).
    var shadow: CGFloat
    /// Share of the banner's gradient foot; 0 is a hard edge.
    var dissolve: CGFloat
    var scale: CGFloat
    var offset: CGSize
}

/// Android 1.8's numbers and the decisions built on them. No views, no state.
enum PlayerDockMotion {
    static let stiffness: Double = 195
    static let settledPoints: CGFloat = 0.5
    /// The least time a slide takes over what is left of its way: a release can't hand over more
    /// speed than covers the remaining distance in this long.
    static let leastSettle: CGFloat = 0.15
    static let fadeLead: CGFloat = 0.15
    static let scrimAlpha: Double = 0.32
    static let flickSpeed: CGFloat = 400
    static let pullBias: CGFloat = 1.5
    static let liftRate: CGFloat = 0.5
    static let liftEase: CGFloat = 72
    static let pullTopMargin: CGFloat = 100
    /// Under Reduce animation the same spring runs this much faster, landing near the old 0.2 s ease.
    static let reducedPace: Double = 3.5
    static let cardCorner: CGFloat = 8
    /// The dissolving band along the moving sheet's top edge at full strength: a fifth of the
    /// window's height (180 pt on a 6.1" phone, 250 on a 12.9" iPad), kept between a landscape
    /// phone's 96 and 260 so a short window still shows the content under the band.
    static func edgeBand(travel: CGFloat) -> CGFloat { clamp(travel * 0.21, 96, 260) }
    /// How much of the system's dark blur the band reaches at its edge.
    static let edgeBlur: CGFloat = 0.45
    static let layoutWait: Duration = .milliseconds(300)
    static let layoutQuiet: Duration = .milliseconds(80)
    static let liftSpringBack = Animation.interpolatingSpring(mass: 1, stiffness: 400, damping: 26)

    static func rect(open: CGRect, mini: CGRect, t: CGFloat, travel: CGFloat) -> CGRect {
        let ride = travel > 0 ? clamp((mini.minY - open.minY) / travel, 0, 1) : 0
        let from = open.offsetBy(dx: 0, dy: (1 - t) * travel * ride)
        func lerp(_ a: CGFloat, _ b: CGFloat, by share: CGFloat) -> CGFloat { a * (1 - share) + b * share }
        // The size leaves its rest with no speed: taken straight from t, a banner dropped into an
        // inset card with its edges showing the moment the sheet moved.
        let grown = 1 - (1 - t) * (1 - t)
        return CGRect(
            x: lerp(mini.minX, from.minX, by: grown),
            y: flightY(open: open, mini: mini, t: t, travel: travel) ?? lerp(mini.minY, from.minY, by: t),
            width: lerp(mini.width, from.width, by: grown), height: lerp(mini.height, from.height, by: grown)
        )
    }

    /// The artwork's height on a trip: it leaves its place at the sheet's own speed and lands on
    /// the mini cover at no speed. Eased toward its place alone, it trailed the header by about 50 pt
    /// halfway up and caught up in the spring's last stretch: the cover snapped into its slot on
    /// arrival. Nil when the cover is too near the top for this curve to stay above it.
    private static func flightY(open: CGRect, mini: CGRect, t: CGFloat, travel: CGFloat) -> CGFloat? {
        // On the mini player it is exactly the cover, which this sum misses by a rounding error.
        guard travel > 0, t > 0 else { return nil }
        let ride = (mini.minY - open.minY) / travel
        guard ride >= 1.0 / 3 else { return nil }
        let left = 1 - t
        return open.minY + travel * (left + (3 * ride - 2) * left * left + (1 - 2 * ride) * left * left * left)
    }

    static func fade(_ t: CGFloat) -> CGFloat { clamp((t - fadeLead) / (1 - fadeLead), 0, 1) }

    /// The banner's clip over its still cover. They are framed differently, so blended across the
    /// trip they read as a double exposure: the clip goes only near the mini cover, where the
    /// artwork is small.
    static func clipFade(_ t: CGFloat) -> CGFloat { clamp((t - 0.05) / 0.15, 0, 1) }

    /// The band's depth by how far through the move the player is: up to full over the first 30% of
    /// the way, then clearing at one steady rate until it lands. Held to 68% and cleared on a curve,
    /// the sheet's visible edge suddenly ran about 40% faster near the top; up in 7%, a small drag
    /// took the handle and caption away at once.
    static func edge(_ moved: CGFloat, travel: CGFloat) -> CGFloat {
        edgeBand(travel: travel) * edgeShare(moved)
    }

    /// ``edge(_:travel:)`` as a share of the band, 0 to 1.
    static func edgeShare(_ moved: CGFloat) -> CGFloat {
        guard moved > 0, moved < 1 else { return 0 }
        return min(moved / 0.3, (1 - moved) / 0.7)
    }

    /// A finger's travel scaled so that reaching the window's far edge is the whole way. A pull
    /// up starts on the mini player, above the window's bottom, and a drag down starts below its
    /// top: followed 1:1 the finger ran out with the player still short of the end, and the
    /// release covered the rest in a frame or two, a jump (55 pt in a windowed iPad app).
    /// `start` and `edge` are window points; at most twice the finger's travel.
    static func reach(_ translation: CGFloat, from start: CGFloat, toward edge: CGFloat, travel: CGFloat) -> CGFloat {
        let room = abs(edge - start)
        guard room > 1, travel > 0 else { return translation }
        return translation * clamp(travel / room, 1, 2)
    }

    /// How far below fully open a pull from the mini player holds the player. Fully open comes
    /// ``pullTopMargin`` short of the window's top, where a finger stops: reaching only for the edge
    /// itself, the player stopped about 65 pt short under the finger and the release jumped the rest.
    static func pullOffset(_ translation: CGFloat, from start: CGFloat, travel: CGFloat) -> CGFloat {
        travel + reach(translation, from: start, toward: pullTopMargin, travel: travel)
    }

    static func pullLift(_ pulled: CGFloat) -> CGFloat {
        liftRate * 2 * liftEase * ((1 + max(pulled, 0) / liftEase).squareRoot() - 1)
    }

    enum MiniAxis: Equatable { case pull, swipe, scroll }
    /// Decided once, at the slop: up and within 1.5× sideways is a pull; mostly sideways is a skip
    /// swipe; anything else belongs to the page behind. `pullAllowed` false turns pulls into scrolls.
    static func miniAxis(_ translation: CGSize, pullAllowed: Bool) -> MiniAxis {
        let dx = abs(translation.width), dy = translation.height
        if dy < 0, dx < -dy * pullBias { return pullAllowed ? .pull : .scroll }
        return dx > abs(dy) ? .swipe : .scroll
    }

    /// A released pull: the faster of the lift-off and whole-pull speeds; a flick (≥ 400 pt/s)
    /// decides by direction, otherwise above half way opens. `offset` is how far below fully open
    /// the player was let go; velocities in pt/s, + = downward.
    static func pullRelease(offset: CGFloat, travel: CGFloat,
                            releaseVelocity: CGFloat, averageVelocity: CGFloat) -> (opens: Bool, velocity: CGFloat) {
        let speed = abs(releaseVelocity) >= abs(averageVelocity) ? releaseVelocity : averageVelocity
        let opens = abs(speed) >= flickSpeed ? speed < 0 : offset < travel / 2
        return (opens, speed)
    }

    /// Critically damped spring, closed form. Settled once within
    /// `threshold` of the target; the value is clamped to [0, 1].
    static func spring(from: CGFloat, to: CGFloat, velocity: CGFloat,
                       elapsed: TimeInterval, threshold: CGFloat) -> (value: CGFloat, velocity: CGFloat, settled: Bool) {
        let omega = stiffness.squareRoot()
        let tau = max(elapsed, 0)
        let d = Double(from - to), v = Double(velocity)
        let decay = exp(-omega * tau)
        let x = Double(to) + (d + (v + omega * d) * tau) * decay
        let speed = (v - omega * (v + omega * d) * tau) * decay
        let value = clamp(CGFloat(x), 0, 1)
        return (value, CGFloat(speed), abs(CGFloat(x) - to) <= threshold)
    }

    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(max(value, low), high)
    }
}

/// Where Now Playing is between the mini player and fully open, and the only thing that moves it.
/// Opened with `open`, closed with `close`, held under a finger with `hold`, whoever asks.
@MainActor
@Observable
final class PlayerDock {
    private(set) var isPresented = false
    /// 0 on the mini player, 1 open. Read per frame, only through ``DockFrame``.
    private(set) var fraction: CGFloat = 0
    /// The mini cover stands aside (Android `coversMiniArt`). Flips twice a trip.
    private(set) var coversMiniArt = false
    /// A trip is under way: canvas clips pause. Flips twice a trip.
    private(set) var isMoving = false
    /// The banner is drawn over the rest of the player. Only once that has faded out, so the change
    /// of order can't be seen. Flips twice a trip.
    private(set) var bannerOverPlayer = false
    /// Window height, written by RootTabView only.
    var travel: CGFloat = 0
    /// Pulls from the mini player are on (off under Reduce animation, or before a window is measured).
    var allowsPull: Bool { travel > 0 && !reduced() }

    private var miniArt: [AppTab: MiniArt] = [:]
    private var attached = false
    @ObservationIgnored private var lastLayoutChange = ContinuousClock.now
    /// Whether the full-bleed banner stands in for the sleeve. Latched for a trip: a report is taken
    /// only at rest, before the slide has moved, or when none is held yet, so a banner that settles
    /// mid-open swaps in at t = 1. The landing rect itself stays live: the layout is still settling
    /// in the first frames of an open, and a rect latched then flew to the wrong place (verify 47).
    @ObservationIgnored private var landingIsBanner: Bool?
    @ObservationIgnored private var closing = false
    @ObservationIgnored private var held = false
    /// The way the player is heading: set as a finger takes hold and as a slide starts.
    @ObservationIgnored private var headingUp = true
    /// A slide that turned back mid-trip: the edge's strength as it turned, let go over the
    /// slide's span. Outlives the slide when a finger catches it; a new trip clears it.
    @ObservationIgnored private var carry: (share: CGFloat, from: CGFloat, to: CGFloat)?
    @ObservationIgnored private var slide: Slide?
    @ObservationIgnored private var pendingOpenVelocity: CGFloat?
    @ObservationIgnored private var layoutWait: Task<Void, Never>?
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private let reduced: @MainActor () -> Bool
    @ObservationIgnored private let drivesFrames: Bool

    private struct Slide {
        var from: CGFloat, to: CGFloat, velocity: CGFloat   // fraction units, fraction/s
        var start: CFTimeInterval?
        var then: (@MainActor () -> Void)?
    }

    init(reduced: @escaping @MainActor () -> Bool = PlayerDock.systemReduced, drivesFrames: Bool = true) {
        self.reduced = reduced
        self.drivesFrames = drivesFrames
    }

    /// Reduce animation, the app's switch or the system's.
    static func systemReduced() -> Bool {
        #if DEBUG
        // A drive can't flip either switch from a launch argument: `-dockReduce YES`.
        if UserDefaults.standard.bool(forKey: "dockReduce") { return true }
        #endif
        return AppSettings.shared.reduceAnimation || UIAccessibility.isReduceMotionEnabled
    }

    func frame(miniOn tab: AppTab) -> DockFrame {
        let mini = miniArt[tab]
        return DockFrame(fraction: fraction, travel: travel, mini: mini,
                         docks: isPresented && mini != nil && !reduced(), edgeShare: edgeShare)
    }

    /// How far along the whole trip the player is, by the way it is heading: the fraction going
    /// up, 1 − fraction going down. The whole trip, not the current slide: a finger let go near
    /// the top hands over to a short slide, and measured from the slide's own start the band
    /// would flash full again over its last few points. At rest the player is where it was
    /// heading, 1.
    private var moved: CGFloat { min(max(headingUp ? fraction : 1 - fraction, 0), 1) }

    /// The dissolve's strength: the curve along the trip, except on a slide that turned back from
    /// the way the player was heading (a pull let go short, a drag flicked back open). Its trip
    /// starts over from the far end, where the curve reads differently, so such a slide carries
    /// the strength it started with and lets it go as it lands.
    private var edgeShare: CGFloat {
        if let carry, carry.to != carry.from {
            return carry.share * (1 - min(max((fraction - carry.from) / (carry.to - carry.from), 0), 1))
        }
        return PlayerDockMotion.edgeShare(moved)
    }

    var presentation: Binding<Bool> {
        Binding(get: { self.isPresented }, set: { on in
            if !on, self.isPresented { self.reset() }
        })
    }

    /// Slides the player fully open from wherever it is, carrying `velocity` (pt/s, + = down).
    /// Not presented: raises the cover at fraction 0 with no UIKit slide, and starts once the
    /// player has appeared (≤ 300 ms). Idempotent while already opening or open.
    func open(velocity: CGFloat = 0) {
        held = false
        if isPresented {
            if pendingOpenVelocity != nil { return }
            if !closing, slide == nil, fraction == 1 { return }
            if !closing, slide?.to == 1, velocity == 0 { return }
        }
        closing = false
        guard !isPresented else {
            start(to: 1, velocity: velocity)
            return
        }
        setFraction(0)
        pendingOpenVelocity = velocity
        setPresented(true)
        layoutWait = Task { [weak self] in
            try? await Task.sleep(for: PlayerDockMotion.layoutWait)
            guard !Task.isCancelled else { return }
            self?.startPendingOpen()
        }
    }

    /// Docks the player into the mini player from wherever it is, then drops the cover with no
    /// slide of its own. A second call while closing does nothing (Android's `closing` guard).
    func close(velocity: CGFloat = 0) {
        held = false
        guard isPresented, !closing else { return }
        closing = true
        cancelPendingOpen()
        if fraction == 0 || travel <= 0 { return finishClose() }
        start(to: 0, velocity: max(velocity, 0)) { [self] in finishClose() }
    }

    /// A finger holds the player `offset` points below fully open. Cancels any slide. From a
    /// closed player (the mini player's pull) it raises the cover first, if pulls are allowed.
    func hold(offset: CGFloat) {
        guard travel > 0 else { return }
        // A finger caught at rest heads away from the end it is at; one caught mid-slide keeps the
        // slide's heading (set when it started), so the band doesn't jump at the catch.
        if !self.held, slide == nil {
            headingUp = !isPresented || fraction < 0.5
            carry = nil
        }
        let held = min(max(1 - offset / travel, 0), 1)
        if !isPresented {
            guard allowsPull else { return }
            setFraction(held)
            setPresented(true)
        } else {
            #if DEBUG
            holds.record(held)
            #endif
        }
        slide = nil
        stopLink()
        closing = false
        self.held = true
        cancelPendingOpen()
        setFraction(held)
        refreshFlags()
    }

    /// A gesture the system cancelled never released its hold: settle the player rather than leave
    /// it part-way. The mini player's pull docks; the open player's own drags settle open. A no-op
    /// once `open` or `close` has decided.
    func abandonHold(settlingOpen: Bool = false) {
        guard held else { return }
        if settlingOpen { open() } else { close() }
    }

    func reportBanner(_ isBanner: Bool) {
        guard acceptsReports || landingIsBanner == nil else { return }
        landingIsBanner = isBanner
    }

    func isBanner(live: Bool) -> Bool {
        isMoving ? landingIsBanner ?? live : live
    }

    private var acceptsReports: Bool { fraction == 0 || fraction == 1 }

    /// A tab's cover is kept once placed, through the tab going off screen: a hidden tab's bar
    /// gets `onDisappear` while another tab is up, and coming back relays it out only if its place
    /// moved, so a rect dropped there was never reported again and the cover slid instead of
    /// flying. A bar that is rebuilt reports its place again on its first layout.
    func reportMiniArt(_ art: MiniArt, on tab: AppTab) {
        if miniArt[tab] != art { miniArt[tab] = art }
    }

    func playerDidAppear() {
        attached = true
        if drivesFrames { startOnceLayoutSettles() } else { startPendingOpen() }
        refreshFlags()
    }

    /// The artwork's landing moved (called by `.docked`). The player has been laid out in
    /// stages, so a flight that starts on the first pass heads for a place that is gone by the
    /// time it arrives.
    func layoutDidChange() {
        lastLayoutChange = ContinuousClock.now
    }

    func playerDidDisappear() {
        attached = false
        refreshFlags()
    }

    /// Advances the slide to `now` (display link; tests call it directly with `drivesFrames: false`).
    func step(to now: CFTimeInterval) {
        guard var current = slide else { return }
        let start = current.start ?? now
        if current.start == nil {
            current.start = now
            slide = current
        }
        let result = PlayerDockMotion.spring(
            from: current.from, to: current.to, velocity: current.velocity,
            elapsed: (now - start) * (reduced() ? PlayerDockMotion.reducedPace : 1) / Self.timeScale,
            threshold: PlayerDockMotion.settledPoints / max(travel, 1)
        )
        setFraction(result.settled ? current.to : result.value)
        refreshFlags()
        guard result.settled else { return }
        slide = nil
        stopLink()
        current.then?()
    }

    // MARK: Private

    private func start(to target: CGFloat, velocity: CGFloat, then: (@MainActor () -> Void)? = nil) {
        let up = target >= fraction
        let midTrip = fraction > 0 && fraction < 1
        // Turned back mid-trip: carry the strength from here. Carrying on the same way mid-trip
        // keeps any carry already running; from either end a new trip starts.
        if !midTrip {
            carry = nil
        } else if up != headingUp {
            carry = (edgeShare, fraction, target)
        }
        headingUp = up
        // A finger let go near the end hands over its speed at lift-off, which spikes; uncapped it
        // crossed the last 15-20 pt in one frame, overshot and was stopped at the end: the player
        // jumped to the top (measured from a screen recording). Capped by the distance left, a flick from midway
        // keeps its speed and a release near the end settles over a few frames.
        let cap = abs(target - fraction) / PlayerDockMotion.leastSettle
        let speed = min(max(-velocity / max(travel, 1), -cap), cap)
        slide = Slide(from: fraction, to: target, velocity: speed, start: nil, then: then)
        if drivesFrames { startLink() }
    }

    /// Starts a waiting open once the layout has been quiet for `layoutQuiet`; `layoutWait` still
    /// starts it at the latest.
    private func startOnceLayoutSettles() {
        Task { [weak self] in
            while let self, self.pendingOpenVelocity != nil, ContinuousClock.now - self.lastLayoutChange < PlayerDockMotion.layoutQuiet {
                try? await Task.sleep(for: .milliseconds(20))
            }
            self?.startPendingOpen()
        }
    }

    private func startPendingOpen() {
        guard let velocity = pendingOpenVelocity, isPresented else { return }
        cancelPendingOpen()
        start(to: 1, velocity: velocity)
    }

    private func cancelPendingOpen() {
        pendingOpenVelocity = nil
        layoutWait?.cancel()
        layoutWait = nil
    }

    private func finishClose() {
        landingIsBanner = nil
        slide = nil
        stopLink()
        setFraction(0)
        setPresented(false)
        closing = false
        refreshFlags()
    }

    private func reset() {
        landingIsBanner = nil
        slide = nil
        stopLink()
        cancelPendingOpen()
        closing = false
        held = false
        setFraction(0)
        isPresented = false
        refreshFlags()
    }

    private func setPresented(_ presented: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { isPresented = presented }
    }

    private func setFraction(_ value: CGFloat) {
        if fraction != value { fraction = value }
    }

    /// Writes `isMoving` / `coversMiniArt` only when they change (@Observable doesn't dedupe).
    private func refreshFlags() {
        let calm = reduced()
        let moving = isPresented && fraction < 1 && !calm && !miniArt.isEmpty
        let covers = isPresented && attached && !calm && fraction > 0
        if moving != isMoving { isMoving = moving }
        let over = moving && fraction <= PlayerDockMotion.fadeLead
        if over != bannerOverPlayer { bannerOverPlayer = over }
        // Not moving, nothing is latched: the next trip locks in what the player shows when it
        // starts (see ``reportBanner(_:)``). Kept, a banner that settled mid-open was still latched
        // as the sleeve, and the close began by snapping the whole layout to it. Cleared on every
        // pass at rest, not only as the flag flips, which a trip with no mini cover never does.
        if !moving { landingIsBanner = nil }
        if covers != coversMiniArt { coversMiniArt = covers }
    }

    private func startLink() {
        guard link == nil else { return }
        let clock = FrameClock { [weak self] timestamp in self?.step(to: timestamp) }
        let link = CADisplayLink(target: clock, selector: #selector(FrameClock.fire(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    #if DEBUG
    /// `-dockTimeScale N` runs the clock N times slower, so a drive can screenshot any frame of
    /// a tap-open or a close without a finger holding it.
    private static let timeScale: Double = max(UserDefaults.standard.double(forKey: "dockTimeScale"), 1)

    /// Where each artwork was last placed, in window points, for the probe.
    var probeArt: [ArtworkRole: CGRect] = [:]
    var probeOpen: [ArtworkRole: CGRect] = [:]
    var probeShown: [ArtworkRole: CGRect] = [:]

    /// What `hold` saw after the cover was already up.
    @ObservationIgnored fileprivate(set) var holds = HoldTrace()
    struct HoldTrace {
        var count = 0
        var low: CGFloat = 1
        var high: CGFloat = 0
        mutating func record(_ fraction: CGFloat) {
            count += 1
            low = min(low, fraction)
            high = max(high, fraction)
        }
    }
    #else
    private static let timeScale: Double = 1
    #endif
}

/// The display link's target: a plain NSObject, since a `CADisplayLink` wants a selector.
@MainActor
private final class FrameClock: NSObject {
    private let tick: @MainActor (CFTimeInterval) -> Void
    init(tick: @escaping @MainActor (CFTimeInterval) -> Void) { self.tick = tick }
    @objc func fire(_ link: CADisplayLink) { tick(link.timestamp) }
}

extension AppRouter {
    var dockFrame: DockFrame { nowPlaying.frame(miniOn: selectedTab) }
}

extension View {
    /// The whole player: offset by the real position, with the 0.32·fraction scrim behind it from
    /// the window's top. Applied once, in NowPlayingScreen. The only per-frame reader, so a frame
    /// invalidates this body and not the player's.
    func dockStage() -> some View { modifier(DockStage()) }
    /// The rest of the player: opacity `fade(t)`, gone with 15% of the way still to go, and cut
    /// clear along the moving sheet's top edge. Backdrop, foreground, landscape content and the
    /// banner's clip. What rides the flying artwork (its canvas, the nerd stats) passes
    /// `cutsEdge: false`: the edge is the sheet's, and the artwork flies out past it.
    func dockFade(cutsEdge: Bool = true) -> some View { modifier(DockFade(cutsEdge: cutsEdge)) }
    /// The banner's clip: opacity ``PlayerDockMotion/clipFade(_:)``, never quite 0, for the reason
    /// ``DockFrame/fade`` gives.
    func dockClipFade() -> some View { modifier(DockClipFade()) }
    /// The nerd stats on the artwork's foot: faded like the rest of the player, and not drawn
    /// while the artwork is flying, since they don't fly with it.
    func dockStats() -> some View { modifier(DockStats()) }
    /// The artwork at `open` (in this view's space), flown to the mini cover by t: frame, position,
    /// corner clip, shadow, banner dissolve and pose. At t = 1 it is the artwork's rest look.
    /// Rides inside the stage, so its place is the window place less the stage's offset.
    func docked(open: CGRect, shape: ArtworkShape, pose: ArtworkPose = .rest) -> some View {
        modifier(Docked(open: open, shape: shape, pose: pose))
    }
    /// A place in the layout the artwork is drawn into. Gestures and accessibility stay on it.
    func artworkSlot(_ surface: ArtworkSurface) -> some View {
        anchorPreference(key: ArtworkSlotKey.self, value: .bounds) { [ArtworkSlot(bounds: $0, surface: surface)] }
    }
}

/// A slot's surface. The card and the collapsed thumb are both alive for the length of the
/// collapse, so the overlay picks the one the pane wants.
enum ArtworkSurface: Equatable { case card, thumb, landscape }

struct ArtworkSlot {
    var bounds: Anchor<CGRect>
    var surface: ArtworkSurface
}

struct ArtworkSlotKey: PreferenceKey {
    static let defaultValue: [ArtworkSlot] = []
    static func reduce(value: inout [ArtworkSlot], nextValue: () -> [ArtworkSlot]) { value += nextValue() }
}

private struct DockFade: ViewModifier {
    let cutsEdge: Bool
    @Environment(AppRouter.self) private var router

    @ViewBuilder
    func body(content: Content) -> some View {
        let frame = router.dockFrame
        let edge = cutsEdge ? frame.edge : 0
        if edge >= 1 {
            content
                .opacity(frame.fade)
                .mask { EdgeMask(edge: edge, sheetTop: frame.stageOffset) }
        } else {
            content
                .opacity(frame.fade)
        }
    }
}

private struct DockClipFade: ViewModifier {
    @Environment(AppRouter.self) private var router

    func body(content: Content) -> some View {
        content.opacity(max(Double(PlayerDockMotion.clipFade(router.dockFrame.t)), 1.0 / 255))
    }
}

private struct DockStats: ViewModifier {
    @Environment(AppRouter.self) private var router

    func body(content: Content) -> some View {
        let shown = router.dockFrame.showsStats
        content
            .dockFade(cutsEdge: false)
            .opacity(shown ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: shown)
    }
}

private struct Docked: ViewModifier {
    let open: CGRect
    let shape: ArtworkShape
    let pose: ArtworkPose
    @Environment(AppRouter.self) private var router

    func body(content: Content) -> some View {
        let dock = router.nowPlaying
        let frame = router.dockFrame
        // Placed against where this space really is in the window, read in the same pass as the
        // stage's offset: the space's origin moves with the stage, so no anchor measured once
        // would hold.
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            let window = open.offsetBy(dx: origin.x, dy: origin.y - frame.stageOffset)
            let placed = frame.artwork(open: window, shape: shape, pose: pose)
            let rect = placed.rect
            content
                .frame(width: rect.width, height: rect.height)
                #if DEBUG
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { dock.probeShown[shape.role] = $0 }
                #endif
                .modifier(BannerDissolve(share: shape.dissolves ? placed.dissolve : nil))
                .clipShape(RoundedRectangle(cornerRadius: placed.corner, style: .continuous))
                .shadow(color: .black.opacity(0.35 * placed.shadow), radius: 14, y: 8)
                .animation(.easeOut(duration: 0.25), value: shape.castsShadow)
                .scaleEffect(placed.scale)
                .offset(placed.offset)
                .position(x: rect.midX - origin.x, y: rect.midY - origin.y)
                #if DEBUG
                .onChange(of: rect, initial: true) { _, rect in
                    dock.probeArt[shape.role] = rect
                    dock.probeOpen[shape.role] = window
                }
                .onDisappear {
                    dock.probeArt[shape.role] = nil
                    dock.probeOpen[shape.role] = nil
                    dock.probeShown[shape.role] = nil
                }
                #endif
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: open, initial: true) { dock.layoutDidChange() }
    }
}

/// The banner's gradient foot: black down to the dissolve's start, then to `1 − share` at the bottom.
/// A sleeve passes nil and is not masked, so it is not drawn into a buffer of its own.
private struct BannerDissolve: ViewModifier {
    let share: CGFloat?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let share {
            content.mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 1 - NowPlayingLayout.heroFadeFraction),
                        .init(color: .black.opacity(1 - share), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
        } else {
            content
        }
    }
}

private struct DockStage: ViewModifier {
    @Environment(AppRouter.self) private var router

    func body(content: Content) -> some View {
        let frame = router.dockFrame
        content
            .compositingGroup()
            .offset(y: frame.stageOffset)
            .background { Color.black.opacity(frame.scrim).ignoresSafeArea() }
    }
}

#if DEBUG
extension View {
    /// An invisible element a verify drive reads: `t=0.430 fraction=0.430 mini=x,y,w,h art=x,y,w,h covered=1 presented=1 holds=n low=a high=b`.
    func dockProbe() -> some View { overlay(alignment: .topLeading) { DockProbe() } }
}

private struct DockProbe: View {
    @Environment(AppRouter.self) private var router

    private static func text(_ rect: CGRect?) -> String {
        rect.map { [$0.minX, $0.minY, $0.width, $0.height].map { String(Int($0.rounded())) }.joined(separator: ",") } ?? "none"
    }

    var body: some View {
        let frame = router.dockFrame
        let dock = router.nowPlaying
        let holds = dock.holds
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel("dock")
            .accessibilityIdentifier("dock.probe")
            .accessibilityValue(String(
                format: "t=%.3f fraction=%.3f mini=%@ art=%@ shown=%@ open=%@ covered=%d presented=%d holds=%d low=%.3f high=%.3f",
                Double(frame.t), Double(frame.fraction), Self.text(frame.mini?.rect), Self.text(dock.probeArt[.sleeve] ?? dock.probeArt[.banner]), Self.text(dock.probeShown[.sleeve] ?? dock.probeShown[.banner]), Self.text(dock.probeOpen[.sleeve] ?? dock.probeOpen[.banner]),
                dock.coversMiniArt ? 1 : 0, dock.isPresented ? 1 : 0, holds.count, Double(holds.low), Double(holds.high)
            ))
            .allowsHitTesting(false)
    }
}
#endif
