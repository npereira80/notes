package com.ikuteam.notestn.ui.notelist

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Notes
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Circle
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FabPosition
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil.compose.AsyncImage
import com.ikuteam.notestn.data.DatabaseManager
import com.ikuteam.notestn.data.Note
import com.ikuteam.notestn.ui.common.BackdropBlurState
import com.ikuteam.notestn.ui.common.backdropBlurBackground
import com.ikuteam.notestn.ui.common.captureForBackdropBlur
import com.ikuteam.notestn.ui.common.rememberBackdropBlurState
import com.ikuteam.notestn.ui.theme.CardBackgroundDark
import com.ikuteam.notestn.ui.theme.CardBackgroundLight
import com.ikuteam.notestn.ui.theme.GroupedBackgroundDark
import com.ikuteam.notestn.ui.theme.GroupedBackgroundLight
import com.ikuteam.notestn.ui.theme.NoteRowSelectedInactiveDark
import com.ikuteam.notestn.ui.theme.NoteRowSelectedInactiveLight
import com.ikuteam.notestn.ui.theme.NotesYellowDimmed
import com.ikuteam.notestn.ui.theme.NotesYellowVivid
import com.ikuteam.notestn.ui.theme.SearchFieldBackgroundDark
import com.ikuteam.notestn.ui.theme.SearchFieldBackgroundLight
import com.ikuteam.notestn.viewmodel.NotesViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.format.TextStyle
import java.time.temporal.ChronoUnit
import java.util.Locale

// MARK: - Section grouping (mirrors NoteListView.swift NoteGroup)

private sealed class NoteGroup(val order: Int) {
    object Today : NoteGroup(0)
    object Yesterday : NoteGroup(1)
    object Previous7Days : NoteGroup(2)
    object Previous30Days : NoteGroup(3)
    // Current year only, e.g. "March" — older years are grouped whole via Year below,
    // with no month breakdown.
    data class Month(val month: Int) : NoteGroup(4)
    data class Year(val year: Int) : NoteGroup(5)

    fun title(currentYear: Int): String = when (this) {
        Today -> "Today"
        Yesterday -> "Yesterday"
        Previous7Days -> "Previous 7 Days"
        Previous30Days -> "Previous 30 Days"
        is Month -> java.time.Month.of(month).getDisplayName(TextStyle.FULL, Locale.getDefault())
        is Year -> year.toString()
    }

    // Stable LazyColumn key. The old "header-${hashCode()}" mixed identity hashes
    // (the singleton objects) with structural hashes (the data classes) — a collision
    // between any two would crash with a duplicate-key exception.
    val key: String
        get() = when (this) {
            Today -> "today"
            Yesterday -> "yesterday"
            Previous7Days -> "previous7"
            Previous30Days -> "previous30"
            is Month -> "month-$month"
            is Year -> "year-$year"
        }
}

private val zone: ZoneId = ZoneId.systemDefault()

// Row title / section header text is 80% bigger than the base Material scale, per request.
private const val BIGGER_TEXT_SCALE = 1.8f

private fun groupFor(note: Note, today: LocalDate): NoteGroup {
    val noteDate = Instant.ofEpochMilli(note.updatedTime).atZone(zone).toLocalDate()
    val days = ChronoUnit.DAYS.between(noteDate, today)
    return when {
        noteDate == today -> NoteGroup.Today
        days == 1L -> NoteGroup.Yesterday
        days < 7 -> NoteGroup.Previous7Days
        days < 30 -> NoteGroup.Previous30Days
        noteDate.year == today.year -> NoteGroup.Month(noteDate.monthValue)
        else -> NoteGroup.Year(noteDate.year)
    }
}

private fun rowDateString(note: Note, today: LocalDate): String {
    val instant = Instant.ofEpochMilli(note.updatedTime)
    val zoned = instant.atZone(zone)
    val noteDate = zoned.toLocalDate()
    val days = ChronoUnit.DAYS.between(noteDate, today)
    return when {
        noteDate == today -> DateTimeFormatter.ofPattern("HH:mm").format(zoned)
        days == 1L -> "Yesterday"
        days < 7 -> zoned.dayOfWeek.getDisplayName(TextStyle.FULL, Locale.getDefault())
        else -> DateTimeFormatter.ofLocalizedDate(FormatStyle.SHORT).withLocale(Locale.getDefault()).format(noteDate)
    }
}

/**
 * Mirrors Mac/NotesTN/NotesTN/Views/NoteListView.swift: search + notes grouped by
 * recency (flat list while searching). The search field and "New Note" button float
 * together as a bottom bar over the list, mirroring the sidebar's floating add-notebook
 * button.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NoteListScreen(
    viewModel: NotesViewModel,
    onNoteClick: (Note) -> Unit,
    isTrash: Boolean = false,
    selectedNoteId: String? = null,
    focusSearchOnLaunch: Boolean = false,
    onOpenSidebar: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val liveNotes by viewModel.notes.collectAsStateWithLifecycle()
    val trashedNotes by viewModel.trashedNotes.collectAsStateWithLifecycle()
    val trashedFolders by viewModel.trashedFolders.collectAsStateWithLifecycle()
    val notes = if (isTrash) trashedNotes else liveNotes
    val searchText by viewModel.searchText.collectAsStateWithLifecycle()
    val selectedFolder by viewModel.selectedFolder.collectAsStateWithLifecycle()
    val isFocusingSearch by viewModel.isFocusingSearch.collectAsStateWithLifecycle()
    val isSyncing by viewModel.isSyncing.collectAsStateWithLifecycle()
    val isRefreshing by viewModel.isRefreshing.collectAsStateWithLifecycle()
    val syncError by viewModel.syncError.collectAsStateWithLifecycle()
    // Read once at screen level instead of inside each row's lambda — reading the
    // state per row made every visible row recompose whenever focus flipped between
    // the list and the editor (two-pane); this way only the selected row's
    // parameters actually change.
    val editorFocused = viewModel.isEditorFocused
    val darkTheme = isSystemInDarkTheme()
    val groupedBackground = if (darkTheme) GroupedBackgroundDark else GroupedBackgroundLight
    val cardBackground = if (darkTheme) CardBackgroundDark else CardBackgroundLight
    val searchFieldBackground = if (darkTheme) SearchFieldBackgroundDark else SearchFieldBackgroundLight
    var confirmEmptyTrash by remember { mutableStateOf(false) }
    // Backdrop blur source — the note list content scrolling behind the floating
    // search bar / new note button (see BackdropBlurState above).
    val blurState = rememberBackdropBlurState()

    // Keyed on the note lists (not remember {} with no keys): a plain remember froze
    // "today" at whatever date the screen first composed on. In an app that stays in
    // memory for days, every "Today"/"Yesterday" label and date group was wrong after
    // midnight until the app was killed and reopened — one of the "temporary visual
    // glitches fixed by restart". Any data refresh (sync, edit, folder switch)
    // re-evaluates it now.
    val today = remember(liveNotes, trashedNotes) { LocalDate.now(ZoneId.systemDefault()) }
    val currentYear = today.year

    val navTitle = when {
        isTrash -> "Trash"
        searchText.isNotEmpty() -> "Search Results"
        else -> selectedFolder?.title ?: "All Notes"
    }
    val noteCountLabel = if (notes.size == 1) "1 Note" else "${notes.size} Notes"

    // Bottom inset so list content isn't hidden behind the floating search/add bar.
    val listBottomPadding = 88.dp

    Scaffold(
        modifier = modifier,
        containerColor = groupedBackground,
        topBar = {
            CenterAlignedTopAppBar(
                title = {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(navTitle, fontWeight = FontWeight.Bold)
                        Text(
                            noteCountLabel,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                },
                navigationIcon = {
                    // The app opens straight into the last-used notebook's note list
                    // (see NotesNavHost) rather than the notebooks list, so this is
                    // the only way back to it.
                    if (onOpenSidebar != null) {
                        IconButton(onClick = onOpenSidebar) {
                            Icon(Icons.Filled.Menu, contentDescription = "Notebooks")
                        }
                    }
                },
                actions = {
                    if (isTrash && (trashedNotes.isNotEmpty() || trashedFolders.isNotEmpty())) {
                        TextButton(onClick = { confirmEmptyTrash = true }) { Text("Empty Trash") }
                    }
                },
                colors = TopAppBarDefaults.centerAlignedTopAppBarColors(containerColor = groupedBackground),
            )
        },
        floatingActionButtonPosition = FabPosition.Center,
        floatingActionButton = {
            // Notes can't be created directly in Trash — only search is offered there.
            FloatingSearchAndAddBar(
                searchText = searchText,
                onSearchTextChange = { viewModel.search(it) },
                onClear = { viewModel.clearSearch() },
                requestFocus = isFocusingSearch || focusSearchOnLaunch,
                onFocusConsumed = { viewModel.consumeFocusSearch() },
                // Routes through onNoteClick (not just viewModel.createNote()) so the
                // new note opens immediately — on compact width that's the callback
                // that also navigates to the editor destination (see NotesNavHost);
                // on two-pane width it's already reactive and this is a no-op re-select.
                onNewNote = { viewModel.createNote { note -> onNoteClick(note) } },
                showAddButton = !isTrash,
                fieldBackground = searchFieldBackground,
                blurState = blurState,
            )
        },
    ) { padding ->
        Column(modifier = Modifier.padding(padding).fillMaxSize().captureForBackdropBlur(blurState)) {
            // Fixed-height slot (the indicator's own default height) rather than
            // conditionally inserting the indicator — inserting it shifted the whole
            // list down and back up every time the 2s-debounced background push ran,
            // i.e. periodically while typing in the two-pane layout.
            Box(modifier = Modifier.fillMaxWidth().height(4.dp)) {
                if (isSyncing) {
                    LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                }
            }
            if (syncError != null) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        "Sync failed: $syncError",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error,
                        modifier = Modifier.weight(1f),
                    )
                    TextButton(onClick = { viewModel.clearSyncError() }) { Text("Dismiss") }
                }
            }
            PullToRefreshBox(
                // isRefreshing (user-initiated), not isSyncing — driving this with
                // isSyncing made the refresh spinner flash into view for every
                // 2s-debounced background push (i.e. after each pause in typing on
                // two-pane devices). Background sync activity still shows in the
                // slim progress bar above.
                isRefreshing = isRefreshing,
                // Plain sync, not force — force skips the local-vs-remote timestamp
                // check entirely (see JoplinSyncEngine.upsertNote), which would let a
                // pull-to-refresh run right after a not-yet-pushed local delete
                // overwrite it with the still-undeleted server copy, undoing it.
                onRefresh = { viewModel.refreshNow() },
                modifier = Modifier.weight(1f),
            ) {
            if (notes.isEmpty()) {
                EmptyState(isSearching = searchText.isNotEmpty(), onCreateNote = { viewModel.createNote { note -> onNoteClick(note) } })
            } else if (searchText.isNotEmpty()) {
                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(bottom = listBottomPadding),
                ) {
                    items(notes, key = { it.id }) { note ->
                        NoteRow(
                            note = note,
                            dateString = rowDateString(note, today),
                            selected = note.id == selectedNoteId,
                            editorFocused = editorFocused,
                            isTrash = isTrash,
                            onClick = { onNoteClick(note) },
                            onDelete = { viewModel.deleteNote(note) },
                            onRestore = { viewModel.restoreNote(note) },
                            onPermanentDelete = { viewModel.permanentlyDeleteNote(note) },
                            onTogglePin = { viewModel.togglePin(note) },
                        )
                    }
                }
            } else {
                // Pinning only applies to live notes — pulled out of their date group
                // into their own section (first, like Apple Notes) so a note doesn't
                // appear twice.
                // remember()ed — filtering, grouping and sorting the whole list used
                // to re-run on every recomposition (every keystroke-save, sync tick,
                // selection change), not just when the data actually changed.
                val pinnedNotes = remember(notes, isTrash) {
                    if (isTrash) emptyList() else notes.filter { it.isPinned }.sortedByDescending { it.updatedTime }
                }
                val grouped = remember(notes, isTrash, today) {
                    val unpinnedNotes = if (isTrash) notes else notes.filterNot { it.isPinned }
                    unpinnedNotes.groupBy { groupFor(it, today) }
                        .toSortedMap(
                            compareBy(
                                { it.order },
                                { (it as? NoteGroup.Month)?.month?.let { m -> -m } ?: 0 },
                                { (it as? NoteGroup.Year)?.year?.let { y -> -y } ?: 0 }
                            )
                        )
                }

                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(bottom = listBottomPadding),
                ) {
                    if (pinnedNotes.isNotEmpty()) {
                        item(key = "header-pinned") {
                            Text(
                                "Pinned",
                                style = MaterialTheme.typography.headlineSmall,
                                color = MaterialTheme.colorScheme.onSurface,
                                modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 20.dp, bottom = 8.dp),
                            )
                        }
                        noteCardRows(
                            notes = pinnedNotes,
                            today = today,
                            selectedNoteId = selectedNoteId,
                            editorFocused = editorFocused,
                            isTrash = false,
                            cardBackground = cardBackground,
                            viewModel = viewModel,
                            onNoteClick = onNoteClick,
                        )
                    }
                    if (isTrash && trashedFolders.isNotEmpty()) {
                        item(key = "header-trashed-notebooks") {
                            Text(
                                "Notebooks",
                                style = MaterialTheme.typography.headlineSmall,
                                color = MaterialTheme.colorScheme.onSurface,
                                modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 20.dp, bottom = 8.dp),
                            )
                        }
                        item(key = "card-trashed-notebooks") {
                            Surface(
                                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                                shape = RoundedCornerShape(14.dp),
                                color = cardBackground,
                            ) {
                                Column {
                                    trashedFolders.forEachIndexed { index, folder ->
                                        TrashedFolderRow(
                                            title = folder.title,
                                            onRestore = { viewModel.restoreFolder(folder) },
                                            onPermanentDelete = { viewModel.permanentlyDeleteFolder(folder) },
                                        )
                                        if (index != trashedFolders.lastIndex) {
                                            HorizontalDivider(
                                                modifier = Modifier.padding(start = 16.dp, end = 16.dp),
                                                thickness = 0.5.dp,
                                                color = MaterialTheme.colorScheme.outlineVariant,
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                    grouped.forEach { (group, groupNotes) ->
                        item(key = "header-${group.key}") {
                            Text(
                                group.title(currentYear),
                                style = MaterialTheme.typography.headlineSmall,
                                color = MaterialTheme.colorScheme.onSurface,
                                modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 20.dp, bottom = 8.dp),
                            )
                        }
                        // One LazyColumn item PER ROW (see noteCardRows) instead of one
                        // giant item wrapping the whole group — LazyColumn can't
                        // virtualize inside an item, so a month group with 100+ notes
                        // used to compose and measure every row in a single frame the
                        // moment it scrolled into view, defeating lazy lists entirely.
                        noteCardRows(
                            notes = groupNotes,
                            today = today,
                            selectedNoteId = selectedNoteId,
                            editorFocused = editorFocused,
                            isTrash = isTrash,
                            cardBackground = cardBackground,
                            viewModel = viewModel,
                            onNoteClick = onNoteClick,
                        )
                    }
                }
            }
            }
        }
    }

    if (confirmEmptyTrash) {
        AlertDialog(
            onDismissRequest = { confirmEmptyTrash = false },
            title = { Text("Empty Trash") },
            text = { Text("Permanently delete everything in Trash? This can't be undone.") },
            confirmButton = {
                TextButton(onClick = { viewModel.emptyTrash(); confirmEmptyTrash = false }) { Text("Empty Trash") }
            },
            dismissButton = {
                TextButton(onClick = { confirmEmptyTrash = false }) { Text("Cancel") }
            },
        )
    }
}

// MARK: - Per-row card items

/**
 * Emits one LazyColumn item per note, drawn so the section still reads as a single
 * rounded card (first/last corners rounded, hairline dividers between rows) —
 * visually identical to the old one-Surface-per-group approach, but each row is its
 * own lazily-composed item. See the call site comment in NoteListScreen.
 */
private fun LazyListScope.noteCardRows(
    notes: List<Note>,
    today: LocalDate,
    selectedNoteId: String?,
    editorFocused: Boolean,
    isTrash: Boolean,
    cardBackground: Color,
    viewModel: NotesViewModel,
    onNoteClick: (Note) -> Unit,
) {
    itemsIndexed(notes, key = { _, note -> note.id }) { index, note ->
        val shape = when {
            notes.size == 1 -> RoundedCornerShape(14.dp)
            index == 0 -> RoundedCornerShape(topStart = 14.dp, topEnd = 14.dp)
            index == notes.lastIndex -> RoundedCornerShape(bottomStart = 14.dp, bottomEnd = 14.dp)
            else -> RectangleShape
        }
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .clip(shape)
                .background(cardBackground),
        ) {
            NoteRow(
                note = note,
                dateString = rowDateString(note, today),
                selected = note.id == selectedNoteId,
                editorFocused = editorFocused,
                isTrash = isTrash,
                onClick = { onNoteClick(note) },
                onDelete = { viewModel.deleteNote(note) },
                onRestore = { viewModel.restoreNote(note) },
                onPermanentDelete = { viewModel.permanentlyDeleteNote(note) },
                onTogglePin = { viewModel.togglePin(note) },
            )
            if (index != notes.lastIndex) {
                HorizontalDivider(
                    modifier = Modifier.padding(start = 16.dp, end = 16.dp),
                    thickness = 0.5.dp,
                    color = MaterialTheme.colorScheme.outlineVariant,
                )
            }
        }
    }
}

// Backdrop blur (search bar / new note button glass) now lives in
// ui/common/BackdropBlur.kt, shared with EditorScreen's formatting toolbar.

// MARK: - Floating search + add bar

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FloatingSearchAndAddBar(
    searchText: String,
    onSearchTextChange: (String) -> Unit,
    onClear: () -> Unit,
    requestFocus: Boolean,
    onFocusConsumed: () -> Unit,
    onNewNote: () -> Unit,
    fieldBackground: Color,
    blurState: BackdropBlurState,
    showAddButton: Boolean = true,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 24.dp)
            .navigationBarsPadding()
            .imePadding(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        FloatingSearchField(
            text = searchText,
            onTextChange = onSearchTextChange,
            onClear = onClear,
            requestFocus = requestFocus,
            onFocusConsumed = onFocusConsumed,
            background = fieldBackground,
            blurState = blurState,
            modifier = Modifier.weight(1f),
        )
        if (showAddButton) {
            val shape = RoundedCornerShape(16.dp)
            // Custom Box instead of FloatingActionButton — FAB draws its own solid
            // Surface internally with no hook to slot a blurred backdrop in behind it,
            // so the glass look needs full control over the draw order (blur, then
            // tint, then icon). "Most opaque" glass setting — see FloatingSearchField's
            // same 0.82 tint alpha.
            Box(
                modifier = Modifier
                    .size(48.dp)
                    .shadow(3.dp, shape)
                    .clip(shape)
                    .backdropBlurBackground(blurState)
                    .background(NotesYellowVivid.copy(alpha = 0.80f))
                    .clickable(onClick = onNewNote),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Default.Add, contentDescription = "New Note", tint = Color.Black)
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FloatingSearchField(
    text: String,
    onTextChange: (String) -> Unit,
    onClear: () -> Unit,
    requestFocus: Boolean,
    onFocusConsumed: () -> Unit,
    background: Color,
    blurState: BackdropBlurState,
    modifier: Modifier = Modifier,
) {
    val focusRequester = remember { FocusRequester() }
    val interactionSource = remember { MutableInteractionSource() }

    LaunchedEffect(requestFocus) {
        if (requestFocus) {
            focusRequester.requestFocus()
            onFocusConsumed()
        }
    }

    // Same elevation/shape language as the FAB next to it, so the two read as one
    // floating control group. `modifier` already carries `weight(1f)` from the
    // caller's Row, so only height needs fixing here.
    //
    // Custom Box instead of Surface — Surface draws its own solid color fill with no
    // hook to slot a blurred backdrop in underneath it, so the glass look needs full
    // control over draw order (blur, then tint, then content). 0.80 tint alpha ==
    // current glass opacity setting (still technically translucent/blurred, but
    // substantially opaque rather than very see-through).
    val shape = RoundedCornerShape(16.dp)
    Box(
        modifier = modifier
            .height(48.dp)
            .shadow(3.dp, shape)
            .clip(shape)
            .backdropBlurBackground(blurState)
            .background(background.copy(alpha = 0.80f))
            .border(0.5.dp, NotesYellowVivid, shape),
    ) {
        Row(
            modifier = Modifier.fillMaxSize().padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Default.Search, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
            // The standard TextField enforces TextFieldDefaults.MinHeight (56dp) via
            // padding baked into its internal decoration box, which can't be overridden
            // through TextField's own parameters — with this field compressed to 48dp,
            // that excess padding pushed the placeholder/text down and clipped it at the
            // bottom (the earlier y-offset nudge just moved the already-clipped glyphs,
            // it didn't remove the clipping). Building it from BasicTextField +
            // TextFieldDefaults.DecorationBox instead exposes contentPadding directly, so
            // it can be sized to actually fit this field's real height.
            BasicTextField(
                value = text,
                onValueChange = onTextChange,
                modifier = Modifier
                    .weight(1f)
                    .focusRequester(focusRequester),
                singleLine = true,
                textStyle = MaterialTheme.typography.bodyLarge.copy(color = MaterialTheme.colorScheme.onSurface),
                cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                interactionSource = interactionSource,
            ) { innerTextField ->
                TextFieldDefaults.DecorationBox(
                    value = text,
                    innerTextField = innerTextField,
                    enabled = true,
                    singleLine = true,
                    visualTransformation = VisualTransformation.None,
                    interactionSource = interactionSource,
                    placeholder = { Text("Search") },
                    colors = TextFieldDefaults.colors(
                        focusedContainerColor = Color.Transparent,
                        unfocusedContainerColor = Color.Transparent,
                        focusedIndicatorColor = Color.Transparent,
                        unfocusedIndicatorColor = Color.Transparent,
                    ),
                    contentPadding = PaddingValues(horizontal = 0.dp, vertical = 0.dp),
                )
            }
            if (text.isNotEmpty()) {
                IconButton(onClick = onClear) {
                    Icon(Icons.Default.Clear, contentDescription = "Clear search")
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun NoteRow(
    note: Note,
    dateString: String,
    selected: Boolean,
    editorFocused: Boolean = false,
    onClick: () -> Unit,
    onDelete: () -> Unit,
    isTrash: Boolean = false,
    onRestore: () -> Unit = {},
    onPermanentDelete: () -> Unit = {},
    onTogglePin: () -> Unit = {},
) {
    var showMenu by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    // produceState on Dispatchers.IO — resourceLocalFile is a synchronous SQLite
    // query, and the old remember(note.id, note.body) ran it on the main thread for
    // every row entering composition (and re-ran it on every keystroke-save of the
    // open note, since the body changed). During a sync the DB is busy writing, so
    // those main-thread reads visibly hitched the list. Keyed on the (cached)
    // firstImageResourceId, so body edits that don't change the first image don't
    // re-query at all.
    val thumbnailFile by produceState<File?>(initialValue = null, note.firstImageResourceId) {
        val resourceId = note.firstImageResourceId
        value = if (resourceId == null) {
            null
        } else {
            withContext(Dispatchers.IO) { DatabaseManager.shared.resourceLocalFile(resourceId) }
        }
    }
    val darkTheme = isSystemInDarkTheme()

    Box {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                // Margin from the list edge + rounded corners on the selection
                // background — mirrors Mac's NoteListView.swift and the sidebar's
                // own rounded/inset selection above.
                .padding(horizontal = 8.dp)
                .clip(RoundedCornerShape(8.dp))
                .combinedClickable(onClick = onClick, onLongClick = { showMenu = true })
                .background(
                    if (selected) {
                        // editorFocused = the editor pane has focus (typing) in the
                        // tablet two-pane layout -> Gray. Otherwise the note list has
                        // focus (browsing) -> Dimmed yellow. See NotesViewModel.isEditorFocused.
                        if (editorFocused) {
                            if (darkTheme) NoteRowSelectedInactiveDark else NoteRowSelectedInactiveLight
                        } else {
                            NotesYellowDimmed
                        }
                    } else {
                        Color.Transparent
                    }
                )
                // Only the start (left) side is shared at the Row level now — the end
                // (right) side is applied to the text column instead, so the thumbnail
                // can sit flush against the row's right edge (0 padding) independent of
                // the text's own right margin.
                .padding(start = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
        // Text column carries its own vertical + end (right) padding now (used to come
        // from the Row above, shared with the thumbnail) so the thumbnail's own padding
        // can be set independently, without relying on a negative-padding counter-hack
        // (Compose's Modifier.padding throws at runtime on negative values, unlike
        // SwiftUI's).
        Column(modifier = Modifier.weight(1f).padding(top = 16.dp, end = 16.dp, bottom = 16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                if (note.isTodo) {
                    Icon(
                        if (note.todoCompleted) Icons.Default.CheckCircle else Icons.Default.Circle,
                        contentDescription = null,
                        tint = if (note.todoCompleted) MaterialTheme.colorScheme.tertiary else MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.height(20.dp),
                    )
                }
                Text(
                    note.title.ifEmpty { "Untitled" },
                    style = MaterialTheme.typography.bodyLarge.let {
                        it.copy(fontSize = it.fontSize * BIGGER_TEXT_SCALE * 0.8f * 0.8f)
                    },
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                )
            }
            val subtitle = if (note.preview.isEmpty()) dateString else "$dateString  ${note.preview}"
            Text(
                subtitle,
                style = MaterialTheme.typography.bodySmall.let {
                    it.copy(fontSize = it.fontSize * 1.2f)
                },
                color = if (selected) Color.Black.copy(alpha = 0.75f) else MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
            if (thumbnailFile != null) {
                AsyncImage(
                    model = thumbnailFile,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier
                        // Independent of the text column's own vertical padding (above) —
                        // the Row itself no longer applies shared vertical padding, so this
                        // 4dp is the thumbnail's real, direct top/bottom gap.
                        .padding(start = 12.dp, top = 4.dp, end = 6.dp, bottom = 4.dp)
                        .size(56.dp)
                        .clip(RoundedCornerShape(10.dp)),
                )
            }
        }
        DropdownMenu(expanded = showMenu, onDismissRequest = { showMenu = false }) {
            if (isTrash) {
                DropdownMenuItem(text = { Text("Restore") }, onClick = {
                    showMenu = false
                    onRestore()
                })
                DropdownMenuItem(text = { Text("Delete Permanently") }, onClick = {
                    showMenu = false
                    confirmDelete = true
                })
            } else {
                DropdownMenuItem(text = { Text(if (note.isPinned) "Unpin Note" else "Pin Note") }, onClick = {
                    showMenu = false
                    onTogglePin()
                })
                DropdownMenuItem(text = { Text("Delete Note") }, onClick = {
                    showMenu = false
                    confirmDelete = true
                })
            }
        }
    }

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text(if (isTrash) "Delete Permanently" else "Delete Note") },
            text = {
                Text(
                    if (isTrash) {
                        "Permanently delete \"${note.title.ifEmpty { "Untitled" }}\"? This can't be undone."
                    } else {
                        "Move \"${note.title.ifEmpty { "Untitled" }}\" to Trash?"
                    }
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    if (isTrash) onPermanentDelete() else onDelete()
                    confirmDelete = false
                }) { Text("Delete") }
            },
            dismissButton = {
                TextButton(onClick = { confirmDelete = false }) { Text("Cancel") }
            },
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun TrashedFolderRow(
    title: String,
    onRestore: () -> Unit,
    onPermanentDelete: () -> Unit,
) {
    var showMenu by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }

    Box {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .combinedClickable(onClick = {}, onLongClick = { showMenu = true })
                .padding(horizontal = 16.dp, vertical = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(title, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.SemiBold)
        }
        DropdownMenu(expanded = showMenu, onDismissRequest = { showMenu = false }) {
            DropdownMenuItem(text = { Text("Restore") }, onClick = {
                showMenu = false
                onRestore()
            })
            DropdownMenuItem(text = { Text("Delete Permanently") }, onClick = {
                showMenu = false
                confirmDelete = true
            })
        }
    }

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete Permanently") },
            text = { Text("Permanently delete \"$title\" and all its notes? This can't be undone.") },
            confirmButton = {
                TextButton(onClick = { onPermanentDelete(); confirmDelete = false }) { Text("Delete") }
            },
            dismissButton = {
                TextButton(onClick = { confirmDelete = false }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun EmptyState(isSearching: Boolean, onCreateNote: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(
            if (isSearching) Icons.Default.Search else Icons.AutoMirrored.Filled.Notes,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.outlineVariant,
        )
        Spacer(Modifier.height(12.dp))
        Text(
            if (isSearching) "No Results" else "No Notes",
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (!isSearching) {
            Spacer(Modifier.height(12.dp))
            TextButton(onClick = onCreateNote) { Text("Create a Note") }
        }
    }
}
