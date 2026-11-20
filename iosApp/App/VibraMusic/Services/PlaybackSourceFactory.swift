import AudioCache
import AVFoundation
import VibraMusicCore
import Playback
import PlaybackPolicy
import Sources

// Ports the resolving data source of PlaybackService.kt: where each queue row's bytes come from.
// Android resolved its `vibramusic://` URIs lazily inside the data source; here each PlayableItem
// carries a factory the engine calls when it needs the audio (to start it, preload it for a
// gapless or crossfaded advance, or retry it), so an expiring stream URL is minted at play time.

/// A file saved on this device for a row, and whether it came from YouTube (whose fragmented MP4
/// needs AudioCache's duration fix, or AVFoundation reports twice its length).
struct SavedAudioFile: Hashable {
    var url: URL
    var isYouTubeOrigin: Bool
}

/// Builds the engine's ``PlayableItem`` for a queue row.
@MainActor
final class PlaybackSourceFactory {
    /// The app's resolver (Sources' SourceResolver over StreamResolution): substitutes, pinned
    /// source tracks and YouTube, raced.
    let resolver: any StreamResolving
    /// YouTube's own walk, for re-minting an expired or refused YouTube URL. Going back through
    /// the SourceResolver there could answer with a different file under the same cache entry.
    let youTube: (any StreamResolving)?
    /// Nil plays streams straight from the network (tests, or a cache that failed to open).
    let cache: AudioStreamCache?
    let facts: StreamFactsBook
    /// The HTTP session streams and read-ahead fetch through. The app passes its shared session;
    /// tests inject one whose protocol classes answer without a network.
    let session: URLSession
    /// What to ask for right now: the per-network ceiling (PlaybackPolicy's `currentRequest`).
    let request: @Sendable () -> StreamRequest
    /// Whether a source outranks YouTube for `request` (Sources' `canSubstituteForYouTube`).
    /// Read-ahead asks before it writes bytes: with substitution possible, read-ahead resolving to
    /// YouTube on its own would fill the entry a substitute is about to fill from another server,
    /// under the same key. Conservative by default: a caller that doesn't wire the ladder gets the
    /// URL-only warm-up plan.
    var canSubstitute: @Sendable (StreamRequest) -> Bool = { _ in true }
    /// Whether an immersive mix may play (device decodes E-AC-3 and the setting is on); keys the
    /// substitute cache entry so turning Atmos off never serves a cached Atmos file.
    let atmosAllowed: @Sendable () -> Bool
    /// StreamResolver's `onPlaybackRefused`: the evidence it needs to retire a client.
    let onRefused: (@Sendable (URL, Int) -> Void)?
    /// Tracks the listener reverted to YouTube's own upload ("Revert to original"): no substitute
    /// is raced for them until "Upgrade quality" lifts the pin.
    var isPinnedToOriginal: @Sendable (String) -> Bool = { OriginalVersion.shared.isPinned($0) }
    /// Tracks a substitute or an upgrade broke mid-play (``fallBackToYouTube(_:)``): they resolve
    /// through `youTube` alone until the refusal lapses.
    var streamChoice = StreamChoice.shared
    /// A saved download or import for the row, if there is one.
    var savedFile: (Song) -> SavedAudioFile? = { _ in nil }
    /// Drops the record of a download whose file the engine just failed to open, so the next play
    /// doesn't walk into the same hole (Android's `Downloads.forgetMissing`).
    var forgetMissing: (Song) -> Void = { _ in }
    /// The byte source for a row on the listener's SMB or WebDAV share, if it is one.
    var networkSource: (Song) -> (any AudioRangeDataSource)? = { _ in nil }
    /// Called on the main actor as each item's stream resolves (stats for nerds, loudness).
    var onResolved: ((String, ResolvedStream) -> Void)?
    /// Called on the main actor as an item opens a copy whole off the disk instead: nothing
    /// resolved for it, and what an earlier resolve recorded is forgotten.
    var onOpenedFromDisk: ((String) -> Void)?
    /// Lays a playlist stream (an add-on's lossless or Atmos) out as one file the cache can
    /// serve and keep; nil plays playlists the old way, uncached.
    var segmented: SegmentedSources?
    /// Whether the connection is unmetered: the only one a played segmented copy's missing parts
    /// are fetched on, so the track is whole for its next play and the offline backup.
    var isUnmetered: () -> Bool = { false }
    /// Whether `videoId` is still the track playing.
    var isPlaying: (String) -> Bool = { _ in false }
    /// How long a segmented copy plays before its missing parts are fetched: past the start, and
    /// past a skip.
    var completionDelay: Duration = .seconds(10)

    /// Fetches what a played segmented copy is missing (an upgrade starts it mid-track; a seek
    /// skips some), so the entry is whole. The cache joins any fetch the player already has under
    /// way: no byte is fetched twice.
    func completeLater(_ key: AudioCacheKey, source: SegmentedAudioSource, videoId: String) {
        guard let cache else { return }
        let delay = completionDelay
        Task { [weak self] in
            // Still this copy: an upgrade that swapped another in meanwhile leaves this one unread.
            guard (try? await Task.sleep(for: delay)) != nil,
                  let self, self.isUnmetered(), self.isPlaying(videoId), self.playingKeys.key(for: videoId) == key.rawValue else { return }
            let whole = await cache.cacheCompletely(key, source: source)
            TrackLog.d(Self.logCategory, "segmented copy \(key) \(whole ? "is whole" : "is not whole yet")", about: videoId)
        }
    }
    /// Whether the device has no connection: a row then plays any whole copy it has on disk.
    var isOffline: @Sendable () -> Bool = { false }
    /// Called on the main actor when YouTube's loudness figure for a video id first becomes known.
    var onLoudness: ((String) -> Void)?
    /// Rows reopened as a different copy of the same recording, by base item id: a quality
    /// upgrade (`hifi`, with the stream it found), a revert to YouTube's own (`original`), or a
    /// plain reopen. The tag makes the engine item new (the engine reuses an opened asset by id)
    /// and keys the cache entry apart, so an upgrade's bytes never land inside the copy it replaces.
    private var renditions: [String: (tag: String, stream: ResolvedStream?)] = [:]
    /// The URL each upgrade slot (`<id>#hifi`) was last emptied for and filled from this session.
    private var upgradeSlotOrigins: [AudioCacheKey: URL] = [:]
    /// The cache key each video id's playing copy was last opened under, for Automix's
    /// `cacheKey(of:)`. Written from the asset factories, read from the analyzer's queue.
    let playingKeys = PlayingCacheKeys()
    /// The streams read-ahead's source race found for the tracks ahead (Direct source stream's
    /// Queue only), played by the track each was found for.
    let readAheadStreams = ReadAheadStreams()
    /// How long a row the queue has reached (a skip, an advance) waits for its look ahead,
    /// counted from when the lookup started (Android `DirectSourceGate.LOOKUP_TIMEOUT_MS`).
    var lookupJoinWait: Duration = .seconds(15)
    /// The quick sources' copy of a track (Sources' `prefetchSubstitute`: JioSaavn), or nil when
    /// none ranks above YouTube or none has it. With Direct source stream Off it is asked for the
    /// row ahead, which then starts on that copy, and read-ahead puts the same copy's bytes on disk
    /// (Android's `prefetchQueue` pinning `prefetchSubstitute`'s answer). Nil asks nothing ahead.
    var quickCopy: (@Sendable (Song, StreamRequest) async throws -> ResolvedStream?)?
    /// Whether the track playing has started sounding. Nothing is looked up for a row ahead before
    /// then, so on a weak link the playing track's start has the connection to itself.
    var isSounding: () -> Bool = { true }
    /// How long a look ahead waits for that before it goes anyway (a pause, a stall).
    var soundingWait: Duration = .seconds(20)
    /// How much of a track ahead's own copy is put on disk: its first seconds, at lossless rates.
    nonisolated static let openingBytes: Int64 = 2 * 1_024 * 1_024

    init(
        resolver: any StreamResolving,
        youTube: (any StreamResolving)?,
        cache: AudioStreamCache?,
        facts: StreamFactsBook,
        session: URLSession = VibraMusicHTTP.session,
        request: @escaping @Sendable () -> StreamRequest,
        atmosAllowed: @escaping @Sendable () -> Bool = { DeviceCodecs.shared.playsDolbyAtmos },
        onRefused: (@Sendable (URL, Int) -> Void)? = nil
    ) {
        self.resolver = resolver
        self.youTube = youTube
        self.cache = cache
        self.facts = facts
        self.session = session
        self.request = request
        self.atmosAllowed = atmosAllowed
        self.onRefused = onRefused
    }

    /// The engine item for `song`: id per queue slot, lock-screen artwork, the catalogue duration.
    func item(for song: Song) -> PlayableItem {
        var item = PlayableItem(song: song, source: source(for: song), loudnessDb: facts.trackLoudness(song.videoId))
        item.id = engineItemID(for: song)
        if let stream = facts.stream(for: item.id), stream.format != StreamFormat() {
            item.declaredFormat = stream.format
        } else if let badge = Self.declaredFormat(ofDownloadBadge: song.downloadFormat) {
            item.declaredFormat = badge
        }
        return item
    }

    /// What a saved file's badge says it is (Downloads' `downloadBadge`: "DOLBY", "FLAC"). The
    /// engine trusts a declared Atmos mix to keep the processing tap off it, so an immersive
    /// download is never folded down by the DSP chain.
    static func declaredFormat(ofDownloadBadge badge: String?) -> StreamFormat? {
        switch badge?.uppercased() {
        case "DOLBY": return StreamFormat(codec: "eac3-joc", channels: 6)
        case "FLAC": return StreamFormat(codec: "flac")
        case "ALAC": return StreamFormat(codec: "alac")
        default: return nil
        }
    }

    /// The engine item id for a queue row: its slot plus the recording, so a version swap in the
    /// same slot is a different item (the engine reuses an opened asset by id) while repeat-one of
    /// the same row is the same item (which the engine loops gaplessly).
    nonisolated static func itemID(for song: Song) -> String {
        "\(song.id)|\(song.videoId)"
    }

    /// An engine item id without its rendition tag: the queue row it plays.
    nonisolated static func baseItemID(_ itemID: String) -> String {
        guard let hash = itemID.lastIndex(of: "#") else { return itemID }
        return String(itemID[..<hash])
    }

    /// The id the engine knows the row by right now: ``itemID(for:)`` plus the rendition tag, if
    /// the row was reopened as another copy.
    func engineItemID(for song: Song) -> String {
        let base = Self.itemID(for: song)
        guard let tag = renditions[base]?.tag else { return base }
        return "\(base)#\(tag)"
    }

    // MARK: - Renditions

    /// Reopens `song`'s row as another copy: `stream` (a quality upgrade the caller already
    /// resolved) or, with a nil stream, whatever the row resolves to now under a new identity.
    func setRendition(_ tag: String, stream: ResolvedStream?, for song: Song) {
        renditions[Self.itemID(for: song)] = (tag, stream)
    }

    /// Back to the row's ordinary copy.
    func clearRendition(for song: Song) {
        renditions[Self.itemID(for: song)] = nil
    }

    func renditionTag(for song: Song) -> String? {
        renditions[Self.itemID(for: song)]?.tag
    }

    /// The stream a row was forced onto, if any.
    func forcedStream(for song: Song) -> ResolvedStream? {
        renditions[Self.itemID(for: song)]?.stream
    }

    /// The cache entry the row's playing copy was opened under, if any. The cached-track floor reads
    /// this entry's size; Android read it back off the item's URI (`AudioCache.contentLengthOf`).
    func playingCacheKey(for videoId: String) -> AudioCacheKey? {
        playingKeys.key(for: videoId).map { AudioCacheKey(rawValue: $0) }
    }

    /// The full size in bytes of the cache entry the row is playing from, or 0 when nothing is
    /// playing from the cache or the entry's length was never recorded.
    func playingContentLength(for videoId: String) async -> Int64 {
        guard let cache, let key = playingCacheKey(for: videoId) else { return 0 }
        return await cache.contentLength(of: key)
    }

    /// Whether the row's playing copy was served whole from the disk cache — the bytes were already
    /// there, so nothing resolved this process. The cached-track quality upgrade runs only for these.
    func playingFromCache(for videoId: String) -> Bool {
        playingKeys.playedFromCache(videoId)
    }

    /// Drops the tags of rows no longer in `keeping` (base ids).
    func retainRenditions(for keeping: Set<String>) {
        renditions = renditions.filter { keeping.contains($0.key) }
    }

    func noteResolved(itemID: String, videoId: String, stream: ResolvedStream) {
        if let loudness = stream.loudnessDb {
            noteLoudness(loudness, forTrack: videoId)
        } else {
            learnLoudness(of: videoId)
        }
        onResolved?(itemID, stream)
    }

    func noteLoudness(_ db: Double, forTrack videoId: String) {
        if facts.noteLoudness(db, forTrack: videoId) { onLoudness?(videoId) }
    }

    /// An add-on's copy carries no loudness figure, and a track played whole from disk resolves
    /// nothing: YouTube's figure for the recording is fetched and handed to any deck playing it.
    /// After the track's start, not during it (Android's `LOUDNESS_RETRY_MS`): by then the race's
    /// YouTube leg has usually resolved it, and the resolver memoises.
    func learnLoudness(of videoId: String) {
        guard facts.trackLoudness(videoId) == nil, SourceRegistry.parseTrackKey(videoId) == nil, let youTube else { return }
        let request = self.request()
        Task { [weak self] in
            try? await Task.sleep(for: Self.loudnessLookupDelay)
            guard let self, self.facts.trackLoudness(videoId) == nil else { return }
            let song = Song(videoId: videoId, title: "", artist: "")
            guard let db = try? await youTube.resolveStream(for: song, request: request).loudnessDb else { return }
            self.noteLoudness(db, forTrack: videoId)
        }
    }

    static let loudnessLookupDelay: Duration = .seconds(6)

    /// Where the row's audio comes from:
    /// 1. a file on this device (an import, or a download — YouTube downloads through the cache's
    ///    file source so their duration is patched);
    /// 2. otherwise a stream, resolved when the engine asks and served through the audio cache
    ///    (range-chunked with the stream's headers, written to disk as it plays), except HLS, which
    ///    AVFoundation fetches itself (a converted DASH manifest through SourcePlaylistLoader).
    func source(for song: Song) -> PlayableItem.Source {
        if let local = Self.localFileURL(of: song) {
            return .file(local)
        }
        if let remote = networkSource(song) {
            guard let cache else { return .asset { throw PlaybackSourceError.missingLocalFile(URL(fileURLWithPath: song.videoId)) } }
            let key = AudioCacheKey(trackID: song.videoId)
            return .asset { cache.makeAsset(for: key, source: remote) }
        }
        if let saved = savedFile(song) {
            guard saved.isYouTubeOrigin, let cache else { return .file(saved.url) }
            let key = AudioCacheKey.youtube(videoId: song.videoId, rendition: "download")
            let file = FileAudioSource(url: saved.url, mimeType: "audio/mp4", requiresYouTubeDurationFix: true)
            return .asset { cache.makeAsset(for: key, source: file) }
        }
        if let rendition = renditions[Self.itemID(for: song)], let stream = rendition.stream {
            return .asset(forcedAssetFactory(for: song, stream: stream, tag: rendition.tag))
        }
        return .resolvedAsset(streamAssetFactory(for: song))
    }

    /// What the engine reopens a failed item with (the engine's ``PlaybackSourceRecovery``;
    /// Android's `restreamMissingLocalFile` and the cache discard in `recoverFrom`).
    ///
    /// - A download whose file is gone is forgotten and the row rebuilt without it, which sends it
    ///   down the streaming branch of ``source(for:)``. A row with nothing else behind it (its id is
    ///   the missing path) comes back nil, so the failure stands instead of reopening the same path.
    /// - A dying stream has its cached bytes thrown away, since an entry filled from two different
    ///   files reads fine until playback reaches the seam, and is rebuilt so it resolves afresh.
    ///   After a network fault, or with no connection, copies on disk in full are kept: the
    ///   network failing says nothing against them, and offline they are all there is to play.
    /// - A failure of the system's (a media-services reset) says nothing against anything: not a byte
    ///   goes, and the copy that was playing opens again with no resolve, since a resolve could land
    ///   on another copy, and bytes of two files in one entry are that seam. Played whole off the
    ///   disk, nothing resolved it and the row's own source finds it there again.
    func recoveredSource(for item: PlayableItem, reason: RecoveryReason) async -> PlayableItem.Source? {
        guard let song = item.song else { return nil }
        switch reason {
        case .missingLocalFile(let gone):
            forgetMissing(song)
            let restreamed = source(for: song)
            if case .file(let url) = restreamed, url == gone { return nil }
            return restreamed
        case .retry(_, let networkFault):
            await cache?.discard(trackID: song.videoId, keepComplete: networkFault || isOffline())
            // A dead stream read-ahead found is not opened again: the row resolves afresh.
            readAheadStreams.forget(song.videoId)
            return source(for: song)
        case .systemFault:
            guard let stream = facts.stream(for: item.id) else { return nil }
            let key = playingCacheKey(for: song.videoId)
            return .asset(forcedAssetFactory(for: song, stream: stream, tag: key?.rendition ?? "", silent: true, key: key))
        }
    }

    /// Whether `item` died on a copy above YouTube with a YouTube upload behind it: a substitute, or
    /// an upgrade's copy (Android's `PlaybackFallback.isAlternative`). Retried as it is, the same
    /// deterministic lookup wins again and hands back the same dead copy. A source's own catalogue
    /// row is that source's or nothing, as on Android, and a row already on YouTube's walk (pinned,
    /// or refused after an earlier fallback) has nothing better to fall back to.
    func diedAboveYouTube(_ item: PlayableItem) -> Bool {
        guard let song = item.song, SourceRegistry.parseTrackKey(song.videoId) == nil, !isPinnedToYouTube(song),
              youTube != nil else { return false }
        if let stream = facts.stream(for: item.id) { return stream.origin != .youtube }
        // Played whole off the disk, so nothing resolved: the copy it was read from says.
        guard let key = playingCacheKey(for: song.videoId) else { return false }
        return key.isSubstitute || Self.isUpgradeCopy(key)
    }

    /// Puts `song`'s row onto YouTube's own upload after its copy above YouTube died (Android's
    /// `fallbackFailedAlternativeToYouTube`): no substitute is raced for it for
    /// ``StreamChoice/refusalPeriod``, and the row becomes its `original` rendition, a new engine
    /// item resolved through `youTube`.
    func fallBackToYouTube(_ song: Song) {
        streamChoice.refuseSubstitutes(for: song.videoId)
        setRendition("original", stream: nil, for: song)
    }

    /// A stream found for a row that is already playing (a quality upgrade): no resolving, and
    /// cached under its own rendition key (`<id>#hifi`), as Android's `QualityUpgrade.cacheTag` did.
    ///
    /// `silent` is the upgrade's proof (the copy opened before a note of the playing one is
    /// touched): it fills the same cache entry but reports nothing — no stream facts, no
    /// `onResolved`, no playing cache key — since the row is still playing its old copy and the
    /// proof may yet reject this one.
    ///
    /// `key` is the entry to fill when it isn't the rendition's: a silent reopen of a copy already
    /// under another key.
    func forcedAssetFactory(for song: Song, stream: ResolvedStream, tag: String, silent: Bool = false, key: AudioCacheKey? = nil) -> PlayableItem.AssetFactory {
        let cache = self.cache
        let facts = self.facts
        let session = self.session
        let onRefused = self.onRefused
        // The id the row will have once it is on this copy, not the one it has now.
        let itemID = "\(Self.itemID(for: song))#\(tag)"
        let key = key ?? AudioCacheKey(trackID: song.videoId, rendition: tag)
        let playingKeys = self.playingKeys
        let segmented = self.segmented
        return { [weak self] in
            if !silent {
                facts.record(itemID: itemID, stream: stream)
                let factory = self
                await MainActor.run { factory?.noteResolved(itemID: itemID, videoId: song.videoId, stream: stream) }
            }
            // A playlist stream goes through the cache as one file, so it is fetched once and kept.
            if let cache, SegmentedAudioSource.handles(stream), let source = await segmented?.source(for: stream) {
                if !silent {
                    playingKeys.set(key.rawValue, for: song.videoId, item: itemID)
                    let factory = self
                    await MainActor.run { factory?.completeLater(key, source: source, videoId: song.videoId) }
                }
                return cache.makeAsset(for: key, source: source)
            }
            // Let go of mid-wait: not settled on the playlist, which the engine would keep for this
            // item's next open.
            if SegmentedAudioSource.handles(stream) { try Task.checkCancellation() }
            if SourcePlaylistLoader.handles(stream.url) {
                var options: [String: Any] = [:]
                if !stream.headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = stream.headers }
                let asset = AVURLAsset(url: stream.url, options: options)
                SourcePlaylistLoader.shared.attach(to: asset)
                return asset
            }
            guard let cache else { return PlaybackSourceFactory.plainAsset(for: stream) }
            if !silent { playingKeys.set(key.rawValue, for: song.videoId, item: itemID) }
            return cache.makeAsset(for: key, stream: stream, session: session, refresh: nil, onRefused: onRefused)
        }
    }

    /// Empties the upgrade's cache slot before its copy is warmed and proved (Android's
    /// `discardRendition` ahead of `auditionUpgrade`). `<id>#hifi` names a slot, not a file: bytes
    /// an earlier attempt left there belong to another candidate (another catalogue, master or
    /// length), and the player reads them and the new copy's as one stream. The cache outlives the
    /// launch and the generation tag restarts at `hifi`, so an earlier session's leftovers are in
    /// the way too.
    ///
    /// Exempt: a slot this session already filled from the same URL (a shelved upgrade proved again),
    /// whose bytes are the copy's own and would be paid for twice; and the entry the row is playing.
    func emptyUpgradeSlot(for song: Song, stream: ResolvedStream, tag: String) async {
        let key = AudioCacheKey(trackID: song.videoId, rendition: tag)
        guard let cache, upgradeSlotOrigins[key] != stream.url, playingKeys.key(for: song.videoId) != key.rawValue else { return }
        await cache.discardRendition(key)
        upgradeSlotOrigins[key] = stream.url
    }

    /// The upgrade slot this session filled from `stream`'s URL, if any: where a shelved copy's
    /// bytes already are, so proving it again reads them instead of fetching them into the other slot.
    func upgradeSlot(holding stream: ResolvedStream, for song: Song) -> AudioCacheKey? {
        upgradeSlotOrigins.first { $0.key.trackID == song.videoId && $0.value == stream.url }?.key
    }

    /// The upgrade rendition's header, pulled onto disk before the proof and the swap. Android warms
    /// a fixed `UPGRADE_HEADER_BYTES` from byte zero ahead of the audition; this warms what the
    /// container declares (see ``UpgradeWarm``) and answers the layout
    /// ``warmUpgradeSwapPoint(for:stream:tag:layout:position:duration:)`` maps the playhead with.
    /// Nil for a stream the cache never serves, and for a container this can't read, which gets
    /// Android's fixed opening instead.
    ///
    /// The entry is the one ``forcedAssetFactory(for:stream:tag:silent:)`` fills. The first read is
    /// the size of HTTPAudioSource's length probe: an upgrade's URL never states its length, so
    /// those bytes are on the wire before anything else, and keeping all of them costs nothing.
    func warmUpgradeHead(for song: Song, stream: ResolvedStream, tag: String) async -> UpgradeWarm.Layout? {
        guard let cache, let source = upgradeSource(for: stream) else { return nil }
        let key = AudioCacheKey(trackID: song.videoId, rendition: tag)
        var through = HTTPAudioSource.probeBytes
        // One read for nearly every file; another when a cover pushes the header past the probe.
        for _ in 0..<4 {
            await cache.warmRange(key, source: source, range: 0..<through)
            let length = await cache.contentLength(of: key)
            guard length > 0, let reader = await cache.reader(for: key, requireComplete: false) else { return nil }
            let prefix = await reader.read(at: 0, count: Int(min(through, length)))
            switch UpgradeWarm.scan(prefix, length: length) {
            case .found(let layout):
                if layout.headerRange.upperBound > through {
                    await cache.warmRange(key, source: source, range: through..<layout.headerRange.upperBound)
                }
                return layout
            case .needMore(let next) where next <= UpgradeWarm.headerCapBytes:
                through = max(next, through + 1)
            case .needMore, .unknown:
                await cache.warmRange(key, source: source, range: 0..<UpgradeWarm.headerCapBytes)
                return nil
            }
        }
        await cache.warmRange(key, source: source, range: 0..<UpgradeWarm.headerCapBytes)
        return nil
    }

    /// The bytes at the swap point, on disk before the swap: a window around `position` seconds
    /// into the copy, mapped through `layout` (see ``UpgradeWarm/window(_:position:duration:)``).
    /// The copy replaces one already playing, so after its header the swap's first read lands
    /// here, not at the copy's start.
    @discardableResult
    func warmUpgradeSwapPoint(for song: Song, stream: ResolvedStream, tag: String, layout: UpgradeWarm.Layout,
                              position: TimeInterval, duration: TimeInterval) async -> Range<Int64>? {
        guard let cache, let source = upgradeSource(for: stream),
              let window = UpgradeWarm.window(layout, position: position, duration: duration) else { return nil }
        await cache.warmRange(AudioCacheKey(trackID: song.videoId, rendition: tag), source: source, range: window)
        return window
    }

    /// What an upgrade's warm-ups fetch through (the session read-ahead and playback use), or nil
    /// for a stream the cache never serves: a file on this device, HLS, or a playlist the source
    /// loader answers itself. No re-mint on refusal, as in ``forcedAssetFactory(for:stream:tag:silent:)``:
    /// a fresh URL could splice another file into the rendition entry, and a dead one fails the
    /// proof that follows.
    private func upgradeSource(for stream: ResolvedStream) -> HTTPAudioSource? {
        guard !stream.url.isFileURL, !stream.isHLS, !SourcePlaylistLoader.handles(stream.url) else { return nil }
        return HTTPAudioSource(stream: stream, session: session, onRefused: onRefused)
    }

    /// A file URL a row points at directly (Files imports, network-library rows already copied).
    /// A download's `localUri` whose file is gone (deleted, or a path from before the app's
    /// container moved) is skipped, so the row plays from the download library or streams, as
    /// Android's `restreamMissingLocalFile` does. A row whose id is the path has nothing else
    /// behind it and keeps the path, so the engine reports the missing file.
    static func localFileURL(of song: Song) -> URL? {
        for raw in [song.localUri, song.localPath, song.videoId].compactMap({ $0 }) {
            let url = raw.hasPrefix("file://") ? URL(string: raw) : raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : nil
            guard let url else { continue }
            if raw == song.videoId || FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { return url }
        }
        return nil
    }

    /// The whole copy on disk a row plays without resolving, best first: the copy a quality upgrade
    /// left (`hifi-2`, `hifi`) or the substitute when lossless is wanted and the row isn't pinned
    /// to YouTube's own, then YouTube's. With no connection nothing can be resolved, so the largest
    /// whole copy plays — the offline backup's promise — except a substitute or an upgrade's copy
    /// for a row pinned to YouTube's own: either can be a different cut, and the listener asked not
    /// to hear it.
    ///
    /// With Atmos off, a copy that may be an Atmos mix never plays off the disk, online or not: an
    /// upgrade's (its entry doesn't say what format it holds) or the substitute fetched with Atmos
    /// on (see ``AudioCacheKey/substitute(videoId:atmosAllowed:)``).
    ///
    /// `asksSourcesFirst` (Direct source stream's Always, with a source ranked above YouTube): online
    /// and not pinned, YouTube's copy isn't played off the disk before the ranked sources are asked
    /// (Android's `settleDirectEntry`), so nil and the race runs. If YouTube wins it, its entry
    /// serves the bytes; a source's answer fills its own key, so YouTube's needn't be deleted.
    nonisolated static func cachedCopy(among known: [AudioCacheRendition], videoId: String, pinned: Bool,
                                       wantsLossless: Bool, atmosAllowed: Bool, offline: Bool,
                                       asksSourcesFirst: Bool = false) -> AudioCacheKey? {
        let complete = known.filter { $0.isComplete && playsOffDisk($0.key, pinned: pinned, atmosAllowed: atmosAllowed) }
        let whole = complete.map(\.key)
        var preferred: [AudioCacheKey] = []
        if !pinned, wantsLossless {
            preferred += [AudioCacheKey(trackID: videoId, rendition: "hifi-2"), AudioCacheKey(trackID: videoId, rendition: "hifi"),
                          .substitute(videoId: videoId, atmosAllowed: atmosAllowed)]
        }
        preferred.append(.youtube(videoId: videoId))
        if let key = preferred.first(where: whole.contains) {
            if asksSourcesFirst, !pinned, !offline, key == .youtube(videoId: videoId) { return nil }
            return key
        }
        guard offline else { return nil }
        return complete.max { $0.contentLength < $1.contentLength }?.key
    }

    /// Whether a whole copy under `key` may play off the disk for a row (the offline backup lists by
    /// the same rule): not a substitute or an upgrade's copy when the row is pinned to YouTube's own,
    /// and with Atmos off, nothing that may be an Atmos mix: an upgrade's copy, or the substitute
    /// fetched while Atmos was on (`#alt`, where `#alt-noatmos` is the one fetched with it off).
    nonisolated static func playsOffDisk(_ key: AudioCacheKey, pinned: Bool, atmosAllowed: Bool) -> Bool {
        let upgrade = isUpgradeCopy(key)
        let mayBeAtmos = upgrade || key == .substitute(videoId: key.trackID, atmosAllowed: true)
        return !(pinned && (key.isSubstitute || upgrade)) && !(mayBeAtmos && !atmosAllowed)
    }

    /// Whether `key` is a quality upgrade's copy (`#hifi`, `#hifi-2`): a ranked source's, above
    /// YouTube, in a format its entry doesn't record.
    nonisolated static func isUpgradeCopy(_ key: AudioCacheKey) -> Bool {
        key.rendition?.hasPrefix("hifi") == true
    }

    /// Opens the row and says what it opened: the stream it resolved, or nil for a copy played whole
    /// off the disk, so the engine never takes the format of an earlier resolve for it.
    private func streamAssetFactory(for song: Song) -> PlayableItem.ResolvedAssetFactory {
        let youTube = self.youTube
        let pinned = isPinnedToYouTube(song)
        let resolver = pinned ? youTube! : self.resolver
        let cache = self.cache
        let facts = self.facts
        let session = self.session
        let request = self.request
        let atmosAllowed = self.atmosAllowed
        let onRefused = self.onRefused
        let isOffline = self.isOffline
        let segmented = self.segmented
        let itemID = engineItemID(for: song)
        let sourceKey = SourceRegistry.parseTrackKey(song.videoId)
        let playingKeys = self.playingKeys
        let readAheadStreams = self.readAheadStreams
        let lookupJoinWait = self.lookupJoinWait
        let canSubstitute = self.canSubstitute
        let quickCopy = self.quickCopy
        let soundingWait = self.soundingWait
        return { [weak self] in
            let wanted = request()
            let atmos = atmosAllowed()
            let started = ContinuousClock.now
            // A track already whole on disk plays without resolving anything (airplane mode), from
            // the rendition this request would have picked. One question to the store, not three:
            // every rendition the row owns, with whether each is whole.
            if let cache {
                var cachedKey: AudioCacheKey?
                if let sourceKey {
                    let key = AudioCacheKey.source(sourceKey.configId, track: sourceKey.trackId)
                    if await cache.isFullyCached(key) { cachedKey = key }
                } else {
                    // Played from the Offline backup page: the listener asked for what is on this
                    // device, so it starts off the disk and any better copy swaps in afterwards.
                    let fromBackup = song.playbackSourceId == LocalBrowseID.offlineBackup
                    let asksFirst = wanted.waitsForSources && canSubstitute(wanted) && !fromBackup
                    let known = await cache.renditions(ofTrack: song.videoId)
                    cachedKey = PlaybackSourceFactory.cachedCopy(
                        among: known, videoId: song.videoId, pinned: pinned,
                        wantsLossless: wanted.wantsLossless, atmosAllowed: atmos, offline: isOffline(), asksSourcesFirst: asksFirst)
                    if cachedKey == nil, asksFirst, known.contains(where: { $0.isComplete && $0.key == .youtube(videoId: song.videoId) }) {
                        TrackLog.d(PlaybackSourceFactory.logCategory, "'\(song.title)': YouTube's copy is whole on disk; the ranked sources are asked first (Always)",
                                   about: song.videoId)
                    }
                }
                if let cachedKey {
                    TrackLog.d(PlaybackSourceFactory.logCategory, "'\(song.title)' is whole on disk (\(cachedKey)); no resolve, \(TrackLog.ms(since: started))ms",
                               about: song.videoId)
                    playingKeys.set(cachedKey.rawValue, for: song.videoId, item: itemID, fromCache: true)
                    // An earlier resolve of this item may have been another copy (the add-on's, before
                    // YouTube's was whole): left in place, it would declare that copy's format and
                    // count a retry of this one as dying above YouTube.
                    facts.forget(itemID: itemID)
                    let factory = self
                    await MainActor.run {
                        factory?.learnLoudness(of: song.videoId)
                        factory?.onOpenedFromDisk?(itemID)
                    }
                    let lazy = HTTPAudioSource(session: session, onRefused: onRefused) {
                        try await resolver.resolveStream(for: song, request: wanted)
                    }
                    return (cache.makeAsset(for: cachedKey, source: lazy), nil)
                }
            }

            let readsAhead = wanted.readsAheadFromSources && !pinned
            // Off: the quick sources' copy (JioSaavn) of a row opened ahead, shared with read-ahead,
            // which puts that same copy's bytes on disk.
            let quickFind = pinned || sourceKey != nil || isOffline() || wanted.waitsForSources || wanted.readsAheadFromSources
                || !canSubstitute(wanted) ? nil : PlaybackSourceFactory.quickFind(quickCopy, song: song, request: wanted)
            // The ranked sources' copy asked for again, at play-time limits.
            let waitingRace: HTTPAudioSource.Resolver = {
                var asked = wanted
                asked.waitsForSources = true
                asked.readsAheadFromSources = false
                return try await TrackLog.about(song.videoId) { try await resolver.resolveStream(for: song, request: asked) }
            }
            // How a copy found ahead of time is found again once it is past its freshness: by the
            // time a long track hands over to it, its URL may be dead (see `refresh` below).
            var refind: HTTPAudioSource.Resolver?
            let picked: ResolvedStream
            if readsAhead || quickFind != nil, let found = readAheadStreams.stream(for: song.videoId, request: wanted, atmosAllowed: atmos) {
                // The copy read-ahead found plays from its first second, with nothing resolved again.
                picked = found
                refind = quickFind ?? waitingRace
                TrackLog.d(PlaybackSourceFactory.logCategory, "'\(song.title)' plays the \(found.origin) \(found.format.summary) stream read-ahead found",
                           about: song.videoId)
            } else {
                let factory = self
                let ahead = await MainActor.run { factory.map { !$0.isPlaying(song.videoId) } ?? false }
                if ahead {
                    // Nothing is looked up for a row ahead until the playing track sounds: on a weak
                    // link, its start has the connection to itself.
                    await PlaybackSourceFactory.held(until: { await MainActor.run { factory.map { $0.isSounding() || $0.isPlaying(song.videoId) } ?? true } },
                                                     atMost: soundingWait)
                    try Task.checkCancellation()
                }
                // Queue only: a row opened ahead of time (the engine's gapless preload), one a look
                // ahead is still finding, or one whose found copy went stale, waits for the ranked
                // sources' copy, so it starts on it. A row nobody looked for and that is wanted now
                // (tapped from a search) starts as with Off.
                let joins = readsAhead && (ahead || readAheadStreams.lookup(for: song.videoId, request: wanted, atmosAllowed: atmos) != nil
                    || readAheadStreams.wentStale(song.videoId, request: wanted, atmosAllowed: atmos))
                TrackLog.d(PlaybackSourceFactory.logCategory, "resolving '\(song.title)' (\(wanted.tier))" + (joins ? (ahead ? " ahead of time" : " with its look ahead") : ""),
                           about: song.videoId)
                do {
                    // Filed under the track, so the race's own lines (each source, each add-on call)
                    // land in this track's log rather than in every track's.
                    if joins {
                        let lookup = readAheadStreams.lookUp(song.videoId, request: wanted, atmosAllowed: atmos) {
                            var asked = wanted
                            asked.waitsForSources = true
                            return try await TrackLog.about(song.videoId) { try await resolver.resolveStream(for: song, request: asked) }
                        }
                        // As long as the lookup takes while nobody is listening yet; once the row is
                        // playing, until `lookupJoinWait` after the lookup started.
                        var found = await PlaybackSourceFactory.waitedFor(lookup.task, until: { await MainActor.run { factory?.isPlaying(song.videoId) ?? true } })
                        try Task.checkCancellation()
                        if found == nil {
                            let left = lookupJoinWait - (ContinuousClock.now - lookup.startedAt)
                            if left > .zero {
                                let task = lookup.task
                                found = await withDeadline(left) { try? await task.value }
                            }
                            try Task.checkCancellation()
                        }
                        if let found, !found.belowRequest {
                            picked = found
                            refind = waitingRace
                        } else {
                            // The sources had nothing, or not in time: it starts now, as a tapped
                            // row does, and the upgrade can still swap their copy in.
                            TrackLog.d(PlaybackSourceFactory.logCategory, "'\(song.title)' starts without its sources' copy", about: song.videoId)
                            picked = try await TrackLog.about(song.videoId) { try await resolver.resolveStream(for: song, request: wanted) }
                        }
                    } else if let quickFind, ahead {
                        // Off: the quick sources are asked first, until the row is reached. Their copy
                        // is what read-ahead fetches; without one the row races as before.
                        let lookup = readAheadStreams.lookUp(song.videoId, request: wanted, atmosAllowed: atmos, resolve: quickFind)
                        let found = await PlaybackSourceFactory.waitedFor(lookup.task, until: { await MainActor.run { factory?.isPlaying(song.videoId) ?? true } })
                        try Task.checkCancellation()
                        if let found {
                            picked = found
                            refind = quickFind
                        } else {
                            // Let go of, so a late answer isn't kept and fetched under the key this
                            // row's own copy fills.
                            readAheadStreams.forget(song.videoId)
                            picked = try await TrackLog.about(song.videoId) { try await resolver.resolveStream(for: song, request: wanted) }
                        }
                    } else {
                        // Off: a quick lookup still running for a row that races now is let go of, as above.
                        if quickFind != nil { readAheadStreams.forget(song.videoId) }
                        picked = try await TrackLog.about(song.videoId) { try await resolver.resolveStream(for: song, request: wanted) }
                        // Always: the next row resolved while the playing one runs.
                        if ahead, wanted.waitsForSources, !pinned { refind = waitingRace }
                    }
                } catch {
                    TrackLog.w(PlaybackSourceFactory.logCategory, "resolving '\(song.title)' failed after \(TrackLog.ms(since: started))ms", error: error, about: song.videoId)
                    throw error
                }
                TrackLog.d(PlaybackSourceFactory.logCategory, "resolved '\(song.title)' in \(TrackLog.ms(since: started))ms: \(picked.origin) \(picked.format.summary)"
                    + (picked.belowRequest ? " (below request)" : ""), about: song.videoId)
            }
            var stamped = picked
            if refind != nil, stamped.origin != .youtube {
                // A copy found ahead counts as expired past its freshness, so the byte source finds
                // it again before reading on (a lookup already stamped it when it was found).
                stamped.expiresAt = min(stamped.expiresAt ?? .distantFuture, Date().addingTimeInterval(ReadAheadStreams.freshness))
            }
            let stream = stamped
            let refindAhead = refind
            facts.record(itemID: itemID, stream: stream)
            let factory = self
            await MainActor.run { factory?.noteResolved(itemID: itemID, videoId: song.videoId, stream: stream) }

            // A substitute's URL is re-minted by the engine's retry, which calls this factory again;
            // re-resolving freely here could come back with YouTube's file, or another source's,
            // under the same key. Only a copy found ahead of time is found again here, once stale or
            // refused, and only a copy from the same source is taken.
            let foundAgain: HTTPAudioSource.Resolver?
            if let refindAhead {
                foundAgain = {
                    if let fresh = try? await refindAhead(), fresh.origin == stream.origin, fresh.sourceConfigId == stream.sourceConfigId {
                        return fresh
                    }
                    // Nobody else's copy: the one found plays on until its server refuses it.
                    var unchanged = stream
                    unchanged.expiresAt = nil
                    return unchanged
                }
            } else {
                foundAgain = nil
            }

            // A playlist stream goes through the cache as one file, so it is fetched once and kept,
            // its segment links found again as an HTTP copy's URL is. A row opened ahead waits for
            // its layout until it is reached: the playlist it would otherwise settle on is uncached
            // for the whole play and starts with nothing buffered.
            if let cache, stream.origin != .youtube, SegmentedAudioSource.handles(stream),
               let source = await segmented?.source(for: stream, refresh: foundAgain, listening: { await MainActor.run { factory?.isPlaying(song.videoId) ?? true } }) {
                let key = sourceKey.map { AudioCacheKey.source($0.configId, track: $0.trackId) }
                    ?? .substitute(videoId: song.videoId, atmosAllowed: atmos)
                playingKeys.set(key.rawValue, for: song.videoId, item: itemID)
                let factory = self
                await MainActor.run { factory?.completeLater(key, source: source, videoId: song.videoId) }
                return (cache.makeAsset(for: key, source: source), stream)
            }
            // Let go of mid-wait: not settled on the playlist, which the engine would keep for this
            // item's next open.
            if SegmentedAudioSource.handles(stream) { try Task.checkCancellation() }
            if SourcePlaylistLoader.handles(stream.url) {
                // A DASH manifest converted to HLS: AVFoundation refuses a file:// playlist with
                // remote segments, so the loader answers the custom scheme (Sources report).
                var options: [String: Any] = [:]
                if !stream.headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = stream.headers }
                let asset = AVURLAsset(url: stream.url, options: options)
                SourcePlaylistLoader.shared.attach(to: asset)
                return (asset, stream)
            }
            guard let cache else { return (PlaybackSourceFactory.plainAsset(for: stream), stream) }

            let key: AudioCacheKey
            let refresh: HTTPAudioSource.Resolver?
            switch stream.origin {
            case .youtube:
                key = .youtube(videoId: song.videoId)
                if let youTube {
                    refresh = { try await youTube.resolveStream(for: song, request: wanted) }
                } else {
                    refresh = nil
                }
            default:
                if let sourceKey {
                    key = AudioCacheKey.source(sourceKey.configId, track: sourceKey.trackId)
                } else {
                    key = .substitute(videoId: song.videoId, atmosAllowed: atmos)
                }
                refresh = foundAgain
            }
            playingKeys.set(key.rawValue, for: song.videoId, item: itemID)
            return (cache.makeAsset(for: key, stream: stream, session: session, refresh: refresh, onRefused: onRefused), stream)
        }
    }

    /// Whether `song` plays YouTube's own upload because the listener pinned it there, or because a
    /// copy above YouTube broke it (``fallBackToYouTube(_:)``). Without a `youTube` resolver (tests)
    /// there is no pin to honour, and a source-backed row isn't a YouTube id at all.
    private func isPinnedToYouTube(_ song: Song) -> Bool {
        (isPinnedToOriginal(song.videoId) || streamChoice.substitutesRefused(for: song.videoId))
            && youTube != nil && SourceRegistry.parseTrackKey(song.videoId) == nil
    }

    /// The read-ahead plan for the tracks following the one playing, in play order, up to
    /// ``AudioStreamCache/queueDepth``. Applies Android's `prefetchQueue` filters, because bytes
    /// spent under a key playback will not read are bytes wasted:
    ///
    /// - a row with a parsable track key plays from its own server (or a local/network copy), never
    ///   googlevideo;
    /// - a downloaded or pinned-to-YouTube row plays a file (or a rendition read-ahead does not
    ///   fill);
    /// - the stream URL warmed is YouTube's, never an add-on's answer (see `warmer` below), except
    ///   with Direct source stream's Queue only, where the whole race runs and waits for the ranked
    ///   sources, and its answer is kept for the track to start on (its copy then goes onto disk:
    ///   the next track's whole on an unmetered connection, otherwise only the opening);
    /// - when a source outranks YouTube for this request, only the stream URL is warmed: read-ahead
    ///   resolving to YouTube on its own would write Opus into the entry a substitute is about to
    ///   fill from another server, under the same key. Except Off's next track, when a quick source
    ///   has it (``quickCopy``, Android's `prefetchSubstitute`): the track's open asks it first and
    ///   starts on its answer, and read-ahead fetches that same copy whole;
    /// - with Always and a source ranked above YouTube, nothing: the track's open asks the sources
    ///   itself, and a YouTube URL warmed for it would go unused (Android switches ordinary
    ///   read-ahead off in Direct mode).
    ///
    /// A row whose copy above YouTube broke (``fallBackToYouTube(_:)``) only has YouTube's URL warmed.
    func prefetchItems(for songs: [Song]) -> [AudioCachePrefetchItem] {
        guard cache != nil else { return [] }
        let request = request()
        let needsSource = !canSubstitute(request)
        if request.waitsForSources, !needsSource { return [] }
        let resolver = self.resolver
        // The URL warm-up goes to YouTube's own resolver, as Android's `prefetchQueue` does: through
        // `resolver` it would be the whole race, every add-on searched and asked for a stream of a
        // track that may never play, with URLs minted minutes before they're used.
        let warmer = youTube ?? resolver
        let onRefused = self.onRefused
        let session = self.session
        let atmos = atmosAllowed()
        let readAheadStreams = self.readAheadStreams
        let cache = self.cache
        let segmented = self.segmented
        let soundingWait = self.soundingWait
        let unmetered = isUnmetered()
        // Queue only: an add-on's stream for a track ahead is the point, so the race waits for the
        // ranked sources as Always does at play time; the track then starts on what it found.
        let waiting = { var asked = request; asked.waitsForSources = true; return asked }()
        // The sources' copy of a track ahead as the cache fetches it, or nil: YouTube's plays under
        // its own key, and a playlist the cache can't lay out isn't cached at all.
        let copySource: @Sendable (ResolvedStream) async -> (any AudioRangeDataSource)? = { stream in
            guard stream.origin != .youtube else { return nil }
            // Nobody is listening to a track ahead, so no deadline: a wait cut short ends this pass
            // with nothing fetched, though the layout lands moments later.
            if SegmentedAudioSource.handles(stream) { return await segmented?.source(for: stream, listening: { false }) }
            if SourcePlaylistLoader.handles(stream.url) { return nil }
            return HTTPAudioSource(stream: stream, session: session, onRefused: onRefused)
        }
        // Whether the track playing sounds yet (or `videoId` is the one playing, after a skip).
        let sounding: @Sendable (String) async -> Bool = { [weak self] videoId in
            let factory = self
            return await MainActor.run { factory.map { $0.isSounding() || $0.isPlaying(videoId) } ?? true }
        }
        // The first row read-ahead fetches bytes for (rows that play from elsewhere are left out).
        var isNext = true
        return songs.prefix(AudioStreamCache.queueDepth).compactMap { song in
            guard SourceRegistry.parseTrackKey(song.videoId) == nil,
                  Self.localFileURL(of: song) == nil,
                  networkSource(song) == nil,
                  savedFile(song) == nil,
                  !isPinnedToOriginal(song.videoId) else { return nil }
            defer { isNext = false }
            let key = AudioCacheKey.youtube(videoId: song.videoId)
            // Where the open reads the sources' copy.
            let copyKey = AudioCacheKey.substitute(videoId: song.videoId, atmosAllowed: atmos)
            let refused = streamChoice.substitutesRefused(for: song.videoId)
            // Started after the playing track's start, not alongside it: on a weak link the start
            // has the connection to itself (Android waits 8 s before reading ahead at all).
            let holdForStart: @Sendable () async -> Void = {
                await PlaybackSourceFactory.held(until: { await sounding(song.videoId) }, atMost: soundingWait)
            }
            let warmUp: @Sendable () async throws -> Void
            if request.readsAheadFromSources, !refused {
                // A lookup of its own, not this warm-up's: read-ahead is replaced on every queue
                // edit (AutoPlay appending, most often), and a slow add-on's answer must outlive that.
                let lookUp: @Sendable () -> Task<ResolvedStream, Error> = {
                    let lookup = readAheadStreams.lookUp(song.videoId, request: request, atmosAllowed: atmos) {
                        try await resolver.resolveStream(for: song, request: waiting)
                    } then: { stream in
                        // Its opening onto disk where the open reads it, so a skip onto the track
                        // plays the sources' copy from the first byte.
                        guard let cache, !stream.belowRequest, let source = await copySource(stream) else { return }
                        await cache.warmRange(copyKey, source: source, range: 0..<PlaybackSourceFactory.openingBytes)
                    }
                    return lookup.task
                }
                // Held outside the lookup, so the wait isn't counted against a skip's join
                // (`lookupJoinWait`).
                warmUp = {
                    await holdForStart()
                    _ = try await lookUp().value
                }
                // By design, the whole copy only on an unmetered connection; on cellular or in
                // Low Data Mode the next track gets its opening, like the tracks after it.
                if isNext, !needsSource, unmetered {
                    // The next track: its whole copy onto disk, so a skip onto it starts from disk
                    // rather than on what a slow link delivers past the opening. Read-ahead's own
                    // pass for the next track fetches it (no byte twice, and it stops when the
                    // queue moves on), from whatever the look ahead finds.
                    let copy = LookAheadCopySource {
                        let stream: ResolvedStream
                        if let kept = readAheadStreams.stream(for: song.videoId, request: request, atmosAllowed: atmos) {
                            stream = kept
                        } else {
                            await holdForStart()
                            stream = try await lookUp().value
                        }
                        guard !stream.belowRequest else { return nil }
                        return await copySource(stream)
                    }
                    return AudioCachePrefetchItem(key: copyKey, source: copy, warmUp: warmUp)
                }
            } else {
                warmUp = {
                    await holdForStart()
                    _ = try await warmer.resolveStream(for: song, request: request)
                }
                if isNext, !needsSource, !request.readsAheadFromSources, !refused, quickCopy != nil {
                    // Off: the quick sources' copy of the next track, whole onto disk. Only the
                    // track's open (the engine's gapless preload) asks them, and it starts on what
                    // it keeps, so read-ahead never fetches a copy the open didn't choose.
                    let copy = LookAheadCopySource {
                        // The open asks once the playing track sounds; give it that long to start.
                        let deadline = ContinuousClock.now + soundingWait + .seconds(5)
                        while readAheadStreams.stream(for: song.videoId, request: request, atmosAllowed: atmos) == nil, ContinuousClock.now < deadline {
                            if let running = readAheadStreams.lookup(for: song.videoId, request: request, atmosAllowed: atmos) {
                                _ = try? await running.value
                                break
                            }
                            try await Task.sleep(for: .milliseconds(250))
                        }
                        // Only a kept answer: one the open let go of (it started the row on another
                        // copy, under the same key) isn't. Without one, YouTube's URL is warmed, as
                        // for the tracks after it.
                        guard let kept = readAheadStreams.stream(for: song.videoId, request: request, atmosAllowed: atmos) else {
                            _ = try? await warmer.resolveStream(for: song, request: request)
                            return nil
                        }
                        return await copySource(kept)
                    }
                    return AudioCachePrefetchItem(key: copyKey, source: copy, warmUp: warmUp)
                }
            }
            guard needsSource else {
                return AudioCachePrefetchItem(key: key, source: nil, warmUp: warmUp)
            }
            // YouTube's next track: its first bytes wait for the playing track's start too, not just
            // read-ahead's own 2 s grace.
            let source = HTTPAudioSource(session: session, onRefused: onRefused) {
                await holdForStart()
                return try await resolver.resolveStream(for: song, request: request)
            }
            return AudioCachePrefetchItem(key: key, source: source, warmUp: warmUp)
        }
    }

    nonisolated static let logCategory = "Playback"

    /// An asset for a stream played without the cache, headers and MIME hint attached.
    nonisolated static func plainAsset(for stream: ResolvedStream) -> AVURLAsset {
        var options: [String: Any] = [:]
        if !stream.headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = stream.headers }
        if let mime = stream.mimeType?.split(separator: ";").first.map(String.init), !mime.isEmpty {
            options[AVURLAssetOverrideMIMETypeKey] = mime
        }
        return AVURLAsset(url: stream.url, options: options)
    }
}

extension PlaybackSourceFactory {
    struct NoQuickCopy: Error, CustomStringConvertible {
        var description: String { "no quick source has a copy" }
    }

    /// The quick sources' copy of `song` as a lookup ``ReadAheadStreams`` can share; nil without
    /// `quickCopy`. Throws when no quick source has the track, so nothing is kept.
    nonisolated static func quickFind(_ quickCopy: (@Sendable (Song, StreamRequest) async throws -> ResolvedStream?)?,
                                      song: Song, request: StreamRequest) -> HTTPAudioSource.Resolver? {
        guard let quickCopy else { return nil }
        return {
            guard let stream = try await TrackLog.about(song.videoId, operation: { try await quickCopy(song, request) }) else { throw NoQuickCopy() }
            return stream
        }
    }

    /// Returns once `ready` says so, `cap` has passed, or the caller is cancelled.
    nonisolated static func held(until ready: @escaping @Sendable () async -> Bool, atMost cap: Duration,
                                 poll: Duration = .milliseconds(250)) async {
        let deadline = ContinuousClock.now + cap
        while ContinuousClock.now < deadline, !(await ready()) {
            guard (try? await Task.sleep(for: poll)) != nil else { return }
        }
    }

    /// `waiting`'s answer, or nil as soon as `isPlaying` says the row has started (or `waiting`
    /// failed). Returns on whichever comes first: abandoning the wait leaves `waiting` running, so
    /// its answer is still kept. (Not a task group, which would wait for `waiting` regardless:
    /// awaiting a task's value ignores the waiter's cancellation.)
    nonisolated static func waitedFor(_ waiting: Task<ResolvedStream, Error>, until isPlaying: @escaping @Sendable () async -> Bool,
                                      poll: Duration = .milliseconds(150)) async -> ResolvedStream? {
        let first = FirstAnswer()
        // A skip cancels the open: the wait ends there too, and `waiting` runs on regardless.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ResolvedStream?, Never>) in
                first.hold(continuation)
                let watcher = Task {
                    while !Task.isCancelled {
                        if await isPlaying() {
                            first.answer(nil)
                            return
                        }
                        try? await Task.sleep(for: poll)
                    }
                }
                Task {
                    let found = try? await waiting.value
                    watcher.cancel()
                    first.answer(found)
                }
            }
        } onCancel: {
            first.answer(nil)
        }
    }
}

/// Resumes a continuation once, with the first answer any racer gives, including one given
/// before the continuation was handed over.
private final class FirstAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ResolvedStream?, Never>?
    private var answered: ResolvedStream??

    func hold(_ continuation: CheckedContinuation<ResolvedStream?, Never>) {
        let early = lock.withLock { () -> ResolvedStream?? in
            if let answered { return answered }
            self.continuation = continuation
            return nil
        }
        if let early { continuation.resume(returning: early) }
    }

    func answer(_ value: ResolvedStream?) {
        let waiting = lock.withLock { () -> CheckedContinuation<ResolvedStream?, Never>? in
            guard answered == nil else { return nil }
            answered = .some(value)
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: value)
    }
}

/// What the source race answered for tracks ahead, by video id: the copy read-ahead found is the
/// one played, until it goes stale or a retry of the track forgets it.
final class ReadAheadStreams: @unchecked Sendable {
    /// About how long an add-on's stream is held in its own cache, and how long read-ahead's
    /// warm-up stands: past it the URL may be dead, and YouTube starts the track instead.
    static let freshness: TimeInterval = 5 * 60
    /// How long a stale entry is remembered as having been found.
    static let staleKept: TimeInterval = 60 * 60

    private struct Entry {
        var stream: ResolvedStream
        var request: StreamRequest
        var atmosAllowed: Bool
        var foundAt: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func put(_ stream: ResolvedStream, for videoId: String, request: StreamRequest, atmosAllowed: Bool) {
        // YouTube's copy taken while the sources were still looking isn't the answer: kept, the
        // track would start on it. Left out, the track asks again when it plays, by when the
        // sources' late answer is usually in their cache; an answer already kept stands. Nor, in
        // Queue only, is a source's copy below the request: the look ahead gave up on a better one.
        // Off's quick copy is kept as it comes: it is what the track would start on anyway.
        lock.withLock { keep(stream, for: videoId, request: request, atmosAllowed: atmosAllowed) }
    }

    /// ``put(_:for:request:atmosAllowed:)`` with `lock` held.
    private func keep(_ stream: ResolvedStream, for videoId: String, request: StreamRequest, atmosAllowed: Bool) {
        guard !stream.belowRequest || (stream.origin != .youtube && !request.readsAheadFromSources) else { return }
        let now = Date()
        // Stale entries are kept a while, so ``wentStale(_:request:atmosAllowed:)`` can tell.
        entries = entries.filter { now.timeIntervalSince($0.value.foundAt) < Self.staleKept }
        entries[videoId] = Entry(stream: stream, request: request, atmosAllowed: atmosAllowed, foundAt: now)
    }

    /// The stream found for `videoId`, if it was found for this same request and Atmos switch (a
    /// change of connection or setting since asks again) and is still fresh.
    func stream(for videoId: String, request: StreamRequest, atmosAllowed: Bool) -> ResolvedStream? {
        lock.withLock { kept(videoId, request: request, atmosAllowed: atmosAllowed) }
    }

    /// ``stream(for:request:atmosAllowed:)`` with `lock` held.
    private func kept(_ videoId: String, request: StreamRequest, atmosAllowed: Bool) -> ResolvedStream? {
        guard let entry = entries[videoId], entry.request == request, entry.atmosAllowed == atmosAllowed, Self.isFresh(entry) else { return nil }
        return entry.stream
    }

    /// Whether a copy was found for `videoId` under this request, and has gone past its freshness:
    /// the track looks again, rather than playing a dead URL or starting on YouTube.
    func wentStale(_ videoId: String, request: StreamRequest, atmosAllowed: Bool) -> Bool {
        guard let entry = lock.withLock({ entries[videoId] }), entry.request == request, entry.atmosAllowed == atmosAllowed else { return false }
        return !Self.isFresh(entry)
    }

    private static func isFresh(_ entry: Entry) -> Bool {
        Date().timeIntervalSince(entry.foundAt) < freshness && !entry.stream.isExpired()
    }

    private struct Lookup {
        var task: Task<ResolvedStream, Error>
        var request: StreamRequest
        var atmosAllowed: Bool
        var startedAt: ContinuousClock.Instant
        var token: UUID
        /// What to run on the answer once it lands: every asker's, so joining never drops one.
        var then: [@Sendable (ResolvedStream) async -> Void]
    }

    private var lookups: [String: Lookup] = [:]

    /// The lookup for `videoId`: one already running for the same request, the answer one kept, or
    /// `resolve` started now. Unstructured, so it outlives whoever asked: its answer is kept when it
    /// lands, and `then` runs on it after that, without holding up anyone waiting for the answer.
    ///
    /// Read-ahead and the engine's early open of the row both wait for the playing track to sound,
    /// then ask here. An answer that lands before the second one asks is that second one's too, or
    /// the sources would be asked twice.
    func lookUp(_ videoId: String, request: StreamRequest, atmosAllowed: Bool,
                resolve: @escaping @Sendable () async throws -> ResolvedStream,
                then: (@Sendable (ResolvedStream) async -> Void)? = nil) -> (task: Task<ResolvedStream, Error>, startedAt: ContinuousClock.Instant) {
        lock.withLock {
            if let running = lookups[videoId], running.request == request, running.atmosAllowed == atmosAllowed {
                if let then { lookups[videoId]?.then.append(then) }
                return (running.task, running.startedAt)
            }
            if let stream = kept(videoId, request: request, atmosAllowed: atmosAllowed) {
                if let then { Task { await then(stream) } }
                return (Task<ResolvedStream, Error> { stream }, ContinuousClock.now)
            }
            let token = UUID()
            let task = Task<ResolvedStream, Error> {
                do {
                    var answer = try await resolve()
                    // A source's copy counts as expired past its freshness, so the byte source the
                    // track opens on finds it again before reading on (a long track can outlive it).
                    if answer.origin != .youtube {
                        answer.expiresAt = min(answer.expiresAt ?? .distantFuture, Date().addingTimeInterval(Self.freshness))
                    }
                    let stream = answer
                    // Not when the track was forgotten meanwhile (its stream died): the retry asks afresh.
                    // Ended and kept under one lock: a forget() in between would otherwise be undone.
                    if let thens = self.end(videoId, token: token, keeping: stream) {
                        if !thens.isEmpty { Task { for then in thens { await then(stream) } } }
                    }
                    return stream
                } catch {
                    self.end(videoId, token: token)
                    throw error
                }
            }
            let startedAt = ContinuousClock.now
            lookups[videoId] = Lookup(task: task, request: request, atmosAllowed: atmosAllowed, startedAt: startedAt, token: token,
                                      then: then.map { [$0] } ?? [])
            return (task, startedAt)
        }
    }

    /// The lookup still running for `videoId` under this request, if any.
    func lookup(for videoId: String, request: StreamRequest, atmosAllowed: Bool) -> Task<ResolvedStream, Error>? {
        lock.withLock {
            guard let running = lookups[videoId], running.request == request, running.atmosAllowed == atmosAllowed else { return nil }
            return running.task
        }
    }

    /// Ends the lookup `token` started, keeping `answer` if there is one, and hands back what to run
    /// on it; nil when it was no longer the current one (nothing is kept then).
    @discardableResult
    private func end(_ videoId: String, token: UUID, keeping answer: ResolvedStream? = nil) -> [@Sendable (ResolvedStream) async -> Void]? {
        lock.withLock {
            guard let running = lookups[videoId], running.token == token else { return nil }
            lookups[videoId] = nil
            if let answer { keep(answer, for: videoId, request: running.request, atmosAllowed: running.atmosAllowed) }
            return running.then
        }
    }

    /// Drops what was found for `videoId`, and a lookup still running: a retry neither rejoins it
    /// nor has its answer put back.
    func forget(_ videoId: String) {
        lock.withLock {
            entries[videoId] = nil
            lookups[videoId] = nil
        }
    }
}

/// The next track's own copy as read-ahead's byte source, before anyone knows what it is: `find`
/// waits for the look ahead and hands back the copy's source, or nil when there is nothing to put
/// under the sources' key (YouTube's stand-in). Found once, however often the cache asks (its
/// whole-file pass retries); only a lookup that failed is asked again.
final class LookAheadCopySource: AudioRangeDataSource, @unchecked Sendable {
    struct NoCopy: Error, CustomStringConvertible {
        var description: String { "the look ahead found no copy of the sources' to fetch" }
    }

    private let find: @Sendable () async throws -> (any AudioRangeDataSource)?
    private let lock = NSLock()
    private var finding: Task<any AudioRangeDataSource, Error>?
    private var found: (any AudioRangeDataSource)?
    private var expected: Int64?

    init(find: @escaping @Sendable () async throws -> (any AudioRangeDataSource)?) {
        self.find = find
    }

    private func copy() async throws -> any AudioRangeDataSource {
        let task = lock.withLock { () -> Task<any AudioRangeDataSource, Error> in
            if let finding { return finding }
            let find = self.find
            let task = Task<any AudioRangeDataSource, Error> {
                guard let source = try await find() else { throw NoCopy() }
                return source
            }
            finding = task
            return task
        }
        let source: any AudioRangeDataSource
        do {
            source = try await task.value
        } catch {
            // A failed lookup is asked again on the cache's next retry; a copy that isn't the
            // sources' stays the answer, rather than a fresh race on every retry.
            if !(error is NoCopy) { lock.withLock { if finding == task { finding = nil } } }
            throw error
        }
        let expected = lock.withLock { () -> Int64? in
            found = source
            return self.expected
        }
        source.expectContentLength(expected)
        return source
    }

    func expectContentLength(_ length: Int64?) {
        let source = lock.withLock { () -> (any AudioRangeDataSource)? in
            expected = length
            return found
        }
        source?.expectContentLength(length)
    }

    func contentInfo() async throws -> AudioContentInfo {
        try await copy().contentInfo()
    }

    func read(_ range: Range<Int64>) async throws -> Data {
        try await copy().read(range)
    }

    func stream(_ range: Range<Int64>) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let source = try await self.copy()
                    try Task.checkCancellation()
                    for try await piece in source.stream(range) { continuation.yield(piece) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The copy's own, once found; until then the cache's default.
    var maxRangeBytes: Int64 {
        lock.withLock { found }?.maxRangeBytes ?? 1_024 * 1_024
    }
}

/// Which cache key each video id is being played from, readable from any thread.
///
/// Kept per engine item, so a row the engine plays again from the audio it still holds (a return
/// to a row a swap moved off) is put back on the key it was opened under when it becomes current
/// (``becameCurrent(_:videoId:)``): no factory runs for it, and the key left behind named the copy
/// swapped in. The oldest items go past ``limit``; the map used to be wiped instead, taking
/// the playing row's key with it.
final class PlayingCacheKeys: @unchecked Sendable {
    private struct Opened {
        var item: String
        var videoId: String
        var key: String
        /// Whether the bytes came off the disk rather than from a resolve this process made.
        var fromCache: Bool
    }

    /// How many items are remembered: the row playing is the newest, a reused one is a few back.
    static let limit = 64
    private let lock = NSLock()
    /// Oldest first.
    private var opened: [Opened] = []
    /// The item each video id's playing copy belongs to.
    private var current: [String: String] = [:]

    func set(_ key: String, for videoId: String, item: String, fromCache: Bool = false) {
        lock.withLock { remember(Opened(item: item, videoId: videoId, key: key, fromCache: fromCache)) }
    }

    /// The engine made `item` current. One it plays from the audio it already opened runs no
    /// factory, so its own key is put back.
    func becameCurrent(_ item: String, videoId: String) {
        lock.withLock {
            guard let known = opened.last(where: { $0.item == item }), known.videoId == videoId else { return }
            remember(known)
        }
    }

    func key(for videoId: String) -> String? {
        lock.withLock { playing(videoId)?.key }
    }

    /// Whether the row's playing copy was served whole from the disk cache, without resolving.
    func playedFromCache(_ videoId: String) -> Bool {
        lock.withLock { playing(videoId)?.fromCache ?? false }
    }

    private func remember(_ copy: Opened) {
        opened.removeAll { $0.item == copy.item }
        opened.append(copy)
        current[copy.videoId] = copy.item
        guard opened.count > Self.limit else { return }
        let dropped = opened.removeFirst()
        if current[dropped.videoId] == dropped.item { current[dropped.videoId] = nil }
    }

    private func playing(_ videoId: String) -> Opened? {
        guard let item = current[videoId] else { return nil }
        return opened.last { $0.item == item }
    }
}
