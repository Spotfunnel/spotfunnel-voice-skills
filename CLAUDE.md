# Working in this repo — instructions for Claude

## Writing style

Plain language. Few words. Concise.

- Sentences over paragraphs. Bullets over sentences when listing.
- Cut filler. No "before we dig in", "let me reflect that back", "I want to anchor", "tell me:" preambles. Get to the point.
- If the same thing can be said in 10 words instead of 40, use 10.
- Applies to: chat responses, generated prompts (synthesize-brain-doc, assemble-rough-system-prompt, generate-discovery-prompt), templates, docs, commit messages.
- Customer-facing artifacts (discovery prompt, brain-doc, system prompt PROCEDURES) follow the same rule.

## Hard rules

- **When updating a live Ultravox agent, always include ALL settings in the PATCH body.** Ultravox PATCH semantics revert any field not explicitly included to the API default — silently wipes voice/temp/inactivity/tools. The safe procedure: GET the agent, copy every field forward, modify only the field you intend to change, then PATCH the complete body. The script `scripts/regenerate-agent.sh [slug]` does this safely. Never construct a partial PATCH manually.
- **Never auto-buy Telnyx DIDs.** Pool-low alerts only. Manual purchase by the operator.
- **Vendor-name hygiene** in customer-facing artifacts: no Ultravox / Telnyx / Supabase / n8n / Resend / Railway / Firecrawl / Anthropic / Claude / Opus / Haiku. ChatGPT is fine (the customer's platform).
- **No facts borrowed from `templates/example-agents/`** into a new customer's brain-doc or system prompt. Examples inform STRUCTURE only.
- **Examples not scripts** in the system prompt PROCEDURES section. Numbered call-flow trees = bad. Scenario-grouped exemplars + principles = good.

## Skill flow

11 stages, all in `base-agent-setup/SKILL.md`. Stage 11.5 runs verify advisory after every onboarding. Resumable via `runs/{slug}-{ts}/state.json` (legacy) or `operator_ui.runs` row (when `USE_SUPABASE_BACKEND=1`).

Sub-commands:

- `/base-agent refine [slug]` — replays open annotations as patches against a new run. See SKILL.md.
- `/base-agent review-feedback` — clusters cross-customer feedback into lessons, then promotes mature lessons into generator prompts. See SKILL.md.
- `/base-agent verify [slug]` — runs 10 deterministic checks (`+ --include-call` for an 11th programmatic test call).

## State backend

`USE_SUPABASE_BACKEND=1` (default for Path A) — runs + artifacts + state mirror to `operator_ui` in Supabase via REST. The operator UI reads from there. `=0` keeps everything local under `runs/{slug}-{ts}/` (legacy; the UI won't see your runs).

Annotations + feedback + lessons + verifications are always Supabase-resident regardless of the flag.

## Testing

```bash
# Python — 76 integration tests (Supabase + httpx mocks). Skips if SUPABASE_OPERATOR_* unset.
cd ui/server && pytest -v

# Playwright — e2e against the local Next.js dev server.
cd ui/web && npx playwright test --reporter=list

# Skill bash unit tests.
cd base-agent-setup/scripts/tests && bash test_state_sh.sh
```

Three Playwright specs are documented as flaky on the synthetic-event drag-select path; they pass on retry. Treat a clean exit as green.
