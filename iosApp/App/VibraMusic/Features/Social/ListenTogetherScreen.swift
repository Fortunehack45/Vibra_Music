import VibraMusicCore
import ListenTogether
import SwiftUI
import UIKit

// Ports ui/screens/ListenTogetherScreen.kt and the part of MainActivity.kt that places it: the
// page under a top bar titled "Listen together" whose trailing slot reads the party server's round
// trip, the sign-in row when signed out, then either the landing (no party) or the party itself
// (code, now playing, members, leave, activity), the page's error line, and the custom server row
// last. The server editor (PartyServerEditor.kt) and the invite server-switch dialog are mounted
// here too.
//
// Android's SettingsGroup/SettingsRow are iOS's grouped list sections and rows, so the page is an
// inset-grouped List; the large title is the navigation bar's.

/// One party, one code, up to ten signed-in devices.
struct ListenTogetherScreen: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ListenTogetherPage(service: service)
    }

    private var service: ListenTogetherService {
        #if DEBUG
        if let demo = SocialDebugLaunch.partyService { return demo }
        #endif
        return LiveListenTogetherService(app: app)
    }
}

/// The page over any ``ListenTogetherService`` (the live one, or a fake in tests).
struct ListenTogetherPage: View {
    @Environment(AppRouter.self) private var router
    @Environment(PlayerController.self) private var player

    @State private var model: ListenTogetherModel
    @State private var editingServer = false
    #if DEBUG
    @State private var debugMembers = false
    #endif

    init(service: ListenTogetherService) {
        _model = State(initialValue: ListenTogetherModel(service: service))
    }

    var body: some View {
        @Bindable var model = model
        List {
            if !model.signedIn {
                Section {
                    PartyRow(symbol: "person.crop.circle.badge.plus", title: L10n.signIn, subtitle: L10n.notSignedIn) {
                        router.present(.googleSignIn)
                    }
                    .accessibilityIdentifier("party.signIn")
                } footer: {
                    Text(L10n.listenTogetherSignInFooter)
                }
            }

            if !model.inParty {
                Section {
                    PartyLanding(avatarUrl: model.myAvatarUrl, enabled: model.canStart && !model.busy,
                                 onCreate: model.openCreate, onJoin: model.openJoin)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            } else {
                InAPartySections(model: model, onCopy: copyCode(toast: false))
                if !model.activity.isEmpty {
                    PartyActivitySection(entries: model.activity)
                }
            }

            if let message = model.pageError {
                Section {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("party.error")
                }
            }

            // Last, and empty by default: nobody setting up a party needs to think about an
            // address, so this is where somebody running their own server comes looking.
            Section {
                customServerRow
            } header: {
                Text(L10n.listenTogetherCustomServer)
            } footer: {
                Text(L10n.listenTogetherCustomServerFooter)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.listenTogether)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ServerPing(connection: model.connection)
            }
        }
        .sheet(item: $model.sheet, onDismiss: sheetClosed) { sheet in
            sheetContent(sheet)
                .fittedSheet()
        }
        .alert(serverSwitchTitle, isPresented: serverSwitchPresented, presenting: model.pendingServerSwitch) { pending in
            Button(L10n.listenTogetherCustomServerSwitchAndJoin) {
                Task { await model.acceptServerSwitch() }
            }
            .keyboardShortcut(.defaultAction)
            Button(L10n.cancel, role: .cancel) { model.declineServerSwitch() }
        } message: { pending in
            Text(pending.isSwitchToOfficial
                 ? L10n.listenTogetherOfficialServerDialogMessage(pending.code)
                 : L10n.listenTogetherCustomServerDialogMessage(pending.server, pending.code))
        }
        .fullScreenCover(isPresented: $editingServer) {
            PartyServerEditor(service: model.service) { toast in
                setEditingServer(false)
                if let toast { player.notice = QueueNotice(message: toast, symbol: nil) }
                Task { await model.refreshServer() }
            }
            .presentationBackground(.clear)
        }
        .task {
            await model.appeared()
            #if DEBUG
            await openDebugTarget()
            #endif
        }
        #if DEBUG
        .background {
            Color.clear.sheet(isPresented: $debugMembers) {
                PartyMembersDrawer(session: model.state) {}
            }
        }
        #endif
        // Runs on appearing too, so this is also where an invite that opened the page is taken.
        .task(id: model.signedIn) { await takeInvite() }
        .onChange(of: router.pendingPartyInvite) { Task { await takeInvite() } }
        .task {
            // The top bar's ping line stays current while the page is looked at: every 10 s, the
            // interval Android's health monitor uses while this screen is active.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await model.refreshServer()
            }
        }
    }

    // MARK: Parts

    private var customServerRow: some View {
        Button {
            setEditingServer(true)
        } label: {
            HStack(spacing: 14) {
                PartyRowIcon(symbol: "server.rack")
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.listenTogetherCustomServer)
                        .foregroundStyle(.primary)
                    Text(model.customServer.isEmpty ? L10n.listenTogetherUsingDefault : model.customServer)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !model.customServer.isEmpty {
                        ServerConnectionLine(connection: model.connection)
                    }
                }
                Spacer(minLength: 8)
                if model.busy {
                    ProgressView()
                } else {
                    Image(systemName: AppSymbol.chevronRight)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .flipsForRightToLeftLayoutDirection(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Locked while in a party: changing the address under a live membership would leave this
        // device holding a token for a server it no longer talks to.
        .disabled(model.inParty || model.busy)
        .opacity(model.inParty || model.busy ? 0.5 : 1)
        .accessibilityIdentifier("party.customServer")
    }

    @ViewBuilder
    private func sheetContent(_ sheet: PartySheet) -> some View {
        switch sheet {
        case .create:
            CreatePartySheet(model: model)
        case .joinCode:
            JoinPartySheet(model: model)
        case .confirm(let preview, let server):
            JoinConfirmSheet(model: model, preview: preview, server: server)
        case .invite:
            let code = model.state.code ?? ""
            InviteSheet(code: code, link: model.inviteLink(for: code), shareMessage: model.shareMessage ?? "",
                        onCopyCode: copyCode(toast: true))
        }
    }

    /// The editor is an alert, not a page: it fades in over the window rather than sliding up, so
    /// the cover itself is presented without its slide.
    private func setEditingServer(_ value: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { editingServer = value }
    }

    private func sheetClosed() {
        // Closed by a swipe with its message unread is still read.
        model.failure = nil
    }

    private func copyCode(toast: Bool) -> () -> Void {
        {
            UIPasteboard.general.string = model.state.code
            Haptics.shared.play(.select)
            if toast { player.notice = QueueNotice(message: L10n.copyCode, symbol: nil) }
        }
    }

    private var serverSwitchTitle: String {
        model.pendingServerSwitch?.isSwitchToOfficial == true
            ? L10n.listenTogetherOfficialServerDialogTitle
            : L10n.listenTogetherCustomServerDialogTitle
    }

    private var serverSwitchPresented: Binding<Bool> {
        Binding(get: { model.pendingServerSwitch != nil },
                set: { if !$0 { model.declineServerSwitch() } })
    }

    #if DEBUG
    /// `-socialOpen …` (see ``SocialDebugLaunch``).
    private func openDebugTarget() async {
        switch SocialDebugLaunch.open {
        case "create": model.openCreate()
        case "join":
            model.openJoin()
            model.setCode("K7Q2")
        case "confirm": await model.openPartyPreview(code: "K7Q2XD", server: nil)
        case "invite": model.openInvite()
        case "editor": setEditingServer(true)
        case "members": debugMembers = true
        default: break
        }
    }
    #endif

    /// A party invite from a link, handed over by the router. Kept waiting (code filled in) while a
    /// signed-out device signs in.
    private func takeInvite() async {
        guard let invite = router.pendingPartyInvite else { return }
        if await model.handleInvite(code: invite.code, server: invite.server) {
            router.pendingPartyInvite = nil
        }
    }
}

// MARK: - In a party

/// The code, what is playing, who is in, and the way out.
private struct InAPartySections: View {
    @Bindable var model: ListenTogetherModel
    let onCopy: () -> Void

    var body: some View {
        let state = model.state
        Section {
            // Wide tracking: a string read out loud and typed by somebody else, not a word.
            Text(state.code ?? "")
                .font(.system(size: 36, weight: .regular, design: .default))
                .tracking(8)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                .padding(.bottom, 6)
                .accessibilityLabel(L10n.listenTogetherCode)
                .accessibilityValue((state.code ?? "").map(String.init).joined(separator: " "))
                .accessibilityIdentifier("party.code")
            PartyRow(symbol: "doc.on.doc", title: L10n.copyCode, action: onCopy)
            PartyRow(symbol: AppSymbol.share, title: L10n.share) { model.openInvite() }
                .accessibilityIdentifier("party.share")
        } header: {
            Text(L10n.listenTogetherCode)
        } footer: {
            Text(L10n.listenTogetherCodeFooter)
        }

        PartyNowPlayingSection(model: model)

        Section {
            if model.isHost {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.listenTogetherPartySize)
                        Text(L10n.listenTogetherHostControls)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    PartySizeStepper(value: state.maxMembers, canDecrease: model.canShrinkParty,
                                     canIncrease: model.canGrowParty, onChange: model.setPartySize)
                }
                .accessibilityIdentifier("party.size")
                Toggle(isOn: Binding(get: { state.hostOnlyControl }, set: model.setHostOnlyControl)) {
                    HStack(spacing: 14) {
                        PartyRowIcon(symbol: "lock.fill")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.listenTogetherHostOnly)
                            Text(L10n.listenTogetherHostOnlySubtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("party.hostOnly")
            }
            ForEach(state.members, id: \.memberId) { member in
                PartyMemberRow(member: member, isYou: member.memberId == state.you?.memberId,
                               canKick: model.isHost && !member.isHost) { model.kick(member) }
            }
        } header: {
            Text(L10n.listenTogetherListening(state.members.count, state.maxMembers))
        } footer: {
            Text(L10n.listenTogetherMembersFooter(state.maxMembers))
        }

        Section {
            PartyRow(symbol: "rectangle.portrait.and.arrow.right", title: L10n.listenTogetherLeave,
                     subtitle: L10n.listenTogetherLeaveSubtitle) {
                Task { await model.leave() }
            }
            .accessibilityIdentifier("party.leave")
        }
    }
}

/// What the party is playing and where its playhead is right now — recomputed on a tick, because
/// that is the feature: two phones side by side should show the same number.
private struct PartyNowPlayingSection: View {
    let model: ListenTogetherModel
    @State private var positionMs: Int64 = 0

    var body: some View {
        let state = model.state
        let track = state.playback.track
        Section(L10n.listenTogetherNowPlaying) {
            HStack(spacing: 14) {
                PartyRowIcon(symbol: AppSymbol.musicNote)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track?.title.isEmpty == false ? track!.title : L10n.listenTogetherNothingPlaying)
                        .lineLimit(1)
                    Text(PartyText.nowPlayingSubtitle(state, positionMs: positionMs))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("party.nowPlaying")
        }
        .task(id: "\(state.playback.seq)-\(state.playback.isPlaying)") {
            while !Task.isCancelled {
                positionMs = await model.service.partyPositionMs() ?? 0
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

/// One member: face, name (with "You"), "Away" while their socket is gone, and Host or the host's
/// Remove on the trailing edge.
private struct PartyMemberRow: View {
    let member: PartyMember
    let isYou: Bool
    let canKick: Bool
    let onKick: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // The member is one VoiceOver element; Remove stays a separate one. Combined into the
            // row, Remove became the row's default action, so double-tapping a name to hear it
            // read would have removed that person from the party.
            HStack(spacing: 14) {
                PartyFace(url: member.avatarUrl, name: member.displayName, size: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(member.displayName)
                            .lineLimit(1)
                        if isYou { PartyBadge(text: L10n.listenTogetherYou) }
                    }
                    // "Away" rather than "offline": the server holds the slot through a grace period.
                    if !member.connected {
                        Text(L10n.listenTogetherAway)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if member.isHost {
                    PartyBadge(text: L10n.listenTogetherHost)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("party.member")
            if !member.isHost, canKick {
                Button(L10n.listenTogetherRemove, action: onKick)
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L10n.listenTogetherRemove)
                    .accessibilityValue(member.displayName)
                    .accessibilityIdentifier("party.kick")
            }
        }
        .frame(minHeight: 36)
    }
}

/// The small pill Android's `Badge` draws after a name.
struct PartyBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color(.tertiarySystemFill), in: Capsule())
    }
}

/// A log of who skipped what, in its own short scrolling box.
private struct PartyActivitySection: View {
    let entries: [PartyActivity]

    var body: some View {
        Section {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        Text(PartyText.activityLine(entry))
                            .font(.caption.monospacedDigit())
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(height: 156)
            .accessibilityIdentifier("party.activity")
        } header: {
            Text(L10n.listenTogetherActivity)
        } footer: {
            Text(L10n.listenTogetherActivityFooter)
        }
    }
}

// MARK: - Rows and status

/// A settings row: glyph, title, optional subtitle, the whole row a button.
struct PartyRow: View {
    let symbol: String
    let title: String
    var subtitle: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                PartyRowIcon(symbol: symbol)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PartyRowIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.body)
            .foregroundStyle(Color.accentColor)
            .frame(width: 26)
            .accessibilityHidden(true)
    }
}

/// Whether the typed address is actually answering, under it (nothing for the built-in server —
/// the row already says "using the built-in one").
private struct ServerConnectionLine: View {
    let connection: PartyServerConnectionState

    var body: some View {
        switch connection {
        case .checking:
            line(nil, L10n.listenTogetherServerChecking, .secondary, spinner: true)
        case .customOnline(let ms):
            line("checkmark.icloud", L10n.listenTogetherStatusCustomOnline(Int(ms)), .accentColor)
        case .customFallback(let ms):
            line("icloud.slash", L10n.listenTogetherStatusCustomFallback(Int(ms)), .red)
        case .offline:
            line("icloud.slash", L10n.listenTogetherStatusAllOffline, .red)
        case .defaultOnline:
            EmptyView()
        }
    }

    private func line(_ symbol: String?, _ text: String, _ tint: Color, spinner: Bool = false) -> some View {
        HStack(spacing: 6) {
            if spinner {
                ProgressView().controlSize(.mini)
            } else if let symbol {
                Image(systemName: symbol).font(.caption)
            }
            Text(text).font(.caption).lineLimit(1)
        }
        .foregroundStyle(tint)
        .accessibilityElement(children: .combine)
    }
}

/// The top bar's trailing round-trip readout, scoped to this page: meaningful while coordinating a
/// party, noise anywhere else.
struct ServerPing: View {
    let connection: PartyServerConnectionState

    var body: some View {
        Group {
            switch connection {
            case .customFallback(let ms):
                HStack(spacing: 4) {
                    Image(systemName: "icloud.slash")
                    Text(L10n.listenTogetherPing(Int(ms)))
                }
                .foregroundStyle(.red)
                .accessibilityLabel(L10n.listenTogetherTopBarFallback(L10n.listenTogetherPing(Int(ms))))
            case .customOnline(let ms), .defaultOnline(let ms):
                Text(L10n.listenTogetherPing(Int(ms)))
            case .checking:
                Text(L10n.listenTogetherServerChecking).foregroundStyle(.secondary)
            case .offline:
                Text(L10n.listenTogetherServerOfflineDash).foregroundStyle(.red)
            }
        }
        .font(.footnote.weight(.medium).monospacedDigit())
        .lineLimit(1)
        .accessibilityIdentifier("party.ping")
    }
}
