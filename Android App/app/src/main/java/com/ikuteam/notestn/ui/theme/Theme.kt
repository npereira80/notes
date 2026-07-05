package com.ikuteam.notestn.ui.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext

// App-wide accent, matching Mac/NotesTN/NotesTN/Assets.xcassets/AccentColor.colorset
// (#FFD60A) — SwiftUI's accentColor cascades through the whole app, so primary and
// primaryContainer are both set here to get the same effect (FAB, active toolbar
// icons, selection indicators, etc.) on Android.
private val DarkColorScheme = darkColorScheme(
    primary = NotesYellow,
    onPrimary = Color.Black,
    primaryContainer = NotesYellow,
    onPrimaryContainer = Color.Black,
    secondary = PurpleGrey80,
    tertiary = Pink80
)

private val LightColorScheme = lightColorScheme(
    primary = NotesYellow,
    onPrimary = Color.Black,
    primaryContainer = NotesYellow,
    onPrimaryContainer = Color.Black,
    secondary = PurpleGrey40,
    tertiary = Pink40
)

@Composable
fun NotesTNTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    // Off by default: Material You would otherwise override the app's brand yellow
    // with wallpaper-derived colors on Android 12+.
    dynamicColor: Boolean = false,
    content: @Composable () -> Unit
) {
    val colorScheme = when {
        dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
            val context = LocalContext.current
            if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        }

        darkTheme -> DarkColorScheme
        else -> LightColorScheme
    }

    MaterialTheme(
        colorScheme = colorScheme,
        typography = Typography,
        content = content
    )
}
