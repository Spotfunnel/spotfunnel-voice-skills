---
name: base-agent-setup
description: Automates voice-AI customer onboarding end-to-end. Invoked as /base-agent or /base-agent [customer]. Scrapes the customer's website, synthesizes a knowledge-base brain doc from site + meeting transcript + operator hints, creates a rough Ultravox agent (no tools, no call flows yet) with voice/temperature/inactivity settings copied from a configured reference agent, claims a Telnyx DID from the operator's pool and wires TeXML + telephony_xml, generates a bespoke ChatGPT-ready discovery prompt the customer pastes into ChatGPT to write a detailed brief back, then hands off to /onboard-customer for dashboard wiring. Resumable across crashes via per-run state files. Use when the operator says "/base-agent", "onboard [name] from scratch", "new customer base agent", or starts the post-meeting onboarding flow.
user_invocable: true
---

# base-agent-setup

> **For Claude:** This skill orchestrates 11 stages, each writing to `runs/{slug}-{timestamp}/state.json` on completion. Re-invocation with the same slug resumes from the last successful stage.

The flow: scrape → brain-doc → rough system prompt → Ultravox agent (POST only, never PATCH) → Telnyx DID claim → TeXML wiring → telephony_xml repoint → discovery prompt + cover email → handoff to `/onboard-customer`. Every stage is checklist-enforced. Halt-on-error is the default; resume picks up from the last `done` stage.

You are the operator-facing orchestrator. You read each stage in order, run the script or apply the prompt, parse the output, write state, and move on. You do not improvise the order. You do not skip stages. If a stage halts, you surface the error verbatim and stop — Leo decides whether to fix and resume.

---

## Runtime notes (Windows + Git Bash gotchas)

- **Every `curl` needs `--ssl-no-revoke`.** Windows SChannel CRL checks fail intermittently against Supabase, Ultravox, Telnyx, and Resend. The flag bypasses revocation but still TLS-verifies the endpoint — safe. Every script in `scripts/` already does this; if you find yourself writing a curl ad-hoc, include the flag.
- **`jq` is not installed.** Use Python3 with stdin JSON parsing for any structured output transformation (matches the pattern in `scripts/state.sh`). Don't pipe to `jq -r`.
- **`/tmp/` paths in Git Bash do not map to a Windows path Python can read.** For any file handed from `curl` to a Python helper, use a portable temp path like `${TMPDIR:-$HOME/.tmp-spotfunnel-skills}/...` (create the dir if missing, `rm -rf` when done).
- **Skill scripts source `.env` via `scripts/env-check.sh`** which resolves the env file in this order: `$SPOTFUNNEL_SKILLS_ENV` → `<repo-root>/.env` → cached path at `~/.config/spotfunnel-skills/env-path`. See [ENV_SETUP.md](ENV_SETUP.md).
- **Run-dir convention.** Every run gets its own directory under `base-agent-setup/runs/{slug}-{ISO_TS}/`. The path is exported as `STATE_RUN_DIR` once `state_init` runs; every subsequent script writes into that dir.
- **Never PATCH an Ultravox agent.** This is the cardinal rule of this skill. Corrections to the rough agent require a NEW POST and discarding the old agent_id. The `scripts/ultravox-create-agent.sh` script POSTs only — there is no PATCH variant by design.

---

## Stage 0 — Env preflight

**Goal:** verify every required env var is present before any network call.

### What to do

Run the env check as a one-shot. The script resolves the `.env` file portably and exits non-zero if any required variable is missing.

```bash
bash scripts/env-check.sh
```

Required vars (each documented in `.env.example` at repo root):

- `ULTRAVOX_API_KEY`, `TELNYX_API_KEY`, `FIRECRAWL_API_KEY`
- `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`
- `RESEND_API_KEY`, `RESEND_FROM_EMAIL`, `OPS_ALERT_EMAIL`
- `REFERENCE_ULTRAVOX_AGENT_ID` — the operator's chosen reference agent (e.g. TelcoWorks-Jack)
- `DASHBOARD_SERVER_URL` — used by the `/onboard-customer` handoff at Stage 11
- `N8N_BASE_URL`, `N8N_API_KEY`, `N8N_ERROR_REPORTER_WORKFLOW_ID` — used by `/onboard-customer` Stage 7b

For the rest of the run you also need env loaded into the current shell, so subsequent stages can `$ULTRAVOX_API_KEY` etc. directly. Source it once:

```bash
set -a; source scripts/env-check.sh >/dev/null; set +a
```

### Halt conditions

- Any `[MISSING]` line in the script output → halt. Print the exact missing var name and the message: *"missing X — see `.env.example` at repo root for what to put here."* Do not proceed.
- The script can't locate any `.env` file → halt. Surface the resolution-order list (env var → repo root → cached path) and ask the operator to set `SPOTFUNNEL_SKILLS_ENV` or place a `.env` at the repo root.

### Resume note

Stage 0 is cheap and must always run on every invocation, including resumes. It does not write state. Re-running it on a resume is the correct behavior — the env file may have changed between invocations.

---

## Stage 1 — Gather inputs

**Goal:** collect the five essential inputs from the operator, infer the slug, initialize state.

### Essential inputs

| Input | Format | Notes |
|---|---|---|
| Customer legal/trading name | string | Slug inferred (e.g. `acme-plumbing` for "Acme Plumbing"); confirm with operator before proceeding. |
| Website URL | string | Normalized (strip trailing slash, ensure scheme). Quick sanity check that it resolves. |
| Meeting transcript | pasted text in chat | Operator copy-pastes from their inbuilt whisper transcription. May be 500–10,000+ words. |
| Operator hints | one paragraph | "Anything you want the discovery prompt to know that isn't in the meeting." Optional but encouraged. |
| Agent first name | string | e.g. "Steve", "Emma". If the operator says "you pick", suggest a vertical-appropriate first name based on the website. |

### What to do

Ask one question at a time. **Skip any input that's already in the invocation args** (e.g. `/base-agent Acme Plumbing` provides the customer name) **or in recent conversation context** (e.g. the operator just pasted the transcript above without being asked). Don't redundantly re-ask things you already know.

After the customer name is known, infer the slug:

- Lowercase, hyphenated, no special characters.
- Strip common suffixes (`Pty Ltd`, `Inc`, `LLC`, `Limited`).
- Ask the operator to confirm: *"I'll use slug `acme-plumbing` — confirm or paste a different one."*

Once all five inputs are gathered, initialize state:

```bash
source scripts/state.sh
RUN_DIR="$(state_init "$SLUG")"
export STATE_RUN_DIR="$RUN_DIR"
```

The `state_init` call creates `runs/{slug}-{ISO_TS}/` and writes the initial `state.json`. Capture the returned run-dir path into `STATE_RUN_DIR` so every subsequent stage can write into it.

Then write each input to state:

```bash
state_set customer_name "$CUSTOMER_NAME"
state_set website "$WEBSITE"
state_set agent_first_name "$AGENT_FIRST_NAME"
state_set operator_hints "$OPERATOR_HINTS"
```

The meeting transcript can be long — write it to a file rather than as a state value:

```bash
printf '%s\n' "$MEETING_TRANSCRIPT" > "$STATE_RUN_DIR/meeting-transcript.md"
state_set meeting_transcript_path "$STATE_RUN_DIR/meeting-transcript.md"
```

Mark the stage complete:

```bash
state_stage_complete 1 "{\"slug\": \"$SLUG\", \"website\": \"$WEBSITE\"}"
```

### Halt conditions

- Operator declines to provide one of the essential inputs → halt and explain why each is load-bearing (no website = no scrape; no transcript = brain-doc is just the website; no agent name = can't create the agent).
- Slug collides with an existing run-dir AND the operator hasn't asked to resume → halt and offer to resume the existing run instead.

### Resume note

If a run-dir for this slug already exists (e.g. operator runs `/base-agent resume acme-plumbing`), use `state_resume_from "$SLUG"` to point at the most recent run-dir, then jump directly to the stage returned by `state_get_next_stage`. Don't re-ask any input — re-read it from `state.json`.

---

## Stage 2 — Firecrawl scrape (async)

**Goal:** crawl the customer's website and dump the markdown for downstream brain-doc synthesis.

### What to do

Run the scrape. The script kicks off Firecrawl's v1 async crawl, polls every 5s for up to 5 minutes, and writes per-page markdown plus a flattened `combined.md`.

```bash
WEBSITE="$(bash scripts/state.sh state_get website)"
bash scripts/firecrawl-scrape.sh \
  --url "$WEBSITE" \
  --out-dir "$STATE_RUN_DIR/scrape"
```

The default page cap is 50 (set via `--max-pages` if the operator wants different; configurable via `FIRECRAWL_MAX_PAGES` env override).

### Output schema

- `{run-dir}/scrape/pages/<slug>.md` — one file per crawled page. Filename is a slug of the source URL.
- `{run-dir}/scrape/combined.md` — all pages joined with `<!-- source: ... -->` headers and `---` separators. This is the file Stage 3 reads.

### What to report

Print the scrape progress to the operator while it's running (the script emits `[INFO] poll #N: status=scraping` lines). On completion, surface:

- Pages scraped (final count).
- Total characters in `combined.md`.
- Whether the page cap was hit (compare pages-scraped to `--max-pages`).

If the cap was hit, flag it so the operator knows the brain-doc may be incomplete:

> *"Scrape hit the 50-page cap. Brain-doc will be built from the first 50 pages only. Re-run with `--max-pages 100` if the customer's site is genuinely larger and you want full coverage."*

Mark the stage complete:

```bash
PAGES_SCRAPED="$(ls "$STATE_RUN_DIR/scrape/pages" | wc -l)"
state_stage_complete 2 "{\"pages\": $PAGES_SCRAPED}"
```

### Halt conditions

- Firecrawl kickoff returns HTTP ≥400 → halt. Most likely cause: API key invalid or Firecrawl free-tier credits exhausted (per the [Firecrawl tier note in MEMORY.md](memory:project_firecrawl_tier.md), expect rate/credit limits during dev).
- Polling times out at 5 minutes (`status` never becomes `completed`) → halt with the last status. Probably a very large site or Firecrawl backend slowness.
- `combined.md` is zero bytes after the script returns → halt. The site may be JS-only with no markdown extractable, or the URL was wrong.

### Resume note

The scrape directory is the resume marker. If `{run-dir}/scrape/combined.md` already exists from a previous attempt, skip the scrape and jump to Stage 3. The operator can force a re-scrape by deleting the directory.

---

## Stage 3 — Brain-doc synthesis (Claude inline)

**Goal:** produce a structured markdown brain-doc that downstream stages depend on.

### What to do

This stage runs **inline in your Claude Code conversation** — no API call, no script. Read the prompt and apply it.

1. Read `prompts/synthesize-brain-doc.md` in full. It is the operating manual for this stage.
2. Read the three inputs:
   - `{run-dir}/scrape/combined.md` (from Stage 2).
   - `{run-dir}/meeting-transcript.md` (from Stage 1).
   - The operator hints, available via `bash scripts/state.sh state_get operator_hints`.
3. Apply the prompt's structure rules: nine fixed H2 sections (`## Identity`, `## Services`, `## Hours`, `## Locations & Service Area`, `## Staff`, `## Contact`, `## Policies & Pricing`, `## Tone & Voice`, `## Notable from Meeting`), every fact tagged with one of `[confirmed: site + meeting]` / `[from site only]` / `[from meeting only]` / `[inferred]`. Empty sections render as `_(no information)_` — never omit a heading.
4. Write the output to `{run-dir}/brain-doc.md`.

### Output schema

- File: `{run-dir}/brain-doc.md`
- Size target: 3–8 KB (≈500–1300 words).
- Structure: nine H2 sections in the prompt's specified order, every fact source-tagged, conflicts between site and meeting flagged inline.

Mark the stage complete:

```bash
SIZE="$(wc -c < "$STATE_RUN_DIR/brain-doc.md")"
state_stage_complete 3 "{\"size_bytes\": $SIZE}"
```

### Halt conditions

- Brain-doc would exceed 12 KB → soft halt. Tell the operator the source material is too verbose; offer to trim the meeting transcript and re-run, or accept the oversized doc and proceed.
- One of the three inputs is missing (e.g. `combined.md` not produced, transcript file empty) → halt.
- The site and meeting are both effectively empty (e.g. Firecrawl returned 1 page of generic copy and the transcript is 50 words) → write the brain-doc with mostly `_(no information)_` sections, surface a warning to the operator that downstream quality will be poor, but continue.

### Resume note

If `{run-dir}/brain-doc.md` already exists with a non-zero size, skip Stage 3 and jump to Stage 4. To force regeneration, delete the file and re-invoke. Re-running Stage 3 is cheap — it's just a Claude inline pass.

---

## Stage 4 — Rough system prompt assembly (Claude inline)

**Goal:** compose the agent's `systemPrompt` by concatenating four layers in a specific order.

### What to do

Like Stage 3, this is an inline Claude pass — no API, no script.

1. Read `prompts/assemble-rough-system-prompt.md` in full.
2. Read the inputs the prompt requires:
   - `templates/universal-rules.md` — the canonical 16-rule base, verbatim.
   - `{run-dir}/brain-doc.md` — from Stage 3.
   - `customer_name` and `agent_first_name` from state (`bash scripts/state.sh state_get customer_name`).
3. Apply the prompt's exact concatenation order with the four literal section delimiters:

   ```
   === UNIVERSAL_RULES ===

   <templates/universal-rules.md>

   === AGENT_IDENTITY ===

   You are {agent_first_name}, the receptionist for {customer_name}. ...

   === BRAIN_DOC ===

   <{run-dir}/brain-doc.md>

   === MINIMAL_TOOL_NOTE ===

   You currently have no action tools — ...
   ```

   Substitute `{customer_name}` and `{agent_first_name}` only inside the `=== AGENT_IDENTITY ===` block. Do **not** substitute placeholders inside `templates/universal-rules.md` or the brain-doc — they're filled in elsewhere or left as literal placeholders for runtime substitution.

4. Write the output to `{run-dir}/system-prompt.md`.

### Output schema

- File: `{run-dir}/system-prompt.md`
- Size target: 10–20 KB.
- Soft cap: 25 KB (halt and ask operator to trim the brain-doc).
- Lower-bound warning: under 4 KB likely means an empty brain-doc (warn but continue).

Mark the stage complete:

```bash
SIZE="$(wc -c < "$STATE_RUN_DIR/system-prompt.md")"
state_stage_complete 4 "{\"size_bytes\": $SIZE}"
```

### Halt conditions

- Assembled prompt exceeds 25 KB → halt with the message in the prompt: *"Assembled system prompt is N KB, over the 25 KB safety cap. Trim the brain-doc and re-run Stage 4."*
- A literal `{customer_name}` or `{agent_first_name}` placeholder remains anywhere in the `AGENT_IDENTITY` block after assembly → halt (substitution failed).
- Any of the four delimiters is missing or duplicated → halt.

### Resume note

If `{run-dir}/system-prompt.md` already exists with a non-zero size, skip Stage 4 and jump to Stage 5. Re-running this stage is cheap; delete the file to force regeneration.

---

## Stage 5 — Reference agent settings pull

**Goal:** pull `voice`, `temperature`, `firstSpeakerSettings`, `inactivityMessages`, `model`, etc. from a known-good Ultravox reference agent so the new rough agent inherits proven settings.

This stage is **load-bearing** — Stage 6 cannot create the agent without these settings. Halt on any failure.

### What to do

```bash
bash scripts/ultravox-get-reference.sh --out "$STATE_RUN_DIR"
```

The script defaults `--agent-id` to `$REFERENCE_ULTRAVOX_AGENT_ID` (set in `.env`). Override with `--agent-id <uuid>` only if the operator explicitly wants a different reference for this customer (e.g. a vertical-specific reference agent).

### Output schema

File: `{run-dir}/reference-settings.json` containing the curated subset:

```json
{
  "sourceAgentId": "...",
  "voice": { "voiceId": "...", "name": "..." },
  "model": "...",
  "languageHint": "en",
  "temperature": 0.4,
  "firstSpeakerSettings": { "agent": {} },
  "inactivityMessages": [ ... ],
  "vadSettings": { ... },
  "voiceOverrides": { ... },
  "recordingEnabled": false,
  "selectedTools": [ ... ]
}
```

Note: `selectedTools` is captured for audit but Stage 6 ships an empty array regardless — the rough agent has no action tools by design.

Stdout summary line: `voice=<voice_id>, temperature=<value>, model=<value>, inactivityMessages=<count>`.

Mark the stage complete:

```bash
state_stage_complete 5 "{\"reference_agent_id\": \"$REFERENCE_ULTRAVOX_AGENT_ID\"}"
```

### Halt conditions

- Ultravox `GET /api/agents/{id}` returns HTTP ≥400 → halt with the response body. Most likely cause: `REFERENCE_ULTRAVOX_AGENT_ID` is wrong, the agent was deleted, or `ULTRAVOX_API_KEY` is invalid.
- Response 200 but no `voice` and no `temperature` extractable → halt; the reference agent is malformed and can't be cloned.

### Resume note

If `{run-dir}/reference-settings.json` exists, skip and proceed. The reference agent is "live-pulled every run" by design (so tuning to the reference propagates), but only on the *first* attempt of a given run — re-running a partially-completed run reuses the captured settings to avoid drift mid-flow.

---

## Stage 6 — Create Ultravox agent

**Goal:** POST a new Ultravox agent with the system prompt from Stage 4 and the settings from Stage 5.

### CARDINAL RULE — READ THIS BEFORE EVERY INVOCATION

**NEVER PATCH this agent.** Ultravox PATCH wipes unrelated callTemplate fields and silently corrupts the agent. If you need to correct anything about the agent — wrong prompt, wrong voice, wrong name — do this:

1. POST a brand-new agent (re-run this stage).
2. Update state with the new `agentId`.
3. Re-run Stage 9 (telephony repoint) to point the DID at the new agent.
4. Discard the old agent_id (manually delete via Ultravox console after confirming the new one works).

The `scripts/ultravox-create-agent.sh` script POSTs only — there is no PATCH variant by design. Do not author one.

### What to do

```bash
CUSTOMER_NAME="$(bash scripts/state.sh state_get customer_name)"
AGENT_FIRST_NAME="$(bash scripts/state.sh state_get agent_first_name)"
# Strip spaces from customer name for the Ultravox display name.
AGENT_NAME="$(printf '%s' "$CUSTOMER_NAME" | tr -d ' ')-$AGENT_FIRST_NAME"

bash scripts/ultravox-create-agent.sh \
  --name "$AGENT_NAME" \
  --system-prompt-file "$STATE_RUN_DIR/system-prompt.md" \
  --settings-file "$STATE_RUN_DIR/reference-settings.json" \
  --out "$STATE_RUN_DIR"
```

Naming convention: `{Customer}-{AgentFirstName}` with no spaces (e.g. `AcmePlumbing-Steve`).

The script:

- Builds the POST payload in Python from the system prompt + reference settings.
- Sends `selectedTools: []` and `eventMessages: []` regardless of what the reference had (rough agent has no action tools; `call.ended` webhook gets wired manually in the Ultravox console at /onboard-customer Stage 7).
- POSTs to `https://api.ultravox.ai/api/agents`.
- Saves the full response to `{run-dir}/agent-created.json`.
- Echoes `[OK] agent created: id=<uuid>, name=<name>` on success.

### Output schema

- File: `{run-dir}/agent-created.json` — full Ultravox response, includes `agentId`, `name`, `callTemplate`, etc.

Capture the agent_id and write it to state:

```bash
AGENT_ID="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('agentId') or json.load(open(sys.argv[1])).get('id'))" "$STATE_RUN_DIR/agent-created.json")"
state_set ultravox_agent_id "$AGENT_ID"
state_set ultravox_agent_name "$AGENT_NAME"
state_stage_complete 6 "{\"agent_id\": \"$AGENT_ID\", \"name\": \"$AGENT_NAME\"}"
```

### Halt conditions

- Ultravox POST returns HTTP non-2xx → halt. The script dumps the full request payload and response body. Common causes: invalid voice ID, malformed `firstSpeakerSettings`, prompt over Ultravox's size limit. Do **not** PATCH-retry.
- Response 2xx but no `agentId` in the body → halt; treat as a failed create and surface the body.
- `--name` resolves to empty (rare — operator never confirmed `customer_name`) → script halts pre-network with `[ERR] --name is required`.

### Resume note

If `state_get ultravox_agent_id` returns a non-empty UUID, the agent was already created. Skip Stage 6. To force re-creation: clear the state field manually, accept that the old agent becomes orphaned (manually delete it from the Ultravox console), and re-run.

---

## Stage 7 — Claim Telnyx DID from pool

**Goal:** pick an unassigned DID from the operator's Telnyx pool, preferring the customer's local area code if inferrable from the brain-doc.

### Step 1 — infer area code from brain-doc

Read `{run-dir}/brain-doc.md`'s `## Locations & Service Area` section. Extract the primary address. Map to an Australian area code:

| Code | Region |
|---|---|
| `02` | Sydney / Canberra / NSW / ACT |
| `03` | Melbourne / VIC / TAS |
| `04` | mobile (skip — pool is landlines) |
| `07` | Brisbane / QLD |
| `08` | Perth / Adelaide / WA / SA / NT |
| `13` / `1300` | national (use only if customer explicitly wants a national number) |

For non-Australian operators: **skip area-code inference, leave empty.** The script falls back to "any unassigned DID in the pool".

If the brain-doc has no address (unusual but possible), leave the area code empty.

### Step 2 — claim

```bash
AREA_CODE="07"  # inferred above; or "" for any
bash scripts/telnyx-claim-did.sh \
  --area-code "$AREA_CODE" \
  --out "$STATE_RUN_DIR"
```

The script:

- Lists every TeXML app in the account (`GET /v2/texml_applications`) and filters to apps tagged `pool-available` AND not already tagged `claimed-*`.
- Cross-references each app's bound DID against `--area-code` (falls back to any-AU if no match unless `--strict-area-code` is passed).
- Picks one and tags its TeXML app `claimed-<slug>` (keeping `pool-available` for auditability).
- Fires a Resend `warn` alert to `$OPS_ALERT_EMAIL` if pool remaining after this claim is `< 3`.
- Fires a Resend `crit` alert and exits 1 if the pool is empty.
- Writes `{run-dir}/claimed-did.json`.

Pass `--customer-slug "$SLUG"` so the `claimed-<slug>` tag is human-meaningful (the script falls back to a timestamp slug if omitted).

### Output schema

`{run-dir}/claimed-did.json`:

```json
{
  "did": "+61731304231",
  "area_code": "07",
  "area_code_requested": "07",
  "fallback_used": false,
  "pool_remaining": 8,
  "claimed_at": "2026-04-25T13:42:07+00:00"
}
```

Capture the DID into state:

```bash
DID="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['did'])" "$STATE_RUN_DIR/claimed-did.json")"
state_set telnyx_did "$DID"
state_stage_complete 7 "{\"did\": \"$DID\"}"
```

### Halt conditions

- Pool empty → script exits 1, hard alert already fired. Halt with: *"Pool exhausted — buy more DIDs in your Telnyx console and re-run `/base-agent resume {slug}` to continue."* Stage 7 will retry on resume; Stages 1–6 outputs are preserved.
- Telnyx `GET /v2/phone_numbers` returns HTTP ≥400 → halt with response body.
- `--strict-area-code` was passed and no match → halt with the no-match message; operator either drops `--strict` or buys a DID in the right area code.

### Resume note

If `{run-dir}/claimed-did.json` exists with a non-empty `did`, skip Stage 7 and proceed to Stage 8. The DID is already claimed in state — re-running would claim a second DID needlessly.

---

## Stage 8 — TeXML app wiring

**Goal:** verify the claimed DID's TeXML app has the right codec / voice_method / status_callback / status_callback_method.

> **Stage 8 verifies; it does not configure.** This stage assumes the operator has already run [INSTALL.md §4.2 step 4](../../INSTALL.md#step-4--run-bulk-create-texml-appssh) (`bulk-create-texml-apps.sh`) to set up one TeXML app per DID with the right `voice_url`, codec, `status_callback`, and `status_callback_method`. If those values are missing or wrong, Stage 8 will halt with a diagnostic — re-run `bulk-create-texml-apps.sh`, which is idempotent.

### What to do

```bash
DID="$(bash scripts/state.sh state_get telnyx_did)"
bash scripts/telnyx-wire-texml.sh \
  --did "$DID" \
  --out "$STATE_RUN_DIR"
```

The script:

1. GETs the phone_number to discover its current `connection_id` (the TeXML app the DID is bound to — set up by `bulk-create-texml-apps.sh` at install time).
2. GETs the TeXML app and confirms codec is in the known-good set (G711U, G711A, G722, OPUS, L16, PCMA — OPUS preferred; G711U is Telnyx's current label for what used to be `PCMU`). Codec mismatch is **WARN-only** because codec is an ops decision.
3. Confirms `voice_method`, `status_callback`, and `status_callback_method`. **Missing or malformed `status_callback` is a HARD FAIL** — without it, our call lifecycle webhooks don't fire and downstream attribution breaks.

### Output schema

`{run-dir}/texml-wired.json`:

```json
{
  "did": "+61731304231",
  "texml_app_id": "2942921998587659757",
  "did_bound": true,
  "codec": "OPUS,G711U",
  "codec_ok": true,
  "status_callback": "https://...",
  "status_callback_ok": true,
  "verified_at": "..."
}
```

Mark the stage complete:

```bash
state_stage_complete 8 "{\"did_bound\": true, \"status_callback_ok\": true}"
```

### Halt conditions

- `status_callback_ok: false` → halt. The script already prints the diagnosis: *"Set status_callback on the TeXML app in your Telnyx console — required for call lifecycle webhooks."* Operator fixes it in the Telnyx console, then `/base-agent resume {slug}`.
- DID not found in this Telnyx account (`PN_INFO=MISSING`) → halt. The DID claimed in Stage 7 doesn't exist or doesn't belong to this account — investigate.
- PATCH-to-bind returns non-2xx → halt with response body. Likely an auth or pool-state issue.

Codec mismatch alone does **NOT** halt — it warns, writes `codec_ok: false`, and continues.

### Resume note

If `{run-dir}/texml-wired.json` exists with `did_bound: true` and `status_callback_ok: true`, skip Stage 8 and proceed to Stage 9. To re-verify: delete the file and re-run.

---

## Stage 9 — TeXML → Ultravox telephony_xml

**Goal:** point the TeXML app's `voice_url` at the new Ultravox agent's `telephony_xml` endpoint, completing the inbound-call chain.

### What to do

```bash
DID="$(bash scripts/state.sh state_get telnyx_did)"
AGENT_ID="$(bash scripts/state.sh state_get ultravox_agent_id)"
bash scripts/wire-ultravox-telephony.sh \
  --did "$DID" \
  --ultravox-agent-id "$AGENT_ID" \
  --out "$STATE_RUN_DIR"
```

The script:

1. Resolves which TeXML app the DID is bound to (via GET phone_number).
2. PATCHes that TeXML app's `voice_url` to `https://app.ultravox.ai/api/agents/{agent_id}/telephony_xml` and `voice_method` to `post`.
3. GETs the TeXML app back and verifies the URL took.

Because every DID has its own dedicated TeXML app (set up by `bulk-create-texml-apps.sh`), this PATCH only ever affects the one customer being onboarded.

### Output schema

`{run-dir}/telephony-wired.json`:

```json
{
  "did": "+61731304231",
  "ultravox_agent_id": "...",
  "texml_app_id": "...",
  "texml_voice_url": "https://app.ultravox.ai/api/agents/.../telephony_xml",
  "wired_at": "..."
}
```

Mark the stage complete:

```bash
state_stage_complete 9 "{\"did\": \"$DID\", \"agent_id\": \"$AGENT_ID\"}"
```

### Halt conditions

- DID has no `connection_id` (TeXML app not bound) → halt with: *"Run telnyx-wire-texml.sh first."* This means Stage 8 was somehow skipped or its PATCH didn't take; investigate before resuming.
- PATCH returns non-2xx → halt with response body. Common cause: malformed `voice_url`, agent_id contains special chars.
- GET-back verification finds `voice_url != expected` → halt. The PATCH appeared to succeed but didn't take. Likely a Telnyx eventual-consistency issue; retry once before declaring failure.

### Resume note

If `{run-dir}/telephony-wired.json` exists and its `texml_voice_url` matches the expected pattern for the current `ultravox_agent_id` in state, skip Stage 9 and proceed to Stage 10. If the agent_id changed (Stage 6 was re-run), re-run Stage 9 too — the URL needs to repoint.

---

## Stage 10 — Per-customer discovery prompt (Claude inline)

**Goal:** generate a bespoke ChatGPT-ready discovery prompt the customer pastes into a fresh ChatGPT conversation, plus a cover-email template the operator forwards.

### What to do

This is an inline Claude pass — like Stages 3 and 4.

1. Read `prompts/generate-discovery-prompt.md` in full.
2. Read the four inputs the prompt requires:
   - `{run-dir}/brain-doc.md` (Stage 3 output).
   - `{run-dir}/meeting-transcript.md` (Stage 1 input).
   - Operator hints (`bash scripts/state.sh state_get operator_hints`).
   - `reference-docs/discovery-methodology.md` — pasted verbatim into the generated prompt.
3. Pull the additional state fields the prompt needs: `customer_name`, plus prompt the operator for `customer_first_name` and `operator_first_name` if they haven't been captured yet (these are required for cover-email substitution).

### Sizing decision (LOAD-BEARING)

Compute the total combined character count of: methodology body + brain-doc body + full meeting transcript + operator hints + your framing prose (opener, scope statement, output schema reminder, bespoke first question).

| Combined chars | Path | Files emitted |
|---|---|---|
| ≤ 25,000 | **One-file** | `discovery-prompt.md` only |
| > 25,000 | **Two-file** | `discovery-prompt.md` (under 10,000 chars) + `customer-context.md` |

In the two-file path, `discovery-prompt.md` keeps methodology + bespoke opener + scope statement + an instruction to read the attached context file. `customer-context.md` carries brain-doc + meeting transcript + operator hints with brief framing headings (`# Business summary`, `# Meeting transcript`, `# Operator notes`).

Record the path in state:

```bash
state_set discovery_prompt_size_path "one-file"   # or "two-file"
state_set discovery_prompt_chars "$CHAR_COUNT"
```

### Cover email

Read `templates/cover-email.md`. Substitute:

- `{customer_first_name}` → the customer's first name.
- `{operator_first_name}` → the operator's first name.
- `{{DISCOVERY_PROMPT}}` → the **full body** of `{run-dir}/discovery-prompt.md` you just produced.
- `{{CUSTOMER_CONTEXT_FILE_PATH}}` (two-file path only) → absolute path to `{run-dir}/customer-context.md` plus the literal filename so the operator knows what to attach.

If the one-file path was taken, **omit** the `--- ATTACH THIS FILE ALONGSIDE YOUR MESSAGE ---` block and the line below it from the cover email.

Write to `{run-dir}/cover-email.md`.

### Output schema

| File | Always | Notes |
|---|---|---|
| `{run-dir}/discovery-prompt.md` | yes | The block customer pastes as ChatGPT message 1 |
| `{run-dir}/customer-context.md` | two-file path only | Customer attaches alongside the prompt |
| `{run-dir}/cover-email.md` | yes | Operator forwards to customer; substitutions resolved |

### What to report

Print word counts and absolute paths to the operator:

```
Discovery prompt: 8,420 words, 51 KB → runs/acme-plumbing-.../discovery-prompt.md  (two-file path)
Customer context:  4,210 words, 28 KB → runs/acme-plumbing-.../customer-context.md
Cover email:        1,180 words,  8 KB → runs/acme-plumbing-.../cover-email.md
```

Mark the stage complete:

```bash
state_stage_complete 10 "{\"size_path\": \"two-file\", \"discovery_chars\": $CHARS}"
```

### Halt conditions

- One of the required state fields (`customer_first_name`, `operator_first_name`) is empty and the operator can't supply it → halt; cover-email substitution would fail.
- Two-file path's `discovery-prompt.md` exceeds 10,000 chars → halt with: *"Trim your framing — the methodology and opener are over the 10K cap."* Never trim the methodology itself; trim your framing prose.
- A vendor name leaks through (mental-grep finds Ultravox / Telnyx / Firecrawl / Resend / Supabase / "Claude" / model names in either output file) → halt; rewrite the offending line and re-emit.
- Bespoke first question is generic (e.g. "tell me about your business") rather than anchored in a specific meeting detail → halt and re-author. Per the prompt, this is the highest-value bespoke content; don't ship a weak opener.

### Resume note

If `{run-dir}/discovery-prompt.md` and `{run-dir}/cover-email.md` both exist with non-zero size, skip Stage 10 and proceed to Stage 11. Force regen by deleting both files. Note: Stage 10 is the most expensive inline Claude stage (the prompt is 6–15K words); regenerating costs context.

---

## Stage 11 — Hand off to /onboard-customer

**Goal:** invoke the `/onboard-customer` skill with pre-filled args so the dashboard wiring runs end-to-end.

### What to do

Invoke `/onboard-customer` via the **Skill tool** with the following args, pulled from state:

| Arg | Source |
|---|---|
| `slug` | `bash scripts/state.sh state_get slug` (or stored under that key during init) |
| `name` | `state_get customer_name` |
| `ultravox_agent_ids` | `[ state_get ultravox_agent_id ]` (single-element list) |
| `telnyx_numbers` | `[ state_get telnyx_did ]` (single-element list) |
| `primary_user_email` | `$OPS_ALERT_EMAIL` (default; operator can override later before customer go-live by re-running `/onboard-customer update primary_user`) |
| `primary_user_name` | `"Operator"` (placeholder; transferred to real customer name before go-live) |
| `archetype` | `auto` (onboard-customer infers — Teleca/TelcoWorks clone vs. new vertical) |

The handoff is via the Skill tool. You do not run a bash script for this stage — you invoke the skill in-process and let it run its own 8-stage flow.

### Output schema

The `/onboard-customer` skill writes its own outputs:

- A `workspaces` row in Supabase keyed on `slug`.
- A `public.users` row + matching `auth.users` row for the primary user.
- A magic link (returned in the skill's stdout if SMTP isn't configured).
- n8n workflow error-reporting wiring (no-op if no workflows yet — brand-new customer).

Capture the magic link if returned and write it to state:

```bash
state_set magic_link "$MAGIC_LINK"   # if returned
state_stage_complete 11 "{\"slug\": \"$SLUG\", \"primary_email\": \"$OPS_ALERT_EMAIL\"}"
```

### Halt conditions

- `/onboard-customer` returns an error → **surface the error verbatim, but do NOT roll back Stages 1–10.** The Ultravox agent is still created; the Telnyx DID is still claimed and wired. The operator can manually re-run `/onboard-customer` later with the state file's saved values:

  ```bash
  /onboard-customer --slug "$SLUG" \
    --ultravox-agent-ids "$AGENT_ID" \
    --telnyx-numbers "$DID" \
    --primary-user-email "$OPS_ALERT_EMAIL"
  ```

- `slug` already exists in `workspaces` → `/onboard-customer` will offer update-config / overwrite / cancel. Surface the offer to the operator, don't auto-pick.

### Resume note

If `state_stage_complete 11` already ran (the state shows stage 11 done), Stage 11 is a no-op on resume. The skill prints the final output block (below) and exits.

---

## Final output

Once Stage 11 completes, print this block to the operator with state values substituted:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ Rough agent live
   agent_id:    {AGENT_ID}
   name:        {AGENT_NAME}
   test number: {DID}
   voice/temp/inactivity copied from reference agent {REFERENCE_AGENT_ID}
   (pulled at {STAGE_5_TS})

✅ Dashboard wired (onboard-customer)
   workspace slug:  {SLUG}
   primary email:   {OPS_ALERT_EMAIL}  ← transfer to real customer before go-live
   magic link:      {MAGIC_LINK}        ← save this if SMTP isn't set up
   n8n error wiring: {N} workflows updated

📋 Discovery prompt ({DISCOVERY_WORDS} words, {DISCOVERY_KB} KB)
   path: {RUN_DIR}/discovery-prompt.md
   sizing: {one-file | two-file}

📋 Customer context (two-file path only — {CONTEXT_WORDS} words, {CONTEXT_KB} KB)
   path: {RUN_DIR}/customer-context.md

📧 Cover email ({COVER_WORDS} words)
   path: {RUN_DIR}/cover-email.md

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Next steps:
  1. Test-dial the rough agent: call {DID} and confirm it speaks coherently
     about the business and gracefully degrades on tool-requiring asks.
  2. Forward the cover email to the customer (paste from {RUN_DIR}/cover-email.md;
     attach customer-context.md if two-file path).
  3. Before the customer goes live: run `/onboard-customer update primary_user`
     to transfer email ownership from {OPS_ALERT_EMAIL} to the real customer.
  4. When the brief returns from ChatGPT: design tools and call flows
     (future skill — `/design-tools {SLUG}`).
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Idempotency & failure handling

Every stage writes to `runs/{slug}-{ISO_TS}/state.json` on completion. Re-invocation with the same slug picks up from the highest `done` stage + 1. Outputs from prior stages are preserved on the filesystem.

| Failure | Stage | Behavior |
|---|---|---|
| Env var missing | 0 | Halt with clear "missing X — see `.env.example`" message. No state written. |
| Firecrawl scrape timeout / partial | 2 | If `combined.md` is non-zero, continue with whatever pages came back; flag gaps in brain-doc. If zero bytes, halt. |
| Firecrawl page cap hit | 2 | Continue, surface a warning so operator knows the brain-doc may miss content. |
| Reference agent GET fails | 5 | Halt — reference agent is load-bearing for Stage 6. Operator checks `REFERENCE_ULTRAVOX_AGENT_ID` and `ULTRAVOX_API_KEY`. |
| Ultravox POST rejected | 6 | Halt; dump request payload + response body. **No PATCH retry.** Operator fixes the input and re-runs Stage 6 (which POSTs a fresh agent). |
| Telnyx pool < 3 DIDs | 7 | Claim succeeds, Resend `warn` alert fires, continue. |
| Telnyx pool empty | 7 | Halt; Resend `crit` alert fires; state preserved. Operator buys DIDs in Telnyx console, then `/base-agent resume {slug}`. |
| TeXML status_callback missing | 8 | Halt — re-run `bulk-create-texml-apps.sh` (idempotent), then resume. |
| TeXML codec mismatch | 8 | Warn-only, continue. Codec is an ops decision. |
| Telephony PATCH didn't take | 9 | Halt; verification GET-back caught the discrepancy. Retry once or investigate Telnyx state. |
| Discovery prompt too long (two-file path > 10K chars) | 10 | Halt; trim framing prose, never the methodology body. |
| Vendor-name leak in discovery prompt or cover email | 10 | Halt; rewrite offending line; re-emit. |
| `/onboard-customer` failure | 11 | Surface error; **leave Ultravox agent + Telnyx DID claimed.** Operator manually runs `/onboard-customer` later with state values. |

---

## What this skill does NOT do

Hard non-goals — out of scope for `/base-agent`:

- **Tool design.** CRM integration, calendar booking, SMS, transfer wiring — all post-brief, future skill (`/design-tools`).
- **Stress testing.** The existing `voice-stress-test` skill handles this after tools are added.
- **Customer email ownership transfer.** Manual step before go-live (operator runs `/onboard-customer update primary_user`).
- **Telnyx number purchasing.** Operator buys DIDs in bulk manually; this skill only *claims* from the existing pool and alerts when low/empty.
- **New verticals where the reference agent isn't a sensible template.** The operator picks the reference agent per invocation via `--reference-agent <id>`. If no reference is appropriate for a brand-new vertical, build one manually first, then onboard subsequent customers in that vertical via `/base-agent` using the new reference.
- **White-label rebranding** (Teleca / TelcoWorks customer-facing labels). This skill is operator-internal tooling. White-label productization is a future project.

---

## Commands

| Command | Behavior |
|---|---|
| `/base-agent` | Guided flow. Asks for customer name, website, transcript, hints, agent first name one at a time. |
| `/base-agent [customer-name]` | Same as guided, but skips the "what's the customer name" prompt. |
| `/base-agent resume [slug]` | Locates the most recent run-dir for the slug via `state_resume_from`, reads `state.json`, jumps to `state_get_next_stage`, continues from there. |
| `/base-agent status [slug]` | Read-only. Prints the state file's `stages` block and the file inventory in the run-dir without running anything. Use for audit or to see where a halted run left off. |

---

## Notes for future-me running this skill

- **The `runs/` directory is gitignored.** Per-customer artifacts live there forever (or until manually pruned). Don't commit them.
- **The reference agent pull is live every run** by design — so tuning the reference agent (voice, temperature, inactivity) propagates automatically to every new customer's rough agent. If you want to pin a customer to a specific reference snapshot, copy `reference-settings.json` somewhere stable and pass it via a future `--settings-file-override` flag.
- **The discovery prompt + cover email are the highest-leverage outputs of this skill.** A weak opener wastes the customer's ChatGPT session. Get the bespoke first question right; don't ship generic.
- **The `/onboard-customer` handoff is intentionally late.** If anything in Stages 1–10 fails, no Supabase rows are written and no magic links are sent. The customer's first contact happens after the rough agent is verified working.
- **Hard rule, repeated for emphasis:** NEVER PATCH an Ultravox agent via API. The cardinal rule of this skill. POST a new agent and discard the old one if you need to correct anything.
