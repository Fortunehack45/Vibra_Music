import Foundation
import MediaPlayer

/// Registers the engine's remote-command handler with the system. The default wraps
/// `MPRemoteCommandCenter`; tests inject a fake and call the handler directly (an
/// `MPRemoteCommandEvent` can't be constructed outside the system).
@MainActor
public protocol RemoteCommandRegistering: AnyObject {
    func activate(handler: @escaping @MainActor (RemoteCommand) -> RemoteCommandResult)
    func deactivate()
    /// Lights the like/dislike buttons for the current item.
    func updateFeedback(isLiked: Bool, isDisliked: Bool)
}

/// `MPRemoteCommandCenter.shared()`.
@MainActor
public final class SystemRemoteCommandCenter: RemoteCommandRegistering {
    private let center: MPRemoteCommandCenter
    private var targets: [(MPRemoteCommand, Any)] = []
    /// Whether the lock screen shows ±15 s skip buttons. Off: on iOS they *replace* next/previous,
    /// which is right for a podcast app and wrong for this one.
    public var showsSkipIntervals: Bool
    /// Whether like/dislike are offered (the Android notification's heart). On iPhone the system
    /// may present feedback commands in a menu that takes the previous-track slot on the lock
    /// screen; turn this off to keep previous there. CarPlay and the watch show them alongside.
    public var showsFeedbackCommands: Bool

    public init(center: MPRemoteCommandCenter = .shared(), showsSkipIntervals: Bool = false, showsFeedbackCommands: Bool = true) {
        self.center = center
        self.showsSkipIntervals = showsSkipIntervals
        self.showsFeedbackCommands = showsFeedbackCommands
    }

    public func activate(handler: @escaping @MainActor (RemoteCommand) -> RemoteCommandResult) {
        deactivate()
        func add(_ command: MPRemoteCommand, _ map: @escaping (MPRemoteCommandEvent) -> RemoteCommand?) {
            command.isEnabled = true
            let target = command.addTarget { event in
                guard let mapped = map(event) else { return .commandFailed }
                return Self.onMain { handler(mapped) }.status
            }
            targets.append((command, target))
        }
        add(center.playCommand) { _ in .play }
        add(center.pauseCommand) { _ in .pause }
        add(center.togglePlayPauseCommand) { _ in .togglePlayPause }
        add(center.stopCommand) { _ in .stop }
        add(center.nextTrackCommand) { _ in .nextTrack }
        add(center.previousTrackCommand) { _ in .previousTrack }
        add(center.changePlaybackPositionCommand) { event in
            (event as? MPChangePlaybackPositionCommandEvent).map { .changePlaybackPosition($0.positionTime) }
        }
        center.changePlaybackRateCommand.supportedPlaybackRates = [0.5, 0.75, 1, 1.25, 1.5, 2]
        add(center.changePlaybackRateCommand) { event in
            (event as? MPChangePlaybackRateCommandEvent).map { .changePlaybackRate($0.playbackRate) }
        }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
        add(center.skipForwardCommand) { event in .skipForward((event as? MPSkipIntervalCommandEvent)?.interval ?? 15) }
        add(center.skipBackwardCommand) { event in .skipBackward((event as? MPSkipIntervalCommandEvent)?.interval ?? 15) }
        center.skipForwardCommand.isEnabled = showsSkipIntervals
        center.skipBackwardCommand.isEnabled = showsSkipIntervals
        center.likeCommand.localizedTitle = "Like"
        center.likeCommand.localizedShortTitle = "Like"
        center.dislikeCommand.localizedTitle = "Dislike"
        center.dislikeCommand.localizedShortTitle = "Dislike"
        add(center.likeCommand) { [center] _ in .like(wasActive: center.likeCommand.isActive) }
        add(center.dislikeCommand) { [center] _ in .dislike(wasActive: center.dislikeCommand.isActive) }
        center.likeCommand.isEnabled = showsFeedbackCommands
        center.dislikeCommand.isEnabled = showsFeedbackCommands
    }

    public func deactivate() {
        for (command, target) in targets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        targets.removeAll()
    }

    public func updateFeedback(isLiked: Bool, isDisliked: Bool) {
        center.likeCommand.isActive = isLiked
        center.dislikeCommand.isActive = isDisliked
    }

    /// The command center calls its targets on the main thread; hop there if it ever doesn't.
    nonisolated private static func onMain(_ body: @MainActor () -> RemoteCommandResult) -> RemoteCommandResult {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { body() }
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }
}

extension RemoteCommandResult {
    var status: MPRemoteCommandHandlerStatus {
        switch self {
        case .success: return .success
        case .noSuchContent: return .noSuchContent
        case .noActionableNowPlayingItem: return .noActionableNowPlayingItem
        case .commandFailed: return .commandFailed
        }
    }
}
