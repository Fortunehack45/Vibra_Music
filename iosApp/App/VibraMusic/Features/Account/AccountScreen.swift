import VibraMusicCore
import InnerTube
import SwiftUI

/// Account & integrations (ports ui/screens/AccountAndScrobblingScreen.kt and how MainActivity.kt
/// hosts it: the bar says "Account & scrobbling", the page leads with its own large
/// "Account & integrations", and the account avatar is not in the bar here).
///
/// Top to bottom, as on Android: the account card; signed in, "Listen as" (the profile selector)
/// with the Personal/Brand footnote, then Sign out; the Discord row under Rich presence; then
/// Scrobbling — ListenBrainz and Last.fm, each with a switch, their sub-switches while connected,
/// and Last.fm's timing sliders. The ListenBrainz token and Last.fm sign-in are frosted alerts.
struct AccountScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(AppRouter.self) private var router
    @State private var alert: AccountAlert?

    var body: some View {
        let identity = AccountIdentity(model.accounts)
        List {
            Section {
                AccountCard(signedIn: identity.signedIn, account: identity.account,
                            onSignIn: {
                                GoogleSignInModel.closeAccountPages(router)
                                router.present(.googleSignIn)
                            },
                            onClick: switchChannel)
                    .listRowInsets(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
            } header: {
                // The page's own large title (Android's displayLarge heading above the card).
                Text(L10n.accountIntegrations)
                    .font(AppTheme.Typeface.display)
                    // `Color(.label)`, not `.primary`: a List section header resolves `.primary` to its own dimmed level.
                    .foregroundStyle(Color(.label))
                    .textCase(nil)
                    .accessibilityAddTraits(.isHeader)
                    .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 14, trailing: 4))
            }

            if identity.signedIn {
                SettingsGroup(footer: L10n.accountProfilesHelp) {
                    SettingsRow(symbol: "person.2.circle", title: L10n.listenAs,
                                subtitle: identity.channelName ?? L10n.defaultYoutubeProfile,
                                action: switchChannel)
                }
                SettingsGroup {
                    SettingsCenteredActionRow(label: L10n.signOut) {
                        Task { await model.accounts.signOut() }
                    }
                }
            }

            SettingsGroup(header: L10n.richPresence, footer: L10n.richPresenceFooter) {
                SettingsRow(symbol: AppSymbol.discord, title: L10n.discord,
                            subtitle: AccountScrobbling.discordSubtitle(settings)) {
                    router.open(.discord)
                }
            }

            if AppSettings.scrobblingAvailable {
                scrobblingGroups
            } else {
                // Left in place rather than dropped (as on Android): a section that vanishes reads
                // as a feature that never existed, and this one is coming back.
                SettingsGroup(header: L10n.scrobbling, footer: L10n.scrobblingPausedFooter) {
                    SettingsRow(symbol: "cloud.fill", title: "ListenBrainz", subtitle: L10n.backInFutureVersion, enabled: false)
                    SettingsRow(symbol: AppSymbol.history, title: "Last.fm", subtitle: L10n.backInFutureVersion, enabled: false)
                }
            }
        }
        .settingsGroupList()
        .contentMargins(.bottom, 24, for: .scrollContent)
        .navigationTitle(L10n.accountScrobbling)
        .navigationBarTitleDisplayMode(.inline)
        .accountAlert($alert) { which in
            switch which {
            case .lastfmLogin:
                LastfmLoginAlert(onDismiss: closeAlert,
                                 signIn: AccountScrobbling.liveLastfmSignIn(settings: settings))
            default:
                ListenBrainzTokenAlert(onDismiss: closeAlert)
            }
        }
        #if DEBUG
        .onAppear {
            if let open = AccountDebugLaunch.takeAlert(.listenBrainzToken) ?? AccountDebugLaunch.takeAlert(.lastfmLogin) {
                present(open)
            }
        }
        #endif
    }

    @ViewBuilder
    private var scrobblingGroups: some View {
        @Bindable var settings = settings
        let lbConnected = AccountScrobbling.listenBrainzConnected(settings)
        let lastfmActive = AccountScrobbling.lastfmActive(settings)
        SettingsGroup(header: L10n.scrobbling, footer: L10n.scrobblingFooter) {
            AccountSwitchRow(symbol: "cloud.fill", title: "ListenBrainz",
                             subtitle: AccountScrobbling.listenBrainzSubtitle(settings),
                             isOn: Binding(get: { settings.listenBrainzEnabled }, set: { checked in
                                 switch AccountScrobbling.listenBrainzSwitch(to: checked, settings: settings) {
                                 case .openLogin: present(.listenBrainzToken)
                                 case .set(let value): settings.listenBrainzEnabled = value
                                 }
                             }),
                             onTap: { present(.listenBrainzToken) })
            if lbConnected {
                SettingsToggleRow(symbol: "waveform", title: L10n.scrobblePrimaryArtistOnly,
                                  subtitle: L10n.scrobblePrimaryArtistOnlySubtitle,
                                  isOn: $settings.listenBrainzPrimaryArtistOnly)
            }
            AccountSwitchRow(symbol: AppSymbol.history, title: "Last.fm",
                             subtitle: AccountScrobbling.lastfmSubtitle(settings),
                             isOn: Binding(get: { settings.lastfmEnabled }, set: { checked in
                                 switch AccountScrobbling.lastfmSwitch(to: checked, settings: settings) {
                                 case .openLogin: present(.lastfmLogin)
                                 case .set(let value): settings.lastfmEnabled = value
                                 }
                             }),
                             onTap: {
                                 if AccountScrobbling.tapLastfmRow(settings: settings) { present(.lastfmLogin) }
                             })
            if lastfmActive {
                SettingsToggleRow(symbol: "waveform", title: L10n.scrobbleTracks,
                                  subtitle: L10n.scrobbleTracksSubtitle, isOn: $settings.lastfmScrobbleEnabled)
                SettingsToggleRow(symbol: "waveform", title: L10n.scrobblePrimaryArtistOnly,
                                  subtitle: L10n.scrobblePrimaryArtistOnlySubtitle, isOn: $settings.lastfmPrimaryArtistOnly)
                SettingsToggleRow(symbol: "waveform", title: L10n.nowPlaying,
                                  subtitle: L10n.lastfmNowPlayingSubtitle, isOn: $settings.lastfmNowPlaying)
            }
        }

        if lastfmActive {
            SettingsGroup(header: L10n.scrobbleTiming) {
                SettingsSliderRow(symbol: "slider.horizontal.3", title: L10n.minSongDuration,
                                  subtitle: L10n.minSongDurationSubtitle,
                                  value: AccountScrobbling.secondsLabel(settings.scrobbleMinDuration),
                                  sliderValue: Binding(get: { Double(settings.scrobbleMinDuration) },
                                                       set: { settings.scrobbleMinDuration = Int($0.rounded()) }),
                                  range: AccountScrobbling.minDurationRange, step: AccountScrobbling.minDurationStep)
                SettingsSliderRow(symbol: "slider.horizontal.3", title: L10n.scrobbleDelay,
                                  subtitle: L10n.scrobbleDelaySubtitle,
                                  value: AccountScrobbling.percentLabel(settings.scrobbleDelayPercent),
                                  sliderValue: Binding(get: { Double(settings.scrobbleDelayPercent) },
                                                       set: { settings.scrobbleDelayPercent = Float($0) }),
                                  range: AccountScrobbling.delayPercentRange, step: AccountScrobbling.delayPercentStep)
                SettingsSliderRow(symbol: "slider.horizontal.3", title: L10n.maxDelay,
                                  subtitle: L10n.maxDelaySubtitle,
                                  value: AccountScrobbling.secondsLabel(settings.scrobbleDelaySeconds),
                                  sliderValue: Binding(get: { Double(settings.scrobbleDelaySeconds) },
                                                       set: { settings.scrobbleDelaySeconds = Int($0.rounded()) }),
                                  range: AccountScrobbling.maxDelayRange, step: AccountScrobbling.maxDelayStep)
            }
        }
    }

    /// "Listen as" and the card: the account/profile selector, with the channel list refreshed.
    private func switchChannel() {
        Task { await model.accounts.loadChannels() }
        router.present(.profileSwitcher)
    }

    private func present(_ which: AccountAlert) {
        setAccountAlert($alert, which)
    }

    private func closeAlert() {
        setAccountAlert($alert, nil)
    }
}

/// The account card at the top of the page (Android `AccountCard` in SettingsSheet.kt): the
/// account photo, its name and email. Signed out it reads "Not signed in / Tap to sign in with
/// Google" with a chevron and opens the sign-in.
struct AccountCard: View {
    let signedIn: Bool
    let account: Account?
    let onSignIn: () -> Void
    var onClick: (() -> Void)?

    /// The card's second line: the email, else what the card is for.
    static func subtitle(signedIn: Bool, account: Account?) -> String {
        account.map(\.email).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? (signedIn ? L10n.youtubeMusicAccount : L10n.tapToSignInGoogle)
    }

    var body: some View {
        let content = HStack(spacing: 14) {
            AccountAvatar(url: account?.thumbnailUrl, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(account?.name ?? (signedIn ? L10n.signedIn : L10n.notSignedIn))
                    .font(AppTheme.Typeface.titleLarge)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(Self.subtitle(signedIn: signedIn, account: account))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !signedIn { SettingsChevron() }
        }
        .contentShape(Rectangle())

        if !signedIn {
            Button(action: onSignIn) { content }
                .buttonStyle(SettingsRowButtonStyle())
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("account.card")
        } else if let onClick {
            Button(action: onClick) { content }
                .buttonStyle(SettingsRowButtonStyle())
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("account.card")
        } else {
            content.accessibilityElement(children: .combine)
        }
    }
}

/// A round account photo with a hairline ring, or a person glyph on a filled circle when there is
/// none (Android's `AsyncImage … thumbnailBorder(CircleShape)` / `Icons.Rounded.Person`).
struct AccountAvatar: View {
    let url: String?
    let size: CGFloat
    var placeholderSymbol = "person.fill"

    var body: some View {
        Group {
            if let url, let parsed = URL(string: url) {
                ArtworkImage(url: parsed, cornerRadius: 0, placeholderSymbol: placeholderSymbol)
            } else {
                ZStack {
                    Color(.systemGray4)
                    Image(systemName: placeholderSymbol)
                        .font(.system(size: size * 0.42))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

/// A row with a switch whose body does something else when tapped (Android `SettingsRow` with a
/// `Switch` trailing and its own `onClick`): ListenBrainz opens the token alert, Last.fm signs in or
/// out. The switch stays a separate control for VoiceOver.
struct AccountSwitchRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 0) {
                    SettingsIcon(symbol: symbol)
                    Spacer().frame(width: SettingsMetrics.iconGap)
                    SettingsRowText(title: title, subtitle: subtitle)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(SettingsRowButtonStyle())
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .tint(Color.accentColor)
                .sensoryFeedback(.selection, trigger: isOn)
        }
        .frame(minHeight: 28)
    }
}
