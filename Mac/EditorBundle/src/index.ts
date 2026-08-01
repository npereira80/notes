/**
 * NotesTN Editor — ProseMirror entry point.
 *
 * Shared by the Mac (WKWebView) and Android (WebView) apps. Communicates with
 * native code via:
 *   JS → Swift:   window.webkit.messageHandlers.editorMessage.postMessage(msg)
 *   JS → Kotlin:  window.AndroidBridge.postMessage(JSON.stringify(msg))
 *   Native → JS:  window.NativeEditor.setContent(html) / execCommand(cmd, value) etc.
 */

import { EditorState, Plugin, PluginKey, Selection, Transaction } from 'prosemirror-state';
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
import { commands, toggleCheckboxAtPos } from './commands';

// ── Types ─────────────────────────────────────────────────────────────────────

interface SelectionState {
  bold: boolean;
  italic: boolean;
  code: boolean;
  strikethrough: boolean;
  highlight: boolean;
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
  // openMaps carries a plain address string in `url`; native shows a Google Maps /
  // Waze chooser and opens the chosen app. Everything else routes through openUrl
  // with a fully-formed scheme URL (https:, mailto:, tel:).
  // findResult reports in-note find progress to the native find bar: `count` total
  // matches and `index` the 1-based current match (0 when there are none).
  type: 'contentChanged' | 'selectionChanged' | 'imageRequested' | 'ready' | 'log' | 'openUrl' | 'openMaps' | 'focusChanged' | 'findResult';
  title?: string;
  html?: string;
  selectionState?: SelectionState;
  message?: string;
  url?: string;
  focused?: boolean;
  count?: number;
  index?: number;
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

// ── Data detectors (auto-link URLs / emails / phones / addresses) ──────────────
//
// Detects link-like spans in plain text and renders them as yellow-underlined
// "active links" via ProseMirror decorations (see the auto-link plugin in
// createEditor). Detection is presentational only — it never alters the stored
// document/Markdown. On tap, native opens the right app (browser / mail / phone /
// maps). Kept intentionally simple; phone and address detection are best-effort
// heuristics (bare 9-digit local numbers are matched per product decision, and
// addresses key off street-type keywords near a number).

type DetectedLinkType = 'url' | 'email' | 'phone' | 'address';
interface DetectedLink {
  start: number;   // offset within the text
  end: number;
  type: DetectedLinkType;
  href: string;    // scheme URL for url/email/phone; raw address string for address
}

const EMAIL_RE = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g;
const URL_RE = /\b(?:https?:\/\/|www\.)[^\s<>()]+/gi;
// Candidate phone runs; digit count is validated in detectLinks (9–15) so bare
// 9-digit local numbers match while short numeric tokens (years, postal codes,
// quantities) don't.
const PHONE_RE = /(?:\+|00)?\d[\d\s().-]{5,}\d/g;
// Street-type keywords (Portuguese + English), used by the address heuristic.
const STREET = "(?:Rua|R\\.|Avenida|Av\\.?|Travessa|Tv\\.?|Largo|Pra[çc]a|Estrada|Alameda|Beco|Street|St\\.?|Avenue|Ave\\.?|Road|Rd\\.?|Boulevard|Blvd\\.?|Lane|Ln\\.?|Drive|Dr\\.?|Way|Court|Ct\\.?|Place|Pl\\.?)";
const ADDRESS_RE = new RegExp(
  // "123 Some Name Street" (number, up to 4 words, then a street type) ...
  `(?:\\b\\d{1,5}\\s+(?:[A-Za-zÀ-ÿ.'ºª]+\\s+){0,4}${STREET}\\b)` +
  // ... or "Rua da Prata 12" (street type, words, then a number)
  `|(?:\\b${STREET}\\s+[A-Za-zÀ-ÿ0-9.'ºª ]*?\\d{1,5}(?:\\s*[-–]\\s*\\d{1,4})?)`,
  'gi'
);

function countDigits(s: string): number {
  return (s.match(/\d/g) || []).length;
}

function trimTrailingPunct(s: string): string {
  return s.replace(/[.,;:!?)\]}'"]+$/, '');
}

/** Non-overlapping detected links in [text], resolved by priority
 * (email > url > phone > address) then by earliest start / longest match. */
function detectLinks(text: string): DetectedLink[] {
  const all: DetectedLink[] = [];

  const scan = (
    re: RegExp,
    build: (raw: string) => { value: string; href: string } | null,
  ) => {
    re.lastIndex = 0;
    let m: RegExpExecArray | null;
    while ((m = re.exec(text))) {
      const built = build(m[0]);
      if (!built) continue;
      const start = m.index;
      all.push({ start, end: start + built.value.length, type: typeForRe(re), href: built.href });
    }
  };
  const typeForRe = (re: RegExp): DetectedLinkType =>
    re === EMAIL_RE ? 'email' : re === URL_RE ? 'url' : re === PHONE_RE ? 'phone' : 'address';

  scan(EMAIL_RE, (raw) => ({ value: raw, href: `mailto:${raw}` }));
  scan(URL_RE, (raw) => {
    const value = trimTrailingPunct(raw);
    const href = /^www\./i.test(value) ? `https://${value}` : value;
    return { value, href };
  });
  scan(PHONE_RE, (raw) => {
    const digits = countDigits(raw);
    if (digits < 9 || digits > 15) return null;
    // Keep a leading + if present; strip spaces/formatting for the tel: URL.
    const plus = raw.trimStart().startsWith('+') ? '+' : '';
    const tel = plus + (raw.match(/\d/g) || []).join('');
    return { value: raw, href: `tel:${tel}` };
  });
  scan(ADDRESS_RE, (raw) => {
    const value = raw.trim();
    if (value.length < 6) return null;
    return { value, href: value }; // raw address; native builds the maps URL
  });

  const priority: Record<DetectedLinkType, number> = { email: 0, url: 1, phone: 2, address: 3 };
  all.sort(
    (a, b) => a.start - b.start || priority[a.type] - priority[b.type] || (b.end - b.start) - (a.end - a.start),
  );
  const result: DetectedLink[] = [];
  let lastEnd = -1;
  for (const link of all) {
    if (link.start >= lastEnd) {
      result.push(link);
      lastEnd = link.end;
    }
  }
  return result;
}

// Plugin state holds the current auto-link DecorationSet; recomputed only when the
// document changes (not on every selection move).
const autoLinkKey = new PluginKey<DecorationSet>('autoLink');

function buildAutoLinkDecos(doc: any): DecorationSet {
  const decos: Decoration[] = [];
  doc.descendants((node: any, pos: number) => {
    if (!node.isText || !node.text) return;
    // Skip text that's already an explicit link (<a> via the link mark) — those are
    // handled by the existing link click handler and shouldn't be double-detected.
    if (node.marks.some((m: any) => m.type === schema.marks.link)) return;
    for (const link of detectLinks(node.text)) {
      decos.push(
        Decoration.inline(pos + link.start, pos + link.end, {
          class: `pm-autolink pm-autolink-${link.type}`,
          'data-al-type': link.type,
          'data-al-href': link.href,
        }),
      );
    }
  });
  return DecorationSet.create(doc, decos);
}

// ── Find in note (in-editor search + highlight) ────────────────────────────────
//
// A find plugin holds the current query, the matched ranges, and the "current"
// match index, and renders them as decorations (light-yellow for all matches, a
// stronger yellow for the current one). Driven imperatively by the native find bar
// through the setContent-style bridge methods (find / findNext / findPrevious /
// endFind); it never mutates the document.

const findKey = new PluginKey<FindState>('find');

interface FindMatch { from: number; to: number; }
interface FindState { query: string; matches: FindMatch[]; current: number; }

/** Flattens the doc into a single lowercased string plus a per-character map back to
 * document positions, inserting a newline (mapped to the block boundary) between
 * blocks so a match can't span across block nodes. */
function collectDocText(doc: any): { text: string; map: number[] } {
  let text = '';
  const map: number[] = [];
  doc.descendants((node: any, pos: number) => {
    if (node.isText && node.text) {
      for (let i = 0; i < node.text.length; i++) {
        text += node.text[i];
        map.push(pos + i);
      }
    } else if (node.isBlock) {
      if (text.length && text[text.length - 1] !== '\n') {
        text += '\n';
        map.push(pos);
      }
    }
    return true;
  });
  return { text, map };
}

function computeFindMatches(doc: any, query: string): FindMatch[] {
  if (!query) return [];
  const { text, map } = collectDocText(doc);
  const haystack = text.toLowerCase();
  const needle = query.toLowerCase();
  const matches: FindMatch[] = [];
  let from = 0;
  while (from <= haystack.length) {
    const idx = haystack.indexOf(needle, from);
    if (idx < 0) break;
    const startPos = map[idx];
    const endPos = map[idx + needle.length - 1] + 1;
    if (startPos !== undefined && endPos !== undefined) {
      matches.push({ from: startPos, to: endPos });
    }
    from = idx + needle.length;
  }
  return matches;
}

/** Decorations for the current find state: every match gets pm-find-match, the
 * current one additionally gets pm-find-current. */
function findDecorations(doc: any, state: FindState): DecorationSet {
  if (!state.matches.length) return DecorationSet.empty;
  const decos = state.matches.map((m, i) =>
    Decoration.inline(m.from, m.to, {
      class: i === state.current ? 'pm-find-match pm-find-current' : 'pm-find-match',
    }),
  );
  return DecorationSet.create(doc, decos);
}

// Pasted rich HTML from webpages sometimes carries structural layout markup —
// most commonly nested <table>s used for old-school box/grid layouts (e.g. a
// shipment tracker widget) — that this schema can technically parse (tables
// are a real node type, see schema.ts's tableNodes) but that some WebViews
// (WKWebView on Mac/iOS) fail to lay out/render at all, leaving the rest of
// the note blank. This flattens table structure into plain paragraphs (one
// per cell) before the schema parses the paste, while leaving inline
// formatting (bold/italic/links/lists/etc.) inside those cells untouched —
// see transformPastedHTML below for where this hooks in.
function stripPastedTables(html: string): string {
  const dom = new DOMParser().parseFromString(html, 'text/html');

  // Repeatedly unwrap the innermost tables (no <table> descendant of their
  // own) so nested tables-within-tables are fully flattened, not just their
  // outermost shell. The guard caps iterations against runaway/malformed
  // input; real-world nesting is never anywhere near this deep.
  let tables = Array.from(dom.body.querySelectorAll('table'));
  let guard = 0;
  while (tables.length > 0 && guard < 20) {
    for (const table of tables) {
      if (table.querySelector('table')) continue; // handle innermost first
      const frag = dom.createDocumentFragment();
      for (const cell of Array.from(table.querySelectorAll('td, th'))) {
        const p = dom.createElement('p');
        while (cell.firstChild) p.appendChild(cell.firstChild);
        frag.appendChild(p);
      }
      table.replaceWith(frag);
    }
    tables = Array.from(dom.body.querySelectorAll('table'));
    guard++;
  }

  return dom.body.innerHTML;
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
    highlight: hasMark(m.highlight),
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

  // Runtime-toggleable editability. Starts from ?readonly=1 (a trashed note stays
  // permanently read-only). Android flips this at runtime via the setEditable native
  // bridge to implement its read-mode / edit-mode split: read mode (editable=false)
  // means a tap interacts with content (open a link, toggle a task, select text) and
  // never pops the keyboard; edit mode (editable=true) is normal editing. Mac and iOS
  // never call setEditable, so for them this stays === !isReadOnly and their behavior
  // is unchanged.
  let editable = !isReadOnly;

  // Android only — the on-screen keyboard's floating formatting toolbar sits
  // right above the keyboard, close enough to the last line that the text
  // selection handles are hard to grab. Extra bottom padding gives room to
  // scroll the last line clear of both. See EditorWebView.kt's ?platform=
  // query param and the body.pm-android rule in build.mjs.
  const isAndroid = /[?&]platform=android(&|$)/.test(location.search);
  if (isAndroid) document.body.classList.add('pm-android');

  // iPhone only — the body's 24/30px left/right padding (below) was sized for Mac's
  // much wider window and left too large a gap on iPhone's narrow screen. See
  // EditorView.swift's (iOS target) ?platform= query param and the body.pm-ios-phone
  // rule in build.mjs. iPad keeps the default padding (its screen is wide enough).
  const isIOSPhone = /[?&]platform=ios-phone(&|$)/.test(location.search);
  if (isIOSPhone) document.body.classList.add('pm-ios-phone');

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
              // On Android in edit mode, a link tap should place the cursor so the
              // link text can be edited — not launch the browser. In Android read
              // mode (and on every other platform, where `editable` is never toggled)
              // this opens the link as before.
              if (isAndroid && editable) return false;
              event.preventDefault();
              postToNative({ type: 'openUrl', url: anchor.href });
              return true;
            },
          },
        },
      }),

      // Data detectors: underline detected URLs / emails / phones / addresses in
      // plain text (see detectLinks) as yellow "active links", via decorations that
      // don't touch the stored document. A tap opens the right app; on Android in
      // edit mode a tap places the cursor instead (same rule as explicit links).
      new Plugin({
        key: autoLinkKey,
        state: {
          init: (_config, editorState) => buildAutoLinkDecos(editorState.doc),
          apply: (tr, old, _oldState, newState) =>
            tr.docChanged ? buildAutoLinkDecos(newState.doc) : old,
        },
        props: {
          decorations(editorState) {
            return autoLinkKey.getState(editorState);
          },
          handleDOMEvents: {
            click(_view, event) {
              const el = (event.target as HTMLElement).closest('[data-al-href]') as HTMLElement | null;
              if (!el) return false;
              if (isAndroid && editable) return false;
              event.preventDefault();
              const type = el.getAttribute('data-al-type');
              const href = el.getAttribute('data-al-href') || '';
              // Addresses go through openMaps (native shows a Google Maps / Waze
              // chooser); url/email/phone are already fully-formed scheme URLs.
              postToNative(type === 'address' ? { type: 'openMaps', url: href } : { type: 'openUrl', url: href });
              return true;
            },
          },
        },
      }),

      // Find in note — holds query/matches/current and renders them as decorations.
      // Driven by the find/findNext/findPrevious/endFind bridge methods, which
      // dispatch meta-only transactions (no doc change) picked up in apply below.
      new Plugin({
        key: findKey,
        state: {
          init: (): FindState => ({ query: '', matches: [], current: -1 }),
          apply: (tr, prev: FindState, _old, newState): FindState => {
            const meta = tr.getMeta(findKey) as { type: string; query?: string } | undefined;
            if (meta) {
              if (meta.type === 'clear') return { query: '', matches: [], current: -1 };
              if (meta.type === 'set') {
                const query = meta.query ?? '';
                const matches = computeFindMatches(newState.doc, query);
                // Start at the first match at/after the caret, else the first match.
                const head = newState.selection.head;
                let current = matches.findIndex((m) => m.from >= head);
                if (current < 0) current = matches.length ? 0 : -1;
                return { query, matches, current };
              }
              if ((meta.type === 'next' || meta.type === 'prev') && prev.matches.length) {
                const step = meta.type === 'next' ? 1 : -1;
                const current = (prev.current + step + prev.matches.length) % prev.matches.length;
                return { ...prev, current };
              }
              return prev;
            }
            // Keep matches in sync as the document changes while find is open.
            if (tr.docChanged && prev.query) {
              const matches = computeFindMatches(newState.doc, prev.query);
              const current = matches.length ? Math.min(Math.max(prev.current, 0), matches.length - 1) : -1;
              return { ...prev, matches, current };
            }
            return prev;
          },
        },
        props: {
          decorations(editorState) {
            const st = findKey.getState(editorState);
            return st ? findDecorations(editorState.doc, st) : null;
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
                // Resolve the position from the actual clicked checkbox (not
                // view.state.selection, which is still wherever the cursor was left
                // from a previous click/edit at this point — preventDefault() above
                // stops the browser from moving it to here first). Fixes checking one
                // line toggling a different (or no) line.
                const pos = view.posAtDOM(target, 0);
                toggleCheckboxAtPos(view, pos);
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

      // Flatten table-based layout structure out of pasted HTML — see
      // stripPastedTables above. Only runs for the normal (non-image,
      // non-bare-URL) rich-HTML paste path; the two handlePaste plugins above
      // already fully take over image/URL pastes before this would apply.
      new Plugin({
        props: {
          transformPastedHTML(html) {
            return stripPastedTables(html);
          },
        },
      }),
    ],
  });

  const view = new EditorView(domEl, {
    state,
    dispatchTransaction: (tr) => dispatchWithNotify(view)(tr),
    editable: () => editable,
  });

  // Exposed for the native setEditable bridge (Android's read/edit toggle). Flips the
  // `editable` flag the props closure above reads, then setProps() forces ProseMirror
  // to re-evaluate it and update the DOM's contentEditable (and blur if turning off).
  (view as EditorViewWithSetEditable).__setEditable = (value: boolean) => {
    if (editable === value) return;
    editable = value;
    view.setProps({ editable: () => editable });
  };

  // Android-only signal: lets the two-pane tablet layout (note list + editor
  // visible side by side, no persistent sidebar — see NotesNavHost.kt) switch
  // the selected note row between Dimmed Yellow (list has focus) and Gray
  // (editor has focus). Mac doesn't need this — its equivalent distinction is
  // driven by sidebar focus instead (see SidebarView.swift's isSidebarFocused).
  view.dom.addEventListener('focus', () => postToNative({ type: 'focusChanged', focused: true }));
  view.dom.addEventListener('blur', () => postToNative({ type: 'focusChanged', focused: false }));

  // Initial selection state
  notifySelection(view.state);

  return view;
}

// ── Native API (called from Swift via evaluateJavaScript) ─────────────────────

interface NativeEditorBridge {
  setContent: (title: string, body: string) => void;
  execCommand: (command: string, value?: any) => void;
  setEditable: (value: boolean) => void;
  find: (query: string) => void;
  findNext: () => void;
  findPrevious: () => void;
  endFind: () => void;
  focus: () => void;
  blur: () => void;
  getHTML: () => string;
  collapseSelection: () => void;
}

// EditorView with the runtime editability setter attached in createEditor (see there).
type EditorViewWithSetEditable = EditorView & { __setEditable?: (value: boolean) => void };

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

  // After a find/findNext/findPrevious dispatch: scroll the current match into view
  // (without moving the selection) and report count/index to the native find bar.
  const afterFindUpdate = () => {
    const st = findKey.getState(view.state);
    if (!st) return;
    const match = st.current >= 0 ? st.matches[st.current] : undefined;
    if (match) {
      try {
        const domAt = view.domAtPos(match.from);
        const el = domAt.node.nodeType === Node.TEXT_NODE ? domAt.node.parentElement : (domAt.node as HTMLElement);
        el?.scrollIntoView({ block: 'center', behavior: 'smooth' });
      } catch (_) {
        // position not resolvable this frame — ignore
      }
    }
    postToNative({ type: 'findResult', count: st.matches.length, index: st.current >= 0 ? st.current + 1 : 0 });
  };

  const bridge: NativeEditorBridge = {
    setContent(title: string, body: string) {
      // Splice the title in as a real `div.pm-title` DOM node (title's own
      // parseDOM tag) ahead of the body, then run the *full* parser.parse()
      // over the combined DOM with `doc` as the top node. Unlike parseSlice +
      // doc.create() (previous approach — produced structurally invalid docs
      // that later crashed with "contentMatchAt on a node with invalid
      // content") or doc.createAndFill() (tried, reverted — it repairs
      // mismatches by deleting whatever doesn't fit, which silently wiped an
      // entire note body), parser.parse() builds the document incrementally
      // against doc's own content expression ('title block*'), auto-wrapping
      // stray content in the correct block type as it goes — the same
      // context-aware matching used while typing — so it can't produce an
      // invalid document and doesn't drop valid content to do it.
      const domParser = new DOMParser();
      const dom = domParser.parseFromString(body || '<p></p>', 'text/html');

      const titleDiv = dom.createElement('div');
      titleDiv.className = 'pm-title';
      if (title) titleDiv.textContent = title;
      dom.body.insertBefore(titleDiv, dom.body.firstChild);

      const parser = PMDOMParser.fromSchema(schema);
      const doc = parser.parse(dom.body, { preserveWhitespace: true });

      const newState = EditorState.create({
        doc,
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

    setEditable(value: boolean) {
      (view as EditorViewWithSetEditable).__setEditable?.(value);
    },

    // ── Find in note ──
    find(query: string) {
      view.dispatch(view.state.tr.setMeta(findKey, { type: 'set', query }));
      afterFindUpdate();
    },
    findNext() {
      view.dispatch(view.state.tr.setMeta(findKey, { type: 'next' }));
      afterFindUpdate();
    },
    findPrevious() {
      view.dispatch(view.state.tr.setMeta(findKey, { type: 'prev' }));
      afterFindUpdate();
    },
    endFind() {
      view.dispatch(view.state.tr.setMeta(findKey, { type: 'clear' }));
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
