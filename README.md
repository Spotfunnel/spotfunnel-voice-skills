# spotfunnel-voice-skills

Voice-AI customer onboarding skills for Claude Code, plus a small operator UI
that closes the read-and-fix protocol-improvement loop.

## What this is

A `/base-agent` Claude Code skill that onboards a voice-AI customer end-to-end
in 11 stages: scrape the customer's website, synthesize a knowledge-base brain
doc from site + meeting transcript + operator hints, create a rough Ultravox
agent with voice/temperature/inactivity copied from a reference agent, claim a
Telnyx DID from your pool and wire TeXML, generate a bespoke ChatGPT-ready
discovery prompt, then hand off to `/onboard-customer` for dashboard wiring.
Resumable across crashes via per-run state.

A small Next.js operator UI deployed at <https://zero-onboarding.vercel.app>
shows runs in shared Supabase, lets you annotate any artifact (drag-select +
comment), and feeds the feedback back through the skill: `refine` replays
open annotations as patches against a new run; `review-feedback` clusters
cross-customer feedback into reusable lessons and promotes mature ones into
the generator prompts. So a fix made once benefits every future onboarding.

## What's in the box

| Component | Where | What it does |
|---|---|---|
| `/base-agent` skill | `base-agent-setup/` | 11-stage onboarding orchestrator |
| `/onboard-customer` skill | `onboard-customer/` | Dashboard wiring after `/base-agent` |
| `/stress-test` skill | `voice-stress-test/` | Voice agent stress testing |
| Operator UI | `ui/web/` | Next.js app, deployed at `zero-onboarding.vercel.app` |
| Verify module | `base-agent-setup/server/verify.py` | 10 deterministic post-onboarding checks |
| Operator-UI server lib | `ui/server/` | Python helpers + 76 integration tests against the `operator_ui` schema |

## Quick start

Install: see [INSTALL.md](INSTALL.md). Path A (shared backend) takes <10 min
once you have keys.

Once installed, in Claude Code from any directory:

```
/base-agent
```

Browse runs in the operator UI: <https://zero-onboarding.vercel.app>.

## Sub-commands

- `/base-agent [customer-name]` — run or resume the 11-stage onboarding.
- `/base-agent refine [customer-slug]` — replay open annotations as per-run patches against a new run.
- `/base-agent review-feedback` — cluster cross-customer feedback into lessons; promote mature lessons into prompt files.
- `/base-agent verify [customer-slug]` — run 10 deterministic post-onboarding checks. Stage 11.5 runs it advisory after every onboarding.

See [`base-agent-setup/SKILL.md`](base-agent-setup/SKILL.md) for the full
stage-by-stage spec.

## Architecture

- **Operator UI** — Next.js (App Router) on Vercel. All reads + writes go
  through Supabase Auth (magic-link, two-email allowlist). RLS pins access
  to `kye@getspotfunnel.com` + `leo@getspotfunnel.com`; annotations are
  attributed to the JWT email. Hosted at `zero-onboarding.vercel.app`.
- **Skill** — local Bash + Python under Claude Code. Scripts live in
  `base-agent-setup/scripts/`.
- **State backend** — `operator_ui` schema in Supabase Postgres. When
  `USE_SUPABASE_BACKEND=1`, the skill writes runs/artifacts/state to Supabase
  via REST. When `0` (legacy), state lives in `runs/{slug}-{ts}/state.json`
  on disk. Annotations + feedback + lessons + verifications are always
  Supabase-resident.

See [`docs/plans/2026-04-26-operator-ui-design.md`](docs/plans/2026-04-26-operator-ui-design.md)
for the full design rationale and
[`docs/plans/2026-04-26-operator-ui-implementation.md`](docs/plans/2026-04-26-operator-ui-implementation.md)
for the milestone-by-milestone build plan.

## Tests

```bash
# Python — 76 integration tests against live Supabase + httpx mocks.
cd ui/server
pytest -v

# Playwright — e2e against the local Next.js dev server.
cd ui/web
npx playwright test --reporter=list

# Skill bash unit tests (state, refine, review-feedback, regenerate).
cd base-agent-setup/scripts/tests
bash test_state_sh.sh
```

`pytest` requires `SUPABASE_OPERATOR_URL` and `SUPABASE_OPERATOR_SERVICE_ROLE_KEY`
in your env — integration tests skip without them.

## Hard rules

See [CLAUDE.md](CLAUDE.md). Short version: safe full-PATCH for Ultravox
updates (never partial); never auto-buy DIDs; vendor-name hygiene in
customer-facing artifacts; examples-not-scripts in PROCEDURES.

## License

MIT. See [LICENSE](LICENSE).
