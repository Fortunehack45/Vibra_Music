import VibraMusicCore
import SwiftUI

// Ports ui/components/Skeletons.kt and the empty/error states of Common.kt.

/// A pulsing placeholder shape (Skeletons.kt's shimmer), honouring Reduce Motion.
///
/// Driven by a `TimelineView`, as ``ShimmerBlock`` is. A repeating `withAnimation` in `onAppear` took
/// in whatever else changed in that pass: the album page's sort button, added as its loading rows
/// appeared, faded and slid in and out every 1.8 s for as long as the page was up.
struct SkeletonBlock: View {
    var width: CGFloat?
    var height: CGFloat
    var cornerRadius: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let period = 1.8

    var body: some View {
        let block = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(.tertiarySystemFill))
            .frame(width: width, height: height)
        if reduceMotion {
            block
        } else {
            TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: Self.period) / Self.period
                block.opacity(1 - 0.55 * (1 - cos(2 * .pi * phase)) / 2)
            }
        }
    }
}

/// Stand-in rows while a list loads.
struct SongRowSkeleton: View {
    var body: some View {
        HStack(spacing: 12) {
            SkeletonBlock(width: 48, height: 48, cornerRadius: AppTheme.artCorner)
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBlock(width: 180, height: 12)
                SkeletonBlock(width: 110, height: 10)
            }
            Spacer()
        }
        .padding(.horizontal, AppTheme.gutter)
        .padding(.vertical, 6)
        .accessibilityHidden(true)
    }
}

/// Stand-in shelf while a feed loads.
struct ShelfSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SkeletonBlock(width: 160, height: 18).padding(.horizontal, AppTheme.gutter)
            HStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonBlock(width: 150, height: 150, cornerRadius: 10)
                        SkeletonBlock(width: 110, height: 10)
                    }
                }
            }
            .padding(.horizontal, AppTheme.gutter)
        }
        .accessibilityHidden(true)
    }
}

/// A list of skeleton rows.
struct ListSkeleton: View {
    var rows = 8

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<rows, id: \.self) { _ in SongRowSkeleton() }
        }
    }
}

/// Nothing here: a symbol, a title, an optional explanation and action.
struct EmptyStateView: View {
    var symbol: String = AppSymbol.empty
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if let message { Text(message) }
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.bordered)
            }
        }
    }
}

/// Loading failed: the message and a retry.
struct ErrorStateView: View {
    var message: String?
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(L10n.somethingWentWrong, systemImage: AppSymbol.error)
        } description: {
            if let message, !message.isEmpty { Text(message) }
        } actions: {
            Button(L10n.retry, action: retry).buttonStyle(.bordered)
        }
        .accessibilityIdentifier("errorState")
    }
}

/// Draws a `LoadState`: skeleton while loading, the error with retry, else the content.
struct LoadStateView<Value, Content: View, Placeholder: View>: View {
    let state: LoadState<Value>
    let retry: () -> Void
    @ViewBuilder var placeholder: () -> Placeholder
    @ViewBuilder var content: (Value) -> Content

    var body: some View {
        switch state {
        case .loading: placeholder()
        case .error(let message): ErrorStateView(message: message, retry: retry)
        case .success(let value): content(value)
        }
    }
}

/// A titled placeholder for a screen another part of the port fills in.
struct FeaturePlaceholder: View {
    let title: String
    var symbol: String = AppSymbol.musicNote
    var detail: String?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if let detail { Text(detail) }
        }
        .navigationTitle(title)
        .accessibilityIdentifier("placeholder.\(title)")
    }
}
