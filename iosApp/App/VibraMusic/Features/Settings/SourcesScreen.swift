import VibraMusicCore
import NetworkLibrary
import Sources
import SwiftUI

// Ports ui/screens/SourcesScreen.kt and the editors MainActivity.kt raises for it (the addon
// editor, the WebDAV and SMB server editors, the JioSaavn warning).
//
// Where the app may get audio from. Addons are tried first (the sources chosen on purpose), in the
// user's drag order; then the legacy module sources, JioSaavn and YouTube Music by rank. Nothing
// here downloads code: an addon answers with JSON. Legacy modules still run and can be re-pointed
// or removed, but a new one can't be added (the registry refuses a new module index).

/// `AppRoute.sources`, from Settings › Audio quality › Source.
struct SourcesScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(AppSettings.self) private var settings
    @State private var model: SourcesModel?
    @State private var metered: Bool?
    @State private var editing: SourceConfig?
    @State private var editingLibrary: RemoteLibraryKind?
    @State private var confirmJioSaavn = false

    var body: some View {
        let model = model ?? SourcesModel(registry: app.sourceRegistry)
        SourcesList(model: model, metered: metered, editing: $editing, editingLibrary: $editingLibrary,
                    confirmJioSaavn: $confirmJioSaavn, tester: { kind, values in try await app.testRemoteLibrary(kind, values) })
            .navigationTitle(L10n.source)
            .navigationBarTitleDisplayMode(.large)
            .onAppear { if self.model == nil { self.model = model } }
            .task { await model.refreshHealth() }
            .task {
                for await status in app.network.statusUpdates() { metered = status.isMetered }
            }
            .sheet(item: $editing) { config in
                AddonEditorSheet(model: AddonEditorModel(registry: app.sourceRegistry, config: config)) {
                    Task { await model.refreshHealth() }
                }
            }
            .sheet(item: $editingLibrary) { kind in
                ServerEditorSheet(kind: kind, fields: kind.fields(settings)) { values in
                    try await app.testRemoteLibrary(kind, values)
                } onSave: { values in
                    kind.save(values, to: settings)
                }
            }
            .alert(L10n.enableJiosaavn, isPresented: $confirmJioSaavn) {
                Button(L10n.enableAnyway) { model.confirmJioSaavn() }
                Button(L10n.cancel, role: .cancel) {}
            } message: {
                Text(L10n.jiosaavnMismatchWarning)
            }
    }
}

/// The list itself, over an explicit model so it can be hosted in tests.
struct SourcesList: View {
    let model: SourcesModel
    let metered: Bool?
    @Binding var editing: SourceConfig?
    @Binding var editingLibrary: RemoteLibraryKind?
    @Binding var confirmJioSaavn: Bool
    let tester: RemoteLibraryTester
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        let ceiling = SourcesModel.ceiling(settings: settings, metered: metered)
        let addons = model.addons
        let fixed = model.fixed
        List {
            SettingsGroup(header: L10n.sourcesOrderHeader, footer: model.footer(ceiling: ceiling)) {
                // One continuously numbered list: the numbers say what order the sources are tried
                // in, and restarting the count under a second heading would break the one thing
                // this screen is for.
                ForEach(Array(addons.enumerated()), id: \.element.id) { index, config in
                    row(config, position: index + 1, ceiling: ceiling)
                }
                .onMove { from, to in
                    Haptics.shared.play(.select)
                    model.moveAddons(from: from, to: to)
                }
                .moveDisabled(addons.count < 2)
                ForEach(Array(fixed.enumerated()), id: \.element.id) { index, config in
                    row(config, position: addons.count + index + 1, ceiling: ceiling)
                        .moveDisabled(true)
                }
                AddSourceRow { editing = SourceConfig(kind: .addon) }
                    .moveDisabled(true)
            }

            // Personal libraries rather than catalogues: they hold the listener's own files and
            // take no part in the ranking above.
            RemoteLibrarySection(kind: .webDAV, tester: tester) { editingLibrary = .webDAV }
            RemoteLibrarySection(kind: .smb, tester: tester) { editingLibrary = .smb }

            SettingsGroup(header: L10n.sourceMatching, footer: L10n.upgradeLengthSlackFooter) {
                SettingsSliderRow(
                    symbol: "slider.horizontal.3",
                    title: L10n.upgradeLengthSlack,
                    subtitle: L10n.upgradeLengthSlackSubtitle,
                    value: L10n.secondsShort(settings.upgradeLengthSlackSeconds),
                    sliderValue: Binding(get: { Double(settings.upgradeLengthSlackSeconds) },
                                         set: { settings.upgradeLengthSlackSeconds = Int($0.rounded()) }),
                    range: Double(AppSettings.upgradeLengthSlackRange.lowerBound)...Double(AppSettings.upgradeLengthSlackRange.upperBound),
                    step: 1
                )
            }
        }
        .settingsGroupList()
        // Dragging a row only works in edit mode, which also draws the grips.
        .environment(\.editMode, .constant(.active))
    }

    private func row(_ config: SourceConfig, position: Int, ceiling: AudioQuality) -> some View {
        SourceRow(
            position: position,
            config: config,
            status: model.statusLine(config, ceiling: ceiling, metered: metered == true),
            statusIsError: model.isRejected(config) && !SourcesModel.skippedByQuality(config, ceiling: ceiling),
            dimmed: !config.enabled || SourcesModel.skippedByQuality(config, ceiling: ceiling),
            isOn: SourcesModel.hasSwitch(config) ? Binding(
                get: { config.enabled },
                set: { on in if model.setEnabled(config, on) { confirmJioSaavn = true } }
            ) : nil,
            onEdit: SourcesModel.isEditable(config) ? { editing = config } : nil
        )
    }
}

/// Number, glyph, name and status line, then the switch (or "Always on"). The list's edit mode
/// draws the grip after it for a row whose position is the user's to set. Dimmed while off or
/// skipped by the ceiling; an off source still has a position worth setting.
private struct SourceRow: View {
    let position: Int
    let config: SourceConfig
    let status: String
    let statusIsError: Bool
    let dimmed: Bool
    let isOn: Binding<Bool>?
    let onEdit: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let large = typeSize.isAccessibilitySize
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("\(position)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 18, alignment: .leading)
                Spacer().frame(width: 6)
                SettingsIcon(symbol: symbol)
                Spacer().frame(width: SettingsMetrics.iconGap)
                VStack(alignment: .leading, spacing: 2) {
                    // Android's 1 + 2 lines, relaxed at accessibility sizes where they would
                    // truncate to a word.
                    Text(config.displayName)
                        .foregroundStyle(.primary)
                        .lineLimit(large ? 3 : 1)
                    Text(status)
                        .font(.subheadline)
                        .foregroundStyle(statusIsError ? Color.red : Color.secondary)
                        .lineLimit(large ? nil : 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            }
            .opacity(dimmed ? 0.4 : 1)
            .contentShape(Rectangle())
            .onTapGesture { onEdit?() }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(onEdit != nil ? .isButton : [])
            .accessibilityAction { onEdit?() }

            Spacer().frame(width: 8)
            if let isOn {
                Toggle(config.displayName, isOn: isOn)
                    .labelsHidden()
                    .tint(Color.accentColor)
            } else {
                Text(L10n.alwaysOn)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 40)
        // Android's source rows: 60 pt tall, 10 above and below.
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
    }

    private var symbol: String {
        switch config.kind {
        case .addon, .customModule, .module: return "puzzlepiece.extension.fill"
        case .jioSaavn: return "waveform"
        case .youtube: return "play.circle.fill"
        }
    }
}

/// The one row that adds something: at the foot of the numbered list, since what it adds goes
/// into that list. Its plus lines up with the numbers above it.
private struct AddSourceRow: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Spacer().frame(width: 24)
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: SettingsMetrics.iconSize)
                Spacer().frame(width: SettingsMetrics.iconGap)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.addAddon).foregroundStyle(Color.accentColor)
                    Text(L10n.addAddonDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsRowButtonStyle())
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        .accessibilityIdentifier("sources.addAddon")
    }
}

/// The server row, and once something is set up, Test and Disconnect. The test result lives here,
/// so each library tracks its own.
private struct RemoteLibrarySection: View {
    let kind: RemoteLibraryKind
    let tester: RemoteLibraryTester
    let onEdit: () -> Void
    @Environment(AppSettings.self) private var settings
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        SettingsGroup(header: kind.title, footer: kind.description) {
            SettingsRow(symbol: kind.symbol, title: kind.title, subtitle: kind.summary(settings), action: onEdit)
            if kind.isConfigured(settings) {
                SettingsRow(symbol: "server.rack", title: testing ? L10n.testing : (testResult ?? L10n.test),
                            subtitle: kind.listSubtitle) {
                    guard !testing else { return }
                    testing = true
                    testResult = nil
                    Task {
                        testResult = await remoteLibraryTestResult(kind, values: savedValues, tester: tester).message
                        testing = false
                    }
                }
                SettingsRow(symbol: "trash", title: kind.disconnectTitle) {
                    kind.disconnect(settings)
                    testResult = nil
                }
            }
        }
    }

    private var savedValues: [String] { kind.fields(settings).map(\.value) }
}

// MARK: - Editors

/// Android's frosted editor card (one field, status replacing the description in place, stacked
/// Test / Save / Remove / Cancel). An iOS alert can't stay open across a Test or show its result,
/// so the closest native control is a small form sheet with the same fields and actions.
struct AddonEditorSheet: View {
    @State var model: AddonEditorModel
    var onDone: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://my-addon.example.com", text: $model.url)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(model.busy)
                        .submitLabel(.done)
                        .onSubmit { save() }
                        .accessibilityIdentifier("addonEditor.url")
                } footer: {
                    EditorStatus(status: model.status, isGood: model.statusIsGood, description: L10n.addonUrlDescription)
                }
                Section {
                    Button(model.busy ? L10n.testing : L10n.test) {
                        Task { await model.run(save: false) }
                    }
                    .disabled(!model.canSubmit)
                    if !model.isNew {
                        Button(L10n.removeSource, role: .destructive) {
                            model.remove()
                            dismiss()
                            onDone()
                        }
                        .disabled(model.busy)
                    }
                }
            }
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.cancel) { dismiss() }.disabled(model.busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.save) { save() }.disabled(!model.canSubmit)
                }
            }
            .interactiveDismissDisabled(model.busy)
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        guard model.canSubmit else { return }
        Task {
            if await model.run(save: true) {
                dismiss()
                onDone()
            }
        }
    }
}

/// The WebDAV / SMB server editor (MainActivity.kt's `ServerEditorHost`): fields opening on the
/// saved values, Test against what is typed, Save stores it.
struct ServerEditorSheet: View {
    let kind: RemoteLibraryKind
    @State var fields: [ServerField]
    let test: RemoteLibraryTester?
    let onSave: ([String]) -> Void
    @State private var testing = false
    @State private var status: String?
    @State private var statusIsGood = false
    @Environment(\.dismiss) private var dismiss

    init(kind: RemoteLibraryKind, fields: [ServerField],
         test: @escaping @MainActor ([String]) async throws -> Void, onSave: @escaping ([String]) -> Void) {
        self.kind = kind
        _fields = State(initialValue: fields)
        self.test = { _, values in try await test(values) }
        self.onSave = onSave
    }

    private var values: [String] { fields.map(\.value) }
    private var canSubmit: Bool { kind.canSubmit(values) && !testing }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(fields.indices, id: \.self) { index in
                        field(index)
                    }
                } footer: {
                    EditorStatus(status: status, isGood: statusIsGood, description: kind.description)
                }
                Section {
                    Button(testing ? L10n.testing : L10n.test) {
                        guard let test else { return }
                        testing = true
                        status = nil
                        Task {
                            let result = await remoteLibraryTestResult(kind, values: values, tester: test)
                            status = result.message
                            statusIsGood = result.ok
                            testing = false
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.cancel) { dismiss() }.disabled(testing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.save) {
                        onSave(values)
                        dismiss()
                    }
                    .disabled(!canSubmit)
                }
            }
            .interactiveDismissDisabled(testing)
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func field(_ index: Int) -> some View {
        let binding = Binding(get: { fields[index].value }, set: { fields[index].value = $0; status = nil })
        switch fields[index].kind {
        case .password:
            SecureField(fields[index].placeholder, text: binding)
                .textContentType(.password)
                .disabled(testing)
        case .url:
            TextField(fields[index].placeholder, text: binding)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(testing)
        case .text:
            TextField(fields[index].placeholder, text: binding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(testing)
        }
    }
}

/// The description under an editor's fields, replaced by the last result, coloured by outcome.
private struct EditorStatus: View {
    let status: String?
    let isGood: Bool
    let description: String

    var body: some View {
        Text(status ?? description)
            .foregroundStyle(status == nil ? Color.secondary : (isGood ? Color.accentColor : Color.red))
            .animation(.default, value: status)
    }
}

// MARK: - Live connection tests

extension AppModel {
    /// Tests a WebDAV server or SMB share with the given editor values (in `RemoteLibraryKind.fields`
    /// order), through the same clients the libraries use.
    func testRemoteLibrary(_ kind: RemoteLibraryKind, _ values: [String]) async throws {
        let v = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        switch kind {
        case .webDAV:
            let credentials = WebDavCredentials(url: v[0], username: v[1], password: values[2])
            try await WebDavRepository(credentials: credentials, client: WebDavClient()).testConnection()
        case .smb:
            let credentials = SmbCredentials(host: v[0], share: v[1], basePath: v[2], username: v[3], password: values[4])
            try await SmbClient(credentials: credentials, pool: smbPool(for: credentials)).testConnection()
        }
    }
}
