# spotfunnel-voice-skills

Two Claude Code skills that automate end-to-end voice-AI customer onboarding:

- **`/base-agent`** — scrape a new customer's website, synthesize a knowledge-base brain doc from the site + your meeting transcript, create a rough Ultravox agent (no tools yet) with your reference agent's voice/temperature/inactivity settings, claim a Telnyx DID from your pool and wire TeXML, then generate a bespoke ChatGPT-ready discovery prompt the customer pastes into ChatGPT to write a detailed brief back to you.
- **`/onboard-customer`** — wire a finished Ultravox agent into your dashboard backend (Supabase workspaces + auth users + n8n error reporting + dashboard webhook).

Together they collapse a multi-hour manual onboarding process into roughly 30 minutes of operator attention per customer.

## Prerequisites

- **Claude Code** installed locally
- A **Claude Max subscription** (or compatible plan) — the skills use Claude Opus 4.7 inline as their LLM brain
- Accounts: **Ultravox**, **Telnyx**, **Firecrawl**, **Resend**, **Supabase**, **n8n**
- An existing Ultravox agent in your account that you'll use as the reference (its voice, temperature, and inactivity messages get copied onto every new customer)
- A deployed `dashboard-server` (the service that receives Ultravox `call.ended` webhooks and writes to Supabase) — separate from this repo

## Quick install

```bash
git clone https://github.com/Spotfunnel/spotfunnel-voice-skills.git
cd spotfunnel-voice-skills
cp .env.example .env
# Edit .env and fill in every value (see comments in the file)
```

Then make the two skills discoverable by Claude Code. On Windows (Git Bash) using directory junctions:

```bash
cmd <<EOF
mklink /J "C:\Users\YOU\.claude\skills\base-agent-setup" "C:\path\to\spotfunnel-voice-skills\base-agent-setup"
mklink /J "C:\Users\YOU\.claude\skills\onboard-customer" "C:\path\to\spotfunnel-voice-skills\onboard-customer"
EOF
```

On macOS / Linux:

```bash
ln -s "$(pwd)/base-agent-setup" ~/.claude/skills/base-agent-setup
ln -s "$(pwd)/onboard-customer" ~/.claude/skills/onboard-customer
```

Open a fresh Claude Code session anywhere and run `/base-agent` to start.

See **[INSTALL.md](INSTALL.md)** for the full step-by-step setup including Supabase schema migration, n8n error workflow setup, and Telnyx pool TeXML app creation.

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
│   ├── templates/                                ← static templates (universal rules, cover email)
│   ├── scripts/                                  ← bash helpers for Firecrawl / Ultravox / Telnyx / Resend
│   └── docs/                                     ← design + implementation plan
├── onboard-customer/          ← skill 2 (dashboard wiring)
│   ├── SKILL.md
│   ├── ENV_SETUP.md
│   ├── examples/                                 ← intent/outcome taxonomy templates per vertical
│   └── prompts/                                  ← Claude-facing taxonomy generation prompt
├── docs/runbooks/             ← operational runbooks (n8n error wiring, etc.)
└── schema/                    ← SQL migrations for the dashboard backend
```

## Contributing / forks

Fork freely. The methodology in `base-agent-setup/reference-docs/discovery-methodology.md` is the highest-leverage thing to customize for your own onboarding style — it controls how the customer's ChatGPT discovery conversation behaves. Push back genuinely useful changes via PR if you'd like.

## License

MIT. See [LICENSE](LICENSE).
