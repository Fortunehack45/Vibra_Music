import CryptoKit
import VibraMusicCore
import Foundation
import os

/// Lightweight, on-demand lyric translation and romanization (Android: `LyricsTranslation.kt`).
///
/// Translation models are deliberately not installed on the device: a model for every
/// language would cost tens of megabytes each, and translated lyric text is normally a few
/// kilobytes. Requests go to Google's lightweight web translation endpoint (`sl=auto`, no
/// key); the compact result is kept in a bounded cache — 12 entries in memory and at most
/// 2 MiB on disk under Caches, where the system may reclaim it.
///
/// **Timing survives translation.** Every translated line keeps its `timeMs`,
/// `sungUntilMs`, duet side, background placement, instrumental gaps and list position.
/// Source-language word boundaries cannot describe a translated sentence, so a word-synced
/// line gets one word spanning the original vocal and a `timingSource` pointing at the
/// original: `revealedChars` then projects the original's non-uniform character progress
/// onto the new text, so the sweep follows the source's holds, pauses and pace changes.
public final class LyricsTranslator: Sendable {
    public enum TranslationResult: Hashable, Sendable {
        case translated(lines: [LyricLine], sourceLanguage: String, fromCache: Bool)
        /// The detected source language is the target language: nothing to translate.
        case sameLanguage(String)
        /// Network failure, a malformed or partial answer, or nothing to translate.
        case unavailable
    }

    public enum RomanizationResult: Hashable, Sendable {
        case romanized(lines: [LyricLine], sourceLanguage: String, fromCache: Bool)
        /// Every letter is already Latin.
        case alreadyRomanized
        case unavailable
    }

    /// A shared translator caching under the app's Caches directory.
    public static let shared = LyricsTranslator()

    static let endpoint = URL(string: "https://translate.googleapis.com/translate_a/single")!
    static let inputToolsEndpoint = URL(string: "https://inputtools.google.com/request")!
    /// Version 3 invalidates answers cached before the Latin-script retry existed; otherwise
    /// a song that once came back untranslated would never take the repaired path.
    static let cacheVersion = 3
    static let maxCacheBytes = 2 * 1024 * 1024
    static let maxBatchChars = 3_500
    static let maxParallelRequests = 2
    /// Requests have a 12-second call deadline.
    static let deadline: TimeInterval = 12
    private static let agent = "Vibra Music/1.5.2"

    /// Input Tools changes ASCII digits to the destination script, so match the private-use
    /// wrapper rather than assuming the counter remains ASCII.
    private static let marker = LyricsRegex("\u{E000}[^\u{E001}]*\u{E001}")

    private let http: LyricsHTTP
    private let memory = LyricsTranslationMemory(capacity: 12)
    private let disk: LyricsTranslationDiskCache?

    /// - Parameters:
    ///   - session: used for every request.
    ///   - cacheDirectory: where translations are persisted; `Caches/lyrics_translation_v3`
    ///     by default. Pass nil to keep the cache in memory only.
    public init(session: URLSession = VibraMusicHTTP.session, cacheDirectory: URL? = LyricsTranslator.defaultCacheDirectory) {
        http = LyricsHTTP(session: session)
        disk = cacheDirectory.map(LyricsTranslationDiskCache.init(directory:))
    }

    public static var defaultCacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("lyrics_translation_v3", isDirectory: true)
    }

    // MARK: Translation

    /// `lines` translated into `targetLanguage` (a Google code such as `en`, `zh-TW`).
    ///
    /// The tag is sent as given rather than reduced to a base language: zh-CN and zh-TW are
    /// the same language in two scripts, and canonicalising either to "zh" hands back
    /// Simplified whichever was asked for. The narrowing happens only in `sameLanguage`.
    public func translate(trackId: String, lines: [LyricLine], targetLanguage: String) async -> TranslationResult {
        let target = targetLanguage.kTrimmed
        if target.kIsBlank || lines.isEmpty { return .unavailable }
        let slots = Self.flatten(lines)
        if slots.isEmpty { return .unavailable }

        let key = Self.cacheKey(trackId: trackId, target: target, slots: slots)
        if let cached = await cached(key), cached.version == Self.cacheVersion, cached.texts.count == slots.count {
            if Self.sameLanguage(cached.sourceLanguage, target) { return .sameLanguage(cached.sourceLanguage) }
            return .translated(lines: Self.rebuild(lines, slots: slots, translated: cached.texts), sourceLanguage: cached.sourceLanguage, fromCache: true)
        }

        let batches = Self.batches(slots)
        guard let answers = await answers(for: batches, { try await self.requestBatch($0, target: target) }) else {
            return .unavailable
        }
        let source = Self.dominantLanguage(answers)
        if source.kIsBlank { return .unavailable }

        var translated = answers.flatMap(\.translations)
        if translated.count != slots.count { return .unavailable }

        // Google's auto-detection understands many Latin-script Hindi/Urdu/Punjabi lyrics,
        // but its NMT occasionally returns whole phrases unchanged ("tera hone laga hoon").
        // If a sizeable part of a Latin-script source survived untouched, use Input Tools to
        // restore the detected language's native script and translate that. Keep the first
        // answer unless the retry actually transforms more of the song, so names and
        // genuinely bilingual lyrics do not get worse merely because they contain Latin text.
        if !Self.sameLanguage(source, target),
           Self.predominantlyLatin(slots),
           Self.unchangedWeight(slots, translated) * 3 >= slots.reduce(0, { $0 + $1.text.kLength }),
           let retried = await retryRomanizedTranslation(batches, sourceLanguage: source, target: target),
           retried.count == slots.count,
           Self.unchangedWeight(slots, retried) < Self.unchangedWeight(slots, translated) {
            translated = retried
        }

        let entry = CachedTranslation(version: Self.cacheVersion, sourceLanguage: source, targetLanguage: target, texts: translated)
        await store(entry, key: key)
        if Self.sameLanguage(source, target) { return .sameLanguage(source) }
        return .translated(lines: Self.rebuild(lines, slots: slots, translated: translated), sourceLanguage: source, fromCache: false)
    }

    // MARK: Romanization

    /// `lines` in Latin script ("Shizuka na minato ni…"), with the same timing guarantees as
    /// `translate`. `targetLanguage` is still sent as `tl` because the endpoint requires it,
    /// but is not part of the cache key: changing "translate to" cannot change how the source
    /// language is pronounced.
    public func romanize(trackId: String, lines: [LyricLine], targetLanguage: String) async -> RomanizationResult {
        if lines.isEmpty { return .unavailable }
        let slots = Self.flatten(lines)
        if slots.isEmpty { return .unavailable }
        if !Self.hasNonLatinLetters(slots) { return .alreadyRomanized }

        let key = Self.cacheKey(trackId: trackId, target: "romanize", slots: slots)
        if let cached = await cached(key), cached.version == Self.cacheVersion, cached.texts.count == slots.count {
            return .romanized(lines: Self.rebuild(lines, slots: slots, translated: cached.texts), sourceLanguage: cached.sourceLanguage, fromCache: true)
        }

        let target = targetLanguage.kTrimmed.kIfBlank("en")
        guard let answers = await answers(for: Self.batches(slots), { try await self.requestRomanizationBatch($0, target: target) }) else {
            return .unavailable
        }
        let source = Self.dominantLanguage(answers)
        let romanized = answers.flatMap(\.translations)
        if source.kIsBlank || romanized.count != slots.count { return .unavailable }
        if Self.unchangedWeight(slots, romanized) == slots.reduce(0, { $0 + $1.text.kLength }) {
            // Non-Latin input reached this point, so an unchanged response is an unsupported
            // or failed romanization rather than an already-Latin lyric.
            return .unavailable
        }

        await store(CachedTranslation(version: Self.cacheVersion, sourceLanguage: source, targetLanguage: "Latn", texts: romanized), key: key)
        return .romanized(lines: Self.rebuild(lines, slots: slots, translated: romanized), sourceLanguage: source, fromCache: false)
    }

    // MARK: Slots and batches

    struct TextSlot: Hashable {
        let lineIndex: Int
        let background: Bool
        let text: String
        let sectionHeader: Bool
    }

    struct Batch: Hashable {
        let slots: [TextSlot]
        let payload: String
    }

    struct BatchAnswer: Hashable {
        let translations: [String]
        let sourceLanguage: String
        let sourceWeight: Int
    }

    /// Every non-blank lead and background text, in order. Blank instrumental lines are
    /// preserved and never sent; section labels ("[Chorus]") go without their brackets.
    static func flatten(_ lines: [LyricLine]) -> [TextSlot] {
        var slots = [TextSlot]()
        for (index, line) in lines.enumerated() {
            if !line.text.kIsBlank {
                let header = GeniusProvider.isSectionHeader(line.text)
                let text = header ? line.text.kRemovingPrefix("[").kRemovingSuffix("]").kTrimmed : line.text
                slots.append(TextSlot(lineIndex: index, background: false, text: text, sectionHeader: header))
            }
            if let background = line.background, !background.text.kIsBlank {
                slots.append(TextSlot(lineIndex: index, background: true, text: background.text, sectionHeader: false))
            }
        }
        return slots
    }

    /// Slots batched up to `maxBatchChars`, separated by private-use markers that preserve
    /// the exact mapping between the response and the lyric lines.
    static func batches(_ slots: [TextSlot]) -> [Batch] {
        var result = [Batch]()
        var current = [TextSlot]()
        var length = 0
        func flush() {
            if current.isEmpty { return }
            result.append(Batch(slots: current, payload: payload(current)))
            current = []
            length = 0
        }
        for slot in slots {
            let added = slot.text.kLength + (current.isEmpty ? 0 : 8)
            if !current.isEmpty && length + added > maxBatchChars { flush() }
            current.append(slot)
            length += added
        }
        flush()
        return result
    }

    private static func payload(_ slots: [TextSlot]) -> String {
        var out = ""
        for (index, slot) in slots.enumerated() {
            if index > 0 { out += "\n" + marker(index) + "\n" }
            out += slot.text
        }
        return out
    }

    private static func marker(_ index: Int) -> String {
        let digits = String(index)
        return "\u{E000}" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits + "\u{E001}"
    }

    /// Batches answered at most `maxParallelRequests` at a time — two short requests keep a
    /// long lyric fast without competing with playback for every connection. Nil if any
    /// batch failed: a partial answer is discarded, and the original stays on screen.
    private func answers(for batches: [Batch], _ request: @escaping @Sendable (Batch) async throws -> BatchAnswer?) async -> [BatchAnswer]? {
        var all = [BatchAnswer]()
        var start = 0
        while start < batches.count {
            let group = Array(batches[start..<min(start + Self.maxParallelRequests, batches.count)])
            let answered = await withTaskGroup(of: (Int, BatchAnswer?).self) { tasks in
                for (index, batch) in group.enumerated() {
                    tasks.addTask { (index, try? await request(batch)) }
                }
                var collected = [BatchAnswer?](repeating: nil, count: group.count)
                for await (index, answer) in tasks { collected[index] = answer }
                return collected
            }
            if Task.isCancelled { return nil }
            for answer in answered {
                guard let answer else { return nil }
                all.append(answer)
            }
            start += Self.maxParallelRequests
        }
        return all
    }

    /// The source language by weight of text, grouping on the canonical language.
    private static func dominantLanguage(_ answers: [BatchAnswer]) -> String {
        var order = [String]()
        var weights = [String: Int]()
        for answer in answers {
            let language = canonicalLanguage(answer.sourceLanguage)
            if weights[language] == nil { order.append(language) }
            weights[language, default: 0] += answer.sourceWeight
        }
        return order.kMaxBy { weights[$0] ?? 0 } ?? ""
    }

    // MARK: Requests

    private func requestBatch(_ batch: Batch, target: String, sourceLanguage: String = "auto") async throws -> BatchAnswer? {
        let body = try await http.postForm(
            Self.endpoint,
            form: [("client", "dict-chrome-ex"), ("sl", sourceLanguage), ("tl", target), ("dt", "t"), ("q", batch.payload)],
            headers: ["User-Agent": Self.agent, "Accept": "application/json"],
            deadline: Self.deadline
        )
        return Self.parseTranslation(body, batch: batch)
    }

    static func parseTranslation(_ body: String, batch: Batch) -> BatchAnswer? {
        guard let root = LyricsJSON.parse(body)?.array, let segments = root.first?.array else { return nil }
        var translated = ""
        for segment in segments {
            guard let parts = segment.array else { return nil }
            translated += parts.first?.content ?? ""
        }
        let source = root.kGet(2)?.content ?? ""
        let parts = marker.split(translated).map(\.kTrimmed)
        if parts.count != batch.slots.count || parts.contains(where: \.kIsBlank) { return nil }
        return BatchAnswer(translations: parts, sourceLanguage: source, sourceWeight: batch.payload.kLength)
    }

    private func requestRomanizationBatch(_ batch: Batch, target: String) async throws -> BatchAnswer? {
        let body = try await http.postForm(
            Self.endpoint,
            form: [("client", "dict-chrome-ex"), ("sl", "auto"), ("tl", target), ("dt", "rm"), ("q", batch.payload)],
            headers: ["User-Agent": Self.agent, "Accept": "application/json"],
            deadline: Self.deadline
        )
        return Self.parseRomanization(body, batch: batch)
    }

    static func parseRomanization(_ body: String, batch: Batch) -> BatchAnswer? {
        guard let root = LyricsJSON.parse(body)?.array, let segments = root.first?.array else { return nil }
        var romanized = ""
        for segment in segments {
            guard let parts = segment.array else { return nil }
            romanized += parts.kGet(3)?.content ?? ""
        }
        let source = root.kGet(2)?.content ?? ""
        let parts = marker.split(romanized).map(\.kTrimmed)
        if source.kIsBlank || parts.count != batch.slots.count || parts.contains(where: \.kIsBlank) { return nil }
        return BatchAnswer(translations: parts, sourceLanguage: source, sourceWeight: batch.payload.kLength)
    }

    private func retryRomanizedTranslation(_ batches: [Batch], sourceLanguage: String, target: String) async -> [String]? {
        let source = Self.canonicalLanguage(sourceLanguage)
        if source.kIsBlank || source == "en" { return nil }
        let answers = await answers(for: batches) { batch in
            guard let native = try await self.requestNativeScript(batch.payload, sourceLanguage: source) else { return nil }
            return try await self.requestBatch(Batch(slots: batch.slots, payload: native), target: target, sourceLanguage: source)
        }
        return answers?.flatMap(\.translations)
    }

    private func requestNativeScript(_ text: String, sourceLanguage: String) async throws -> String? {
        let body = try await http.postForm(
            Self.inputToolsEndpoint,
            form: [
                ("text", text), ("itc", sourceLanguage + "-t-i0-und"), ("num", "1"), ("cp", "0"), ("cs", "1"),
                ("ie", "utf-8"), ("oe", "utf-8"),
            ],
            headers: ["User-Agent": Self.agent, "Accept": "application/json"],
            deadline: Self.deadline
        )
        return Self.parseInputTools(body)
    }

    static func parseInputTools(_ body: String) -> String? {
        guard let root = LyricsJSON.parse(body)?.array, root.first?.content == "SUCCESS",
              let native = root.kGet(1)?.array?.first?.array?.kGet(1)?.array?.first?.content,
              !native.kIsBlank
        else { return nil }
        return native
    }

    // MARK: Script and language

    private static let latinLetter = LyricsRegex(#"[\p{L}&&\p{Script=Latin}]"#)
    private static let otherLetter = LyricsRegex(#"[\p{L}&&[^\p{Script=Latin}]]"#)

    static func predominantlyLatin(_ slots: [TextSlot]) -> Bool {
        var latin = 0
        var other = 0
        for slot in slots {
            latin += latinLetter.count(in: slot.text)
            other += otherLetter.count(in: slot.text)
        }
        return latin > 0 && latin >= other * 4
    }

    static func hasNonLatinLetters(_ slots: [TextSlot]) -> Bool {
        slots.contains { otherLetter.containsMatch(in: $0.text) }
    }

    static func unchangedWeight(_ slots: [TextSlot], _ transformed: [String]) -> Int {
        zip(slots, transformed).reduce(0) { total, pair in
            comparable(pair.0.text) == comparable(pair.1) ? total + pair.0.text.kLength : total
        }
    }

    private static func comparable(_ text: String) -> String {
        LyricsRegex(#"[ \t\n\x0B\f\r]+"#).replacing(in: text.kTrimmed.lowercased(), with: " ")
    }

    /// The base language of a tag, lowercased, with Java's legacy aliases folded
    /// (`iw`→`he`, `in`→`id`, `ji`→`yi`). Empty for something that is not a language tag.
    static func canonicalLanguage(_ tag: String) -> String {
        let base = String(tag.replacingOccurrences(of: "_", with: "-").split(separator: "-", omittingEmptySubsequences: false).first ?? "")
        let lower = base.lowercased()
        let isLanguage = (2...3).contains(lower.count) || (5...8).contains(lower.count)
        guard isLanguage, lower.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) }) else { return "" }
        switch lower {
        case "iw": return "he"
        case "in": return "id"
        case "ji": return "yi"
        default: return lower
        }
    }

    static func sameLanguage(_ first: String, _ second: String) -> Bool {
        canonicalLanguage(first) == canonicalLanguage(second)
    }

    // MARK: Rebuilding

    /// The original lines with the translated text dropped in — timing untouched. An
    /// unmapped slot keeps its original text.
    static func rebuild(_ original: [LyricLine], slots: [TextSlot], translated: [String]) -> [LyricLine] {
        var byLine = [Int: [(TextSlot, String)]]()
        for (slot, text) in zip(slots, translated) { byLine[slot.lineIndex, default: []].append((slot, text)) }
        return original.enumerated().map { index, line in
            let entries = byLine[index] ?? []
            let lead = entries.first { !$0.0.background }
            let backing = entries.first { $0.0.background }
            let leadText = lead.map { $0.0.sectionHeader ? "[" + $0.1 + "]" : $0.1 } ?? line.text
            var rebuilt = line
            rebuilt.text = leadText
            rebuilt.words = retimeWords(line, leadText)
            rebuilt.timingSource = line.isWordSynced ? line : nil
            if let source = line.background {
                var background = source
                let text = backing?.1 ?? source.text
                background.text = text
                background.words = retimeWords(source, text)
                background.timingSource = source.isWordSynced ? source : nil
                rebuilt.background = background
            }
            return rebuilt
        }
    }

    /// Keep the source vocal bounds without inventing translated word timings.
    private static func retimeWords(_ source: LyricLine, _ translated: String) -> [LyricWord] {
        guard let first = source.words.first, let last = source.words.last, !translated.isEmpty else { return [] }
        return [LyricWord(startMs: first.startMs, endMs: last.endMs, text: translated)]
    }

    // MARK: Cache

    struct CachedTranslation: Codable, Hashable, Sendable {
        var version: Int
        var sourceLanguage: String
        var targetLanguage: String
        var texts: [String]
    }

    /// SHA-256 of track, destination and source text.
    static func cacheKey(trackId: String, target: String, slots: [TextSlot]) -> String {
        var source = trackId + "\u{0}" + target
        for slot in slots { source += "\u{0}" + slot.text }
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func cached(_ key: String) async -> CachedTranslation? {
        if let hit = memory[key] { return hit }
        guard let fromDisk = await disk?.read(key) else { return nil }
        memory[key] = fromDisk
        return fromDisk
    }

    private func store(_ entry: CachedTranslation, key: String) async {
        memory[key] = entry
        await disk?.write(entry, key: key)
    }
}

/// The 12 most recent translations, least-recently-used out first.
final class LyricsTranslationMemory: Sendable {
    private struct State {
        var order: [String] = []
        var values: [String: LyricsTranslator.CachedTranslation] = [:]
    }

    private let capacity: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(capacity: Int) { self.capacity = capacity }

    subscript(key: String) -> LyricsTranslator.CachedTranslation? {
        get {
            state.withLock { state in
                guard let value = state.values[key] else { return nil }
                state.order.removeAll { $0 == key }
                state.order.append(key)
                return value
            }
        }
        set {
            let capacity = capacity
            state.withLock { state in
                state.order.removeAll { $0 == key }
                state.values[key] = newValue
                guard newValue != nil else { return }
                state.order.append(key)
                while state.order.count > capacity { state.values[state.order.removeFirst()] = nil }
            }
        }
    }
}

/// Compressed JSON files under a caches directory, trimmed least-recently-used first to
/// `maxCacheBytes`.
///
/// iOS difference: Android gzips; Foundation offers raw DEFLATE (`NSData.compressed(using:
/// .zlib)`), so the files are `.json.deflate`. They are private to this app and never
/// exchanged, and an unreadable file is simply a miss.
actor LyricsTranslationDiskCache {
    private let directory: URL

    init(directory: URL) { self.directory = directory }

    private func file(_ key: String) -> URL { directory.appendingPathComponent(key + ".json.deflate") }

    func read(_ key: String) -> LyricsTranslator.CachedTranslation? {
        let url = file(key)
        guard let compressed = try? Data(contentsOf: url),
              let json = try? (compressed as NSData).decompressed(using: .zlib) as Data,
              let value = try? JSONDecoder().decode(LyricsTranslator.CachedTranslation.self, from: json),
              value.version == LyricsTranslator.cacheVersion
        else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return value
    }

    func write(_ value: LyricsTranslator.CachedTranslation, key: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let json = try JSONEncoder().encode(value)
            let compressed = try (json as NSData).compressed(using: .zlib) as Data
            try compressed.write(to: file(key), options: .atomic)
            trim()
        } catch {
            lyricsLog.debug("Could not cache a lyrics translation: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func trim() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        let entries = files.filter { $0.pathExtension == "deflate" }.map { url -> (URL, Date, Int) in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (url, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0)
        }.sorted { $0.1 > $1.1 }
        var kept = 0
        for (url, _, size) in entries {
            kept += size
            if kept > LyricsTranslator.maxCacheBytes { try? FileManager.default.removeItem(at: url) }
        }
    }
}
