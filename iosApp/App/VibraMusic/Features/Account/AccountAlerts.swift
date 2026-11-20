import VibraMusicCore
import Integrations
import SwiftUI

// Ports the frosted alert shell of ui/components/AccountAlerts.kt (AlertScaffold, AlertRule,
// AlertAction, PillTextField, ChoiceRow) for the alerts the account screens open: the ListenBrainz
// token, the Last.fm sign-in, the Discord token, a free-text presence field and a single choice.
//
// Android drew UIAlertController by hand — a 270 pt frosted card, centred title and message, the
// fields, then full-width stacked actions between hairlines — because Material had nothing like it.
// SwiftUI's `.alert` can't keep itself open while a sign-in runs, show an error in place of its
// message, or carry a detail line and a tick per choice, so the same card is drawn here with the
// real material. It is shown in a transparent full-screen cover so its scrim covers the tab bar and
// the mini player, as Android hosted it at the activity's root for the same reason.

/// Android `ALERT_WIDTH`: the system alert's own width.
private let alertWidth: CGFloat = 270
/// Android `ACTION_HEIGHT`.
private let actionHeight: CGFloat = 44

/// Which account alert is open. One slot per screen, like MainActivity's `discordDialog`.
enum AccountAlert: String, Identifiable, Hashable {
    case listenBrainzToken
    case lastfmLogin
    case discordToken
    case discordStatus
    case discordActivityType
    case discordActivityName
    case discordButton1
    case discordButton2

    var id: String { rawValue }
}

extension View {
    /// Presents `content` as a frosted alert over everything while `alert` is non-nil.
    ///
    /// The cover itself appears without the sheet slide (`presentAccountAlert` / the card's own
    /// dismissal turn that off); the card fades and scales in on its own, as UIAlertController does.
    func accountAlert<Content: View>(_ alert: Binding<AccountAlert?>,
                                     @ViewBuilder content: @escaping (AccountAlert) -> Content) -> some View {
        fullScreenCover(item: alert) { which in
            content(which)
                .presentationBackground(.clear)
        }
    }
}

/// Changes an alert slot without the full-screen cover's slide.
@MainActor
func setAccountAlert(_ binding: Binding<AccountAlert?>, _ value: AccountAlert?) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) { binding.wrappedValue = value }
}

/// The scrim and the frosted card. Tapping the scrim dismisses (Android's `AlertScaffold`), unless
/// `dismissible` is false while work is in flight.
struct FrostedAlertCard<Content: View>: View {
    var dismissible = true
    let onDismiss: () -> Void
    @ViewBuilder var content: () -> Content

    @Environment(AppSettings.self) private var settings
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.opacity(shown ? 0.28 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { if dismissible { onDismiss() } }
                .accessibilityHidden(true)
            VStack(spacing: 0, content: content)
                .frame(width: alertWidth)
                .background {
                    if settings.reduceDynamicBlur {
                        Color(.secondarySystemBackground)
                    } else {
                        Rectangle().fill(.regularMaterial)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .scaleEffect(shown || reduceMotion ? 1 : 1.12)
                .opacity(shown ? 1 : 0)
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isModal)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.2)) { shown = true }
        }
        .accessibilityAction(.escape) { if dismissible { onDismiss() } }
    }
}

/// The centred title and the message (or an error in its place, in red) at the top of the card.
struct AlertHeader: View {
    let title: String
    var message: String?
    var isError = false

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(isError ? Color.red : Color.primary)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The hairline between the card's sections.
struct AlertRule: View {
    var body: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(height: 1 / UIScreen.main.scale)
            .accessibilityHidden(true)
    }
}

/// One full-width stacked action. The emphasised one is semibold, a destructive one red; disabled
/// actions grey out.
struct AlertAction: View {
    let label: String
    var emphasised = false
    var destructive = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(emphasised ? .body.weight(.semibold) : .body)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: actionHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(AlertActionStyle(destructive: destructive))
        .disabled(!enabled)
    }
}

private struct AlertActionStyle: ButtonStyle {
    let destructive: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? (destructive ? Color.red : Color.accentColor) : Color.accentColor.opacity(0.4))
            // iOS washes the whole row instead of drawing a ripple inside it.
            .background(Color.primary.opacity(configuration.isPressed ? 0.09 : 0))
    }
}

/// The rounded field inside the card (Android `PillTextField`).
struct AlertTextField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure = false
    var enabled = true
    var contentType: UITextContentType?
    var submitLabel: SubmitLabel = .done
    var onSubmit: () -> Void = {}

    var body: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textContentType(contentType)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(submitLabel)
        .onSubmit(onSubmit)
        .disabled(!enabled)
        .font(.subheadline)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// One option of a single-choice alert: its label, an optional detail line, and a tick on the
/// current one (Android `ChoiceRow`, ticked like LyricsSourcesDialog rather than with radios).
struct AlertChoiceRow: View {
    let label: String
    var detail: String?
    let checked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    // Explicit label colours: inside the action style `.primary` would resolve to
                    // the accent the actions are tinted with (Android: onSurface, and 55 % of it).
                    Text(label)
                        .font(.subheadline)
                        .foregroundStyle(Color(.label))
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(Color(.label).opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if checked {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(minHeight: actionHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(AlertActionStyle(destructive: false))
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

/// The padded block holding the header and fields (Android: 16 pt sides, 19 pt top and bottom).
struct AlertBody<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0, content: content)
            .padding(.horizontal, 16)
            .padding(.vertical, 19)
    }
}

// MARK: - The alerts

/// ListenBrainz token entry (Android `ListenBrainzTokenAlert`): Save stores the trimmed token.
struct ListenBrainzTokenAlert: View {
    let onDismiss: () -> Void
    @Environment(AppSettings.self) private var settings
    @State private var token = ""

    var body: some View {
        FrostedAlertCard(onDismiss: onDismiss) {
            AlertBody {
                AlertHeader(title: L10n.listenbrainzToken, message: L10n.listenbrainzTokenDescription)
                    .padding(.bottom, 14)
                AlertTextField(placeholder: L10n.apiToken, text: $token, onSubmit: save)
            }
            AlertRule()
            AlertAction(label: L10n.save, emphasised: true, action: save)
            AlertRule()
            AlertAction(label: L10n.cancel, action: onDismiss)
        }
        .onAppear { token = settings.listenBrainzToken }
    }

    private func save() {
        settings.listenBrainzToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        onDismiss()
    }
}

/// Last.fm username and password (Android `LastfmLoginAlert` and its host in MainActivity): the
/// sign-in runs with the card open, "Signing in…" on the button, and a failure replaces the message
/// in red.
struct LastfmLoginAlert: View {
    let onDismiss: () -> Void
    /// Exchanges the credentials for a session; injectable so tests don't reach Last.fm.
    var signIn: (String, String) async throws -> LastFMSessionInfo

    @Environment(AppSettings.self) private var settings
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var loading = false
    @FocusState private var focus: Field?

    private enum Field { case username, password }

    var body: some View {
        let canSubmit = !loading && !username.isBlankText && !password.isBlankText
        FrostedAlertCard(dismissible: !loading, onDismiss: onDismiss) {
            AlertBody {
                AlertHeader(title: L10n.lastfmLogin, message: error ?? L10n.lastfmLoginDescription, isError: error != nil)
                    .padding(.bottom, 14)
                AlertTextField(placeholder: L10n.username, text: $username, enabled: !loading,
                               contentType: .username, submitLabel: .next) { focus = .password }
                    .focused($focus, equals: .username)
                AlertTextField(placeholder: L10n.password, text: $password, isSecure: true, enabled: !loading,
                               contentType: .password) { if canSubmit { submit() } }
                    .focused($focus, equals: .password)
                    .padding(.top, 8)
            }
            AlertRule()
            AlertAction(label: loading ? L10n.signingIn : L10n.signIn, emphasised: true, enabled: canSubmit, action: submit)
            AlertRule()
            AlertAction(label: L10n.cancel, enabled: !loading, action: onDismiss)
        }
    }

    private func submit() {
        loading = true
        error = nil
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = password
        Task {
            do {
                let session = try await signIn(name, secret)
                AccountScrobbling.didSignInToLastfm(session, settings: settings)
                loading = false
                onDismiss()
            } catch {
                self.error = AccountScrobbling.loginErrorMessage(error)
                loading = false
            }
        }
    }
}

/// Manual Discord token entry (Android `DiscordTokenAlert` hosted by `DiscordDialogHost`): the
/// token is verified with Discord before it is saved, because one that doesn't work fails silently
/// later — the presence simply never appears.
struct DiscordTokenAlert: View {
    let onDismiss: () -> Void
    var fetchUser: (String) async -> DiscordUserInfo?

    @Environment(AppSettings.self) private var settings
    @State private var token = ""
    @State private var error: String?
    @State private var checking = false

    var body: some View {
        let canSave = !checking && !token.isBlankText
        FrostedAlertCard(dismissible: !checking, onDismiss: onDismiss) {
            AlertBody {
                AlertHeader(title: L10n.discordToken, message: error ?? L10n.discordTokenDescription, isError: error != nil)
                    .padding(.bottom, 14)
                AlertTextField(placeholder: L10n.token, text: $token, isSecure: true, enabled: !checking) {
                    if canSave { save() }
                }
            }
            AlertRule()
            AlertAction(label: checking ? L10n.checking : L10n.save, emphasised: true, enabled: canSave, action: save)
            AlertRule()
            AlertAction(label: L10n.cancel, enabled: !checking, action: onDismiss)
        }
    }

    private func save() {
        checking = true
        error = nil
        Task {
            if await DiscordTokenCheck.verifyAndSave(token, settings: settings, fetchUser: fetchUser) {
                onDismiss()
            } else {
                error = L10n.discordTokenRejected
                checking = false
            }
        }
    }
}

/// A pasted Discord token, checked with Discord before anything is stored.
@MainActor
enum DiscordTokenCheck {
    nonisolated static let liveFetchUser: @Sendable (String) async -> DiscordUserInfo? = { token in
        await DiscordAccountService.fetchUserInfo(session: VibraMusicHTTP.session, token: token)
    }

    /// Stores the trimmed token and who it belongs to if Discord accepts it; returns whether it did.
    static func verifyAndSave(_ token: String, settings: AppSettings,
                              fetchUser: (String) async -> DiscordUserInfo?) async -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let info = await fetchUser(trimmed) else { return false }
        settings.setDiscordAccount(username: info.username, name: info.name, avatar: info.avatar)
        settings.discordToken = trimmed
        return true
    }
}

/// One free-text presence field (Android `TextValueAlert`): an activity name or a button label.
struct TextValueAlert: View {
    let title: String
    let message: String
    let placeholder: String
    let initial: String
    let onSave: (String) -> Void
    let onDismiss: () -> Void

    @State private var value = ""

    var body: some View {
        FrostedAlertCard(onDismiss: onDismiss) {
            AlertBody {
                AlertHeader(title: title, message: message)
                    .padding(.bottom, 14)
                AlertTextField(placeholder: placeholder, text: $value) { save() }
            }
            AlertRule()
            AlertAction(label: L10n.save, emphasised: true, action: save)
            AlertRule()
            AlertAction(label: L10n.cancel, action: onDismiss)
        }
        .onAppear { value = initial }
    }

    private func save() {
        onSave(value.trimmingCharacters(in: .whitespacesAndNewlines))
        onDismiss()
    }
}

/// A single choice that commits on tap (Android `ChoiceAlert`); Cancel is the only action.
struct ChoiceAlert<Option: Hashable>: View {
    let title: String
    var message: String?
    let options: [Option]
    let selected: Option
    let label: (Option) -> String
    var detail: (Option) -> String? = { _ in nil }
    let onSelect: (Option) -> Void
    let onDismiss: () -> Void

    var body: some View {
        FrostedAlertCard(onDismiss: onDismiss) {
            AlertBody {
                AlertHeader(title: title, message: message)
            }
            ForEach(options, id: \.self) { option in
                AlertRule()
                AlertChoiceRow(label: label(option), detail: detail(option), checked: option == selected) {
                    Haptics.shared.play(.tick)
                    onSelect(option)
                    onDismiss()
                }
            }
            AlertRule()
            AlertAction(label: L10n.cancel, action: onDismiss)
        }
    }
}

extension String {
    /// Empty or only whitespace (Kotlin's `isBlank`).
    fileprivate var isBlankText: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
