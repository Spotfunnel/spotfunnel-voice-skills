"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import type { Annotation } from "@/lib/types";
import { relativeTime, truncate } from "@/lib/format";

export type RailFilter = "open" | "resolved" | "deleted";

type Props = {
  annotations: Annotation[]; // ALL annotations on this artifact, all statuses
  filter: RailFilter;
  onFilterChange: (f: RailFilter) => void;
  onUpdate: (id: string, patch: Partial<Annotation>) => Promise<void>;
  onDelete: (id: string) => Promise<void>; // soft-delete (status='deleted')
  onClose: () => void;
  chapterName: string;
  highlightId: string | null;
  onScrollToHighlight: (id: string) => void;
};

// Map an annotation's stored status to a rail filter bucket. "orphan" rides
// alongside "open" because the rail's user-facing buckets are the operator's
// mental model (open / resolved / deleted), not the storage model.
function bucketOf(a: Annotation): RailFilter {
  if (a.status === "resolved") return "resolved";
  if (a.status === "deleted") return "deleted";
  return "open";
}

export function AnnotationRail({
  annotations,
  filter,
  onFilterChange,
  onUpdate,
  onDelete,
  onClose,
  chapterName,
  highlightId,
  onScrollToHighlight,
}: Props) {
  // Track in-flight per-action so the UI disables only the row being mutated.
  const [busyId, setBusyId] = useState<string | null>(null);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [editDraft, setEditDraft] = useState("");

  // Auto-enter edit mode requested via highlightId? Not in M7 — clicking the
  // mark just focuses the row. Edit is an explicit action.

  const filtered = useMemo(
    () =>
      annotations
        .filter((a) => bucketOf(a) === filter)
        .sort((x, y) => x.char_start - y.char_start),
    [annotations, filter],
  );

  // Buckets present so we can decide whether to render the filter pills.
  const buckets = useMemo(() => {
    const set = new Set<RailFilter>();
    for (const a of annotations) set.add(bucketOf(a));
    return set;
  }, [annotations]);

  // Show the pill row whenever there's any annotation at all AND either
  // (a) the current bucket is empty (so the operator needs a way out), or
  // (b) there's at least one annotation in a non-current bucket. This
  // prevents stranding on an empty bucket — e.g. operator deletes the last
  // open annotation while filter='deleted' is selected.
  const showPills = useMemo(() => {
    if (annotations.length === 0) return false;
    if (filtered.length === 0) return true;
    for (const b of buckets) if (b !== filter) return true;
    return false;
  }, [annotations.length, filtered.length, buckets, filter]);

  // Scroll the focused item into view whenever highlightId changes.
  const itemRefs = useRef<Map<string, HTMLLIElement>>(new Map());
  useEffect(() => {
    if (!highlightId) return;
    const el = itemRefs.current.get(highlightId);
    if (el) el.scrollIntoView({ block: "nearest", behavior: "smooth" });
  }, [highlightId]);

  function startEdit(a: Annotation) {
    setEditingId(a.id);
    setEditDraft(a.comment);
  }

  function cancelEdit() {
    setEditingId(null);
    setEditDraft("");
  }

  async function saveEdit(a: Annotation) {
    const trimmed = editDraft.trim();
    if (!trimmed || trimmed === a.comment) {
      cancelEdit();
      return;
    }
    setBusyId(a.id);
    try {
      await onUpdate(a.id, { comment: trimmed });
      cancelEdit();
    } finally {
      setBusyId(null);
    }
  }

  async function resolve(a: Annotation) {
    setBusyId(a.id);
    try {
      await onUpdate(a.id, { status: "resolved" });
    } finally {
      setBusyId(null);
    }
  }

  async function reopen(a: Annotation) {
    setBusyId(a.id);
    try {
      await onUpdate(a.id, { status: "open" });
    } finally {
      setBusyId(null);
    }
  }

  async function softDelete(a: Annotation) {
    setBusyId(a.id);
    try {
      await onDelete(a.id);
    } finally {
      setBusyId(null);
    }
  }

  async function restore(a: Annotation) {
    setBusyId(a.id);
    try {
      await onUpdate(a.id, { status: "open" });
    } finally {
      setBusyId(null);
    }
  }

  return (
    <aside
      className="fixed right-0 top-0 bottom-0 w-[360px] bg-white border-l border-[#E5E5E0] flex flex-col z-40"
      data-testid="annotation-rail"
      aria-label="Annotations"
    >
      {/* Header */}
      <div className="px-5 py-4 border-b border-[#E5E5E0] flex items-start justify-between gap-2">
        <div className="text-[11px] uppercase tracking-[0.12em] text-[#6B6B6B]">
          Annotations on {chapterName}
          <span className="mx-1.5 text-[#C0C0BA]">·</span>
          <span data-testid="annotation-rail-count">{filtered.length}</span>
        </div>
        <button
          type="button"
          onClick={onClose}
          aria-label="Close annotations rail"
          className="text-[#6B6B6B] hover:text-[#1A1A1A] -mt-1 -mr-1 px-1.5 leading-none"
          data-testid="annotation-rail-close"
        >
          ×
        </button>
      </div>

      {/* Body — scrollable list */}
      <ul className="flex-1 overflow-y-auto" data-testid="annotation-rail-list">
        {filtered.length === 0 ? (
          <li className="px-5 py-6 text-sm text-[#9B9B95]">
            No {filter} annotations.
          </li>
        ) : (
          filtered.map((a) => {
            const isFocused = a.id === highlightId;
            const isEditing = editingId === a.id;
            const isBusy = busyId === a.id;
            return (
              <li
                key={a.id}
                ref={(el) => {
                  if (el) itemRefs.current.set(a.id, el);
                  else itemRefs.current.delete(a.id);
                }}
                className={`px-5 py-4 border-b border-[#F0F0EC] cursor-pointer ${
                  isFocused ? "bg-[#FFF8E0]" : "hover:bg-[#FAFAF7]"
                }`}
                onClick={() => onScrollToHighlight(a.id)}
                data-testid="annotation-rail-item"
                data-annotation-id={a.id}
              >
                {/* Quote */}
                <div className="text-xs font-serif italic text-[#6B6B6B] border-l-2 border-[#FFE38A] pl-2">
                  &ldquo;{truncate(a.quote, 100)}&rdquo;
                </div>

                {/* Comment — text or textarea */}
                {isEditing ? (
                  <textarea
                    autoFocus
                    value={editDraft}
                    onChange={(e) => setEditDraft(e.target.value)}
                    onKeyDown={(e) => {
                      if ((e.ctrlKey || e.metaKey) && e.key === "Enter") {
                        e.preventDefault();
                        void saveEdit(a);
                      } else if (e.key === "Escape") {
                        e.preventDefault();
                        e.stopPropagation();
                        cancelEdit();
                      }
                    }}
                    onClick={(e) => e.stopPropagation()}
                    rows={3}
                    className="mt-2 w-full border border-[#E5E5E0] rounded px-2 py-1.5 text-sm text-[#1A1A1A] focus:outline-none focus:border-[#3B5BDB] resize-none"
                    data-testid="annotation-rail-edit-textarea"
                  />
                ) : (
                  <div className="mt-2 text-sm text-[#1A1A1A] whitespace-pre-wrap">
                    {a.comment}
                  </div>
                )}

                {/* Author + time */}
                <div className="mt-2 text-xs text-[#9B9B95]">
                  {a.author_name} · {relativeTime(a.created_at)}
                </div>

                {/* Actions row — only when this row's bucket matches filter,
                    so e.g. you can only "resolve" something that's currently
                    open. Edit-mode swaps the row to save/cancel. */}
                {bucketOf(a) === filter ? (
                  <div
                    className="mt-3 flex items-center gap-3 text-xs"
                    onClick={(e) => e.stopPropagation()}
                  >
                    {isEditing ? (
                      <>
                        <button
                          type="button"
                          onClick={() => void saveEdit(a)}
                          disabled={isBusy || !editDraft.trim()}
                          className="text-[#3B5BDB] hover:text-[#2F4DBF] disabled:opacity-50"
                          data-testid="annotation-rail-save"
                        >
                          save
                        </button>
                        <button
                          type="button"
                          onClick={cancelEdit}
                          className="text-[#6B6B6B] hover:text-[#1A1A1A]"
                          data-testid="annotation-rail-cancel"
                        >
                          cancel
                        </button>
                      </>
                    ) : (
                      <>
                        <button
                          type="button"
                          onClick={() => startEdit(a)}
                          disabled={isBusy}
                          className="text-[#6B6B6B] hover:text-[#1A1A1A] disabled:opacity-50"
                          data-testid="annotation-rail-edit"
                        >
                          edit
                        </button>
                        {filter === "open" ? (
                          <button
                            type="button"
                            onClick={() => void resolve(a)}
                            disabled={isBusy}
                            className="text-[#6B6B6B] hover:text-[#1A1A1A] disabled:opacity-50"
                            data-testid="annotation-rail-resolve"
                          >
                            resolve
                          </button>
                        ) : null}
                        {filter === "resolved" ? (
                          <button
                            type="button"
                            onClick={() => void reopen(a)}
                            disabled={isBusy}
                            className="text-[#6B6B6B] hover:text-[#1A1A1A] disabled:opacity-50"
                            data-testid="annotation-rail-reopen"
                          >
                            reopen
                          </button>
                        ) : null}
                        {filter === "deleted" ? (
                          <button
                            type="button"
                            onClick={() => void restore(a)}
                            disabled={isBusy}
                            className="text-[#6B6B6B] hover:text-[#1A1A1A] disabled:opacity-50"
                            data-testid="annotation-rail-restore"
                          >
                            restore
                          </button>
                        ) : (
                          <button
                            type="button"
                            onClick={() => void softDelete(a)}
                            disabled={isBusy}
                            className="text-[#6B6B6B] hover:text-[#1A1A1A] disabled:opacity-50"
                            data-testid="annotation-rail-delete"
                          >
                            delete
                          </button>
                        )}
                      </>
                    )}
                  </div>
                ) : null}
              </li>
            );
          })
        )}
      </ul>

      {/* Footer — filter pills, only when there's something to filter to. */}
      {showPills ? (
        <div
          className="px-5 py-3 border-t border-[#E5E5E0] flex items-center gap-2 text-xs"
          data-testid="annotation-rail-filters"
        >
          {(["open", "resolved", "deleted"] as RailFilter[]).map((f) => {
            const active = f === filter;
            return (
              <button
                key={f}
                type="button"
                onClick={() => onFilterChange(f)}
                className={`px-2.5 py-1 rounded-full transition-colors ${
                  active
                    ? "bg-[#1A1A1A] text-white"
                    : "text-[#6B6B6B] hover:text-[#1A1A1A] hover:bg-[#F0F0EC]"
                }`}
                data-testid={`annotation-rail-filter-${f}`}
              >
                {f}
              </button>
            );
          })}
        </div>
      ) : null}
    </aside>
  );
}
