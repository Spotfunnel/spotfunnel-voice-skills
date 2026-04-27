"use client";

import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { browserSupabase } from "@/lib/supabase-browser";
import { captureSelection, type AnnotationAnchor } from "@/lib/highlight";
import type { Annotation } from "@/lib/types";
import { AnnotationRail, type RailFilter } from "@/components/AnnotationRail";
import { relativeTime, truncate } from "@/lib/format";
import { displayAuthor } from "@/lib/author";

type Props = {
  content: string;
  runId: string;
  artifactName: string;
  chapterName: string;
  annotations: Annotation[];
};

// M24: chip can also be "stale" — operator drag-selected, then clicked
// elsewhere (collapsing the live selection). We keep the chip visible for
// 3s with a subtle visual cue so an accidental click-away isn't a silent
// data loss. Clicking the stale chip restores the prior anchor and opens
// the composer.
type PopoverState =
  | { kind: "chip"; anchor: AnnotationAnchor; rect: DOMRect }
  | { kind: "stale-chip"; anchor: AnnotationAnchor; rect: DOMRect }
  | { kind: "composer"; anchor: AnnotationAnchor; rect: DOMRect }
  | null;

const STALE_CHIP_MS = 3000;

// Highlight color: warm yellow at 60% opacity so prose underneath stays
// readable. Matches the M6 spec (#FFF1A8 @ 60%).
const HIGHLIGHT_BG = "rgba(255, 241, 168, 0.6)";
// Resolved opacity: keep mark visible (so reviewers can still see what was
// commented on) but obviously dimmed. 30% per M7 spec.
const HIGHLIGHT_BG_RESOLVED = "rgba(255, 241, 168, 0.18)"; // ~30% of base

// Post-render DOM walker: iterates text nodes inside `root` and wraps any
// substring that overlaps an annotation range in a <mark>. Idempotent —
// scans for an existing data-annotation-id under root and rebuilds. We do
// this in useEffect instead of during react-markdown render because that
// path needs a mutable cursor across components, which violates React's
// pure-render contract (StrictMode double-renders trip it).
//
// M7: resolved annotations render dimmed (still clickable to open the rail).
// Deleted annotations are skipped here entirely — they only appear inside
// the rail under the "deleted" filter.
function applyHighlights(
  root: HTMLElement,
  annotations: Annotation[],
  onMarkClick: (id: string) => void,
) {
  // Tear down previous marks: replace each <mark data-annotation-id> with
  // its text content, then merge adjacent text nodes via normalize().
  const stale = root.querySelectorAll("mark[data-annotation-id]");
  stale.forEach((m) => {
    const text = document.createTextNode(m.textContent ?? "");
    m.replaceWith(text);
  });
  root.normalize();

  // Filter out deleted before doing any DOM work. Resolved are kept (dimmed).
  const renderable = annotations.filter((a) => a.status !== "deleted");
  if (renderable.length === 0) return;

  const sorted = [...renderable].sort((a, b) => a.char_start - b.char_start);

  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode(n) {
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

    const overlaps = sorted.filter(
      (a) => a.char_end > nodeStart && a.char_start < nodeEnd,
    );
    if (overlaps.length === 0) continue;

    const cuts = new Set<number>([0, len]);
    for (const a of overlaps) {
      cuts.add(Math.max(0, a.char_start - nodeStart));
      cuts.add(Math.min(len, a.char_end - nodeStart));
    }
    const sortedCuts = [...cuts].sort((x, y) => x - y);

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
        mark.setAttribute("data-annotation-status", ann.status);
        const isResolved = ann.status === "resolved";
        mark.style.backgroundColor = isResolved
          ? HIGHLIGHT_BG_RESOLVED
          : HIGHLIGHT_BG;
        mark.style.borderRadius = "2px";
        mark.style.padding = "0 2px";
        mark.style.cursor = "pointer";
        mark.title = `${truncate(ann.comment, 60)} — ${displayAuthor(ann)}, ${relativeTime(ann.created_at)}`;
        mark.textContent = text;
        // Click opens the rail focused on this annotation. We bind a closure
        // here rather than rely on event delegation so multiple rebuilds
        // don't double-fire. Skip the click if the user is in the middle of
        // a text selection (mouseup with non-collapsed selection inside the
        // mark) — that path is for creating a NEW annotation overlapping an
        // existing one, not opening the rail.
        mark.addEventListener("click", (ev) => {
          const sel = window.getSelection();
          if (sel && !sel.isCollapsed) {
            const r = sel.getRangeAt(0);
            // If the live selection intersects this mark in any direction
            // (starts inside, ends inside, or spans across), the user is
            // selecting, not clicking. Bail. Range.intersectsNode catches
            // start-inside, end-inside, and fully-overlapping cases.
            if (r.toString().length > 0 && r.intersectsNode(mark)) {
              return;
            }
          }
          ev.stopPropagation();
          onMarkClick(ann.id);
        });
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
  chapterName,
  annotations: initialAnnotations,
}: Props) {
  const router = useRouter();
  const rootRef = useRef<HTMLDivElement | null>(null);
  const [popover, setPopover] = useState<PopoverState>(null);
  const [comment, setComment] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Local annotations state — seeded from the server prop, mutated optimistically
  // on save/update/delete. Avoids router.refresh() round-trips that would flash
  // the route's loading.tsx skeleton and reset scroll to the top of the article.
  const [annotations, setAnnotations] = useState<Annotation[]>(initialAnnotations);
  useEffect(() => {
    // Re-sync if the server-rendered prop changes (e.g. navigation between runs
    // or another tab edits the annotations).
    setAnnotations(initialAnnotations);
  }, [initialAnnotations]);

  // Rail state: closed by default. Opens via `A` keypress or clicking a mark.
  const [railOpen, setRailOpen] = useState(false);
  const [railFilter, setRailFilter] = useState<RailFilter>("open");
  const [focusedAnnotationId, setFocusedAnnotationId] = useState<string | null>(
    null,
  );

  // M24: timer ref for the stale-chip grace window. Cleared when a fresh
  // selection arrives, the operator clicks the stale chip, or the chip's
  // grace expires.
  const staleTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(() => {
    return () => {
      if (staleTimerRef.current) clearTimeout(staleTimerRef.current);
    };
  }, []);

  // Annotations to render as <mark> in the prose: open/orphan always, plus
  // resolved (dimmed). Deleted are skipped inside applyHighlights.
  const renderableAnnotations = useMemo(
    () =>
      [...annotations].filter(
        (a) =>
          a.status === "open" ||
          a.status === "orphan" ||
          a.status === "resolved",
      ),
    [annotations],
  );

  // Keep a ref of latest annotations so the mark click closure can resolve
  // status without itself depending on the prop (which would force rebuild).
  const annotationsRef = useRef<Annotation[]>(annotations);
  useEffect(() => {
    annotationsRef.current = annotations;
  }, [annotations]);

  // Click-on-mark handler — kept stable so rebuilds don't churn listeners.
  // Resolves the latest status via annotationsRef so the closure stays fresh.
  const onMarkClick = useCallback((id: string) => {
    const ann = annotationsRef.current.find((a) => a.id === id);
    if (!ann) return;
    setFocusedAnnotationId(id);
    setRailFilter(
      ann.status === "resolved"
        ? "resolved"
        : ann.status === "deleted"
          ? "deleted"
          : "open",
    );
    setRailOpen(true);
  }, []);

  useLayoutEffect(() => {
    const root = rootRef.current;
    if (!root) return;
    applyHighlights(root, renderableAnnotations, onMarkClick);
  }, [renderableAnnotations, content, onMarkClick]);

  const onMouseUp = useCallback(() => {
    const root = rootRef.current;
    if (!root) return;
    requestAnimationFrame(() => {
      const anchor = captureSelection(root);
      if (!anchor) {
        // No live selection. If a chip was on screen, transition it to a
        // stale-but-recoverable state for 3s instead of vanishing silently.
        // Composer stays put (operator already committed to commenting).
        if (popover?.kind === "chip") {
          if (staleTimerRef.current) clearTimeout(staleTimerRef.current);
          const staleAnchor = popover.anchor;
          const staleRect = popover.rect;
          setPopover({
            kind: "stale-chip",
            anchor: staleAnchor,
            rect: staleRect,
          });
          staleTimerRef.current = setTimeout(() => {
            // After grace expires, drop the stale chip. Guard: only clear
            // if we're still in the stale state (operator didn't already
            // start a new selection or click).
            setPopover((cur) =>
              cur?.kind === "stale-chip" && cur.anchor === staleAnchor
                ? null
                : cur,
            );
            staleTimerRef.current = null;
          }, STALE_CHIP_MS);
          return;
        }
        if (popover?.kind !== "composer") setPopover(null);
        return;
      }
      // Fresh selection — cancel any pending stale grace timer.
      if (staleTimerRef.current) {
        clearTimeout(staleTimerRef.current);
        staleTimerRef.current = null;
      }
      const sel = window.getSelection();
      if (!sel || sel.rangeCount === 0) return;
      const rect = sel.getRangeAt(0).getBoundingClientRect();
      setPopover({ kind: "chip", anchor, rect });
    });
  }, [popover]);

  // M24: window-level mousedown listener for the stale-chip transition.
  // The article's onMouseUp only fires when the press starts inside it; if
  // the operator clicks anywhere else (sidebar, body, blank space) while a
  // chip is up, we won't otherwise hear about it. Listen on mousedown so
  // the transition fires as the live selection collapses, not after.
  useEffect(() => {
    if (popover?.kind !== "chip") return;
    function onDocMouseDown(e: MouseEvent) {
      const root = rootRef.current;
      const target = e.target as Node | null;
      // Click inside the article: leave it to onMouseUp logic (a fresh
      // selection or genuine collapse-inside-article is handled there).
      if (root && target && root.contains(target)) return;
      // Click on the chip itself: it's the consumer button — let its onClick
      // run instead of pre-empting it here.
      if (
        target instanceof Element &&
        target.closest('[data-testid="annotation-chip"]')
      ) {
        return;
      }
      // Snapshot prior anchor + rect into a stale chip; start the 3s timer.
      const cur = popover;
      if (!cur || cur.kind !== "chip") return;
      if (staleTimerRef.current) clearTimeout(staleTimerRef.current);
      const staleAnchor = cur.anchor;
      const staleRect = cur.rect;
      setPopover({
        kind: "stale-chip",
        anchor: staleAnchor,
        rect: staleRect,
      });
      staleTimerRef.current = setTimeout(() => {
        setPopover((p) =>
          p?.kind === "stale-chip" && p.anchor === staleAnchor ? null : p,
        );
        staleTimerRef.current = null;
      }, STALE_CHIP_MS);
    }
    document.addEventListener("mousedown", onDocMouseDown);
    return () => document.removeEventListener("mousedown", onDocMouseDown);
  }, [popover]);

  // Restore a stale anchor by re-creating a Range that spans char_start..char_end
  // within rootRef.current. Used when the operator clicks the stale chip after
  // the live selection collapsed. This walks text nodes summing lengths until
  // it finds nodes that contain the anchor's offsets — same shape as the
  // `applyHighlights` walker. Returns the new bounding rect for popover
  // positioning, or null if the offsets don't resolve (e.g. content shifted).
  const restoreSelection = useCallback(
    (anchor: AnnotationAnchor): DOMRect | null => {
      const root = rootRef.current;
      if (!root) return null;
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      let offset = 0;
      let startNode: Text | null = null;
      let startOffsetInNode = 0;
      let endNode: Text | null = null;
      let endOffsetInNode = 0;
      let cur: Node | null = walker.nextNode();
      while (cur) {
        const t = cur as Text;
        const len = t.data.length;
        if (
          startNode === null &&
          anchor.charStart >= offset &&
          anchor.charStart <= offset + len
        ) {
          startNode = t;
          startOffsetInNode = anchor.charStart - offset;
        }
        if (
          anchor.charEnd >= offset &&
          anchor.charEnd <= offset + len
        ) {
          endNode = t;
          endOffsetInNode = anchor.charEnd - offset;
          break;
        }
        offset += len;
        cur = walker.nextNode();
      }
      if (!startNode || !endNode) return null;
      try {
        const range = document.createRange();
        range.setStart(startNode, startOffsetInNode);
        range.setEnd(endNode, endOffsetInNode);
        const sel = window.getSelection();
        if (sel) {
          sel.removeAllRanges();
          sel.addRange(range);
        }
        return range.getBoundingClientRect();
      } catch {
        return null;
      }
    },
    [],
  );

  // Document-level keyboard handlers:
  // - Esc: clear composer/chip first; if none, close the rail.
  // - 'a' / 'A': toggle rail UNLESS the user is typing in an input/textarea/
  //   contenteditable. We deliberately don't gate on focus inside the rail
  //   itself for the open path — but DO gate so the rail's own textarea (in
  //   edit mode) doesn't toggle when the operator types 'a'.
  useEffect(() => {
    function isTypingTarget(t: EventTarget | null): boolean {
      if (!(t instanceof HTMLElement)) return false;
      const tag = t.tagName;
      if (tag === "INPUT" || tag === "TEXTAREA") return true;
      if (t.isContentEditable) return true;
      return false;
    }
    function onKey(e: KeyboardEvent) {
      if (e.key === "Escape") {
        if (popover) {
          setPopover(null);
          setComment("");
          setError(null);
          return;
        }
        if (railOpen) {
          setRailOpen(false);
          setFocusedAnnotationId(null);
          return;
        }
        return;
      }
      if (e.key === "a" || e.key === "A") {
        if (e.ctrlKey || e.metaKey || e.altKey) return;
        if (isTypingTarget(e.target)) return;
        e.preventDefault();
        setRailOpen((v) => !v);
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [popover, railOpen]);

  async function save() {
    if (!popover || popover.kind !== "composer") return;
    const trimmed = comment.trim();
    if (!trimmed) return;

    setSaving(true);
    setError(null);
    // M22: author_email defaults to (auth.jwt() ->> 'email') at the column
    // level, so we deliberately don't pass it. The RLS policy enforces that
    // it matches the caller's JWT email, blocking impersonation.
    const { data: inserted, error: insertErr } = await browserSupabase
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
        status: "open",
      })
      .select()
      .single();
    setSaving(false);
    if (insertErr) {
      setError(insertErr.message);
      return;
    }
    setPopover(null);
    setComment("");
    if (inserted) {
      setAnnotations((prev) => [...prev, inserted as Annotation]);
    }
  }

  function onComposerKey(e: React.KeyboardEvent) {
    // Enter saves; Shift+Enter inserts a newline (default textarea behaviour).
    // Ctrl/Cmd+Enter still works as the historical save shortcut.
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      void save();
    }
  }

  function popoverPos(rect: DOMRect): { top: number; left: number } {
    const pad = 8;
    const top = window.scrollY + rect.top - 40 - pad;
    const left = window.scrollX + rect.left + rect.width / 2;
    return { top, left };
  }

  // Map an annotation status to its rail bucket. Mirror of bucketOf in the
  // rail — duplicated here to keep the rail's bucket logic encapsulated.
  function statusToBucket(s: Annotation["status"]): RailFilter {
    if (s === "resolved") return "resolved";
    if (s === "deleted") return "deleted";
    return "open";
  }

  // Rail handlers — PATCH the annotation row, then router.refresh() to pull
  // the new state. Same pattern as M6's insert; M14 will swap to optimistic.
  // If the mutated annotation was the focused one and its new status moves
  // it out of the current rail filter, clear focus to avoid a phantom focus
  // ring on a re-rendered row that the user can't see.
  // M24: throw on failure so the rail can render an inline retry affordance
  // per-row. The rail catches and tracks per-id error state.
  const handleUpdate = useCallback(
    async (id: string, patch: Partial<Annotation>) => {
      const { error: updErr } = await browserSupabase
        .from("annotations")
        .update(patch)
        .eq("id", id);
      if (updErr) {
        throw new Error(updErr.message);
      }
      if (
        id === focusedAnnotationId &&
        patch.status &&
        statusToBucket(patch.status) !== railFilter
      ) {
        setFocusedAnnotationId(null);
      }
      setAnnotations((prev) =>
        prev.map((a) => (a.id === id ? { ...a, ...patch } : a)),
      );
    },
    [focusedAnnotationId, railFilter],
  );

  const handleDelete = useCallback(
    async (id: string) => {
      const { error: delErr } = await browserSupabase
        .from("annotations")
        .update({ status: "deleted" })
        .eq("id", id);
      if (delErr) {
        throw new Error(delErr.message);
      }
      if (id === focusedAnnotationId && railFilter !== "deleted") {
        setFocusedAnnotationId(null);
      }
      setAnnotations((prev) =>
        prev.map((a) => (a.id === id ? { ...a, status: "deleted" } : a)),
      );
    },
    [focusedAnnotationId, railFilter],
  );

  // Scroll prose to a specific highlight when its rail row is clicked.
  // Marks for deleted annotations don't exist in the DOM, so this is a no-op
  // when filter='deleted' — that's fine, scroll-to has no meaning there.
  const onScrollToHighlight = useCallback((id: string) => {
    const root = rootRef.current;
    if (!root) return;
    const mark = root.querySelector(
      `mark[data-annotation-id="${id}"]`,
    ) as HTMLElement | null;
    if (mark) {
      mark.scrollIntoView({ block: "center", behavior: "smooth" });
    }
  }, []);

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

      {/* M24: stale chip — operator drag-selected then clicked away. We keep
          the chip on screen for ~3s with a subtle visual cue (dimmed +
          extended label) so the prior selection isn't silently lost. Click
          to restore the prior selection and open the composer. */}
      {popover?.kind === "stale-chip" ? (
        <button
          type="button"
          onMouseDown={(e) => {
            e.preventDefault();
          }}
          onClick={() => {
            // Cancel the grace timer first — we're about to consume the chip.
            if (staleTimerRef.current) {
              clearTimeout(staleTimerRef.current);
              staleTimerRef.current = null;
            }
            const restoredRect = restoreSelection(popover.anchor);
            setPopover({
              kind: "composer",
              anchor: popover.anchor,
              rect: restoredRect ?? popover.rect,
            });
          }}
          className="absolute z-50 -translate-x-1/2 -translate-y-full bg-[#1A1A1A]/60 text-white text-xs px-3 py-1.5 rounded-full shadow-md hover:bg-[#1A1A1A]/80 transition-colors"
          style={popoverPos(popover.rect)}
          data-testid="annotation-chip-stale"
          title="click here to comment on the previous selection"
        >
          Comment on previous selection
        </button>
      ) : null}

      {popover?.kind === "composer" ? (
        <>
          <div
            className="fixed inset-0 z-40 bg-[#1A1A1A]/20 backdrop-blur-[2px]"
            onMouseDown={() => {
              setPopover(null);
              setComment("");
              setError(null);
            }}
            aria-hidden
          />
          <div
            className="fixed z-50 top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 bg-white border border-[#E5E5E0] rounded-md shadow-xl p-5 w-[420px] max-w-[calc(100vw-2rem)]"
            data-testid="annotation-composer"
          >
            <div className="text-sm font-serif italic text-[#6B6B6B] border-l-2 border-[#FFE38A] pl-3">
              &ldquo;{truncate(popover.anchor.quote, 120)}&rdquo;
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
          <div className="mt-2 text-[11px] text-[#7A7A72]">
            Enter to save · Shift+Enter for a newline · Esc to cancel
          </div>
          </div>
        </>
      ) : null}

      {railOpen ? (
        <AnnotationRail
          annotations={annotations}
          filter={railFilter}
          onFilterChange={setRailFilter}
          onUpdate={handleUpdate}
          onDelete={handleDelete}
          onClose={() => {
            setRailOpen(false);
            setFocusedAnnotationId(null);
          }}
          chapterName={chapterName}
          highlightId={focusedAnnotationId}
          onScrollToHighlight={onScrollToHighlight}
        />
      ) : null}
    </>
  );
}
