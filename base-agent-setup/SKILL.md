---
name: base-agent-setup
description: Automates voice-AI customer onboarding end-to-end. Invoked as /base-agent or /base-agent [customer]. Scrapes the customer's website, synthesizes a knowledge-base brain doc from site + meeting transcript + operator hints, creates a rough Ultravox agent (no tools, no call flows yet) with voice/temperature/inactivity settings copied from a configured reference agent, claims a Telnyx DID from the operator's pool and wires TeXML + telephony_xml, generates a bespoke ChatGPT-ready discovery prompt the customer pastes into ChatGPT to write a detailed brief back, then hands off to /onboard-customer for dashboard wiring. Resumable across crashes via per-run state files. Use when the operator says "/base-agent", "onboard [name] from scratch", "new customer base agent", or starts the post-meeting onboarding flow.
user_invocable: true
---

# base-agent-setup

> **For Claude:** This skill orchestrates 11 stages, each writing to `runs/{slug}-{timestamp}/state.json` on completion. Re-invocation with the same slug resumes from the last successful stage.

The flow: scrape → brain-doc → rough system prompt → Ultravox agent (POST first; subsequent system-prompt updates use safe full-PATCH) → Telnyx DID claim → TeXML wiring → telephony_xml repoint → discovery prompt + cover email → handoff to `/onboard-customer`. Every stage is checklist-enforced. Halt-on-error is the default; resume picks up from the last `done` stage.

You are the operator-facing orchestrator. You read each stage in order, run the script or apply the prompt, parse the output, write state, and move on. You do not improvise the order. You do not skip stages. If a stage halts, you surface the error verbatim and stop — Leo decides whether to fix and resume.

---

## Runtime notes (Windows + Git Bash gotchas)

- **Every `curl` needs `--ssl-no-revoke`.** Windows SChannel CRL checks fail intermittently against Supabase, Ultravox, Telnyx, and Resend. The flag bypasses revocation but still TLS-verifies the endpoint — safe. Every script in `scripts/` already does this; if you find yourself writing a curl ad-hoc, include the flag.
- **`jq` is not installed.** Use Python3 with stdin JSON parsing for any structured output transformation (matches the pattern in `scripts/state.sh`). Don't pipe to `jq -r`.
- **`/tmp/` paths in Git Bash do not map to a Windows path Python can read.** For any file handed from `curl` to a Python helper, use a portable temp path like `${TMPDIR:-$HOME/.tmp-spotfunnel-skills}/...` (create the dir if missing, `rm -rf` when done).
- **Skill scripts source `.env` via `scripts/env-check.sh`** which resolves the env file in this order: `$SPOTFUNNEL_SKILLS_ENV` → `<repo-root>/.env` → cached path at `~/.config/spotfunnel-skills/env-path`. See [ENV_SETUP.md](ENV_SETUP.md).
- **Run-dir convention.** Every run gets its own directory under `base-agent-setup/runs/{slug}-{ISO_TS}/`. The path is exported as `STATE_RUN_DIR` once `state_init` runs; every subsequent script writes into that dir.
- **Updating a live Ultravox agent uses safe full-PATCH** (`scripts/regenerate-agent.sh`). PATCH semantics revert any omitted field to API default, so the script GETs every current setting, swaps in the new system-prompt, and PATCHes the complete body. Never construct a partial PATCH manually — always carry every field forward.

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
state_set_artifact meeting-transcript "$STATE_RUN_DIR/meeting-transcript.md"
```

Mark the stage complete:

```bash
state_stage_complete 1 "{\"slug\": \"$SLUG\", \"website\": \"$WEBSITE\"}"
```

`state_set_artifact` is a no-op when `USE_SUPABASE_BACKEND` is unset (legacy file backend). When the Supabase backend is on, it upserts the file's content into `operator_ui.artifacts` so the operator UI can read it.

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

The default page cap is 100 (set via `--max-pages` if the operator wants different; configurable via `FIRECRAWL_MAX_PAGES` env override). The 100 default was chosen because the prior 50-page cap missed the `/pricing` tree on a Teleca-sized site; 100 covers virtually every SMB site without exhausting Firecrawl free-tier credits. Firecrawl v2 stays on the start domain by default (`allowExternalLinks:false`), so the crawl stops naturally once every internal page is reached — the cap only kicks in for sites that genuinely have >100 internal pages.

### Output schema

- `{run-dir}/scrape/pages/<slug>.md` — one file per crawled page. Filename is a slug of the source URL.
- `{run-dir}/scrape/combined.md` — all pages joined with `<!-- source: ... -->` headers and `---` separators. This is the file Stage 3 reads.

### What to report

Print the scrape progress to the operator while it's running (the script emits `[INFO] poll #N: status=scraping` lines). On completion, surface:

- Pages scraped (final count).
- Total characters in `combined.md`.
- Whether the page cap was hit (compare pages-scraped to `--max-pages`).

If the cap was hit, flag it so the operator knows the brain-doc may be incomplete:

> *"Scrape hit the 100-page cap. Brain-doc will be built from the first 100 pages only. Re-run with `--max-pages 200` if the customer's site is genuinely larger and you want full coverage."*

Mark the stage complete:

```bash
PAGES_SCRAPED="$(ls "$STATE_RUN_DIR/scrape/pages" | wc -l)"
state_set_artifact scraped-pages "$STATE_RUN_DIR/scrape/combined.md"
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

1. Compose the prompt with the deterministic substitution helper, then read the composed file:

   ```bash
   bash scripts/compose-prompt.sh prompts/synthesize-brain-doc.md > /tmp/composed-brain-doc.md
   ```

   This bakes the active-lessons block (and an empty corrections block — see Step 6 of refine for the corrections-populated path) into the prompt at the `{{LESSONS_BLOCK}}` / `{{CORRECTIONS_BLOCK}}` placeholders. **Read `/tmp/composed-brain-doc.md` as the operating manual for this stage.**

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
state_set_artifact brain-doc "$STATE_RUN_DIR/brain-doc.md"
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

1. Compose the prompt with the deterministic substitution helper, then read the composed file:

   ```bash
   bash scripts/compose-prompt.sh prompts/assemble-rough-system-prompt.md > /tmp/composed-system-prompt.md
   ```

   Read `/tmp/composed-system-prompt.md` as the operating manual for this stage. The lessons block is pre-substituted; you do not run `fetch_lessons.py`.

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
state_set_artifact system-prompt "$STATE_RUN_DIR/system-prompt.md"
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

**Stage 6 only ever POSTs.** This stage creates a brand-new agent — never PATCH from here. The `scripts/ultravox-create-agent.sh` script has no PATCH variant by design; if you find yourself reaching for one, you're in the wrong stage.

Subsequent system-prompt updates against a live agent — e.g. when `/base-agent refine` regenerates the prompt — go through `scripts/regenerate-agent.sh` (M13), which does a safe full-PATCH (GET every current field → swap only systemPrompt → PATCH full body → verify no drift). That preserves the agent_id so Telnyx telephony_xml wiring survives.

If you need to correct voice/name/firstSpeaker after the agent is live: that still requires a new POST + DELETE because the safe-PATCH path is scoped to system-prompt only. Plan: POST a brand-new agent (re-run this stage), update state with the new `agentId`, re-run Stage 9 (telephony repoint), then discard the old agent_id via the Ultravox console.

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
  --out "$STATE_RUN_DIR" \
  --slug "$SLUG" \
  --run-id "${STATE_RUN_ID:-$(basename "$STATE_RUN_DIR")}"
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
  --customer-slug "$SLUG" \
  --run-id "${STATE_RUN_ID:-$(basename "$STATE_RUN_DIR")}" \
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

1. Compose the prompt with the deterministic substitution helper, then read the composed file:

   ```bash
   bash scripts/compose-prompt.sh prompts/generate-discovery-prompt.md > /tmp/composed-discovery-prompt.md
   ```

   Read `/tmp/composed-discovery-prompt.md` as the operating manual for this stage. The lessons block is pre-substituted; you do not run `fetch_lessons.py`.

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
state_set_artifact discovery-prompt "$STATE_RUN_DIR/discovery-prompt.md"
state_set_artifact cover-email "$STATE_RUN_DIR/cover-email.md"
# Customer-context only exists on the two-file path.
[ -f "$STATE_RUN_DIR/customer-context.md" ] && state_set_artifact customer-context "$STATE_RUN_DIR/customer-context.md"
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

## Stage 11.5 — Post-onboarding verification (HALTS success banner on fail)

**Goal:** run 10 deterministic checks against the live agent, DID, and dashboard wiring. Surface drift before the operator's first test call.

This stage **does not roll back** Stages 1–11 (the agent is live, the DID is claimed, the dashboard is wired). But a `fail` result here HALTS the Stage 11 success banner so the operator sees the failure before forwarding the cover email. Skips never halt — an all-skip case (operator running offline) still proceeds.

### What to do

Run verify and capture its exit code (do NOT swallow with `|| true`):

```bash
python -m server.verify --slug "$SLUG"
VERIFY_EXIT=$?
```

Run from `base-agent-setup/` so `python -m server.verify` resolves the module. From elsewhere:

```bash
python base-agent-setup/server/verify.py --slug "$SLUG"
VERIFY_EXIT=$?
```

Exit codes:
- `0` = no fails (all pass or skip). Proceed to the Stage 11 success banner.
- `2` = at least one check failed. **HALT the success banner.** Print a clear remediation block to the operator with the failed check's `detail` + `remediation` fields, then stop. Do not print the `✅ Rough agent live` block. The operator must address the failure (or explicitly acknowledge and re-run /base-agent — Stage 11.5 is replayable).
- `1` = internal error (no run for slug, Supabase unreachable, etc.). HALT loudly.

### What gets checked

1. Ultravox agent exists and live (state.ultravox_agent_id → GET /api/agents/{id})
2. Voice + temperature match the operator's reference agent
3. system-prompt-matches-artifact (live agent's systemPrompt is byte-equal to the latest system-prompt artifact for this run)
4. selectedTools array length matches reference
5. Telnyx DID is `active` (state.telnyx_did → GET /v2/phone_numbers)
6. DID has a connection_id wired (TeXML app)
7. TeXML app `status_callback` is non-empty
8. Customer dashboard `workspaces` row exists (skips when SUPABASE_URL unset / table 404)
9. Customer dashboard `users` row exists (same skip rules)
10. n8n error-reporter workflow is `active` (skips when N8N_* env unset)

Each row carries `{id, title, status: pass|fail|skip, ms, detail, remediation?}`. Failures include the exact existing script to re-run.

### Skip vs fail

- **Skip** = the check couldn't run (env missing, table not provisioned, reference agent unfetchable). Skips never count against the run; an all-skip exit code is `0`.
- **Fail** = the check ran and found a real problem. Surface verbatim; don't auto-fix; HALT the success banner.

### Resume note

Re-running `/base-agent <slug>` after fixing the failure cause is safe. `state.stage_complete=11` is already set, so Stages 1–11 short-circuit on resume. Stage 11.5 is a side-effect-free check (other than the persistence write into `operator_ui.verifications`), so it re-runs cleanly and prints the success banner once verify is green.

---

## Final output

Once Stage 11 AND Stage 11.5 both clear (verify exit 0 — pass/skip only, no fails), print this block to the operator with state values substituted. **If verify exited 2, do NOT print this block** — print the failure remediation block from Stage 11.5 instead.

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

## Sub-command: `/base-agent refine [customer-slug]`

Replays the operator's open annotations as patches against a NEW run. Each annotation is classified (per-run patch vs cross-customer feedback signal vs both), per-run patches re-generate the affected artifact(s), feedback signals land in `operator_ui.feedback`, and recurring patterns get probed for elevation to `operator_ui.lessons` at the end.

You — Claude in chat — are the orchestrator. The schema mutations live in `scripts/refine-*.sh` helpers. You do the LLM-judgment work (classifying annotations, splitting mixed comments, regenerating artifacts) and call the helpers to record state.

**Pre-requisite:** `USE_SUPABASE_BACKEND=1` and a working `SUPABASE_OPERATOR_URL` + `SUPABASE_OPERATOR_SERVICE_ROLE_KEY`. The legacy file backend has no annotations to refine against.

### Step 1 — Resolve the latest run

```bash
SLUG="<customer-slug>"
bash scripts/refine-list-annotations.sh "$SLUG" > /tmp/refine-anns.jsonl
```

The helper looks up the customer by slug, finds the latest `runs.created_at` for that customer, and prints open annotations as JSON Lines (one per line) ordered by `(artifact_name, char_start)`.

**Halt conditions:**

- Helper exits non-zero with `no customer for slug` → halt: *"No customer matches `<slug>`. Did you mean a different slug? Run `/base-agent status <slug>` for context."*
- Helper exits non-zero with `no runs for slug` → halt: *"Customer exists but has no runs. There's nothing to refine. Run `/base-agent <slug>` first."*
- File is empty (zero open annotations) → exit cleanly: *"Nothing to refine — no open annotations on the latest run. Done."*

### Step 2 — Read context

Read the unpromoted lessons table for cross-customer guardrails:

```bash
python3 scripts/fetch_lessons.py
```

Surface the lesson list to the operator at the start of refine so they have context: *"Heads-up — N active lessons in play. <list ids + titles>. These guard your classification."*

### Step 3 — Classify each annotation interactively

Walk `/tmp/refine-anns.jsonl` one annotation at a time. For each one:

1. Print to the operator: artifact name, char range, the quoted text, the comment.
2. Apply the classification heuristic yourself:
   - **Pure factual correction** (a wrong fact about the specific customer — wrong address, wrong phone, wrong service area, wrong staff name) → `per-run`. No question. Save silently. Bias toward this when the comment names a concrete fact.
   - **Pure behavior critique** (a critique of HOW the generator behaves — invents personas, paraphrases brand voice, ships generic openers) → `feedback` candidate. Ask the operator: *"Behavior critique. Record as feedback signal? [Y/n]"* Default Y on enter.
   - **Mixed** (both a factual correction AND a behavioral critique in one annotation) → split. The fact half is `per-run` silently. Surface only the behavior half: *"This annotation is mixed. The factual half (`<extract>`) is being applied silently. The behavior half is: `<extract>` — record as feedback signal? [Y/n]"*
3. After each decision, call:

   ```bash
   # Per-run only:
   bash scripts/refine-resolve-annotation.sh "$ANN_ID" "$NEW_RUN_ID" per-run
   # Feedback only:
   bash scripts/refine-record-feedback.sh "$ANN_ID"
   bash scripts/refine-resolve-annotation.sh "$ANN_ID" "$NEW_RUN_ID" feedback
   # Mixed (operator answered Y on the behavior half):
   #   1. Record the feedback row first (durable record of the behavior half;
   #      its source_annotation_id points back to this annotation).
   #   2. Then resolve the annotation with classification=feedback. The
   #      mixed-ness is implicit — the feedback row exists for the annotation
   #      AND the regenerated artifact silently absorbs the factual half.
   bash scripts/refine-record-feedback.sh "$ANN_ID" "<behavior-half-extract>"
   bash scripts/refine-resolve-annotation.sh "$ANN_ID" "$NEW_RUN_ID" feedback
   ```

   The stored `resolved_classification` column only takes `per-run` or `feedback`
   (matches the design doc + the `ui/web/lib/types.ts` union). "Mixed" is how
   you THINK about the annotation, not a value you store.

   `$NEW_RUN_ID` doesn't exist yet — defer the resolve calls until after Step 5 spawns the new run. Hold the classification decisions in working memory.

**Halt conditions:**

- `refine-record-feedback.sh` returns non-zero → halt; the feedback insert failed and we can't half-resolve. Surface stderr verbatim.
- Operator declines a behavior critique with `n` and there's no factual correction half → mark the annotation `per-run` (silent — nothing to apply, but don't leave it open).

### Step 4 — Group classified annotations into per-run patches

In your working memory, group all `per-run` and the factual half of `mixed` annotations by `artifact_name`. The result is a per-artifact list of corrections to inject. Each correction = `(quote, comment, char_range)`.

The artifacts you may need to regenerate: `brain-doc`, `system-prompt`, `discovery-prompt`, `customer-context`, `cover-email`. Tools you have: the inline regeneration prompts at `prompts/synthesize-brain-doc.md`, `prompts/assemble-rough-system-prompt.md`, `prompts/generate-discovery-prompt.md`.

### Step 5 — Cascade prompt + spawn the new run

Ask the operator: *"Per-run patches will modify {list of artifacts}. Re-derive downstream artifacts? [y/N]"* Default N. The dependency order is:

```
brain-doc  →  system-prompt  →  discovery-prompt  ⊕  customer-context  →  cover-email
```

If the operator says Y, mark every downstream artifact for regeneration too.

Spawn the new run:

```bash
read -r NEW_SLUG_TS NEW_RUN_ID < <(bash scripts/refine-spawn-run.sh "$SLUG")
export STATE_RUN_ID="$NEW_SLUG_TS"
export STATE_RUN_DIR="base-agent-setup/runs/$NEW_SLUG_TS"
mkdir -p "$STATE_RUN_DIR"
```

`refine-spawn-run.sh` creates the new `runs` row with `refined_from_run_id` pointing at the prior run, copies every artifact from the prior run forward as the baseline, and prints `<slug_with_ts>\t<run_uuid>` so a single `read` captures both.

### Step 6 — Apply per-run patches

For each artifact in the patch group, re-compose the relevant generator prompt with a corrections JSONL file, then re-run that composed prompt inline.

First, write the corrections for each artifact to a JSONL file (one line per per-run-classified annotation, with `quote` + `comment` fields):

```bash
# Example: brain-doc has 2 per-run patches.
cat > /tmp/refine-corrections-brain-doc.jsonl <<'JSONL'
{"quote": "<quote-from-annotation-1>", "comment": "<comment-from-annotation-1>"}
{"quote": "<quote-from-annotation-2>", "comment": "<comment-from-annotation-2>"}
JSONL
```

Then compose:

```bash
bash scripts/compose-prompt.sh \
  prompts/synthesize-brain-doc.md \
  --corrections /tmp/refine-corrections-brain-doc.jsonl \
  > /tmp/composed-brain-doc.md
```

The composer substitutes the `{{LESSONS_BLOCK}}` (active lessons) AND `{{CORRECTIONS_BLOCK}}` (formatted as a `<corrections>` block) at version-controlled placeholders inside the prompt. The LLM cannot "forget" the corrections — they are baked into the prompt body before you read it.

Read `/tmp/composed-<artifact>.md` and run the inline generator. Write the regenerated artifact to `$STATE_RUN_DIR/<artifact>.md`, then mirror it to Supabase:

```bash
source scripts/state.sh
state_set_artifact brain-doc "$STATE_RUN_DIR/brain-doc.md"
# ...repeat per regenerated artifact
```

The mapping of artifact → prompt is the same as the fresh-run stages: brain-doc → `prompts/synthesize-brain-doc.md`, system-prompt → `prompts/assemble-rough-system-prompt.md`, discovery-prompt + customer-context + cover-email → `prompts/generate-discovery-prompt.md`. For artifacts with zero direct corrections (downstream cascades), pass an empty JSONL file or omit `--corrections`; the placeholder becomes empty and the regeneration is purely upstream-driven.

### Step 7 — Cascade downstream artifacts (only if Step 5 = Y)

Walk the dependency graph and re-run the generator for each downstream artifact. Same prompt-with-`<correction>`-block pattern, except the `<correction>` block can be empty for downstream artifacts whose direct corrections are zero — they regenerate purely because their upstream changed.

### Step 8 — Resolve consumed annotations

Now that `$NEW_RUN_ID` exists, replay the deferred resolve calls from Step 3:

```bash
bash scripts/refine-resolve-annotation.sh "$ANN_ID" "$NEW_RUN_ID" "$CLASS"
```

Where `$CLASS` is one of `per-run` / `feedback` (the stored column rejects anything else). Mixed annotations resolve as `feedback` — the feedback row recorded in Step 3 is the durable record; the factual half lives in the regenerated artifact.

**Halt conditions:**

- Any resolve call returns non-zero → halt; investigate before proceeding. The new run still exists; the operator can re-run refine to retry the resolves.

### Step 9 — System-prompt push prompt

If `system-prompt` was regenerated in Step 6 OR Step 7, ask: *"system-prompt was regenerated. Push to live Ultravox agent now? [y/N]"*

On Y:

```bash
bash scripts/regenerate-agent.sh "$SLUG"
```

The script GETs every current Ultravox setting, swaps in the new system-prompt, PATCHes the full body back, and verifies post-PATCH state matches pre-update state on every non-systemPrompt field. The pre-update snapshot lands in `state.live_agent_pre_update` for audit/rollback; `state.system_prompt_pushed_at` is stamped on success. On drift detection (any non-systemPrompt field changed), the script halts with a diff to stderr — investigate before re-running. Never construct a partial PATCH manually; always go through this script.

### Step 10 — Elevation probing

Once all annotations are resolved, probe for cross-customer patterns to elevate:

```bash
bash scripts/refine-cluster-feedback.sh "$SLUG" > /tmp/refine-clusters.jsonl
```

The helper reads open feedback rows for this customer (across all runs), groups by `(lower-cased artifact_name, comment[:80].lower())`, and emits clusters with size ≥ 2 as JSON Lines. Empty file = no clusters big enough = exit cleanly.

For each cluster:

1. Print to the operator: *"This pattern showed up in {N} annotations: '<comment-prefix>' on `<artifact>`. Elevate to a lesson now? [y/N]"*
2. On Y, ask for `title`, `pattern`, `fix` — three short single-line strings. The cluster's quotes/comments give you raw material; the operator polishes.
3. Insert the lesson and mark the cluster's feedback rows elevated:

   ```bash
   bash scripts/refine-elevate-cluster.sh "$FEEDBACK_ID_CSV" "$TITLE" "$PATTERN" "$FIX"
   ```

   `$FEEDBACK_ID_CSV` is the cluster's `feedback_ids` joined with commas.

The helper generates the next `L-NNN` id, inserts the lesson with `observed_in_customer_ids` derived from the source feedback rows, and PATCHes those rows to `status='elevated'` with `elevated_to_lesson_id`.

### Final report

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ Refine complete — new run: {NEW_SLUG_TS}
   refined_from: {OLD_SLUG_TS}

Annotations consumed:
  per-run:  N
  feedback: N

Artifacts regenerated:
  - brain-doc       (Y patches applied)
  - system-prompt   (cascade)
  ...

Lessons elevated:
  - L-007: <title>  (from F-..., F-...)
  ...

System-prompt push:
  - {pending — see step 9 / M13 deliverable}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Halt-summary cheat sheet

| Failure | Step | Behavior |
|---|---|---|
| Slug not found | 1 | Halt — friendly "no customer matches" message. |
| Zero open annotations | 1 | Exit cleanly — "nothing to refine". |
| Feedback insert fails | 3 | Halt — don't half-resolve. Surface stderr. |
| Spawn-run insert fails | 5 | Halt — surface stderr; no annotations resolved yet. |
| Resolve call fails | 8 | Halt — new run exists, operator re-runs refine to retry resolves. |
| Cascade=N but system-prompt was patched | 9 | Still ask the push question. Operator may want a manual paste. |
| Cluster size < 2 across all groupings | 10 | Skip elevation; exit cleanly. |

### Resume note

`/base-agent refine` is itself idempotent over annotations: a re-run on the same customer reads the SAME `latest run` (the one with the open annotations), spawns ANOTHER refine run, and consumes the still-open annotations. The previously-resolved ones are excluded by `status=eq.open` in `refine-list-annotations.sh`.

If a refine halted mid-flow (e.g. a resolve call failed at Step 8), the new run row from Step 5 already exists with the regenerated artifacts; re-running refine will skip those annotations whose `status` already flipped and resolve the remainder against ANOTHER new run. This is intentional — refine is replayable.

---

## Sub-command: `/base-agent review-feedback`

Two-phase cross-customer protocol-improvement loop. Phase 1 turns recurring feedback into lessons; phase 2 bakes mature lessons into the generator prompt files themselves.

You — Claude in chat — are the orchestrator. The schema mutations live in `scripts/review-*.sh` helpers. You do the LLM-judgment work (synthesizing lesson title/pattern/fix from cluster quotes; picking the right prompt file for promotion); the helpers record state.

**Pre-requisite:** `USE_SUPABASE_BACKEND=1` and a working `SUPABASE_OPERATOR_URL` + `SUPABASE_OPERATOR_SERVICE_ROLE_KEY`. The legacy file backend has no feedback or lessons.

**Idempotent / resumable:** phase 1 always reads `feedback.status='open'`; phase 2 always reads `lessons.promoted_to_prompt=false`. Re-running picks up where you left off — already-elevated feedback and already-promoted lessons drop out automatically.

### Phase 1 — feedback → lessons

#### Step 1.1 — Pull cross-customer clusters

```bash
bash scripts/review-list-clusters.sh > /tmp/review-clusters.jsonl
bash scripts/review-list-singletons.sh > /tmp/review-singletons.jsonl
```

`review-list-clusters.sh` emits open feedback rows grouped by `(lower(artifact_name), comment[:80].lower())`, size ≥ 2. `review-list-singletons.sh` emits the open rows that didn't form a cluster.

Empty clusters AND empty singletons → exit cleanly: *"No open feedback. Nothing to review. Done."*

#### Step 1.2 — Walk each cluster

For each cluster line, synthesize a `title`, `pattern`, and `fix` from the cluster's quotes + comments. Then present:

```
Pattern: brain-doc invents personas not in the meeting transcript
Observed: dsa-law (Apr 25), automateconvert (Apr 25), telco-x (Apr 26)
Source feedback: F-2026-04-25-001, F-2026-04-25-014, F-2026-04-26-003
Proposed lesson title: "Brain-doc must not invent personas"
Proposed pattern: <synthesized>
Proposed fix: <synthesized>

[P]romote / [K]eep / [D]elete?
```

- **P (promote):** call `bash scripts/refine-elevate-cluster.sh "$FEEDBACK_ID_CSV" "$TITLE" "$PATTERN" "$FIX"` (M12's helper — reused, not duplicated). It mints `L-NNN`, inserts the lesson row with `observed_in_customer_ids` derived from the source feedback, and PATCHes those rows to `status='elevated'`.
- **K (keep):** no change. The cluster will re-surface on the next review-feedback run.
- **D (delete):** `bash scripts/review-delete-feedback.sh "$FEEDBACK_ID_CSV"`. Physical delete — operator decided this isn't a real issue.

  **Warning: D physically deletes the feedback rows for ALL customers in the cluster.** Only pick D if you're sure none of them represent a real issue. Reversibility requires re-running /base-agent refine for each affected customer.

#### Step 1.3 — Walk each singleton

For each singleton, present:

```
Singleton feedback F-2026-04-25-009 (customer: dsa-law)
Artifact: brain-doc
Quote:   "<quote>"
Comment: "<comment>"

[P]romote (one-customer lesson) / [K]eep / [D]elete?
```

- **P:** call `bash scripts/refine-elevate-cluster.sh "$FID" "$TITLE" "$PATTERN" "$FIX"` with a single-element CSV.
- **K:** no change.
- **D:** `bash scripts/review-delete-feedback.sh "$FID"`.

### Phase 2 — lessons → prompts

#### Step 2.1 — Pull unpromoted lessons

```bash
bash scripts/review-list-lessons.sh > /tmp/review-lessons.jsonl
```

The helper emits each `promoted_to_prompt=false` lesson with maturity metadata: `customer_count`, `days_since_created`, `days_since_oldest_source_feedback`, plus a `recommendation` of `"promote"` or `"keep"`. The recommendation is `"promote"` iff `customer_count >= 3` AND `days_since_oldest_source_feedback > 14` — otherwise `"keep"`. Always defer to the operator's choice.

> Note on naming: `source_feedback_ids` is set once at lesson creation and `feedback.created_at` is immutable, so `days_since_oldest_source_feedback` is "earliest feedback row that fed this lesson, in days" — NOT "last elevation". Use `days_since_created` if you want the lesson row's own age.

Empty file → exit cleanly: *"No unpromoted lessons. Done."*

#### Step 2.2 — Walk each lesson

For each line, present:

```
Lesson L-001: Brain-doc must not invent personas
Pattern: <pattern>
Fix: <fix>
Observed in 3 customers
Created: 2026-04-25 (3 days ago)
Source feedback: 3 rows, all elevated

Maturity check:
  - Customer count: 3 (>= 3? yes)
  - Days since created: 3
  - Oldest source feedback: 18 days ago

Recommended: Promote (mature, ≥3 customers, oldest source feedback >14 days old)
Recommended: Keep (still maturing)

[P]romote / [K]eep / [D]elete?
```

- **P:** pick the right prompt file for the lesson's `artifact_name`:

  | artifact_name | prompt file |
  |---|---|
  | `brain-doc` | `prompts/synthesize-brain-doc.md` |
  | `system-prompt` | `prompts/assemble-rough-system-prompt.md` |
  | `discovery-prompt` / `customer-context` / `cover-email` | `prompts/generate-discovery-prompt.md` |

  Then run:

  ```bash
  bash scripts/review-promote-lesson.sh "$LESSON_ID" "$PROMPT_PATH"
  ```

  The helper, in order: (1) PATCHes the lesson row with `promoted_to_prompt=true / promoted_at / promoted_to_file` — cheapest probe of "can I still talk to Supabase", failing here leaves the prompt file untouched; (2) atomically appends the fix under a `## Lessons learned (do not regenerate)` section at end of the prompt file (writes to a `.tmp` sibling then `os.replace` — no truncation hazard if interrupted); (3) physically deletes the lesson row. Per design — once the fix lives in version-controlled prose, the runtime fetcher no longer needs the row.

  **Halt-on-double-append:** if the prompt file already contains `### From <lesson_id>:` the helper refuses to write. This is load-bearing recovery infra for partial-failure replay — if a prior run failed between PATCH and DELETE the row is already promoted=true and the prompt entry is already written, so a normal re-run of review-feedback skips the row (only lists promoted=false). If an operator manually flips promoted_to_prompt back to false to retry, this guard prevents a duplicate entry from corrupting the prompt body.

- **K:** no change.
- **D:** `bash scripts/review-delete-lesson.sh "$LESSON_ID"`. Physical delete — operator decided the lesson turned out wrong / superseded.

### Final report

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ Review-feedback complete

Phase 1 — feedback → lessons:
  clusters seen:  N  (promoted: N, kept: N, deleted: N)
  singletons:     N  (promoted: N, kept: N, deleted: N)
  lessons created: L-007, L-008

Phase 2 — lessons → prompts:
  unpromoted lessons seen: N
  promoted to prompt: L-002 → prompts/synthesize-brain-doc.md
                     L-005 → prompts/generate-discovery-prompt.md
  kept (still maturing): L-006
  deleted (superseded):  L-001
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Halt-summary cheat sheet

| Failure | Step | Behavior |
|---|---|---|
| Empty open feedback | 1.1 | Skip phase 1, fall through to phase 2. |
| Cluster helper non-zero | 1.1 | Halt — surface stderr. |
| `refine-elevate-cluster.sh` fails | 1.2 / 1.3 | Halt — feedback rows may be partially elevated; surface message and let operator clean up. |
| `review-delete-feedback.sh` count mismatch | 1.2 / 1.3 | Halt — DELETE returned fewer rows than asked; investigate before continuing. |
| Empty lessons | 2.1 | Skip phase 2; exit cleanly. |
| Prompt file missing for lesson's artifact | 2.2 | Halt — surface the artifact_name and let operator pick a prompt file manually (or fix the lesson's artifact_name in the source feedback first). |
| `### From L-NNN:` already present in prompt | 2.2 | Halt — refusing to double-append. A prior run already PATCHed promoted=true and wrote the prompt entry but failed before DELETE. Normal recovery: manually `DELETE FROM lessons WHERE id = 'L-NNN'` and continue — the prompt body is already correct. |
| `review-promote-lesson` PATCH non-zero | 2.2 | Halt — Supabase reachability issue. Prompt file was NOT mutated; safe to re-run after fixing connectivity. |
| `review-promote-lesson` DELETE non-zero (after PATCH + write succeeded) | 2.2 | Lesson row remains as `promoted_to_prompt=true` artifact. Harmless — `review-list-lessons.sh` only lists `promoted_to_prompt=false`, so it won't resurface. Operator can manually delete the row at leisure. |

### Resume note

Phase 1 always reads `feedback?status=eq.open` and phase 2 always reads `lessons?promoted_to_prompt=eq.false`. A halted run can be resumed by re-invoking `/base-agent review-feedback` — the helpers naturally skip rows that already moved on.

---

## Sub-command: `/base-agent verify [customer-slug]`

Runs the same 10 deterministic checks as Stage 11.5 against the customer's most recent run. Useful for re-checks after suspected drift, or when an operator wants to confirm an agent is still healthy weeks after onboarding.

### What to do

```bash
SLUG="<customer-slug>"
python -m server.verify --slug "$SLUG"
```

Run from `base-agent-setup/`. Add `--include-call` to also place a real Telnyx call to the customer's DID and immediately hang up (M17). The `--include-call` flag is **opt-in only** — never run it without explicit operator request, as it triggers a real outbound call.

Optional flags:

- `--include-call` — adds the 11th check (programmatic Telnyx call → hangup). Requires `TELNYX_TEST_FROM_NUMBER` + `TELNYX_TEST_CONNECTION_ID` env vars (or the legacy `TELNYX_FROM_NUMBER` / `TELNYX_CONNECTION_ID` names — both are honored).
- `--no-write` — skip persisting to `operator_ui.verifications`. Use during dev / dry runs.
- `--json` — emit the report as JSON instead of the default human-readable layout.

### What the operator sees

A line per check with `[PASS]` / `[FAIL]` / `[SKIP]`, elapsed ms, a short detail string, and (on failures) the exact existing script to re-run as the remediation hint. Skips never count against the run — they indicate the check couldn't apply (e.g. dashboard schema not provisioned, reference agent unfetchable).

### Halt conditions

- Slug doesn't resolve to a customer / run → halt: *"No run found for `<slug>`. Did you mean a different slug?"*
- `SUPABASE_OPERATOR_URL` / `SUPABASE_OPERATOR_SERVICE_ROLE_KEY` unset → halt: *"Operator UI Supabase env not configured."*
- Individual check failures are NOT halt conditions — they land as `fail` rows in the report.

### Resume note

Verify is read-only (except for the persistence write to `operator_ui.verifications` and check 11's outbound call when opted in). Re-running creates a new row keyed by run id; nothing else changes.

---

## Commands

| Command | Behavior |
|---|---|
| `/base-agent` | Guided flow. Asks for customer name, website, transcript, hints, agent first name one at a time. |
| `/base-agent [customer-name]` | Same as guided, but skips the "what's the customer name" prompt. |
| `/base-agent resume [slug]` | Locates the most recent run-dir for the slug via `state_resume_from`, reads `state.json`, jumps to `state_get_next_stage`, continues from there. |
| `/base-agent status [slug]` | Read-only. Prints the state file's `stages` block and the file inventory in the run-dir without running anything. Use for audit or to see where a halted run left off. |
| `/base-agent refine [slug]` | Walk open annotations on the latest run, classify per-run vs feedback, spawn a new run with `refined_from_run_id`, regenerate affected artifacts, probe for elevation to lessons. See "Sub-command: /base-agent refine" above. |
| `/base-agent review-feedback` | Cluster cross-customer feedback into lessons (phase 1), then bake mature lessons into generator prompt files (phase 2). See "Sub-command: /base-agent review-feedback" above. |
| `/base-agent verify [slug]` | Runs the 10 deterministic checks (11 with `--include-call`) against the most recent run for the slug. Same checks Stage 11.5 runs advisory after every onboarding. See "Sub-command: /base-agent verify" above. |
| `/base-agent remove [slug]` | Tear down every trace of a customer across operator_ui + dashboard + Telnyx + Ultravox + local FS. See "Sub-command: /base-agent remove" below. |

---

## Sub-command: `/base-agent remove [slug]`

Tear down a customer cleanly. Reads the saga audit log written by every preceding stage, replays inverse operations newest-first, falls back to live-discovery for any drift, verifies zero residue. Halts on Telnyx or Ultravox failures (so a partial wipe never leaves a phone ringing into a deleted agent).

### When to run

- A test/demo customer is no longer needed.
- A prospect dropped out before deployment was completed.
- An onboarding ran wrong and you want to start over.
- A real customer churned and asked for full data deletion.

### What it touches

| System | What gets cleaned |
|---|---|
| Supabase `operator_ui` | `customers`, `runs`, `artifacts`, `annotations`, `feedback`, `verifications` rows. `lessons` rows are surgically scrubbed (this customer's id removed from `observed_in_customer_ids`; their `feedback_ids` removed from `source_feedback_ids`); orphan unpromoted lessons get deleted, promoted ones are kept (the prompt file change is git-tracked). |
| Supabase `dashboard` | `workspaces`, `public.users`, `auth.users` (via Auth Admin API), `calls`, `workflow_errors` rows. Skipped silently if the dashboard schema isn't accessible from the configured Supabase URL (PGRST205). |
| Telnyx | DIDs tagged `claimed-{slug}` get fully restored: claim tag dropped, `pool-available` re-asserted, `voice_url` cleared, any TeXML wiring from Stages 8/9 reset. Single inverse covers Stages 7+8+9 cleanup. |
| Ultravox | Agents whose name (case-insensitive, hyphens stripped) contains the slug get DELETEd. |
| Local FS | All `runs/{slug}-*` directories get `rm -rf`'d. |
| `operator_ui.deployment_log` | Rows for this slug flip `active` → `reversed` (with timestamps). NOT deleted — kept as a permanent audit trail of "this slug was deployed on X, torn down on Y." |

### What it does NOT touch

- **Per-customer Railway services** (the customer-specific `*-server` deployments). Operator manually tears those down at railway.app — they're separate infra.
- **Shared central-n8n workflows that have inert `errorWorkflow` pointers** to this customer's external server. Those become dead-ends when the per-customer Railway service goes down.
- **Promoted-to-prompt lessons** (where `lessons.promoted_to_prompt=true`). The prompt file change is git-tracked methodology evolution, not customer-identifying data.

### Usage

```bash
# Dry run — enumerate everything that would be deleted, exit without changes
bash base-agent-setup/scripts/remove-customer.sh acme-plumbing --dry-run

# Real run — print inventory, prompt y/N, tear down on yes
bash base-agent-setup/scripts/remove-customer.sh acme-plumbing

# Non-interactive (skip the prompt)
bash base-agent-setup/scripts/remove-customer.sh acme-plumbing --yes
```

### Safety design

- **Confirmation gate** — single `(y/N)` prompt after the inventory prints. Anything other than literal `y` (case-insensitive) aborts. `--yes` skips for scripted use.
- **Halt rules** — Telnyx and Ultravox failures abort immediately with exit code 2 (re-run after fixing). Downstream failures (Supabase rows, local FS) are best-effort — the script continues, summarizes, and exits 1 if anything didn't clean up.
- **Verification phase** — after teardown, re-runs the live-discovery queries. If anything survived (residue), prints what + exits 1. Zero-residue runs print `✓ Verified` + exit 0.
- **Drift detection** — items found in reality without a matching `deployment_log` entry get a `⚠ Drift detected` warning before the prompt. They still get cleaned up via live-discovery teardown — drift detection is an audit signal, not a blocker.

### Halt conditions

- Telnyx PATCH on the TeXML app fails (network, auth, 5xx) → halt with exit 2. Re-run picks up where it stopped.
- Ultravox DELETE on the agent fails → halt with exit 2.
- `operator_ui` REST returns 5xx during discovery → halt early before any destructive action.
- Slug doesn't match `^[a-z0-9][a-z0-9-]*$` → reject with exit 1 (defensive against shell-injection / typos).

### Resume note

The skill is idempotent. Re-running on a partially-cleaned customer picks up where it stopped: anything already gone is marked `reverse_skipped` automatically; anything still present gets cleaned this run.

---

## Notes for future-me running this skill

- **The `runs/` directory is gitignored.** Per-customer artifacts live there forever (or until manually pruned). Don't commit them.
- **The reference agent pull is live every run** by design — so tuning the reference agent (voice, temperature, inactivity) propagates automatically to every new customer's rough agent. If you want to pin a customer to a specific reference snapshot, copy `reference-settings.json` somewhere stable and pass it via a future `--settings-file-override` flag.
- **The discovery prompt + cover email are the highest-leverage outputs of this skill.** A weak opener wastes the customer's ChatGPT session. Get the bespoke first question right; don't ship generic.
- **The `/onboard-customer` handoff is intentionally late.** If anything in Stages 1–10 fails, no Supabase rows are written and no magic links are sent. The customer's first contact happens after the rough agent is verified working.
- **Hard rule, repeated for emphasis:** Never construct a partial Ultravox PATCH body. PATCH semantics revert any omitted field to API default (silently wipes voice/temp/inactivity/tools). System-prompt updates against a live agent go through `scripts/regenerate-agent.sh` (safe full-PATCH: GET → swap systemPrompt → PATCH full body → verify no drift). For non-prompt corrections (voice/name/firstSpeaker), POST a new agent and discard the old one.
