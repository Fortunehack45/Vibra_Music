import VibraMusicCore
import ListenTogether
import SwiftUI

// Ports ui/player/ListenTogetherMembersSheet.kt: who is in the party right now, from the player's
// party button — a drawer rather than the settings page, with a Manage row as the way through to
// that page for what the drawer has no room for (party size, server, leaving). Drawn in the
// player's own dark style (PlayerDrawer): white text over the artwork backdrop.
//
// Presented by Now Playing; `onManage` is where the Manage row goes (the player closes and the
// Listen Together page opens).

struct ListenTogetherMembersSheet: View {
    @Environment(AppModel.self) private var app
    /// Drills into the full Listen Together page. Defaults to closing the player and pushing it.
    var onManage: (() -> Void)?

    var body: some View {
        PartyMembersDrawer(session: sessionState, onManage: onManage ?? openManage)
    }

    private var sessionState: PartySessionState {
        #if DEBUG
        if let demo = SocialDebugLaunch.partyService { return demo.state }
        #endif
        return app.listenTogether.state
    }

    private func openManage() {
        app.router.nowPlaying.close()
        app.router.open(.listenTogether)
    }
}

/// The drawer's content over a party state (testable without an app).
struct PartyMembersDrawer: View {
    let session: PartySessionState
    let onManage: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.listenTogether)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 14)
            VStack(spacing: 6) {
                ForEach(session.members, id: \.memberId) { member in
                    MemberDrawerRow(member: member, isYou: member.memberId == session.you?.memberId)
                }
            }
            ManageRow(code: session.code) {
                Haptics.shared.play(.select)
                dismiss()
                onManage()
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .fittedSheet()
        .presentationBackground(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
    }

    /// The line under a member's name: Host / You, else Away, else Host.
    static func subtitle(for member: PartyMember, isYou: Bool) -> String? {
        if isYou && member.isHost { return L10n.listenTogetherHost }
        if isYou { return L10n.listenTogetherYou }
        if !member.connected { return L10n.listenTogetherAway }
        if member.isHost { return L10n.listenTogetherHost }
        return nil
    }
}

private let drawerRowShape = RoundedRectangle(cornerRadius: 14, style: .continuous)

/// One member; the row that is you is lit, the way the output picker lights the playing route.
private struct MemberDrawerRow: View {
    let member: PartyMember
    let isYou: Bool

    var body: some View {
        HStack(spacing: 13) {
            PartyFace(url: member.avatarUrl, name: member.displayName, size: 40, background: .white.opacity(0.08))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName)
                    .font(.body.weight(isYou ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(isYou ? 1 : 0.85))
                    .lineLimit(1)
                if let subtitle = PartyMembersDrawer.subtitle(for: member, isYou: isYou) {
                    Text(subtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.white.opacity(isYou ? 0.10 : 0.05), in: drawerRowShape)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("partyDrawer.member")
    }
}

/// Through to the full Listen Together page.
private struct ManageRow: View {
    let code: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: AppSymbol.settings)
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.white.opacity(0.08)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.listenTogetherManage)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    if let code {
                        Text(L10n.listenTogetherInParty(code))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: AppSymbol.chevronRight)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.35))
                    .flipsForRightToLeftLayoutDirection(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.white.opacity(0.05), in: drawerRowShape)
            .contentShape(drawerRowShape)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("partyDrawer.manage")
    }
}
