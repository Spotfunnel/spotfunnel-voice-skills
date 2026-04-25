---
name: onboard-customer
description: Wire a finished Ultravox voice-AI agent into the SpotFunnel dashboard end-to-end. Maps every webhook, env var, and data-flow checkpoint. Leans on existing context (your project's CLAUDE.md if any, memory, Supabase, Ultravox API) — only asks the operator for genuinely novel info. Use when the operator says "/onboard-customer", "onboard [name]", "new customer", or "set up [customer] in the dashboard".
user_invocable: true
---

# Onboard Customer

The agent is already built in Ultravox: prompts, tools, voice, Telnyx numbers — all done in those consoles. What's left is SpotFunnel wiring so calls flow into the dashboard and render the way they should.

This skill is the **manual for that wiring**. It is NOT a questionnaire. Before asking the operator anything, read what you already know.

---

## Runtime notes (Windows + Git Bash gotchas, verified 2026-04-18)

- **Every `curl` needs `--ssl-no-revoke`.** Windows SChannel's certificate revocation check fails on some hosts (Supabase Auth admin endpoint included), producing `CRYPT_E_NO_REVOCATION_CHECK`. Flag bypasses the CRL check but still TLS-verifies the endpoint — safe.
- **`jq` is not installed.** Use `grep -oE '"key":"[^"]+"'` or Python for JSON parsing. Don't write `| jq -r ...` — it'll fail.
- **Python3 can't read `/tmp/` paths** (Git Bash's `/tmp` doesn't map to a Windows path Python recognizes). For any file handed from curl to Python, write it to a portable temp path like `${TMPDIR:-$HOME/.tmp-spotfunnel-skills}/...` (create the dir if missing, `rm -rf` when done). On Windows + Git Bash this resolves under the user's home; on macOS/Linux it follows `$TMPDIR`.
- Supabase auth user delete: `DELETE $SUPABASE_URL/auth/v1/admin/users/{uuid}` works and returns 200 on success.

---

## Stage 0 — Load env (MUST run first)

Stage 0 is preflight — runs BEFORE any of the main 8 stages. The numbered flow (1 through 8) begins after env is loaded.

All secrets live in a single `.env` file. Claude Code's bash does NOT auto-source it. Resolve the file in this order — first hit wins — and source it. Run this ONCE at the start of every invocation, before any `curl` or Stage 6b calls:

```bash
# Resolve env file path: $SPOTFUNNEL_SKILLS_ENV → <repo-root>/.env → cached path → prompt
ENV_PATH=""
if [ -n "$SPOTFUNNEL_SKILLS_ENV" ] && [ -f "$SPOTFUNNEL_SKILLS_ENV" ]; then
  ENV_PATH="$SPOTFUNNEL_SKILLS_ENV"
elif [ -f "$(git rev-parse --show-toplevel 2>/dev/null)/.env" ]; then
  ENV_PATH="$(git rev-parse --show-toplevel)/.env"
elif [ -f "$HOME/.config/spotfunnel-skills/env-path" ] && [ -f "$(cat "$HOME/.config/spotfunnel-skills/env-path")" ]; then
  ENV_PATH="$(cat "$HOME/.config/spotfunnel-skills/env-path")"
fi

if [ -z "$ENV_PATH" ]; then
  echo "Cannot locate the spotfunnel-voice-skills .env file."
  echo "Set \$SPOTFUNNEL_SKILLS_ENV, place .env at the repo root, or paste an absolute path now."
  # Skill should prompt the operator for an absolute path, validate it exists,
  # write it to ~/.config/spotfunnel-skills/env-path, then assign to ENV_PATH.
  exit 1
fi

set -a
source "$ENV_PATH"
set +a
```

Sanity check immediately:
```bash
[ -n "$ULTRAVOX_API_KEY" ] && echo "ULTRAVOX_API_KEY loaded" || echo "❌ ULTRAVOX_API_KEY missing"
[ -n "$SUPABASE_SERVICE_ROLE_KEY" ] && echo "SUPABASE_SERVICE_ROLE_KEY loaded" || echo "❌ SUPABASE_SERVICE_ROLE_KEY missing"
[ -n "$SUPABASE_URL" ] && echo "SUPABASE_URL loaded" || echo "❌ SUPABASE_URL missing"
[ -n "$DASHBOARD_SERVER_URL" ] && echo "DASHBOARD_SERVER_URL loaded" || echo "❌ DASHBOARD_SERVER_URL missing"
```

If any `❌`, STOP and tell the operator which var is missing — see `ENV_SETUP.md` for what to paste. Do not proceed.

---

## The 6 wiring surfaces

Every onboarding touches exactly these six surfaces. Know them cold.

### Surface 1 — Ultravox agent `call.ended` webhook (THE key connection)

| | |
|---|---|
| **What** | Each Ultravox agent's `call.ended` webhook URL must be `$DASHBOARD_SERVER_URL/webhooks/call-ended` (the public URL of the operator's `dashboard-server` deployment, configured in `.env`). |
| **Why** | This single POST is how calls reach the dashboard. Ultravox fires it after every call; dashboard-server fetches the full transcript+audio from Ultravox, runs analysis, inserts a `calls` row attributed to the workspace |
| **Who sets it** | The operator, manually in Ultravox console (per project rule: never PATCH Ultravox agents via API) |
| **Failure mode** | If unset or wrong: call NEVER reaches dashboard. Silent. No row appears. |
| **Verify** | After it's set, GET `https://api.ultravox.ai/api/agents/{id}` with `X-API-Key: $ULTRAVOX_API_KEY` and confirm `callTemplate.eventMessages[*]` or equivalent contains the URL exactly |

### Surface 2 — Supabase `workspaces` + `users` rows

| | |
|---|---|
| **What** | (1) INSERT `workspaces` (name, slug, plan, timezone, ultravox_agent_ids[], telnyx_numbers[], config JSONB). (2) Invite primary user via Supabase Auth → get back their `auth.users.id` UUID. (3) INSERT `public.users` (id=that UUID, email, name, role=`'admin'`, workspace_id). |
| **Why** | Dashboard routes calls by `workspace_id`. Login is magic-link via Supabase Auth at `https://app.spotfunnel.com/login`; `public.users.id` must match `auth.users.id` because `getActiveWorkspace()` joins on `id`, not email (see `dashboard/lib/get-workspace.ts:17`). Without a matching `public.users` row, the customer logs in fine but sees a blank dashboard. |
| **Who sets it** | Skill inserts workspaces via MCP. Primary-user invite uses `SUPABASE_SERVICE_ROLE_KEY` + `SUPABASE_URL` (loaded from `.env` at Stage 0) via Supabase Auth Admin API — no manual Studio clicks. |
| **Failure mode** | Bad agent_ids → calls drop silently (Surface 3). `public.users.id` ≠ `auth.users.id` → customer logs in but sees empty dashboard. Wrong role → customer can't self-service their team (see the Roles note at the bottom of this doc). |
| **Verify** | SELECT back both rows. Critically: `SELECT pu.id, au.id FROM public.users pu JOIN auth.users au USING (id) WHERE pu.email = $EMAIL` must return one row — proves the IDs match. |

### Surface 3 — Call-to-workspace attribution

| | |
|---|---|
| **What** | `dashboard-server/routes/webhooks/call-ended.js:75-103` does `.from('workspaces').contains('ultravox_agent_ids', [agentId])` |
| **Why** | Multi-tenant routing. The ONLY mechanism. |
| **Who sets it** | Already shipped; skill just verifies the workspace row has the right agent_ids |
| **Failure mode** | `agentId` not in any workspace's array → call logged to `workflow_errors` table + silently dropped. 2+ workspaces share the same agent_id → call rejected as cross-tenant violation |
| **Verify** | After a test call, SELECT from `workflow_errors` for the last 5 min + that call_id. Should be empty. |

### Surface 4 — Analysis pipeline

| | |
|---|---|
| **What** | `dashboard-server/lib/analysis.js` runs GPT on the transcript. Reads `workspace.config.outcomes`, `workspace.config.intents` (when populated), `workspace.config.company_description`. Writes `calls.outcome`, `calls.status`, `calls.summary`, `calls.interest`, `calls.caller_name`, `calls.follow_up_needed`, `calls.intent` |
| **Why** | Turns raw transcripts into structured classifications the dashboard renders |
| **Who sets it** | Already shipped; skill populates `config.outcomes` + `config.intents` so the classifier picks from the right vocabulary |
| **Failure mode** | Missing `config.outcomes` → falls back to hardcoded defaults (`converted/info/message/transferred`), still works but inaccurate for the customer. Missing `config.intents` → no intent classification (null column). Missing `config.company_description` → generic prompt, slightly worse accuracy. |
| **Verify** | After a test call lands, SELECT the call row — confirm `outcome` is one of the workspace's declared outcomes (not a default) |

### Surface 5 — Agent tool webhooks (OUT OF SCOPE — customer's own server owns these)

| | |
|---|---|
| **What** | The agent's in-call tools (transfer, SMS, etc.) POST to the customer's own per-customer Railway service (e.g. `teleca-server`, `telcoworks-server`, future `solarco-server`) |
| **Why** | Per-customer data (transfer targets, SMS videos, number info) lives in the customer's server, not the dashboard |
| **Who sets it** | The operator when deploying the per-customer server; NOT the skill's job |
| **The skill explicitly does NOT configure these.** If transfers don't work after onboarding, that's a per-customer-server issue, not a dashboard-wiring issue. |

### Surface 6 — Error reporting pipeline

| | |
|---|---|
| **What** | Every surface that can fail at runtime for this customer routes errors to `$DASHBOARD_SERVER_URL/webhooks/n8n-error` with `{ source, severity, message, payload }`. Covers: customer-specific n8n workflows, customer-server runtime errors (if they run their own server), and agent tool failures (already captured by call-ended analysis). |
| **Why** | Otherwise failures are silent — they hit Railway/n8n logs but never appear in `/admin/health`. The operator needs a single place to see everything broken. |
| **Who sets it** | Skill, via n8n API: enumerate the customer's n8n workflows, set `settings.errorWorkflow` on each to the central error-reporter workflow (ID stored in env var `N8N_ERROR_REPORTER_WORKFLOW_ID` — skill reads it). For customer-server code: skill instructs the operator to `require('voice-tools-shared/error-reporter')` in the new server and wrap catch blocks. |
| **Failure mode** | New n8n workflow ships without errorWorkflow set → its failures go invisible. Customer server has unwrapped try/catch → Railway logs only. |
| **Verify** | After onboarding, the central error-reporter workflow ID appears in `settings.errorWorkflow` on every active n8n workflow tagged for this customer. Optionally fire a deliberate bad-input execution to confirm a row lands in `workflow_errors`. |

---

## The flow

### Stage 1 — Context gather (silent; no questions to the operator)

Before asking ANYTHING, fill in what you can. Check in order:

1. **Your project's `CLAUDE.md` (optional)** — if the current project has a CLAUDE.md at the project root, it may carry known agent IDs, Telnyx numbers, prompt URLs for past customers. Reuse these when onboarding a new instance of an existing customer. Skip if absent.
2. **Your auto-memory (optional)** — if Claude Code has logged customer details for the current project (e.g. `~/.claude/projects/<project-key>/memory/MEMORY.md`), it may have per-customer project details worth re-using. Skip if absent.
3. **Supabase `workspaces`** — `SELECT slug, name, ultravox_agent_ids, config FROM workspaces` via `mcp__supabase__execute_sql`. If the customer already has a row, flip to update-config mode (see bottom).
4. **Ultravox API** (`ULTRAVOX_API_KEY` is always available after Stage 0):
   ```bash
   curl -H "X-API-Key: $ULTRAVOX_API_KEY" https://api.ultravox.ai/api/agents/{agent_id}
   ```
   — returns the agent's current prompt, attached tools, voice, call-ended webhook URL, inactivity messages. Use to infer: customer archetype, tool set for taxonomy, current webhook state.
5. **Project-local `prompts/*.md`** — if the operator's project keeps prompt files for known customers, those can be referenced.

From these, fill in automatically:
- Customer name + slug (guess from agent name; flag a 1-line confirmation)
- Timezone — default `Australia/Sydney` unless project CLAUDE.md says otherwise
- Plan — default `inbound` for receptionist agents (pattern-match on the prompt)
- `ultravox_agent_ids` — from project CLAUDE.md or the operator
- `telnyx_numbers` — from project CLAUDE.md or the operator
- Attached tool list — from Ultravox API's `selectedTools` array

### Stage 2 — Ask the operator only what you couldn't infer

Normally this is just:

- **Primary user email + name** — the customer's human contact. (Not inferrable.)
- **Final confirmation** on the inferred slug + name.

Ask the business description ONLY if:
- The customer is brand-new and has no analogue in project CLAUDE.md / memory
- Ultravox agent prompt isn't accessible (no API key)

If the customer is a known archetype (Teleca-like telco), skip business description entirely and reuse the Teleca taxonomy from `examples/teleca.json`.

### Stage 3 — Taxonomy

Three paths:

**a) Known archetype → reuse.** If the customer resembles Teleca/TelcoWorks (toll-free number provider, etc.), load `examples/teleca.json` verbatim. No LLM call.

**b) Plausible adaptation → LLM draft.** If customer is a new vertical (dental clinic, solar installer, law firm, etc.), call the LLM using `prompts/generate-taxonomy.md` with Teleca + dental-clinic as few-shots. Inputs: inferred business description + attached tools.

**c) Can't draft → fallback.** If LLM fails validation twice, copy Teleca taxonomy and flag in output: "couldn't generate custom taxonomy — using Teleca defaults, edit in /settings after apply".

Validate any drafted taxonomy:
- 5–8 intents, 5–8 outcomes
- snake_case keys, unique within each array, 1–40 chars
- Descriptions ≤120 chars
- Colors from pinned palette (see `prompts/generate-taxonomy.md`)
- `abandoned` + `unclassified` outcomes present
- If `warm_transfer` in attached_tools: `transferred_to_team` + `transfer_failed` present
- If `*SendSMS` / `*SendNumberInfo` tool: at least one `*_sent` outcome present

### Stage 4 — Preflight checks

**Run these before Apply. Don't skip.**

```sql
-- Is the slug already taken?
SELECT id, name FROM workspaces WHERE slug = $SLUG;
-- If row → ask: update-config / overwrite / cancel

-- Are any of the agent_ids already claimed?
SELECT slug, name FROM workspaces WHERE ultravox_agent_ids && ARRAY[$AGENT_IDS]::text[];
-- If row → STOP with the conflicting workspace name
```

Never silently overwrite.

### Stage 5 — Confirm

Print the full plan as markdown tables (not raw JSON):

- Workspace row (name, slug, plan, timezone, agent_ids, telnyx_numbers, primary_user_email)
- Intents table (key | label | description | color-swatch)
- Outcomes table (same)
- Config keys being populated (`intents`, `outcomes`, `stat_cards`, `company_description`, `email_recipient`, `taxonomy_generated_at`, `agent_names`)

**`agent_names` format — one entry per Ultravox agent ID, value = the agent's first name as it should appear on `/calls` avatars and summary rows.** The dashboard's call-ended handler reads this map to stamp `calls.agent_name`; avatars and the colour-chip derive from the first character. Use a clean first name (e.g. `Jack`, not `TelcoWorks-Jack`) otherwise every row in the customer's dashboard shows a "T" chip and their agent looks generic. Example:

```json
"agent_names": {
  "4f5eab4b-a357-4995-a06d-d4a5e3dfb94a": "Jack",
  "052d9e4f-360f-4cfa-bae2-d17b0eb101f3": "Emma"
}
```

If the operator hasn't told the skill the agent display names, infer from the Ultravox agent's `name` field (stripping any `<Workspace>-` prefix) and confirm in the plan output before Stage 6 applies. If an agent gets renamed later, update both `config.agent_names` AND back-fill existing `calls.agent_name` for that `agent_id` (UI reads the stamped value, not the live config).

The operator types one of:
- `confirm` → apply
- `edit intents` / `edit outcomes` → regen that section
- `edit <field>` → drop back to that gather question
- `cancel` → abort, nothing written

### Stage 6 — Apply

**Step 6a — Insert the workspace row (atomic, via MCP):**

```sql
INSERT INTO workspaces (name, slug, plan, timezone, telnyx_numbers, ultravox_agent_ids, config)
VALUES ($NAME, $SLUG, $PLAN, $TIMEZONE, $TELNYX_NUMBERS::text[], $ULTRAVOX_AGENT_IDS::text[], $CONFIG::jsonb)
RETURNING id;
```

Grab the returned `workspace_id`.

### Step 6b — Invite the primary user via Supabase Auth Admin API

Requires `SUPABASE_SERVICE_ROLE_KEY` + `SUPABASE_URL` (loaded from `.env` at Stage 0 — no manual Studio clicks). If either is unset, STOP and tell the operator:

```
I need SUPABASE_SERVICE_ROLE_KEY and SUPABASE_URL in your .env to
invite the user in one shot. Add them and re-run.
```

Primary path: `POST $SUPABASE_URL/auth/v1/admin/users`. If HTTP 200, capture `.id` as $AUTH_UUID and proceed to 6c.

```bash
curl -sS --ssl-no-revoke -X POST "$SUPABASE_URL/auth/v1/admin/users" \
  -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c "import json,sys; print(json.dumps({'email':sys.argv[1],'email_confirm':True,'user_metadata':{'name':sys.argv[2]}}))" "$USER_EMAIL" "$USER_NAME")"
```

If HTTP 400/422 with an "already exists" style message: the email is already in auth.users (the operator may have invited them before). Fetch the existing UUID:

```bash
curl -sS --ssl-no-revoke "$SUPABASE_URL/auth/v1/admin/users?email=$USER_EMAIL" \
  -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY"
```

Parse the response's first `.users[0].id` as $AUTH_UUID and proceed.

If neither worked: halt and show the response body to the operator.

Then trigger a magic link so the customer can actually sign in:

```bash
curl -sS --ssl-no-revoke -X POST "$SUPABASE_URL/auth/v1/admin/generate_link" \
  -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c "import json,sys; print(json.dumps({'type':'magiclink','email':sys.argv[1]}))" "$USER_EMAIL")"
```

This emails the customer directly (configured via Supabase Auth SMTP). If SMTP isn't set up, the response includes `action_link` — copy that into the Stage 7 output so the operator can forward it.

**Step 6c — Insert the public.users row (via MCP):**

```sql
INSERT INTO public.users (id, email, name, role, workspace_id)
VALUES ($AUTH_UUID::uuid, $USER_EMAIL, $USER_NAME, 'admin', $WORKSPACE_ID::uuid);
```

Use `role='admin'` — the primary customer contact needs admin privileges so they can manage their team themselves (invite/remove users, promote/demote) via Settings → Team, without the operator in the loop. `'viewer'` (the DB default) is for additional team members they invite later. See the Roles note at the bottom.

**Step 6d — Audit trail:**

```sql
INSERT INTO workflow_errors (workspace_id, source, severity, message, payload)
VALUES ($WORKSPACE_ID, 'onboarding', 'info',
        'Workspace onboarded: ' || $SLUG,
        jsonb_build_object('config', $CONFIG::jsonb, 'user_id', $AUTH_UUID));
```

**If 6b or 6c fails after 6a succeeded:** the workspace row is orphaned. Either re-run 6b/6c with the same workspace_id, or DELETE the workspace row and start over. The skill should detect this state on re-run (workspace exists, no matching user) and resume from 6b.

### Stage 7 — Wire up Ultravox (operator does this, skill instructs)

Print this exact message to the operator (substitute values):

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ Workspace created: {NAME} (slug: {SLUG})
✅ Primary user: {USER_EMAIL}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Now wire up each Ultravox agent — one manual step per agent:

{FOR EACH agent_id IN ULTRAVOX_AGENT_IDS}
  → https://app.ultravox.ai/agents/{agent_id}
    Integrations → Webhooks → set `call.ended` URL to:
       $DASHBOARD_SERVER_URL/webhooks/call-ended

That's the only dashboard wiring step. Tool webhooks (transfer, SMS)
stay pointed at your per-customer server.

When you're done, run: /onboard-customer verify {SLUG}
```

### Stage 7b — Wire error reporting

Every customer tool must log failures to the dashboard. Run this after Stage 7 is complete (or in parallel with it — Ultravox webhook wiring and n8n errorWorkflow wiring are independent).

**Env dependency check (run first — halts the stage if any var is missing):** this stage requires three env vars — `N8N_BASE_URL`, `N8N_API_KEY`, and `N8N_ERROR_REPORTER_WORKFLOW_ID`. If any is missing, the curl calls below will hit a malformed URL or auth-fail with confusing errors. Fail fast:

```bash
for v in N8N_BASE_URL N8N_API_KEY N8N_ERROR_REPORTER_WORKFLOW_ID; do
  eval "val=\$$v"
  [ -n "$val" ] || { echo "Stage 7b halted — $v is not set. See ENV_SETUP.md section 4."; return 1 2>/dev/null || exit 1; }
done
```

**For n8n workflows** (the common case — most tools route through n8n):

1. Enumerate the customer's workflows:
   ```bash
   curl -sS --ssl-no-revoke "$N8N_BASE_URL/api/v1/workflows?tags=$SLUG" \
     -H "X-N8N-API-KEY: $N8N_API_KEY"
   ```
2. For each workflow, PATCH its settings to include the central reporter as the error workflow. Preserve any existing settings keys — don't nuke them:
   ```bash
   curl -sS --ssl-no-revoke -X PATCH "$N8N_BASE_URL/api/v1/workflows/$WORKFLOW_ID" \
     -H "X-N8N-API-KEY: $N8N_API_KEY" \
     -H "Content-Type: application/json" \
     -d "$(python3 -c "import json,sys; print(json.dumps({'settings': {**json.loads(sys.argv[1] or '{}'), 'errorWorkflow': sys.argv[2]}}))" "$EXISTING_SETTINGS_JSON" "$N8N_ERROR_REPORTER_WORKFLOW_ID")"
   ```
   (Fetch `$EXISTING_SETTINGS_JSON` from the workflow's current `settings` object via the `GET` in step 1; pass `""` or `"{}"` if none.)
   Where `$N8N_ERROR_REPORTER_WORKFLOW_ID` is the central reporter (created once at dashboard setup; see `docs/runbooks/n8n-error-wiring.md`).
3. Verify by re-fetching and checking `settings.errorWorkflow === $N8N_ERROR_REPORTER_WORKFLOW_ID` on each workflow. If any didn't stick, retry once then report which ones failed.

**For customer-server code** (if the customer gets their own Railway server):

1. Instruct the operator to add `voice-tools-shared/error-reporter` as a dep: `npm install file:../voice-tools-shared` (or copy the file if they prefer no shared dep).
2. Show the 3-line import + wrap pattern for every `catch` block that currently does a `console.error`:
   ```js
   const { reportError } = require('voice-tools-shared/error-reporter');
   // inside catch:
   reportError({ source: '<slug>-server', severity: 'error', message: err.message, payload: { stack: err.stack, ...context } });
   ```

**For Ultravox agent tool webhooks** (covered automatically):

Agent tool failures detected during call transcript analysis already flow to `workflow_errors` with `source='agent-tool'`. No extra wiring needed — just confirm the Ultravox `call.ended` webhook is set (Surface 1).

**Dependency:** Stage 7b requires `N8N_BASE_URL`, `N8N_API_KEY`, and `N8N_ERROR_REPORTER_WORKFLOW_ID` (see env check block above). Additionally, the central error-reporter n8n workflow must already exist on the n8n instance. If `N8N_ERROR_REPORTER_WORKFLOW_ID` is unset or the ID doesn't resolve via `GET /api/v1/workflows/{id}`, skill halts with: "create the global error reporter n8n workflow first — see `docs/runbooks/n8n-error-wiring.md`."

**Empty-tag case:** If `workflows?tags=<slug>` returns an empty array (brand-new customer with no workflows yet), the PATCH loop iterates zero times — this is the expected state. Nothing to do; Stage 7b completes as a no-op. Re-run this stage after deploying any customer-specific workflows in n8n.

### Stage 8 — Verify (separately invoked)

`/onboard-customer verify {slug}` runs this checklist:

1. **Workspace exists + correct shape**
   ```sql
   SELECT id, name, slug, plan, timezone, ultravox_agent_ids, telnyx_numbers,
          config->'intents' AS intents,
          config->'outcomes' AS outcomes,
          config->'stat_cards' AS stat_cards
   FROM workspaces WHERE slug = $1;
   ```
   Confirm: non-empty `ultravox_agent_ids`, non-empty `intents`, non-empty `outcomes`, timezone is valid IANA zone.

2. **User exists**
   ```sql
   SELECT email, name, role, workspace_id FROM users WHERE workspace_id = $WORKSPACE_ID;
   ```
   Confirm: exactly one row for the primary contact with `role = 'admin'` (see Roles note). Additional users invited later via Settings → Team land as `'viewer'`.

3. **Ultravox agent exists and is readable** (requires `ULTRAVOX_API_KEY`)
   ```bash
   for id in $AGENT_IDS; do
     code=$(curl -sS --ssl-no-revoke -o /dev/null -w "%{http_code}" \
       -H "X-API-Key: $ULTRAVOX_API_KEY" "https://api.ultravox.ai/api/agents/$id")
     if [ "$code" = "200" ]; then
       echo "$id: ✅ exists"
     else
       echo "$id: ❌ HTTP $code — likely causes: (a) agent was deleted in Ultravox console, (b) agent_id in workspace row is a typo, (c) UPS slot is still propagating. Check https://app.ultravox.ai/agents and verify the workspace row's ultravox_agent_ids field."
     fi
   done
   ```
   This proves the agent_ids in the workspace row actually resolve to real Ultravox agents. It does NOT prove the `call.ended` webhook URL is set — Ultravox's `GET /api/agents/{id}` response does not include webhook subscriptions (stress-test verified 2026-04-18). The webhook-URL-is-correct confirmation comes from step 5 (a real test call landing in the `calls` table).

4. **No cross-tenant violation**
   ```sql
   SELECT slug, name FROM workspaces
   WHERE ultravox_agent_ids && ARRAY[$AGENT_IDS]::text[]
     AND slug != $SLUG;
   ```
   Must be empty. If not, the agent_ids were double-claimed — a critical bug.

5. **Error reporting wired** — for each n8n workflow tagged with the customer slug, confirm `settings.errorWorkflow` equals the central reporter ID (`$N8N_ERROR_REPORTER_WORKFLOW_ID`).
   ```bash
   curl -sS --ssl-no-revoke "$N8N_BASE_URL/api/v1/workflows?tags=$SLUG" \
     -H "X-N8N-API-KEY: $N8N_API_KEY" \
     | python3 -c "import json,sys,os; d=json.load(sys.stdin); rid=os.environ['N8N_ERROR_REPORTER_WORKFLOW_ID']; [print(('✅' if w.get('settings',{}).get('errorWorkflow')==rid else '❌'), w['id'], w['name']) for w in d.get('data',[])]"
   ```
   If any workflow is missing it, tell the operator which ones — re-run Stage 7b on those specifically.

6. **Recent calls landed (once a test call has been placed)**
   ```sql
   SELECT id, ultravox_call_id, started_at, status, outcome, intent, summary IS NOT NULL AS has_summary
   FROM calls WHERE workspace_id = $WORKSPACE_ID
   ORDER BY started_at DESC LIMIT 3;
   ```
   If zero rows after 60s of placing a call: check `workflow_errors`:
   ```sql
   SELECT severity, message, created_at FROM workflow_errors
   WHERE created_at > now() - interval '5 minutes' AND source = 'call-ended'
   ORDER BY created_at DESC LIMIT 5;
   ```

7. **Attribution sanity** — take the most recent call, confirm its `workspace_id` matches.

Print a green/red summary:

```
Verify {SLUG}:
  ✅ Workspace row exists with correct config
  ✅ Primary user created
  ✅ Ultravox agents webhook set (2/2)
  ✅ No cross-tenant conflicts
  ✅ Error reporting wired on all n8n workflows (N/N)
  ⚠️  No test calls yet — place a call and re-run
```

### Failure-mode diagnostics

When `/onboard-customer verify` reports a ❌, print the specific diagnosis:

| Symptom | Root cause | Fix |
|---|---|---|
| Test call placed but no `calls` row | `call.ended` webhook URL wrong or missing in Ultravox | Re-run step 3 of verify; if still broken, the operator re-pastes the URL in Ultravox console |
| `calls` row exists but `workspace_id` is different | `agent_id` in Ultravox ≠ anything in `workspaces.ultravox_agent_ids` for this slug | Update the workspace row's agent_ids array with the real ID (SQL UPDATE) |
| `calls` row exists but `outcome` is a default like 'converted' not a customer-specific key | `workspace.config.outcomes` wasn't set correctly at apply time | Re-open /settings → Outcomes editor and save — triggers re-classification on next call |
| Cross-tenant violation (one agent_id in 2 workspaces) | Someone onboarded this customer twice, or agent_id was reused | DELETE the duplicate workspace or reassign the agent_id |
| `workflow_errors` severity='error' source='analysis' | GPT call failed or schema-invalid | Check the payload for the specific error; usually an OpenAI rate limit or a malformed transcript |
| n8n workflow fails silently, nothing in /admin/health | `settings.errorWorkflow` not set | Re-run `Stage 7b`, or manually PATCH the workflow |

---

## Commands

- `/onboard-customer` — guided flow. Infers from conversation context + project CLAUDE.md + memory. Asks the operator only for novel info.
- `/onboard-customer [name]` — target a specific customer (skips the "who are we onboarding" inference).
- `/onboard-customer verify [slug]` — re-verify wiring of an existing workspace. Can be run any time.
- `/onboard-customer undo [slug]` — delete workspace. Refuses if it has calls with `is_test = false`, unless the operator types the slug to confirm.

## Update-config semantics

If `/onboard-customer` is run with a slug that already exists, offer three paths:

1. **update-config** — re-gather only the fields the operator names (e.g. "just update intents and outcomes"). Applies via `jsonb_set` UPDATE, preserving other /settings edits.
2. **overwrite** — full re-run from scratch. Blows away config. Requires the operator to type the slug to confirm.
3. **cancel** — exit.

Never silently overwrite.

## Undo command

```sql
-- Safety check
SELECT count(*) FROM calls WHERE workspace_id = $WORKSPACE_ID AND is_test = false;
-- If > 0 and the operator didn't type the slug to confirm → refuse
```

**Dynamic FK safety check (run BEFORE the hardcoded cascade).** The hardcoded list below will drift as the schema evolves. Before any undo, query `pg_constraint` for every table that currently references `workspaces` and `users` and add a DELETE for anything not already in the cascade list:

```sql
SELECT conrelid::regclass AS referencing_table
FROM pg_constraint
WHERE confrelid = 'public.workspaces'::regclass AND contype = 'f';
```

```sql
SELECT conrelid::regclass AS referencing_table
FROM pg_constraint
WHERE confrelid = 'public.users'::regclass AND contype = 'f';
```

If either query returns a table not listed in the cascade block below, add a `DELETE FROM <table> WHERE workspace_id = $1;` (or equivalent FK column) BEFORE the `workspaces` / `users` delete. If you skip this and the schema has drifted, the cascade will FK-fail mid-run and leave an orphaned workspace.

**Capture auth UUIDs BEFORE deleting public.users** (IDs match `auth.users.id` by design — see Surface 2):
```sql
-- Save each returned UUID to a variable ($AUTH_UUIDS) for use after the public-schema cascade.
SELECT id FROM public.users WHERE workspace_id = $1;
```

Then cascade delete in order (child → parent):
```sql
DELETE FROM workflow_errors         WHERE workspace_id = $1;
DELETE FROM judgement_fixes         WHERE workspace_id = $1;
DELETE FROM call_judgements         WHERE workspace_id = $1;
DELETE FROM workspace_judging_usage WHERE workspace_id = $1;
DELETE FROM feedback                WHERE workspace_id = $1;
DELETE FROM call_saves              WHERE call_id IN (SELECT id FROM calls WHERE workspace_id = $1);
DELETE FROM judgement_clusters      WHERE workspace_id = $1;
DELETE FROM weekly_batch_runs       WHERE workspace_id = $1;
DELETE FROM calls                   WHERE workspace_id = $1;
DELETE FROM users                   WHERE workspace_id = $1;
DELETE FROM workspaces              WHERE id = $1;
```

**Then delete the auth.users row(s)** so the ex-customer can't magic-link back in. `public.users` is gone but the `auth.users` row persists unless explicitly removed — a customer with a valid auth.users row can still receive magic links and sign in (they'd hit a blank dashboard because `public.users` is missing, which is still a security failure, not an offboarding):

```bash
# AUTH_UUIDS was captured before the public.users delete (see above).
for uuid in $AUTH_UUIDS; do
  curl -sS --ssl-no-revoke -X DELETE "$SUPABASE_URL/auth/v1/admin/users/$uuid" \
    -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
    -w "auth.users DELETE $uuid: HTTP %{http_code}\n"
done
```

- If the workspace had multiple `public.users` rows (future: multi-user per workspace), delete every matching `auth.users` row — iterate over every captured UUID.

## What this skill does NOT do

- Create Ultravox agents or edit their prompts (CLAUDE.md: never touch agents via API)
- Configure Telnyx TeXML apps or phone numbers
- Deploy or configure the customer's per-customer Railway service
- Configure tool webhooks (transfer, SMS, etc.) — those live on the customer's own server
- Send a welcome email
- Invite additional users — the primary contact does this themselves via Settings → Team (they're role=`'admin'`, which gives them invite/remove/promote rights within their own workspace)

## Notes to future-me running this skill

- The dashboard is already fully multi-tenant. The wiring is genuinely one webhook URL + one SQL insert. Everything else is confirmation and verification.
- `workspaces.config` is JSONB; all keys are optional with hardcoded defaults, so partial configs work.
- Attribution: `workspaces.ultravox_agent_ids` array CONTAINS on incoming `agentId`. If a call goes missing, check there first.
- **Roles** (UI terminology — see your project CLAUDE.md § Roles & Terminology, if defined):
  - `'superadmin'` (DB) = **owner** (UI): platform operator. One per platform.
  - `'admin'` (DB) = **admin** (UI): customer CEO / primary contact. Can manage their team + rename outcome/intent **labels** (not descriptions, not keys). Scoped to their workspace.
  - `'viewer'` (DB) = **user** (UI): read-only team member. Sees calls/analytics, no mutations.
  - `'owner'` (DB) = legacy/unused — don't assign.
  - **Onboarding default:** primary customer contact gets `'admin'` (Stage 6c). They invite additional team members themselves via Settings → Team; those invites default to `'viewer'`.
- **Owner-only taxonomy retro-reclassify:** when the platform owner edits an outcome/intent *description* (not label) via Settings on an existing workspace, the save triggers a background backfill that re-classifies historical calls whose current outcome/intent matches the changed keys. Irrelevant at onboarding time (fresh workspace has zero calls), but worth knowing if the taxonomy is tweaked after the customer is live — a save modal will surface the affected call count for confirmation.
- If `calls.intent` column exists but is null on fresh calls, it's because the analysis pipeline hasn't been updated to classify intent yet. Not a blocker for onboarding; ignore.
- **Hard rule:** NEVER PATCH an Ultravox agent's `callTemplate` via API — it wipes unrelated fields. The only Ultravox API calls you may make are READ (GET /api/agents/{id}) for verification.
