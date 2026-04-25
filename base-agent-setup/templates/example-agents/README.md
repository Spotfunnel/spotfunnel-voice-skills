# example-agents — reference prompts for synthesis enrichment

This directory holds **complete, production-tuned voice-AI receptionist prompts** that the `/base-agent` synthesis stages read as INSPIRATION when authoring new customer agents.

The repo ships with four reference prompts so you don't start from a blank slate:

- **`teleca-steve.prompt.md`** — telco/trades receptionist, baseline tone
- **`teleca-hannah.prompt.md`** — concierge / scheduler companion to Steve
- **`telcoworks-jack.prompt.md`** — TelcoWorks reception, more transactional
- **`telcoworks-emma.prompt.md`** — TelcoWorks scheduling specialist

Drop in your own as you build them. The synthesis prompts scan this directory at runtime for `*.prompt.md` files — naming conventions are descriptive lowercase-hyphenated, but the skill only cares that the files exist and are valid prompts.

Each prompt also has a paired tool-definition file:

- **`teleca-steve.tools.json`**
- **`teleca-hannah.tools.json`**
- **`telcoworks-jack.tools.json`**
- **`telcoworks-emma.tools.json`**

These are **supplementary references for the future post-brief tool-design step** — the part of the per-customer flow where, after the customer's discovery brief comes back, you (or a follow-on skill) sit down and design the `transferToHuman`, `bookAppointment`, `lookupKnowledge`, etc. tools the agent actually needs. The four examples here show **what well-built voice-AI agent tools look like in production**: parameter shapes, descriptions tuned for an LLM caller, dynamic-parameter behaviour, and how transfer / hangup / messaging tools are typically wired.

> **Important — Stages 3 and 4 do NOT read these tool defs.** The rough agent created by `/base-agent` is intentionally tools-free. That's by design: tools depend on the customer's own answers in the discovery brief (which staff to transfer to, which hours, which booking platform, which CRM), so they cannot be authored before the brief comes back. The synthesis prompts at Stage 3 (`synthesize-brain-doc.md`) and Stage 4 (`assemble-rough-system-prompt.md`) only consult the `*.prompt.md` files in this directory for behavioural and structural inspiration. The `.tools.json` files sit alongside as reference material for whatever skill or process designs tools after the brief comes back.

---

## How synthesis uses them

Two stages of `/base-agent` consult this directory:

1. **Stage 3 — `prompts/synthesize-brain-doc.md`** reads any `*.prompt.md` files here for **structural and behavioural inspiration**: what business-context details to extract, how to phrase tone markers, what kind of operational nuance shows up in real receptionist behaviour worth capturing in the brain-doc.

2. **Stage 4 — `prompts/assemble-rough-system-prompt.md`** runs an **optional enrichment pass** before its concatenation. It scans the examples for behavioural patterns (caller scenarios, transfer phrasings, hold messages, decline patterns, common-situation handlers) and expands underdeveloped areas of the brain-doc inline before the four-section assembly.

In both cases the examples teach the synthesis **"what good looks like"** — depth and structure, not facts. **No specific data from these reference prompts is copied into a new customer's artefacts** — not phone numbers, addresses, staff names, business hours, internal SLAs, or transfer numbers. The hard rule in both synthesis prompts: source facts only from the customer's own website + meeting + operator hints.

If this directory is empty (or contains only this README), both stages skip the example-driven enrichment and proceed normally with universal-rules + brain-doc alone.

---

## What's safe to add

These files are **public on GitHub** along with the rest of the repo. Before adding new files, check that:

- Customer transfer numbers, staff names, addresses, internal escalation rules, and pricing details that you wouldn't post publicly elsewhere don't go in.
- If you want a tuned prompt as a reference but it contains sensitive specifics, **sanitise first**: replace real numbers with `[OWNER_PHONE]`, real names with `[STAFF_NAME]`, real addresses with `[ADDRESS]`, etc. The structural and behavioural value of the prompt survives the sanitisation; the customer-confidential bits don't.

The four reference prompts that ship with this repo are committed deliberately as working examples. If you fork the repo, you inherit them — and you can add or sanitise as fits your context.

---

## Naming convention

`<vertical-or-pattern>.prompt.md` — descriptive, lowercase-hyphenated, ending in `.prompt.md`.

Good:
- `dental-clinic-reception.prompt.md`
- `plumbing-after-hours.prompt.md`
- `b2b-sales-frontline.prompt.md`

The synthesis prompts use a simple glob (`*.prompt.md`) — anything matching gets read. Anything not matching (`.md`, `.json`, `.txt`) is ignored.

---

## Removing or rotating examples

Just delete or rename the file (drop the `.prompt.md` suffix to hide without deleting). The synthesis stages re-scan on every run.
