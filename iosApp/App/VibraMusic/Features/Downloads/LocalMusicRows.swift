import VibraMusicCore
import Downloads
import NetworkLibrary
import SwiftUI

// The rows and cards of ui/screens/LocalMusicScreen.kt (SongGridCard, ArtistRow, ArtistGridCard,
// AlbumRow, AlbumGridCard, CollectionArtwork, SectionHeader) and the SongRow variant it drew
// (Common.kt's SongRow with `selected`, `trackNumber` and the downloaded badge). The shell's
// SongRow always opens the song menu on a hold; the Downloads folder turns the hold into
// "select", so these rows take their gestures from the page.

// MARK: - Artwork

private struct RemoteArtworkResolverKey: EnvironmentKey {
    static let defaultValue: (@MainActor (Song) async -> URL?)? = nil
}

extension EnvironmentValues {
    /// Resolves covers the shared image loader can't fetch (SMB, WebDAV, embedded pictures). Set by
    /// the pages that list remote tracks.
    var remoteArtworkResolver: (@MainActor (Song) async -> URL?)? {
        get { self[RemoteArtworkResolverKey.self] }
        set { self[RemoteArtworkResolverKey.self] = newValue }
    }
}

/// A track's cover: the row's own artwork, or for a remote track whatever the resolver finds
/// (Android's `rememberRemoteArtworkUrl`).
struct LocalArtwork: View {
    let song: Song?
    var pixels = ArtworkSize.row
    var cornerRadius: CGFloat = AppTheme.artCorner
    var placeholderSymbol = AppSymbol.musicNote

    @Environment(\.remoteArtworkResolver) private var resolver
    @State private var resolved: URL?

    /// The covers resolved this run, by track. A row scrolled back into view is a new view whose
    /// `resolved` starts empty: without this it drew the placeholder for a round trip to the
    /// loader before the cover it had already shown came back. The resolver is still asked,
    /// and its answer replaces this one.
    @MainActor private static var known: [String: URL] = [:]

    static func needsResolver(_ song: Song) -> Bool {
        SmbConfig.isSmbId(song.videoId) || WebDavConfig.isWebDavId(song.videoId)
    }

    var body: some View {
        Group {
            if let song, Self.needsResolver(song) {
                ArtworkImage(url: resolved ?? Self.known[song.videoId], pixels: pixels, cornerRadius: cornerRadius,
                             placeholderSymbol: placeholderSymbol)
                    .task(id: song.videoId) {
                        guard let resolver else { return }
                        let url = await resolver(song)
                        resolved = url
                        Self.known[song.videoId] = url
                    }
            } else {
                ArtworkImage(song?.thumbnailUrl, pixels: pixels, cornerRadius: cornerRadius, placeholderSymbol: placeholderSymbol)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Shared pieces

/// The count line over each tab's list (LocalMusicScreen's SectionHeader).
struct LocalSectionHeader: View {
    let symbol: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .imageScale(.small)
            Text(title)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Common.kt's MessageState: a centred line saying why there's nothing to show.
struct LocalMessageState: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, AppTheme.gutter + 12)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("downloads.message")
    }
}

/// The now-playing glyph: GraphicEq while playing, PlayArrow while paused.
private struct NowPlayingGlyph: View {
    let isPlaying: Bool
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: isPlaying ? "waveform" : "play.fill")
            .font(.system(size: size * 0.8, weight: .semibold))
            .symbolEffect(.variableColor.iterative, isActive: isPlaying)
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel(L10n.nowPlaying)
    }
}

/// A press that also reports a hold, without the hold stealing the tap or the list's scroll.
private struct TapAndHold: ViewModifier {
    let onTap: () -> Void
    let onHold: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .onLongPressGesture(minimumDuration: 0.4) {
                guard let onHold else { return }
                Haptics.shared.play(.tap)
                onHold()
            }
    }
}

// MARK: - Song row

/// One track in a folder list (Common.kt's SongRow as LocalMusicScreen used it).
struct LocalSongRow: View {
    let song: Song
    var trackNumber: Int?
    var selected = false
    var isCurrent = false
    var isPlaying = false
    var isDownloaded = false
    let onTap: () -> Void
    let onHold: () -> Void
    let onMore: () -> Void
    let onSwipe: () -> Void

    @Environment(AppSettings.self) private var settings

    var body: some View {
        HStack(spacing: 14) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                ExplicitSongTitle(song: song, font: .callout.weight(.semibold), color: isCurrent ? .accentColor : .primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, AppTheme.gutter)
        .padding(.vertical, 4)
        .background((isCurrent || selected) ? Color.accentColor.opacity(0.14) : .clear)
        .animation(.easeOut(duration: 0.2), value: selected)
        .modifier(TapAndHold(onTap: onTap, onHold: onHold))
        .modifier(SwipeToQueue(enabled: true, playNext: settings.swipeToPlayNext, action: onSwipe))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: Text(L10n.more), onMore)
        .accessibilityAction(named: Text(settings.swipeToPlayNext ? L10n.playNext : L10n.addToQueue), onSwipe)
        .accessibilityIdentifier("songRow")
    }

    /// "Artist · FLAC" — the credit, then the saved file's format badge.
    private var subtitle: String {
        [song.artist.isEmpty ? nil : song.artist, song.downloadFormat].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private var leading: some View {
        if let trackNumber {
            // The same 52 pt the artwork would take, so a numbered list and an illustrated one share
            // a leading edge and a divider inset.
            ZStack {
                if isCurrent {
                    NowPlayingGlyph(isPlaying: isPlaying, size: 22)
                } else {
                    Text("\(trackNumber)")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 52, height: 52)
        } else {
            LocalArtwork(song: song)
                .frame(width: 52, height: 52)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isDownloaded {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel(L10n.downloaded)
        }
        if selected {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel(L10n.selected)
        }
        if isCurrent, trackNumber == nil {
            NowPlayingGlyph(isPlaying: isPlaying)
        }
        if let duration = song.durationText, !duration.isEmpty {
            Text(duration)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
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
}

/// A track as a grid card (SongGridCard).
struct LocalSongCard: View {
    let song: Song
    var selected = false
    var isCurrent = false
    var isPlaying = false
    let onTap: () -> Void
    let onHold: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LocalArtwork(song: song, pixels: ArtworkSize.card, cornerRadius: 12)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if isCurrent {
                        NowPlayingGlyph(isPlaying: isPlaying, size: 28)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
            ExplicitSongTitle(song: song, font: .callout.weight(.semibold))
                .padding(.top, 8)
            Text(song.artist.isEmpty ? L10n.unknownArtist : song.artist)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(4)
        .background(selected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .modifier(TapAndHold(onTap: onTap, onHold: onHold))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("songCard")
    }
}

// MARK: - Artists

/// A round avatar with the person glyph behind whatever cover the artist's first track has.
private struct ArtistAvatar: View {
    let song: Song?
    var glyphSize: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.18))
            Image(systemName: "person.fill")
                .font(.system(size: glyphSize))
                .foregroundStyle(Color.accentColor)
            if song?.thumbnailUrl != nil {
                LocalArtwork(song: song, pixels: ArtworkSize.card, cornerRadius: 0)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            }
        }
        .accessibilityHidden(true)
    }
}

struct LocalArtistRow: View {
    let artist: LocalArtistGroup
    let onTap: () -> Void
    let onHold: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ArtistAvatar(song: artist.songs.first { $0.thumbnailUrl != nil }, glyphSize: 22)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(L10n.songCountPlural(artist.songs.count))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "play.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, AppTheme.gutter)
        .padding(.vertical, 10)
        .modifier(TapAndHold(onTap: onTap, onHold: onHold))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("artistRow")
    }
}

struct LocalArtistCard: View {
    let artist: LocalArtistGroup
    let onTap: () -> Void
    let onHold: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ArtistAvatar(song: artist.songs.first { $0.thumbnailUrl != nil }, glyphSize: 40)
                .aspectRatio(1, contentMode: .fit)
                .padding(.horizontal, 8)
            Text(artist.name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .padding(.top, 8)
            Text(L10n.songCountPlural(artist.songs.count))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .multilineTextAlignment(.center)
        .padding(4)
        .modifier(TapAndHold(onTap: onTap, onHold: onHold))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("artistCard")
    }
}

// MARK: - Albums

/// "Playlist · 12 songs", "Artist · 12 songs" or just "12 songs" (AlbumRow's credit line). A
/// playlist's tracks are off forty different releases, so the first one's artist is not a credit
/// for it — the kind of thing it is says more, and is true.
func albumCredit(_ album: LocalAlbumGroup) -> String {
    let count = L10n.songCountPlural(album.songs.count)
    if album.playlist { return L10n.playlist + " · " + count }
    if !album.artist.isEmpty, album.artist != album.title { return album.artist + " · " + count }
    return count
}

/// A release's cover, with a glyph standing in when there isn't one (CollectionArtwork). Drawn
/// behind the image, so a cover that loads late replaces the glyph without the row changing size.
struct CollectionArtwork: View {
    let album: LocalAlbumGroup
    var cornerRadius: CGFloat = 8
    var glyphSize: CGFloat = 26
    var pixels = ArtworkSize.row

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.secondary.opacity(0.18))
            Image(systemName: album.playlist ? "music.note.list" : "square.stack.fill")
                .font(.system(size: glyphSize))
                .foregroundStyle(.secondary)
            if let cover = album.thumbnailUrl {
                ArtworkImage(cover, pixels: pixels, cornerRadius: cornerRadius)
            } else if let first = album.songs.first, first.thumbnailUrl != nil || isRemote(first) {
                // Albums grouped off tags have no cover of their own; the first track's picture
                // stands in until the real one exists.
                LocalArtwork(song: first, pixels: pixels, cornerRadius: cornerRadius)
            }
        }
        .accessibilityHidden(true)
    }

    private func isRemote(_ song: Song) -> Bool {
        SmbConfig.isSmbId(song.videoId) || WebDavConfig.isWebDavId(song.videoId)
    }
}

struct LocalAlbumRow: View {
    let album: LocalAlbumGroup
    var selected = false
    let onTap: () -> Void
    let onHold: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            CollectionArtwork(album: album)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(albumCredit(album))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: selected ? "checkmark.circle.fill" : "play.fill")
                .font(.system(size: selected ? 18 : 14))
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .accessibilityLabel(selected ? L10n.selected : "")
                .accessibilityHidden(!selected)
        }
        .padding(.horizontal, AppTheme.gutter)
        .padding(.vertical, 10)
        .background(selected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .modifier(TapAndHold(onTap: onTap, onHold: onHold))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("albumRow")
    }
}

struct LocalAlbumCard: View {
    let album: LocalAlbumGroup
    var selected = false
    let onTap: () -> Void
    let onHold: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CollectionArtwork(album: album, cornerRadius: 12, glyphSize: 36, pixels: ArtworkSize.card)
                .aspectRatio(1, contentMode: .fit)
            Text(album.title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .padding(.top, 8)
            Text(albumCredit(album))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(4)
        .background(selected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .modifier(TapAndHold(onTap: onTap, onHold: onHold))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("albumCard")
    }
}
