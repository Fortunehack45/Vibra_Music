import VibraMusicCore
import Foundation
import WidgetKit

/// The app's side of ``SystemIntentHandling``: the widget buttons and "play X", run against the
/// player. Registered by its Objective-C name so the Shared intents can find it without the widget
/// (which compiles the same intents) needing to know the app's types.
@objc(Vibra MusicSystemIntentHandler)
final class SystemIntentHandler: NSObject, SystemIntentHandling {
    @MainActor
    static func perform(_ action: WidgetTransportAction) async {
        guard let model = SystemAppAccess.model() else { return }
        WidgetTransport.perform(action, player: model.player)
    }

    @MainActor
    static func play(request: String?) async -> SystemPlayOutcome {
        guard let model = SystemAppAccess.model() else { return .unavailable }
        return await VoicePlayback.play(request: request, player: model.player, router: model.router, search: VoicePlayback.searchSongs(model.repository))
    }
}

/// What a widget button does (MediaWidgetActions.execute).
@MainActor
enum WidgetTransport {
    static func perform(
        _ action: WidgetTransportAction,
        player: PlayerController,
        defaults: UserDefaults? = NowPlayingSnapshot.sharedDefaults,
        reloadWidgets: Bool = true
    ) {
        // No live or restored queue means the buttons have nothing to control.
        guard player.currentSong != nil else { return }
        switch action {
        case .togglePlayPause:
            // Follows playWhenReady, like the glyph: a tap during a stream's resolve pauses it.
            player.togglePlayPause()
        case .next:
            // Skipping while paused leaves you paused, here as everywhere else.
            _ = player.next()
        case .previous:
            _ = player.previous()
        case .like:
            // Optimistic, with the YouTube write behind it; the snapshot observer republishes.
            _ = player.toggleLike()
        case .shuffle:
            player.toggleShuffle()
            publishQueueShape(of: player, to: defaults, reload: reloadWidgets)
        }
    }

    /// Shuffle changes the widget's face (the 4×1's Shuffle, and which ends of the queue are
    /// dimmed). WidgetSnapshotObserver picks that up on its next main-actor turn, but the widget
    /// redraws as soon as the intent returns, so the snapshot is written here synchronously too.
    static func publishQueueShape(of player: PlayerController, to defaults: UserDefaults?, reload: Bool) {
        guard var snapshot = NowPlayingSnapshot.load(from: defaults) else { return }
        snapshot.shuffleEnabled = player.shuffleEnabled
        snapshot.hasNext = player.hasNext
        snapshot.hasPrevious = player.hasPrevious
        snapshot.save(to: defaults)
        if reload { WidgetCenter.shared.reloadAllTimelines() }
    }
}
