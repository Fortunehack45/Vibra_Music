import VibraMusicCore
import SwiftUI
import Theming

// Ports ui/player/PlayerMeshBackdrop.kt (the artwork's own colours reduced to a mesh, hung from
// where the sleeve stops), its PlayerArtworkBlurBackdrop (one pre-blurred cover for the lyrics and
// the queue), and MeshGradient.kt (v1.5's four drifting blobs, behind the legacy switch). The
// colours come from Theming; this is how they're drawn. iOS 18 draws the mesh with SwiftUI's
// MeshGradient; iOS 17 stretches the resampled texture, as Android did.

// MARK: - Artwork mesh

/// The player's backdrop: the mesh hung from `seam` (where the artwork stops) and stretched over
/// everything below it, with its first row held above. A new mesh — a track skip, or a frame off a
/// playing clip — is drawn over the one on screen and eased in over 0.9 s (``PlayerMeshFade``).
///
/// The outgoing mesh stays fully drawn until the incoming one covers it: the floor colour under
/// the mesh is never what shows. An opacity *transition* on each mesh did let it show — the old
/// layer left at once and the new one faded up from near-black, which read as the screen going
/// black for a beat every time a clip's colours arrived.
struct PlayerMeshBackdrop: View {
    let mesh: ArtworkMesh?
    /// How far down the surface the artwork's bottom edge sits, in points; 0 puts the whole mesh
    /// on screen.
    var seam: CGFloat = 0
    var reduceBlur = false
    var reduceMotion = false

    @State private var fade = PlayerMeshFade()

    var body: some View {
        GeometryReader { proxy in
            let fraction = proxy.size.height > 0 ? min(max(seam / proxy.size.height, 0), 1) : 0
            TimelineView(.animation(minimumInterval: nil, paused: fade.incoming == nil)) { timeline in
                let now = timeline.date.timeIntervalSinceReferenceDate
                ZStack {
                    ArtworkMeshBackdropStyle.fallback.color
                    ForEach(fade.layers(at: now)) { layer in
                        MeshLayerView(mesh: layer.mesh, seamFraction: fraction)
                            .opacity(layer.opacity)
                    }
                }
            }
            .blur(radius: ArtworkMeshBackdropStyle.blurRadius(reduceDynamicBlur: reduceBlur), opaque: true)
            .overlay(PlayerScrimGradient(stops: ArtworkMeshBackdropStyle.scrimStops))
        }
        .accessibilityHidden(true)
        .onChange(of: mesh, initial: true) { _, next in
            fade.receive(next, at: Date.timeIntervalSinceReferenceDate, reduceMotion: reduceMotion)
        }
        .task(id: fade.incoming?.id) {
            // Collapses a finished fade to one layer, which also stops the timeline.
            guard fade.incoming != nil else { return }
            try? await Task.sleep(for: .seconds(PlayerMeshFade.duration + 0.05))
            guard !Task.isCancelled else { return }
            fade.settle(at: Date.timeIntervalSinceReferenceDate)
        }
    }
}

/// One mesh, drawn once.
private struct MeshLayerView: View {
    let mesh: ArtworkMesh
    let seamFraction: Double

    var body: some View {
        if #available(iOS 18.0, *) {
            mesh.gridLayout(seamFraction: seamFraction).meshGradient()
        } else {
            MeshTextureLayer(mesh: mesh, seamFraction: seamFraction)
        }
    }
}

/// iOS 17: two draws of one small texture, both stretched by the sampler — the seam row held above
/// the seam, the whole texture below it (Android's `drawMesh`).
private struct MeshTextureLayer: View {
    let mesh: ArtworkMesh
    let seamFraction: Double

    var body: some View {
        Canvas { context, size in
            let regions = ArtworkMesh.textureRegions(in: size, seam: size.height * seamFraction)
            if regions.held.height > 0, let row = mesh.seamRowImage() {
                context.draw(Image(decorative: row, scale: 1).interpolation(.medium).resizable(), in: regions.held)
            }
            if let texture = mesh.textureImage() {
                context.draw(Image(decorative: texture, scale: 1).interpolation(.medium).resizable(), in: regions.body)
            }
        }
    }
}

/// A vertical gradient from Theming's stops.
struct PlayerScrimGradient: View {
    let stops: [ThemeGradientStop]

    var body: some View {
        LinearGradient(stops: stops.map { Gradient.Stop(color: $0.color.color, location: $0.location) }, startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)
    }
}

// MARK: - Full-cover blur

/// A full-surface, still-art backdrop for the surfaces that have no artwork edge to continue from:
/// the lyrics, the queue, and the landscape player. One copy of the cover cropped across the whole
/// surface and blurred in place, from a pre-blurred thumbnail Theming keeps.
struct PlayerArtworkBlurBackdrop: View {
    let url: URL?
    let palettes: ArtworkPaletteCache

    @State private var image: CGImage?
    @State private var shownURL: URL?

    /// Starts on the cached blur when there is one, so a player reopened on the lyrics or the queue
    /// paints it on its first frame rather than the floor colour until the task runs.
    init(url: URL?, palettes: ArtworkPaletteCache) {
        self.url = url
        self.palettes = palettes
        let cached = url.flatMap(palettes.cachedBlurredArtwork(for:))?.makeCGImage()
        _image = State(initialValue: cached)
        _shownURL = State(initialValue: cached == nil ? nil : url)
    }

    var body: some View {
        // The cover hangs in an overlay of the flexible base colour: a filled image laid out
        // directly would size the surface to the picture (wider than a portrait window) and push
        // everything beside it off screen.
        ArtworkMeshBackdropStyle.fallback.color
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFill()
                        .transition(.opacity)
                        .id(shownURL)
                }
            }
            .overlay(PlayerScrimGradient(stops: ArtworkBlur.scrimStops))
            .clipped()
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .animation(.easeOut(duration: ArtworkBlur.imageFadeDuration), value: shownURL)
        .task(id: url) {
            guard let url else {
                // A track with no cover shows the floor, not the last track's.
                image = nil
                shownURL = nil
                return
            }
            if let cached = palettes.cachedBlurredArtwork(for: url)?.makeCGImage() {
                image = cached
                shownURL = url
                return
            }
            guard let pixels = await palettes.blurredArtwork(for: url, artPixels: ArtworkSize.player),
                  !Task.isCancelled, let made = pixels.makeCGImage() else { return }
            image = made
            shownURL = url
        }
    }
}

// MARK: - v1.5's blob mesh

/// Four luminous blobs sampled from the art, blurred into a mesh (MeshGradient.kt), kept behind
/// Settings' legacy backdrop switch. They drift when there is a reason to — the player opening or
/// the track changing — and then come to rest: a full-screen blur redrawn at display rate for
/// motion nobody is watching was the most expensive thing the old app did.
struct PlayerLegacyMeshBackdrop: View {
    let palette: MeshPalette
    let trackKey: String?
    var reduceMotion = false

    @State private var phase: Double = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                BlobLayer(colors: MeshGradientColors(palette: palette), phase: phase)
                    .id(palette)
                    .transition(.opacity)
            }
            .blur(radius: MeshGradientLayout.defaultBlurRadius, opaque: true)
            .scaleEffect(MeshGradientLayout.overscale)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .overlay(PlayerScrimGradient(stops: MeshGradientLayout.scrimStops))
        .animation(reduceMotion ? nil : .easeInOut(duration: MeshGradientMotion.colorFadeDuration), value: palette)
        .accessibilityHidden(true)
        .onChange(of: trackKey, initial: true) {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: MeshGradientMotion.defaultDriftDuration)) {
                phase += MeshGradientMotion.driftRadians
            }
        }
    }
}

/// The four blobs at one drift phase; animatable, so a settle glides rather than jumps.
private struct BlobLayer: View, Animatable {
    let colors: MeshGradientColors
    var phase: Double

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    var body: some View {
        Canvas { context, size in
            for blob in MeshGradientLayout.blobs(colors: colors, phase: phase, in: size) {
                let rect = CGRect(x: blob.center.x - blob.radius, y: blob.center.y - blob.radius, width: blob.radius * 2, height: blob.radius * 2)
                context.fill(
                    Path(ellipseIn: rect),
                    with: .radialGradient(
                        Gradient(colors: [blob.color.color, blob.color.withAlpha(0).color]),
                        center: blob.center, startRadius: 0, endRadius: blob.radius
                    )
                )
            }
        }
        .background(colors.base.color)
    }
}
