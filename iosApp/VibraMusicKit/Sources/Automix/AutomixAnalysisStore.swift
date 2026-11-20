/*
 * Copyright (C) 2026 Kushagra Singh
 *
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation, either version 3 of the License, or (at your
 * option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
 * Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation
import os

/// Analysis results kept on disk, so a track is measured once and stays measured.
///
/// ## Why this exists
///
/// In memory only, every app start threw away everything and every track had to earn its result
/// again — from audio that may no longer be on disk to earn it from, at the cost of a decode plus
/// two model inferences that have to finish *before* the transition that wants them. Neither
/// applies to a result already computed. The audio is a means to the numbers, and the numbers are
/// small.
///
/// ## Shape
///
/// One JSON file per track in an injectable directory, named by track id rather than written into
/// a single index, so a write cannot corrupt anything but its own entry and a prune is a file
/// delete. Coordinates are seconds on the track's own timeline, identical across renditions of the
/// same recording. Only fields the planner reads are stored, and the curves are rounded to
/// milliseconds: they are the bulk of the payload and nothing downstream can tell the difference.
public final class AutomixAnalysisStore: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.fortune.vibramusic.ios", category: "Automix")

    /// Bump whenever a stored number starts being computed differently. Entries from an older
    /// schema are ignored rather than migrated: a re-analysis costs seconds, and a beat grid
    /// interpreted under the wrong assumptions is silently wrong for the life of the file.
    static let schemaVersion = 1

    /// A few thousand tracks' worth, at tens of kilobytes each.
    static let defaultMaxEntries = 2_000

    /// `Application Support/smart_analysis`, the iOS counterpart of Android's `filesDir/smart_analysis`.
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("smart_analysis", isDirectory: true)
    }

    public let directory: URL
    private let maxEntries: Int
    private let lock = NSLock()

    /// Track ids known to have no file, so a track analysed in neither this session nor a previous
    /// one does not hit the filesystem on every tick. A write clears the entry.
    private var known: [String: Bool] = [:]

    public init(directory: URL = AutomixAnalysisStore.defaultDirectory) {
        self.directory = directory
        self.maxEntries = Self.defaultMaxEntries
    }

    init(directory: URL, maxEntries: Int) {
        self.directory = directory
        self.maxEntries = maxEntries
    }

    /// Reads `trackId`'s stored analysis, or nil when there isn't one.
    public func load(_ trackId: String) -> TrackAnalysis? {
        if trackId.isBlank { return nil }
        lock.lock()
        let knownAbsent = known[trackId] == false
        lock.unlock()
        if knownAbsent { return nil }

        let file = fileURL(for: trackId)
        guard FileManager.default.fileExists(atPath: file.path) else {
            setKnown(trackId, false)
            return nil
        }
        do {
            let stored = try JSONDecoder().decode(Stored.self, from: Data(contentsOf: file))
            // An entry from an older build may hold numbers computed a different way, and a wrong
            // beat grid is worse than none — so it is dropped and re-earned rather than migrated.
            guard stored.version == Self.schemaVersion else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "schema \(stored.version)"])
            }
            return stored.toAnalysis(trackId: trackId)
        } catch {
            // A half-written or outdated file is worth exactly nothing and costs a re-analysis to
            // replace, so it goes rather than being returned as a partly-filled result.
            Self.logger.warning("Discarding unreadable analysis for \(trackId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: file)
            setKnown(trackId, false)
            return nil
        }
    }

    /// Stores `analysis`. Silently does nothing for a result with no usable tempo: a failure is
    /// cheap to rediscover and worth rediscovering, since the reason for it is usually missing
    /// bytes rather than the track itself.
    public func save(_ trackId: String, _ analysis: TrackAnalysis) {
        if trackId.isBlank || !analysis.isUsable { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Stored(analysis))
            // Written aside and renamed, so a kill mid-write leaves the old entry rather than a
            // truncated one.
            try data.write(to: fileURL(for: trackId), options: .atomic)
            setKnown(trackId, true)
        } catch {
            Self.logger.warning("Could not store analysis for \(trackId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        prune()
    }

    /// Keeps the directory under the entry cap, oldest first.
    private func prune() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ), files.count > maxEntries else { return }
        let dated = files.map { file -> (URL, Date) in
            let modified = (try? file.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return (file, modified)
        }
        for (file, _) in dated.stableSorted(by: { $0.1 < $1.1 }).prefix(files.count - maxEntries) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func setKnown(_ trackId: String, _ present: Bool) {
        lock.lock()
        known[trackId] = present
        lock.unlock()
    }

    /// Hashed rather than used raw: a track id is not guaranteed to be a legal filename. The same
    /// name Android gives it (Java's `String.hashCode` as unsigned, then the UTF-16 length), so the
    /// scheme is deterministic across launches, which Swift's own seeded `hashValue` is not.
    func fileURL(for trackId: String) -> URL {
        directory.appendingPathComponent(Self.fileName(for: trackId))
    }

    static func fileName(for trackId: String) -> String {
        var hash: Int32 = 0
        for unit in trackId.utf16 { hash = hash &* 31 &+ Int32(unit) }
        return "\(UInt32(bitPattern: hash))_\(trackId.utf16.count).json"
    }

    /// Milliseconds is finer than anything downstream distinguishes.
    static func round(_ value: Double) -> Double {
        value.isFinite ? (value * 1000).rounded() / 1000 : 0
    }

    /// The persisted subset, kept separate from ``TrackAnalysis`` so that adding a field to the
    /// in-memory type is not silently a schema change. Missing keys read as their defaults and
    /// unknown keys are ignored; ``version`` is compared explicitly.
    struct Stored: Codable, Equatable {
        var version = AutomixAnalysisStore.schemaVersion
        var duration = 0.0
        var bpm = 0.0
        var beatInterval = 0.0
        var beatConfidence = 0.0
        var firstBeat = 0.0
        var downbeats: [Double] = []
        var phraseBoundaries: [Double] = []
        var key = ""
        var keyConfidence = 0.0
        var audibleStartTime: Double?
        var pickupTime: Double?
        var introEndTime = 0.0
        var outroStartTime = 0.0
        var contentEndTime = 0.0
        var mixInTime = 0.0
        var mixOutTime = 0.0
        var mixInCandidates: [StoredCue] = []
        var mixOutCandidates: [StoredCue] = []
        var energyCurve: [StoredEnergy] = []
        var lowEnergyCurve: [StoredEnergy] = []
        var vocalActivityMask: [Double] = []
        var vocalProbability = 0.0

        init(_ analysis: TrackAnalysis) {
            duration = analysis.duration
            bpm = analysis.bpm
            beatInterval = analysis.beatInterval
            beatConfidence = analysis.beatConfidence
            firstBeat = analysis.firstBeat
            downbeats = analysis.downbeats.map(AutomixAnalysisStore.round)
            phraseBoundaries = analysis.phraseBoundaries.map(AutomixAnalysisStore.round)
            key = analysis.key
            keyConfidence = analysis.keyConfidence
            audibleStartTime = analysis.audibleStartTime
            pickupTime = analysis.pickupTime
            introEndTime = analysis.introEndTime
            outroStartTime = analysis.outroStartTime
            contentEndTime = analysis.contentEndTime
            mixInTime = analysis.mixInTime
            mixOutTime = analysis.mixOutTime
            mixInCandidates = analysis.mixInCandidates.map(StoredCue.init)
            mixOutCandidates = analysis.mixOutCandidates.map(StoredCue.init)
            energyCurve = analysis.energyCurve.map(StoredEnergy.init)
            lowEnergyCurve = analysis.lowEnergyCurve.map(StoredEnergy.init)
            vocalActivityMask = analysis.vocalActivityMask.map(AutomixAnalysisStore.round)
            vocalProbability = analysis.vocalProbability
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? AutomixAnalysisStore.schemaVersion
            duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
            bpm = try c.decodeIfPresent(Double.self, forKey: .bpm) ?? 0
            beatInterval = try c.decodeIfPresent(Double.self, forKey: .beatInterval) ?? 0
            beatConfidence = try c.decodeIfPresent(Double.self, forKey: .beatConfidence) ?? 0
            firstBeat = try c.decodeIfPresent(Double.self, forKey: .firstBeat) ?? 0
            downbeats = try c.decodeIfPresent([Double].self, forKey: .downbeats) ?? []
            phraseBoundaries = try c.decodeIfPresent([Double].self, forKey: .phraseBoundaries) ?? []
            key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
            keyConfidence = try c.decodeIfPresent(Double.self, forKey: .keyConfidence) ?? 0
            audibleStartTime = try c.decodeIfPresent(Double.self, forKey: .audibleStartTime)
            pickupTime = try c.decodeIfPresent(Double.self, forKey: .pickupTime)
            introEndTime = try c.decodeIfPresent(Double.self, forKey: .introEndTime) ?? 0
            outroStartTime = try c.decodeIfPresent(Double.self, forKey: .outroStartTime) ?? 0
            contentEndTime = try c.decodeIfPresent(Double.self, forKey: .contentEndTime) ?? 0
            mixInTime = try c.decodeIfPresent(Double.self, forKey: .mixInTime) ?? 0
            mixOutTime = try c.decodeIfPresent(Double.self, forKey: .mixOutTime) ?? 0
            mixInCandidates = try c.decodeIfPresent([StoredCue].self, forKey: .mixInCandidates) ?? []
            mixOutCandidates = try c.decodeIfPresent([StoredCue].self, forKey: .mixOutCandidates) ?? []
            energyCurve = try c.decodeIfPresent([StoredEnergy].self, forKey: .energyCurve) ?? []
            lowEnergyCurve = try c.decodeIfPresent([StoredEnergy].self, forKey: .lowEnergyCurve) ?? []
            vocalActivityMask = try c.decodeIfPresent([Double].self, forKey: .vocalActivityMask) ?? []
            vocalProbability = try c.decodeIfPresent(Double.self, forKey: .vocalProbability) ?? 0
        }

        func toAnalysis(trackId: String) -> TrackAnalysis {
            TrackAnalysis(
                status: TrackAnalysis.statusReady,
                trackId: trackId,
                duration: duration,
                bpm: bpm,
                beatInterval: beatInterval,
                beatConfidence: beatConfidence,
                downbeats: downbeats,
                phraseBoundaries: phraseBoundaries,
                firstBeat: firstBeat,
                key: key,
                keyConfidence: keyConfidence,
                audibleStartTime: audibleStartTime,
                pickupTime: pickupTime,
                introEndTime: introEndTime,
                contentEndTime: contentEndTime,
                outroStartTime: outroStartTime,
                mixInTime: mixInTime,
                mixOutTime: mixOutTime,
                mixInCandidates: mixInCandidates.map(\.cue),
                mixOutCandidates: mixOutCandidates.map(\.cue),
                energyCurve: energyCurve.map(\.sample),
                lowEnergyCurve: lowEnergyCurve.map(\.sample),
                vocalActivityMask: vocalActivityMask,
                vocalProbability: vocalProbability
            )
        }
    }

    struct StoredCue: Codable, Equatable {
        var time: Double
        var score: Double
        var type: String

        init(_ cue: MixCandidate) {
            time = AutomixAnalysisStore.round(cue.time)
            score = AutomixAnalysisStore.round(cue.score)
            type = cue.type
        }

        var cue: MixCandidate { MixCandidate(time: time, score: score, type: type) }
    }

    struct StoredEnergy: Codable, Equatable {
        var time: Double
        var energy: Double

        init(_ sample: EnergySample) {
            time = AutomixAnalysisStore.round(sample.time)
            energy = AutomixAnalysisStore.round(sample.energy)
        }

        var sample: EnergySample { EnergySample(time: time, energy: energy) }
    }
}
