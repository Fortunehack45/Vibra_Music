import Foundation
import VibraMusicCore

// Ports data/sources/AddonSource.kt. iOS difference: where Android declared a DASH transport to
// ExoPlayer, this converts the manifest (``DashToHLS``), because AVPlayer can't play DASH.

/// A ``MusicSource`` backed by one addon server the user pointed at.
///
/// The config's `baseUrl` is the addon's own URL, token and all. This class is the translation
/// between what the addon says and what the rest of the app understands. One addon is one
/// catalogue and one search; a user wanting two catalogues adds two addons.
public final class AddonSource: MusicSource, @unchecked Sendable {
    public let config: SourceConfig?
    private let sourceConfig: SourceConfig
    private let client: AddonClient
    private let environment: SourceEnvironment

    public var configId: String { sourceConfig.id }
    public var kind: SourceKind { sourceConfig.kind }
    public var displayName: String { sourceConfig.displayName }

    /// Rows this addon recently handed over, by their own id: their claimed runtime (checked before
    /// a substitute is cut into a playing track) and their own `streamURL` (the fallback when
    /// `/stream` has nothing). Bounded and cleared wholesale: a miss costs metadata, not a track.
    private let rowsLock = NSLock()
    private var rows: [String: AddonTrack] = [:]
    private var rowOrder: [String] = []
    private static let maxRows = 256

    public init(config: SourceConfig, environment: SourceEnvironment) {
        self.config = config
        sourceConfig = config
        self.environment = environment
        client = AddonClient(baseUrl: config.baseUrl, session: environment.session, atmosWanted: {
            await environment.atmosWanted()
        })
    }

    // MARK: Health

    /// Whether this addon is there and usable. The manifest answers reachable, well formed and
    /// searchable at once; ``AddonError/rejected(_:)`` is a rejection, anything else is a bad
    /// minute. No readable manifest is not no addon: one that answers a search is healthy, and says
    /// which kind of working it is.
    public func health() async -> SourceHealth {
        if sourceConfig.baseUrl.nonBlank == nil { return .rejected("An addon URL is required") }
        switch await client.manifest() {
        case .success(let manifest):
            let parts = [manifest.displayName.nonBlank, manifest.version.nonBlank.map { "v\($0)" }].compactMap { $0 }
            return .ok(detail: parts.isEmpty ? nil : parts.joined(separator: " "))
        case .failure(let failure):
            if case .success = await client.probeSearch() {
                SourcesLog.d("\(displayName): no manifest, but search answers")
                return .ok(detail: "No manifest · search works")
            }
            let reason = failure.localizedDescription.nonBlank ?? "Could not reach the addon"
            if case AddonError.rejected = failure { return .rejected(reason) }
            SourcesLog.w("addon unreachable for \(displayName): \(reason)")
            return .unreachable(reason)
        }
    }

    /// What the addon calls itself, or nil. The Sources screen stores it as the row's label ("Unified
    /// · Quality First" rather than a hostname). Free after ``health()``: the manifest is cached.
    public func manifestName() async -> String? {
        (try? await client.manifest().get())?.displayName.nonBlank
    }

    // MARK: Search

    /// One request, one catalogue, in the order the addon returned it. `waitForAll` means nothing
    /// here (one HTTP round trip). The tier is the stream's when a stream is what this is for, and
    /// lossless for the search box.
    public func search(_ query: String, limit: Int, waitForAll: Bool, tier: StreamRequest.Tier?) async throws -> [Song] {
        if query.nonBlank == nil { return [] }
        let tierName = tier.map(ModuleSource.tierName) ?? AddonClient.tierLossless
        let tracks: [AddonTrack]
        switch await client.search(query, tier: tierName) {
        case .success(let found):
            tracks = found
        case .failure(let failure):
            if failure is CancellationError { throw failure }
            SourcesLog.w("\(displayName): search failed — \(failure.localizedDescription)")
            return []
        }
        let kept = tracks.filter { $0.id.nonBlank != nil && $0.title.nonBlank != nil }.prefix(max(limit, 0))
        remember(Array(kept))
        return kept.map { track in
            Song(
                videoId: SourceRegistry.trackKey(configId: configId, trackId: track.id),
                title: track.title,
                artist: track.artist,
                thumbnailUrl: track.artwork,
                durationText: track.durationSec.map(TrackMatcher.durationText),
                albumName: track.album.nonBlank,
                // Atmos is read before the tier label and not from it: Tidal publishes immersive
                // rows as `audioQuality: LOW`.
                sourceQuality: track.isDolbyAtmos ? SourceQuality.immersive : ModuleSource.sourceQuality("\(track.audioQuality) \(track.format)")
            )
        }
    }

    // MARK: Stream

    public func stream(trackId: String, tier: StreamRequest.Tier) async throws -> ResolvedStream? {
        let tierName = ModuleSource.tierName(tier)
        let answer: AddonStream
        switch await client.stream(trackId, tier: tierName) {
        case .success(let found):
            answer = found
        case .failure(let failure):
            if failure is CancellationError { throw failure }
            // A 404 is the addon saying it does not hold this recording: a miss, no log line.
            if (failure as? AddonError) != .notFound {
                SourcesLog.w("\(displayName): stream failed for \(trackId) — \(failure.localizedDescription)")
            }
            return try await fromRow(trackId, tierName)
        }
        guard let url = answer.url.nonBlank else {
            // It answered, and has nothing for this one. Its own words when it gave any: some are a
            // backend that came up empty, others a credential to set on the addon's setup page.
            let why = answer.error?.nonBlank.map { " — \($0)" } ?? ""
            SourcesLog.w("\(displayName): no stream for \(trackId)\(why)")
            return try await fromRow(trackId, tierName)
        }
        return try await openable(url, answer, trackId: trackId, tierName: tierName)
    }

    /// The stream the search row carried, when `/stream` had nothing. Not used in place of the call
    /// (the row's URL comes with none of the routing metadata) but worth having as a fallback: an
    /// addon serving permanent direct links may treat `/stream` as optional.
    private func fromRow(_ trackId: String, _ tierName: String) async throws -> ResolvedStream? {
        guard let row = rowsLock.withLock({ rows[trackId] }), let url = row.streamURL?.nonBlank else { return nil }
        SourcesLog.d("\(displayName): using the search row's own URL for \(trackId)")
        return try await openable(url, AddonStream(url: url, format: row.format), trackId: trackId, tierName: tierName)
    }

    /// Everything between a URL the addon named and one the player may open. Three refusals —
    /// unopenable, encrypted, immersive where it can't play — then the transport: HLS is passed on
    /// typed, DASH is converted.
    private func openable(_ url: String, _ answer: AddonStream, trackId: String, tierName: String) async throws -> ResolvedStream? {
        if ModuleSource.malformed(url) {
            SourcesLog.w("\(displayName): malformed URL for \(trackId); skipping it — \(url.prefix(120))")
            return nil
        }
        if answer.isEncrypted {
            SourcesLog.w("\(displayName): \(trackId) came back encrypted, which Vibra Music never asked for — passing")
            return nil
        }
        let format = Self.format(of: answer, url: url, tierName: tierName)
        let playsAtmos = environment.deviceCodecs.playsDolbyAtmos
        let atmosAllowed = playsAtmos ? await environment.dolbyAtmosEnabled() : false
        if ModuleSource.unplayable(format, atmosAllowed: atmosAllowed) {
            let why = playsAtmos ? "which is switched off in Settings" : "which this device has no decoder for"
            SourcesLog.w("\(displayName): answered a \(tierName) request with \(format.summary), \(why) — passing")
            return nil
        }
        guard let streamURL = URL(string: url) else { return nil }
        let duration = rowsLock.withLock { rows[trackId]?.durationSec }
        var stream = ResolvedStream(
            url: streamURL,
            origin: .addon,
            mimeType: answer.mimeType?.nonBlank,
            format: format,
            durationSeconds: duration
        )

        // Said out loud rather than left to be sniffed: an addon serving HLS from an extensionless
        // path (the reference addon does, at `/dash/{id}`) is the shape that fails as an unreadable
        // container.
        let transport = answer.transport
            ?? (DashToHLS.looksLikeDash(url: url, mimeType: answer.mimeType) ? .dash : nil)
        switch transport {
        case .hls:
            stream.mimeType = AddonTransport.hls.mimeType
        case .dash:
            guard let converted = await DashToHLS.playable(stream, environment: environment, atmosAllowed: atmosAllowed, label: "\(displayName) \(trackId)") else {
                return nil
            }
            stream = converted
        case nil:
            break
        }
        return stream
    }

    /// What is really on the end of the URL, from what the addon said, most trustworthy first:
    /// a stated codec; a container that names its codec; a mime type; an Atmos or lossless label;
    /// last the URL's extension — the guess that catches a server that walked down to `.128.mp3`.
    /// Nil when nothing knows: "unknown" is information, and "no" when it doesn't know is not.
    static func format(of answer: AddonStream, url: String, tierName: String) -> StreamFormat {
        let mimeCodec = answer.mimeType.map { $0.afterLast("/").before(";").trimmingCharacters(in: .whitespaces).lowercased() }
        let codec: String?
        if let stated = answer.statedCodec, audioCodecs.contains(stated) {
            codec = stated
        } else if let container = answer.statedContainer, selfDescribingContainers.contains(container) {
            codec = container
        } else if let mimeCodec, audioCodecs.contains(mimeCodec) {
            codec = mimeCodec
        } else if answer.isDolbyAtmos {
            codec = "eac3-joc"
        } else if ModuleSource.qualityTier(answer.qualityText) == ModuleSource.lossless {
            codec = "flac"
        } else {
            let ext = url.before("?").afterLast(".").lowercased()
            codec = audioCodecs.contains(ext) ? ext : nil
        }
        // The tier's published meaning, last and only for the lossy rungs: "HIGH" is a statement of
        // 320, and the number is what says "this is not what you asked for".
        let fallbackKbps: Int?
        switch tierName {
        case AddonClient.tierHigh: fallbackKbps = 320
        case AddonClient.tierLow: fallbackKbps = 128
        default: fallbackKbps = nil
        }
        return StreamFormat(
            codec: codec,
            kbps: answer.kbps ?? fallbackKbps,
            sampleRateHz: answer.sampleRateHz,
            bitDepth: answer.bits
        )
    }

    // MARK: Lifecycle

    /// Dropped along with the source it belongs to.
    public func release() {
        rowsLock.withLock {
            rows.removeAll()
            rowOrder.removeAll()
        }
        let client = client
        Task { await client.clear() }
    }

    public func clearCompletedTrackCalls() async {
        await client.clearCompletedTrackCalls()
    }

    private func remember(_ tracks: [AddonTrack]) {
        rowsLock.withLock {
            for track in tracks {
                if rows.updateValue(track, forKey: track.id) == nil { rowOrder.append(track.id) }
            }
            if rows.count > Self.maxRows {
                let excess = rows.count - Self.maxRows
                for id in rowOrder.prefix(excess) { rows[id] = nil }
                rowOrder.removeFirst(excess)
            }
        }
    }

    /// Containers that name their own codec. `mp4` and `ogg` hold several things and say nothing.
    private static let selfDescribingContainers: Set<String> = ["flac", "wav", "mp3", "aiff"]

    /// What may be believed as a codec. `mp4` is here on purpose: a live addon's JioSaavn backend
    /// answers `{"format": "mp4", "quality": "320kbps"}`, and with `mp4` unrecognised the codec came
    /// back nil — "unknown" rather than "not lossless", which kept a 320 kbps AAC in contention
    /// against a FLAC. The underscore spelling `eac3_joc` is deliberately absent: returned verbatim
    /// it would miss ``StreamFormat/isDolbyAtmos``; the free-text path maps it to `eac3-joc`.
    private static let audioCodecs: Set<String> = [
        "flac", "alac", "wav", "aiff", "mp3", "aac", "he-aac", "m4a", "mp4",
        "ogg", "opus", "vorbis", "webm", "eac3-joc", "ec3-joc",
    ]
}
