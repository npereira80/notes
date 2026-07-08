package com.ikuteam.notestn.ui.editor

import android.webkit.MimeTypeMap
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Redo
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.BorderColor
import androidx.compose.material.icons.filled.EditNote
import androidx.compose.material.icons.filled.FormatIndentDecrease
import androidx.compose.material.icons.filled.FormatIndentIncrease
import androidx.compose.material.icons.filled.FormatQuote
import androidx.compose.material.icons.filled.FormatStrikethrough
import androidx.compose.material.icons.filled.HorizontalRule
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.TableChart
import androidx.compose.material.icons.filled.Title
import androidx.compose.material.icons.outlined.FormatBold
import androidx.compose.material.icons.outlined.FormatItalic
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.PopupProperties
import com.ikuteam.notestn.data.DatabaseManager
import com.ikuteam.notestn.data.Note
import com.ikuteam.notestn.data.Resource
import com.ikuteam.notestn.ui.common.backdropBlurBackground
import com.ikuteam.notestn.ui.common.captureForBackdropBlur
import com.ikuteam.notestn.ui.common.rememberBackdropBlurState
import com.ikuteam.notestn.ui.theme.GroupedBackgroundDark
import com.ikuteam.notestn.ui.theme.GroupedBackgroundLight
import com.ikuteam.notestn.ui.theme.NotesYellowVivid
import com.ikuteam.notestn.viewmodel.NotesViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.File
import java.io.FileOutputStream

/**
 * Mirrors Mac/NotesTN/NotesTN/Views/EditorView.swift: title field + formatting
 * toolbar + the shared ProseMirror WebView editor.
 *
 * `note` is a snapshot passed in by the navigation layer; callers should key this
 * composable on `note.id` (see NotesNavHost) so switching notes fully resets local
 * editor state, mirroring the Mac app's `.id(note.id)`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EditorScreen(
    note: Note,
    viewModel: NotesViewModel,
    readOnly: Boolean = false,
    onBack: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val coordinator = remember(note.id) { EditorCoordinator() }
    val darkTheme = isSystemInDarkTheme()
    val groupedBackground = if (darkTheme) GroupedBackgroundDark else GroupedBackgroundLight
    // Same border color as the note list's search bar (NotesYellowVivid).
    val toolbarBorderColor = NotesYellowVivid
    // Same hand-rolled glass blur as the note list's search bar / new note button
    // (see ui/common/BackdropBlur.kt) — the toolbar blurs the note content scrolling
    // behind it instead of sitting on a flat, opaque background.
    val blurState = rememberBackdropBlurState()
    // The formatting toolbar is only useful while typing — hide it once the
    // keyboard is dismissed instead of leaving it pinned to the bottom of the
    // screen taking up space.
    val density = LocalDensity.current
    val imeBottomPx = WindowInsets.ime.getBottom(density)
    val imeVisible = imeBottomPx > 0
    // Computed directly from the raw IME inset (not Modifier.imePadding()) so the
    // gap above the keyboard is an exact, predictable value — imePadding() combined
    // with Scaffold's own contentWindowInsets (which already factors in ime once for
    // the outer Box) meant a second imePadding() here read an already-consumed inset,
    // so changing the extra padding after it had no visible effect.
    val imeHeightDp = with(density) { imeBottomPx.toDp() }

    var showLinkDialog by remember(note.id) { mutableStateOf(false) }
    var confirmPermanentDelete by remember(note.id) { mutableStateOf(false) }

    LaunchedEffect(coordinator, note.id) {
        // Title now lives inside the shared ProseMirror doc (see Mac/EditorBundle),
        // so it scrolls with the body instead of sitting in a separate native
        // field — one combined callback replaces the old separate title/body
        // debounce paths.
        coordinator.onContentChanged = { title, body ->
            viewModel.saveNote(note.copy(title = title, body = body))
        }
        coordinator.onImageRequested = { dataUri ->
            scope.launch {
                val resource = withContext(Dispatchers.IO) { copyDataUriIntoResources(dataUri, note.id) }
                if (resource != null) {
                    coordinator.insertImage(
                        src = "https://appassets.androidplatform.net/resources/${resource.filename}",
                        alt = resource.title,
                        resourceId = resource.id,
                    )
                }
            }
        }
        coordinator.onOpenUrl = { url ->
            runCatching {
                context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url)))
            }
        }
        coordinator.onFocusChanged = { focused ->
            viewModel.isEditorFocused = focused
        }
    }

    DisposableEffect(Unit) {
        onDispose { viewModel.isEditorFocused = false }
    }

    // Push initial content once the WebView bundle signals it's ready.
    LaunchedEffect(coordinator.isReady, note.id) {
        if (coordinator.isReady) coordinator.setContent(note.title, note.body)
    }

    val imagePicker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            val resource = withContext(Dispatchers.IO) { copyImageIntoResources(context, uri, note.id) }
            if (resource != null) {
                coordinator.insertImage(
                    src = "https://appassets.androidplatform.net/resources/${resource.filename}",
                    alt = resource.title,
                    resourceId = resource.id,
                )
            }
        }
    }

    key(note.id) {
        Scaffold(
            modifier = modifier,
            // Scaffold's default contentWindowInsets (safeDrawing) includes the IME
            // inset, which would shift this whole Box up by the keyboard height on its
            // own — on top of the explicit imeHeightDp calc below on the toolbar, that
            // double-counting is what made changing the extra gap value invisible.
            // systemBars (status + navigation bars only, no ime) keeps the WebView's
            // safe-area padding when the keyboard is closed without touching ime.
            contentWindowInsets = WindowInsets.systemBars,
            topBar = {
                TopAppBar(
                    title = {},
                    navigationIcon = {
                        if (onBack != null) {
                            IconButton(onClick = onBack) {
                                Icon(Icons.Filled.ArrowBack, contentDescription = "Back")
                            }
                        }
                    },
                    actions = {
                        if (readOnly) {
                            TextButton(onClick = { viewModel.restoreNote(note); onBack?.invoke() }) { Text("Restore") }
                            TextButton(onClick = { confirmPermanentDelete = true }) { Text("Delete Permanently") }
                        } else {
                            IconButton(onClick = { coordinator.execCommand("undo") }) {
                                Icon(Icons.AutoMirrored.Filled.Undo, contentDescription = "Undo")
                            }
                            IconButton(onClick = { coordinator.execCommand("redo") }) {
                                Icon(Icons.AutoMirrored.Filled.Redo, contentDescription = "Redo")
                            }
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = groupedBackground),
                )
            },
        ) { padding ->
            // A Box (not Scaffold's bottomBar slot) so the toolbar floats on top of the
            // WebView instead of reserving its own layout row — that's what lets the
            // area outside the toolbar's border show live note content scrolling
            // underneath it rather than a solid, layout-reserved background.
            Box(modifier = Modifier.padding(padding).fillMaxSize()) {
                // Title lives inside the WebView's shared ProseMirror doc now (see
                // Mac/EditorBundle's `pm-title` node) so it scrolls together with the
                // body instead of sitting in a separate native field above it.
                EditorWebView(
                    coordinator = coordinator,
                    darkTheme = darkTheme,
                    readOnly = readOnly,
                    modifier = Modifier.fillMaxSize().captureForBackdropBlur(blurState),
                )

                // A trashed note is read-only until restored — no formatting toolbar.
                // Also hidden once the keyboard is dismissed (see imeVisible above).
                if (!readOnly && imeVisible) {
                    // bottom = imeHeightDp + 5.dp rises the toolbar above the keyboard
                    // (the app is edge-to-edge — see MainActivity's enableEdgeToEdge —
                    // so nothing resizes for the IME automatically) with a deliberate
                    // 5dp gap on top of that, and the 10dp horizontal padding insets the
                    // toolbar from the screen edges — together with the rounded shape
                    // this makes it read as a floating card over the note rather than an
                    // edge-to-edge bar.
                    // 16dp matches the note list's search bar corner radius
                    // (see NoteListScreen.kt's FloatingSearchField).
                    // Custom Box instead of Surface — same reasoning as the note list's
                    // search bar / new note button (see NoteListScreen.kt): Surface draws
                    // its own solid color fill with no hook to slot a blurred backdrop in
                    // underneath it, so the glass look needs full control over draw order
                    // (blur, then tint, then content). 0.80 tint alpha matches the note
                    // list's glass elements.
                    val toolbarShape = RoundedCornerShape(16.dp)
                    Box(
                        modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .padding(horizontal = 10.dp)
                            .padding(bottom = imeHeightDp + 5.dp)
                            .shadow(8.dp, toolbarShape)
                            .clip(toolbarShape)
                            .backdropBlurBackground(blurState)
                            .background(groupedBackground.copy(alpha = 0.80f))
                            .border(0.5.dp, toolbarBorderColor, toolbarShape),
                    ) {
                        EditorToolbar(
                            coordinator = coordinator,
                            onInsertImage = { imagePicker.launch(androidx.activity.result.PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
                            onInsertLink = { showLinkDialog = true },
                        )
                    }
                }
            }
        }
    }

    if (showLinkDialog) {
        LinkInputDialog(
            initialValue = coordinator.selectionState.linkHref ?: "",
            onConfirm = { href ->
                showLinkDialog = false
                if (href.isNotBlank()) coordinator.setLink(href)
            },
            onDismiss = { showLinkDialog = false },
        )
    }

    if (confirmPermanentDelete) {
        AlertDialog(
            onDismissRequest = { confirmPermanentDelete = false },
            title = { Text("Delete Permanently") },
            text = { Text("Permanently delete \"${note.title.ifEmpty { "Untitled" }}\"? This can't be undone.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmPermanentDelete = false
                    viewModel.permanentlyDeleteNote(note)
                    onBack?.invoke()
                }) { Text("Delete") }
            },
            dismissButton = {
                TextButton(onClick = { confirmPermanentDelete = false }) { Text("Cancel") }
            },
        )
    }
}

@Composable
fun EditorEmptyState(onCreateNote: () -> Unit, modifier: Modifier = Modifier) {
    Box(modifier = modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(
                Icons.Filled.EditNote,
                contentDescription = null,
                modifier = Modifier.size(48.dp),
                tint = MaterialTheme.colorScheme.outlineVariant,
            )
            Text(
                "Select or create a note",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 8.dp),
            )
            TextButton(onClick = onCreateNote, modifier = Modifier.padding(top = 4.dp)) {
                Text("New Note")
            }
        }
    }
}

// MARK: - Toolbar

@Composable
private fun EditorToolbar(
    coordinator: EditorCoordinator,
    onInsertImage: () -> Unit,
    onInsertLink: () -> Unit,
) {
    val s = coordinator.selectionState
    var showHeadingMenu by remember { mutableStateOf(false) }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 8.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box {
            ToolbarIconButton(Icons.Filled.Title, "Text Style") {
                // Collapse any active range selection first — otherwise Android's
                // native Cut/Copy/Paste floating toolbar stays up and renders on
                // top of this dropdown (see collapseSelection's doc comment).
                coordinator.collapseSelection()
                showHeadingMenu = true
            }
            // focusable = false so this popup doesn't steal Android view focus from the
            // WebView — taking focus collapses the live ProseMirror selection inside it,
            // which made every command here silently no-op (nothing to apply the style to
            // by the time the tap reached the JS side).
            DropdownMenu(
                expanded = showHeadingMenu,
                onDismissRequest = { showHeadingMenu = false },
                properties = PopupProperties(focusable = false),
            ) {
                // "Title" reuses heading level 1 (restyled in CSS to match the note
                // title's look) so it can be applied to any paragraph in the body.
                DropdownMenuItem(text = { Text("Title") }, onClick = {
                    showHeadingMenu = false; coordinator.execCommand("heading1")
                })
                DropdownMenuItem(text = { Text("Heading") }, onClick = {
                    showHeadingMenu = false; coordinator.execCommand("heading3")
                })
                DropdownMenuItem(text = { Text("Subheading") }, onClick = {
                    showHeadingMenu = false; coordinator.execCommand("heading4")
                })
                DropdownMenuItem(text = { Text("Paragraph") }, onClick = {
                    showHeadingMenu = false; coordinator.execCommand("paragraph")
                })
                HorizontalDivider()
                DropdownMenuItem(text = { Text("Bullet List") }, onClick = {
                    showHeadingMenu = false; coordinator.execCommand("bulletList")
                })
                DropdownMenuItem(text = { Text("Number List") }, onClick = {
                    showHeadingMenu = false; coordinator.execCommand("orderedList")
                })
                HorizontalDivider()
                DropdownMenuItem(text = { Text("Monospaced") }, onClick = {
                    showHeadingMenu = false; coordinator.execCommand("code")
                })
                DropdownMenuItem(text = { Text("Code Block") }, onClick = {
                    showHeadingMenu = false; coordinator.execCommand("codeBlock")
                })
            }
        }

        ToolbarDivider()
        // Task list + Insert Image — moved up front (2nd/3rd items), per request
        ToolbarToggleButton(Icons.Filled.Checklist, "Task List", s.inTaskList) { coordinator.execCommand("taskList") }
        ToolbarIconButton(Icons.Filled.Image, "Insert Image", onInsertImage)

        ToolbarDivider()
        ToolbarToggleButton(Icons.Outlined.FormatBold, "Bold", s.bold) { coordinator.execCommand("bold") }
        ToolbarToggleButton(Icons.Outlined.FormatItalic, "Italic", s.italic) { coordinator.execCommand("italic") }
        ToolbarToggleButton(Icons.Filled.FormatStrikethrough, "Strikethrough", s.strikethrough) { coordinator.execCommand("strikethrough") }
        ToolbarToggleButton(Icons.Filled.BorderColor, "Highlight", s.highlight) { coordinator.execCommand("highlight") }
        ToolbarToggleButton(Icons.Filled.Code, "Inline Code", s.code) { coordinator.execCommand("code") }

        ToolbarDivider()
        ToolbarToggleButton(Icons.Filled.FormatQuote, "Blockquote", s.inBlockquote) { coordinator.execCommand("blockquote") }

        ToolbarDivider()
        ToolbarIconButton(Icons.Filled.FormatIndentDecrease, "Outdent") { coordinator.execCommand("outdent") }
        ToolbarIconButton(Icons.Filled.FormatIndentIncrease, "Indent") { coordinator.execCommand("indent") }

        ToolbarDivider()
        // Image moved above; table/HR remain
        ToolbarIconButton(Icons.Filled.TableChart, "Insert Table") {
            coordinator.execCommand("table", buildJsonObject { put("rows", 3); put("cols", 3) })
        }
        ToolbarIconButton(Icons.Filled.HorizontalRule, "Horizontal Rule") { coordinator.execCommand("horizontalRule") }

        ToolbarDivider()
        ToolbarToggleButton(Icons.Filled.Link, "Link", s.hasLink) {
            if (s.hasLink) coordinator.removeLink() else onInsertLink()
        }
    }
}

@Composable
private fun ToolbarIconButton(icon: androidx.compose.ui.graphics.vector.ImageVector, tooltip: String, onClick: () -> Unit) {
    IconButton(onClick = onClick, modifier = Modifier.size(36.dp)) {
        Icon(icon, contentDescription = tooltip, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(20.dp))
    }
}

@Composable
private fun ToolbarToggleButton(icon: androidx.compose.ui.graphics.vector.ImageVector, tooltip: String, isActive: Boolean, onClick: () -> Unit) {
    IconButton(onClick = onClick, modifier = Modifier.size(36.dp)) {
        Icon(
            icon,
            contentDescription = tooltip,
            tint = if (isActive) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(20.dp),
        )
    }
}

@Composable
private fun RowScope.ToolbarDivider() {
    Box(
        modifier = Modifier
            .padding(horizontal = 4.dp)
            .height(16.dp)
            .width(1.dp)
            .background(MaterialTheme.colorScheme.outlineVariant),
    )
}

@Composable
private fun LinkInputDialog(
    initialValue: String,
    onConfirm: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    var text by remember { mutableStateOf(initialValue) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Insert Link") },
        text = {
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                singleLine = true,
                placeholder = { Text("https://example.com") },
            )
        },
        confirmButton = { TextButton(onClick = { onConfirm(text.trim()) }) { Text("OK") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

// MARK: - Image handling (mirrors NoteEditorView.handleImagePick)

private fun copyImageIntoResources(context: android.content.Context, uri: android.net.Uri, noteId: String): Resource? {
    val resolver = context.contentResolver
    val mimeType = resolver.getType(uri) ?: "image/png"
    val ext = MimeTypeMap.getSingleton().getExtensionFromMimeType(mimeType) ?: "png"
    val resourceId = Note.generateId()
    val filename = "$resourceId.$ext"
    val destFile = File(DatabaseManager.shared.resourcesDirectory, filename)

    val copied = runCatching {
        resolver.openInputStream(uri)?.use { input ->
            FileOutputStream(destFile).use { output -> input.copyTo(output) }
        } != null
    }.getOrDefault(false)
    if (!copied) return null

    val resource = Resource(
        id = resourceId,
        title = filename,
        mimeType = mimeType,
        filename = filename,
        fileSize = destFile.length(),
        noteId = noteId,
    )
    // New resource, never seen by Joplin Cloud yet — dirty so it gets pushed, not
    // synced since the server doesn't know about it.
    // New resource, never seen by Joplin Cloud yet — dirty so it gets pushed, not
    // synced since the server doesn't know about it.
    DatabaseManager.shared.saveResource(resource, dirty = true, synced = false)
    return resource
}

private val dataUriRegex = Regex("^data:([^;]+);base64,(.+)$", RegexOption.DOT_MATCHES_ALL)

/** Counterpart to copyImageIntoResources for the paste-from-clipboard path — the editor
 * bundle hands us a raw "data:image/png;base64,..." URI (see the paste handler in
 * Mac/EditorBundle/src/index.ts) instead of a content:// Uri, since there's no system
 * picker involved. */
private fun copyDataUriIntoResources(dataUri: String, noteId: String): Resource? {
    val match = dataUriRegex.find(dataUri) ?: return null
    val mimeType = match.groupValues[1]
    val bytes = runCatching { android.util.Base64.decode(match.groupValues[2], android.util.Base64.DEFAULT) }
        .getOrNull() ?: return null

    val ext = MimeTypeMap.getSingleton().getExtensionFromMimeType(mimeType) ?: "png"
    val resourceId = Note.generateId()
    val filename = "$resourceId.$ext"
    val destFile = File(DatabaseManager.shared.resourcesDirectory, filename)
    val written = runCatching { destFile.writeBytes(bytes) }.isSuccess
    if (!written) return null

    val resource = Resource(
        id = resourceId,
        title = filename,
        mimeType = mimeType,
        filename = filename,
        fileSize = destFile.length(),
        noteId = noteId,
    )
    DatabaseManager.shared.saveResource(resource, dirty = true, synced = false)
    return resource
}
