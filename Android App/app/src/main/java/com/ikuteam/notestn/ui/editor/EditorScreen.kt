package com.ikuteam.notestn.ui.editor

import android.webkit.MimeTypeMap
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.FormatListBulleted
import androidx.compose.material.icons.automirrored.filled.Redo
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.EditNote
import androidx.compose.material.icons.filled.FormatIndentDecrease
import androidx.compose.material.icons.filled.FormatIndentIncrease
import androidx.compose.material.icons.filled.FormatListNumbered
import androidx.compose.material.icons.filled.FormatQuote
import androidx.compose.material.icons.filled.FormatStrikethrough
import androidx.compose.material.icons.filled.HorizontalRule
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.TableChart
import androidx.compose.material.icons.filled.Title
import androidx.compose.material.icons.filled.UnfoldMore
import androidx.compose.material.icons.outlined.FormatBold
import androidx.compose.material.icons.outlined.FormatItalic
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.ikuteam.notestn.data.DatabaseManager
import com.ikuteam.notestn.data.Note
import com.ikuteam.notestn.data.Resource
import com.ikuteam.notestn.viewmodel.NotesViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
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
    onBack: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val coordinator = remember(note.id) { EditorCoordinator() }
    val darkTheme = isSystemInDarkTheme()

    var title by rememberSaveable(note.id) { mutableStateOf(note.title) }
    var currentBody by remember(note.id) { mutableStateOf(note.body) }
    var showLinkDialog by remember(note.id) { mutableStateOf(false) }

    fun persist(newTitle: String = title, newBody: String = currentBody) {
        viewModel.saveNote(note.copy(title = newTitle, body = newBody))
    }

    // Debounced title save — mirrors NoteEditorView.schedulesTitleSave (500ms).
    LaunchedEffect(title) {
        if (title == note.title) return@LaunchedEffect
        delay(500)
        persist(newTitle = title)
    }

    LaunchedEffect(coordinator, note.id) {
        coordinator.onContentChanged = { html ->
            currentBody = html
            persist(newBody = html)
        }
        coordinator.onImageRequested = { /* paste-image already inlines a data URI in JS */ }
        coordinator.onOpenUrl = { url ->
            runCatching {
                context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url)))
            }
        }
    }

    // Push initial content once the WebView bundle signals it's ready.
    LaunchedEffect(coordinator.isReady, note.id) {
        if (coordinator.isReady) coordinator.setContent(note.body)
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
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = Color(0xFFF2F2F6)),
                )
            },
            bottomBar = {
                // imePadding here (not on the content column) is what makes the toolbar
                // rise above the keyboard instead of being hidden behind it — the app is
                // edge-to-edge (see MainActivity's enableEdgeToEdge), so nothing resizes
                // for the IME automatically and this has to be explicit.
                Surface(
                    modifier = Modifier.imePadding(),
                    color = Color(0xFFF2F2F6),
                    tonalElevation = 2.dp,
                    shadowElevation = 8.dp,
                ) {
                    EditorToolbar(
                        coordinator = coordinator,
                        onInsertImage = { imagePicker.launch(androidx.activity.result.PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
                        onInsertLink = { showLinkDialog = true },
                    )
                }
            },
        ) { padding ->
            Column(modifier = Modifier.padding(padding).fillMaxSize()) {
                TextField(
                    value = title,
                    onValueChange = { title = it },
                    placeholder = { Text("Title") },
                    textStyle = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.Bold),
                    singleLine = true,
                    colors = TextFieldDefaults.colors(
                        focusedContainerColor = Color(0xFFF2F2F6),
                        unfocusedContainerColor = Color(0xFFF2F2F6),
                        focusedIndicatorColor = Color.Transparent,
                        unfocusedIndicatorColor = Color.Transparent,
                    ),
                    // This TextField(value: String, ...) overload has no contentPadding param —
                    // that only exists on the newer TextFieldState-based overload. Its internal
                    // default content padding is 16dp on each side, so we add extra here to reach
                    // the desired totals: +2dp start = 18dp, +4dp end = 20dp.
                    modifier = Modifier.fillMaxWidth().padding(start = 2.dp, end = 4.dp),
                )

                EditorWebView(coordinator = coordinator, darkTheme = darkTheme, modifier = Modifier.fillMaxSize())
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
            ToolbarIconButton(Icons.Filled.Title, "Paragraph / Headings") { showHeadingMenu = true }
            DropdownMenu(expanded = showHeadingMenu, onDismissRequest = { showHeadingMenu = false }) {
                DropdownMenuItem(text = { Text("Paragraph") }, onClick = {
                    showHeadingMenu = false; coordinator.execCommand("paragraph")
                })
                for (level in 1..6) {
                    DropdownMenuItem(text = { Text("Heading $level") }, onClick = {
                        showHeadingMenu = false; coordinator.execCommand("heading$level")
                    })
                }
                DropdownMenuItem(text = { Text("Code Block") }, onClick = {
                    showHeadingMenu = false; coordinator.execCommand("codeBlock")
                })
            }
        }

        ToolbarDivider()
        ToolbarToggleButton(Icons.Outlined.FormatBold, "Bold", s.bold) { coordinator.execCommand("bold") }
        ToolbarToggleButton(Icons.Outlined.FormatItalic, "Italic", s.italic) { coordinator.execCommand("italic") }
        ToolbarToggleButton(Icons.Filled.FormatStrikethrough, "Strikethrough", s.strikethrough) { coordinator.execCommand("strikethrough") }
        ToolbarToggleButton(Icons.Filled.Code, "Inline Code", s.code) { coordinator.execCommand("code") }

        ToolbarDivider()
        ToolbarToggleButton(Icons.Filled.FormatQuote, "Blockquote", s.inBlockquote) { coordinator.execCommand("blockquote") }

        ToolbarDivider()
        ToolbarToggleButton(Icons.AutoMirrored.Filled.FormatListBulleted, "Bullet List", s.inBulletList) { coordinator.execCommand("bulletList") }
        ToolbarToggleButton(Icons.Filled.FormatListNumbered, "Numbered List", s.inOrderedList) { coordinator.execCommand("orderedList") }
        ToolbarToggleButton(Icons.Filled.Checklist, "Task List", s.inTaskList) { coordinator.execCommand("taskList") }

        ToolbarDivider()
        ToolbarIconButton(Icons.Filled.FormatIndentDecrease, "Outdent") { coordinator.execCommand("outdent") }
        ToolbarIconButton(Icons.Filled.FormatIndentIncrease, "Indent") { coordinator.execCommand("indent") }

        ToolbarDivider()
        ToolbarIconButton(Icons.Filled.Image, "Insert Image", onInsertImage)
        ToolbarIconButton(Icons.Filled.TableChart, "Insert Table") {
            coordinator.execCommand("table", buildJsonObject { put("rows", 3); put("cols", 3) })
        }
        ToolbarIconButton(Icons.Filled.HorizontalRule, "Horizontal Rule") { coordinator.execCommand("horizontalRule") }
        ToolbarIconButton(Icons.Filled.UnfoldMore, "Toggle Block") { coordinator.execCommand("toggle") }

        ToolbarDivider()
        ToolbarToggleButton(Icons.Filled.Link, "Link", s.hasLink) {
            if (s.hasLink) coordinator.removeLink() else onInsertLink()
        }

        ToolbarDivider()
        ToolbarIconButton(Icons.AutoMirrored.Filled.Undo, "Undo") { coordinator.execCommand("undo") }
        ToolbarIconButton(Icons.AutoMirrored.Filled.Redo, "Redo") { coordinator.execCommand("redo") }
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
    DatabaseManager.shared.saveResource(resource)
    return resource
}
