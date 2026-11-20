import VibraMusicCore
import Playback
import PlaybackPolicy
import SwiftUI

/// The audio pipeline, stage by stage: Track Info → Decoder → Resampler → DSP → Output Device
/// (ports ui/components/AudioPipelineDialog.kt).
///
/// Whether the decoded samples reach the output unaltered is stated outright in the DSP stage's
/// Bit-exact row, naming the first thing altering them — which is also the first thing to change
/// to get it back. While the track plays, a pulse travels down the signal bus between the stages.
/// Android's centred frosted card becomes a sheet on iOS, keeping its header, groups and the
/// full-width Done at the foot.
struct AudioPipelineSheet: View {
    let pipeline: AudioPipeline
    var isPlaying: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text(L10n.audioPipeline)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                Text(L10n.audioPipelineSubtitle)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 19)
            Divider().overlay(Color.white.opacity(0.12))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(pipeline.stages.enumerated()), id: \.element.id) { index, stage in
                        StageView(
                            stage: stage,
                            index: index,
                            isLast: index == pipeline.stages.count - 1,
                            flowing: isPlaying && !reduceMotion,
                            count: pipeline.stages.count
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            Divider().overlay(Color.white.opacity(0.12))
            Button {
                dismiss()
            } label: {
                Text(L10n.done)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pipeline.done")
        }
        .accessibilityIdentifier(pipeline.isSignalAltered ? "nowPlaying.pipelineSheet.altered" : "nowPlaying.pipelineSheet")
    }

    /// The pipeline for what's playing: the measured stream, the output route, and the DSP settings
    /// behind the engine's signal path.
    @MainActor
    static func build(player: PlayerController, settings: AppSettings) -> AudioPipeline {
        AudioPipeline.build(
            stats: PlayerQuality.snapshot(player: player),
            output: AudioOutputStatus.shared.current,
            dsp: PlayerPipelineWording.dspSettings(settings, signalPath: player.signalPath)
        )
    }
}

private struct StageView: View {
    let stage: AudioPipeline.Stage
    let index: Int
    let isLast: Bool
    let flowing: Bool
    let count: Int

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Image(systemName: stage.kind.playerSymbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 23, height: 23)
                    .background(Circle().fill(Color(white: 0.075)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.45), lineWidth: 1))
                if !isLast {
                    SignalBus(segment: index, segments: count - 1, flowing: flowing)
                        .frame(width: 6)
                        .frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(stage.kind.playerTitle)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(minHeight: 23)
                    .accessibilityAddTraits(.isHeader)
                ForEach(stage.rows, id: \.self) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(PlayerPipelineWording.label(row.label))
                            .foregroundStyle(.white.opacity(0.6))
                        Spacer(minLength: 12)
                        Text(row.value)
                            .foregroundStyle(.white.opacity(0.92))
                            .multilineTextAlignment(.trailing)
                    }
                    .font(.subheadline)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.bottom, isLast ? 0 : 18)
        }
    }
}

/// The line between two stage nodes, with the pulse passing through it in turn: one sweep down
/// the whole chain every 2.4 s, each segment taking its share.
private struct SignalBus: View {
    let segment: Int
    let segments: Int
    let flowing: Bool

    var body: some View {
        TimelineView(.animation(paused: !flowing)) { context in
            GeometryReader { proxy in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
                let span = 0.85 / Double(max(segments, 1))
                let local = (phase - Double(segment) * span) / span
                ZStack(alignment: .top) {
                    Rectangle()
                        .fill(Color.white.opacity(flowing ? 0.28 : 0.18))
                        .frame(width: 2)
                        .frame(maxWidth: .infinity)
                    if flowing, local >= 0, local <= 1 {
                        let y = proxy.size.height * local
                        LinearGradient(colors: [.clear, .white.opacity(0.95)], startPoint: .top, endPoint: .bottom)
                            .frame(width: 2.5, height: 38)
                            .offset(y: y - 38)
                            .frame(maxWidth: .infinity)
                        Circle()
                            .fill(Color.white)
                            .frame(width: 4, height: 4)
                            .shadow(color: .white.opacity(0.7), radius: 4)
                            .offset(y: y - 2)
                    }
                }
                .frame(height: proxy.size.height, alignment: .top)
                .clipped()
            }
        }
        .accessibilityHidden(true)
    }
}

/// A pipeline as it stood when the sheet was asked for, for `sheet(item:)`.
struct PlayerPipelineSnapshot: Identifiable {
    let id = UUID()
    let pipeline: AudioPipeline
}
