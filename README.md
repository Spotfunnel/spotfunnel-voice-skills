# spotfunnel-voice-skills

Three Claude Code skills that automate end-to-end voice-AI customer onboarding and validation:

- **`/base-agent`** — scrape a new customer's website, synthesize a knowledge-base brain doc from the site + your meeting transcript, create a rough Ultravox agent (no tools yet) with your reference agent's voice/temperature/inactivity settings, claim a Telnyx DID from your pool and wire TeXML, then generate a bespoke ChatGPT-ready discovery prompt the customer pastes into ChatGPT to write a detailed brief back to you.
- **`/onboard-customer`** — wire a finished Ultravox agent into your dashboard backend (Supabase workspaces + auth users + n8n error reporting + dashboard webhook).
- **`/stress-test`** — run simulated calls against a finished agent, grade the transcripts against a constitution of rules, and produce actionable per-violation reports. The post-tool-design quality gate before an agent goes live.

Together they collapse a multi-hour manual onboarding process into roughly 30 minutes of operator attention per customer, plus an automated stress-test pass before go-live.

## Prerequisites

- **Claude Code** installed locally
- A **Claude Max subscription** (or compatible plan) — the skills use Claude Opus 4.7 inline as their LLM brain
- **Git Bash** on Windows or any POSIX shell on macOS/Linux
- **Python 3** on `PATH`

**Vendor accounts (Ultravox, Telnyx, Firecrawl, Resend, Supabase, n8n) are only required if you're standing up your own backend from scratch.** If a collaborator is onboarding you into their existing Spotfunnel-style operation, you piggyback on their accounts via the `.env` they send you — no signup needed on your side.

## Quick install

There are two install paths. Pick yours:

**Path A — joining an existing Spotfunnel-style operation.** A collaborator is sharing their business backend (Telnyx, Ultravox, Supabase, n8n, Resend, Firecrawl) with you. They'll send you a complete `.env` privately. Paste it in at the repo root, junction the three skills into `~/.claude/skills/`, open a fresh Claude Code session, and you're ready. ~5 minutes. See **[INSTALL.md §3](INSTALL.md#3-quick-install-shared-backend--path-a)** for details.

**Path B — forking to build your own copy from scratch.** You're provisioning your own Telnyx, Ultravox, Supabase, etc. See **[INSTALL.md §4](INSTALL.md#4-provision-your-own-backend--path-b)** for the detailed walkthrough — every account, every key, every verification curl. ~60–90 minutes.

Common skeleton for both paths:

```bash
git clone https://github.com/Spotfunnel/spotfunnel-voice-skills.git
cd spotfunnel-voice-skills
cp .env.example .env
# Path A: paste in the values your collaborator sent you privately.
# Path B: see INSTALL.md §4 to provision each vendor account and capture keys.
```

Then make the three skills discoverable by Claude Code. On Windows (Git Bash) using directory junctions:

```bash
cmd <<EOF
mklink /J "C:\Users\YOU\.claude\skills\base-agent-setup" "C:\path\to\spotfunnel-voice-skills\base-agent-setup"
mklink /J "C:\Users\YOU\.claude\skills\onboard-customer" "C:\path\to\spotfunnel-voice-skills\onboard-customer"
mklink /J "C:\Users\YOU\.claude\skills\voice-stress-test" "C:\path\to\spotfunnel-voice-skills\voice-stress-test"
EOF
```

On macOS / Linux:

```bash
ln -s "$(pwd)/base-agent-setup" ~/.claude/skills/base-agent-setup
ln -s "$(pwd)/onboard-customer" ~/.claude/skills/onboard-customer
ln -s "$(pwd)/voice-stress-test" ~/.claude/skills/voice-stress-test
```

Open a fresh Claude Code session anywhere and run `/base-agent` to start.

See **[INSTALL.md](INSTALL.md)** for the full step-by-step — including the shared-backend path, the from-scratch path, env preflight, the dry-run procedure, and troubleshooting.

## Layout

```
spotfunnel-voice-skills/
├── README.md                  ← you are here
├── INSTALL.md                 ← detailed first-time setup
├── .env.example               ← template for your secrets
├── .gitignore                 ← ignores .env, runs/, customer data
├── base-agent-setup/          ← skill 1 (the 30-min onboarding workhorse)
│   ├── SKILL.md
│   ├── reference-docs/discovery-methodology.md   ← steers the discovery prompt
│   ├── prompts/                                  ← Claude-facing prompt templates
│   ├── templates/                                ← static templates (universal rules, cover email, example agents + tool defs)
│   ├── scripts/                                  ← bash helpers for Firecrawl / Ultravox / Telnyx / Resend
│   └── docs/                                     ← design + implementation plan
├── onboard-customer/          ← skill 2 (dashboard wiring)
│   ├── SKILL.md
│   ├── ENV_SETUP.md
│   ├── examples/                                 ← intent/outcome taxonomy templates per vertical
│   └── prompts/                                  ← Claude-facing taxonomy generation prompt
├── voice-stress-test/         ← skill 3 (post-tool-design validation gate)
│   └── SKILL.md                                  ← constitution + scenarios + grader orchestration
├── docs/runbooks/             ← operational runbooks (n8n error wiring, etc.)
└── schema/                    ← SQL migrations for the dashboard backend
```

## Contributing / forks

Fork freely. The methodology in `base-agent-setup/reference-docs/discovery-methodology.md` is the highest-leverage thing to customize for your own onboarding style — it controls how the customer's ChatGPT discovery conversation behaves. Push back genuinely useful changes via PR if you'd like.

## License

MIT. See [LICENSE](LICENSE).
