import VibraMusicCore
import PlaybackQueue
import SwiftUI

// Ports the shelf pieces of ui/components/Common.kt: section headers, horizontally scrolling
// shelves of cards, and the card itself.

/// A section title with an optional trailing action ("Show all").
struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(AppTheme.Typeface.label)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
                Text(title)
                    .font(AppTheme.Typeface.headline)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 8)
            if let action {
                Button {
                    Haptics.shared.play(.tap)
                    action()
                } label: {
                    HStack(spacing: 2) {
                        Text(actionTitle ?? L10n.showAll)
                        Image(systemName: AppSymbol.chevronRight).font(.caption.weight(.bold))
                    }
                    .font(AppTheme.Typeface.bodySmall.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, AppTheme.gutter)
    }
}

/// What a shelf card stands for, and what tapping it does.
enum ShelfCardAction {
    case play(Song)
    case open(AppRoute)
}

extension ShelfItem {
    /// A card that plays a song, or opens a page (a shelf mixes both).
    var cardAction: ShelfCardAction? {
        if let videoId, !videoId.isEmpty {
            return .play(Song(videoId: videoId, title: title, artist: subtitle, thumbnailUrl: thumbnailUrl))
        }
        if let browseId, !browseId.isEmpty {
            let item = BrowseItem(browseId: browseId, title: title, subtitle: subtitle, thumbnailUrl: thumbnailUrl,
                                  type: BrowseType.of(browseId: browseId))
            return .open(AppRoute.item(item))
        }
        return nil
    }

    var browseItem: BrowseItem? {
        guard let browseId, !browseId.isEmpty else { return nil }
        return BrowseItem(browseId: browseId, title: title, subtitle: subtitle, thumbnailUrl: thumbnailUrl, type: BrowseType.of(browseId: browseId))
    }
}

/// A square card: artwork, title, subtitle. Artist cards are round.
struct ShelfCard: View {
    let title: String
    var subtitle: String?
    let artwork: String?
    var isCircular = false
    var width: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkImage(artwork, pixels: ArtworkSize.card, cornerRadius: isCircular ? width / 2 : 10)
                .frame(width: width, height: width)
            Text(title)
                .font(AppTheme.Typeface.bodySmall.weight(.semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: isCircular ? .center : .leading)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(AppTheme.Typeface.label.weight(.regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: isCircular ? .center : .leading)
            }
        }
        .frame(width: width)
        .multilineTextAlignment(isCircular ? .center : .leading)
    }
}

/// A titled shelf of cards scrolling sideways (Home, Explore, artist pages). Tapping a song card
/// plays it; a page card opens it; long-press opens the matching actions sheet.
struct ShelfCarousel: View {
    let shelf: HomeShelf
    var source: PlaybackSourceType = .home
    var onShowAll: (() -> Void)?

    @Environment(PlayerController.self) private var player
    @Environment(AppRouter.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: shelf.title, subtitle: shelf.subtitle, action: onShowAll)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(Array(shelf.items.enumerated()), id: \.offset) { _, item in
                        card(item)
                    }
                }
                .padding(.horizontal, AppTheme.gutter)
            }
            .scrollClipDisabled()
        }
    }

    private func card(_ item: ShelfItem) -> some View {
        let isArtist = item.browseId.map { BrowseType.of(browseId: $0) == .artist } ?? false
        return ShelfCard(title: item.title, subtitle: item.subtitle, artwork: item.thumbnailUrl, isCircular: isArtist)
            .contentShape(Rectangle())
            .onTapGesture { tap(item) }
            .onLongPressGesture(minimumDuration: 0.4) {
                Haptics.shared.play(.tap)
                switch item.cardAction {
                case .play(let song): router.present(.songActions(song))
                case .open:
                    if let browse = item.browseItem { router.present(.browseActions(browse)) }
                case nil: break
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("shelfCard")
    }

    private func tap(_ item: ShelfItem) {
        switch item.cardAction {
        case .play(let song):
            // Songs from a shelf play with the rest of the shelf's songs as context.
            let songs = shelf.items.compactMap { entry -> Song? in
                if case .play(let s) = entry.cardAction { return s }
                return nil
            }
            let index = songs.firstIndex { $0.videoId == song.videoId } ?? 0
            player.play(songs, startAt: index, source: QueueSource(title: shelf.title, type: source))
        case .open(let route):
            router.open(route)
        case nil:
            break
        }
    }
}
