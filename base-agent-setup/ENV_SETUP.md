# Env setup — base-agent-setup

This skill loads its config from a single `.env` file at the repo root. Every required variable is documented in [`<repo-root>/.env.example`](../.env.example) — copy that file to `.env` and fill in your values.

## How env loading works

The skill resolves the env file location in this order:

1. **`$SPOTFUNNEL_SKILLS_ENV`** if set — explicit override (useful when running from outside the repo).
2. **`<repo-root>/.env`** — the default; works when you run skills from a clone of this repo.
3. **`~/.config/spotfunnel-skills/env-path`** — a cached path written the first time you tell the skill where your env file lives (for operators who keep `.env` outside the repo for any reason).

If none of those resolve to a readable file, Stage 0 halts with a clear message.

## Required variables

The full list with descriptions lives in `.env.example`. Summary:

**Vendor APIs:**
- `ULTRAVOX_API_KEY`
- `TELNYX_API_KEY`
- `FIRECRAWL_API_KEY`
- `RESEND_API_KEY`
- `RESEND_FROM_EMAIL`

**Operator's backend:**
- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`
- `DASHBOARD_SERVER_URL`

**Reference assets in your accounts:**
- `REFERENCE_ULTRAVOX_AGENT_ID` — the Ultravox agent whose voice/temperature/inactivity settings get copied onto every new customer

> Telnyx pool TeXML apps are auto-discovered at claim time via tags (`pool-available` / `claimed-<slug>`) — no env var to set. Run `base-agent-setup/scripts/bulk-create-texml-apps.sh` once at install to create them.

**n8n (consumed by the chained `/onboard-customer` skill):**
- `N8N_BASE_URL`
- `N8N_API_KEY`
- `N8N_ERROR_REPORTER_WORKFLOW_ID`

**Alerting:**
- `OPS_ALERT_EMAIL`

## What if a variable is missing?

Stage 0 (`scripts/env-check.sh`) prints `[OK] X loaded` for every present variable and `[MISSING] X` for every empty one, then halts the run if any are missing. Fill in the missing values in `.env` and re-invoke.

## Why one .env at the repo root, not per-skill?

Both `base-agent-setup` and `onboard-customer` share the same backend (Ultravox, Supabase, Telnyx, Resend, n8n), so duplicating env vars per skill would just create drift. One file = one source of truth.
