import VibraMusicCore
import Replay
import SwiftUI
import Theming

// The pieces Replay's page, stories and cards share: the player's blob mesh held still
// (MeshGradientBackground with `animated = false`), the wallet card (ReplayCard.kt's
// ReplayCreditCard), the rank badge and the lettered stand-in cover (ReplayCard.kt).

// MARK: - Mesh

/// Four soft blobs sampled from `artwork`, blurred into a mesh, turned `hue` degrees around the
/// colour wheel. Drawn once and held still: a Replay surface should read as a still image, and a
/// row of cards re-blurring on every swipe is the expensive case.
struct ReplayMeshBackground: View {
    let artwork: String?
    var hue: Double = 0
    var blurRadius: CGFloat = MeshGradientLayout.defaultBlurRadius
    /// The size ``ReplayCover`` draws the same artwork at, so the colours come out of its cache
    /// entry instead of a second download of the full-size cover.
    var artPixels = ArtworkSize.row

    @State private var model = MeshPaletteModel(cache: .shared)

    private var url: URL? { artwork.flatMap(URL.init(string:)) }

    var body: some View {
        let palette = model.currentPalette(for: url).rotated(degrees: Float(hue))
        GeometryReader { proxy in
            ReplayBlobLayer(colors: MeshGradientColors(palette: palette))
                .blur(radius: blurRadius, opaque: true)
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
        .task(id: url) { await model.load(url, artPixels: artPixels) }
    }
}

/// The blobs at rest (drift phase 0).
private struct ReplayBlobLayer: View {
    let colors: MeshGradientColors

    var body: some View {
        Canvas { context, size in
            for blob in MeshGradientLayout.blobs(colors: colors, phase: 0, in: size) {
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
}

// MARK: - Credit card

/// One headline number as a card you could keep in a wallet: the real card proportions (85.6 × 54
/// mm), the cardholder and member-since lines embossed, the logo top-right, lit by the record it
/// describes.
struct ReplayWalletCard: View {
    let card: ReplayHeroCard
    let holder: String
    let memberSince: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                ReplayMeshBackground(artwork: card.artworkUrl, blurRadius: 34)
                // Deepened towards the foot, where the pale embossed lines are.
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.18), location: 0),
                    .init(color: .black.opacity(0.30), location: 0.55),
                    .init(color: .black.opacity(0.55), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                face
            }
            .aspectRatio(1.586, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
            .environment(\.colorScheme, .dark)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(card.label), \(card.value)")
        .accessibilityValue(card.detail ?? "")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("replayCard")
    }

    private var face: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Text(L10n.yourListeningExperience.uppercased(with: ReplayText.locale))
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(maxWidth: .infinity, alignment: .leading)
                ReplayLogo(height: 22)
            }
            Spacer(minLength: 0)
            Text(card.value)
                .font(.system(size: 27, weight: .heavy))
                .foregroundStyle(ReplayInk.polished)
                .shadow(color: .black.opacity(0.6), radius: 2, y: 1.2)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Text(card.label.uppercased(with: ReplayText.locale))
                .font(.system(size: 11, weight: .bold))
                .tracking(1.8)
                .foregroundStyle(.white.opacity(0.65))
            Spacer(minLength: 0).frame(maxHeight: .infinity).layoutPriority(-1)
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    ReplayEmbossed(text: (holder.isEmpty ? L10n.defaultReplayHolder : holder).uppercased(with: ReplayText.locale), size: 13)
                    if let detail = card.detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let memberSince {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(L10n.memberSince.uppercased(with: ReplayText.locale))
                            .font(.system(size: 7, weight: .semibold))
                            .tracking(0.8)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.white.opacity(0.55))
                        ReplayEmbossed(text: memberSince, size: 12)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }
}

/// The Vibra Music mark as the app draws it on iOS (no vector logo ships in the asset catalog).
struct ReplayLogo: View {
    var height: CGFloat

    var body: some View {
        Image(systemName: ReplayLogo.symbol)
            .font(.system(size: height * 0.9, weight: .semibold))
            .foregroundStyle(.white)
            .frame(height: height)
            .accessibilityHidden(true)
    }

    nonisolated static let symbol = "waveform.circle.fill"
}

/// The fill on every raised line: bright along the top edge, cooler below.
enum ReplayInk {
    static let polished = LinearGradient(
        colors: [Color(white: 1), Color(red: 0xF3 / 255, green: 0xF4 / 255, blue: 0xF8 / 255),
                 Color(red: 0xC9 / 255, green: 0xCC / 255, blue: 0xD6 / 255)],
        startPoint: .top, endPoint: .bottom
    )
}

/// A line pressed into the card: fixed-pitch and widely tracked (what an embosser produces), a
/// dark shadow under a fill lit from above.
struct ReplayEmbossed: View {
    let text: String
    let size: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .semibold, design: .monospaced))
            .tracking(1.6)
            .foregroundStyle(ReplayInk.polished)
            .shadow(color: .black.opacity(0.6), radius: 2, y: 1.2)
            .lineLimit(1)
    }
}

// MARK: - Rank and stand-in

/// Number one is the accent; the rest are quiet — a chart where every position shouts has no
/// first place.
struct ReplayRankBadge: View {
    let rank: Int
    /// The colour of ranks two and down.
    var quiet: Color = .white.opacity(0.45)

    var body: some View {
        Text("\(rank)")
            .font(rank == 1 ? .title3.weight(.heavy) : .headline.weight(.heavy))
            .foregroundStyle(rank == 1 ? AppTheme.accentRed : quiet)
            .frame(width: 28, alignment: .leading)
            .accessibilityHidden(true)
    }
}

/// A stand-in cover for a row with no artwork (a genre): its initial on a colour derived from the
/// word, so the same genre is the same colour every time.
struct ReplayInitialTile<S: Shape>: View {
    let text: String
    let size: CGFloat
    let shape: S

    var body: some View {
        let color = Color(replayHue: replayInitialTileHue(for: text) / 360, saturation: 0.55, lightness: 0.45)
        ZStack {
            LinearGradient(colors: [color, color.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(text.prefix(1).uppercased())
                .font(.system(size: size * 0.42, weight: .heavy))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .accessibilityHidden(true)
    }
}

/// A cover: the artwork, else the lettered tile, else a faint square.
struct ReplayCover<S: Shape>: View {
    let url: String?
    let fallbackText: String
    let size: CGFloat
    let shape: S
    var pixels = ArtworkSize.row
    var elevated = false

    var body: some View {
        Group {
            if let url {
                ArtworkImage(url, pixels: pixels, cornerRadius: 0)
                    .frame(width: size, height: size)
                    .clipShape(shape)
            } else if !fallbackText.isEmpty {
                ReplayInitialTile(text: fallbackText, size: size, shape: shape)
            } else {
                shape.fill(Color.white.opacity(0.10)).frame(width: size, height: size)
            }
        }
        .shadow(color: .black.opacity(elevated ? 0.35 : 0), radius: elevated ? 12 : 0, y: elevated ? 6 : 0)
        .accessibilityHidden(true)
    }
}

extension Color {
    /// HSL, as Android's `Color.hsl`.
    init(replayHue hue: Double, saturation: Double, lightness: Double) {
        let l = lightness, s = saturation
        let brightness = l + s * min(l, 1 - l)
        let hsbSaturation = brightness == 0 ? 0 : 2 * (1 - l / brightness)
        self.init(hue: hue, saturation: hsbSaturation, brightness: brightness)
    }
}
