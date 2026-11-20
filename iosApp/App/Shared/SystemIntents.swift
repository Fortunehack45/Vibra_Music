import AppIntents
import Foundation

// Ports widget/MediaWidgetActions.kt: the widget's transport buttons as App Intents.
//
// Android reaches playback from a widget tap by binding the media session, so the command runs in
// the app's process. `AudioPlaybackIntent` is the iOS counterpart: an interactive widget's
// audio-playback intent is performed in the app's process (launched in the background when it isn't
// running), where the player lives. These files are compiled into the app and the widget (and the
// Share Extension, which never runs them); only the app contains the handler, so the widget-side
// copy of `perform()` finds none and does nothing.

/// What a widget button asks the player to do (MediaWidgetActions' ACTION_*).
enum WidgetTransportAction: String, CaseIterable, Sendable {
    case togglePlayPause
    case next
    case previous
    case like
    case shuffle
}

/// Implemented by the app (App/Vibra Music/Intents) under ``SharedConstants/intentHandlerClassName``.
protocol SystemIntentHandling: AnyObject {
    /// Runs a widget button's command against the app's player.
    @MainActor static func perform(_ action: WidgetTransportAction) async
    /// "Play X": searches and plays the best match; an empty request resumes.
    @MainActor static func play(request: String?) async -> SystemPlayOutcome
}

/// What a spoken or typed "play" request ended up doing.
enum SystemPlayOutcome: String, Sendable, Equatable {
    /// A matching song started.
    case playing
    /// Nothing was named, and what was already queued carried on.
    case resumed
    /// Nothing matched; the app opens its search results instead (MainActivity's fallback).
    case showedSearch
    /// Nothing was named and there was nothing to resume.
    case nothingToPlay
    /// The request couldn't reach the player (this process isn't the app).
    case unavailable
}

/// Finds the app's handler at run time.
enum SystemIntentBridge {
    /// Tests substitute their own.
    nonisolated(unsafe) static var handlerOverride: SystemIntentHandling.Type?

    static var handler: SystemIntentHandling.Type? {
        handlerOverride ?? (NSClassFromString(SharedConstants.intentHandlerClassName) as? SystemIntentHandling.Type)
    }

    @MainActor
    static func perform(_ action: WidgetTransportAction) async {
        await handler?.perform(action)
    }
}

/// Play / pause (`ACTION_TOGGLE`).
struct TogglePlaybackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = LocalizedStringResource("widget_play", defaultValue: "Play")
    static var isDiscoverable = false
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await SystemIntentBridge.perform(.togglePlayPause)
        return .result()
    }
}

/// Next (`ACTION_NEXT`).
struct NextTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = LocalizedStringResource("widget_next", defaultValue: "Next")
    static var isDiscoverable = false
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await SystemIntentBridge.perform(.next)
        return .result()
    }
}

/// Previous (`ACTION_PREVIOUS`).
struct PreviousTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = LocalizedStringResource("widget_previous", defaultValue: "Previous")
    static var isDiscoverable = false
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await SystemIntentBridge.perform(.previous)
        return .result()
    }
}

/// Like / remove from liked (`ACTION_LIKE`, the 4×1 widget's heart).
struct ToggleLikeIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = LocalizedStringResource("like", defaultValue: "Like")
    static var isDiscoverable = false
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await SystemIntentBridge.perform(.like)
        return .result()
    }
}

/// Shuffle on / off (`ACTION_SHUFFLE`, the 4×1 widget).
struct ToggleShuffleIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = LocalizedStringResource("shuffle", defaultValue: "Shuffle")
    static var isDiscoverable = false
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await SystemIntentBridge.perform(.shuffle)
        return .result()
    }
}
