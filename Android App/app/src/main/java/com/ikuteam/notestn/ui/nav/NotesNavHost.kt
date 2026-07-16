package com.ikuteam.notestn.ui.nav

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.material3.windowsizeclass.WindowWidthSizeClass
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.ikuteam.notestn.ui.editor.EditorEmptyState
import com.ikuteam.notestn.ui.editor.EditorScreen
import com.ikuteam.notestn.ui.notelist.NoteListScreen
import com.ikuteam.notestn.ui.settings.LoginScreen
import com.ikuteam.notestn.ui.settings.SettingsScreen
import com.ikuteam.notestn.ui.sidebar.SidebarScreen
import com.ikuteam.notestn.viewmodel.NotesViewModel

private const val ALL_NOTES_SENTINEL = "all"

/**
 * Navigation host. Phone (Compact width): drill-down stack, sidebar -> note list ->
 * editor, matching a single-column mobile note app. Tablet/large screens (Medium+
 * width): the note-list route shows notes and the editor side by side instead of
 * pushing a new destination — an adaptive approximation of the Mac app's persistent
 * 3-column NavigationSplitView (see Mac/NotesTN/NotesTN/ContentView.swift).
 */
@Composable
fun NotesNavHost(
    viewModel: NotesViewModel,
    windowWidthSizeClass: WindowWidthSizeClass,
) {
    val navController = rememberNavController()
    val isWide = windowWidthSizeClass != WindowWidthSizeClass.Compact

    // Open straight into the last notebook's note list (persisted in NotesViewModel)
    // instead of the notebooks list — the sidebar is still reachable from the note
    // list's navigation icon (see onOpenSidebar below), it's just no longer the
    // first thing shown.
    val startDestination = remember { "notes/${viewModel.selectedFolderId.value ?: ALL_NOTES_SENTINEL}" }

    NavHost(navController = navController, startDestination = startDestination) {
        composable("sidebar") {
            SidebarScreen(
                viewModel = viewModel,
                onFolderClick = { folder ->
                    viewModel.selectFolder(folder)
                    navController.navigate("notes/${folder?.id ?: ALL_NOTES_SENTINEL}")
                },
                onTrashClick = {
                    viewModel.selectTrash()
                    navController.navigate("trash")
                },
                onSettingsClick = { navController.navigate("settings") },
            )
        }

        composable("settings") {
            SettingsScreen(
                onBack = { navController.popBackStack() },
                onLoginClick = { navController.navigate("login") },
                onForceResync = { viewModel.syncNow(force = true) },
            )
        }

        composable("login") {
            LoginScreen(
                onBack = { navController.popBackStack() },
                onLoggedIn = { navController.popBackStack() },
            )
        }

        composable(
            route = "notes/{folderId}",
            arguments = listOf(navArgument("folderId") { type = NavType.StringType }),
        ) {
            if (isWide) {
                TwoPaneNotesAndEditor(
                    viewModel = viewModel,
                    isTrash = false,
                    onOpenSidebar = { navController.navigate("sidebar") },
                )
            } else {
                NoteListScreen(
                    viewModel = viewModel,
                    isTrash = false,
                    onNoteClick = { note ->
                        viewModel.selectNote(note)
                        navController.navigate("editor/${note.id}")
                    },
                    onOpenSidebar = { navController.navigate("sidebar") },
                )
            }
        }

        composable("trash") {
            if (isWide) {
                TwoPaneNotesAndEditor(
                    viewModel = viewModel,
                    isTrash = true,
                    onOpenSidebar = { navController.navigate("sidebar") },
                )
            } else {
                NoteListScreen(
                    viewModel = viewModel,
                    isTrash = true,
                    onNoteClick = { note ->
                        viewModel.selectNote(note)
                        navController.navigate("editor/${note.id}")
                    },
                    onOpenSidebar = { navController.navigate("sidebar") },
                )
            }
        }

        composable(
            route = "editor/{noteId}",
            arguments = listOf(navArgument("noteId") { type = NavType.StringType }),
        ) { backStackEntry ->
            val noteId = backStackEntry.arguments?.getString("noteId")
            val notes by viewModel.notes.collectAsStateWithLifecycle()
            val trashedNotes by viewModel.trashedNotes.collectAsStateWithLifecycle()
            val note = notes.firstOrNull { it.id == noteId } ?: trashedNotes.firstOrNull { it.id == noteId }
            if (note != null) {
                EditorScreen(
                    note = note,
                    viewModel = viewModel,
                    // From the note itself, not trashedNotes membership — trashedNotes
                    // is only kept fresh while Trash is selected (see loadNotes), so a
                    // stale snapshot could mark a live note read-only here.
                    readOnly = note.deletedTime != null,
                    onBack = { navController.popBackStack() },
                )
            }
        }
    }
}

@Composable
private fun TwoPaneNotesAndEditor(viewModel: NotesViewModel, isTrash: Boolean, onOpenSidebar: () -> Unit) {
    val notes by (if (isTrash) viewModel.trashedNotes else viewModel.notes).collectAsStateWithLifecycle()
    val selectedNoteId by viewModel.selectedNoteId.collectAsStateWithLifecycle()
    val selectedNote = notes.firstOrNull { it.id == selectedNoteId }

    Row(modifier = Modifier.fillMaxSize()) {
        NoteListScreen(
            viewModel = viewModel,
            isTrash = isTrash,
            onNoteClick = { note -> viewModel.selectNote(note) },
            selectedNoteId = selectedNoteId,
            onOpenSidebar = onOpenSidebar,
            modifier = Modifier.width(360.dp).fillMaxHeight(),
        )
        Box(modifier = Modifier.weight(1f).fillMaxHeight()) {
            if (selectedNote != null) {
                EditorScreen(note = selectedNote, viewModel = viewModel, readOnly = isTrash, onBack = null)
            } else {
                EditorEmptyState(onCreateNote = { viewModel.createNote() })
            }
        }
    }
}
