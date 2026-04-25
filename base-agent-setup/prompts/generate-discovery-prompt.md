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

3. **`customer-context.md`** — brain-doc + meeting transcript packaged as an attachment. The cover email points at it.

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
  Emit a single `discovery-prompt.md` that contains everything: methodology + bespoke opener + brain-doc summary + transcript + operator hints + output schema. The customer pastes it once into ChatGPT and the conversation begins.

- **Combined size > 25,000 characters → TWO-FILE PATH.**
  Emit two files:
  - `discovery-prompt.md` — methodology + bespoke opener + scope statement + a short instruction that says *"a context file with our meeting and your business summary is attached to this message; treat it as ground truth and don't re-ask anything covered in it."* This file must come in **under 10,000 characters** so the customer can paste it cleanly even on a free tier.
  - `customer-context.md` — brain-doc body + meeting transcript verbatim + operator hints, with brief framing headings (`# Business summary`, `# Meeting transcript`, `# Operator notes`). No methodology, no opener — just the context.

  The customer pastes `discovery-prompt.md` as their first message and drag-drops `customer-context.md` as an attachment to that same message.

The cover email handles both paths automatically — it tells the customer "if you see two parts below, paste the prompt and attach the context file."

### Step 3 — record the path

In `state.json` write `discovery_prompt.size_path: "one-file"` or `"two-file"` and the measured character count, so downstream stages and the operator's terminal output know which path was taken.

---

## What the generated discovery prompt must contain

Whether one-file or two-file, the discovery prompt itself (the part the customer pastes as their first message) must contain these elements, in roughly this order. Write each element as natural prose addressed to ChatGPT — not as headed sections — so it reads as a single coherent instruction block.

### 1. Framing line

One sentence that tells ChatGPT what this conversation is and who it's talking to. Example shape:

> "You are about to interview {customer_first_name} from {customer_name} to produce a brief for the voice agent we're building for their business. Read everything below carefully before you respond."

### 2. The methodology

Paste the full body of `base-agent-setup/reference-docs/discovery-methodology.md` verbatim. Do not edit, summarise, reorder, or strip sections. Bracket the methodology content with a clear opening line and closing line so ChatGPT can parse it as one block:

> "**The methodology you must follow is below. Read it in full before you ask the customer anything.**"
>
> [...full methodology body...]
>
> "**End of methodology. Below this line is the per-customer context for this specific interview.**"

In the **two-file path**, this block stays in `discovery-prompt.md` — the methodology always travels with the prompt, never with the attachment. The methodology is what makes the conversation work; without it the attachment is just data.

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

**Two-file path:** replace the inline content with a pointer:

> "**A context file is attached to this message containing the business summary, our meeting transcript, and operator notes. Read it in full before you respond. Treat it as ground truth — do not re-ask anything covered in it.**"

### 4. The bespoke first question — REQUIRED, NOT OPTIONAL

This is the single highest-value piece of bespoke content you generate. It is **not** generic. It must reference an actual phrase, decision, concern, or topic the customer raised in the meeting.

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

## Final checks before writing

Before you write either file, run this checklist:

1. **Sizing decision logged.** You computed the total combined character count, you picked one-file or two-file path, and you wrote the decision into `state.json`.
2. **Methodology pasted verbatim, not paraphrased.** Open `reference-docs/discovery-methodology.md`, paste its full body into the prompt block bracketed by the opening/closing methodology markers.
3. **Bespoke opener references a specific meeting detail.** Not generic. Not "tell me about your business." Pulled from a real phrase or topic in the transcript.
4. **Known-vs-unknown map present** and accurately reflects what the brain-doc + meeting already cover.
5. **No vendor names** in either output file. No model names. No infrastructure names. No internal codenames.
6. **Cover email substitutions all resolved.** No literal `{customer_first_name}`, `{operator_first_name}`, `{{DISCOVERY_PROMPT}}`, or `{{CUSTOMER_CONTEXT_FILE_PATH}}` left in the email.
7. **Two-file path only:** `customer-context.md` exists at `{run-dir}/customer-context.md`, contains brain-doc + transcript + operator hints with brief framing headings, and is referenced by absolute path in the cover email.
8. **One-file path only:** the `--- ATTACH THIS FILE ALONGSIDE YOUR MESSAGE ---` block is omitted from the cover email.
9. **Discovery-prompt size on the two-file path is under 10,000 characters.** If it isn't, the methodology + opener + scope statement is too verbose — trim your framing, never the methodology.

Write the files and stop. Stage 10 reports the path taken, the file sizes, and the absolute paths to the operator's terminal.
