package com.ikuteam.notestn.ui.common

import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.BlurEffect
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.layer.GraphicsLayer
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.graphics.rememberGraphicsLayer
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

// MARK: - Backdrop blur (hand-rolled, no third-party blur library)
//
// Real frosted-glass behind floating glass elements (note list's search bar / new
// note button, editor's formatting toolbar): captures whatever's drawn behind them
// into an offscreen GraphicsLayer with a blur RenderEffect applied (Android
// 12+/API 31 android.graphics.RenderEffect, wrapped by Compose's own
// GraphicsLayer.renderEffect — see build.gradle.kts's minSdk bump to 31, there's no
// fallback below that), then redraws that exact captured content translated into
// each glass element's own coordinate space, behind a translucent tint. This is the
// same fundamental technique blur libraries like "Haze" use internally, just built
// directly on Compose's GraphicsLayer API instead of a dependency.
//
// Shared by NoteListScreen (search bar / new note button) and EditorScreen
// (formatting toolbar) so all glass elements use exactly the same blur behavior.
internal class BackdropBlurState(val layer: GraphicsLayer) {
    var sourceCoordinates: LayoutCoordinates? = null
}

@Composable
internal fun rememberBackdropBlurState(blurRadius: Dp = 24.dp): BackdropBlurState {
    val layer = rememberGraphicsLayer()
    val density = LocalDensity.current
    val state = remember(layer) { BackdropBlurState(layer) }
    // Assign synchronously (not via LaunchedEffect) so the blur is in place on the very
    // first frame — a coroutine-based assignment lands a frame late, which was showing
    // up as a flash/patch of sharp, unblurred content (card/toolbar-icon rectangles)
    // behind the glass element before the effect kicked in.
    val radiusPx = with(density) { blurRadius.toPx() }
    layer.renderEffect = BlurEffect(radiusPx, radiusPx, TileMode.Clamp)
    return state
}

// Applied to the content that should be visible (and blurrable) behind the glass
// elements — draws it normally on screen AND simultaneously records the same pixels
// into the shared GraphicsLayer for reuse.
internal fun Modifier.captureForBackdropBlur(state: BackdropBlurState): Modifier =
    this
        .onGloballyPositioned { state.sourceCoordinates = it }
        .drawWithContent {
            state.layer.record { this@drawWithContent.drawContent() }
            drawContent()
        }

// Applied to a glass element's own background — paints the captured, blurred backdrop
// translated into this element's local coordinate space, so the slice that shows
// through lines up with what's really behind it on screen.
internal fun Modifier.backdropBlurBackground(state: BackdropBlurState): Modifier = composed {
    var localCoordinates by remember { mutableStateOf<LayoutCoordinates?>(null) }
    this
        .onGloballyPositioned { localCoordinates = it }
        .drawWithContent {
            val source = state.sourceCoordinates
            val local = localCoordinates
            if (source != null && local != null) {
                val delta = source.positionInRoot() - local.positionInRoot()
                translate(left = delta.x, top = delta.y) {
                    drawLayer(state.layer)
                }
            }
            drawContent()
        }
}
