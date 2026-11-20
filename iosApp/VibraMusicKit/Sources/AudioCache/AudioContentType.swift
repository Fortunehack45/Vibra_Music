import Foundation
import UniformTypeIdentifiers

/// Maps what a server or file says about its bytes to the uniform type identifier AVFoundation
/// wants in a resource loader's content-information answer.
///
/// A custom-scheme asset has no file extension or HTTP response for AVFoundation to look at, so
/// this answer is the only thing that tells it which demuxer to use. Get it wrong and a perfectly
/// good file fails to open.
public enum AudioContentType {
    /// MPEG-4 audio (AAC or ALAC in an `.m4a`/`.mp4`): YouTube's itag 139/140, most addons.
    public static let mpeg4Audio = "com.apple.m4a-audio"
    /// MPEG-4 with video (a music video's muxed stream).
    public static let mpeg4 = "public.mpeg-4"
    public static let mp3 = "public.mp3"
    public static let flac = "org.xiph.flac"
    /// Raw ADTS AAC.
    public static let aac = "public.aac-audio"
    public static let wave = "com.microsoft.waveform-audio"
    public static let aiff = "public.aiff-audio"
    public static let coreAudio = "com.apple.coreaudio-format"
    public static let ogg = "org.xiph.ogg-audio"
    /// YouTube's Opus renditions. AVFoundation can't play these on iOS 17 (PORTING §6, Q5); the
    /// cache still stores them for Automix analysis and reports them honestly.
    public static let webm = "org.webmproject.webm"
    public static let ac3 = "public.ac3-audio"
    public static let eac3 = "public.enhanced-ac3-audio"

    /// The UTI for `mimeType` (parameters such as `codecs=` are ignored), falling back to
    /// `pathExtension`, or nil when neither says anything useful. `application/octet-stream` (what
    /// WebDAV servers and SMB listings usually claim) counts as saying nothing.
    public static func uti(mimeType: String?, pathExtension: String? = nil) -> String? {
        if let mimeType, let uti = uti(forMIME: mimeType) { return uti }
        if let pathExtension, let uti = uti(forExtension: pathExtension) { return uti }
        return nil
    }

    /// Recognises a container from its first bytes, for sources whose type is unknown. Twelve bytes
    /// are enough for every format listed here.
    public static func sniff(_ prefix: Data) -> String? {
        let bytes = [UInt8](prefix.prefix(16))
        func ascii(_ offset: Int, _ text: String) -> Bool {
            let wanted = Array(text.utf8)
            guard bytes.count >= offset + wanted.count else { return false }
            return Array(bytes[offset..<(offset + wanted.count)]) == wanted
        }
        if ascii(4, "ftyp") {
            // `M4A ` / `M4B ` brands are audio-only; anything else (isom, mp42, dash) may carry
            // video, and AVFoundation opens audio-only MPEG-4 fine under either identifier.
            return ascii(8, "M4A ") || ascii(8, "M4B ") || ascii(8, "dash") ? mpeg4Audio : mpeg4
        }
        if ascii(0, "fLaC") { return flac }
        if ascii(0, "ID3") { return mp3 }
        if ascii(0, "OggS") { return ogg }
        if ascii(0, "RIFF"), ascii(8, "WAVE") { return wave }
        if ascii(0, "FORM"), ascii(8, "AIFF") || ascii(8, "AIFC") { return aiff }
        if ascii(0, "caff") { return coreAudio }
        if bytes.count >= 4, bytes[0] == 0x1A, bytes[1] == 0x45, bytes[2] == 0xDF, bytes[3] == 0xA3 { return webm }
        if bytes.count >= 2, bytes[0] == 0x0B, bytes[1] == 0x77 { return ac3 }
        if bytes.count >= 2, bytes[0] == 0xFF {
            // ADTS sync words carry layer 00; MPEG audio frames carry a non-zero layer.
            if bytes[1] & 0xF6 == 0xF0 { return aac }
            if bytes[1] & 0xE0 == 0xE0 { return mp3 }
        }
        return nil
    }

    static func uti(forMIME raw: String) -> String? {
        let mime = raw.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        switch mime {
        case "audio/mp4", "audio/m4a", "audio/x-m4a", "audio/mp4a-latm", "audio/aacp-mp4", "audio/alac":
            return mpeg4Audio
        case "video/mp4", "application/mp4":
            return mpeg4
        case "audio/mpeg", "audio/mp3", "audio/mpeg3", "audio/x-mpeg", "audio/x-mpeg-3", "audio/mpa":
            return mp3
        case "audio/flac", "audio/x-flac":
            return flac
        case "audio/aac", "audio/aacp", "audio/x-aac", "audio/x-hx-aac-adts":
            return aac
        case "audio/wav", "audio/x-wav", "audio/wave", "audio/vnd.wave":
            return wave
        case "audio/aiff", "audio/x-aiff":
            return aiff
        case "audio/x-caf":
            return coreAudio
        case "audio/ogg", "audio/opus", "application/ogg":
            return ogg
        case "audio/webm", "video/webm":
            return webm
        case "audio/ac3":
            return ac3
        case "audio/eac3", "audio/ec3":
            return eac3
        case "", "application/octet-stream", "binary/octet-stream", "application/x-download":
            return nil
        default:
            guard let type = UTType(mimeType: mime), type.conforms(to: .audiovisualContent) else { return nil }
            return type.identifier
        }
    }

    static func uti(forExtension raw: String) -> String? {
        switch raw.lowercased() {
        case "m4a", "m4b", "alac": return mpeg4Audio
        case "mp4", "m4v": return mpeg4
        case "mp3": return mp3
        case "flac": return flac
        case "aac", "adts": return aac
        case "wav", "wave": return wave
        case "aif", "aiff", "aifc": return aiff
        case "caf": return coreAudio
        case "ogg", "oga", "opus": return ogg
        case "webm", "weba": return webm
        case "ac3": return ac3
        case "eac3", "ec3": return eac3
        case "": return nil
        default:
            guard let type = UTType(filenameExtension: raw), type.conforms(to: .audiovisualContent) else { return nil }
            return type.identifier
        }
    }
}
