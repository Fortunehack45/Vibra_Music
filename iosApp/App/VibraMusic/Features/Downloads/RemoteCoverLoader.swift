import VibraMusicCore
import CryptoKit
import Foundation
import ImageIO
import NetworkLibrary

// Ports the app side of ui/components/RemoteArtwork.kt (`rememberRemoteArtworkUrl`) and the Coil
// fetchers MainActivity registered for remote covers (SmbCoverFetcher, WebDavCoilAuth): a track on
// an SMB share or a WebDAV server has a cover the shared image loader can't fetch on its own — an
// `smb://` picture, a picture behind the server's login, or one embedded in the audio file itself.
// This turns each into a file on disk that ``ArtworkImage`` draws like any other.

/// How to reach the servers, snapshotted from settings on the main actor.
struct RemoteLibraryAccess: Sendable {
    var smbClient: SmbClient?
    var smbShare: String
    var webdav: WebDavCredentials?
    /// The server settings the access was built from: a miss remembered under one set is asked
    /// again under the next, since it may have been a share that refused the old login.
    var settingsKey: String
}

/// Covers for remote tracks, fetched once and kept under Caches.
actor RemoteCoverLoader {
    /// `Library/Caches/remote_covers`: the covers fetched from servers, and the embedded ones under
    /// `embedded/`.
    static let sharedDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "remote_covers", directoryHint: .isDirectory)
    static let shared = RemoteCoverLoader(directory: sharedDirectory)

    private let directory: URL
    private let session: URLSession
    private let embedded: RemoteArtworkStore
    /// What each track resolved to this run, misses included: a lazy list asks again every time a
    /// row scrolls back into view, and a track with no cover would otherwise cost a round of ranged
    /// requests to the server each time.
    private var memory: [String: URL?] = [:]
    /// Fetches running, per track.
    private var running: [String: Task<Fetched, Never>] = [:]

    /// What a fetch came to. A download refused as a page, or as an image that doesn't decode, is
    /// not remembered as a miss: once the user signs in to the portal, or a cut-off transfer is
    /// retried, the cover should appear without a relaunch.
    private struct Fetched {
        var url: URL?
        var retryable = false
    }

    init(directory: URL, session: URLSession = VibraMusicHTTP.session) {
        self.directory = directory
        self.session = session
        embedded = RemoteArtworkStore(cacheDirectory: directory.appending(path: "embedded", directoryHint: .isDirectory))
    }

    /// A URL ``ArtworkImage`` can draw for `song`, or nil when it has no cover anywhere.
    func coverURL(for song: Song, access: RemoteLibraryAccess) async -> URL? {
        let key = song.videoId + "|" + (song.thumbnailUrl ?? "") + "|" + access.settingsKey
        if let known = memory[key] { return known }
        // Unstructured, so a row scrolled away mid-fetch doesn't cancel it: a cancelled request
        // came back as "no cover" and was remembered as one for the rest of the run.
        let fetching = running[key] ?? Task { await fetch(song, access: access) }
        running[key] = fetching
        let fetched = await fetching.value
        if fetched.url != nil || !fetched.retryable { memory[key] = .some(fetched.url) }
        // Only this fetch's own entry: a retry may have been started since by another waiter.
        if running[key] == fetching { running[key] = nil }
        return fetched.url
    }

    private func fetch(_ song: Song, access: RemoteLibraryAccess) async -> Fetched {
        let isRemote = SmbConfig.isSmbId(song.videoId) || WebDavConfig.isWebDavId(song.videoId)
        guard let thumbnail = song.thumbnailUrl, !thumbnail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // No sidecar picture: the one inside the file, read with a few ranged requests.
            guard isRemote else { return Fetched() }
            let source = RemoteArtworkStore.Source(smbClient: access.smbClient, smbShare: access.smbShare,
                                                   webdavCredentials: access.webdav)
            return Fetched(url: await embedded.resolveArt(song, source: source))
        }
        if SmbConfig.isSmbUrl(thumbnail) {
            guard let client = access.smbClient else { return Fetched() }
            return await cached(thumbnail) {
                try await SmbArtworkLoader(client: client).load(thumbnail).data
            }
        }
        if WebDavConfig.isWebDavId(song.videoId), let credentials = access.webdav,
           let request = WebDavArtworkAuth.authorizedRequest(for: thumbnail, credentials: credentials) {
            return await cached(thumbnail) { [session] in
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                return data
            }
        }
        return Fetched(url: URL(string: thumbnail))
    }

    /// The picture at `source`, written under a hash of its address (addresses carry slashes and
    /// credentials that must never reach the file system).
    private func cached(_ source: String, load: @Sendable () async throws -> Data) async -> Fetched {
        let name = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appending(path: name)
        if FileManager.default.fileExists(atPath: file.path) { return Fetched(url: file) }
        guard let data = try? await load(), !data.isEmpty else { return Fetched() }
        // Only a picture: a captive portal answers with its sign-in page, which, once written here,
        // was the track's cover for good. And one that decodes, as ``ArtworkImageCache``
        // requires: a damaged image kept here would be served for good, while the cache deletes its
        // own copy and downloads it again. Decoded at a small size, which reads a large JPEG at a
        // fraction of the work and fails on damage alike.
        guard let image = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetType(image) != nil,
              ArtworkImageCache.decode(data, pixels: 128) != nil else { return Fetched(retryable: true) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try? data.write(to: file, options: .atomic)) != nil else { return Fetched() }
        return Fetched(url: file)
    }
}
