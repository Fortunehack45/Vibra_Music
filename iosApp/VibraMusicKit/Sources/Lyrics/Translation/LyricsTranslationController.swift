import Foundation
import Observation

/// The translation and romanization state machine behind the lyric panel: which language,
/// what has been asked for, what came back, and which version is on screen (Android:
/// `rememberLyricsTranslation` in `PlayerLyrics.kt`). Reset per track, per target language
/// and per lyric sheet — call `configure` whenever any of those change.
///
/// The original lyrics are never overwritten. Tapping the same button again returns to them
/// immediately, and a repeated toggle after success makes no request.
@MainActor
@Observable
public final class LyricsTranslationController {
    public enum State: Hashable, Sendable {
        case idle
        case loading
        case ready([LyricLine])
        /// Translation: already in the target language. Romanization: already Latin.
        case sameLanguage
    }

    public enum DisplayMode: String, Hashable, Sendable {
        case original
        case romanized
        case translated
    }

    /// Something the panel should tell the listener (Android showed these as toasts).
    public struct Notice: Hashable, Sendable, Identifiable {
        public enum Kind: Hashable, Sendable {
            /// "Lyrics are already in <language>".
            case alreadyInLanguage(languageName: String)
            case translationUnavailable
            case alreadyRomanized
            case romanizationUnavailable
        }

        public let id: Int
        public let kind: Kind
    }

    public private(set) var translationState: State = .idle
    public private(set) var romanizationState: State = .idle
    public private(set) var displayMode: DisplayMode = .original
    /// Bumped on every switch between versions — the trigger for the swap animation.
    public private(set) var transition = 0
    /// The latest notice, with a fresh id each time so the same message can re-appear.
    public private(set) var notice: Notice?
    /// The resolved target language code and its display name.
    public private(set) var targetLanguage = "en"
    public private(set) var targetLanguageName = "English"

    private let translator: LyricsTranslator
    private var trackId = ""
    private var lines: [LyricLine]?
    private var noticeCounter = 0
    private var translationTask: Task<Void, Never>?
    private var romanizationTask: Task<Void, Never>?
    private var configuration = 0

    public init(translator: LyricsTranslator = .shared) {
        self.translator = translator
    }

    /// Point the controller at the current track, lyric sheet and language. Any change resets
    /// both versions to idle and the display to the original, cancelling pending requests.
    ///
    /// - Parameters:
    ///   - preferredLanguage: `LyricsPreferences.translationLanguage` (blank follows the app).
    ///   - appLanguageTag: the language Vibra Music is shown in; see `LyricsTranslationTarget`.
    public func configure(
        trackId: String,
        lines: [LyricLine]?,
        preferredLanguage: String,
        appLanguageTag: String = LyricsTranslationTarget.appLanguageTag
    ) {
        let target = LyricsTranslationTarget.resolve(preferred: preferredLanguage, appLanguageTag: appLanguageTag)
        let name = TranslationLanguage.displayName(for: target, in: Locale(identifier: appLanguageTag))
        if trackId == self.trackId && lines == self.lines && target == targetLanguage {
            targetLanguageName = name
            return
        }
        let trackChanged = trackId != self.trackId
        self.trackId = trackId
        self.lines = lines
        targetLanguage = target
        targetLanguageName = name
        configuration += 1
        translationTask?.cancel()
        romanizationTask?.cancel()
        translationState = .idle
        romanizationState = .idle
        displayMode = .original
        if trackChanged { transition = 0 }
    }

    public var showingTranslation: Bool { displayMode == .translated }
    public var showingRomanization: Bool { displayMode == .romanized }

    /// What the one-line strip over the scrubber shows: the chosen version, or the original.
    public var displayedLines: [LyricLine] {
        switch displayMode {
        case .translated: if case .ready(let lines) = translationState { return lines }
        case .romanized: if case .ready(let lines) = romanizationState { return lines }
        case .original: break
        }
        return lines ?? []
    }

    /// What the panel draws in small type under each original line, Apple Music style. The
    /// panel itself always keeps the original words; one mode at a time by construction.
    public var subLines: [LyricLine]? {
        switch displayMode {
        case .translated: if case .ready(let lines) = translationState { return lines }
        case .romanized: if case .ready(let lines) = romanizationState { return lines }
        case .original: break
        }
        return nil
    }

    /// The translate button.
    public func toggleTranslation() {
        switch translationState {
        case .ready:
            displayMode = showingTranslation ? .original : .translated
            transition += 1
        case .loading:
            break
        case .sameLanguage:
            post(.alreadyInLanguage(languageName: targetLanguageName))
        case .idle:
            guard let source = lines, !source.isEmpty else { return }
            translationState = .loading
            romanizationTask?.cancel()
            if romanizationState == .loading { romanizationState = .idle }
            translationTask?.cancel()
            let configuration = configuration
            let (trackId, target, translator) = (trackId, targetLanguage, translator)
            translationTask = Task { [weak self] in
                let result = await translator.translate(trackId: trackId, lines: source, targetLanguage: target)
                guard let self, self.configuration == configuration, !Task.isCancelled else { return }
                switch result {
                case .translated(let lines, _, _):
                    self.translationState = .ready(lines)
                    self.displayMode = .translated
                    self.transition += 1
                case .sameLanguage:
                    self.translationState = .sameLanguage
                    self.post(.alreadyInLanguage(languageName: self.targetLanguageName))
                case .unavailable:
                    self.translationState = .idle
                    self.post(.translationUnavailable)
                }
            }
        }
    }

    /// The romanize button.
    public func toggleRomanization() {
        switch romanizationState {
        case .ready:
            displayMode = showingRomanization ? .original : .romanized
            transition += 1
        case .loading:
            break
        case .sameLanguage:
            post(.alreadyRomanized)
        case .idle:
            guard let source = lines, !source.isEmpty else { return }
            romanizationState = .loading
            translationTask?.cancel()
            if translationState == .loading { translationState = .idle }
            romanizationTask?.cancel()
            let configuration = configuration
            let (trackId, target, translator) = (trackId, targetLanguage, translator)
            romanizationTask = Task { [weak self] in
                let result = await translator.romanize(trackId: trackId, lines: source, targetLanguage: target)
                guard let self, self.configuration == configuration, !Task.isCancelled else { return }
                switch result {
                case .romanized(let lines, _, _):
                    self.romanizationState = .ready(lines)
                    self.displayMode = .romanized
                    self.transition += 1
                case .alreadyRomanized:
                    self.romanizationState = .sameLanguage
                    self.post(.alreadyRomanized)
                case .unavailable:
                    self.romanizationState = .idle
                    self.post(.romanizationUnavailable)
                }
            }
        }
    }

    /// Waits for whichever request is in flight; for tests and previews.
    func settle() async {
        await translationTask?.value
        await romanizationTask?.value
    }

    private func post(_ kind: Notice.Kind) {
        noticeCounter += 1
        notice = Notice(id: noticeCounter, kind: kind)
    }
}
