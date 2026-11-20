import XCTest
@testable import Integrations

/// `api_sig` vectors (Last.fm signing rule: sorted `key+value` pairs plus the
/// secret, MD5 hex). Expected digests computed with Python `hashlib.md5`.
final class LastFMSignatureTests: XCTestCase {
    func testMD5KnownVectors() {
        XCTAssertEqual(LastFMSignature.md5Hex(""), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(LastFMSignature.md5Hex("abc"), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(
            LastFMSignature.md5Hex("The quick brown fox jumps over the lazy dog"),
            "9e107d9d372bb6826bd81d3542a419d6"
        )
    }

    func testSignatureSortsKeysBeforeHashing() {
        // Order of the input dict must not matter: keys sort byte-wise.
        let a = LastFMSignature.signature(params: ["method": "auth.getToken", "api_key": "key"], secret: "secret")
        let b = LastFMSignature.signature(params: ["api_key": "key", "method": "auth.getToken"], secret: "secret")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "b4705499705a550b07ca058a15bde9b0")
    }

    func testSignatureIncludesSessionKeyAndExtra() {
        let sig = LastFMSignature.signature(
            params: [
                "api_key": "TESTKEY",
                "artist": "Cher",
                "method": "track.updateNowPlaying",
                "sk": "SESSION123",
                "track": "Believe",
                "trackNumber": "5",
            ],
            secret: "b5f3cr3t"
        )
        XCTAssertEqual(sig, "b541948c10c2038525525d8ffe9d9bd0")
    }

    func testFormFieldsSignThenAppendSigAndFormat() {
        let fields = Dictionary(
            uniqueKeysWithValues: LastFMClient.formFields(
                method: "auth.getToken", apiKey: "key", secret: "secret"
            ).map { ($0.name, $0.value) }
        )
        XCTAssertEqual(fields["method"], "auth.getToken")
        XCTAssertEqual(fields["api_key"], "key")
        XCTAssertEqual(fields["format"], "json")
        XCTAssertEqual(fields["api_sig"], "b4705499705a550b07ca058a15bde9b0")
    }

    func testFormBodyOmitsFormatFromSignature() {
        // `format=json` is framing, not signed: recomputing the signature over
        // every field except api_sig/format must reproduce api_sig.
        let body = LastFMClient.formBody(
            method: "track.scrobble", apiKey: "k", secret: "s",
            sessionKey: "sess", extra: ["artist[0]": "A", "track[0]": "T", "timestamp[0]": "1"]
        )
        let query = String(data: body, encoding: .utf8) ?? ""
        var params: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            params[kv[0].removingPercentEncoding ?? ""] = kv[1].removingPercentEncoding ?? ""
        }
        let apiSig = params.removeValue(forKey: "api_sig")
        params.removeValue(forKey: "format")
        XCTAssertEqual(apiSig, LastFMSignature.signature(params: params, secret: "s"))
    }

    func testFormBodyKeepsAPlusInAValue() {
        let body = LastFMClient.formBody(
            method: "track.scrobble", apiKey: "k", secret: "s", extra: ["artist[0]": "C++ Rock"])
        let query = String(data: body, encoding: .utf8) ?? ""
        let artist = query.split(separator: "&")
            .first { $0.hasPrefix("artist") }?
            .split(separator: "=", maxSplits: 1).last
            .flatMap { String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding }
        XCTAssertEqual(artist, "C++ Rock")
    }
}
