package com.ikuteam.notestn.ui.editor

import android.annotation.SuppressLint
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.view.ViewGroup
import android.util.Log
import android.webkit.ConsoleMessage
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import com.ikuteam.notestn.BuildConfig
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewAssetLoader
import androidx.webkit.WebViewFeature
import com.ikuteam.notestn.data.DatabaseManager

/**
 * Hosts the shared ProseMirror editor bundle (Mac/EditorBundle, built into
 * app/src/main/assets/editor.html + editor.bundle.js) inside an Android WebView.
 * Mirrors Mac/NotesTN/NotesTN/Views/EditorView.swift `RichTextEditorView`.
 *
 * Local files (the editor bundle and image resources) are served through
 * https://appassets.androidplatform.net/ via WebViewAssetLoader — the modern
 * replacement for file:// access, which WebView restricts on API 30+.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun EditorWebView(
    coordinator: EditorCoordinator,
    darkTheme: Boolean,
    readOnly: Boolean = false,
    modifier: Modifier = Modifier,
) {
    AndroidView(
        modifier = modifier,
        factory = { ctx ->
            val assetLoader = WebViewAssetLoader.Builder()
                .setDomain("appassets.androidplatform.net")
                .addPathHandler("/assets/", WebViewAssetLoader.AssetsPathHandler(ctx))
                .addPathHandler(
                    "/resources/",
                    WebViewAssetLoader.InternalStoragePathHandler(ctx, DatabaseManager.shared.resourcesDirectory),
                )
                .build()

            // Debug builds only: lets chrome://inspect attach, and forwards JS console
            // errors (e.g. an uncaught exception in the Enter/paragraph-split keymap)
            // to Logcat instead of them vanishing silently inside the WebView.
            if (BuildConfig.DEBUG) WebView.setWebContentsDebuggingEnabled(true)

            WebView(ctx).apply {
                layoutParams = ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT,
                )
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                setBackgroundColor(Color.TRANSPARENT)
                if (BuildConfig.DEBUG) {
                    webChromeClient = object : WebChromeClient() {
                        override fun onConsoleMessage(message: ConsoleMessage): Boolean {
                            Log.d("EditorJS", "${message.message()} (${message.sourceId()}:${message.lineNumber()})")
                            return true
                        }
                    }
                }

                // Belt-and-suspenders for any native WebView chrome (e.g. scrollbars);
                // the actual page theming below no longer depends on this.
                if (WebViewFeature.isFeatureSupported(WebViewFeature.ALGORITHMIC_DARKENING)) {
                    WebSettingsCompat.setAlgorithmicDarkeningAllowed(settings, true)
                }

                addJavascriptInterface(EditorJsBridge(coordinator), "AndroidBridge")

                webViewClient = object : WebViewClient() {
                    override fun shouldInterceptRequest(
                        view: WebView,
                        request: WebResourceRequest,
                    ): WebResourceResponse? = assetLoader.shouldInterceptRequest(request.url)

                    override fun shouldOverrideUrlLoading(
                        view: WebView,
                        request: WebResourceRequest,
                    ): Boolean {
                        val url = request.url
                        // The editor page itself and its resources live on this virtual domain —
                        // only intercept genuine outbound navigation (defensive fallback; normal
                        // link clicks are handled by the ProseMirror "openUrl" bridge message).
                        if (url.host == "appassets.androidplatform.net") return false
                        openInBrowser(view.context, url)
                        return true
                    }

                    override fun onPageFinished(view: WebView, url: String) {
                        // Belt-and-suspenders: the ?theme= param (below) already sets this
                        // before first paint, but re-apply in case the page reloads.
                        applyDarkMode(view, darkTheme)
                    }
                }

                coordinator.webView = this
                // ?theme= is read by a synchronous bootstrap script in editor.html's
                // <head>, before first paint — avoids a flash of the wrong theme.
                // ?readonly=1 disables ProseMirror's contentEditable entirely for a
                // trashed note opened from Trash — see EditorBundle/src/index.ts.
                // ?platform=android adds extra bottom padding (body.pm-android in
                // build.mjs) so the last line of a long note can scroll clear of the
                // floating formatting toolbar/keyboard.
                // See Mac/EditorBundle/build.mjs.
                val themeParam = if (darkTheme) "dark" else "light"
                val readOnlyParam = if (readOnly) "&readonly=1" else ""
                loadUrl("https://appassets.androidplatform.net/assets/editor.html?theme=$themeParam$readOnlyParam&platform=android")
            }
        },
        update = { webView -> applyDarkMode(webView, darkTheme) },
    )

    DisposableEffect(Unit) {
        onDispose { coordinator.webView = null }
    }
}

private fun applyDarkMode(webView: WebView, dark: Boolean) {
    val theme = if (dark) "dark" else "light"
    webView.evaluateJavascript(
        "document.documentElement.setAttribute('data-theme', '$theme')",
        null,
    )
}

private fun openInBrowser(context: android.content.Context, url: Uri) {
    runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, url)) }
}
