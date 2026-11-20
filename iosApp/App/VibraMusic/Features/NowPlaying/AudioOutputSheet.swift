import AVKit
import PlaybackPolicy
import SwiftUI

// Ports ui/player/AudioOutputSheet.kt and AudioOutput.kt. Android listed the phone's outputs and
// switched by telling its own player which sink to render into; iOS doesn't let an app list or pick
// outputs, so the sheet shows where the music is going now and hands the choice to the system's
// route picker (AVRoutePickerView: AirPods, AirPlay, Bluetooth, CarPlay) — PORTING.md §4.

/// Where the music is coming out, and how loud: the active output (tap it to open the system's
/// picker), the volume, and the way into the audio pipeline.
struct AudioOutputSheet: View {
    let accountName: String?
    /// The pipeline as it stands, built when the row is tapped.
    let makePipeline: () -> AudioPipeline
    var isPlaying = false

    @State private var pipeline: PlayerPipelineSnapshot?

    var body: some View {
        // Android's PlayerDrawer: a grab handle, a bold title, the rows; dragged down to put away.
        // The sheet's own drag indicator and detents are that drawer on iOS.
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.audioOutput)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.leading, 4)
                    .padding(.bottom, 8)
                    .accessibilityAddTraits(.isHeader)
                ForEach(shownOutputs) { device in
                    OutputRow(device: device, label: PlayerOutputLabel.label(for: device, accountName: accountName))
                }
                Spacer().frame(height: 4)
                SystemVolumeRow()
                Spacer().frame(height: 0)
                PipelineRow(summary: AudioOutputStatus.shared.current.summary) {
                    pipeline = PlayerPipelineSnapshot(pipeline: makePipeline())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 22)
            .padding(.bottom, 20)
        }
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(26)
        .sheet(item: $pipeline) { snapshot in
            AudioPipelineSheet(pipeline: snapshot.pipeline, isPlaying: isPlaying)
                .presentationDetents([.large])
                .presentationBackground(.ultraThinMaterial)
                // White-on-material like the sheet it opens from, whatever the system appearance.
                .preferredColorScheme(.dark)
        }
        .accessibilityIdentifier("nowPlaying.outputSheet")
    }

    /// The route's outputs, read live so a route change while the sheet is up shows in its rows
    /// (the player that presents it follows the audio session), or the phone itself before the
    /// session has reported one.
    private var shownOutputs: [AudioRouting.Device] {
        let outputs = AudioOutputStatus.shared.current.outputs
        if !outputs.isEmpty { return outputs }
        return [AudioRouting.Device(id: "phone", portType: .builtInSpeaker, name: "", kind: .phone, isActive: true)]
    }
}

/// One output. The playing one is lit and says so. Android switched outputs by tapping a row; an
/// iOS app can't pick a route itself, so each row is covered by the system's route picker
/// (AVRoutePickerView), which is the closest native control: tapping it offers AirPods,
/// AirPlay, Bluetooth and the phone, and switches.
private struct OutputRow: View {
    let device: AudioRouting.Device
    let label: String

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: PlayerOutputLabel.symbol(for: device.kind))
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(device.isActive ? 1 : 0.7))
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.white.opacity(device.isActive ? 0.16 : 0.08)))
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.body.weight(device.isActive ? .semibold : .regular))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if device.isActive {
                    Text(L10n.audioOutputPlaying)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer(minLength: 0)
            if device.isActive {
                Image(systemName: AppSymbol.check)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(device.isActive ? 0.1 : 0.05)))
        // Nearly transparent rather than hidden: a hidden view takes no touches.
        .overlay { PlayerRoutePicker(invisible: true) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("output.route")
    }
}

/// The system's route picker, stretched over whatever it sits on so the whole row is the button.
struct PlayerRoutePicker: UIViewRepresentable {
    /// Draws no glyph of its own, for covering a row that already says what it is.
    var invisible = false

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = invisible ? .clear : .white
        picker.activeTintColor = invisible ? .clear : .white
        return picker
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

/// Drills into the audio pipeline. Its subtitle is what's actually leaving the phone, read live,
/// so the row says it before anyone taps in for the rest of the chain.
private struct PipelineRow: View {
    let summary: String
    let action: () -> Void

    var body: some View {
        Button(action: {
            Haptics.shared.play(.select)
            action()
        }) {
            HStack(spacing: 13) {
                Image(systemName: "waveform")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.audioPipeline)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.85))
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.55))
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: AppSymbol.chevronRight)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.35))
                    .flipsForRightToLeftLayoutDirection(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("output.pipeline")
    }
}

/// The phone's media volume in the sheet: one speaker glyph and the system's slider, in a card
/// like the rows above it.
private struct SystemVolumeRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.body)
                .foregroundStyle(.white.opacity(0.6))
                .accessibilityHidden(true)
            PlayerSystemVolumeSlider()
                .frame(height: 32)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}
