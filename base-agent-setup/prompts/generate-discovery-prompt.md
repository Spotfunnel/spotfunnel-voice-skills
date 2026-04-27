# Discovery-prompt generator

## Active lessons + corrections (read first, treat as binding)

{{LESSONS_BLOCK}}

{{CORRECTIONS_BLOCK}}

The block above is populated deterministically by `scripts/compose-prompt.sh` at orchestration time — do not run `fetch_lessons.py` yourself; the composer already did. Empty `(no active lessons)` is normal. The `<corrections>` block, if present, lists operator-marked factual errors from a previous run that you must apply verbatim in this regeneration.

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
  - `discovery-prompt.md` — short, paste-friendly. Contents: framing line + a one-line pointer telling ChatGPT to read the methodology and per-customer context in the attached `customer-context.md` file + known map + numbered to-do list (the visual centrepiece — see element 4 below) + bespoke opener (one punchy question only — see element 5 below) + output-schema reminder + tone instruction. **NO methodology body inline. NO transcript inline. NO brain-doc inline.** This file must come in **under 10,000 characters**, hard cap.
  - `customer-context.md` — methodology body (verbatim) + brain-doc body (post-sanitization, see "Sanitization rules" below) + meeting transcript verbatim (post-sanitization, see below) + operator hints (post-sanitization, see below), with brief framing headings: `# Methodology` (the verbatim discovery-methodology body), `# Business summary` (brain-doc), `# Meeting transcript`, `# Operator notes`. Methodology comes first in this file because ChatGPT needs to ingest it before it does anything else with the per-customer context.

  The customer pastes `discovery-prompt.md` as their first message and drag-drops the literal `customer-context.md` file as an attachment to that same message.

**Routing rule, stated explicitly:** if methodology + brain-doc + transcript + operator hints + framing prose ≤ 25K total → single-file (methodology stays inline). Else → two-file with methodology in the attachment. The methodology never lives inline in `discovery-prompt.md` on the two-file path.

The cover email handles both paths automatically — it tells the customer "if you see two parts below, paste the prompt and attach the context file."

### Step 3 — record the path

In `state.json` write `discovery_prompt.size_path: "one-file"` or `"two-file"` and the measured character count, so downstream stages and the operator's terminal output know which path was taken.

---

## What the generated discovery prompt must contain

Whether one-file or two-file, the discovery prompt itself (the part the customer pastes as their first message) must contain these elements, in this order:

1. **Framing line** (identity)
2. **Methodology** (verbatim inline on one-file path, pointer on two-file path)
3. **Per-customer ground truth** (inline on one-file path; lives in attachment on two-file path)
4. **Known map + numbered to-do list** — *the visual centrepiece of the prompt*
5. **Bespoke first question** — punchy, 1–2 sentences, anchored in ONE specific
6. **Output schema reminder**
7. **Conversational tone instruction**

The to-do list (element 4) comes **before** the bespoke opener (element 5). This is deliberate. ChatGPT reads the work first, then receives the entry-point question. The opener is just the door; the to-do list is the room.

Write each element as natural prose addressed to ChatGPT — except element 4, which **must** render as a numbered list (see element 4 spec below for hard rules). The rest reads as a single coherent instruction block.

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

**Two-file path:** the inline brain-doc + transcript + hints content does NOT appear here either — it's all in the attachment, after the methodology section. The pointer-line you wrote at element 2 already covers this; you don't duplicate it. Move on to element 4 (the known map + to-do list).

### 4. Known map + the to-do list (the visual centrepiece)

This is the **work** of the discovery prompt. ChatGPT will skim everything else; it must not skim this. Make it visually punchier than every other section. The customer will read the rendered prompt over ChatGPT's shoulder; both audiences need this section to read as a tight, numbered task list rather than a paragraph of run-ons.

#### 4a. Already settled — do not re-ask

A short paragraph or compact bullet list that names what's already in the brain-doc + meeting so ChatGPT doesn't waste a question on it. Pull these from the brain-doc and the meeting transcript. Examples of items: business hours, services offered, staff first names, the published phone number, the agent's general scope (when the meeting set it), the existing booking system, the brand voice in broad strokes.

Example shape (write yours similarly, customer-specific):

> "**Already settled — do not re-ask:** business hours, services offered, staff names, address, the agent's general scope (per the meeting), the existing booking system, the brand voice in broad strokes."

#### 4b. Your job — get clear on these with the customer

Then a **numbered to-do list** of every coverage-target item from the methodology that is in scope but not yet answered. **This list IS the work.** Frame it as instructions to ChatGPT, not a topic survey.

**Building the list — mechanical, in this order:**

1. **First, paste in every item from the brain-doc's `## Knowledge Gaps` section.** That section is by construction the list of coverage areas the inputs couldn't fill. Each gap line maps one-to-one to a to-do item; carry the imperative phrasing across (e.g. `"Business hours — site does not publish them. ASK."` becomes `"Business hours — site does not publish them."`). Strip the trailing `ASK.` token if it makes the line awkward; the section's framing already conveys imperative intent.
2. **Then add any in-scope methodology coverage items (A–F) that aren't already covered by a gap line.** These are usually the brain-engaging "dream behaviour" items the brain-doc can't ever source from a website (per-persona dream call ending, per-integration dream behaviour, etc.). Don't repeat anything the gap-derived lines already cover.
3. **Always include this item if it isn't already on the list:** `Humour vs. seriousness register — should the agent crack jokes when appropriate, or stay strictly professional?` (Methodology §3D, voice texture decision the customer needs to make.)
4. **Visually flag gap-derived items.** The gap-derived items go FIRST in the numbered list (they're the inputs-couldn't-fill items the customer must answer). Methodology-coverage items follow. Don't mark the boundary inside the list — the to-do list is one continuous numbered list — but the order matters because ChatGPT reads top-down.

**Hard rules for this section:**

- **Numbered list, 1–N.** Not a paragraph. Not semicolon-separated. Not "and... and... and..." run-ons.
- **One short line per item.** Hard cap **15 words per item**. If a line wants to balloon, split it into two items or trim it.
- **Imperative phrasing.** Each item reads like a task: "Caller personas in practice — who actually rings the line." Not "caller personas, per-persona dream call endings, transfer-target rules…" all jammed together.
- **No semicolons inside an item.** Semicolons signal a run-on; if you need one, you've packed two items into one.
- **Bold framing line above the list.** Use the literal heading **`Your job — get clear on these with [Customer first name]:`** (or **`Your job — get clear on these with the customer:`** when no first name is on file). It must read as an instruction list, not a topic list.
- **Closing instruction line below the list.** Add a single line *after* the numbered items, in bold, that reads: **`These are your tasks. Work through them. Don't skip any. The opener below is just your entry point — this list is the work.`**

Worked example of the shape (your contents will be customer-specific):

> "**Your job — get clear on these with Sarah:**
>
> 1. Transfer rules — name, role, direct number, trigger per target.
> 2. After-hours and emergency-escalation policy.
> 3. Software stack — what tools does the business use, especially anything the agent could meaningfully interact with? Specific products and versions.
> 4. Caller personas in practice — who actually rings the line.
> 5. Per-persona dream call ending — what each caller leaves with.
> 6. Per-integration dream behaviour — what writes where, when.
> 7. _(do NOT include "red lines / do-not-say list" — common sense, not worth a question)_
> 8. Humour vs. seriousness register — crack jokes when fitting, or strictly professional?
> 9. Call-recording posture and jurisdictional disclosure handling.
> 10. Known failure modes today — what currently goes wrong on calls.
> 11. Call volume and peak-time patterns.
>
> **These are your tasks. Work through them. Don't skip any. The opener below is just your entry point — this list is the work.**"

**Ordering rule.** The software-stack item lands BEFORE the persona/dream-call items. Knowing what software exists lets the customer answer persona/outcome questions concretely ("leads land in our CRM, calendar invites go in Google Calendar") rather than in a software-vacuum. If you find yourself ordering personas before software, re-order.

This section enforces the methodology's "never re-ask" principle (principle 2) by making the already-answered items explicit up front, AND it enforces the methodology's coverage targets (§3 A–F) by making the still-open items a literal numbered to-do list ChatGPT can tick through.

### 5. The opener — transparent gap acknowledgement + envisioning question

The opener is the **entry point**, not the centrepiece. Element 4 above is the centrepiece. The opener's job is to (a) make the customer feel seen by naming what we already know we DON'T know, and (b) hand the conversation back to them with one open question they can answer in their own terms.

**Do NOT prescribe a verbatim question for ChatGPT to deliver.** The operator does not write the opener line. ChatGPT generates the phrasing live, anchored in the gap-list above and the customer's brand voice from the brain-doc. The generator's job is to give ChatGPT the *pattern*, not the words.

**Pattern ChatGPT must follow (two beats):**

1. **Acknowledge the biggest gaps directly.** Pull 3–5 items from the to-do list above and tell the customer these are the main things you'd want to nail to make sure the agent gets built right. This is the "transparency" beat — it shows the customer we read the brief and understand exactly what's still missing.
2. **Pivot to one open envisioning question.** Something close to: *"But first — what are you envisioning for your voice agent? What does the dream version look like to you?"* The exact phrasing is ChatGPT's call. The point is to let the customer anchor the conversation in their own terms before any structured questioning begins.

After that opening turn, work through the to-do list per the methodology — MCQ scaffolding, one question at a time, branch dynamically based on what the customer says.

**No time-expectation line in the opener.** The cover email the operator forwards already sets the time frame ("usually 20–40 minutes"); ChatGPT restating it inside the conversation is redundant and risks reading as paternalistic. Drop it.

**Spell this out to ChatGPT explicitly inside the discovery prompt — not as a verbatim opener for it to deliver, but as a 2-step instruction for it to enact in its first message.** Use a heading like `**Open the conversation transparently with [first name]:**` followed by the two numbered beats above, customised lightly for the brain-doc material (e.g. "voice agent" replaced with the customer's framing if they used a different term in the meeting).

**Hard rules:**

1. **No verbatim opener prescribed.** The generator must NOT write a specific opener question for ChatGPT to deliver. It writes the 2-beat *pattern* and trusts ChatGPT to phrase the actual sentences live.
2. **No fabricated deployment facts.** The opener must NOT anchor on routing or deployment details (which line rings the agent, what number forwards where, which tool the agent uses). Those are operator-side details the brain-doc doesn't reliably know — fabricating them ("your line at 1300 X is what the agent's about to pick up…") is a pattern that mis-states the deployment to the customer. Stick to facts the brain-doc explicitly states.
3. **No time-expectation line.** The cover email already covers this; do not repeat it in the discovery prompt.
4. **Plain language.** Banned phrasing the generator must not write into the opener instructions, and ChatGPT must not produce in its delivery: "throughline", "anchor scope", "anchor the scope", "before we go anywhere near", "land in the middle", "we'll work outward from there", "I want to anchor", "Tell me:" preamble, "let me reflect that back", "let me anchor", "before I dig in", "before we dig in".
5. **Brevity.** ChatGPT's opening turn caps at ~80 words total across both beats — gap acknowledgement + envisioning question. No paragraphs of explanation; let the to-do list above do the heavy lifting.
6. **Single envisioning question.** The opener ends with exactly ONE question mark — the envisioning question. Not compound. Not "what are you envisioning, and what's the dream version, and what should the agent do?" — those are stacked questions. Pick one.

**GOOD instruction shape (this is what the generator emits in the discovery prompt — NOT a verbatim opener):**

> "**Open the conversation transparently with Kye:**
>
> 1. Acknowledge the biggest gaps. Pull 3–5 items from the to-do list above and tell Kye these are the main things you'd want to nail to make sure the agent gets built right.
> 2. Pivot with one open envisioning question — something like 'But first, what are you envisioning for your voice agent? What does the dream version look like to you?' Phrase it your own way, but keep it single-question.
>
> Wait for his answer. Match his energy. Then work through the to-do list — MCQ scaffolding, one question at a time, branch dynamically per the methodology."

**BAD shapes (do not write these):**

- A verbatim opener anchored in deployment details: *"Your sales line at 1300 95 55 33 is what Adam's about to pick up — when it rings tomorrow morning, what's the single most valuable thing he can do for the business?"* (Fabricates which line is forwarded to the agent — the brain-doc doesn't state this, and getting it wrong tells the customer we misread their setup. Also corny.)
- An opener that restates the cover email's time frame: *"This usually takes 20–40 minutes, so set aside some space…"* (Redundant — the cover email already covers this. Reading it twice feels paternalistic.)
- A wall-of-text scoped opener with multiple anchors: *"Looking at your site, the throughline is the contrast between 'one-trick' agencies and breadth-and-depth Formula — Facebook, Google, email, direct mail, webinars, sales automation, the lot. Before we go anywhere near integrations, I want to anchor scope in your terms…"* (Banned phrasing. Six anchors. Compound question.)
- A generic non-anchored opener: *"Tell me about your business and what you'd want the agent to do for it."* (No transparency beat, no gap-list. Customer feels unheard — the meeting already happened.)
- A verbatim opener the generator wrote for ChatGPT to repeat: any literal sentence in the discovery prompt that ChatGPT is supposed to read out unchanged. The opener is ChatGPT's to phrase, not the operator's to script.

The pattern that works: **2-beat instruction → ChatGPT phrases the delivery live, anchored in the brain-doc and the to-do list, ending in exactly one open envisioning question.**

### 6. Output schema reminder

A short pointer back to methodology §6 (the brief output schema):

> "**When the interview wraps, produce the brief in the format laid out in section 6 of the methodology — sections A through F as plain markdown, between the literal `--- COPY EVERYTHING BELOW INTO YOUR EMAIL ---` and `--- END OF BRIEF ---` separators. Sections that fell outside the scope inferred at the start may be a one-line "out of scope" note or omitted entirely. Do not pad."**

You don't repeat the full schema — it's already inside the methodology body you pasted at element 2. This element is just a reminder so ChatGPT lands the output cleanly.

### 7. Conversational tone instruction

The closing instructions to ChatGPT cover three things, in this order: how to start, how to ask, and how to land the brief.

#### 7a. How to start

> "Start with the 2-beat opener above (gap-acknowledgement → envisioning question). Phrase it your own way; do not deliver a scripted question. Wait for {customer_first_name}'s reply. From there, one question at a time. Acknowledge before moving on. Match {customer_first_name}'s energy — if they're terse, be terse; if they're chatty, be chatty."

#### 7b. How to ask — multiple-choice scaffolding

The customer is a small-business owner, not a voice-AI engineer. Open-ended questions ("what's your software stack?") cause blank-page paralysis. ChatGPT must offer multiple-choice scaffolding for most questions — but **generated dynamically based on what the customer has already shared**, not pre-baked.

Spell this out to ChatGPT explicitly:

> "When you ask a question, offer 3–4 likely options plus 'something else' or 'not sure' as escape hatches. Generate the options based on what the customer has already told you — earlier answers narrow later options.
>
> Example shape (illustrative — generate yours from context):
>
> *Bad (blank-page):* 'What's your CRM?'
> *Good:* 'Which CRM are you using? a) HubSpot, b) Pipedrive, c) Salesforce, d) something else (tell me which)'.
>
> Branching matters: if they answer 'HubSpot', your next question's options should be HubSpot-shaped ('a) Service Hub, b) Marketing Hub, c) Sales Hub, d) just the free CRM') — not generic. Build forward.
>
> Stay succinct. Aim for fifth-grade reading level. Keep questions under 30 words. Don't write paragraphs explaining why you're asking — just ask. The customer should be able to answer in 5 seconds, not after reading a page of context.
>
> If the customer wants to dig into a specific topic that wasn't on the to-do list, follow them — the goal is to help them envision and describe their dream agent, not to march through a checklist. The to-do list is your safety net, not your script.
>
> Offer suggestions when the customer is stuck. 'Most clinics I've helped have wanted X — does that match your situation, or are you thinking differently?' Help them feel guided, not interrogated."

#### 7c. How to land the brief

> "When the conversation feels complete (the to-do list is covered or out-of-scope items have been explicitly closed), produce the final brief in the schema from section 6 of the methodology. **If the conversation ended up being long and detailed (rough heuristic: more than 20 turns), it may be more useful to suggest the customer just copy-paste the entire conversation back instead of — or alongside — the structured brief.** They can decide which is easier; you offer both options."

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
3. **Opener is a 2-beat instruction, not a verbatim question.** The discovery prompt's opener block emits a **`Open the conversation transparently with [first name]:`** heading followed by two numbered beats: (1) acknowledge gaps from the to-do list, (2) pivot with one open envisioning question (e.g. "what are you envisioning for your voice agent?"). ChatGPT phrases the actual delivery live; the operator does NOT prescribe a verbatim opener question. **Mechanical checks:** (a) grep the discovery-prompt body for `Open the conversation transparently` — the literal opener heading must appear. (b) Verify the two beats are present (gap-acknowledgement, envisioning question). (c) Verify NO verbatim opener-question is hard-coded for ChatGPT to repeat — the opener block must read as instruction-to-ChatGPT, not as a sentence ChatGPT will deliver word-for-word. (d) Verify the opener block does NOT name fabricated deployment details (which line gets forwarded, which number rings the agent, which routing applies) — those are operator-side facts the brain-doc doesn't reliably state. (e) Verify the opener block does NOT contain a time-expectation line ("20–40 minutes", "this will take", etc.) — that's the cover email's job, restating it here is redundant. (f) Grep for any banned phrase in the instruction or any examples it carries: "throughline", "anchor scope", "anchor the scope", "before we go anywhere near", "land in the middle", "we'll work outward from there", "I want to anchor", "Tell me:" preamble, "let me reflect that back", "let me anchor", "before I dig in", "before we dig in". Match count must be zero.
4. **Known map + numbered to-do list present and visually punchy.** The "Already settled" sub-section is a short paragraph or compact bullet list. The **`Your job — get clear on these with [Customer]`** sub-section is a **numbered list (1–N), one short line per item, no semicolons, no run-ons**. Every item is **≤15 words**. The closing instruction line **`These are your tasks. Work through them. Don't skip any. The opener below is just your entry point — this list is the work.`** is present in bold below the list. **Mechanical check:** verify the to-do section renders as numbered items, not a paragraph. Verify each line is ≤15 words. Verify zero semicolons inside any item. **Mechanical check (gap propagation):** read the brain-doc's `## Knowledge Gaps` section. Every numbered item there must appear (in spirit, condensed if needed) in the to-do list. If a gap line is missing, the to-do list is incomplete — re-build per element 4b. **Mechanical check (humour/seriousness):** the to-do list must contain a humour-vs-seriousness item — grep for the substring `Humour` or `humour` — at least one match required.
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
