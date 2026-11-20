import VibraMusicCore
import Downloads
import Foundation
import InnerTube
import NetworkLibrary
import SwiftUI
import XCTest
@testable import VibraMusic

// A stand-in for the Downloads screens' outside world, over a real DownloadLibrary on a throwaway
// store (so deletes really delete and free real bytes), and the helpers that host a Downloads screen
// in the unit-test host.

@MainActor
final class FakeDownloadsService: DownloadsService {
    let library: DownloadLibrary
    let session = DownloadSession()
    var remote: [NetworkLibraryKind: LoadState<[Song]>] = [:]
    var webDAVConfigured = true
    var conflictOnUpload = false
    private(set) var cancelled: [String] = []
    private(set) var retried: [String] = []
    private(set) var uploaded: [[Song]] = []
    private(set) var listed: [NetworkLibraryKind] = []
    /// Every folder read, so a render test can tell the page loaded itself.
    private(set) var folderReads: [LocalFolder] = []

    init(library: DownloadLibrary) {
        self.library = library
    }

    var libraryVersion: Int {
        var hasher = Hasher()
        hasher.combine(library.saved)
        hasher.combine(library.records.count)
        return hasher.finalize()
    }

    func songs(in folder: LocalFolder) -> [Song] {
        folderReads.append(folder)
        return library.songs(includeImported: true)
    }
    func collections(among songs: [Song]) -> [DownloadedCollection] { library.collectionsAmong(songs) }
    func isDownloaded(_ videoId: String) -> Bool { library.isDownloaded(videoId) }
    func delete(_ videoIds: [String]) -> DownloadDeletion { library.delete(videoIds) }
    func importFiles(at urls: [URL]) async -> LocalImportResult {
        await LocalMusicImporter(library: library).importItems(at: urls)
    }
    func cancelDownload(_ videoId: String) {
        cancelled.append(videoId)
        session.forget(videoId)
    }
    func retryDownload(_ videoId: String) {
        retried.append(videoId)
        if let item = session.item(videoId) { session.queued(item.song, from: item.from) }
    }
    var isWaitingForWiFi = false

    var canUploadToWebDAV: Bool { webDAVConfigured }

    func uploadToWebDAV(
        _ songs: [Song],
        onConflict: @escaping @Sendable (WebDavUploads.ConflictRequest) async -> WebDavUploads.Resolution
    ) async -> WebDavUploads.Summary {
        uploaded.append(songs)
        var skipped = 0
        if conflictOnUpload, let first = songs.first, let file = URL(string: first.localUri ?? "file:///x.m4a") {
            let item = WebDavUploads.UploadItem(id: first.videoId, fileURL: file, title: first.title, artist: first.artist)
            let answer = await onConflict(WebDavUploads.ConflictRequest(item: item, fileName: "\(first.title).m4a",
                                                                       remaining: songs.count - 1))
            if answer.choice == .skip { skipped = 1 }
        }
        return WebDavUploads.Summary(uploaded: songs.count - skipped, skipped: skipped, failed: 0)
    }

    func networkSettingsKey(_ kind: NetworkLibraryKind) -> String { kind.rawValue }

    func listNetworkLibrary(_ kind: NetworkLibraryKind) async -> LoadState<[Song]> {
        listed.append(kind)
        return remote[kind] ?? .error(kind == .smb ? L10n.smbEmpty : L10n.webdavEmpty)
    }

    func remoteArtwork(for song: Song) async -> URL? { nil }
}

/// A library on a fresh store under the temporary directory.
@MainActor
func makeTestDownloadLibrary(_ test: XCTestCase) -> DownloadLibrary {
    let root = makeTemporaryDirectory(test).appending(path: "Downloads", directoryHint: .isDirectory)
    let store = DownloadStore(root: root)
    try? store.prepare()
    return DownloadLibrary(store: store)
}

/// Real, distinct audio files imported into `library` (a Files import — the Local Music path), so
/// rows have files with bytes behind them.
@MainActor
func importTones(_ count: Int, into library: DownloadLibrary, test: XCTestCase) async throws -> [Song] {
    let directory = makeTemporaryDirectory(test)
    var urls: [URL] = []
    for index in 0..<count {
        // Different lengths, so the importer's content-hash dedupe keeps every one.
        urls.append(try TestAudio.tone(seconds: 1 + Double(index) * 0.5, format: .m4a, in: directory, name: "Tone \(index + 1)"))
    }
    let result = await LocalMusicImporter(library: library).importItems(at: urls)
    XCTAssertEqual(result.imported.count, count, "skipped: \(result.skipped)")
    return result.imported
}

/// An app to host Downloads screens in, with `service` installed as its Downloads context.
@MainActor
func makeDownloadsTestModel(_ test: XCTestCase, service: FakeDownloadsService) -> (AppModel, DownloadsContext) {
    let suite = "vibramusic.downloads.tests.\(UUID().uuidString)"
    var launch = AppLaunchOptions()
    launch.restoresQueue = false
    launch.integratesWithSystem = false
    let model = AppModel(
        settings: makeTestSettings(),
        likeState: LikeState(),
        searchHistory: SearchHistory(defaults: UserDefaults(suiteName: suite)!),
        network: NetworkMonitor(),
        innerTube: InnerTubeClient(),
        audioCache: nil,
        launch: launch
    )
    let context = DownloadsContext(service: service)
    context.notify = { [weak model] message, symbol in model?.player.notice = QueueNotice(message: message, symbol: symbol) }
    DownloadsContext.install(context, for: model)
    let engine = model.engine
    test.addTeardownBlock { @MainActor in engine.shutdown() }
    return (model, context)
}

/// Fixture rows.
enum DownloadsFixtures {
    static func song(_ id: String, _ title: String, artist: String = "Daft Punk", album: String? = nil,
                     added: Int64? = nil) -> Song {
        Song(videoId: id, title: title, artist: artist, durationText: "3:30", albumName: album,
             localUri: "file:///tmp/\(id).m4a", localDateAddedSeconds: added, localDateModifiedSeconds: added)
    }
}

/// An SMB share held in memory: display path → bytes.
struct MemorySmbShare: SmbShareSession {
    let files: [String: Data]

    func listDirectory(_ path: String) async throws -> [SmbDirectoryEntry] {
        let prefix = path.isEmpty ? "" : path + "/"
        var seen: [String: SmbDirectoryEntry] = [:]
        for (file, data) in files where file.hasPrefix(prefix) {
            let rest = file.dropFirst(prefix.count)
            let parts = rest.split(separator: "/", maxSplits: 1)
            guard let name = parts.first.map(String.init) else { continue }
            seen[name] = SmbDirectoryEntry(name: name, isDirectory: parts.count > 1, size: parts.count > 1 ? 0 : Int64(data.count))
        }
        return Array(seen.values)
    }

    func fileSize(_ path: String) async throws -> Int64 { Int64(files[path]?.count ?? 0) }

    func readFile(_ path: String, range: Range<Int64>) async throws -> Data {
        guard let data = files[path] else { throw SmbError.notAFile(path) }
        let upper = min(Int(range.upperBound), data.count)
        return data.subdata(in: Int(range.lowerBound)..<upper)
    }

    func close() async {}
}

struct MemorySmbFactory: SmbSessionFactory {
    var share: MemorySmbShare?
    var failure: Error?

    func connect(_ credentials: SmbCredentials) async throws -> any SmbShareSession {
        if let failure { throw failure }
        return share ?? MemorySmbShare(files: [:])
    }
}

/// Hosting asserts that the page drew at phone size. (SwiftUI builds no accessibility tree in the
/// unit-test host without an assistive client, so rendered text can't be read back here; what a page
/// shows is checked through its state and the service calls its tasks made.)
@MainActor
func assertDrew(_ controller: UIViewController, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(controller.view.bounds.width, 393, file: file, line: line)
    XCTAssertGreaterThan(controller.view.bounds.height, 0, file: file, line: line)
    XCTAssertNotNil(controller.view.window, file: file, line: line)
}
