/// Raw PCM sample encodings the boundary layer converts to and from Float32.
///
/// Every multi-byte format is little-endian, which is what Android's AudioTrack,
/// Media3 and Core Audio on Apple silicon and Intel all use.
public enum PCMEncoding: String, CaseIterable, Sendable {
    /// Signed 16-bit integer, 2 bytes per sample (-32768...32767).
    case pcm16Bit
    /// Signed 24-bit integer packed into 3 bytes (-8388608...8388607).
    case pcm24BitPacked
    /// Signed 32-bit integer, 4 bytes per sample.
    case pcm32Bit
    /// IEEE 754 32-bit float, 4 bytes per sample (nominal -1.0...1.0).
    case pcmFloat

    public var bytesPerSample: Int {
        switch self {
        case .pcm16Bit: return 2
        case .pcm24BitPacked: return 3
        case .pcm32Bit, .pcmFloat: return 4
        }
    }

    public var bitDepth: Int {
        switch self {
        case .pcm16Bit: return 16
        case .pcm24BitPacked: return 24
        case .pcm32Bit, .pcmFloat: return 32
        }
    }

    /// Bytes needed for one frame across [channelCount] channels.
    public func bytesPerFrame(channelCount: Int) -> Int {
        precondition(channelCount > 0, "channelCount must be positive: \(channelCount)")
        return bytesPerSample * channelCount
    }

    /// Bytes needed for [frames] frames across [channelCount] channels.
    public func totalBytes(frames: Int, channelCount: Int) -> Int {
        precondition(frames >= 0, "frames must be non-negative: \(frames)")
        return frames * bytesPerFrame(channelCount: channelCount)
    }
}
