import SwiftUI

// Ports the parts of ui/components/Skeletons.kt the Browse screens use: grey stand-ins laid out
// to the same metrics as the real rows and cards, so nothing jumps when the data lands.

/// Ragged widths, so a run of rows reads as text rather than as a barcode.
private let titleWidths: [CGFloat] = [0.68, 0.46, 0.58, 0.74, 0.52]
private let subtitleWidths: [CGFloat] = [0.34, 0.44, 0.27, 0.38, 0.31]

/// One placeholder block with a highlight sweeping across it (`ShimmerBox`), every 1.4 s.
///
/// Driven by a `TimelineView` rather than a repeating `withAnimation`: an animation started that
/// way belongs to whatever transaction is open, and a skeleton is exactly the view that gets
/// swapped out mid-animation. With Reduce Motion on it is a flat block.
struct ShimmerBlock<S: Shape>: View {
    var shape: S

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static var period: Double { 1.4 }

    var body: some View {
        if reduceMotion {
            shape.fill(Color(.secondarySystemFill))
        } else {
            TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: Self.period) / Self.period
                shape
                    .fill(Color(.secondarySystemFill))
                    .overlay {
                        GeometryReader { proxy in
                            let band = proxy.size.width * 0.5
                            let start = -band + phase * (proxy.size.width + band * 2)
                            LinearGradient(
                                colors: [.clear, Color.primary.opacity(0.08), .clear],
                                startPoint: .leading, endPoint: .trailing
                            )
                            .frame(width: band)
                            .offset(x: start)
                        }
                        .clipShape(shape)
                    }
            }
        }
    }
}

extension ShimmerBlock where S == RoundedRectangle {
    init(cornerRadius: CGFloat = 6) {
        self.init(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// A placeholder line `fraction` of its parent wide.
private struct SkeletonLine: View {
    let fraction: CGFloat
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ShimmerBlock(cornerRadius: 4).frame(width: proxy.size.width * fraction, height: height)
        }
        .frame(height: height)
    }
}

/// A section heading: only the title line — most shelves come back without a subtitle.
private struct SectionHeaderSkeleton: View {
    var index = 0

    var body: some View {
        SkeletonLine(fraction: titleWidths[index % titleWidths.count] * 0.7, height: 18)
            .padding(.horizontal, BrowseMetrics.gutter)
            .padding(.vertical, 10)
    }
}

/// One search row (`SongRowSkeleton`); `circular` for artist rows.
struct BrowseRowSkeleton: View {
    var index = 0
    var circular = false

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if circular { ShimmerBlock(shape: Circle()) } else { ShimmerBlock(cornerRadius: 8) }
            }
            .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 7) {
                SkeletonLine(fraction: titleWidths[index % titleWidths.count], height: 14)
                SkeletonLine(fraction: subtitleWidths[index % subtitleWidths.count], height: 11)
            }
        }
        .padding(.horizontal, BrowseMetrics.gutter)
        .padding(.vertical, 8)
        .accessibilityHidden(true)
    }
}

/// The compact carousel of square cards used by every shelf below the first.
struct ShelfCardsSkeleton: View {
    var index = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeaderSkeleton(index: index)
            HStack(alignment: .top, spacing: BrowseMetrics.cardSpacing) {
                ForEach(0..<3, id: \.self) { card in
                    VStack(alignment: .leading, spacing: 0) {
                        ShimmerBlock(cornerRadius: 12)
                            .frame(width: BrowseMetrics.shelfCardWidth, height: BrowseMetrics.shelfCardWidth)
                        SkeletonLine(fraction: titleWidths[card % titleWidths.count], height: 13).padding(.top, 12)
                        SkeletonLine(fraction: subtitleWidths[card % subtitleWidths.count], height: 11).padding(.top, 6)
                    }
                    .frame(width: BrowseMetrics.shelfCardWidth)
                }
            }
            .padding(.horizontal, BrowseMetrics.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .padding(.bottom, BrowseMetrics.shelfBottom)
        .accessibilityHidden(true)
    }
}

/// The lead shelf's near-page-width cards.
private struct HeroShelfSkeleton: View {
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeaderSkeleton()
            heroCards(width: width)
        }
        .padding(.bottom, BrowseMetrics.shelfBottom)
    }
}

private func heroCards(width: CGFloat) -> some View {
    let cardWidth = BrowseMetrics.heroCardWidth(width)
    return HStack(spacing: BrowseMetrics.cardSpacing) {
        ForEach(0..<2, id: \.self) { _ in
            ShimmerBlock(cornerRadius: 18)
                .frame(width: cardWidth, height: cardWidth / BrowseMetrics.heroCardRatio)
        }
    }
    .padding(.horizontal, BrowseMetrics.gutter)
    .frame(width: width, alignment: .leading)
    .clipped()
}

/// Reserved at the top of Home while Recents loads, in its saved layout.
struct RecentsSkeleton: View {
    let listLayout: Bool
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SkeletonLine(fraction: titleWidths[0] * 0.7, height: 18)
                ShimmerBlock(shape: Circle()).frame(width: 32, height: 32)
            }
            .padding(.horizontal, BrowseMetrics.gutter)
            .padding(.vertical, 10)
            if listLayout {
                VStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { index in
                        HStack(spacing: 12) {
                            ShimmerBlock(cornerRadius: 7).frame(width: 48, height: 48)
                            VStack(alignment: .leading, spacing: 6) {
                                SkeletonLine(fraction: titleWidths[index % titleWidths.count], height: 14)
                                SkeletonLine(fraction: subtitleWidths[index % subtitleWidths.count], height: 11)
                            }
                        }
                        .padding(.vertical, 7)
                    }
                }
                .frame(width: BrowseMetrics.trackColumnWidth(width))
                .padding(.horizontal, BrowseMetrics.gutter)
            } else {
                heroCards(width: width)
            }
        }
        .padding(.bottom, BrowseMetrics.shelfBottom)
        .accessibilityHidden(true)
    }
}

/// Home, Explore's mood pages and the like while the first page of shelves loads.
struct FeedSkeleton: View {
    var shelves = 3
    var firstIsHero = true
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if firstIsHero {
                HeroShelfSkeleton(width: width)
                ForEach(1..<shelves, id: \.self) { ShelfCardsSkeleton(index: $0) }
            } else {
                ForEach(0..<shelves, id: \.self) { ShelfCardsSkeleton(index: $0) }
            }
        }
        .accessibilityHidden(true)
    }
}
