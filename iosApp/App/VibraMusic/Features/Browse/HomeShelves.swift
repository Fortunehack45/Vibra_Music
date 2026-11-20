import VibraMusicCore
import SwiftUI

// Ports the shelf composables of ui/screens/HomeScreen.kt: SectionHeader, RecentShelf (with its
// list / grid toggle), HeroShelf + HeroCard, Shelf + ShelfCard. Explore's mood pages reuse
// HomeShelfRow and BrowseSectionHeader, as Android reuses Shelf and SectionHeader.

/// `SectionHeader`: a shelf's heading and strapline, both in the app's language where known.
struct BrowseSectionHeader: View {
    let title: String
    var subtitle: String = ""
    /// Only Recents carries a trailing control (its layout toggle).
    var trailing: AnyView?

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(ShelfLocalization.title(title))
                    .font(BrowseFont.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                let strapline = ShelfLocalization.subtitle(subtitle)
                if !strapline.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(strapline)
                        .font(BrowseFont.title)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let trailing { trailing }
        }
        .padding(.horizontal, BrowseMetrics.gutter)
        .padding(.vertical, 10)
    }
}

/// `Shelf`: a heading over a sideways row of square cards.
struct HomeShelfRow: View {
    let shelf: HomeShelf
    let onOpen: (ShelfItem) -> Void
    /// Nil where a card has nothing behind it to act on (Explore's mood pages).
    var onMenu: ((ShelfItem) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrowseSectionHeader(title: shelf.title, subtitle: shelf.subtitle)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: BrowseMetrics.cardSpacing) {
                    ForEach(Array(shelf.items.enumerated()), id: \.offset) { index, item in
                        HomeShelfCard(item: item)
                            .cardGestures(item: item, onOpen: onOpen, onMenu: onMenu)
                            .prefetchingCovers(after: index, in: shelf.items, ahead: 6, pixels: ArtworkSize.card) { [$0.thumbnailUrl] }
                    }
                }
                .padding(.horizontal, BrowseMetrics.gutter)
            }
            .scrollClipDisabled()
        }
        .padding(.bottom, BrowseMetrics.shelfBottom)
    }
}

extension View {
    /// When this shelf appears, starts loading the first cards of the two shelves below it, so a
    /// shelf scrolled up into view has its covers (a sideways row's cards warm each other).
    func prefetchingShelfCovers(after index: Int, in shelves: [HomeShelf]) -> some View {
        prefetchingCovers(after: index, in: shelves, ahead: 2, pixels: ArtworkSize.card) {
            $0.items.prefix(6).map(\.thumbnailUrl)
        }
    }
}

/// `ShelfCard`: square artwork, one-line title, one-line subtitle.
struct HomeShelfCard: View {
    let item: ShelfItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CroppedArtwork(raw: item.thumbnailUrl, pixels: ArtworkSize.card, width: BrowseMetrics.shelfCardWidth, cornerRadius: 12)
            Text(item.title)
                .font(BrowseFont.title)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.top, 10)
            Text(ShelfLocalization.cardSubtitle(item.subtitle))
                .font(BrowseFont.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: BrowseMetrics.shelfCardWidth, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("shelfCard")
    }
}

/// `HeroShelf`: the lead shelf's big cards, 70% of the page wide so the next one peeks in.
struct HeroShelf: View {
    let shelf: HomeShelf
    let width: CGFloat
    let onOpen: (ShelfItem) -> Void
    var onMenu: ((ShelfItem) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrowseSectionHeader(title: shelf.title, subtitle: shelf.subtitle)
            HeroCardsRow(items: shelf.items, width: width, onOpen: onOpen, onMenu: onMenu)
        }
        .padding(.bottom, BrowseMetrics.shelfBottom)
    }
}

private struct HeroCardsRow: View {
    let items: [ShelfItem]
    let width: CGFloat
    let onOpen: (ShelfItem) -> Void
    var onMenu: ((ShelfItem) -> Void)?

    var body: some View {
        let cardWidth = BrowseMetrics.heroCardWidth(width)
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: BrowseMetrics.cardSpacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HeroCard(item: item, width: cardWidth)
                        .cardGestures(item: item, onOpen: onOpen, onMenu: onMenu)
                        .prefetchingCovers(after: index, in: items, ahead: 2, pixels: ArtworkSize.header) { [$0.thumbnailUrl] }
                }
            }
            .padding(.horizontal, BrowseMetrics.gutter)
        }
        .scrollClipDisabled()
    }
}

/// `HeroCard`: artwork with the caption laid over a dark scrim, as on Apple Music's Listen Now.
struct HeroCard: View {
    let item: ShelfItem
    let width: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        // The artwork is square and the card isn't: it fills the card's own frame and is cropped
        // to it, rather than sizing the card.
        Color.clear
            .frame(width: width, height: width / BrowseMetrics.heroCardRatio)
            .overlay { ArtworkImage(item.thumbnailUrl, pixels: ArtworkSize.header, cornerRadius: 0) }
            .overlay(alignment: .bottomLeading) { caption }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .contentShape(shape)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("heroCard")
    }

    private var caption: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(BrowseFont.titleLarge)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !item.subtitle.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(ShelfLocalization.cardSubtitle(item.subtitle))
                        .font(BrowseFont.body)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 34)
            .padding(.bottom, 14)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .top, endPoint: .bottom))
    }
}

/// `RecentShelf`: the listener's history, as four-track columns scrolling sideways (the artist
/// page's Top songs treatment) or as big cards; the heading's button flips between the two and
/// the choice is remembered.
struct RecentShelf: View {
    let shelf: HomeShelf
    let width: CGFloat
    let onOpen: (ShelfItem) -> Void
    var onMenu: ((ShelfItem) -> Void)?

    @Environment(AppSettings.self) private var settings
    private static let tracksPerColumn = 4

    var body: some View {
        let isList = settings.homeRecentsViewType == .list
        VStack(alignment: .leading, spacing: 0) {
            BrowseSectionHeader(title: shelf.title, subtitle: shelf.subtitle, trailing: AnyView(toggle(isList: isList)))
            if isList {
                let columnWidth = BrowseMetrics.trackColumnWidth(width)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                            VStack(spacing: 0) {
                                ForEach(Array(column.enumerated()), id: \.offset) { _, item in
                                    RecentTrackRow(item: item, onOpen: onOpen, onMenu: onMenu)
                                }
                            }
                            .frame(width: columnWidth, alignment: .top)
                        }
                    }
                    .padding(.horizontal, BrowseMetrics.gutter)
                }
                // A free-scrolling row, as HomeScreen.kt's plain LazyRow (no snapping).
                .scrollClipDisabled()
            } else {
                HeroCardsRow(items: shelf.items, width: width, onOpen: onOpen, onMenu: onMenu)
            }
        }
        .padding(.bottom, BrowseMetrics.shelfBottom)
    }

    private var columns: [[ShelfItem]] {
        stride(from: 0, to: shelf.items.count, by: Self.tracksPerColumn).map {
            Array(shelf.items[$0..<min($0 + Self.tracksPerColumn, shelf.items.count)])
        }
    }

    private func toggle(isList: Bool) -> some View {
        Button {
            Haptics.shared.play(.select)
            settings.homeRecentsViewType = isList ? .grid : .list
        } label: {
            Image(systemName: isList ? AppSymbol.gridView : AppSymbol.listView)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isList ? L10n.switchToGridView : L10n.switchToListView)
        .accessibilityIdentifier("home.recentsLayout")
    }
}

/// `RecentTrackRow`: a compact track row with a More button (the long-press menu).
private struct RecentTrackRow: View {
    let item: ShelfItem
    let onOpen: (ShelfItem) -> Void
    var onMenu: ((ShelfItem) -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            CroppedArtwork(raw: item.thumbnailUrl, pixels: ArtworkSize.row, width: 48, cornerRadius: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                    .font(BrowseFont.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(BrowseFont.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let onMenu {
                Button {
                    onMenu(item)
                } label: {
                    Image(systemName: AppSymbol.more)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.more)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { onOpen(item) }
        .onLongPressGesture(minimumDuration: 0.4) { onMenu?(item) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen(item) }
        .accessibilityActions {
            if let onMenu, item.hasCardMenu {
                Button(L10n.more) { onMenu(item) }
            }
        }
        .accessibilityIdentifier("recentTrack")
    }
}

extension View {
    /// Tap opens a card; holding it (Android's `combinedClickable` long click) opens its menu.
    func cardGestures(item: ShelfItem, onOpen: @escaping (ShelfItem) -> Void, onMenu: ((ShelfItem) -> Void)?) -> some View {
        self
            .contentShape(Rectangle())
            .onTapGesture { onOpen(item) }
            .onLongPressGesture(minimumDuration: 0.4) { onMenu?(item) }
            .accessibilityAction { onOpen(item) }
            .accessibilityActions {
                // Only where holding the card opens something: not on a mood page's cards, and
                // not on an artist (MainActivity's onBrowseLongPress skips artists).
                if let onMenu, item.hasCardMenu {
                    Button(L10n.more) { onMenu(item) }
                }
            }
    }
}

extension ShelfItem {
    /// Whether holding the card opens a menu: a track's, or an album's / playlist's (never an
    /// artist's), as BrowseNavigator.openCardMenu decides.
    var hasCardMenu: Bool {
        if shelfSong != nil { return true }
        guard let page = shelfBrowseItem else { return false }
        return page.type != .artist
    }
}
