// Selection-capture utility for the annotation flow.
//
// Resolves a `window.getSelection()` to char offsets within `rootEl.textContent`
// — NOT the rendered DOM, which has extra nodes from react-markdown. This
// lets us persist a stable anchor that survives re-renders.
//
// Strategy: walk the root's text nodes in document order, summing their
// `length` until we hit the selection's start/end nodes. The result is the
// pair of offsets into the concatenated `textContent` string.
//
// Anchor shape matches operator_ui.annotations: quote + 40-char prefix +
// 40-char suffix + char_start + char_end. Three-strategy means future code
// can re-locate the highlight when content shifts.

export type AnnotationAnchor = {
  quote: string;
  prefix: string;
  suffix: string;
  charStart: number;
  charEnd: number;
};

const CONTEXT_LEN = 40;

function offsetWithinRoot(
  rootEl: HTMLElement,
  node: Node,
  offsetInNode: number,
): number | null {
  // Walk text nodes in document order; sum lengths until we reach `node`.
  // Returns null if `node` isn't a descendant text node of rootEl OR if
  // `node` is the rootEl itself with `offsetInNode` indexing child nodes
  // (Range can land on element boundaries — handle below).

  if (node === rootEl) {
    // Selection landed on the root element. The offset indexes child nodes,
    // not characters. Sum textContent lengths of children [0, offsetInNode).
    let total = 0;
    for (let i = 0; i < offsetInNode && i < rootEl.childNodes.length; i++) {
      total += rootEl.childNodes[i].textContent?.length ?? 0;
    }
    return total;
  }

  if (!rootEl.contains(node)) return null;

  // If `node` is an element rather than a text node, the offset indexes its
  // children. Resolve to a text-position by summing child textContent.
  if (node.nodeType !== Node.TEXT_NODE) {
    let prefixLen = 0;
    for (let i = 0; i < offsetInNode && i < node.childNodes.length; i++) {
      prefixLen += node.childNodes[i].textContent?.length ?? 0;
    }
    // Add the length of all text preceding `node` itself within rootEl.
    const preceding = textBefore(rootEl, node);
    return preceding === null ? null : preceding + prefixLen;
  }

  // Text-node path: walk siblings/ancestors before `node` and accumulate.
  const preceding = textBefore(rootEl, node);
  if (preceding === null) return null;
  return preceding + offsetInNode;
}

function textBefore(rootEl: HTMLElement, target: Node): number | null {
  // Returns sum of textContent lengths of all text appearing in document
  // order before `target` within rootEl. Null if target isn't inside.
  if (!rootEl.contains(target)) return null;
  let total = 0;
  const walker = document.createTreeWalker(rootEl, NodeFilter.SHOW_TEXT);
  let cursor: Node | null = walker.nextNode();
  while (cursor) {
    if (cursor === target) break;
    const pos = target.compareDocumentPosition(cursor);
    // DOCUMENT_POSITION_PRECEDING (0x02): cursor comes before target.
    if (pos & Node.DOCUMENT_POSITION_PRECEDING) {
      total += (cursor as Text).data.length;
    } else {
      // cursor follows target (or is unrelated) — stop walking.
      break;
    }
    cursor = walker.nextNode();
  }
  return total;
}

export function captureSelection(rootEl: HTMLElement): AnnotationAnchor | null {
  if (typeof window === "undefined") return null;
  const sel = window.getSelection();
  if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return null;

  const range = sel.getRangeAt(0);
  if (!rootEl.contains(range.commonAncestorContainer)) return null;

  const startOffset = offsetWithinRoot(rootEl, range.startContainer, range.startOffset);
  const endOffset = offsetWithinRoot(rootEl, range.endContainer, range.endOffset);
  if (startOffset === null || endOffset === null) return null;

  const charStart = Math.min(startOffset, endOffset);
  const charEnd = Math.max(startOffset, endOffset);
  if (charStart === charEnd) return null;

  const fullText = rootEl.textContent ?? "";
  const quote = fullText.slice(charStart, charEnd);
  if (!quote.trim()) return null;

  const prefix = fullText.slice(Math.max(0, charStart - CONTEXT_LEN), charStart);
  const suffix = fullText.slice(charEnd, Math.min(fullText.length, charEnd + CONTEXT_LEN));

  return { quote, prefix, suffix, charStart, charEnd };
}
