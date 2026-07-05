package com.ikuteam.notestn.ui.sidebar

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Notes
import androidx.compose.material.icons.filled.CreateNewFolder
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.ikuteam.notestn.data.Folder
import com.ikuteam.notestn.viewmodel.NotesViewModel

/**
 * Mirrors Mac/NotesTN/NotesTN/Views/SidebarView.swift: "All Notes" + a list of
 * notebooks, with add/rename/delete actions (long-press instead of right-click).
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun SidebarScreen(
    viewModel: NotesViewModel,
    onFolderClick: (Folder?) -> Unit,
) {
    val folders by viewModel.folders.collectAsStateWithLifecycle()
    val selectedFolderId by viewModel.selectedFolderId.collectAsStateWithLifecycle()

    var showAddDialog by remember { mutableStateOf(false) }
    var renamingFolder by remember { mutableStateOf<Folder?>(null) }
    var menuFolderId by remember { mutableStateOf<String?>(null) }
    var pendingDelete by remember { mutableStateOf<Folder?>(null) }

    Scaffold(
        topBar = { TopAppBar(title = { Text("Notes TN") }) },
        floatingActionButton = {
            FloatingActionButton(onClick = { showAddDialog = true }) {
                Icon(Icons.Default.CreateNewFolder, contentDescription = "Add Notebook")
            }
        }
    ) { padding ->
        LazyColumn(modifier = Modifier.padding(padding).fillMaxSize()) {
            item {
                NotebookRow(
                    title = "All Notes",
                    icon = Icons.AutoMirrored.Filled.Notes,
                    selected = selectedFolderId == null,
                    onClick = { onFolderClick(null) },
                )
            }
            item {
                Text(
                    "NOTEBOOKS",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(start = 16.dp, top = 20.dp, bottom = 4.dp),
                )
            }
            items(folders, key = { it.id }) { folder ->
                Row {
                    NotebookRow(
                        title = folder.title,
                        icon = Icons.Default.Folder,
                        selected = selectedFolderId == folder.id,
                        onClick = { onFolderClick(folder) },
                        onLongClick = { menuFolderId = folder.id },
                    )
                    DropdownMenu(
                        expanded = menuFolderId == folder.id,
                        onDismissRequest = { menuFolderId = null },
                    ) {
                        DropdownMenuItem(text = { Text("Rename") }, onClick = {
                            menuFolderId = null
                            renamingFolder = folder
                        })
                        DropdownMenuItem(text = { Text("Delete Notebook") }, onClick = {
                            menuFolderId = null
                            pendingDelete = folder
                        })
                    }
                }
            }
        }
    }

    if (showAddDialog) {
        FolderNameDialog(
            title = "New Notebook",
            initialValue = "",
            confirmLabel = "Create",
            onConfirm = { name ->
                viewModel.createFolder(name.ifBlank { "New Notebook" })
                showAddDialog = false
            },
            onDismiss = { showAddDialog = false },
        )
    }

    renamingFolder?.let { folder ->
        FolderNameDialog(
            title = "Rename Notebook",
            initialValue = folder.title,
            confirmLabel = "Rename",
            onConfirm = { name ->
                viewModel.renameFolder(folder, name)
                renamingFolder = null
            },
            onDismiss = { renamingFolder = null },
        )
    }

    pendingDelete?.let { folder ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Delete Notebook") },
            text = { Text("Delete \"${folder.title}\" and all its notes? This can't be undone.") },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.deleteFolder(folder)
                    pendingDelete = null
                }) { Text("Delete") }
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) { Text("Cancel") }
            },
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun NotebookRow(
    title: String,
    icon: ImageVector,
    selected: Boolean,
    onClick: () -> Unit,
    onLongClick: (() -> Unit)? = null,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
            .background(if (selected) MaterialTheme.colorScheme.secondaryContainer else Color.Transparent)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = if (selected) MaterialTheme.colorScheme.onSecondaryContainer else MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.width(16.dp))
        Text(
            title,
            color = if (selected) MaterialTheme.colorScheme.onSecondaryContainer else MaterialTheme.colorScheme.onSurface,
        )
    }
}

@Composable
private fun FolderNameDialog(
    title: String,
    initialValue: String,
    confirmLabel: String,
    onConfirm: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    var text by remember { mutableStateOf(initialValue) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                singleLine = true,
                label = { Text("Notebook name") },
            )
        },
        confirmButton = {
            TextButton(onClick = { onConfirm(text.trim()) }, enabled = text.isNotBlank()) {
                Text(confirmLabel)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}
