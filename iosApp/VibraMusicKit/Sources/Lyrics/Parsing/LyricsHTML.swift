import Foundation

/// A forgiving HTML reader — just enough of Jsoup for the Genius scraper, which is the only
/// place Android parsed HTML as a tree (Megalobiz is regex-scraped on both platforms).
///
/// It tokenizes tags, attributes (quoted, unquoted, bare), comments and doctypes; keeps
/// `script`/`style` bodies as raw data rather than text; treats void and self-closed
/// elements as leaves; closes an open `<p>` when another block starts; and recovers from a
/// stray end tag by ignoring it. Character references are decoded in text and attribute
/// values. It does not implement the full HTML5 tree-construction algorithm, which a
/// server-rendered page like Genius's does not need.
final class LyricsHTMLNode {
    enum Kind {
        case element(name: String, attributes: [(name: String, value: String)])
        case text(String)
        /// `script`/`style` bodies — not text, so never part of `wholeText`.
        case data(String)
    }

    private(set) var kind: Kind
    fileprivate(set) var children: [LyricsHTMLNode] = []
    fileprivate(set) weak var parent: LyricsHTMLNode?

    init(_ kind: Kind) { self.kind = kind }

    var tagName: String? {
        if case .element(let name, _) = kind { return name }
        return nil
    }

    func attribute(_ name: String) -> String? {
        guard case .element(_, let attributes) = kind else { return nil }
        return attributes.first { $0.name == name }?.value
    }

    /// Jsoup's `.class` selector: a whole whitespace-separated token of `class`.
    func hasClass(_ name: String) -> Bool {
        guard let classes = attribute("class") else { return false }
        return classes.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\u{0C}" })
            .contains { $0 == name }
    }

    /// Jsoup's `[name=value]`: the attribute present and equal, ignoring case and surrounding space.
    func attribute(_ name: String, equals value: String) -> Bool {
        attribute(name)?.kTrimmed.kEqualsIgnoreCase(value) ?? false
    }

    /// Every descendant (not this node), depth-first in document order.
    var descendants: [LyricsHTMLNode] {
        var out = [LyricsHTMLNode]()
        func walk(_ node: LyricsHTMLNode) {
            for child in node.children {
                out.append(child)
                walk(child)
            }
        }
        walk(self)
        return out
    }

    /// Descendant elements matching `predicate`, in document order.
    func select(_ predicate: (LyricsHTMLNode) -> Bool) -> [LyricsHTMLNode] {
        descendants.filter { $0.tagName != nil && predicate($0) }
    }

    /// Detaches this node from its parent.
    func remove() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        self.parent = nil
    }

    /// Puts `replacement` where this node is.
    func replace(with replacement: LyricsHTMLNode) {
        guard let parent, let index = parent.children.firstIndex(where: { $0 === self }) else { return }
        replacement.parent = parent
        parent.children[index] = replacement
        self.parent = nil
    }

    func prepend(_ child: LyricsHTMLNode) {
        child.parent = self
        children.insert(child, at: 0)
    }

    /// Jsoup's `wholeText()`: every descendant text node, unnormalised, in order.
    var wholeText: String {
        var out = ""
        func walk(_ node: LyricsHTMLNode) {
            for child in node.children {
                if case .text(let text) = child.kind { out += text }
                walk(child)
            }
        }
        walk(self)
        return out
    }

    // MARK: Parsing

    static func parse(_ html: String) -> LyricsHTMLNode {
        var parser = Parser(scalars: Array(html.unicodeScalars))
        return parser.run()
    }

    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "keygen", "link", "meta", "param",
        "source", "track", "wbr",
    ]
    private static let rawTextElements: Set<String> = ["script", "style"]
    private static let escapableRawTextElements: Set<String> = ["textarea", "title"]
    /// Starting one of these closes an open `<p>`.
    private static let closesParagraph: Set<String> = [
        "address", "article", "aside", "blockquote", "div", "dl", "fieldset", "figure", "footer", "form",
        "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "main", "nav", "ol", "p", "pre", "section",
        "table", "ul",
    ]

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0
        let root = LyricsHTMLNode(.element(name: "#root", attributes: []))
        var stack: [LyricsHTMLNode] = []

        init(scalars: [Unicode.Scalar]) {
            self.scalars = scalars
            stack = [root]
        }

        mutating func run() -> LyricsHTMLNode {
            var text = ""
            while index < scalars.count {
                let scalar = scalars[index]
                if scalar == "<", let next = scalars.kGet(index + 1),
                   next == "/" || next == "!" || next == "?" || next.properties.isAlphabetic {
                    flushText(&text)
                    tag()
                } else {
                    text.unicodeScalars.append(scalar)
                    index += 1
                }
            }
            flushText(&text)
            return root
        }

        private mutating func flushText(_ text: inout String) {
            guard !text.isEmpty else { return }
            append(LyricsHTMLNode(.text(LyricsHTMLEntities.decode(text))))
            text = ""
        }

        private mutating func append(_ node: LyricsHTMLNode) {
            let parent = stack[stack.count - 1]
            node.parent = parent
            parent.children.append(node)
        }

        /// Whether `literal` (ASCII) starts at `position`, ignoring ASCII case.
        private func startsWith(_ literal: String, at position: Int) -> Bool {
            let target = literal.unicodeScalars
            guard position + target.count <= scalars.count else { return false }
            var offset = position
            for want in target {
                if Self.asciiLower(scalars[offset].value) != Self.asciiLower(want.value) { return false }
                offset += 1
            }
            return true
        }

        private static func asciiLower(_ value: UInt32) -> UInt32 {
            (65...90).contains(value) ? value + 32 : value
        }

        private mutating func skip(past terminator: String) {
            while index < scalars.count, !startsWith(terminator, at: index) { index += 1 }
            index = min(scalars.count, index + terminator.unicodeScalars.count)
        }

        private mutating func tag() {
            if startsWith("<!--", at: index) {
                index += 4
                skip(past: "-->")
                return
            }
            if scalars[index + 1] == "!" || scalars[index + 1] == "?" {
                skip(past: ">")
                return
            }
            if scalars[index + 1] == "/" {
                index += 2
                let name = readName()
                skip(past: ">")
                close(name)
                return
            }
            index += 1
            let name = readName()
            var attributes = [(name: String, value: String)]()
            var selfClosing = false
            while index < scalars.count {
                skipSpace()
                guard index < scalars.count else { break }
                if scalars[index] == ">" { index += 1; break }
                if scalars[index] == "/" {
                    index += 1
                    if index < scalars.count, scalars[index] == ">" { selfClosing = true; index += 1; break }
                    continue
                }
                let attributeName = readAttributeName()
                if attributeName.isEmpty { index += 1; continue }
                skipSpace()
                var value = ""
                if index < scalars.count, scalars[index] == "=" {
                    index += 1
                    skipSpace()
                    value = readAttributeValue()
                }
                if !attributes.contains(where: { $0.name == attributeName }) {
                    attributes.append((attributeName, LyricsHTMLEntities.decode(value)))
                }
            }

            if name == "p" || LyricsHTMLNode.closesParagraph.contains(name) {
                if let open = stack.lastIndex(where: { $0.tagName == "p" }),
                   !stack[open...].contains(where: { ["button", "table", "td", "th"].contains($0.tagName ?? "") }) {
                    stack.removeSubrange(open...)
                }
            }

            let element = LyricsHTMLNode(.element(name: name, attributes: attributes))
            append(element)
            if selfClosing || LyricsHTMLNode.voidElements.contains(name) { return }
            if LyricsHTMLNode.rawTextElements.contains(name) || LyricsHTMLNode.escapableRawTextElements.contains(name) {
                let start = index
                let terminator = "</" + name
                while index < scalars.count, !startsWith(terminator, at: index) { index += 1 }
                var body = ""
                body.unicodeScalars.append(contentsOf: scalars[start..<index])
                if !body.isEmpty {
                    let child = LyricsHTMLNode(
                        LyricsHTMLNode.rawTextElements.contains(name) ? .data(body) : .text(LyricsHTMLEntities.decode(body))
                    )
                    child.parent = element
                    element.children.append(child)
                }
                skip(past: ">")
                return
            }
            stack.append(element)
        }

        private mutating func close(_ name: String) {
            guard let open = stack.lastIndex(where: { $0.tagName == name }), open > 0 else { return }
            stack.removeSubrange(open...)
        }

        private mutating func skipSpace() {
            while index < scalars.count, scalars[index].properties.isWhitespace { index += 1 }
        }

        private mutating func readName() -> String {
            var name = ""
            while index < scalars.count {
                let scalar = scalars[index]
                if scalar.properties.isWhitespace || scalar == ">" || scalar == "/" { break }
                name.unicodeScalars.append(scalar)
                index += 1
            }
            return name.lowercased()
        }

        private mutating func readAttributeName() -> String {
            var name = ""
            while index < scalars.count {
                let scalar = scalars[index]
                if scalar.properties.isWhitespace || scalar == ">" || scalar == "/" || scalar == "=" { break }
                name.unicodeScalars.append(scalar)
                index += 1
            }
            return name.lowercased()
        }

        private mutating func readAttributeValue() -> String {
            guard index < scalars.count else { return "" }
            var value = ""
            let quote = scalars[index]
            if quote == "\"" || quote == "'" {
                index += 1
                while index < scalars.count, scalars[index] != quote {
                    value.unicodeScalars.append(scalars[index])
                    index += 1
                }
                index = min(scalars.count, index + 1)
                return value
            }
            while index < scalars.count {
                let scalar = scalars[index]
                if scalar.properties.isWhitespace || scalar == ">" { break }
                value.unicodeScalars.append(scalar)
                index += 1
            }
            return value
        }
    }
}

/// HTML character references: numeric, and the named ones that turn up in lyric pages.
enum LyricsHTMLEntities {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "sbquo": "‚",
        "ldquo": "“", "rdquo": "”", "bdquo": "„", "laquo": "«", "raquo": "»", "copy": "©", "reg": "®",
        "trade": "™", "deg": "°", "middot": "·", "bull": "•", "prime": "′", "times": "×", "divide": "÷",
        "iexcl": "¡", "iquest": "¿", "shy": "\u{00AD}", "zwj": "\u{200D}", "zwnj": "\u{200C}",
        "aacute": "á", "eacute": "é", "iacute": "í", "oacute": "ó", "uacute": "ú", "ntilde": "ñ",
        "Aacute": "Á", "Eacute": "É", "Iacute": "Í", "Oacute": "Ó", "Uacute": "Ú", "Ntilde": "Ñ",
        "agrave": "à", "egrave": "è", "igrave": "ì", "ograve": "ò", "ugrave": "ù",
        "acirc": "â", "ecirc": "ê", "icirc": "î", "ocirc": "ô", "ucirc": "û",
        "auml": "ä", "euml": "ë", "iuml": "ï", "ouml": "ö", "uuml": "ü", "yuml": "ÿ",
        "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß", "ccedil": "ç", "Ccedil": "Ç",
        "aring": "å", "Aring": "Å", "aelig": "æ", "AElig": "Æ", "oslash": "ø", "Oslash": "Ø",
        "atilde": "ã", "otilde": "õ",
    ]

    private static let reference = LyricsRegex("&(#[xX][0-9a-fA-F]{1,6}|#[0-9]{1,7}|[A-Za-z][A-Za-z0-9]{1,31});?")

    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return reference.replacing(in: text) { match in
            let body = match.groupValues[1]
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                return UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) } ?? match.value
            }
            if body.hasPrefix("#") {
                return UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) } ?? match.value
            }
            // A named reference must be terminated to count, except the legacy few.
            guard match.value.hasSuffix(";") || ["amp", "lt", "gt", "quot", "nbsp"].contains(body) else { return match.value }
            return named[body] ?? match.value
        }
    }
}
