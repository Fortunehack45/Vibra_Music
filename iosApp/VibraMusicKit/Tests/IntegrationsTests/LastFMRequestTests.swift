import VibraMusicTestSupport
import Foundation
import XCTest
@testable import Integrations

/// Now-playing and scrobble request encoding, stubbed at the HTTP layer.
/// No live Last.fm account is available here; everything runs offline.
final class LastFMRequestTests: XCTestCase {
    private func client(
        stub: URLProtocolStub,
        sessionKey: String? = "SESSION",
        apiKey: String = "KEY",
        secret: String = "SECRET"
    ) -> LastFMClient {
        LastFMClient(
            configuration: LastFMConfiguration(apiKey: apiKey, secret: secret, sessionKey: sessionKey),
            session: stub.makeSession()
        )
    }

    private func formFields(of request: URLRequest) -> [String: String] {
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        var out: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            out[kv[0].removingPercentEncoding ?? kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
        }
        return out
    }

    func testInertWithoutCredentials() async {
        let stub = URLProtocolStub()
        let client = LastFMClient(configuration: LastFMConfiguration(), session: stub.makeSession())
        let status = await client.status()
        XCTAssertEqual(status, .missingCredentials)
        do {
            _ = try await client.requestToken()
            XCTFail("expected missingCredentials")
        } catch let error as LastFMError {
            XCTAssertEqual(error, .missingCredentials)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertTrue(stub.requests.isEmpty, "inert client must not hit the network")
    }

    func testScrobbleRequiresSessionKey() async {
        let stub = URLProtocolStub()
        let client = self.client(stub: stub, sessionKey: nil)
        let status = await client.status()
        if case .ready(let key) = status {
            XCTAssertNil(key)
        } else {
            XCTFail("expected ready without session")
        }
        do {
            try await client.scrobble(artist: "A", track: "T", timestamp: 1)
            XCTFail("expected missingSession")
        } catch let error as LastFMError {
            XCTAssertEqual(error, .missingSession)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testNowPlayingEncoding() async throws {
        let stub = URLProtocolStub()
        stub.register(host: "ws.audioscrobbler.com", path: "/2.0/", method: "POST", response: .json("{}"))
        let client = self.client(stub: stub)
        try await client.updateNowPlaying(artist: "Cher", track: "Believe", album: "Believe", durationSeconds: 200)

        XCTAssertEqual(stub.requests.count, 1)
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), LastFMClient.userAgent)
        let fields = formFields(of: request)
        XCTAssertEqual(fields["method"], "track.updateNowPlaying")
        XCTAssertEqual(fields["artist"], "Cher")
        XCTAssertEqual(fields["track"], "Believe")
        XCTAssertEqual(fields["album"], "Believe")
        XCTAssertEqual(fields["duration"], "200")
        XCTAssertEqual(fields["sk"], "SESSION")
        XCTAssertEqual(fields["format"], "json")
        // api_sig verifies against the signed subset.
        var signed = fields
        let sig = signed.removeValue(forKey: "api_sig")
        signed.removeValue(forKey: "format")
        XCTAssertEqual(sig, LastFMSignature.signature(params: signed, secret: "SECRET"))
    }

    func testScrobbleEncodingUsesIndexedKeys() async throws {
        let stub = URLProtocolStub()
        stub.register(host: "ws.audioscrobbler.com", path: "/2.0/", method: "POST", response: .json("{}"))
        let client = self.client(stub: stub)
        try await client.scrobble(artist: "A", track: "T", timestamp: 1_700_000_000, album: "AL", durationSeconds: 227)

        let request = try XCTUnwrap(stub.requests.first)
        let fields = formFields(of: request)
        XCTAssertEqual(fields["method"], "track.scrobble")
        XCTAssertEqual(fields["artist[0]"], "A")
        XCTAssertEqual(fields["track[0]"], "T")
        XCTAssertEqual(fields["timestamp[0]"], "1700000000")
        XCTAssertEqual(fields["album[0]"], "AL")
        XCTAssertEqual(fields["duration[0]"], "227")
    }

    func testTokenAndSessionRoundTrip() async throws {
        let stub = URLProtocolStub()
        stub.register(host: "ws.audioscrobbler.com", path: "/2.0/", method: "POST") { request in
            let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if body.contains("method=auth.getToken") {
                return .json(#"{"token":"TOKEN123"}"#)
            }
            return .json(#"{"session":{"name":"user","key":"SESS456","subscriber":0}}"#)
        }
        let client = self.client(stub: stub, sessionKey: nil)
        let token = try await client.requestToken()
        XCTAssertEqual(token, "TOKEN123")
        let session = try await client.fetchSession(token: "TOKEN123")
        XCTAssertEqual(session.username, "user")
        XCTAssertEqual(session.sessionKey, "SESS456")
        let authURL = await client.authorizationURL(for: "TOKEN123")
        XCTAssertEqual(
            authURL?.absoluteString,
            "https://www.last.fm/api/auth/?api_key=KEY&token=TOKEN123"
        )
    }

    func testLibreFmAuthURL() async {
        let client = LastFMClient(
            configuration: LastFMConfiguration(
                endpoint: LastFMConfiguration.libreFmEndpoint, apiKey: "K", secret: "S"
            )
        )
        let authURL = await client.authorizationURL(for: "T")
        XCTAssertEqual(
            authURL?.absoluteString,
            "https://libre.fm/api/auth?api_key=K&token=T"
        )
    }

    func testAPIErrorSurfacesCodeAndMessage() async {
        let stub = URLProtocolStub()
        stub.register(
            host: "ws.audioscrobbler.com", path: "/2.0/", method: "POST",
            response: .json(#"{"error":4,"message":"Authentication Failed"}"#)
        )
        let client = self.client(stub: stub)
        do {
            _ = try await client.requestToken()
            XCTFail("expected LastFMError")
        } catch let error as LastFMError {
            XCTAssertEqual(error.code, 4)
            XCTAssertEqual(error.message, "Authentication Failed")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testEndpointNormalization() throws {
        XCTAssertEqual(
            try LastFMConfiguration.normalizeEndpoint("https://libre.fm"),
            "https://libre.fm/2.0/"
        )
        XCTAssertEqual(
            try LastFMConfiguration.normalizeEndpoint("https://example.com/api/"),
            "https://example.com/api/"
        )
        XCTAssertThrowsError(try LastFMConfiguration.normalizeEndpoint("ftp://example.com/2.0/"))
        XCTAssertThrowsError(try LastFMConfiguration.normalizeEndpoint("https://example.com/2.0/?x=1"))
    }
}
