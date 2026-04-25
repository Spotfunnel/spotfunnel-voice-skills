---
name: base-agent-setup
description: Automates voice-AI customer onboarding end-to-end. Invoked as /base-agent or /base-agent [customer]. Scrapes the customer's website, synthesizes a knowledge-base brain doc from site + meeting transcript + operator hints, creates a rough Ultravox agent (no tools, no call flows yet) with voice/temperature/inactivity settings copied from a configured reference agent, claims a Telnyx DID from the operator's pool and wires TeXML + telephony_xml, generates a bespoke ChatGPT-ready discovery prompt the customer pastes into ChatGPT to write a detailed brief back, then hands off to /onboard-customer for dashboard wiring. Resumable across crashes via per-run state files. Use when the operator says "/base-agent", "onboard [name] from scratch", "new customer base agent", or starts the post-meeting onboarding flow.
user_invocable: true
---

# base-agent-setup

> **For Claude:** This skill orchestrates 11 stages, each writing to `runs/{slug}-{timestamp}/state.json` on completion. Re-invocation with the same slug resumes from the last successful stage.

## Runtime notes (Windows + Git Bash gotchas)

- Every `curl` needs `--ssl-no-revoke` on Windows — SChannel CRL checks fail intermittently against Supabase, Ultravox, and others.
- `jq` is not installed on the typical Git Bash setup. Use Python3 with stdin JSON parsing for any structured output transformation.
- `/tmp/` paths in Git Bash do not map to a Windows path Python can read. For any file handed from `curl` to a Python helper, use a Windows-style absolute path like `c:/Users/<you>/.tmp-spotfunnel-skills/...` and `rm -rf` when done.
- Skill scripts source `.env` from the operator's repo root (resolved via `$SPOTFUNNEL_SKILLS_ENV` → `<repo-root>/.env` → cached path). See [ENV_SETUP.md](ENV_SETUP.md).

## Stage 0 — Env preflight

## Stage 1 — Gather inputs

## Stage 2 — Firecrawl scrape (async)

## Stage 3 — Brain-doc synthesis (Claude inline)

## Stage 4 — Rough system prompt generation (Claude inline)

## Stage 5 — Reference agent settings pull

## Stage 6 — Create Ultravox agent

## Stage 7 — Claim Telnyx DID from pool

## Stage 8 — TeXML app wiring

## Stage 9 — TeXML → Ultravox telephony_xml

## Stage 10 — Per-customer discovery prompt (Claude inline)

## Stage 11 — Hand off to /onboard-customer

## Idempotency & failure handling

## What this skill does NOT do

## Commands
