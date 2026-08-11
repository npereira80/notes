import Foundation

/// Two-way sync with Joplin Cloud. Pull runs first (downloads notes/folders/resources,
/// remote wins over local on a timestamp tie per item), then push (uploads anything
/// locally dirty, plus queued deletes) — pulling first means the push phase only ever
/// uploads content that's genuinely newer than what's on the server, which is what
/// gives "last write wins by timestamp" its meaning instead of just clobbering remote
/// edits pushed here with a stale local copy. See DatabaseManager's is_dirty/is_synced
/// columns and pending_deletes table.
///
/// Port of Android App's JoplinSyncEngine.kt — keep both in sync.
actor JoplinSyncEngine {

    private let db = DatabaseManager.shared
    private let prefs = UserDefaults.standard
    private let cursorKey = "joplin_sync_delta_cursor"

    enum SyncOutcome {
        case success(notesUpdated: Int, foldersUpdated: Int, notesPushed: Int, foldersPushed: Int, resourcesPushed: Int)
        // Distinct from .failure so the caller (AppState.syncNow) can attempt a silent
        // re-login and retry, instead of just surfacing an error message.
        case unauthorized
        case failure(String)
    }

    private enum PushOutcome {
        case success(notesPushed: Int, foldersPushed: Int, resourcesPushed: Int)
        case unauthorized
        case failure(String)
    }

    private var cursor: String? {
        get { prefs.string(forKey: cursorKey) }
        set { prefs.set(newValue, forKey: cursorKey) }
    }

    /// `force` resyncs everything from scratch and overwrites local notes regardless
    /// of timestamps — used for Cmd+R "Force Resync", e.g. after a fix to how we
    /// convert Markdown to HTML, so already-pulled notes pick up the new conversion
    /// even though nothing actually changed on the Joplin Cloud side. A normal sync
    /// only touches items whose remote updated_time is newer, and only sees items at
    /// all if they appear in the delta since the last saved cursor — force resets both.
    func sync(sessionId: String, force: Bool = false) async -> SyncOutcome {
        var notesUpdated = 0
        var foldersUpdated = 0
        var pageCursor: String? = force ? nil : cursor

        // Collect every change across all delta pages first, then process resources
        // before notes/folders. Notes reference resources by id (`:/resourceId`), and a
        // resource can appear later in the same delta than the note that embeds it —
        // resolving links only works if the resource is already local.
        var allChanges: [JoplinCloudApi.DeltaChange] = []
        var hasMorePages = true
        while hasMorePages {
            let result = await JoplinCloudApi.delta(sessionId: sessionId, cursor: pageCursor)
            switch result {
            case .failure(let error):
                return mapFailure(error)
            case .success(let delta):
                allChanges.append(contentsOf: delta.items)
                hasMorePages = delta.hasMore
                if hasMorePages {
                    pageCursor = delta.cursor
                } else {
                    cursor = delta.cursor
                }
            }
        }

        var parsedItems: [JoplinItemParser.ParsedItem] = []
        for change in allChanges {
            guard let itemName = change.itemName else { continue }
            // The resource blob lives at its own path (".resource/{id}"), separate from
            // the "{id}.md" metadata item. Its content isn't text and isn't parseable
            // via JoplinItemParser — it's fetched on demand by id from upsertResource()
            // below, driven by the metadata item instead.
            if itemName.hasPrefix(".resource/") { continue }

            if change.type == Self.changeTypeDelete {
                // Only remove local rows that a previous pull created — never touch
                // items that only ever existed locally. A delta delete doesn't say
                // what type the item was (the content is already gone server-side),
                // so try all three tables: ids are globally unique in Joplin, so the
                // two misses are safe no-ops. Handling only notes here meant a
                // notebook or resource deleted on another device stayed around
                // locally forever (ghost folders that not even a relaunch cleared).
                let id = itemName.hasSuffix(".md") ? String(itemName.dropLast(3)) : itemName
                db.deleteNote(id: id)
                db.deleteFolder(id: id)
                db.deleteResource(id: id)
                continue
            }

            switch await JoplinCloudApi.itemContent(sessionId: sessionId, itemName: itemName) {
            case .failure(let error): return mapFailure(error)
            case .success(let content): parsedItems.append(JoplinItemParser.parse(content))
            }
        }

        // Resources first (see comment above), then notes/folders so image links can
        // be resolved against already-downloaded resources.
        for parsed in parsedItems where parsed.props["type_"] == Self.typeResource {
            await upsertResource(parsed, sessionId: sessionId, force: force)
        }
        for parsed in parsedItems {
            switch parsed.props["type_"] {
            case Self.typeNote: if upsertNote(parsed, force: force) { notesUpdated += 1 }
            case Self.typeFolder: if upsertFolder(parsed, force: force) { foldersUpdated += 1 }
            default: break
            }
        }

        // One-time cleanup: only ever runs during a Force Resync (see doc comment on
        // `force` above), and self-deactivates via headingCleanupDoneKey after its first
        // successful pass, so it never touches notes again after the import artifact is
        // cleaned up.
        if force {
            runHeadingCleanupIfNeeded()
        }

        switch await push(sessionId: sessionId) {
        case .unauthorized:
            return .unauthorized
        case .failure(let message):
            return .failure(message)
        case .success(let notesPushed, let foldersPushed, let resourcesPushed):
            return .success(
                notesUpdated: notesUpdated,
                foldersUpdated: foldersUpdated,
                notesPushed: notesPushed,
                foldersPushed: foldersPushed,
                resourcesPushed: resourcesPushed
            )
        }
    }

    /// Uploads anything locally dirty (edited or newly created notes/folders/resources)
    /// and processes queued remote deletes. Joplin Server has a single PUT-upserts-content
    /// endpoint — no separate "create" call — so a brand-new local note and an edit to
    /// an already-synced one are pushed identically. Resources are pushed before notes,
    /// mirroring pull's resources-before-notes order, so a note's `:/resourceId` links
    /// resolve to something that already exists remotely as soon as the note lands.
    private func push(sessionId: String) async -> PushOutcome {
        for pending in db.fetchPendingDeletes() {
            if case .failure(let error) = await JoplinCloudApi.deleteItem(sessionId: sessionId, itemName: "\(pending.id).md") {
                return mapPushFailure(error)
            }
            // A resource is two separate remote files — its `{id}.md` metadata (just
            // deleted above) and its binary blob at `.resource/{id}` — both need removing.
            if pending.itemType == "resource" {
                if case .failure(let error) = await JoplinCloudApi.deleteItem(sessionId: sessionId, itemName: ".resource/\(pending.id)") {
                    return mapPushFailure(error)
                }
            }
            db.clearPendingDelete(id: pending.id)
        }

        var resourcesPushed = 0
        for resource in db.fetchDirtyResources() {
            let metadata = Data(JoplinItemSerializer.serialize(resource).utf8)
            if case .failure(let error) = await JoplinCloudApi.putItemContent(sessionId: sessionId, itemName: "\(resource.id).md", content: metadata) {
                return mapPushFailure(error)
            }
            guard let dir = db.resourcesDirectory,
                  let bytes = try? Data(contentsOf: dir.appendingPathComponent(resource.filename)) else {
                return .failure("Couldn't read local file for resource \(resource.id).")
            }
            if case .failure(let error) = await JoplinCloudApi.putResourceBlob(sessionId: sessionId, resourceId: resource.id, content: bytes) {
                return mapPushFailure(error)
            }
            db.markResourceSynced(id: resource.id)
            resourcesPushed += 1
        }

        var notesPushed = 0
        for note in db.fetchDirtyNotes() {
            let content = Data(JoplinItemSerializer.serialize(note).utf8)
            if case .failure(let error) = await JoplinCloudApi.putItemContent(sessionId: sessionId, itemName: "\(note.id).md", content: content) {
                return mapPushFailure(error)
            }
            db.markNoteSynced(id: note.id)
            notesPushed += 1
        }

        var foldersPushed = 0
        for folder in db.fetchDirtyFolders() {
            let content = Data(JoplinItemSerializer.serialize(folder).utf8)
            if case .failure(let error) = await JoplinCloudApi.putItemContent(sessionId: sessionId, itemName: "\(folder.id).md", content: content) {
                return mapPushFailure(error)
            }
            db.markFolderSynced(id: folder.id)
            foldersPushed += 1
        }

        return .success(notesPushed: notesPushed, foldersPushed: foldersPushed, resourcesPushed: resourcesPushed)
    }

    private func upsertNote(_ parsed: JoplinItemParser.ParsedItem, force: Bool) -> Bool {
        guard let id = parsed.props["id"] else { return false }
        // Already permanently deleted locally, pending a push to remove it from the
        // server too — pull runs before push, so the server's still-current copy would
        // otherwise resurrect it here just before push tells the server to delete it.
        if db.hasPendingDelete(id: id) { return false }
        let remoteUpdatedTime = JoplinItemParser.parseTime(parsed.props["updated_time"])
        if !force, let localUpdatedTime = db.noteUpdatedTime(id: id), localUpdatedTime >= remoteUpdatedTime {
            return false
        }

        let isHtml = parsed.props["markup_language"] == "2"
        let converted = isHtml ? parsed.body : MarkdownToHtml.convert(parsed.body)
        let body = fillAttachmentMetadata(rewriteResourceLinks(converted))

        db.saveNote(Note(
            id: id,
            folderId: parsed.props["parent_id"] ?? "",
            title: parsed.title,
            body: body,
            createdTime: Date(timeIntervalSince1970: Double(JoplinItemParser.parseTime(parsed.props["created_time"])) / 1000),
            updatedTime: Date(timeIntervalSince1970: Double(remoteUpdatedTime) / 1000),
            isTodo: parsed.props["is_todo"] == "1",
            todoCompleted: parsed.props["todo_completed"] != nil && parsed.props["todo_completed"] != "0",
            deletedTime: Self.parseDeletedTime(parsed.props["deleted_time"]),
            isPinned: Self.parseIsPinned(parsed.props["application_data"])
        ), dirty: false, synced: true)
        return true
    }

    private func upsertFolder(_ parsed: JoplinItemParser.ParsedItem, force: Bool) -> Bool {
        guard let id = parsed.props["id"] else { return false }
        // See the matching comment in upsertNote — same resurrection risk.
        if db.hasPendingDelete(id: id) { return false }
        let remoteUpdatedTime = JoplinItemParser.parseTime(parsed.props["updated_time"])
        if !force, let localUpdatedTime = db.folderUpdatedTime(id: id), localUpdatedTime >= remoteUpdatedTime {
            return false
        }

        db.saveFolder(Folder(
            id: id,
            title: parsed.title,
            createdTime: Date(timeIntervalSince1970: Double(JoplinItemParser.parseTime(parsed.props["created_time"])) / 1000),
            updatedTime: Date(timeIntervalSince1970: Double(remoteUpdatedTime) / 1000),
            deletedTime: Self.parseDeletedTime(parsed.props["deleted_time"])
        ), dirty: false, synced: true)
        return true
    }

    /// deleted_time is a plain epoch-millis integer (like is_todo/file_size), NOT an
    /// ISO date string like created_time/updated_time — using JoplinItemParser.parseTime()
    /// here was a bug: it expects ISO-8601, and its fallback for anything unparseable is
    /// "now", which made every note pulled from a real Joplin client (whose deleted_time
    /// is a plain int, not ISO) look freshly trashed. A missing/blank/unparseable value
    /// must mean "not trashed" (nil) instead.
    private static func parseDeletedTime(_ value: String?) -> Date? {
        guard let value, let ms = Int64(value), ms != 0 else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    /// application_data isn't a Joplin field we own — it's blank unless this app set
    /// it (see JoplinItemSerializer), so any parse failure just means "not pinned"
    /// rather than a real error worth surfacing.
    private static func parseIsPinned(_ value: String?) -> Bool {
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return false }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json["pinned"] as? Bool ?? false
    }

    /// Downloads a resource's binary blob (image, etc.) and saves it into the same
    /// resourcesDirectory / `resources` table the app already uses for locally-attached
    /// images (see EditorView.handleImagePick), so the WKWebView's existing
    /// allowingReadAccessTo file:// access can serve it unchanged.
    private func upsertResource(_ parsed: JoplinItemParser.ParsedItem, sessionId: String, force: Bool) async {
        guard let id = parsed.props["id"] else { return }
        // See the matching comment in upsertNote — same resurrection risk.
        if db.hasPendingDelete(id: id) { return }
        if !force && db.resourceExists(id: id) { return }

        let mime = parsed.props["mime"] ?? ""
        let extensionFromMime = mime.split(separator: "/").last.map(String.init)
        let ext = parsed.props["file_extension"].flatMap { $0.isEmpty ? nil : $0 } ?? extensionFromMime ?? "bin"
        let filename = "\(id).\(ext)"

        guard case .success(let bytes) = await JoplinCloudApi.resourceBlob(sessionId: sessionId, resourceId: id),
              let dir = db.resourcesDirectory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? bytes.write(to: dir.appendingPathComponent(filename))

        db.saveResource(Resource(
            id: id,
            title: parsed.title,
            mimeType: mime,
            filename: filename,
            fileSize: Int(parsed.props["size"] ?? "") ?? bytes.count,
            noteId: ""
        ), dirty: false, synced: true)
    }

    // Attachment card as MarkdownToHtml emits it from a [name](:/id) link — it can only
    // know the id and the link text, so size/mime come from the resources table here.
    private static let attachmentCardRegex = try! NSRegularExpression(
        pattern: #"<div class="pm-attachment" data-resource-id="([0-9a-fA-F]{32})" data-title="([^"]*)" data-size="0" data-mime=""></div>"#
    )

    /// Escapes a value going into an HTML attribute. escapeHtml elsewhere is written for
    /// text content and leaves quotes alone, which would end the attribute early — a
    /// filename like My "Notes" File.pdf would corrupt the tag.
    private func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Fills in an attachment card's size and MIME type (and its name, if the link had
    /// none) from the locally stored resource. A resource that hasn't been downloaded
    /// yet is left as-is — the card still shows its name and stays openable once the
    /// blob arrives on a later sync.
    private func fillAttachmentMetadata(_ html: String) -> String {
        let regex = Self.attachmentCardRegex
        let nsHtml = html as NSString
        let matchesFound = regex.matches(in: html, range: NSRange(location: 0, length: nsHtml.length))
        guard !matchesFound.isEmpty else { return html }

        var result = ""
        var lastEnd = 0
        for match in matchesFound {
            result += nsHtml.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            let id = nsHtml.substring(with: match.range(at: 1))
            let linkText = nsHtml.substring(with: match.range(at: 2))
            if let meta = db.resourceMeta(id: id) {
                let title = linkText.isEmpty ? meta.title : linkText
                result += "<div class=\"pm-attachment\" data-resource-id=\"\(id)\" data-title=\"\(escapeAttribute(title))\" data-size=\"\(meta.size)\" data-mime=\"\(escapeAttribute(meta.mime))\"></div>"
            } else if db.noteUpdatedTime(id: id) != nil {
                // Joplin uses the same [title](:/id) syntax for a link to another NOTE.
                // MarkdownToHtml can't tell the two apart, but here we can: this id is a
                // note, not a resource, so put the link back rather than leaving a card
                // that could never resolve to a file.
                result += "<a href=\":/\(id)\">\(linkText)</a>"
            } else {
                // Neither a known resource nor a note — most likely a resource whose
                // blob hasn't been downloaded yet. Leave the card; it fills in on a
                // later sync.
                result += nsHtml.substring(with: match.range)
            }
            lastEnd = match.range.location + match.range.length
        }
        result += nsHtml.substring(with: NSRange(location: lastEnd, length: nsHtml.length - lastEnd))
        return result
    }

    /// Rewrites Joplin's `:/resourceId` link syntax (inside src="..."/href="...") into
    /// the local file:// URL for that resource, once it's been synced. Links to a
    /// resource that hasn't synced yet (or was never one) are left untouched.
    private func rewriteResourceLinks(_ html: String) -> String {
        let regex = Self.resourceLinkRegex
        let nsHtml = html as NSString
        let fullRange = NSRange(location: 0, length: nsHtml.length)
        let matchesFound = regex.matches(in: html, range: fullRange)
        guard !matchesFound.isEmpty else { return html }

        var result = ""
        var lastEnd = 0
        for match in matchesFound {
            result += nsHtml.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            let attr = nsHtml.substring(with: match.range(at: 1))
            let id = nsHtml.substring(with: match.range(at: 3))
            if let localUrl = db.resourceLocalUrl(id: id) {
                result += "\(attr)=\"\(localUrl)\""
            } else {
                result += nsHtml.substring(with: match.range)
            }
            lastEnd = match.range.location + match.range.length
        }
        result += nsHtml.substring(with: NSRange(location: lastEnd, length: nsHtml.length - lastEnd))
        return result
    }

    /// One-off fix for notes imported from UpNote via Joplin's Markdown import: Joplin's
    /// importer read each note's leading "## Title" heading as the note's title AND left
    /// a duplicate copy of that heading in the body, so every imported note showed its
    /// title twice. Runs at most once (guarded by headingCleanupDoneKey below, flipped to
    /// true at the end) — strips the note's leading heading only when its text is an
    /// exact match (after trimming whitespace) for the note's title, then marks the note
    /// dirty so the push() call right after this uploads the fix to Joplin Cloud too, so
    /// it sticks after future syncs instead of only fixing the local copy. Only mutates
    /// `body` on a copy of the existing Note — createdTime/updatedTime are carried over
    /// untouched, so the note list's date-based ordering doesn't reshuffle.
    // Flip to true only to re-run the cleanup (e.g. a fresh install where
    // headingCleanupDoneKey isn't set yet, or a future re-import). Left false after the
    // one real cleanup pass completed successfully, so the code stays in place but never
    // runs again even if the UserDefaults flag below were ever cleared.
    private static let headingCleanupEnabled = false
    private static let headingCleanupDoneKey = "hasCleanedImportHeadings"
    // Anchored to the very start of the body on purpose — the importer only ever
    // duplicated the *first* heading, so later same-named headings must be left alone.
    private static let leadingHeadingRegex = try! NSRegularExpression(
        pattern: "^\\s*<h([1-6])[^>]*>(.*?)</h\\1>",
        options: [.dotMatchesLineSeparators]
    )

    private func runHeadingCleanupIfNeeded() {
        guard Self.headingCleanupEnabled else { return }
        guard !prefs.bool(forKey: Self.headingCleanupDoneKey) else { return }
        for note in db.fetchNotes(folderId: nil) {
            guard let fixedBody = Self.stripDuplicateHeading(from: note.body, title: note.title) else { continue }
            var fixed = note
            fixed.body = fixedBody
            db.saveNote(fixed, dirty: true, synced: false)
        }
        prefs.set(true, forKey: Self.headingCleanupDoneKey)
    }

    /// Returns the body with its leading heading removed if that heading's text exactly
    /// matches the title (after trimming whitespace on both sides), else nil.
    private static func stripDuplicateHeading(from body: String, title: String) -> String? {
        let nsBody = body as NSString
        guard let match = leadingHeadingRegex.firstMatch(in: body, range: NSRange(location: 0, length: nsBody.length)) else {
            return nil
        }
        let rawHeadingText = nsBody.substring(with: match.range(at: 2))
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let headingText = decodeEntities(rawHeadingText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard headingText == title.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return nsBody.substring(from: match.range.location + match.range.length)
    }

    // Same entity set Note.preview already decodes — kept identical for consistency.
    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }

    private func describeError(_ error: JoplinCloudApi.SyncApiError) -> String {
        error.errorDescription ?? "Sync failed."
    }

    private func mapFailure(_ error: JoplinCloudApi.SyncApiError) -> SyncOutcome {
        if case .unauthorized = error { return .unauthorized }
        return .failure(describeError(error))
    }

    private func mapPushFailure(_ error: JoplinCloudApi.SyncApiError) -> PushOutcome {
        if case .unauthorized = error { return .unauthorized }
        return .failure(describeError(error))
    }

    private static let changeTypeDelete = 3
    private static let typeNote = "1"
    private static let typeFolder = "2"
    private static let typeResource = "4"
    // Matches src="..."/href="..." attributes whose value is Joplin's ":/{32-hex-id}"
    // resource link syntax, e.g. src=":/4a6ec8ff...".
    private static let resourceLinkRegex = try! NSRegularExpression(pattern: "(src|href)=\"(:/([0-9a-fA-F]{32}))\"")
}
