"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useRouter, usePathname } from "next/navigation";
import { browserSupabase } from "@/lib/supabase-browser";
import { ARTIFACT_ORDER, ARTIFACT_SLUGS } from "@/lib/types";
import { truncate } from "@/lib/format";

// M19 — Ctrl+K command palette. Mounted once at layout level. Hotkey listens
// at window scope and intentionally does NOT respect input focus: Ctrl+K is
// a chord the operator wants to work even from inside the annotation
// composer. Esc closes; Up/Down moves; Enter chooses.

type CustomerRow = { id: string; slug: string; name: string };
type AnnotationRow = { id: string; comment: string; quote: string };

type Result =
  | {
      kind: "customer";
      id: string;
      label: string;
      sublabel: string;
      action: { type: "navigate"; href: string };
    }
  | {
      kind: "artifact";
      id: string;
      label: string;
      sublabel: string;
      action: { type: "navigate"; href: string };
    }
  | {
      kind: "action";
      id: string;
      label: string;
      sublabel: string;
      action: { type: "copy"; text: string };
    }
  | {
      kind: "annotation";
      id: string;
      label: string;
      sublabel: string;
      action: { type: "scroll-to-annotation"; annotationId: string };
    };

// Minimal subsequence fuzzy match: each query char (lowercased) must appear
// in order in the candidate. Score = density (smaller window = higher score)
// + bonus for prefix match. Empty query returns the candidate untouched
// with score 0 so initial render shows the first N items.
function fuzzyScore(query: string, candidate: string): number | null {
  if (query.length === 0) return 0;
  const q = query.toLowerCase();
  const c = candidate.toLowerCase();
  if (c.startsWith(q)) return 1000 - q.length;
  let qi = 0;
  let firstHit = -1;
  let lastHit = -1;
  for (let i = 0; i < c.length && qi < q.length; i++) {
    if (c[i] === q[qi]) {
      if (firstHit === -1) firstHit = i;
      lastHit = i;
      qi++;
    }
  }
  if (qi !== q.length) return null;
  const span = lastHit - firstHit + 1;
  return 500 - span - firstHit;
}

function rank<T>(items: T[], query: string, key: (t: T) => string): T[] {
  if (query.length === 0) return items;
  const scored: Array<{ item: T; score: number }> = [];
  for (const it of items) {
    const s = fuzzyScore(query, key(it));
    if (s !== null) scored.push({ item: it, score: s });
  }
  scored.sort((a, b) => b.score - a.score);
  return scored.map((s) => s.item);
}

const ACTIONS = (slug: string | null) =>
  slug
    ? [
        {
          id: "act-refine",
          label: `Copy /base-agent refine ${slug}`,
          text: `/base-agent refine ${slug}`,
        },
        {
          id: "act-verify",
          label: `Copy /base-agent verify ${slug}`,
          text: `/base-agent verify ${slug}`,
        },
        {
          id: "act-review",
          label: "Copy /base-agent review-feedback",
          text: "/base-agent review-feedback",
        },
      ]
    : [
        {
          id: "act-review",
          label: "Copy /base-agent review-feedback",
          text: "/base-agent review-feedback",
        },
      ];

export function CommandPalette() {
  const router = useRouter();
  const pathname = usePathname();
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState(0);
  const [customers, setCustomers] = useState<CustomerRow[]>([]);
  const [annotations, setAnnotations] = useState<AnnotationRow[]>([]);
  const inputRef = useRef<HTMLInputElement | null>(null);

  // Parse current route to extract context: customer slug + (optional)
  // run id + (optional) artifact slug. Path patterns we recognise:
  //   /c/{slug}
  //   /c/{slug}/{artifact}
  //   /c/{slug}/run/{runId}
  //   /c/{slug}/run/{runId}/{artifact}
  //   /c/{slug}/inspect
  const ctx = useMemo(() => {
    if (!pathname) return { slug: null as string | null, runId: null as string | null, artifact: null as string | null };
    const segs = pathname.split("/").filter(Boolean);
    let slug: string | null = null;
    let runId: string | null = null;
    let artifact: string | null = null;
    if (segs[0] === "c" && segs[1]) {
      slug = segs[1];
      if (segs[2] === "run" && segs[3]) {
        runId = segs[3];
        if (segs[4] && ARTIFACT_SLUGS.has(segs[4])) artifact = segs[4];
      } else if (segs[2] && ARTIFACT_SLUGS.has(segs[2])) {
        artifact = segs[2];
      }
    }
    return { slug, runId, artifact };
  }, [pathname]);

  // Hotkey: Ctrl+K / Cmd+K toggles. Esc closes. Listens at window so it
  // works regardless of focus. Re-checks localStorage at keypress time so
  // the listener can attach unconditionally on mount (no race against the
  // async useEffect that resolves `hasName`) while still refusing to open
  // the palette before the operator name gate is satisfied.
  useEffect(() => {
    function nameSet(): boolean {
      try {
        const n = window.localStorage.getItem("operatorName");
        return typeof n === "string" && n.trim().length > 0;
      } catch {
        return false;
      }
    }
    function onKey(e: KeyboardEvent) {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "k") {
        if (!nameSet()) return;
        e.preventDefault();
        setOpen((v) => !v);
        return;
      }
      if (e.key === "Escape" && open) {
        e.preventDefault();
        setOpen(false);
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open]);

  // On open: focus input + reset state.
  useEffect(() => {
    if (!open) return;
    setQuery("");
    setSelected(0);
    // Defer to next tick so the input is mounted.
    const t = setTimeout(() => {
      inputRef.current?.focus();
    }, 0);
    return () => clearTimeout(t);
  }, [open]);

  // Load customers once when the palette first opens. Cache for the session.
  useEffect(() => {
    if (!open) return;
    if (customers.length > 0) return;
    let cancelled = false;
    (async () => {
      const { data, error } = await browserSupabase
        .from("customers")
        .select("id, slug, name")
        .order("created_at", { ascending: false });
      if (cancelled) return;
      if (!error && data) setCustomers(data as CustomerRow[]);
    })();
    return () => {
      cancelled = true;
    };
  }, [open, customers.length]);

  // Load annotations for the current artifact when palette opens AND we're
  // in reading mode. Re-fetches whenever the (slug, runId, artifact) triple
  // changes so navigating to a new chapter without closing the palette gets
  // fresh data on next open.
  useEffect(() => {
    if (!open) return;
    if (!ctx.artifact || !ctx.slug) {
      setAnnotations([]);
      return;
    }
    let cancelled = false;
    (async () => {
      // Resolve run_id: either the explicit one in the URL or the latest
      // for this customer. Each await may resolve after the operator has
      // navigated to a different artifact, so we guard between hops to
      // avoid setAnnotations() landing on a stale render.
      let runId = ctx.runId;
      if (!runId) {
        const { data: cRow } = await browserSupabase
          .from("customers")
          .select("id")
          .eq("slug", ctx.slug)
          .maybeSingle();
        if (cancelled) return;
        if (cRow) {
          const { data: rRow } = await browserSupabase
            .from("runs")
            .select("id")
            .eq("customer_id", (cRow as { id: string }).id)
            .order("started_at", { ascending: false })
            .limit(1)
            .maybeSingle();
          if (cancelled) return;
          runId = (rRow as { id: string } | null)?.id ?? null;
        }
      }
      if (!runId) return;
      const { data, error } = await browserSupabase
        .from("annotations")
        .select("id, comment, quote")
        .eq("run_id", runId)
        .eq("artifact_name", ctx.artifact)
        .neq("status", "deleted");
      if (cancelled) return;
      if (!error && data) setAnnotations(data as AnnotationRow[]);
    })();
    return () => {
      cancelled = true;
    };
  }, [open, ctx.slug, ctx.runId, ctx.artifact]);

  // Build the result list in fixed category order.
  const results = useMemo<Result[]>(() => {
    const out: Result[] = [];

    // 1. Customers — always available.
    const matchedCustomers = rank(customers, query, (c) => `${c.name} ${c.slug}`).slice(0, 6);
    for (const c of matchedCustomers) {
      out.push({
        kind: "customer",
        id: `cust:${c.id}`,
        label: c.name,
        sublabel: c.slug,
        action: { type: "navigate", href: `/c/${c.slug}` },
      });
    }

    // 2. Artifacts — only when we have a customer in scope.
    if (ctx.slug) {
      const items = ARTIFACT_ORDER.map((a) => ({
        slug: a.artifact,
        name: a.name,
        href: ctx.runId
          ? `/c/${ctx.slug}/run/${ctx.runId}/${a.artifact}`
          : `/c/${ctx.slug}/${a.artifact}`,
      }));
      const matched = rank(items, query, (i) => i.name).slice(0, 6);
      for (const a of matched) {
        out.push({
          kind: "artifact",
          id: `art:${a.slug}`,
          label: a.name,
          sublabel: ctx.slug,
          action: { type: "navigate", href: a.href },
        });
      }
    }

    // 3. Actions — fixed, always available.
    const actions = ACTIONS(ctx.slug);
    const matchedActions = rank(actions, query, (a) => a.label);
    for (const a of matchedActions) {
      out.push({
        kind: "action",
        id: a.id,
        label: a.label,
        sublabel: "copies to clipboard",
        action: { type: "copy", text: a.text },
      });
    }

    // 4. Annotations — only in reading mode.
    if (ctx.artifact && annotations.length > 0) {
      const matched = rank(annotations, query, (a) => `${a.comment} ${a.quote}`).slice(0, 8);
      for (const a of matched) {
        out.push({
          kind: "annotation",
          id: `ann:${a.id}`,
          label: truncate(a.comment, 80),
          sublabel: `"${truncate(a.quote, 60)}"`,
          action: { type: "scroll-to-annotation", annotationId: a.id },
        });
      }
    }

    return out;
  }, [customers, query, ctx.slug, ctx.runId, ctx.artifact, annotations]);

  // Clamp selection when results change.
  useEffect(() => {
    if (selected >= results.length) setSelected(0);
  }, [results.length, selected]);

  const choose = useCallback(
    async (r: Result) => {
      if (r.action.type === "navigate") {
        setOpen(false);
        router.push(r.action.href);
        return;
      }
      if (r.action.type === "copy") {
        try {
          await navigator.clipboard.writeText(r.action.text);
        } catch {
          // ignore clipboard errors silently — palette closes either way
        }
        setOpen(false);
        return;
      }
      if (r.action.type === "scroll-to-annotation") {
        const annotationId = r.action.annotationId;
        setOpen(false);
        // Defer one frame so the overlay unmounts before we try to focus.
        requestAnimationFrame(() => {
          const mark = document.querySelector(
            `mark[data-annotation-id="${annotationId}"]`,
          ) as HTMLElement | null;
          if (mark) {
            mark.scrollIntoView({ block: "center", behavior: "smooth" });
            // Click opens the rail focused on this annotation.
            mark.click();
          }
        });
      }
    },
    [router],
  );

  function onKeyDown(e: React.KeyboardEvent<HTMLDivElement>) {
    if (e.key === "ArrowDown") {
      e.preventDefault();
      setSelected((s) => (results.length === 0 ? 0 : (s + 1) % results.length));
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      setSelected((s) =>
        results.length === 0 ? 0 : (s - 1 + results.length) % results.length,
      );
    } else if (e.key === "Enter") {
      e.preventDefault();
      const r = results[selected];
      if (r) void choose(r);
    } else if (e.key === "Escape") {
      e.preventDefault();
      setOpen(false);
    }
  }

  if (!open) return null;

  return (
    <div
      className="fixed inset-0 z-50 flex items-start justify-center pt-[12vh] bg-black/30"
      onMouseDown={(e) => {
        // Click on dim backdrop = close. Inside the panel = ignore.
        if (e.target === e.currentTarget) setOpen(false);
      }}
      data-testid="command-palette"
      onKeyDown={onKeyDown}
      role="dialog"
      aria-modal="true"
    >
      <div className="w-[640px] max-w-[92vw] bg-white border border-[#E5E5E0] rounded-md shadow-2xl overflow-hidden">
        <div className="px-4 py-3 border-b border-[#E5E5E0]">
          <input
            ref={inputRef}
            type="text"
            placeholder="Search customers, artifacts, actions, annotations…"
            value={query}
            onChange={(e) => {
              setQuery(e.target.value);
              setSelected(0);
            }}
            className="w-full bg-transparent text-[15px] text-[#1A1A1A] placeholder-[#9B9B95] focus:outline-none"
            data-testid="command-palette-input"
          />
        </div>

        <ul
          className="max-h-[60vh] overflow-y-auto"
          data-testid="command-palette-list"
        >
          {results.length === 0 ? (
            <li className="px-4 py-6 text-sm text-[#9B9B95]">No results</li>
          ) : (
            results.map((r, i) => {
              const active = i === selected;
              return (
                <li
                  key={r.id}
                  className={`px-4 py-2.5 cursor-pointer flex items-baseline gap-3 border-b border-[#F0F0EC] last:border-b-0 ${
                    active ? "bg-[#FAFAF7]" : ""
                  }`}
                  onMouseEnter={() => setSelected(i)}
                  onMouseDown={(e) => {
                    e.preventDefault();
                    void choose(r);
                  }}
                  data-testid="command-palette-item"
                  data-kind={r.kind}
                  data-active={active ? "true" : undefined}
                >
                  <span className="text-[10px] uppercase tracking-widest text-[#9B9B95] w-[72px] shrink-0">
                    {r.kind}
                  </span>
                  <span className="flex-1 text-sm text-[#1A1A1A] truncate">
                    {r.label}
                  </span>
                  <span className="text-xs text-[#6B6B6B] truncate max-w-[220px]">
                    {r.sublabel}
                  </span>
                </li>
              );
            })
          )}
        </ul>

        <div className="px-4 py-2 border-t border-[#E5E5E0] flex items-center gap-4 text-[10px] text-[#9B9B95]">
          <span>↑↓ navigate</span>
          <span>↵ select</span>
          <span>Esc close</span>
        </div>
      </div>
    </div>
  );
}
