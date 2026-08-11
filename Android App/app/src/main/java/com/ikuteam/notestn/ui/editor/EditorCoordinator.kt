package com.ikuteam.notestn.ui.editor

import android.os.Handler
import android.os.Looper
import android.util.Log
import android.webkit.JavascriptInterface
import android.webkit.WebView
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Owns the WebView reference and bridges Kotlin <-> the shared ProseMirror JS bundle
 * (Mac/EditorBundle). Mirrors Mac/NotesTN/NotesTN/Views/EditorView.swift `EditorCoordinator`.
 */
class EditorCoordinator {
    var selectionState by mutableStateOf(EditorSelectionState())
        private set

    var isReady by mutableStateOf(false)
        private set

    // The last content this editor is known to hold — written by setContent (what we
    // pushed in) and by the contentChanged message (what the user typed). Lets
    // EditorScreen tell a sync-pulled external change (DB body differs from this →
    // refresh the editor) from the echo of its own saves (identical → ignore),
    // without reloading the WebView. Mirrors Mac's EditorCoordinator.
    var lastKnownTitle: String = ""
        private set
    var lastKnownBody: String = ""
        private set

    /** Called when the WebView is being recreated (e.g. after its render process
     * died — see EditorWebView's onRenderProcessGone) so content gets re-pushed
     * once the fresh page signals ready again. */
    fun notifyEditorReset() {
        isReady = false
    }

    // Set by EditorWebView's AndroidView factory, cleared on dispose.
    var webView: WebView? = null

    var onContentChanged: ((title: String, body: String) -> Unit)? = null
    var onImageRequested: ((dataUri: String) -> Unit)? = null
    var onOpenUrl: ((String) -> Unit)? = null
    // A detected address (see the data detectors in Mac/EditorBundle/src/index.ts) —
    // the screen shows a Google Maps / Waze chooser and opens the pick.
    var onOpenMaps: ((address: String) -> Unit)? = null
    // In-note find progress: (total matches, 1-based current index; 0 = none).
    var onFindResult: ((count: Int, index: Int) -> Unit)? = null
    // True while the ProseMirror editor's contentEditable region has keyboard
    // focus (vs. the note list) — drives the selected note row's Gray (editor
    // focused) vs. Dimmed yellow (list focused) background in the tablet
    // two-pane layout. See NotesViewModel.isEditorFocused.
    var onFocusChanged: ((Boolean) -> Unit)? = null

    private val jsonCoder = Json { ignoreUnknownKeys = true }

    // MARK: JS → Kotlin

    fun handleBridgeMessage(raw: String) {
        val message = runCatching {
            jsonCoder.decodeFromString(EditorBridgeMessage.serializer(), raw)
        }.getOrNull() ?: return

        when (message.type) {
            "ready" -> isReady = true
            "contentChanged" -> message.html?.let {
                lastKnownTitle = message.title ?: ""
                lastKnownBody = it
                onContentChanged?.invoke(message.title ?: "", it)
            }
            "selectionChanged" -> message.selectionState?.let { selectionState = it }
            "imageRequested" -> message.html?.let { onImageRequested?.invoke(it) }
            "openUrl" -> message.url?.let { onOpenUrl?.invoke(it) }
            "openMaps" -> message.url?.let { onOpenMaps?.invoke(it) }
            "findResult" -> onFindResult?.invoke(message.count ?: 0, message.index ?: 0)
            "focusChanged" -> message.focused?.let { onFocusChanged?.invoke(it) }
            "log" -> Log.d("EditorJS", message.message ?: "")
        }
    }

    // MARK: Commands → JS

    fun setContent(title: String, body: String) {
        val wv = webView ?: return
        lastKnownTitle = title
        lastKnownBody = body
        val encodedTitle = jsonCoder.encodeToString(title)
        val encodedBody = jsonCoder.encodeToString(body)
        wv.post { wv.evaluateJavascript("window.NativeEditor && window.NativeEditor.setContent($encodedTitle, $encodedBody)", null) }
    }

    fun execCommand(command: String, value: JsonObject? = null) {
        val wv = webView ?: return
        val js = if (value != null) {
            "window.NativeEditor && window.NativeEditor.execCommand('$command', $value)"
        } else {
            "window.NativeEditor && window.NativeEditor.execCommand('$command')"
        }
        wv.post {
            wv.requestFocus()
            wv.evaluateJavascript(js, null)
        }
    }

    // Collapses the selection to a caret before opening the Android-only "Text
    // Style" dropdown — see collapseSelection's doc comment in index.ts.
    fun collapseSelection() {
        val wv = webView ?: return
        wv.post { wv.evaluateJavascript("window.NativeEditor && window.NativeEditor.collapseSelection()", null) }
    }

    /** Toggles the editor between read mode (false) and edit mode (true) — see the
     * setEditable/`editable` handling in Mac/EditorBundle/src/index.ts. In read mode
     * the editor is contentEditable=false, so a tap interacts with content (link,
     * task checkbox, text selection) and never pops the keyboard. */
    fun setEditable(editable: Boolean) {
        val wv = webView ?: return
        wv.post { wv.evaluateJavascript("window.NativeEditor && window.NativeEditor.setEditable($editable)", null) }
    }

    fun focus() {
        val wv = webView ?: return
        wv.post {
            wv.requestFocus()
            wv.evaluateJavascript("window.NativeEditor && window.NativeEditor.focus()", null)
        }
    }

    /** Drops editor focus (dismisses the keyboard) — used when leaving edit mode. */
    fun blur() {
        val wv = webView ?: return
        wv.post { wv.evaluateJavascript("window.NativeEditor && window.NativeEditor.blur()", null) }
    }

    // ── In-note find ──
    /** [caseSensitive] is true once Replace is showing, so a replace only rewrites the
     * exact-case text that was highlighted (see the find plugin in EditorBundle). */
    fun find(query: String, caseSensitive: Boolean = false) {
        val wv = webView ?: return
        val encoded = jsonCoder.encodeToString(query)
        wv.post { wv.evaluateJavascript("window.NativeEditor && window.NativeEditor.find($encoded, $caseSensitive)", null) }
    }

    fun replaceCurrent(replacement: String) = evaluateReplace("replaceCurrent", replacement)

    fun replaceAll(replacement: String) = evaluateReplace("replaceAll", replacement)

    private fun evaluateReplace(method: String, replacement: String) {
        val wv = webView ?: return
        val encoded = jsonCoder.encodeToString(replacement)
        wv.post { wv.evaluateJavascript("window.NativeEditor && window.NativeEditor.$method($encoded)", null) }
    }

    fun findNext() {
        val wv = webView ?: return
        wv.post { wv.evaluateJavascript("window.NativeEditor && window.NativeEditor.findNext()", null) }
    }

    fun findPrevious() {
        val wv = webView ?: return
        wv.post { wv.evaluateJavascript("window.NativeEditor && window.NativeEditor.findPrevious()", null) }
    }

    fun endFind() {
        val wv = webView ?: return
        wv.post { wv.evaluateJavascript("window.NativeEditor && window.NativeEditor.endFind()", null) }
    }

    fun insertImage(src: String, alt: String? = null, resourceId: String? = null) {
        val value = buildJsonObject {
            put("src", src)
            alt?.let { put("alt", it) }
            resourceId?.let { put("resourceId", it) }
        }
        execCommand("image", value)
    }

    fun setLink(href: String) {
        execCommand("link", buildJsonObject { put("href", href) })
    }

    fun removeLink() {
        execCommand("link")
    }
}

/**
 * Bridges JS → Kotlin. Injected into the WebView as `window.AndroidBridge`, matching
 * the Android branch added to `postToNative()` in Mac/EditorBundle/src/index.ts.
 */
class EditorJsBridge(private val coordinator: EditorCoordinator) {
    private val mainHandler = Handler(Looper.getMainLooper())

    @JavascriptInterface
    fun postMessage(json: String) {
        // Called on the WebView's JS thread — hop to main before touching Compose state.
        mainHandler.post { coordinator.handleBridgeMessage(json) }
    }
}
