import VibraMusicCore
import ListenTogether
import SwiftUI

// Ports ui/screens/ListenTogetherSheets.kt: the landing (this device's face lit from behind, Create
// and Join), the create sheet (name and size), the join sheet (six cells), the confirm sheet (who
// is in there), the invite sheet (a link and a square), and PartyCodeField from
// ListenTogetherScreen.kt.

// MARK: - Landing

/// This device's own face, lit from behind: one blurred circle that breathes on two offset periods,
/// so the rise and the fade never turn over together — light moving rather than a pulse.
struct GlowingAvatar: View {
    let url: String?
    var size: CGFloat = 104

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spread = false
    @State private var bright = false

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [Color.accentColor.opacity(bright ? 0.6 : 0.35),
                             Color.accentColor.opacity((bright ? 0.6 : 0.35) * 0.35),
                             .clear],
                    center: .center, startRadius: 0, endRadius: size * 0.875
                ))
                .frame(width: size * 1.75, height: size * 1.75)
                .scaleEffect(spread ? 1.14 : 0.92)
                .blur(radius: 28)
            PartyFace(url: url, name: nil, size: size, symbolScale: 0.45)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 2))
        }
        .frame(width: size * 2.1, height: size * 2.1)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            // Deliberately unequal periods: equal ones make the brightest frame always the widest.
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { spread = true }
            withAnimation(.easeInOut(duration: 3.4).repeatForever(autoreverses: true)) { bright = true }
        }
    }
}

/// A round face: the picture, else the initial, else a person glyph.
struct PartyFace: View {
    let url: String?
    let name: String?
    var size: CGFloat
    var symbolScale: CGFloat = 0.5
    var background: Color = Color(.secondarySystemFill)

    var body: some View {
        ZStack {
            Circle().fill(background)
            if let url {
                ArtworkImage(url: URL(string: url), cornerRadius: size / 2, placeholderSymbol: "person.fill")
            } else if let name, !name.isEmpty {
                Text(PartyText.initial(name))
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * symbolScale))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// What the page is when there is no party yet. Two doors, not equals: creating is the common case
/// and gets the filled button; joining is for somebody who already has a code.
struct PartyLanding: View {
    let avatarUrl: String?
    let enabled: Bool
    let onCreate: () -> Void
    let onJoin: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            GlowingAvatar(url: avatarUrl)
            Text(L10n.listenTogetherLandingTitle)
                .font(.system(.title, design: .default, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.top, 20)
            Text(L10n.listenTogetherLandingSubtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            PartyPrimaryButton(title: L10n.listenTogetherCreateAction, enabled: enabled, action: onCreate)
                .padding(.top, 28)
                .accessibilityIdentifier("party.create")
            Button(action: onJoin) {
                Text(L10n.listenTogetherJoinExisting)
                    .font(.headline.weight(.regular))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
            .padding(.top, 6)
            .accessibilityIdentifier("party.join")
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
    }
}

/// The filled, capsule-shaped action every party sheet leads with. Drawn rather than
/// `.borderedProminent`, whose disabled state goes near-black on a dark sheet; this one dims.
struct PartyPrimaryButton: View {
    let title: String
    var systemImage: String?
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PartyPrimaryLabel(title: title, systemImage: systemImage, enabled: enabled)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

struct PartyPrimaryLabel: View {
    let title: String
    var systemImage: String?
    var enabled = true

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage { Image(systemName: systemImage) }
            Text(title)
        }
        .font(.headline)
        .foregroundStyle(.white.opacity(enabled ? 1 : 0.7))
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(Color.accentColor.opacity(enabled ? 1 : 0.35), in: Capsule())
        .contentShape(Capsule())
    }
}

// MARK: - Sheet parts

/// The shared head of every sheet here: a title, and an optional line under it.
private struct SheetHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

/// Why the last attempt from this sheet did not work, said next to the control that produced it.
private struct SheetError: View {
    let message: String?

    var body: some View {
        if let message, !message.isEmpty {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
                .accessibilityIdentifier("party.sheetError")
        }
    }
}

/// The avatar and the nickname field, side by side (Android's PillTextField in the sheets).
private struct NicknameRow: View {
    let avatarUrl: String?
    @Binding var nickname: String
    var enabled = true

    var body: some View {
        HStack(spacing: 14) {
            PartyFace(url: avatarUrl, name: nil, size: 40)
                .accessibilityHidden(true)
            TextField(L10n.listenTogetherNicknameHint, text: $nickname)
                .submitLabel(.done)
                .textInputAutocapitalization(.words)
                .disabled(!enabled)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(Color(.tertiarySystemFill), in: Capsule())
                .accessibilityIdentifier("party.nickname")
        }
    }
}

/// The −/number/+ stepper Android drew with two text buttons.
struct PartySizeStepper: View {
    let value: Int
    let canDecrease: Bool
    let canIncrease: Bool
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", enabled: canDecrease) { onChange(value - 1) }
            Text("\(value)")
                .font(.headline.monospacedDigit())
                .frame(minWidth: 32)
            stepButton("plus", enabled: canIncrease) { onChange(value + 1) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.listenTogetherPartySize)
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if canIncrease { onChange(value + 1) }
            case .decrement: if canDecrease { onChange(value - 1) }
            @unknown default: break
            }
        }
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.5))
        .disabled(!enabled)
    }
}

// MARK: - Create

/// Name and size, asked once before a party exists (both can be changed afterwards).
struct CreatePartySheet: View {
    @Bindable var model: ListenTogetherModel

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: L10n.listenTogetherCreate, subtitle: L10n.listenTogetherCreateSheetSubtitle)
            NicknameRow(avatarUrl: model.myAvatarUrl,
                        nickname: Binding(get: { model.nickname }, set: { model.setNickname($0) }),
                        enabled: model.canStart)
                .padding(.top, 22)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.listenTogetherPartySize)
                    Text(L10n.listenTogetherPartySizeSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                PartySizeStepper(value: model.maxMembers,
                                 canDecrease: model.canStart && model.maxMembers > 2,
                                 canIncrease: model.canStart && model.maxMembers < PartyLimits.maxMembers,
                                 onChange: model.setNewPartySize)
            }
            .padding(.top, 18)
            PartyPrimaryButton(title: model.busy ? L10n.listenTogetherCreating : L10n.listenTogetherCreateAction,
                               enabled: model.canStart && !model.busy) {
                Task { await model.createParty() }
            }
            .padding(.top, 24)
            .accessibilityIdentifier("party.createConfirm")
            SheetError(message: model.failure)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 12)
    }
}

// MARK: - Join by code

/// Six characters, and the button that looks them up (a party to consider, not yet joined).
struct JoinPartySheet: View {
    @Bindable var model: ListenTogetherModel

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: L10n.listenTogetherJoin, subtitle: L10n.listenTogetherCodeHint)
            PartyCodeField(code: model.codeInput, enabled: model.canStart && !model.busy,
                           onChange: model.setCode) {
                Task { await model.submitCode() }
            }
            .padding(.top, 22)
            PartyPrimaryButton(title: model.busy ? L10n.listenTogetherJoining : L10n.listenTogetherJoinAction,
                               enabled: model.canStart && !model.busy && model.codeInput.count == PartyLimits.codeLength) {
                Task { await model.submitCode() }
            }
            .padding(.top, 20)
            .accessibilityIdentifier("party.lookUp")
            SheetError(message: model.failure)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 16)
    }
}

/// The party code as six cells over one invisible field: six fields would mean six focus targets
/// to hand along on every keystroke, and a pasted code landing entirely in the first. Every cell
/// keeps a ring; only the one being typed into lights up, and only while the keyboard is up.
struct PartyCodeField: View {
    let code: String
    let enabled: Bool
    let onChange: (String) -> Void
    let onSubmit: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        let characters = Array(code)
        ZStack {
            HStack(spacing: 8) {
                ForEach(0..<PartyLimits.codeLength, id: \.self) { index in
                    CodeCell(
                        character: index < characters.count ? characters[index] : nil,
                        active: focused && index == min(characters.count, PartyLimits.codeLength - 1),
                        enabled: enabled
                    )
                }
            }
            .accessibilityHidden(true)
            TextField("", text: Binding(get: { code }, set: onChange))
                .focused($focused)
                .disabled(!enabled)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .textContentType(.oneTimeCode)
                .submitLabel(.join)
                .onSubmit { if code.count == PartyLimits.codeLength { onSubmit() } }
                // Both invisible: the cells are where the typing shows up.
                .foregroundStyle(.clear)
                .tint(.clear)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(L10n.listenTogetherCode)
                .accessibilityValue(code.map(String.init).joined(separator: " "))
                .accessibilityIdentifier("party.codeField")
        }
        .frame(height: 52)
        .onAppear { if enabled { focused = true } }
    }
}

private struct CodeCell: View {
    let character: Character?
    let active: Bool
    let enabled: Bool

    @State private var caretVisible = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ZStack {
            shape.fill(Color(.tertiarySystemFill))
            shape.strokeBorder(active && enabled ? Color.accentColor : Color(.separator), lineWidth: 1.5)
            if let character {
                Text(String(character))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(enabled ? Color.primary : Color.secondary)
            } else if active {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor)
                    .frame(width: 2, height: 22)
                    .opacity(caretVisible ? 1 : 0)
                    .onAppear {
                        withAnimation(.linear(duration: 0.6).repeatForever(autoreverses: true)) { caretVisible = false }
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .animation(.easeInOut(duration: 0.15), value: active)
    }
}

// MARK: - Confirm

/// The faces already in a party, overlapped, with a count for the rest: three and a number, so the
/// row stays one width at two members and at ten.
struct MemberAvatarStack: View {
    let members: [PartyPreviewMember]
    let total: Int
    var faceSize: CGFloat = 52
    var shown = 3

    var body: some View {
        let faces = Array(members.prefix(shown))
        let extra = max(total - faces.count, 0)
        HStack(spacing: -12) {
            ForEach(Array(faces.enumerated()), id: \.offset) { _, member in
                PartyFace(url: member.avatarUrl, name: member.displayName, size: faceSize)
                    .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
            }
            if extra > 0 {
                Text("+\(extra)")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: faceSize, height: faceSize)
                    .background(Circle().fill(Color.accentColor))
                    .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The last step before a slot is committed: who is in there, and a way out that is not the back
/// gesture.
struct JoinConfirmSheet: View {
    @Bindable var model: ListenTogetherModel
    let preview: PartyPreview
    let server: String?

    var body: some View {
        VStack(spacing: 0) {
            MemberAvatarStack(members: preview.members, total: preview.memberCount)
            Text(preview.hostName.isEmpty ? L10n.listenTogetherJoinQuestionUnnamed : L10n.listenTogetherJoinQuestion(preview.hostName))
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.top, 18)
            // Only when the server told us: a server with no preview endpoint answers with a code
            // and nothing else, and "0 of 5 listening" would be inventing a fact.
            if preview.memberCount > 0 {
                Label(L10n.listenTogetherListening(preview.memberCount, preview.maxMembers), systemImage: "person.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 8)
            }
            NicknameRow(avatarUrl: model.myAvatarUrl,
                        nickname: Binding(get: { model.nickname }, set: { model.setNickname($0) }),
                        enabled: !model.busy)
                .padding(.top, 20)
            PartyPrimaryButton(title: joinTitle, enabled: !model.busy && !preview.isFull) {
                Task { await model.confirmJoin(preview, server: server) }
            }
            .padding(.top, 20)
            .accessibilityIdentifier("party.confirmJoin")
            SheetError(message: model.failure)
            Button {
                model.sheetDismissed()
            } label: {
                Text(L10n.listenTogetherNotNow)
                    .font(.headline.weight(.regular))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            Text(L10n.listenTogetherPreviewFooter)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 12)
    }

    private var joinTitle: String {
        if preview.isFull { return L10n.listenTogetherFull }
        return model.busy ? L10n.listenTogetherJoining : L10n.listenTogetherJoinAction
    }
}

// MARK: - Invite

/// How somebody else gets in: a link to send, or a square to point a camera at — with the code
/// under it, because the square is useless on the phone the party was made on.
struct InviteSheet: View {
    let code: String
    let link: String
    let shareMessage: String
    let onCopyCode: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: L10n.listenTogetherInviteTitle)
            ShareLink(item: shareMessage) {
                PartyPrimaryLabel(title: L10n.listenTogetherShareLink, systemImage: "link")
            }
            .buttonStyle(.plain)
            .padding(.top, 20)
            .accessibilityIdentifier("party.shareLink")
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.listenTogetherScanQr)
                    Text(L10n.listenTogetherScanQrSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button(action: onCopyCode) {
                        Text(code)
                            .font(.headline.weight(.bold))
                            .tracking(3)
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 10)
                    .accessibilityLabel(L10n.copyCode)
                    .accessibilityValue(code)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                PartyQRCode(content: link, size: 132)
            }
            .padding(.top, 24)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 16)
    }
}

// MARK: - Sizing

/// Sizes a sheet to its content, the way Android's ModalBottomSheet wraps its column: measured,
/// then handed to the detent.
///
/// In a scroll view that only scrolls when the content is taller than the screen: at the larger
/// accessibility text sizes (or a ten-member drawer) the detent tops out at the full height, and
/// the bottom of the sheet — the confirm sheet's footer, the drawer's Manage row — was cut off
/// with no way to reach it.
struct FittedSheet: ViewModifier {
    @State private var height: CGFloat = 320

    func body(content: Content) -> some View {
        ScrollView(.vertical) {
            content
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.automatic)
        .presentationDetents([.height(height)])
        .presentationDragIndicator(.visible)
    }
}

extension View {
    func fittedSheet() -> some View { modifier(FittedSheet()) }
}
