import VibraMusicCore
import MediaPlayer
import PlaybackPolicy
import SwiftUI

// Ports ui/player/PlayerThinSlider.kt (Apple Music's hairline scrubber) and PlayerControls.kt: the
// scrubber with its times and quality badge, the transport, the volume row, the round glyphs, the
// lyrics / output / queue row with its capsules, the output caption, the marquee credits. The
// player is drawn in white alphas over its artwork-coloured backdrop whatever the app's theme, as
// on Android and in Apple Music.

// MARK: - Thin slider

/// A hairline capsule with no thumb that thickens under the finger and settles back on release.
/// One gesture takes taps and drags alike.
struct PlayerThinSlider: View {
    var value: Double
    var onChange: (Double) -> Void
    var onEnd: () -> Void = {}
    /// The drag was taken away (a system gesture, the view covered) without a release.
    var onCancel: () -> Void = {}
    /// A travelling sheen across the whole bar while a version switch fetches and measures the
    /// other cut: a wait with no fraction to draw, shown on the bar itself rather than beside it.
    var loading = false
    /// The span, as fractions of the track, the next Automix transition is planned to occupy —
    /// drawn as a brighter stretch of the unplayed bar.
    var transitionWindow: ClosedRange<Double>?
    var idleHeight: CGFloat = 7
    var activeHeight: CGFloat = 12

    @State private var dragging = false
    /// Resets on its own when the system takes the touch away, which `onEnded` never hears about.
    @GestureState private var touching = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let height = dragging ? activeHeight : idleHeight
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.26))
                if let window = transitionWindow, window.upperBound > window.lowerBound {
                    let from = width * min(max(window.lowerBound, 0), 1)
                    let to = width * min(max(window.upperBound, 0), 1)
                    Capsule().fill(Color.white.opacity(0.5))
                        .frame(width: max(to - from, 0))
                        .offset(x: from)
                }
                let filled = width * min(max(value, 0), 1)
                if filled > 0 && !loading {
                    Capsule().fill(Color.white.opacity(0.92))
                        .frame(width: min(max(filled, height), width))
                        .transition(.opacity)
                }
                if loading {
                    SliderSheen(reduceMotion: reduceMotion)
                        .clipShape(Capsule())
                        .transition(.opacity)
                }
            }
            .frame(height: height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($touching) { _, touching, _ in touching = true }
                    .onChanged { gesture in
                        dragging = true
                        onChange(min(max(gesture.location.x / width, 0), 1))
                    }
                    .onEnded { _ in
                        dragging = false
                        onEnd()
                    }
            )
            .onChange(of: touching) { _, now in
                guard !now, dragging else { return }
                dragging = false
                onCancel()
            }
        }
        // Drawn and read left to right whatever the language, as Android's canvas-drawn bar is:
        // mirrored, the fill grew from the right while the finger was still read from the left.
        .environment(\.layoutDirection, .leftToRight)
        .frame(height: activeHeight + 22)
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: dragging)
        .animation(.easeInOut(duration: 0.45), value: loading)
    }
}

/// A band at the progress fill's brightness sweeping the bar about once a second, reversing at each
/// end rather than jumping back to the start.
private struct SliderSheen: View {
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            GeometryReader { proxy in
                let band = proxy.size.width * 0.34
                let cycle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2)
                // Held still in the middle under Reduce Motion: a paused sweep froze wherever the
                // clock happened to be, sometimes off the end of the bar.
                let t = reduceMotion ? 0.5 : (cycle < 1 ? cycle : 2 - cycle)
                let x = -band + t * (proxy.size.width + band)
                LinearGradient(colors: [.clear, .white.opacity(0.92), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: band)
                    .offset(x: x)
            }
        }
    }
}

// MARK: - Scrubber

/// The seek bar, with elapsed and remaining under it and the quality badge pinned between them.
/// Its own view: the position ticks four times a second and only this should redraw with it.
struct PlayerScrubberView: View {
    let scrub: PlayerScrub
    var loading = false
    var badge: PlaybackQualityBadge?

    @Environment(PlayerController.self) private var player

    var body: some View {
        let duration = max(player.duration, 0)
        let shown = scrub.shown(position: player.position, duration: duration)
        let labels = PlayerTime.labels(fraction: shown, duration: duration)
        let window = scrub.scrubbing ? nil : player.engine.transitionWindow.map { $0.start...$0.end }
        VStack(spacing: 0) {
            PlayerThinSlider(
                value: shown,
                onChange: { scrub.drag(to: $0) },
                onEnd: {
                    // On release only: ticking the whole way along the bar turns a scrub into a
                    // rattle, and the beat that matters is where the playhead landed.
                    let fraction = scrub.release()
                    Haptics.shared.play(.select)
                    player.seek(to: fraction * max(player.duration, 0))
                },
                onCancel: { scrub.cancel() },
                loading: loading,
                transitionWindow: window
            )
            ZStack {
                HStack {
                    Text(labels.elapsed)
                    Spacer()
                    Text(duration > 0 ? labels.remaining : "--:--")
                }
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
                if let badge {
                    PlayerQualityBadgeView(badge: badge)
                        .padding(.horizontal, 44)
                }
            }
            .offset(y: -9)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badge.map { "\(L10n.nowPlaying), \($0.playerLabel)" } ?? L10n.nowPlaying)
        .accessibilityValue("\(labels.elapsed), \(labels.remaining)")
        .accessibilityAdjustableAction { direction in
            let step: TimeInterval = 10
            let target = direction == .increment ? player.position + step : max(player.position - step, 0)
            player.seek(to: min(target, duration))
        }
        .accessibilityIdentifier("nowPlaying.scrubber")
        .onChange(of: player.position) { _, position in
            scrub.positionDidChange(position, duration: duration)
        }
        .onChange(of: player.currentSong?.id) {
            scrub.trackDidChange()
        }
    }
}

/// "Lossless", "Hi-Res Lossless", "Dolby Atmos" shimmer — confirmed, not claimed; the rest are
/// plain labels.
struct PlayerQualityBadgeView: View {
    let badge: PlaybackQualityBadge

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: badge.playerSymbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(badge.shimmers ? 0.7 : 0.45))
            if badge.shimmers {
                PlayerShimmerText(text: badge.playerLabel, font: .caption.weight(.semibold))
            } else {
                Text(badge.playerLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityElement(children: .combine)
    }
}

/// A highlight band sweeping the text every three seconds.
struct PlayerShimmerText: View {
    let text: String
    var font: Font = .caption.weight(.semibold)
    var baseAlpha: Double = 0.55

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(.white.opacity(baseAlpha))
            .overlay {
                if !reduceMotion {
                    TimelineView(.animation) { context in
                        GeometryReader { proxy in
                            let width = proxy.size.width
                            let band = width * 0.6
                            let progress = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3
                            let center = -band + progress * (width + 2 * band)
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(baseAlpha), location: 0),
                                    .init(color: .white, location: 0.5),
                                    .init(color: .white.opacity(baseAlpha), location: 1),
                                ],
                                startPoint: .leading, endPoint: .trailing
                            )
                            .frame(width: band * 2)
                            .offset(x: center - band)
                        }
                        .mask(Text(text).font(font))
                    }
                }
            }
    }
}

// MARK: - Transport

/// Previous, play/pause, next. `compact` is the landscape player on a phone.
struct PlayerTransportRow: View {
    var isPlaying: Bool
    /// While the stream resolves and buffers, the play glyph would be a lie.
    var isLoading: Bool
    var previousEnabled: Bool
    var nextEnabled: Bool
    var compact = false
    var onPrevious: () -> Void
    var onPlayPause: () -> Void
    var onNext: () -> Void

    var body: some View {
        let skip: CGFloat = compact ? 30 : 36
        let play: CGFloat = compact ? 40 : 50
        let touch: CGFloat = compact ? 64 : 84
        HStack {
            Spacer(minLength: 0)
            Button {
                Haptics.shared.play(.skipPrevious)
                onPrevious()
            } label: {
                Image(systemName: AppSymbol.previous).font(.system(size: skip)).frame(width: touch * 0.75, height: touch)
            }
            .disabled(!previousEnabled)
            .opacity(previousEnabled ? 1 : 0.3)
            .accessibilityLabel(L10n.widgetPrevious)
            .accessibilityIdentifier("nowPlaying.previous")
            Spacer(minLength: 0)
            ZStack {
                if isLoading {
                    ProgressView().controlSize(.large).tint(.white)
                } else {
                    Button {
                        Haptics.shared.play(isPlaying ? .pause : .resume)
                        onPlayPause()
                    } label: {
                        Image(systemName: isPlaying ? AppSymbol.pause : AppSymbol.play)
                            .font(.system(size: play))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: touch, height: touch)
                    }
                    .accessibilityLabel(isPlaying ? L10n.pause : L10n.play)
                    .accessibilityIdentifier("nowPlaying.playPause")
                }
            }
            .frame(width: touch, height: touch)
            Spacer(minLength: 0)
            Button {
                Haptics.shared.play(.skipNext)
                onNext()
            } label: {
                Image(systemName: AppSymbol.next).font(.system(size: skip)).frame(width: touch * 0.75, height: touch)
            }
            .disabled(!nextEnabled)
            .opacity(nextEnabled ? 1 : 0.3)
            .accessibilityLabel(L10n.widgetNext)
            .accessibilityIdentifier("nowPlaying.next")
            Spacer(minLength: 0)
        }
        .buttonStyle(PlayerGlyphButtonStyle())
        .foregroundStyle(.white)
        .animation(.easeOut(duration: 0.2), value: previousEnabled)
        .animation(.easeOut(duration: 0.2), value: nextEnabled)
    }
}

/// A glyph that dips when pressed, with a soft disc behind it, as Apple Music's transport does.
struct PlayerGlyphButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0))
                    .padding(6)
            )
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

// MARK: - Volume

/// The system volume between its two speaker glyphs. iOS lets an app move the volume only through
/// MPVolumeView, so the bar is the system's slider, drawn thin, with no knob of its own — Android's
/// ThinSlider (ui/player/ThinSlider.kt) and the song bar above draw the same way.
struct PlayerVolumeRow: View {
    var onDraggingChange: (Bool) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
            PlayerSystemVolumeSlider(onDraggingChange: onDraggingChange)
                .frame(height: 32)
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.footnote)
        .foregroundStyle(.white.opacity(0.5))
        .accessibilityElement(children: .contain)
    }
}

struct PlayerSystemVolumeSlider: UIViewRepresentable {
    /// A finger landed on the bar (true) or let go of it (false).
    var onDraggingChange: (Bool) -> Void = { _ in }

    func makeUIView(context: Context) -> CentredVolumeView {
        let view = CentredVolumeView(frame: .zero)
        view.onDraggingChange = onDraggingChange
        view.tintColor = .white
        view.setMinimumVolumeSliderImage(Self.track(alpha: 0.92), for: .normal)
        view.setMaximumVolumeSliderImage(Self.track(alpha: 0.26), for: .normal)
        view.setVolumeThumbImage(Self.thumb(), for: .normal)
        return view
    }

    func updateUIView(_ view: CentredVolumeView, context: Context) {
        view.onDraggingChange = onDraggingChange
    }

    /// Taken off screen mid-touch, the slider never reports the touch ending: let go for it.
    static func dismantleUIView(_ view: CentredVolumeView, coordinator: ()) {
        view.onDraggingChange(false)
    }

    /// A 6 pt capsule, stretchable across its middle.
    private static func track(alpha: CGFloat) -> UIImage {
        let size = CGSize(width: 7, height: 6)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.white.withAlphaComponent(alpha).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3).fill()
        }
        return image.resizableImage(withCapInsets: UIEdgeInsets(top: 0, left: 3, bottom: 0, right: 3))
    }

    /// No knob at all: a 1×1 clear point. UISlider ends the fill at the thumb's frame, so the old
    /// dot's transparent inset showed a dark gap between the fill and the dot at full volume.
    static func thumb() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
    }
}

/// MPVolumeView lays its slider at the top of its bounds, at the slider's own height, so in the
/// 32 pt row the bar rode above the speaker glyphs' centre. The slider's place is the
/// view's documented override point; here it moves to the vertical centre.
final class CentredVolumeView: MPVolumeView {
    var onDraggingChange: (Bool) -> Void = { _ in }

    override func volumeSliderRect(forBounds bounds: CGRect) -> CGRect {
        Self.centred(super.volumeSliderRect(forBounds: bounds), in: bounds)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // MPVolumeView builds its own slider, and builds it again on a route change, so every
        // slider it holds is asked on every layout to report its touches, once.
        for slider in subviews.compactMap({ $0 as? UISlider }) where !slider.allTargets.contains(self) {
            slider.addTarget(self, action: #selector(touchBegan), for: .touchDown)
            slider.addTarget(self, action: #selector(touchEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        }
    }

    /// A slider rebuilt from under the finger never reports the touch ending: let go for it.
    override func willRemoveSubview(_ subview: UIView) {
        super.willRemoveSubview(subview)
        if (subview as? UISlider)?.isTracking == true { onDraggingChange(false) }
    }

    @objc private func touchBegan() { onDraggingChange(true) }
    @objc private func touchEnded() { onDraggingChange(false) }

    /// `rect` moved up or down until its centre sits on `bounds`' centre line; x and size kept.
    static func centred(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        rect.offsetBy(dx: 0, dy: bounds.midY - rect.midY)
    }
}

// MARK: - Round glyphs

/// The translucent disc used for the like control and the menu. `active` brightens the disc rather
/// than only the glyph: it sits on artwork of any colour, and a white icon on a white-ish sleeve
/// has no tint change left to make.
struct PlayerCircleGlyph: View {
    let symbol: String
    var active = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .contentTransition(.symbolEffect(.replace))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(Circle().fill(Color.white.opacity(active ? 0.34 : 0.18)))
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.18), value: active)
    }
}

// MARK: - Tap windows

/// Drops a tap that lands inside the window of the last one. Toggling shuffle replaces the upcoming
/// stretch of the queue, and AutoPlay's work is heavier still: one tap is all a toggle can usefully
/// mean in that window, so the rest are dropped, haptic included (PlayerControls.kt).
struct PlayerTapThrottle {
    static let shuffle: TimeInterval = 0.4
    static let autoplay: TimeInterval = 0.7

    let window: TimeInterval
    private var last: Date?

    init(window: TimeInterval) {
        self.window = window
    }

    mutating func allow(now: Date = Date()) -> Bool {
        if let last, now.timeIntervalSince(last) < window { return false }
        last = now
        return true
    }
}

// MARK: - Lyrics / output / queue row

/// The row both layouts end on: lyrics, a capsule, the queue. The capsule is where the sound goes
/// (output and party) normally, and how the queue plays (shuffle, repeat, AutoPlay) while the
/// queue is up — that's when those are what you're about to reach for.
struct PlayerActionRow: View {
    let panes: PlayerPaneState
    var shuffleEnabled: Bool
    var repeatMode: RepeatMode
    var autoplayEnabled: Bool
    var party: PlayerPartyBadge
    var onToggleLyrics: () -> Void
    var onToggleQueue: () -> Void
    var onToggleShuffle: () -> Void
    var onCycleRepeat: () -> Void
    var onToggleAutoplay: () -> Void
    var onOpenOutput: () -> Void
    var onParty: () -> Void

    @State private var shuffleTaps = PlayerTapThrottle(window: PlayerTapThrottle.shuffle)
    @State private var autoplayTaps = PlayerTapThrottle(window: PlayerTapThrottle.autoplay)

    var body: some View {
        HStack {
            BottomGlyph(symbol: AppSymbol.lyricsQuote, highlighted: panes.lyricsOpen,
                        label: panes.lyricsOpen ? L10n.closeLyrics : L10n.openLyrics) {
                Haptics.shared.play(.tap)
                onToggleLyrics()
            }
            .accessibilityIdentifier("nowPlaying.lyrics")
            Spacer(minLength: 8)
            ZStack {
                if panes.queueOpen {
                    queueModes.transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    outputPill.transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.82), value: panes.queueOpen)
            Spacer(minLength: 8)
            BottomGlyph(symbol: AppSymbol.queue, highlighted: panes.queueOpen, label: L10n.upNext) {
                Haptics.shared.play(panes.queueOpen ? .tap : .expand)
                onToggleQueue()
            }
            .accessibilityIdentifier("nowPlaying.queue")
        }
    }

    private var queueModes: some View {
        Pill {
            PillSegment(symbol: AppSymbol.shuffle, highlighted: shuffleEnabled, width: 52,
                        label: shuffleEnabled ? L10n.shuffleOn : L10n.shuffleOff) {
                guard shuffleTaps.allow() else { return }
                Haptics.shared.play(shuffleEnabled ? .toggleOff : .toggleOn)
                onToggleShuffle()
            }
            .accessibilityIdentifier("nowPlaying.shuffle")
            PillDivider()
            PillSegment(symbol: repeatMode == .one ? AppSymbol.repeatOne : AppSymbol.repeatAll,
                        highlighted: repeatMode != .off, width: 52, label: PlayerRepeatText.label(repeatMode)) {
                // Three states, so the buzz tracks the edges of the cycle.
                switch repeatMode {
                case .off: Haptics.shared.play(.toggleOn)
                case .one: Haptics.shared.play(.toggleOff)
                case .all: Haptics.shared.play(.select)
                }
                onCycleRepeat()
            }
            .accessibilityIdentifier("nowPlaying.repeat")
            PillDivider()
            PillSegment(symbol: AppSymbol.infinity, highlighted: autoplayEnabled, width: 52,
                        label: autoplayEnabled ? L10n.autoplayOn : L10n.autoplayOff) {
                guard autoplayTaps.allow() else { return }
                Haptics.shared.play(autoplayEnabled ? .toggleOff : .toggleOn)
                onToggleAutoplay()
            }
            .accessibilityIdentifier("nowPlaying.autoplay")
        }
    }

    private var outputPill: some View {
        Pill {
            PillSegment(symbol: "headphones", highlighted: false, width: 64, label: L10n.audioOutput) {
                Haptics.shared.play(.tap)
                onOpenOutput()
            }
            .accessibilityIdentifier("nowPlaying.output")
            PillDivider()
            PillSegment(symbol: "person.fill", highlighted: party.inParty, width: 64,
                        trailing: party.inParty ? "\(party.members)" : nil,
                        label: party.inParty ? L10n.listenTogetherOpenCount(party.members) : L10n.listenTogetherOpen) {
                Haptics.shared.play(.tap)
                onParty()
            }
        }
    }
}

enum PlayerRepeatText {
    static func label(_ mode: RepeatMode) -> String {
        switch mode {
        case .off: return L10n.repeatOff
        case .all: return L10n.repeatAll
        case .one: return L10n.repeatOne
        }
    }
}

private struct BottomGlyph: View {
    let symbol: String
    var highlighted = false
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.white.opacity(highlighted ? 1 : 0.75))
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.white.opacity(highlighted ? 0.2 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
        .animation(.easeOut(duration: 0.2), value: highlighted)
    }
}

/// Several controls joined into one capsule by hairlines: the shape the player uses for a set of
/// choices that answer the same question.
private struct Pill<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .frame(height: 44)
            .background(Capsule().fill(Color.white.opacity(0.12)))
            .clipShape(Capsule())
    }
}

private struct PillDivider: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1, height: 44)
    }
}

private struct PillSegment: View {
    let symbol: String
    var highlighted: Bool
    var width: CGFloat
    var trailing: String?
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .medium))
                    .contentTransition(.symbolEffect(.replace))
                if let trailing {
                    Text(trailing).font(.footnote.weight(.bold))
                }
            }
            .foregroundStyle(.white.opacity(highlighted ? 1 : 0.75))
            .frame(width: width, height: 44)
            .background(Color.white.opacity(highlighted ? 0.14 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
        .animation(.easeOut(duration: 0.2), value: highlighted)
    }
}

// MARK: - Party badge

/// The three facts about a Listen Together party the player draws.
struct PlayerPartyBadge: Hashable {
    var inParty = false
    var members = 0
    var hostFirstName: String?

    /// The host's first name, as the output line shortens the account's ("Kushagra's Jam").
    static func firstName(of displayName: String?) -> String? {
        guard let first = displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .first, !first.isEmpty else { return nil }
        return String(first)
    }

    var jamName: String {
        hostFirstName.map(L10n.listenTogetherJam) ?? L10n.listenTogetherJamUnnamed
    }
}

// MARK: - Output caption

/// The line under the controls: normally the output, and the party's name whenever there is one.
/// It shimmers when the device is receiving hi-res music at the quality it was sent in.
struct PlayerOutputCaption: View {
    let outputName: String
    var party: PlayerPartyBadge
    var shines: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if !party.inParty && shines {
                    PlayerShimmerText(text: outputName, font: .caption2.weight(.semibold))
                } else {
                    Text(party.inParty ? party.jamName : outputName)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 260)
            .frame(minHeight: 20)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("nowPlaying.outputCaption")
    }
}

// MARK: - Marquee

/// One line of text that scrolls in place, only when it is too long to show whole: drawn twice
/// with a gap and crawled one copy-plus-gap leftwards, so the trailing copy lands exactly where the
/// first started and the reset can't be seen. A pass waits `startDelay`, crawls, then rests five
/// seconds. With `enabled` off (or Reduce Motion on) it is a plain truncated line.
struct PlayerMarqueeText: View {
    let text: String
    var font: Font
    var color: Color = .white
    var enabled = true
    var startDelay: TimeInterval = 0
    var onOverflowChange: (Bool) -> Void = { _ in }

    static let pointsPerSecond: CGFloat = 26
    static let gap: CGFloat = 48
    static let rest: TimeInterval = 5
    static let artistStagger: TimeInterval = 3

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var overflowing: Bool { textWidth > boxWidth + 0.5 && boxWidth > 0 }
    private var scrolls: Bool { enabled && !reduceMotion && overflowing }

    var body: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                HStack(spacing: Self.gap) {
                    line
                    if scrolls { line }
                }
                .fixedSize()
                .offset(x: scrolls ? offset : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                .opacity(scrolls ? 1 : 0)
            }
            .overlay(alignment: .leading) {
                if !scrolls {
                    Text(text).font(font).foregroundStyle(color).lineLimit(1).truncationMode(.tail)
                }
            }
            .background {
                GeometryReader { proxy in
                    Color.clear.onAppear { boxWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, width in boxWidth = width }
                }
            }
            .background {
                Text(text).font(font).lineLimit(1).fixedSize().hidden()
                    .background(GeometryReader { proxy in
                        Color.clear.onAppear { textWidth = proxy.size.width }
                            .onChange(of: proxy.size.width) { _, width in textWidth = width }
                    })
            }
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .onChange(of: overflowing, initial: true) { _, value in onOverflowChange(value) }
            .task(id: "\(text)|\(scrolls)|\(textWidth)|\(startDelay)") {
                offset = 0
                guard scrolls else { return }
                let travel = textWidth + Self.gap
                let duration = max(Double(travel / Self.pointsPerSecond), 0.4)
                try? await Task.sleep(for: .seconds(startDelay))
                while !Task.isCancelled {
                    withAnimation(.linear(duration: duration)) { offset = -travel }
                    try? await Task.sleep(for: .seconds(duration))
                    guard !Task.isCancelled else { return }
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    withTransaction(instant) { offset = 0 }
                    try? await Task.sleep(for: .seconds(Self.rest))
                }
            }
    }

    private var line: some View {
        Text(text).font(font).foregroundStyle(color).lineLimit(1).fixedSize()
    }
}
