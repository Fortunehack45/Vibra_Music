import VibraMusicCore
import Lyrics
import SwiftUI

/// The picker's rows and filter (TranslationLanguageDialog.kt), apart from the view.
struct TranslationLanguageChoices {
    struct Row: Identifiable, Equatable {
        let language: TranslationLanguage
        /// The name in the app's language.
        let name: String

        var id: String { language.code }

        /// The English name under the localised one — reading the app in German, "Japanisch" is
        /// the row you want but "Japanese" is what you were going to type. The code when the two
        /// agree.
        var detail: String {
            language.fallbackName.compare(name, options: .caseInsensitive) == .orderedSame ? language.code : language.fallbackName
        }
    }

    /// Names are resolved once per locale: the list is long and the filter reads every one of
    /// them on every keystroke.
    let rows: [Row]

    init(locale: Locale) {
        rows = TranslationLanguage.all.map { Row(language: $0, name: TranslationLanguage.displayName(for: $0.code, in: locale)) }
    }

    /// Matched against the English name as well as the localised one, so someone reading the app
    /// in Hindi can still type "Japanese".
    func filtered(by query: String) -> [Row] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return rows }
        return rows.filter {
            $0.name.range(of: needle, options: .caseInsensitive) != nil
                || $0.language.fallbackName.range(of: needle, options: .caseInsensitive) != nil
        }
    }

    /// The "app default" row isn't a language, so it has no name to match: shown only with an
    /// empty field.
    static func showsAppDefault(query: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isSelected(_ code: String, stored: String) -> Bool {
        stored.compare(code, options: .caseInsensitive) == .orderedSame
    }
}

/// Which language the lyrics translate button translates into (ports
/// ui/components/TranslationLanguageDialog.kt): the app's own language by default, or one of ~130.
/// Picking a row applies it and closes; there's one active language and nothing to confirm.
///
/// Android's is the app's frosted alert with a filter field and a scrolling list; on iOS it's a
/// sheet laid out the same way — title and explanation, the filter, the list, Done pinned under it.
struct TranslationLanguageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @State private var query = ""
    @State private var choices = TranslationLanguageChoices(locale: LanguageBundle.locale)
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text(L10n.translationLanguage)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(L10n.translationLanguageDescription)
                    .font(.footnote)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.top, 22)
            .padding(.bottom, 19)

            Divider()
            HStack(spacing: 8) {
                Image(systemName: AppSymbol.search)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(L10n.searchLanguages, text: $query)
                    .font(.subheadline)
                    .focused($searchFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .accessibilityIdentifier("translationLanguage.search")
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            Divider()

            let shown = choices.filtered(by: query)
            List {
                if TranslationLanguageChoices.showsAppDefault(query: query) {
                    choiceRow(
                        label: L10n.translationLanguageAppDefault,
                        detail: L10n.translationLanguageSubtitle,
                        selected: settings.translationLanguage.trimmingCharacters(in: .whitespaces).isEmpty,
                        id: "appDefault"
                    ) { choose("") }
                }
                ForEach(shown) { row in
                    choiceRow(
                        label: row.name,
                        detail: row.detail,
                        selected: TranslationLanguageChoices.isSelected(row.language.code, stored: settings.translationLanguage),
                        id: row.language.code
                    ) { choose(row.language.code) }
                }
                if shown.isEmpty {
                    Text(L10n.noLanguagesMatch)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 44)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)

            // Pinned under the list: on a list this long the way out has to stay put.
            Divider()
            AlertActionRow(label: L10n.done, emphasised: true) { dismiss() }
                .accessibilityIdentifier("translationLanguage.done")
        }
        .presentationDetents([.large])
        .presentationBackground(.regularMaterial)
        .onChange(of: LanguageBundle.locale.identifier) { _, _ in
            choices = TranslationLanguageChoices(locale: LanguageBundle.locale)
        }
        // A container: without this the identifier lands on every child and hides theirs.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lyrics.translationLanguageSheet")
    }

    private func choose(_ code: String) {
        Haptics.shared.play(.select)
        settings.translationLanguage = code
        dismiss()
    }

    private func choiceRow(label: String, detail: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if selected {
                    Image(systemName: AppSymbol.check)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 9)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("translationLanguage.\(id)")
    }
}
