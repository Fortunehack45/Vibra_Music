import AVFoundation

/// A short 440 Hz tone as AAC in fragmented MP4, cut by `AVAssetWriter`'s HLS segment output —
/// the pieces of a real HLS rendition, for tests that serve one over HTTP.
enum FragmentedAAC {
    struct Segment {
        var data: Data
        var duration: Double
    }

    private final class Collector: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
        var initialization = Data()
        var segments: [Segment] = []
        func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType,
                         segmentReport: AVAssetSegmentReport?) {
            switch segmentType {
            case .initialization:
                initialization = segmentData
            case .separable:
                segments.append(Segment(data: segmentData, duration: segmentReport?.trackReports.first?.duration.seconds ?? 0))
            @unknown default:
                break
            }
        }
    }

    static func make(seconds: Double, segmentSeconds: Double) async throws -> (initialization: Data, segments: [Segment]) {
        let sampleRate = 44_100.0
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: segmentSeconds, preferredTimescale: 1)
        writer.initialSegmentStartTime = .zero
        let collector = Collector()
        writer.delegate = collector
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? URLError(.cannotCreateFile) }
        writer.startSession(atSourceTime: .zero)

        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let totalFrames = Int(seconds * sampleRate)
        let chunk = 4_096
        var written = 0
        while written < totalFrames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            let frames = min(chunk, totalFrames - written)
            var samples = [Float](repeating: 0, count: frames * 2)
            for frame in 0..<frames {
                let value = Float(sin(2 * Double.pi * 440 * Double(written + frame) / sampleRate)) * 0.2
                samples[frame * 2] = value
                samples[frame * 2 + 1] = value
            }
            var block: CMBlockBuffer?
            let bytes = frames * 8
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                               customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
            samples.withUnsafeBytes { raw in
                _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes)
            }
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: frames,
                presentationTimeStamp: CMTime(value: CMTimeValue(written), timescale: CMTimeScale(sampleRate)),
                packetDescriptions: nil, sampleBufferOut: &sample
            )
            guard let sample, input.append(sample) else { throw writer.error ?? URLError(.cannotWriteToFile) }
            written += frames
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
        return (collector.initialization, collector.segments)
    }
}
