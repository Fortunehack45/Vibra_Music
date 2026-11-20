import XCTest
@testable import StreamResolution

/// The probe's range and its three verdicts (Android's `Probe` enum).
final class StreamURLProbeTests: XCTestCase {
    private func gv(client: String = "VISIONOS", clen: Int64? = 3_449_447) -> URL {
        var text = "https://rr1---sn-abc.googlevideo.com/videoplayback?c=\(client)&itag=140"
        if let clen { text += "&clen=\(clen)" }
        return URL(string: text)!
    }

    // MARK: Range

    /// Some clients serve the first megabyte and 403 everything after it, so the probe starts
    /// past it and asks for as much as one real range request.
    func testLongFilesAreProbedPastTheFirstMegabyte() {
        XCTAssertEqual(StreamURLProbe.probeRange(for: gv()), 1_048_576...(1_048_576 + 1_048_576 - 1))
    }

    func testNarrowClientsAreProbedWithTheirNarrowRange() {
        XCTAssertEqual(StreamURLProbe.probeRange(for: gv(client: "ANDROID_VR")), 1_048_576...(1_048_576 + 524_288 - 1))
    }

    func testShortFilesAreProbedFromTheStartAndNotPastTheirEnd() {
        XCTAssertEqual(StreamURLProbe.probeRange(for: gv(clen: 500_000)), 0...499_999)
        // Just under the boundary plus the read size: still from the start.
        XCTAssertEqual(StreamURLProbe.probeRange(for: gv(clen: 1_048_576 + 16_384)).lowerBound, 0)
        XCTAssertEqual(StreamURLProbe.probeRange(for: gv(clen: 1_048_576 + 16_385)).lowerBound, 1_048_576)
    }

    func testURLsWithoutALengthAreProbedFromTheStart() {
        XCTAssertEqual(StreamURLProbe.probeRange(for: gv(clen: nil)), 0...1_048_575)
        let foreign = URL(string: "https://cdn.example.com/track.m4a")!
        XCTAssertEqual(StreamURLProbe.probeRange(for: foreign).lowerBound, 0)
        XCTAssertEqual(StreamURLProbe.probeRange(for: foreign).upperBound, Int64.max - 1)
    }

    // MARK: Verdicts

    private func verdict(_ response: StreamStubResponse, timeout: TimeInterval = 6, headers: [String: String] = [:]) async -> (StreamURLProbe.Verdict, StreamStubServer) {
        let server = StreamStubServer { _ in response }
        let probe = StreamURLProbe(session: server.session, timeout: timeout)
        return (await probe.probe(gv(), headers: headers), server)
    }

    func testAudioBytesAreOK() async {
        let (result, server) = await verdict(.audio(bytes: 64 * 1024), headers: ["User-Agent": "UA/1"])
        XCTAssertEqual(result, .ok)
        let request = try? XCTUnwrap(server.requests.first)
        XCTAssertEqual(request?.header("Range"), "bytes=1048576-2097151")
        XCTAssertEqual(request?.header("User-Agent"), "UA/1", "the probe tests the request that matters")
    }

    func testRefusalCodesAreRefused() async {
        for code in [403, 404, 410] {
            let (result, _) = await verdict(StreamStubResponse(status: code, headers: ["Content-Type": "text/plain"]))
            XCTAssertEqual(result, .refused, "HTTP \(code)")
        }
    }

    func testOtherErrorsAreUnreachable() async {
        for code in [500, 503, 429] {
            let (result, _) = await verdict(StreamStubResponse(status: code))
            XCTAssertEqual(result, .unreachable, "HTTP \(code)")
        }
        let (failed, _) = await verdict(StreamStubResponse(error: URLError(.networkConnectionLost)))
        XCTAssertEqual(failed, .unreachable)
    }

    /// An error page or a consent interstitial, dressed as a success.
    func testNonAudioSuccessIsARefusal() async {
        let (result, _) = await verdict(.text("<html>consent</html>"))
        XCTAssertEqual(result, .refused)
        let (rangeNotSatisfiable, _) = await verdict(StreamStubResponse(status: 416, headers: ["Content-Type": "text/plain"]))
        XCTAssertEqual(rangeNotSatisfiable, .refused)
    }

    /// Headers can arrive long before a body that never does.
    func testStalledBodyIsUnreachable() async {
        let started = Date()
        let (result, _) = await verdict(StreamStubResponse(status: 206, headers: ["Content-Type": "audio/mp4"], stallAfterHeaders: true), timeout: 0.5)
        XCTAssertEqual(result, .unreachable)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the probe must give up on its own deadline")
    }

    func testShortBodyIsUnreachable() async {
        let (result, _) = await verdict(.audio(bytes: 1_000))
        XCTAssertEqual(result, .unreachable)
    }
}
