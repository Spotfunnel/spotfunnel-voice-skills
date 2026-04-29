import { getServerSupabase } from "@/lib/supabase-server";
import { CustomerCard } from "@/components/CustomerCard";
import { CommandPaletteHint } from "@/components/CommandPaletteHint";
import type { CustomerSummary, VerificationSummary } from "@/lib/types";

const TOTAL_STAGES = 11;
// Test-data slugs from earlier e2e/refine smoke runs. Hidden from the roster
// by default; still reachable by direct URL or via Ctrl+K palette.
const TEST_SLUG = /^(refine-|test-|test-stress-|test-customer-)/;

type RunRow = {
  id: string;
  customer_id: string;
  started_at: string;
  stage_complete: number;
};

// Subset of runs.state we read for the homepage strip — only the DID matters
// here. The strip on each customer card surfaces the latest run's claimed DID
// so operators can scan "who has a phone number wired?" at a glance.
type RunStateRow = {
  customer_id: string;
  started_at: string;
  state: { telnyx_did?: string; did?: string; [k: string]: unknown };
};

type AgentToolsCountRow = { customer_id: string };

function classify(
  latest: RunRow | undefined,
  summary: VerificationSummary | undefined,
): CustomerSummary["status"] {
  if (!latest) return "none";
  if (latest.stage_complete < TOTAL_STAGES) return "in-progress";
  if (!summary) return "none";
  const pass = (summary.pass as number | undefined) ?? 0;
  const fail = (summary.fail as number | undefined) ?? 0;
  const skip = (summary.skip as number | undefined) ?? 0;
  if (fail > 0) return "fail";
  if (skip > 0 && pass > 0) return "partial";
  if (pass > 0) return "pass";
  return "none";
}

export default async function Home() {
  const supabase = await getServerSupabase();
  const { data: rows, error } = await supabase
    .from("customers")
    .select("id, slug, name, created_at")
    .order("created_at", { ascending: false });
  if (error) throw new Error(`Failed to load customers: ${error.message}`);

  const customers = (rows ?? []).filter((c) => !TEST_SLUG.test(c.slug));
  const customerIds = customers.map((c) => c.id);

  let summaries: CustomerSummary[] = [];
  if (customerIds.length > 0) {
    const [runsRes, annRes, verRes, runsStateRes, toolsRes] = await Promise.all([
      supabase
        .from("runs")
        .select("id, customer_id, started_at, stage_complete")
        .in("customer_id", customerIds),
      supabase
        .from("annotations")
        .select("id, run_id")
        .eq("status", "open"),
      supabase
        .from("verifications")
        .select("run_id, summary, verified_at")
        .order("verified_at", { ascending: false }),
      // Latest run state per customer — driven via descending order so the
      // first entry per customer_id is the most recent. Used to surface the
      // claimed DID on the homepage card.
      supabase
        .from("runs")
        .select("customer_id, started_at, state")
        .in("customer_id", customerIds)
        .order("started_at", { ascending: false }),
      // Per-customer base-tools count. agent_tools rows are 1-per-tool — each
      // base-tools customer gets 2 (transfer + take-message). Existing per-
      // customer-server installs (Teleca, TelcoWorks) have zero rows here.
      supabase
        .from("agent_tools")
        .select("customer_id")
        .in("customer_id", customerIds),
    ]);

    if (runsRes.error)
      throw new Error(`Failed to load runs: ${runsRes.error.message}`);
    if (annRes.error)
      throw new Error(`Failed to load annotations: ${annRes.error.message}`);
    if (verRes.error)
      throw new Error(`Failed to load verifications: ${verRes.error.message}`);
    if (runsStateRes.error)
      throw new Error(`Failed to load run states: ${runsStateRes.error.message}`);
    if (toolsRes.error)
      throw new Error(`Failed to load agent_tools: ${toolsRes.error.message}`);

    const runs = (runsRes.data ?? []) as RunRow[];
    const runStates = (runsStateRes.data ?? []) as RunStateRow[];
    const toolsRows = (toolsRes.data ?? []) as AgentToolsCountRow[];

    // Map customer_id → DID from the latest run (first row wins because we
    // ordered desc above).
    const phoneByCustomer = new Map<string, string>();
    for (const r of runStates) {
      if (phoneByCustomer.has(r.customer_id)) continue;
      const did = r.state?.telnyx_did ?? r.state?.did ?? null;
      if (did && typeof did === "string") {
        phoneByCustomer.set(r.customer_id, did);
      } else {
        // Mark as "looked at, none found" so older runs don't override.
        phoneByCustomer.set(r.customer_id, "");
      }
    }

    // Map customer_id → tools_count.
    const toolsByCustomer = new Map<string, number>();
    for (const t of toolsRows) {
      toolsByCustomer.set(t.customer_id, (toolsByCustomer.get(t.customer_id) ?? 0) + 1);
    }
    const customerRuns = new Map<string, RunRow[]>();
    for (const r of runs) {
      const list = customerRuns.get(r.customer_id) ?? [];
      list.push(r);
      customerRuns.set(r.customer_id, list);
    }
    for (const list of customerRuns.values()) {
      list.sort(
        (a, b) =>
          new Date(b.started_at).getTime() - new Date(a.started_at).getTime(),
      );
    }

    const openByRun = new Map<string, number>();
    for (const a of annRes.data ?? []) {
      openByRun.set(
        a.run_id as string,
        (openByRun.get(a.run_id as string) ?? 0) + 1,
      );
    }

    // verRes is sorted desc by verified_at — first hit per run wins.
    const latestVerByRun = new Map<string, VerificationSummary>();
    for (const v of verRes.data ?? []) {
      const id = v.run_id as string;
      if (!latestVerByRun.has(id)) {
        latestVerByRun.set(id, v.summary as VerificationSummary);
      }
    }

    summaries = customers.map((c) => {
      const cRuns = customerRuns.get(c.id) ?? [];
      const latest = cRuns[0];
      const openCount = cRuns.reduce(
        (sum, r) => sum + (openByRun.get(r.id) ?? 0),
        0,
      );
      const verSummary = latest ? latestVerByRun.get(latest.id) : undefined;
      const phoneRaw = phoneByCustomer.get(c.id);
      return {
        ...c,
        run_count: cRuns.length,
        latest_run_at: latest?.started_at ?? null,
        latest_stage: latest?.stage_complete ?? null,
        open_annotations: openCount,
        phone: phoneRaw && phoneRaw.length > 0 ? phoneRaw : null,
        tools_count: toolsByCustomer.get(c.id) ?? 0,
        status: classify(latest, verSummary),
      };
    });
  }

  if (summaries.length === 0) {
    return (
      <main className="min-h-screen flex items-center justify-center px-8 bg-[#FAFAF7] text-[#1A1A1A]">
        <CommandPaletteHint />
        <div className="max-w-md text-center">
          <h1 className="text-[44px] font-semibold tracking-tight leading-none">
            ZeroOnboarding
          </h1>
          <p className="mt-8 text-[15px] leading-relaxed text-[#6B6B6B]">
            Run{" "}
            <code className="font-mono text-[13px] text-[#1A1A1A]">
              /base-agent
            </code>{" "}
            in Claude Code to onboard your first customer.
          </p>
        </div>
      </main>
    );
  }

  return (
    <main className="min-h-screen px-8 py-20 sm:px-16 sm:py-24 bg-[#FAFAF7] text-[#1A1A1A]">
      <CommandPaletteHint />
      <div className="mx-auto max-w-3xl">
        <header className="mb-16">
          <h1 className="text-[44px] font-semibold tracking-tight leading-none">
            ZeroOnboarding
          </h1>
          <p className="mt-4 text-[13px] text-[#7A7A72]">
            {summaries.length} customer{summaries.length === 1 ? "" : "s"}
          </p>
        </header>
        <div className="border-t border-[#EDECE6]">
          {summaries.map((s) => (
            <CustomerCard key={s.id} customer={s} />
          ))}
        </div>
      </div>
    </main>
  );
}
