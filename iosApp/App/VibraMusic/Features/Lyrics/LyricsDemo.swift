#if DEBUG
import VibraMusicCore
import Lyrics
import SwiftUI

/// Canned lyrics and providers for the debug screens and the tests: a word-synced song with an
/// intro, a duet voice, an answering vocal, a held note and an instrumental break, so every
/// feature of the panel is on the page at once. Nothing here touches the network.
enum LyricsDemo {
    /// A word-synced line: `words` are (text, duration ms), laid end to end from `at`.
    static func line(_ at: Int, _ words: [(String, Int)], alignment: LyricAlignment = .start, background: LyricLine? = nil) -> LyricLine {
        var time = at
        var timed: [LyricWord] = []
        for (text, duration) in words {
            timed.append(LyricWord(startMs: time, endMs: time + duration, text: text))
            time += duration
        }
        return LyricLine(
            timeMs: at,
            text: words.map(\.0).joined(separator: " "),
            words: timed,
            background: background,
            alignment: alignment
        )
    }

    static let wordSynced: [LyricLine] = [
        LyricLine(timeMs: 0, text: ""),
        line(2_000, [("Like", 350), ("a", 250), ("lighthouse", 700), ("in", 250), ("the", 250), ("dark", 800)]),
        line(4_800, [("You", 300), ("keep", 400), ("on", 300), ("calling", 600), ("me", 300), ("home", 900)],
             background: line(7_000, [("(calling", 500), ("me", 300), ("home)", 700)])),
        LyricLine(timeMs: 8_000, text: ""),
        line(12_000, [("I", 250), ("hear", 450), ("you", 350), ("over", 450), ("the", 250), ("water", 900)], alignment: .end),
        line(15_000, [("Hold", 450), ("on,", 500), ("hold", 400), ("on", 2_400), ("to", 300), ("me", 900)]),
        line(20_200, [("We'll", 400), ("find", 450), ("the", 250), ("shore", 700), ("tonight", 1_200)], alignment: .end),
        line(23_600, [("And", 300), ("every", 500), ("wave", 600), ("will", 350), ("carry", 600), ("us", 900)]),
        line(27_200, [("Back", 400), ("to", 250), ("where", 450), ("we", 300), ("started", 1_100)]),
    ]

    /// Invented Japanese lines in kanji and kana, line-synced and timed like an LRCLIB answer.
    static let japanese: [LyricLine] = [
        LyricLine(timeMs: 1_410, text: "静かな港に灯りがともる頃に", sungUntilMs: 6_830),
        LyricLine(timeMs: 6_830, text: ""),
        LyricLine(timeMs: 8_920, text: "遠い波の音が窓をたたく朝", sungUntilMs: 15_680),
        LyricLine(timeMs: 15_680, text: "「おかえり」とうたうよ", sungUntilMs: 19_200),
        LyricLine(timeMs: 19_200, text: "小さな舟で明日へ向かった", sungUntilMs: 24_000),
    ]

    static let japaneseTranslated: [LyricLine] = [
        LyricLine(timeMs: 1_410, text: "As the quiet harbor lights up", sungUntilMs: 6_830),
        LyricLine(timeMs: 6_830, text: ""),
        LyricLine(timeMs: 8_920, text: "In the morning, distant waves knock at the window", sungUntilMs: 15_680),
        LyricLine(timeMs: 15_680, text: "Singing \"welcome home\"", sungUntilMs: 19_200),
        LyricLine(timeMs: 19_200, text: "We set off for tomorrow in a little boat", sungUntilMs: 24_000),
    ]

    /// Plain lyrics with Genius-style section headers.
    static let plain: [LyricLine] = [
        LyricLine(timeMs: 0, text: "[Verse 1]"),
        LyricLine(timeMs: 0, text: "Like a lighthouse in the dark"),
        LyricLine(timeMs: 0, text: "You keep on calling me home"),
        LyricLine(timeMs: 0, text: ""),
        LyricLine(timeMs: 0, text: "[Chorus]"),
        LyricLine(timeMs: 0, text: "Hold on, hold on to me"),
        LyricLine(timeMs: 0, text: "We'll find the shore tonight"),
    ]

    static let track = LyricsTrack(videoId: "demo-lighthouse", title: "Lighthouse", artist: "Vibra Music", album: nil, durationMs: 200_000, localFileURL: nil)

    /// A provider that answers after `delay` with `lines`, or with nothing.
    struct Provider: LyricsProvider {
        var lines: [LyricLine]?
        var delay: Duration = .zero

        func lyrics(for request: LyricsProviderRequest) async throws -> LyricsProviderAnswer? {
            if delay > .zero { try await Task.sleep(for: delay) }
            return lines.map { LyricsProviderAnswer(lines: $0) }
        }
    }

    /// A repository where every source is canned: a word-synced hit from the top source, a
    /// line-synced one further down, misses, and one still thinking.
    static func repository(topAnswers: Bool = true) -> LyricsRepository {
        var overrides: [LyricsSource: any LyricsProvider] = [:]
        for source in LyricsSource.allCases { overrides[source] = Provider(lines: nil) }
        overrides[.biniLyrics] = Provider(lines: topAnswers ? wordSynced : nil, delay: .milliseconds(80))
        overrides[.betterLyrics] = Provider(lines: wordSynced, delay: .milliseconds(20))
        overrides[.lrcLib] = Provider(lines: wordSynced.map { LyricLine(timeMs: $0.timeMs, text: $0.text) }, delay: .milliseconds(10))
        overrides[.paxSenix] = Provider(lines: wordSynced, delay: .seconds(120))
        return LyricsRepository(overrides: overrides)
    }
}

// MARK: - Debug screens

/// `-lyricsDebugScreen panel|translated|plain|loading|empty|provider|offset|sources|translation`
/// opens that screen over the app with canned lyrics, for screenshots and manual checks.
/// `-lyricsDebugPosition <ms>` sets the song position; `-lyricsDebugPlaying NO` holds it still.
struct LyricsDebugScreens: ViewModifier {
    private let screen = UserDefaults.standard.string(forKey: "lyricsDebugScreen")

    func body(content: Content) -> some View {
        if let screen {
            // An overlay, not a full-screen cover: the shell presents its own covers and sheets at
            // launch, and a `.constant(true)` cover loses that race and never shows.
            content.overlay {
                LyricsDebugHost(screen: screen)
            }
        } else {
            content
        }
    }
}

extension View {
    func lyricsDebugScreens() -> some View { modifier(LyricsDebugScreens()) }
}

private struct LyricsDebugHost: View {
    let screen: String
    @State private var clock = LyricFrameClock()
    @State private var translation = LyricsTranslationController()
    @State private var session = LyricsSession(repository: LyricsDemo.repository())
    @State private var sheetShown = true
    @State private var startedAt = Date()
    @State private var position = UserDefaults.standard.object(forKey: "lyricsDebugPosition") as? Int
        ?? Int(UserDefaults.standard.string(forKey: "lyricsDebugPosition") ?? "") ?? 15_900
    private let playing = UserDefaults.standard.object(forKey: "lyricsDebugPlaying") == nil
        || UserDefaults.standard.bool(forKey: "lyricsDebugPlaying")

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.20, blue: 0.34), Color(red: 0.05, green: 0.06, blue: 0.10)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            switch screen {
            case "panel", "translated", "plain", "loading", "empty":
                panel
                    .padding(.horizontal, LyricsPanelMetrics.gutter)
                    .padding(.top, 20)
                    // The player is dark whatever the app theme; the settings sheets are not.
                    .environment(\.colorScheme, .dark)
            default:
                Color.clear
            }
        }
        .sheet(isPresented: sheetBinding) {
            sheet
        }
        .task {
            clock.reset(positionMs: position, isPlaying: playing)
            clock.isRunnable = true
            session.load(LyricsDemo.track, preferences: .default)
            guard playing else { return }
            startedAt = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                clock.report(positionMs: position + Int(Date().timeIntervalSince(startedAt) * 1_000), isPlaying: true)
            }
        }
    }

    private var sheetBinding: Binding<Bool> {
        Binding(get: { sheetShown && ["provider", "offset", "sources", "translation"].contains(screen) }, set: { sheetShown = $0 })
    }

    @ViewBuilder
    private var sheet: some View {
        switch screen {
        case "provider":
            LyricsProviderSheet()
                .environment(session)
                .presentationDetents([.medium, .large])
        case "offset":
            LyricsOffsetSheet().presentationDetents([.medium])
        case "sources":
            LyricsSourcesSheet()
        default:
            TranslationLanguageSheet()
        }
    }

    @ViewBuilder
    private var panel: some View {
        switch screen {
        case "translated":
            LyricsPanelContent(lines: LyricsDemo.japanese, subLines: LyricsDemo.japaneseTranslated, looking: false, trackKey: "ja",
                               clock: clock, isPlaying: playing, translation: translation, onSeek: seek)
        case "plain":
            LyricsPanelContent(lines: LyricsDemo.plain, subLines: nil, looking: false, trackKey: "plain",
                               clock: clock, isPlaying: playing, translation: translation, onSeek: seek)
        case "loading":
            LyricsPanelContent(lines: [], subLines: nil, looking: true, trackKey: "loading",
                               clock: clock, isPlaying: playing, translation: translation, onSeek: seek)
        case "empty":
            LyricsPanelContent(lines: [], subLines: nil, looking: false, trackKey: "empty",
                               clock: clock, isPlaying: playing, translation: translation, onSeek: seek)
        default:
            LyricsPanelContent(lines: LyricsDemo.wordSynced, subLines: nil, looking: false, trackKey: "demo",
                               clock: clock, isPlaying: playing, translation: translation, onSeek: seek)
        }
    }

    private func seek(_ ms: Int) {
        position = ms
        startedAt = Date()
        clock.reset(positionMs: ms, isPlaying: playing)
    }
}
#endif
