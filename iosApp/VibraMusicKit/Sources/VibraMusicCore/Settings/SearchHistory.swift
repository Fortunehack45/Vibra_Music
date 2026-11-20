import Foundation
import Observation

// Ports data/settings/SearchHistory.kt.

/// What's been searched for lately, kept on this device only.
///
/// YouTube Music has an account-level history, but reading it needs a signed-in call and is wrong
/// for a signed-out user. A local list is instant, works either way, and is what Spotify and Apple
/// Music show in the same spot.
///
/// Stored as JSON under `search_history` in the settings `UserDefaults`, as on Android (a query can
/// contain any character, so no delimited string). Because it shares that storage, a settings
/// import replaces it: call ``reload()`` after ``AppSettings/importPrefs(_:)``.
@MainActor
@Observable
public final class SearchHistory {
    /// Deep enough to be useful, shallow enough that the list stays scannable.
    nonisolated public static let maxEntries = 20

    /// The app's instance, over `UserDefaults.standard` like ``AppSettings/shared``.
    public static let shared = SearchHistory()

    /// Most recent first.
    public private(set) var recent: [SearchHistoryEntity] = []

    @ObservationIgnored private let defaults: UserDefaults
    private static var storageKey: String { AppSettings.Key.searchHistory.rawValue }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
    }

    /// Re-reads the list from storage. An unreadable list reads as empty.
    public func reload() {
        guard let json = defaults.string(forKey: Self.storageKey), let data = json.data(using: .utf8) else {
            recent = []
            return
        }
        recent = (try? JSONDecoder().decode([SearchHistoryEntity].self, from: data)) ?? []
    }

    /// Records `entity`, or moves it back to the top if it's already there. Matched by id,
    /// case-insensitively, so a re-tap refreshes the entry rather than duplicating it.
    public func record(_ entity: SearchHistoryEntity) {
        let deduped = recent.filter { $0.id.caseInsensitiveCompare(entity.id) != .orderedSame }
        save(Array(([entity] + deduped).prefix(Self.maxEntries)))
    }

    public func remove(id: String) {
        save(recent.filter { $0.id.caseInsensitiveCompare(id) != .orderedSame })
    }

    public func clear() {
        save([])
    }

    private func save(_ entries: [SearchHistoryEntity]) {
        recent = entries
        guard let data = try? JSONEncoder().encode(entries), let json = String(data: data, encoding: .utf8) else {
            return
        }
        defaults.set(json, forKey: Self.storageKey)
    }
}
