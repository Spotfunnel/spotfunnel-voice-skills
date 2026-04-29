// Extracts structured values from operator_ui.verifications.checks[].detail
// strings, which are the free-text "what we found" reports written by
// base-agent-setup/server/verify.py. The verify checks emit a stable id
// (e.g. "ultravox-voice-temperature") and a human-readable detail string
// — the UI scrapes those strings into typed shapes for the resource cards.
//
// Long-term: harden by adding a structured `data: jsonb` field on each
// check result so this scraping disappears. Until then: every extractor
// is fail-soft (returns nulls / "(unknown)" rather than throwing) so a
// surprising detail string never breaks page render.

import type { VerificationSummary } from "./types";

// Shape of a single row inside verifications.checks (parallel to verify.py's
// _result()). `detail` is the field we scrape; `status` drives the card's
// status dot.
export type CheckRow = {
  id?: string;
  title?: string;
  status?: "pass" | "fail" | "skip" | string;
  detail?: string;
  remediation?: string;
  ms?: number;
};

// Pull a check by its id. Returns undefined if the check didn't run for
// this verification (e.g. agent fetch failed earlier and downstream skipped).
export function findCheck(checks: ReadonlyArray<CheckRow>, id: string): CheckRow | undefined {
  return checks.find((c) => c.id === id);
}

// AND-of-statuses helper — returns "pass" iff every check passes; "fail" if
// any failed; "skip" if all skipped; "none" otherwise. Used to compute a
// card-level status dot from N underlying checks.
export function aggregateStatus(
  checks: ReadonlyArray<CheckRow>,
  ids: ReadonlyArray<string>,
): "pass" | "fail" | "skip" | "none" {
  let any = false;
  let anyFail = false;
  let allSkip = true;
  let anyPass = false;
  for (const id of ids) {
    const c = findCheck(checks, id);
    if (!c) continue;
    any = true;
    const s = (c.status ?? "skip").toLowerCase();
    if (s === "fail") anyFail = true;
    if (s !== "skip") allSkip = false;
    if (s === "pass") anyPass = true;
  }
  if (!any) return "none";
  if (anyFail) return "fail";
  if (allSkip) return "skip";
  return anyPass ? "pass" : "none";
}

// Map the SUMMARY-level pass/fail/skip into the dot palette used elsewhere
// in the operator UI (matches CustomerCard's classify()).
export function summaryToDot(
  summary: VerificationSummary | undefined,
): "pass" | "fail" | "partial" | "none" {
  if (!summary) return "none";
  const pass = (summary.pass as number | undefined) ?? 0;
  const fail = (summary.fail as number | undefined) ?? 0;
  const skip = (summary.skip as number | undefined) ?? 0;
  if (fail > 0) return "fail";
  if (skip > 0 && pass > 0) return "partial";
  if (pass > 0) return "pass";
  return "none";
}

// ---------- Per-card extractors -----------------------------------------

// Run.state shape (jsonb) — only the keys this module reads.
export type RunStateLike = {
  ultravox_agent_id?: string;
  agent_first_name?: string;
  customer_name?: string;
  telnyx_did?: string;
  did?: string;
  texml_app_id?: string;
  area_code?: string;
  [key: string]: unknown;
};

export type AgentInfo = {
  agentId: string | null;
  agentFirstName: string | null;
  customerName: string | null;
  voice: string | null;
  voiceId: string | null;
  temperature: string | null;
  systemPromptBytes: number | null;
};

// Extract Ultravox agent info. Voice + temperature come from the
// "ultravox-voice-temperature" check's detail string. System-prompt size
// comes from "system-prompt-matches-artifact" (which says e.g.
// "sizes match (18432 bytes)" or "size 5421 bytes").
export function extractAgentInfo(
  state: RunStateLike | null | undefined,
  checks: ReadonlyArray<CheckRow>,
): AgentInfo {
  const voiceTempDetail = findCheck(checks, "ultravox-voice-temperature")?.detail ?? "";
  const systemPromptDetail = findCheck(checks, "system-prompt-matches-artifact")?.detail ?? "";

  // verify.py emits e.g. "voice + temp match ref" on pass; on detail mismatches
  // the message includes the specific values. We don't have a guaranteed shape,
  // so try a few patterns.
  const voiceMatch = voiceTempDetail.match(/voice[:= ]+([\w\d-]+)/i);
  const tempMatch = voiceTempDetail.match(/temp(?:erature)?[:= ]+([\d.]+)/i);

  const sizeMatch = systemPromptDetail.match(/(\d+)\s*bytes/);
  const systemPromptBytes = sizeMatch ? parseInt(sizeMatch[1], 10) : null;

  return {
    agentId: state?.ultravox_agent_id ?? null,
    agentFirstName: state?.agent_first_name ?? null,
    customerName: state?.customer_name ?? null,
    voice: null, // verify currently emits a pass message without naming the voice; deferred
    voiceId: voiceMatch ? voiceMatch[1] : null,
    temperature: tempMatch ? tempMatch[1] : null,
    systemPromptBytes,
  };
}

export type TelephonyInfo = {
  phone: string | null;
  phoneFormatted: string | null;
  areaCode: string | null;
  texmlAppId: string | null;
  voiceUrl: string | null;
  statusCallback: string | null;
};

// "+61212345678" → "+61 2 1234 5678" (AU only — non-AU numbers fall back
// to passthrough). The shape mirrors how Telnyx renders DIDs in the
// console + how AU operators read phone numbers aloud. Order matters:
// check the more-specific patterns BEFORE the generic landline one.
export function formatAuPhone(e164: string | null | undefined): string | null {
  if (!e164) return null;
  // Mobile: +614XX XXX XXX (must precede landline since both have 11 digits
  // post-+61 — mobile starts with 4 which the landline pattern would
  // happily consume as area code).
  const mobile = e164.match(/^\+61(4\d{2})(\d{3})(\d{3})$/);
  if (mobile) return `+61 ${mobile[1]} ${mobile[2]} ${mobile[3]}`;
  // Special-rate 13/1300/1800: +61 1300 XXXXX  +61 1800 XXXXXX
  const sp = e164.match(/^\+61(1[38]00)(\d+)$/);
  if (sp) return `+61 ${sp[1]} ${sp[2]}`;
  // Plain 13XX: +61 13 XX XX
  const sp13 = e164.match(/^\+61(13)(\d{4})$/);
  if (sp13) return `+61 ${sp13[1]} ${sp13[2]}`;
  // Landline: +61 X XXXX XXXX (X is 2/3/7/8 typically — we don't enforce).
  const landline = e164.match(/^\+61(\d)(\d{4})(\d{4})$/);
  if (landline) return `+61 ${landline[1]} ${landline[2]} ${landline[3]}`;
  return e164;
}

export function extractTelephony(
  state: RunStateLike | null | undefined,
  checks: ReadonlyArray<CheckRow>,
): TelephonyInfo {
  const phone = state?.telnyx_did ?? state?.did ?? null;
  const didDetail = findCheck(checks, "telnyx-did-active")?.detail ?? "";
  const routingDetail = findCheck(checks, "telnyx-call-routing-wired")?.detail ?? "";

  const voiceUrlMatch = (didDetail + " " + routingDetail).match(
    /voice_url=([^\s,]+)/,
  );
  const callbackMatch = findCheck(checks, "webhook-callback-set")?.detail?.match(
    /(https?:\/\/[^\s,]+)/,
  );

  return {
    phone,
    phoneFormatted: formatAuPhone(phone),
    areaCode: state?.area_code ?? null,
    texmlAppId: state?.texml_app_id ?? null,
    voiceUrl: voiceUrlMatch ? voiceUrlMatch[1] : null,
    statusCallback: callbackMatch ? callbackMatch[1] : null,
  };
}

export type DashboardInfo = {
  workspaceExists: boolean;
  primaryUserExists: boolean;
  workspaceDetail: string | null;
  primaryUserDetail: string | null;
};

// The dashboard checks emit free-text on the workspace + primary user. We
// preserve the raw detail string for display; future iterations can parse
// the workspace name + primary user role + agent_ids count from these strings
// once verify.py emits them in a parseable format.
export function extractDashboard(checks: ReadonlyArray<CheckRow>): DashboardInfo {
  const ws = findCheck(checks, "supabase-customer-dashboard-workspace-exists");
  const user = findCheck(checks, "supabase-customer-dashboard-auth-user-exists");
  return {
    workspaceExists: ws?.status === "pass",
    primaryUserExists: user?.status === "pass",
    workspaceDetail: ws?.detail ?? null,
    primaryUserDetail: user?.detail ?? null,
  };
}

export type AgentToolRow = {
  id: string;
  tool_name: string;
  config: unknown;
  ultravox_tool_id: string | null;
  attached_to_agent_id: string | null;
  updated_at?: string;
};

export type ToolDisplayRow = {
  toolName: string;
  prettyName: string;
  ultravoxToolId: string | null;
  attachedToAgentId: string | null;
  displayValue: string;
  updatedAt: string | null;
};

// Render a single agent_tools row's config blob as a one-line operator-
// readable summary. transfer → "primary → +61...", take_message → "email →
// ops@...", anything else → JSON of config.
export function summariseTool(row: AgentToolRow): ToolDisplayRow {
  const cfg = row.config as Record<string, unknown> | null;
  let displayValue = "(no config)";
  if (cfg) {
    if (row.tool_name === "transfer") {
      const dests = (cfg.destinations as Array<{ label?: string; phone?: string }> | undefined) ?? [];
      if (dests.length > 0) {
        displayValue = dests
          .map((d) => `${d.label ?? "?"} → ${formatAuPhone(d.phone) ?? d.phone ?? "?"}`)
          .join(", ");
      } else {
        displayValue = "(no destinations)";
      }
    } else if (row.tool_name === "take_message") {
      const recipient = (cfg.recipient as { channel?: string; address?: string } | undefined) ?? {};
      displayValue = `${recipient.channel ?? "?"} → ${recipient.address ?? "?"}`;
    } else {
      displayValue = JSON.stringify(cfg);
    }
  }
  const prettyName =
    row.tool_name === "take_message" ? "Take message"
      : row.tool_name === "transfer" ? "Transfer"
        : row.tool_name;
  return {
    toolName: row.tool_name,
    prettyName,
    ultravoxToolId: row.ultravox_tool_id,
    attachedToAgentId: row.attached_to_agent_id,
    displayValue,
    updatedAt: row.updated_at ?? null,
  };
}

// Truncate a UUID for compact rendering: 8 chars + ellipsis. Returns
// the input unchanged when it's already shorter or non-UUID-ish.
export function truncateUuid(id: string | null | undefined): string {
  if (!id) return "—";
  if (id.length <= 12) return id;
  return `${id.slice(0, 8)}…`;
}

// Mask a phone number except the last 4 digits. "+61212345678" → "•••• 5678".
export function maskPhone(phone: string | null | undefined): string {
  if (!phone) return "—";
  const last4 = phone.slice(-4);
  return `•••• ${last4}`;
}
