import VibraMusicCore
import Foundation

/// The databases `LyricsRepository` can ask, in the order it asks them.
///
/// The enum itself (cases, `label`, `detail`, `wordSynced`, `legacySources`) lives in Core,
/// because `AppSettings` persists the enabled set and the order by these names. This alias
/// keeps `Lyrics.LyricsSource` spelling the same type, so settings pass straight through
/// without a raw-value round trip.
public typealias LyricsSource = VibraMusicCore.LyricsSource

// MARK: - Stored settings (Android: AppSettings.readLyricsSources / readLyricsSourceOrder)

extension VibraMusicCore.LyricsSource {
    /// A set or order as it is stored: names joined by commas.
    public static func storageString<S: Sequence>(_ sources: S) -> String where S.Element == LyricsSource {
        sources.map(\.rawValue).joined(separator: ",")
    }

    /// The enabled set, read back from what was stored.
    ///
    /// Stored as a joined list of names rather than a set: a name that no longer exists — a
    /// source dropped in a later build — has to fall out quietly, and the default when
    /// nothing has been saved is "all of them", which a missing key and an empty set would
    /// otherwise be unable to tell apart.
    ///
    /// A source *added* by an upgrade is enabled rather than left out. Absence from a saved
    /// list is a decision only about the sources that list was chosen from; a new one was
    /// never on it. `seen` (written alongside the set, see `storageString(allCases)`) is what
    /// makes the two cases distinguishable — before it existed, Core's `legacySources` stands
    /// in as the list of everything there was to have an opinion about.
    public static func enabledSources(stored: String?, seen: String?) -> Set<LyricsSource> {
        guard let stored else { return Set(allCases) }
        let chosen = sources(named: stored)
        let known = seen.map(sources(named:)) ?? legacySources
        return chosen.union(allCases.filter { !known.contains($0) })
    }

    /// The priority order, read back from what was stored. A named source dropped since it
    /// was saved falls out; one added since is appended in declaration order, so a fresh
    /// install and an upgraded one agree on where a new source lands.
    public static func sourceOrder(stored: String?) -> [LyricsSource] {
        guard let stored else { return allCases }
        var saved = [LyricsSource]()
        for name in stored.split(separator: ",", omittingEmptySubsequences: false) {
            if let source = LyricsSource(rawValue: String(name)) { saved.append(source) }
        }
        return saved + allCases.filter { !saved.contains($0) }
    }

    private static func sources(named stored: String) -> Set<LyricsSource> {
        Set(stored.split(separator: ",", omittingEmptySubsequences: false).compactMap { LyricsSource(rawValue: String($0)) })
    }
}
