import VibraMusicCore
import Canvas
import SwiftUI
import Theming

// The pieces of ui/screens/DetailScreen.kt both page kinds share: the artwork backdrop and the
// glass across its foot, the circular action buttons and the white Play pill, the About block,
// section headings, and the three kinds of track row (full, compact, suggested).

extension ArtworkPalette {
    var backgroundColor: Color { background.color }
    var washColor: Color { wash.color }
    var accentColor: Color { accent.color }
    var onBackgroundColor: Color { onBackground.color }
    var onBackgroundVariantColor: Color { onBackgroundVariant.color }
    var dividerColor: Color { divider.color }
    var elevatedColor: Color { elevated.color }
}

/// How far past the foot of the artwork the title block hangs, so it sits on the blurred colour
/// rather than on whatever the bottom of the sleeve is busy with (DetailScreen.kt's HEADER_DROP).
let detailHeaderDrop: CGFloat = 44

/// The artwork's height: the page's width over the ratio, capped at 60% of the page so a wide
/// window doesn't get a hero taller than itself.
func detailArtHeight(size: CGSize, isArtist: Bool) -> CGFloat {
    let ratio: CGFloat = isArtist ? 0.95 : 0.92
    return min(size.width / ratio, size.height * 0.6)
}

/// The track list's bottom inset, so the last rows scroll clear of the tab bar and the mini
/// player (MainActivity's `listPadding.bottom`: 210 dp with something playing, 140 dp without).
/// The scroll view's own safe-area inset already covers what the system reports it covers; the
/// rest of Android's inset is added on top of it.
func detailBottomInset(bottomInset: CGFloat, isPlaying: Bool) -> CGFloat {
    max(0, (isPlaying ? 210 : 140) - bottomInset)
}

/// `detailBottomInset` for a page that isn't laid out in a GeometryReader of its own (the Library,
/// Show all, History, an artist): MainActivity hands every one of them the same `listPadding`, so
/// their last card or row scrolls clear of the mini player and the tab bar too. Reads the scroll
/// view's reported bottom inset and adds the rest of Android's as a content margin.
struct CollectionsListBottomInset: ViewModifier {
    @Environment(PlayerController.self) private var player
    @State private var reported: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { reported = $0 }
            .contentMargins(.bottom, detailBottomInset(bottomInset: reported, isPlaying: player.currentSong != nil),
                            for: .scrollContent)
    }
}

extension View {
    func collectionsListBottomInset() -> some View { modifier(CollectionsListBottomInset()) }
}

/// The page wash (ArtworkBackdrop.kt's ArtworkWash): the wash colour down to where the artwork
/// stops, easing into the page background below, with two faint lobes of the accent and the
/// elevated colour just under the sleeve.
struct ArtworkWash: View {
    let palette: ArtworkPalette
    var washFraction: CGFloat = 0.62

    var body: some View {
        GeometryReader { proxy in
            let wash = palette.wash
            let background = palette.background
            ZStack {
                LinearGradient(stops: [
                    .init(color: wash.color, location: 0),
                    .init(color: wash.color, location: washFraction),
                    .init(color: wash.mixed(with: background, fraction: 0.12).color, location: washFraction + (1 - washFraction) * 0.35),
                    .init(color: wash.mixed(with: background, fraction: 0.55).color, location: washFraction + (1 - washFraction) * 0.70),
                    .init(color: background.color, location: 1),
                ], startPoint: .top, endPoint: .bottom)
                // Centred in place rather than offset, so no lobe is cut off by its own frame.
                RadialGradient(colors: [palette.accent.withAlpha(0.13).color, .clear],
                               center: UnitPoint(x: 0.12, y: washFraction + 0.08), startRadius: 0,
                               endRadius: proxy.size.width * 0.8)
                RadialGradient(colors: [palette.elevated.withAlpha(0.30).color, .clear],
                               center: UnitPoint(x: 0.96, y: washFraction + 0.30), startRadius: 0,
                               endRadius: proxy.size.width * 0.95)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// The artwork across the top of the page, settled onto the wash at its foot, with one pane of
/// glass laid across the join (DetailScreen.kt's PageBackground + MergeBand). The blur samples both
/// sides of the join so the sleeve and the page read as one surface; with "Reduce dynamic blur" on,
/// only the gradient settles the foot, as on Android.
struct DetailArtworkHeaderBackground: View {
    let artwork: String?
    let palette: ArtworkPalette
    let artHeight: CGFloat
    let reduceBlur: Bool
    /// An album's looping clip: above the still art, below the gradient that settles it onto the
    /// page. Always running — there is no transport here to follow, and the page is only up while
    /// it is being read.
    var canvas: CanvasArtwork?

    var body: some View {
        GeometryReader { proxy in
            let minY = proxy.frame(in: .global).minY
            let pull = max(minY, 0)
            ZStack(alignment: .top) {
                art
                    .frame(height: artHeight + pull)
                    .offset(y: -pull)
                    .overlay {
                        if let canvas {
                            PlayerCanvasView(canvas: canvas, isPlaying: true)
                                .accessibilityIdentifier("detail.canvas")
                        }
                    }
                    .overlay {
                        LinearGradient(stops: [
                            .init(color: .clear, location: 0.55),
                            .init(color: palette.wash.withAlpha(0.88).color, location: 1),
                        ], startPoint: .top, endPoint: .bottom)
                    }
                    .clipped()
                if !reduceBlur {
                    // The merge band: centred on the artwork's foot, arriving from nothing and leaving
                    // to nothing so it has no edge of its own.
                    art
                        .frame(height: artHeight + pull)
                        .offset(y: -pull)
                        .blur(radius: 40, opaque: true)
                        .overlay(palette.wash.withAlpha(0.35).color)
                        .frame(height: 220, alignment: .bottom)
                        .clipped()
                        .mask(LinearGradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.5),
                            .init(color: .clear, location: 1),
                        ], startPoint: .top, endPoint: .bottom))
                        .offset(y: artHeight - 110)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: artHeight + detailHeaderDrop, alignment: .top)
        .accessibilityHidden(true)
    }

    private var art: some View {
        GeometryReader { proxy in
            ArtworkImage(artwork, pixels: ArtworkSize.header, cornerRadius: 0)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
        }
    }
}

/// A small circular icon button over glass (DetailScreen.kt's CircleIconButton): Shuffle, Search,
/// More, and the save / subscribe toggle.
struct CircleIconButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 50
    var haptic: Haptic = .tap
    var identifier: String?
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.shared.play(haptic)
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier ?? "")
    }
}

/// The Play control (DetailScreen.kt's PlayPill): a fixed white surface with black content so the
/// primary action survives every palette. Releases use the icon-only circle; the artist keeps the
/// labelled pill.
struct PlayPill: View {
    var iconOnly = false
    var size: CGFloat = 50
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.shared.play(.resume)
            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: AppSymbol.play)
                    .font(.system(size: iconOnly ? size * 0.4 : 17, weight: .bold))
                if !iconOnly {
                    Text(L10n.play).font(CollectionsType.title)
                }
            }
            .foregroundStyle(.black)
            .frame(width: iconOnly ? size : nil, height: size)
            .padding(.horizontal, iconOnly ? 0 : 32)
            .background(Color.white, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.play)
        .accessibilityIdentifier("detail.play")
    }
}

/// A section heading on a page, in the page's colours (DetailScreen.kt's SectionHeading).
struct DetailSectionHeading: View {
    let title: String
    let palette: ArtworkPalette
    var onShowAll: (() -> Void)?

    var body: some View {
        HStack {
            Text(title)
                .font(CollectionsType.headline)
                .foregroundStyle(palette.onBackgroundColor)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            if let onShowAll {
                Button(L10n.showAll, action: onShowAll)
                    .font(CollectionsType.titleSmall)
                    .foregroundStyle(palette.accentColor)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("showAll")
            }
        }
        .padding(.horizontal, CollectionsMetrics.gutter)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}

/// YouTube's editorial note, collapsed to three lines with a tap to read the rest
/// (DetailScreen.kt's AboutSection). "More" only appears once the collapsed text is measured to
/// have lost something, so a two-line bio has no toggle with nothing behind it.
struct AboutSection: View {
    let title: String
    let text: String
    let palette: ArtworkPalette

    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var clippedHeight: CGFloat = 0

    private var clipped: Bool { fullHeight > clippedHeight + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(CollectionsType.title)
                .foregroundStyle(palette.onBackgroundColor)
                .padding(.top, 2)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            Text(text)
                .font(CollectionsType.body.weight(.medium))
                .foregroundStyle(palette.onBackgroundVariantColor)
                .lineLimit(expanded ? nil : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .topLeading) { measurements }
                .contentShape(Rectangle())
                .onTapGesture { if clipped || expanded { toggle() } }
            if clipped || expanded {
                Button(expanded ? L10n.less : L10n.more, action: toggle)
                    .font(CollectionsType.label)
                    .foregroundStyle(palette.accentColor)
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
            }
        }
        .padding(.horizontal, CollectionsMetrics.aboutGutter)
        .accessibilityIdentifier("detail.about")
    }

    private func toggle() {
        withAnimation(.easeInOut(duration: 0.25)) { expanded.toggle() }
    }

    /// The text laid out twice, invisibly — whole and at three lines — to learn whether the
    /// collapsed copy hides anything.
    private var measurements: some View {
        ZStack(alignment: .topLeading) {
            Text(text).font(CollectionsType.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { Color.clear.preference(key: FullHeightKey.self, value: $0.size.height) })
            Text(text).font(CollectionsType.body.weight(.medium)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { Color.clear.preference(key: ClippedHeightKey.self, value: $0.size.height) })
        }
        .hidden()
        .onPreferenceChange(FullHeightKey.self) { fullHeight = $0 }
        .onPreferenceChange(ClippedHeightKey.self) { clippedHeight = $0 }
        .accessibilityHidden(true)
    }

    private struct FullHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    private struct ClippedHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
}

/// One track on a page or list (Common.kt's SongRow): the artwork or, on an album, the sleeve's own
/// track number; the title (accent while it's the current track); artist and download format; the
/// downloaded tick; the now-playing glyph; the duration; and the ⋮ menu. Tap plays, hold or ⋮ opens
/// the song menu, a sideways swipe queues it.
struct CollectionsSongRow: View {
    let song: Song
    var trackNumber: Int?
    var subtitleColor: Color = .secondary
    var titleColor: Color = .primary
    /// Nil leaves downloaded rows unmarked (a page that is itself a reading of this device).
    var downloadedTint: Color? = .accentColor
    var activeTint: Color = .accentColor
    var swipeToQueue = true
    let onTap: () -> Void
    let onMore: () -> Void

    @Environment(PlayerController.self) private var player

    var body: some View {
        let isCurrent = player.currentSong?.isSameTrackAs(song) == true
        let isPlaying = isCurrent && player.isPlaying
        HStack(spacing: 0) {
            leading(isCurrent: isCurrent, isPlaying: isPlaying)
            VStack(alignment: .leading, spacing: 2) {
                ExplicitSongTitle(song: song, font: CollectionsType.title, color: isCurrent ? activeTint : titleColor)
                Text([song.artist.isEmpty ? nil : song.artist, song.downloadFormat].compactMap { $0 }.joined(separator: " · "))
                    .font(CollectionsType.bodySmall)
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
            }
            .padding(.leading, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let downloadedTint {
                DownloadedBadge(videoId: song.videoId, tint: downloadedTint)
            }
            if isCurrent && trackNumber == nil {
                nowPlayingGlyph(isPlaying: isPlaying, size: 20)
                    .padding(.leading, 8)
            }
            if let duration = song.durationText, !duration.isEmpty {
                Text(duration)
                    .font(CollectionsType.label.weight(.medium).monospacedDigit())
                    .foregroundStyle(subtitleColor)
                    .padding(.leading, 8)
            }
            Button {
                Haptics.shared.play(.tap)
                onMore()
            } label: {
                Image(systemName: AppSymbol.more)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.more)
        }
        .padding(.horizontal, CollectionsMetrics.gutter)
        .padding(.vertical, 4)
        .background(isCurrent ? activeTint.opacity(0.14) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onLongPressGesture(minimumDuration: 0.4) {
            Haptics.shared.play(.tap)
            onMore()
        }
        .modifier(SwipeToQueue(enabled: swipeToQueue, playNext: player.settings.swipeToPlayNext) {
            player.queueFromSwipe(song)
        })
        .animation(.easeInOut(duration: 0.2), value: isCurrent)
        .modifier(SongRowAccessibility(song: song, isCurrent: isCurrent, onTap: onTap, onMore: onMore))
        .accessibilityAction(named: Text(player.settings.swipeToPlayNext ? L10n.playNext : L10n.addToQueue)) {
            player.queueFromSwipe(song)
        }
    }

    @ViewBuilder
    private func leading(isCurrent: Bool, isPlaying: Bool) -> some View {
        if let trackNumber {
            ZStack {
                if isCurrent {
                    nowPlayingGlyph(isPlaying: isPlaying, size: 22)
                } else {
                    Text("\(trackNumber)")
                        .font(CollectionsType.body.monospacedDigit())
                        .foregroundStyle(subtitleColor)
                }
            }
            .frame(width: 52, height: 52)
        } else {
            ArtworkImage(song: song, pixels: ArtworkSize.row, cornerRadius: AppTheme.artCorner)
                .artworkFrame(52, cornerRadius: AppTheme.artCorner)
        }
    }

    private func nowPlayingGlyph(isPlaying: Bool, size: CGFloat) -> some View {
        Image(systemName: isPlaying ? "waveform" : AppSymbol.play)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(activeTint)
            .symbolEffect(.variableColor.iterative, isActive: isPlaying)
            .accessibilityLabel(L10n.nowPlaying)
    }
}

/// The compact row of an artist's song grid (DetailScreen.kt's CompactSongRow): no swipe, so the
/// sideways pager's gesture stays unambiguous.
struct CompactSongRow: View {
    let song: Song
    let palette: ArtworkPalette
    let onTap: () -> Void
    let onMore: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ArtworkImage(song: song, pixels: ArtworkSize.row, cornerRadius: 7)
                .artworkFrame(48, cornerRadius: 7)
            VStack(alignment: .leading, spacing: 0) {
                ExplicitSongTitle(song: song, font: CollectionsType.title, color: palette.onBackgroundColor)
                Text(song.artist)
                    .font(CollectionsType.bodySmall)
                    .foregroundStyle(palette.onBackgroundVariantColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            DownloadedBadge(videoId: song.videoId, tint: palette.accentColor)
            Button {
                Haptics.shared.play(.tap)
                onMore()
            } label: {
                Image(systemName: AppSymbol.more)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.onBackgroundVariantColor)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.more)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onLongPressGesture(minimumDuration: 0.4) {
            Haptics.shared.play(.tap)
            onMore()
        }
        .modifier(SongRowAccessibility(song: song, isCurrent: false, onTap: onTap, onMore: onMore))
    }
}

/// A track row as one VoiceOver element named by its song (``DetailText/songRowLabel(_:)``): the
/// title first, so neither the sleeve number nor the now-playing glyph leads; activating plays it,
/// and the ⋮ menu is a named action.
struct SongRowAccessibility: ViewModifier {
    let song: Song
    let isCurrent: Bool
    let onTap: () -> Void
    let onMore: () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(DetailText.songRowLabel(song))
            .accessibilityValue(isCurrent ? L10n.nowPlaying : "")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("songRow")
            .accessibilityAction { onTap() }
            .accessibilityAction(named: Text(L10n.more), onMore)
    }
}

/// A row under "Suggested" (DetailScreen.kt's SuggestedSongRow): the trailing spot a track on the
/// playlist spends on ⋮ goes to adding this one, the point of the row.
struct SuggestedSongRow: View {
    let song: Song
    let palette: ArtworkPalette
    let onTap: () -> Void
    let onMore: () -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ArtworkImage(song: song, pixels: ArtworkSize.row, cornerRadius: AppTheme.artCorner)
                .artworkFrame(52, cornerRadius: AppTheme.artCorner)
            VStack(alignment: .leading, spacing: 2) {
                ExplicitSongTitle(song: song, font: CollectionsType.title, color: palette.onBackgroundColor)
                Text(song.artist)
                    .font(CollectionsType.bodySmall)
                    .foregroundStyle(palette.onBackgroundVariantColor)
                    .lineLimit(1)
            }
            .padding(.leading, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            DownloadedBadge(videoId: song.videoId, tint: palette.accentColor)
            Button {
                Haptics.shared.play(.toggleOn)
                onAdd()
            } label: {
                Image(systemName: AppSymbol.plus)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(palette.accentColor)
                    .frame(width: 36, height: 36)
                    .background(palette.accent.withAlpha(0.16).color, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
            .accessibilityLabel(L10n.addToPlaylist)
            .accessibilityIdentifier("suggested.add")
        }
        .padding(.horizontal, CollectionsMetrics.gutter)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onLongPressGesture(minimumDuration: 0.4) {
            Haptics.shared.play(.tap)
            onMore()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(L10n.addToPlaylist), onAdd)
        .accessibilityAction(named: Text(L10n.more), onMore)
    }
}

/// An album card on an artist page (DetailScreen.kt's SectionCard).
struct SectionCard: View {
    let item: ShelfItem
    let palette: ArtworkPalette
    var width: CGFloat? = CollectionsMetrics.shelfCardWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    ArtworkImage(item.thumbnailUrl, pixels: ArtworkSize.card, cornerRadius: 10)
                }
                .background(palette.elevatedColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(item.title)
                .font(CollectionsType.title)
                .foregroundStyle(palette.onBackgroundColor)
                .lineLimit(1)
                .padding(.top, 8)
            Text(item.subtitle)
                .font(CollectionsType.bodySmall)
                .foregroundStyle(palette.onBackgroundVariantColor)
                .lineLimit(1)
        }
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// A thin divider inset past a row's artwork, in the page's colour.
struct RowDivider: View {
    var color: Color = Color(.separator)

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: 0.5)
            .padding(.leading, CollectionsMetrics.rowDividerInset)
            .accessibilityHidden(true)
    }
}

extension View {
    /// A square cover at a fixed size, clipped to its rounded shape (Compose's `size` + `clip`).
    func artworkFrame(_ side: CGFloat, cornerRadius: CGFloat) -> some View {
        frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
