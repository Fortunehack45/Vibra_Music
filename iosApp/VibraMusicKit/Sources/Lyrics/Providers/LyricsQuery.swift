import Foundation

/// Java's `\s`: ASCII whitespace only (ICU's is Unicode-wide).
let javaSpace = #"[ \t\n\x0B\f\r]"#

extension String {
    /// A YouTube title, as a lyrics database would have indexed it.
    ///
    /// Every source here but SimpMusic is asked for a name, and the name this app has is
    /// YouTube's, which is not the name anyone catalogued. "Title (feat. Guest)" is filed
    /// by Apple, LRCLIB and everyone else as "Title", and asked for verbatim it misses all
    /// of them.
    ///
    /// Only credits and packaging are taken off: who else is on the record, and how the
    /// upload was labelled. Anything that names a *different recording* stays — "(Remix)",
    /// "(Acoustic)", "(Live)", "(Remastered 2011)", "(Sped Up)". Stripping those turns a
    /// search for one recording into a search for another, and the lyrics that come back are
    /// confidently wrong rather than merely missing. A miss is recoverable; the wrong words
    /// scrolling in time with the right song is not.
    var forLyricsSearch: String {
        var name = self
        for pattern in LyricsQueryPatterns.credits { name = pattern.replacing(in: name, with: " ") }
        let cleaned = LyricsQueryPatterns.whitespace.replacing(in: name, with: " ")
            .kTrimmed
            .kTrimmingEnd([",", "-", "–", "—"])
            .kTrimmed
        // A title that was *only* packaging is no title at all; better to ask with what we
        // were given than with nothing.
        return cleaned.kIsBlank ? kTrimmed : cleaned
    }

    /// Trims " - Topic" off an auto-generated channel name. YouTube's own artist channels for
    /// licensed music are named this way, and it reaches the player as the artist on
    /// anything played from one.
    var artistForLyricsSearch: String {
        let trimmed = kRemovingSuffix(" - Topic").kTrimmed
        return trimmed.kIsBlank ? kTrimmed : trimmed
    }
}

private enum LyricsQueryPatterns {
    static let whitespace = LyricsRegex(javaSpace + "+")

    static let credits = [
        // Bracketed credits: (feat. X), [ft. X], (with X).
        LyricsRegex(
            javaSpace + #"*[(\[]"# + javaSpace + #"*(feat|ft|featuring|with)\b[^)\]]*[)\]]"#,
            caseInsensitive: true
        ),
        // The same, unbracketed and running to the end of the title.
        LyricsRegex(javaSpace + #"+(feat|ft|featuring)\.?"# + javaSpace + "+.*$", caseInsensitive: true),
        // How the upload was labelled, not what was recorded.
        LyricsRegex(
            javaSpace + #"*[(\[]"# + javaSpace + "*(official" + javaSpace + "*)?(music" + javaSpace + "*)?"
                + "(video|audio|visuali[sz]er|lyrics?" + javaSpace + "*video|lyrics?|m/?v|hd|hq|4k|full"
                + javaSpace + "*song)" + javaSpace + #"*[)\]]"#,
            caseInsensitive: true
        ),
        LyricsRegex(javaSpace + #"*[(\[]"# + javaSpace + "*official" + javaSpace + #"*[)\]]"#, caseInsensitive: true),
    ]
}
