import VibraMusicCore
import XCTest
@testable import Playback

private struct Unplayable: PermanentPlaybackError {
    var verdict: String { "This video is age-restricted" }
}

final class RecoveryLedgerTests: XCTestCase {
    func testATrackGetsTwoRetriesThenIsSkippedIfItNeverPlayed() {
        var ledger = RecoveryLedger()
        ledger.itemBecameCurrent("a")
        XCTAssertEqual(ledger.recordFailure(itemID: "a", verdict: nil), .retry(attempt: 1))
        ledger.retryingItemID = "a"
        ledger.itemBecameCurrent("a")
        XCTAssertEqual(ledger.recordFailure(itemID: "a", verdict: nil), .retry(attempt: 2), "our own retry must not refill the budget")
        ledger.retryingItemID = "a"
        ledger.itemBecameCurrent("a")
        XCTAssertEqual(ledger.recordFailure(itemID: "a", verdict: nil), .giveUp(skipReason: "failed to start after 3 attempts", attempt: 3))
    }

    func testATrackThatDiesMidSongStaysPut() {
        var ledger = RecoveryLedger()
        ledger.itemBecameCurrent("a")
        ledger.itemBecameAudible("a")
        _ = ledger.recordFailure(itemID: "a", verdict: nil)
        _ = ledger.recordFailure(itemID: "a", verdict: nil)
        XCTAssertEqual(ledger.recordFailure(itemID: "a", verdict: nil), .giveUp(skipReason: nil, attempt: 3), "jumping on would take the song away")
    }

    func testAVerdictGivesUpAtOnceAndAlwaysSkips() {
        var ledger = RecoveryLedger()
        ledger.itemBecameCurrent("a")
        ledger.itemBecameAudible("a")
        XCTAssertEqual(ledger.recordFailure(itemID: "a", verdict: "age-restricted"), .giveUp(skipReason: "age-restricted", attempt: 1))
    }

    func testANewTrackOrTheListenerAskingAgainIsACleanSlate() {
        var ledger = RecoveryLedger()
        ledger.itemBecameCurrent("a")
        _ = ledger.recordFailure(itemID: "a", verdict: nil)
        _ = ledger.recordFailure(itemID: "a", verdict: nil)
        ledger.itemBecameCurrent("a")
        XCTAssertEqual(ledger.attemptCount(for: "a"), 0)
        XCTAssertEqual(ledger.recordFailure(itemID: "a", verdict: nil), .retry(attempt: 1))
    }

    func testAtMostFourTracksInARowAreSkippedForPlainErrors() {
        var ledger = RecoveryLedger()
        for index in 0..<RecoveryLedger.maxConsecutiveSkips {
            let id = "t\(index)"
            ledger.itemBecameCurrent(id)
            _ = ledger.recordFailure(itemID: id, verdict: nil)
            _ = ledger.recordFailure(itemID: id, verdict: nil)
            guard case .giveUp(let reason?, _) = ledger.recordFailure(itemID: id, verdict: nil) else {
                return XCTFail("track \(index) should be skipped")
            }
            XCTAssertTrue(reason.hasPrefix("failed to start"))
        }
        ledger.itemBecameCurrent("t4")
        _ = ledger.recordFailure(itemID: "t4", verdict: nil)
        _ = ledger.recordFailure(itemID: "t4", verdict: nil)
        XCTAssertEqual(ledger.recordFailure(itemID: "t4", verdict: nil), .giveUp(skipReason: nil, attempt: 3), "offline, every track fails the same way")
        XCTAssertEqual(ledger.recordFailure(itemID: "t5", verdict: "gone"), .giveUp(skipReason: "gone", attempt: 1), "verdicts are exempt")

        ledger.itemBecameAudible("t9")
        ledger.itemBecameCurrent("t6")
        _ = ledger.recordFailure(itemID: "t6", verdict: nil)
        _ = ledger.recordFailure(itemID: "t6", verdict: nil)
        if case .giveUp(nil, _) = ledger.recordFailure(itemID: "t6", verdict: nil) {
            XCTFail("anything playing restores the allowance")
        }
    }

    func testTheVerdictIsFoundThroughWrappedErrors() {
        let wrapped = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: "Loader", code: 1, userInfo: [NSUnderlyingErrorKey: Unplayable()]),
        ])
        XCTAssertEqual(RecoveryLedger.permanentVerdict(in: wrapped), "This video is age-restricted")
        XCTAssertEqual(RecoveryLedger.permanentVerdict(in: Unplayable()), "This video is age-restricted")
        XCTAssertNil(RecoveryLedger.permanentVerdict(in: URLError(.timedOut)))
        XCTAssertNil(RecoveryLedger.permanentVerdict(in: nil))
    }

    func testANetworkFaultIsFoundUnderAVFoundationsWrapper() {
        let wrapped = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [
            NSUnderlyingErrorKey: URLError(.networkConnectionLost),
        ])
        XCTAssertTrue(RecoveryLedger.isNetworkFault(wrapped))
        XCTAssertTrue(RecoveryLedger.isNetworkFault(URLError(.timedOut)))
        XCTAssertFalse(RecoveryLedger.isNetworkFault(NSError(domain: "AVFoundationErrorDomain", code: -11829)), "an undecodable file is the file's fault")
        XCTAssertFalse(RecoveryLedger.isNetworkFault(URLError(.badURL)))
        XCTAssertFalse(RecoveryLedger.isNetworkFault(nil))
    }

    /// A reset isn't the item's doing: it leaves the item's retries alone, and only media services
    /// staying down, with nothing sounding between reopens, ends the reopening.
    func testResetsSpendNoRetriesAndStopOnlyWhenNothingSoundsBetweenThem() {
        var ledger = RecoveryLedger()
        ledger.itemBecameCurrent("a")
        let waits = (0..<RecoveryLedger.maxResetReopens).compactMap { _ in ledger.recordReset() }
        XCTAssertEqual(waits.count, RecoveryLedger.maxResetReopens)
        XCTAssertEqual(waits, waits.sorted(), "each waits at least as long as the last")
        XCTAssertEqual(waits.first, RecoveryLedger.recoveryDelay)
        XCTAssertNil(ledger.recordReset(), "still down after every reopen")
        XCTAssertEqual(ledger.attemptCount(for: "a"), 0)

        ledger.itemBecameAudible("a")
        XCTAssertEqual(ledger.recordReset(), RecoveryLedger.recoveryDelay, "sound starts the count again")
        ledger.mediaServicesCameBack()
        XCTAssertEqual(ledger.recordReset(), RecoveryLedger.recoveryDelay, "so does the session saying they are back")
    }

    /// The classification, wrapped or not: what the system did, against what the file or the server did.
    func testSystemFaultsAreToldFromTheBytesFault() {
        func avError(_ code: Int) -> NSError { NSError(domain: "AVFoundationErrorDomain", code: code) }
        let wrapped = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [NSUnderlyingErrorKey: avError(-11819)])
        XCTAssertTrue(RecoveryLedger.isMediaServicesReset(avError(-11819)))
        XCTAssertTrue(RecoveryLedger.isMediaServicesReset(wrapped))
        XCTAssertFalse(RecoveryLedger.isMediaServicesReset(avError(-11839)), "a decoder taken away leaves the players alive")
        for system in [-11801, -11807, -11818, -11819, -11839, -11847, -11856, -11857, -11878, -11882] {
            XCTAssertTrue(RecoveryLedger.isSystemFault(avError(system)), "\(system)")
        }
        XCTAssertTrue(RecoveryLedger.isSystemFault(wrapped))
        for bytes in [-11800, -11821, -11828, -11829, -11849, -11850, -11855] {
            XCTAssertFalse(RecoveryLedger.isSystemFault(avError(bytes)), "\(bytes)")
        }
        XCTAssertFalse(RecoveryLedger.isSystemFault(URLError(.networkConnectionLost)))
        XCTAssertFalse(RecoveryLedger.isSystemFault(NSError(domain: "Other", code: -11819)), "only AVFoundation's")
        XCTAssertFalse(RecoveryLedger.isSystemFault(nil))
    }
}
