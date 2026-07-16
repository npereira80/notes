import Foundation

/// A minimal HTML parser for the specific, well-formed markup ProseMirror's
/// DOMSerializer produces from our schema (see Mac/EditorBundle/src/schema.ts) — not a
/// general HTML parser. Used by HtmlToMarkdown for push sync. Kept dependency-free
/// (no SwiftSoup/libxml2) since this project has no package manager set up; Android's
/// equivalent uses Jsoup since Gradle makes that trivial there.
enum MiniHtmlParser {

    final class HtmlNode {
        let tag: String // "#text" for text nodes
        var attributes: [String: String] = [:]
        var children: [HtmlNode] = []
        var text: String = "" // only meaningful for #text nodes

        init(tag: String) { self.tag = tag }
    }

    // Elements ProseMirror's serializer emits with no closing tag.
    private static let voidTags: Set<String> = ["img", "br", "hr", "input"]

    static func parse(_ html: String) -> [HtmlNode] {
        let chars = Array(html)
        var index = 0
        return parseNodes(chars, &index, until: nil)
    }

    private static func parseNodes(_ chars: [Character], _ index: inout Int, until closingTag: String?) -> [HtmlNode] {
        var nodes: [HtmlNode] = []
        while index < chars.count {
            if chars[index] == "<" {
                // Comment — skip entirely.
                if matches(chars, index, "<!--") {
                    index = (findRange(chars, from: index, of: "-->") ?? chars.count - 3) + 3
                    continue
                }
                // Closing tag — if it's ours, consume and stop; otherwise stop without
                // consuming (a mismatched closer shouldn't happen with our own output,
                // but bail out gracefully rather than looping forever).
                if chars[index + 1] == "/" {
                    let end = findChar(chars, from: index, ">") ?? chars.count
                    let name = String(chars[(index + 2)..<end]).trimmingCharacters(in: .whitespaces).lowercased()
                    index = end + 1
                    if name == closingTag { return nodes }
                    continue
                }
                // Opening tag.
                let (node, selfClosing, nextIndex) = parseOpeningTag(chars, index)
                index = nextIndex
                if !selfClosing && !voidTags.contains(node.tag) {
                    node.children = parseNodes(chars, &index, until: node.tag)
                }
                nodes.append(node)
            } else {
                let start = index
                while index < chars.count && chars[index] != "<" { index += 1 }
                let text = decodeEntities(String(chars[start..<index]))
                if !text.isEmpty {
                    let textNode = HtmlNode(tag: "#text")
                    textNode.text = text
                    nodes.append(textNode)
                }
            }
        }
        return nodes
    }

    /// Parses `<tagname attr="value" ...>` or `<tagname .../>`, returning the node,
    /// whether it was self-closed, and the index right after the closing `>`.
    private static func parseOpeningTag(_ chars: [Character], _ start: Int) -> (HtmlNode, Bool, Int) {
        var i = start + 1 // skip '<'
        let nameStart = i
        while i < chars.count && !chars[i].isWhitespace && chars[i] != ">" && chars[i] != "/" { i += 1 }
        let tag = String(chars[nameStart..<i]).lowercased()
        let node = HtmlNode(tag: tag)

        var selfClosing = false
        while i < chars.count && chars[i] != ">" {
            if chars[i] == "/" {
                selfClosing = true
                i += 1
                continue
            }
            if chars[i].isWhitespace { i += 1; continue }
            let attrNameStart = i
            while i < chars.count && chars[i] != "=" && chars[i] != ">" && chars[i] != "/" && !chars[i].isWhitespace { i += 1 }
            let attrName = String(chars[attrNameStart..<i]).lowercased()
            while i < chars.count && chars[i].isWhitespace { i += 1 }
            if i < chars.count && chars[i] == "=" {
                i += 1
                while i < chars.count && chars[i].isWhitespace { i += 1 }
                if i < chars.count && (chars[i] == "\"" || chars[i] == "'") {
                    let quote = chars[i]
                    i += 1
                    let valueStart = i
                    while i < chars.count && chars[i] != quote { i += 1 }
                    if !attrName.isEmpty { node.attributes[attrName] = decodeEntities(String(chars[valueStart..<i])) }
                    if i < chars.count { i += 1 } // skip closing quote
                }
            } else if !attrName.isEmpty {
                node.attributes[attrName] = ""
            }
        }
        if i < chars.count { i += 1 } // skip '>'
        return (node, selfClosing, i)
    }

    private static func matches(_ chars: [Character], _ index: Int, _ literal: String) -> Bool {
        let litChars = Array(literal)
        guard index + litChars.count <= chars.count else { return false }
        return Array(chars[index..<(index + litChars.count)]) == litChars
    }

    private static func findChar(_ chars: [Character], from: Int, _ target: Character) -> Int? {
        var i = from
        while i < chars.count { if chars[i] == target { return i }; i += 1 }
        return nil
    }

    private static func findRange(_ chars: [Character], from: Int, of literal: String) -> Int? {
        let litChars = Array(literal)
        var i = from
        while i + litChars.count <= chars.count {
            if Array(chars[i..<(i + litChars.count)]) == litChars { return i }
            i += 1
        }
        return nil
    }

    private static func decodeEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&") // must be last — it would otherwise re-corrupt the above
    }
}
