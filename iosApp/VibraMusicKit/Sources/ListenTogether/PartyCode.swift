import Foundation

/// Party codes: generation, charitable reading, and validation.
/// (Ports `backend/codes/codes.go` plus the invite-side cleaning in
/// `data/listentogether/JamInviteLink.kt`.)
public enum PartyCode {
    /// The code alphabet. `I`, `L` and `O` are absent so a code read out loud cannot be
    /// misheard; `Normalise` maps those onto `1` and `0` when they are typed anyway.
    public static let alphabet = "0123456789ABCDEFGHJKMNPQRSTUVWXYZ"

    /// A fresh code from the system RNG (one uniform draw per character).
    public static func makeRandom() -> String {
        let chars = Array(alphabet)
        var result = ""
        result.reserveCapacity(PartyLimits.codeLength)
        for _ in 0 ..< PartyLimits.codeLength {
            result.append(chars[Int.random(in: 0 ..< chars.count)])
        }
        return result
    }

    /// Reads a mistyped code charitably, exactly like the server's `Normalise`: strips
    /// spaces, hyphens and anything non-alphanumeric, uppercases, and maps the commonly
    /// confused characters `I`/`L` → `1`, `O` → `0`. The server normalises before lookup,
    /// so sending the normalised form is equivalent and lets the client refuse junk early.
    public static func normalize(_ code: String) -> String {
        var out = ""
        out.reserveCapacity(code.count)
        for scalar in code.uppercased().unicodeScalars {
            let c = Character(scalar)
            guard c.isLetter || c.isNumber else { continue }
            switch c {
            case "I", "L": out.append("1")
            case "O": out.append("0")
            default: out.append(c)
            }
        }
        return out
    }

    /// Whether the code is exactly six alphabet characters.
    public static func isValid(_ code: String) -> Bool {
        guard code.count == PartyLimits.codeLength else { return false }
        return code.allSatisfy { alphabet.contains($0) }
    }

    /// The invite-link cleaning: alphanumerics only, uppercased, exactly six. Unlike
    /// `normalize` this does not remap confusables — an invite URL carries the canonical
    /// code, not something somebody typed.
    public static func cleanInviteCode(_ raw: String) -> String? {
        let cleaned = raw.filter(\.isLetterOrNumber).uppercased()
        return cleaned.count == PartyLimits.codeLength ? cleaned : nil
    }
}

extension Character {
    var isLetterOrNumber: Bool { isLetter || isNumber }
}
