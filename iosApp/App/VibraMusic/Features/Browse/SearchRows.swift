import VibraMusicCore
import SwiftUI

// The rows of ui/screens/SearchScreen.kt: SearchFilterTabs, SuggestionRow, TypeaheadSongRow,
// BrowseRow, RecentSearchEntityRow and TopResultCard. (Song hits use the shared SongRow.)

/// `SearchFilterTabs`: squarish pills scrolling sideways, the selected one inverted.
struct SearchFilterPills: View {
    let filter: SearchFilter
    let onChange: (SearchFilter) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchFilter.allCases) { entry in
                    let selected = entry == filter
                    Button {
                        // Re-tapping the current filter changes nothing, so it doesn't buzz.
                        if !selected { Haptics.shared.play(.select) }
                        onChange(entry)
                    } label: {
                        Text(BrowseStrings.filterLabel(entry))
                            .font(BrowseFont.label)
                            .lineLimit(1)
                            .foregroundStyle(selected ? Color(.systemBackground) : Color.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                selected ? Color.primary : Color(.secondarySystemFill),
                                // Rounded, but well short of a capsule.
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                    .accessibilityIdentifier("search.filter.\(entry.rawValue)")
                }
            }
            .padding(.horizontal, BrowseMetrics.gutter)
            .padding(.vertical, 6)
        }
    }
}

/// `SuggestionRow`: tap the text to search it, or the arrow to put it in the field and keep typing.
struct SuggestionRow: View {
    let term: String
    let onSearch: () -> Void
    let onFill: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: AppSymbol.search)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(term)
                .font(BrowseFont.title)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onFill) {
                // The arrow points up and back toward the field, mirrored in right-to-left.
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .flipsForRightToLeftLayoutDirection(true)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.recentSearchEdit(term))
        }
        .padding(.leading, BrowseMetrics.gutter)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSearch)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text(L10n.search), onSearch)
        .accessibilityIdentifier("search.suggestion")
    }
}

/// `TypeaheadSongRow`: a live hit under the completions. Tap plays; holding opens the song menu.
struct TypeaheadSongRow: View {
    let song: Song
    let onTap: () -> Void
    let onMenu: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            CroppedArtwork(raw: song.thumbnailUrl, pixels: ArtworkSize.row, width: 48)
            VStack(alignment: .leading, spacing: 2) {
                ExplicitSongTitle(song: song, font: BrowseFont.title)
                Text(song.artist)
                    .font(BrowseFont.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, BrowseMetrics.gutter)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onLongPressGesture(minimumDuration: 0.4) {
            Haptics.shared.play(.tap)
            onMenu()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(L10n.more), onMenu)
        .accessibilityIdentifier("songRow")
    }
}

/// `BrowseRow`: an album, playlist or artist (artists round).
struct BrowseResultRow: View {
    let item: BrowseItem
    let onTap: () -> Void
    let onMenu: (() -> Void)?

    var body: some View {
        let isArtist = item.type == .artist
        HStack(spacing: 12) {
            CroppedArtwork(raw: item.thumbnailUrl, pixels: ArtworkSize.row, width: 48, cornerRadius: isArtist ? 24 : AppTheme.artCorner,
                           placeholderSymbol: isArtist ? AppSymbol.artist : AppSymbol.album)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(BrowseFont.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(item.subtitle.trimmingCharacters(in: .whitespaces).isEmpty ? Self.typeLabel(item.type) : item.subtitle)
                    .font(BrowseFont.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, BrowseMetrics.gutter)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onLongPressGesture(minimumDuration: 0.4) {
            guard let onMenu else { return }
            Haptics.shared.play(.tap)
            onMenu()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("browseRow")
    }

    /// The type as a word, for a row YouTube sent without a subtitle.
    static func typeLabel(_ type: BrowseType) -> String {
        switch type {
        case .album: return L10n.album
        case .artist: return L10n.artist
        case .playlist: return L10n.playlist
        case .other: return BrowseStrings.sectionMore
        }
    }
}

/// `RecentSearchEntityRow`: what was tapped before, with a button to forget it.
struct RecentSearchRow: View {
    let entity: SearchHistoryEntity
    let onTap: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            CroppedArtwork(raw: entity.artworkUrl, pixels: ArtworkSize.row, width: 48,
                           cornerRadius: entity.entityType == .artist ? 24 : AppTheme.artCorner,
                           placeholderSymbol: entity.entityType == .artist ? AppSymbol.artist : AppSymbol.musicNote)
            VStack(alignment: .leading, spacing: 2) {
                Text(entity.title)
                    .font(BrowseFont.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(entity.subtitle.trimmingCharacters(in: .whitespaces).isEmpty ? Self.typeLabel(entity.entityType) : entity.subtitle)
                    .font(BrowseFont.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: AppSymbol.close)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.recentSearchRemove(entity.title))
            .accessibilityIdentifier("search.recent.remove")
        }
        .padding(.leading, BrowseMetrics.gutter)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search.recent")
    }

    static func typeLabel(_ type: SearchHistoryEntity.EntityType) -> String {
        switch type {
        case .track: return L10n.shelfSongItem
        case .album: return L10n.album
        case .artist: return L10n.artist
        case .playlist: return L10n.playlist
        }
    }
}

/// `TopResultCard`: the unfiltered search's promoted hit, with Play and Playlist.
struct TopResultCard: View {
    let song: Song
    let onPlay: () -> Void
    let onPlaylist: () -> Void
    let onMenu: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(BrowseStrings.topResult)
                .font(BrowseFont.label)
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 14) {
                CroppedArtwork(raw: song.thumbnailUrl, pixels: ArtworkSize.row, width: 72, cornerRadius: 10)
                VStack(alignment: .leading, spacing: 4) {
                    Text(song.title)
                        .font(BrowseFont.titleLarge)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(song.artist)
                        .font(BrowseFont.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                Button(action: onMenu) {
                    Image(systemName: AppSymbol.more)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.more)
            }
            .padding(.top, 10)
            HStack(spacing: 10) {
                Button(action: onPlay) {
                    Label(L10n.play, systemImage: AppSymbol.play)
                }
                .accessibilityIdentifier("search.topResult.play")
                Button(action: onPlaylist) {
                    Label(L10n.playlistAction, systemImage: AppSymbol.playlistAdd)
                }
                .accessibilityIdentifier("search.topResult.playlist")
            }
            .buttonStyle(OutlinedButtonStyle())
            .padding(.top, 12)
        }
        .padding(.horizontal, BrowseMetrics.gutter)
        .padding(.top, 18)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
        .onLongPressGesture(minimumDuration: 0.4) {
            Haptics.shared.play(.tap)
            onMenu()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search.topResult")
    }
}

/// Material's `OutlinedButton`: a capsule outline around icon and label. iOS has no outlined
/// button style of its own; this is the nearest drawing of it.
private struct OutlinedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BrowseFont.label)
            .foregroundStyle(.primary)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
