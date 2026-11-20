import Lyrics
import SwiftUI
import UIKit

// Ports SweptLyricLine, sweepTo, riseWith, growEach, glowGrown and lyricParticles from
// ui/player/PlayerLyrics.kt.
//
// A lyric line with the sung part lit, the rest dimmed, and the boundary travelling across the
// words in time with the vocal. Three copies of the same layout, stacked as layers: the dim text,
// the bloom behind held notes, and the lit text clipped to whatever has been sung. Same layout, so
// the lit copy lands exactly on the dim one. SwiftUI's Text can only colour whole runs, which
// turns a sweep into a flicker, so the copies are drawn with TextKit (see LyricTextLayout).
//
// The dim copy's brightness and the bloom's strength are layer opacities, so Core Animation
// fades them; only what moves with the clock (the sweep, the lift, the swell) is redrawn per frame,
// and only on lines the clock is actually inside.

/// How far the word being sung lifts off the line (WORD_RISE).
private let wordRise: CGFloat = 2
/// Extra room above a row holding a swelling letter, in rises (GROW_HEADROOM).
private let growHeadroom: CGFloat = 3
/// The sweep's leading edge fades over this rather than ending on a cut (WIPE_FEATHER).
private let wipeFeather: CGFloat = 30
/// How far the bloom spreads off a letter (GLOW_RADIUS).
private let glowRadius: CGFloat = 6

/// What the line view needs to draw one voice.
struct LyricVoiceStyle: Equatable {
    var typeface: LyricTypeface
    /// Right-hand duet voice: right-aligned (in a left-to-right layout).
    var alignEnd = false
    /// Room inside the view for the bloom and the lift to spread into (GLOW_ROOM).
    var room: CGFloat = 0
    /// Word-synced lines sweep; others light whole.
    var sweeps = true
    /// Words lift and held notes swell (off with Reduce Motion).
    var rises = true
    /// The sweep's edge is feathered (only on the line being sung).
    var feather = false
    /// At most this many rows, ending in "…" (0: wrap freely). The strip over the scrubber is one.
    var maxLines = 0
    /// Takes only the width the words need rather than all it's offered (Compose's
    /// `weight(1f, fill = false)` slot), so what follows the line sits right after it.
    var hugs = false
}

/// The UIKit side: the three layers and the arithmetic that fills them.
final class LyricLineUIView: UIView, LyricClockListener {
    private(set) var line = LyricLine(timeMs: 0, text: "")
    private(set) var style = LyricVoiceStyle(typeface: .synced)
    private var rightToLeftLayout = false
    private var layout: LyricTextLayout?
    private weak var clock: LyricFrameClock?

    private let dimLayer = LyricDrawingLayer()
    private let glowLayer = LyricDrawingLayer()
    private let litLayer = LyricDrawingLayer()
    private let particleLayer = LyricDrawingLayer()

    /// What the last frame drew, so a line nobody is singing isn't redrawn every frame.
    private var drawnPhase: Phase?
    private var positionMs = 0
    /// The particle pass (0…1) while a translation toggle is resolving, nil otherwise.
    private var particlesStartedAt: CFTimeInterval?
    private static let particleDuration: CFTimeInterval = 0.54

    private enum Phase: Equatable {
        case before
        case after
        case live(Int)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        clipsToBounds = false
        isUserInteractionEnabled = false
        for sublayer in [dimLayer, glowLayer, litLayer, particleLayer] {
            sublayer.contentsScale = UIScreen.main.scale
            sublayer.masksToBounds = false
            sublayer.needsDisplayOnBoundsChange = true
            layer.addSublayer(sublayer)
        }
        dimLayer.drawer = { [weak self] context in self?.drawDim(in: context) }
        glowLayer.drawer = { [weak self] context in self?.drawGlow(in: context) }
        litLayer.drawer = { [weak self] context in self?.drawLit(in: context) }
        particleLayer.drawer = { [weak self] context in self?.drawParticles(in: context) }
        // Opacity changes are the line's own crossfades (tail, bloom), so leave the layers'
        // default actions alone and let configure() add each fade with its own endpoints.
        dimLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        glowLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        litLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        particleLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Configuration

    func configure(
        line: LyricLine,
        style: LyricVoiceStyle,
        rightToLeftLayout: Bool,
        dimAlpha: Double,
        glowAlpha: CGFloat,
        clock: LyricFrameClock?,
        animated: Bool
    ) {
        let relayout = line.text != self.line.text || style.typeface != self.style.typeface
            || style.alignEnd != self.style.alignEnd || rightToLeftLayout != self.rightToLeftLayout
            || style.room != self.style.room || style.maxLines != self.style.maxLines
        let changed = relayout || line != self.line || style != self.style
        self.line = line
        self.style = style
        self.rightToLeftLayout = rightToLeftLayout
        if relayout { layout = nil }
        if self.clock !== clock {
            self.clock?.removeListener(self)
            self.clock = clock
            clock?.addListener(self)
        }
        positionMs = clock?.positionMs ?? positionMs
        Self.setOpacity(dimLayer, Float(dimAlpha), animated: animated, spring: true)
        Self.setOpacity(glowLayer, Float(glowAlpha), animated: animated, spring: false)
        if changed {
            drawnPhase = nil
            setNeedsLayout()
            redraw(force: true)
        }
    }

    /// Stops listening to the clock (the row scrolled out of the lazy list).
    func detach() {
        clock?.removeListener(self)
        clock = nil
    }

    /// The line's own crossfade (the tail, the whole-copy lit state, the bloom): the fade is
    /// added with its endpoints rather than left to the layer's action — an action with no
    /// start or end animates nothing, so the new brightness would land in one frame.
    private static func setOpacity(_ layer: CALayer, _ value: Float, animated: Bool, spring: Bool) {
        let changed = value != layer.opacity
        let fade: CAAnimation?
        if changed, animated {
            let from = layer.presentation()?.opacity ?? layer.opacity
            if spring {
                // Compose's default spring for the text's own brightness (damping ratio 1,
                // stiffness 1500: PlayerLyrics.kt's animateFloatAsState on the unsung tail).
                let spring = CASpringAnimation(keyPath: "opacity")
                spring.mass = 1
                spring.stiffness = 1500
                spring.damping = 2 * (1500 as CGFloat).squareRoot()
                spring.duration = spring.settlingDuration
                spring.fromValue = from
                spring.toValue = value
                fade = spring
            } else {
                // The bloom's 420 ms FastOutSlowIn (PlayerLyrics.kt's glow tween).
                let tween = CABasicAnimation(keyPath: "opacity")
                tween.duration = 0.42
                tween.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
                tween.fromValue = from
                tween.toValue = value
                fade = tween
            }
        } else {
            fade = nil
        }
        // The model value lands with actions disabled, so only the animation above fades.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = value
        CATransaction.commit()
        if let fade { layer.add(fade, forKey: "fade") }
    }

    /// Starts the translation particles over this line's letters.
    func playParticles() {
        particlesStartedAt = CACurrentMediaTime()
        clock?.animate(for: Self.particleDuration)
        particleLayer.setNeedsDisplay()
    }

    // MARK: Layout

    func textLayout(forWidth width: CGFloat) -> LyricTextLayout {
        let inner = max(width - style.room * 2, 1)
        if let layout, abs(layout.container.size.width - inner) < 0.5 { return layout }
        let fresh = LyricTextLayout(text: line.text, typeface: style.typeface, width: inner, alignEnd: style.alignEnd,
                                    rightToLeftLayout: rightToLeftLayout, maxLines: style.maxLines)
        layout = fresh
        return fresh
    }

    func fittingSize(forWidth width: CGFloat) -> CGSize {
        let measured = textLayout(forWidth: width)
        guard style.hugs else { return CGSize(width: width, height: measured.size.height + style.room * 2) }
        // The inked width, rounded up so laying out again at exactly that width wraps (or cuts)
        // at the same place.
        let inked = (measured.rows.map(\.right).max() ?? 0) - (measured.rows.map(\.left).min() ?? 0)
        let hugged = min(ceil(inked) + 1 + style.room * 2, width)
        return CGSize(width: hugged, height: measured.size.height + style.room * 2)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        _ = textLayout(forWidth: bounds.width)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in [dimLayer, glowLayer, litLayer, particleLayer] {
            sublayer.frame = bounds
        }
        CATransaction.commit()
        redraw(force: true)
    }

    // MARK: Clock

    func lyricClockDidTick(_ positionMs: Int) {
        self.positionMs = positionMs
        redraw(force: false)
    }

    private func phase(at position: Int) -> Phase {
        let lifted = style.rises && (line.isLifted(position) || line.isGrowing(position))
        if !style.sweeps { return position >= line.timeMs && !lifted ? .after : (lifted ? .live(position) : .before) }
        if position <= line.timeMs && !lifted { return .before }
        if position >= line.endMs && !lifted { return .after }
        return .live(position)
    }

    private func redraw(force: Bool) {
        let phase = phase(at: positionMs)
        let particlesRunning = particlesStartedAt.map { CACurrentMediaTime() - $0 < Self.particleDuration + 0.05 } ?? false
        if particlesRunning || particlesStartedAt != nil { particleLayer.setNeedsDisplay() }
        if !particlesRunning { particlesStartedAt = nil }
        guard force || phase != drawnPhase else { return }
        let wasLive: Bool = { if case .live = drawnPhase { return true }; return false }()
        drawnPhase = phase
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        litLayer.setNeedsDisplay()
        let liftChanges: Bool = { if case .live = phase { return style.rises }; return wasLive && style.rises }()
        if force || liftChanges {
            dimLayer.setNeedsDisplay()
        }
        // Forced too: a row handed a new line keeps the last line's bloom until the glow is redrawn.
        if force || (style.rises && !line.growingWords.isEmpty) { glowLayer.setNeedsDisplay() }
        CATransaction.commit()
    }

    // MARK: Drawing

    private var origin: CGPoint { CGPoint(x: style.room, y: style.room) }

    /// The dim copy: every word, lifted where the singing has lifted it.
    private func drawDim(in context: CGContext) {
        guard let layout = currentLayout else { return }
        drawText(layout, in: context, position: positionMs, revealed: nil)
    }

    /// The lit copy, clipped to what has been sung.
    private func drawLit(in context: CGContext) {
        guard let layout = currentLayout else { return }
        if !style.sweeps {
            // Lines with no word timings are one brightness, carried by the dim layer's opacity.
            return
        }
        let position = positionMs
        let revealed: Float
        if position >= line.endMs {
            revealed = Float(layout.length)
        } else if position <= line.timeMs {
            return
        } else {
            revealed = line.revealedChars(position)
        }
        if revealed <= 0 { return }
        if style.feather, revealed < Float(layout.length) {
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            drawText(layout, in: context, position: position, revealed: revealed)
            featherEdge(layout, in: context, revealed: revealed)
            context.endTransparencyLayer()
        } else {
            drawText(layout, in: context, position: position, revealed: revealed)
        }
    }

    /// Softens the sweep's cut into a wavefront: the row holding the boundary is erased over the
    /// last `wipeFeather` points before it.
    private func featherEdge(_ layout: LyricTextLayout, in context: CGContext, revealed: Float) {
        guard let index = layout.rows.firstIndex(where: { Float($0.characters.upperBound) > revealed && Float($0.characters.lowerBound) < revealed }) else { return }
        let row = layout.rows[index]
        let edge = layout.sweepEdge(revealed: revealed, row: index) + origin.x
        let rtl = layout.rightToLeftText
        // Narrowed over the row's last stretch, so the sweep itself lights the row's last letter.
        // At full width it held that letter part dark until the row was done, then
        // lit it in one frame, as the line handed over or wrapped. Android draws the same pop.
        // A row cut for an ellipsis keeps its full soft edge: the sweep waits at the ellipsis
        // while the hidden words are sung (the strip over the scrubber). Throughout, not only
        // once the edge is there, or it would sharpen on the way in and pop soft again.
        let feather = row.truncatedFrom != nil ? wipeFeather : min(wipeFeather, abs((rtl ? row.left : row.right) + origin.x - edge))
        let start = rtl ? min(edge + feather, row.right + origin.x) : max(edge - feather, row.left + origin.x)
        // On past the edge by a device pixel, cleared by the gradient's end. Stopping
        // exactly at the edge, where the lit copy's clip stops too, left the pixel the edge cuts
        // only part erased, and it shone through the letter being sung as a thin line. Android's
        // erase isn't clipped at the edge at all.
        let pixel = 1 / max(abs(context.userSpaceToDeviceSpaceTransform.a), 1)
        let end = rtl ? edge - pixel : edge + pixel
        let band = CGRect(
            x: min(start, end),
            y: row.top + origin.y - wordRise * growHeadroom,
            width: abs(end - start),
            height: row.bottom - row.top + wordRise * growHeadroom
        )
        guard start != edge, let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [UIColor.white.cgColor, UIColor.white.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 1]
        ) else { return }
        context.saveGState()
        context.clip(to: band)
        context.setBlendMode(.destinationIn)
        context.drawLinearGradient(gradient, start: CGPoint(x: start, y: band.midY), end: CGPoint(x: edge, y: band.midY), options: .drawsAfterEndLocation)
        context.restoreGState()
    }

    /// The bloom behind held notes: each swelling letter's own light, masked to its brightness.
    /// Drawn as a shadow cast from a copy far off to the side, so only the halo lands here.
    private func drawGlow(in context: CGContext) {
        guard style.rises, let layout = currentLayout else { return }
        let position = positionMs
        guard line.isGrowing(position) else { return }
        // The layout draws into UIKit's current context; a layer's drawer has none until pushed
        // (on a Mac the font dereferences the missing context and the app stops).
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        let em = layout.typeface.size
        let throw_: CGFloat = 10_000
        for word in line.growingWords where position >= word.startMs && position <= word.restsAtMs {
            guard let span = line.wordSpans.kGetSafe(word.index) else { continue }
            let fall = CGFloat(line.wordFall(word.index, position))
            for char in span.lowerBound..<min(span.upperBound, layout.length) {
                let growth = word.sample(char - span.lowerBound, position)
                guard growth.bloom > 0.01, let rowIndex = layout.row(ofCharacter: char) else { continue }
                let row = layout.rows[rowIndex]
                let (from, to) = layout.span(char..<(char + 1), row: rowIndex)
                guard to > from else { continue }
                let dx = CGFloat(growth.shift) * em
                let dy = -CGFloat(growth.rise) * wordRise * fall
                let center = CGPoint(x: (from + to) / 2 + origin.x, y: (row.top + row.bottom) / 2 + origin.y)
                context.saveGState()
                // Shadow offset and blur are in device space, unaffected by the CTM.
                let device = context.userSpaceToDeviceSpaceTransform
                let offset = CGSize(width: throw_, height: 0).applying(device)
                context.setShadow(offset: CGSize(width: offset.width, height: 0), blur: glowRadius * 2 * abs(device.a), color: UIColor.white.withAlphaComponent(CGFloat(growth.bloom)).cgColor)
                context.translateBy(x: dx - throw_, y: dy)
                context.translateBy(x: center.x, y: center.y)
                context.scaleBy(x: CGFloat(growth.scale), y: CGFloat(growth.scale))
                context.translateBy(x: -center.x, y: -center.y)
                layout.draw(layout.glyphs(for: char..<(char + 1)), at: origin)
                context.restoreGState()
            }
        }
    }

    /// Draws the line, cut at word boundaries so each piece can sit at its own height, optionally
    /// clipped to the first `revealed` characters (the sweep). Pieces with nothing happening to
    /// them go down as one run.
    private func drawText(_ layout: LyricTextLayout, in context: CGContext, position: Int, revealed: Float?) {
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        let lifted = style.rises && !line.words.isEmpty && line.isLifted(position)
        let em = layout.typeface.size
        for (rowIndex, row) in layout.rows.enumerated() {
            if let revealed, revealed <= Float(row.characters.lowerBound) { break }
            context.saveGState()
            if let revealed {
                clipToSweep(layout, row: rowIndex, revealed: revealed, in: context)
            } else {
                // Each row keeps to its own band, so a lifted piece never redraws the one above.
                context.clip(to: CGRect(x: -bounds.width, y: row.top + origin.y - wordRise * growHeadroom, width: bounds.width * 3, height: row.bottom - row.top + wordRise * growHeadroom))
            }
            guard lifted else {
                layout.draw(row.glyphs, at: origin)
                context.restoreGState()
                continue
            }
            var flat: [Range<Int>] = []
            var at = row.characters.lowerBound
            for index in line.words.indices {
                guard let span = line.wordSpans.kGetSafe(index) else { continue }
                let start = max(span.lowerBound, row.characters.lowerBound)
                let end = min(span.upperBound, row.characters.upperBound)
                guard start < end else { continue }
                let held = line.growingAt(index).flatMap { position >= $0.startMs && position <= $0.restsAtMs ? $0 : nil }
                let lift = CGFloat(line.wordLift(index, position))
                if held == nil && lift <= 0.01 { continue }
                if start > at { flat.append(at..<start) }
                if let held {
                    let fall = CGFloat(line.wordFall(index, position))
                    let first = span.lowerBound
                    for char in start..<end {
                        let growth = held.sample(char - first, position)
                        let (from, to) = layout.span(char..<(char + 1), row: rowIndex)
                        guard to > from else { continue }
                        let center = CGPoint(x: (from + to) / 2 + origin.x, y: (row.top + row.bottom) / 2 + origin.y)
                        context.saveGState()
                        context.translateBy(x: CGFloat(growth.shift) * em, y: -CGFloat(growth.rise) * wordRise * fall)
                        context.translateBy(x: center.x, y: center.y)
                        context.scaleBy(x: CGFloat(growth.scale), y: CGFloat(growth.scale))
                        context.translateBy(x: -center.x, y: -center.y)
                        layout.draw(layout.glyphs(for: char..<(char + 1)), at: origin)
                        context.restoreGState()
                    }
                } else {
                    context.saveGState()
                    context.translateBy(x: 0, y: -lift * wordRise)
                    layout.draw(layout.glyphs(for: start..<end), at: origin)
                    context.restoreGState()
                }
                at = end
            }
            if at < row.characters.upperBound { flat.append(at..<row.characters.upperBound) }
            for run in flat { layout.draw(layout.glyphs(for: run), at: origin) }
            context.restoreGState()
        }
    }

    /// Clips to the part of `row` the sweep has reached: whole rows before the boundary, the
    /// boundary row up to the edge.
    private func clipToSweep(_ layout: LyricTextLayout, row index: Int, revealed: Float, in context: CGContext) {
        let row = layout.rows[index]
        let top = row.top + origin.y - wordRise * growHeadroom
        let height = row.bottom - row.top + wordRise * growHeadroom
        // Generous horizontal slack past the row's ends: letters that swell or lean reach beyond
        // the inked box and must not be shaved.
        let slack: CGFloat = 40
        if revealed >= Float(row.characters.upperBound) {
            context.clip(to: CGRect(x: row.left + origin.x - slack, y: top, width: row.right - row.left + slack * 2, height: height))
            return
        }
        let edge = layout.sweepEdge(revealed: revealed, row: index) + origin.x
        if layout.rightToLeftText {
            context.clip(to: CGRect(x: edge, y: top, width: row.right + origin.x + slack - edge, height: height))
        } else {
            context.clip(to: CGRect(x: row.left + origin.x - slack, y: top, width: edge - (row.left + origin.x - slack), height: height))
        }
    }

    /// A field of tiny glyph-like particles resolving into the new text (LyricsTranslationMotion).
    private func drawParticles(in context: CGContext) {
        guard let started = particlesStartedAt, let layout = currentLayout else { return }
        let value = CGFloat((CACurrentMediaTime() - started) / Self.particleDuration)
        guard value > 0, value < 1 else { return }
        let ns = layout.text as NSString
        var candidates: [Int] = []
        for index in 0..<ns.length {
            if let scalar = UnicodeScalar(ns.character(at: index)), CharacterSet.alphanumerics.contains(scalar) { candidates.append(index) }
        }
        var generator = SeededGenerator(seed: UInt64(bitPattern: Int64(layout.text.hashValue)))
        candidates.shuffle(using: &generator)
        for index in candidates.prefix(18) {
            let glyph = layout.box(ofCharacter: index)
            let anchor = CGPoint(x: glyph.midX + origin.x, y: glyph.midY + origin.y)
            let drift = CGPoint(x: (CGFloat.random(in: 0...1, using: &generator) - 0.5) * 12, y: -(5 + CGFloat.random(in: 0...1, using: &generator) * 11))
            let radius = 0.65 + CGFloat.random(in: 0...1, using: &generator) * 0.65
            let delay = 0.16 * CGFloat(index) / CGFloat(max(ns.length, 1))
            let t = min(max((value - delay) / 0.84, 0), 1)
            let envelope = sin(.pi * t)
            let ease = 1 - (1 - t) * (1 - t)
            let center = CGPoint(x: anchor.x + drift.x * ease, y: anchor.y + drift.y * ease + 3 * t * t)
            context.setFillColor(UIColor.white.withAlphaComponent(envelope * 0.07).cgColor)
            context.fillEllipse(in: CGRect(x: center.x - radius * 2.7, y: center.y - radius * 2.7, width: radius * 5.4, height: radius * 5.4))
            context.setFillColor(UIColor.white.withAlphaComponent(envelope * 0.58).cgColor)
            context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
    }

    private var currentLayout: LyricTextLayout? {
        bounds.width > 0 ? textLayout(forWidth: bounds.width) : nil
    }
}

/// A layer that hands its drawing to a closure (a CALayer delegate without the UIView baggage).
final class LyricDrawingLayer: CALayer {
    var drawer: ((CGContext) -> Void)?

    override func draw(in ctx: CGContext) {
        drawer?(ctx)
    }
}

/// Deterministic randomness, so a line's particles are the same field every time it resolves.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

extension Array {
    fileprivate func kGetSafe(_ index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - SwiftUI

/// One voice of a lyric row, drawn by ``LyricLineUIView`` off the panel's frame clock.
struct LyricVoice: UIViewRepresentable {
    let line: LyricLine
    let style: LyricVoiceStyle
    /// The dim copy's brightness: the unsung tail, or the whole line when it doesn't sweep.
    let dimAlpha: Double
    let glowAlpha: CGFloat
    let clock: LyricFrameClock?
    /// Bumped to play the translation particles over this voice.
    var particleTrigger = 0
    /// Whether the line's own crossfades are disabled. The strip passes its Reduce settings; the
    /// panel does not, as Android's fades keep running under either.
    var reduceMotion = false

    @Environment(\.layoutDirection) private var layoutDirection

    final class Coordinator {
        var particleTrigger = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> LyricLineUIView {
        let view = LyricLineUIView()
        context.coordinator.particleTrigger = particleTrigger
        configure(view, animated: false)
        return view
    }

    func updateUIView(_ view: LyricLineUIView, context: Context) {
        configure(view, animated: !reduceMotion)
        if particleTrigger != context.coordinator.particleTrigger {
            context.coordinator.particleTrigger = particleTrigger
            if particleTrigger > 0 { view.playParticles() }
        }
    }

    private func configure(_ view: LyricLineUIView, animated: Bool) {
        view.configure(
            line: line,
            style: style,
            rightToLeftLayout: layoutDirection == .rightToLeft,
            dimAlpha: dimAlpha,
            glowAlpha: glowAlpha,
            clock: clock,
            animated: animated
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: LyricLineUIView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        guard width.isFinite, width > 0 else { return nil }
        configure(uiView, animated: false)
        return uiView.fittingSize(forWidth: width)
    }

    static func dismantleUIView(_ view: LyricLineUIView, coordinator: Coordinator) {
        view.detach()
    }
}
