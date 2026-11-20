import Foundation
import Observation
import VibraMusicCore

// Ports data/NerdStats.kt, the stats line from ui/player/PlayerControls.kt (`Snapshot.describe`)
// and PlaybackService's `publishNerdStats` / `currentSourceName`.

/// What the audio decoder is actually being fed, for "stats for nerds".
///
/// Every figure here is measured rather than inferred, and every label derived from them — "High
/// Quality", "Lossless", "Hi-Res Lossless" — is decided on the measurements alone. On iOS the
/// figures come from the playing item's audio track (its `AudioStreamBasicDescription`) and access
/// log; see ``AudioFormatMeasurement``. Anything the player hasn't reported stays nil and is left out
/// of the display instead of being guessed at.
///
/// ``Snapshot/claimed`` is the one figure that is *not* measured, and is kept apart for that reason:
/// it is what a source said it was about to send. Holding both is the point — a source promising
/// 24-bit/192 kHz while the decoder reports 16-bit/48 kHz is the most likely way for a lossless
/// setting to be quietly doing nothing, and it is invisible unless the two are put side by side.
///
/// Observable (``current``, ``racingLossless``) and safe to call from any thread: read-ahead
/// resolves the next track through the same code on a loading thread.
public final class NerdStats: Observable, @unchecked Sendable {
    public static let shared = NerdStats()

    /// The upper bound in kbps for a low-bitrate / data-saver lossy stream.
    public static let lowQualityMaxKbps = 80

    /// The bitrate a lossy stream has to reach to be worth calling out. At 256 an Apple-style AAC
    /// counts and YouTube's Opus, which tops out around 160, does not — which is the distinction the
    /// label exists to draw.
    public static let hiQualityKbps = 256

    /// Enough for the queue in hand; these are lookups, not stores.
    public static let maxRemembered = 64

    public struct Snapshot: Hashable, Sendable {
        public var mimeType: String?
        public var bitrateKbps: Int?
        public var sampleRateHz: Int?
        public var channels: Int?
        /// From the decoder's input format, where it states one (lossless and PCM only on iOS).
        public var bitDepth: Int?
        /// What the source said it would serve, when it came from one that says.
        public var claimed: StreamFormat?
        /// The source that supplied this stream ("YouTube", an addon's name, "Local Storage").
        public var sourceName: String?

        public init(
            mimeType: String?,
            bitrateKbps: Int?,
            sampleRateHz: Int?,
            channels: Int?,
            bitDepth: Int? = nil,
            claimed: StreamFormat? = nil,
            sourceName: String? = nil
        ) {
            self.mimeType = mimeType
            self.bitrateKbps = bitrateKbps
            self.sampleRateHz = sampleRateHz
            self.channels = channels
            self.bitDepth = bitDepth
            self.claimed = claimed
            self.sourceName = sourceName
        }

        /// Whether what arrived is measurably worse than what was promised.
        ///
        /// Only ever true when both figures are known: an absent measurement is not evidence of a
        /// downgrade, and reporting one on that basis would make the warning worthless the moment it
        /// fired on a container that simply doesn't state its rate.
        public var downgraded: Bool {
            if let wanted = claimed?.sampleRateHz, let got = sampleRateHz, got < wanted { return true }
            if let wanted = claimed?.bitDepth, let got = bitDepth, got < wanted { return true }
            return false
        }

        /// Whether the decoder is genuinely being fed a lossless codec — the figure the Now Playing
        /// "Lossless" badge is gated on, not what a source promised.
        ///
        /// It used to accept the claim too, and did exactly what that allows: an upgrade to a Tidal
        /// FLAC was recorded as declared, died on a bad HTTP status, playback recovered onto
        /// YouTube's Opus, and the badge went on reading "Lossless" because the claim outlived the
        /// stream that made it. So the decoder gets the only word; ``NerdStats/current`` is nil
        /// across a track change so that gap shows nothing rather than the previous track's figures.
        public var isLossless: Bool { NerdStats.isLosslessMime(mimeType) }

        /// Dolby Atmos decoded as E-AC-3 (JOC); deliberately distinct from lossless.
        public var isDolbyAtmos: Bool { NerdStats.isDolbyAtmosMime(mimeType) }

        /// Better than CD quality — the line Tidal, Qobuz and Apple Music draw: past 16-bit or past
        /// 48 kHz, not merely lossless. A 16/44.1 FLAC is "Lossless"; a 24/96 one is "Hi-Res
        /// Lossless".
        public var isHiRes: Bool {
            isLossless && ((bitDepth ?? 0) > 16 || (sampleRateHz ?? 0) > 48_000)
        }

        /// Lossy, but at the top of what lossy gets — a 320 kbps AAC rather than YouTube's ~160.
        /// Decided on the measured bitrate, not on the source or its claim: a module offering a
        /// LOSSLESS tier and serving SoundCloud at 128 kbps is the ordinary case, not the exotic one.
        public var isHiQuality: Bool {
            !isLossless && (bitrateKbps ?? 0) >= NerdStats.hiQualityKbps
        }

        /// Strictly between low (≤ 80 kbps) and high (≥ 256 kbps): YouTube's AAC/Opus, a 128–192
        /// kbps AAC.
        public var isMediumQuality: Bool {
            let kbps = bitrateKbps ?? 0
            return !isLossless && kbps > NerdStats.lowQualityMaxKbps && kbps < NerdStats.hiQualityKbps
        }

        /// A data-saver stream (YouTube's ~48–70 kbps rungs).
        public var isLowQuality: Bool {
            let kbps = bitrateKbps ?? 0
            return !isLossless && kbps >= 1 && kbps <= NerdStats.lowQualityMaxKbps
        }

        /// "FLAC · 24-bit · 96.0 kHz · 4608 kbps · Stereo" — whichever of those the player has
        /// actually reported, or nil when it has reported nothing.
        ///
        /// A figure it hasn't is dropped rather than filled in, so a short line means little was
        /// known, never that something was invented. Bitrate is stated for a lossless stream too, as
        /// the rate its samples decode to (1411 for 16/44.1, 4608 for 24/96) — the figure Tidal,
        /// Qobuz and Apple Music print, and one a listener can compare between tracks. A stream that
        /// arrived worse than promised says so ("↓ from FLAC · 24-bit · 192 kHz").
        public var statsLine: String? {
            var parts: [String] = []
            if let codec = NerdStats.codecLabel(mimeType) { parts.append(codec) }
            if let bitDepth { parts.append("\(bitDepth)-bit") }
            if let sampleRateHz { parts.append(String(format: "%.1f kHz", locale: Locale(identifier: "en_US_POSIX"), Double(sampleRateHz) / 1_000)) }
            if let bitrateKbps { parts.append("\(bitrateKbps) kbps") }
            if let channels {
                switch channels {
                case 1: parts.append("Mono")
                case 2: parts.append("Stereo")
                default: parts.append("\(channels) ch")
                }
            }
            if downgraded { parts.append("↓ from \(claimed?.summary ?? "")") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    // MARK: Codec vocabulary

    /// Suffixes of a MIME type whose bytes are bit-exact. `audio/raw` is how PCM is named (a WAV or
    /// AIFF reaches the decoder as raw samples); see ``AudioFormatMeasurement/mimeType(forFormatID:)``.
    private static let losslessCodecSuffixes = ["flac", "alac", "raw"]

    /// Whether `mimeType` names a bit-exact codec.
    ///
    /// Public because the decoder's own verdict is also what decides whether a track playing from
    /// the disk cache is worth hunting a better copy of (``QualityUpgrade/adoptUnresolved(_:uri:target:playingMime:playing:)``).
    /// Reading ``Snapshot/isLossless`` there instead would trust whichever track the last publish
    /// described, which after a queue advance is the previous one.
    public static func isLosslessMime(_ mimeType: String?) -> Bool {
        guard let mimeType else { return false }
        return losslessCodecSuffixes.contains { mimeType.hasSuffix($0) }
    }

    public static func isDolbyAtmosMime(_ mimeType: String?) -> Bool {
        guard let mimeType else { return false }
        return mimeType.hasSuffix("eac3-joc") || mimeType.hasSuffix("eac3")
    }

    /// The codec under its usual name rather than its MIME type.
    public static func codecLabel(_ mimeType: String?) -> String? {
        guard let mimeType else { return nil }
        let lower = mimeType.lowercased()
        if lower.hasSuffix("flac") { return "FLAC" }
        if lower.hasSuffix("opus") { return "Opus" }
        if lower.hasSuffix("mp4a-latm") || lower.hasSuffix("aac") { return "AAC" }
        if lower.hasSuffix("mpeg") || lower.hasSuffix("mp3") { return "MP3" }
        if lower.hasSuffix("alac") { return "ALAC" }
        if lower.hasSuffix("raw") { return "PCM" }
        if lower.hasSuffix("vorbis") { return "Vorbis" }
        if lower.hasSuffix("eac3-joc") { return "E-AC-3 JOC" }
        if lower.hasSuffix("eac3") { return "E-AC-3" }
        if let slash = mimeType.lastIndex(of: "/") { return mimeType[mimeType.index(after: slash)...].uppercased() }
        return mimeType.uppercased()
    }

    // MARK: State

    private struct State {
        var current: Snapshot?
        var racing: Set<String> = []
        var picked: [String: Int] = [:]
        var declared: [String: StreamFormat] = [:]
        var sources: [String: String] = [:]
    }

    private let lock = NSLock()
    private var state = State()
    private let registrar = ObservationRegistrar()

    public init() {}

    /// What the decoder is being fed right now; nil across a track change and before the first
    /// measurement. Observable.
    public var current: Snapshot? {
        get {
            registrar.access(self, keyPath: \.current)
            return lock.withLock { state.current }
        }
        set {
            let changed: Bool = lock.withLock {
                guard state.current != newValue else { return false }
                state.current = newValue
                return true
            }
            if changed { announce(\.current) }
        }
    }

    /// Video ids with a better copy still being looked for — a module racing YouTube's resolve, or
    /// a second look running under a track already playing (``QualityUpgrade``). The UI shows
    /// "Upgrading quality" off this. A track leaves the set when its own lookup settles, never on a
    /// timer. Observable.
    public var racingLossless: Set<String> {
        registrar.access(self, keyPath: \.racingLossless)
        return lock.withLock { state.racing }
    }

    public func isRacing(_ videoId: String?) -> Bool {
        guard let videoId else { return false }
        return racingLossless.contains(videoId)
    }

    /// Upgrade lookups also run for read-ahead items, so two threads can arrive together; the
    /// insert happens under the lock so neither erases the other's marker (Android fixed exactly
    /// that race with `StateFlow.update`).
    public func onLosslessRaceStart(_ videoId: String) {
        let changed = lock.withLock { state.racing.insert(videoId).inserted }
        if changed { announce(\.racingLossless) }
    }

    public func onLosslessRaceEnd(_ videoId: String) {
        let changed = lock.withLock { state.racing.remove(videoId) != nil }
        if changed { announce(\.racingLossless) }
    }

    // MARK: What the resolvers said

    /// Records the bitrate of the stream picked for `videoId` (and which source picked it). Keyed by
    /// track rather than kept as one "last picked": read-ahead resolves the *next* track through the
    /// same code, so one loose value would describe the wrong song.
    public func onStreamPicked(_ videoId: String, kbps: Int, source: String? = nil) {
        lock.withLock {
            if kbps > 0 {
                if state.picked.count >= Self.maxRemembered { state.picked.removeAll() }
                state.picked[videoId] = kbps
            }
            if let source, !source.trimmingCharacters(in: .whitespaces).isEmpty {
                rememberSource(source, for: videoId)
            }
        }
    }

    /// Recorded as a source hands over a stream, keyed by that source's own track id.
    public func onSourceStream(_ trackId: String?, format: StreamFormat, source: String? = nil) {
        guard let trackId, !trackId.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        lock.withLock {
            if state.declared.count >= Self.maxRemembered { state.declared.removeAll() }
            state.declared[trackId] = format
            if let source, !source.trimmingCharacters(in: .whitespaces).isEmpty {
                rememberSource(source, for: trackId)
            }
        }
    }

    public func recordSource(_ mediaId: String?, _ source: String?) {
        guard let mediaId, !mediaId.trimmingCharacters(in: .whitespaces).isEmpty,
              let source, !source.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        lock.withLock { rememberSource(source, for: mediaId) }
    }

    /// The source recorded for exactly this id — no unwrapping, so a source track id shared by two
    /// catalogues ("101" on JioSaavn and on an addon) never leaks one's name onto the other.
    public func exactSource(for mediaId: String?) -> String? {
        guard let mediaId else { return nil }
        return lock.withLock { state.sources[mediaId] }
    }

    /// The source recorded for this id, or for the source track id inside a `src:` key.
    public func source(for mediaId: String?) -> String? {
        guard let mediaId else { return nil }
        return lock.withLock {
            if let exact = state.sources[mediaId] { return exact }
            return SourceTrackKey.parse(mediaId).flatMap { state.sources[$0.trackId] }
        }
    }

    public func pickedBitrateKbps(for videoId: String?) -> Int? {
        guard let videoId else { return nil }
        return lock.withLock { state.picked[videoId] }
    }

    /// Undoes ``onSourceStream(_:format:source:)`` for `trackId`: a swap to a claimed-better stream
    /// didn't pan out and the player fell back to what it had. Without this the abandoned claim
    /// goes on describing the stream that is actually playing.
    public func clearDeclared(_ trackId: String?) {
        guard let trackId else { return }
        lock.withLock {
            state.declared[trackId] = nil
            state.sources[trackId] = nil
        }
    }

    /// What a source declared for this track; `mediaId` may be a `src:` key, unwrapped here so
    /// callers don't each have to know the key format.
    public func declaredFormat(for mediaId: String?) -> StreamFormat? {
        guard let mediaId else { return nil }
        return lock.withLock {
            if let exact = state.declared[mediaId] { return exact }
            return SourceTrackKey.parse(mediaId).flatMap { state.declared[$0.trackId] }
        }
    }

    /// Drops everything measured about the last player, because there isn't one any more.
    ///
    /// All of this describes a stream a particular player was reading, and the process can outlive
    /// the player (Android destroys the service and keeps the process; on iOS the Playback engine
    /// can be torn down and rebuilt in one app session). Measured on Android: the Now Playing screen
    /// read "Lossless" over a player that had not been handed a single byte, off a claim from a
    /// stream that stopped existing a minute earlier. See ``QualityUpgrade/forgetLastSession()`` for
    /// the half that decides whether the track gets its lossless copy back.
    public func forgetLastSession() {
        lock.withLock {
            state = State()
        }
        announce(\.current)
        announce(\.racingLossless)
    }

    // MARK: Publishing a measurement

    /// Publishes what the decoder is really being fed, for the stats line and the quality badge
    /// (Android's `PlaybackService.publishNerdStats`).
    ///
    /// Bitrate is the awkward one. A lossless stream gets the rate its samples decode to — a product
    /// of three measured figures, and the number a listener can compare between tracks. A lossy one
    /// gets the measured stream bitrate when there is one (the track's data rate, or the HLS
    /// variant's), then the rate the source declared, then the one the YouTube resolver picked. The
    /// source's figure comes ahead of YouTube's because a track can have both: one resolved through
    /// YouTube and upgraded mid-song has a stale ~160 sitting in ``pickedBitrateKbps(for:)``.
    /// Anything still unknown stays nil for the UI to omit.
    ///
    /// Pass nil `measured` while the item has not reported a format yet; the snapshot then carries
    /// only the claim and the source, and the badge stays in its "not measured" state.
    public func publish(measured: MeasuredAudioFormat?, mediaId: String?, sourceName: String?) {
        let declared = declaredFormat(for: mediaId)
        let mime = measured?.mimeType
        let losslessRate = Self.isLosslessMime(mime) ? measured?.pcmBitrateKbps : nil
        let bitrate = losslessRate
            ?? measured?.bitrateKbps.flatMap { $0 > 0 ? $0 : nil }
            ?? declared?.kbps
            ?? pickedBitrateKbps(for: mediaId)
        current = Snapshot(
            mimeType: mime,
            bitrateKbps: bitrate,
            sampleRateHz: measured?.sampleRateHz,
            channels: measured?.channels,
            bitDepth: measured?.bitDepth,
            claimed: declared,
            sourceName: sourceName
        )
    }

    /// Who is serving `mediaId` right now, for the pipeline dialog's "Source" row (Android's
    /// `PlaybackService.currentSourceName`). The first answer that applies wins:
    ///
    /// 1. a file on the device ("Local Storage");
    /// 2. an upgraded stream parked for this item's URI (``QualityUpgrade/forcedStream(_:)``);
    /// 3. the source recorded for exactly this id;
    /// 4. the source named by a `src:` key ("Unknown" for a config that no longer exists);
    /// 5. the source serving a substituted YouTube id (``StreamChoice``), "Module" if unnamed;
    /// 6. the `s=` config of a `vibramusic://source` URI;
    /// 7. a source recorded against the unwrapped id;
    /// 8. "YouTube" for an 11-character video id or a `v=` URI; otherwise "Unknown".
    ///
    /// - Parameter configName: display name of a source config id (the Sources registry).
    public func sourceName(
        for mediaId: String?,
        playbackURI: String?,
        isLocalPlayback: Bool,
        qualityUpgrade: QualityUpgrade?,
        streamChoice: StreamChoice = .shared,
        configName: (String) -> String?
    ) -> String? {
        guard let id = mediaId else { return nil }
        if isLocalPlayback { return "Local Storage" }
        func named(_ configId: String?) -> String? {
            guard let configId, let name = configName(configId),
                  !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return name
        }
        if let uri = playbackURI, let upgraded = qualityUpgrade?.forcedStream(uri),
           let name = named(upgraded.sourceConfigId) {
            return name
        }
        if let exact = exactSource(for: id), !exact.isEmpty { return exact }
        if let key = SourceTrackKey.parse(id) {
            return configName(key.configId) ?? "Unknown"
        }
        if let serving = streamChoice.stream(for: id) {
            if let name = named(serving.sourceConfigId) { return name }
            if streamChoice.isSubstitute(id) { return "Module" }
        }
        if let uri = playbackURI, PlaybackURI.isSourceURI(uri) {
            return named(PlaybackURI.queryValue(PlaybackURI.sourceConfigParameter, in: uri)) ?? "Unknown"
        }
        if let recorded = source(for: id), !recorded.isEmpty { return recorded }
        if id.count == 11 || playbackURI.flatMap({ PlaybackURI.queryValue(PlaybackURI.videoIdParameter, in: $0) }) != nil {
            return "YouTube"
        }
        return "Unknown"
    }

    // MARK: Private

    /// Called with the lock held.
    private func rememberSource(_ source: String, for id: String) {
        if state.sources.count >= Self.maxRemembered { state.sources.removeAll() }
        state.sources[id] = source
    }

    private func announce<Value>(_ keyPath: KeyPath<NerdStats, Value>) {
        onMainThread { [self] in registrar.withMutation(of: self, keyPath: keyPath) {} }
    }
}
