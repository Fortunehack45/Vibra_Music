/// Common contract for Vibra Music's in-place Float32 DSP stages.
///
/// Threading, which every conformer follows:
/// - `configure` and `reset` allocate and free, so they run where allocation is
///   allowed — an `MTAudioProcessingTap`'s prepare and unprepare callbacks —
///   and never concurrently with `process`.
/// - `process` and `flush` run on the audio thread. They never allocate, lock or
///   log, and they read settings through lock-free hand-offs.
/// - Settings (`setTuning`, `isEnabled`, `setCutoffs`, ...) may be changed from
///   any other thread at any time; the audio thread picks the change up at its
///   next block.
public protocol FloatAudioProcessor: AnyObject {
    /// Prepares for [sampleRate] and [channelCount]; allocates whatever the stage needs.
    func configure(sampleRate: Double, channelCount: Int)

    /// Processes the frames in [channels] in place.
    func process(_ channels: DSPChannels)

    /// Clears filter state and histories, for a seek or a stream boundary.
    func flush()

    /// Releases buffers and returns to the unconfigured state.
    func reset()
}

extension FloatAudioProcessor {
    /// Processes the valid frames of an interleaved `AudioBlock` in place.
    public func process(_ block: AudioBlock) {
        process(block.channels)
    }
}
