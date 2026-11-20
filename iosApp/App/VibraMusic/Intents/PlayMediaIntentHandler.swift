import Intents
import UIKit

/// "Hey Siri, play Daft Punk in Vibra Music": SiriKit's media intent, handled inside the app.
///
/// Siri resolves the words into `mediaSearch`; the app searches and plays the best match, or
/// resumes when nothing was named ("Hey Siri, play music in Vibra Music"). While driving this is
/// CarPlay's search too — CarPlay gives audio apps no on-screen search.
final class PlayMediaIntentHandler: NSObject, INPlayMediaIntentHandling {
    func handle(intent: INPlayMediaIntent) async -> INPlayMediaIntentResponse {
        let query = Self.query(of: intent)
        let outcome = await Self.play(query)
        return INPlayMediaIntentResponse(code: Self.code(for: outcome), userActivity: nil)
    }

    @MainActor
    private static func play(_ query: String?) async -> SystemPlayOutcome {
        await SystemIntentBridge.handler?.play(request: query) ?? .unavailable
    }

    /// The words to search for: the media's name, else its artist or album ("play some Daft Punk").
    static func query(of intent: INPlayMediaIntent) -> String? {
        let search = intent.mediaSearch
        let candidates = [search?.mediaName, search?.artistName, search?.albumName]
        let named = candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard var query = named.first else { return nil }
        // "Play Get Lucky by Daft Punk": the artist narrows the search the way typing both would.
        if search?.mediaName != nil, let artist = search?.artistName, !artist.isEmpty, !query.localizedCaseInsensitiveContains(artist) {
            query += " \(artist)"
        }
        return query
    }

    static func code(for outcome: SystemPlayOutcome) -> INPlayMediaIntentResponseCode {
        switch outcome {
        case .playing, .resumed: return .success
        // The search results need the screen.
        case .showedSearch: return .continueInApp
        case .nothingToPlay: return .failureNoUnplayedContent
        case .unavailable: return .failure
        }
    }
}

extension AppDelegate {
    /// In-app Siri intent handling (no Intents extension): Siri's media requests land here.
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        intent is INPlayMediaIntent ? PlayMediaIntentHandler() : nil
    }
}
