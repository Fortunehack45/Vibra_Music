#if DEBUG
import VibraMusicCore
import Downloads
import Foundation
import NetworkLibrary

/// Debug-build fixtures for screenshots and manual checks of the Downloads screens, which otherwise
/// need a library of real downloads on the simulator.
///
/// `-downloadsDemo` swaps in canned downloads and a download batch in every state; the remote
/// libraries stay live (point them at a real server). `-downloadsOpen <what>` then drives the
/// Downloads page once it is shown: `manager` opens the manager sheet, `select` selects three rows,
/// `albums` / `artists` pick that tab, `grid` switches to the grid, `drill` opens the first album,
/// `smb` / `webdav` push that library, `local` pushes the Local Music folder. Release builds have
/// none of this.
@MainActor
final class DownloadsDemoService: DownloadsService {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-downloadsDemo") }

    /// The `-downloadsOpen` targets, comma separated.
    static var openTargets: Set<String> {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-downloadsOpen"), index + 1 < arguments.count else { return [] }
        return Set(arguments[index + 1].split(separator: ",").map(String.init))
    }

    @MainActor private static var consumed: Set<String> = []

    /// True the first time `target` is asked for, when it was requested.
    static func take(_ target: String) -> Bool {
        guard openTargets.contains(target), !consumed.contains(target) else { return false }
        consumed.insert(target)
        return true
    }

    static func requested() -> DownloadsDemoService? {
        guard isRequested else { return nil }
        return DownloadsDemoService(live: nil)
    }

    private let live: DownloadsService?
    let session = DownloadSession()
    private var saved: [Song]
    private var revision = 0

    init(live: DownloadsService?) {
        self.live = live
        saved = Self.library
        for song in Self.batch { session.queued(song, from: song.albumName) }
        session.done(Self.batch[0].videoId)
        session.done(Self.batch[1].videoId)
        session.running(Self.batch[2].videoId, fraction: 0.62)
        session.failed(Self.batch[3].videoId, reason: L10n.wifiOnlyDownloadRefusal)
    }

    var libraryVersion: Int { revision }

    func songs(in folder: LocalFolder) -> [Song] { saved }

    func collections(among songs: [Song]) -> [DownloadedCollection] {
        let ram = songs.filter { $0.albumName == "Random Access Memories" }
        guard !ram.isEmpty else { return [] }
        return [DownloadedCollection(id: "MPREb_ram", title: "Random Access Memories", subtitle: "Daft Punk",
                                     thumbnailUrl: Self.cover("khnokW3Mw24"), playlist: false, songs: ram)]
    }

    func isDownloaded(_ videoId: String) -> Bool { saved.contains { $0.videoId == videoId } }

    func delete(_ videoIds: [String]) -> DownloadDeletion {
        let before = saved.count
        saved.removeAll { videoIds.contains($0.videoId) }
        revision += 1
        return DownloadDeletion(deletedFiles: before - saved.count, freedBytes: Int64(before - saved.count) * 7_400_000)
    }

    func importFiles(at urls: [URL]) async -> LocalImportResult {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "downloads-demo", directoryHint: .isDirectory)
        return await LocalMusicImporter(library: DownloadLibrary(store: DownloadStore(root: scratch))).importItems(at: urls)
    }
    func cancelDownload(_ videoId: String) { session.forget(videoId) }
    func retryDownload(_ videoId: String) {
        guard let item = session.item(videoId) else { return }
        session.queued(item.song, from: item.from)
    }
    var isWaitingForWiFi: Bool { live?.isWaitingForWiFi ?? false }

    var canUploadToWebDAV: Bool { true }

    func uploadToWebDAV(
        _ songs: [Song],
        onConflict: @escaping @Sendable (WebDavUploads.ConflictRequest) async -> WebDavUploads.Resolution
    ) async -> WebDavUploads.Summary {
        guard let first = songs.first else { return WebDavUploads.Summary(uploaded: 0, skipped: 0, failed: 0) }
        let item = WebDavUploads.UploadItem(id: first.videoId, fileURL: URL(fileURLWithPath: "/tmp/demo.m4a"),
                                            title: first.title, artist: first.artist)
        let answer = await onConflict(WebDavUploads.ConflictRequest(item: item, fileName: "\(first.artist) - \(first.title).m4a",
                                                                   remaining: songs.count - 1))
        let skipped = answer.choice == .skip ? 1 : 0
        return WebDavUploads.Summary(uploaded: songs.count - skipped, skipped: skipped, failed: 0)
    }

    func networkSettingsKey(_ kind: NetworkLibraryKind) -> String { kind.rawValue }

    func listNetworkLibrary(_ kind: NetworkLibraryKind) async -> LoadState<[Song]> {
        guard let model = AppModel.current else { return .error(L10n.webdavEmpty) }
        return await LiveDownloadsService(model: model).listNetworkLibrary(kind)
    }

    func remoteArtwork(for song: Song) async -> URL? {
        guard let model = AppModel.current else { return nil }
        return await LiveDownloadsService(model: model).remoteArtwork(for: song)
    }

    // MARK: - Fixtures

    private static func cover(_ id: String) -> String { "https://i.ytimg.com/vi/\(id)/hqdefault.jpg" }

    private static func song(_ id: String, _ title: String, _ artist: String, album: String?, _ duration: String,
                             format: String? = nil, added: Int64) -> Song {
        Song(videoId: id, title: title, artist: artist, thumbnailUrl: cover(id), durationText: duration,
             albumName: album, localUri: "file:///demo/\(id).m4a", downloadFormat: format,
             localDateAddedSeconds: added, localDateModifiedSeconds: added)
    }

    static let library: [Song] = [
        song("khnokW3Mw24", "Instant Crush", "Daft Punk", album: "Random Access Memories", "5:37", format: "ALAC", added: 1_790_000_900),
        song("5NV6Rdv1a3I", "Get Lucky", "Daft Punk", album: "Random Access Memories", "6:09", format: "ALAC", added: 1_790_000_800),
        song("IluRBvnYMoY", "Lose Yourself to Dance", "Daft Punk", album: "Random Access Memories", "5:53", format: "ALAC", added: 1_790_000_700),
        song("fJ9rUzIMcZQ", "Bohemian Rhapsody", "Queen", album: "A Night at the Opera", "5:55", added: 1_790_000_600),
        song("4NRXx6U8ABQ", "Blinding Lights", "The Weeknd", album: "After Hours", "3:20", format: "AAC", added: 1_790_000_500),
        song("XXYlFuWEuKI", "Save Your Tears", "The Weeknd", album: "After Hours", "3:36", format: "AAC", added: 1_790_000_400),
        song("hTWKbfoikeg", "Smells Like Teen Spirit", "Nirvana", album: "Nevermind", "5:01", added: 1_790_000_300),
        song("1w7OgIMMRc4", "Sweet Child O' Mine", "Guns N' Roses", album: nil, "5:56", added: 1_790_000_200),
        song("JGwWNGJdvx8", "Shape of You", "Ed Sheeran", album: "÷", "3:54", format: "AAC", added: 1_790_000_100),
    ]

    static let batch: [Song] = [
        song("IluRBvnYMoY", "Lose Yourself to Dance", "Daft Punk", album: "Random Access Memories", "5:53", added: 0),
        song("5NV6Rdv1a3I", "Get Lucky", "Daft Punk", album: "Random Access Memories", "6:09", added: 0),
        song("sOnqjkJTMaA", "Thriller", "Michael Jackson", album: "Thriller", "5:57", added: 0),
        song("Zi_XLOBDo_Y", "Billie Jean", "Michael Jackson", album: "Thriller", "4:54", added: 0),
        song("oRdxUFDoQe0", "Beat It", "Michael Jackson", album: "Thriller", "4:18", added: 0),
    ]
}
#endif
