import Foundation

struct Folder: Identifiable, Hashable, Equatable {
    // Joplin-compatible: 32-char lowercase hex, no hyphens
    let id: String
    var title: String
    var createdTime: Date
    var updatedTime: Date
    var deletedTime: Date?   // nil = not trashed

    init(
        id: String = Folder.generateId(),
        title: String = "",
        createdTime: Date = Date(),
        updatedTime: Date = Date(),
        deletedTime: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.createdTime = createdTime
        self.updatedTime = updatedTime
        self.deletedTime = deletedTime
    }

    static func generateId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
