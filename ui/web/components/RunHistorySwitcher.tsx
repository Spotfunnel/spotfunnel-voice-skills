"use client";

import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import { relativeTime } from "@/lib/format";

const TOTAL_STAGES = 11;

export type RunHistoryEntry = {
  id: string;
  started_at: string;
  stage_complete: number;
  refined_from_run_id: string | null;
  // Pre-computed parent label for the current run row when refined from
  // another run in this customer's history. Server resolves this so the
  // dropdown stays a passive Client Component.
  parentLabel?: string | null;
};

type Props = {
  slug: string;
  // Newest → oldest. The first entry is treated as the "latest"; clicking it
  // routes to the bare /c/{slug} page rather than /c/{slug}/run/{id}.
  runs: RunHistoryEntry[];
  // The run currently being viewed (may be null if customer has no runs).
  // Used to mark the active row in the dropdown.
  activeRunId: string | null;
};

export function RunHistorySwitcher({ slug, runs, activeRunId }: Props) {
  const [open, setOpen] = useState(false);
  const wrapperRef = useRef<HTMLDivElement | null>(null);

  // Close on outside click + Esc.
  useEffect(() => {
    if (!open) return;
    function onDocClick(e: MouseEvent) {
      if (!wrapperRef.current) return;
      if (!wrapperRef.current.contains(e.target as Node)) setOpen(false);
    }
    function onKey(e: KeyboardEvent) {
      if (e.key === "Escape") setOpen(false);
    }
    document.addEventListener("mousedown", onDocClick);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDocClick);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  if (runs.length === 0) {
    return (
      <div className="mt-2 text-sm text-[#6B6B6B]" data-testid="run-history">
        Run history (none)
      </div>
    );
  }

  return (
    <div
      ref={wrapperRef}
      className="mt-2 relative"
      data-testid="run-history"
    >
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        aria-expanded={open}
        aria-haspopup="listbox"
        className="text-sm text-[#6B6B6B] hover:text-[#1A1A1A] transition-colors"
        data-testid="run-history-toggle"
      >
        Run history {open ? "▴" : "▾"} ({runs.length})
      </button>

      {open ? (
        <ul
          role="listbox"
          className="absolute left-0 mt-2 w-[420px] max-h-[320px] overflow-y-auto bg-white border border-[#E5E5E0] rounded-md shadow-md z-30"
          data-testid="run-history-list"
        >
          {runs.map((r, i) => {
            const isLatest = i === 0;
            const href = isLatest ? `/c/${slug}` : `/c/${slug}/run/${r.id}`;
            const isActive = r.id === activeRunId;
            return (
              <li key={r.id}>
                <Link
                  href={href}
                  onClick={() => setOpen(false)}
                  className={`block px-4 py-3 border-b border-[#F0F0EC] last:border-b-0 hover:bg-[#FAFAF7] transition-colors ${
                    isActive ? "bg-[#FAFAF7]" : ""
                  }`}
                  data-testid="run-history-item"
                  data-run-id={r.id}
                >
                  <div className="text-sm text-[#1A1A1A]">
                    {relativeTime(r.started_at)}
                    {isLatest ? (
                      <span className="ml-2 text-[10px] uppercase tracking-widest text-[#6B6B6B]">
                        latest
                      </span>
                    ) : null}
                    {isActive && !isLatest ? (
                      <span className="ml-2 text-[10px] uppercase tracking-widest text-[#6B6B6B]">
                        viewing
                      </span>
                    ) : null}
                  </div>
                  <div className="mt-0.5 text-xs text-[#6B6B6B]">
                    stage {r.stage_complete}/{TOTAL_STAGES}
                    {r.parentLabel ? (
                      <span className="ml-2">↺ refined from {r.parentLabel}</span>
                    ) : null}
                  </div>
                </Link>
              </li>
            );
          })}
        </ul>
      ) : null}
    </div>
  );
}
