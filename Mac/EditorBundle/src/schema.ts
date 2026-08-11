/**
 * ProseMirror schema for NotesTN.
 * Adapted from Joplin's packages/editor/ProseMirror/schema.ts.
 * Nodes: doc, paragraph, text, hard_break, heading, code_block, blockquote,
 *        horizontal_rule, bullet_list, ordered_list, list_item,
 *        task_list, task_list_item, image, attachment, table nodes.
 * Marks: strong, em, code, strikethrough, link, sub, sup, highlight.
 */

import { Schema } from 'prosemirror-model';
import { tableNodes } from 'prosemirror-tables';

// ── Attachment card helpers ───────────────────────────────────────────────────

/// "1.2 MB" — decimal units, matching what Finder and Apple Notes show.
function formatFileSize(bytes: number): string {
  if (!bytes || bytes < 0) return '';
  if (bytes < 1000) return `${bytes} bytes`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let value = bytes / 1000;
  let unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  return `${value < 10 ? value.toFixed(1) : Math.round(value)} ${units[unit]}`;
}

function fileExtension(title: string, mime: string): string {
  const fromName = /\.([A-Za-z0-9]+)$/.exec(title || '')?.[1];
  if (fromName) return fromName.toLowerCase();
  const fromMime = (mime || '').split('/').pop() || '';
  return fromMime.toLowerCase();
}

/// Short badge shown on the right of the card, e.g. "PDF".
function fileExtensionLabel(title: string, mime: string): string {
  const ext = fileExtension(title, mime);
  return ext ? ext.toUpperCase().slice(0, 4) : 'FILE';
}

/// Human-readable type name, the way Apple Notes labels attachments
/// ("Word Document"). Falls back to "<EXT> File", then to the MIME type.
function fileTypeName(title: string, mime: string): string {
  const byExtension: Record<string, string> = {
    pdf: 'PDF Document',
    doc: 'Word Document',
    docx: 'Word Document',
    xls: 'Excel Spreadsheet',
    xlsx: 'Excel Spreadsheet',
    csv: 'CSV Document',
    ppt: 'PowerPoint Presentation',
    pptx: 'PowerPoint Presentation',
    pages: 'Pages Document',
    numbers: 'Numbers Spreadsheet',
    key: 'Keynote Presentation',
    txt: 'Plain Text Document',
    rtf: 'Rich Text Document',
    md: 'Markdown Document',
    zip: 'ZIP Archive',
    gz: 'Archive',
    tar: 'Archive',
    mp3: 'Audio',
    wav: 'Audio',
    m4a: 'Audio',
    mp4: 'Movie',
    mov: 'Movie',
    json: 'JSON Document',
    html: 'HTML Document',
  };
  const ext = fileExtension(title, mime);
  if (byExtension[ext]) return byExtension[ext];
  if (ext) return `${ext.toUpperCase()} File`;
  return mime || 'File';
}

/// The card's second line: "Word Document · 642 KB" (size omitted if unknown).
function attachmentMeta(title: string, mime: string, size: number): string {
  const type = fileTypeName(title, mime);
  const readableSize = formatFileSize(size);
  return readableSize ? `${type} · ${readableSize}` : type;
}

const nodes = {
  doc: {
    // Every doc has exactly one title node, always first, followed by the note
    // body. This lets the title scroll in the same element/scroll-context as
    // the body instead of living in a separate native text field.
    content: 'title block*',
  },

  // The note's title, as the doc's mandatory first node. A plain div (not an
  // h1) so it can never collide with the `heading` node's h1-h6 parseDOM
  // rules below. No marks — the native title field was always plain text.
  title: {
    content: 'inline*',
    marks: '',
    defining: true,
    parseDOM: [{ tag: 'div.pm-title' }],
    toDOM() { return ['div', { class: 'pm-title' }, 0] as const; },
  },

  paragraph: {
    group: 'block',
    content: 'inline*',
    parseDOM: [{ tag: 'p' }],
    toDOM() { return ['p', 0] as const; },
  },

  text: {
    group: 'inline',
  },

  hard_break: {
    inline: true,
    group: 'inline',
    selectable: false,
    parseDOM: [{ tag: 'br' }],
    toDOM() { return ['br'] as const; },
  },

  heading: {
    attrs: { level: { default: 1 }, collapsed: { default: false } },
    content: 'inline*',
    group: 'block',
    defining: true,
    parseDOM: [1, 2, 3, 4, 5, 6].map(i => ({
      tag: `h${i}`,
      getAttrs(dom: HTMLElement | string) {
        if (typeof dom === 'string') return { level: i };
        return {
          level: i,
          collapsed: (dom as HTMLElement).hasAttribute('data-collapsed'),
        };
      },
    })),
    toDOM(node: any) {
      const attrs: Record<string, string> = {};
      // Level 1 ("Title" in the toolbar's style menu) is a plain heading with no
      // collapse behavior — only level 3/4 ("Heading"/"Subheading") get the arrow.
      // See the collapse plugin in index.ts, which only acts on level !== 1.
      if (node.attrs.level === 1) {
        return [`h${node.attrs.level}`, attrs, 0] as any;
      }
      if (node.attrs.collapsed) attrs['data-collapsed'] = '';
      // Non-editable arrow span + content hole in a second span.
      // The arrow is purely visual (CSS ::after); the content hole carries the text.
      return [`h${node.attrs.level}`, attrs,
        ['span', { class: 'pm-heading-arrow', contenteditable: 'false' }],
        ['span', { class: 'pm-heading-content' }, 0],
      ] as any;
    },
  },

  code_block: {
    content: 'text*',
    marks: '',
    group: 'block',
    code: true,
    defining: true,
    parseDOM: [{ tag: 'pre', preserveWhitespace: 'full' as const }],
    toDOM() { return ['pre', ['code', 0]] as const; },
  },

  blockquote: {
    content: 'block+',
    group: 'block',
    defining: true,
    parseDOM: [{ tag: 'blockquote' }],
    toDOM() { return ['blockquote', 0] as const; },
  },

  horizontal_rule: {
    group: 'block',
    parseDOM: [{ tag: 'hr' }],
    toDOM() { return ['hr'] as const; },
  },

  // Standard bullet list (ul without data-is-checklist)
  bullet_list: {
    group: 'block',
    content: 'list_item+',
    parseDOM: [{ tag: 'ul:not([data-is-checklist])' }],
    toDOM() { return ['ul', 0] as const; },
  },

  // Standard ordered list
  ordered_list: {
    group: 'block',
    content: 'list_item+',
    attrs: { order: { default: 1 } },
    parseDOM: [{
      tag: 'ol',
      getAttrs(dom: HTMLElement | string) {
        if (typeof dom === 'string') return {};
        return { order: dom.hasAttribute('start') ? +(dom.getAttribute('start') || 1) : 1 };
      },
    }],
    toDOM(node: any) {
      return node.attrs.order === 1
        ? ['ol', 0]
        : ['ol', { start: node.attrs.order }, 0];
    },
  },

  // Standard list item (for bullet/ordered lists)
  list_item: {
    content: 'paragraph block*',
    defining: true,
    parseDOM: [{ tag: 'li:not(.md-checkbox)' }],
    toDOM() { return ['li', 0] as const; },
  },

  // Task list container (ul with data-is-checklist)
  task_list: {
    group: 'block',
    content: 'task_list_item+',
    parseDOM: [{ tag: 'ul[data-is-checklist]' }],
    toDOM() { return ['ul', { 'data-is-checklist': 'true' }, 0] as const; },
  },

  // Task list item (checkbox + content)
  task_list_item: {
    attrs: { checked: { default: false } },
    content: 'paragraph block*',
    defining: true,
    parseDOM: [{
      tag: 'li.md-checkbox',
      getAttrs(dom: HTMLElement | string) {
        if (typeof dom === 'string') return {};
        const checkbox = dom.querySelector('input[type="checkbox"]') as HTMLInputElement | null;
        return { checked: checkbox?.checked ?? false };
      },
    }],
    toDOM(node: any) {
      const li = ['li', { class: node.attrs.checked ? 'md-checkbox checked' : 'md-checkbox' }];
      const checkbox = ['input', {
        type: 'checkbox',
        ...(node.attrs.checked ? { checked: '' } : {}),
      }];
      return [...li, checkbox, ['div', 0]] as any;
    },
  },

  // Toggle / collapsible section
  details: {
    attrs: { open: { default: true } },
    group: 'block',
    content: 'details_summary block+',
    defining: true,
    parseDOM: [{
      tag: 'details',
      getAttrs(dom: HTMLElement | string) {
        if (typeof dom === 'string') return {};
        return { open: (dom as HTMLElement).hasAttribute('open') };
      },
    }],
    toDOM(node: any) {
      return ['details', node.attrs.open ? { open: '' } : {}, 0] as const;
    },
  },

  // Summary / title line inside a toggle block
  details_summary: {
    content: 'inline*',
    defining: true,
    parseDOM: [{ tag: 'summary' }],
    toDOM() {
      // The arrow span is non-editable (CSS ::after draws the triangle).
      // The content hole goes into the second span so ProseMirror manages it.
      return ['summary', {},
        ['span', { class: 'pm-toggle-arrow', contenteditable: 'false' }],
        ['span', { class: 'pm-toggle-content' }, 0],
      ] as any;
    },
  },

  // Image node
  image: {
    inline: true,
    attrs: {
      src: {},
      alt: { default: null },
      title: { default: null },
      width: { default: null },
      height: { default: null },
      'data-resource-id': { default: null },
    },
    group: 'inline',
    draggable: true,
    parseDOM: [{
      tag: 'img[src]',
      getAttrs(dom: HTMLElement | string) {
        if (typeof dom === 'string') return {};
        return {
          src: dom.getAttribute('src'),
          alt: dom.getAttribute('alt'),
          title: dom.getAttribute('title'),
          width: dom.getAttribute('width'),
          height: dom.getAttribute('height'),
          'data-resource-id': dom.getAttribute('data-resource-id'),
        };
      },
    }],
    toDOM(node: any) {
      const { src, alt, title, width, height } = node.attrs;
      const attrs: Record<string, string> = { src };
      if (alt) attrs.alt = alt;
      if (title) attrs.title = title;
      if (width) attrs.width = width;
      if (height) attrs.height = height;
      if (node.attrs['data-resource-id']) attrs['data-resource-id'] = node.attrs['data-resource-id'];
      return ['img', attrs];
    },
  },

  // File attachment (PDF, Word, …) shown as an Apple Notes-style card: filename,
  // then a "Type · Size" line, with a type badge on the right. An atom so the card
  // behaves as a single object rather than editable content, and a block so it sits
  // on its own line.
  //
  // Round-trips through Joplin Markdown as a plain resource link, [title](:/id) —
  // Joplin's own format for a non-image attachment — so other Joplin clients can
  // still open it. See HtmlToMarkdown/MarkdownToHtml.
  attachment: {
    group: 'block',
    atom: true,
    selectable: true,
    attrs: {
      resourceId: { default: '' },
      title: { default: '' },
      size: { default: 0 },
      mime: { default: '' },
    },
    parseDOM: [{
      tag: 'div.pm-attachment',
      getAttrs(dom: HTMLElement | string) {
        if (typeof dom === 'string') return {};
        return {
          resourceId: dom.getAttribute('data-resource-id') || '',
          title: dom.getAttribute('data-title') || '',
          size: Number(dom.getAttribute('data-size') || '0') || 0,
          mime: dom.getAttribute('data-mime') || '',
        };
      },
    }],
    toDOM(node: any) {
      const { resourceId, title, size, mime } = node.attrs;
      return [
        'div',
        {
          class: 'pm-attachment',
          'data-resource-id': resourceId,
          'data-title': title,
          'data-size': String(size ?? 0),
          'data-mime': mime ?? '',
          contenteditable: 'false',
        },
        ['div', { class: 'pm-attachment-info' },
          ['div', { class: 'pm-attachment-name' }, title || 'Attachment'],
          ['div', { class: 'pm-attachment-meta' }, attachmentMeta(title, mime, size)],
        ],
        ['div', { class: 'pm-attachment-badge' }, fileExtensionLabel(title, mime)],
      ] as any;
    },
  },

  // Table nodes from prosemirror-tables
  ...tableNodes({
    tableGroup: 'block',
    cellContent: 'block+',
    cellAttributes: {},
  }),
};

const marks = {
  strong: {
    parseDOM: [
      { tag: 'strong' },
      { tag: 'b', getAttrs: (n: HTMLElement | string) => typeof n !== 'string' && n.style.fontWeight !== 'normal' && null },
      { style: 'font-weight=400', clearMark: (m: any) => m.type.name === 'strong' },
      { style: 'font-weight', getAttrs: (value: string | HTMLElement) => typeof value === 'string' && /^(bold(er)?|[5-9]\d{2,})$/.test(value) && null },
    ],
    toDOM() { return ['strong', 0] as const; },
  },

  em: {
    parseDOM: [
      { tag: 'i' },
      { tag: 'em' },
      { style: 'font-style=italic' },
      { style: 'font-style=oblique' },
    ],
    toDOM() { return ['em', 0] as const; },
  },

  code: {
    parseDOM: [{ tag: 'code' }],
    toDOM() { return ['code', 0] as const; },
  },

  strikethrough: {
    parseDOM: [
      { tag: 's' },
      { tag: 'del' },
      { tag: 'strike' },
      { style: 'text-decoration=line-through' },
    ],
    toDOM() { return ['s', 0] as const; },
  },

  link: {
    attrs: {
      href: {},
      title: { default: null },
    },
    inclusive: false,
    parseDOM: [{
      tag: 'a[href]',
      getAttrs(dom: HTMLElement | string) {
        if (typeof dom === 'string') return {};
        return {
          href: dom.getAttribute('href'),
          title: dom.getAttribute('title'),
        };
      },
    }],
    toDOM(node: any) {
      const { href, title } = node.attrs;
      return ['a', { href, ...(title ? { title } : {}) }, 0] as const;
    },
  },

  sub: {
    parseDOM: [{ tag: 'sub' }],
    toDOM() { return ['sub', 0] as const; },
  },

  sup: {
    parseDOM: [{ tag: 'sup' }],
    toDOM() { return ['sup', 0] as const; },
  },

  highlight: {
    parseDOM: [{ tag: 'mark' }],
    toDOM() { return ['mark', 0] as const; },
  },
};

const schema = new Schema({ nodes, marks });

export default schema;
