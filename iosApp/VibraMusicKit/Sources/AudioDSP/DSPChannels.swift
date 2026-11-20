import CoreAudio

/// A view over Float32 PCM that the processors edit in place, whichever way the
/// channels are laid out.
///
/// Android's processors only ever saw interleaved samples (`AudioBlock`). On iOS
/// an `MTAudioProcessingTap` on an `AVPlayerItem` hands over an `AudioBufferList`
/// with one buffer per channel, so every processor here addresses a channel as a
/// base pointer and a stride instead: stride 1 for a non-interleaved buffer,
/// stride = channel count for an interleaved one.
///
/// Building one never allocates; it is meant to be made inside the render callback.
public struct DSPChannels {
    public let channelCount: Int
    public let frameCount: Int

    @usableFromInline let interleaved: UnsafeMutablePointer<Float>?
    @usableFromInline let bufferList: UnsafeMutablePointer<AudioBufferList>?

    /// Interleaved samples: frame `f`, channel `c` is `samples[f * channelCount + c]`.
    public init(interleaved samples: UnsafeMutablePointer<Float>, channelCount: Int, frameCount: Int) {
        precondition(channelCount > 0, "channelCount must be positive: \(channelCount)")
        precondition(frameCount >= 0, "frameCount must not be negative: \(frameCount)")
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.interleaved = samples
        self.bufferList = nil
    }

    /// Float32 samples in an `AudioBufferList`, as a processing tap or an
    /// `AVAudioPCMBuffer` presents them.
    ///
    /// Two layouts are understood: one buffer per channel (non-interleaved, what
    /// an `MTAudioProcessingTap` delivers) and a single buffer carrying every
    /// channel interleaved. Anything else — a buffer too short for
    /// [frameCount], a missing `mData`, buffers of mixed widths — returns nil,
    /// and the caller should leave the audio alone, the same way Android's
    /// processors answer `NOT_SET` for a format they can't handle rather than
    /// failing the whole sink.
    public init?(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        guard frameCount >= 0 else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let bytesPerSample = MemoryLayout<Float>.size
        if buffers.count == 1 {
            let only = buffers[0]
            let channels = Int(only.mNumberChannels)
            guard channels > 0, let data = only.mData,
                  Int(only.mDataByteSize) >= frameCount * channels * bytesPerSample else { return nil }
            self.channelCount = channels
            self.frameCount = frameCount
            self.interleaved = data.assumingMemoryBound(to: Float.self)
            self.bufferList = nil
            return
        }
        guard buffers.count > 1 else { return nil }
        var index = 0
        while index < buffers.count {
            let buffer = buffers[index]
            guard buffer.mNumberChannels == 1, buffer.mData != nil,
                  Int(buffer.mDataByteSize) >= frameCount * bytesPerSample else { return nil }
            index += 1
        }
        self.channelCount = buffers.count
        self.frameCount = frameCount
        self.interleaved = nil
        self.bufferList = bufferList
    }

    /// Distance between two consecutive samples of one channel.
    @inlinable
    public var stride: Int {
        interleaved == nil ? 1 : channelCount
    }

    /// First sample of [channel]; step by [stride] to reach the next frame.
    @inlinable
    public func base(of channel: Int) -> UnsafeMutablePointer<Float> {
        if let interleaved {
            return interleaved + channel
        }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList!)
        return buffers[channel].mData!.assumingMemoryBound(to: Float.self)
    }
}
