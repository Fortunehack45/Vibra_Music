import VibraMusicCore
import Integrations
import SwiftUI

/// Discord Rich Presence (ports ui/screens/DiscordScreen.kt and DiscordDialogHost): the account it
/// posts as, what the card says, and a live preview of it.
///
/// The preview is the point of the screen. Every field here changes something about a card the
/// listener can't see from inside the app, so it draws the card as Discord will, from the track
/// actually playing, and updates as they change things.
///
/// Top to bottom, as on Android: the large "Discord" heading; the account card (tap to sign in when
/// not connected); "Enter a token instead" while not connected; the one-off warning about what a
/// token is; Rich presence (the master switch, lead with the song, audio quality, customise the
/// card); while customising, Presence (status, activity, name) and Buttons; the Preview; and
/// Disconnect while connected.
struct DiscordScreen: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerController.self) private var player
    @State private var alert: AccountAlert?
    @State private var showLogin = false

    /// Looks the connected account up; injectable so tests don't reach Discord.
    private let fetchUser: (String) async -> DiscordUserInfo?

    init(fetchUser: @escaping (String) async -> DiscordUserInfo? = DiscordTokenCheck.liveFetchUser) {
        self.fetchUser = fetchUser
    }

    var body: some View {
        @Bindable var settings = settings
        let connected = DiscordCard.connected(settings)
        let optionsEnabled = DiscordCard.presenceOptionsEnabled(settings)
        List {
            Section {
                DiscordAccountCard(onConnect: { showLogin = true })
                    .listRowInsets(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
            } header: {
                // The page's own large title (Android's displayLarge heading above the card).
                Text(L10n.discord)
                    .font(AppTheme.Typeface.display)
                    // `Color(.label)`, not `.primary`: a List section header resolves `.primary` to its own dimmed level.
                    .foregroundStyle(Color(.label))
                    .textCase(nil)
                    .accessibilityAddTraits(.isHeader)
                    .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 14, trailing: 4))
            }

            if !connected {
                SettingsGroup(footer: L10n.discordSignInFooter) {
                    SettingsRow(symbol: "key.fill", title: L10n.enterTokenInstead,
                                subtitle: L10n.enterTokenInsteadSubtitle) { present(.discordToken) }
                }
            }

            if !settings.discordInfoDismissed {
                DiscordNoticeCard(text: L10n.discordTokenWarning) {
                    withAnimation { settings.discordInfoDismissed = true }
                }
            }

            SettingsGroup(header: L10n.richPresence, footer: L10n.discordPresenceFooter) {
                SettingsToggleRow(symbol: AppSymbol.discord, title: L10n.showWhatPlaying,
                                  subtitle: connected ? nil : L10n.connectAccountFirst,
                                  enabled: connected,
                                  isOn: Binding(get: { settings.discordRpcEnabled && connected },
                                                set: { settings.discordRpcEnabled = $0 }))
                SettingsToggleRow(symbol: "tag", title: L10n.leadWithSong, subtitle: L10n.leadWithSongSubtitle,
                                  enabled: optionsEnabled, isOn: $settings.discordUseDetails)
                SettingsToggleRow(symbol: "waveform", title: L10n.discordShowAudioQuality,
                                  subtitle: L10n.discordShowAudioQualitySubtitle,
                                  enabled: optionsEnabled, isOn: $settings.discordShowAudioQuality)
                SettingsToggleRow(symbol: "slider.horizontal.3", title: L10n.customizeCard,
                                  subtitle: L10n.customizeCardSubtitle,
                                  enabled: optionsEnabled, isOn: $settings.discordAdvancedMode)
            }

            if DiscordCard.showsCustomization(settings) {
                SettingsGroup(header: L10n.presence) {
                    SettingsRow(symbol: "record.circle", title: L10n.status,
                                value: DiscordPresenceStatus(stored: settings.discordStatus).label) { present(.discordStatus) }
                    SettingsRow(symbol: "slider.horizontal.3", title: L10n.activity,
                                value: DiscordActivityKind(stored: settings.discordActivityType).label) { present(.discordActivityType) }
                    SettingsRow(symbol: "tag", title: L10n.name,
                                subtitle: settings.discordActivityName.isEmpty ? DiscordCard.appName : settings.discordActivityName) {
                        present(.discordActivityName)
                    }
                }
                SettingsGroup(header: L10n.buttons, footer: L10n.discordButtonsFooter) {
                    AccountSwitchRow(symbol: "button.horizontal", title: L10n.firstButton,
                                     subtitle: settings.discordButton1Text.isEmpty ? DiscordPresenceClient.defaultButton1 : settings.discordButton1Text,
                                     isOn: $settings.discordButton1Visible) { present(.discordButton1) }
                    AccountSwitchRow(symbol: "button.horizontal", title: L10n.secondButton,
                                     subtitle: settings.discordButton2Text.isEmpty ? DiscordPresenceClient.defaultButton2 : settings.discordButton2Text,
                                     isOn: $settings.discordButton2Visible) { present(.discordButton2) }
                }
            }

            SettingsGroup(header: L10n.preview, footer: player.currentSong == nil ? L10n.playToPreview : nil) {
                RichPresencePreview()
                    .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
            }

            if connected {
                SettingsGroup {
                    SettingsCenteredActionRow(label: L10n.disconnect) { settings.clearDiscordAccount() }
                }
            }
        }
        .settingsGroupList()
        .contentMargins(.bottom, 24, for: .scrollContent)
        .navigationTitle(L10n.discord)
        .navigationBarTitleDisplayMode(.inline)
        // Refreshes the cached profile whenever the connected account changes. A failure leaves
        // the cache standing: the usual reason for one is being offline, and blanking the name every
        // time the phone loses signal would read as having been signed out.
        .task(id: settings.discordToken) {
            let token = settings.discordToken
            if token.isEmpty {
                settings.setDiscordAccount(username: "", name: "", avatar: nil)
                return
            }
            if let info = await fetchUser(token), token == settings.discordToken {
                settings.setDiscordAccount(username: info.username, name: info.name, avatar: info.avatar)
            }
        }
        .sheet(isPresented: $showLogin) {
            DiscordLoginScreen()
        }
        .accountAlert($alert) { which in
            alertView(which)
        }
        #if DEBUG
        .onAppear {
            if AccountDebugLaunch.takeAlert(.discordToken) != nil { present(.discordToken) }
            if AccountDebugLaunch.takeAlert(.discordStatus) != nil { present(.discordStatus) }
            if AccountDebugLaunch.take(.discordLogin) != nil { showLogin = true }
        }
        #endif
    }

    @ViewBuilder
    private func alertView(_ which: AccountAlert) -> some View {
        switch which {
        case .discordStatus:
            ChoiceAlert(title: L10n.status, message: L10n.statusDialogMessage,
                        options: DiscordPresenceStatus.allCases,
                        selected: DiscordPresenceStatus(stored: settings.discordStatus),
                        label: \.label, detail: { $0.detail },
                        onSelect: { settings.discordStatus = $0.rawValue }, onDismiss: closeAlert)
        case .discordActivityType:
            let name = settings.discordActivityName.isEmpty ? DiscordCard.appName : settings.discordActivityName
            ChoiceAlert(title: L10n.activity, message: L10n.activityDialogMessage,
                        options: DiscordActivityKind.allCases,
                        selected: DiscordActivityKind(stored: settings.discordActivityType),
                        label: \.label, detail: { "\u{201C}\($0.verb) \(name)\u{201D}" },
                        onSelect: { settings.discordActivityType = $0.rawValue }, onDismiss: closeAlert)
        case .discordActivityName:
            TextValueAlert(title: L10n.name, message: L10n.activityNameMessage(DiscordCard.appName),
                           placeholder: DiscordCard.appName, initial: settings.discordActivityName,
                           onSave: { settings.discordActivityName = $0 }, onDismiss: closeAlert)
        case .discordButton1:
            TextValueAlert(title: L10n.firstButton, message: L10n.discordButtonVariables,
                           placeholder: DiscordPresenceClient.defaultButton1, initial: settings.discordButton1Text,
                           onSave: { settings.discordButton1Text = $0 }, onDismiss: closeAlert)
        case .discordButton2:
            TextValueAlert(title: L10n.secondButton, message: L10n.discordButtonVariables,
                           placeholder: DiscordPresenceClient.defaultButton2, initial: settings.discordButton2Text,
                           onSave: { settings.discordButton2Text = $0 }, onDismiss: closeAlert)
        default:
            DiscordTokenAlert(onDismiss: closeAlert, fetchUser: fetchUser)
        }
    }

    private func present(_ which: AccountAlert) {
        setAccountAlert($alert, which)
    }

    private func closeAlert() {
        setAccountAlert($alert, nil)
    }
}

/// Who this posts as. Same frame as the account card, with Discord's status dot on the photo.
private struct DiscordAccountCard: View {
    let onConnect: () -> Void
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let connected = DiscordCard.connected(settings)
        let content = HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                AccountAvatar(url: settings.discordAvatar.isEmpty ? nil : settings.discordAvatar, size: 52,
                              placeholderSymbol: AppSymbol.discord)
                if connected {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                        // Ringed in the card's own colour so it reads as punched out of the photo.
                        .padding(2.5)
                        .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
                        .offset(x: 1, y: 1)
                        .accessibilityHidden(true)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(DiscordCard.accountTitle(settings))
                    .font(AppTheme.Typeface.titleLarge)
                    .lineLimit(1)
                Text(DiscordCard.accountSubtitle(settings))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !connected { SettingsChevron() }
        }
        .contentShape(Rectangle())

        if connected {
            content
                .accessibilityElement(children: .combine)
                .accessibilityValue(DiscordPresenceStatus(stored: settings.discordStatus).label)
        } else {
            Button(action: onConnect) { content }
                .buttonStyle(SettingsRowButtonStyle())
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("discord.card")
        }
    }

    /// Android paints primary / tertiary / error. This app's accent is red, which would make
    /// "online" read as do-not-disturb, so the dots take the colours the status alert describes
    /// ("Green dot", "Amber crescent", "Red dash").
    private var statusColor: Color {
        switch DiscordPresenceStatus(stored: settings.discordStatus) {
        case .online: return .green
        case .idle: return .orange
        case .dnd: return .red
        }
    }
}

/// A one-off explanation with its own dismiss, shaped like a settings group.
private struct DiscordNoticeCard: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .trailing, spacing: 0) {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.gotIt, action: onDismiss)
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
            }
            .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 4, trailing: 8))
        } header: {
            Color.clear.frame(height: 0)
                .listRowInsets(EdgeInsets(top: 26, leading: 0, bottom: 0, trailing: 0))
        }
    }
}

/// The card as Discord will draw it: heading, sleeve, title and artist (whichever leads is bold),
/// an optional quality line, the countdown, and up to two buttons. Deliberately not built from the
/// app's own row pieces — it is a picture of another app's UI. The buttons work, so it doubles as a
/// way to check the links land.
private struct RichPresencePreview: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerController.self) private var player
    @Environment(\.openURL) private var openURL

    var body: some View {
        let song = player.currentSong
        let useDetails = settings.discordUseDetails
        let quality = DiscordCard.audioQualityLine(player.stats, enabled: settings.discordShowAudioQuality)
        VStack(alignment: .leading, spacing: 0) {
            Text(DiscordCard.heading(settings))
                .font(.caption2.weight(.bold))
                .foregroundStyle(.primary)
            HStack(alignment: .top, spacing: 12) {
                ArtworkImage(song: song, pixels: ArtworkSize.card, cornerRadius: 6)
                    .frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 0) {
                    // Discord bolds whichever line `status_display_type` names — the one it also
                    // repeats next to the name in a member list — which is the whole point of
                    // "Lead with the song".
                    Text(song?.title ?? L10n.widgetPreviewTitle)
                        .font(.system(size: 15, weight: useDetails ? .bold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(song?.artist ?? L10n.widgetPreviewArtist)
                        .font(.system(size: 14, weight: useDetails ? .regular : .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let quality {
                        Text(quality)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    DiscordProgressLine()
                        .padding(.top, 8)
                }
            }
            .padding(.top, 12)
            if settings.discordButton1Visible {
                PresenceButton(label: DiscordCard.buttonLabel(settings.discordButton1Text,
                                                              fallback: DiscordPresenceClient.defaultButton1, song: song),
                               enabled: song != nil) {
                    if let song, let url = URL(string: DiscordPresenceClient.watchURL(for: song)) { openURL(url) }
                }
                .padding(.top, 12)
            }
            if settings.discordButton2Visible {
                PresenceButton(label: DiscordCard.buttonLabel(settings.discordButton2Text,
                                                              fallback: DiscordPresenceClient.defaultButton2, song: song),
                               enabled: true) {
                    if let url = URL(string: DiscordPresenceClient.projectURL) { openURL(url) }
                }
                .padding(.top, 8)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Elapsed and total either side of a plain 4 pt track, like Discord's own bar. Its own view so
/// the position's four-a-second ticks redraw only this.
private struct DiscordProgressLine: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        let positionMs = Int64(player.position * 1000)
        let durationMs = Int64(player.duration * 1000)
        VStack(spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.systemGray4))
                    Capsule().fill(Color.accentColor)
                        .frame(width: proxy.size.width * DiscordCard.progress(positionMs: positionMs, durationMs: durationMs))
                }
            }
            .frame(height: 4)
            HStack {
                Text(DiscordCard.clock(positionMs))
                Spacer()
                Text(DiscordCard.clock(durationMs))
            }
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(DiscordCard.clock(positionMs)) / \(DiscordCard.clock(durationMs))")
    }
}

/// Discord's flat, full-width secondary button.
private struct PresenceButton: View {
    let label: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(Color.primary.opacity(enabled ? 1 : 0.5))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Color(.systemGray4).opacity(enabled ? 0.9 : 0.4),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
