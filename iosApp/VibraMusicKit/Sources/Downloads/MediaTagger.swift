import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VibraMusicCore

// Ports download/MediaTagger.kt.

/// A cover to embed: the image bytes and what they are.
public struct DownloadArtwork: Hashable, Sendable {
    public let data: Data
    public let mime: String

    public init(data: Data, mime: String) {
        self.data = data
        self.mime = mime
    }
}

/// Embeds title, artist, album, lyrics and cover art into a track the queue just finished saving,
/// so it reads correctly in Files, a share target or another player rather than only inside this
/// app.
///
/// Best-effort throughout, deliberately: the cover fetch is a network call that can fail for reasons
/// that have nothing to do with the download that already succeeded, and both taggers return nil on
/// anything they don't recognise. Every step here is caught rather than left to propagate — a
/// tagging failure costs the tags, not the file.
///
/// An actor so one rewrite runs at a time across every download worker. Not about correctness —
/// the workers write different files — but about memory: an M4A rewrite holds the track and a
/// tagged copy at once, and on iOS a background relaunch runs under a much tighter memory limit
/// than the foreground app. FLAC, the large format, is streamed instead (see ``embed``).
actor MediaTagger {
    let store: DownloadStore
    let http: URLSession

    init(store: DownloadStore, http: URLSession) {
        self.store = store
        self.http = http
    }

    /// Long side of the embedded cover — plenty for a lock screen or CarPlay, without ballooning the
    /// file.
    static let coverMaxSide = 1000

    /// How much of a FLAC has to be read to be sure the whole metadata chain is in hand. Enormously
    /// more than any real file needs; guessing short only costs a fall back to the in-memory path.
    static let flacHeadBytes = 16 * 1024 * 1024

    /// The containers there is a tagger for. WebM is gone on iOS (AVPlayer can't play it, so nothing
    /// saves one); WAV keeps the tags its filename carries and nothing more, as on Android — its
    /// RIFF metadata is ignored by a good number of players.
    static let taggable: Set<String> = ["m4a", "flac"]

    /// Whether a file of `ext` gets tags at all. Asked before fetching anything that exists only to
    /// be tagged, so a `.wav` download doesn't spend lyric lookups on a field it has nowhere to put.
    static func carriesTags(_ ext: String) -> Bool { taggable.contains(ext.lowercased()) }

    // MARK: Artwork

    /// The cover for `track`: the sidecar already saved for its URL, or a fresh fetch at 1200 px,
    /// scaled to ``coverMaxSide`` and re-encoded as JPEG.
    nonisolated func artwork(for track: Song, allowsMeteredNetwork: Bool = true) async -> DownloadArtwork? {
        guard let source = track.thumbnailUrl, !source.isBlank else {
            // Said out loud rather than returned as a quiet null: an album's own track rows carry
            // no artwork (the release is billed once, in the header), so a row that gets this far
            // without the release's cover stamped on saves a file with no cover, permanently.
            DebugLog.d("Downloads", "no artwork url for \(track.videoId); saving it without a cover")
            return nil
        }
        if let cached = cachedArtwork(source) { return cached }
        guard let url = URL(string: track.artworkAt(1200) ?? source) else { return nil }
        return await fetchCover(url, allowsMeteredNetwork: allowsMeteredNetwork, logId: track.videoId)
    }

    /// Keeps a local copy of `artwork` under `Artwork/`, named by a hash of `sourceUrl` so an
    /// album's tracks share one file. Returns its path relative to the store root.
    ///
    /// The app draws a downloaded track's cover from this rather than from the tags, so the
    /// Downloads page never depends on re-reading every file, and a collection record keeps an
    /// image that works offline.
    nonisolated func persistArtwork(sourceUrl: String?, artwork: DownloadArtwork?) -> String? {
        guard let sourceUrl, !sourceUrl.isBlank, let artwork, !artwork.data.isEmpty else { return nil }
        let name = Self.artworkFileName(sourceUrl)
        let target = store.artworkDirectory.appending(path: name, directoryHint: .notDirectory)
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: target.path(percentEncoded: false)) {
            do {
                try store.prepare()
                // Written beside and renamed, so two workers saving one album's cover never leave
                // a half-written image for the other to read.
                let temp = store.artworkDirectory.appending(path: ".\(name)-\(UUID().uuidString).part")
                try artwork.data.write(to: temp)
                if (try? fileManager.moveItem(at: temp, to: target)) == nil { try? fileManager.removeItem(at: temp) }
            } catch {
                DebugLog.w("Downloads", "could not save artwork sidecar", error: error)
                return nil
            }
        }
        return "\(DownloadStore.artworkFolder)/\(name)"
    }

    /// Fetch and keep a collection cover before its remote URL goes stale. Returns the relative path.
    nonisolated func cacheArtwork(sourceUrl: String?, allowsMeteredNetwork: Bool = true) async -> String? {
        guard let sourceUrl, !sourceUrl.isBlank else { return nil }
        let name = Self.artworkFileName(sourceUrl)
        if FileManager.default.fileExists(atPath: store.artworkDirectory.appending(path: name).path(percentEncoded: false)) {
            return "\(DownloadStore.artworkFolder)/\(name)"
        }
        guard let url = URL(string: Artwork.resized(sourceUrl, to: 1200) ?? sourceUrl),
              let artwork = await fetchCover(url, allowsMeteredNetwork: allowsMeteredNetwork, logId: "collection") else { return nil }
        return persistArtwork(sourceUrl: sourceUrl, artwork: artwork)
    }

    nonisolated static func artworkFileName(_ sourceUrl: String) -> String {
        SHA256.hash(data: Data(sourceUrl.utf8)).map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    private nonisolated func cachedArtwork(_ sourceUrl: String) -> DownloadArtwork? {
        let url = store.artworkDirectory.appending(path: Self.artworkFileName(sourceUrl))
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return DownloadArtwork(data: data, mime: "image/jpeg")
    }

    private nonisolated func fetchCover(_ url: URL, allowsMeteredNetwork: Bool, logId: String) async -> DownloadArtwork? {
        var request = URLRequest(url: url)
        request.allowsExpensiveNetworkAccess = allowsMeteredNetwork
        request.allowsConstrainedNetworkAccess = allowsMeteredNetwork
        do {
            let (data, response) = try await http.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status),
                  let jpeg = Self.normalizedCover(data) else { return nil }
            return DownloadArtwork(data: jpeg, mime: "image/jpeg")
        } catch {
            DebugLog.d("Downloads", "no cover saved for \(logId): \(error.localizedDescription)")
            return nil
        }
    }

    /// `raw` decoded, scaled so its long side is at most `maxSide` (never up), and re-encoded as a
    /// quality-92 JPEG. Nil when the bytes aren't an image.
    nonisolated static func normalizedCover(_ raw: Data, maxSide: Int = coverMaxSide) -> Data? {
        guard let source = CGImageSourceCreateWithData(raw as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    // MARK: Tagging

    /// Writes the tags into `file` (the part file, before it is published — so concurrent album
    /// workers never expose an untagged track). Returns whether the file was rewritten.
    @discardableResult
    func embed(file: URL, track: Song, extension ext: String, lyrics: DownloadLyrics?, artwork: DownloadArtwork?) -> Bool {
        guard Self.carriesTags(ext) else { return false }
        // The portable field and this app's own, split here so both taggers agree on which string
        // goes where.
        let plain = lyrics?.plain
        let words = lyrics?.enhanced
        let isPng = artwork.map { ImageKind.sniff($0.data) == .png || $0.mime.contains("png") } ?? false

        if ext.lowercased() == "flac", let done = tagFlacStreaming(file: file, track: track, lyrics: plain, words: words, artwork: artwork) {
            return done
        }
        guard let original = try? Data(contentsOf: file, options: .alwaysMapped) else {
            DebugLog.w("Downloads", "could not read \(file.lastPathComponent) for tagging")
            return false
        }
        let tagged: Data?
        switch ext.lowercased() {
        case "m4a":
            tagged = Mp4Tagger.tag(original, title: track.title, artist: track.artist, album: track.albumName,
                                   lyrics: plain, cover: artwork?.data, coverIsPng: isPng, wordLyrics: words)
        default:
            tagged = FlacTagger.tag(original, title: track.title, artist: track.artist, album: track.albumName,
                                    lyrics: plain, cover: artwork?.data, coverMime: artwork?.mime ?? "image/jpeg", wordLyrics: words)
        }
        guard let tagged else { return false }
        do {
            let temp = file.deletingLastPathComponent().appending(path: ".\(file.lastPathComponent).tagging")
            try tagged.write(to: temp)
            _ = try FileManager.default.replaceItemAt(file, withItemAt: temp)
            return true
        } catch {
            DebugLog.w("Downloads", "could not write tags to \(file.lastPathComponent)", error: error)
            return false
        }
    }

    /// Tags a FLAC without ever holding it in memory: read the front, ask ``FlacTagger/header`` for
    /// the replacement metadata region and where the frames start, then stream the frames through.
    ///
    /// - Returns: true/false when the file has been dealt with (rewritten, or found to have nothing
    ///   to write); nil asks the caller to fall back to the in-memory path, which happens only for a
    ///   metadata region larger than ``flacHeadBytes`` or an I/O failure. The original is untouched
    ///   until the finished copy replaces it in one move.
    private func tagFlacStreaming(file: URL, track: Song, lyrics: String?, words: String?, artwork: DownloadArtwork?) -> Bool? {
        guard let reader = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? reader.close() }
        guard let head = try? reader.read(upToCount: Self.flacHeadBytes) else { return nil }
        // Short of the cap means the read hit the end of the file, so a refusal below is final.
        let wholeFile = head.count < Self.flacHeadBytes
        guard let rewrite = FlacTagger.header(head, title: track.title, artist: track.artist, album: track.albumName,
                                              lyrics: lyrics, cover: artwork?.data, coverMime: artwork?.mime ?? "image/jpeg",
                                              wordLyrics: words) else {
            return wholeFile ? false : nil
        }
        let temp = file.deletingLastPathComponent().appending(path: ".\(file.lastPathComponent).tagging")
        do {
            FileManager.default.createFile(atPath: temp.path(percentEncoded: false), contents: nil)
            let writer = try FileHandle(forWritingTo: temp)
            defer { try? writer.close() }
            try writer.write(contentsOf: rewrite.metadata)
            try reader.seek(toOffset: UInt64(rewrite.audioStart))
            while let chunk = try reader.read(upToCount: 64 * 1024), !chunk.isEmpty {
                try writer.write(contentsOf: chunk)
            }
            try writer.synchronize()
            _ = try FileManager.default.replaceItemAt(file, withItemAt: temp)
            return true
        } catch {
            DebugLog.w("Downloads", "streaming flac tag failed for \(track.videoId)", error: error)
            try? FileManager.default.removeItem(at: temp)
            return nil
        }
    }
}

// MARK: - Lyrics (Android LyricsTag)

/// The lyrics to write into a track being saved: the same lookup the player does, turned into text a
/// container can hold. Android's `LyricsTag`; the lookup itself is the Lyrics module's, passed in as
/// a ``DownloadLyricsProvider``.
///
/// Gated on ``AppSettings/syncedLyrics`` and ``AppSettings/lyricsSources`` rather than on a switch of
/// its own: those settings are about whether this app may contact third-party lyric services at
/// all, and a download quietly asking a source the user unticked would be the request they said no
/// to, made somewhere they weren't looking.
///
/// Never throws. A download that has otherwise succeeded must not be undone by a lyrics server being
/// down.
enum LyricsEmbedding {
    /// The most LRC one track may contribute to its own file. An order of magnitude clear of
    /// anything genuine: a ceiling on a malformed or hostile response, not a judgement about songs.
    static let maxLrcCharacters = 64_000

    /// How long the lookup may hold a finished download up. Usually nothing: it starts alongside
    /// the transfer. Bounds the *wait*: a provider that ignores cancellation is left to finish on its
    /// own while the queue moves on.
    static let lookupSeconds: Double = 30

    static func fetch(_ provider: DownloadLyricsProvider?, track: Song, timeout: Double) async -> DownloadLyrics? {
        guard let provider else { return nil }
        if track.durationMillis <= 0 {
            // Album and playlist rows don't always carry a duration; the title, artist and album
            // still give the providers a useful match.
            DebugLog.d("Downloads", "no duration for \(track.videoId); looking up lyrics by title and artist")
        }
        let found = await withTimeout(seconds: timeout) {
            do {
                return try await provider(track)
            } catch {
                DebugLog.d("Downloads", "no lyrics for \(track.videoId): \(error.localizedDescription)")
                return nil
            }
        }
        return sanitized(found ?? nil)
    }

    /// Applies the Android checks to what a provider returned.
    static func sanitized(_ lyrics: DownloadLyrics?) -> DownloadLyrics? {
        guard let lyrics else { return nil }
        // A result made only of timestamps is what an instrumental, or a provider that answered
        // with timing and no words, comes back as. That is not lyrics, and it isn't blank either.
        guard hasWords(lyrics.plain) else { return nil }
        guard lyrics.plain.count <= maxLrcCharacters else {
            DebugLog.w("Downloads", "lyrics are \(lyrics.plain.count) chars; not embedding")
            return nil
        }
        // The word stamps roughly double the size, so the enhanced form gets its own headroom
        // rather than sharing the budget and pushing the portable field out.
        let enhanced = lyrics.enhanced.flatMap { !$0.isBlank && $0.count <= maxLrcCharacters * 2 ? $0 : nil }
        return DownloadLyrics(plain: lyrics.plain, enhanced: enhanced)
    }

    /// Whether any line has text once its `[mm:ss.xx]` / `<mm:ss.xx>` stamps and `[tag:value]`
    /// headers are taken away.
    static func hasWords(_ lrc: String) -> Bool {
        lrc.split(whereSeparator: \.isNewline).contains { line in
            let stripped = String(line)
                .replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"<\d+:\d+(?:[.:]\d+)?>"#, with: "", options: .regularExpression)
            return !stripped.isBlank
        }
    }
}

// MARK: - Timeout

/// Runs `operation`, returning nil if it hasn't finished within `seconds` (or the caller is
/// cancelled). The operation is cancelled but not awaited on timeout, so one that ignores
/// cancellation can't hold the caller.
func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async -> T) async -> T? {
    let race = TimeoutRace<T>()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            race.arm(continuation)
            let work = Task {
                let value = await operation()
                race.finish(value)
            }
            race.onCancel { work.cancel() }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                race.finish(nil)
                work.cancel()
            }
        }
    } onCancel: {
        race.finish(nil)
    }
}

private final class TimeoutRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    private var finished = false
    private var pendingResult: T??
    private var cancelWork: (() -> Void)?

    func arm(_ continuation: CheckedContinuation<T?, Never>) {
        let early: T?? = lock.withLock {
            if finished { return pendingResult }
            self.continuation = continuation
            return nil
        }
        if let early { continuation.resume(returning: early) }
    }

    func onCancel(_ cancel: @escaping () -> Void) {
        lock.withLock { cancelWork = cancel }
    }

    func finish(_ value: T?) {
        let (continuation, cancel): (CheckedContinuation<T?, Never>?, (() -> Void)?) = lock.withLock {
            guard !finished else { return (nil, nil) }
            finished = true
            pendingResult = .some(value)
            defer { self.continuation = nil }
            return (self.continuation, value == nil ? cancelWork : nil)
        }
        continuation?.resume(returning: value)
        cancel?()
    }
}
