import Foundation
import VibraMusicCore

// Ports data/sources/addon/SourceFormats.kt.

/// What kind of thing is on the end of a URL somebody pasted.
///
/// The Sources screen accepts any link. A manifest is a *description* of an addon and the endpoints
/// are the addon, so a missing or oddly named manifest is not a reason to refuse anything — the
/// last thing tried is always "does `/search` answer". And a refusal says what was found, not just
/// that it wasn't wanted.
public enum DetectedSourceFormat: Hashable, Sendable {
    /// An addon server. `manifest` may be published or synthesised from a working `/search`.
    case addon(manifest: AddonManifest, baseUrl: String)
    /// A legacy module index: JS plugins under `category:*` keys.
    case moduleIndex(moduleCount: Int, url: String)
    /// Recognised, and not something the app can play. `reason` is shown to the user.
    case unsupported(reason: String)
}

public enum SourceFormats {

    /// Fetches `rawUrl`, works out what it is, and falls back to asking the server directly.
    ///
    /// Three passes, cheapest first: the link as given when it names a `.json` document; then
    /// `{base}/manifest.json`; then `{base}/search`, which makes a manifest optional.
    public static func identify(_ rawUrl: String, session: URLSession, atmosWanted: @escaping @Sendable () async -> Bool = { false }) async throws -> DetectedSourceFormat {
        let url = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines).trimmingTrailing("/")
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https", parsed.host()?.isEmpty == false else {
            return .unsupported(reason: "That is not a web address Vibra Music can open")
        }

        let base = AddonClient.normalizeBase(url)
        let isDocument = url.before("?").lowercased().hasSuffix(".json")
        let attempts = isDocument ? [url, base + "/manifest.json"] : [url + "/manifest.json", url]

        var lastFailure: Error?
        var firstUnsupported: DetectedSourceFormat?
        for attempt in attempts {
            guard let attemptURL = URL(string: attempt) else { continue }
            let body: Data
            do {
                body = try await fetch(attemptURL, session: session)
            } catch {
                lastFailure = error
                continue
            }
            let found = detect(body, url: attempt)
            if case .unsupported = found {
                if firstUnsupported == nil { firstUnsupported = found }
            } else {
                return found
            }
        }

        // Nothing readable was published. Ask the endpoints — the pass that lets an addon with no
        // manifest be added at all.
        let probe = AddonClient(baseUrl: base, session: session, atmosWanted: atmosWanted)
        if case .success = await probe.probeSearch() {
            SourcesLog.d("identify(\(AddonClient.redact(base))) — no manifest, but /search answered")
            return .addon(manifest: synthesised(base), baseUrl: base)
        }
        // What was actually found beats the transport error from a URL the user never typed.
        if let firstUnsupported { return firstUnsupported }
        throw lastFailure ?? AddonError.unavailable("Nothing answered at that address")
    }

    /// Which format `body` is, decided on its shape alone. Kept pure so every branch is a test
    /// against a real payload. Order matters: several formats are objects with an array in them.
    public static func detect(_ body: Data, url: String = "") -> DetectedSourceFormat {
        guard let root = JSONValue.parse(body) else {
            return .unsupported(reason: "That address did not return JSON")
        }
        guard let object = root.objectValue else {
            return .unsupported(reason: "That JSON is a list, and every format Vibra Music reads is an object")
        }

        // 1. A module index: its "category:*" marker belongs to no other format.
        if object.keys.contains(where: { $0.hasPrefix("category:") }) {
            let modules = (try? ModuleIndex.parseModules(body)) ?? []
            return modules.isEmpty
                ? .unsupported(reason: "That module index listed no modules")
                : .moduleIndex(moduleCount: modules.count, url: url)
        }

        // 2. An addon manifest, by `resources` or by the id/name/version trio. A manifest without
        //    `resources` is under-described, not disqualified.
        let looksLikeManifest = object["resources"]?.arrayValue != nil
            || (object["id"] != nil && (object["name"] != nil || object["version"] != nil))
        if looksLikeManifest {
            guard let manifest = try? JSONDecoder().decode(AddonManifest.self, from: body) else {
                return .unsupported(reason: "That looks like an addon manifest, but it could not be read")
            }
            // Search is the one thing required, and only when the addon said what it does.
            if !manifest.resources.isEmpty, !manifest.declares("search") {
                let declared = manifest.resources.joined(separator: ", ")
                return .unsupported(reason: "This addon declares \(declared) — Vibra Music needs search")
            }
            return .addon(manifest: manifest, baseUrl: AddonClient.normalizeBase(url))
        }

        // 3. An index of *something*, just not ours: says the link was the right sort of thing and
        //    this is the wrong app, rather than sending someone hunting for a typo. The first
        //    non-empty list in document order.
        if let listKey = orderedKeys(body).first(where: { key in
            if case .array(let items)? = object[key] { return !items.isEmpty }
            return false
        }) {
            return .unsupported(reason: "That JSON lists \"\(listKey)\", which is not a format Vibra Music reads")
        }

        let keys = orderedKeys(body).prefix(4).joined(separator: ", ")
        return .unsupported(reason: "Unrecognised JSON — it holds \(keys.isEmpty ? "nothing" : keys)")
    }

    public static func detect(_ body: String, url: String = "") -> DetectedSourceFormat {
        detect(Data(body.utf8), url: url)
    }

    /// A stand-in for an addon that answered but never described itself, named for its host.
    private static func synthesised(_ base: String) -> AddonManifest {
        AddonManifest(id: base, name: URL(string: base)?.host()?.nonBlank ?? base, resources: ["search", "stream"])
    }

    /// One GET, as plain as it gets: this runs before anything is configured.
    private static func fetch(_ url: URL, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(VibraMusicHTTP.UserAgent.addon, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = AddonClient.callTimeout
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            guard (200..<300).contains(status) else {
                throw status >= 500 ? AddonError.unavailable("HTTP \(status)") : AddonError.rejected("HTTP \(status)")
            }
            guard String(data: data, encoding: .utf8)?.nonBlank != nil else { throw AddonError.rejected("Empty response") }
            return data
        } catch {
            SourcesLog.d("identify(\(AddonClient.redact(url.absoluteString))) failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Top-level keys in document order (JSONSerialization and `[String: _]` lose it; Kotlin's
    /// `JsonObject` keeps it, and "the first list" should mean the first one written).
    static func orderedKeys(_ body: Data) -> [String] {
        guard let text = String(data: body, encoding: .utf8) else { return [] }
        var keys: [String] = []
        var depth = 0
        var index = text.startIndex
        var expectingKey = false
        while index < text.endIndex {
            let character = text[index]
            switch character {
            case "{", "[":
                depth += 1
                expectingKey = character == "{" && depth == 1
            case "}", "]":
                depth -= 1
            case ",":
                if depth == 1 { expectingKey = true }
            case "\"":
                // Read the whole string, honouring escapes.
                var end = text.index(after: index)
                var raw = ""
                while end < text.endIndex, text[end] != "\"" {
                    if text[end] == "\\" {
                        raw.append(text[end])
                        end = text.index(after: end)
                        guard end < text.endIndex else { break }
                    }
                    raw.append(text[end])
                    end = text.index(after: end)
                }
                if depth == 1, expectingKey {
                    let decoded = (try? JSONDecoder().decode(String.self, from: Data("\"\(raw)\"".utf8))) ?? raw
                    keys.append(decoded)
                    expectingKey = false
                }
                index = end
            default:
                break
            }
            if index < text.endIndex { index = text.index(after: index) }
        }
        return keys
    }
}
