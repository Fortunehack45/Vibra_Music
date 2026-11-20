import XCTest
@testable import StreamResolution

/// BotGuard wire formats (Android's `JavaScriptUtil.kt`), against a recorded `Create` answer.
final class PoTokenChallengeTests: XCTestCase {
    /// The recorded answer is the scrambled shape: `[null, "<base64, each byte - 97>"]`.
    func testRecordedCreateResponseDescramblesIntoAChallenge() throws {
        let challenge = try PoTokenChallenge.parseChallengeData(StreamFixture.data("botguard_create.json"))
        XCTAssertFalse((challenge["messageId"] as? String ?? "").isEmpty)
        XCTAssertFalse((challenge["program"] as? String ?? "").isEmpty)
        XCTAssertFalse((challenge["globalName"] as? String ?? "").isEmpty)
        XCTAssertFalse((challenge["interpreterHash"] as? String ?? "").isEmpty)
        XCTAssertNotNil(challenge["clientExperimentsStateBlob"] as? String)
        let interpreter = try XCTUnwrap(challenge["interpreterJavascript"] as? [String: Any])
        let script = try XCTUnwrap(interpreter["privateDoNotAccessOrElseSafeScriptWrappedValue"] as? String)
        XCTAssertGreaterThan(script.count, 1000, "the VM's interpreter JavaScript is inline")
        // JSON-serialisable, because that is how it reaches the page.
        XCTAssertTrue(JSONSerialization.isValidJSONObject(challenge))
    }

    func testPlainChallengeShapeIsAcceptedToo() throws {
        let plain = #"[["msg",["safe-script"],null,"hash","program","globalVm",null,"blob"]]"#
        let challenge = try PoTokenChallenge.parseChallengeData(Data(plain.utf8))
        XCTAssertEqual(challenge["messageId"] as? String, "msg")
        XCTAssertEqual(challenge["globalName"] as? String, "globalVm")
        let interpreter = try XCTUnwrap(challenge["interpreterJavascript"] as? [String: Any])
        XCTAssertEqual(interpreter["privateDoNotAccessOrElseSafeScriptWrappedValue"] as? String, "safe-script")
        XCTAssertTrue(interpreter["privateDoNotAccessOrElseTrustedResourceUrlWrappedValue"] is NSNull)
    }

    func testTruncatedChallengeIsAnError() {
        XCTAssertThrowsError(try PoTokenChallenge.parseChallengeData(Data(#"[["only","three","fields"]]"#.utf8)))
        XCTAssertThrowsError(try PoTokenChallenge.parseChallengeData(Data(#"{"not":"an array"}"#.utf8)))
    }

    func testIntegrityTokenAndLifetimeParse() throws {
        let raw = #"["AQID_-8.", 43200, 1, "x"]"#
        let (token, lifetime) = try PoTokenChallenge.parseIntegrityTokenData(Data(raw.utf8))
        XCTAssertEqual(token, [1, 2, 3, 255, 239])
        XCTAssertEqual(lifetime, 43200)
        XCTAssertThrowsError(try PoTokenChallenge.parseIntegrityTokenData(Data("[]".utf8)))
    }

    /// YouTube's variant: `-`/`_` alphabet, `.` padding; padding may also be missing.
    func testYouTubeBase64Decodes() throws {
        XCTAssertEqual(try PoTokenChallenge.base64Bytes("_-8."), [255, 239])
        XCTAssertEqual(try PoTokenChallenge.base64Bytes("_-8"), [255, 239])
        XCTAssertEqual(try PoTokenChallenge.base64Bytes("YWJj"), Array("abc".utf8))
        XCTAssertThrowsError(try PoTokenChallenge.base64Bytes("!!!"))
    }

    /// `Uint8Array` bytes back into the web-safe form with padding kept, as Android's `u8ToBase64`.
    func testMintedBytesBecomeWebSafeBase64() {
        XCTAssertEqual(PoTokenChallenge.tokenString(Array("abc".utf8)), "YWJj")
        XCTAssertEqual(PoTokenChallenge.tokenString([251, 255, 191]), "-_-_")
        XCTAssertEqual(PoTokenChallenge.tokenString([255]), "_w==")
        XCTAssertEqual(PoTokenChallenge.identifierBytes("dQw4w9WgXcQ"), Array("dQw4w9WgXcQ".utf8))
    }

    /// Only a syntax error in our own page means the engine is unusable for the session.
    func testJavaScriptErrorsClassifyLikeAndroid() {
        XCTAssertEqual(StreamPoTokenError.fromJavaScriptError("SyntaxError: Unexpected token"), .badWebView("SyntaxError: Unexpected token"))
        XCTAssertEqual(StreamPoTokenError.fromJavaScriptError("TypeError: x is undefined"), .failed("TypeError: x is undefined"))
    }

    /// The page is the Android asset, unchanged.
    func testEmbeddedPageDefinesTheThreeEntryPoints() {
        for name in ["function runBotGuard(", "async function createPoTokenMinter(", "async function obtainPoToken("] {
            XCTAssertTrue(PoTokenPage.html.contains(name), name)
        }
        XCTAssertTrue(PoTokenPage.html.hasPrefix("<!DOCTYPE html>"))
    }

    /// The timeout has to answer at its deadline even when the work ignores cancellation, as a web
    /// view's JavaScript call does. It used to wait for the work, so an 8 s budget lasted as long
    /// as the web view took, and forever when the call never came back.
    func testTimeoutHelperGivesUp() async {
        let hungCall = Latch()
        // Ends the hung call much later, so a regression fails this test instead of hanging it.
        let backstop = Task { try? await Task.sleep(nanoseconds: 30_000_000_000); hungCall.open() }
        do {
            _ = try await withStreamTimeout(0.1) { await hungCall.wait(); return 1 }
            XCTFail("expected a timeout")
        } catch {
            XCTAssertTrue(error is StreamTimeoutError)
        }
        XCTAssertFalse(hungCall.isOpen, "the timeout must answer while the call it gave up on is still hung")
        hungCall.open()
        backstop.cancel()
        let quick = try? await withStreamTimeout(5) { 42 }
        XCTAssertEqual(quick, 42)
    }

    /// Cancelling the waiting task answers at once with `CancellationError`, whether the cancel
    /// lands while the work hangs or before the wait has stored its continuation, and does not
    /// wait for work that ignores cancellation.
    func testCancellingTheWaiterThrowsCancellationAtOnce() async {
        for cancelBeforeItStarts in [false, true] {
            let hungCall = Latch()
            let backstop = Task { try? await Task.sleep(nanoseconds: 30_000_000_000); hungCall.open() }
            let started = ContinuousClock.now
            let waiter = Task { try await withStreamTimeout(30) { await hungCall.wait(); return 1 } }
            if !cancelBeforeItStarts { try? await Task.sleep(nanoseconds: 100_000_000) }
            waiter.cancel()
            do {
                _ = try await waiter.value
                XCTFail("expected a cancellation")
            } catch {
                XCTAssertTrue(error is CancellationError, "\(error)")
            }
            XCTAssertLessThan(started.duration(to: .now), .seconds(5), "the cancel waited for the hung call")
            XCTAssertFalse(hungCall.isOpen)
            hungCall.open()
            backstop.cancel()
        }
    }
}

/// Work that ignores cancellation and finishes only when opened.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isOpen: Bool { lock.withLock { opened } }

    func wait() async {
        await withCheckedContinuation { continuation in
            let openAlready = lock.withLock { () -> Bool in
                if !opened { waiters.append(continuation) }
                return opened
            }
            if openAlready { continuation.resume() }
        }
    }

    func open() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            opened = true
            defer { waiters = [] }
            return waiters
        }
        waiting.forEach { $0.resume() }
    }
}

/// The signed-in session's headers (Android's `sapisidFrom` / `sapisidHash`).
final class StreamAuthSessionTests: XCTestCase {
    func testSAPISIDIsFoundUnderAnyOfItsThreeNamesInOrder() {
        XCTAssertEqual(StreamAuthSession(cookie: "A=1; SAPISID=plain; __Secure-3PAPISID=third").sapisid, "plain")
        XCTAssertEqual(StreamAuthSession(cookie: "__Secure-1PAPISID=first; __Secure-3PAPISID=third").sapisid, "third")
        XCTAssertEqual(StreamAuthSession(cookie: "__Secure-1PAPISID=first").sapisid, "first")
        XCTAssertNil(StreamAuthSession(cookie: "SID=x; HSID=y").sapisid)
        XCTAssertNil(StreamAuthSession(cookie: "SAPISID=").sapisid, "an empty value signs nothing")
    }

    /// `SAPISIDHASH <ts>_<sha1("<ts> <sapisid> <origin>")>`.
    func testAuthorizationIsTheOriginScopedSHA1() {
        let session = StreamAuthSession(cookie: "SAPISID=abc123")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            session.authorization(origin: "https://music.youtube.com", now: now),
            "SAPISIDHASH 1700000000_\(Self.sha1Hex("1700000000 abc123 https://music.youtube.com"))"
        )
        XCTAssertNil(StreamAuthSession(cookie: "SID=x").authorization(origin: "https://music.youtube.com"))
    }

    func testHeadersNameTheAccountAndTheBrandChannel() {
        let session = StreamAuthSession(cookie: "SAPISID=abc", authUser: "2", pageId: "1234")
        let headers = session.headers(origin: "https://music.youtube.com", now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(headers["Cookie"], "SAPISID=abc")
        XCTAssertEqual(headers["X-Goog-AuthUser"], "2")
        XCTAssertEqual(headers["X-Goog-PageId"], "1234")
        XCTAssertTrue(headers["Authorization"]?.hasPrefix("SAPISIDHASH 1_") == true)
        XCTAssertNil(StreamAuthSession(cookie: "SAPISID=abc").headers(origin: "o")["X-Goog-PageId"])
    }

    func testReferenceSHA1MatchesTheStandardVector() {
        XCTAssertEqual(Self.sha1Hex("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
    }

    private static func sha1Hex(_ text: String) -> String { SHA1Reference.hex(Array(text.utf8)) }
}

/// A tiny reference SHA-1 so the SAPISIDHASH test does not check CryptoKit against itself.
enum SHA1Reference {
    static func hex(_ message: [UInt8]) -> String {
        var h0: UInt32 = 0x67452301, h1: UInt32 = 0xEFCDAB89, h2: UInt32 = 0x98BADCFE, h3: UInt32 = 0x10325476, h4: UInt32 = 0xC3D2E1F0
        var data = message
        let bitLength = UInt64(message.count) * 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }
        for chunk in stride(from: 0, to: data.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0..<16 {
                w[i] = data[chunk + i * 4..<chunk + i * 4 + 4].reduce(0) { $0 << 8 | UInt32($1) }
            }
            for i in 16..<80 {
                let x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
                w[i] = x << 1 | x >> 31
            }
            var a = h0, b = h1, c = h2, d = h3, e = h4
            for i in 0..<80 {
                let (f, k): (UInt32, UInt32)
                switch i {
                case 0..<20: (f, k) = ((b & c) | (~b & d), 0x5A827999)
                case 20..<40: (f, k) = (b ^ c ^ d, 0x6ED9EBA1)
                case 40..<60: (f, k) = ((b & c) | (b & d) | (c & d), 0x8F1BBCDC)
                default: (f, k) = (b ^ c ^ d, 0xCA62C1D6)
                }
                let temp = (a << 5 | a >> 27) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = b << 30 | b >> 2; b = a; a = temp
            }
            h0 = h0 &+ a; h1 = h1 &+ b; h2 = h2 &+ c; h3 = h3 &+ d; h4 = h4 &+ e
        }
        return [h0, h1, h2, h3, h4].map { String(format: "%08x", $0) }.joined()
    }
}
