import AudioDSP
import VibraMusicCore
import SwiftUI

// Ports ui/screens/EqualizerScreen.kt.
//
// **Dynamic** is a tone pad: one puck over a dot grid, tilting the spectrum left to right and
// shaping its middle bottom to top, with Broad and Focused choosing how wide each move is.
// **Manual** is the seven-band graphic equaliser with a preset list over it. Both drive the same
// filters (AudioDSP's `EqualizerCurve`), with the automatic preamp taking back any boost.
//
// Left out: Android's "System equalizer" row, which hands the audio session to the device's own
// effect panel. iOS has no such panel for an app to open.

/// The app's own equaliser (`AppRoute.equalizer`, from Settings › Playback › Equalizer).
struct EqualizerScreen: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerController.self) private var player
    @State private var pickingPreset = false

    var body: some View {
        @Bindable var settings = settings
        let enabled = settings.equalizerEnabled
        List {
            SettingsGroup(footer: L10n.equalizerFooter, topSpacing: 8) {
                SettingsToggleRow(symbol: "slider.horizontal.3", title: L10n.equalizer, isOn: Binding(
                    get: { settings.equalizerEnabled },
                    set: { on in
                        Haptics.shared.play(on ? .toggleOn : .toggleOff)
                        settings.equalizerEnabled = on
                    }
                ))
                .accessibilityIdentifier("equalizer.enabled")
            }

            // Off, the whole apparatus below reads as unavailable rather than merely idle: each
            // control is disabled itself, and the block is dimmed.
            Group {
                SettingsGroup(topSpacing: 18) {
                    Picker(L10n.equalizer, selection: $settings.equalizerMode) {
                        ForEach(EqualizerMode.allCases, id: \.self) { mode in
                            Text(mode.settingsLabel).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .sensoryFeedback(.selection, trigger: settings.equalizerMode)
                }

                switch settings.equalizerMode {
                case .dynamic: dynamicSections
                case .manual: manualSections
                }

                SettingsGroup(header: L10n.equalizerBalance, footer: L10n.equalizerBalanceFooter) {
                    BalanceControl(balance: $settings.equalizerBalance)
                }

                // A stream that never reaches the app's tap (Dolby Atmos passthrough, or a tap the
                // system refused) has no samples for a filter to touch. Said plainly rather than
                // left as a control that answers every touch and changes no sound.
                if player.signalPath == .spatialPassthrough || player.signalPath == .unprocessed {
                    SettingsGroup(footer: L10n.equalizerBitstreamFooter) {
                        SettingsRow(symbol: "exclamationmark.triangle", title: L10n.equalizerBitstreamTitle,
                                    subtitle: L10n.equalizerBitstreamSubtitle)
                    }
                }
            }
            .disabled(!enabled)
            // `.disabled` stops the built-in controls, not the pad's, faders' and balance's own drag gestures.
            .allowsHitTesting(enabled)
            .opacity(enabled ? 1 : 0.38)
            .animation(.easeInOut(duration: 0.22), value: enabled)
        }
        .settingsGroupList()
        .navigationTitle(L10n.equalizer)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $pickingPreset) { presetSheet }
    }

    // MARK: Dynamic

    @ViewBuilder
    private var dynamicSections: some View {
        @Bindable var settings = settings
        SettingsGroup(header: L10n.equalizerTone,
                      footer: settings.equalizerFocused ? L10n.equalizerFocusedFooter : L10n.equalizerBroadFooter) {
            TonePad(x: settings.equalizerToneX, y: settings.equalizerToneY) { x, y in
                settings.equalizerToneX = x
                settings.equalizerToneY = y
            }
            .listRowSeparator(.hidden)
            ToneReadout(x: settings.equalizerToneX, y: settings.equalizerToneY)
                .alignmentGuide(.listRowSeparatorLeading) { _ in SettingsMetrics.textInset }
            EqualizerChoiceRow(label: L10n.equalizerBroad, selected: !settings.equalizerFocused) {
                settings.equalizerFocused = false
            }
            EqualizerChoiceRow(label: L10n.equalizerFocused, selected: settings.equalizerFocused) {
                settings.equalizerFocused = true
            }
        }
    }

    // MARK: Manual

    @ViewBuilder
    private var manualSections: some View {
        @Bindable var settings = settings
        SettingsGroup {
            SettingsRow(symbol: "waveform", title: L10n.equalizerPreset,
                        value: EqualizerMath.preset(of: settings.equalizerBands).settingsLabel) {
                pickingPreset = true
            }
        }
        SettingsGroup(header: L10n.equalizerBands, footer: L10n.equalizerBandsFooter) {
            BandSliders(bands: $settings.equalizerBands)
            SettingsCenteredActionRow(label: L10n.equalizerReset) {
                Haptics.shared.play(.select)
                settings.equalizerBands = EqualizerPreset.flat.bandsDb
            }
        }
    }

    private var presetSheet: some View {
        let current = EqualizerMath.preset(of: settings.equalizerBands)
        // Custom is a state the bands can be in, not a curve anyone can choose, so it is only
        // listed while it is the one in force.
        let presets = EqualizerPreset.allCases.filter { $0 != .custom || current == .custom }
        return SettingsChoiceSheet(
            title: L10n.equalizerPreset,
            options: presets.map { SettingsChoice(value: $0, label: $0.settingsLabel, selectable: $0 != .custom) },
            selected: current
        ) { preset in
            settings.equalizerBands = preset.bandsDb
        }
    }
}

// MARK: - Tone pad

/// The dot grid and its puck. The puck snaps to whole steps as the finger moves, with a tick at
/// each, and springs between them rather than teleporting. Takes the touch on the way down, so a
/// vertical drag on the pad moves the puck rather than scrolling the page.
private struct TonePad: View {
    let x: Int
    let y: Int
    let onChange: (Int, Int) -> Void

    private let steps = EqualizerMath.toneSteps
    private let puckRadius: CGFloat = 19
    private let dotRadius: CGFloat = 2.5

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let usableWidth = size.width - puckRadius * 2
                    let usableHeight = size.height - puckRadius * 2
                    let columns = steps * 2
                    for column in 0...columns {
                        for row in 0...columns {
                            // The row and column through dead centre are drawn up, so the origin
                            // is findable without a reading.
                            let onAxis = column == steps || row == steps
                            let center = CGPoint(x: puckRadius + usableWidth * CGFloat(column) / CGFloat(columns),
                                                 y: puckRadius + usableHeight * CGFloat(row) / CGFloat(columns))
                            let dot = CGRect(x: center.x - dotRadius, y: center.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
                            context.fill(Path(ellipseIn: dot), with: .color(.secondary.opacity(onAxis ? 0.55 : 0.3)))
                        }
                    }
                }
                Circle()
                    .fill(Color(uiColor: .systemBackground))
                    .frame(width: puckRadius * 2, height: puckRadius * 2)
                    // A hairline so the puck reads on a dark card, where its shadow can't.
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1.5)
                    .position(puckCenter(in: size))
                    .animation(.spring(response: 0.18, dampingFraction: 0.75), value: x)
                    .animation(.spring(response: 0.18, dampingFraction: 0.75), value: y)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let step = EqualizerMath.toneStep(at: value.location, in: size, inset: puckRadius)
                        guard step.x != x || step.y != y else { return }
                        Haptics.shared.play(.tick)
                        onChange(step.x, step.y)
                    }
            )
        }
        .frame(height: 230)
        .padding(.vertical, 12)
        // A graph, not text: the tilt axis runs low to high left to right in every language.
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement()
        .accessibilityLabel(L10n.equalizerTone)
        .accessibilityValue("\(L10n.equalizerTilt) \(EqualizerMath.signed(x)), \(L10n.equalizerContour) \(EqualizerMath.signed(y))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(x + 1, steps), y)
            case .decrement: onChange(max(x - 1, -steps), y)
            @unknown default: break
            }
        }
        .accessibilityAction(named: Text("\(L10n.equalizerContour) +")) { onChange(x, min(y + 1, steps)) }
        .accessibilityAction(named: Text("\(L10n.equalizerContour) −")) { onChange(x, max(y - 1, -steps)) }
    }

    private func puckCenter(in size: CGSize) -> CGPoint {
        let usableWidth = size.width - puckRadius * 2
        let usableHeight = size.height - puckRadius * 2
        let columns = CGFloat(steps * 2)
        return CGPoint(x: puckRadius + usableWidth * CGFloat(x + steps) / columns,
                       y: puckRadius + usableHeight * CGFloat(steps - y) / columns)
    }
}

/// The two numbers under the pad: how far it is tilted, and how far contoured.
private struct ToneReadout: View {
    let x: Int
    let y: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "water.waves")
                .accessibilityLabel(L10n.equalizerTilt)
            Text(EqualizerMath.signed(x)).monospacedDigit()
            // With the stack's 8 either side, 22 between the pairs (Android ToneReadout).
            Spacer().frame(width: 6)
            Image(systemName: "chart.xyaxis.line")
                .accessibilityLabel(L10n.equalizerContour)
            Text(EqualizerMath.signed(y)).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// A row that is one of a set, ticked when it is the one in force.
private struct EqualizerChoiceRow: View {
    let label: String
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button {
            guard !selected else { return }
            Haptics.shared.play(.select)
            onSelect()
        } label: {
            HStack {
                Text(label).foregroundStyle(.primary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsRowButtonStyle())
        // Android's RowDivider starts at the text inset even under these glyph-less rows.
        .alignmentGuide(.listRowSeparatorLeading) { _ in SettingsMetrics.textInset }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Manual bands

/// Seven vertical faders, drawn: a track, a fill from the centre (the value is signed, so +6 and
/// −6 are equal and opposite) and a knob, each taking the touch on the way down.
private struct BandSliders: View {
    @Binding var bands: [Float]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(EqualizerMath.bandsHz.enumerated()), id: \.offset) { index, hz in
                let value = index < bands.count ? bands[index] : 0
                VStack(spacing: 8) {
                    Text(EqualizerMath.formatGain(value))
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(abs(value) < 0.05 ? Color.secondary : Color.accentColor)
                        .lineLimit(1)
                    BandFader(value: value, frequency: EqualizerMath.formatFrequency(hz)) { updated in
                        var next = bands
                        while next.count <= index { next.append(0) }
                        next[index] = updated
                        bands = next
                    }
                    Text(EqualizerMath.formatFrequency(hz))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 10)
        // Low to high, left to right, whatever the reading direction.
        .environment(\.layoutDirection, .leftToRight)
    }
}

private struct BandFader: View {
    let value: Float
    let frequency: String
    let onChange: (Float) -> Void

    private let height: CGFloat = 150
    private let trackWidth: CGFloat = 5
    private let knobRadius: CGFloat = 10
    private let range = EqualizerMath.rangeDb

    var body: some View {
        GeometryReader { proxy in
            let usable = proxy.size.height - knobRadius * 2
            let centerY = knobRadius + usable / 2
            let knobY = knobRadius + usable * CGFloat(1 - (value / range + 1) / 2)
            let centerX = proxy.size.width / 2
            ZStack {
                Capsule()
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .frame(width: trackWidth, height: usable)
                    .position(x: centerX, y: centerY)
                if abs(value) > 0.05 {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: trackWidth, height: abs(centerY - knobY))
                        .position(x: centerX, y: (centerY + knobY) / 2)
                }
                // The zero line, over the track so it survives a full-scale fill.
                Rectangle()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: trackWidth * 2, height: 1)
                    .position(x: centerX, y: centerY)
                Circle()
                    .fill(Color(uiColor: .systemBackground))
                    .frame(width: knobRadius * 2, height: knobRadius * 2)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1.5)
                    .position(x: centerX, y: knobY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let fraction = (drag.location.y - knobRadius) / max(usable, 1)
                        let snapped = EqualizerMath.gain(atFraction: fraction)
                        guard abs(snapped - value) > 0.001 else { return }
                        // A tick per step; the step at zero is the one people aim for.
                        Haptics.shared.play(.tick)
                        onChange(snapped)
                    }
            )
        }
        .frame(width: 34, height: height)
        .accessibilityElement()
        .accessibilityLabel("\(frequency) Hz")
        .accessibilityValue(L10n.loudnessGainDb(EqualizerMath.formatGain(value)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(EqualizerMath.snapGain(value + 0.5))
            case .decrement: onChange(EqualizerMath.snapGain(value - 0.5))
            @unknown default: break
            }
        }
    }
}

// MARK: - Balance

/// L and R with the trim between them, and a detent at centre: dead centre is where this spends
/// its life, and the one position a drag can't land on by aim alone. Left is left in every
/// language — it is the left speaker.
private struct BalanceControl: View {
    @Binding var balance: Float

    private let knobRadius: CGFloat = 10
    private let trackHeight: CGFloat = 5

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(L10n.equalizerBalanceLeft)
                Spacer()
                Text(EqualizerMath.formatBalance(balance))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Text(L10n.equalizerBalanceRight)
            }
            GeometryReader { proxy in
                let usable = proxy.size.width - knobRadius * 2
                let centerY = proxy.size.height / 2
                let centerX = knobRadius + usable / 2
                let knobX = knobRadius + usable * CGFloat(balance + 1) / 2
                ZStack {
                    Capsule()
                        .fill(Color(uiColor: .tertiarySystemFill))
                        .frame(width: usable, height: trackHeight)
                        .position(x: centerX, y: centerY)
                    if abs(balance) > 0.004 {
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: abs(centerX - knobX), height: trackHeight)
                            .position(x: (centerX + knobX) / 2, y: centerY)
                    }
                    Circle()
                        .fill(Color(uiColor: .systemBackground))
                        .frame(width: knobRadius * 2, height: knobRadius * 2)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1.5)
                        .position(x: knobX, y: centerY)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let snapped = EqualizerMath.balance(atFraction: (drag.location.x - knobRadius) / max(usable, 1))
                            guard abs(snapped - balance) > 0.004 else { return }
                            if snapped == 0 && balance != 0 { Haptics.shared.play(.tick) }
                            balance = snapped
                        }
                )
            }
            .frame(height: knobRadius * 2 + 8)
            .accessibilityElement()
            .accessibilityLabel(L10n.equalizerBalance)
            .accessibilityValue(EqualizerMath.formatBalance(balance))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: balance = EqualizerMath.balance(atFraction: CGFloat(balance + 1) / 2 + 0.05)
                case .decrement: balance = EqualizerMath.balance(atFraction: CGFloat(balance + 1) / 2 - 0.05)
                @unknown default: break
                }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .padding(.vertical, 6)
    }
}
