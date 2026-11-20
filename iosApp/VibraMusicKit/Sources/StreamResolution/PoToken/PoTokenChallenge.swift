import Foundation

/// The BotGuard wire formats. Port of `potoken/JavaScriptUtil.kt`.
///
/// Android built JavaScript source strings (`new Uint8Array([...])`) to splice into
/// `evaluateJavascript`; WebKit's `callAsyncJavaScript` takes arguments directly, so these return
/// plain values (a dictionary, byte arrays) and the page builds its own `Uint8Array`s.
enum PoTokenChallenge {
    /// BotGuard's API key and request key, as used by YouTube's web client.
    static let googleAPIKey = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw"
    static let requestKey = "O43z0dpjhgX20SCx4KAo"
    static let createURL = URL(string: "https://www.youtube.com/api/jnn/v1/Create")!
    static let generateITURL = URL(string: "https://www.youtube.com/api/jnn/v1/GenerateIT")!
    static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.3"

    struct ParseError: Error, LocalizedError {
        let detail: String
        var errorDescription: String? { "BotGuard response: \(detail)" }
    }

    /// The raw `Create` response into the object `runBotGuard` takes.
    ///
    /// The challenge is either plain (`[[...]]`) or scrambled (`[null, "<base64>"]`, each byte
    /// shifted by 97); the fields are positional.
    static func parseChallengeData(_ raw: Data) throws -> [String: Any] {
        guard let scrambled = try JSONSerialization.jsonObject(with: raw) as? [Any] else {
            throw ParseError(detail: "Create response is not an array")
        }
        let challenge: [Any]
        if scrambled.count > 1, let encoded = scrambled[1] as? String {
            let bytes = try base64Bytes(encoded).map { $0 &+ 97 }
            guard let inner = try JSONSerialization.jsonObject(with: Data(bytes)) as? [Any] else {
                throw ParseError(detail: "descrambled challenge is not an array")
            }
            challenge = inner
        } else if let plain = scrambled.first as? [Any] {
            challenge = plain
        } else {
            throw ParseError(detail: "no challenge in Create response")
        }
        guard challenge.count > 7,
              let messageId = challenge[0] as? String,
              let interpreterHash = challenge[3] as? String,
              let program = challenge[4] as? String,
              let globalName = challenge[5] as? String,
              let experiments = challenge[7] as? String
        else { throw ParseError(detail: "challenge is missing fields") }
        let safeScript = (challenge[1] as? [Any])?.first { $0 is String } as? String
        let trustedURL = (challenge[2] as? [Any])?.first { $0 is String } as? String
        return [
            "messageId": messageId,
            "interpreterJavascript": [
                "privateDoNotAccessOrElseSafeScriptWrappedValue": safeScript ?? NSNull(),
                "privateDoNotAccessOrElseTrustedResourceUrlWrappedValue": trustedURL ?? NSNull(),
            ] as [String: Any],
            "interpreterHash": interpreterHash,
            "program": program,
            "globalName": globalName,
            "clientExperimentsStateBlob": experiments,
        ]
    }

    /// The raw `GenerateIT` response into the integrity token's bytes and its lifetime in seconds.
    static func parseIntegrityTokenData(_ raw: Data) throws -> (token: [UInt8], lifetimeSeconds: Int) {
        guard let array = try JSONSerialization.jsonObject(with: raw) as? [Any], array.count > 1,
              let token = array[0] as? String
        else { throw ParseError(detail: "GenerateIT response has no token") }
        let lifetime: Int
        if let number = array[1] as? NSNumber {
            lifetime = number.intValue
        } else if let text = array[1] as? String, let value = Int(text) {
            lifetime = value
        } else {
            throw ParseError(detail: "GenerateIT response has no lifetime")
        }
        return (try base64Bytes(token), lifetime)
    }

    /// The identifier a token is bound to (a videoId or a visitor id), as bytes.
    static func identifierBytes(_ identifier: String) -> [UInt8] { Array(identifier.utf8) }

    /// A minted token (the bytes `obtainPoToken` returns) in YouTube's web-safe base64: standard
    /// alphabet with `+`→`-` and `/`→`_`, padding kept.
    static func tokenString(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    /// Decodes YouTube's base64 variant (`-`/`_` alphabet, `.` as padding).
    static func base64Bytes(_ text: String) throws -> [UInt8] {
        var standard = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: ".", with: "=")
        let remainder = standard.count % 4
        if remainder != 0 { standard += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: standard) else { throw ParseError(detail: "cannot base64 decode") }
        return Array(data)
    }
}
