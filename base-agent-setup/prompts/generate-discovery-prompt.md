# Discovery-prompt generator

> **Audience:** you, reading this at Stage 10 of the `/base-agent` skill.
>
> **Job:** read four inputs and produce two output files — a bespoke ChatGPT discovery prompt and a cover-email the operator forwards to the customer. Both files end up in front of a customer, so language hygiene matters.

---

## What you have

Four inputs, in this order of authority for the customer-facing content:

1. **The meeting transcript** — verbatim text of the operator's recorded conversation with the customer. Already in your conversation state from Stage 1. This is the **primary source of truth for scope** and the most important input.
2. **The brain-doc** at `{run-dir}/brain-doc.md` — produced at Stage 3, structured factual summary of the business with source tags.
3. **The operator hints** — one freeform paragraph captured at Stage 1.
4. **The discovery methodology reference doc** at `base-agent-setup/reference-docs/discovery-methodology.md` — stable cross-customer methodology that the generated prompt embeds verbatim so the customer's ChatGPT conversation is governed by it.

You will read the methodology doc in full and embed its body inside the generated discovery prompt. You do not summarise or paraphrase it — paste it.

---

## What you produce

Two files. Both go in `{run-dir}/`:

1. **`discovery-prompt.md`** — a single copy-pasteable text block the customer drops into a fresh ChatGPT conversation as their first message. May be the whole prompt, or a short prompt that pairs with an attached context file (see "Sizing logic" below).
2. **`cover-email.md`** — populated from `templates/cover-email.md`. Short note from the operator that frames the discovery prompt and tells the customer how to use it. The discovery-prompt content is substituted into the template at the `{{DISCOVERY_PROMPT}}` placeholder.

When the two-file path triggers (see Sizing logic), there is also a third output:

3. **`customer-context.md`** — methodology (verbatim) + brain-doc + meeting transcript + operator hints packaged as an attachment. The cover email points at it. On the two-file path the methodology lives here, NOT in `discovery-prompt.md`.

---

## Inputs you also need from skill state

Pull these from `state.json` or the conversation:

- `customer_name` — full business/trading name.
- `customer_first_name` — the primary contact's first name (the person the cover email is addressed to). If only one name is on file, use that.
- `operator_first_name` — the operator's first name (the cover email is signed by them).
- `agent_first_name` — the agent's chosen first name (e.g. "Steve", "Emma"). Used for natural reference in the prompt where appropriate.

If any of these are missing, halt and ask the operator before generating — these are load-bearing for the customer-facing tone.

---

## Sizing logic — LOAD-BEARING

ChatGPT's free-tier per-message paste reliably handles around 30,000 characters. Long meeting transcripts plus a rich brain-doc plus the embedded methodology can push the combined prompt over that. The skill auto-routes based on size:

### Step 1 — measure

Compute the **total combined character count** of:

- The methodology body (read from the reference doc, pasted verbatim).
- The brain-doc body.
- The full meeting transcript.
- The operator hints paragraph.
- The framing prose you write yourself (opener, scope statement, output schema reminder, the bespoke first question).

Round to nearest 500 chars.

### Step 2 — route

- **Combined size ≤ 25,000 characters → ONE-FILE PATH.**
  Emit a single `discovery-prompt.md` that contains everything: methodology + bespoke opener + brain-doc summary + transcript + operator hints + output schema. The customer pastes it once into ChatGPT and the conversation begins. **Hard cap on `discovery-prompt.md` in single-file mode: 25,000 characters.**

- **Combined size > 25,000 characters → TWO-FILE PATH.**
  In two-file mode the methodology body is **too large to live inline** — it has to move into the attached context file alongside the per-customer ground truth. Otherwise the discovery-prompt itself blows past any reasonable paste cap.

  Emit two files:
  - `discovery-prompt.md` — short, paste-friendly. Contents: framing line + bespoke opener (one question only — see element 4 below) + scope statement + known-vs-unknown map + output-schema reminder + a one-line pointer telling ChatGPT to read the methodology and per-customer context in the attached `customer-context.md` file. **NO methodology body inline. NO transcript inline. NO brain-doc inline.** This file must come in **under 10,000 characters**, hard cap.
  - `customer-context.md` — methodology body (verbatim) + brain-doc body (post-sanitization, see "Sanitization rules" below) + meeting transcript verbatim (post-sanitization, see below) + operator hints (post-sanitization, see below), with brief framing headings: `# Methodology` (the verbatim discovery-methodology body), `# Business summary` (brain-doc), `# Meeting transcript`, `# Operator notes`. Methodology comes first in this file because ChatGPT needs to ingest it before it does anything else with the per-customer context.

  The customer pastes `discovery-prompt.md` as their first message and drag-drops the literal `customer-context.md` file as an attachment to that same message.

**Routing rule, stated explicitly:** if methodology + brain-doc + transcript + operator hints + framing prose ≤ 25K total → single-file (methodology stays inline). Else → two-file with methodology in the attachment. The methodology never lives inline in `discovery-prompt.md` on the two-file path.

The cover email handles both paths automatically — it tells the customer "if you see two parts below, paste the prompt and attach the context file."

### Step 3 — record the path

In `state.json` write `discovery_prompt.size_path: "one-file"` or `"two-file"` and the measured character count, so downstream stages and the operator's terminal output know which path was taken.

---

## What the generated discovery prompt must contain

Whether one-file or two-file, the discovery prompt itself (the part the customer pastes as their first message) must contain these elements, in roughly this order. Write each element as natural prose addressed to ChatGPT — not as headed sections — so it reads as a single coherent instruction block.

### 1. Framing line

One sentence that tells ChatGPT what this conversation is and who it's talking to. **Path-specific shape:**

- **One-file path** — instruct ChatGPT to read the inline material below before responding:

  > "You are about to interview {customer_first_name} from {customer_name} to produce a brief for the voice agent we're building for their business. Read everything below carefully before you respond."

- **Two-file path** — keep the framing line strictly identity-only. Do **NOT** also tell ChatGPT to read the attached file here — that instruction belongs exclusively in element 2 (the methodology pointer). Issuing the read-the-attachment instruction twice (once in the framing line and again in the pointer line directly below it) is a regression that flags as redundancy in the customer-facing output.

  > "You are about to interview {customer_first_name} from {customer_name} to produce a brief for the voice agent we're building for their business."

  No "read the attached context file" addendum here on the two-file path. Element 2 owns that instruction.

**Hard rule (two-file path):** the framing line is exactly one sentence and contains zero references to the attachment. Re-read your draft after writing — if the framing line and the line below it both say something like "read the attachment", strip the framing-line copy.

### 2. The methodology

**One-file path:** paste the full body of `base-agent-setup/reference-docs/discovery-methodology.md` verbatim into `discovery-prompt.md`. Do not edit, summarise, reorder, or strip sections. Bracket the methodology content with a clear opening line and closing line so ChatGPT can parse it as one block:

> "**The methodology you must follow is below. Read it in full before you ask the customer anything.**"
>
> [...full methodology body...]
>
> "**End of methodology. Below this line is the per-customer context for this specific interview.**"

**Two-file path:** the methodology body does **not** appear inline in `discovery-prompt.md`. It moves to the attached `customer-context.md` (under a `# Methodology` heading at the top of that file). In `discovery-prompt.md` itself, replace the inline methodology block with a single pointer line that **names the attachment by literal filename** AND tells the customer how to attach it:

> "**Before you respond, read the attached `customer-context.md` file in full. (If you haven't attached it yet: drag and drop the `customer-context.md` file into this same ChatGPT message before sending — it lives alongside this prompt in the email I sent you.) The first section is the methodology you must follow for this interview — it is non-negotiable. The remaining sections are the per-customer ground truth (business summary, meeting notes, operator notes). Treat all of it as ground truth and do not re-ask anything covered in it.**"

This pointer is the only methodology-related content in `discovery-prompt.md` on the two-file path. The methodology body lives once, in the attachment, never duplicated inline. This is what keeps `discovery-prompt.md` under its 10K cap.

**Hard rule (filename literality):** the pointer line must contain the literal string `customer-context.md` (with the `.md` extension, in backticks or plain — but spelled exactly). If you draft the pointer with vague phrasing like "the attached context file" or "the attached file" without naming `customer-context.md`, the customer pastes the prompt into ChatGPT with no idea what file to drag-drop. **Mechanical check before writing:** grep your draft of `discovery-prompt.md` for the exact string `customer-context.md`. If it doesn't appear at least once, the prompt fails this rule. Rewrite the pointer to include it.

**Hard rule (drag-drop instruction):** the pointer line (or an adjacent sentence in the same paragraph) must explicitly tell the customer how to attach the file — phrase it as "drag and drop `customer-context.md` into this same ChatGPT message before sending" or equivalent. Customers paste this prompt into ChatGPT cold. If the prompt doesn't tell them to attach the file, they won't.

### 3. Per-customer ground truth (one-file path) OR pointer to context file (two-file path)

**One-file path:** embed the brain-doc body and the meeting transcript inline, with brief framing for each:

> "**Here is what we already know about {customer_name} from their public website and our recent conversation. Treat this as ground truth — do not re-ask anything covered here.**
>
> **Business summary:**
>
> [...brain-doc body...]
>
> **The meeting we had was as follows. Cite from it when you follow up with the customer (per principle 3 of the methodology):**
>
> [...full meeting transcript verbatim...]
>
> **Notes from the operator about anything that didn't make the meeting:**
>
> [...operator hints paragraph...]"

**Two-file path:** the inline brain-doc + transcript + hints content does NOT appear here either — it's all in the attachment, after the methodology section. The pointer-line you wrote at element 2 already covers this; you don't duplicate it. Move on to element 4 (the bespoke opener).

### 4. The bespoke first question — REQUIRED, NOT OPTIONAL — exactly ONE question

This is the single highest-value piece of bespoke content you generate. It is **not** generic. It must reference an actual phrase, decision, concern, or topic the customer raised in the meeting.

**Hard rule: exactly ONE question.** The bespoke opener fires a single question and stops. Do not compound questions, even with "first... second..." or "and also..." framing. Do not stack a scope-confirmation question on top of a coverage question. Do not ask "is that the scope, and what's your priority for the next 30 days?" — that's two questions. Defer the second question to the next message; ChatGPT will get there once the customer answers the first one. This rule comes from methodology §3 ("one question at a time"); the opener is bound by it like every other turn in the conversation.

Read the meeting transcript. Find the moment that most clearly captures the *scope* the customer wants for this agent. Quote a short phrase or paraphrase a specific concrete detail back at them. Anchor your first question in that specific moment.

Examples of the right shape (these are illustrative — yours will be different and customer-specific):

- *"You said in our call that you don't want a full receptionist — Karen handles that during the day, and what you actually want is just for the Google Ads number to be answered after hours and book new patients into your Cliniko diary. Before I dig in, let me reflect that back: this agent's only job is the after-hours overflow on the Ads line, qualifying new-patient inquiries and booking them in. Anything outside that — existing patients, massage queries, sales calls — gets a polite handoff and the call ends. Is that the scope you want, or should I broaden it?"*

- *"You mentioned Mondays are insane — 80 calls before 1pm — and that the worst calls today are the ones where someone's put on hold for two minutes and they hang up. That second one tells me something specific about how you want this agent to behave. Before we dig in, let me anchor: the agent's job is to pick up everything across all hours and never park anyone on hold; daytime it supports Megan when she's flooded, after-hours it's the only line, and it routes clinical follow-ups to the right dentist. That match how you see it, or should I tighten it somewhere?"*

The pattern: short paraphrase of a real meeting detail → reflection of inferred scope → explicit "is this the scope?" ask. Per methodology §8 "Phase 1," every interview opens with scope confirmation, not a coverage-target question.

If the meeting is so short or vague that you genuinely cannot find a specific phrase to anchor on, write the opener around the *clearest signal* the meeting did contain (e.g. the type of business the customer mentioned wanting help with, or the specific tool they named) — but never default to a generic "tell me about your business" opener. The customer's already had the meeting. They expect the conversation to start informed.

### 5. Known-vs-unknown map

A short paragraph that names what's already settled (so ChatGPT doesn't waste a question on it) and what's still open (so it knows where to drill). Draw the "known" side from the brain-doc and meeting; draw the "unknown" side from the methodology coverage targets minus what was already covered.

Example shape:

> "**Already settled — do not re-ask:** business hours, services offered, staff names, address, the agent's general scope (per the meeting), the existing booking system, the brand voice in broad strokes.
>
> **Still to nail down with the customer:** [list of items pulled from coverage A–F that are in scope but not yet answered]."

This map is for ChatGPT's benefit. It enforces the methodology's "never re-ask" principle (principle 2) by making the already-answered items explicit up front.

### 6. Output schema reminder

A short pointer back to methodology §6 (the brief output schema):

> "**When the interview wraps, produce the brief in the format laid out in section 6 of the methodology — sections A through F as plain markdown, between the literal `--- COPY EVERYTHING BELOW INTO YOUR EMAIL ---` and `--- END OF BRIEF ---` separators. Sections that fell outside the scope inferred at the start may be a one-line "out of scope" note or omitted entirely. Do not pad."**

You don't repeat the full schema — it's already inside the methodology body you pasted at element 2. This element is just a reminder so ChatGPT lands the output cleanly.

### 7. Conversational tone instruction

A final sentence telling ChatGPT how to begin:

> "Start the conversation with the bespoke first question above. Wait for {customer_first_name}'s reply. One question at a time. Acknowledge before moving on. Match {customer_first_name}'s energy — if they're terse, be terse; if they're chatty, be chatty."

---

## What the generated cover email must contain

The cover email is produced from `templates/cover-email.md` with substitutions:

- `{customer_first_name}` → the customer's first name.
- `{operator_first_name}` → the operator's first name.
- `{{DISCOVERY_PROMPT}}` → the **full body** of `discovery-prompt.md` you produced above, pasted verbatim. (Yes — duplicating it inside the email is intentional. The operator forwards the email to the customer; the customer pastes from inside the email body.)
- `{{CUSTOMER_CONTEXT_FILE_PATH}}` (two-file path only) → the absolute path to `customer-context.md` in `{run-dir}`, plus the literal filename so the operator knows what to attach.

If the one-file path was taken, **omit** the `--- ATTACH THIS FILE ALONGSIDE YOUR MESSAGE ---` block from the cover email entirely. The template includes that block conditionally — you only emit it on the two-file path.

The cover email's job is to make the operator's forwarding step zero-friction. They open `cover-email.md`, paste it into a fresh email to the customer (subject line included), attach the context file if one exists, and send. No editing on the operator's side.

---

## Vendor and platform name hygiene — STRICT

The discovery prompt and the cover email both end up in front of the customer. Neither file may name the infrastructure we use to build their agent. The customer doesn't need to know what platform their voice agent runs on, what we use for telephony, what we use for transcription, what we use for orchestration, what we use for email, what we use for scraping, or that the AI authoring this prompt is anything in particular.

**Do not include in either output file:**

- The names of any external vendors, infrastructure providers, or platform tools we use internally to build the agent.
- The names of any AI models or labs.
- The fact that the prompt was authored by an AI at all (the customer doesn't need to know this).
- Any internal codenames, project names, or repo names.

You CAN mention "ChatGPT" inside both files — that's the platform the customer themselves will use, and the cover email needs to give the customer concrete instructions ("paste this into ChatGPT"). ChatGPT is named in the customer-facing surface by necessity.

The methodology body, when you paste it into the prompt, is already vendor-clean by construction. The brain-doc, when you paste it into the prompt, is also vendor-clean by construction (the brain-doc generator is governed by its own hygiene rules upstream). The places vendor names could leak in are: framing prose you write yourself, the bespoke first question, the operator-hints paragraph, and the cover email body.

**Before writing either file**, scan your draft for vendor names by mental grep. If anything matches, rewrite the line to drop the name. The rule is **omission**, not disclosure — never write "we use X internally but please ignore that"; just don't name X.

If the operator hints paragraph contains a vendor name (operators sometimes write naturally), strip it from the embedded copy in the prompt. Paraphrase the substance without naming the tool.

---

## Sanitization rules — STRICT

The customer reads `customer-context.md` as a clean, professional packet of context for an interview. It must not surface operator-test-harness scaffolding, internal stage numbers, or any meta-commentary about the skill that produced it. The two places this leakage typically happens are the meeting-transcript block and the operator-hints block. Both get sanitized BEFORE they're written into `customer-context.md`.

### Rule 1 — Meeting-transcript sanitization

When the meeting transcript file is the canonical "no meeting" placeholder — recognise this when the file body matches any of:

- contains literal phrases like `[NO MEETING TRANSCRIPT`, `forced-broad-scope`, `Stage 11`, `stress-test`, `End-to-end test run`, `Forced-broad-scope`, `test of the skill`, `the discovery prompt itself becomes the artifact`
- is empty or under ~200 characters of meaningful content
- otherwise reads as operator scaffolding rather than verbatim dialogue

then the **embedded transcript section** in `customer-context.md` must read as a clean, professional "no meeting transcript yet" stub. The customer should never see the words "Stage 11", "stress-testing", "forced-broad-scope", "test of the skill", or any other operator-meta language in this section.

**Replacement copy** (use verbatim or close to it):

```
# Meeting transcript

_No meeting transcript was recorded for this customer ahead of the discovery interview. The interview itself fills this gap — work through the methodology's coverage targets in full and produce the brief from the customer's answers plus the business summary above._
```

Drop the entire raw placeholder block. Do not preserve "for completeness" or "in case it's useful". The customer never benefits from seeing operator scaffolding.

If the transcript IS a real meeting transcript (not a placeholder — actual dialogue between operator and customer), embed it verbatim under the heading. No sanitization on real transcripts.

### Rule 2 — Operator-hint sanitization

Operator hints are written by the operator for the operator's downstream tools. They sometimes contain test-harness language: "End-to-end test run", "stress-testing the pipeline", "Stage 11", "Stage X", "Forced-broad-scope", "test of the skill", references to internal stages or the dashboard onboarding stages, etc. None of that belongs in the customer-facing `customer-context.md`.

**Procedure for sanitizing operator hints:**

1. Read the operator-hints paragraph as it appears in skill state.
2. Scan for test-harness terminology. The forbidden substring set is at minimum: `Stage 1`, `Stage 2`, `Stage 3`, `Stage 4`, `Stage 5`, `Stage 6`, `Stage 7`, `Stage 8`, `Stage 9`, `Stage 10`, `Stage 11`, `Stage 12`, `Stage 13`, `End-to-end test`, `End to end test`, `e2e test`, `stress-test`, `stress test`, `stress-testing`, `forced-broad-scope`, `forced broad scope`, `test run`, `test of the skill`, `the pipeline`, `dashboard onboarding` (when used as scaffolding rather than describing the customer).
3. **Strip every sentence that contains a forbidden substring** from the embedded hints.
4. If anything substantive remains (e.g. "Agent name vertical-appropriate for a Melbourne-based law firm" — that's a real instruction even though it sat alongside test-harness language), **rewrite it as a clean operator note** addressed to ChatGPT. Drop the test-harness framing; keep only the substantive guidance, rephrased as if the operator was writing fresh notes about a real customer. Example: from `"End-to-end test run with Stage 11. Forced-broad-scope. Agent name vertical-appropriate for a Melbourne-based law firm. We're stress-testing the full pipeline including dashboard onboarding."` keep only `"Agent name should be vertical-appropriate for a Melbourne-based law firm."` — and only if that's actually new info not already in the brain-doc.
5. **If the entire hints paragraph is test-harness with no real substantive content** (or the only substantive content is already in the brain-doc), replace the whole `# Operator notes` block body with the literal string `_(no operator notes)_`. Do not invent operator content; do not pad.

**Mechanical check before writing `customer-context.md`:** grep the assembled `customer-context.md` body for each forbidden substring listed above. If any match, your sanitization didn't catch it — fix and re-grep until the file is clean.

### Rule 3 — Brain-doc body sanitization on copy-in

The brain-doc itself is a 9/9/9 artifact and must not be modified at its source path. However, when the brain-doc body is **copied into `customer-context.md` under the `# Business summary` heading**, the same forbidden-substring grep applies. If the brain-doc happens to contain a `## Notable from Meeting` subsection (or similar) that absorbed test-harness operator hints upstream, sanitize that subsection in the COPY only — do NOT modify the source brain-doc.md file.

**Specifically:** when copying brain-doc body into `customer-context.md`, scan each section heading and bullet for the forbidden-substring set above. For any line that matches:

- If the line is inside a `## Notable from Meeting` (or equivalent merge-of-meeting-and-hints) subsection, drop the line in the copy. If the subsection ends up empty after stripping, replace its body with `_(no meeting notes)_` (or omit the subsection entirely if the brain-doc structure permits it cleanly).
- If the line appears elsewhere in the brain-doc, that's an upstream brain-doc bug — flag it in the operator's terminal output but proceed with the copy stripped of the offending line.

The source brain-doc.md is not edited. Only the inline copy in `customer-context.md` is sanitized.

### Sanitization summary

After sanitization, `customer-context.md` should contain ZERO occurrences of: `Stage 11`, `stress-test` (any form), `End-to-end test`, `forced-broad-scope`, `test of the skill`, or any other operator-meta scaffolding. The customer reads it and sees a clean methodology + business summary + meeting note + operator note packet, with no leak of how it was assembled.

---

## Final checks before writing

Before you write either file, run this checklist:

1. **Sizing decision logged.** You computed the total combined character count, you picked one-file or two-file path, and you wrote the decision into `state.json`.
2. **Methodology placement correct for the path.**
   - One-file path: methodology body pasted verbatim into `discovery-prompt.md`, bracketed by the opening/closing methodology markers.
   - Two-file path: methodology body pasted verbatim into `customer-context.md` under a `# Methodology` heading at the top of that file. `discovery-prompt.md` contains a one-line pointer to the attachment, NOT the methodology body.
3. **Bespoke opener references a specific meeting detail.** Not generic. Not "tell me about your business." Pulled from a real phrase or topic in the transcript. **Exactly ONE question** — no compound openers, no "and also" stacking, no "first... second..." double-asks. Re-read your opener; if it contains more than one question mark or more than one distinct ask, rewrite it.
4. **Known-vs-unknown map present** and accurately reflects what the brain-doc + meeting already cover.
5. **No vendor names** in either output file. No model names. No infrastructure names. No internal codenames.
6. **Cover email substitutions all resolved.** No literal `{customer_first_name}`, `{operator_first_name}`, `{{DISCOVERY_PROMPT}}`, or `{{CUSTOMER_CONTEXT_FILE_PATH}}` left in the email.
7. **Two-file path only:** `customer-context.md` exists at `{run-dir}/customer-context.md`, contains methodology (first) + brain-doc + transcript + operator hints with brief framing headings, and is referenced by absolute path in the cover email.
8. **One-file path only:** the `--- ATTACH THIS FILE ALONGSIDE YOUR MESSAGE ---` block is omitted from the cover email.
9. **Discovery-prompt size caps.**
   - One-file path: `discovery-prompt.md` is under 25,000 characters. If it isn't, the routing should have been two-file — re-route.
   - Two-file path: `discovery-prompt.md` is under 10,000 characters. Hard cap. If it isn't, your framing prose is too verbose or methodology has accidentally been inlined — strip until it fits. The methodology body must be in the attachment, not the prompt.
10. **No "read the attachment" redundancy (two-file path).** On the two-file path, the instruction telling ChatGPT to read the attached context file appears **exactly once** — in element 2 (the methodology pointer line). It does **NOT** also appear in element 1 (the framing line). Mechanical check: count occurrences of any phrase like "read the attached context file", "read the attachment", "read the attached file", "read everything below … and the attached" inside `discovery-prompt.md`. If the count is greater than 1, strip the framing-line copy and keep the pointer-line copy. The framing line is identity-only on the two-file path.
11. **Attachment named by literal filename (two-file path).** Grep `discovery-prompt.md` for the literal string `customer-context.md`. It must appear at least once. If it doesn't, the customer pasting this into ChatGPT has no idea what file to drag-drop. Rewrite the pointer line until the filename is literal.
12. **Drag-drop instruction present (two-file path).** Grep `discovery-prompt.md` for any of: "drag and drop", "drag-and-drop", "drag-drop", "attach", "drop the file" (case-insensitive). At least one must match, AND it must be in a sentence that gives the customer the action to take. A passive "the attached file" alone does NOT satisfy this — there has to be an explicit instruction to attach.
13. **Sanitization checks on `customer-context.md` (two-file path).** Grep the assembled `customer-context.md` body for each of: `Stage 1` through `Stage 13`, `End-to-end test`, `stress-test` (any form), `forced-broad-scope`, `test of the skill`, `test run`, `the pipeline`. Match count must be **zero**. If any match, your transcript-block or operator-hints sanitization missed it — re-sanitize and re-grep.

Write the files and stop. Stage 10 reports the path taken, the file sizes, and the absolute paths to the operator's terminal.
