import VibraMusicCore
import CarPlay
import PlaybackPolicy
import PlaybackQueue
import UIKit

/// Draws ``CarLibrary`` as CarPlay templates and wires the car's Now Playing screen to the player.
///
/// Android Auto shows the root's folders as tabs; the CarPlay counterpart is a tab bar of list
/// templates, one per folder, in the same order. Playlists are a grid on Android Auto; CarPlay's
/// grid template holds at most eight buttons and no artwork captions, so they are an artwork list
/// here (the closest native layout).
@MainActor
final class CarPlayCoordinator: NSObject {
    let library: CarLibrary
    private let player: PlayerController
    private weak var interfaceController: CPInterfaceController?
    /// Open list templates by the folder they show, so a background refresh can redraw them.
    private var openLists: [String: CPListTemplate] = [:]
    /// Song rows on screen, so the playing marker follows the player rather than the moment the
    /// row was drawn.
    private var songRows: [(videoId: String, item: WeakRow<CPListItem>)] = []
    private var trackers: [ChangeTracker] = []
    private let isPinnedToOriginal: (String) -> Bool

    init(library: CarLibrary, player: PlayerController, isPinnedToOriginal: @escaping (String) -> Bool = { OriginalVersion.shared.isPinned($0) }) {
        self.library = library
        self.player = player
        self.isPinnedToOriginal = isPinnedToOriginal
        super.init()
        library.onFolderRefreshed = { [weak self] id in
            Task { @MainActor [weak self] in await self?.reload(id) }
        }
    }

    // MARK: - Connection

    func connect(_ interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        interfaceController.delegate = self
        interfaceController.setRootTemplate(makeRootTemplate(), animated: false, completion: nil)
        startNowPlaying()
        trackers.append(ChangeTracker.track({ [weak self] in self?.player.currentSong?.videoId }) { [weak self] videoId in
            self?.markPlaying(videoId)
        })
    }

    func disconnect() {
        trackers.forEach { $0.cancel() }
        trackers = []
        CPNowPlayingTemplate.shared.remove(self)
        openLists = [:]
        songRows = []
        interfaceController?.delegate = nil
        interfaceController = nil
    }

    // MARK: - Browse templates

    /// The tab bar: Quick picks, Recent, Playlists, Liked songs, More. A car that allows fewer tabs
    /// gets the first ones and More, which then lists the rest ahead of Downloads and Local Music.
    func makeRootTemplate() -> CPTabBarTemplate {
        var folders = library.rootFolders
        let maximum = max(2, CPTabBarTemplate.maximumTabCount)
        var overflow: [CarNode] = []
        if folders.count > maximum {
            overflow = Array(folders[(maximum - 1)..<(folders.count - 1)])
            folders = Array(folders.prefix(maximum - 1)) + [folders[folders.count - 1]]
        }
        let tabs = folders.map { folder -> CPListTemplate in
            if folder.id == CarNodeID.more { moreLeading = overflow }
            let template = makeList(for: folder.id, title: folder.title, leading: folder.id == CarNodeID.more ? overflow : [])
            template.tabTitle = folder.title
            template.tabImage = UIImage(systemName: Self.tabSymbol(folder.id))
            return template
        }
        let tabBar = CPTabBarTemplate(templates: tabs)
        tabBar.delegate = self
        return tabBar
    }

    static func tabSymbol(_ id: String) -> String {
        switch id {
        case CarNodeID.quickPicks: return "sparkles"
        case CarNodeID.recents: return "clock"
        case CarNodeID.playlists: return "music.note.list"
        case CarNodeID.liked: return "heart"
        default: return "ellipsis"
        }
    }

    /// A list for one folder, filled in when its rows arrive.
    func makeList(for id: String, title: String, leading: [CarNode] = []) -> CPListTemplate {
        let template = CPListTemplate(title: title, sections: [])
        template.emptyViewTitleVariants = [title]
        openLists[id] = template
        loading.insert(id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let nodes = leading + (await self.library.children(of: id))
            self.loading.remove(id)
            template.updateSections([self.section(for: nodes, folderTitle: title, folderId: id)])
        }
        return template
    }

    private func reload(_ id: String) async {
        guard let template = openLists[id] else { return }
        songRows.removeAll { $0.item.value == nil }
        let leading = id == CarNodeID.more ? moreLeading : []
        let nodes = leading + (await library.children(of: id))
        template.updateSections([section(for: nodes, folderTitle: template.title ?? "", folderId: id)])
    }

    /// Android Auto asks for a folder's children every time it is opened; CarPlay keeps a tab's list
    /// alive for the whole drive. So a folder is re-read whenever it comes back on screen (a tab
    /// chosen, a pushed list popped back to): Recents picks up what was just played, a folder that
    /// was empty for want of a network fills in, and signing in on the phone replaces the prompt.
    /// ``CarLibrary``'s caches keep this from costing a fetch each time.
    func refresh(_ template: CPTemplate) {
        guard let list = template as? CPListTemplate,
              let id = openLists.first(where: { $0.value === list })?.key,
              !loading.contains(id) else { return }
        Task { @MainActor [weak self] in await self?.reload(id) }
    }

    /// Folders whose first load is still under way (their first appearance needn't ask again).
    private var loading: Set<String> = []

    /// The root folders that didn't fit the car's tab bar, listed at the top of More.
    private var moreLeading: [CarNode] = []

    func markPlaying(_ videoId: String?) {
        songRows.removeAll { $0.item.value == nil }
        for row in songRows { row.item.value?.isPlaying = row.videoId == videoId }
    }

    func section(for nodes: [CarNode], folderTitle: String, folderId: String) -> CPListSection {
        let limit = CPListTemplate.maximumItemCount
        return CPListSection(items: nodes.prefix(limit).map { listItem(for: $0, folderTitle: folderTitle, folderId: folderId) })
    }

    func listItem(for node: CarNode, folderTitle: String, folderId: String) -> CPListItem {
        switch node {
        case .folder(let id, let title, let subtitle, let artworkURL):
            let item = CPListItem(text: title, detailText: subtitle)
            item.accessoryType = .disclosureIndicator
            loadArtwork(artworkURL.flatMap(URL.init(string:)), into: item)
            item.handler = { [weak self] _, completion in
                guard let self else { return completion() }
                self.interfaceController?.pushTemplate(self.makeList(for: id, title: title), animated: true) { _, _ in completion() }
            }
            return item
        case .song(let song):
            let item = CPListItem(text: song.title, detailText: song.artist)
            item.isPlaying = player.currentSong?.videoId == song.videoId
            songRows.append((song.videoId, WeakRow(item)))
            loadArtwork(song.artworkURL(at: ArtworkSize.row), into: item)
            item.handler = { [weak self] _, completion in
                self?.play(song, from: folderTitle, folderId: folderId)
                completion()
            }
            return item
        case .info(_, let title, let subtitle):
            let item = CPListItem(text: title, detailText: subtitle)
            item.isEnabled = false
            return item
        }
    }

    /// A choice plays that song, and the queue carries on from it the way AutoPlay does (Android
    /// Auto hands the session one item), then the car shows Now Playing.
    func play(_ song: Song, from folderTitle: String, folderId: String) {
        player.playSong(song, source: QueueSource(title: folderTitle, type: Self.sourceType(folderId), id: folderId))
        guard let interfaceController, interfaceController.topTemplate !== CPNowPlayingTemplate.shared else { return }
        interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    static func sourceType(_ folderId: String) -> PlaybackSourceType {
        switch folderId {
        case CarNodeID.quickPicks: return .home
        case CarNodeID.recents: return .history
        default: return .browse
        }
    }

    private func loadArtwork(_ url: URL?, into item: CPListItem) {
        guard let url else { return }
        Task { @MainActor in
            guard let image = await ArtworkImageCache.shared.image(for: url) else { return }
            item.setImage(image)
        }
    }

    // MARK: - Now Playing

    private func startNowPlaying() {
        let template = CPNowPlayingTemplate.shared
        template.isUpNextButtonEnabled = true
        template.isAlbumArtistButtonEnabled = false
        template.add(self)
        trackers.append(ChangeTracker.track({ [weak self] in self?.nowPlayingButtons() ?? [] }) { [weak self] buttons in
            self?.apply(buttons)
        })
    }

    func nowPlayingButtons() -> [CarNowPlayingButton] {
        let song = player.currentSong
        return CarNowPlayingButton.buttons(
            for: song,
            liked: song.map { player.likeStatus(of: $0) == .like } ?? false,
            shuffle: player.shuffleEnabled,
            isPinnedToOriginal: isPinnedToOriginal
        )
    }

    private func apply(_ buttons: [CarNowPlayingButton]) {
        CPNowPlayingTemplate.shared.updateNowPlayingButtons(buttons.map(makeButton))
    }

    func makeButton(_ button: CarNowPlayingButton) -> CPNowPlayingButton {
        switch button {
        case .shuffle(let on):
            // The widget follows through WidgetSnapshotObserver, which watches shuffle.
            let shuffle = CPNowPlayingShuffleButton { [weak self] _ in
                self?.player.toggleShuffle()
            }
            shuffle.isSelected = on
            return shuffle
        case .favorite:
            return CPNowPlayingImageButton(image: UIImage(systemName: button.symbol) ?? UIImage()) { [weak self] _ in
                _ = self?.player.toggleLike()
            }
        case .radio:
            return CPNowPlayingImageButton(image: UIImage(systemName: button.symbol) ?? UIImage()) { [weak self] _ in
                guard let self, let song = self.player.currentSong else { return }
                Task { @MainActor in _ = await self.player.startRadio(from: song) }
            }
        case .revert:
            return CPNowPlayingImageButton(image: UIImage(systemName: button.symbol) ?? UIImage()) { [weak self] _ in
                self?.player.revertToOriginal()
            }
        }
    }

    /// The queue, as the car's Up Next list; choosing a row jumps there.
    func makeUpNextTemplate() -> CPListTemplate {
        let songs = player.songs
        let current = player.currentIndex
        let window = Self.upNextWindow(count: songs.count, current: current, limit: CPListTemplate.maximumItemCount)
        let items = window.map { index -> CPListItem in
            let song = songs[index]
            let item = CPListItem(text: song.title, detailText: song.artist)
            item.isPlaying = index == current
            loadArtwork(song.artworkURL(at: ArtworkSize.row), into: item)
            item.handler = { [weak self] _, completion in
                _ = self?.player.jump(to: index)
                completion()
            }
            return item
        }
        return CPListTemplate(title: L10n.upNext, sections: [CPListSection(items: items)])
    }

    /// The rows the car can show: a car caps a list (as low as a dozen rows), so a long queue is
    /// windowed to start at the playing song, keeping it and what follows on screen, filled back
    /// with earlier songs near the end of the queue.
    static func upNextWindow(count: Int, current: Int?, limit: Int) -> Range<Int> {
        guard count > 0, limit > 0 else { return 0..<0 }
        guard count > limit else { return 0..<count }
        let start = min(max(current ?? 0, 0), count - limit)
        return start..<(start + limit)
    }
}

extension CarPlayCoordinator: CPTabBarTemplateDelegate, CPInterfaceControllerDelegate {
    nonisolated func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        MainActor.assumeIsolated { refresh(selectedTemplate) }
    }

    nonisolated func templateWillAppear(_ aTemplate: CPTemplate, animated: Bool) {
        MainActor.assumeIsolated { refresh(aTemplate) }
    }
}

/// A reference that doesn't keep a CarPlay row alive after its list is gone.
private struct WeakRow<Object: AnyObject> {
    weak var value: Object?
    init(_ value: Object) { self.value = value }
}

extension CarPlayCoordinator: CPNowPlayingTemplateObserver {
    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        MainActor.assumeIsolated {
            interfaceController?.pushTemplate(makeUpNextTemplate(), animated: true, completion: nil)
        }
    }

    nonisolated func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {}
}
