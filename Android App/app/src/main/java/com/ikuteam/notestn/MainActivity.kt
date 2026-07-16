package com.ikuteam.notestn

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Surface
import androidx.compose.material3.windowsizeclass.ExperimentalMaterial3WindowSizeClassApi
import androidx.compose.material3.windowsizeclass.calculateWindowSizeClass
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import com.ikuteam.notestn.ui.nav.NotesNavHost
import com.ikuteam.notestn.ui.theme.NotesTNTheme
import com.ikuteam.notestn.viewmodel.NotesViewModel

class MainActivity : ComponentActivity() {

    private val viewModel: NotesViewModel by viewModels()

    @OptIn(ExperimentalMaterial3WindowSizeClassApi::class, ExperimentalMaterial3Api::class)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            val windowSizeClass = calculateWindowSizeClass(this)

            NotesTNTheme {
                Surface(
                    modifier = Modifier
                        .fillMaxSize()
                        .keyboardShortcuts(viewModel),
                ) {
                    NotesNavHost(
                        viewModel = viewModel,
                        windowWidthSizeClass = windowSizeClass.widthSizeClass,
                    )
                }
            }
        }
    }
}

/**
 * Hardware-keyboard shortcuts for external keyboards / Chromebooks, mirroring the
 * ⌘N / ⌘⇧N / ⌘F commands in Mac/NotesTN/NotesTN/NotesTNApp.swift.
 */
@Composable
private fun Modifier.keyboardShortcuts(viewModel: NotesViewModel): Modifier = this.onPreviewKeyEvent { event ->
    if (event.type != KeyEventType.KeyDown || !event.isCtrlPressed) return@onPreviewKeyEvent false
    when (event.key) {
        Key.N -> {
            if (event.isShiftPressed) viewModel.createFolder() else viewModel.createNote()
            true
        }
        Key.F -> {
            viewModel.requestFocusSearch()
            true
        }
        else -> false
    }
}
