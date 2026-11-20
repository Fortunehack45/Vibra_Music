import XCTest
import VibraMusicTestSupport
@testable import VibraMusicCore

final class DiagnosticLogTests: XCTestCase {
    /// 1970-01-01 00:16:40 UTC, so the expected lines don't depend on the machine's time zone.
    private let at = Date(timeIntervalSince1970: 1_000)

    private func makeLog(maxFileBytes: Int = 1_000_000) throws -> DiagnosticLog {
        let fixed = at
        return DiagnosticLog(
            directory: try makeTemporaryDirectory().appending(path: "Logs"),
            maxFileBytes: maxFileBytes,
            timeZone: TimeZone(identifier: "UTC")!,
            now: { fixed }
        )
    }

    private func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    func testALineCarriesTheTimeLevelCategoryTrackAndMessage() throws {
        let log = try makeLog()
        log.record(.warning, category: "Resolver", track: "abc123", message: "no stream")
        log.record(.info, category: "App", track: nil, message: "hello")
        log.waitUntilWritten()
        XCTAssertEqual(text(log.fileURL), """
            1970-01-01 00:16:40.000 W Resolver [abc123] no stream
            1970-01-01 00:16:40.000 I App [-] hello

            """)
    }

    func testAMultiLineMessageIndentsItsContinuationLines() throws {
        let log = try makeLog()
        log.record(.error, category: "Net", track: nil, message: "failed\nURLError(-1001)\nsecond")
        log.waitUntilWritten()
        XCTAssertEqual(text(log.fileURL), """
            1970-01-01 00:16:40.000 E Net [-] failed
                URLError(-1001)
                second

            """)
    }

    func testALongMessageIsCutWithANoteOfHowMuchWentSoTheCapStillHolds() throws {
        let log = try makeLog()
        log.record(.debug, category: "C", track: nil, message: String(repeating: "x", count: 2_500))
        log.waitUntilWritten()
        XCTAssertTrue(text(log.fileURL).hasSuffix(String(repeating: "x", count: 2_000) + "…(500 more)\n"))
    }

    func testPastTheCapTheFileMovesAsideAndReplacesTheOlderOne() throws {
        // Each line is 40 bytes, so three fit in 150 and the fourth starts a new file.
        let log = try makeLog(maxFileBytes: 150)
        for index in 0..<12 {
            log.record(.info, category: "Cat", track: nil, message: String(format: "msg%02d", index))
        }
        log.waitUntilWritten()
        func lines(_ range: Range<Int>) -> String {
            range.map { String(format: "1970-01-01 00:16:40.000 I Cat [-] msg%02d\n", $0) }.joined()
        }
        XCTAssertEqual(text(log.fileURL), lines(9..<12))
        XCTAssertEqual(text(log.rotatedFileURL), lines(6..<9), "msg00 to msg05 were replaced along the way")
        XCTAssertEqual(log.existingFileURLs, [log.fileURL, log.rotatedFileURL])
    }

    func testTurningTheLogOffDeletesBothFilesAndStopsWriting() throws {
        let log = try makeLog(maxFileBytes: 100)
        for index in 0..<5 { log.record(.info, category: "Cat", track: nil, message: "line \(index)") }
        log.waitUntilWritten()
        XCTAssertEqual(log.existingFileURLs.count, 2)

        log.setEnabled(false)
        log.record(.info, category: "Cat", track: nil, message: "after")
        log.waitUntilWritten()
        XCTAssertEqual(log.existingFileURLs, [])

        log.setEnabled(true, header: "log started")
        log.waitUntilWritten()
        XCTAssertEqual(text(log.fileURL), "1970-01-01 00:16:40.000 I App [-] log started\n")
    }

    func testTheFilesAreKeptOutOfBackups() throws {
        let log = try makeLog(maxFileBytes: 100)
        for index in 0..<5 { log.record(.info, category: "Cat", track: nil, message: "line \(index)") }
        log.waitUntilWritten()
        for url in log.existingFileURLs {
            XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true, url.lastPathComponent)
        }
    }

    func testDebugLogAndTrackLogLinesReachTheSinkWhateverTheBuild() throws {
        let log = try makeLog()
        let previous = DiagnosticLog.shared
        DiagnosticLog.shared = log
        defer { DiagnosticLog.shared = previous }

        DebugLog.d("Feeds", "a debug line")
        DebugLog.i("Feeds", "an info line")
        DebugLog.w("Feeds", "a warning", error: URLError(.timedOut))
        DebugLog.e("Feeds", "an error")
        TrackLog.d("Resolver", "a track line", about: "vid1")
        TrackLog(writesDiagnosticLog: false).log(.info, "Resolver", "an instance nobody asked to write")
        log.waitUntilWritten()

        let written = text(log.fileURL)
        XCTAssertTrue(written.contains("D Feeds [-] a debug line\n"))
        XCTAssertTrue(written.contains("I Feeds [-] an info line\n"))
        XCTAssertTrue(written.contains("W Feeds [-] a warning\n    "))
        XCTAssertTrue(written.contains("E Feeds [-] an error\n"))
        XCTAssertTrue(written.contains("D Resolver [vid1] a track line\n"))
        XCTAssertFalse(written.contains("nobody asked"))
    }

    func testSecretsAreScrubbedAtTheSink() throws {
        let log = try makeLog()
        log.record(.warning, category: "Net", track: nil, message: """
            GET https://rr1.googlevideo.com/videoplayback?id=1&sig=SECRET&lsig=SECRET2 failed
            listenbrainz_token=SECRET3 cookie: SECRET4 Authorization: Bearer SECRET5
            """)
        log.waitUntilWritten()
        let written = text(log.fileURL)
        XCTAssertFalse(written.contains("SECRET"), written)
        XCTAssertTrue(written.contains("https://rr1.googlevideo.com/videoplayback?*** failed"))
    }

    func testOrdinaryTextSurvivesTheScrub() {
        XCTAssertEqual(DiagnosticLog.scrub("no token in localStorage after 3 tries, 2 cookies, https://a.b/c"),
                       "no token in localStorage after 3 tries, 2 cookies, https://a.b/c")
    }

    func testTheOpeningLineNamesTheBuildTheDeviceAndTheTimeZone() {
        let header = DiagnosticLog.launchHeader()
        XCTAssertTrue(header.contains("Vibra Music"))
        XCTAssertTrue(header.contains(TimeZone.current.identifier))
        XCTAssertTrue(header.contains(ProcessInfo.processInfo.operatingSystemVersionString))
    }
}
