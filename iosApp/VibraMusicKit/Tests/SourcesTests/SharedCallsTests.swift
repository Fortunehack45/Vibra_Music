import XCTest
@testable import Sources

/// The contract that keeps a source's server from being asked the same question over and over.
/// Ported from Android's SharedCallsTest.
final class SharedCallsTests: XCTestCase {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        @discardableResult func increment() -> Int { lock.withLock { value += 1; return value } }
        var count: Int { lock.withLock { value } }
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if open { lock.unlock(); continuation.resume(); return }
                waiters.append(continuation)
                lock.unlock()
            }
        }
        func release() {
            lock.lock()
            open = true
            let pending = waiters
            waiters = []
            lock.unlock()
            pending.forEach { $0.resume() }
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: TimeInterval = 0
        var now: TimeInterval {
            get { lock.withLock { time } }
            set { lock.withLock { time = newValue } }
        }
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async {
        for _ in 0..<500 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition never became true")
    }

    func testARepeatedQuestionInsideTheWindowCostsOneCall() async {
        let calls = Counter()
        let shared = SharedCalls<String>(ttl: 60)
        for _ in 0..<5 {
            let answer = await shared.get("q") { calls.increment(); return .success("flac") }
            XCTAssertEqual(try? answer.get(), "flac")
        }
        XCTAssertEqual(calls.count, 1)
    }

    /// "This catalogue does not hold that recording" is an answer, and the one re-asked most.
    func testAnEmptyAnswerIsKeptBecauseItIsAnAnswer() async {
        let calls = Counter()
        let shared = SharedCalls<[String]>(ttl: 60)
        for _ in 0..<3 {
            _ = await shared.get("missing") { calls.increment(); return .success([]) }
        }
        XCTAssertEqual(calls.count, 1)
    }

    func testAFailureIsNotKept() async {
        let calls = Counter()
        let shared = SharedCalls<String>(ttl: 60)
        for _ in 0..<3 {
            _ = await shared.get("q") { calls.increment(); return .failure(URLError(.badServerResponse)) }
        }
        XCTAssertEqual(calls.count, 3)
    }

    func testAnExplicitRefreshDropsACompletedAnswer() async {
        let calls = Counter()
        let shared = SharedCalls<String>(ttl: 60)
        _ = await shared.get("q") { .success("answer-\(calls.increment())") }
        await shared.clearCompleted()
        let refreshed = await shared.get("q") { .success("answer-\(calls.increment())") }
        XCTAssertEqual(try? refreshed.get(), "answer-2")
        XCTAssertEqual(calls.count, 2)
    }

    func testAnExplicitRefreshKeepsARequestAlreadyInFlight() async {
        let calls = Counter()
        let joined = Counter()
        let started = Gate()
        let release = Gate()
        let shared = SharedCalls<String>(ttl: 60, log: { _ in joined.increment() })

        async let first = shared.get("q") {
            calls.increment()
            started.release()
            await release.wait()
            return .success("flac")
        }
        await started.wait()
        await shared.clearCompleted()
        async let second = shared.get("q") { calls.increment(); return .success("duplicate") }
        await waitUntil { joined.count >= 1 }
        release.release()

        let (a, b) = await (first, second)
        XCTAssertEqual(try? a.get(), "flac")
        XCTAssertEqual(try? b.get(), "flac")
        XCTAssertEqual(calls.count, 1)
    }

    func testAnExpiredAnswerIsAskedAgain() async {
        let calls = Counter()
        let clock = Clock()
        let shared = SharedCalls<String>(ttl: 1, now: { clock.now })
        _ = await shared.get("q") { calls.increment(); return .success("a") }
        clock.now = 0.999
        _ = await shared.get("q") { calls.increment(); return .success("a") }
        XCTAssertEqual(calls.count, 1)
        clock.now = 1.001
        _ = await shared.get("q") { calls.increment(); return .success("a") }
        XCTAssertEqual(calls.count, 2)
    }

    /// ttl 0: nothing is kept once done, so only in-flight sharing explains a single call.
    func testCallersArrivingMidFlightShareTheOneCall() async {
        let calls = Counter()
        let joined = Counter()
        let release = Gate()
        let shared = SharedCalls<String>(ttl: 0, log: { _ in joined.increment() })
        let waiters = (0..<4).map { _ in
            Task {
                await shared.get("q") {
                    calls.increment()
                    await release.wait()
                    return .success("flac")
                }
            }
        }
        await waitUntil { joined.count >= 3 }
        release.release()
        for waiter in waiters {
            let answer = await waiter.value
            XCTAssertEqual(try? answer.get(), "flac")
        }
        XCTAssertEqual(calls.count, 1)
    }

    /// What the operator complained about: a cancelled caller used to take the request down after
    /// the server had been asked. Now it drops its wait, and the answer lands in the cache.
    func testACancelledCallerDoesNotKillTheCallOthersStillWant() async {
        let calls = Counter()
        let started = Gate()
        let release = Gate()
        let shared = SharedCalls<String>(ttl: 60)
        let abandoning = Task {
            await shared.get("q") {
                calls.increment()
                started.release()
                await release.wait()
                return .success("flac")
            }
        }
        await started.wait()
        abandoning.cancel()
        let abandoned = await abandoning.value
        XCTAssertTrue((try? abandoned.get()) == nil, "the cancelled caller returns without waiting")
        release.release()

        let answer = await shared.get("q") { .success("never asked") }
        XCTAssertEqual(try? answer.get(), "flac")
        XCTAssertEqual(calls.count, 1)
    }

    func testHeldAnswersStayBounded() async {
        let shared = SharedCalls<String>(ttl: 60)
        for index in 0..<400 {
            _ = await shared.get("q\(index)") { .success("a") }
        }
        let size = await shared.size
        XCTAssertLessThanOrEqual(size, 128)
    }

    func testKeysAreLengthPrefixedSoNoPartCanForgeASeparator() {
        XCTAssertNotEqual(sharedCallKey("a|b", "c"), sharedCallKey("a", "b|c"))
        XCTAssertEqual(sharedCallKey("ab", "c"), "2:ab|1:c")
    }
}
