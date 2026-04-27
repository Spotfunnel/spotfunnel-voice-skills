// Server-side helper: load all runs for a customer plus a label string for
// any run that was refined from another, formatted like "DD MMM HH:mm" so
// it's compact in the dropdown.
//
// Used by the customer page (/c/[slug]) and the run-scoped page
// (/c/[slug]/run/[runId]) so both render the same RunHistorySwitcher data.

import type { RunHistoryEntry } from "@/components/RunHistorySwitcher";

type SupabaseClient = {
  // narrow shape to avoid importing the heavy SupabaseClient type
  from: (table: string) => {
    select: (cols: string) => {
      eq: (col: string, val: string) => {
        order: (col: string, opts: { ascending: boolean }) => Promise<{
          data: RunRow[] | null;
          error: { message: string } | null;
        }>;
      };
    };
  };
};

type RunRow = {
  id: string;
  started_at: string;
  stage_complete: number;
  refined_from_run_id: string | null;
};

function shortStamp(iso: string): string {
  const d = new Date(iso);
  const day = d.getUTCDate();
  const month = d.toLocaleString("en-GB", { month: "short", timeZone: "UTC" });
  const hh = String(d.getUTCHours()).padStart(2, "0");
  const mm = String(d.getUTCMinutes()).padStart(2, "0");
  return `${day} ${month} ${hh}:${mm}`;
}

export async function loadRunHistory(
  supabase: SupabaseClient,
  customerId: string,
): Promise<RunHistoryEntry[]> {
  const { data, error } = await supabase
    .from("runs")
    .select("id, started_at, stage_complete, refined_from_run_id")
    .eq("customer_id", customerId)
    .order("started_at", { ascending: false });

  if (error) {
    throw new Error(`Failed to load run history: ${error.message}`);
  }
  const rows = (data ?? []) as RunRow[];
  const byId = new Map<string, RunRow>(rows.map((r) => [r.id, r]));
  return rows.map((r) => {
    let parentLabel: string | null = null;
    if (r.refined_from_run_id) {
      const parent = byId.get(r.refined_from_run_id);
      parentLabel = parent ? shortStamp(parent.started_at) : "earlier run";
    }
    return {
      id: r.id,
      started_at: r.started_at,
      stage_complete: r.stage_complete,
      refined_from_run_id: r.refined_from_run_id,
      parentLabel,
    };
  });
}
