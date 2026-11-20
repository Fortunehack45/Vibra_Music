import VibraMusicCore
import SwiftUI

// Ports ui/screens/SpotifyCanvasAuthScreen.kt, opened from Settings › Appearance › "Set up Spotify
// Canvas" (under Animated cover art).

/// The sp_dc cookie Spotify Canvas needs, plus the two Canvas behaviour switches. Save stores the
/// token and goes back, as Android's does.
struct SpotifyCanvasSetupScreen: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var tokenInput = ""
    @State private var loaded = false

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                Text(L10n.spotifyCanvasSetupDescription)
                    .font(.body)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 8, trailing: 4))
            }
            Section {
                SettingsToggleRow(title: L10n.spotifyCanvasAutoHide, subtitle: L10n.spotifyCanvasAutoHideSubtitle,
                                  isOn: $settings.spotifyCanvasAutoHide)
                SettingsToggleRow(title: L10n.prioritizeSpotifyCanvas, subtitle: L10n.prioritizeSpotifyCanvasSubtitle,
                                  isOn: $settings.prioritizeSpotifyCanvas)
            } footer: {
                Text(L10n.spotifyCanvasSetupSteps)
            }
            Section {
                SecureField(L10n.spdcToken, text: $tokenInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.password)
                    .accessibilityIdentifier("spotifyCanvas.token")
            } header: {
                Text(L10n.spdcToken)
            }
            Section {
                Button {
                    settings.spotifySpdcToken = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    dismiss()
                } label: {
                    Text(L10n.save)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.spotifyCanvasSetup)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            tokenInput = settings.spotifySpdcToken
        }
    }
}
