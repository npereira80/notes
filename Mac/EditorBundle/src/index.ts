/**
 * NotesTN Editor — ProseMirror entry point.
 *
 * Shared by the Mac (WKWebView) and Android (WebView) apps. Communicates with
 * native code via:
 *   JS → Swift:   window.webkit.messageHandlers.editorMessage.postMessage(msg)
 *   JS → Kotlin:  window.AndroidBridge.postMessage(JSON.stringify(msg))
 *   Native → JS:  window.NativeEditor.setContent(html) / execCommand(cmd, value) etc.
 */

import { EditorState, Plugin, Selection, Transaction } from 'prosemirror-state';
import { EditorView, DirectEditorProps, Decoration, DecorationSet } from 'prosemirror-view';
import { DOMParser as PMDOMParser, DOMSerializer, Fragment } from 'prosemirror-model';
import { history } from 'prosemirror-history';
import { keymap } from 'prosemirror-keymap';
import { baseKeymap, chainCommands, exitCode, newlineInCode } from 'prosemirror-commands';
import { splitListItem, liftListItem, sinkListItem } from 'prosemirror-schema-list';
import { dropCursor } from 'prosemirror-dropcursor';
import { gapCursor } from 'prosemirror-gapcursor';
import { tableEditing, columnResizing } from 'prosemirror-tables';
import { inputRules, wrappingInputRule, textblockTypeInputRule, smartQuotes, emDash, ellipsis, InputRule } from 'prosemirror-inputrules';

import schema from './schema';
import { commands, toggleCheckbox } from './commands';

// ── Types ─────────────────────────────────────────────────────────────────────

interface SelectionState {
  bold: boolean;
  italic: boolean;
  code: boolean;
  strikethrough: boolean;
  inCode: boolean;       // cursor is inside code_block
  inBlockquote: boolean;
  inBulletList: boolean;
  inOrderedList: boolean;
  inTaskList: boolean;
  inCheckedTask: boolean;
  headingLevel: number;  // 0 = not a heading
  hasLink: boolean;
  linkHref: string | null;
}

interface NativeMessage {
  type: 'contentChanged' | 'selectionChanged' | 'imageRequested' | 'ready' | 'log' | 'openUrl';
  title?: string;
  html?: string;
  selectionState?: SelectionState;
  message?: string;
  url?: string;
}

// ── Swift bridge ──────────────────────────────────────────────────────────────

function postToNative(msg: NativeMessage) {
  try {
    window.webkit?.messageHandlers?.['editorMessage']?.postMessage(msg);
  } catch (_) {
    // Not running in WKWebView — ignore
  }
  try {
    // Android's addJavascriptInterface only accepts primitive/String args, so
    // the message is JSON-encoded here and decoded on the Kotlin side.
    window.AndroidBridge?.postMessage(JSON.stringify(msg));
  } catch (_) {
    // Not running in Android WebView — ignore
  }
}

function log(message: string) {
  postToNative({ type: 'log', message });
}

// ── Input rules (Markdown shortcuts) ─────────────────────────────────────────

function buildInputRules() {
  const {
    paragraph, heading, code_block, blockquote,
    bullet_list, ordered_list, list_item, task_list, task_list_item,
  } = schema.nodes;

  return inputRules({
    rules: [
      // # → Heading
      textblockTypeInputRule(/^(#{1,6})\s$/, heading, match => ({
        level: match[1].length,
      })),
      // ``` → code block
      textblockTypeInputRule(/^```$/, code_block),
      // > → blockquote
      wrappingInputRule(/^\s*>\s$/, blockquote),
      // - or * → bullet list
      wrappingInputRule(/^\s*([-*])\s$/, bullet_list),
      // 1. → ordered list
      wrappingInputRule(/^(\d+)\.\s$/, ordered_list, match => ({
        order: +match[1],
      })),
      // - [ ] → task list
      new InputRule(/^\s*-\s\[\s?\]\s$/, (state, _match, start, end) => {
        const tr = state.tr.delete(start, end);
        const taskItem = task_list_item.create(
          { checked: false },
          schema.nodes.paragraph.create()
        );
        const taskListNode = task_list.create(null, taskItem);
        return tr.replaceSelectionWith(taskListNode);
      }),
      // Smart typography
      ...smartQuotes,
      ellipsis,
      emDash,
    ],
  });
}

// ── URL helpers ───────────────────────────────────────────────────────────────

function isUrl(text: string): boolean {
  try {
    const url = new URL(text);
    return url.protocol === 'http:' || url.protocol === 'https:';
  } catch {
    return false;
  }
}

// ── Build editor keymap ────────────────────────────────────────────────────────

// Enter inside the title moves the cursor into the body instead of splitting
// the title node (there's nowhere else for a "second title" to go).
const moveFromTitleToBody = (state: EditorState, dispatch?: (tr: Transaction) => void) => {
  const { $from } = state.selection;
  if ($from.parent.type !== schema.nodes.title) return false;
  if (dispatch) {
    const afterTitle = state.doc.firstChild!.nodeSize;
    const sel = Selection.near(state.doc.resolve(afterTitle), 1);
    dispatch(state.tr.setSelection(sel).scrollIntoView());
  }
  return true;
};

// Backspace at the very start of the first body block would otherwise try to
// join/lift into the title node above (different schema, no marks) — swallow
// it instead of letting that merge happen.
const guardBackspaceIntoTitle = (state: EditorState, dispatch?: (tr: Transaction) => void) => {
  const { $from, empty } = state.selection;
  if (!empty) return false;
  const afterTitle = state.doc.firstChild!.nodeSize;
  if ($from.pos === afterTitle + 1 && $from.parentOffset === 0) return true;
  return false;
};

function buildKeymap() {
  const { list_item, task_list_item } = schema.nodes;
  const listItemTypes = [list_item, task_list_item];

  return keymap({
    'Mod-b': (state, dispatch, view) => commands.bold(view!),
    'Mod-i': (state, dispatch, view) => commands.italic(view!),
    'Mod-`': (state, dispatch, view) => commands.code(view!),
    'Mod-z': (state, dispatch, view) => commands.undo(view!),
    'Mod-Shift-z': (state, dispatch, view) => commands.redo(view!),
    'Mod-a': (state, dispatch, view) => commands.selectAll(view!),

    // List indentation
    'Tab': (state, dispatch, view) => commands.indent(view!),
    'Shift-Tab': (state, dispatch, view) => commands.outdent(view!),

    // Enter in list items (title-to-body handoff checked first)
    'Enter': chainCommands(
      moveFromTitleToBody,
      splitListItem(task_list_item),
      splitListItem(list_item),
      newlineInCode,
      exitCode,
    ),

    // Lift out with Backspace — only when cursor is at the very start of an empty list item.
    // Without the parentOffset guard, liftListItem fires mid-word and removes list formatting.
    'Backspace': chainCommands(
      guardBackspaceIntoTitle,
      (state, dispatch) => {
        if (state.selection.$from.parentOffset > 0) return false;
        return liftListItem(task_list_item)(state, dispatch);
      },
      (state, dispatch) => {
        if (state.selection.$from.parentOffset > 0) return false;
        return liftListItem(list_item)(state, dispatch);
      },
    ),
  });
}

// ── Selection state ────────────────────────────────────────────────────────────

function getSelectionState(state: EditorState): SelectionState {
  const { $from, empty } = state.selection;

  const hasMark = (markType: any) => {
    if (empty) return !!markType.isInSet(state.storedMarks || $from.marks());
    return state.doc.rangeHasMark($from.pos, state.selection.to, markType);
  };

  let headingLevel = 0;
  let inCode = false;
  let inBlockquote = false;
  let inBulletList = false;
  let inOrderedList = false;
  let inTaskList = false;
  let inCheckedTask = false;
  let hasLink = false;
  let linkHref: string | null = null;

  const { nodes: n, marks: m } = schema;

  for (let d = $from.depth; d >= 0; d--) {
    const node = $from.node(d);
    switch (node.type) {
      case n.heading: headingLevel = node.attrs.level; break;
      case n.code_block: inCode = true; break;
      case n.blockquote: inBlockquote = true; break;
      case n.bullet_list: inBulletList = true; break;
      case n.ordered_list: inOrderedList = true; break;
      case n.task_list: inTaskList = true; break;
      case n.task_list_item:
        inTaskList = true;
        inCheckedTask = !!node.attrs.checked;
        break;
    }
  }

  const linkMark = m.link.isInSet(state.storedMarks || $from.marks());
  if (linkMark) {
    hasLink = true;
    linkHref = linkMark.attrs.href;
  }

  return {
    bold: hasMark(m.strong),
    italic: hasMark(m.em),
    code: hasMark(m.code),
    strikethrough: hasMark(m.strikethrough),
    inCode,
    inBlockquote,
    inBulletList,
    inOrderedList,
    inTaskList,
    inCheckedTask,
    headingLevel,
    hasLink,
    linkHref,
  };
}

// ── HTML serialization ────────────────────────────────────────────────────────

const serializer = DOMSerializer.fromSchema(schema);

/** Splits the doc's mandatory first (title) node from the rest (body) — the
 * doc-level HTML the native side ever needs to know about, in the shape it
 * already stores Note.title/Note.body separately. */
function stateToParts(state: EditorState): { title: string; body: string } {
  const titleNode = state.doc.firstChild!;
  const bodyFragment = state.doc.content.cut(titleNode.nodeSize);
  const div = document.createElement('div');
  div.appendChild(serializer.serializeFragment(bodyFragment));
  return { title: titleNode.textContent, body: div.innerHTML };
}

// ── Editor setup ──────────────────────────────────────────────────────────────

function createEditor(): EditorView {
  const domEl = document.getElementById('editor');
  if (!domEl) throw new Error('#editor element not found');

  // Set by native for a trashed note opened in Trash — matches the ?theme= query
  // param pattern below. Read once at load time; a trashed note is always reopened
  // as a fresh WebView load (never toggled live), so this doesn't need to be reactive.
  const isReadOnly = /[?&]readonly=1(&|$)/.test(location.search);

  // Android only — the on-screen keyboard's floating formatting toolbar sits
  // right above the keyboard, close enough to the last line that the text
  // selection handles are hard to grab. Extra bottom padding gives room to
  // scroll the last line clear of both. See EditorWebView.kt's ?platform=
  // query param and the body.pm-android rule in build.mjs.
  const isAndroid = /[?&]platform=android(&|$)/.test(location.search);
  if (isAndroid) document.body.classList.add('pm-android');

  let lastTitle = '';
  let lastHTML = '';
  let selectionDebounce: ReturnType<typeof setTimeout> | null = null;

  const notifyContent = (state: EditorState) => {
    const { title, body } = stateToParts(state);
    if (title !== lastTitle || body !== lastHTML) {
      lastTitle = title;
      lastHTML = body;
      postToNative({ type: 'contentChanged', title, html: body });
    }
  };

  const notifySelection = (state: EditorState) => {
    if (selectionDebounce) clearTimeout(selectionDebounce);
    selectionDebounce = setTimeout(() => {
      postToNative({ type: 'selectionChanged', selectionState: getSelectionState(state) });
    }, 30);
  };

  const dispatchWithNotify = (view: EditorView) => (tr: Transaction) => {
    view.updateState(view.state.apply(tr));
    if (tr.docChanged) notifyContent(view.state);
    notifySelection(view.state);
  };

  // Build initial empty state
  const state = EditorState.create({
    schema,
    plugins: [
      history(),
      buildKeymap(),
      keymap(baseKeymap),
      buildInputRules(),
      dropCursor(),
      gapCursor(),
      columnResizing(),
      tableEditing(),

      // Open links in default browser on click
      new Plugin({
        props: {
          handleDOMEvents: {
            click(_view, event) {
              const anchor = (event.target as HTMLElement).closest('a[href]') as HTMLAnchorElement | null;
              if (!anchor) return false;
              event.preventDefault();
              postToNative({ type: 'openUrl', url: anchor.href });
              return true;
            },
          },
        },
      }),

      // Auto-linkify pasted URLs
      new Plugin({
        props: {
          handlePaste(view, event) {
            const text = event.clipboardData?.getData('text/plain')?.trim() ?? '';
            if (!text || !isUrl(text)) return false;

            const { state, dispatch } = view;
            const { selection } = state;
            const linkMark = schema.marks.link.create({ href: text });

            if (!selection.empty) {
              // Paste URL as link mark over selected text
              if (dispatch) dispatch(state.tr.addMark(selection.from, selection.to, linkMark));
              return true;
            }

            // No selection: insert URL as linked text
            const textNode = schema.text(text, [linkMark]);
            if (dispatch) dispatch(state.tr.replaceSelectionWith(textNode, false).scrollIntoView());
            return true;
          },
        },
      }),

      // Placeholder text ("Title") shown when the title node is empty.
      new Plugin({
        props: {
          decorations(state) {
            const titleNode = state.doc.firstChild;
            if (titleNode && titleNode.type === schema.nodes.title && titleNode.content.size === 0) {
              return DecorationSet.create(state.doc, [
                Decoration.node(0, titleNode.nodeSize, { class: 'pm-title-empty' }),
              ]);
            }
            return DecorationSet.empty;
          },
        },
      }),

      // Collapse/expand sections under headings
      new Plugin({
        props: {
          // Hide all blocks that follow a collapsed heading until the next
          // heading of the same or higher level.
          decorations(state) {
            const topLevel: { node: any; offset: number }[] = [];
            state.doc.forEach((node, offset) => topLevel.push({ node, offset }));

            const decos: Decoration[] = [];
            for (let i = 0; i < topLevel.length; i++) {
              const { node, offset } = topLevel[i];
              // Level 1 ("Title") has no arrow/collapse UI — see schema.ts's heading
              // toDOM — so guard against stale collapsed=true data too (e.g. a
              // heading collapsed at level 3, then restyled to Title).
              if (node.type !== schema.nodes.heading || node.attrs.level === 1 || !node.attrs.collapsed) continue;
              const level = node.attrs.level as number;
              for (let j = i + 1; j < topLevel.length; j++) {
                const next = topLevel[j];
                if (next.node.type === schema.nodes.heading && next.node.attrs.level <= level) break;
                decos.push(Decoration.node(next.offset, next.offset + next.node.nodeSize, {
                  class: 'pm-heading-section-hidden',
                }));
              }
            }

            // The arrow is hidden by default (see build.mjs) and only shown on the
            // heading (level 3/4, not "Title") the cursor is currently in, collapsed
            // or not — this marks that heading with a class the CSS keys off.
            const { $from } = state.selection;
            for (let d = $from.depth; d >= 0; d--) {
              const node = $from.node(d);
              if (node.type === schema.nodes.heading && node.attrs.level !== 1) {
                const pos = $from.before(d);
                decos.push(Decoration.node(pos, pos + node.nodeSize, { class: 'pm-heading-focused' }));
                break;
              }
            }

            return DecorationSet.create(state.doc, decos);
          },

          // Toggle collapsed state when the arrow span is tapped/clicked.
          // pointerdown (not mousedown) — mousedown on a contenteditable="false"
          // island inside a contenteditable region relies on the browser
          // synthesizing a mouse event from a touch, which Chromium/Android
          // WebView doesn't always do reliably (unlike WebKit/Mac). pointerdown
          // is fired natively for both touch and mouse on both engines.
          handleDOMEvents: {
            pointerdown(view, event) {
              const target = event.target as HTMLElement;
              if (!target.classList.contains('pm-heading-arrow')) return false;

              event.preventDefault();
              event.stopPropagation();

              const headingEl = target.closest('h1,h2,h3,h4,h5,h6') as HTMLElement | null;
              if (!headingEl) return false;

              let found: { pos: number; node: any } | null = null;
              view.state.doc.forEach((node, offset) => {
                if (found) return;
                if (node.type === schema.nodes.heading && view.nodeDOM(offset) === headingEl) {
                  found = { pos: offset, node };
                }
              });

              if (found) {
                const { pos, node } = found as any;
                view.dispatch(view.state.tr.setNodeMarkup(pos, undefined, {
                  ...node.attrs,
                  collapsed: !node.attrs.collapsed,
                }));
                return true;
              }
              return false;
            },
          },
        },
      }),

      // Handle arrow clicks in toggle/details blocks
      new Plugin({
        props: {
          // pointerdown — see the heading-arrow handler above for why.
          handleDOMEvents: {
            pointerdown(view, event) {
              const target = event.target as HTMLElement;
              if (!target.classList.contains('pm-toggle-arrow')) return false;

              event.preventDefault();
              event.stopPropagation();

              // Find the details node whose DOM subtree contains this arrow
              let found: { pos: number; node: any } | null = null;
              view.state.doc.descendants((node, pos) => {
                if (found) return false;
                if (node.type === schema.nodes.details) {
                  const dom = view.nodeDOM(pos) as HTMLElement | null;
                  if (dom?.contains(target)) {
                    found = { pos, node };
                    return false;
                  }
                }
              });

              if (found) {
                const { pos, node } = found as any;
                view.dispatch(
                  view.state.tr.setNodeMarkup(pos, undefined, {
                    ...node.attrs,
                    open: !node.attrs.open,
                  })
                );
                return true;
              }
              return false;
            },
          },
        },
      }),

      // Handle checkbox clicks in task list items
      new Plugin({
        props: {
          // pointerdown — see the heading-arrow handler above for why.
          handleDOMEvents: {
            pointerdown(view, event) {
              const target = event.target as HTMLElement;
              if (target.tagName === 'INPUT' && target.getAttribute('type') === 'checkbox') {
                event.preventDefault();
                toggleCheckbox(view);
                return true;
              }
              return false;
            },
          },
        },
      }),

      // Paste images from clipboard
      new Plugin({
        props: {
          handlePaste(view, event) {
            const items = event.clipboardData?.items;
            if (!items) return false;
            for (const item of Array.from(items)) {
              if (item.type.startsWith('image/')) {
                event.preventDefault();
                const file = item.getAsFile();
                if (file) {
                  const reader = new FileReader();
                  reader.onload = (e) => {
                    const dataUri = e.target?.result as string;
                    // Hand the raw data URI to native code instead of inserting it
                    // inline — only native has filesystem access to save it as a real
                    // Resource (with an id, a local file, and a row in the resources
                    // table) the way the toolbar's image picker already does. Native
                    // calls back into insertImage() once that's done.
                    if (dataUri) postToNative({ type: 'imageRequested', html: dataUri });
                  };
                  reader.readAsDataURL(file);
                }
                return true;
              }
            }
            return false;
          },
        },
      }),
    ],
  });

  const view = new EditorView(domEl, {
    state,
    dispatchTransaction: (tr) => dispatchWithNotify(view)(tr),
    editable: () => !isReadOnly,
  });

  // Initial selection state
  notifySelection(view.state);

  return view;
}

// ── Native API (called from Swift via evaluateJavaScript) ─────────────────────

interface NativeEditorBridge {
  setContent: (title: string, body: string) => void;
  execCommand: (command: string, value?: any) => void;
  focus: () => void;
  blur: () => void;
  getHTML: () => string;
  collapseSelection: () => void;
}

declare global {
  interface Window {
    NativeEditor: NativeEditorBridge;
    webkit?: {
      messageHandlers?: {
        [key: string]: { postMessage: (msg: any) => void };
      };
    };
    // Injected by Android via WebView.addJavascriptInterface("AndroidBridge", ...)
    AndroidBridge?: { postMessage: (json: string) => void };
  }
}

// ── Bootstrap ─────────────────────────────────────────────────────────────────

document.addEventListener('DOMContentLoaded', () => {
  let view: EditorView;

  try {
    view = createEditor();
  } catch (err) {
    log(`Editor init error: ${err}`);
    return;
  }

  const bridge: NativeEditorBridge = {
    setContent(title: string, body: string) {
      // Build the title node directly from the raw string (a plain text node,
      // no HTML involved) rather than splicing it into an HTML string — sidesteps
      // any HTML-escaping concerns for title text like "&" or "<".
      const titleNode = schema.nodes.title.create(null, title ? schema.text(title) : undefined);

      // parseSlice (not parse) — it doesn't require its result to independently
      // satisfy doc's own content expression, so the body's blocks can be
      // extracted as a plain Fragment and combined with titleNode below.
      const parser = PMDOMParser.fromSchema(schema);
      const domParser = new DOMParser();
      const dom = domParser.parseFromString(body || '<p></p>', 'text/html');
      const bodySlice = parser.parseSlice(dom.body, { preserveWhitespace: true });

      const content = bodySlice.content.addToStart(titleNode);
      const newState = EditorState.create({
        doc: schema.nodes.doc.create(null, content),
        plugins: view.state.plugins,
      });
      view.updateState(newState);
    },

    execCommand(command: string, value?: any) {
      const cmd = commands[command];
      if (!cmd) {
        log(`Unknown command: ${command}`);
        return;
      }
      // Run the command first — ProseMirror dispatch works without DOM focus.
      // Do NOT call view.focus() before the command: on macOS, programmatic
      // focus() from evaluateJavaScript is not a user gesture and can silently
      // fail or trigger async browser focus-handling that races the dispatch.
      cmd(view, value);
      // After the command's DOM updates are committed, restore editor focus
      // so the cursor is visible and the user can keep typing.
      requestAnimationFrame(() => {
        (view.dom as HTMLElement).focus({ preventScroll: true });
      });
    },

    focus() {
      view.focus();
    },

    blur() {
      (view.dom as HTMLElement).blur();
    },

    getHTML() {
      // Body only — matches what native code actually treats as Note.body;
      // the title lives in Note.title, not in this string.
      return stateToParts(view.state).body;
    },

    // Collapses the current selection to a caret at its head, staying in the
    // same block. Used by Android before opening the "Text Style" dropdown:
    // a real range selection triggers Android's native floating Cut/Copy/Paste
    // toolbar, which renders on top of that dropdown. The block-level commands
    // offered there (heading/paragraph/list/etc.) only need the caret inside
    // the target block, not a preserved range, so collapsing first is safe and
    // makes Android dismiss its native toolbar on its own.
    collapseSelection() {
      const { state, dispatch } = view;
      dispatch(state.tr.setSelection(Selection.near(state.doc.resolve(state.selection.head))));
    },
  };

  window.NativeEditor = bridge;

  postToNative({ type: 'ready' });
});
