import Foundation
import SwiftUI

// Ports ui/components/AppLanguageDialog.kt: the in-app language list.

/// One language the app ships: its `.lproj` identifier and its name in the current language.
struct AppLanguage: Hashable, Identifiable {
    /// The localization identifier (`LanguageBundle.supported`), e.g. "he", "zh-Hans".
    let code: String
    let name: () -> String
    var id: String { code }

    static func == (lhs: AppLanguage, rhs: AppLanguage) -> Bool { lhs.code == rhs.code }
    func hash(into hasher: inout Hasher) { hasher.combine(code) }

    /// Android's `SUPPORTED_LANGUAGES`, in its order. Android's "zh" is the Simplified Chinese
    /// catalog, `zh-Hans` on iOS.
    static let all: [AppLanguage] = [
        AppLanguage(code: "en", name: { L10n.english }),
        AppLanguage(code: "es", name: { L10n.spanish }),
        AppLanguage(code: "fr", name: { L10n.french }),
        AppLanguage(code: "de", name: { L10n.german }),
        AppLanguage(code: "pl", name: { L10n.polish }),
        AppLanguage(code: "pt", name: { L10n.portuguese }),
        AppLanguage(code: "id", name: { L10n.indonesian }),
        AppLanguage(code: "hi", name: { L10n.hindi }),
        AppLanguage(code: "ja", name: { L10n.japanese }),
        AppLanguage(code: "ru", name: { L10n.russian }),
        AppLanguage(code: "zh-Hans", name: { L10n.chinese }),
        AppLanguage(code: "he", name: { L10n.hebrew }),
        AppLanguage(code: "it", name: { L10n.italian }),
        AppLanguage(code: "tr", name: { L10n.turkish }),
        AppLanguage(code: "th", name: { L10n.thai }),
        AppLanguage(code: "vi", name: { L10n.vietnamese }),
    ]

    /// The language the UI is in now: the in-app choice, else the first of the system's preferred
    /// languages the app ships, else English (Android `languageDisplayNameRes`'s fallback).
    static func current(override: String? = LanguageBundle.override,
                        preferred: [String] = Locale.preferredLanguages) -> AppLanguage {
        if let override, let match = all.first(where: { $0.code == override }) { return match }
        for identifier in preferred {
            if let match = match(identifier) { return match }
        }
        return all[0]
    }

    /// The shipped language a BCP-47 identifier ("pt-BR", "zh-Hans-CN", "he-IL") falls under.
    static func match(_ identifier: String) -> AppLanguage? {
        let language = Locale.Language(identifier: identifier)
        guard let code = language.languageCode?.identifier else { return nil }
        if code == "zh" {
            // Only the Simplified catalog ships; Traditional Chinese falls through to English
            // rather than being shown the wrong script.
            let script = language.script?.identifier
            let region = language.region?.identifier
            let traditional = script == "Hant" || (script == nil && ["TW", "HK", "MO"].contains(region ?? ""))
            return traditional ? nil : all.first { $0.code == "zh-Hans" }
        }
        return all.first { $0.code == code }
    }
}

/// The picker: title and description, then one row per language with a tick on the current one.
/// Tapping a row applies it and closes, rather than waiting on a separate Done action.
///
/// Android drew this as a frosted centred alert; a list this long doesn't fit an iOS alert, so it
/// is a sheet, the closest native control.
struct AppLanguagePicker: View {
    let selected: AppLanguage
    let onSelect: (AppLanguage) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(AppLanguage.all) { language in
                        Button {
                            Haptics.shared.play(.select)
                            dismiss()
                            onSelect(language)
                        } label: {
                            HStack {
                                Text(language.name())
                                    .foregroundStyle(.primary)
                                Spacer()
                                if language == selected {
                                    Image(systemName: "checkmark")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(Color.accentColor)
                                        .accessibilityHidden(true)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(SettingsRowButtonStyle())
                        .accessibilityAddTraits(language == selected ? .isSelected : [])
                    }
                } header: {
                    Text(L10n.appLanguageDescription)
                        .textCase(nil)
                        .font(.footnote)
                }
            }
            .navigationTitle(L10n.appLanguage)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.cancel) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
