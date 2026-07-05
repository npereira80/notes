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

    // Set by EditorWebView's AndroidView factory, cleared on dispose.
    var webView: WebView? = null

    var onContentChanged: ((String) -> Unit)? = null
    var onImageRequested: (() -> Unit)? = null
    var onOpenUrl: ((String) -> Unit)? = null

    private val jsonCoder = Json { ignoreUnknownKeys = true }

    // MARK: JS → Kotlin

    fun handleBridgeMessage(raw: String) {
        val message = runCatching {
            jsonCoder.decodeFromString(EditorBridgeMessage.serializer(), raw)
        }.getOrNull() ?: return

        when (message.type) {
            "ready" -> isReady = true
            "contentChanged" -> message.html?.let { onContentChanged?.invoke(it) }
            "selectionChanged" -> message.selectionState?.let { selectionState = it }
            "imageRequested" -> onImageRequested?.invoke()
            "openUrl" -> message.url?.let { onOpenUrl?.invoke(it) }
            "log" -> Log.d("EditorJS", message.message ?: "")
        }
    }

    // MARK: Commands → JS

    fun setContent(html: String) {
        val wv = webView ?: return
        val encoded = jsonCoder.encodeToString(html)
        wv.post { wv.evaluateJavascript("window.NativeEditor && window.NativeEditor.setContent($encoded)", null) }
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

    fun focus() {
        val wv = webView ?: return
        wv.post {
            wv.requestFocus()
            wv.evaluateJavascript("window.NativeEditor && window.NativeEditor.focus()", null)
        }
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
