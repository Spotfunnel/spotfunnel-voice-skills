"use client";

import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { browserSupabase } from "@/lib/supabase-browser";
import { captureSelection, type AnnotationAnchor } from "@/lib/highlight";
import type { Annotation } from "@/lib/types";

type Props = {
  content: string;
  runId: string;
  artifactName: string;
  annotations: Annotation[];
};

type PopoverState =
  | { kind: "chip"; anchor: AnnotationAnchor; rect: DOMRect }
  | { kind: "composer"; anchor: AnnotationAnchor; rect: DOMRect }
  | null;

// Highlight color: warm yellow at 60% opacity so prose underneath stays
// readable. Matches the M6 spec (#FFF1A8 @ 60%).
const HIGHLIGHT_BG = "rgba(255, 241, 168, 0.6)";

function relativeTime(iso: string): string {
  const then = new Date(iso).getTime();
  const now = Date.now();
  const sec = Math.max(0, Math.round((now - then) / 1000));
  if (sec < 60) return "just now";
  const min = Math.round(sec / 60);
  if (min < 60) return `${min}m ago`;
  const hr = Math.round(min / 60);
  if (hr < 24) return `${hr}h ago`;
  const d = Math.round(hr / 24);
  if (d < 30) return `${d}d ago`;
  return new Date(iso).toLocaleDateString();
}

function truncate(s: string, n: number): string {
  return s.length > n ? s.slice(0, n) + "..." : s;
}

// Post-render DOM walker: iterates text nodes inside `root` and wraps any
// substring that overlaps an annotation range in a <mark>. Idempotent —
// scans for an existing data-annotation-id under root and rebuilds. We do
// this in useEffect instead of during react-markdown render because that
// path needs a mutable cursor across components, which violates React's
// pure-render contract (StrictMode double-renders trip it).
function applyHighlights(root: HTMLElement, annotations: Annotation[]) {
  // Tear down previous marks: replace each <mark data-annotation-id> with
  // its text content, then merge adjacent text nodes via normalize().
  const stale = root.querySelectorAll("mark[data-annotation-id]");
  stale.forEach((m) => {
    const text = document.createTextNode(m.textContent ?? "");
    m.replaceWith(text);
  });
  root.normalize();

  if (annotations.length === 0) return;

  const sorted = [...annotations].sort((a, b) => a.char_start - b.char_start);

  // Walk text nodes, tracking absolute offset in the running textContent.
  // For each annotation overlapping the current node's [offset, offset+len),
  // split the text node and wrap the slice.
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode(n) {
      // Skip text already inside a <mark> we're about to add — shouldn't
      // happen on the second pass because we tore them down, but defensive.
      let p: Node | null = n.parentNode;
      while (p && p !== root) {
        if (
          p.nodeType === Node.ELEMENT_NODE &&
          (p as Element).hasAttribute("data-annotation-id")
        ) {
          return NodeFilter.FILTER_REJECT;
        }
        p = p.parentNode;
      }
      return NodeFilter.FILTER_ACCEPT;
    },
  });

  // Materialize the list first because mutation during walking confuses the
  // walker.
  const textNodes: Text[] = [];
  let cur: Node | null = walker.nextNode();
  while (cur) {
    textNodes.push(cur as Text);
    cur = walker.nextNode();
  }

  let offset = 0;
  for (const node of textNodes) {
    const len = node.data.length;
    const nodeStart = offset;
    const nodeEnd = offset + len;
    offset = nodeEnd;

    // Find every annotation overlapping [nodeStart, nodeEnd).
    const overlaps = sorted.filter(
      (a) => a.char_end > nodeStart && a.char_start < nodeEnd,
    );
    if (overlaps.length === 0) continue;

    // Compute non-overlapping intra-node ranges, each tagged with at most
    // one annotation (the first that contains the segment).
    const cuts = new Set<number>([0, len]);
    for (const a of overlaps) {
      cuts.add(Math.max(0, a.char_start - nodeStart));
      cuts.add(Math.min(len, a.char_end - nodeStart));
    }
    const sortedCuts = [...cuts].sort((x, y) => x - y);

    // Build replacement nodes in order.
    const parent = node.parentNode;
    if (!parent) continue;
    const replacement = document.createDocumentFragment();
    for (let i = 0; i < sortedCuts.length - 1; i++) {
      const segStart = sortedCuts[i];
      const segEnd = sortedCuts[i + 1];
      if (segStart === segEnd) continue;
      const text = node.data.slice(segStart, segEnd);
      const absStart = nodeStart + segStart;
      const absEnd = nodeStart + segEnd;
      const ann = overlaps.find(
        (a) => a.char_start <= absStart && a.char_end >= absEnd,
      );
      if (ann) {
        const mark = document.createElement("mark");
        mark.setAttribute("data-annotation-id", ann.id);
        mark.style.backgroundColor = HIGHLIGHT_BG;
        mark.style.borderRadius = "2px";
        mark.style.padding = "0 2px";
        mark.style.cursor = "default";
        mark.title = `${truncate(ann.comment, 60)} — ${ann.author_name}, ${relativeTime(ann.created_at)}`;
        mark.textContent = text;
        replacement.appendChild(mark);
      } else {
        replacement.appendChild(document.createTextNode(text));
      }
    }
    parent.replaceChild(replacement, node);
  }
}

export function ArtifactReader({
  content,
  runId,
  artifactName,
  annotations,
}: Props) {
  const router = useRouter();
  const rootRef = useRef<HTMLDivElement | null>(null);
  const [popover, setPopover] = useState<PopoverState>(null);
  const [comment, setComment] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Sort + filter annotations once per prop change.
  const liveAnnotations = useMemo(
    () =>
      [...annotations].filter(
        (a) => a.status === "open" || a.status === "orphan",
      ),
    [annotations],
  );

  // After react-markdown finishes rendering (and on every annotations change),
  // walk the article and overlay <mark> elements. useLayoutEffect runs before
  // browser paint, avoiding the visible flash between unmarked and marked
  // render passes that useEffect would produce.
  useLayoutEffect(() => {
    const root = rootRef.current;
    if (!root) return;
    applyHighlights(root, liveAnnotations);
  }, [liveAnnotations, content]);

  const onMouseUp = useCallback(() => {
    const root = rootRef.current;
    if (!root) return;
    // Defer one tick so the browser finalizes the selection (Safari quirk).
    requestAnimationFrame(() => {
      const anchor = captureSelection(root);
      if (!anchor) {
        // Don't clobber an open composer with an empty selection event.
        if (popover?.kind !== "composer") setPopover(null);
        return;
      }
      const sel = window.getSelection();
      if (!sel || sel.rangeCount === 0) return;
      const rect = sel.getRangeAt(0).getBoundingClientRect();
      setPopover({ kind: "chip", anchor, rect });
    });
  }, [popover]);

  // Esc cancels composer/chip; document-level so it works regardless of focus.
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key === "Escape") {
        setPopover(null);
        setComment("");
        setError(null);
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  async function save() {
    if (!popover || popover.kind !== "composer") return;
    const trimmed = comment.trim();
    if (!trimmed) return;

    // Author name MUST come from the OperatorNameGate (which populates
    // localStorage). Falling through silently to "anonymous" would pollute
    // the audit trail M7+ relies on. If the gate didn't run, refuse to save
    // and surface the error so the user is rerouted through the gate.
    const stored =
      typeof window !== "undefined"
        ? window.localStorage.getItem("operatorName")
        : null;
    const authorName = stored?.trim();
    if (!authorName) {
      setError("Operator name missing — please refresh the page to set your name.");
      return;
    }

    setSaving(true);
    setError(null);
    const { error: insertErr } = await browserSupabase
      .from("annotations")
      .insert({
        run_id: runId,
        artifact_name: artifactName,
        quote: popover.anchor.quote,
        prefix: popover.anchor.prefix,
        suffix: popover.anchor.suffix,
        char_start: popover.anchor.charStart,
        char_end: popover.anchor.charEnd,
        comment: trimmed,
        author_name: authorName,
        status: "open",
      });
    setSaving(false);
    if (insertErr) {
      setError(insertErr.message);
      return;
    }
    setPopover(null);
    setComment("");
    // Refresh server props so the new annotation joins the rendered overlay.
    // M7 follow-up: switch to optimistic insert + targeted annotations refetch
    // so we don't re-fetch customer + run + artifact for one new row.
    router.refresh();
  }

  function onComposerKey(e: React.KeyboardEvent) {
    if ((e.ctrlKey || e.metaKey) && e.key === "Enter") {
      e.preventDefault();
      void save();
    }
  }

  // Position the popover above the selection rect, clamped to viewport.
  function popoverPos(rect: DOMRect): { top: number; left: number } {
    const pad = 8;
    const top = window.scrollY + rect.top - 40 - pad;
    const left = window.scrollX + rect.left + rect.width / 2;
    return { top, left };
  }

  return (
    <>
      <article
        ref={rootRef}
        onMouseUp={onMouseUp}
        className="max-w-3xl mx-auto mt-10 prose prose-stone font-serif"
        data-testid="artifact-body"
      >
        <ReactMarkdown remarkPlugins={[remarkGfm]}>{content}</ReactMarkdown>
      </article>

      {popover?.kind === "chip" ? (
        <button
          type="button"
          onMouseDown={(e) => {
            // Prevent the click from clearing the selection before we read it.
            e.preventDefault();
          }}
          onClick={() => {
            setPopover({
              kind: "composer",
              anchor: popover.anchor,
              rect: popover.rect,
            });
          }}
          className="absolute z-50 -translate-x-1/2 -translate-y-full bg-[#1A1A1A] text-white text-xs px-3 py-1.5 rounded-full shadow-md hover:bg-[#333] transition-colors"
          style={popoverPos(popover.rect)}
          data-testid="annotation-chip"
        >
          Comment
        </button>
      ) : null}

      {popover?.kind === "composer" ? (
        <div
          className="absolute z-50 -translate-x-1/2 -translate-y-full bg-white border border-[#E5E5E0] rounded-md shadow-lg p-4 w-80"
          style={popoverPos(popover.rect)}
          data-testid="annotation-composer"
        >
          <div className="text-sm font-serif italic text-[#6B6B6B] border-l-2 border-[#FFE38A] pl-2">
            &ldquo;{truncate(popover.anchor.quote, 80)}&rdquo;
          </div>
          <textarea
            autoFocus
            value={comment}
            onChange={(e) => setComment(e.target.value)}
            onKeyDown={onComposerKey}
            placeholder="Add a comment…"
            rows={3}
            className="mt-3 w-full border border-[#E5E5E0] rounded px-2 py-1.5 text-sm text-[#1A1A1A] focus:outline-none focus:border-[#3B5BDB] resize-none"
            data-testid="annotation-textarea"
          />
          {error ? (
            <div className="mt-2 text-xs text-red-600">{error}</div>
          ) : null}
          <div className="mt-3 flex items-center justify-end gap-2">
            <button
              type="button"
              onClick={() => {
                setPopover(null);
                setComment("");
                setError(null);
              }}
              className="text-xs text-[#6B6B6B] hover:text-[#1A1A1A] px-2 py-1"
            >
              Cancel
            </button>
            <button
              type="button"
              onClick={() => void save()}
              disabled={!comment.trim() || saving}
              className="text-xs bg-[#3B5BDB] text-white px-3 py-1.5 rounded hover:bg-[#2F4DBF] disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
              data-testid="annotation-save"
            >
              {saving ? "Saving…" : "Save"}
            </button>
          </div>
          <div className="mt-2 text-[10px] text-[#9B9B95]">
            Ctrl+Enter to save · Esc to cancel
          </div>
        </div>
      ) : null}
    </>
  );
}
