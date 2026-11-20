import XCTest
@testable import Automix

/// Port of VersionAudioAlignerCorrelationTest.kt.
///
/// ``VersionAudioAligner/crossCorrelate(_:_:hopMs:maxLagSeconds:)`` runs the per-lag sums through
/// an FFT instead of the double loop it replaced. These tests pin the two implementations together:
/// same searchable range, same winning lag, same confidence — a silent sign flip or wraparound here
/// would turn every switch into a misaligned one.
final class VersionAlignmentCorrelationTests: XCTestCase {

    func testFFTCorrelationMatchesBruteForceOverManyRandomEnvelopes() {
        var random = SyntheticAudio.Random(seed: 42)
        for testCase in 0..<40 {
            let sourceSize = 320 + random.int(in: 0...599)
            let targetSize = 320 + random.int(in: 0...599)
            let source = (0..<sourceSize).map { _ in random.float() }
            // Shift the target by a known lag and add noise, so the peak lands somewhere plausible
            // but not trivially at zero.
            let trueLag = random.int(in: -150...150)
            let target: [Float] = (0..<targetSize).map { index in
                let sourceIndex = index - trueLag
                let base = source.indices.contains(sourceIndex) ? source[sourceIndex] : random.float()
                return min(max(base + random.float() * 0.2, 0), 1)
            }

            let fft = VersionAudioAligner.crossCorrelate(source, target)
            let brute = bruteForce(source, target)

            XCTAssertEqual(fft.floor, brute.floor, "floor differs in case \(testCase)")
            XCTAssertEqual(fft.ceiling, brute.ceiling, "ceiling differs in case \(testCase)")
            XCTAssertEqual(fft.lagFrames, brute.lagFrames, "best lag differs in case \(testCase)")
            XCTAssertEqual(fft.confidence, brute.confidence, accuracy: 1e-6, "confidence differs in case \(testCase)")
        }
    }

    func testCorrelationFindsAPlantedLagWithHighConfidence() {
        var random = SyntheticAudio.Random(seed: 7)
        let source = (0..<900).map { _ in random.float() }
        let trueLag = 286 // 28.6 s at 100 fps — the field case's shape
        let target: [Float] = (0..<900).map { index in
            let sourceIndex = index - trueLag
            return source.indices.contains(sourceIndex) ? source[sourceIndex] : random.float() * 0.3
        }

        let result = VersionAudioAligner.crossCorrelate(source, target)

        XCTAssertEqual(result.lagFrames, trueLag)
        XCTAssertGreaterThan(result.confidence, 0.9, "expected a confident peak")
        XCTAssertNotEqual(result.lagFrames, result.floor, "peak must not be pinned to the searchable edge")
        XCTAssertNotEqual(result.lagFrames, result.ceiling, "peak must not be pinned to the searchable edge")
    }

    func testNegativeLagMeansTheTargetStartsEarlier() {
        var random = SyntheticAudio.Random(seed: 11)
        let target = (0..<800).map { _ in random.float() }
        let source: [Float] = (0..<800).map { index in
            let targetIndex = index - 120
            return target.indices.contains(targetIndex) ? target[targetIndex] : random.float() * 0.3
        }

        XCTAssertEqual(VersionAudioAligner.crossCorrelate(source, target).lagFrames, -120)
    }

    func testEmptyEnvelopesYieldNoMeasurableCorrelation() {
        let result = VersionAudioAligner.crossCorrelate([], [Float](repeating: 0.5, count: 500))
        XCTAssertEqual(result.lagFrames, 0)
        XCTAssertEqual(result.confidence, 0)
    }

    func testEnvelopesShorterThanTheMinimumOverlapSearchNothing() {
        // Under three seconds of envelope each: no lag has enough overlap to score.
        let result = VersionAudioAligner.crossCorrelate([Float](repeating: 0.2, count: 100), [Float](repeating: 0.3, count: 100))
        XCTAssertEqual(result.confidence, -1, "nothing was scored, so the sentinel survives")
        XCTAssertLessThan(result.confidence, VersionAudioAligner.minConfidence, "and it can never pass for a measurement")
    }

    /// The pre-FFT implementation, verbatim, as the reference oracle.
    private func bruteForce(
        _ sourceEnv: [Float],
        _ targetEnv: [Float],
        hopMs: Double = 10,
        maxLagSec: Double = 40
    ) -> VersionAudioAligner.Correlation {
        if sourceEnv.isEmpty || targetEnv.isEmpty {
            return VersionAudioAligner.Correlation(lagFrames: 0, confidence: 0, floor: 0, ceiling: 0)
        }
        let maxLagFrames = Int(maxLagSec * 1000 / hopMs)
        let minOverlapFrames = Int(3.0 * 1000 / hopMs)

        var bestLag = 0
        var bestCorrelation = -1.0
        let minLag = max(-maxLagFrames, -(sourceEnv.count - minOverlapFrames))
        let maxLag = min(maxLagFrames, targetEnv.count - minOverlapFrames)

        for lag in minLag...maxLag {
            let srcStart = max(0, -lag)
            let tgtStart = max(0, lag)
            let overlapLen = min(sourceEnv.count - srcStart, targetEnv.count - tgtStart)
            if overlapLen < minOverlapFrames { continue }

            var sumSrc = 0.0
            var sumTgt = 0.0
            for k in 0..<overlapLen {
                sumSrc += Double(sourceEnv[srcStart + k])
                sumTgt += Double(targetEnv[tgtStart + k])
            }
            let meanSrc = sumSrc / Double(overlapLen)
            let meanTgt = sumTgt / Double(overlapLen)

            var num = 0.0
            var denSrc = 0.0
            var denTgt = 0.0
            for k in 0..<overlapLen {
                let diffSrc = Double(sourceEnv[srcStart + k]) - meanSrc
                let diffTgt = Double(targetEnv[tgtStart + k]) - meanTgt
                num += diffSrc * diffTgt
                denSrc += diffSrc * diffSrc
                denTgt += diffTgt * diffTgt
            }
            let denom = (denSrc * denTgt).squareRoot()
            if denom > 1e-6 {
                let r = num / denom
                if r > bestCorrelation {
                    bestCorrelation = r
                    bestLag = lag
                }
            }
        }
        return VersionAudioAligner.Correlation(lagFrames: bestLag, confidence: bestCorrelation, floor: minLag, ceiling: maxLag)
    }
}
