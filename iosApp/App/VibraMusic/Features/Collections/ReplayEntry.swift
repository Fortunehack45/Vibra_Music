import VibraMusicCore
import Replay
import SwiftUI
import Theming

// The way into Replay at the top of the Library: LibraryScreen.kt's ReplayBanner before there is
// listening to show, and ui/replay/ReplayScreen.kt's ReplayCardRow of ReplayCreditCards (ReplayCard.kt)
// once there is. Drawn whether or not anything has been played — the page has to say the feature
// exists, or the only way to find it is to have used it.

struct ReplayEntry: View {
    let cards: [ReplayHeroCard]
    let holder: String
    let memberSince: String?
    /// The chart the tapped card summarises; the banner opens the stories' intro (LibraryScreen.kt).
    let onOpen: (ReplayStoryPage) -> Void

    var body: some View {
        if cards.isEmpty {
            ReplayBanner { onOpen(.intro) }
                .padding(.horizontal, CollectionsMetrics.gutter)
                .padding(.vertical, 6)
        } else {
            // ReplayCardRow: 300-wide cards 12 apart. The card itself is Social's port of
            // ReplayCard.kt, so the Library and the Replay page draw the very same card.
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(cards, id: \.label) { card in
                        ReplayWalletCard(card: card, holder: holder, memberSince: memberSince) { onOpen(card.page) }
                            .frame(width: 300)
                    }
                }
                .padding(.horizontal, CollectionsMetrics.gutter)
                .padding(.vertical, 6)
            }
            .scrollClipDisabled()
            .accessibilityIdentifier("library.replayCards")
        }
    }
}

/// One wide strip rather than a shelf: a carousel with one card always reads as one that failed to
/// load the rest. Lit by the Replay mesh (stock colours, drifting — `continuous = true`) rather than
/// a brand gradient, so it doesn't read as a promo.
private struct ReplayBanner: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.yourReplay)
                        .font(CollectionsType.titleLarge)
                        .foregroundStyle(.white)
                    Text(L10n.replaySubtitle)
                        .font(CollectionsType.bodySmall)
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: AppSymbol.chevronRight)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .flipsForRightToLeftLayoutDirection(true)
                    .accessibilityHidden(true)
            }
            .padding(18)
            .background {
                ZStack {
                    ReplayBannerMesh()
                    // Light, and running the other way from the mesh's own scrim: just enough under
                    // the words at the leading end, almost nothing over the colour at the trailing end.
                    LinearGradient(colors: [.black.opacity(0.34), .black.opacity(0.12), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.replay")
    }
}

/// MeshGradientBackground with `continuous = true` and a 28 blur: the four stock blobs orbiting a
/// full turn every `defaultDriftDuration × 4`, linearly and for as long as the strip is on screen.
/// Held at phase 0 when Reduce Motion is on (`MeshGradientMotion.phaseChange`).
struct ReplayBannerMesh: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var palettes = MeshPaletteModel(cache: .shared)
    /// Where the orbit started; phases are measured from here so they stay small numbers.
    @State private var start = Date()

    var body: some View {
        let colors = MeshGradientColors(palette: palettes.currentPalette(for: nil))
        let change = MeshGradientMotion.phaseChange(animated: true, reduceAnimation: reduceMotion, continuous: true)
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
                Canvas { context, size in
                    let phase = Self.phase(for: change, elapsed: timeline.date.timeIntervalSince(start))
                    for blob in MeshGradientLayout.blobs(colors: colors, phase: phase, in: size) {
                        let rect = CGRect(x: blob.center.x - blob.radius, y: blob.center.y - blob.radius,
                                          width: blob.radius * 2, height: blob.radius * 2)
                        context.fill(Path(ellipseIn: rect), with: .radialGradient(
                            Gradient(colors: [blob.color.color, blob.color.withAlpha(0).color]),
                            center: blob.center, startRadius: 0, endRadius: blob.radius
                        ))
                    }
                }
                .background(colors.base.color)
            }
            .blur(radius: 28, opaque: true)
            .scaleEffect(MeshGradientLayout.overscale)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .overlay(
            LinearGradient(stops: MeshGradientLayout.scrimStops.map { .init(color: $0.color.color, location: $0.location) },
                           startPoint: .top, endPoint: .bottom)
        )
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    /// The drift phase (radians) `elapsed` seconds in: an orbit advances linearly and never wraps
    /// (the blobs' speeds differ, so a lap doesn't land where it began); anything else rests where it
    /// snapped.
    static func phase(for change: MeshGradientMotion.PhaseChange, elapsed: TimeInterval) -> Double {
        switch change {
        case .orbit(let radians, let duration):
            guard duration > 0 else { return 0 }
            return max(elapsed, 0) / duration * radians
        case .snap(let phase):
            return phase
        case .settle:
            return 0
        }
    }
}
