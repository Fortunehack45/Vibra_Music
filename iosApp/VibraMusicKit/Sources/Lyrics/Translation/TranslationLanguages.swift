import Foundation

/// One language the translate button can translate lyrics *into*.
///
/// `code` is what goes on the wire as the endpoint's `tl` parameter, so it is kept exactly as
/// Google spells it — including the handful that are not bare ISO-639-1: `zh-CN` and `zh-TW`
/// are different scripts of the same language and collapsing either to `zh` silently gives
/// you Simplified, and `mni-Mtei` names the script it is actually written in.
///
/// `fallbackName` is only used when the platform has no display name for the code. Where the
/// platform *does* know the language its own name wins, because that one is localised into
/// whatever the app is set to and this one is not.
public struct TranslationLanguage: Hashable, Sendable, Identifiable {
    public let code: String
    public let fallbackName: String

    public var id: String { code }

    public init(code: String, fallbackName: String) {
        self.code = code
        self.fallbackName = fallbackName
    }

    /// Every language Google Translate offers, in the order its own picker lists them:
    /// alphabetical by English name.
    public static let all: [TranslationLanguage] = [
        ("af", "Afrikaans"), ("sq", "Albanian"), ("am", "Amharic"), ("ar", "Arabic"), ("hy", "Armenian"),
        ("as", "Assamese"), ("ay", "Aymara"), ("az", "Azerbaijani"), ("bm", "Bambara"), ("eu", "Basque"),
        ("be", "Belarusian"), ("bn", "Bengali"), ("bho", "Bhojpuri"), ("bs", "Bosnian"), ("bg", "Bulgarian"),
        ("ca", "Catalan"), ("ceb", "Cebuano"), ("ny", "Chichewa"), ("zh-CN", "Chinese (Simplified)"),
        ("zh-TW", "Chinese (Traditional)"), ("co", "Corsican"), ("hr", "Croatian"), ("cs", "Czech"),
        ("da", "Danish"), ("dv", "Dhivehi"), ("doi", "Dogri"), ("nl", "Dutch"), ("en", "English"),
        ("eo", "Esperanto"), ("et", "Estonian"), ("ee", "Ewe"), ("tl", "Filipino"), ("fi", "Finnish"),
        ("fr", "French"), ("fy", "Frisian"), ("gl", "Galician"), ("ka", "Georgian"), ("de", "German"),
        ("el", "Greek"), ("gn", "Guarani"), ("gu", "Gujarati"), ("ht", "Haitian Creole"), ("ha", "Hausa"),
        ("haw", "Hawaiian"), ("iw", "Hebrew"), ("hi", "Hindi"), ("hmn", "Hmong"), ("hu", "Hungarian"),
        ("is", "Icelandic"), ("ig", "Igbo"), ("ilo", "Ilocano"), ("id", "Indonesian"), ("ga", "Irish"),
        ("it", "Italian"), ("ja", "Japanese"), ("jw", "Javanese"), ("kn", "Kannada"), ("kk", "Kazakh"),
        ("km", "Khmer"), ("rw", "Kinyarwanda"), ("gom", "Konkani"), ("ko", "Korean"), ("kri", "Krio"),
        ("ku", "Kurdish (Kurmanji)"), ("ckb", "Kurdish (Sorani)"), ("ky", "Kyrgyz"), ("lo", "Lao"),
        ("la", "Latin"), ("lv", "Latvian"), ("ln", "Lingala"), ("lt", "Lithuanian"), ("lg", "Luganda"),
        ("lb", "Luxembourgish"), ("mk", "Macedonian"), ("mai", "Maithili"), ("mg", "Malagasy"), ("ms", "Malay"),
        ("ml", "Malayalam"), ("mt", "Maltese"), ("mi", "Maori"), ("mr", "Marathi"),
        ("mni-Mtei", "Meiteilon (Manipuri)"), ("lus", "Mizo"), ("mn", "Mongolian"), ("my", "Myanmar (Burmese)"),
        ("ne", "Nepali"), ("no", "Norwegian"), ("or", "Odia (Oriya)"), ("om", "Oromo"), ("ps", "Pashto"),
        ("fa", "Persian"), ("pl", "Polish"), ("pt", "Portuguese"), ("pa", "Punjabi"), ("qu", "Quechua"),
        ("ro", "Romanian"), ("ru", "Russian"), ("sm", "Samoan"), ("sa", "Sanskrit"), ("gd", "Scots Gaelic"),
        ("nso", "Sepedi"), ("sr", "Serbian"), ("st", "Sesotho"), ("sn", "Shona"), ("sd", "Sindhi"),
        ("si", "Sinhala"), ("sk", "Slovak"), ("sl", "Slovenian"), ("so", "Somali"), ("es", "Spanish"),
        ("su", "Sundanese"), ("sw", "Swahili"), ("sv", "Swedish"), ("tg", "Tajik"), ("ta", "Tamil"),
        ("tt", "Tatar"), ("te", "Telugu"), ("th", "Thai"), ("ti", "Tigrinya"), ("ts", "Tsonga"),
        ("tr", "Turkish"), ("tk", "Turkmen"), ("ak", "Twi"), ("uk", "Ukrainian"), ("ur", "Urdu"),
        ("ug", "Uyghur"), ("uz", "Uzbek"), ("vi", "Vietnamese"), ("cy", "Welsh"), ("xh", "Xhosa"),
        ("yi", "Yiddish"), ("yo", "Yoruba"), ("zu", "Zulu"),
    ].map { TranslationLanguage(code: $0.0, fallbackName: $0.1) }

    private static let byCode = Dictionary(uniqueKeysWithValues: all.map { ($0.code.lowercased(), $0) })

    /// What to call `code` on screen, written in `locale`.
    ///
    /// Asks the platform first so the name arrives in the reader's own language —
    /// "Japanese" to an English reader, "Japonés" to a Spanish one — and falls back to the
    /// English name from the table for codes the platform does not carry. A code that is in
    /// neither comes back as itself rather than blank: wrong but legible.
    public static func displayName(for code: String, in locale: Locale) -> String {
        let entry = byCode[code.lowercased()]
        // A subtag is the whole point of the codes that carry one, and the platform renders
        // it as territory: zh-CN would come back "Chinese (China)", naming the country
        // rather than the script. For those the curated name is the accurate one.
        let platform = code.contains("-") ? nil : locale.localizedString(forLanguageCode: code)
        let known = platform.map { !$0.kIsBlank && !$0.kEqualsIgnoreCase(code) } ?? false
        let name = known ? platform! : (entry?.fallbackName ?? code)
        guard let first = name.first, first.isLowercase else { return name }
        return String(first).capitalized(with: locale) + name.dropFirst()
    }
}

/// Which language the translate button translates into.
public enum LyricsTranslationTarget {
    /// Settings wins where it has been set; blank means follow the app language. Only the
    /// app-language path is reduced to a base language — a code chosen in Settings is already
    /// exactly what the endpoint wants, and narrowing it would throw away the script half of
    /// zh-TW.
    public static func resolve(preferred: String, appLanguageTag: String) -> String {
        if !preferred.kIsBlank { return preferred }
        let base = Locale(identifier: appLanguageTag).language.languageCode?.identifier ?? ""
        return base.isEmpty ? "en" : base
    }

    /// The language Vibra Music itself is showing: the first localization the bundle chose,
    /// else the user's preferred language.
    public static var appLanguageTag: String {
        Bundle.main.preferredLocalizations.first ?? Locale.preferredLanguages.first ?? "en"
    }
}
