import AppIntents
import SwiftUI
import WidgetKit

// Ports res/layout/widget_media_compact.xml, widget_media_wide.xml and widget_media_pill.xml.
//
// Compiled into the app as well as the widget so the app's tests (and the debug gallery) can lay
// them out; the widget draws them through WidgetKit's container background, the app inline.

/// Where a widget view is being drawn.
enum WidgetCanvas {
    /// On the Home Screen: the background goes to WidgetKit (`containerBackground`), which rounds
    /// and insets it itself.
    case widgetKit
    /// Inside the app (tests, debug gallery): drawn inline and rounded like a widget.
    case inline
}

/// The Android widget's stand-in cover (`widget_preview_art.xml`): used when a track has no art and
/// in the gallery preview. The bottom third darkens on its own, standing in for the scrim.
struct WidgetPlaceholderArt: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: Color(red: 0x2E / 255, green: 0x34 / 255, blue: 0x46 / 255), location: 0),
                .init(color: Color(red: 0x1B / 255, green: 0x21 / 255, blue: 0x30 / 255), location: 0.45),
                .init(color: Color(red: 0x07 / 255, green: 0x09 / 255, blue: 0x0E / 255), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// Full-bleed cover whose foot dissolves into a blur for the transport band (MediaWidgetArt.render):
/// the blurred copy ramps in over a region far taller than the band and stops short of full, then a
/// scrim darkens the band itself.
struct WidgetCoverBackdrop: View {
    var art: WidgetArt?
    /// Height of the transport band in points (`widget_band_compact` 66 / `widget_band_wide` 60).
    var band: CGFloat

    /// MediaWidgetArt.BLUR_REGION_SCALE: how much taller than the band the blur's ramp is.
    static let blurRegionScale: CGFloat = 2.2

    var body: some View {
        GeometryReader { proxy in
            let height = max(proxy.size.height, 1)
            let region = min(band * Self.blurRegionScale, height)
            let rampStart = (height - region) / height
            let bandStart = (height - band) / height
            ZStack {
                if let art {
                    Image(uiImage: art.cover)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                    Image(uiImage: art.softened)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .clear, location: rampStart),
                                    .init(color: .black.opacity(0.35), location: rampStart + (bandStart - rampStart) * 0.6),
                                    .init(color: .black.opacity(0.92), location: bandStart),
                                    .init(color: .black.opacity(0.92), location: 1),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .clear, location: max(0, bandStart - 0.12)),
                            .init(color: .black.opacity(0.45), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                } else {
                    WidgetPlaceholderArt()
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// One transport glyph: a live App Intent button with a track, a plain dimmed glyph without one (so
/// the tap falls through to the widget's URL and opens the app, like MediaWidget's `open` intent).
struct WidgetControl<Intent: AppIntent>: View {
    var intent: Intent
    var symbol: String
    var label: String
    var opacity: Double
    var isLive: Bool
    var glyph: CGFloat
    var height: CGFloat
    var fillsWidth = true
    var isOn = false

    var body: some View {
        let icon = Image(systemName: symbol)
            .font(.system(size: glyph, weight: .semibold))
            .foregroundStyle(.white)
            .opacity(opacity)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .frame(width: fillsWidth ? nil : height, height: height)
            .background {
                // widget_toggle_on: a soft disc behind a toggle that is on.
                if isOn { Circle().fill(.white.opacity(0.2)).frame(width: height, height: height) }
            }
            .contentShape(Rectangle())
        if isLive {
            Button(intent: intent) { icon }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
        } else {
            icon.accessibilityLabel(label)
        }
    }
}

private extension View {
    @ViewBuilder
    func widgetBackground<Background: View>(_ canvas: WidgetCanvas, @ViewBuilder _ background: () -> Background) -> some View {
        switch canvas {
        case .widgetKit:
            containerBackground(for: .widget) { background() }
        case .inline:
            self.background { background() }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}

/// The 2×2 (systemSmall): full-bleed art, the title on its own line over three centred buttons.
struct CompactWidgetView: View {
    var snapshot: NowPlayingSnapshot?
    var art: WidgetArt?
    var canvas: WidgetCanvas = .widgetKit

    static let band: CGFloat = 66

    var body: some View {
        let face = WidgetFace(snapshot)
        VStack(spacing: 3) {
            Spacer(minLength: 0)
            Text(face.title)
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 4)
            HStack(spacing: 0) {
                WidgetControl(intent: PreviousTrackIntent(), symbol: "backward.fill", label: SharedStrings.widgetPrevious,
                              opacity: face.opacity(.previous), isLive: face.hasTrack, glyph: 17, height: 40)
                WidgetControl(intent: TogglePlaybackIntent(), symbol: face.toggleSymbol, label: face.toggleLabel,
                              opacity: face.opacity(.togglePlayPause), isLive: face.hasTrack, glyph: 20, height: 40)
                WidgetControl(intent: NextTrackIntent(), symbol: "forward.fill", label: SharedStrings.widgetNext,
                              opacity: face.opacity(.next), isLive: face.hasTrack, glyph: 17, height: 40)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .widgetBackground(canvas) { WidgetCoverBackdrop(art: art, band: Self.band) }
        .widgetURL(SharedConstants.openPlayerURL)
    }
}

/// The 4×2 (systemMedium): the same cover, with the title and artist beside the three buttons.
struct WideWidgetView: View {
    var snapshot: NowPlayingSnapshot?
    var art: WidgetArt?
    var canvas: WidgetCanvas = .widgetKit

    static let band: CGFloat = 60

    var body: some View {
        let face = WidgetFace(snapshot)
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(face.title)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if face.hasTrack, let artist = face.artist {
                        Text(artist)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
                WidgetControl(intent: PreviousTrackIntent(), symbol: "backward.fill", label: SharedStrings.widgetPrevious,
                              opacity: face.opacity(.previous), isLive: face.hasTrack, glyph: 18, height: 44, fillsWidth: false)
                WidgetControl(intent: TogglePlaybackIntent(), symbol: face.toggleSymbol, label: face.toggleLabel,
                              opacity: face.opacity(.togglePlayPause), isLive: face.hasTrack, glyph: 22, height: 44, fillsWidth: false)
                WidgetControl(intent: NextTrackIntent(), symbol: "forward.fill", label: SharedStrings.widgetNext,
                              opacity: face.opacity(.next), isLive: face.hasTrack, glyph: 18, height: 44, fillsWidth: false)
            }
            .frame(height: Self.band)
            .padding(.leading, 14)
            .padding(.trailing, 4)
        }
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .widgetBackground(canvas) { WidgetCoverBackdrop(art: art, band: Self.band) }
        .widgetURL(SharedConstants.openPlayerURL)
    }
}

/// The 4×1 row: the cover in a circle, the track over Like, previous, play, next and Shuffle.
///
/// iOS has no one-row Home Screen size, so this is offered in the medium slot (the closest native
/// size), with the row centred on a body of the cover blurred to colour — the capsule's body grown
/// to fill the widget.
struct PillWidgetView: View {
    var snapshot: NowPlayingSnapshot?
    var art: WidgetArt?
    var canvas: WidgetCanvas = .widgetKit

    var body: some View {
        let face = WidgetFace(snapshot)
        HStack(spacing: 6) {
            Group {
                if let art {
                    Image(uiImage: art.cover).resizable().scaledToFill()
                } else {
                    WidgetPlaceholderArt()
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(Circle())
            .accessibilityLabel(SharedStrings.widgetArtwork)
            VStack(alignment: .leading, spacing: 0) {
                Text(face.pillTitle)
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                HStack(spacing: 0) {
                    WidgetControl(intent: ToggleLikeIntent(), symbol: face.likeSymbol, label: face.likeLabel,
                                  opacity: face.opacity(.like), isLive: face.hasTrack, glyph: 18, height: 38, fillsWidth: false)
                    Spacer(minLength: 0)
                    WidgetControl(intent: PreviousTrackIntent(), symbol: "backward.fill", label: SharedStrings.widgetPrevious,
                                  opacity: face.opacity(.previous), isLive: face.hasTrack, glyph: 17, height: 38, fillsWidth: false)
                    Spacer(minLength: 0)
                    WidgetControl(intent: TogglePlaybackIntent(), symbol: face.toggleSymbol, label: face.toggleLabel,
                                  opacity: face.opacity(.togglePlayPause), isLive: face.hasTrack, glyph: 21, height: 38, fillsWidth: false)
                    Spacer(minLength: 0)
                    WidgetControl(intent: NextTrackIntent(), symbol: "forward.fill", label: SharedStrings.widgetNext,
                                  opacity: face.opacity(.next), isLive: face.hasTrack, glyph: 17, height: 38, fillsWidth: false)
                    Spacer(minLength: 0)
                    WidgetControl(intent: ToggleShuffleIntent(), symbol: "shuffle", label: face.shuffleLabel,
                                  opacity: face.opacity(.shuffle), isLive: face.hasTrack, glyph: 16, height: 38, fillsWidth: false,
                                  isOn: face.hasTrack && face.shuffleEnabled)
                }
                .frame(height: 38)
            }
            .padding(.top, 4)
        }
        .padding(.leading, 7)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .widgetBackground(canvas) {
            ZStack {
                if let art {
                    Image(uiImage: art.body).resizable().scaledToFill()
                } else {
                    WidgetPlaceholderArt()
                }
                Color.black.opacity(0.12)
            }
            .accessibilityHidden(true)
        }
        .widgetURL(SharedConstants.openPlayerURL)
    }
}
