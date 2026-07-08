import * as esbuild from 'esbuild';
import { readFileSync, writeFileSync, mkdirSync, copyFileSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const isWatch = process.argv.includes('--watch');

// Shared by both native clients: Mac (WKWebView) reads it from the app bundle,
// Android (WebView) reads it from assets/ via WebViewAssetLoader.
const outDirs = [
  resolve(__dirname, '../NotesTN/NotesTN/Editor'),
  resolve(__dirname, '../../Android App/app/src/main/assets'),
];
for (const dir of outDirs) mkdirSync(dir, { recursive: true });

const bundlePath = resolve(outDirs[0], 'editor.bundle.js');

const buildOptions = {
  entryPoints: [resolve(__dirname, 'src/index.ts')],
  bundle: true,
  format: 'iife',
  target: ['safari14', 'chrome90'],
  platform: 'browser',
  outfile: bundlePath,
  minify: false, // Keep readable for debugging; set true for release
  sourcemap: false,
  logLevel: 'info',
};

if (isWatch) {
  const ctx = await esbuild.context(buildOptions);
  await ctx.watch();
  console.log('Watching for changes...');
} else {
  const result = await esbuild.build(buildOptions);
  if (result.errors.length === 0) {
    console.log(`Built editor.bundle.js → ${bundlePath}`);
    writeEditorHtml(outDirs[0]);
    for (const dir of outDirs.slice(1)) {
      copyFileSync(bundlePath, resolve(dir, 'editor.bundle.js'));
      writeEditorHtml(dir);
      console.log(`Copied editor.bundle.js + editor.html → ${dir}`);
    }
  }
}

function writeEditorHtml(outDir) {
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta http-equiv="Content-Security-Policy" content="default-src 'self' 'unsafe-inline'; img-src 'self' data: file: blob:;">
<script>
  // Runs synchronously during <head> parsing, before first paint, so there's
  // no flash of the wrong theme. Android passes ?theme=dark|light on the
  // loadUrl() call (see EditorWebView.kt); Mac never sets it and relies on
  // the prefers-color-scheme media query instead.
  (function () {
    var m = /[?&]theme=(dark|light)/.exec(location.search);
    if (m) document.documentElement.setAttribute('data-theme', m[1]);
  })();
</script>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }

  :root {
    --font-body: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
    --font-mono: 'SF Mono', Menlo, Monaco, 'Courier New', monospace;
    --color-text: #000;
    --color-bg: #fff;
    --color-secondary: #666;
    --color-selection: #faebc3;
    --color-code-bg: rgba(0, 0, 0, 0.06);
    --color-blockquote: #999;
    /* Joplin-style text highlight mark (<mark>) — matches Joplin's own light
       purple highlight color, same value in light/dark. */
    --color-highlight-bg: #f1e0f3;
    --color-highlight-text: #b04ac5;
    --color-link: #deaa33;
    --color-hr: rgba(0, 0, 0, 0.2);
  }

  @media (prefers-color-scheme: dark) {
    :root {
      --color-text: #f0f0f0;
      --color-bg: #1e1e1e;
      --color-secondary: #aaa;
      --color-selection: #faebc3;
      --color-code-bg: rgba(255, 255, 255, 0.08);
      --color-blockquote: #777;
      --color-link: #deaa33;
      --color-hr: rgba(255, 255, 255, 0.3);
    }
  }

  /* Explicit override, set imperatively by the Android host (see the bootstrap
     script below + EditorWebView.kt). Android WebView's support for reporting
     prefers-color-scheme to the page is unreliable across OEM/WebView versions,
     so Android doesn't rely on the media query above — it sets this attribute
     directly instead. Higher specificity than :root wins over the media query
     regardless of what WebView reports. No-op on Mac (WKWebView never sets it,
     and correctly honors prefers-color-scheme on its own). */
  :root[data-theme="dark"] {
    --color-text: #f0f0f0;
    --color-bg: #1e1e1e;
    --color-secondary: #aaa;
    --color-selection: #faebc3;
    --color-code-bg: rgba(255, 255, 255, 0.08);
    --color-blockquote: #777;
    --color-link: #deaa33;
    --color-hr: rgba(255, 255, 255, 0.3);
  }
  :root[data-theme="light"] {
    --color-text: #000;
    --color-bg: #fff;
    --color-secondary: #666;
    --color-selection: #faebc3;
    --color-code-bg: rgba(0, 0, 0, 0.06);
    --color-blockquote: #999;
    --color-link: #deaa33;
    --color-hr: rgba(0, 0, 0, 0.2);
  }

  html {
    height: 100%;
  }

  body {
    /* min-height (not height) — height:100% pins the box's own bottom edge
       (and thus its bottom padding) at the viewport boundary, so on a long
       note whose content overflows that boundary, the padding-bottom below
       renders invisibly underneath the overflowing text instead of after it.
       min-height still fills the background for short notes but lets the
       box grow with content for long ones, so the padding actually lands
       after the real last line. */
    min-height: 100%;
    background: var(--color-bg);
    color: var(--color-text);
    padding: 0 24px 48px 24px;
    font-family: var(--font-body);
    font-size: 16px;
    line-height: 1.7;
    -webkit-font-smoothing: antialiased;
  }

  /* Android only (see index.ts's ?platform=android detection) — 64px more than
     the default 48px, so the last line of a long note can scroll clear of the
     floating formatting toolbar/keyboard, making its selection handles easier
     to grab. */
  body.pm-android {
    padding-bottom: 112px;
    /* Android's TopAppBar sits directly above the WebView with no gap of its
       own, leaving the title right up against it — 10px (~10dp, this WebView
       uses width=device-width so CSS px map 1:1 to dp) of breathing room. */
    padding-top: 10px;
  }

  /* iPhone only (see index.ts's ?platform=ios-phone detection) — the default
     0 24px 48px 30px is sized for Mac's much wider window; on iPhone's narrow
     screen it left too large a gap from the edge. iPad keeps the default. */
  body.pm-ios-phone {
    padding: 0 12px 48px 24px;
  }

  /* ProseMirror container */
  #editor {
    outline: none;
    min-height: calc(100vh - 48px);
  }

  .ProseMirror {
    outline: none;
    min-height: inherit;
    /* Matches the native title field's cursor (MaterialTheme primary / NotesYellowDark
       on Android, AccentColor on Mac) instead of the browser-engine default black. */
    caret-color: #deaa33;
  }

  .ProseMirror > * + * { margin-top: 0.75em; }

  /* Title — the doc's mandatory first node, scrolls with the body since it's
     part of the same ProseMirror document instead of a separate native field. */
  .ProseMirror .pm-title {
    font-size: 24px;
    font-weight: 700;
    line-height: 1.25;
    /* .pm-title is the doc's mandatory first node, so .ProseMirror > * + * (above)
       never applies to it — margin-top has to be set here explicitly to get any
       space above it at all. */
    margin-top: 0.75em;
    /* Same rhythm as the space between any two paragraphs (.ProseMirror > * + *
       above) — explicit here (rather than relying only on the next node's
       margin-top) so the gap after the title is guaranteed regardless of what
       kind of node follows it. */
    margin-bottom: 0.75em;
  }
  .ProseMirror .pm-title.pm-title-empty::before {
    content: 'Title';
    color: var(--color-secondary);
    pointer-events: none;
  }

  /* Headings — h1 doubles as the "Title" style choice in the toolbar menu, so it
     matches .pm-title's look exactly (24px/700) instead of its old 1.8em size. */
  .ProseMirror h1 { font-size: 24px; font-weight: 700; line-height: 1.25; }
  .ProseMirror h2 { font-size: 1.5em; font-weight: 600; line-height: 1.25; }
  .ProseMirror h3 { font-size: 1.25em; font-weight: 700; }
  .ProseMirror h4 { font-size: 1.1em; font-weight: 700; }
  .ProseMirror h5 { font-size: 1em; font-weight: 600; }
  .ProseMirror h6 { font-size: 0.9em; font-weight: 600; color: var(--color-secondary); }

  /* Paragraph */
  .ProseMirror p { margin: 0; }
  .ProseMirror p + p { margin-top: 0.5em; }

  /* Inline code */
  .ProseMirror code {
    font-family: var(--font-mono);
    font-size: 0.88em;
    background: var(--color-code-bg);
    border-radius: 3px;
    padding: 1px 4px;
  }

  /* Code block */
  .ProseMirror pre {
    background: var(--color-code-bg);
    border-radius: 6px;
    padding: 12px 16px;
    overflow-x: auto;
  }
  .ProseMirror pre code {
    background: none;
    padding: 0;
    font-size: 0.875em;
  }

  /* Blockquote */
  .ProseMirror blockquote {
    border-left: 3px solid var(--color-blockquote);
    margin: 0;
    padding-left: 16px;
    color: var(--color-secondary);
  }

  /* Lists */
  .ProseMirror ul,
  .ProseMirror ol {
    padding-left: 1.5em;
  }
  .ProseMirror li { margin: 0.1em 0; }
  .ProseMirror li > p { margin: 0; }

  /* Task list */
  .ProseMirror ul[data-is-checklist] {
    list-style: none;
    padding-left: 0.25em;
  }
  .ProseMirror ul[data-is-checklist] li {
    display: flex;
    align-items: flex-start;
    gap: 6px;
  }
  .ProseMirror ul[data-is-checklist] li input[type="checkbox"] {
    margin-top: 3px;
    flex-shrink: 0;
    cursor: pointer;
    width: 15px;
    height: 15px;
  }
  .ProseMirror ul[data-is-checklist] li.checked > div {
    text-decoration: line-through;
    opacity: 0.55;
  }

  /* Images */
  .ProseMirror img {
    max-width: 100%;
    border-radius: 8px;
    display: block;
  }
  .ProseMirror img.ProseMirror-selectednode {
    outline: 2px solid #0078ff;
  }

  /* Horizontal rule */
  .ProseMirror hr {
    border: none;
    border-top: 1px solid var(--color-hr);
    margin: 1.5em 0;
  }

  /* Links */
  .ProseMirror a {
    color: var(--color-link);
    text-decoration: underline;
    text-underline-offset: 2px;
  }

  /* Highlight */
  .ProseMirror mark {
    background: var(--color-highlight-bg);
    color: var(--color-highlight-text);
    border-radius: 2px;
    padding: 0 2px;
  }

  /* Heading collapse arrows */
  .ProseMirror h1, .ProseMirror h2, .ProseMirror h3,
  .ProseMirror h4, .ProseMirror h5, .ProseMirror h6 {
    position: relative;
    /* Use rem (fixed to the base 16px) instead of the generic 0.75em rule below,
       which is relative to each heading's own (larger) font-size and so gave
       bigger headings disproportionately more space before them. This matches
       the 0.5em/8px gap paragraphs already use between each other. */
    margin-top: 0.5rem;
  }
  /* Space after a heading, before whatever follows it — same 8px gap as above,
     so a heading's trailing space matches a paragraph's trailing space instead
     of falling back to the generic 0.75em rule (which, computed off a plain
     paragraph's own font-size, worked out larger and felt inconsistent). */
  .ProseMirror h1 + *, .ProseMirror h2 + *, .ProseMirror h3 + *,
  .ProseMirror h4 + *, .ProseMirror h5 + *, .ProseMirror h6 + * {
    margin-top: 0.5rem;
  }
  /* The arrow is pulled out of flow into the body's left padding (see the
     body rule's "padding: 0 24px 48px") so the heading text lines up with
     paragraph text instead of being pushed right by an inline arrow. */
  .ProseMirror .pm-heading-arrow {
    position: absolute;
    left: -22px;
    top: 50%;
    /* Widened from 18px so the arrow's right edge reaches the heading/body
       text's left edge (0), closing the 4px gap that used to sit between them —
       left stays at -22px (chevron position unchanged) and the text's own
       position is untouched. */
    width: 22px;
    height: 18px;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    border-radius: 3px;
    color: var(--color-secondary);
    font-size: 1em;
    font-weight: normal;
    /* Hidden unless the cursor is in this heading (see the pm-heading-focused
       decoration in index.ts) — collapsed or not. */
    opacity: 0;
    transform: translateY(-50%) rotate(90deg); /* expanded: chevron points down */
    transition: transform 0.15s ease;
    user-select: none;
  }
  .ProseMirror .pm-heading-focused .pm-heading-arrow {
    opacity: 1;
  }
  .ProseMirror .pm-heading-arrow::after { content: '›'; }
  .ProseMirror .pm-heading-arrow:hover { background: var(--color-code-bg); }
  /* Collapsed: chevron points right (h1/"Title" has no arrow at all — see
     schema.ts's heading toDOM) */
  .ProseMirror h2[data-collapsed] .pm-heading-arrow,
  .ProseMirror h3[data-collapsed] .pm-heading-arrow,
  .ProseMirror h4[data-collapsed] .pm-heading-arrow,
  .ProseMirror h5[data-collapsed] .pm-heading-arrow,
  .ProseMirror h6[data-collapsed] .pm-heading-arrow { transform: translateY(-50%) rotate(0deg); }
  /* Blocks hidden by a collapsed heading */
  .pm-heading-section-hidden { display: none; }

  /* Toggle / collapsible sections */
  .ProseMirror details {
    border: 1px solid var(--color-code-bg);
    border-radius: 6px;
    overflow: hidden;
  }
  .ProseMirror summary {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 7px 12px;
    font-weight: 600;
    list-style: none;
    cursor: default;
  }
  .ProseMirror summary::-webkit-details-marker { display: none; }
  .ProseMirror .pm-toggle-arrow {
    flex-shrink: 0;
    width: 16px;
    height: 16px;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    border-radius: 3px;
    color: var(--color-secondary);
    font-size: 0.6em;
    transition: transform 0.15s ease;
    user-select: none;
  }
  .ProseMirror .pm-toggle-arrow::after { content: '▶'; }
  .ProseMirror .pm-toggle-arrow:hover { background: var(--color-code-bg); }
  .ProseMirror details[open] > summary .pm-toggle-arrow { transform: rotate(90deg); }
  .ProseMirror .pm-toggle-content { flex: 1; outline: none; }
  .ProseMirror details > *:not(summary) {
    padding: 6px 12px 10px;
    border-top: 1px solid var(--color-code-bg);
  }

  /* Gap cursor */
  .ProseMirror-gapcursor {
    display: none;
    pointer-events: none;
    position: absolute;
  }
  .ProseMirror-gapcursor::after {
    content: "";
    display: block;
    position: absolute;
    top: -2px;
    width: 20px;
    border-top: 1px solid black;
    animation: ProseMirror-cursor-blink 1.1s steps(2, start) infinite;
  }
  .ProseMirror-focused .ProseMirror-gapcursor { display: block; }

  /* Tables */
  .ProseMirror table {
    border-collapse: collapse;
    width: 100%;
    font-size: 0.9em;
  }
  .ProseMirror th, .ProseMirror td {
    border: 1px solid var(--color-blockquote);
    padding: 6px 10px;
    text-align: left;
  }
  .ProseMirror th { background: var(--color-code-bg); font-weight: 600; }
  .selectedCell::after {
    z-index: 2;
    position: absolute;
    content: "";
    left: 0; right: 0; top: 0; bottom: 0;
    background: var(--color-selection);
    pointer-events: none;
  }
</style>
</head>
<body>
<div id="editor"></div>
<script src="editor.bundle.js"></script>
</body>
</html>`;

  writeFileSync(resolve(outDir, 'editor.html'), html);
  console.log(`Wrote editor.html → ${outDir}`);
}
