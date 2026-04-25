---
name: voice-stress-test
description: Set up and run stress tests against voice AI agents using constitutions (rule sets), simulated callers, and automated grading. Creates test scenarios, defines scoring rules, runs diagnosis, and generates actionable reports.
user_invocable: true
---

# Voice AI Stress Testing

Run simulated test calls against a voice AI agent, grade them against a constitution of rules, and generate reports explaining exactly what went wrong and how to fix it.

## When to use this skill

- `/stress-test` — Run a diagnosis against an agent
- `/stress-test init` — Set up a new stress testing system from scratch
- `/stress-test add-scenarios` — Add new test scenarios for an agent
- `/stress-test add-rules` — Add new rules to the constitution
- `/stress-test report` — Regenerate reports from cached results

## Where this fits in the pipeline

This skill is the third leg of the spotfunnel-voice-skills repo:

1. `/base-agent` — scrapes the customer's site, synthesises a brain-doc, creates a rough Ultravox agent (no tools yet), claims a DID, generates a discovery prompt for the customer to fill out.
2. `/onboard-customer` — wires a finished Ultravox agent into the dashboard backend (Supabase workspaces + auth + n8n + webhook).
3. `/stress-test` (this skill) — validates the finished agent against a constitution of rules **before it goes live**, and re-runs whenever you tune prompts or add tools.

The natural order is: `/base-agent` → operator does tool-design after the customer's brief comes back → `/onboard-customer` → `/stress-test` to confirm the agent behaves under load. You can also run `/stress-test` standalone against any existing Ultravox agent.

## How the system works

1. **Constitution** (config/constitution.js) — Rules the agent must follow. Two types: deterministic (checked by code) and LLM-judged (checked by Claude).
2. **Scenarios** (config/scenarios.js) — Fake callers with different personas, goals, and scripts.
3. **Diagnosis** (scripts/diagnose.js) — Orchestrates: create call → simulate caller → grade transcript → cluster violations → generate reports.
4. **Graders** — Four parallel graders: deterministic (code), LLM judge (Claude CLI), outcome (call-level), audio (pacing).
5. **Reports** — summary.md + per-violation markdown files with transcripts, analysis, and fix suggestions.

## Cost model

- **Simulated caller**: Claude Haiku API (~$0.01/call)
- **LLM judge**: Claude CLI (subscription, $0 API cost)
- **TTS**: OpenAI ($0.02/call, optional — text mode is free)
- **Agent minutes**: ~1 min per scenario on Ultravox
- **Deterministic grading**: Free (local code)

To minimize cost: use text mode (no TTS), use `--skip-tests` to regenerate reports from cache.

## Env resolution

The training infrastructure reads its own `.env` (Ultravox + Anthropic + optional OpenAI keys). Resolve it the same way the rest of the spotfunnel-voice-skills do — `$SPOTFUNNEL_SKILLS_ENV` → `<repo-root>/.env` → cached path at `~/.config/spotfunnel-skills/env-path`. Run this ONCE at the start of every invocation, before any `node` or `curl`:

```bash
# Resolve env file path: $SPOTFUNNEL_SKILLS_ENV → <repo-root>/.env → cached path → prompt
ENV_PATH=""
if [ -n "$SPOTFUNNEL_SKILLS_ENV" ] && [ -f "$SPOTFUNNEL_SKILLS_ENV" ]; then
  ENV_PATH="$SPOTFUNNEL_SKILLS_ENV"
elif [ -f "$(git rev-parse --show-toplevel 2>/dev/null)/.env" ]; then
  ENV_PATH="$(git rev-parse --show-toplevel)/.env"
elif [ -f "$HOME/.config/spotfunnel-skills/env-path" ] && [ -f "$(cat "$HOME/.config/spotfunnel-skills/env-path")" ]; then
  ENV_PATH="$(cat "$HOME/.config/spotfunnel-skills/env-path")"
fi

if [ -z "$ENV_PATH" ]; then
  echo "Cannot locate the spotfunnel-voice-skills .env file."
  echo "Set \$SPOTFUNNEL_SKILLS_ENV, place .env at the repo root, or paste an absolute path now."
  exit 1
fi

set -a
source "$ENV_PATH"
set +a
```

The training scripts only need a subset of the repo's `.env`:

- `ULTRAVOX_API_KEY` — to create test calls against the agent under test
- `ANTHROPIC_API_KEY` — for the simulated caller (Haiku)
- `OPENAI_API_KEY` — optional, only when running with TTS
- `STAGING_AGENT_ID` — usually passed inline on the command line, not in `.env`, so you can swap which agent you're testing

## Commands

### `/stress-test` — Run a diagnosis

Ask the operator:
1. Which agent to test (need the Ultravox agent ID)
2. Which constitution key to use (check config/constitution.js for available keys)
3. How many scenarios (or "all")

Then run:
```bash
STAGING_AGENT_ID={agent_id} node scripts/diagnose.js --agent {constitution_key}
```

This takes 3-5 minutes per scenario. Monitor progress with `tail -5` on the output file.

After completion, read `reports/summary.md` and present the results in plain English:
- Composite score
- How many passed
- Top violation clusters (what broke, how often, which scenarios)
- Dimension score averages

If the operator wants details on a specific violation, read `reports/{rule-id}.md`.

### `/stress-test init` — Set up from scratch

For a brand new project that doesn't have the testing infrastructure yet:

1. **Check prerequisites:**
   - Node.js installed
   - Claude CLI installed and working (`claude -p "hello"`)
   - Ultravox API key
   - Anthropic API key (for Haiku)

2. **Create the directory structure:**
   ```
   training/
     config/
       constitution.js
       scenarios.js
     graders/
       deterministic.js
       llm-judge.js
       outcome.js
       scoring.js
       audio.js
     callers/
       simulated-caller.js
       text-caller.js
     lib/
       claude.js
       ultravox-api.js
     scripts/
       diagnose.js
     reports/
     .env
     package.json
   ```

3. **Read the reference doc** at `training/docs/stress-testing-reference.md` for the full architecture and code patterns. If this file doesn't exist, look for a working reference implementation alongside your project's voice-AI agent code (the project that owns the Ultravox prompt versions and call traces) — the training harness usually lives next to the agent it tests.

4. **Start with the constitution.** Ask the operator:
   - What agent are they testing?
   - What are the hard rules? (sentence limits, word limits, banned phrases)
   - What are the soft rules? (tone, empathy, accuracy)
   - What dimensions should be scored?

5. **Then write scenarios.** Read the agent's prompt first. Ask the operator:
   - What types of callers does this agent handle?
   - What are the happy paths?
   - What are the objections/edge cases?
   - Write 8-15 scenarios covering the spread.

6. **Copy the graders and infrastructure** from the reference implementation. The graders are agent-agnostic — they work on any transcript against any constitution.

### `/stress-test add-scenarios` — Add new scenarios

1. Read the existing scenarios for the agent
2. Read the agent's prompt to understand what it does
3. Ask the operator what gaps they want to cover
4. Write new scenarios following the existing format
5. Add them to config/scenarios.js

### `/stress-test add-rules` — Add new rules

1. Read the existing constitution
2. Ask the operator what behavior they want to enforce or prevent
3. Determine if it's deterministic (can be checked by code) or LLM-judged (needs AI)
4. Add to the universal rules (if it applies to all agents) or agent-specific section
5. For deterministic rules, check that the grader supports the `check` type

### `/stress-test report` — Regenerate reports

Run without making new calls:
```bash
node scripts/diagnose.js --agent {key} --skip-tests
```

Useful after changing the constitution — re-grades cached transcripts with new rules.

## Writing good rules

**Be specific.** "Tone should be warm" is vague. "Tone must stay warm and steady regardless of caller mood. Frustrated callers get acknowledgement before problem-solving." is specific.

**Include exemptions.** "Never ask two questions in one turn (confirmation questions like 'Was that X?' are exempt)" prevents false positives.

**Describe what NOT to flag.** "Conversational reassurances like 'we'll get you sorted' are NOT violations" stops the judge from being overly strict.

**Use real examples in descriptions.** The LLM judge grades better when it has concrete examples of good and bad behavior.

## Writing good scenarios

**Use real caller archetypes.** Base them on actual calls your agent gets, not hypothetical edge cases.

**Make the callerScript natural.** It's the first thing the fake caller says. Write it like a real person talks, not a test script.

**callerBehavior guides the rest of the call.** After the first turn, Claude generates responses based on this field. Be specific: "Asks pointed questions, tests the agent's conversational ability, needs convincing" is better than "skeptical."

**failIf should be specific.** "Gets the price wrong" is better than "makes mistakes."

## Report style

Reports should be written in plain English. No jargon. Third-grade reading level. Spell out what went wrong with exact transcript quotes. Include what the agent SHOULD have said instead. These reports get handed to AI prompt editors who need clear, actionable instructions.

Bad: "The agent violated the knowledge-base-only rule with a fabricated integration claim."

Good: "The agent told the caller 'We integrate directly with ServiceM8.' The knowledge base never mentions ServiceM8. It made it up. It should have said 'I'm not sure about ServiceM8 specifically — our team can walk you through integrations in the consultation.'"
