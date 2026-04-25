# Env keys this skill needs

## Where secrets live

The skill loads secrets from a single `.env` file at runtime (Stage 0). One file, sourced as shell env, keeps every secret in one place — no split across "user env vars" vs. "project files".

### Env-file resolution (portable across machines)

Stage 0 finds the `.env` file in this order — first hit wins:

1. **`$SPOTFUNNEL_SKILLS_ENV`** — if set, that path is used verbatim.
2. **`<repo-root>/.env`** — the file at the root of the cloned `spotfunnel-voice-skills` repo. This is the recommended default: clone the repo, copy `.env.example` to `.env`, fill it in, done.
3. **Cached path at `~/.config/spotfunnel-skills/env-path`** — if the operator has previously been prompted for a path on this machine, the skill cached it here and re-uses it.
4. **Prompt the operator** — if none of the above resolves, the skill asks once for the absolute path to the env file, then writes that path to `~/.config/spotfunnel-skills/env-path` so future runs don't re-ask.

The exact bash snippet Stage 0 runs is documented in SKILL.md → Stage 0.

If any required var is empty after sourcing, the skill halts with a specific "missing X — see `.env.example` for what to put here" message.

---

## Required env vars

All of these must be present in the resolved `.env` file. The repo-root `.env.example` documents each one with a comment explaining where to fetch the value.

### Application keys

| Var | Where to get it |
|---|---|
| `SUPABASE_URL` | Your Supabase project URL — `https://<project-ref>.supabase.co`. Settings → API. |
| `SUPABASE_SERVICE_ROLE_KEY` | Supabase dashboard → Settings → API → **`service_role`** key (the locked one, NOT anon/public). Long JWT starting `eyJhbGciOi…`. |
| `ULTRAVOX_API_KEY` | Ultravox → Settings → API Keys. Starts with `uv_`. |
| `DASHBOARD_SERVER_URL` | Public base URL of your `dashboard-server` deployment (e.g. `https://dashboard-server-production-XXXX.up.railway.app`). The skill uses this for the `call.ended` and `n8n-error` webhook URLs. |
| `OPS_ALERT_EMAIL` | Email address that receives ops alerts (low DID pool, onboarding failures, etc.). |

### n8n keys (Stage 7b — error-reporter wiring)

| Var | Where to get it |
|---|---|
| `N8N_BASE_URL` | Your n8n instance URL — e.g. `https://<your-tenant>.app.n8n.cloud` (or self-hosted equivalent). |
| `N8N_API_KEY` | n8n → Settings → API. Personal API key. Long string, no common prefix. |
| `N8N_ERROR_REPORTER_WORKFLOW_ID` | The ID of the central "Global Error Reporter" workflow on your n8n instance. Created once when the error-reporting pipeline is first set up (see `docs/runbooks/n8n-error-wiring.md`). Fetch by opening the workflow in n8n and copying the ID from the URL (`.../workflow/<ID>`). |

The `N8N_ERROR_REPORTER_WORKFLOW_ID` workflow forwards errors from every customer's n8n workflows to the dashboard's `workflow_errors` table via `$DASHBOARD_SERVER_URL/webhooks/n8n-error`. Without it, Stage 7b halts. The skill PATCHes every new customer's n8n workflows to set `settings.errorWorkflow` to this ID, so failures surface in `/admin/health`.

---

## Setting them

1. From the cloned repo root, copy the example file:
   ```bash
   cp .env.example .env
   ```
2. Open `.env` and paste each value, following the inline comments.
3. (Optional) If you want the env file somewhere other than the repo root, set `SPOTFUNNEL_SKILLS_ENV` in your shell profile to point at that path:
   ```bash
   export SPOTFUNNEL_SKILLS_ENV="/absolute/path/to/your/.env"
   ```

---

## Apply + verify

1. Open a fresh shell (or restart Claude Code) so the new env-resolver lookup runs cleanly.
2. In a Claude Code session, sanity-check (shows first 20 chars only so the full secret never lands in transcript context):
   ```bash
   echo "SUPABASE_URL=$SUPABASE_URL"
   echo "SUPABASE_SERVICE_ROLE_KEY=${SUPABASE_SERVICE_ROLE_KEY:0:20}..."
   echo "ULTRAVOX_API_KEY=${ULTRAVOX_API_KEY:0:20}..."
   echo "DASHBOARD_SERVER_URL=$DASHBOARD_SERVER_URL"
   echo "N8N_BASE_URL=$N8N_BASE_URL"
   echo "N8N_API_KEY=${N8N_API_KEY:0:20}..."
   echo "N8N_ERROR_REPORTER_WORKFLOW_ID=$N8N_ERROR_REPORTER_WORKFLOW_ID"
   ```
   All should print non-empty values once Stage 0 has sourced the file (or after you `source` it manually for the check).

---

## Rotate a key later

Edit the `.env` file with the new value. Restart Claude Code (or re-source the file) so the new value is picked up.

## Why one .env file (not Windows user env / shell profile)

- **Portable.** Same skill works identically on Mac, Linux, Windows — no per-OS storage path.
- **Discoverable.** New operators see one `.env.example` at the repo root and know exactly what they need.
- **Auditable.** One file to grep for "is this secret set anywhere I forgot about?"
- **Safe to commit-protect.** `.env` is in `.gitignore` at repo root; `.env.example` (with placeholders only) is committed.

`~/.claude/settings.json` is config (permissions, enabled plugins, etc.), not credentials. Keep them separate.

---

## Troubleshooting

- **Skill halts at Stage 0 with "missing X":** open `.env`, paste a value for that var (example file shows where to get it), restart the skill.
- **Skill prompts for env-file path on every run:** the cached path at `~/.config/spotfunnel-skills/env-path` is missing or wrong. Set `SPOTFUNNEL_SKILLS_ENV` in your shell profile to make it permanent, or place the file at `<repo-root>/.env` so it's auto-found.
- **`$DASHBOARD_SERVER_URL` is unset but other vars work:** you copied an older `.env.example` predating the multi-machine refactor. Add `DASHBOARD_SERVER_URL=https://...` manually and re-source.
