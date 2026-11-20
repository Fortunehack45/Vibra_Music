import VibraMusicCore
import SwiftUI
import UIKit

// The moving sheet's top edge, dissolving: while the player opens or closes, a band along the
// sheet's top fades to clear at the edge, blurs toward it and goes under a black shade.
// `dockFade()` cuts every faded layer with `EdgeMask`; `DockEdgeShade` draws the blur and shade.
// Depth and timing come from ``DockFrame/edge``.

/// The sheet's top edge dissolving: clear at the edge, solid ~40% into the band. Placed in window
/// points, where the sheet's top is the stage's offset, so every faded piece cuts at the same line.
/// Drawn well past the masked view's frame: a mask hides whatever falls outside it, and a backdrop
/// that ignores the safe area from inside a frame that keeps it (landscape) draws past that frame.
struct EdgeMask: View {
    let edge: CGFloat
    let sheetTop: CGFloat
    private static let overflow: CGFloat = 2000

    var body: some View {
        band.padding(-Self.overflow)
    }

    @ViewBuilder
    private var band: some View {
        if edge < 1 {
            Color.black
        } else {
            GeometryReader { proxy in
                let height = max(proxy.size.height, 1)
                let top = sheetTop - proxy.frame(in: .global).minY
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.35), location: 0.38),
                        .init(color: .black.opacity(0.8), location: 0.71),
                        .init(color: .black, location: 1),
                    ],
                    startPoint: UnitPoint(x: 0.5, y: top / height),
                    endPoint: UnitPoint(x: 0.5, y: (top + 0.42 * edge) / height)
                )
            }
        }
    }
}

/// Over the sheet's top edge while it moves: the system's dark blur and a black shade, both gone
/// with the player's fade, so nothing rides the empty sheet down past the docking cover. Placed in
/// each player's stack over its faded layers and under the flying artwork, which stays crisp.
/// Fills its place from the sheet's top.
struct DockEdgeShade: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let frame = router.dockFrame
        let fade = CGFloat(frame.fade)
        ZStack(alignment: .top) {
            if frame.edge >= 1 {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.92), location: 0),
                        .init(color: .black.opacity(0.55), location: 0.3),
                        .init(color: .black.opacity(0.15), location: 0.65),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: frame.edge)
                .opacity(fade)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A blur whose strength follows `progress` (0 none, 1 the full material): a paused property
/// animator scrubbed to it, the one way UIKit draws a partial blur. Strongest just inside the
/// sheet's edge and gone at the band's end, through the view's own mask.
private struct EdgeBlur: UIViewRepresentable {
    var progress: CGFloat

    func makeUIView(context: Context) -> EdgeBlurView {
        let view = EdgeBlurView()
        let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) {
            view.effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        }
        animator.pausesOnCompletion = true
        animator.fractionComplete = progress
        context.coordinator.animator = animator
        return view
    }

    func updateUIView(_ view: EdgeBlurView, context: Context) {
        context.coordinator.animator?.fractionComplete = progress
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// A paused animator released while still active raises, so it is stopped first.
    static func dismantleUIView(_ view: EdgeBlurView, coordinator: Coordinator) {
        coordinator.animator?.stopAnimation(true)
        coordinator.animator = nil
    }

    final class Coordinator {
        var animator: UIViewPropertyAnimator?
    }
}

/// A blur view faded by a gradient in its `mask` view, the masking UIKit supports for effect views.
final class EdgeBlurView: UIVisualEffectView {
    private let fadeMask = UIView()
    private let gradient = CAGradientLayer()

    init() {
        super.init(effect: nil)
        gradient.colors = [0, 0.55, 1, 0.45, 0].map { UIColor.black.withAlphaComponent($0).cgColor }
        gradient.locations = [0, 0.15, 0.35, 0.7, 1]
        fadeMask.layer.addSublayer(gradient)
        mask = fadeMask
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        fadeMask.frame = bounds
        gradient.frame = bounds
    }
}
