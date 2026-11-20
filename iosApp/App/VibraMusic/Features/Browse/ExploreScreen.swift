import VibraMusicCore
import SwiftUI

/// Explore (ports ui/screens/ExploreScreen.kt and its place on the Explore tab in MainActivity.kt).
///
/// The page title, then YouTube Music's Moods & Genres: each server-defined section as a heading
/// over a two-column grid of coloured tiles, a tilted cover tucked into each tile's corner. Tapping
/// a tile opens its playlists (``MoodGenreScreen``). Pull to refresh.
struct ExploreScreen: View {
    @Environment(AppModel.self) private var model
    @State private var explore = ExploreModel()

    var body: some View {
        let state = explore.state
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // One container per state (see HomeScreen: rows of different branches sharing ids
                // in one lazy stack keep drawing the old branch).
                switch state {
                case .loading:
                    ExploreSkeleton()
                case .error(let message):
                    BrowseMessage(message: message, actionTitle: L10n.retry) { reload() }
                case .success(let sections):
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections, id: \.title) { section in
                            MoodGenreGrid(section: section) { model.router.open(.moodGenre($0)) }
                        }
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .refreshable { await explore.refresh(model.repository) }
        #if DEBUG
        .onChange(of: explore.state.value?.first?.items.first) { _, first in
            if let first, BrowseDebugLaunch.take("moodGenre") != nil { model.router.open(.moodGenre(first)) }
        }
        #endif
        .navigationTitle(L10n.explore)
        .navigationBarTitleDisplayMode(.large)
        .task {
            guard !explore.hasLoaded else { return }
            reload()
        }
        // A container: without this the screen identifier lands on every child and hides theirs.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.explore")
    }

    private func reload() {
        let catalog = model.repository
        // Unstructured (Android's viewModelScope), so leaving the tab can't strand the skeleton.
        Task { await explore.load(catalog) }
    }
}

/// `MoodGenreGrid`: a section heading over its tiles, two to a row. Lazy, where Android's rows are
/// not: a section runs to forty-odd tiles, each with a cover to load, most of them off screen, and
/// built at once they cost a hitch as each section scrolled in. Same columns and spacing.
private struct MoodGenreGrid: View {
    let section: MoodGenreSection
    let onOpen: (MoodGenre) -> Void

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 2)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrowseSectionHeader(title: section.title)
            LazyVGrid(columns: Self.columns, spacing: 12) {
                ForEach(section.items.indices, id: \.self) { index in
                    MoodGenreTile(item: section.items[index]) { onOpen(section.items[index]) }
                }
            }
            .padding(.horizontal, BrowseMetrics.gutter)
        }
        .padding(.bottom, 22)
    }
}

/// `MoodGenreCard`: a tile in the category's colour, its name in the top corner and a cover
/// rotated 16° and pushed past the bottom corner like a cropped album sleeve.
struct MoodGenreTile: View {
    let item: MoodGenre
    let onTap: () -> Void

    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        let color = MoodColor.color(for: item.title)
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Button(action: onTap) {
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [color, color.darkened(0.68)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Color.white.opacity(0.22)
                    .frame(width: 82, height: 82)
                    .overlay {
                        if let artwork = item.thumbnailUrl {
                            ArtworkImage(artwork, pixels: ArtworkSize.row, cornerRadius: 0)
                        }
                    }
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .rotationEffect(.degrees(layoutDirection == .rightToLeft ? -16 : 16))
                .offset(x: 10, y: 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(12)
                Text(item.title)
                    .font(BrowseFont.title.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.trailing, 48)
                    .padding(12)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 100)
            .clipShape(shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityIdentifier("moodGenreTile")
    }
}

/// `moodColor`: one of eight colours, picked by the title's Java `hashCode` so a category keeps the
/// colour it has on Android.
enum MoodColor {
    static let palette: [UInt32] = [0xE64A19, 0xEC0B65, 0x8664AC, 0x6B4EFF, 0xBE6100, 0x233C78, 0x4D97E5, 0xAA267E]

    static func index(for title: String) -> Int {
        Int((javaHashCode(title) & Int32.max) % 8)
    }

    static func color(for title: String) -> Color {
        let rgb = palette[index(for: title)]
        return Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }

    /// `String.hashCode()`: s[0]·31^(n-1) + … + s[n-1] over UTF-16 units, wrapping at 32 bits.
    static func javaHashCode(_ text: String) -> Int32 {
        text.utf16.reduce(Int32(0)) { hash, unit in hash &* 31 &+ Int32(unit) }
    }
}

private extension Color {
    /// The colour with each channel scaled by `factor` (the tile gradient's darker end).
    func darkened(_ factor: Double) -> Color {
        let ui = UIColor(self)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        ui.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return Color(red: red * factor, green: green * factor, blue: blue * factor, opacity: alpha)
    }
}

/// `ExploreSkeleton`: five rows of two placeholder tiles.
private struct ExploreSkeleton: View {
    var body: some View {
        VStack(spacing: 12) {
            ForEach(0..<5, id: \.self) { _ in
                HStack(spacing: 12) {
                    ForEach(0..<2, id: \.self) { _ in
                        ShimmerBlock(cornerRadius: 8)
                            .frame(maxWidth: .infinity)
                            .frame(height: 100)
                    }
                }
            }
        }
        .padding(.horizontal, BrowseMetrics.gutter)
        .padding(.top, 10)
        .accessibilityHidden(true)
    }
}
