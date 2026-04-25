# base-agent-setup — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship a globally-invocable Claude Code skill (`/base-agent`) that runs the full Spotfunnel GTM Phase 1 base-agent onboarding flow end-to-end — scrape → rough agent live in Ultravox with Teleca/TelcoWorks-proven settings → Telnyx DID claimed + TeXML wired → dashboard registered via `/onboard-customer` → bespoke ChatGPT-ready discovery prompt for the customer.

**Architecture:** Markdown SKILL.md orchestrates 11 resumable stages. All AI inference runs inline in Claude Code (Opus 4.7) — zero Haiku/SDK calls. Bash helper scripts (in `scripts/`) talk to vendor APIs (Firecrawl, Ultravox, Telnyx, Resend) via `curl`. Reference doc in `reference-docs/discovery-methodology.md` steers the discovery-prompt generator. State-per-run at `runs/{slug}-{timestamp}/state.json` for resumability.

**Tech Stack:** Bash + curl + jq-free Python3 for JSON (same pattern as `onboard-customer`); markdown for prompts and docs; Claude Opus 4.7 as inline brain.

**Design doc:** `C:/Users/leoge/.claude/skills/base-agent-setup/docs/2026-04-25-design.md`

---

## Testing posture

This isn't a Python lib — it's a skill. We don't have pytest. Adapt TDD as follows:

- **Bash scripts** → write a "verification command" for each script that exercises it against stubs or a harmless real call. Script's expected output is spelled out; the test passes when actual matches.
- **Prompt/reference files** → "acceptance test" = paste a representative stub input into Claude (via a separate test conversation) and confirm the output has the expected structure. Record the stub + expected output shape in `tests/stubs/` for reproducibility.
- **End-to-end** → Tasks 25–26 run real customer paths. No shortcuts.
- **Commits** → git-track the skill directory. Init a git repo in `C:/Users/leoge/.claude/skills/base-agent-setup/` before Task 1 so every task can commit. (Global skills dir is not itself a repo by default.)

## Constraints reminder

- **NEVER PATCH Ultravox agents via API** (CLAUDE.md rule — wipes unrelated fields). Agent creation only via POST; corrections = POST new + discard old.
- **NEVER auto-buy Telnyx DIDs.** Pool-low alert, pool-empty halt. Manual purchase stays with Leo.
- **Windows + Git Bash gotchas** (from `onboard-customer` SKILL): every `curl` needs `--ssl-no-revoke`; `jq` is not installed (use Python3); `/tmp/` paths can't cross Git Bash ↔ Windows Python — use `c:/Users/leoge/...` absolute paths.
- **Env vars loaded once at Stage 0** from `c:/Users/leoge/OneDrive/Documents/AI Activity/VSCODE/Ultravox/teleca/.env` via `set -a; source ...; set +a`.
- **No tech-stack content in customer-facing artifacts.** The reference doc, discovery prompt, and cover email don't write about our tools or anyone else's. The discovery agent has zero context on how the voice agent is built — by omission, not by rule. If ChatGPT speculates generically about voice AI when asked, that's fine and recoverable; the system just contains nothing accurate to leak.

---

## Phase 0 — Portable repo bootstrap (do this FIRST, before Phase A)

The skill must ship as a public GitHub repo a friend can clone and run on their own machine. This phase creates that repo and lays in everything not specific to a single operator.

### Task 0.1: Create local repo at `c:/Users/leoge/Code/spotfunnel-voice-skills/` and init git

**Step 1:** `mkdir -p c:/Users/leoge/Code/spotfunnel-voice-skills && cd c:/Users/leoge/Code/spotfunnel-voice-skills && git init`

**Step 2:** `mkdir -p schema docs/runbooks`

**Step 3:** Move (don't copy) `c:/Users/leoge/.claude/skills/base-agent-setup/` into the repo: `mv c:/Users/leoge/.claude/skills/base-agent-setup c:/Users/leoge/Code/spotfunnel-voice-skills/`

**Step 4:** Symlink it back so the skill keeps working locally: `ln -s c:/Users/leoge/Code/spotfunnel-voice-skills/base-agent-setup c:/Users/leoge/.claude/skills/base-agent-setup` (use `mklink /D` on Windows cmd if symlink path syntax differs — Git Bash handles symlinks fine for this case).

**Step 5:** Verify the symlink works: `ls c:/Users/leoge/.claude/skills/base-agent-setup/docs/` should show the design + plan files.

**Step 6:** Commit: `git add -A && git commit -m "init: spotfunnel-voice-skills repo with base-agent-setup"`

### Task 0.2: Bring `onboard-customer` skill into the repo

**Step 1:** Copy (not move yet — let's verify it works first) `c:/Users/leoge/.claude/skills/onboard-customer/` to `c:/Users/leoge/Code/spotfunnel-voice-skills/onboard-customer/`.

**Step 2:** **Portability audit pass:** grep the copied skill for hardcoded values that need to become env vars:
```bash
grep -rEn 'leoge|teleca/.env|dashboard-server-production-0ee1' onboard-customer/
```
Replace each occurrence:
- `c:/Users/leoge/OneDrive/Documents/AI Activity/VSCODE/Ultravox/teleca/.env` → use the portable env resolver (same pattern as Task 9)
- `https://dashboard-server-production-0ee1.up.railway.app` → `$DASHBOARD_SERVER_URL`
- Any other Leo-specific paths or IDs → env var

**Step 3:** Copy `c:/Users/leoge/OneDrive/Documents/AI Activity/VSCODE/Ultravox/docs/n8n-error-wiring.md` (referenced by onboard-customer) into `c:/Users/leoge/Code/spotfunnel-voice-skills/docs/runbooks/n8n-error-wiring.md`. Update onboard-customer's reference to the new path.

**Step 4:** Once verified, replace the original local skill with a symlink to the repo copy: `rm -rf c:/Users/leoge/.claude/skills/onboard-customer && ln -s c:/Users/leoge/Code/spotfunnel-voice-skills/onboard-customer c:/Users/leoge/.claude/skills/onboard-customer`.

**Step 5:** Commit: `git add -A && git commit -m "feat: bring onboard-customer into repo, parameterize hardcoded paths"`

### Task 0.3: Write `.gitignore`

**Step 1:** At repo root, create `.gitignore`:
```
.env
*.local.env
**/runs/
!**/runs/.gitkeep
~/.config/spotfunnel-skills/
*.log
.DS_Store
node_modules/
.tmp-*/
```

**Step 2:** Commit.

### Task 0.4: Write `.env.example`

**Step 1:** At repo root, create `.env.example` with every required env var, blank value, and a comment line above each explaining where to get it. Mirror the list from the design doc Stage 0 + onboard-customer's ENV_SETUP. Include section headers (`# ====== Vendor APIs ======`, `# ====== Operator's Backend ======`, etc.) for scannability.

**Step 2:** Verify completeness — diff against actual env vars referenced anywhere in either skill's bash scripts. Every reference must have a corresponding `.env.example` entry.

**Step 3:** Commit.

### Task 0.5: Write top-level `README.md`

**Step 1:** Create `README.md` at repo root with these sections:
- **What this is** — one-paragraph pitch: a pair of Claude Code skills that automate end-to-end voice-AI customer onboarding (scrape → rough agent → discovery prompt → dashboard wiring)
- **Prerequisites** — Claude Code installed; Ultravox / Telnyx / Supabase / Resend / Firecrawl accounts; an existing reference agent in your Ultravox account; a deployed dashboard-server (link to its repo if separate)
- **Quick install** — `git clone`, copy `.env.example` → `.env`, fill in vars, symlink the two skill folders into `~/.claude/skills/`, run `/base-agent` in a fresh Claude Code session
- **Layout** — directory tree explanation
- **Skills** — short descriptions of `base-agent-setup` and `onboard-customer` with links to their internal SKILL.md files
- **Contributing / forks** — simple guidance: fork, customize the reference doc methodology, push back if helpful
- **License** — MIT (or whichever Leo picks)

**Step 2:** Commit.

### Task 0.6: Write `INSTALL.md`

**Step 1:** Detailed step-by-step setup for a fresh machine — every external account creation, schema migration, env var population, symlink command. Include screenshots-as-words ("In Ultravox console: Settings → API keys → Create new key, paste it as `ULTRAVOX_API_KEY` in your `.env`").

**Step 2:** Commit.

### Task 0.7: Schema migration for the dashboard

**Step 1:** Use the supabase MCP tools to dump the current dashboard schema (tables: `workspaces`, `users`, `calls`, `workflow_errors`, etc., plus relevant policies) to `schema/supabase-dashboard.sql`. Strip any rows with real customer data — schema only.

**Step 2:** Add a header to the file: `-- Run this against a fresh Supabase project to bootstrap the dashboard backend.`

**Step 3:** Commit.

### Task 0.8: Pick a license + add LICENSE file

**Step 1:** Create `LICENSE` at repo root. Default to MIT — easy to share, no surprises. Confirm with Leo if he prefers something else before pushing.

**Step 2:** Commit.

### Task 0.9: Push to public GitHub

**Step 1:** Create the GitHub repo (Leo does this manually via web — `gh repo create spotfunnel-voice-skills --public` works too if `gh` is authenticated).

**Step 2:** `git remote add origin git@github.com:Spotfunnel/spotfunnel-voice-skills.git`

**Step 3:** `git push -u origin main`

**Step 4:** Verify the repo is public and `.env` was NOT pushed (gitignore working). Visit the GitHub URL and confirm `.env.example` is there but `.env` isn't.

---

## Phase A — Skill scaffolding

### Task 1: Init git + scaffold directory tree

**Files:**
- Create: `C:/Users/leoge/.claude/skills/base-agent-setup/.gitignore`
- Create dirs: `reference-docs/`, `prompts/`, `scripts/`, `templates/`, `runs/`, `tests/stubs/`, `docs/` (docs/ already exists from brainstorming)

**Step 1:** `cd C:/Users/leoge/.claude/skills/base-agent-setup && git init`

**Step 2:** Write `.gitignore`:
```
runs/
!runs/.gitkeep
.env
*.log
```

**Step 3:** `mkdir -p reference-docs prompts scripts templates runs tests/stubs && touch runs/.gitkeep`

**Step 4:** Verify:
```bash
ls -la
```
Expected: `.git/`, `.gitignore`, `docs/`, `reference-docs/`, `prompts/`, `scripts/`, `templates/`, `runs/`, `tests/`

**Step 5:** Commit:
```bash
git add -A && git commit -m "scaffold: base-agent-setup skill directory tree"
```

---

### Task 2: SKILL.md frontmatter + skeleton

**Files:**
- Create: `C:/Users/leoge/.claude/skills/base-agent-setup/SKILL.md`

**Step 1:** Write frontmatter + section headers only (no content yet):

```markdown
---
name: base-agent-setup
description: Automates Spotfunnel's GTM Phase 1 base-agent customer onboarding. Invoked as /base-agent or /base-agent [customer]. Scrapes site, synthesizes brain-doc, creates rough Ultravox agent with TelcoWorks-Jack-derived settings, claims Telnyx DID + wires TeXML, generates ChatGPT-ready discovery prompt, hands off to /onboard-customer. Runs from any project dir. Use when Leo says "/base-agent", "onboard [name] from scratch", "new customer base agent", or starts the 30-min post-meeting onboarding flow.
user_invocable: true
---

# base-agent-setup

## Runtime notes (Windows + Git Bash gotchas)

(Will mirror onboard-customer's gotchas block.)

## Stage 0 — Env preflight
## Stage 1 — Gather inputs
## Stage 2 — Firecrawl scrape (async)
## Stage 3 — Brain-doc synthesis
## Stage 4 — Rough system prompt generation
## Stage 5 — Reference agent settings pull
## Stage 6 — Create Ultravox agent
## Stage 7 — Claim Telnyx DID from pool
## Stage 8 — TeXML app wiring
## Stage 9 — TeXML → Ultravox telephony_xml
## Stage 10 — Per-customer discovery prompt
## Stage 11 — Hand off to /onboard-customer

## Idempotency & failure handling
## What this skill does NOT do
## Commands
```

**Step 2:** Verify file exists + frontmatter parses:
```bash
head -5 SKILL.md
```
Expected: `---` then `name: base-agent-setup` etc.

**Step 3:** Commit:
```bash
git add SKILL.md && git commit -m "feat: skill frontmatter and stage skeleton"
```

---

### Task 3: ENV_SETUP.md

**Files:**
- Create: `ENV_SETUP.md`

**Step 1:** Document required env vars. Mirror onboard-customer's ENV_SETUP.md structure:
- `ULTRAVOX_API_KEY` — from Ultravox console
- `TELNYX_API_KEY` — from Telnyx console
- `FIRECRAWL_API_KEY` — from Firecrawl dashboard
- `SUPABASE_URL` — spotfunnel-dashboard Supabase project URL
- `SUPABASE_SERVICE_ROLE_KEY` — for /onboard-customer handoff
- `RESEND_API_KEY` — for pool alerts
- `RESEND_FROM_EMAIL` — default `noreply@spotfunnel.com`
- `REFERENCE_ULTRAVOX_AGENT_ID` — TelcoWorks-Jack ID (new: needs adding to `.env`)
- `TELNYX_POOL_TEXML_APP_ID` — `2942921998587659757` per phase-4 handoff

All live in `c:/Users/leoge/OneDrive/Documents/AI Activity/VSCODE/Ultravox/teleca/.env`. Document the single-source-of-truth pattern + load command.

**Step 2:** Verify: file exists, at least 10 env vars documented.

**Step 3:** Commit:
```bash
git add ENV_SETUP.md && git commit -m "docs: env var requirements"
```

---

## Phase B — Reference doc + prompt templates (content authoring)

### Task 4: Author reference-docs/discovery-methodology.md

**Files:**
- Create: `reference-docs/discovery-methodology.md`

This is the **highest-value creative artifact in the skill** — stable across all customers, read by Claude at Stage 10 to produce each bespoke discovery prompt.

**Step 1:** Write the doc per the design doc §4 "The reference doc." Sections:
1. **Purpose** — what this doc does, what reads it
2. **Meeting-first scope inference** — the load-bearing principle. Meeting defines SCOPE; website is secondary context for facts only. Never ask about things outside the scope the customer defined in the meeting (e.g. if meeting says "inbound appointment setter only," skip transfer questions, skip walk-in-customer personas). When ambiguous, ChatGPT confirms scope up-front before drilling in.
3. **Coverage targets** — sections A–F from the design doc, *each flagged "conditional on scope."* Section B explicitly says "skip entirely if meeting says no transfers." Section B's after-hours item now covers: emergency number vs. take-a-message, with scenario-permitting rules if an emergency number exists.
4. **Question-generation principles** — (1) meeting-first scope inference; (2) never re-ask; (3) cite source; (4) compliance → research + options; (5) open-ended brain-engaging; (6) **integration optimism with research** — assume ANY tool with a self-serve public API is integrable, ChatGPT web-searches each named tool to confirm tier, defaults to YES, only flags when API genuinely doesn't exist or requires multi-week dev approval; (7) graceful-hard-asks (only when genuinely hard).
5. **Posture rules** — optimistic-realistic; stay focused on customer business outcomes; multi-turn output OK; copy-pasteable
6. **Brief output schema** — six sections A–F, prose format, with a note that out-of-scope sections may be empty or omitted entirely

**Step 2:** Acceptance test — write TWO stubs to test both the broad and narrow-scope paths:
- `tests/stubs/methodology-broad-scope.md` — full receptionist use case (transfers, after-hours, multiple personas). Discovery prompt should cover all sections A–F.
- `tests/stubs/methodology-narrow-scope.md` — "inbound appointment setter for Google Ads leads only." Discovery prompt MUST skip transfer questions, skip unrelated-persona questions, focus on appointment-booking specifics.

Run both through Claude in a fresh conversation; verify scope inference works correctly in each case and never re-asks known facts in either.

**Step 3:** Commit:
```bash
git add reference-docs/discovery-methodology.md tests/stubs/methodology-broad-scope.md tests/stubs/methodology-narrow-scope.md && \
  git commit -m "feat: discovery methodology reference doc with meeting-first scope inference"
```

---

### Task 5: Brain-doc synthesis prompt

**Files:**
- Create: `prompts/synthesize-brain-doc.md`

**Step 1:** Write the prompt Claude uses in Stage 3 to produce a structured brain-doc from (scrape + transcript + hints). Prompt should instruct Claude to:
- Extract company identity, services, hours, staff, locations, existing contact, policies, tone markers
- Flag "inferred from meeting only" vs. "confirmed by both site and meeting"
- Target 3–8 KB output
- Output in a stable markdown structure downstream stages rely on

**Step 2:** Acceptance test — `tests/stubs/brain-doc-test-input.md` with a small fake scrape + transcript; run the prompt through Claude; verify output has all required sections and size is in range.

**Step 3:** Commit:
```bash
git add prompts/synthesize-brain-doc.md tests/stubs/brain-doc-test-input.md && \
  git commit -m "feat: brain-doc synthesis prompt"
```

---

### Task 6: Rough system prompt assembly template

**Files:**
- Create: `prompts/assemble-rough-system-prompt.md`
- Create: `templates/universal-rules.md`

**Step 1:** Port the 16 universal rules from VoiceAIMachine's `services/api/src/api/composer.py` (or `prompts/` dir — verify path) into `templates/universal-rules.md`. Copy verbatim so they match what Leo already ships with real customers.

**Step 2:** Write `prompts/assemble-rough-system-prompt.md` — instructs Claude to produce the agent's systemPrompt by concatenating:
- `UNIVERSAL_RULES` (from `templates/universal-rules.md`)
- `AGENT_IDENTITY` ("You are [agent_name] for [company]. ...")
- `BRAIN_DOC` (from Stage 3 output)
- `MINIMAL_TOOL_NOTE` (fixed text — "You have no action tools today. For any request requiring a tool, say so clearly and offer to take a message or warm-transfer.")

Prompt specifies exact joining order, section delimiters, and length target (~10–20 KB).

**Step 3:** Acceptance test — feed `tests/stubs/brain-doc-test-input.md`'s expected brain-doc output through the assembly prompt; verify the resulting system prompt has all four layers clearly delimited and totals within size bounds.

**Step 4:** Commit:
```bash
git add prompts/assemble-rough-system-prompt.md templates/universal-rules.md && \
  git commit -m "feat: rough system prompt assembly"
```

---

### Task 7: Discovery prompt generator

**Files:**
- Create: `prompts/generate-discovery-prompt.md`

**Step 1:** Write the prompt for Stage 10. Claude will read:
- The brain-doc (Stage 3 output)
- Full meeting transcript
- Operator hints
- The reference doc (`reference-docs/discovery-methodology.md`)

And produce: a single copy-pasteable ChatGPT-ready prompt (6–15k words typical) containing:
- Known facts about the business (ground truth; don't re-ask)
- Transcript with cited references
- Tailored **opening question** anchored in something the customer said in the meeting
- Embedded methodology from the reference doc
- Brief output schema (sections A–F)

The prompt also specifies that Claude should output a separate **cover email template** Leo can forward.

**Step 2:** Acceptance test — with the test stub from Task 4, run this prompt; verify output has the opening tailored question + the methodology embedded + brief output schema spelled out + a cover email section.

**Step 3:** Commit:
```bash
git add prompts/generate-discovery-prompt.md && \
  git commit -m "feat: per-customer discovery prompt generator"
```

---

### Task 8: Cover email template skeleton

**Files:**
- Create: `templates/cover-email.md`

**Step 1:** Write the skeletal template:
- Subject: `Next step: quick ChatGPT brainstorm before we build your agent`
- Greeting (use customer name)
- 1 paragraph: explains Leo wants to get the agent right the first time, ChatGPT brainstorm saves lots of back-and-forth
- Instruction: paste the block below into a fresh ChatGPT conversation (or a ChatGPT custom GPT they save for re-use)
- Expectation-setting: this takes 20–40 min, output is a single block they email back, no formatting cleanup needed
- Sign-off from Leo
- `--- PASTE EVERYTHING BELOW THIS LINE INTO CHATGPT ---`
- `{{DISCOVERY_PROMPT}}` placeholder filled in at Stage 10

**Step 2:** Acceptance test — visually review the template; ensure substitution markers are clear; ensure no internal jargon leaks (no "Ultravox", "Telnyx", etc.).

**Step 3:** Commit:
```bash
git add templates/cover-email.md && git commit -m "feat: cover email template"
```

---

## Phase C — Bash helper scripts

### Task 9: scripts/env-check.sh

**Files:**
- Create: `scripts/env-check.sh`

**Step 1:** Write: resolves the env file location portably, sources it, verifies each required var is non-empty, prints `[OK] X loaded` or `[MISSING] X`, exit 1 if any missing.

```bash
#!/bin/bash
# Usage: source scripts/env-check.sh
# Resolves env file in this order: $SPOTFUNNEL_SKILLS_ENV → <repo-root>/.env → cached path → prompt.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CACHE_FILE="$HOME/.config/spotfunnel-skills/env-path"

if [ -n "$SPOTFUNNEL_SKILLS_ENV" ] && [ -f "$SPOTFUNNEL_SKILLS_ENV" ]; then
  ENV_FILE="$SPOTFUNNEL_SKILLS_ENV"
elif [ -f "$REPO_ROOT/.env" ]; then
  ENV_FILE="$REPO_ROOT/.env"
elif [ -f "$CACHE_FILE" ]; then
  ENV_FILE="$(cat "$CACHE_FILE")"
else
  echo "No env file found. Set SPOTFUNNEL_SKILLS_ENV, or copy .env.example to <repo-root>/.env and fill in values."
  return 1 2>/dev/null || exit 1
fi

set -a; source "$ENV_FILE"; set +a

required=(ULTRAVOX_API_KEY TELNYX_API_KEY FIRECRAWL_API_KEY SUPABASE_URL SUPABASE_SERVICE_ROLE_KEY RESEND_API_KEY RESEND_FROM_EMAIL OPS_ALERT_EMAIL REFERENCE_ULTRAVOX_AGENT_ID TELNYX_POOL_TEXML_APP_ID DASHBOARD_SERVER_URL N8N_BASE_URL N8N_API_KEY N8N_ERROR_REPORTER_WORKFLOW_ID)
missing=0
for v in "${required[@]}"; do
  eval "val=\$$v"
  if [ -z "$val" ]; then echo "[MISSING] $v"; missing=1; else echo "[OK] $v loaded"; fi
done
[ $missing -eq 0 ] || { echo "See .env.example at repo root for what each var should contain."; return 1 2>/dev/null || exit 1; }
```

**Step 2:** Verify with real env:
```bash
source scripts/env-check.sh
```
Expected: All ✅ lines, exit 0 (assuming Leo has added `REFERENCE_ULTRAVOX_AGENT_ID` and `TELNYX_POOL_TEXML_APP_ID` to the env — if not, it'll flag them and Leo adds them).

**Step 3:** Verify failure mode — temporarily unset one:
```bash
unset ULTRAVOX_API_KEY && source scripts/env-check.sh; echo "exit=$?"
```
Expected: `❌ ULTRAVOX_API_KEY missing`, exit 1.

**Step 4:** Commit:
```bash
git add scripts/env-check.sh && git commit -m "feat: env preflight helper"
```

---

### Task 10: scripts/firecrawl-scrape.sh

**Files:**
- Create: `scripts/firecrawl-scrape.sh`

**Step 1:** Write: takes `--url` and `--out-dir` args; kicks off Firecrawl `/v1/crawl` (or v2 async — confirm against current Firecrawl docs); polls status; on complete, dumps markdown per page to `{out-dir}/pages/` and a flattened `{out-dir}/combined.md`. Caps at 50 pages; respects `respectRobots:false`. Uses `--ssl-no-revoke`.

Use the firecrawl MCP (`mcp__plugin_firecrawl_firecrawl__*`) if available for the MCP path, but bash curl as the authoritative flow so it works from inside a skill without MCP.

**Step 2:** Verify against a real test URL (e.g. `https://spotfunnel.com`):
```bash
bash scripts/firecrawl-scrape.sh --url https://spotfunnel.com --out-dir /tmp/scrape-test
ls /tmp/scrape-test/pages/
```
Expected: at least 5 markdown files, `combined.md` present and non-empty.

**Step 3:** Verify page cap:
```bash
bash scripts/firecrawl-scrape.sh --url https://spotfunnel.com --out-dir /tmp/scrape-test --max-pages 3
ls /tmp/scrape-test/pages/ | wc -l
```
Expected: `3`.

**Step 4:** Commit:
```bash
git add scripts/firecrawl-scrape.sh && git commit -m "feat: firecrawl full-site scrape helper"
```

---

### Task 11: scripts/ultravox-get-reference.sh

**Files:**
- Create: `scripts/ultravox-get-reference.sh`

**Step 1:** Write: takes `--agent-id` and `--out` args (defaults agent-id to `$REFERENCE_ULTRAVOX_AGENT_ID`); `GET https://api.ultravox.ai/api/agents/{id}` with `X-API-Key`; extracts `voice`, `temperature`, `firstSpeaker`, `inactivityMessages`, `languageHint`, `model`, and writes to `{out}/reference-settings.json` using Python3 for JSON parsing.

**Step 2:** Verify with the real reference agent:
```bash
bash scripts/ultravox-get-reference.sh --out /tmp/ref-test
cat /tmp/ref-test/reference-settings.json
```
Expected: JSON with `voice`, `temperature`, `inactivityMessages`, etc., non-empty.

**Step 3:** Verify failure mode — wrong agent ID:
```bash
bash scripts/ultravox-get-reference.sh --agent-id 00000000-0000-0000-0000-000000000000 --out /tmp/ref-fail
```
Expected: prints HTTP 404, exits 1.

**Step 4:** Commit:
```bash
git add scripts/ultravox-get-reference.sh && git commit -m "feat: pull ref agent settings"
```

---

### Task 12: scripts/ultravox-create-agent.sh

**Files:**
- Create: `scripts/ultravox-create-agent.sh`

**Step 1:** Write: takes `--name`, `--system-prompt-file`, `--settings-file` (the reference-settings.json from Task 11), `--out` dir. Assembles the POST payload in Python3 (merges system prompt + reference settings into the Ultravox agent create schema), POSTs to `https://api.ultravox.ai/api/agents`, captures the `agentId` from response, writes `{out}/agent-created.json`.

**No PATCH fallback.** If POST fails, dump the request/response bodies and exit 1.

**Step 2:** Verify: create a throwaway test agent with minimal prompt:
```bash
echo "You are TestBot, a temporary test agent." > /tmp/test-prompt.md
bash scripts/ultravox-create-agent.sh --name "TEST-DELETE-$(date +%s)" --system-prompt-file /tmp/test-prompt.md --settings-file /tmp/ref-test/reference-settings.json --out /tmp/create-test
python3 -c "import json; print(json.load(open('/tmp/create-test/agent-created.json'))['agentId'])"
```
Expected: a UUID. Then **manually delete the test agent from Ultravox console** (skill doesn't auto-delete).

**Step 3:** Verify failure mode:
```bash
bash scripts/ultravox-create-agent.sh --name "" --system-prompt-file /tmp/test-prompt.md --settings-file /tmp/ref-test/reference-settings.json --out /tmp/create-fail
```
Expected: non-zero exit, request/response bodies printed.

**Step 4:** Commit:
```bash
git add scripts/ultravox-create-agent.sh && git commit -m "feat: ultravox POST agent"
```

---

### Task 13: scripts/telnyx-claim-did.sh

**Files:**
- Create: `scripts/telnyx-claim-did.sh`

**Step 1:** Write: takes `--area-code` (preferred; empty = any AU), `--out`. Queries Telnyx for unassigned DIDs in pool (reuse VAM's `telnyx.py::claim_did_for_user` logic — read its source for the auth pattern, pool selection, area-code filter), picks one, marks it claimed (Telnyx doesn't have true "claim" — the app just tracks which DID is tied to a customer via the internal `active_dids` concept; follow VAM's exact approach).

Counts pool size after claim; if `< 3`, triggers a Resend alert via Task 17's script. If pool is empty (no DID claimed), exits 1 WITHOUT claiming, and triggers hard alert.

Writes `{out}/claimed-did.json` with `{ did, area_code, pool_remaining }`.

**Step 2:** Verify — dry-run flag first (`--dry-run` shows what would be claimed without claiming):
```bash
bash scripts/telnyx-claim-did.sh --area-code 02 --dry-run --out /tmp/telnyx-test
```
Expected: JSON with proposed DID + pool remaining; no actual change.

**Step 3:** Verify empty-pool path (requires either real empty pool or mock — use a stub env var `TELNYX_TEST_POOL_EMPTY=1` that the script respects):
```bash
TELNYX_TEST_POOL_EMPTY=1 bash scripts/telnyx-claim-did.sh --area-code 02 --out /tmp/telnyx-empty
echo "exit=$?"
```
Expected: exit 1, alert fired.

**Step 4:** Commit:
```bash
git add scripts/telnyx-claim-did.sh && git commit -m "feat: telnyx DID claim from pool"
```

---

### Task 14: scripts/telnyx-wire-texml.sh

**Files:**
- Create: `scripts/telnyx-wire-texml.sh`

**Step 1:** Write: takes `--did` + `--texml-app-id` (defaults to `$TELNYX_POOL_TEXML_APP_ID`). Verifies the DID is bound to that TeXML app; if not, updates the DID's voice-settings to point at the app ID. Verifies codec is 16 kHz (with g711 fallback acceptable per VAM's pattern) by GETting the TeXML app and checking its `codec` field. Confirms `status_callback` still points at VAM's `/telnyx-webhook`.

Writes `{out}/texml-wired.json` with verification results.

**Step 2:** Verify: run against a claimed test DID (from Task 13 dry-run or a real throwaway):
```bash
bash scripts/telnyx-wire-texml.sh --did "+6173130XXXX" --out /tmp/texml-test
cat /tmp/texml-test/texml-wired.json
```
Expected: `{ "did_bound": true, "codec_ok": true, "status_callback_ok": true }`.

**Step 3:** Verify mismatch detection — manually break something (point the DID to a different app):
```bash
# (break it via Telnyx console or API, then re-run)
bash scripts/telnyx-wire-texml.sh --did "+6173130XXXX" --out /tmp/texml-broken
```
Expected: detects mismatch, either fixes or exits 1 with clear diagnosis.

**Step 4:** Commit:
```bash
git add scripts/telnyx-wire-texml.sh && git commit -m "feat: telnyx TeXML wiring + verification"
```

---

### Task 15: scripts/wire-ultravox-telephony.sh

**Files:**
- Create: `scripts/wire-ultravox-telephony.sh`

**Step 1:** Write: takes `--did` + `--ultravox-agent-id`. Points the DID's TeXML app (the pool one) at `https://app.ultravox.ai/api/agents/{agent_id}/telephony_xml`. Verifies by cURLing the TeXML endpoint and grepping for the agent_id in returned XML. The pool TeXML app is shared — this changes its `voice_url`/`webhook_url` to the new agent path, BUT since the pool TeXML app is shared across all customers, **this is the wrong model** unless each customer gets their own TeXML app. Re-read VAM's `telnyx.py::claim_did_for_user` — it likely creates one TeXML app per DID-per-customer OR the pool app routes based on incoming DID.

**Resolve before writing:** does VAM use one-TeXML-per-customer or one-TeXML-pool-with-DID-routing? Read `services/api/src/api/telnyx.py` and `docs/phase-4-handoff-2026-04-23.md` to confirm. The phase-4 handoff says "Pool TeXML app 2942921998587659757" and mentions `claim_did_for_user` re-sets status_callback on every repoint, which suggests **per-customer TeXML is created at claim time**. Confirm this before writing the script.

Writes `{out}/telephony-wired.json` with verification.

**Step 2:** Verify: wire a test DID to a test agent, then dial the TeXML endpoint with curl:
```bash
bash scripts/wire-ultravox-telephony.sh --did "+6173130XXXX" --ultravox-agent-id "<test-agent-id>" --out /tmp/telephony-test
curl --ssl-no-revoke "https://api.telnyx.com/v2/texml_applications/.../compose" ...
```
Expected: returned XML contains the agent ID.

**Step 3:** Commit:
```bash
git add scripts/wire-ultravox-telephony.sh && git commit -m "feat: wire telnyx texml to ultravox telephony_xml"
```

---

### Task 16: scripts/state.sh

**Files:**
- Create: `scripts/state.sh`

**Step 1:** Write: helper functions `state_init`, `state_set`, `state_get`, `state_stage_complete`, `state_resume_from`. Uses a JSON file at `runs/{slug}-{timestamp}/state.json`. Stage completion writes `{stage_number: {"status": "done", "ts": "...", "outputs": {...}}}`. Resume picks up from highest `done` stage + 1.

**Step 2:** Verify — script self-tests:
```bash
source scripts/state.sh
state_init "test-customer" 
state_set_stage_complete 2 '{"scrape_size": 42}'
state_get_next_stage
# should print 3
```
Expected: `3`.

**Step 3:** Commit:
```bash
git add scripts/state.sh && git commit -m "feat: state file helpers for resumability"
```

---

### Task 17: scripts/resend-alert.sh

**Files:**
- Create: `scripts/resend-alert.sh`

**Step 1:** Write: takes `--subject`, `--body`, `--severity` (info/warn/crit). POSTs to Resend's `/emails` endpoint with `from=$RESEND_FROM_EMAIL`, `to=leo@getspotfunnel.com`. Includes severity as a subject prefix tag (e.g. `[crit]`). Dedupe within 12h via a local cache file (reuse VAM's `alerts.py` logic if applicable).

**Step 2:** Verify:
```bash
bash scripts/resend-alert.sh --subject "Skill test alert" --body "ignore me" --severity info
```
Expected: email arrives at `leo@getspotfunnel.com` (Leo checks inbox).

**Step 3:** Verify dedupe:
```bash
bash scripts/resend-alert.sh --subject "Skill test alert" --body "ignore me" --severity info
# second send same subject within 12h should be a no-op
```
Expected: second call prints "deduped (last sent < 12h)", exit 0, no second email.

**Step 4:** Commit:
```bash
git add scripts/resend-alert.sh && git commit -m "feat: resend alert helper with dedupe"
```

---

## Phase D — Orchestration SKILL.md body

Each task in Phase D writes one or more stages into `SKILL.md`. Stages are authored as markdown instructions Claude follows at runtime, not as code.

### Task 18: Write Stage 0 + Stage 1 in SKILL.md

**Files:**
- Modify: `SKILL.md` (fill in Stage 0 and Stage 1 sections)

**Step 1:** Write Stage 0 body — instructs Claude to source `.env`, run `scripts/env-check.sh`, halt with a clear message if any var missing. Mirrors the onboard-customer pattern.

**Step 2:** Write Stage 1 body — instructs Claude to ask the essential questions one at a time (customer name, website URL, transcript paste, operator hints, agent first name), skipping whatever's already in invocation args or recent convo context, confirming inferred slug. On completion, calls `state_init` via `scripts/state.sh` and writes the inputs to state.

**Step 3:** Verify — manually "role-play" a stage-1 invocation in a fresh conversation; check Claude asks the right questions in order and skips what's known.

**Step 4:** Commit:
```bash
git add SKILL.md && git commit -m "feat: SKILL.md stages 0-1 (env + inputs)"
```

---

### Task 19: Write Stages 2, 3, 4 in SKILL.md

**Files:**
- Modify: `SKILL.md`

**Step 1:** Write Stage 2 — instructs Claude to run `scripts/firecrawl-scrape.sh`, report scrape progress + page count, flag if page cap hit.

**Step 2:** Write Stage 3 — instructs Claude to read `prompts/synthesize-brain-doc.md`, feed in `{run-dir}/scrape/combined.md` + the meeting transcript from state + operator hints, produce brain-doc markdown, write to `{run-dir}/brain-doc.md`. State marks Stage 3 done.

**Step 3:** Write Stage 4 — instructs Claude to read `prompts/assemble-rough-system-prompt.md` + `templates/universal-rules.md`, assemble the system prompt per the template, write to `{run-dir}/system-prompt.md`. State marks Stage 4 done.

**Step 4:** Verify — role-play through stages 2-4 with a stub website + transcript; confirm files land in the right paths + state updates.

**Step 5:** Commit:
```bash
git add SKILL.md && git commit -m "feat: SKILL.md stages 2-4 (scrape + brain-doc + prompt)"
```

---

### Task 20: Write Stages 5, 6 in SKILL.md

**Files:**
- Modify: `SKILL.md`

**Step 1:** Write Stage 5 — runs `scripts/ultravox-get-reference.sh` with default `$REFERENCE_ULTRAVOX_AGENT_ID`. Halts if the GET fails (reference agent is load-bearing).

**Step 2:** Write Stage 6 — runs `scripts/ultravox-create-agent.sh` with `{run-dir}/system-prompt.md` + `{run-dir}/reference-settings.json`. **Explicitly reminds Claude** never to PATCH — any correction means a new POST + discard old. Captures `agentId` to state.

**Step 3:** Verify — role-play with a test customer, confirm test agent is created + agentId captured.

**Step 4:** Commit:
```bash
git add SKILL.md && git commit -m "feat: SKILL.md stages 5-6 (reference + create agent)"
```

---

### Task 21: Write Stages 7, 8, 9 in SKILL.md

**Files:**
- Modify: `SKILL.md`

**Step 1:** Write Stage 7 — infers area code from the scraped address (Claude reads `{run-dir}/brain-doc.md`, pulls the address, maps to `02/03/04/07/08/13` etc.). Runs `scripts/telnyx-claim-did.sh`. Halts on empty pool.

**Step 2:** Write Stage 8 — runs `scripts/telnyx-wire-texml.sh` on the claimed DID; halts on verification mismatch.

**Step 3:** Write Stage 9 — runs `scripts/wire-ultravox-telephony.sh` with the DID + agent_id; verifies via TeXML endpoint curl.

**Step 4:** Verify — role-play stages 7–9 with test DID + test agent; confirm DID → TeXML → agent chain is wired and verifiable.

**Step 5:** Commit:
```bash
git add SKILL.md && git commit -m "feat: SKILL.md stages 7-9 (telnyx + texml + telephony wire)"
```

---

### Task 22: Write Stage 10 in SKILL.md

**Files:**
- Modify: `SKILL.md`

**Step 1:** Write Stage 10 — instructs Claude to read `prompts/generate-discovery-prompt.md`, feed in brain-doc + transcript + hints + reference doc, generate:
- `{run-dir}/discovery-prompt.md` (the big ChatGPT-ready block)
- `{run-dir}/cover-email.md` (populated from `templates/cover-email.md`)

Reports word counts of both.

**Step 2:** Verify — role-play Stage 10; confirm both artifacts land, discovery prompt covers all 6 sections A–F in the customer's own language context.

**Step 3:** Commit:
```bash
git add SKILL.md && git commit -m "feat: SKILL.md stage 10 (discovery prompt + cover email)"
```

---

### Task 23: Write Stage 11 + final output summary in SKILL.md

**Files:**
- Modify: `SKILL.md`

**Step 1:** Write Stage 11 — instructs Claude to invoke `/onboard-customer` via the Skill tool with pre-filled args (slug, name, agent_id, telnyx_numbers, primary_user_email=`leo@getspotfunnel.com`, primary_user_name=`Leo Gewert`, archetype=auto). On failure, surface error but leave agent + DID claimed.

**Step 2:** Add the final "What Leo gets back" output block — replicate §6 of the design doc, templated with actual state values.

**Step 3:** Verify — role-play Stage 11; confirm onboard-customer is chained cleanly.

**Step 4:** Commit:
```bash
git add SKILL.md && git commit -m "feat: SKILL.md stage 11 (handoff) + final output"
```

---

### Task 24: Write idempotency + failure handling + Commands sections

**Files:**
- Modify: `SKILL.md`

**Step 1:** Write "Idempotency & failure handling" section — the failure table from the design doc §7.

**Step 2:** Write "What this skill does NOT do" section — the list from design doc §2 "Non-goals."

**Step 3:** Write "Commands" section:
- `/base-agent` — guided flow
- `/base-agent [customer-name]` — target a specific customer
- `/base-agent resume [slug]` — resume from last completed stage
- `/base-agent status [slug]` — show state without running

**Step 4:** Write "Runtime notes" block at the top — mirror onboard-customer's Windows + Git Bash gotchas.

**Step 5:** Full-file sanity check — SKILL.md reads as a coherent operator manual, no gaps.

**Step 6:** Commit:
```bash
git add SKILL.md && git commit -m "feat: idempotency, failure table, commands, runtime notes"
```

---

## Phase E — End-to-end testing

### Task 25: Dry-run test with fake customer

**Files:**
- Create: `tests/stubs/fake-customer/website.md`
- Create: `tests/stubs/fake-customer/transcript.md`
- Create: `tests/stubs/fake-customer/hints.md`

**Step 1:** Create a realistic fake customer — "Redgum Plumbing" — with a fake 5-page website content dump + a 1000-word fake meeting transcript + 200-word operator hints. Realistic enough that the skill exercises every stage.

**Step 2:** Manually walk through the full skill invocation using the fake customer. For vendor-API stages (6, 7, 8, 9, 11), use a dedicated "skill-smoke-test" workspace/agent that gets torn down after:
- Create actual test Ultravox agent (post-run: manually delete via console)
- Claim actual test DID (post-run: re-release via Telnyx console)
- Fire real onboard-customer flow (post-run: `/onboard-customer undo redgum-plumbing-test`)

**Step 3:** Verify every stage completes, state file updates correctly, resumability works (kill mid-stage 7, re-invoke, confirm stage 7 resumes).

**Step 4:** Tear down — manually delete test agent, re-release DID, undo workspace.

**Step 5:** Commit the stubs (not the test-run state dir — that's in `runs/` which is gitignored):
```bash
git add tests/stubs/fake-customer/ && git commit -m "test: e2e dry-run fixture"
```

---

### Task 26: First real customer

**Step 1:** Leo picks a new prospect who signed up recently but isn't live yet. Run `/base-agent <name>` with real website + real meeting transcript.

**Step 2:** Time the run. Goal: Leo's active attention ≤ 30 min. Note any gaps — stages that asked stupid questions, stages that failed silently, stages that took too long.

**Step 3:** Test-dial the rough agent once it's up — confirm it speaks, has the brain-doc context, gracefully degrades on tool-requiring asks.

**Step 4:** Email Leo the customer the discovery prompt + cover email (Leo forwards).

**Step 5:** When the brief returns, log learnings against the skill (what the ChatGPT interview missed, what it handled well). Open follow-up issues for prompt tuning.

**Step 6:** No commit (this is a production run, not code). Log in HERCULES:
```
/log first real run of /base-agent for <customer>. Time-to-ready=X min. Learnings: ...
```

---

## After the plan

Once Phase E passes, consider:

- Adding a `/base-agent status` dashboard command that lists all in-flight `runs/` dirs with stage progress.
- Porting the skill's orchestration layer into VoiceAIMachine's Railway API as the foundation for GTM Phase 2 (white-label self-serve).
- Adding a post-brief follow-up skill (`/design-tools [slug]`) that reads the returned brief and drafts tool/flow specs.

Plan complete and saved to `C:/Users/leoge/.claude/skills/base-agent-setup/docs/2026-04-25-implementation-plan.md`.
