import Foundation
import Theming

// The mesh backdrop's crossfade (ArtworkMeshBackdrop.kt's `LaunchedEffect(mesh)`): each new mesh is
// drawn over the one on screen and eased in over MESH_FADE_MS with FastOutSlowIn. Theming's
// ``ArtworkMeshCrossfade`` is the same state machine, but a change arriving mid-fade there promotes
// the half-faded mesh to fully opaque, which is a visible jump every time a clip's read lands
// inside a track skip's fade. Here the half-faded layer is frozen where it stands instead, so the
// next fade really starts from what is on screen.

/// The layers the player's mesh backdrop draws, bottom to top, and how they fade.
///
/// - The first mesh has nothing to fade from: it is shown at once.
/// - Nil (a cover not read yet, the gap between two tracks) changes nothing — the last mesh stays
///   up. Nothing here ever takes the backdrop back to its bare floor colour.
/// - Reduced motion: every change is a cut.
/// - A change mid-fade freezes the fading layer at its current opacity and fades the new one in
///   over the lot, so the start of the new fade is exactly the picture that was on screen.
struct PlayerMeshFade: Equatable {
    /// Android's MESH_FADE_MS.
    static let duration: TimeInterval = ArtworkMeshCrossfade.fadeDuration
    /// Frozen layers kept under a fade before the lowest ones are folded away. Only reached when
    /// changes arrive faster than one per fade (a burst of skips); a clip reads every 3 s.
    static let maxLayers = 4

    struct Layer: Equatable, Identifiable {
        let id: Int
        let mesh: ArtworkMesh
        var opacity: Double
    }

    /// Settled layers, bottom first; the bottom one is always opaque.
    private(set) var base: [Layer] = []
    /// The mesh fading in over ``base``.
    private(set) var incoming: Layer?
    private(set) var fadeStart: TimeInterval = 0
    private var lastReceived: ArtworkMesh?
    private var nextID = 0

    init(mesh: ArtworkMesh? = nil) {
        if let mesh {
            base = [Layer(id: 0, mesh: mesh, opacity: 1)]
            lastReceived = mesh
            nextID = 1
        }
    }

    /// The mesh the backdrop is heading for (what it will show once settled).
    var target: ArtworkMesh? { incoming?.mesh ?? base.last?.mesh }

    /// Feeds the mesh that should now be on screen.
    mutating func receive(_ mesh: ArtworkMesh?, at time: TimeInterval, reduceMotion: Bool) {
        guard let next = mesh, next != lastReceived else { return }
        lastReceived = next

        if var fading = incoming {
            let opacity = incomingOpacity(at: time)
            incoming = nil
            if opacity >= 0.999 {
                fading.opacity = 1
                base = [fading]
            } else if opacity > 0.001 {
                fading.opacity = opacity
                base.append(fading)
            }
        }
        if base.count == 1, base[0].mesh == next { return }
        if base.isEmpty || reduceMotion {
            base = [makeLayer(next, opacity: 1)]
            return
        }
        if base.count >= Self.maxLayers {
            base.removeFirst(base.count - Self.maxLayers + 1)
            base[0].opacity = 1
        }
        incoming = makeLayer(next, opacity: 0)
        fadeStart = time
    }

    /// The incoming layer's opacity at `time`, eased as Android's tween(FastOutSlowInEasing).
    func incomingOpacity(at time: TimeInterval) -> Double {
        guard incoming != nil else { return 0 }
        let linear = min(max((time - fadeStart) / Self.duration, 0), 1)
        return ThemingMotion.fastOutSlowIn(linear)
    }

    func isSettled(at time: TimeInterval) -> Bool {
        incoming == nil || time - fadeStart >= Self.duration
    }

    /// Completes a finished fade: the incoming mesh becomes the only layer.
    mutating func settle(at time: TimeInterval) {
        guard var fading = incoming, time - fadeStart >= Self.duration else { return }
        fading.opacity = 1
        base = [fading]
        incoming = nil
    }

    /// What to draw at `time`, bottom to top.
    func layers(at time: TimeInterval) -> [Layer] {
        guard var fading = incoming else { return base }
        fading.opacity = incomingOpacity(at: time)
        return base + [fading]
    }

    private mutating func makeLayer(_ mesh: ArtworkMesh, opacity: Double) -> Layer {
        defer { nextID += 1 }
        return Layer(id: nextID, mesh: mesh, opacity: opacity)
    }
}
