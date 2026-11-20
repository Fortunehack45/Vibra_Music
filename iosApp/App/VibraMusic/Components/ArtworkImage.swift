import VibraMusicCore
import CryptoKit
import ImageIO
import os
import SwiftUI
import Theming
import UIKit

// Ports ui/components/RemoteArtwork.kt and the image loader VibraMusicApplication.kt configured for
// Coil: a memory cache sized to a share of RAM under an absolute ceiling, a 100 MB disk cache
// under Caches, and a short fade so covers develop rather than flicker in.

/// Artwork loading with a memory and a disk cache. Thread-safe; one per process.
final class ArtworkImageCache: @unchecked Sendable {
    static let shared = ArtworkImageCache()

    /// Coil's disk budget in VibraMusicApplication.kt.
    static let diskLimitBytes: Int64 = 100 * 1024 * 1024

    /// Coil sizes its memory cache as a share of the *app's* memory; a share of device RAM grows
    /// with the phone instead, so the budget is also held to an absolute ceiling. Android's own
    /// 20% of a 256-512 MB heap is 50-100 MB, so 150 MB is an Android-scale figure with headroom.
    static let memoryBudgetCeilingBytes: Int = 150 * 1024 * 1024

    /// The decoded-image budget for a device with `physicalMemory` bytes of RAM: 20% of RAM,
    /// as Android's MemoryCache.maxSizePercent(0.20), counted in decoded bytes, and never over
    /// ``memoryBudgetCeilingBytes`` whatever the device ships with.
    static func memoryBudgetBytes(physicalMemory: UInt64) -> Int {
        min(Int(Double(physicalMemory) * 0.2), memoryBudgetCeilingBytes)
    }

    /// What this cache's memory budget came out at, in decoded bytes.
    let memoryBudgetBytes: Int

    /// Decoded covers, one per URL and drawn size (see ``memoryKey(_:_:)``).
    private let memory = NSCache<NSString, UIImage>()
    private let directory: URL
    private let session: URLSession
    private let lock = NSLock()
    /// Downloads (or disk reads) running, per URL: every size of a cover shares one.
    private var fetches: [URL: Task<Data?, Never>] = [:]
    /// Decodes running, per memory key: rows showing the same cover at one size share one.
    private var decodes: [NSString: Task<UIImage?, Never>] = [:]
    /// Covers ``diskImage(for:pixels:)`` found missing or unreadable, so a body pass that asks
    /// again costs nothing; cleared when a load puts the cover in memory. Guarded by `lock`.
    private var diskMisses: Set<NSString> = []
    private static let signposter = OSSignposter(subsystem: "com.fortune.vibramusic.ios", category: "Artwork")

    /// `Library/Caches/Vibra Music/Artwork`, where the shared cache keeps its files.
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Vibra Music/Artwork", directoryHint: .isDirectory)
    }

    init(directory: URL? = nil, session: URLSession = VibraMusicHTTP.session) {
        self.directory = directory ?? Self.defaultDirectory
        self.session = session
        let budget = Self.memoryBudgetBytes(physicalMemory: ProcessInfo.processInfo.physicalMemory)
        memoryBudgetBytes = budget
        memory.totalCostLimit = budget
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        // A cache left over its disk budget — after a lowered limit, or a heavy session that ended
        // before the debounced trim ran — is reclaimed here too: trimming otherwise waits for the
        // next network load, so an over-budget directory would sit that way across launches.
        // The task holds the cache until it is done, so the trim runs whoever drops the cache first.
        Task.detached(priority: .utility) {
            self.trim(to: Self.diskLimitBytes)
        }
    }

    /// The memory cache's key. A cover decoded for a box of `pixels` is its own bitmap: the same
    /// URL (a video thumbnail carries no size hint) can be drawn in a row and in the player.
    private static func memoryKey(_ url: URL, _ pixels: Int?) -> NSString {
        (pixels.map { "\($0)|" } ?? "") + url.absoluteString as NSString
    }

    /// The decoded image already in memory, if any. Cheap enough to call from a view body.
    /// `pixels` is the box it's drawn in, as passed to ``image(for:pixels:)``.
    func memoryImage(for url: URL, pixels: Int? = nil) -> UIImage? {
        memory.object(forKey: Self.memoryKey(url, pixels))
    }

    /// The cover's disk copy decoded here and now, for the one frame that can't wait for a task:
    /// a thumbnail-sized read, so a few milliseconds, and nil for anything not already on disk.
    /// Tried once per cover: a hit is kept in memory and a miss is remembered, so a body pass that
    /// asks again is a memory read either way.
    func diskImage(for url: URL, pixels: Int) -> UIImage? {
        let key = Self.memoryKey(url, pixels)
        guard !url.isFileURL, !lock.withLock({ diskMisses.contains(key) }) else { return nil }
        guard let data = try? Data(contentsOf: diskURL(for: url)), let image = Self.decode(data, pixels: pixels) else {
            _ = lock.withLock { diskMisses.insert(key) }
            return nil
        }
        remember(image, forKey: key)
        return image
    }

    private func remember(_ image: UIImage, forKey key: NSString) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        memory.setObject(image, forKey: key, cost: cost)
        _ = lock.withLock { diskMisses.remove(key) }
    }

    /// Memory, then disk, then the network, decoded for a box `pixels` on its long edge (nil: the
    /// picture's own size). Concurrent requests share one download, and one decode per size.
    /// At `.userInitiated`, as the colour reads that join its download: it's on screen.
    func image(for url: URL, pixels: Int? = nil) async -> UIImage? {
        if let hit = memoryImage(for: url, pixels: pixels) { return hit }
        return await decodeTask(url, pixels: pixels, priority: .userInitiated).value
    }

    /// Starts loading covers a list is about to show, so their rows draw them from memory on their
    /// first frame (UICollectionView's prefetching; a lazy stack has none). Below on-screen covers'
    /// priority; one already in memory or on its way costs nothing.
    func prefetch(_ urls: some Sequence<URL>, pixels: Int) {
        for url in urls where memoryImage(for: url, pixels: pixels) == nil {
            _ = decodeTask(url, pixels: pixels, priority: .utility)
        }
    }

    /// The cover's encoded bytes, for the colour reads (tint, mesh, blur): the disk copy of a cover
    /// already drawn, else the download that draws it, joined if one is running. So a cover shown
    /// and coloured is downloaded once, as Coil serves both on Android.
    func data(for url: URL) async -> Data? {
        await fetchTask(url, priority: .userInitiated).value
    }

    /// The decode of `url` for `pixels`, joined if one is running. Detached, so it runs off the
    /// main thread and finishes into the cache even when the row that asked has scrolled away.
    private func decodeTask(_ url: URL, pixels: Int?, priority: TaskPriority) -> Task<UIImage?, Never> {
        let key = Self.memoryKey(url, pixels)
        return lock.withLock {
            if let running = decodes[key] { return running }
            // Registered under the lock, so the task can't finish (and deregister) first.
            let made = Task.detached(priority: priority) { [weak self] () -> UIImage? in
                guard let self else { return nil }
                defer { self.lock.withLock { self.decodes[key] = nil } }
                guard let data = await self.fetchTask(url, priority: priority).value else { return nil }
                guard let image = Self.decode(data, pixels: pixels) else {
                    // Kept bytes that don't decode go, so the next request downloads the cover
                    // again rather than reading the same broken file (a disk hit is a use, so
                    // the trim would never take it).
                    if !url.isFileURL { try? FileManager.default.removeItem(at: self.diskURL(for: url)) }
                    return nil
                }
                self.remember(image, forKey: key)
                return image
            }
            decodes[key] = made
            return made
        }
    }

    /// The bytes at `url`: a file URL's own, else the disk copy, else one download shared by every
    /// caller and kept on disk once it proves to be a picture.
    private func fetchTask(_ url: URL, priority: TaskPriority) -> Task<Data?, Never> {
        lock.withLock {
            if let running = fetches[url] { return running }
            let made = Task.detached(priority: priority) { [weak self] () -> Data? in
                guard let self else { return nil }
                defer { self.lock.withLock { self.fetches[url] = nil } }
                return await self.fetch(url)
            }
            fetches[url] = made
            return made
        }
    }

    private func fetch(_ url: URL) async -> Data? {
        if url.isFileURL { return try? Data(contentsOf: url) }
        let file = diskURL(for: url)
        if let data = try? Data(contentsOf: file) {
            touch(file)
            return data
        }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              // An error page served with a 200 must not be cached as the cover.
              CGImageSourceCreateWithData(data as CFData, nil).flatMap(CGImageSourceGetType) != nil
        else { return nil }
        try? data.write(to: file, options: .atomic)
        trimIfNeeded()
        return data
    }

    /// A disk hit is a use, so trimming evicts the least recently used first.
    private func touch(_ file: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
    }

    /// Decoded off the main thread so scrolling never pays for it, and at the size it's drawn when
    /// the caller says (Coil decodes to the view's size): ImageIO's thumbnail decoder reads a large
    /// JPEG at a fraction of the work, and the bitmap kept is the box's, not the download's. A
    /// widescreen picture keeps its short side at `pixels`, so it still fills a square box cropped.
    static func decode(_ data: Data, pixels: Int?) -> UIImage? {
        let state = signposter.beginInterval("decode", id: signposter.makeSignpostID(), "\(data.count) bytes for \(pixels ?? 0) px")
        defer { signposter.endInterval("decode", state) }
        if let pixels, pixels > 0,
           let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int,
           min(width, height) > pixels {
            let short = min(width, height)
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                // The long edge that puts the short one at `pixels`, rounded up.
                kCGImageSourceThumbnailMaxPixelSize: (pixels * max(width, height) + short - 1) / short,
            ]
            if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return UIImage(cgImage: thumbnail)
            }
        }
        guard let image = UIImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
    }

    private func diskURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: digest)
    }

    private var trimScheduled = false

    private func trimIfNeeded() {
        let shouldRun: Bool = lock.withLock {
            guard !trimScheduled else { return false }
            trimScheduled = true
            return true
        }
        guard shouldRun else { return }
        Task.detached(priority: .background) { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self else { return }
            self.trim(to: Self.diskLimitBytes)
            self.lock.withLock { self.trimScheduled = false }
        }
    }

    /// Evicts the least recently used files until the cache fits `limit`.
    func trim(to limit: Int64) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { file -> (URL, Int64, Date)? in
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { return nil }
            return (file, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > limit else { return }
        entries.sort { $0.2 < $1.2 }
        for entry in entries where total > limit {
            // A cache hit touches the file as it reads it: re-check just before evicting, so a
            // file touched after this listing is kept and what goes is genuinely the least
            // recently used rather than artwork the user is looking at right now. The listing
            // cached its values on the URL, so drop those first or this reads the stale date back.
            var current = entry.0
            current.removeAllCachedResourceValues()
            if let values = try? current.resourceValues(forKeys: [.contentModificationDateKey]),
               let date = values.contentModificationDate,
               date != entry.2 {
                continue
            }
            try? FileManager.default.removeItem(at: entry.0)
            total -= entry.1
        }
    }

    /// Bytes on disk.
    func diskUsage() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// "Clear image cache": empties both caches. Returns the bytes freed on disk.
    @discardableResult
    func clear() -> Int64 {
        let freed = diskUsage()
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return freed
    }
}

/// The colour reads (tint, mesh, blur) decode the artwork cache's own bytes: a cover on screen
/// gives its colours with no request, and one not fetched yet is fetched once, for both, through
/// the cache's session (the app's ``VibraMusicHTTP``).
struct ArtworkCacheLoader: ArtworkImageLoading {
    let cache: ArtworkImageCache

    func loadArtwork(from url: URL, fittingLongestSide side: Int) async throws -> ArtworkPixels {
        guard let data = await cache.data(for: url) else { throw URLError(.resourceUnavailable) }
        guard let pixels = ArtworkPixels(imageData: data, fittingLongestSide: side) else {
            throw ArtworkLoadingError.undecodable
        }
        return pixels
    }
}

extension ArtworkPaletteCache {
    /// The colour reads every surface shares, out of ``ArtworkImageCache/shared``.
    static let shared = ArtworkPaletteCache(loader: ArtworkCacheLoader(cache: .shared))
}

extension View {
    /// When this list item appears, starts loading the covers of the `ahead` items after it, each
    /// item's `covers` at `pixels` (the size its row draws them), so a scroll finds them in memory.
    /// Twenty rows is about an iPad screen; Compose prefetches only the next item.
    func prefetchingCovers<Item>(after index: Int, in items: [Item], ahead: Int = 20, pixels: Int = ArtworkSize.row,
                                 covers: @escaping (Item) -> [String?]) -> some View {
        onAppear {
            let urls = items.dropFirst(index + 1).prefix(ahead).flatMap(covers)
                .compactMap { Artwork.resized($0, to: pixels).flatMap(URL.init(string:)) }
            ArtworkImageCache.shared.prefetch(urls, pixels: pixels)
        }
    }
}

/// A remote cover, sized for where it is drawn (Core's ``Artwork/resized(_:to:)``), with a
/// placeholder while it loads and when there is none.
///
/// The view is exactly the box its caller gives it, whatever the image's shape: the backing plate
/// takes the proposed size and the picture is laid over it, so a 16:9 video thumbnail can never
/// widen the layout. (Drawn as the ZStack's own child, a `scaledToFill` image reported its filled
/// width as the stack's, and the stack — clip and all — grew past the caller's frame.)
///
/// `contentMode` is Compose's `contentScale` on the matching AsyncImage: `.fill` for Crop, which
/// is Coil's own default and what every Android surface uses — page headers, shelf cards, back
/// drops, the list rows and the mini player, where a widescreen video thumbnail is centre-cropped
/// into its fixed square box.
struct ArtworkImage: View {
    let url: URL?
    /// The box's long edge in pixels, which the cover is decoded to; nil decodes it whole.
    var pixels: Int?
    var cornerRadius: CGFloat = AppTheme.artCorner
    var placeholderSymbol: String = AppSymbol.musicNote
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?
    @State private var loadedURL: URL?

    /// A raw artwork string, resized to `pixels` on its long edge.
    init(_ raw: String?, pixels: Int, cornerRadius: CGFloat = AppTheme.artCorner, placeholderSymbol: String = AppSymbol.musicNote,
         contentMode: ContentMode = .fill) {
        self.url = Artwork.resized(raw, to: pixels).flatMap(URL.init(string:))
        self.pixels = pixels
        self.cornerRadius = cornerRadius
        self.placeholderSymbol = placeholderSymbol
        self.contentMode = contentMode
    }

    /// A song's cover, resized to `pixels`.
    init(song: Song?, pixels: Int, cornerRadius: CGFloat = AppTheme.artCorner, contentMode: ContentMode = .fill) {
        self.init(song?.thumbnailUrl, pixels: pixels, cornerRadius: cornerRadius, contentMode: contentMode)
    }

    init(url: URL?, pixels: Int? = nil, cornerRadius: CGFloat = AppTheme.artCorner, placeholderSymbol: String = AppSymbol.musicNote,
         contentMode: ContentMode = .fill) {
        self.url = url
        self.pixels = pixels
        self.cornerRadius = cornerRadius
        self.placeholderSymbol = placeholderSymbol
        self.contentMode = contentMode
    }

    /// An already-decoded cover: tests (and previews) draw it without the async loader, so a
    /// render can be inspected synchronously.
    init(image: UIImage, cornerRadius: CGFloat = AppTheme.artCorner, contentMode: ContentMode = .fill) {
        self.url = nil
        self.cornerRadius = cornerRadius
        self.placeholderSymbol = AppSymbol.musicNote
        self.contentMode = contentMode
        _image = State(initialValue: image)
        _loadedURL = State(initialValue: nil)
        _keepsImage = State(initialValue: true)
    }

    @State private var keepsImage = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // The plate sets the size; everything else is an overlay proposed that same size.
        Rectangle()
            .fill(Color(.secondarySystemFill))
            .overlay {
                if let shown = currentImage {
                    Image(uiImage: shown)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .transition(.opacity)
                } else {
                    Image(systemName: placeholderSymbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .task(id: url) {
                guard let url else {
                    if !keepsImage { image = nil }
                    return
                }
                if loadedURL == url, image != nil { return }
                let fetched = await ArtworkImageCache.shared.image(for: url, pixels: pixels)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    image = fetched
                    loadedURL = url
                }
            }
    }

    /// The loaded image, or one already in memory so a reused row never flashes its placeholder.
    private var currentImage: UIImage? {
        if let image, loadedURL == url { return image }
        return url.flatMap { ArtworkImageCache.shared.memoryImage(for: $0, pixels: pixels) }
    }
}
