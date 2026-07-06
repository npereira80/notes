import Foundation

/// Builds Joplin's plain-text item serialization (the reverse of JoplinItemParser) for
/// push sync. Port of Android App's JoplinItemSerializer.kt — keep both in sync,
/// including the two bugs already found and fixed there:
/// 1. No trailing newline after the last footer line (breaks JoplinItemParser's
///    backward scan, silently dropping every property including the required type_).
/// 2. Always write markup_language=1 (Markdown) — HtmlToMarkdown always produces real
///    Markdown, so a note that started as markup_language=2 (Joplin's rich-text/HTML
///    format) must not keep that stale flag once we've rewritten its body.
enum JoplinItemSerializer {

    private static let isoFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func serialize(_ note: Note) -> String {
        let markdown = HtmlToMarkdown.convert(note.body)
        let props: [(String, String)] = [
            ("id", note.id),
            ("parent_id", note.folderId),
            ("created_time", formatTime(note.createdTime)),
            ("updated_time", formatTime(note.updatedTime)),
            ("is_todo", note.isTodo ? "1" : "0"),
            ("todo_completed", note.todoCompleted ? "1" : "0"),
            ("markup_language", "1"),
            // Plain epoch-millis integer, NOT an ISO date string like created_time/
            // updated_time — deleted_time is an ordinary int field in Joplin, same as
            // is_todo/file_size, not one of the handful of fields Joplin formats as a
            // date. Written explicitly (never omitted) so "0" unambiguously means "not
            // trashed" to any reader.
            ("deleted_time", epochMillisString(note.deletedTime)),
            // Standard Joplin has no native pinned-note field, so we stash it in
            // application_data — a real Joplin field meant for exactly this kind of
            // app-specific custom data, blank when unused (matches Joplin's own
            // convention). Whatever else might be in this field is not preserved —
            // acceptable here since this app is the only writer of it in practice.
            ("application_data", note.isPinned ? "{\"pinned\":true}" : ""),
            ("type_", "1"),
        ]
        return buildItem(title: note.title, body: markdown, props: props)
    }

    static func serialize(_ folder: Folder) -> String {
        let props: [(String, String)] = [
            ("id", folder.id),
            ("created_time", formatTime(folder.createdTime)),
            ("updated_time", formatTime(folder.updatedTime)),
            ("deleted_time", epochMillisString(folder.deletedTime)),
            ("type_", "2"),
        ]
        return buildItem(title: folder.title, body: "", props: props)
    }

    /// Resource (attachment/image) metadata item — the binary bytes go to a separate
    /// `.resource/{id}` path (see JoplinCloudApi.putResourceBlob), this is just the
    /// `{id}.md`-style metadata Joplin Server expects alongside it. Resource has no
    /// createdTime/updatedTime of its own (unlike Note/Folder), so both are stamped as
    /// "now" at push time — these are descriptive metadata only, never used by our own
    /// pull logic for conflict resolution.
    static func serialize(_ resource: Resource) -> String {
        let ext = (resource.filename as NSString).pathExtension
        let now = formatTime(Date())
        let props: [(String, String)] = [
            ("id", resource.id),
            ("mime", resource.mimeType),
            ("file_extension", ext),
            ("size", String(resource.fileSize)),
            ("created_time", now),
            ("updated_time", now),
            ("type_", "4"),
        ]
        return buildItem(title: resource.title, body: "", props: props)
    }

    /// No trailing newline after the last footer line — see doc comment above.
    private static func buildItem(title: String, body: String, props: [(String, String)]) -> String {
        let footer = props.map { key, value in "\(key): \(escapeValue(value))" }.joined(separator: "\n")
        return "\(title)\n\n\(body)\n\n\(footer)"
    }

    private static func formatTime(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private static func epochMillisString(_ date: Date?) -> String {
        String(Int64((date ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970 * 1000))
    }

    // Footer lines are single-line key:value pairs — escape any embedded newlines,
    // matching BaseItem.serialize_format()'s \n -> \\n / \r -> \\r escaping.
    private static func escapeValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
