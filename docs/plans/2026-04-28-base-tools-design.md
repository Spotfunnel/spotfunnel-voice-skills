# Base tools layer + Inspect view evolution — design

**Date:** 2026-04-28
**Skill modified:** `base-agent-setup`
**Repo:** `Spotfunnel/spotfunnel-voice-skills`

## Problem

Today every voice agent is shipped tool-less at Stage 6 (`selectedTools=[]`). Production agents (Teleca/TelcoWorks) get tools attached *after the fact* via per-customer Railway services that own webhook handlers + per-customer logic — heavy infrastructure per customer. New customers from Goulburn forward shouldn't need a dedicated server just to do warm-transfer or take-a-message.

The Inspect view (M24, shipped) shows verification checks but no view of *what's actually attached* to an agent: no tools panel, no agent-config detail, no recent activity.

## Goal

1. Make transfer + take-message the default at agent-creation time, configured per customer with structured data, runtime-served from the shared dashboard-server (no per-customer infra).
2. Surface every connected resource in the Inspect view — tools, agent settings, recent calls — alongside the existing checks.

## Decisions (reasoning in conversation 2026-04-28)

| Decision | Locked |
|---|---|
| First-wave tools | transfer + take-message |
| Lifecycle | mandatory at Stage 6.5; halt-loud on missing config |
| Config scope | minimal — destinations/recipients only; behavior stays in PROCEDURES |
| Storage | new `operator_ui.agent_tools` table |
| Webhook host (take-message) | shared dashboard-server |
| Webhook host (transfer) | none — Ultravox built-in PSTN transfer used; no callback needed |
| Existing Teleca/TelcoWorks | stay as-is forever; base-tools is for new customers only |
| Stage 6.5 UX | CLI prompts during the run |
| Later editing UX | UI form on the customer page (deferred to iter 2; v1 ships CLI-only) |

## Architecture

```
                    ┌────────────────────────────┐
                    │   /base-agent (Stage 6.5)  │
                    │  prompts operator for:     │
                    │  - transfer destinations   │
                    │  - message recipients      │
                    └──────────┬─────────────────┘
                               │
                  ┌────────────┴────────────┐
                  │ INSERT operator_ui.     │
                  │   agent_tools rows      │
                  └────────────┬────────────┘
                               │
                  ┌────────────┴────────────┐
                  │ PATCH Ultravox agent    │
                  │   selectedTools = [     │
                  │     {toolId: BWT, ...}  │
                  │     {toolId: BTM, ...}  │
                  │   ]                     │
                  └─────────────────────────┘

   At call time:
   ─────────────
   Caller dials → Ultravox runs agent → agent invokes baseTakeMessage
   → Ultravox POSTs https://dashboard-server/webhooks/take-message
     {agent_id, caller_phone, caller_name, callback_number, reason, urgency}
   → dashboard-server looks up workspace via agent_id → reads
     operator_ui.agent_tools.config.recipient → emails/SMSes the operator

   For transfer: Ultravox's built-in PSTN transfer dials the destination
   directly. No webhook. Destinations live in agent_tools but are passed
   into the Ultravox tool as parameterOverrides at attach time.
```

Two Ultravox tools (created once, shared across all base-tools customers):

- **`baseWarmTransfer`** — wraps Ultravox's PSTN transferToCallParticipant. Per-customer destinations passed via parameterOverrides at attach time.
- **`baseTakeMessage`** — HTTP tool that POSTs structured fields to `$DASHBOARD_SERVER_URL/webhooks/take-message`.

## Data model — `operator_ui.agent_tools`

```sql
CREATE TABLE operator_ui.agent_tools (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id            uuid NOT NULL REFERENCES operator_ui.customers(id) ON DELETE CASCADE,
  tool_name              text NOT NULL,           -- 'transfer' | 'take_message'
  config                 jsonb NOT NULL,
  ultravox_tool_id       text,                    -- the shared toolId baked into selectedTools
  attached_to_agent_id   text,                    -- which Ultravox agent it's attached to
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  UNIQUE (customer_id, tool_name)
);
CREATE INDEX agent_tools_customer_idx ON operator_ui.agent_tools (customer_id);
ALTER TABLE operator_ui.agent_tools ENABLE ROW LEVEL SECURITY;
CREATE POLICY "service role full access" ON operator_ui.agent_tools FOR ALL USING (true) WITH CHECK (true);
```

Config shapes:

```jsonc
// transfer
{
  "destinations": [
    { "label": "primary", "phone": "+61400000000" }
  ]
}

// take_message
{
  "recipient": {
    "channel": "email",            // 'email' | 'sms' (sms = phase 2)
    "address": "ops@example.com"
  }
}
```

## Stage 6.5 flow

Inserted between Stage 6 (Ultravox agent created) and Stage 7 (Telnyx DID claim).

1. Read `state.ultravox_agent_id` from the run.
2. Prompt operator interactively:
   - **Transfer destination** — single phone number for v1 (multiple later). Format-validated as E.164 AU (`+61...`). One destination = label `"primary"`.
   - **Message recipient** — email address (validated as RFC 5321-ish). SMS deferred to phase 2.
3. INSERT both `agent_tools` rows for this customer.
4. PATCH the Ultravox agent's `selectedTools` (safe full-PATCH via `_ultravox_safe_patch.py`) with the two tool definitions:
   ```jsonc
   [
     {
       "toolId": "<baseWarmTransfer toolId>",
       "nameOverride": "warmTransfer",
       "parameterOverrides": {
         "destination_phone": "+61400000000"
       }
     },
     {
       "toolId": "<baseTakeMessage toolId>",
       "nameOverride": "takeMessage",
       "parameterOverrides": {
         "recipient_channel": "email",
         "recipient_address": "ops@example.com"
       }
     }
   ]
   ```
5. Append two `deployment_log` entries (one per tool attached) so `/base-agent remove` can clean up via inverse replay.
6. `state_stage_complete 6.5` → continue to Stage 7.

Halt conditions:
- Operator declines / leaves blank → halt; no agent should ship without these.
- Phone number fails E.164-AU regex → halt with the rule, prompt for re-entry.
- Email fails validation → halt with the rule.
- Ultravox PATCH fails → halt; agent_tools rows already written are picked up by `/base-agent remove` cleanly via deployment_log.

## Inspect view evolution

Extend `ui/web/app/c/[slug]/inspect/page.tsx` with three new panels above the existing checklist:

1. **Agent settings card** — name, voice, temperature, system-prompt size, last-modified (sourced from `state.ultravox_agent_id` → live GET on Ultravox + cached). Click "Refresh" → re-fetch.
2. **Tools panel** — for each row in `operator_ui.agent_tools` for this customer: tool name, config (destinations/recipients), attached to agent_id, last-updated. Click row → details modal showing the live Ultravox `selectedTools` entry side-by-side (drift surfaced visually).
3. **Recent activity** — last 5 calls from `dashboard.calls` for the workspace (when accessible): caller_phone (masked), outcome, duration, started_at. Empty state when no dashboard or no calls.

Existing checks list stays at the bottom unchanged. The order top → bottom is *what's there → what's working*.

## Verify extensions

Add three checks to `base-agent-setup/server/verify.py`:

| Check | Pass condition |
|---|---|
| `agent-tools-config-present` | `operator_ui.agent_tools` has rows for both `transfer` AND `take_message` for this customer. |
| `agent-tools-attached-live` | The live Ultravox agent's `selectedTools` contains both expected toolIds with non-empty `parameterOverrides`. |
| `agent-tools-no-drift` | Live `parameterOverrides` match the values in `agent_tools.config` (destinations/recipients). |

These count as fail (not skip) when a customer has Stage 6.5 in their state but the rows/PATCH didn't land — that's a partial-onboarding state worth surfacing.

## Removal integration

Extend `scripts/_remove_customer.py`:
- Discovery: SELECT `agent_tools` rows for this customer's id; surface in inventory.
- Teardown: DELETE rows after Ultravox agent DELETE (the PATCH-revert is implicit because we're deleting the agent itself; if the customer is keeping the agent and just nuking tools, we'd need a separate flow — out of scope for v1).
- Phase 4 verification: confirm `agent_tools` count = 0.

## Dashboard-server contract (separate repo)

The `take-message` webhook endpoint must be added to the dashboard-server repo:

```
POST /webhooks/take-message
Headers: X-Ultravox-Signature: ...   (existing webhook auth pattern)
Body: {
  "agent_id":         "uuid",
  "caller_phone":     "+61...",
  "caller_name":      "string",
  "callback_number":  "+61...",
  "reason":           "string",
  "urgency":          "string"
}

Response: { "success": true }

Behavior:
1. Look up workspace via workspaces.ultravox_agent_ids @> [agent_id]
2. Look up operator_ui.agent_tools where tool_name='take_message' and
   customer matches workspace.slug → recipient channel + address
3. Send via Resend (email) — payload is structured into a clean text body
4. Insert workflow_errors audit row (severity=info, source=take_message)
```

This is documented as a TODO note in the operator-handoff section. Operator deploys the dashboard-server change alongside this skill iteration.

## Out of scope (explicit)

- **SMS as a take-message recipient channel** — phase 2, requires SMS provider env (Twilio/MessageMedia). v1 ships email-only.
- **Multiple transfer destinations with per-destination triggers** — phase 2, current minimal shape is one destination labelled "primary".
- **UI-side editing of agent_tools** — phase 2, v1 ships CLI-only via Stage 6.5 + a one-shot edit script (`scripts/edit-base-tool.sh` deferred).
- **Migration of Teleca/TelcoWorks to base tools** — explicitly out per operator decision; existing customers keep their per-customer Railway services.
- **Time-of-day routing, urgency-based escalation, dynamic destinations** — phase 3+.
- **Dashboard-server endpoint implementation** — lives in a separate repo; this skill iteration documents the contract only.

## Build sequence

1. Migration `operator_ui_agent_tools.sql` — apply.
2. Bootstrap script: create the two shared Ultravox tools (`baseWarmTransfer`, `baseTakeMessage`) via API. Their toolIds get committed into the skill (`scripts/_base_tool_ids.sh`).
3. `scripts/attach-base-tools.sh` — interactive Stage 6.5 attach.
4. Add Stage 6.5 to `SKILL.md`.
5. Extend `verify.py` with the three new checks.
6. Extend `_remove_customer.py` with `agent_tools` discovery + cleanup.
7. Extend `inspect/page.tsx` with the three new panels.
8. Document the dashboard-server contract in SKILL.md (operator handoff).
9. Test end-to-end with a synthetic customer.

## Testing

End-to-end on a fresh `e2e-tools-test` slug taken through Stage 6.5: agent created → tools attached with synthetic destinations (`+61400000000` + `dev@example.com`) → verify all three new checks pass → Inspect view shows Tools panel → `/base-agent remove e2e-tools-test` cleans `agent_tools` + agent + everything → re-verify zero residue.
