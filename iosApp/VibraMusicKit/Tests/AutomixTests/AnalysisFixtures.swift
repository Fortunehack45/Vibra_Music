import Foundation
@testable import Automix

/// Builds analyses the way the analyzer shapes them, without running it: a steady grid, eight-bar
/// phrases, a one-second energy curve and a vocal mask parallel to it.
enum AnalysisFixtures {

    static func track(
        id: String = "track",
        bpm: Double = 124,
        confidence: Double = 0.9,
        duration: Double = 210,
        firstBeat: Double = 0.5,
        key: String = "A minor",
        keyConfidence: Double = 0.6,
        contentEnd: Double? = nil,
        audibleStart: Double? = nil,
        mixIn: [MixCandidate]? = nil,
        mixOut: [MixCandidate]? = nil,
        energy: ((Double) -> Double)? = nil,
        lowEnergy: ((Double) -> Double)? = nil,
        vocal: ((Double) -> Double)? = nil,
        vocalProbability: Double = 0.3
    ) -> TrackAnalysis {
        let beat = 60 / bpm
        let end = contentEnd ?? duration
        var downbeats: [Double] = []
        var time = firstBeat
        while time < end {
            downbeats.append(time)
            time += beat * 4
        }
        var phrases: [Double] = []
        time = firstBeat
        while time < end {
            phrases.append(time)
            time += beat * 32
        }
        phrases.append(end)

        let curveTimes = stride(from: 0.0, through: duration, by: 1.0).map { $0 }
        let energyCurve = curveTimes.map { t in
            EnergySample(time: t, energy: energy?(t) ?? (t < end ? 1.0 : 0.0))
        }
        let lowCurve = lowEnergy.map { function in curveTimes.map { EnergySample(time: $0, energy: function($0)) } } ?? []
        let mask = vocal.map { function in curveTimes.map(function) } ?? []

        let start = audibleStart ?? firstBeat
        let introDrop = firstBeat + beat * 32
        return TrackAnalysis(
            status: TrackAnalysis.statusReady,
            trackId: id,
            duration: duration,
            bpm: bpm,
            beatInterval: beat,
            beatConfidence: confidence,
            downbeats: downbeats,
            phraseBoundaries: phrases,
            firstBeat: firstBeat,
            key: key,
            keyConfidence: keyConfidence,
            audibleStartTime: start,
            pickupTime: start,
            introEndTime: introDrop,
            contentEndTime: end,
            outroStartTime: end - beat * 32,
            mixInTime: introDrop,
            mixOutTime: end,
            mixInCandidates: mixIn ?? [
                MixCandidate(time: start, score: 0.8, type: "pickup"),
                MixCandidate(time: introDrop, score: 0.9, type: "intro_drop"),
            ],
            mixOutCandidates: mixOut ?? [
                MixCandidate(time: end - beat * 32, score: 0.9, type: "outro_start"),
                MixCandidate(time: end, score: 0.75, type: "content_end"),
            ],
            energyCurve: energyCurve,
            lowEnergyCurve: lowCurve,
            vocalActivityMask: mask,
            vocalProbability: vocalProbability
        )
    }

    static func info(_ analysis: TrackAnalysis, title: String = "Song", artist: String = "Artist", album: String = "", albumId: String = "") -> TransitionTrackInfo {
        TransitionTrackInfo(
            id: analysis.trackId,
            durationMs: Int64(analysis.duration * 1000),
            title: title,
            artist: artist,
            album: album,
            albumId: albumId
        )
    }
}
