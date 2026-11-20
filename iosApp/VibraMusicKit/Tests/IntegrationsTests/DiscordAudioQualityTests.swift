import VibraMusicCore
import XCTest
@testable import Integrations

/// Port of `DiscordAudioQualityTest.kt`: the Discord quality line reflects
/// *measured* decoder figures, and ordinary lossy audio earns no line.
final class DiscordAudioQualityTests: XCTestCase {
    func testHiResLineContainsMeasuredSpecsSeparatedByCenterDots() {
        let stats = DiscordAudioSnapshot(
            mimeType: "audio/flac", bitrateKbps: 4608, sampleRateHz: 96_000, channels: 2, bitDepth: 24
        )
        XCTAssertEqual(
            discordAudioQualityLine(stats),
            "Hi-Res Lossless · FLAC · 4608 kbps · 24-bit · 96 kHz · Stereo"
        )
    }

    func testCDQualityLosslessLineKeepsKnownSpecsOnly() {
        let stats = DiscordAudioSnapshot(
            mimeType: "audio/alac", bitrateKbps: 1411, sampleRateHz: 44_100, channels: nil, bitDepth: 16
        )
        XCTAssertEqual(
            discordAudioQualityLine(stats),
            "Lossless · ALAC · 1411 kbps · 16-bit · 44.1 kHz"
        )
    }

    func testDolbyLineIncludesImmersiveCodecAndChannels() {
        let stats = DiscordAudioSnapshot(
            mimeType: "audio/eac3-joc", bitrateKbps: 768, sampleRateHz: 48_000, channels: 6
        )
        XCTAssertEqual(
            discordAudioQualityLine(stats),
            "◗◖ Dolby Atmos · E-AC-3 JOC · 768 kbps · 48 kHz · 6 ch"
        )
    }

    func testOrdinaryLossyAudioHasNoQualityLine() {
        let stats = DiscordAudioSnapshot(
            mimeType: "audio/opus", bitrateKbps: 160, sampleRateHz: 48_000, channels: 2
        )
        XCTAssertNil(discordAudioQualityLine(stats))
        XCTAssertNil(discordAudioQualityLine(nil))
    }

    func testFullLosslessLineStaysWithinDiscordLimit() {
        // The richest realistic snapshot still fits the 128-character field cap.
        let stats = DiscordAudioSnapshot(
            mimeType: "audio/flac", bitrateKbps: 9_216, sampleRateHz: 192_000, channels: 6, bitDepth: 32
        )
        let line = discordAudioQualityLine(stats)
        XCTAssertEqual(line, "Hi-Res Lossless · FLAC · 9216 kbps · 32-bit · 192 kHz · 6 ch")
        XCTAssertLessThanOrEqual(line?.count ?? 0, discordTextLimit)
    }

    func testCodecFallbackLabel() {
        XCTAssertEqual(discordCodecLabel("audio/x-custom"), "X-CUSTOM")
        XCTAssertNil(discordCodecLabel(nil))
    }
}

/// Port of `PrimaryArtistTest.kt`. The splitter itself lives in
/// `VibraMusicCore.ArtistCredit` (shared vocabulary); these tests pin the
/// scrobbling contract — joint credits reduce to the first artist, plain
/// names (including `AC/DC`) pass through — from this module's side.
final class PrimaryArtistTests: XCTestCase {
    func testTakesFirstArtistFromCommonCollaborationCredits() {
        XCTAssertEqual(ArtistCredit.primary(of: "Anitta & Shakira"), "Anitta")
        XCTAssertEqual(ArtistCredit.primary(of: "Anitta, Shakira"), "Anitta")
    }

    func testLeavesSingleArtistUnchanged() {
        XCTAssertEqual(ArtistCredit.primary(of: "AC/DC"), "AC/DC")
        XCTAssertEqual(ArtistCredit.primary(of: "Florence and the Machine"), "Florence and the Machine")
    }
}
