import Lyrics

/// The words the player shows about the lyrics (ports the `status` line and the toasts of
/// `rememberLyricsTranslation` in ui/player/PlayerLyrics.kt).
enum LyricsStatus {
    /// The line over the scrubber while the lyrics are open: what the translation is doing, else
    /// where the lyrics came from. Worked out in one place so the portrait and landscape players
    /// can't disagree about it.
    ///
    /// - Parameters:
    ///   - source: where the lines came from; nil for lyrics read out of a downloaded file.
    ///   - unavailable: the lookup came back empty.
    ///   - hasLyrics: there are lines to show.
    ///   - loadingText: what to say while the lookup is still out.
    @MainActor
    static func text(
        translation: LyricsTranslationController,
        source: LyricsSource?,
        unavailable: Bool,
        hasLyrics: Bool,
        loadingText: String
    ) -> String {
        let language = translation.targetLanguageName
        if translation.translationState == .loading { return L10n.translatingLyricsTo(language) }
        if translation.romanizationState == .loading { return L10n.romanizingLyrics }
        if translation.showingTranslation { return L10n.lyricsTranslatedTo(language) }
        if translation.showingRomanization { return L10n.lyricsRomanized }
        if translation.translationState == .sameLanguage { return L10n.lyricsAlreadyInLanguage(language) }
        if translation.romanizationState == .sameLanguage { return L10n.lyricsAlreadyRomanized }
        if let source { return L10n.lyricsBy(source.label) }
        if unavailable { return L10n.noLyricsFound }
        if !hasLyrics { return loadingText }
        return L10n.lyricsSavedWithDownload
    }

    /// What a translation notice says (Android showed these as toasts; here they go through the
    /// player's notice).
    static func message(for kind: LyricsTranslationController.Notice.Kind) -> String {
        switch kind {
        case .alreadyInLanguage(let name): return L10n.lyricsAlreadyInLanguage(name)
        case .translationUnavailable: return L10n.lyricsTranslationUnavailable
        case .alreadyRomanized: return L10n.lyricsAlreadyRomanized
        case .romanizationUnavailable: return L10n.lyricsRomanizationUnavailable
        }
    }
}
