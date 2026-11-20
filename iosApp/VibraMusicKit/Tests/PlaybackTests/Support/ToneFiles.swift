import AVFoundation
import XCTest

/// Writes short real audio files for the engine to play: sine tones and digital silence.
enum ToneFile {
    enum Segment {
        case tone(frequency: Double, seconds: Double, amplitude: Float = 0.3)
        case silence(seconds: Double)

        var seconds: Double {
            switch self {
            case .tone(_, let seconds, _), .silence(let seconds): return seconds
            }
        }
    }

    enum Container {
        /// Linear PCM (32-bit float) in a CAF.
        case caf
        /// AAC at the given bitrate in an M4A.
        case aac(bitrate: Int)
    }

    static let sampleRate: Double = 44_100

    @discardableResult
    static func write(_ segments: [Segment], to directory: URL, name: String, container: Container = .caf) throws -> URL {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let url: URL
        let settings: [String: Any]
        switch container {
        case .caf:
            url = directory.appendingPathComponent("\(name).caf")
            settings = format.settings
        case .aac(let bitrate):
            url = directory.appendingPathComponent("\(name).m4a")
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: bitrate,
            ]
        }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var phase = 0.0
        for segment in segments {
            let frames = AVAudioFrameCount(segment.seconds * sampleRate)
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { continue }
            buffer.frameLength = frames
            for channel in 0..<2 {
                let samples = buffer.floatChannelData![channel]
                switch segment {
                case .silence:
                    for index in 0..<Int(frames) { samples[index] = 0 }
                case .tone(let frequency, _, let amplitude):
                    var local = phase
                    let step = 2 * Double.pi * frequency / sampleRate
                    for index in 0..<Int(frames) {
                        samples[index] = amplitude * Float(sin(local))
                        local += step
                    }
                }
            }
            if case .tone(let frequency, _, _) = segment {
                phase += 2 * Double.pi * frequency / sampleRate * Double(frames)
            }
            try file.write(from: buffer)
        }
        return url
    }

    static func tone(_ seconds: Double, frequency: Double = 440, in directory: URL, name: String) throws -> URL {
        try write([.tone(frequency: frequency, seconds: seconds)], to: directory, name: name)
    }
}
