import { notFound } from "next/navigation";
import { getServerSupabase } from "@/lib/supabase-server";
import { RunHistorySwitcher } from "@/components/RunHistorySwitcher";
import { CommandPaletteHint } from "@/components/CommandPaletteHint";
import { CustomerTabs, parseTab } from "@/components/customer/Tabs";
import { OverviewTab } from "@/components/customer/OverviewTab";
import { ConnectionsTab } from "@/components/customer/ConnectionsTab";
import { ReadTab } from "@/components/customer/ReadTab";
import { AuditTab, type DeploymentLogRow } from "@/components/customer/AuditTab";
import {
  VerifyTabBody,
  VerifyTabEmpty,
  type VerificationRow,
} from "@/components/customer/VerifyTab";
import { loadRunHistory } from "@/lib/run-history";
import {
  type Customer,
  type Run,
  type VerificationSummary,
} from "@/lib/types";
import type {
  AgentToolRow,
  CheckRow,
  RunStateLike,
} from "@/lib/inspect-extractors";
import type { RecentCall } from "@/components/customer/cards/RecentActivityCard";

const TOTAL_STAGES = 11;

function formatRunDate(iso: string): string {
  const d = new Date(iso);
  const day = d.getUTCDate();
  const month = d.toLocaleString("en-GB", { month: "short", timeZone: "UTC" });
  const year = d.getUTCFullYear();
  return `${day} ${month} ${year}`;
}

export default async function CustomerPage({
  params,
  searchParams,
}: {
  params: Promise<{ slug: string }>;
  searchParams: Promise<{ tab?: string | string[] }>;
}) {
  const { slug } = await params;
  const { tab: tabParam } = await searchParams;
  const currentTab = parseTab(tabParam);
  const supabase = await getServerSupabase();

  const { data: customerRow, error: customerError } = await supabase
    .from("customers")
    .select("id, slug, name, created_at")
    .eq("slug", slug)
    .maybeSingle();

  if (customerError) {
    throw new Error(`Failed to load customer: ${customerError.message}`);
  }
  if (!customerRow) notFound();
  const customer = customerRow as Customer;

  // Latest run.
  const { data: runRow, error: runError } = await supabase
    .from("runs")
    .select("id, customer_id, started_at, stage_complete, state, refined_from_run_id")
    .eq("customer_id", customer.id)
    .order("started_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (runError) {
    throw new Error(`Failed to load latest run: ${runError.message}`);
  }
  const run = (runRow ?? null) as Run | null;
  const runState = (run?.state ?? null) as RunStateLike | null;

  const runHistory = await loadRunHistory(
    supabase as unknown as Parameters<typeof loadRunHistory>[0],
    customer.id,
  );

  // Per-tab data load. Each branch fetches only what it renders so a
  // narrow tab doesn't pay for irrelevant queries. Overview is the
  // densest because it powers four cards at once.
  const artifactNames = new Set<string>();
  const openByArtifact = new Map<string, number>();
  const resolvedByArtifact = new Map<string, number>();
  let verification: VerificationRow | null = null;
  let verificationSummary: VerificationSummary | null = null;
  let toolsRows: AgentToolRow[] = [];
  let auditRows: DeploymentLogRow[] = [];
  let recentCalls: RecentCall[] = [];
  let recentCallsConfigured = false;

  if (run) {
    // Read tab data — chapter list + per-artifact annotation counts.
    if (currentTab === "read") {
      const [artifactRowsRes, annotationRowsRes] = await Promise.all([
        supabase.from("artifacts").select("artifact_name").eq("run_id", run.id),
        supabase
          .from("annotations")
          .select("artifact_name, status")
          .eq("run_id", run.id)
          .in("status", ["open", "resolved"]),
      ]);
      if (artifactRowsRes.error) {
        throw new Error(`Failed to load artifacts: ${artifactRowsRes.error.message}`);
      }
      if (annotationRowsRes.error) {
        throw new Error(`Failed to load annotation counts: ${annotationRowsRes.error.message}`);
      }
      for (const row of artifactRowsRes.data ?? []) {
        artifactNames.add(row.artifact_name as string);
      }
      for (const row of annotationRowsRes.data ?? []) {
        const name = row.artifact_name as string;
        const status = row.status as string;
        const target = status === "open" ? openByArtifact : resolvedByArtifact;
        target.set(name, (target.get(name) ?? 0) + 1);
      }
    }

    // Verification (used by Overview status dots + the Verify tab itself).
    if (currentTab === "overview" || currentTab === "verify" || currentTab === "connections") {
      const { data: vRow, error: vError } = await supabase
        .from("verifications")
        .select("id, run_id, verified_at, summary, checks, created_at")
        .eq("run_id", run.id)
        .order("verified_at", { ascending: false })
        .limit(1)
        .maybeSingle();
      if (vError) {
        throw new Error(`Failed to load verification: ${vError.message}`);
      }
      if (vRow) {
        verification = vRow as VerificationRow;
        verificationSummary = vRow.summary as VerificationSummary;
      }
    }
  }

  // Tools — needed for Overview's tool count, Connections tab, and the empty
  // state for legacy customers. Cheap query so always run.
  const { data: toolsRes, error: toolsErr } = await supabase
    .from("agent_tools")
    .select("id, tool_name, config, ultravox_tool_id, attached_to_agent_id, updated_at")
    .eq("customer_id", customer.id)
    .order("tool_name", { ascending: true });
  if (toolsErr) {
    throw new Error(`Failed to load agent_tools: ${toolsErr.message}`);
  }
  toolsRows = (toolsRes ?? []) as AgentToolRow[];

  // Audit — only when the tab is open. Filtered by customer_slug (text col,
  // intentionally not FK so log survives row deletion).
  if (currentTab === "audit") {
    const { data: logRes, error: logErr } = await supabase
      .from("deployment_log")
      .select("id, stage, system, action, target_kind, target_id, inverse_op, status, created_at")
      .eq("customer_slug", slug)
      .order("created_at", { ascending: false });
    if (logErr) {
      throw new Error(`Failed to load deployment_log: ${logErr.message}`);
    }
    auditRows = (logRes ?? []) as DeploymentLogRow[];
  }

  const checks: ReadonlyArray<CheckRow> = Array.isArray(verification?.checks)
    ? (verification!.checks as CheckRow[])
    : [];

  const stageHeader = run ? (
    <p className="mt-6 text-[13px] text-[#7A7A72]">
      Latest run · {formatRunDate(run.started_at)} · stage {run.stage_complete}/{TOTAL_STAGES}
    </p>
  ) : (
    <p className="mt-6 text-[13px] text-[#7A7A72]">No runs yet</p>
  );

  return (
    <main className="min-h-screen px-8 py-20 sm:px-16 sm:py-24 bg-[#FAFAF7] text-[#1A1A1A]">
      <CommandPaletteHint />
      <div className="mx-auto max-w-3xl">
        <header>
          <h1 className="text-[44px] font-semibold tracking-tight leading-none">
            {customer.name}
          </h1>
          <p className="mt-4 font-mono text-[12px] text-[#9A9A92]">{customer.slug}</p>
          {stageHeader}
        </header>

        <CustomerTabs slug={customer.slug} currentTab={currentTab} />

        {currentTab === "overview" ? (
          <OverviewTab
            state={runState}
            checks={checks}
            recentCalls={recentCalls}
            recentCallsConfigured={recentCallsConfigured}
            slug={customer.slug}
          />
        ) : null}
        {currentTab === "connections" ? (
          <ConnectionsTab state={runState} checks={checks} tools={toolsRows} />
        ) : null}
        {currentTab === "read" ? (
          <ReadTab
            slug={customer.slug}
            artifactNames={artifactNames}
            openByArtifact={openByArtifact}
            resolvedByArtifact={resolvedByArtifact}
            scrapeCount={run?.state?.scrape_pages_count}
          />
        ) : null}
        {currentTab === "verify" ? (
          verification ? (
            <VerifyTabBody verification={verification} customerSlug={customer.slug} />
          ) : (
            <VerifyTabEmpty slug={customer.slug} />
          )
        ) : null}
        {currentTab === "audit" ? <AuditTab rows={auditRows} /> : null}

        <RunHistorySwitcher
          slug={customer.slug}
          runs={runHistory}
          activeRunId={run?.id ?? null}
        />

        {/* Reserved for future verificationSummary use; expose to silence the
            unused-variable lint without changing render output. */}
        <span className="hidden" data-testid="verification-status-marker" data-status={verificationSummary ? "loaded" : "absent"} />
      </div>
    </main>
  );
}
