# Verification + stress-test plan

Walk through every phase. Tick items as you go. No phase is optional.

**Goal:** every customer onboarding produces correct artifacts, a working live agent, a wired dashboard, a callable phone number, and call summaries hitting your inbox.

---

## Phase 1 — Output stress test (artifact quality)

Test the synthesis prompts against websites of different shapes. Goal: each artifact passes the constitution at ≥9 from 3 independent judges, on each test site.

Sites to test against (pick 5):

- [ ] **Trades** — plumber / electrician with after-hours emergency line (e.g. a Mick-style site)
- [ ] **Health** — dental clinic / physio / chiro with appointment booking
- [ ] **Professional services** — accounting firm or law firm (DSA Law done; pick a different vertical)
- [ ] **Retail** — small e-commerce with phone support
- [ ] **B2B services** — software vendor or marketing agency (AutomateConvert done)

For each site, fire `/base-agent` against it, then run 3 independent judges per `tests/e2e-judging-constitution.md`.

**Pass criteria per site:**

- [ ] All three artifacts (brain-doc, system-prompt, discovery-prompt) score ≥9 from all three judges
- [ ] Brain-doc has a populated `## Knowledge Gaps` section (mechanical, not LLM intuition)
- [ ] Discovery-prompt to-do list mechanically reflects every knowledge gap
- [ ] Vendor-name grep clean on every customer-facing artifact
- [ ] System prompt's `=== UNIVERSAL_RULES ===` opens at rule 1 (no operator commentary)
- [ ] Bespoke opener ≤40 words, exactly one question
- [ ] Discovery-prompt + customer-context naming clean, drag-drop instruction present

**Stress edges:**

- [ ] **No-meeting placeholder** — verified DSA Law + AutomateConvert. Pass.
- [ ] **Real meeting transcript** — feed in a real ~30-min meeting. Verify scope inference works (narrow vs broad).
- [ ] **Site that's already polished** — top-tier brand with explicit pricing, hours, staff. Brain-doc shouldn't pad.
- [ ] **Site that's sparse** — single-page with little content. Brain-doc should be small + flag many gaps.
- [ ] **Site with multi-language** — confirm pronunciation guide and language-routing surface in PROCEDURES.

---

## Phase 2 — Ultravox agent verification

Per customer run, after Stage 6 fires.

- [ ] `agent-created.json` returned a valid `agentId` (UUID)
- [ ] Agent visible in Ultravox console at `https://app.ultravox.ai/agents/{id}`
- [ ] Voice ID matches reference agent (`$REFERENCE_ULTRAVOX_AGENT_ID`)
- [ ] Temperature copied
- [ ] Inactivity messages copied (correct count + content)
- [ ] First-speaker setting copied
- [ ] Model copied
- [ ] `selectedTools` is empty (no tools on rough agent)
- [ ] Agent's `systemPrompt` field matches the assembled five-section prompt byte-for-byte
- [ ] No PATCH attempted (logs clean)
- [ ] Agent name follows `{Customer}-{AgentName}` pattern

---

## Phase 3 — Telephony verification

Per customer run, after Stages 7–9.

- [ ] DID claimed from pool (`pool-available` tag → `claimed-{slug}` added)
- [ ] DID's `connection_id` points at the right TeXML app
- [ ] TeXML app's `voice_url` matches `https://app.ultravox.ai/api/agents/{agent_id}/telephony_xml`
- [ ] TeXML app's `voice_method` = `POST`
- [ ] TeXML app's codec includes `OPUS` (with `G711U` fallback acceptable)
- [ ] TeXML app's `status_callback_url` points at `$DASHBOARD_SERVER_URL/webhooks/call-ended`
- [ ] TeXML app's `status_callback_method` = `POST`
- [ ] Pool count updates correctly (claim decrements; alert at <3)

**Real-call test:**

- [ ] Dial the claimed DID from a mobile
- [ ] Agent picks up, speaks the configured opening line
- [ ] Agent holds a coherent conversation about the business (brain-doc context loaded)
- [ ] Agent declines tool-requiring asks gracefully (per minimal-tool-note)
- [ ] Hang up; check Telnyx call detail record exists
- [ ] No SChannel / TLS errors in `claim-did` or `wire-texml` logs

---

## Phase 4 — Webhook + call-summary verification

Verify `call.ended` flows from Telnyx → Ultravox → dashboard-server → Supabase → email.

- [ ] After the test call, `dashboard-server-production-0ee1.up.railway.app/webhooks/call-ended` received the POST (check Railway logs)
- [ ] Webhook signature verified (Ed25519 against `TELNYX_PUBLIC_KEY`)
- [ ] Dashboard-server fetched transcript + audio from Ultravox
- [ ] Analysis pipeline ran (intent + outcome classified)
- [ ] `calls` row inserted with correct `workspace_id`
- [ ] `calls.transcript` non-empty
- [ ] `calls.summary` populated
- [ ] `calls.outcome` is one of the workspace's declared outcomes (not a default)
- [ ] `calls.intent` populated (not null)
- [ ] `calls.agent_name` matches `workspace.config.agent_names[<agent_id>]`
- [ ] If summary-email setting is enabled in workspace config: email arrives at `OPS_ALERT_EMAIL` (initially) or customer email (post-go-live)
- [ ] Email contains: caller info, intent, outcome, summary, transcript link

**Failure-flow tests:**

- [ ] Webhook signature invalid → server rejects 401, no row inserted
- [ ] Agent-id not in any workspace's `ultravox_agent_ids[]` → `workflow_errors` row written, no `calls` row
- [ ] Two workspaces share an agent-id → cross-tenant violation flagged

---

## Phase 5 — Dashboard verification (`/onboard-customer`)

Per customer run, after Stage 11.

- [ ] `workspaces` row inserted with: `slug`, `name`, `plan`, `timezone`, `ultravox_agent_ids`, `telnyx_numbers`, `config` (intents + outcomes + stat_cards + agent_names)
- [ ] `auth.users` row created via Supabase Auth Admin API
- [ ] `public.users` row created with `id` matching `auth.users.id` (Surface 2 invariant)
- [ ] `public.users.role` = `'admin'` for primary contact
- [ ] `public.users.workspace_id` matches the new workspace
- [ ] Magic-link generated (or `action_link` returned if SMTP not configured)
- [ ] `workflow_errors` audit row inserted (severity=info, source=onboarding)
- [ ] n8n workflows tagged with the slug have `settings.errorWorkflow` set to `$N8N_ERROR_REPORTER_WORKFLOW_ID` (no-op if no workflows yet)
- [ ] `/onboard-customer verify {slug}` returns all green ticks (except "no test calls yet" before Phase 4 test)
- [ ] Magic link successfully signs the test user in to `app.spotfunnel.com`
- [ ] User sees the new workspace
- [ ] Calls page renders the test call (after Phase 4)
- [ ] Outcomes + intents render correctly per `workspace.config`

**Cleanup verification:**

- [ ] `/onboard-customer undo {slug}` cleanly cascades: `workflow_errors`, `judgement_*`, `calls`, `users`, `workspaces`, then `auth.users`
- [ ] Test user can no longer sign in after undo

---

## Phase 6 — End-to-end real-world tests

- [ ] **Stub run** — Redgum Plumbing (or similar invented business). Full skill end-to-end. Tear down after.
- [ ] **First real customer** — recent prospect with real meeting transcript. Time-to-ready ≤ 30 min target. Test-dial. Email customer the discovery prompt.
- [ ] **Second real customer** — different vertical. Time-to-ready ≤ 30 min.
- [ ] **Third real customer** — different vertical. Methodology gaps surfacing across customers 1–3 get fed back into `reference-docs/discovery-methodology.md`.

---

## Phase 7 — Architecture follow-ups (currently sloppy, fix at scale)

Issues surfaced during the iterative-improvement loop. Each is real but not blocking.

- [ ] **Live Ultravox agent doesn't pick up system-prompt regenerations.** Stage 6 only runs once. Fix: add a `/base-agent regenerate-agent {slug}` command that POSTs a new agent + flags the old for deletion + updates the workspace's `ultravox_agent_ids`.
- [ ] **Round-by-round artifact history.** Currently overwrite-in-place. Fix: snapshot to `runs/{slug}/round-{N}/` on each Stage 3/4/10 regeneration.
- [ ] **Forbidden-substring blacklist duplicated.** Lives in both `synthesize-brain-doc.md` and `generate-discovery-prompt.md`. Fix: extract to `templates/forbidden-substrings.txt`, both prompts reference it.
- [ ] **Brain-doc immutability not enforced.** Stage 4 says read-only, no checksum check. Fix: write checksum-before, verify-after.
- [ ] **`example-agents/` no-fact-leak rule is mental-grep only.** Fix: post-Stage-4 grep for known facts (specific phone numbers, addresses, staff names from example-agents) against the regenerated brain-doc/system-prompt.
- [ ] **Customer-context assembly is prompt-based, not scripted.** Fix: write `scripts/assemble-customer-context.sh` that takes brain-doc + transcript + hints + methodology and produces customer-context.md deterministically.
- [ ] **Operator-hint sanitization was reactive.** Round 6 blacklist landed after the leakage shipped. Fix: add a CI-style integration test that runs `/base-agent` against a fixture with adversarial operator hints and asserts zero forbidden substrings in any artifact.
- [ ] **TeXML drift caught only in production.** Add a startup check that hits Telnyx + Firecrawl + Ultravox API health endpoints to surface API-shape changes early.

---

## Phase 8 — Skill itself

- [ ] `improve-codebase-architecture` skill (Matt Pocock) — run it against `base-agent-setup/` to surface deepening opportunities
- [ ] `tdd` skill (Matt Pocock) — adopt for any new bash helpers or API integrations
- [ ] Delete any unused/dead code paths (`.gen-discovery-r5.py`, etc. — leftover from iteration loop)

---

## Cross-cutting acceptance

A customer onboarding is "verified" only when every checkbox in Phases 1 (for the relevant vertical), 2, 3, 4, 5 passes for that customer. Phases 6, 7, 8 are project-level not per-customer.
