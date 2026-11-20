/// Reusable, audio-thread-owned memory block holding interleaved Float32 PCM samples.
///
/// All samples are stored in [samples] as normalized IEEE 754 32-bit floats. The
/// nominal amplitude range is `[-1.0, +1.0]`, though intermediate DSP operations
/// may use values outside it (headroom) before final clamping.
///
/// Allocated once per processor or sink lifecycle and reused across callbacks,
/// so the steady-state processing path allocates nothing.
public final class AudioBlock {
    public static let defaultChannels = 2
    public static let defaultCapacityFrames = 4096

    /// Number of audio channels (1 for mono, 2 for stereo).
    public let channelCount: Int

    /// Maximum number of frames [samples] can hold.
    public let capacityFrames: Int

    /// Pre-allocated contiguous storage for `capacityFrames * channelCount` samples,
    /// zero-filled at creation.
    public let samples: UnsafeMutablePointer<Float>

    /// Number of valid frames currently in the block.
    public private(set) var frameCount: Int = 0

    public init(channelCount: Int = AudioBlock.defaultChannels,
                capacityFrames: Int = AudioBlock.defaultCapacityFrames) {
        precondition(channelCount > 0, "channelCount must be positive: \(channelCount)")
        precondition(capacityFrames > 0, "capacityFrames must be positive: \(capacityFrames)")
        self.channelCount = channelCount
        self.capacityFrames = capacityFrames
        samples = .allocate(capacity: capacityFrames * channelCount)
        samples.initialize(repeating: 0, count: capacityFrames * channelCount)
    }

    deinit {
        samples.deallocate()
    }

    /// Total number of valid samples (`frameCount * channelCount`).
    public var sampleCount: Int {
        frameCount * channelCount
    }

    /// The valid region as an interleaved buffer view.
    public var channels: DSPChannels {
        DSPChannels(interleaved: samples, channelCount: channelCount, frameCount: frameCount)
    }

    /// Marks [frames] frames as valid for a new processing cycle, without touching memory.
    public func reset(_ frames: Int = 0) {
        precondition((0...capacityFrames).contains(frames),
                     "frames (\(frames)) out of range 0...\(capacityFrames)")
        frameCount = frames
    }

    /// Updates [frameCount] after samples were written into [samples] directly.
    public func setFrameCount(_ frames: Int) {
        reset(frames)
    }

    /// Zeroes the valid region and marks the block empty.
    public func clear() {
        if sampleCount > 0 {
            samples.update(repeating: 0, count: sampleCount)
        }
        frameCount = 0
    }

    /// Copies [frames] frames of [source], starting at [sourceStartFrame], into
    /// this block at [destStartFrame]. [frameCount] grows to cover what was written.
    public func copy(from source: AudioBlock,
                     sourceStartFrame: Int = 0,
                     destStartFrame: Int = 0,
                     frames: Int? = nil) {
        let frames = frames ?? source.frameCount - sourceStartFrame
        precondition(source.channelCount == channelCount,
                     "Channel count mismatch: source has \(source.channelCount), dest has \(channelCount)")
        precondition(sourceStartFrame >= 0 && sourceStartFrame + frames <= source.frameCount,
                     "Source range [\(sourceStartFrame), \(sourceStartFrame + frames)) out of bounds for source frameCount \(source.frameCount)")
        precondition(destStartFrame >= 0 && destStartFrame + frames <= capacityFrames,
                     "Dest range [\(destStartFrame), \(destStartFrame + frames)) out of bounds for capacity \(capacityFrames)")
        guard frames > 0 else { return }
        (samples + destStartFrame * channelCount)
            .update(from: source.samples + sourceStartFrame * channelCount, count: frames * channelCount)
        frameCount = max(frameCount, destStartFrame + frames)
    }
}
