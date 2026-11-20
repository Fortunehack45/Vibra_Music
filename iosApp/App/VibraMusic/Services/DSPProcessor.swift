import AudioDSP
import AVFoundation
import VibraMusicCore
import os
import Playback

// Plugs the AudioDSP chain into the engine's processing tap (Playback report: "DSP"), one chain
// per deck, and maps the listener's settings onto it.

/// What the stream resolver learned about each item's loudness, readable from the render thread.
///
/// Items played through the audio cache open as `.asset` sources, and an asset carries no
/// loudness figure: the resolved stream's `loudnessDb` would otherwise never reach the tap. The
/// source factory records it here as each stream resolves (before AVFoundation has a single
/// frame), and the processor falls back to it when the engine hands it nil.
final class StreamFactsBook: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [String: Facts]())

    struct Facts: Hashable, Sendable {
        var loudnessDb: Double?
        var stream: ResolvedStream?
    }

    func record(itemID: String, stream: ResolvedStream) {
        lock.withLock { $0[itemID] = Facts(loudnessDb: stream.loudnessDb, stream: stream) }
    }

    /// Drops what an earlier resolve recorded for `itemID`, once the item plays a copy nothing resolved.
    func forget(itemID: String) {
        lock.withLock { $0[itemID] = nil }
    }

    func loudness(for itemID: String) -> Double? {
        lock.withLockIfAvailable { $0[itemID]?.loudnessDb } ?? nil
    }

    /// YouTube's figure per video id, whichever copy plays: an add-on's FLAC carries none of its
    /// own, and a track replayed from disk after a relaunch resolves nothing. Kept on disk.
    private let tracks: OSAllocatedUnfairLock<[String: Double]>
    private let defaults: UserDefaults?
    static let tracksKey = "loudness_db_by_track"
    static let trackLimit = 5_000

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        tracks = OSAllocatedUnfairLock(initialState: defaults?.dictionary(forKey: Self.tracksKey) as? [String: Double] ?? [:])
    }

    /// Records YouTube's figure for `videoId`. True when it's news, so a deck already playing the
    /// track without one can take it up.
    @discardableResult
    func noteLoudness(_ db: Double, forTrack videoId: String) -> Bool {
        let snapshot: [String: Double]? = tracks.withLock { book in
            guard book[videoId] != db else { return nil }
            // ponytail: past the bound one arbitrary figure goes, not the oldest; an LRU if the
            // wrong one being forgotten ever matters.
            if book.count >= Self.trackLimit, book[videoId] == nil, let victim = book.keys.first { book.removeValue(forKey: victim) }
            book[videoId] = db
            return book
        }
        guard let snapshot else { return false }
        defaults?.set(snapshot, forKey: Self.tracksKey)
        return true
    }

    /// Render-thread safe: never blocks.
    func trackLoudness(_ videoId: String) -> Double? {
        tracks.withLockIfAvailable { $0[videoId] } ?? nil
    }

    /// The figure for `item`: its own stream's, else its recording's.
    func loudness(for item: PlayableItem) -> Double? {
        loudness(for: item.id) ?? trackLoudness(item.trackID)
    }

    func stream(for itemID: String) -> ResolvedStream? {
        lock.withLock { $0[itemID]?.stream }
    }

    /// Keeps the book to the items still in play.
    func retain(only itemIDs: Set<String>) {
        lock.withLock { book in
            guard book.count > 16 else { return }
            book = book.filter { itemIDs.contains($0.key) }
        }
    }
}

extension AudioDSPSettings {
    /// The chain's settings from the listener's: EQ, stereo widening and loudness normalization.
    /// Skip silence is left to the engine's own live detector and look-ahead scan, so the chain's
    /// detector stays off rather than doing the same work twice.
    @MainActor
    static func from(_ settings: AppSettings) -> AudioDSPSettings {
        AudioDSPSettings(
            equalizer: EqualizerSettings(
                isEnabled: settings.equalizerEnabled,
                mode: EqualizerSettings.Mode(rawValue: settings.equalizerMode.rawValue) ?? .dynamic,
                toneX: settings.equalizerToneX,
                toneY: settings.equalizerToneY,
                isFocused: settings.equalizerFocused,
                balance: settings.equalizerBalance,
                bandsDb: settings.equalizerBands
            ),
            spatialAudio: settings.spatialAudio,
            loudnessNormalization: settings.loudnessNormalization,
            skipSilence: false
        )
    }
}

/// One deck's DSP: the AudioDSP chain behind Playback's processor protocol.
final class AudioDSPProcessor: PlaybackAudioProcessor, @unchecked Sendable {
    let chain: DSPChain
    private let facts: StreamFactsBook
    /// Settings as last applied, read on the main actor to answer ``altersSignal(for:loudnessDb:)``.
    private let state = OSAllocatedUnfairLock(initialState: (settings: AudioDSPSettings(), automix: false))

    init(chain: DSPChain = DSPChain(), facts: StreamFactsBook) {
        self.chain = chain
        self.facts = facts
    }

    /// Any thread. Pushes the listener's settings onto the chain.
    func apply(_ settings: AudioDSPSettings, automix: Bool) {
        state.withLock { $0 = (settings, automix) }
        chain.apply(settings)
    }

    // MARK: PlaybackAudioProcessor

    func prepare(format: AudioTapFormat, maximumFrames: Int) {
        chain.configure(sampleRate: format.sampleRate, channelCount: format.channelCount)
    }

    func beginItem(_ item: PlayableItem, loudnessDb: Double?) {
        let figure = loudnessDb ?? facts.loudness(for: item)
        _ = began.withLockIfAvailable { $0 = (item.trackID, figure != nil) }
        chain.loudness.setTrackLoudness(figure)
    }

    /// The track this chain last began, and whether it had a figure then.
    private let began = OSAllocatedUnfairLock<(trackID: String, hadFigure: Bool)?>(initialState: nil)

    /// Main actor. YouTube's figure for `videoId` arrived after its item began (an add-on's copy
    /// won the race, or the track played from disk): applied now if this chain is on that track
    /// and began without one (Android's `LOUDNESS_RETRY_MS`), rather than the whole track playing
    /// un-normalised.
    func loudnessArrived(forTrack videoId: String) {
        let waiting = began.withLock { state -> Bool in
            guard let current = state, current.trackID == videoId, !current.hadFigure else { return false }
            state = (videoId, true)
            return true
        }
        guard waiting, let figure = facts.trackLoudness(videoId) else { return }
        chain.loudness.setTrackLoudness(figure)
    }

    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int, format: AudioTapFormat, timing: AudioTapTiming) {
        chain.process(bufferList: buffers.unsafeMutablePointer, frameCount: frameCount, sourceFramePosition: timing.sourceFramePosition)
        if timing.isEndOfStream { chain.finish() }
    }

    func setTransitionFilter(_ cutoffs: TransitionFilterCutoffs) {
        if cutoffs.isOpen {
            chain.transition.open()
        } else {
            chain.transition.setCutoffs(lowPassHz: cutoffs.lowPassHz, highPassHz: cutoffs.highPassHz)
        }
    }

    func reset() {
        chain.reset()
    }

    /// Whether the chain would change `item`'s samples: EQ, widening, a normalization gain other
    /// than 0 dB, or Automix (whose transition filter may ride the item). A lossless item for which
    /// this is false plays with no tap, so the pipeline dialog can honestly say "unaltered".
    func altersSignal(for item: PlayableItem, loudnessDb: Double?) -> Bool {
        let (settings, automix) = state.withLock { $0 }
        return Self.alters(settings: settings, automix: automix, loudnessDb: loudnessDb ?? facts.loudness(for: item))
    }

    static func alters(settings: AudioDSPSettings, automix: Bool, loudnessDb: Double?) -> Bool {
        if settings.equalizer.isEnabled || settings.spatialAudio || automix { return true }
        let readout = LoudnessNormalizer.readout(enabled: settings.loudnessNormalization, loudnessDb: loudnessDb)
        if let gain = readout.gainDb, gain != 0 { return true }
        return false
    }

    /// The normalization readout for the pipeline sheet's Gain and Measured rows: the gain that
    /// would apply, and the figure it came from. Nil when normalization is off or the track's
    /// figure isn't known — the same test ``altersSignal(for:loudnessDb:)`` makes.
    func loudnessReadout(for item: PlayableItem, loudnessDb: Double?) -> LoudnessReadout? {
        let (settings, _) = state.withLock { $0 }
        guard settings.loudnessNormalization else { return nil }
        let readout = LoudnessNormalizer.readout(enabled: true, loudnessDb: loudnessDb ?? facts.loudness(for: item))
        return readout.isActive ? readout : nil
    }
}
