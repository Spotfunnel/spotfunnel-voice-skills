# Install — Path A (shared backend)

Goal: clone, set `.env`, run `/base-agent` in under 10 minutes.

This is the cloud-shared install. You piggyback on Leo's Supabase project +
Vercel deployment; you bring your own Ultravox / Telnyx / Firecrawl keys.
Path B (your own backend) is out of scope for v1 — see the bottom of this doc.

## What you'll set up

- Local clone of this repo.
- Claude Code installed and connected to your account (any Max plan or higher).
- Python 3.11+ on `PATH` (for the verify module + the `ui/server` test deps).
- Git Bash on Windows or any POSIX shell on macOS/Linux. The skill scripts
  assume Unix-style paths and tools (`curl`, `python3`, `bash`).
- `.env` at the repo root with values from Leo (Supabase) + values from your
  own vendor accounts (Ultravox, Telnyx, Firecrawl, Resend).

## Step by step

### 1. Clone

```bash
git clone https://github.com/Spotfunnel/spotfunnel-voice-skills.git
cd spotfunnel-voice-skills
```

### 2. Create `.env`

```bash
cp .env.example .env
```

Fill it in. Group by source:

**Leo sends you these privately** (Signal, iMessage, encrypted email — never
public channels). Same Supabase project hosts both the customer-facing
dashboard schema and the `operator_ui` schema:

- `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY` — customer-facing dashboard.
- `SUPABASE_OPERATOR_URL` + `SUPABASE_OPERATOR_SERVICE_ROLE_KEY` — operator-UI
  schema. Usually the same project as `SUPABASE_URL`.
- `DASHBOARD_SERVER_URL` — the deployed dashboard-server that handles
  call.ended webhooks.
- `N8N_BASE_URL` + `N8N_API_KEY` + `N8N_ERROR_REPORTER_WORKFLOW_ID` — Leo's
  n8n tenant + the central error-reporter workflow ID.
- `REFERENCE_ULTRAVOX_AGENT_ID` — Leo's reference agent in his Ultravox
  account whose voice/temp/inactivity get copied onto each new customer.
  (You can override with your own once you have a reference agent set up.)
- `RESEND_API_KEY` + `RESEND_FROM_EMAIL` + `OPS_ALERT_EMAIL` — pool-low
  alerts. Either piggyback on Leo's Resend or bring your own; both work.

**You sign up for these yourself** (each has a free tier sufficient for dev):

- `ULTRAVOX_API_KEY` — <https://app.ultravox.ai/> → Settings → API Keys.
- `TELNYX_API_KEY` — <https://portal.telnyx.com/> → API Keys. Note: you also
  need DIDs purchased + bound to TeXML apps in Leo's Telnyx account before
  you can claim them. Ask Leo.
- `FIRECRAWL_API_KEY` — <https://www.firecrawl.dev/> → API Keys.

**Always 1 for the cloud path:**

- `USE_SUPABASE_BACKEND=1` — opts the skill into shared cloud state. Without
  this flag the skill writes to local `runs/` files and the operator UI
  won't see your runs.

`.env` syntax: no quotes around values, no spaces around `=`, no trailing
whitespace, comments on their own line.

### 3. Install Python deps

The verify module + the integration test suite live under `ui/server/`. Set
up its venv:

```bash
cd ui/server
python -m venv .venv
. .venv/Scripts/activate    # Windows; use .venv/bin/activate on POSIX
pip install -e ".[dev]"
cd ../..
```

### 4. Verify the install

```bash
bash base-agent-setup/scripts/env-check.sh
```

Should print every required var as `[OK] <NAME> loaded`. If any line says
`[MISSING]`, fix `.env` and re-run.

### 5. Junction the skills into `~/.claude/skills/`

Claude Code discovers skills by scanning `~/.claude/skills/` at session
startup. Link the three skill folders so future `git pull`s take effect
without re-copying.

**Windows (Git Bash → cmd junctions):**

```bash
mkdir -p "$USERPROFILE/.claude/skills"
cmd <<'EOF'
mklink /J "C:\Users\USERNAME\.claude\skills\base-agent-setup" "C:\Users\USERNAME\Code\spotfunnel-voice-skills\base-agent-setup"
mklink /J "C:\Users\USERNAME\.claude\skills\onboard-customer" "C:\Users\USERNAME\Code\spotfunnel-voice-skills\onboard-customer"
mklink /J "C:\Users\USERNAME\.claude\skills\voice-stress-test" "C:\Users\USERNAME\Code\spotfunnel-voice-skills\voice-stress-test"
EOF
```

Replace `USERNAME` and the absolute path. All three should print
`Junction created for ...`.

**macOS / Linux:**

```bash
mkdir -p ~/.claude/skills
ln -s "$(pwd)/base-agent-setup" ~/.claude/skills/base-agent-setup
ln -s "$(pwd)/onboard-customer" ~/.claude/skills/onboard-customer
ln -s "$(pwd)/voice-stress-test" ~/.claude/skills/voice-stress-test
```

Verify all three resolve:

```bash
ls ~/.claude/skills/base-agent-setup/SKILL.md
ls ~/.claude/skills/onboard-customer/SKILL.md
ls ~/.claude/skills/voice-stress-test/SKILL.md
```

### 6. Browse the operator UI

<https://zero-onboarding.vercel.app>. Password: ask Leo.

On first visit you'll be prompted for an operator name (stored in
`localStorage`). Annotations you write get tagged with that name.

### 7. Run `/base-agent`

Open a fresh Claude Code session (skill discovery happens at startup, so
restart Claude Code if it was open before junctioning). From any directory:

```
/base-agent
```

Stage 0 runs immediately and re-validates env. Walk through the prompts.

That's it. Runs land in shared Supabase; your customer cards appear in the UI
alongside everyone else's.

## Cleaning up

- Runs + artifacts persist in shared Supabase forever after a successful
  `/base-agent`. Don't delete other operators' rows.
- Annotations are tagged with the operator name from `localStorage` (set on
  first UI visit). Clear `localStorage` to switch identities.
- Test runs against `example.com` are safe but visible — name them clearly
  (`Test Customer Inc`) and use `/onboard-customer undo <slug>` to clean up
  if needed.

## Path B (own backend)

Out of scope for v1. If you need it: provision a separate Supabase project,
apply `migrations/operator_ui_schema.sql`, create the customer-facing schema
(see `schema/`), deploy `ui/web/` to your own Vercel account with the
appropriate env vars (`NEXT_PUBLIC_SUPABASE_URL`,
`NEXT_PUBLIC_SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`), and stand up
your own n8n + dashboard-server. Walk yourself through using the design doc
at [`docs/plans/2026-04-26-operator-ui-design.md`](docs/plans/2026-04-26-operator-ui-design.md).

## Troubleshooting

**Stage 0 reports `[MISSING] X`** — check `.env` for that var: blank value,
quotes around the value, trailing whitespace, or spaces around `=`. The
script halts on the first missing var.

**Skill doesn't autocomplete in Claude Code** — junction was created during
a running session. Close + reopen Claude Code; skill discovery only runs at
session startup.

**`Cannot locate the spotfunnel-voice-skills .env file`** — resolver couldn't
find `.env`. Either place it at the repo root, or export
`SPOTFUNNEL_SKILLS_ENV=/abs/path/to/.env` in your shell profile.

**Ultravox 401 on Stage 6** — `ULTRAVOX_API_KEY` is wrong, revoked, or the
account is past trial limits. Re-verify in the Ultravox console.

**Telnyx claim returns no DIDs** — pool is empty or `bulk-create-texml-apps.sh`
was never run on Leo's Telnyx account. Tell Leo; pool refill is manual on his
side (the skill never auto-buys).

**Calls don't land in dashboard** — the `call.ended` webhook URL must be set
manually on each Ultravox agent (Stage 7 of `/onboard-customer` reminds you).
Ultravox PATCH would wipe other config, so the skill won't do it for you.
Open the agent in the Ultravox console → Integrations → Webhooks → set
`call.ended` to `$DASHBOARD_SERVER_URL/webhooks/call-ended`.
