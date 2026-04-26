# ZeroOnboarding Operator UI — Design + Implementation Plan

**Date:** 2026-04-26
**Repo:** `Spotfunnel/ZeroOnboarding` (renamed from `spotfunnel-voice-skills` — a separate operation done before this build)
**Stack:** Next.js (App Router) on Vercel + Supabase Postgres + local Python skill (Claude Code)
**Auth:** Vercel password protection (shared, multi-session, password set out-of-band — never committed to git)
**v1 scope:** annotation loop + CLI verification (no UI verify panel — deferred to v2)

---

## Context

The `/base-agent` skill onboards voice-AI customers via an 11-stage pipeline that produces brain-doc, system-prompt, discovery-prompt, customer-context, and cover-email artifacts. Today the entire flow lives in a Claude Code chat — outputs land in `runs/{slug}-{ts}/` folders on the operator's laptop and the only way to review or correct them is to open files manually and ask Claude in chat.

This is a black box. Specific failure modes:

1. **Corrections die in chat.** When Leo spots a bad line in a discovery prompt, he tells Claude to fix it — for that one customer. The underlying generator prompt that produced the bad line is never updated. Future runs repeat the mistake.
2. **No operational confidence.** No single view of "is this customer's agent live? DID wired? dashboard onboarded?". Verification is ad-hoc by re-reading API responses.
3. **No multi-operator access.** Leo's friend wants to use this too. Today they'd need a full local clone with shared `.env`. No way to view ongoing customer state from anywhere else.
4. **No history.** Every run overwrites the same files. No round-by-round comparison. Methodology iteration is blind.

This UI exists to close the **read + highlight + fix protocol loop** so future runs benefit from every past correction. Verification gets a CLI module + auto-hook so post-onboarding ops state is at least *reportable*; the live UI panel for verification ships in v2.

---

## Architecture

| Layer | Choice | Why |
|---|---|---|
| UI host | Vercel (free tier OK) | Native target for Next.js, password protection built-in |
| Frontend | Next.js App Router + TypeScript | Server Components for Supabase reads server-side; API Routes ready for v2 vendor calls |
| Markdown rendering | `react-markdown` + `remark-gfm` | Mature, fast, plugin-friendly |
| Highlight overlay | Native `window.getSelection()` + Hypothesis-style anchor scheme | Custom ~200-LOC implementation; rejected Hypothesis client (heavyweight) and react-markdown plugins (immature) |
| Style | Tailwind CSS | Speed of scaffolding |
| Data fetching | TanStack Query + Supabase JS client | Standard, no Redux |
| Database | Supabase Postgres (existing project, new `operator_ui` schema) | Already provisioned; one query layer; full-text search built-in |
| Auth (humans) | Vercel password protection (shared) | Zero auth code in app; trade-off accepted (Section 8 R8) |
| Auth (skill) | Service-role key in local `.env` | Bypasses RLS for operator schema only |
| Skill execution | Stays local, on operator's machine | Requires Claude Code + local API keys; cloud execution out of scope |
| Skill data writes | Supabase REST API (replacing local `cat > runs/...`) | Single canonical store; no dual-write |

**Visual design language (Apple-style subtractive premise):**
- Customer = book, not folder. Reading mode = single-artifact focus.
- Two pages only: customer list (`/`) and customer detail (`/c/{slug}`). Reading mode is `/c/{slug}/{artifact}`.
- Generous whitespace; sans-serif system stack for chrome (Inter); **serif for generated artifacts** (Charter / Source Serif Pro) — visually distinguishes "stuff Claude wrote" from "stuff the operator interacts with".
- Restrained color: warm off-white background `#FAFAF7`, primary text `#1A1A1A`, muted secondary `#6B6B6B`, single accent `#2563EB`, highlight `#FFF1A8` at 60%, muted forest green/brick red for status.
- 8px grid, single shadow style, 150ms ease-out transitions.
- No top nav, no logo, no breadcrumbs, no avatar menu, no notification badge, no settings page.
- Keyboard nav throughout (Windows): `Ctrl+K` palette, `Ctrl+Enter` save, `Alt+←/→` prev/next customer, `1`–`7` jump to chapter, `J/K` next/prev linear, `A` toggle annotation rail, `I` open Inspect view, `Esc` back.

---

## Data model — Supabase Postgres schemas

Schema: `operator_ui`. Separate from existing customer-facing schema to avoid pollution.

```sql
create schema operator_ui;

create table operator_ui.customers (
  id uuid primary key default gen_random_uuid(),
  slug text unique not null,
  name text not null,
  created_at timestamptz not null default now()
);

create table operator_ui.runs (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references operator_ui.customers(id) on delete cascade,
  slug_with_ts text unique not null,        -- e.g. 'e2e-automateconvert-r6-2026-04-25T15-01-12Z'
  started_at timestamptz not null,
  state jsonb not null,                      -- formerly state.json
  stage_complete int not null default 0,
  refined_from_run_id uuid references operator_ui.runs(id),
  created_at timestamptz not null default now()
);

create table operator_ui.artifacts (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references operator_ui.runs(id) on delete cascade,
  artifact_name text not null,               -- 'brain-doc' | 'system-prompt' | 'discovery-prompt' | 'customer-context' | 'cover-email' | 'meeting-transcript'
  content text not null,
  size_bytes int not null,
  created_at timestamptz not null default now(),
  unique (run_id, artifact_name)
);

create table operator_ui.annotations (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references operator_ui.runs(id) on delete cascade,
  artifact_name text not null,
  quote text not null,
  prefix text not null,
  suffix text not null,
  char_start int not null,
  char_end int not null,
  comment text not null,
  status text not null default 'open',       -- 'open' | 'resolved' | 'orphan' | 'deleted'
  author_name text not null,                 -- from localStorage prompt
  created_at timestamptz not null default now(),
  resolved_by_run_id uuid references operator_ui.runs(id),
  resolved_classification text                -- 'per-run' | 'feedback'
);

create table operator_ui.feedback (
  id text primary key,                       -- 'F-2026-04-26-001'
  customer_id uuid not null references operator_ui.customers(id),
  run_id uuid not null references operator_ui.runs(id),
  source_annotation_id uuid not null references operator_ui.annotations(id),
  artifact_name text not null,
  quote text not null,
  comment text not null,
  status text not null default 'open',       -- 'open' | 'elevated'
  elevated_to_lesson_id text,
  created_at timestamptz not null default now()
);

create table operator_ui.lessons (
  id text primary key,                       -- 'L-001'
  title text not null,
  pattern text not null,
  fix text not null,
  observed_in_customer_ids uuid[] not null,
  source_feedback_ids text[] not null,
  promoted_to_prompt boolean not null default false,
  promoted_at timestamptz,
  promoted_to_file text,                     -- e.g. 'prompts/synthesize-brain-doc.md'
  created_at timestamptz not null default now()
);

create table operator_ui.verifications (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references operator_ui.runs(id) on delete cascade,
  verified_at timestamptz not null,
  summary jsonb not null,                    -- {pass: int, fail: int, skip: int}
  checks jsonb not null,                     -- array of check results
  created_at timestamptz not null default now()
);

-- RLS: keep open within the schema; access gated by Vercel password + service-role key
alter table operator_ui.customers enable row level security;
-- ... (similar for all tables; permissive policy since Vercel password is the gate)

create policy "all_access_for_authenticated" on operator_ui.customers
  for all using (true);
-- ... (repeat for all tables)

-- indexes
create index on operator_ui.runs(customer_id, started_at desc);
create index on operator_ui.artifacts(run_id, artifact_name);
create index on operator_ui.annotations(run_id, status);
create index on operator_ui.feedback(status, created_at);
create index on operator_ui.lessons(promoted_to_prompt, created_at);
```

---

## UI surface

### Customer list (`/`)

Vertical roster of cards. Each card: customer name (display, 32px), slug (muted, mono), run count, latest stage progress, open annotation count, last-verified timestamp + status dot. Click to enter customer page. Search + sort top-right (sort by latest run / name / open annotations). `Ctrl+K` opens command palette.

Empty state: single line `Run /base-agent in Claude Code to onboard your first customer.` No mock data.

### Customer page (`/c/{slug}`)

Reads from latest run by default. Layout:

```
    AutomateConvert
    ──
    Latest run · 25 Apr 2026

    Read

      1.  Brain doc                 3 annotations    →
      2.  System prompt             1 annotation     →
      3.  Discovery prompt          2 annotations    →
      4.  Customer context          —                →
      5.  Cover email               —                →
      6.  Meeting transcript        —                →
      7.  Scraped pages (12)        —                →

    [ Inspect deployment ]    ●  2h ago

    Run history ▾                                  Ctrl+K
```

Number prefix = keyboard shortcut. Click any chapter or press number → reading mode.

`[ Inspect deployment ]` button + colored status dot (green/amber/red/unfilled) + last-verified time. Click → Inspect view. Press `I` to enter.

Run history dropdown expands inline; switching changes URL to `/c/{slug}/run/{run_id}` and reloads everything.

### Reading mode (`/c/{slug}/{artifact-name}` or `/c/{slug}/run/{run_id}/{artifact-name}`)

Single-artifact focus. Header: `← AutomateConvert  ·  Discovery prompt  ·  2 annotations`. Body: serif markdown, max-width 720px centered. Footer: `Next: Customer context →`.

Drag-to-select prose → floating `Comment` chip appears anchored to selection → click → composer slides in from right rail → type → `Ctrl+Enter` saves → highlight materializes immediately on prose, no toast.

Existing annotations render as `▓` overlays at 60% opacity. Hover → tooltip with first 60 chars + author + age. Click → right rail opens to that annotation expanded with edit / resolve / delete actions (plain text links, not buttons). `A` toggles right rail review mode (all annotations on this artifact in document order). `Esc` closes the rail.

Status filter pill at rail bottom (`open · resolved · deleted`) — only visible when at least one non-open annotation exists.

### Inspect view (`/c/{slug}/inspect`)

**v1 stub:** raw verification.json contents rendered as syntax-highlighted JSON, read-only. If absent: `Not yet verified · click to copy /base-agent verify [slug]`. No interactive controls.

**v2 (deferred):** structured checklist with config detail per check, LIVE/TEST tagging, refresh button, optional simulated-call action. Same monastic typography; same right-rail behavior reusable for "more details" overlays.

### Command palette (`Ctrl+K`)

Centered overlay, dims page. Single search field. Result categories in fixed order:
1. Customers (fuzzy match name/slug)
2. Artifacts (jump to chapter within current customer)
3. Actions (`Copy /base-agent refine [slug]`, `Copy /base-agent verify [slug]`, etc.)
4. Annotations (fuzzy on comment text → jump to highlight)

Arrow keys navigate; `Enter` chooses; `Esc` closes.

### Edge cases

- **In-progress run** (stage < 11): chapters whose source artifacts don't exist render as muted/disabled.
- **Failed markdown render:** fall back to plain `<pre>`. Small `(rendering failed)` label.
- **Long artifact** (customer-context up to 62KB): chunk-render via react-markdown; lightweight virtualization for highlight overlay if 100+ annotations.
- **Orphan annotation** (quote no longer matches text): auto-flag, hide from default rail view, surface under `orphaned` filter.
- **Non-markdown artifact** (state, agent-created.json, etc.): syntax-highlighted JSON, no annotation surface.

### Loading & feedback

- First paint never blocks on data. Page shell renders immediately, populates as Supabase responds.
- Loading is *absence*, not animation — a fetching customer card just shows muted slug; full info materializes when data lands. No spinners.
- Saves are awaited (no optimistic updates) — local-only latency is single-digit ms, no UX penalty.
- Failed save: floating retry pill with comment text preserved.

---

## `/base-agent refine [customer-name]` flow

Manually triggered in Claude Code chat after annotations have been made in the UI. Per-customer scope.

**Steps:**

1. Find the customer's most recent run via Supabase query.
2. Read open annotations for that run from `annotations` table.
3. Read `lessons` table for context.
4. **Classify each annotation interactively.** Per the heuristic:
   - Pure factual correction → per-run patch only, no question asked, saved silently
   - Pure behavior critique → feedback candidate, ask Y/n
   - Mixed (fact + behavior) → split: fact half is per-run; behavior half is feedback candidate, ask Y/n on the behavior half only
5. Group classified annotations into per-run patches and feedback signals.
6. **Cascade prompt** (matches Leo's earlier "ask each time" answer): "Per-run patches will modify {brain-doc.md}. Also re-derive system-prompt.md and discovery-prompt.md? [y/N]"
7. Spawn new run row in Supabase with `refined_from_run_id` set. Copy all artifacts forward as baseline.
8. Apply per-run patches via generator prompts with corrections injected.
9. Cascade if Y'd.
10. Append confirmed feedback signals to `feedback` table with provenance.
11. Mark consumed annotations `resolved` with `resolved_by_run_id` + `resolved_classification`.
12. **If `system-prompt` was modified, prompt:** "Push to live Ultravox agent now? [y/N]". On Y → invoke `scripts/regenerate-agent.sh [slug]` (safe full-PATCH).
13. **End-of-refine elevation probing:** read `feedback` rows with status=open, recurrence ≥ 2; for each cluster probe Y/n to elevate.
14. Final summary printed.

---

## `scripts/regenerate-agent.sh [slug]` — safe Ultravox PATCH

Implements what CLAUDE.md should always have said. The OLD rule (`POST-new + DELETE-old`) is replaced by this canonical procedure.

1. Read `runs.state.ultravox_agent_id` from Supabase.
2. **Fetch ALL live settings:** `GET https://api.ultravox.ai/api/agents/{id}`. Capture name, voice, temperature, inactivityMessages, firstSpeaker, model, selectedTools, systemPrompt, every other field. Save to `runs.state.live_agent_pre_update` (jsonb) for audit.
3. Read latest `system-prompt` artifact from Supabase.
4. **Construct PATCH body containing EVERY field from step 2,** with `systemPrompt` swapped to new content.
5. **PATCH** the agent.
6. Verify post-PATCH via diff against pre-PATCH snapshot — fail loud if any non-systemPrompt field changed.
7. Update `runs.state.system_prompt_pushed_at` to ISO timestamp. Agent id unchanged.

Agent id is preserved → no need to re-wire Telnyx telephony. Old `POST-new + DELETE-old` rule deleted from CLAUDE.md.

**CLAUDE.md update:**
> **When updating a live Ultravox agent, always include ALL settings in the PATCH body.** Ultravox PATCH semantics revert any field not explicitly included to the API default — silently wipes voice/temp/inactivity/tools. The safe procedure: GET the agent first, copy every field forward, modify only the field you intend to change, then PATCH with the complete body. The script `scripts/regenerate-agent.sh [slug]` does this safely. Never construct a partial PATCH body — always carry every field forward.

---

## `/base-agent review-feedback` flow

Manually triggered. Cross-customer methodology cleanup. Three-action grammar at both tiers (P/K/D).

**Phase 1 — feedback → lessons:**
1. Read `feedback` rows where status=open.
2. Cluster by similar pattern across customers.
3. For each cluster, present:
   ```
   Pattern: brain-doc invents personas not in the meeting transcript
   Observed: dsa-law (Apr 25), automateconvert (Apr 25), telco-x (Apr 26)
   Source feedback: F-...-003, F-...-001, F-...-014
   Proposed lesson: "Brain-doc must not invent personas"
   [P]romote / [K]eep / [D]elete
   ```
4. **P:** write new `lessons` row with provenance; mark source feedback rows `elevated`.
5. **K:** no change; re-surfaces next review.
6. **D:** physically delete those feedback rows.
7. Singletons (recurrence = 1): listed at end. Walk individually if Y'd.

**Phase 2 — lessons → prompts:**
1. Scan `lessons` where promoted_to_prompt=false.
2. For each mature lesson (recurrence ≥ 3, fix stable, > 14 days since last new occurrence): propose promotion to relevant `prompts/*.md`.
3. **P:** append lesson's fix to relevant generator prompt file (`prompts/synthesize-brain-doc.md`, etc.); set `promoted_to_prompt=true`, `promoted_to_file`, `promoted_at`. Physically delete the lesson row from `lessons` table after promotion.
4. **K:** no change.
5. **D:** physically delete the lesson row (turned out wrong / superseded).
6. Final summary.

---

## Verification module (CLI for v1)

Python module at `ui/server/verify.py` (callable from skill via `python -m server.verify --slug X`). Writes results to Supabase `verifications` table.

**10 deterministic checks + 1 opt-in test call:**

1. Ultravox agent exists and live
2. Voice + temperature match reference settings
3. System prompt non-empty (>500 chars)
4. Tools array matches expectation
5. Telnyx DID active
6. Telnyx call routing wired (voice_url → agent telephony URL)
7. Webhook callback set
8. Supabase customer dashboard workspace exists
9. Supabase customer dashboard auth user exists
10. n8n error workflow active
11. **(opt-in `--include-call`)** Test call to DID — Telnyx programmatic call, brief wait, hang up

Each check writes a row to `verifications.checks` jsonb array with `{id, status: pass|fail|skip, ms, detail, remediation?}`. The `remediation` field on failures gives the exact existing script to re-run.

**Stage 11.5 hook:** appended to `/base-agent` SKILL.md, advisory only (`|| true`). Auto-runs after Stage 11. Failures don't halt the onboarding.

**Manual command:** `/base-agent verify [customer-name]` runs the same module. Useful for re-checks after suspected drift.

---

## Build sequence — 8 phases, 21 milestones

### Phase 1 — Cloud foundation (1 day)
- M1: Supabase schema + RLS + indexes (per Data Model section above)
- M2: Next.js app skeleton + Supabase JS client connected + Vercel project + password protection set

### Phase 2 — Read-only viewer (1-2 days)
- M3: Customer list page reads from Supabase
- M4: Customer page (artifact roster)
- M5: Reading mode (artifact viewer)

### Phase 3 — Annotation flow (2-3 days)
- M6: Drag-to-select + Comment popover + save (POST → Supabase annotations table)
- M7: Right rail review mode + edit/resolve/delete

### Phase 4 — Skill backend rewrite (2-3 days, biggest unknown)
- M8: `scripts/state.sh` rewritten — Supabase REST calls instead of local file writes (behind feature flag `USE_SUPABASE_BACKEND=1`)
- M9: All artifact-writing stages (3, 4, 7, 8, 9, 10) write to Supabase tables
- M10: `state_resume_from` queries Supabase

### Phase 5 — Protocol-improvement loop (2-3 days)
- M11: Generator prompts read `lessons` table at run start (Python helper that queries Supabase)
- M12: `/base-agent refine [customer]` — full 13-step flow
- M13: `scripts/regenerate-agent.sh` — safe full-PATCH
- M14: `/base-agent review-feedback` — methodology review

### Phase 6 — Verification (1 day)
- M15: `verify.py` module + 10 deterministic checks
- M16: `/base-agent verify [customer]` + Stage 11.5 hook
- M17: Optional `--include-call` flag

### Phase 7 — UI polish (1-2 days)
- M18: Run history switcher
- M19: Command palette (Ctrl+K)
- M20: Inspect view stub

### Phase 8 — Docs + handoff (0.5 day)
- M21: README + INSTALL.md + CLAUDE.md updates (safe-PATCH rule canonical, new commands documented)

**Total: ~10-15 days of focused work.**

---

## Tests per milestone (TDD discipline)

Behavior-driven, integration-style, public-interface only. **One tracer per milestone, written at the start of that milestone — not all upfront.**

**Highest-business-value test:** **M13 (regenerate-agent safe-PATCH)** — verifies the captured PATCH body to Ultravox contains every field from the prior GET response with only `systemPrompt` modified. No POST. No DELETE. (pytest with `respx`.)

**Other key tests:**
- M1: schema round-trip (insert + read every table)
- M3-M5: Playwright — customer list, customer page, reading mode all render with seed data
- M6-M7: Playwright — annotation save persists across page refresh; status changes persist
- M8-M9: pytest — state_set/get round-trip via Supabase
- M11: integration — known lesson reflected in generated brain-doc (manual verify due to AI non-determinism)
- M12: pytest with fixture data — refine produces correct outputs (per-run patch in new run row, feedback row appended, source annotations marked resolved)
- M14: pytest with fixtures — review-feedback P/K/D actions modify Supabase as specified
- M15: pytest with respx — verify writes complete report
- M16: integration — Stage 11.5 hook is non-blocking on failure
- M19: Playwright — Ctrl+K search + navigate
- M21: manual — friend can read INSTALL and run /base-agent within 10 minutes

---

## Critical files

**New:**
- `ui/web/` — Next.js app (App Router)
  - `app/page.tsx` — customer list
  - `app/c/[slug]/page.tsx` — customer page
  - `app/c/[slug]/[artifact]/page.tsx` — reading mode
  - `app/c/[slug]/inspect/page.tsx` — Inspect stub
  - `app/api/annotations/route.ts` — POST/PATCH/DELETE annotations
  - `lib/supabase.ts` — server + client Supabase clients
  - `lib/highlight.ts` — Hypothesis-style anchor logic
  - `components/ArtifactViewer.tsx`
  - `components/AnnotationPanel.tsx`
  - `components/CommandPalette.tsx`
- `ui/server/verify.py` — verification module
- `scripts/regenerate-agent.sh` — safe Ultravox PATCH
- `migrations/operator_ui_schema.sql` — Supabase schema migration

**Modified:**
- `base-agent-setup/SKILL.md` — Stage 11.5 hook, new sub-commands documented
- `base-agent-setup/scripts/state.sh` — Supabase backend (feature-flagged)
- `base-agent-setup/scripts/firecrawl-scrape.sh` — write artifacts to Supabase, not files
- `base-agent-setup/scripts/ultravox-create-agent.sh` — record agent_id in Supabase state
- `base-agent-setup/scripts/telnyx-claim-did.sh` — record DID in Supabase state
- `base-agent-setup/scripts/telnyx-wire-texml.sh` — record TeXML config in Supabase state
- `base-agent-setup/scripts/wire-ultravox-telephony.sh` — record telephony state
- `base-agent-setup/prompts/synthesize-brain-doc.md` — preamble: read lessons table
- `base-agent-setup/prompts/assemble-rough-system-prompt.md` — preamble: read lessons table
- `base-agent-setup/prompts/generate-discovery-prompt.md` — preamble: read lessons table
- `CLAUDE.md` — replace POST-new + DELETE-old rule with full-PATCH-with-all-fields rule
- `README.md` — cloud model setup + Vercel URL + INSTALL link
- `INSTALL.md` — Path A (shared backend) updated to point at Supabase project + Vercel URL + password share via private channel

**Deleted (after Phase 4 cutover):**
- `runs/` directory convention (old local-file source of truth) — retained only as gitignored output dir for transient debugging if needed

---

## Risks + open questions

**Risks:**
1. **Skill rewrite breaks existing flow** (Phase 4) — mitigation: feature flag `USE_SUPABASE_BACKEND=1`, file path keeps working until cloud path verified end-to-end.
2. **Annotation anchors break when artifacts are refined** — mitigation: three-strategy anchoring (quote → quote+prefix-suffix → char offsets); orphans auto-flagged, never silently lost.
3. **Ultravox PATCH wipes a field added to API after we wrote regenerate-agent.sh** — mitigation: post-PATCH diff against pre-PATCH snapshot; fail loud on unintended drift.
4. **Vercel cold starts** — likely unnoticed at v1 traffic; move to Pro tier if it bites.
5. **Supabase free tier limits** — current data shape uses <1% of free tier.
6. **Lessons file pollution from over-eager elevation** — mitigation: Phase-2 of review-feedback prunes by promoting mature lessons into prompts; token-count alert at 3k tokens.
7. **Local skill loses access when Supabase down** — out of v1 scope; deferred to v2 cache layer if it bites.
8. **Shared password leak risk** — acceptable for v1 (no PII/PCI/PHI); switch to Supabase Auth if stricter needed (~half-day migration).

**Open questions (resolve during implementation, not now):**
- Annotation history across multiple refines (punt: pinned to run, audit via `resolved_by_run_id`)
- Operator-attribution localStorage fragility (punt: localStorage v1, harden later)
- Refine partial-failure recovery (punt: wrap in single Postgres transaction where possible)
- Human readability of feedback/lessons as Postgres rows vs markdown files (punt: UI markdown view + CLI dump-to-temp-file for `Read` access)
- Concurrent operator races during refine (punt: refine reads annotations once at start; mid-refine adds queue for next refine)
- Friend's local skill writes to same Supabase project (mitigation: unique slug constraint; `author_name` disambiguates)

**Explicit non-goals:**
- Customer-facing dashboards (separate Supabase schema, exists)
- AI inference quality (this UI is the curation tool, not itself a quality improver)
- Full live verification UI panel (v2)
- Mobile / tablet UI (desktop-only by design)
- Realtime collaboration on same artifact (sync via reload only)

---

## Verification — end-to-end test of the build

After all 21 milestones complete:

1. Open Vercel URL → password gate → enter `Walkergewert0!` → land on customer list (empty if first install).
2. In Claude Code locally, run `/base-agent` against a real customer site + meeting transcript. Watch artifacts appear in Supabase tables (run + state + 5+ artifacts).
3. Refresh Vercel UI → customer card appears with "stage 11/11 ✓".
4. Click customer → see 7 chapters → click "Brain doc" → reads as serif markdown.
5. Drag-select prose, type comment, `Ctrl+Enter` → highlight materializes, refresh → still there.
6. Press `A` → annotation rail opens with the saved comment. Click resolve → status flips, refresh → persists.
7. Press `I` → Inspect view shows raw verification.json (or "Not yet verified" message).
8. Back to Claude Code: `/base-agent refine [customer]` → interactive classification prompts appear → confirm Y → new run row created → end-of-refine elevation probe runs.
9. Check Supabase: feedback row appended, original annotation marked resolved with new run id.
10. `/base-agent review-feedback` → cluster (or singleton) presented → P → lessons row created.
11. Friend opens Vercel URL on their machine → password works → sees same customer + same annotations.
12. Friend in their own Claude Code: `/base-agent` against another customer → both customers visible to both operators.

If steps 1-12 work, v1 is shipped.

---

## Post-approval next steps

1. User calls `ExitPlanMode` to approve this plan.
2. Optionally: copy this design doc to `c:/Users/leoge/Code/spotfunnel-voice-skills/docs/plans/2026-04-26-operator-ui-design.md` and commit (the brainstorming skill's standard terminal step — paused by plan mode).
3. Invoke `writing-plans` skill to convert this design into a detailed implementation plan, milestone by milestone with TDD tracer-bullet structure.
4. Begin Phase 1 — Supabase schema migration + Next.js skeleton.
