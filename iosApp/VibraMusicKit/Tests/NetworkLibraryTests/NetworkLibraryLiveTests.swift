// These live end-to-end tests launch local servers with Process, which only exists on the
// Mac host; on the iOS Simulator they compile out (they could never start a server there).
#if os(macOS)
import Foundation
import XCTest
@testable import NetworkLibrary

/// End to end against throwaway local servers, skipped unless
/// `VIBRAMUSIC_LIVE_TESTS=1`.
///
/// An impacket SMB2 server (with a username and password, on a high port so
/// no root is needed) shares a temp dir holding a generated FLAC and m4a
/// with embedded cover art plus a sidecar picture; a WsgiDAV server with
/// basic auth shares the same dir. The tests list, range-read and stream,
/// fetch cover art and (WebDAV) upload a local file.
///
/// The Python venv is taken from `VIBRAMUSIC_TEST_VENV`; the tests skip when
/// it is unset. Each test launches its own servers so runs
/// never share state.
final class NetworkLibraryLiveTests: XCTestCase {
    struct Endpoints {
        var smb: SmbCredentials
        var webdav: WebDavCredentials
        var share: URL
    }

    private var servers: LiveServers?

    override func setUp() async throws {
        try requireLiveTests()
        try await super.setUp()
    }

    override func tearDown() {
        servers?.stop()
        servers = nil
        super.tearDown()
    }

    // MARK: - SMB

    func testLiveSmbLibraryListsStreamsAndCovers() async throws {
        let live = try await launch()
        print("LIVE smb: \(live.smb.host):\(live.smb.port) share MUSIC")
        let pool = SmbConnectionPool(credentials: live.smb, factory: AmSmbSessionFactory(timeout: 15))
        let client = SmbClient(credentials: live.smb, pool: pool)

        let listing = try await client.listLibrary()
        print("LIVE smb listing: \(listing.audio.count) audio, \(listing.images.count) images")
        XCTAssertEqual(Set(listing.audio.map(\.path)), ["Album/Artist - Title.flac", "Album/Track.m4a"])
        XCTAssertEqual(listing.images.map(\.path), ["Album/cover.jpg"])

        let repository = SmbRepository(credentials: live.smb, client: client)
        let songs = await repository.getSongs()
        XCTAssertEqual(songs.count, 2)
        let flac = try XCTUnwrap(songs.first { $0.title == "Title" })
        XCTAssertEqual(flac.artist, "Artist")
        XCTAssertEqual(flac.albumName, "Album")
        XCTAssertTrue(flac.thumbnailUrl?.hasSuffix("Album/cover.jpg") ?? false)

        // Range reads serve the exact bytes for the cache to stream.
        let local = try Data(contentsOf: live.share.appendingPathComponent("Album/Artist - Title.flac"))
        let source = SmbAudioSource(streamURL: flac.localUri ?? "", client: client)
        let info = try await source.contentInfo()
        XCTAssertEqual(info.contentLength, Int64(local.count))
        XCTAssertEqual(info.mimeType, "audio/flac")
        let head = try await source.read(0..<1024)
        XCTAssertEqual(head, local.prefix(1024))
        let mid = try await source.read(70_000..<71_000)
        XCTAssertEqual(mid, local[70_000..<71_000])
        var streamed = Data()
        for try await piece in source.stream(0..<Int64(local.count)) {
            streamed.append(piece)
        }
        XCTAssertEqual(streamed, local)

        // Embedded art comes out over share offsets…
        let embedded = await RemoteArtReader.picture(
            url: flac.localUri ?? "", isSmb: true,
            session: .shared, smbClient: client, smbShare: live.smb.share
        )
        XCTAssertEqual(embedded?.mime, "image/png")
        XCTAssertEqual(embedded?.bytes, LiveMedia.png)
        // …and the sidecar loads byte-identical.
        let loader = SmbArtworkLoader(client: client)
        XCTAssertTrue(loader.supports(flac.thumbnailUrl ?? ""))
        let sidecar = try await loader.load(flac.thumbnailUrl ?? "")
        XCTAssertEqual(sidecar.data, LiveMedia.sidecarJpeg)
    }

    // MARK: - WebDAV

    func testLiveWebDavLibraryStreamsUploadsAndCovers() async throws {
        let live = try await launch()
        print("LIVE webdav: \(live.webdav.rootUrl)")
        let client = WebDavClient()
        let credentials = live.webdav

        try await client.testConnection(credentials)
        let listing = try await client.listLibrary(credentials)
        print("LIVE webdav listing: \(listing.audio.count) audio, \(listing.images.count) images")
        XCTAssertEqual(Set(listing.audio.map { $0.url.split(separator: "/").last.map(String.init) ?? "" }),
                       ["Artist%20-%20Title.flac", "Track.m4a"])
        XCTAssertEqual(listing.images.count, 1)

        let repository = WebDavRepository(credentials: credentials, client: client)
        let songs = await repository.getSongs()
        XCTAssertEqual(songs.count, 2)
        let flac = try XCTUnwrap(songs.first { $0.title == "Title" })
        let fileUrl = try XCTUnwrap(flac.localUri)

        let local = try Data(contentsOf: live.share.appendingPathComponent("Album/Artist - Title.flac"))
        let source = WebDavAudioSource(fileURL: fileUrl, client: client, credentials: credentials)
        let info = try await source.contentInfo()
        XCTAssertEqual(info.contentLength, Int64(local.count))
        let head = try await source.read(0..<1024)
        XCTAssertEqual(head, local.prefix(1024))

        // Embedded art over HTTP ranges…
        let embedded = await RemoteArtReader.picture(
            url: fileUrl, isSmb: false,
            session: .shared, smbClient: nil, smbShare: "",
            webdavCredentials: credentials
        )
        XCTAssertEqual(embedded?.mime, "image/png")
        XCTAssertEqual(embedded?.bytes, LiveMedia.png)
        // …while the row prefers the sidecar filed beside the music.
        XCTAssertTrue(flac.thumbnailUrl?.hasSuffix("Album/cover.jpg") ?? false)

        // Upload a local file, then read it back.
        let uploadDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: uploadDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: uploadDir) }
        let payload = Data((0..<50_000).map { _ in UInt8.random(in: 0...255) })
        let localFile = uploadDir.appendingPathComponent("local.mp3")
        try payload.write(to: localFile)
        let uploader = WebDavUploads(client: client, credentials: credentials)
        let summary = await uploader.upload([
            WebDavUploads.UploadItem(id: "upload-1", fileURL: localFile, title: "Upload", artist: "Me"),
        ])
        XCTAssertEqual(summary.uploaded, 1)
        let target = WebDavClient.joinUrl(
            root: credentials.rootUrl,
            segment: WebDavClient.uploadFileName(title: "Upload", artist: "Me", fileExtension: "mp3")
        )
        print("LIVE webdav uploaded: \(target)")
        let present = try await client.exists(fileUrl: target, credentials: credentials)
        XCTAssertTrue(present)
        let roundTripped = try await client.readRange(fileURL: target, range: 0..<Int64(payload.count), credentials: credentials)
        XCTAssertEqual(roundTripped, payload)
    }

    // MARK: - Harness

    private func launch() async throws -> Endpoints {
        let servers = try await LiveServers.launch()
        self.servers = servers
        return servers.endpoints
    }
}

// MARK: - Throwaway servers

/// An impacket SMB2 server and a basic-auth WsgiDAV server sharing one
/// generated library, started on high ports and stopped afterwards.
private final class LiveServers {
    let endpoints: NetworkLibraryLiveTests.Endpoints
    private let processes: [Process]
    private let directory: URL

    static func launch() async throws -> LiveServers {
        guard let venv = ProcessInfo.processInfo.environment["VIBRAMUSIC_TEST_VENV"] else {
            throw XCTSkip("Set VIBRAMUSIC_TEST_VENV to a Python venv with impacket and WsgiDAV to run tests against the local SMB/WebDAV servers")
        }
        let venvURL = URL(fileURLWithPath: venv)
        for binary in ["bin/python", "bin/smbserver.py", "bin/wsgidav"] {
            guard FileManager.default.isExecutableFile(atPath: venvURL.appendingPathComponent(binary).path) else {
                throw XCTSkip("Missing \(binary) in \(venv)")
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vibramusic-netlib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Album"), withIntermediateDirectories: true)
        try LiveMedia.writeLibrary(to: directory)

        let smbPort = 14445
        let davPort = 18082
        let config = directory.appendingPathComponent("wsgidav.yaml")
        try """
            host: 127.0.0.1
            port: \(davPort)
            provider_mapping:
              "/": "\(directory.path(percentEncoded: false))"
            simple_dc:
              user_mapping:
                "*":
                  testuser:
                    password: testpass
            """.write(to: config, atomically: true, encoding: .utf8)

        let smb = Process()
        smb.executableURL = venvURL.appendingPathComponent("bin/python")
        smb.arguments = [
            venvURL.appendingPathComponent("bin/smbserver.py").path,
            "-username", "testuser", "-password", "testpass",
            "-smb2support", "-port", "\(smbPort)", "MUSIC",
            directory.path(percentEncoded: false),
        ]
        let dav = Process()
        dav.executableURL = venvURL.appendingPathComponent("bin/wsgidav")
        dav.arguments = ["--config", config.path(percentEncoded: false)]
        for process in [smb, dav] {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        }
        let servers = LiveServers(
            endpoints: NetworkLibraryLiveTests.Endpoints(
                smb: SmbCredentials(host: "127.0.0.1:\(smbPort)", share: "MUSIC", username: "testuser", password: "testpass"),
                webdav: WebDavCredentials(url: "http://127.0.0.1:\(davPort)", username: "testuser", password: "testpass"),
                share: directory
            ),
            processes: [smb, dav],
            directory: directory
        )
        do {
            try await servers.waitReady(smbPort: smbPort, davPort: davPort)
        } catch {
            servers.stop()
            throw error
        }
        return servers
    }

    private init(endpoints: NetworkLibraryLiveTests.Endpoints, processes: [Process], directory: URL) {
        self.endpoints = endpoints
        self.processes = processes
        self.directory = directory
    }

    private func waitReady(smbPort: Int, davPort: Int) async throws {
        let deadline = Date().addingTimeInterval(45)
        // WebDAV first: plain HTTP polling.
        while Date() < deadline {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(davPort)/")!)
            request.httpMethod = "PROPFIND"
            request.setValue("0", forHTTPHeaderField: "Depth")
            request.setValue("Basic " + Data("testuser:testpass".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let code = (response as? HTTPURLResponse)?.statusCode, code == 207
            {
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        // Then SMB: a real connect through the production factory.
        let factory = AmSmbSessionFactory(timeout: 4)
        let credentials = endpoints.smb
        while Date() < deadline {
            if let session = try? await factory.connect(credentials),
               (try? await session.listDirectory("")) != nil
            {
                await session.close()
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw WebDavError("Local SMB/WebDAV servers did not start")
    }

    func stop() {
        for process in processes where process.isRunning {
            process.terminate()
        }
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - Generated library

/// A FLAC and an m4a with real embedded pictures, plus a sidecar cover.
private enum LiveMedia {
    /// A 1×1 PNG used as the embedded picture.
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
    /// Sidecar bytes with a JPEG magic, so loaders sniff the right type.
    static let sidecarJpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data("vibramusic-sidecar".utf8)

    static func writeLibrary(to directory: URL) throws {
        let album = directory.appendingPathComponent("Album")
        try flac(title: "Artist - Title", picture: png, fillerBytes: 128_000)
            .write(to: album.appendingPathComponent("Artist - Title.flac"))
        try m4a(picture: sidecarJpeg, fillerBytes: 96_000)
            .write(to: album.appendingPathComponent("Track.m4a"))
        try sidecarJpeg.write(to: album.appendingPathComponent("cover.jpg"))
    }

    static func flac(title _: String, picture: Data, fillerBytes: Int) -> Data {
        var out = Data("fLaC".utf8)
        out += flacBlock(type: 0, payload: Data(repeating: 0, count: 34), last: false)
        let mime = Data("image/png".utf8)
        let payload = u32be(3) + u32be(mime.count) + mime + u32be(0)
            + Data(repeating: 0, count: 16) + u32be(picture.count) + picture
        out += flacBlock(type: 6, payload: payload, last: true)
        out += Data(repeating: 0xA5, count: fillerBytes)
        return out
    }

    private static func flacBlock(type: UInt8, payload: Data, last: Bool) -> Data {
        let length = payload.count
        return Data([(last ? 0x80 : 0) | type,
                     UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]) + payload
    }

    static func m4a(picture: Data, fillerBytes: Int) -> Data {
        let data = u32be(13) + u32be(0) + picture
        let moov = box("moov", box("udta", box("meta", Data([0, 0, 0, 0]) + box("ilst", box("covr", box("data", data))))))
        return box("ftyp", Data("isom".utf8)) + box("mdat", Data(repeating: 0x5A, count: fillerBytes)) + moov
    }

    private static func box(_ type: String, _ payload: Data) -> Data {
        u32be(8 + payload.count) + Data(type.utf8) + payload
    }

    private static func u32be(_ value: Int) -> Data {
        Data([UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
              UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }
}
#endif
