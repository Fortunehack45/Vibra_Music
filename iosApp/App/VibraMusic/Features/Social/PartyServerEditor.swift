import VibraMusicCore
import ListenTogether
import Observation
import SwiftUI

// Ports ui/screens/PartyServerEditor.kt: the party server's address on the same card an addon is
// added with (AccountAlerts.kt's ServerEditorAlert) — a title, the description or the last result,
// one address field, and four stacked actions: Test, Save, Remove (only for a stored address, and
// never while a party is live on it), Cancel.

@MainActor
@Observable
final class PartyServerEditorModel {
    @ObservationIgnored private let service: ListenTogetherService

    /// A draft of the stored address, seeded once when the card opens: re-seeding it from the store
    /// while it is being typed into would overwrite the typing.
    var input: String {
        didSet {
            // A result describes the address it was run against; edited, it stops being true.
            if input != oldValue { status = nil }
        }
    }
    /// What the last Test or Save said, and whether it was good news. Nil until one has run.
    private(set) var status: (message: String, good: Bool)?
    private(set) var busy = false

    init(service: ListenTogetherService) {
        self.service = service
        input = service.customServer
    }

    var canSubmit: Bool { !input.trimmingCharacters(in: .whitespaces).isEmpty }
    /// Nothing to remove until one is stored, and never under a live membership: this device would
    /// be left holding a token for a server it no longer talks to.
    var canRemove: Bool { !service.customServer.isEmpty && !service.state.inParty }

    func test() async {
        switch PartyServerConfig.parseAndNormalizeServerUrl(input) {
        case .invalid(let error):
            status = (error.message, false)
        case .valid(let normalized):
            busy = true
            status = nil
            let probe = await service.probe(normalized)
            status = probe.isOnline
                ? (L10n.listenTogetherServerOnline(Int(probe.latencyMs)), true)
                : (L10n.listenTogetherServerOffline, false)
            busy = false
        }
    }

    /// Validates in the card (where the address being complained about still is), then stores it
    /// and says what the server did. Returns the toast to show, or nil when the card stays open.
    func save() async -> String?? {
        switch PartyServerConfig.parseAndNormalizeServerUrl(input) {
        case .invalid(let error):
            status = (error.message, false)
            return nil
        case .valid(let normalized):
            busy = true
            status = nil
            let resolved = await service.setCustomServer(normalized)
            busy = false
            return .some(Self.message(for: resolved, customServer: service.customServer))
        }
    }

    func remove() async -> String {
        busy = true
        status = nil
        _ = await service.setCustomServer("")
        busy = false
        return L10n.listenTogetherSwitchedToDefault
    }

    static func message(for state: PartyServerConnectionState, customServer: String) -> String? {
        switch state {
        case .customOnline: return L10n.listenTogetherCustomServerConnected
        case .customFallback: return L10n.listenTogetherCustomServerUnreachableFallback
        case .defaultOnline: return L10n.listenTogetherSwitchedToDefault
        case .offline: return customServer.isEmpty ? L10n.listenTogetherServerOffline : L10n.listenTogetherStatusAllOffline
        case .checking: return nil
        }
    }
}

/// The card. Android drew an iOS-style alert by hand because the action it needs — Test, which
/// must not close the card — is not something an alert's buttons can do; SwiftUI's `.alert` has the
/// same limit, so this is the same hand-drawn alert over a dimmed window.
struct PartyServerEditor: View {
    let service: ListenTogetherService
    /// Called when the card closes, with the toast to show (if any).
    let onDismiss: (String?) -> Void

    @State private var model: PartyServerEditorModel
    @State private var shown = false
    @FocusState private var fieldFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    init(service: ListenTogetherService, onDismiss: @escaping (String?) -> Void) {
        self.service = service
        self.onDismiss = onDismiss
        _model = State(initialValue: PartyServerEditorModel(service: service))
    }

    var body: some View {
        @Bindable var model = model
        ZStack {
            Color.black.opacity(shown ? 0.4 : 0)
                .ignoresSafeArea()
                .onTapGesture { if !model.busy { close(nil) } }
                .accessibilityHidden(true)
            if shown {
                card(model: model)
                    .transition(.scale(scale: 1.1).combined(with: .opacity))
            }
        }
        .onAppear {
            withAnimation(.spring(duration: 0.28)) { shown = true }
            fieldFocused = true
        }
    }

    private func card(model: PartyServerEditorModel) -> some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text(L10n.listenTogetherCustomServer)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(model.status?.message ?? L10n.listenTogetherCustomServerFooter)
                    .font(.footnote)
                    .foregroundStyle(statusColor)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("partyServer.status")
                // Never the default address, even as a placeholder: this box takes somebody else's.
                TextField("https://party.example.com", text: $model.input)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($fieldFocused)
                    .onSubmit { if model.canSubmit && !model.busy { runSave() } }
                    // Held while a Test or Save is out: the answer describes the address it was
                    // sent with, so that address can't change under it (ServerEditorAlert's
                    // `enabled = !testing`).
                    .disabled(model.busy)
                    .font(.subheadline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    // Android's PillTextField: a capsule, like every other field on its cards.
                    .background(Color(.tertiarySystemFill), in: Capsule())
                    .padding(.top, 12)
                    .accessibilityIdentifier("partyServer.field")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 19)

            Divider()
            action(model.busy ? L10n.testing : L10n.test, enabled: model.canSubmit && !model.busy) {
                Task { await model.test() }
            }
            Divider()
            action(L10n.save, emphasised: true, enabled: model.canSubmit && !model.busy) { runSave() }
            if model.canRemove {
                Divider()
                action(L10n.listenTogetherRemoveServer, destructive: true, enabled: !model.busy) {
                    Task { close(await model.remove()) }
                }
            }
            Divider()
            action(L10n.cancel, enabled: !model.busy) { close(nil) }
        }
        .frame(maxWidth: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private var statusColor: Color {
        guard let status = model.status else { return .primary }
        return status.good ? .accentColor : .red
    }

    private func action(_ label: String, emphasised: Bool = false, destructive: Bool = false, enabled: Bool, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(label)
                .font(.body.weight(emphasised ? .semibold : .regular))
                .foregroundStyle(destructive ? Color.red : Color.accentColor)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    private func runSave() {
        Task {
            if let toast = await model.save() { close(toast) }
        }
    }

    private func close(_ toast: String?) {
        fieldFocused = false
        withAnimation(.easeOut(duration: 0.18)) { shown = false }
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            onDismiss(toast)
        }
    }
}
