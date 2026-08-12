package com.ikuteam.notestn.data.joplin

import android.content.Context
import android.util.Log
import com.ikuteam.notestn.data.DatabaseManager
import com.ikuteam.notestn.data.Folder
import com.ikuteam.notestn.data.Note
import com.ikuteam.notestn.data.Resource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File

/**
 * Two-way sync with Joplin Cloud, Android only for now. Pull runs first (downloads
 * notes/folders/resources, remote wins over local on a timestamp tie per item), then
 * push (uploads anything locally dirty, plus queued deletes) — pulling first means the
 * push phase only ever uploads content that's genuinely newer than what's on the
 * server, which is what gives "last write wins by timestamp" its meaning instead of
 * just clobbering remote edits pushed here with a stale local copy. See
 * DatabaseManager's is_dirty/is_synced columns and pending_deletes table.
 */
class JoplinSyncEngine(context: Context) {

    private val appContext = context.applicationContext
    private val prefs = appContext.getSharedPreferences("joplin_sync_state", Context.MODE_PRIVATE)
    private val db = DatabaseManager.shared

    sealed class SyncOutcome {
        data class Success(
            val notesUpdated: Int,
            val foldersUpdated: Int,
            val notesPushed: Int = 0,
            val foldersPushed: Int = 0,
            val resourcesPushed: Int = 0,
        ) : SyncOutcome()
        // Distinct from Failure so the caller can attempt a silent re-login and retry,
        // instead of just surfacing an error message.
        data object Unauthorized : SyncOutcome()
        data class Failure(val message: String) : SyncOutcome()
    }

    private var cursor: String?
        get() = prefs.getString(KEY_CURSOR, null)
        set(value) = prefs.edit().putString(KEY_CURSOR, value).apply()

    /** [force] resyncs everything from scratch and overwrites local notes regardless
     * of timestamps — used for "Force Resync" in Settings, e.g. after a fix to how we
     * convert Markdown to HTML, so already-pulled notes pick up the new conversion
     * even though nothing actually changed on the Joplin Cloud side. A normal sync
     * only touches items whose remote updated_time is newer, and only sees items at
     * all if they appear in the delta since the last saved cursor — force resets both. */
    suspend fun sync(force: Boolean = false): SyncOutcome = withContext(Dispatchers.IO) {
        val account = JoplinAccountStore.shared.account.value
            ?: return@withContext SyncOutcome.Failure("Not logged in to Joplin Cloud.")

        var notesUpdated = 0
        var foldersUpdated = 0
        var pageCursor = if (force) null else cursor
        val startedAt = System.currentTimeMillis()
        Log.i(LOG_TAG, "sync start: force=$force, cursor=${pageCursor ?: "(none, full pull)"}")

        try {
            // Collect every change across all delta pages first, then process resources
            // before notes/folders. Notes reference resources by id (`:/resourceId`),
            // and a resource can appear later in the same delta than the note that
            // embeds it — resolving links only works if the resource is already local.
            val allChanges = mutableListOf<JoplinCloudApi.DeltaChange>()
            while (true) {
                val delta = JoplinCloudApi.delta(account.sessionId, pageCursor).getOrElse { error ->
                    Log.w(LOG_TAG, "delta failed after ${allChanges.size} changes: ${describe(error)}")
                    return@withContext mapFailure(error)
                }
                allChanges.addAll(delta.items)
                Log.i(LOG_TAG, "delta page: ${delta.items.size} changes, has_more=${delta.has_more}")
                if (!delta.has_more) {
                    cursor = delta.cursor
                    break
                }
                pageCursor = delta.cursor
            }

            val parsedItems = mutableListOf<JoplinItemParser.ParsedItem>()
            for (change in allChanges) {
                val itemName = change.item_name ?: continue
                // The resource blob lives at its own path (".resource/{id}"), separate
                // from the "{id}.md" metadata item. Its content isn't text and isn't
                // parseable via JoplinItemParser — it's fetched on demand by id from
                // upsertResource() below, driven by the metadata item instead.
                if (itemName.startsWith(".resource/")) continue

                if (change.type == CHANGE_TYPE_DELETE) {
                    // Only remove local rows that a previous pull created — never
                    // touch items that only ever existed locally. A delta delete
                    // doesn't say what type the item was (the content is already gone
                    // server-side), so try all three tables: ids are globally unique
                    // in Joplin, so the two misses are safe no-ops. Handling only
                    // notes here meant a notebook or resource deleted on another
                    // device stayed around locally forever (ghost folders that not
                    // even an app restart cleared).
                    val id = itemName.removeSuffix(".md")
                    db.deleteNote(id)
                    db.deleteFolder(id)
                    db.deleteResource(id)
                    continue
                }

                val content = JoplinCloudApi.itemContent(account.sessionId, itemName).getOrElse { error ->
                    Log.w(LOG_TAG, "fetching $itemName failed (${parsedItems.size} of ${allChanges.size} done): ${describe(error)}")
                    return@withContext mapFailure(error)
                }
                parsedItems.add(JoplinItemParser.parse(content))
            }

            // Resources first (see comment above), then notes/folders so image links
            // can be resolved against already-downloaded resources.
            for (parsed in parsedItems) {
                if (parsed.props["type_"] == TYPE_RESOURCE) upsertResource(parsed, account.sessionId, force)
            }
            for (parsed in parsedItems) {
                when (parsed.props["type_"]) {
                    TYPE_NOTE -> if (upsertNote(parsed, force)) notesUpdated++
                    TYPE_FOLDER -> if (upsertFolder(parsed, force)) foldersUpdated++
                }
            }

            Log.i(
                LOG_TAG,
                "pulled ${allChanges.size} changes in ${System.currentTimeMillis() - startedAt}ms: " +
                    "$notesUpdated notes, $foldersUpdated notebooks written locally",
            )

            when (val pushResult = push(account.sessionId)) {
                is PushOutcome.Unauthorized -> {
                    Log.w(LOG_TAG, "push: session rejected")
                    SyncOutcome.Unauthorized
                }
                is PushOutcome.Failure -> {
                    Log.w(LOG_TAG, "push failed: ${pushResult.message}")
                    SyncOutcome.Failure(pushResult.message)
                }
                is PushOutcome.Success -> SyncOutcome.Success(
                    notesUpdated = notesUpdated,
                    foldersUpdated = foldersUpdated,
                    notesPushed = pushResult.notesPushed,
                    foldersPushed = pushResult.foldersPushed,
                    resourcesPushed = pushResult.resourcesPushed,
                )
            }
        } catch (t: Throwable) {
            Log.e(LOG_TAG, "sync threw", t)
            SyncOutcome.Failure(t.message ?: "Sync failed.")
        }
    }

    /** Error text for the log: the exception's own type and message, not the friendly
     * wording the banner shows, so a failed sync can be told apart from a slow one. */
    private fun describe(error: Throwable): String =
        "${error::class.simpleName}: ${error.message ?: "(no message)"}"

    private sealed class PushOutcome {
        data class Success(val notesPushed: Int, val foldersPushed: Int, val resourcesPushed: Int) : PushOutcome()
        data object Unauthorized : PushOutcome()
        data class Failure(val message: String) : PushOutcome()
    }

    /** Uploads anything locally dirty (edited or newly created notes/folders/resources)
     * and processes queued remote deletes. Joplin Server has a single PUT-upserts-content
     * endpoint — no separate "create" call — so a brand-new local note and an edit to
     * an already-synced one are pushed identically. Resources are pushed before notes,
     * mirroring pull's resources-before-notes order, so a note's `:/resourceId` links
     * resolve to something that already exists remotely as soon as the note lands. */
    private suspend fun push(sessionId: String): PushOutcome {
        Log.i(
            LOG_TAG,
            "push: ${db.fetchDirtyNotes().size} notes, ${db.fetchDirtyFolders().size} notebooks, " +
                "${db.fetchDirtyResources().size} resources, ${db.fetchPendingDeletes().size} deletes waiting",
        )
        for ((id, itemType) in db.fetchPendingDeletes()) {
            JoplinCloudApi.deleteItem(sessionId, "$id.md").getOrElse { error ->
                return mapPushFailure(error)
            }
            // A resource is two separate remote files — its `{id}.md` metadata (just
            // deleted above) and its binary blob at `.resource/{id}` — both need removing.
            if (itemType == "resource") {
                JoplinCloudApi.deleteItem(sessionId, ".resource/$id").getOrElse { error ->
                    return PushOutcome.Failure(describeError(error))
                }
            }
            db.clearPendingDelete(id)
        }

        var resourcesPushed = 0
        for (resource in db.fetchDirtyResources()) {
            val metadata = JoplinItemSerializer.serialize(resource).toByteArray(Charsets.UTF_8)
            JoplinCloudApi.putItemContent(sessionId, "${resource.id}.md", metadata).getOrElse { error ->
                return mapPushFailure(error)
            }
            val bytes = File(db.resourcesDirectory, resource.filename).readBytes()
            JoplinCloudApi.putResourceBlob(sessionId, resource.id, bytes).getOrElse { error ->
                return mapPushFailure(error)
            }
            db.markResourceSynced(resource.id)
            resourcesPushed++
        }

        var notesPushed = 0
        for (note in db.fetchDirtyNotes()) {
            val content = JoplinItemSerializer.serialize(note).toByteArray(Charsets.UTF_8)
            JoplinCloudApi.putItemContent(sessionId, "${note.id}.md", content).getOrElse { error ->
                return mapPushFailure(error)
            }
            db.markNoteSynced(note.id)
            notesPushed++
        }

        var foldersPushed = 0
        for (folder in db.fetchDirtyFolders()) {
            val content = JoplinItemSerializer.serialize(folder).toByteArray(Charsets.UTF_8)
            JoplinCloudApi.putItemContent(sessionId, "${folder.id}.md", content).getOrElse { error ->
                return mapPushFailure(error)
            }
            db.markFolderSynced(folder.id)
            foldersPushed++
        }

        return PushOutcome.Success(notesPushed, foldersPushed, resourcesPushed)
    }

    private fun upsertNote(parsed: JoplinItemParser.ParsedItem, force: Boolean): Boolean {
        val id = parsed.props["id"] ?: return false
        // Already permanently deleted locally, pending a push to remove it from the
        // server too — pull runs before push, so the server's still-current copy would
        // otherwise resurrect it here just before push tells the server to delete it.
        if (db.hasPendingDelete(id)) return false
        val remoteUpdatedTime = JoplinItemParser.parseTime(parsed.props["updated_time"])
        val localUpdatedTime = db.noteUpdatedTime(id)
        if (!force && localUpdatedTime != null && localUpdatedTime >= remoteUpdatedTime) return false

        val isHtml = parsed.props["markup_language"] == "2"
        val converted = if (isHtml) parsed.body else MarkdownToHtml.convert(parsed.body)
        val body = fillAttachmentMetadata(rewriteResourceLinks(converted))

        db.saveNote(
            Note(
                id = id,
                folderId = parsed.props["parent_id"].orEmpty(),
                title = parsed.title,
                body = body,
                createdTime = JoplinItemParser.parseTime(parsed.props["created_time"]),
                updatedTime = remoteUpdatedTime,
                isTodo = parsed.props["is_todo"] == "1",
                todoCompleted = parsed.props["todo_completed"] != null && parsed.props["todo_completed"] != "0",
                deletedTime = parseDeletedTime(parsed.props["deleted_time"]),
                isPinned = parseIsPinned(parsed.props["application_data"]),
            ),
            dirty = false,
            synced = true,
        )
        return true
    }

    private fun upsertFolder(parsed: JoplinItemParser.ParsedItem, force: Boolean): Boolean {
        val id = parsed.props["id"] ?: return false
        // See the matching comment in upsertNote — same resurrection risk.
        if (db.hasPendingDelete(id)) return false
        val remoteUpdatedTime = JoplinItemParser.parseTime(parsed.props["updated_time"])
        val localUpdatedTime = db.folderUpdatedTime(id)
        if (!force && localUpdatedTime != null && localUpdatedTime >= remoteUpdatedTime) return false

        db.saveFolder(
            Folder(
                id = id,
                title = parsed.title,
                createdTime = JoplinItemParser.parseTime(parsed.props["created_time"]),
                updatedTime = remoteUpdatedTime,
                deletedTime = parseDeletedTime(parsed.props["deleted_time"]),
            ),
            dirty = false,
            synced = true,
        )
        return true
    }

    /** deleted_time is a plain epoch-millis integer (like is_todo/file_size), NOT an
     * ISO date string like created_time/updated_time — using JoplinItemParser.parseTime()
     * here was a bug: it expects ISO-8601, and its fallback for anything unparseable is
     * "now", which made every note pulled from a real Joplin client (whose deleted_time
     * is a plain int, not ISO) look freshly trashed. A missing/blank/unparseable value
     * must mean "not trashed" (null) instead. */
    private fun parseDeletedTime(value: String?): Long? {
        return value?.toLongOrNull()?.takeIf { it != 0L }
    }

    /** application_data isn't a Joplin field we own — it's blank unless this app set
     * it (see JoplinItemSerializer), so any parse failure just means "not pinned"
     * rather than a real error worth surfacing. */
    private fun parseIsPinned(value: String?): Boolean {
        if (value.isNullOrBlank()) return false
        return runCatching {
            Json.parseToJsonElement(value).jsonObject["pinned"]?.jsonPrimitive?.booleanOrNull
        }.getOrNull() ?: false
    }

    /** Downloads a resource's binary blob (image, etc.) and saves it into the same
     * resourcesDirectory / `resources` table the app already uses for locally-attached
     * images (see EditorScreen.copyImageIntoResources), so the WebView's existing
     * appassets.androidplatform.net/resources/ asset loader can serve it unchanged. */
    private suspend fun upsertResource(parsed: JoplinItemParser.ParsedItem, sessionId: String, force: Boolean) {
        val id = parsed.props["id"] ?: return
        // See the matching comment in upsertNote — same resurrection risk.
        if (db.hasPendingDelete(id)) return
        if (!force && db.resourceExists(id)) return

        val mime = parsed.props["mime"].orEmpty()
        val extension = parsed.props["file_extension"]?.takeIf { it.isNotBlank() }
            ?: mime.substringAfterLast('/').takeIf { it.isNotBlank() }
            ?: "bin"
        val filename = "$id.$extension"

        val bytes = JoplinCloudApi.resourceBlob(sessionId, id).getOrElse { return }
        File(db.resourcesDirectory, filename).writeBytes(bytes)

        db.saveResource(
            Resource(
                id = id,
                title = parsed.title,
                mimeType = mime,
                filename = filename,
                fileSize = parsed.props["size"]?.toLongOrNull() ?: bytes.size.toLong(),
                noteId = "",
            ),
            dirty = false,
            synced = true,
        )
    }

    /** Rewrites Joplin's `:/resourceId` link syntax (inside src="..."/href="...") into
     * the local WebView URL for that resource, once it's been synced. Links to a
     * resource that hasn't synced yet (or was never one) are left untouched. */
    /** Escapes a value going into an HTML attribute — an unescaped quote in a filename
     * would end the attribute early and corrupt the tag. */
    private fun escapeAttributeValue(value: String): String = value
        .replace("&", "&amp;")
        .replace("\"", "&quot;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")

    /** Fills in an attachment card's size and MIME type (and its name, if the link had
     * none) from the locally stored resource — MarkdownToHtml can only know the id and
     * the link text. A resource that hasn't been downloaded yet is left as-is: the card
     * still shows its name and becomes openable once the blob arrives on a later sync. */
    private fun fillAttachmentMetadata(html: String): String =
        attachmentCardRegex.replace(html) { m ->
            val id = m.groupValues[1]
            val linkText = m.groupValues[2]
            val meta = db.resourceMeta(id)
            if (meta == null) {
                // Joplin uses the same [title](:/id) syntax for a link to another NOTE.
                // MarkdownToHtml can't tell the two apart, but here we can: if this id
                // is a note, put the link back rather than leaving a card that could
                // never resolve to a file. Otherwise it's most likely a resource whose
                // blob hasn't downloaded yet — leave the card, it fills in on a later
                // sync.
                return@replace if (db.noteUpdatedTime(id) != null) {
                    "<a href=\":/$id\">$linkText</a>"
                } else {
                    m.value
                }
            }
            val (resourceTitle, mime, size) = meta
            val title = linkText.ifEmpty { escapeAttributeValue(resourceTitle) }
            "<div class=\"pm-attachment\" data-resource-id=\"$id\" data-title=\"$title\"" +
                " data-size=\"$size\" data-mime=\"${escapeAttributeValue(mime)}\"></div>"
        }

    private fun rewriteResourceLinks(html: String): String {
        return resourceLinkRegex.replace(html) { m ->
            val id = m.groupValues[3]
            val localUrl = db.resourceLocalUrl(id) ?: return@replace m.value
            "${m.groupValues[1]}=\"$localUrl\""
        }
    }

    private fun describeError(error: Throwable): String = when (error) {
        is JoplinCloudApi.SyncApiError.Unauthorized -> "Joplin Cloud session expired — please log in again."
        is JoplinCloudApi.SyncApiError.Other -> error.message
        is JoplinCloudApi.SyncApiError.Network -> "Couldn't reach Joplin Cloud. Check your connection."
        else -> error.message ?: "Sync failed."
    }

    private fun mapFailure(error: Throwable): SyncOutcome =
        if (error is JoplinCloudApi.SyncApiError.Unauthorized) SyncOutcome.Unauthorized
        else SyncOutcome.Failure(describeError(error))

    private fun mapPushFailure(error: Throwable): PushOutcome =
        if (error is JoplinCloudApi.SyncApiError.Unauthorized) PushOutcome.Unauthorized
        else PushOutcome.Failure(describeError(error))

    companion object {
        /** adb logcat -s JoplinSync to watch a sync run. */
        private const val LOG_TAG = "JoplinSync"
        private const val KEY_CURSOR = "delta_cursor"
        private const val CHANGE_TYPE_DELETE = 3
        private const val TYPE_NOTE = "1"
        private const val TYPE_FOLDER = "2"
        private const val TYPE_RESOURCE = "4"
        // Matches src="..."/href="..." attributes whose value is Joplin's ":/{32-hex-id}"
        // resource link syntax, e.g. src=":/4a6ec8ff...".
        private val resourceLinkRegex = Regex("""(src|href)="(:/([0-9a-fA-F]{32}))"""")

        // Attachment card as MarkdownToHtml emits it from a [name](:/id) link — it can
        // only know the id and the link text, so size/mime are filled in from the
        // resources table (see fillAttachmentMetadata).
        private val attachmentCardRegex = Regex(
            """<div class="pm-attachment" data-resource-id="([0-9a-fA-F]{32})" data-title="([^"]*)" data-size="0" data-mime=""></div>"""
        )
    }
}
