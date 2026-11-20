import VibraMusicCore
import SwiftUI
import Theming

// The shared pieces of the Collections screens: the type scale (Dynamic Type text styles standing
// in for Theme.kt's fixed sizes), the artwork palette reader, and the Android widgets the Library,
// the pages and the sheets all draw — SectionHeader, ShelfCard, NewShelfCard, MessageState and
// DownloadedBadge (ui/screens/HomeScreen.kt, ui/components/Common.kt).

/// Theme.kt's type scale as text styles, so every Collections screen follows Dynamic Type.
enum CollectionsType {
    /// displayLarge — the Library title, an artist's name.
    static let display = Font.largeTitle.weight(.heavy)
    /// headlineMedium — shelf headings, a release's title.
    static let headline = Font.title2.weight(.bold)
    /// titleLarge — sheet panel titles.
    static let titleLarge = Font.title3.weight(.bold)
    /// titleMedium — row titles, card titles, the credit line.
    static let title = Font.callout.weight(.semibold)
    /// titleSmall — "Show all".
    static let titleSmall = Font.subheadline.weight(.semibold)
    /// bodyLarge — menu rows, the About text.
    static let body = Font.body
    /// bodyMedium — subtitles.
    static let bodySmall = Font.subheadline
    /// labelMedium / labelLarge — chips, "More".
    static let label = Font.footnote.weight(.semibold)
    /// labelSmall — the header's metadata line.
    static let labelSmall = Font.caption2.weight(.semibold)
}

/// Android's layout constants, in points.
enum CollectionsMetrics {
    /// PAGE_GUTTER, at the iOS app's own gutter so these pages line up with the rest of it.
    static let gutter = AppTheme.gutter
    /// HEADER_GUTTER: the inset the header text and the action circles share.
    static let headerGutter = AppTheme.gutter + 14
    /// ABOUT_GUTTER.
    static let aboutGutter = AppTheme.gutter + 12
    /// SHELF_CARD_WIDTH.
    static let shelfCardWidth: CGFloat = 150
    /// LIBRARY_GRID_SPACING.
    static let gridSpacing: CGFloat = 12
    /// LIBRARY_GRID_MIN_CARD_WIDTH.
    static let gridMinCardWidth: CGFloat = 140
    /// ROW_DIVIDER_INSET: clear of the row's artwork.
    static let rowDividerInset = AppTheme.gutter + 68

    /// Common.kt's `libraryGrid`: as many columns as fit at the minimum width, two to five.
    static func gridColumns(available: CGFloat) -> Int {
        let raw = Int((available + gridSpacing) / (gridMinCardWidth + gridSpacing))
        return min(max(raw, 2), 5)
    }
}

extension ThemeColorScheme {
    /// The Android scheme matching SwiftUI's colour scheme, for the artwork palette.
    static func matching(_ scheme: ColorScheme) -> ThemeColorScheme {
        .forDarkTheme(scheme == .dark)
    }
}

/// Library shelf titles as the app says them (HomeScreen.kt's `localizeShelfTitle`, the library
/// part): the repository names the feeds in English.
func localizedLibraryShelfTitle(_ title: String) -> String {
    switch title.trimmingCharacters(in: .whitespaces).lowercased() {
    case "playlists": return L10n.playlists
    case "albums", "album": return L10n.albums
    case "artists": return L10n.artists
    case "subscriptions": return L10n.subscriptions
    default: return title
    }
}

/// A shelf heading with its optional "Show all" (HomeScreen.kt's SectionHeader).
struct CollectionsSectionHeader: View {
    let title: String
    var subtitle: String = ""
    var titleColor: Color = .primary
    var accent: Color = .accentColor
    var onShowAll: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(CollectionsType.headline)
                    .foregroundStyle(titleColor)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(CollectionsType.title)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let onShowAll {
                Button {
                    Haptics.shared.play(.tap)
                    onShowAll()
                } label: {
                    Text(L10n.showAll)
                        .font(CollectionsType.titleSmall)
                        .foregroundStyle(accent)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("showAll")
            }
        }
        .padding(.horizontal, CollectionsMetrics.gutter)
        .padding(.vertical, 10)
    }
}

/// A Library card (HomeScreen.kt's ShelfCard): the square cover — or, for the on-device folders,
/// a gradient tile with the folder's glyph — then the title (with a pin when pinned) and subtitle.
struct LibraryShelfCard: View {
    let item: ShelfItem
    var width: CGFloat? = CollectionsMetrics.shelfCardWidth
    var isPinned = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
            HStack(spacing: 4) {
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(L10n.pinned)
                }
                Text(item.title)
                    .font(CollectionsType.title)
                    .lineLimit(1)
            }
            .padding(.top, 10)
            Text(item.subtitle)
                .font(CollectionsType.bodySmall)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var cover: some View {
        switch item.browseId {
        case LocalBrowseID.downloads:
            FolderTile(colors: [Color(argb: 0xFF1E_3C72), Color(argb: 0xFF2A_5298)], symbol: AppSymbol.download)
        case LocalBrowseID.all:
            FolderTile(colors: [Color(argb: 0xFF13_4E5E), Color(argb: 0xFF71_B280)], symbol: "music.note.house.fill")
        case LocalBrowseID.offlineBackup:
            FolderTile(colors: [Color(argb: 0xFF23_2526), Color(argb: 0xFF41_4345)], symbol: "icloud.slash.fill")
        case LocalBrowseID.webDAV:
            FolderTile(colors: [Color(argb: 0xFF3A_1C71), Color(argb: 0xFFD7_6D77)], symbol: "folder.fill")
        case LocalBrowseID.smb:
            FolderTile(colors: [Color(argb: 0xFF0F_2027), Color(argb: 0xFF2C_5364)], symbol: "externaldrive.fill")
        default:
            GeometryReader { proxy in
                ArtworkImage(item.thumbnailUrl, pixels: ArtworkSize.card, cornerRadius: 0)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
            .background(Color(.secondarySystemFill))
        }
    }
}

/// The device-folder card (HomeScreen.kt's ServiceCard). Android drew a drifting mesh in the
/// folder's two colours; a still two-stop mesh-like gradient is the closest native drawing.
private struct FolderTile: View {
    let colors: [Color]
    let symbol: String

    var body: some View {
        ZStack {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [colors[1].opacity(0.9), .clear], center: .topTrailing, startRadius: 0, endRadius: 140)
            Image(systemName: symbol)
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }
}

/// The dashed "New playlist" tile at the head of the playlist row (HomeScreen.kt's NewShelfCard).
struct NewShelfCard: View {
    let label: String
    let subtitle: String
    var width: CGFloat? = CollectionsMetrics.shelfCardWidth
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.shared.play(.tap)
            action()
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemFill))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        Image(systemName: AppSymbol.plus)
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                Text(label)
                    .font(CollectionsType.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.top, 10)
                Text(subtitle)
                    .font(CollectionsType.bodySmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: width)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.newPlaylist")
    }
}

/// A centred message with an optional button (Common.kt's MessageState).
struct MessageState: View {
    let message: String
    var actionLabel: String?
    var action: (() -> Void)?
    var textColor: Color = .secondary

    var body: some View {
        VStack(spacing: 16) {
            Text(message)
                .font(CollectionsType.body)
                .foregroundStyle(textColor)
                .multilineTextAlignment(.center)
            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, CollectionsMetrics.gutter + 12)
        .padding(.vertical, 48)
        .accessibilityIdentifier("messageState")
    }
}

/// The tick a row wears once its track is saved on this device (Common.kt's DownloadedBadge).
struct DownloadedBadge: View {
    let videoId: String
    let tint: Color

    @Environment(AppModel.self) private var model

    var body: some View {
        if CollectionsStore.shared(for: model).service.isDownloaded(videoId) {
            Image(systemName: AppSymbol.downloaded)
                .font(.system(size: 14))
                .foregroundStyle(tint)
                .padding(.leading, 8)
                .accessibilityLabel(L10n.downloaded)
        }
    }
}

extension Color {
    /// A colour from an Android `0xAARRGGBB` literal.
    init(argb: UInt32) {
        self.init(
            .sRGB,
            red: Double((argb >> 16) & 0xFF) / 255,
            green: Double((argb >> 8) & 0xFF) / 255,
            blue: Double(argb & 0xFF) / 255,
            opacity: Double((argb >> 24) & 0xFF) / 255
        )
    }
}

/// The artwork palette a page paints itself in (`rememberArtworkPalette`), read from the shared
/// cache so a sleeve seen before is tinted on the first frame.
struct ArtworkPaletteReader<Content: View>: View {
    let artwork: String?
    var artPixels: Int = ArtworkPaletteCache.defaultArtPixels
    @ViewBuilder let content: (ArtworkPalette) -> Content

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tint = ArtworkTintModel(cache: .shared)

    private var url: URL? {
        // The cache sizes the request itself (ArtworkSizing), so it is handed the raw URL.
        artwork.flatMap(URL.init(string:))
    }

    var body: some View {
        let palette = tint.palette(for: url, scheme: .matching(colorScheme))
        content(palette)
            .animation(tint.fade(for: url, reduceAnimation: reduceMotion).map { .easeInOut(duration: $0) }, value: palette)
            .task(id: url) { await tint.load(url, artPixels: artPixels) }
    }
}
