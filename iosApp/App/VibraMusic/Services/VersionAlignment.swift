import AudioCache
import Automix
import VibraMusicCore
import Foundation
import StreamResolution

// Ports PlaybackService.kt's `prepareVersionAlignment` / `measureVersionAlignmentAsync`: before a
// song ↔ music video switch, both cuts' openings are fetched and cross-correlated so the other cut
// starts where the listener actually is.

/// How far lining up two cuts of a recording has got, for stats for nerds ("Aligned: +6.5 s").
/// The app's copy of Automix's `VersionAudioAligner.AlignmentStatus`, so views needn't import it.
struct VersionAlignmentStatus: Hashable {
    enum Phase: String, Hashable {
        case fetching, measuring, aligned, failed
    }

    /// The cut playing when the switch started, and the one switched to.
    var sourceId: String
    var targetId: String
    var phase: Phase
    /// The shift applied (or about to be), once known: target position = source position + offset.
    var offsetMs: Int64?
    /// Recalled from an earlier switch between the same pair rather than measured now.
    var fromCache: Bool

    init(sourceId: String, targetId: String, phase: Phase, offsetMs: Int64? = nil, fromCache: Bool = false) {
        self.sourceId = sourceId
        self.targetId = targetId
        self.phase = phase
        self.offsetMs = offsetMs
        self.fromCache = fromCache
    }

    init(_ status: VersionAudioAligner.AlignmentStatus) {
        self.init(sourceId: status.sourceId, targetId: status.targetId,
                  phase: Phase(rawValue: status.phase.rawValue) ?? .failed,
                  offsetMs: status.offsetMs, fromCache: status.fromCache)
    }

    /// Whether this status is about the switch away from, or onto, `videoId`.
    func concerns(_ videoId: String?) -> Bool { videoId == sourceId || videoId == targetId }

    /// Where the target cut starts: the source position plus the offset, never before 0.
    static func targetPositionMs(sourcePositionMs: Int64, offsetMs: Int64) -> Int64 {
        VersionAudioAligner.targetPositionMs(sourcePositionMs: sourcePositionMs, offsetMs: offsetMs)
    }
}

/// Measures the offset between a song and its music video for ``PlayerController/switchVersion()``.
///
/// Both openings are pulled into the audio cache at once (the analysis head: enough for the
/// aligner's 45 s window), then the aligner reads them through the cache's rendition links. With no
/// cache (or a head that never came) the aligner falls back to YouTube's stream URL, fetched with
/// its headers and duration-patched. One measurement per pair runs at a time; a second switch
/// waits on the first instead of paying for it twice.
@MainActor
final class VersionAlignmentService {
    let aligner: VersionAudioAligner
    private let cache: AudioStreamCache?
    private let renditions: AudioCacheRenditions?
    /// YouTube's own copy of a video id, as a byte source for the cache.
    private let headSource: @Sendable (String) -> (any AudioRangeDataSource)?
    /// YouTube's stream for a video id, for when nothing is cached.
    private let remoteStream: @Sendable (String) async -> ResolvedStream?
    /// The measurement per pair, with the token its founder opened it under: a second switch to
    /// the same counterpart joins under that token, so it can't invalidate the founder's.
    private var running: [String: (token: Int64, task: Task<Int64?, Never>)] = [:]
    private var statusTask: Task<Void, Never>?

    /// Android's `ALIGNMENT_HEAD_TIMEOUT_MS` and `ALIGNMENT_MEASURE_TIMEOUT_MS`.
    static let headTimeout: Duration = .seconds(20)
    static let measureTimeout: Duration = .seconds(30)

    init(
        aligner: VersionAudioAligner,
        cache: AudioStreamCache?,
        renditions: AudioCacheRenditions?,
        headSource: @escaping @Sendable (String) -> (any AudioRangeDataSource)?,
        remoteStream: @escaping @Sendable (String) async -> ResolvedStream?
    ) {
        self.aligner = aligner
        self.cache = cache
        self.renditions = renditions
        self.headSource = headSource
        self.remoteStream = remoteStream
    }

    /// The aligner the app uses: the cache's renditions, and StreamResolution's init-segment patch
    /// for a remote copy (AVFoundation reads YouTube's fragmented AAC at twice its length unpatched).
    static func makeAligner(renditions: AutomixRenditionProvider?, session: URLSession) -> VersionAudioAligner {
        VersionAudioAligner(renditions: renditions, session: session, remoteHeadPatch: { data in
            _ = YouTubeMP4InitSegment.patchDurations(in: &data)
        })
    }

    /// Mirrors the aligner's status onto `player.versionAlignment` for as long as the app runs.
    func publishStatus(to player: PlayerController) {
        statusTask?.cancel()
        let updates = aligner.statusUpdates()
        statusTask = Task { @MainActor [weak player] in
            for await status in updates {
                guard let player else { return }
                player.versionAlignment = status.map(VersionAlignmentStatus.init)
            }
        }
    }

    /// The offset from `source` to `target` in ms, or nil when it couldn't be measured. Walks the
    /// aligner's status through fetching → measuring → aligned/failed on the way.
    func offset(from source: Song, to target: Song) async -> Int64? {
        if let cached = aligner.cachedOffsetMs(sourceVideoId: source.videoId, targetVideoId: target.videoId) {
            let token = aligner.beginAttempt(sourceId: source.videoId, targetId: target.videoId)
            aligner.publishPhase(token, phase: .aligned, offsetMs: cached, fromCache: true)
            return cached
        }
        let key = "\(source.videoId)\u{1F}\(target.videoId)"
        let found: (token: Int64, task: Task<Int64?, Never>)
        if let existing = running[key] {
            found = existing
        } else {
            let founding = aligner.beginAttempt(sourceId: source.videoId, targetId: target.videoId)
            aligner.publishPhase(founding, phase: .fetching)
            found = (founding, Task { await self.measure(source, target, token: founding) })
            running[key] = found
        }
        let token = found.token
        let measured = await found.task.value
        // Not a newer measurement of the pair that started after this one finished.
        if running[key]?.token == token { running[key] = nil }
        aligner.publishPhase(token, phase: measured == nil ? .failed : .aligned, offsetMs: measured)
        return measured
    }

    private func measure(_ source: Song, _ target: Song, token: Int64) async -> Int64? {
        async let sourceHead = head(of: source)
        async let targetHead = head(of: target)
        let (sourceReady, targetReady) = await (sourceHead, targetHead)
        if !sourceReady || !targetReady {
            // Measured anyway: the aligner reads the largest opening on disk, and a short one
            // still correlates better than not trying.
            TrackLog.w("Automix", "version alignment head short on disk (source=\(sourceReady), target=\(targetReady)) for '\(source.title)'",
                       about: source.videoId)
        }
        aligner.publishPhase(token, phase: .measuring)
        let sourceTrack = await track(for: source, cached: sourceReady)
        let targetTrack = await track(for: target, cached: targetReady)
        let aligner = self.aligner
        // Returns at the deadline even if a decode is still grinding (Kotlin's withTimeoutOrNull).
        return await withDeadline(Self.measureTimeout) {
            await aligner.findOffsetMs(source: sourceTrack, target: targetTrack)
        }
    }

    /// Pulls `song`'s opening into the cache. True when enough of it is there (or it is a file
    /// on the device, which needs nothing).
    private func head(of song: Song) async -> Bool {
        if PlaybackSourceFactory.localFileURL(of: song) != nil { return true }
        guard let cache, let source = headSource(song.videoId) else { return false }
        let ready = await cache.awaitAnalysisHead(for: .youtube(videoId: song.videoId), source: source, timeout: Self.headTimeout)
        if let renditions, let watch = URL(string: "vibramusic://watch?v=\(song.videoId)") {
            _ = await renditions.refresh(trackID: AudioCacheRenditions.trackID(of: watch) ?? song.videoId)
        }
        return ready
    }

    /// What the aligner reads `song` from: the device file, else (through the rendition links) the
    /// cache, else YouTube's stream when nothing usable is cached.
    private func track(for song: Song, cached: Bool) async -> VersionAlignmentTrack {
        var track = VersionAlignmentTrack(videoId: song.videoId, title: song.title, localURL: PlaybackSourceFactory.localFileURL(of: song))
        if track.localURL == nil, !cached || renditions == nil, let stream = await remoteStream(song.videoId) {
            track.remoteAudioURL = stream.url
            track.remoteAudioHeaders = stream.headers
        }
        return track
    }
}
