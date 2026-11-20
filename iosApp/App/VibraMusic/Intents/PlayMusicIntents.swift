import AppIntents
import Foundation

// Ports MusicLink.kt's `MEDIA_PLAY_FROM_SEARCH` handling for Siri and Shortcuts.
//
// Two ways in, because App Intents can't carry free text inside an App Shortcut phrase:
// - "Hey Siri, play Daft Punk in Vibra Music" is SiriKit's media domain (`INPlayMediaIntent`,
//   PlayMediaIntentHandler.swift), which is how Siri hands a spoken media request to an audio app.
// - These App Intents: "Play music in Vibra Music" (nothing named: resumes), and "Play something in
//   Vibra Music", where Siri asks what to play. Both also appear in the Shortcuts app.

/// "Play music": carries on with what was playing, or plays what it is given.
struct PlayMusicIntent: AudioPlaybackIntent, ForegroundContinuableIntent {
    static var title = LocalizedStringResource("play", defaultValue: "Play", table: "Localizable")
    static var openAppWhenRun = false

    @Parameter(title: LocalizedStringResource("search", defaultValue: "Search", table: "Localizable"))
    var query: String?

    init() {}

    init(query: String?) {
        self.query = query
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await PlayIntentRunner.run(query)
        return .result()
    }
}

/// "Play something": Siri asks for the words, then plays the best match.
struct PlaySearchIntent: AudioPlaybackIntent, ForegroundContinuableIntent {
    static var title = LocalizedStringResource("search", defaultValue: "Search", table: "Localizable")
    static var openAppWhenRun = false

    @Parameter(
        title: LocalizedStringResource("search", defaultValue: "Search", table: "Localizable"),
        requestValueDialog: IntentDialog(LocalizedStringResource("search_hint", defaultValue: "Artists, Songs, Lyrics and More", table: "Localizable"))
    )
    var query: String

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        try await PlayIntentRunner.run(query)
        return .result()
    }
}

@MainActor
enum PlayIntentRunner {
    static func run(_ query: String?) async throws {
        let handler = SystemIntentBridge.handler
        let outcome = await handler?.play(request: query) ?? .unavailable
        switch outcome {
        case .playing, .resumed:
            break
        // Nothing matched: the app has opened its search on the words, which needs the screen.
        case .showedSearch:
            throw PlayMusicIntent().needsToContinueInForegroundError()
        // Without an error Siri and Shortcuts would report a run that played nothing as done.
        case .nothingToPlay, .unavailable:
            throw NothingPlayedError()
        }
    }
}

struct NothingPlayedError: Error, CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource("no_results", defaultValue: "No results", table: "Localizable")
    }
}

struct Vibra MusicShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayMusicIntent(),
            phrases: [
                "Play music in \(.applicationName)",
                "Play \(.applicationName)",
                "Resume \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("play", defaultValue: "Play", table: "Localizable"),
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PlaySearchIntent(),
            phrases: [
                "Play something in \(.applicationName)",
                "Search \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("search", defaultValue: "Search", table: "Localizable"),
            systemImageName: "magnifyingglass"
        )
    }
}
