import XCTest
@testable import ListenTogether

/// Ports the server-routing halves of `JamInviteLinkTest`: URL validation, probe order,
/// health resolution, switch-target resolution, and fallback eligibility — against the
/// pure functions, with no network.
final class PartyServerConfigTests: XCTestCase {
    private let defaultServer = "https://default.example.com"

    // MARK: URL validation matrix

    func testValidInputs() {
        func assertValid(_ input: String, _ expected: String, line: UInt = #line) {
            XCTAssertEqual(
                .valid(normalizedUrl: expected),
                PartyServerConfig.parseAndNormalizeServerUrl(input),
                "input '\(input)'", line: line)
        }
        assertValid("", "")
        assertValid("  ", "")
        assertValid(" my-server.com ", "https://my-server.com")
        assertValid("https://my-server.com/", "https://my-server.com")
        assertValid("https://my-server.com///", "https://my-server.com")
        assertValid("HTTP://my-server.com", "http://my-server.com")
        assertValid("HTTP://LOCALHOST:8080", "http://localhost:8080")
        assertValid("HTTPS://EXAMPLE.COM", "https://example.com")
        assertValid("http://localhost", "http://localhost")
        assertValid("http://127.0.0.1:8080", "http://127.0.0.1:8080")
        assertValid("http://[::1]", "http://[::1]")
        assertValid("http://[::1]:8080", "http://[::1]:8080")
        assertValid("HTTP://[2001:DB8::1]:8080", "http://[2001:db8::1]:8080")
        assertValid("https://example.com/path", "https://example.com/path")
        assertValid("https://example.com//path", "https://example.com/path")
        assertValid("https://example.com/path/to/party/", "https://example.com/path/to/party")
        assertValid("example.com/custom/subpath", "https://example.com/custom/subpath")
        assertValid("http://192.168.1.50:8080/nested/path/", "http://192.168.1.50:8080/nested/path")
        assertValid("https://[::1]:8080/subpath", "https://[::1]:8080/subpath")
        // Escapes stay escaped: decoded, `%20` became a space the next parse rejects.
        assertValid("https://example.com/my%20server", "https://example.com/my%20server")
    }

    /// `PartyClient.setCustomServerUrl` takes only an address this function returns unchanged.
    /// One it didn't (a percent-encoded path) trapped there, from a user's typing.
    func testANormalizedAddressNormalizesToItself() {
        for input in ["https://example.com/my%20server", "example.com/a%3Fb", "https://example.com/caf%C3%A9/x/",
                      "HTTP://[2001:DB8::1]:8080", "http://192.168.1.50:8080/nested/path/"] {
            guard case .valid(let normalized) = PartyServerConfig.parseAndNormalizeServerUrl(input) else {
                XCTFail("'\(input)' should be valid")
                continue
            }
            XCTAssertEqual(.valid(normalizedUrl: normalized), PartyServerConfig.parseAndNormalizeServerUrl(normalized), "input '\(input)'")
        }
    }

    func testInvalidInputs() {
        func assertInvalid(_ input: String, _ error: PartyServerURLError, line: UInt = #line) {
            XCTAssertEqual(
                .invalid(error),
                PartyServerConfig.parseAndNormalizeServerUrl(input),
                "input '\(input)'", line: line)
        }
        assertInvalid("http://foo bar.com", .whitespace)
        assertInvalid("random shit", .whitespace)
        assertInvalid("https://example.com/../etc", .invalidPath)
        assertInvalid("https://example.com/path/./sub", .invalidPath)
        assertInvalid("https://example.com/path/../sub", .invalidPath)
        assertInvalid("https://example.com/foo/..%2Fbar", .invalidPath)
        assertInvalid("https://example.com?foo=bar", .hasQuery)
        assertInvalid("https://example.com#anchor", .hasFragment)
        assertInvalid("https://", .invalidHost)
        assertInvalid("http://.", .invalidHost)
        assertInvalid("http://foo_bar.com", .invalidHost)
        assertInvalid("https://-example.com", .invalidHost)
        assertInvalid("https://example-.com", .invalidHost)
        assertInvalid("https://foo.-bar.com", .invalidHost)
        assertInvalid("https://foo..com", .invalidHost)
        assertInvalid("https://.foo.com", .invalidHost)
        assertInvalid("https://foo.com.", .invalidHost)
        assertInvalid("randomshit", .invalidHost)
        assertInvalid("example", .invalidHost)
        assertInvalid("http://localhost:99999", .invalidPort)
    }

    // MARK: Probe order invariants

    func testCustomSucceedsSkipsDefaultProbe() async {
        var defaultProbed = false
        let (effective, state) = await PartyServerConfig.resolveServerConnection(
            customServer: "https://healthy-custom.example.com",
            defaultServer: defaultServer,
            probeCustom: { PartyProbeResult(isOnline: true, latencyMs: 42) },
            probeDefault: {
                defaultProbed = true
                return PartyProbeResult(isOnline: true, latencyMs: 99)
            })
        XCTAssertFalse(defaultProbed, "Default server must NEVER be probed when custom succeeds")
        XCTAssertEqual("https://healthy-custom.example.com", effective)
        XCTAssertEqual(.customOnline(latencyMs: 42), state)
        XCTAssertEqual(42, state.latencyMs)
        XCTAssertFalse(state.isFallback)
        XCTAssertEqual(.online, state.health)
    }

    func testCustomFailsProbesDefaultExactlyOnce() async {
        var defaultProbeCount = 0
        let (effective, state) = await PartyServerConfig.resolveServerConnection(
            customServer: "https://failing-custom.example.com",
            defaultServer: defaultServer,
            probeCustom: { PartyProbeResult(isOnline: false) },
            probeDefault: {
                defaultProbeCount += 1
                return PartyProbeResult(isOnline: true, latencyMs: 115)
            })
        XCTAssertEqual(1, defaultProbeCount)
        XCTAssertEqual(defaultServer, effective)
        XCTAssertEqual(.customFallback(latencyMs: 115), state)
        XCTAssertEqual(115, state.latencyMs)
        XCTAssertTrue(state.isFallback)
        XCTAssertEqual(.online, state.health)
    }

    func testCustomEqualToDefaultProbesOnce() async {
        var customProbeCount = 0
        var defaultProbeCount = 0
        let (effective, state) = await PartyServerConfig.resolveServerConnection(
            customServer: defaultServer,
            defaultServer: defaultServer,
            probeCustom: {
                customProbeCount += 1
                return PartyProbeResult(isOnline: true, latencyMs: 50)
            },
            probeDefault: {
                defaultProbeCount += 1
                return PartyProbeResult(isOnline: true, latencyMs: 50)
            })
        XCTAssertEqual(0, customProbeCount)
        XCTAssertEqual(1, defaultProbeCount)
        XCTAssertEqual(defaultServer, effective)
        XCTAssertEqual(.defaultOnline(latencyMs: 50), state)
        XCTAssertFalse(state.isFallback)
    }

    func testBothOfflineReportsOffline() async {
        let (effective, state) = await PartyServerConfig.resolveServerConnection(
            customServer: "https://dead-custom.example.com",
            defaultServer: defaultServer,
            probeCustom: { PartyProbeResult(isOnline: false) },
            probeDefault: { PartyProbeResult(isOnline: false) })
        XCTAssertEqual(defaultServer, effective)
        XCTAssertEqual(.offline, state)
        XCTAssertNil(state.latencyMs)
        XCTAssertFalse(state.isFallback)
        XCTAssertEqual(.offline, state.health)
    }

    // MARK: Health resolution

    func testFallbackPreservesCustomPreference() async {
        let resolution = await PartyServerConfig.computeHealthResolution(
            customServer: "https://user-custom.example.com",
            defaultServer: defaultServer,
            probeCustom: { false },
            probeDefault: { true })
        XCTAssertEqual(defaultServer, resolution.resolvedServer)
        XCTAssertEqual(.online, resolution.health)
        XCTAssertTrue(resolution.isFallback)
    }

    func testCustomRecoveryRegainsPriority() async {
        let resolution = await PartyServerConfig.computeHealthResolution(
            customServer: "https://recovering-custom.example.com",
            defaultServer: defaultServer,
            probeCustom: { true },
            probeDefault: { true })
        XCTAssertEqual("https://recovering-custom.example.com", resolution.resolvedServer)
        XCTAssertEqual(.online, resolution.health)
        XCTAssertFalse(resolution.isFallback)
    }

    func testHealthyCustomSkipsDefaultProbe() async {
        var defaultProbed = false
        let resolution = await PartyServerConfig.computeHealthResolution(
            customServer: "https://working-custom.example.com",
            defaultServer: defaultServer,
            probeCustom: { true },
            probeDefault: {
                defaultProbed = true
                return false
            })
        XCTAssertEqual("https://working-custom.example.com", resolution.resolvedServer)
        XCTAssertEqual(.online, resolution.health)
        XCTAssertFalse(resolution.isFallback)
        XCTAssertFalse(defaultProbed)
    }

    func testNoCustomDefaultDownIsOffline() async {
        let resolution = await PartyServerConfig.computeHealthResolution(
            customServer: "",
            defaultServer: defaultServer,
            probeCustom: { true },
            probeDefault: { false })
        XCTAssertEqual(defaultServer, resolution.resolvedServer)
        XCTAssertEqual(.offline, resolution.health)
        XCTAssertFalse(resolution.isFallback)
    }

    // MARK: Switch target

    func testSwitchTargetResolvesBlankCustomToIdleFallback() {
        // A typed code entered while already live used to hand the raw "" custom preference
        // to the switch and be refused as an invalid target.
        XCTAssertEqual(
            defaultServer,
            PartyServerConfig.resolveSwitchTarget(
                inviteServer: nil, customServer: "", idleServer: defaultServer))
        XCTAssertEqual(
            "https://user-custom.example.com",
            PartyServerConfig.resolveSwitchTarget(
                inviteServer: nil, customServer: "https://user-custom.example.com",
                idleServer: defaultServer))
        XCTAssertEqual(
            "https://invite-target.example.com",
            PartyServerConfig.resolveSwitchTarget(
                inviteServer: "https://invite-target.example.com",
                customServer: "https://user-custom.example.com",
                idleServer: defaultServer))
    }

    // MARK: Fallback eligibility

    func testFallbackErrorClassification() {
        XCTAssertTrue(PartyServerConfig.isEligibleForFallback(
            statusCode: nil, transportError: URLError(.cannotFindHost)))
        XCTAssertTrue(PartyServerConfig.isEligibleForFallback(
            statusCode: nil, transportError: URLError(.cannotConnectToHost)))
        XCTAssertTrue(PartyServerConfig.isEligibleForFallback(
            statusCode: nil, transportError: URLError(.timedOut)))
        XCTAssertTrue(PartyServerConfig.isEligibleForFallback(statusCode: 500))
        XCTAssertTrue(PartyServerConfig.isEligibleForFallback(statusCode: 502))
        XCTAssertTrue(PartyServerConfig.isEligibleForFallback(statusCode: 504))
        let wrapped = NSError(
            domain: NSCocoaErrorDomain, code: 0,
            userInfo: [NSUnderlyingErrorKey: URLError(.cannotConnectToHost)])
        XCTAssertTrue(PartyServerConfig.isEligibleForFallback(statusCode: nil, transportError: wrapped))

        XCTAssertFalse(PartyServerConfig.isEligibleForFallback(statusCode: 409))
        XCTAssertFalse(PartyServerConfig.isEligibleForFallback(statusCode: 404))
        XCTAssertFalse(PartyServerConfig.isEligibleForFallback(statusCode: 400))
        XCTAssertFalse(PartyServerConfig.isEligibleForFallback(statusCode: 401))
        XCTAssertFalse(PartyServerConfig.isEligibleForFallback(statusCode: 422))
        XCTAssertFalse(PartyServerConfig.isEligibleForFallback(
            statusCode: nil, transportError: NSError(domain: "local", code: 1)))
        XCTAssertFalse(PartyServerConfig.isEligibleForFallback(statusCode: nil))
    }

    // MARK: Base resolution

    func testHttpAndWsBases() {
        XCTAssertEqual(
            "https://example.com",
            PartyServerConfig.resolveHttpBase("example.com", defaultServer: defaultServer))
        XCTAssertEqual(
            "http://localhost:8080",
            PartyServerConfig.resolveHttpBase("http://localhost:8080", defaultServer: defaultServer))
        XCTAssertEqual(
            defaultServer,
            PartyServerConfig.resolveHttpBase("", defaultServer: defaultServer))
        XCTAssertEqual(
            "wss://example.com",
            PartyServerConfig.wsBase(httpBase: "https://example.com"))
        XCTAssertEqual(
            "ws://localhost:8080",
            PartyServerConfig.wsBase(httpBase: "http://localhost:8080"))
    }
}
