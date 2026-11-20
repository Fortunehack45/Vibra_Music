import VibraMusicCore
import Downloads
import Foundation
import NetworkLibrary
import Observation

// The outside world the Downloads screens stand on — the parts of MainActivity.kt and
// MainViewModel.kt that fed LocalMusicScreen and DownloadManagerSheet: the device folders' track
// lists (`openDetail` / `reloadLocalDetail` for `local:downloads` and `local:all`), the download
// record's releases (`Downloads.collectionsAmong`), delete (`Downloads.delete`), the queue's
// cancel/retry, the remote libraries' listings (`remoteLibrary` / `RemoteListing.state`) and the
// WebDAV upload (`uploadToWebDav`). Behind a protocol so tests and the screenshot fixtures can
// stand in for the disk and the network.

/// Which on-device folder a ``DownloadsScreen`` shows. Android drew both with the same
/// LocalMusicScreen; only the list, the empty message and whether it is the Downloads folder
/// (long-press selects, releases lead the Albums tab) differ.
enum LocalFolder: String, Hashable, CaseIterable {
    /// `local:downloads` — what this app downloaded.
    case downloads
    /// `local:all` — every track on the device. On iOS there is no MediaStore to scan (PORTING Q8):
    /// the files are the ones imported through Files, plus the downloads, as Android's Music folder
    /// held both.
    case localMusic

    var browseId: String {
        switch self {
        case .downloads: return LocalBrowseID.downloads
        case .localMusic: return LocalBrowseID.all
        }
    }

    /// The folder a device-folder browse id names, nil for any other id. Read back out of
    /// ``browseId`` rather than repeating the ids, so the pair can't drift.
    init?(browseId: String) {
        guard let folder = LocalFolder.allCases.first(where: { $0.browseId == browseId }) else { return nil }
        self = folder
    }

    /// The Library card's title, which is what the page bills itself as (`page.title`).
    var title: String {
        switch self {
        case .downloads: return L10n.downloads
        case .localMusic: return L10n.localMusic
        }
    }

    /// What the page says when it has no tracks (MainViewModel's `UiState.Error` for the folder).
    var emptyMessage: String {
        switch self {
        // Android hard-coded "No downloaded tracks"; it lives in Downloads.xcstrings here.
        case .downloads: return DownloadsText.noDownloadedTracks
        case .localMusic: return L10n.noLocalAudioFound
        }
    }
}

/// What the Downloads screens need from the app.
@MainActor
protocol DownloadsService: AnyObject {
    /// This sitting's download batch, for the manager sheet and the top-bar indicator.
    var session: DownloadSession { get }
    /// Changes whenever what is on disk or on record changes, so an open folder re-reads itself
    /// (MainActivity's `LaunchedEffect(savedDownloads, savedCollections)`). Reading it from a view
    /// body registers the dependency.
    var libraryVersion: Int { get }
    /// The folder's tracks. Checks the files off the main actor and may prune the record, so call it
    /// outside a view body.
    func songs(in folder: LocalFolder) async -> [Song]
    /// The releases downloaded whole among `songs` (`Downloads.collectionsAmong`).
    func collections(among songs: [Song]) -> [DownloadedCollection]
    /// Whether the record says `videoId` is saved — the row's downloaded badge.
    func isDownloaded(_ videoId: String) -> Bool
    /// Deletes the files behind `videoIds` and reports the space freed.
    @discardableResult func delete(_ videoIds: [String]) -> DownloadDeletion
    /// Copies audio picked in Files into the library (the Local Music folder's source on iOS).
    func importFiles(at urls: [URL]) async -> LocalImportResult
    func cancelDownload(_ videoId: String)
    func retryDownload(_ videoId: String)
    /// Whether the queue is holding for Wi-Fi (Wi-Fi only on, connection metered) — the held row's
    /// "why it isn't moving" label on the manager sheet.
    var isWaitingForWiFi: Bool { get }

    /// Whether a WebDAV server is set up, which is what puts "Upload to WebDAV" on the selection bar.
    var canUploadToWebDAV: Bool { get }
    /// Sends `songs` to the WebDAV server, asking `onConflict` about each name already there.
    func uploadToWebDAV(
        _ songs: [Song],
        onConflict: @escaping @Sendable (WebDavUploads.ConflictRequest) async -> WebDavUploads.Resolution
    ) async -> WebDavUploads.Summary

    /// Changes when the library's server settings do, so an open page lists again
    /// (MainActivity's `LaunchedEffect(webdavUrl)` / `LaunchedEffect(smbHost)`).
    func networkSettingsKey(_ kind: NetworkLibraryKind) -> String
    /// Lists an SMB share or WebDAV server as rows; a failure names its cause.
    func listNetworkLibrary(_ kind: NetworkLibraryKind) async -> LoadState<[Song]>
    /// A drawable cover for a track on an SMB share or WebDAV server (sidecar picture behind auth,
    /// or the picture embedded in the file), or nil.
    func remoteArtwork(for song: Song) async -> URL?
}

/// Listing helpers shared by the live service and its tests.
enum NetworkListing {
    /// Maps a listing onto the page state. The repositories answer an unreadable server with no rows
    /// (they swallow the error), so an empty answer is checked once more against the server: a
    /// share that refuses the login is not an empty share, and "no audio files" would send the user
    /// hunting through folder paths for a password problem (RemoteListing.kt's reason to exist).
    static func state(
        isConfigured: Bool,
        emptyMessage: String,
        songs: () async -> [Song],
        probe: () async throws -> Void
    ) async -> LoadState<[Song]> {
        guard isConfigured else { return .error(emptyMessage) }
        let listed = await songs()
        if !listed.isEmpty { return .success(listed) }
        do {
            try await probe()
            return .error(emptyMessage)
        } catch {
            return RemoteListing.state(for: Result<[Song], Error>.failure(error), emptyMessage: emptyMessage)
        }
    }
}

/// The running app's downloads, library and remote servers.
@MainActor
final class LiveDownloadsService: DownloadsService {
    private unowned let model: AppModel
    private let covers: RemoteCoverLoader

    init(model: AppModel) {
        self.model = model
        covers = RemoteCoverLoader.shared
    }

    private var library: DownloadLibrary { model.downloadLibrary }
    private var settings: AppSettings { model.settings }

    var session: DownloadSession { model.downloads.session }

    var libraryVersion: Int {
        var hasher = Hasher()
        hasher.combine(library.saved)
        hasher.combine(library.records.count)
        hasher.combine(library.collections.keys.sorted())
        return hasher.finalize()
    }

    func songs(in folder: LocalFolder) async -> [Song] {
        await library.listSongs(includeImported: folder == .localMusic)
    }

    func collections(among songs: [Song]) -> [DownloadedCollection] { library.collectionsAmong(songs) }
    func isDownloaded(_ videoId: String) -> Bool { library.isDownloaded(videoId) }
    func delete(_ videoIds: [String]) -> DownloadDeletion { library.delete(videoIds) }

    func importFiles(at urls: [URL]) async -> LocalImportResult {
        await LocalMusicImporter(library: library).importItems(at: urls)
    }

    func cancelDownload(_ videoId: String) { model.downloads.cancel(videoId) }
    func retryDownload(_ videoId: String) { model.downloads.retry(videoId) }
    var isWaitingForWiFi: Bool { model.downloads.isWaitingForWiFi }

    var canUploadToWebDAV: Bool { WebDavConfig.isConfigured(settings.webdavUrl) }

    private var webDavCredentials: WebDavCredentials {
        WebDavCredentials(url: settings.webdavUrl, username: settings.webdavUsername, password: settings.webdavPassword)
    }

    private var smbCredentials: SmbCredentials {
        SmbCredentials(host: settings.smbHost, share: settings.smbShare, basePath: settings.smbBasePath,
                       username: settings.smbUsername, password: settings.smbPassword)
    }

    func uploadToWebDAV(
        _ songs: [Song],
        onConflict: @escaping @Sendable (WebDavUploads.ConflictRequest) async -> WebDavUploads.Resolution
    ) async -> WebDavUploads.Summary {
        let items = songs.compactMap(uploadItem)
        let uploads = WebDavUploads(client: WebDavClient(), credentials: webDavCredentials, notifier: WebDavUploadLocalNotifier())
        var summary = await uploads.upload(items, onConflict: onConflict)
        // A song with no file behind it can't go up; it counts as failed rather than vanishing.
        summary.failed += songs.count - items.count
        return summary
    }

    /// The file behind a row: the verified saved file, else the row's own `file://` URI.
    private func uploadItem(_ song: Song) -> WebDavUploads.UploadItem? {
        let file = library.savedFileURL(for: song.videoId)
            ?? song.localUri.flatMap(URL.init(string:)).flatMap { $0.isFileURL ? $0 : nil }
        guard let file else { return nil }
        return WebDavUploads.UploadItem(id: song.videoId, fileURL: file, title: song.title, artist: song.artist)
    }

    func networkSettingsKey(_ kind: NetworkLibraryKind) -> String {
        // The password goes in hashed (the key lives only in memory): a corrected password is
        // the commonest fix for a server that refused the old login.
        switch kind {
        case .smb: return [settings.smbHost, settings.smbShare, settings.smbBasePath, settings.smbUsername,
                           String(settings.smbPassword.hashValue)].joined(separator: "|")
        case .webDAV: return [settings.webdavUrl, settings.webdavUsername, String(settings.webdavPassword.hashValue)].joined(separator: "|")
        }
    }

    func listNetworkLibrary(_ kind: NetworkLibraryKind) async -> LoadState<[Song]> {
        switch kind {
        case .smb:
            let credentials = smbCredentials
            let repository = SmbRepository(credentials: credentials,
                                           client: SmbClient(credentials: credentials, pool: model.smbPool(for: credentials)))
            return await NetworkListing.state(isConfigured: repository.isConfigured, emptyMessage: L10n.smbEmpty,
                                              songs: { await repository.getSongs() },
                                              probe: { try await repository.testConnection() })
        case .webDAV:
            let repository = WebDavRepository(credentials: webDavCredentials, client: WebDavClient())
            return await NetworkListing.state(isConfigured: repository.isConfigured, emptyMessage: L10n.webdavEmpty,
                                              songs: { await repository.getSongs() },
                                              probe: { try await repository.testConnection() })
        }
    }

    func remoteArtwork(for song: Song) async -> URL? {
        let smb = smbCredentials
        let access = RemoteLibraryAccess(
            smbClient: smb.isConfigured ? SmbClient(credentials: smb, pool: model.smbPool(for: smb)) : nil,
            smbShare: smb.share,
            webdav: settings.isWebDAVConfigured ? webDavCredentials : nil,
            settingsKey: networkSettingsKey(.smb) + "#" + networkSettingsKey(.webDAV)
        )
        return await covers.coverURL(for: song, access: access)
    }
}

/// One ``DownloadsService`` per running app, plus what the Downloads screens share across pages:
/// the WebDAV upload in flight and the clash it may be waiting on (MainActivity's
/// `uploadToWebDav` and its `WebDavConflictAlert`).
@MainActor
@Observable
final class DownloadsContext {
    @ObservationIgnored let service: DownloadsService
    /// Shows a one-line confirmation above the mini player (Android's queue-notice toast).
    @ObservationIgnored var notify: (String, String?) -> Void = { _, _ in }

    /// The clash the upload is waiting on, for the conflict prompt.
    private(set) var conflict: WebDavUploads.ConflictRequest?
    /// The prompt's "Apply to all" box.
    var applyToAll = false
    /// Bumped when an upload put something on the server, so an open WebDAV page lists again.
    private(set) var webDAVRevision = 0
    @ObservationIgnored private var pendingAnswer: CheckedContinuation<WebDavUploads.Resolution, Never>?
    /// The batch the next upload waits behind.
    @ObservationIgnored private var lastUpload: Task<Void, Never>?

    init(service: DownloadsService) {
        self.service = service
    }

    /// One context per model. The model is held weakly beside its context and checked on the way
    /// out: an identifier is only an address, and a model made where a released one lived (tests
    /// build many) must not inherit a context whose service points at the dead one.
    private struct Entry {
        weak var model: AppModel?
        let context: DownloadsContext
    }

    @ObservationIgnored private static var contexts: [ObjectIdentifier: Entry] = [:]

    static func shared(for model: AppModel) -> DownloadsContext {
        let key = ObjectIdentifier(model)
        if let entry = contexts[key], entry.model === model { return entry.context }
        var service: DownloadsService = LiveDownloadsService(model: model)
        #if DEBUG
        if let demo = DownloadsDemoService.requested() { service = demo }
        #endif
        let context = DownloadsContext(service: service)
        context.notify = { [weak model] message, symbol in model?.player.notice = QueueNotice(message: message, symbol: symbol) }
        contexts[key] = Entry(model: model, context: context)
        return context
    }

    /// Puts `context` in place for `model` (tests and the screenshot fixtures).
    static func install(_ context: DownloadsContext, for model: AppModel) {
        contexts[ObjectIdentifier(model)] = Entry(model: model, context: context)
    }

    // MARK: - WebDAV upload

    /// Copies tracks to the WebDAV server, leaving the local files alone. A clash suspends the batch
    /// on ``conflict`` until the prompt answers it, so this needs nothing more than the summary.
    func upload(_ songs: [Song]) async {
        guard !songs.isEmpty else { return }
        // Android's progress lived in a notification; iOS has no ongoing notifications (PORTING §4),
        // so the start of the batch is said in the app instead.
        notify(L10n.uploadingSongCount(songs.count), "arrow.up.circle")
        // One batch at a time: the prompt answers one clash, so a second batch must not take over
        // the clash the first one is waiting on.
        let previous = lastUpload
        let batch = Task { [weak self] in
            await previous?.value
            await self?.send(songs)
        }
        lastUpload = batch
        await batch.value
    }

    private func send(_ songs: [Song]) async {
        let summary = await service.uploadToWebDAV(songs) { [weak self] request in
            await self?.ask(request) ?? WebDavUploads.Resolution(choice: .skip, applyToAll: true)
        }
        if summary.total > 0 {
            notify(L10n.webdavUploadSummary(summary.uploaded, summary.skipped, summary.failed), nil)
        }
        if summary.uploaded > 0 { webDAVRevision += 1 }
    }

    private func ask(_ request: WebDavUploads.ConflictRequest) async -> WebDavUploads.Resolution {
        await withCheckedContinuation { continuation in
            pendingAnswer?.resume(returning: WebDavUploads.Resolution(choice: .skip))
            pendingAnswer = continuation
            applyToAll = false
            conflict = request
        }
    }

    /// The prompt's answer. Dismissing it without choosing is a skip, as on Android.
    func resolveConflict(_ choice: WebDavUploads.Choice) {
        let resolution = WebDavUploads.Resolution(choice: choice, applyToAll: applyToAll)
        conflict = nil
        let answer = pendingAnswer
        pendingAnswer = nil
        answer?.resume(returning: resolution)
    }
}
