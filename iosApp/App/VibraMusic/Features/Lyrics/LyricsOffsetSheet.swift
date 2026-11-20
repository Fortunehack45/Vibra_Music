import VibraMusicCore
import Lyrics
import SwiftUI

/// The lyrics offset's controls, apart from the view so the rules are testable (Android:
/// LyricsOffsetSheet.kt writing `AppSettings.lyricsOffsetMs`). Positive values delay the lyrics:
/// +500 ms moves the highlight later.
@MainActor
struct LyricsOffsetControl {
    let settings: AppSettings

    var offsetMs: Int { settings.lyricsOffsetMs }
    var readout: String { LyricsOffset.formatted(offsetMs, locale: LanguageBundle.locale) }
    var canDecrease: Bool { LyricsOffset.canDecrease(offsetMs) }
    var canIncrease: Bool { LyricsOffset.canIncrease(offsetMs) }
    var canReset: Bool { offsetMs != 0 }
    var fraction: Double { Double(LyricsOffset.fraction(forOffset: offsetMs)) }

    func decrease() { settings.lyricsOffsetMs = LyricsOffset.decreased(offsetMs) }
    func increase() { settings.lyricsOffsetMs = LyricsOffset.increased(offsetMs) }
    func reset() { settings.lyricsOffsetMs = 0 }
    /// The slider snaps to the buttons' 100 ms step.
    func setFraction(_ fraction: Double) {
        let snapped = LyricsOffset.offset(forFraction: Float(fraction))
        if snapped != offsetMs { settings.lyricsOffsetMs = snapped }
    }
}

/// A player drawer for shifting all synced lyrics against the playback clock (ports
/// ui/player/LyricsOffsetSheet.kt): the title and what the number means, the readout, − / slider
/// / +, and Reset under the card.
///
/// Android draws its own frosted drawer with a grab handle and drag-to-dismiss; the system sheet
/// is that control on iOS, so the handle is the sheet's drag indicator. Like every player drawer
/// it is dark whatever the app theme — it rises over the player.
struct LyricsOffsetSheet: View {
    @Environment(AppSettings.self) private var settings

    /// 19 sp on Android, so it grows with the reader's text size like the rest of the drawer.
    @ScaledMetric(relativeTo: .title3) private var titleSize: CGFloat = 19

    var body: some View {
        let control = LyricsOffsetControl(settings: settings)
        VStack(spacing: 0) {
            Text(L10n.lyricsOffset)
                .font(.system(size: titleSize, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            Text(L10n.lyricsOffsetDescription)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
                .padding(.top, 3)
                .padding(.bottom, 14)

            VStack(spacing: 8) {
                Text(control.readout)
                    .font(.system(.title, design: .default, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(value: Double(control.offsetMs)))
                    .animation(.snappy, value: control.offsetMs)
                    .accessibilityIdentifier("lyricsOffset.readout")
                HStack(spacing: 8) {
                    OffsetStepButton(label: "−", accessibility: L10n.decreaseLyricsOffset, enabled: control.canDecrease) {
                        Haptics.shared.play(.select)
                        control.decrease()
                    }
                    .accessibilityIdentifier("lyricsOffset.decrease")
                    // Android's ThinSlider; the system slider is its iOS counterpart.
                    Slider(value: Binding(get: { control.fraction }, set: { control.setFraction($0) }), in: 0...1)
                        .tint(.white)
                        .accessibilityLabel(L10n.lyricsOffset)
                        .accessibilityValue(control.readout)
                    OffsetStepButton(label: "+", accessibility: L10n.increaseLyricsOffset, enabled: control.canIncrease) {
                        Haptics.shared.play(.select)
                        control.increase()
                    }
                    .accessibilityIdentifier("lyricsOffset.increase")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            Button {
                Haptics.shared.play(.tap)
                control.reset()
            } label: {
                Text(L10n.lyricsOffsetReset)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(control.canReset ? 0.8 : 0.35))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!control.canReset)
            .padding(.top, 12)
            .accessibilityIdentifier("lyricsOffset.reset")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .frame(maxWidth: 640)
        .environment(\.colorScheme, .dark)
        .presentationDragIndicator(.visible)
        .presentationBackground { PlayerDrawerBackground() }
        // A container: without this the identifier lands on every child and hides theirs.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lyrics.offsetSheet")
    }
}

private struct OffsetStepButton: View {
    let label: String
    let accessibility: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.title2.weight(.regular))
                .foregroundStyle(.white.opacity(enabled ? 0.85 : 0.25))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(accessibility)
    }
}

/// The dark frosted ground every player drawer stands on (Android: HazeMaterials.regular over
/// #141414, then #121212 at 90 %; solid #121212 with Reduce dynamic blur).
struct PlayerDrawerBackground: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        ZStack {
            if settings.reduceDynamicBlur {
                Color(red: 0x12 / 255, green: 0x12 / 255, blue: 0x12 / 255)
            } else {
                Rectangle().fill(.regularMaterial)
                Color(red: 0x12 / 255, green: 0x12 / 255, blue: 0x12 / 255).opacity(0.9)
            }
        }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }
}
