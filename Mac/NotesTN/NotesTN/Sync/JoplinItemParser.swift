import Foundation

/// Parses Joplin's plain-text item serialization: title, blank line, body, blank line,
/// then a footer of `key: value` metadata lines (see BaseItem.serialize() in Joplin's
/// source). We don't know the exact footer key set ahead of time, so we scan from the
/// bottom collecting contiguous `key: value` lines instead of matching a fixed list.
///
/// Port of Android App's JoplinItemParser.kt — keep both in sync.
enum JoplinItemParser {

    struct ParsedItem {
        let title: String
        let body: String
        let props: [String: String]
    }

    private static let propertyLine = try! NSRegularExpression(pattern: "^([a-z_]+): ?(.*)$")

    static func parse(_ raw: String) -> ParsedItem {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        // Walk backward from the end collecting the metadata footer: as long as a line
        // matches "key: value", it's part of the footer; the first line that doesn't
        // (blank separator or actual content) ends the scan.
        var footerStart = lines.count
        for index in stride(from: lines.count - 1, through: 0, by: -1) {
            guard matches(propertyLine, lines[index]) else { break }
            footerStart = index
        }

        var props: [String: String] = [:]
        for index in footerStart..<lines.count {
            guard let match = firstMatch(propertyLine, lines[index]) else { continue }
            props[match.0] = match.1
        }

        // Everything above the footer (minus the blank separator line right before it)
        // is title + blank line + body.
        var aboveFooter = Array(lines[0..<footerStart])
        if let last = aboveFooter.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            aboveFooter.removeLast()
        }

        let title = aboveFooter.first ?? ""
        var body = ""
        if aboveFooter.count > 1 {
            var rest = Array(aboveFooter.dropFirst())
            if let first = rest.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
                rest.removeFirst()
            }
            body = rest.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return ParsedItem(title: title, body: body, props: props)
    }

    /// Joplin serializes timestamps as ISO-8601 (e.g. "2021-08-07T17:03:33.592Z"),
    /// we store epoch millis locally. Falls back to now if unparseable/missing.
    static func parseTime(_ value: String?) -> Int64 {
        guard let value, !value.isEmpty else { return Int64(Date().timeIntervalSince1970 * 1000) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        // Some timestamps may lack fractional seconds.
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        return Int64(Date().timeIntervalSince1970 * 1000)
    }

    private static func matches(_ regex: NSRegularExpression, _ line: String) -> Bool {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return regex.firstMatch(in: line, range: range) != nil
    }

    private static func firstMatch(_ regex: NSRegularExpression, _ line: String) -> (String, String)? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let keyRange = Range(match.range(at: 1), in: line),
              let valueRange = Range(match.range(at: 2), in: line) else { return nil }
        return (String(line[keyRange]), String(line[valueRange]))
    }
}
