import Foundation

/// How to decipher one YouTube player version: which internal call turns an obfuscated
/// signature into a real one, which URL class applies the `n` transform, and the player's
/// `signatureTimestamp`.
///
/// This is the config model of zemer-cipher (GPL-3.0, the library InnerTubeX's cipher tier
/// ports), whose `player_configs.json` maps player hashes to entries like
/// `"7460dd14": { "sig": "hQ(40,3024,INPUT)", "nClass": "ZO", "sts": 20717 }`.
struct PlayerScriptConfig: Sendable, Equatable {
    /// A single call `name(int,int,INPUT)`; `INPUT` stands for the URL-decoded `s` value.
    var sigExpression: String
    /// The player's URL class. Constructing it from a URL carrying `n` makes the player apply
    /// its own `n` transform, which is then read back — no need to find the n function itself.
    var nClass: String
    var signatureTimestamp: Int

    // Security boundary: every value here ends up evaluated as JavaScript, so entries are
    // regex-locked to shapes that cannot carry arbitrary code — the same locks as zemer's
    // `PlayerConfigParser`. The n-transform expression is built locally, never taken from a file.
    static let sigPattern = #"^[A-Za-z0-9$_]{1,8}\(\d+,\d+,INPUT\)$"#
    static let nClassPattern = #"^[A-Za-z0-9$_]{1,8}$"#
    static let hashPattern = #"^[a-f0-9]{8}$"#

    var isValidShape: Bool {
        sigExpression.range(of: Self.sigPattern, options: .regularExpression) != nil
            && nClass.range(of: Self.nClassPattern, options: .regularExpression) != nil
            && signatureTimestamp > 0
    }

    /// The JavaScript expression for the n transform, with `INPUT` for the value. Byte-equal to
    /// zemer's `buildNJsExpression` template.
    static func nExpression(nClass: String) -> String {
        "(function(n){try{var u=new g.\(nClass)('https://x.googlevideo.com/videoplayback?n='+n,true);"
            + "var t=u.get('n');return(t&&t!==n)?t:n;}catch(e){return n;}})(INPUT)"
    }

    /// Reads the config straight out of the player source, for a player the remote table does
    /// not know yet.
    ///
    /// Anchored on the one place the player itself deciphers a stream URL:
    /// `f=new g.ZO(f,!0);f.set("alr","yes");G&&(G=hQ(40,3024,WH(3,2444,G)),…)` — the class it
    /// builds is `nClass`, the outer call on the signature is `sig`. Fragile by nature (a
    /// reshuffle of that statement defeats it), which is why the remote table comes first and a
    /// derived config is only used after it passes `StreamCipherSolver`'s self-test.
    static func derive(fromPlayerSource js: String) -> PlayerScriptConfig? {
        let pattern =
            #"new g\.([A-Za-z0-9_$]+)\(([A-Za-z0-9_$]+),!0\);\2\.set\("alr","yes"\);([A-Za-z0-9_$]+)&&\(\3=([A-Za-z0-9_$]+)\((\d+),(\d+),"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: js, range: NSRange(js.startIndex..., in: js)),
              let sts = signatureTimestamp(inPlayerSource: js)
        else { return nil }
        func group(_ index: Int) -> String { Range(match.range(at: index), in: js).map { String(js[$0]) } ?? "" }
        let config = PlayerScriptConfig(
            sigExpression: "\(group(4))(\(group(5)),\(group(6)),INPUT)",
            nClass: group(1),
            signatureTimestamp: sts
        )
        return config.isValidShape ? config : nil
    }

    static func signatureTimestamp(inPlayerSource js: String) -> Int? {
        firstMatch(#"signatureTimestamp:(\d+)"#, in: js).flatMap(Int.init)
            ?? firstMatch(#"[,{]sts:(\d+)"#, in: js).flatMap(Int.init)
    }
}

/// The remote per-player table (`player_configs.json`, schemaVersion 1). Port of zemer's
/// `PlayerConfigParser`: invalid entries are skipped; a malformed file, an unsupported schema, or
/// an ambiguous table (a hash or alias claimed twice) is rejected whole so callers keep their
/// last good copy.
enum PlayerConfigTable {
    static let supportedSchemaVersion = 1

    enum ParseResult: Equatable {
        case success(configs: [String: PlayerScriptConfig], skipped: [String])
        case failure(String)
    }

    static func parse(_ data: Data) -> ParseResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure("root is not a JSON object")
        }
        // A number, not a string: "1" must fail here exactly as it does in zemer's reader.
        guard let version = root["schemaVersion"] as? NSNumber, !(root["schemaVersion"] is String),
              CFGetTypeID(version) != CFBooleanGetTypeID()
        else { return .failure("schemaVersion missing or not an int") }
        let schema = version.intValue
        if schema <= 0 { return .failure("schemaVersion must be positive") }
        if schema > supportedSchemaVersion {
            return .failure("unsupported schemaVersion \(schema) (supported: \(supportedSchemaVersion))")
        }
        guard let players = root["players"] as? [String: Any] else {
            return .failure("players missing or not an object")
        }
        var configs: [String: PlayerScriptConfig] = [:]
        var skipped: [String] = []
        for hash in players.keys.sorted() {
            guard let (config, aliases) = parseEntry(hash: hash, players[hash] as? [String: Any]) else {
                skipped.append(hash)
                continue
            }
            let keys = [hash] + aliases
            if let duplicate = keys.first(where: { configs[$0] != nil })
                ?? Dictionary(grouping: keys, by: { $0 }).first(where: { $0.value.count > 1 })?.key {
                return .failure("duplicate hash/alias '\(duplicate)' (entry \(hash))")
            }
            for key in keys { configs[key] = config }
        }
        return .success(configs: configs, skipped: skipped)
    }

    private static func parseEntry(hash: String, _ object: [String: Any]?) -> (PlayerScriptConfig, [String])? {
        guard let object, hash.range(of: PlayerScriptConfig.hashPattern, options: .regularExpression) != nil,
              let sig = object["sig"] as? String,
              let nClass = object["nClass"] as? String,
              let stsNumber = object["sts"] as? NSNumber, !(object["sts"] is String),
              CFGetTypeID(stsNumber) != CFBooleanGetTypeID()
        else { return nil }
        let sts = stsNumber.intValue
        guard Double(sts) == stsNumber.doubleValue else { return nil }
        let config = PlayerScriptConfig(sigExpression: sig, nClass: nClass, signatureTimestamp: sts)
        guard config.isValidShape else { return nil }
        var aliases: [String] = []
        if let raw = object["aliases"] {
            guard let list = raw as? [Any] else { return nil }
            for element in list {
                guard let alias = element as? String,
                      alias.range(of: PlayerScriptConfig.hashPattern, options: .regularExpression) != nil
                else { return nil }
                aliases.append(alias)
            }
        }
        return (config, aliases)
    }
}

/// Where YouTube's player script lives, and how to name one.
enum PlayerScriptLocator {
    /// The variant zemer's table is keyed against. The `player_es6` variant music.youtube.com
    /// links to is the same player compiled differently: its internal names differ, so a
    /// config for one is wrong for the other.
    static func scriptURL(hash: String) -> URL {
        URL(string: "https://www.youtube.com/s/player/\(hash)/player_ias.vflset/en_US/base.js")!
    }

    /// The small iframe API loader; it names the current player in a few hundred bytes.
    static let iframeAPIURL = URL(string: "https://www.youtube.com/iframe_api")!

    static func hash(inPath path: String) -> String? {
        firstMatch(#"/s/player/([a-zA-Z0-9_-]{8})/"#, in: path)
    }

    static func hash(inIframeAPI body: String) -> String? {
        firstMatch(#"player\\?/([a-zA-Z0-9_-]{8})\\?/"#, in: body)
    }
}
