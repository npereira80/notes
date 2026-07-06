import Foundation

struct Note: Identifiable, Hashable, Equatable {
    // Joplin-compatible: 32-char lowercase hex, no hyphens
    let id: String
    var folderId: String      // maps to parent_id in Joplin schema
    var title: String
    var body: String          // stored as HTML; convert to Markdown at sync time
    var createdTime: Date
    var updatedTime: Date
    var isTodo: Bool
    var todoCompleted: Bool
    var deletedTime: Date?   // nil = not trashed
    // Not a native Joplin field (standard Joplin has no pinned-note concept) — stored
    // in the note's own application_data JSON, a real Joplin field meant for exactly
    // this kind of app-specific custom state, so it round-trips safely through Joplin
    // Cloud sync. See JoplinItemSerializer/JoplinItemParser.
    var isPinned: Bool

    init(
        id: String = Note.generateId(),
        folderId: String = "",
        title: String = "",
        body: String = "",
        createdTime: Date = Date(),
        updatedTime: Date = Date(),
        isTodo: Bool = false,
        todoCompleted: Bool = false,
        deletedTime: Date? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.folderId = folderId
        self.title = title
        self.body = body
        self.createdTime = createdTime
        self.updatedTime = updatedTime
        self.isTodo = isTodo
        self.todoCompleted = todoCompleted
        self.deletedTime = deletedTime
        self.isPinned = isPinned
    }

    // Joplin uses 32-char lowercase hex IDs
    static func generateId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    // Plain-text preview extracted from HTML body
    var preview: String {
        guard !body.isEmpty else { return "" }
        // Strip HTML tags
        let noTags = body.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // Collapse whitespace and newlines
        let collapsed = noTags
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            // Decode common HTML entities
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespaces)
        return String(collapsed.prefix(160))
    }

    // Resource id of the first image in the body, or nil if there is none — used
    // for the note list's thumbnail (mirrors Apple Notes' list row thumbnail).
    var firstImageResourceId: String? {
        guard let imgRange = body.range(of: "<img\\b[^>]*>", options: .regularExpression) else { return nil }
        let imgTag = String(body[imgRange])
        guard let idRange = imgTag.range(of: "data-resource-id=\"([^\"]*)\"", options: .regularExpression) else { return nil }
        let attr = String(imgTag[idRange])
        let value = attr
            .replacingOccurrences(of: "data-resource-id=\"", with: "")
            .replacingOccurrences(of: "\"", with: "")
        return value.isEmpty ? nil : value
    }
}
