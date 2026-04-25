# INSTALL.md — first-time setup for spotfunnel-voice-skills

Two install paths live in this doc. Pick yours from the section right below, then follow the numbered sections in order.

---

## Which path is this?

- **Path A — Joining an existing Spotfunnel-style operation (most readers).** A collaborator is sharing their business backend with you. They'll send you a complete `.env` privately — covering Telnyx, Ultravox, Supabase, n8n, Resend, Firecrawl. You do **not** create any vendor accounts, do **not** buy DIDs, do **not** run schema migrations, and do **not** run `bulk-create-texml-apps.sh`. Your collaborator already did all of that. Follow §1, §2, **§3**, then §5 → §6 → §7. Total time: ~5 minutes once your collaborator has the `.env` ready.

- **Path B — Setting up your own copy from scratch.** You're forking the project and standing up your own Telnyx, Ultravox, Supabase, Firecrawl, Resend, and n8n. Follow §1, §2, then **§4** in full, then §5 → §6 → §7. Total time: 60–90 minutes of clicking around vendor consoles, plus whatever it takes to deploy your dashboard-server (out of scope here).

---

## Table of contents

1. [Prerequisites](#1-prerequisites)
2. [Clone the repo](#2-clone-the-repo)
3. [Quick install (shared backend) — Path A](#3-quick-install-shared-backend--path-a)
4. [Provision your own backend — Path B](#4-provision-your-own-backend--path-b)
   - [4.1 Ultravox](#41-ultravox)
   - [4.2 Telnyx](#42-telnyx)
   - [4.3 Firecrawl](#43-firecrawl)
   - [4.4 Resend](#44-resend)
   - [4.5 Supabase](#45-supabase)
   - [4.6 n8n](#46-n8n)
   - [4.7 Optional: deploy dashboard-server](#47-optional-deploy-dashboard-server)
5. [Verify env preflight (both paths)](#5-verify-env-preflight-both-paths)
6. [Test run (both paths)](#6-test-run-both-paths)
7. [Troubleshooting (both paths)](#7-troubleshooting-both-paths)

---

## 1. Prerequisites

Applies to both paths.

You need:

- **Claude Code** installed locally. Install instructions: <https://docs.anthropic.com/en/docs/claude-code>. The skills run inside a Claude Code session — there is no standalone CLI.
- **A Claude Max subscription** (or higher). The skills use Claude Opus 4.7 inline as their LLM brain for brain-doc synthesis, prompt authoring, and discovery-prompt generation. **All AI inference uses your Claude Code subscription's quota — there is no separate Anthropic API key required for the onboarding skills themselves.**
- **Git Bash on Windows**, or any POSIX shell on macOS/Linux. The skills' bash blocks assume Unix-style paths and tools (`curl`, `python3`, `grep`, `git`). Native Windows `cmd.exe` and PowerShell are **not** supported as the skill shell — but you'll still use `cmd` once for directory junctions in §3 (Path A) or §5 (Path B).
- **Python 3** on `PATH`. Used by the skills for safe JSON construction (`python3 -c "import json; ..."`). Verify with `python3 --version`.
- **Node.js** on `PATH`, only if you intend to run `/stress-test`. The stress-test skill orchestrates a Node-based diagnosis harness (simulated callers, graders, report generation). Not needed for `/base-agent` or `/onboard-customer`. Verify with `node --version` (any 18+ works).
- **An Anthropic API key**, only if you intend to run `/stress-test`. The simulated-caller side of the harness uses Claude Haiku via the API (~$0.01/call) — separate from the Claude Code subscription used by the onboarding skills. Set as `ANTHROPIC_API_KEY` in your `.env`. Skip if you're not using `/stress-test`.

**Vendor accounts** are only needed on Path B. On Path A your collaborator already owns all of them — you'll piggyback on their access via the `.env` they send you.

If you're on Path B, you'll need accounts at every vendor below (all have free tiers sufficient for development; production usage will require paid plans):

- [Ultravox](https://app.ultravox.ai/) — voice AI platform
- [Telnyx](https://portal.telnyx.com/) — phone numbers + TeXML
- [Firecrawl](https://www.firecrawl.dev/) — full-site web scraper
- [Resend](https://resend.com/) — transactional email
- [Supabase](https://supabase.com/) — your dashboard's Postgres + auth
- n8n — automation. Use [n8n Cloud](https://n8n.io/cloud/) or self-host.

You **do not** need (either path):

- An Anthropic API key — Claude Code's subscription handles all inference.
- An OpenAI key — analysis runs server-side on your dashboard-server using whatever model you've wired there; not the skills' concern.
- Anything Windows-specific beyond Git Bash + cmd for junctions.

---

## 2. Clone the repo

Applies to both paths.

Pick a stable parent directory you won't accidentally delete (e.g. `~/Code/`).

```bash
mkdir -p ~/Code
cd ~/Code
git clone https://github.com/Spotfunnel/spotfunnel-voice-skills.git
cd spotfunnel-voice-skills
```

You should now see:

```
.
├── README.md
├── INSTALL.md          ← this file
├── LICENSE
├── .env.example
├── base-agent-setup/
├── onboard-customer/
├── voice-stress-test/
├── docs/
└── schema/
```

You'll know it worked when `ls` shows all three skill directories (`base-agent-setup/`, `onboard-customer/`, `voice-stress-test/`) and `cat .env.example` prints the env template.

---

## 3. Quick install (shared backend) — Path A

If you're on Path B (provisioning your own copy), skip ahead to [§4](#4-provision-your-own-backend--path-b).

This is the fast path. Your collaborator owns every vendor account already; you're plugging into their setup.

### 3.1 Get `.env` values from your collaborator privately

They'll send you either a complete `.env` file or a list of `KEY=VALUE` lines covering every variable in `.env.example`. **Treat the credentials like passwords — don't paste them anywhere public.** Receive via DM, Signal, encrypted email, or a password manager share. Don't paste into Slack channels, GitHub issues, or anywhere with shared visibility.

The list will include every key from `.env.example`: `ULTRAVOX_API_KEY`, `TELNYX_API_KEY`, `TELNYX_PUBLIC_KEY`, `FIRECRAWL_API_KEY`, `RESEND_API_KEY`, `RESEND_FROM_EMAIL`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `DASHBOARD_SERVER_URL`, `REFERENCE_ULTRAVOX_AGENT_ID`, `N8N_BASE_URL`, `N8N_API_KEY`, `N8N_ERROR_REPORTER_WORKFLOW_ID`, and `OPS_ALERT_EMAIL`.

### 3.2 Save them as `.env` at the repo root

```bash
cp .env.example .env
```

Open `.env` in your editor and replace each blank value with what your collaborator sent. The `.env` file is gitignored — never commit it.

`.env` syntax rules:

- **No quotes around values.** Write `ULTRAVOX_API_KEY=uv_abc123`, not `ULTRAVOX_API_KEY="uv_abc123"`.
- **No trailing whitespace** on any line. Trailing spaces become part of the value.
- **No spaces around `=`.** `KEY=value`, not `KEY = value`.
- **Comments start with `#`** and must be on their own line, not inline after a value.

### 3.3 Junction the skills into `~/.claude/skills/`

Claude Code discovers skills by scanning `~/.claude/skills/` at session startup. We don't copy the skill folders — we link them, so future `git pull`s take effect without re-copying.

**Windows (Git Bash → cmd junctions).** `ln -s` from Git Bash typically fails on Windows without admin rights or developer mode. Use Windows directory junctions via `cmd` instead — they work without elevated privileges and Claude Code follows them transparently.

```bash
mkdir -p "$USERPROFILE/.claude/skills"

# Replace USERNAME and the absolute path if your clone lives elsewhere
cmd <<'EOF'
mklink /J "C:\Users\USERNAME\.claude\skills\base-agent-setup" "C:\Users\USERNAME\Code\spotfunnel-voice-skills\base-agent-setup"
mklink /J "C:\Users\USERNAME\.claude\skills\onboard-customer" "C:\Users\USERNAME\Code\spotfunnel-voice-skills\onboard-customer"
mklink /J "C:\Users\USERNAME\.claude\skills\voice-stress-test" "C:\Users\USERNAME\Code\spotfunnel-voice-skills\voice-stress-test"
EOF
```

All three should print `Junction created for ...`.

**macOS / Linux (POSIX symlinks).**

```bash
mkdir -p ~/.claude/skills
ln -s "$(pwd)/base-agent-setup" ~/.claude/skills/base-agent-setup
ln -s "$(pwd)/onboard-customer" ~/.claude/skills/onboard-customer
ln -s "$(pwd)/voice-stress-test" ~/.claude/skills/voice-stress-test
```

Verify:

```bash
ls ~/.claude/skills/base-agent-setup/SKILL.md
ls ~/.claude/skills/onboard-customer/SKILL.md
ls ~/.claude/skills/voice-stress-test/SKILL.md
```

All three must resolve. If any is missing, the junction/symlink isn't pointing at the right place — recreate it.

### 3.4 Open a fresh Claude Code session and run `/base-agent`

Skill discovery runs at session startup, so close any existing Claude Code window and reopen it. Then jump to [§5](#5-verify-env-preflight-both-paths) — Stage 0 will green-tick every env var and confirm the install worked.

That's the entire setup for Path A. ~5 minutes if your collaborator has the `.env` ready.

---

## 4. Provision your own backend — Path B

If you're standing up your own copy of this stack from scratch, walk through every subsection below. If you're joining someone else's, you've already done §3 — skip ahead to [§5](#5-verify-env-preflight-both-paths).

This is the canonical reference for forking the project: every vendor account, every key, every verification curl.

### 4.0 Create `.env` from the template

```bash
cp .env.example .env
```

The `.env` file is gitignored — never commit it. Every secret the skills need lives here, sourced once at Stage 0 of every skill invocation.

Open `.env` in your editor. The file is grouped into four sections; you'll fill them in over the course of §4.1–§4.6 (creating accounts gives you the values).

`.env` syntax rules:

- **No quotes around values.** Write `ULTRAVOX_API_KEY=uv_abc123`, not `ULTRAVOX_API_KEY="uv_abc123"`. Bash's `set -a; source .env; set +a` treats the literal text as the value, quotes included.
- **No trailing whitespace** on any line. Trailing spaces become part of the value.
- **No spaces around `=`.** `KEY=value`, not `KEY = value`.
- **Comments start with `#`** and must be on their own line, not inline after a value.
- **Multi-line values are not supported.** If a key needs a multi-line string, base64-encode it.

### 4.1 Ultravox

Ultravox is the voice AI platform that hosts each customer's agent.

1. **Create an account** at <https://app.ultravox.ai/>. Free tier gives you a few minutes of trial calls — enough for a smoke test, but you'll need to add billing before serving real customers.
2. **Generate an API key.** Go to **Settings → API Keys → Create**. Copy the key (it starts with `uv_`). Paste it into `.env`:
   ```
   ULTRAVOX_API_KEY=uv_your_key_here
   ```
3. **Create your reference agent.** This is a baseline agent in your Ultravox console whose voice, temperature, inactivity messages, and first-speaker settings get copied onto every new customer agent the skill creates.
   - Click **Agents → New Agent**.
   - Pick a voice you like (try ElevenLabs voices — Jack, Emma, or any other premium voice). The voice you pick here propagates to every customer until you change it.
   - Set **temperature** to something conservative (0.3–0.5 is a good default for receptionist-style agents).
   - Configure **inactivity messages** — the tiered prompts the agent says when the caller goes silent. Three to four messages, escalating in directness ("Are you still there?" → "I'll need to wrap up if I can't hear you" → end-call). The exact wording doesn't matter; the skill copies whatever you set.
   - Set **first speaker** to whatever feels right (usually the agent speaks first on inbound calls).
   - Save the agent. **Copy its agent ID from the URL or the agent details panel** (a UUID like `4f5eab4b-a357-4995-a06d-d4a5e3dfb94a`).
4. Paste the agent ID into `.env`:
   ```
   REFERENCE_ULTRAVOX_AGENT_ID=4f5eab4b-a357-4995-a06d-d4a5e3dfb94a
   ```

You'll know it worked when:
```bash
curl -sS -H "X-API-Key: $ULTRAVOX_API_KEY" "https://api.ultravox.ai/api/agents/$REFERENCE_ULTRAVOX_AGENT_ID" | python3 -c "import json, sys; d = json.load(sys.stdin); print('voice:', d.get('voice')); print('temp:', d.get('temperature'))"
```
returns the voice and temperature you just configured. (Source `.env` first if you haven't: `set -a; source .env; set +a`.)

### 4.2 Telnyx

Telnyx provides the phone numbers (DIDs) and TeXML applications that bridge PSTN calls to Ultravox. The model is one TeXML app per DID — set up in bulk via a single script, no manual app-by-app clicking, no `TELNYX_POOL_TEXML_APP_ID` to copy.

The end-to-end inbound chain you're building:

```
PSTN  →  Telnyx DID  →  TeXML app (voice_url)  →  Ultravox agent telephony_xml  →  conversation
                                  ↓ (status_callback)
                          dashboard-server /webhooks/call-ended  →  Supabase calls row
```

#### Step 1 — Account and API key

1. **Create an account** at <https://portal.telnyx.com/>. You'll need to add billing — DIDs cost ~$1 USD/month each plus per-minute usage.
2. **Generate an API key.** Telnyx Portal → **API Keys → Create API Key**. Pick the default scope (full account access). Save the key. Paste it into `.env`:
   ```
   TELNYX_API_KEY=KEY...
   ```

#### Step 2 — Buy DIDs

Buy 3–5 DIDs in your country/region. **Phone Numbers → Search & Buy Numbers**.

- The skill is Australia-defaulted in its examples (area codes 02/03/07/08), but works anywhere — pick whatever country code makes sense for your customer base.
- Buy at least 3, ideally 5, to give the pool some buffer. The `/base-agent` skill claims one per customer and alerts you when the pool drops below 3.
- The skill never auto-purchases DIDs. You buy them manually in bulk; the skill only *claims* from the pool.

#### Step 3 — Capture your Telnyx public key for webhook signing

Telnyx signs every webhook it sends with **Ed25519**. Your dashboard-server must verify the `Telnyx-Signature-Ed25519-Signature` and `Telnyx-Signature-Ed25519-Timestamp` headers on incoming `/webhooks/call-ended` requests, otherwise it has no proof the webhook actually came from Telnyx.

1. Telnyx Portal → top-right **Account** menu → **Settings** (or directly: <https://portal.telnyx.com/#/app/account/public-key>).
2. Copy the **Public Key** value (a base64 string).
3. Paste it into your **dashboard-server's** environment as `TELNYX_PUBLIC_KEY` (or whatever your dashboard-server expects — exact variable name lives in the dashboard-server repo, not here).

> `TELNYX_PUBLIC_KEY` is consumed by your dashboard-server, not by these skills. It's listed in `.env.example` so you don't forget it when wiring up the dashboard-server side.

#### Step 4 — Run `bulk-create-texml-apps.sh`

This one script does all the per-DID TeXML setup. From the repo root, with `.env` filled in (especially `DASHBOARD_SERVER_URL` and `TELNYX_API_KEY`):

```bash
bash base-agent-setup/scripts/bulk-create-texml-apps.sh
```

For each DID in your account that doesn't already have a TeXML app bound, the script:

- Creates a TeXML app named `pool-did-<normalized-e164>` (e.g. `pool-did-61731304231`).
- Sets `voice_url` to a placeholder, `voice_method=POST`, codec preferences `[OPUS, G711U]`, `anchorsite_override=Latency`, `status_callback=$DASHBOARD_SERVER_URL/webhooks/call-ended`, `status_callback_method=POST`, and `tags=["pool-available"]`.
- Binds the DID to the new TeXML app and tags the DID with `pool-available`.

The script is **idempotent** — DIDs already bound to a TeXML app are skipped with `[SKIP]`. Re-running after buying more DIDs is safe and only processes the new ones.

To preview without making changes, add `--dry-run`. To target a subset, add `--dids +614...,+617...`.

#### Step 5 — Verification

Run this one-liner to confirm every DID has a `pool-available` TeXML app bound. Source `.env` first if you haven't (`set -a; source .env; set +a`).

```bash
echo "=== pool-available TeXML apps + bound DIDs ==="
curl --ssl-no-revoke -sS -G "https://api.telnyx.com/v2/texml_applications" \
  --data-urlencode "page[size]=100" \
  -H "Authorization: Bearer $TELNYX_API_KEY" \
  | python3 -c "
import json, sys
apps = json.load(sys.stdin).get('data') or []
pool = [a for a in apps if 'pool-available' in (a.get('tags') or [])]
claimed = [a for a in pool if any((t or '').startswith('claimed-') for t in (a.get('tags') or []))]
free = [a for a in pool if a not in claimed]
print(f'  {len(pool)} pool TeXML apps | {len(free)} free | {len(claimed)} claimed')
for a in pool:
    tags = a.get('tags') or []
    state = 'CLAIMED' if any((t or '').startswith('claimed-') for t in tags) else 'free'
    print(f'    {a.get(\"friendly_name\")}  [{state}]  app_id={a.get(\"id\")}  tags={tags}')
"
```

Expected output: at least 3 apps listed, all `[free]` on a fresh install. The count should match the number of DIDs you bought in step 2. If any DID is missing, re-run `bulk-create-texml-apps.sh` — it'll create the missing TeXML apps without re-creating existing ones.

### 4.3 Firecrawl

Firecrawl is the web scraper used by `/base-agent` Stage 2 to crawl the customer's website and feed it into brain-doc synthesis.

1. **Create an account** at <https://www.firecrawl.dev/>. The free tier (500 credits) is enough for development and a handful of small-site customer onboardings.
2. **Generate an API key.** Dashboard → **API Keys → Create**. Copy the key (starts with `fc-`). Paste into `.env`:
   ```
   FIRECRAWL_API_KEY=fc-your_key_here
   ```
3. **Note: upgrade before serving real customers.** A typical customer onboarding scrape (50–100 pages, the skill's default cap) will burn through free-tier credits fast. The skill respects `FIRECRAWL_MAX_PAGES` (default 50) — set lower during dev if you want to conserve credits.

You'll know it worked when:
```bash
curl -sS -X POST "https://api.firecrawl.dev/v1/scrape" \
  -H "Authorization: Bearer $FIRECRAWL_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"url":"https://example.com"}' | python3 -c "import json, sys; d = json.load(sys.stdin); print('success:', d.get('success'))"
```
prints `success: True`.

### 4.4 Resend

Resend sends transactional email — pool-low alerts from `/base-agent` and magic-link emails from `/onboard-customer` (when configured to use Resend).

1. **Create an account** at <https://resend.com/>.
2. **Verify a sending domain.** Settings → **Domains → Add Domain**. Add your domain (e.g. `your-org.com`), then add the DNS records Resend provides (SPF, DKIM, DMARC) at your DNS host. Wait for verification to flip to green — usually 5–30 minutes.
   - **Note: you can use Resend's `onboarding@resend.dev` shared sender for testing**, but it has heavy rate limits and looks unprofessional in customer-facing emails. Verify your own domain before going live.
3. **Generate an API key.** Settings → **API Keys → Create API Key**. Pick "Full access" or "Sending access" — both work. Copy the key (starts with `re_`). Paste into `.env`:
   ```
   RESEND_API_KEY=re_your_key_here
   ```
4. **Set the from address** to a verified address on your domain. Suggested:
   ```
   RESEND_FROM_EMAIL=noreply@your-org.com
   ```
   This must be on the domain you just verified — if you try to send from an unverified domain, Resend rejects with a 403.
5. **Set `OPS_ALERT_EMAIL`** to wherever you want pool-low and onboarding-failure alerts to land:
   ```
   OPS_ALERT_EMAIL=ops@your-org.com
   ```

You'll know it worked when:
```bash
curl -sS -X POST "https://api.resend.com/emails" \
  -H "Authorization: Bearer $RESEND_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"from\":\"$RESEND_FROM_EMAIL\",\"to\":[\"$OPS_ALERT_EMAIL\"],\"subject\":\"Resend smoke test\",\"text\":\"If you're reading this, your Resend wiring works.\"}"
```
returns a JSON body with an `id` field, and the test email lands in your inbox.

### 4.5 Supabase

Supabase hosts your dashboard's Postgres database (workspaces, users, calls, workflow_errors) and the auth subsystem.

> If a collaborator is sharing their Supabase project with you, you're on **Path A** — go back to [§3](#3-quick-install-shared-backend--path-a) and follow it. The schema is already there, auth is already configured, you just paste the values they sent. The walkthrough below is for someone provisioning a brand-new project.

1. **Create a project** at <https://supabase.com/dashboard>. Pick a region close to where your customers are. Choose a strong database password and save it somewhere — you won't need it for the skills, but you might need it for direct DB access later.
2. **Capture URL and service-role key.** Project Settings → **API**.
   - **Project URL** → paste into `.env` as `SUPABASE_URL` (format: `https://<project-ref>.supabase.co`).
   - **service_role key** (the **locked** one — *not* the anon/public key) → paste into `.env` as `SUPABASE_SERVICE_ROLE_KEY`. This is a long JWT starting `eyJhbGciOi...`.
   ```
   SUPABASE_URL=https://abcdefghijkl.supabase.co
   SUPABASE_SERVICE_ROLE_KEY=eyJhbGciOi...
   ```
   > **Treat the service-role key like a root password.** It bypasses Row Level Security. Never paste it into client-side code, public Slack channels, or commit it to git.
3. **Run the SQL migration.** The skills assume a specific schema (`workspaces`, `public.users` mirroring `auth.users`, `calls`, `workflow_errors`, etc.).
   - Open Supabase Studio → **SQL Editor → New query**.
   - Paste the contents of `schema/supabase-dashboard.sql` and run.
   - **Note:** as of this writing, `schema/supabase-dashboard.sql` is generated by Task 0.7 (separate from this install task). If the file doesn't exist in your clone yet, see `schema/supabase-dashboard.sql, generated separately` — it'll appear in a follow-up commit. In the meantime, your dashboard-server's own migrations or schema doc is the authoritative source for what tables `/onboard-customer` expects.
4. **Enable Auth.** Authentication → **Providers** → make sure Email is enabled. Configure Auth → **URL Configuration** with the redirect URL of your dashboard frontend (the one users land on after clicking a magic link).

You'll know it worked when:
```bash
curl -sS "$SUPABASE_URL/rest/v1/workspaces?select=count" \
  -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY"
```
returns either `[]` (empty table — fine for a freshly-provisioned project) or a row count, with no auth errors.

### 4.6 n8n

n8n is your automation host. The skills use it indirectly: `/onboard-customer` Stage 7b wires every per-customer n8n workflow's `settings.errorWorkflow` to a central error-reporter workflow you create once.

1. **Get an n8n instance.**
   - Easiest: [n8n Cloud](https://n8n.io/cloud/) — sign up, pick a tenant URL like `https://<your-tenant>.app.n8n.cloud`.
   - Self-host: see <https://docs.n8n.io/hosting/> for Docker/Railway/Render options.
2. **Create the central error-reporter workflow.** Follow `docs/runbooks/n8n-error-wiring.md` step by step. The short version:
   - In n8n, create a new workflow named **Global Error Alert System**.
   - Add an **Error Trigger** node.
   - Add an **HTTP Request** node configured to POST to `$DASHBOARD_SERVER_URL/webhooks/n8n-error` with a body shape matching the runbook's example (the `{ source, severity, message, workflow, execution, payload }` schema).
   - Optionally add a Gmail/Resend node in parallel for human-readable alerts.
   - Set the HTTP node's "Continue On Fail" to true so a dashboard outage doesn't kill the reporter.
   - Activate the workflow.
   - **Copy its workflow ID** from the URL (`https://<tenant>.app.n8n.cloud/workflow/<ID>`).
3. **Create an n8n API key.** n8n → **Settings → API → Create an API key**. Copy. Paste into `.env`:
   ```
   N8N_BASE_URL=https://your-tenant.app.n8n.cloud
   N8N_API_KEY=n8n_api_...
   N8N_ERROR_REPORTER_WORKFLOW_ID=8UJUhRw26ZtVH9HV
   ```
   - **No trailing slash on `N8N_BASE_URL`.** A trailing slash will produce malformed URLs in Stage 7b (you'll get 404s on `/api/v1/workflows//...`).

You'll know it worked when:
```bash
curl -sS -H "X-N8N-API-KEY: $N8N_API_KEY" "$N8N_BASE_URL/api/v1/workflows/$N8N_ERROR_REPORTER_WORKFLOW_ID" | python3 -c "import json, sys; d = json.load(sys.stdin); print('name:', d.get('name')); print('active:', d.get('active'))"
```
prints the reporter workflow's name and `active: True`.

### 4.7 Optional: deploy dashboard-server

`/onboard-customer` writes workspace rows that point at `$DASHBOARD_SERVER_URL/webhooks/call-ended`. Without a deployed dashboard-server, customer calls hit Ultravox successfully but never land in your Supabase — the dashboard will be empty.

**This repo does not include the dashboard-server source code.** Building it is out of scope here. The contract dashboard-server must satisfy:

- Accept POST at `/webhooks/call-ended` from Ultravox. Body shape per Ultravox's webhook docs.
- On receipt: fetch the full transcript + audio from Ultravox using the call ID, run analysis (your choice of LLM), and INSERT into `calls` with `workspace_id` resolved by `SELECT id FROM workspaces WHERE ultravox_agent_ids @> ARRAY[$agentId]`.
- Accept POST at `/webhooks/n8n-error` from your central n8n error-reporter. Auth via a shared `x-n8n-token` header. Body shape per `docs/runbooks/n8n-error-wiring.md`. Insert into `workflow_errors`.
- Use `SUPABASE_SERVICE_ROLE_KEY` for writes (RLS-bypassing). Never expose this key to the browser.
- Be reachable at a stable public URL — Railway, Render, Fly, Vercel-functions, or any Node host. Mark a `DASHBOARD_SERVER_URL` env on that deploy back into your skills' `.env`.

For the architecture rationale and full surface map, read [`base-agent-setup/docs/2026-04-25-design.md`](base-agent-setup/docs/2026-04-25-design.md) and [`onboard-customer/SKILL.md`](onboard-customer/SKILL.md) — they spell out every webhook, every column, and every failure mode.

If you don't have a dashboard-server yet, you can still:

- Run `/base-agent` end-to-end. It creates Ultravox agents and claims DIDs without touching dashboard-server.
- Test the rough agent by dialing the claimed DID — you'll hear it answer, knowledgeable about the customer's business.

What you **can't** do without dashboard-server:

- See calls in any kind of operational dashboard.
- Have call summaries emailed.
- Have analysis populate `outcome`/`intent`/`summary` columns.

### 4.8 Junction the skill folders into `~/.claude/skills/`

Same as §3.3 in Path A — Claude Code discovers skills by scanning `~/.claude/skills/` at session startup. Each skill must be a directory (or symlink/junction to one) inside that folder, containing a `SKILL.md` at its root.

**Windows (Git Bash → cmd junctions).**

```bash
mkdir -p "$USERPROFILE/.claude/skills"

cmd <<'EOF'
mklink /J "C:\Users\USERNAME\.claude\skills\base-agent-setup" "C:\Users\USERNAME\Code\spotfunnel-voice-skills\base-agent-setup"
mklink /J "C:\Users\USERNAME\.claude\skills\onboard-customer" "C:\Users\USERNAME\Code\spotfunnel-voice-skills\onboard-customer"
mklink /J "C:\Users\USERNAME\.claude\skills\voice-stress-test" "C:\Users\USERNAME\Code\spotfunnel-voice-skills\voice-stress-test"
EOF
```

**macOS / Linux (POSIX symlinks).**

```bash
mkdir -p ~/.claude/skills
ln -s "$(pwd)/base-agent-setup" ~/.claude/skills/base-agent-setup
ln -s "$(pwd)/onboard-customer" ~/.claude/skills/onboard-customer
ln -s "$(pwd)/voice-stress-test" ~/.claude/skills/voice-stress-test
```

Verify:

```bash
ls ~/.claude/skills/base-agent-setup/SKILL.md
ls ~/.claude/skills/onboard-customer/SKILL.md
ls ~/.claude/skills/voice-stress-test/SKILL.md
```

All three must resolve. If any is missing, the junction/symlink isn't pointing at the right place — recreate it.

---

## 5. Verify env preflight (both paths)

The fastest way to confirm everything's wired correctly is to start a Claude Code session and run the skill — Stage 0 will preflight every required env var and halt with a specific error if anything is missing.

1. **Open a fresh Claude Code session.** Skill discovery runs at session startup, so if you had Claude Code open before junctioning the skills, close and reopen it.
2. From any directory (the skills are global):
   ```
   /base-agent
   ```
3. Stage 0 runs immediately. You should see something like:
   ```
   Stage 0 — Env preflight
   ✅ ULTRAVOX_API_KEY loaded
   ✅ TELNYX_API_KEY loaded
   ✅ FIRECRAWL_API_KEY loaded
   ✅ RESEND_API_KEY loaded
   ✅ RESEND_FROM_EMAIL loaded
   ✅ SUPABASE_URL loaded
   ✅ SUPABASE_SERVICE_ROLE_KEY loaded
   ✅ DASHBOARD_SERVER_URL loaded
   ✅ REFERENCE_ULTRAVOX_AGENT_ID loaded
   ✅ N8N_BASE_URL loaded
   ✅ N8N_API_KEY loaded
   ✅ N8N_ERROR_REPORTER_WORKFLOW_ID loaded
   ✅ OPS_ALERT_EMAIL loaded
   ```
4. **If any var halts the skill**, open `.env` and check that:
   - The line for that var has a value (not blank).
   - There are no quotes around the value.
   - There is no trailing whitespace.
   - There are no spaces around the `=`.
   - The line is at the top level (not commented out, not under a heading you accidentally collapsed).
5. **If Stage 0 reports "Cannot locate the spotfunnel-voice-skills .env file"**, the resolver couldn't find your `.env`. Either:
   - place `.env` at the repo root (the default-discovery path), or
   - export `SPOTFUNNEL_SKILLS_ENV` in your shell profile (`~/.bashrc`, `~/.zshrc`, or Windows user env vars):
     ```bash
     export SPOTFUNNEL_SKILLS_ENV="/absolute/path/to/your/.env"
     ```

Once Stage 0 prints all green ticks, you can `^C` out of `/base-agent` for now — env preflight is what we wanted to confirm.

You can also do the same check with `/onboard-customer` — it has its own Stage 0 that validates the subset of vars it needs.

`/stress-test` is the third skill in the family — it's the post-tool-design quality gate that runs simulated calls against a finished agent, grades transcripts against a constitution of rules, and produces actionable per-violation reports. It complements `/base-agent` (which builds the rough agent) and `/onboard-customer` (which wires it into the dashboard) by validating the agent's behaviour before it goes live and on every prompt or tool change after. See [`voice-stress-test/SKILL.md`](voice-stress-test/SKILL.md) for invocation patterns. It uses a subset of the same `.env` (`ULTRAVOX_API_KEY`, `ANTHROPIC_API_KEY`) plus its own training-harness directory and constitution config.

---

## 6. Test run (both paths)

Before exposing real customer data to the pipeline, do one dry run against a fake customer.

> **Path A note:** if you're sharing a backend with a collaborator, coordinate before doing a test run — your test workspace will land in their Supabase too. Use a clearly-fake customer name (e.g. `Test Customer Inc`) and clean up afterwards.

1. Pick a fake customer — anything works as long as the website exists and is small. Suggestions:
   - `https://example.com` (smallest possible)
   - A defunct local-business site with public hours and contact info
2. Generate or write a fake "meeting transcript" (5–10 paragraphs). The skill's brain-doc synthesis needs *some* transcript text to work with.
3. From any project directory:
   ```
   /base-agent Test Customer Inc
   ```
4. Walk through the prompts. Paste the website URL when asked. Paste the fake transcript when asked.
5. Watch each stage execute. Pay particular attention to:
   - **Stage 5** (reference agent settings pull) — confirms your `REFERENCE_ULTRAVOX_AGENT_ID` works.
   - **Stage 6** (create Ultravox agent) — confirms your `ULTRAVOX_API_KEY` has write permissions.
   - **Stage 7** (claim Telnyx DID) — confirms your TeXML app and DID pool are wired.
   - **Stage 11** (handoff to `/onboard-customer`) — confirms Supabase + n8n end of the pipeline.
6. After the run, **clean up the test artifacts** so they don't leak into production:
   - Delete the test workspace from Supabase: `/onboard-customer undo test-customer-inc` (the skill refuses if there are non-test calls — fine for a fresh test).
   - Delete the test agent from Ultravox console.
   - Release the test DID back to Telnyx (Phone Numbers → My Numbers → Release) or leave it in the pool.

> Note: Phase E Task 25 of the implementation plan is expected to add a stub-customer fixture that automates this dry-run pattern (deterministic fake transcript + scrape, no live API calls). Once that's in place, see `base-agent-setup/docs/2026-04-25-implementation-plan.md` for the canonical test recipe. Until then, the manual fake-customer run above is the recommended smoke test.

You'll know the install is fully working when:
- `/base-agent` runs all 11 stages without halting.
- A new agent appears in your Ultravox console.
- A new TeXML connection appears on one of your DIDs.
- A new row appears in `workspaces` in Supabase, with the correct `ultravox_agent_ids` and `telnyx_numbers`.
- A magic-link email lands at the primary user email you specified (if Supabase Auth SMTP is configured) — or the action link is printed in Stage 7 output for manual forwarding.
- Calling the claimed DID gets you a working voice AI conversation.

---

## 7. Troubleshooting (both paths)

### Stage 0 reports a missing var

**Symptom:** the skill halts at Stage 0 with `❌ X missing` or `Stage 0 halted — X is not set`.

**Causes & fixes:**

- **`.env` syntax error.** Check the offending line for: quotes around the value (remove them), trailing whitespace (trim it), spaces around `=` (remove them), inline comments (move them to their own line).
- **Wrong env file resolved.** The resolver order is `$SPOTFUNNEL_SKILLS_ENV` → `<repo-root>/.env` → cached path at `~/.config/spotfunnel-skills/env-path`. If you have multiple clones or copies, an old one might be winning. `echo $SPOTFUNNEL_SKILLS_ENV` to check the override; `cat ~/.config/spotfunnel-skills/env-path` to check the cache. Delete the cache file if stale.
- **Var name typo.** `.env` must use exactly the names from `.env.example`. `REFERENCE_UL_TRAVOX_AGENT_ID` (with extra underscore) won't match `REFERENCE_ULTRAVOX_AGENT_ID`. Compare side by side.
- **Path A only — collaborator missed a key.** If your `.env` is missing a value entirely, ask your collaborator to send the missing one. Don't try to provision it yourself — that vendor account is theirs.

### Junction created but `ls ~/.claude/skills/` is empty

**Symptom:** `mklink /J` printed "Junction created" but the `~/.claude/skills/` listing is empty, or `/base-agent` doesn't autocomplete in Claude Code.

**Causes & fixes:**

- **Wrong target path in mklink.** Junctions don't validate the target at creation time; if the path is wrong, the junction exists but resolves to nothing. Run `dir "C:\Users\USERNAME\.claude\skills\base-agent-setup"` from cmd — if it errors with "The system cannot find the path specified", the junction's target is broken. Delete and recreate with the correct absolute path.
- **Junction path mismatches Claude Code's expectation.** Claude Code reads `~/.claude/skills/` (which on Windows resolves to `C:\Users\USERNAME\.claude\skills\`). Confirm `$USERPROFILE` points where you think it does: `echo $USERPROFILE` from Git Bash.
- **Claude Code session was already open.** Skill discovery happens at session startup. Close and reopen Claude Code — junctions created during a running session aren't picked up until next launch.
- **`SKILL.md` missing inside the linked folder.** Each skill folder needs `SKILL.md` at its root. Confirm with `ls ~/.claude/skills/base-agent-setup/SKILL.md`.

### Ultravox agent creation fails with 401

**Symptom:** Stage 6 halts with `Ultravox POST rejected: 401 Unauthorized`.

**Causes & fixes:**

- **API key wrong or empty.** Check `.env` and verify `ULTRAVOX_API_KEY` is the full key from Ultravox console (Settings → API Keys), not truncated.
- **API key revoked.** If you regenerated keys in the Ultravox console, the old one is dead. Use the new one and restart the Claude Code session. (Path A: ask your collaborator for the new key — they own the account.)
- **Account inactive / billing not added.** Ultravox sometimes rejects API calls with 401 when an account is past trial limits — log into the console and check for billing prompts. Add billing if so.

### Telnyx claim returns no DIDs

**Symptom:** Stage 7 halts with `Pool exhausted — buy more DIDs and re-run /base-agent {slug} to resume`, or warns `DID pool low — N remaining`.

**Causes & fixes:**

- **Pool actually empty.** Buy more DIDs in the Telnyx portal, then re-run `bash base-agent-setup/scripts/bulk-create-texml-apps.sh` to create + bind TeXML apps for the new DIDs. (Path A: tell your collaborator — they own the Telnyx account and need to buy + bulk-create.)
- **DIDs were bought but `bulk-create-texml-apps.sh` was never run.** The claim logic looks for TeXML apps tagged `pool-available` — if you bought DIDs but skipped the bulk-create step, no TeXML apps will be tagged. Run the script.
- **All `pool-available` apps are already tagged `claimed-*`.** Every claim adds a `claimed-<slug>` tag. Either you've claimed every DID, or stale `claimed-*` tags are sticking around. Inspect via the verification block in §4.2 step 5; remove `claimed-*` tags from apps you want to release.
- **API key lacks number-management scope.** Telnyx API keys can have scoped permissions. Re-create the key with full account access if the issue persists.

### n8n calls fail with 401

**Symptom:** `/onboard-customer` Stage 7b halts with HTTP 401 on `$N8N_BASE_URL/api/v1/workflows`.

**Causes & fixes:**

- **API key expired.** n8n API keys can be invalidated by tenant admins or rotated. Regenerate in n8n Settings → API and update `.env`.
- **`N8N_BASE_URL` has a trailing slash.** `https://tenant.app.n8n.cloud/` (note the slash) becomes `https://tenant.app.n8n.cloud//api/v1/...` — n8n returns 404 or 401 depending on version. Remove the trailing slash.
- **Wrong tenant URL.** n8n Cloud URLs look like `https://<tenant>.app.n8n.cloud`. Self-hosted is whatever you set. The path must reach `/healthz` if you append it manually — sanity-check with `curl $N8N_BASE_URL/healthz`.
- **Auth header name wrong.** The skill sends `X-N8N-API-KEY` (uppercase, hyphenated). n8n versions before ~1.2 used different header names. Upgrade your n8n instance if it's very old.

### Resend 403 on send

**Symptom:** Stage 7 (or pool-low alert) errors with `403 Forbidden` from Resend.

**Causes & fixes:**

- **`RESEND_FROM_EMAIL` is on an unverified domain.** Resend rejects sends from unverified domains. Verify the domain (Settings → Domains) and wait for green status.
- **API key lacks sending scope.** Recreate the key with full or sending access.

### Supabase 401 / 403

**Symptom:** `/onboard-customer` halts with auth errors hitting `$SUPABASE_URL/auth/v1/admin/...` or `/rest/v1/...`.

**Causes & fixes:**

- **Wrong key — anon vs service_role.** The skills require `SUPABASE_SERVICE_ROLE_KEY` (the locked one). The anon/public key won't work for admin endpoints or RLS-bypassed inserts. Confirm in Supabase dashboard which key you copied.
- **Project paused.** Free-tier Supabase projects auto-pause after a week of inactivity. Unpause from the Supabase dashboard.

### Skill prompts for env file path on every run

**Symptom:** every invocation of `/base-agent` or `/onboard-customer` asks "where is your .env?".

**Causes & fixes:**

- **Cached path file at `~/.config/spotfunnel-skills/env-path` is missing or wrong.** The skill writes to this file the first time you provide a path; if writes fail (permissions) or the cached path no longer resolves, the skill re-prompts.
- **Easiest fix:** put `.env` at the repo root and run the skill from a Claude Code session that can `git rev-parse --show-toplevel` to find the repo (i.e. you're inside the cloned directory or any subdirectory of it).
- **More portable fix:** export `SPOTFUNNEL_SKILLS_ENV` in your shell profile so it's always in scope:
  ```bash
  # ~/.bashrc or ~/.zshrc
  export SPOTFUNNEL_SKILLS_ENV="$HOME/Code/spotfunnel-voice-skills/.env"
  ```

### Calls don't land in dashboard after onboarding

**Symptom:** `/onboard-customer` succeeded, but a real call to the customer's DID doesn't produce a row in `calls`.

**Causes & fixes:**

- **`call.ended` webhook URL not set on the Ultravox agent.** This is a manual step (Stage 7 of `/onboard-customer` reminds you of it). The skill *cannot* set Ultravox webhooks via API — Ultravox PATCH wipes unrelated config. Open the agent in the Ultravox console → Integrations → Webhooks → set `call.ended` to `$DASHBOARD_SERVER_URL/webhooks/call-ended`. Save. Re-test.
- **dashboard-server isn't deployed or its URL is wrong in `.env`.** See §4.7. The webhook URL written into the workspace row is `$DASHBOARD_SERVER_URL/webhooks/call-ended` — if that URL doesn't resolve to a running service, Ultravox's webhook fires fail silently.
- **`workflow_errors` row exists with `source = 'call-ended'`.** Check Supabase: `SELECT severity, message, payload FROM workflow_errors WHERE source = 'call-ended' ORDER BY created_at DESC LIMIT 5;`. The payload tells you exactly what went wrong (workspace not found, agent_id mismatch, etc.).

### Brain-doc synthesis returns generic / blank

**Symptom:** `/base-agent` Stage 3 produces a brain-doc that's ~empty or generic.

**Causes & fixes:**

- **Firecrawl scrape returned nothing.** Some sites block scrapers heavily; the skill's `respectRobots: false` helps but isn't a silver bullet. Check `runs/{slug}-*/scrape/` — if it's tiny or empty, the customer's site has a blocker (Cloudflare challenge, login wall, geo-block). Manually paste the customer's site copy as part of the operator hints to compensate.
- **Meeting transcript is too short.** The brain-doc draws heavily from transcript when site is thin. Paste a longer transcript with concrete details — names, hours, services, prices.

---

## You're set up

If `/base-agent` runs all 11 stages green against a test customer and you can dial the claimed DID and have a coherent conversation, the install is complete. From here:

- Read [`base-agent-setup/SKILL.md`](base-agent-setup/SKILL.md) and [`onboard-customer/SKILL.md`](onboard-customer/SKILL.md) to understand the per-customer flow you'll be running.
- (Path B only) Tune your reference Ultravox agent over time — every change to its voice/temp/inactivity propagates to the next customer onboarded.
- (Path B only) Customize `base-agent-setup/reference-docs/discovery-methodology.md` to match your preferred customer-discovery style.
- (Path B only) Upgrade Firecrawl from free tier before serving paying customers.

When something breaks, your first stop is `workflow_errors` in Supabase — every surface that can fail at runtime routes there. §7 covers the most common failures, but the error payload is the source of truth for anything novel.
