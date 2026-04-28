import Link from "next/link";
import { notFound } from "next/navigation";
import { getServerSupabase } from "@/lib/supabase-server";
import { dotColor, dotHex } from "@/lib/verification";
import { CopyCommandButton } from "@/components/CopyCommandButton";
import type { Customer, VerificationSummary } from "@/lib/types";

// M20 → M24: structured Inspect view. The verification row is shaped as
// `{summary: {pass, fail, skip}, checks: [{id, title, status, detail,
// remediation?}, ...]}`. Older code (M20) dumped the raw JSON; M24 surfaces
// the data as a checklist with copyable remediations and keeps the JSON
// available below as a collapsible <details> block for debugging.

type CheckRow = {
  id?: string;
  title?: string;
  status?: "pass" | "fail" | "skip" | string;
  detail?: string;
  remediation?: string;
  // Some seed fixtures use `name` instead of `title`/`id`. Tolerate it.
  name?: string;
  ms?: number;
};

type VerificationRow = {
  id: string;
  run_id: string;
  verified_at: string;
  summary: VerificationSummary;
  checks: unknown;
  created_at: string;
};

// Per-customer base-tools row from operator_ui.agent_tools. Stage 6.5
// of /base-agent writes one row per tool (transfer + take_message).
// Existing per-customer-server installs (Teleca/TelcoWorks) have zero
// rows — the panel hides cleanly in that case.
type AgentToolRow = {
  id: string;
  tool_name: "transfer" | "take_message" | string;
  config: unknown;
  ultravox_tool_id: string | null;
  attached_to_agent_id: string | null;
  updated_at: string;
};

export default async function InspectPage({
  params,
}: {
  params: Promise<{ slug: string }>;
}) {
  const { slug } = await params;
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

  const { data: runRow, error: runError } = await supabase
    .from("runs")
    .select("id")
    .eq("customer_id", customer.id)
    .order("started_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (runError) {
    throw new Error(`Failed to load latest run: ${runError.message}`);
  }

  let verification: VerificationRow | null = null;
  if (runRow) {
    const { data: vRow, error: vError } = await supabase
      .from("verifications")
      .select("id, run_id, verified_at, summary, checks, created_at")
      .eq("run_id", runRow.id as string)
      .order("verified_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (vError) {
      throw new Error(`Failed to load verification: ${vError.message}`);
    }
    if (vRow) verification = vRow as VerificationRow;
  }

  // Base-tools attached to this customer (Stage 6.5 output). Empty for
  // existing per-customer-server installs (Teleca/TelcoWorks etc.).
  const { data: toolsRows, error: toolsError } = await supabase
    .from("agent_tools")
    .select("id, tool_name, config, ultravox_tool_id, attached_to_agent_id, updated_at")
    .eq("customer_id", customer.id)
    .order("tool_name", { ascending: true });
  if (toolsError) {
    throw new Error(`Failed to load agent_tools: ${toolsError.message}`);
  }
  const tools = (toolsRows ?? []) as AgentToolRow[];

  return (
    <main className="min-h-screen p-12 bg-[#FAFAF7] text-[#1A1A1A]">
      <div className="max-w-3xl">
        <div className="text-sm text-[#6B6B6B]">
          <Link
            href={`/c/${customer.slug}`}
            className="hover:text-[#1A1A1A] transition-colors"
          >
            &larr; {customer.name}
          </Link>
          <span className="mx-2 text-[#C0C0BA]">&middot;</span>
          <span>Inspect deployment</span>
        </div>

        <h1 className="mt-4 text-3xl font-medium">Inspect deployment</h1>
        <hr className="mt-4 border-t border-[#E5E5E0]" />

        {tools.length > 0 ? <ToolsPanel tools={tools} /> : null}

        {verification ? (
          <InspectBody verification={verification} customerSlug={customer.slug} />
        ) : (
          <EmptyState slug={customer.slug} />
        )}
      </div>
    </main>
  );
}

function EmptyState({ slug }: { slug: string }) {
  const command = `/base-agent verify ${slug}`;
  return (
    <div className="mt-8" data-testid="inspect-empty">
      <p className="text-sm text-[#6B6B6B]">
        Verification hasn&rsquo;t run yet. The next /base-agent onboarding will
        run it automatically. To run it manually now: have someone with skill
        access run{" "}
        <code className="font-mono text-[13px] text-[#1A1A1A]">{command}</code>.
      </p>
      <div className="mt-4">
        <CopyCommandButton command={command} label="Copy command" />
      </div>
    </div>
  );
}

function InspectBody({
  verification,
  customerSlug,
}: {
  verification: VerificationRow;
  customerSlug: string;
}) {
  const color = dotColor(verification.summary);
  const checks = Array.isArray(verification.checks)
    ? (verification.checks as CheckRow[])
    : [];
  const payload = {
    summary: verification.summary,
    checks: verification.checks,
    verified_at: verification.verified_at,
  };
  const json = JSON.stringify(payload, null, 2);

  return (
    <div className="mt-6">
      <div className="flex items-center gap-3 text-sm text-[#6B6B6B]">
        <span
          aria-label={`status: ${color}`}
          style={{ color: dotHex(color) }}
          className="leading-none"
          data-testid="inspect-page-dot"
        >
          &bull;
        </span>
        <span>
          verified {new Date(verification.verified_at).toLocaleString()}
        </span>
        <span className="text-[#C0C0BA]">&middot;</span>
        <span className="font-mono text-xs">/c/{customerSlug}/inspect</span>
      </div>

      <ul
        className="mt-6 divide-y divide-[#F0F0EC] border border-[#E5E5E0] rounded-md bg-white"
        data-testid="inspect-checks"
      >
        {checks.length === 0 ? (
          <li className="px-5 py-4 text-sm text-[#6B6B6B]">No checks recorded.</li>
        ) : (
          checks.map((c, i) => (
            <CheckRowItem key={c.id ?? c.name ?? i} check={c} />
          ))
        )}
      </ul>

      <details className="mt-8 group" data-testid="inspect-raw-details">
        <summary className="cursor-pointer text-sm text-[#6B6B6B] hover:text-[#1A1A1A] select-none">
          Raw verification data <span className="ml-1">&#9662;</span>
        </summary>
        <pre
          className="mt-3 bg-white border border-[#E5E5E0] rounded-md p-5 text-[12.5px] leading-relaxed font-mono text-[#1A1A1A] overflow-x-auto whitespace-pre"
          data-testid="inspect-json"
        >
          {json}
        </pre>
      </details>
    </div>
  );
}

function ToolsPanel({ tools }: { tools: AgentToolRow[] }) {
  return (
    <section className="mt-8" data-testid="inspect-tools-panel">
      <h2 className="text-[11px] uppercase tracking-[0.18em] text-[#9A9A92] font-medium">
        Base tools
      </h2>
      <ul className="mt-3 grid gap-3" data-testid="inspect-tools-list">
        {tools.map((t) => (
          <ToolCard key={t.id} tool={t} />
        ))}
      </ul>
    </section>
  );
}

function ToolCard({ tool }: { tool: AgentToolRow }) {
  const summary = renderToolSummary(tool);
  const label = tool.tool_name === "take_message" ? "Take message" : tool.tool_name === "transfer" ? "Transfer" : tool.tool_name;
  return (
    <li
      className="border border-[#E5E5E0] rounded-md bg-white px-5 py-4"
      data-testid="inspect-tool-card"
      data-tool-name={tool.tool_name}
    >
      <div className="flex items-baseline justify-between gap-4">
        <div className="font-medium text-[#1A1A1A]">{label}</div>
        <div className="font-mono text-[11px] text-[#9A9A92]">
          {tool.attached_to_agent_id
            ? `agent ${tool.attached_to_agent_id.slice(0, 8)}…`
            : "not attached"}
        </div>
      </div>
      <div className="mt-1 text-sm text-[#6B6B6B] break-words">{summary}</div>
    </li>
  );
}

function renderToolSummary(tool: AgentToolRow): string {
  const cfg = tool.config as Record<string, unknown> | null;
  if (!cfg) return "(no config)";
  if (tool.tool_name === "transfer") {
    const dests = (cfg.destinations as Array<{ label?: string; phone?: string }> | undefined) ?? [];
    if (dests.length === 0) return "(no destinations)";
    return dests.map((d) => `${d.label ?? "?"} → ${d.phone ?? "?"}`).join(", ");
  }
  if (tool.tool_name === "take_message") {
    const recipient = (cfg.recipient as { channel?: string; address?: string } | undefined) ?? {};
    return `${recipient.channel ?? "?"} → ${recipient.address ?? "?"}`;
  }
  return JSON.stringify(cfg);
}

function CheckRowItem({ check }: { check: CheckRow }) {
  const status = (check.status ?? "skip").toLowerCase();
  const title = check.title ?? check.id ?? check.name ?? "(unnamed check)";
  const detail = check.detail;
  const remediation = check.remediation;

  let icon = "○"; // ○ amber/skip default
  let iconColor = dotHex("amber");
  let label = "skip";
  if (status === "pass") {
    icon = "✓"; // ✓
    iconColor = dotHex("green");
    label = "pass";
  } else if (status === "fail") {
    icon = "✗"; // ✗
    iconColor = dotHex("red");
    label = "fail";
  }

  return (
    <li
      className="px-5 py-4 text-sm"
      data-testid="inspect-check-row"
      data-check-status={status}
    >
      <div className="flex items-start gap-3">
        <span
          className="mt-0.5 leading-none font-mono text-base"
          style={{ color: iconColor }}
          aria-label={label}
        >
          {icon}
        </span>
        <div className="flex-1 min-w-0">
          <div className="font-medium text-[#1A1A1A]">{title}</div>
          {detail ? (
            <div className="mt-1 text-[#6B6B6B] whitespace-pre-wrap break-words">
              {detail}
            </div>
          ) : null}
          {status === "fail" && remediation ? (
            <div className="mt-2 flex items-start gap-2">
              <code className="flex-1 font-mono text-[12.5px] text-[#1A1A1A] bg-[#FAFAF7] border border-[#E5E5E0] rounded px-2 py-1.5 whitespace-pre-wrap break-words">
                {remediation}
              </code>
              <CopyCommandButton command={remediation} label="copy" compact />
            </div>
          ) : null}
        </div>
      </div>
    </li>
  );
}
