package com.ikuteam.notestn.ui.editor

import android.webkit.MimeTypeMap
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.only
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
import androidx.compose.material.icons.filled.FormatListBulleted
import androidx.compose.material.icons.filled.FormatListNumbered
import androidx.compose.material.icons.automirrored.filled.Redo
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.DataObject
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.BorderColor
import androidx.compose.material.icons.filled.EditNote
import androidx.compose.material.icons.filled.FindReplace
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
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.PopupProperties
import com.ikuteam.notestn.data.DatabaseManager
import com.ikuteam.notestn.data.Note
import com.ikuteam.notestn.data.Resource
import com.ikuteam.notestn.data.joplin.HtmlToMarkdown
import com.ikuteam.notestn.ui.common.backdropBlurBackground
import com.ikuteam.notestn.ui.common.captureForBackdropBlur
import com.ikuteam.notestn.ui.common.rememberBackdropBlurState
import com.ikuteam.notestn.ui.theme.GroupedBackgroundDark
import com.ikuteam.notestn.ui.theme.GroupedBackgroundLight
import com.ikuteam.notestn.ui.theme.NotesYellowDark
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
    var showMarkdownSource by remember(note.id) { mutableStateOf(false) }
    var confirmPermanentDelete by remember(note.id) { mutableStateOf(false) }
    // Set when a detected address is tapped — drives the Google Maps / Waze chooser.
    var mapsAddress by remember(note.id) { mutableStateOf<String?>(null) }
    // Set when an attachment couldn't be opened, to why — the two cases need different
    // advice, so they get different messages (see the dialog below).
    var attachmentError by remember(note.id) { mutableStateOf<AttachmentOpenError?>(null) }
    // Guards against opening the same attachment twice from one tap — see onOpenAttachment.
    var isOpeningAttachment by remember(note.id) { mutableStateOf(false) }

    // In-note find (the search icon next to undo/redo). Highlights matches in the
    // editor and steps through them; independent of the global note-list search.
    var showFind by remember(note.id) { mutableStateOf(false) }
    var findQuery by remember(note.id) { mutableStateOf("") }
    var findCount by remember(note.id) { mutableStateOf(0) }
    var findCurrent by remember(note.id) { mutableStateOf(0) }
    // Replace row. While it's showing, matching switches to case-sensitive so a
    // replace only rewrites the exact text it highlighted.
    var showReplace by remember(note.id) { mutableStateOf(false) }
    var replaceText by remember(note.id) { mutableStateOf("") }
    fun closeFind() {
        showFind = false
        showReplace = false
        findQuery = ""
        replaceText = ""
        findCount = 0
        findCurrent = 0
        coordinator.endFind()
    }

    // Read vs. edit mode. Read mode (the default) keeps the editor non-editable: a tap
    // interacts with content (open a link, toggle a task, select text) and never pops
    // the keyboard. The pencil FAB enters edit mode; the back gesture or dismissing the
    // keyboard leaves it. A brand-new note opens straight in edit mode (see
    // pendingEditNoteId); a trashed note is never editable.
    var editMode by remember(note.id) {
        mutableStateOf(!readOnly && viewModel.pendingEditNoteId.value == note.id)
    }
    // Guards the keyboard-dismiss exit below against the gap between entering edit mode
    // and the keyboard finishing its show animation.
    var sawKeyboardThisEdit by remember(note.id) { mutableStateOf(false) }

    // Copies an image into resources and inserts it at the cursor. Shared by the
    // toolbar's picker and by an image dragged in from another app.
    val insertImageFromUri: (android.net.Uri) -> Unit = { uri ->
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

    // Consume the one-shot "open in edit mode" signal so re-opening this note later
    // starts in read mode.
    LaunchedEffect(note.id) {
        if (viewModel.pendingEditNoteId.value == note.id) viewModel.consumePendingEdit()
    }

    LaunchedEffect(coordinator, note.id) {
        // Title now lives inside the shared ProseMirror doc (see Mac/EditorBundle),
        // so it scrolls with the body instead of sitting in a separate native
        // field — one combined callback replaces the old separate title/body
        // debounce paths.
        //
        // saveNoteContent (by id) instead of saveNote(note.copy(...)) — this effect
        // only re-runs on note.id changes, so the `note` captured here is a snapshot
        // from when the note was opened. Saving through that snapshot silently
        // reverted anything changed elsewhere mid-session (pin/unpin from the list,
        // a folder move, a sync pull) on the next keystroke-save — stale state that
        // previously only clearing the app fixed.
        coordinator.onContentChanged = { title, body ->
            viewModel.saveNoteContent(note.id, title, body)
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
        // An image dragged in from another app (see the drag listener in
        // EditorWebView.kt). Dropping one is an edit, so a note being read switches to
        // edit mode rather than quietly changing underneath.
        coordinator.onImageDropped = { uri ->
            if (!editMode && !readOnly) editMode = true
            if (!readOnly) insertImageFromUri(uri)
        }
        coordinator.onOpenUrl = { url ->
            runCatching {
                context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url)))
            }
        }
        coordinator.onOpenMaps = { address -> mapsAddress = address }
        coordinator.onFindResult = { count, index ->
            findCount = count
            findCurrent = index
        }
        coordinator.onOpenAttachment = { resourceId ->
            // isOpeningAttachment keeps a double tap (the editor sends the preview and
            // the edit message for one card) from launching the viewer twice.
            if (!isOpeningAttachment) {
                isOpeningAttachment = true
                scope.launch {
                    val intent = withContext(Dispatchers.IO) { attachmentViewIntent(context, resourceId) }
                    // Back on the main thread: starting an activity is main-thread work.
                    // A throw here is all but always ActivityNotFoundException, i.e. no
                    // installed app handles this file type.
                    attachmentError = when {
                        intent == null -> AttachmentOpenError.NOT_ON_DEVICE
                        runCatching { context.startActivity(intent) }.isFailure -> AttachmentOpenError.NO_APP
                        else -> null
                    }
                    isOpeningAttachment = false
                }
            }
        }
        coordinator.onFocusChanged = { focused ->
            viewModel.isEditorFocused = focused
        }
    }

    DisposableEffect(Unit) {
        onDispose { viewModel.isEditorFocused = false }
    }

    // Push initial content once the WebView bundle signals it's ready. Also re-runs
    // if isReady drops back to false and returns (WebView recreated after its render
    // process died — see EditorWebView's onRenderProcessGone), re-pushing the
    // current content instead of leaving a blank editor until app restart.
    LaunchedEffect(coordinator.isReady, note.id) {
        if (coordinator.isReady) coordinator.setContent(note.title, note.body)
    }

    // A sync pull that updates the currently open note used to leave the editor
    // showing the old content (content was only pushed once per note id) — the list
    // preview and the editor would disagree until the note was reopened or the app
    // restarted, and the next keystroke-save would overwrite the pulled remote edit
    // with the stale editor content. The lastKnown* comparison keeps this from
    // reacting to the echo of the editor's own saves (`note` here is the fresh
    // object passed down by the nav layer on every list emission). Same fix as the
    // Mac/iPad clients.
    LaunchedEffect(note.updatedTime) {
        if (!coordinator.isReady) return@LaunchedEffect
        if (note.title != coordinator.lastKnownTitle || note.body != coordinator.lastKnownBody) {
            coordinator.setContent(note.title, note.body)
        }
    }

    // Apply the current mode to the editor. Re-runs when the WebView becomes ready
    // (including after a render-process recovery) and whenever editMode flips.
    LaunchedEffect(coordinator.isReady, editMode) {
        if (!coordinator.isReady) return@LaunchedEffect
        coordinator.setEditable(editMode)
        if (editMode) coordinator.focus() else coordinator.blur()
    }

    // Leave edit mode when the keyboard is dismissed (the back gesture is handled by
    // the BackHandler below). No separate Done button by design. sawKeyboardThisEdit
    // avoids treating the pre-show moment as a dismiss.
    LaunchedEffect(imeVisible) {
        if (!editMode) {
            sawKeyboardThisEdit = false
            return@LaunchedEffect
        }
        if (imeVisible) {
            sawKeyboardThisEdit = true
        } else if (sawKeyboardThisEdit) {
            editMode = false
            sawKeyboardThisEdit = false
        }
    }

    // Back gesture in edit mode returns to read mode instead of leaving the note.
    // Disabled in read mode so back navigates away as usual.
    BackHandler(enabled = editMode) {
        editMode = false
    }

    // Back closes the find bar first (composed after the editMode handler so it wins
    // when both are enabled).
    BackHandler(enabled = showFind) {
        closeFind()
    }

    val imagePicker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        insertImageFromUri(uri)
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
            // Top only. The bottom is left off deliberately so the note runs to the
            // bottom edge of the screen and scrolls underneath the gesture bar,
            // rather than stopping above it and leaving a strip of window
            // background. The page carries its own bottom padding (see the
            // body.pm-android rule in EditorBundle/build.mjs) so the last line can
            // still be scrolled clear of it. Not safeDrawing/systemBars in full:
            // either includes the IME, which would shift this whole Box up by the
            // keyboard height on top of the explicit imeHeightDp calc below.
            contentWindowInsets = WindowInsets.systemBars.only(WindowInsetsSides.Top),
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
                            // In-note find — third button, right of undo/redo.
                            IconButton(onClick = { showFind = true }) {
                                Icon(Icons.Filled.Search, contentDescription = "Find in note")
                            }
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = groupedBackground),
                )
            },
            floatingActionButton = {
                // Pencil FAB — only in read mode on an editable (non-trashed) note.
                // Tapping it enters edit mode and pops the keyboard.
                if (!readOnly && !editMode) {
                    // The standard 56dp FAB, matching the New Note button in the list.
                    FloatingActionButton(
                        // The Scaffold no longer insets its content at the bottom (see
                        // contentWindowInsets), so the FAB has to clear the gesture bar
                        // itself.
                        modifier = Modifier.navigationBarsPadding(),
                        onClick = { editMode = true },
                        containerColor = NotesYellowVivid,
                        contentColor = Color.Black,
                    ) {
                        Icon(Icons.Filled.Edit, contentDescription = "Edit note")
                    }
                }
            },
        ) { padding ->
            Column(modifier = Modifier.padding(padding).fillMaxSize()) {
                // In-note find bar — sits above the editor (like a browser Find bar)
                // so it doesn't overlap the note content.
                if (showFind) {
                    FindBar(
                        query = findQuery,
                        replacement = replaceText,
                        showReplace = showReplace,
                        current = findCurrent,
                        count = findCount,
                        onQueryChange = { q ->
                            findQuery = q
                            coordinator.find(q, caseSensitive = showReplace)
                        },
                        onReplacementChange = { replaceText = it },
                        onToggleReplace = {
                            showReplace = !showReplace
                            // Matching switches to exact case while replacing, so
                            // re-run the search against the current query.
                            coordinator.find(findQuery, caseSensitive = showReplace)
                        },
                        onReplace = { coordinator.replaceCurrent(replaceText) },
                        onReplaceAll = { coordinator.replaceAll(replaceText) },
                        onNext = { coordinator.findNext() },
                        onPrevious = { coordinator.findPrevious() },
                        onClose = { closeFind() },
                    )
                }
            // A Box (not Scaffold's bottomBar slot) so the toolbar floats on top of the
            // WebView instead of reserving its own layout row — that's what lets the
            // area outside the toolbar's border show live note content scrolling
            // underneath it rather than a solid, layout-reserved background.
            Box(modifier = Modifier.weight(1f).fillMaxSize()) {
                // Title lives inside the WebView's shared ProseMirror doc now (see
                // Mac/EditorBundle's `pm-title` node) so it scrolls together with the
                // body instead of sitting in a separate native field above it.
                EditorWebView(
                    coordinator = coordinator,
                    darkTheme = darkTheme,
                    readOnly = readOnly,
                    modifier = Modifier.fillMaxSize().captureForBackdropBlur(blurState),
                )

                // Formatting toolbar — only in edit mode with the keyboard up. Read
                // mode and trashed (read-only) notes never show it.
                if (!readOnly && editMode && imeVisible) {
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
                            onShowMarkdownSource = { showMarkdownSource = true },
                        )
                    }
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

    if (showMarkdownSource) {
        // A debugging aid: shows the Joplin Markdown that the current editor HTML
        // converts to (the format actually stored/synced), so an HTML rendering bug
        // can be traced back to its Markdown source. lastKnownBody is the HTML the
        // editor last reported (see EditorCoordinator).
        MarkdownSourceDialog(
            markdown = remember(coordinator.lastKnownBody) { HtmlToMarkdown.convert(coordinator.lastKnownBody) },
            onDismiss = { showMarkdownSource = false },
        )
    }

    attachmentError?.let { reason ->
        AlertDialog(
            onDismissRequest = { attachmentError = null },
            title = { Text("Can't open attachment") },
            text = {
                Text(
                    when (reason) {
                        AttachmentOpenError.NOT_ON_DEVICE ->
                            "This file hasn't finished syncing to this device yet. Try again in a moment."
                        AttachmentOpenError.NO_APP ->
                            "No app on this device can open this type of file. Installing one that handles it will let you preview it here."
                    }
                )
            },
            confirmButton = { TextButton(onClick = { attachmentError = null }) { Text("OK") } },
        )
    }

    mapsAddress?.let { address ->
        MapsChooserDialog(
            address = address,
            onPick = { app ->
                val query = android.net.Uri.encode(address)
                val url = when (app) {
                    MapsApp.GOOGLE -> "https://www.google.com/maps/search/?api=1&query=$query"
                    MapsApp.WAZE -> "https://waze.com/ul?q=$query"
                }
                runCatching {
                    context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url)))
                }
                mapsAddress = null
            },
            onDismiss = { mapsAddress = null },
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
    onShowMarkdownSource: () -> Unit,
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
        // Code: a partial selection inside a line becomes inline code, a whole paragraph
        // (or several) becomes a code block — see setCodeBlock in EditorBundle's
        // commands.ts. Active for either kind.
        ToolbarToggleButton(Icons.Filled.Code, "Code", s.inCode || s.code) { coordinator.execCommand("codeBlock") }

        ToolbarDivider()
        ToolbarToggleButton(Icons.Filled.FormatListBulleted, "Bullet List", s.inBulletList) { coordinator.execCommand("bulletList") }
        ToolbarToggleButton(Icons.Filled.FormatListNumbered, "Number List", s.inOrderedList) { coordinator.execCommand("orderedList") }

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

        ToolbarDivider()
        // Debugging aid — view the Markdown source the current HTML converts to.
        ToolbarIconButton(Icons.Filled.DataObject, "View Markdown Source", onShowMarkdownSource)
    }
}

// In-note find bar (search field + match counter + prev/next + close), with an
// optional replace row behind a toggle. Auto-focuses the field when it appears.
// Highlighting/stepping/replacing happens in the editor via the coordinator.
@Composable
private fun FindBar(
    query: String,
    replacement: String,
    showReplace: Boolean,
    current: Int,
    count: Int,
    onQueryChange: (String) -> Unit,
    onReplacementChange: (String) -> Unit,
    onToggleReplace: () -> Unit,
    onReplace: () -> Unit,
    onReplaceAll: () -> Unit,
    onNext: () -> Unit,
    onPrevious: () -> Unit,
    onClose: () -> Unit,
) {
    val focusRequester = remember { FocusRequester() }
    LaunchedEffect(Unit) { focusRequester.requestFocus() }
    Surface(tonalElevation = 2.dp, shadowElevation = 2.dp) {
        Column(modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    Icons.Filled.Search,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(20.dp),
                )
                Spacer(Modifier.width(8.dp))
                BasicTextField(
                    value = query,
                    onValueChange = onQueryChange,
                    singleLine = true,
                    textStyle = MaterialTheme.typography.bodyLarge.copy(color = MaterialTheme.colorScheme.onSurface),
                    cursorBrush = SolidColor(NotesYellowDark),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    keyboardActions = KeyboardActions(onSearch = { onNext() }),
                    modifier = Modifier
                        .weight(1f)
                        .focusRequester(focusRequester),
                    decorationBox = { inner ->
                        if (query.isEmpty()) {
                            Text("Find in note", color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        inner()
                    },
                )
                if (count > 0 || query.isNotEmpty()) {
                    Text(
                        if (count > 0) "$current/$count" else "0/0",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 6.dp),
                    )
                }
                // Shows/hides the replace row. Turning it on also switches matching to
                // exact case, so a replace only rewrites what was highlighted.
                IconButton(onClick = onToggleReplace) {
                    Icon(
                        Icons.Filled.FindReplace,
                        contentDescription = if (showReplace) "Hide replace" else "Show replace",
                        tint = if (showReplace) MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                IconButton(onClick = onPrevious, enabled = count > 0) {
                    Icon(Icons.Filled.KeyboardArrowUp, contentDescription = "Previous match")
                }
                IconButton(onClick = onNext, enabled = count > 0) {
                    Icon(Icons.Filled.KeyboardArrowDown, contentDescription = "Next match")
                }
                IconButton(onClick = onClose) {
                    Icon(Icons.Filled.Clear, contentDescription = "Close find")
                }
            }
            if (showReplace) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        Icons.Filled.FindReplace,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(20.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                    BasicTextField(
                        value = replacement,
                        onValueChange = onReplacementChange,
                        singleLine = true,
                        textStyle = MaterialTheme.typography.bodyLarge.copy(color = MaterialTheme.colorScheme.onSurface),
                        cursorBrush = SolidColor(NotesYellowDark),
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                        keyboardActions = KeyboardActions(onDone = { onReplace() }),
                        modifier = Modifier.weight(1f),
                        decorationBox = { inner ->
                            if (replacement.isEmpty()) {
                                Text("Replace with", color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            inner()
                        },
                    )
                    TextButton(onClick = onReplace, enabled = count > 0) { Text("Replace") }
                    TextButton(onClick = onReplaceAll, enabled = count > 0) { Text("All") }
                }
            }
        }
    }
}

private enum class MapsApp { GOOGLE, WAZE }

@Composable
private fun MapsChooserDialog(address: String, onPick: (MapsApp) -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Open address in") },
        text = {
            Column {
                Text(address, style = MaterialTheme.typography.bodySmall)
                Spacer(Modifier.height(12.dp))
                TextButton(
                    onClick = { onPick(MapsApp.GOOGLE) },
                    modifier = Modifier.fillMaxWidth(),
                ) { Text("Google Maps") }
                TextButton(
                    onClick = { onPick(MapsApp.WAZE) },
                    modifier = Modifier.fillMaxWidth(),
                ) { Text("Waze") }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun MarkdownSourceDialog(markdown: String, onDismiss: () -> Unit) {
    val clipboard = LocalClipboardManager.current
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Markdown Source") },
        text = {
            SelectionContainer {
                Text(
                    markdown.ifEmpty { "(empty)" },
                    fontFamily = FontFamily.Monospace,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier
                        .heightIn(max = 360.dp)
                        .verticalScroll(rememberScrollState()),
                )
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Close") } },
        dismissButton = {
            TextButton(onClick = { clipboard.setText(AnnotatedString(markdown)) }) { Text("Copy") }
        },
    )
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

// MARK: - Attachments (view only — attachments are created and edited on the desktop)

/**
 * Why an attachment couldn't be opened. NOT_ON_DEVICE means the blob hasn't been pulled
 * down yet; NO_APP means nothing installed handles that file type (common for Office
 * documents on a device with no Word or Docs). They call for different advice, so the
 * dialog tells them apart.
 */
private enum class AttachmentOpenError { NOT_ON_DEVICE, NO_APP }

/**
 * Builds the intent that opens a note attachment in whichever app handles that file
 * type, the way Gmail opens an attachment. The file is handed over as a content:// URI
 * from our FileProvider with temporary read permission — Android blocks file:// URIs
 * across app boundaries.
 *
 * Returns null if the file isn't on this device yet (its blob may still be syncing), so
 * the caller can say so instead of failing silently. Reading the file and its metadata
 * is the caller's cue to run this off the main thread; launching the intent it returns
 * belongs back on the main thread.
 */
private fun attachmentViewIntent(
    context: android.content.Context,
    resourceId: String,
): android.content.Intent? {
    val file = DatabaseManager.shared.resourceLocalFile(resourceId) ?: return null
    if (!file.exists()) return null
    val mime = DatabaseManager.shared.resourceMeta(resourceId)?.second?.takeIf { it.isNotBlank() }
        ?: "application/octet-stream"
    return runCatching {
        val uri = androidx.core.content.FileProvider.getUriForFile(
            context,
            "${context.packageName}.fileprovider",
            file,
        )
        android.content.Intent(android.content.Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
        }
    }.getOrNull()
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
