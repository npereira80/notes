package com.ikuteam.notestn.ui.notelist

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Notes
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Circle
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FabPosition
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.FloatingActionButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.ikuteam.notestn.data.Note
import com.ikuteam.notestn.ui.theme.NotesYellow
import com.ikuteam.notestn.viewmodel.NotesViewModel
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
    data class Month(val year: Int, val month: Int) : NoteGroup(4)

    fun title(currentYear: Int): String = when (this) {
        Today -> "Today"
        Yesterday -> "Yesterday"
        Previous7Days -> "Previous 7 Days"
        Previous30Days -> "Previous 30 Days"
        is Month -> {
            val monthName = java.time.Month.of(month).getDisplayName(TextStyle.FULL, Locale.getDefault())
            if (year == currentYear) monthName else "$monthName $year"
        }
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
        else -> NoteGroup.Month(noteDate.year, noteDate.monthValue)
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
    selectedNoteId: String? = null,
    focusSearchOnLaunch: Boolean = false,
    modifier: Modifier = Modifier,
) {
    val notes by viewModel.notes.collectAsStateWithLifecycle()
    val searchText by viewModel.searchText.collectAsStateWithLifecycle()
    val selectedFolder by viewModel.selectedFolder.collectAsStateWithLifecycle()
    val isFocusingSearch by viewModel.isFocusingSearch.collectAsStateWithLifecycle()

    val today = remember { LocalDate.now(zone) }
    val currentYear = today.year

    val navTitle = when {
        searchText.isNotEmpty() -> "Search Results"
        else -> selectedFolder?.title ?: "All Notes"
    }
    val noteCountLabel = if (notes.size == 1) "1 Note" else "${notes.size} Notes"

    // Bottom inset so list content isn't hidden behind the floating search/add bar.
    val listBottomPadding = 88.dp

    Scaffold(
        modifier = modifier,
        containerColor = Color(0xFFF2F2F6),
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
                colors = TopAppBarDefaults.centerAlignedTopAppBarColors(containerColor = Color(0xFFF2F2F6)),
            )
        },
        floatingActionButtonPosition = FabPosition.Center,
        floatingActionButton = {
            FloatingSearchAndAddBar(
                searchText = searchText,
                onSearchTextChange = { viewModel.search(it) },
                onClear = { viewModel.clearSearch() },
                requestFocus = isFocusingSearch || focusSearchOnLaunch,
                onFocusConsumed = { viewModel.consumeFocusSearch() },
                onNewNote = { viewModel.createNote() },
            )
        },
    ) { padding ->
        Column(modifier = Modifier.padding(padding).fillMaxSize()) {
            if (notes.isEmpty()) {
                EmptyState(isSearching = searchText.isNotEmpty(), onCreateNote = { viewModel.createNote() })
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
                            onClick = { onNoteClick(note) },
                            onDelete = { viewModel.deleteNote(note) },
                        )
                    }
                }
            } else {
                val grouped = notes.groupBy { groupFor(it, today) }
                    .toSortedMap(compareBy({ it.order }, { (it as? NoteGroup.Month)?.year?.let { y -> -y } ?: 0 }, { (it as? NoteGroup.Month)?.month?.let { m -> -m } ?: 0 }))

                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(bottom = listBottomPadding),
                ) {
                    grouped.forEach { (group, groupNotes) ->
                        item(key = "header-${group.hashCode()}") {
                            Text(
                                group.title(currentYear),
                                style = MaterialTheme.typography.headlineSmall,
                                color = MaterialTheme.colorScheme.onSurface,
                                modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 20.dp, bottom = 8.dp),
                            )
                        }
                        item(key = "card-${group.hashCode()}") {
                            // All notes in this section share one rounded card, with thin
                            // dividers between rows — mirrors the iOS Notes list grouping.
                            Surface(
                                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                                shape = RoundedCornerShape(14.dp),
                                color = Color.White,
                            ) {
                                Column {
                                    groupNotes.forEachIndexed { index, note ->
                                        NoteRow(
                                            note = note,
                                            dateString = rowDateString(note, today),
                                            selected = note.id == selectedNoteId,
                                            onClick = { onNoteClick(note) },
                                            onDelete = { viewModel.deleteNote(note) },
                                        )
                                        if (index != groupNotes.lastIndex) {
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
                }
            }
        }
    }
}

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
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
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
            modifier = Modifier.weight(1f),
        )
        FloatingActionButton(
            onClick = onNewNote,
            shape = RoundedCornerShape(14.dp),
            // Default FAB elevation (6dp/6dp/6dp/8dp), halved.
            elevation = FloatingActionButtonDefaults.elevation(
                defaultElevation = 3.dp,
                pressedElevation = 3.dp,
                focusedElevation = 3.dp,
                hoveredElevation = 4.dp,
            ),
        ) {
            Icon(Icons.Default.Add, contentDescription = "New Note")
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
    modifier: Modifier = Modifier,
) {
    val focusRequester = remember { FocusRequester() }

    LaunchedEffect(requestFocus) {
        if (requestFocus) {
            focusRequester.requestFocus()
            onFocusConsumed()
        }
    }

    // Same elevation/shape language as the FAB next to it, so the two read as one
    // floating control group. `modifier` already carries `weight(1f)` from the
    // caller's Row, so only height needs fixing here.
    Surface(
        modifier = modifier.height(56.dp),
        shape = RoundedCornerShape(14.dp),
        color = Color(0xFFFCFCFC),
        border = BorderStroke(0.5.dp, Color.Gray.copy(alpha = 0.5f)),
        tonalElevation = 3.dp,
        shadowElevation = 3.dp,
    ) {
        Row(
            modifier = Modifier.fillMaxSize().padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Default.Search, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
            TextField(
                value = text,
                onValueChange = onTextChange,
                modifier = Modifier
                    .weight(1f)
                    .focusRequester(focusRequester),
                placeholder = { Text("Search") },
                singleLine = true,
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = Color.Transparent,
                    unfocusedContainerColor = Color.Transparent,
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent,
                ),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            )
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
    onClick: () -> Unit,
    onDelete: () -> Unit,
) {
    var showMenu by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }

    Box {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .combinedClickable(onClick = onClick, onLongClick = { showMenu = true })
                .background(if (selected) NotesYellow else Color.Transparent)
                .padding(horizontal = 16.dp, vertical = 16.dp),
        ) {
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
        DropdownMenu(expanded = showMenu, onDismissRequest = { showMenu = false }) {
            DropdownMenuItem(text = { Text("Delete Note") }, onClick = {
                showMenu = false
                confirmDelete = true
            })
        }
    }

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete Note") },
            text = { Text("Delete \"${note.title.ifEmpty { "Untitled" }}\"? This can't be undone.") },
            confirmButton = {
                TextButton(onClick = { onDelete(); confirmDelete = false }) { Text("Delete") }
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
