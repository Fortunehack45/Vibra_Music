import Foundation

/// A small, read-only DOM built on `XMLParser`, which is all Foundation offers on iOS
/// (`XMLDocument` is macOS-only). It reproduces the one thing the TTML reader depends on
/// from Android's non-namespace-aware `DocumentBuilder`: names are kept exactly as written,
/// prefix and all (`ttm:agent`, `xml:id`), so they can be looked up by their qualified name.
///
/// External entities are never resolved (`shouldResolveExternalEntities` stays false) —
/// lyrics arrive from third-party hosts.
final class LyricsXMLNode {
    enum Kind {
        case element(name: String, attributes: [String: String])
        case text(String)
        /// Kept apart from text, as the DOM keeps CDATA sections apart from text nodes.
        case cdata(String)
    }

    let kind: Kind
    fileprivate(set) var children: [LyricsXMLNode] = []

    init(_ kind: Kind) { self.kind = kind }

    var name: String? {
        if case .element(let name, _) = kind { return name }
        return nil
    }

    var isElement: Bool { name != nil }

    var isText: Bool {
        if case .text = kind { return true }
        return false
    }

    /// DOM `getAttribute`: the value, or `""` when absent.
    func attribute(_ name: String) -> String {
        if case .element(_, let attributes) = kind { return attributes[name] ?? "" }
        return ""
    }

    var attributes: [String: String] {
        if case .element(_, let attributes) = kind { return attributes }
        return [:]
    }

    /// DOM `textContent`: every descendant's text, in document order.
    var textContent: String {
        switch kind {
        case .text(let text), .cdata(let text): return text
        case .element: return children.map(\.textContent).joined()
        }
    }

    /// DOM `getElementsByTagName`: every descendant element with exactly this name, in
    /// document order.
    func elements(named name: String) -> [LyricsXMLNode] {
        var found = [LyricsXMLNode]()
        func walk(_ node: LyricsXMLNode) {
            for child in node.children where child.isElement {
                if child.name == name { found.append(child) }
                walk(child)
            }
        }
        walk(self)
        return found
    }

    /// The document in `text`, or nil if it is not well-formed. The returned node is a
    /// synthetic document root whose children are the top-level nodes.
    static func parse(_ text: String) -> LyricsXMLNode? {
        guard let data = text.data(using: .utf8) else { return nil }
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse(), builder.failed == false, builder.stack.count == 1 else { return nil }
        return builder.root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        let root = LyricsXMLNode(.element(name: "#document", attributes: [:]))
        lazy var stack: [LyricsXMLNode] = [root]
        var failed = false

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            let node = LyricsXMLNode(.element(name: qualifiedName ?? elementName, attributes: attributes))
            stack.last?.children.append(node)
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            if stack.count > 1 { stack.removeLast() }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            appendText(string)
        }

        func parser(_ parser: XMLParser, foundIgnorableWhitespace whitespaceString: String) {
            appendText(whitespaceString)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            stack.last?.children.append(LyricsXMLNode(.cdata(String(decoding: CDATABlock, as: UTF8.self))))
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            failed = true
        }

        /// Adjacent character callbacks (split around entity references) are one text node,
        /// as a DOM parser would have them.
        private func appendText(_ string: String) {
            guard let parent = stack.last else { return }
            if let last = parent.children.last, case .text(let existing) = last.kind {
                parent.children[parent.children.count - 1] = LyricsXMLNode(.text(existing + string))
            } else {
                parent.children.append(LyricsXMLNode(.text(string)))
            }
        }
    }
}
