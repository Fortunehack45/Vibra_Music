import CryptoKit
import Foundation

/// Last.fm `api_sig` signing (see `LastFM.kt`).
///
/// Every authenticated Last.fm call signs its parameters by concatenating the
/// `key + value` pairs in UTF-8 byte-sorted key order, appending the shared
/// secret, and taking the MD5 hex digest. `format` is deliberately excluded:
/// it is transport framing, not part of the signed parameter set, matching
/// the Kotlin `lastfmParams` which signs `paramsForSig` before appending
/// `api_sig` and `format`.
public enum LastFMSignature {
    /// Lowercase hex MD5 of the UTF-8 bytes of `string`.
    public static func md5Hex(_ string: String) -> String {
        md5Hex(Data(string.utf8))
    }

    /// Lowercase hex MD5 of `data`.
    public static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Signs `params` with `secret` per the Last.fm `api_sig` rule.
    public static func signature(params: [String: String], secret: String) -> String {
        let concatenated = params.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) })
            .map { $0 + (params[$0] ?? "") }
            .joined() + secret
        return md5Hex(concatenated)
    }
}
