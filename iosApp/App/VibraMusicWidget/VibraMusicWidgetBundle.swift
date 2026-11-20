import SwiftUI
import WidgetKit

// Ports widget/MediaWidget.kt (MediaWidgetSquare, MediaWidgetWide) and widget/MediaWidgetPill.kt:
// the three entries Android's widget picker offers, in its order.

@main
struct VibraMusicWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingSquareWidget()
        NowPlayingWideWidget()
        NowPlayingPillWidget()
    }
}

/// "Now playing 2×2".
struct NowPlayingSquareWidget: Widget {
    static let kind = "com.fortune.vibramusic.ios.widget.square"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: NowPlayingProvider()) { entry in
            CompactWidgetView(snapshot: entry.snapshot, art: entry.art)
        }
        .configurationDisplayName(SharedStrings.widgetSquareLabel)
        .description(SharedStrings.widgetSquareDescription)
        .supportedFamilies([.systemSmall])
        // The band runs edge to edge over the cover, as on Android; the views pad themselves.
        .contentMarginsDisabled()
    }
}

/// "Now playing 4×2".
struct NowPlayingWideWidget: Widget {
    static let kind = "com.fortune.vibramusic.ios.widget.wide"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: NowPlayingProvider()) { entry in
            WideWidgetView(snapshot: entry.snapshot, art: entry.art)
        }
        .configurationDisplayName(SharedStrings.widgetWideLabel)
        .description(SharedStrings.widgetWideDescription)
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

/// "Now playing 4×1". iOS has no one-row Home Screen size; the medium slot is the closest.
struct NowPlayingPillWidget: Widget {
    static let kind = "com.fortune.vibramusic.ios.widget.pill"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: NowPlayingProvider()) { entry in
            PillWidgetView(snapshot: entry.snapshot, art: entry.art)
        }
        .configurationDisplayName(SharedStrings.widgetPillLabel)
        .description(SharedStrings.widgetPillDescription)
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}
