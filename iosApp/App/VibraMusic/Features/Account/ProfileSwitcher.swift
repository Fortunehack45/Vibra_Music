import VibraMusicCore
import InnerTube
import SwiftUI

/// The account and profile selector opened from the top bar's avatar and from "Listen as" (ports
/// ui/components/AccountProfileSelector.kt and its host in MainActivity.kt).
///
/// Android drops a frosted card from under the top bar over a dimmed page; the iOS form of that is
/// a sheet with a frosted background. Same contents: "Switch account", then each Google account's
/// email with its Personal and Brand profiles (a tick on the active one), then Add account, Manage
/// accounts (which turns every profile row into a red "Sign out" for its account) and Settings.
struct ProfileSwitcher: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let identity = AccountIdentity(model.accounts)
        AccountProfileSelector(
            accounts: identity.accounts,
            activeAccountId: identity.activeAccountId,
            activeProfileId: identity.activeProfileId,
            onSelect: { account, profile in
                Haptics.shared.play(.select)
                Task { await model.accounts.selectProfile(accountId: account.accountId, profileId: profile.profileId) }
                dismiss()
            },
            onAddAccount: {
                // Replaces this sheet with the sign-in one.
                router.present(.googleSignIn)
            },
            onRemoveAccount: { account in
                Task { await model.accounts.removeAccount(account.accountId) }
                dismiss()
            },
            onOpenSettings: { Self.openSettings(router) }
        )
        .presentationBackground(model.settings.reduceDynamicBlur ? AnyShapeStyle(Color(.systemBackground))
                                                                  : AnyShapeStyle(.thinMaterial))
        .presentationDragIndicator(.visible)
    }
}

extension ProfileSwitcher {
    /// The selector's "Settings" row: closes the sheet and opens Settings, unless it is already open
    /// under the account page (Android sets `showSettings = true`, which changes nothing then).
    static func openSettings(_ router: AppRouter) {
        router.dismissSheet()
        if !router.path(for: router.selectedTab).contains(.settings) { router.open(.settings) }
    }
}

/// The selector's list, apart from where its data comes from.
struct AccountProfileSelector: View {
    let accounts: [GoogleAccountSession]
    let activeAccountId: String?
    let activeProfileId: String?
    let onSelect: (GoogleAccountSession, YouTubeProfile) -> Void
    let onAddAccount: () -> Void
    let onRemoveAccount: (GoogleAccountSession) -> Void
    let onOpenSettings: () -> Void

    @State private var managing = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text(L10n.switchAccount)
                    .font(AppTheme.Typeface.titleLarge)
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(EdgeInsets(top: 18, leading: 20, bottom: 8, trailing: 20))
                ForEach(accounts) { account in
                    Text(ProfileSelectorText.accountHeading(account))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(EdgeInsets(top: 12, leading: 20, bottom: 4, trailing: 20))
                    ForEach(account.profiles) { profile in
                        let selected = account.accountId == activeAccountId && profile.profileId == activeProfileId
                        ProfileRow(profile: profile, selected: selected, managing: managing) {
                            if managing { onRemoveAccount(account) } else { onSelect(account, profile) }
                        }
                    }
                }
                SelectorAction(symbol: "plus", label: L10n.addAccount, action: onAddAccount)
                    .accessibilityIdentifier("profiles.addAccount")
                SelectorAction(symbol: "person.2.badge.gearshape", label: L10n.manageAccounts) {
                    withAnimation(.easeInOut(duration: 0.2)) { managing.toggle() }
                }
                .accessibilityIdentifier("profiles.manage")
                SelectorAction(symbol: AppSymbol.settings, label: L10n.settings, action: onOpenSettings)
                    .accessibilityIdentifier("profiles.settings")
            }
            .padding(.bottom, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// The selector's wording, apart from the view.
enum ProfileSelectorText {
    /// An account's heading: its email, else its name, else "Accounts".
    static func accountHeading(_ account: GoogleAccountSession) -> String {
        if !account.email.trimmingCharacters(in: .whitespaces).isEmpty { return account.email }
        if !account.name.trimmingCharacters(in: .whitespaces).isEmpty { return account.name }
        return L10n.accounts
    }

    /// A profile's second line: its handle, else whether it is the Personal or a Brand profile.
    static func profileSubtitle(_ profile: YouTubeProfile) -> String {
        if !profile.handle.trimmingCharacters(in: .whitespaces).isEmpty { return profile.handle }
        return profile.isBrandAccount ? L10n.brandAccount : L10n.personal
    }
}

/// One profile: photo, name, handle; a tick on the active one, or "Sign out" while managing.
private struct ProfileRow: View {
    let profile: YouTubeProfile
    let selected: Bool
    let managing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AccountAvatar(url: profile.avatar, size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.name)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(ProfileSelectorText.profileSubtitle(profile))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if selected && !managing {
                    Image(systemName: AppSymbol.check)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
                if managing {
                    Text(L10n.signOut)
                        .foregroundStyle(.red)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(SelectorRowStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(managing ? L10n.signOut : (selected ? L10n.selectedAccount : L10n.switchAccount))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("profiles.row")
    }
}

/// Add account, Manage accounts, Settings.
private struct SelectorAction: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(label)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 20)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(SelectorRowStyle())
    }
}

private struct SelectorRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color(.systemFill).opacity(configuration.isPressed ? 1 : 0))
    }
}
