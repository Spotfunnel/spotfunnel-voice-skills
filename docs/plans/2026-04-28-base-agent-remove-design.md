# `/base-agent remove [slug]` — design

**Date:** 2026-04-28
**Skill modified:** `base-agent-setup`
**Repo:** `Spotfunnel/spotfunnel-voice-skills`

## Problem

Onboarding a customer via `/base-agent` mutates state across five external systems (Supabase `operator_ui`, Supabase `dashboard`, Telnyx, Ultravox, local filesystem). Today there is no clean teardown path. Mistaken/abandoned/test runs leave residue: Telnyx DIDs stuck in `claimed-{slug}` state, Ultravox agents polluting the console, customer rows in `operator_ui` showing in the Zero UI as if active. Fixing this manually is error-prone and time-consuming.

## Goal

`/base-agent remove [slug]` leaves zero traces that the agent ever existed, across every system the creation flow touches. Idempotent, halts safely on ingress-side failures, surfaces drift between expected state and reality.

## Architecture — saga / audit-log pattern

The creation flow writes a thorough audit log of every external mutation it makes, into a hidden Supabase table. The removal flow reads that log and applies the inverse of each entry in reverse order. Live-query verification runs alongside as a drift safety-net.

This replaces a pure live-discovery design because:

- Creation knows precisely what was created with what args; removal shouldn't have to guess via slug-pattern matching.
- Surgical edits (e.g. removing one element from a shared `lessons.observed_in_customer_ids[]` array) need exactly the inverse args at teardown — encoded once at write-time, replayed at remove-time.
- Live-query alone misses anything stored under a non-slug-derived key; log capture is exact.

## New table — `operator_ui.deployment_log`

Hidden from the Zero UI (no page renders it). Append-only. Survives customer/run row deletion (no FK cascade) so the audit trail outlives the deployment.

```sql
CREATE TABLE operator_ui.deployment_log (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_slug   TEXT NOT NULL,
  run_id_text     TEXT,
  stage           INT NOT NULL,
  system          TEXT NOT NULL,        -- 'ultravox' | 'telnyx' | 'supabase_operator_ui' | 'supabase_dashboard' | 'local_fs' | 'n8n'
  action          TEXT NOT NULL,        -- 'created' | 'tagged' | 'wired' | 'wrote' | 'edited_array'
  target_kind     TEXT NOT NULL,        -- 'agent' | 'did' | 'workspace' | 'auth_user' | 'public_user' | 'row' | 'file' | 'workflow'
  target_id       TEXT NOT NULL,
  payload         JSONB,
  inverse_op      TEXT NOT NULL,        -- 'delete' | 'untag_repool' | 'remove_from_array' | 'rm' | 'unset'
  inverse_payload JSONB,
  status          TEXT NOT NULL DEFAULT 'active',  -- 'active' | 'reversed' | 'reverse_failed' | 'reverse_skipped'
  reversed_at     TIMESTAMPTZ,
  reverse_error   TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX deployment_log_slug_status_idx
  ON operator_ui.deployment_log (customer_slug, status, created_at DESC);
```

Audit retention: rows are kept after teardown (status flips `active` → `reversed`). Operator can query forever via Supabase Studio. Confirmed with operator on 2026-04-28.

## Creation-side change

New helper `scripts/log_deployment.sh` (bash) + Python sibling for inline stages. Wraps every external mutation. Pattern:

```bash
log_deployment \
  --slug "$SLUG" \
  --run-id "$RUN_ID" \
  --stage 7 \
  --system telnyx \
  --action tagged \
  --target-kind did \
  --target-id "$NUMBER_ID" \
  --payload '{"phone_number":"...","voice_url":"..."}' \
  --inverse-op untag_repool \
  --inverse-payload '{"number_id":"...","old_tag":"claimed-...","new_tag":"pool-available"}'
```

Stage-by-stage instrumentation (this iteration):

| Stage | Mutation | Log entry |
|---|---|---|
| 1 | `state_init` writes `operator_ui.customers + runs` | 2 entries, inverse `delete` |
| 1 | `state_set_artifact meeting-transcript` | 1 entry, inverse `delete` |
| 2 | scrape → `artifacts.scraped-pages` | 1 entry, inverse `delete` |
| 3 | brain-doc → `artifacts.brain-doc` | 1 entry |
| 4 | system-prompt → `artifacts.system-prompt` | 1 entry |
| 5 | reference-settings.json (local file) | 1 entry, inverse `rm` |
| 6 | Ultravox agent POST | 1 entry, inverse `delete` |
| 7 | Telnyx DID claim (re-tag) | 1 entry, inverse `untag_repool` (old/new tag in payload) |

Stages 8–10 (TeXML config, telephony_xml repoint, discovery-prompt + cover-email) deferred to iteration 2 — caught by drift/live-discovery in this iteration.

`/onboard-customer` Stage 11 dashboard writes deferred to iteration 2 — caught by drift.

## Removal flow — `/base-agent remove [slug]`

### Phase 1 — Read log + live-query verification

1. `SELECT * FROM operator_ui.deployment_log WHERE customer_slug=$SLUG AND status='active' ORDER BY created_at DESC` → drives the inverse plan, newest first.
2. Live-query each external system the same way an audit script would:
   - `operator_ui.customers/runs/artifacts/annotations/feedback/verifications` for this slug
   - `operator_ui.lessons` rows where this customer is in `observed_in_customer_ids[]`
   - `dashboard.workspaces` for this slug → traverse to `public.users` → `auth.users` → `calls` → `workflow_errors`
   - Telnyx numbers tagged `claimed-{slug}`
   - Ultravox agents matching `{Customer*}` name pattern
   - Local `runs/{slug}-*` directories
3. Compare:
   - In log + reality → tear down via log replay.
   - In log NOT in reality → already gone, mark `status=reverse_skipped` automatically.
   - In reality NOT in log (drift in the other direction) → surface warning, will be deleted via live-discovery teardown anyway.
4. Print unified inventory + drift warnings + `Delete all of the above? (y/N)` prompt.

### Phase 2 — Confirmation

Single `(y/N)`. Anything other than `y` (case-insensitive) aborts. `--dry-run` exits 0 here. Choice locked: speed over fat-finger protection at single-operator scale.

### Phase 3 — Replay inverses + handle drift

For each log row + each drift item, dispatch on `(system, inverse_op)`. Halt-rules:

| Step | On error |
|---|---|
| Telnyx (untag_repool, unset voice_url) | **HALT** |
| Ultravox (delete agent) | **HALT** |
| Dashboard auth.users / public.users / calls / workflow_errors / workspaces | best-effort + log |
| operator_ui.lessons surgical edit (`array_remove`) | best-effort + log |
| operator_ui rows (verifications/feedback/annotations/artifacts/runs/customers) | best-effort + log |
| Local FS rm -rf | best-effort + log |

Order is reverse of creation: ingress dies first (Telnyx + Ultravox), then dashboard, then operator_ui, then local files. Per log row, flip `status` to `reversed` / `reverse_failed` + populate `reverse_error`.

### Phase 4 — Verification

Re-run Phase 1 live-discovery. Every count must be 0; every list empty. Print `✓ Verified: zero traces remaining for "{slug}"` or `✗ Residue:` block. Exit non-zero on residue.

### Phase 5 — Audit retention

Deployment_log rows are NOT deleted. They become a permanent audit trail of "this slug was deployed on X, torn down on Y."

## Out of scope (explicit)

- **Per-customer Railway services** — operator manually tears down at railway.app (one-line note in skill output).
- **Shared central-n8n workflows with inert errorWorkflow pointers** — those references become dead-ends once the customer's server goes down. Surgical edit not worth the complexity.
- **Promoted-to-prompt lessons** — kept regardless because the prompt file change is git-tracked methodology evolution, not customer-identifying data.
- **Iteration 2 scope:** stages 8–10 logging + `/onboard-customer` dashboard logging. Until shipped, drift detection covers those.

## Testing

End-to-end on the existing `goulburn-transport` run as the first test. Goulburn has no log entries (predates the migration) so it exercises the **drift / live-discovery teardown path** — the safety net. Validates that the live-query path works on a clean small case (only `operator_ui` + local FS). Then a fresh `e2e-remove-test` slug taken through stages 1–7 to test the **log-driven path** end-to-end.

## Files

**New:**
- `migrations/operator_ui_deployment_log.sql`
- `base-agent-setup/scripts/log_deployment.sh`
- `base-agent-setup/scripts/_log_deployment.py` (used by inline stages 3/4)
- `base-agent-setup/scripts/remove-customer.sh`
- `base-agent-setup/scripts/_remove_customer.py`
- `docs/plans/2026-04-28-base-agent-remove-design.md` (this doc)

**Modified:**
- `base-agent-setup/SKILL.md` (new `## Removal — /base-agent remove [slug]` section after the 11 stages)
- `base-agent-setup/scripts/state.sh` (log writes in `state_init`, `state_set_artifact`)
- `base-agent-setup/scripts/firecrawl-scrape.sh` (Stage 2 logging — actually handled by `state_set_artifact` from the orchestrator)
- `base-agent-setup/scripts/ultravox-get-reference.sh` (Stage 5 local file logging)
- `base-agent-setup/scripts/ultravox-create-agent.sh` (Stage 6 agent logging)
- `base-agent-setup/scripts/telnyx-claim-did.sh` (Stage 7 tag rotation logging)
