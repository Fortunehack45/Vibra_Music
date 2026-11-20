import Foundation
import VibraMusicCore

// The companion-object half of data/sources/ModuleSource.kt: rules both module and addon streams
// are held to. Kept on ModuleSource as Android does, so the tests read the same.

extension SourceQuality {
    /// Android's `ModuleSource.DOLBY` row tag: the immersive mix, published by some catalogues as
    /// its own row (and filed by Tidal under `LOW`). Looked up by raw value so this module builds
    /// against a Core without `SourceQuality.dolby` (requested); there it is nil, immersive rows go
    /// untagged and the resolver simply doesn't prefer them.
    static let immersive = SourceQuality(rawValue: "DOLBY")
}

extension ModuleSource {
    /// The three tiers every compatible module speaks, whatever it calls them on the way out:
    /// `LOSSLESS`, `FLAC 16-bit / 44.1kHz` and `hires-96` are one tier; `320kbps` and `HIGH` another.
    public static let lossless = "LOSSLESS"
    public static let high = "HIGH"
    public static let low = "LOW"

    /// Worst to best, so a row's best available tier can be picked out by index.
    public static let tiers = [low, high, lossless]

    /// Below this, a capped connection is better served by the source's own small tier.
    static let lowCeilingKbps = 128

    /// Which tier a free-text quality label describes, or nil. Order matters: `FLAC 16-bit /
    /// 44.1kHz` carries a bit depth *and* a codec, and the codec settles it.
    public static func qualityTier(_ label: String) -> String? {
        let text = label.uppercased()
        if text.nonBlank == nil { return nil }
        if losslessHints.contains(where: text.contains) { return lossless }
        if lowHints.contains(where: text.contains) { return low }
        if highHints.contains(where: text.contains) { return high }
        return nil
    }

    /// ``qualityTier(_:)`` as Core's row tag.
    static func sourceQuality(_ label: String) -> SourceQuality? {
        qualityTier(label).flatMap(SourceQuality.init(rawValue:))
    }

    private static let losslessHints = ["LOSSLESS", "FLAC", "ALAC", "HI-RES", "HI_RES", "HIRES", "24-BIT", "16-BIT", "WAV"]
    private static let lowHints = ["LOW", "128", "96KBPS", "64"]
    private static let highHints = ["HIGH", "320", "MP3", "AAC", "M4A", "OPUS", "OGG"]

    /// Whether a stream URL is one no server could answer, decided without asking one.
    ///
    /// Two faults, both seen in the field:
    /// - A URL the player's own parser refuses (Android: OkHttp's `Malformed URL`, from a Xiaomi
    ///   report): a relative path, an error string in the URL field, a non-http scheme. Restricting
    ///   to http(s) also stops a source pointing the player at a file on the device.
    /// - A URL carrying a second copy of its own origin — the August 2026 Tidal fault,
    ///   `https://sp-ad-fa.audio.tidal.com/mediatracks/<blob>/https://sp-ad-fa.audio.tidal.com/…`,
    ///   404 every time. Narrower than "contains two schemes": a proxy URL passing its target along
    ///   is legitimate.
    ///
    /// Repair is possible and deliberately not done: reconstructing the intent behind somebody
    /// else's broken output is a liability the app would own forever, and refusing costs one tier.
    public static func malformed(_ url: String) -> Bool {
        guard isOpenableHTTP(url) else { return true }
        guard let schemeEnd = url.range(of: "://") else { return false }
        guard let originEnd = url[schemeEnd.upperBound...].firstIndex(of: "/") else { return false }
        let origin = url[..<originEnd]
        return url[originEnd...].range(of: origin) != nil
    }

    /// OkHttp's `toHttpUrlOrNull() != nil`, closely enough: an absolute http(s) URL with a host
    /// that `URL` accepts, no whitespace.
    private static func isOpenableHTTP(_ url: String) -> Bool {
        guard !url.isEmpty, url.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              url.lowercased().hasPrefix(scheme + "://") else { return false }
        return URL(string: url) != nil
    }

    /// Whether a rendition must not be played: Dolby Atmos when it is not allowed — the device has
    /// no decoder (``DeviceCodecs``) or the listener turned it off. Caught where the source
    /// answers, not by ranking it lower: an Atmos rendition is routinely the only one a source will
    /// give for a track (the Tidal module ignores the tier and asks its backend for `MAX`), so
    /// there is no lower sibling to fall to, and refusing lets another source be heard.
    public static func unplayable(_ format: StreamFormat, atmosAllowed: Bool) -> Bool {
        format.isDolbyAtmos && !atmosAllowed
    }

    /// The tier a source is asked for, in the vocabulary the reference host uses.
    static func tierName(_ tier: StreamRequest.Tier) -> String {
        switch tier {
        case .lossless: return lossless
        case .best: return high
        case .capped(let kbps): return kbps <= lowCeilingKbps ? low : high
        }
    }
}
