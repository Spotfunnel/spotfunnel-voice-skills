# Brain-doc synthesis prompt

> **Audience:** you, reading this at Stage 3 of the `/base-agent` skill.
>
> **Job:** read three inputs and produce a single structured markdown brain-doc that downstream stages depend on.

---

## What you have

You are given three sources, in this order of authority:

1. **The full website scrape** — markdown produced by a public-site crawl of the customer's website. May contain anywhere from a few pages to fifty pages of content; sometimes sparse, sometimes rich.
2. **The meeting transcript** — verbatim text of a recorded conversation between the operator and the customer. This is the **most authoritative source** for the customer's actual situation today.
3. **The operator hints** — one freeform paragraph from the operator capturing anything material that didn't make the meeting.

You will synthesize these into one markdown document — the **brain-doc** — saved at `{run-dir}/brain-doc.md`.

The brain-doc is read downstream by:
- The rough-system-prompt assembler at Stage 4 (becomes part of the agent's persistent knowledge of the business).
- The discovery-prompt generator at Stage 10 (becomes ground truth that the discovery interviewer cites back to the customer rather than re-asking).

Both downstream consumers depend on the structure being stable and the source-flagging being accurate. Get those two things right above all else.

---

## Optional enrichment input — operator's example agents

Before extracting from the three primary sources, **scan `templates/example-agents/` for any `*.prompt.md` files**:

```bash
ls templates/example-agents/*.prompt.md 2>/dev/null
```

If one or more files exist, **read each one in full**. These are the operator's own well-tuned production receptionist prompts. They are present specifically so you can study what depth and behavioural richness a great agent prompt looks like in this operator's house style.

Use them ONLY as **structural and depth inspiration** — i.e. they teach you:

- Which categories of business context show up in tuned agents (caller scenarios, transfer logic, escalation rules, hold messages, fallback cascades, common-situation handlers, edge-case behaviour, pronunciation guides, knowledge-base depth).
- How tone markers get expressed in a way the agent can actually act on (specific phrases, vocabulary cues, formality calibration, empathy triggers, do-not-say lists).
- What level of *operational nuance* counts as worth capturing — versus marketing fluff worth ignoring.
- How named staff, services, and policies are stated crisply versus padded.

**Critical: do NOT copy any specific facts from the example prompts into the brain-doc you are about to write.** No phone numbers, addresses, staff names, business hours, prices, transfer rules, vendor mentions, or any other concrete data leaks from those examples into the customer brain-doc. The customer's brain-doc is sourced ONLY from the three inputs below (website + meeting + operator hints). The examples inform STRUCTURE and DEPTH, never content.

If `templates/example-agents/` is empty or contains only the README, **skip this step entirely** and proceed with the three primary sources alone. The brain-doc still works without the enrichment input — it'll just lean on the universal extraction guidance below.

---

## What to extract

Pull out the following, from any of the three sources. Some fields will be present in all three; some in one; some in none.

- **Identity** — legal name, trading name, one-line pitch in the business's own voice (quote from the site if a clean tagline exists; otherwise compose one based on what the site says).
- **Services** — each named service or product with a one- or two-sentence description. If the site lists ten services and the meeting only mentions three, capture all ten and note which the customer specifically discussed.
- **Hours** — opening hours per day-of-week. Capture as plain prose ("Mon–Fri 8am–6pm, Sat 9am–12pm, closed Sun") not a table. If the site and the meeting disagree, use the meeting and flag the conflict.
- **Locations & service area** — physical address(es), suburb/region(s) served, any geographic constraints ("we only do callouts within 30 minutes of Brisbane CBD").
- **Staff** — list ONLY people who are likely transfer targets or named handoff destinations: partners, principals, special counsel, named heads of practice areas, the practice manager, and anyone the meeting transcript explicitly singles out. For each listed person capture **role + matter-area + direct contact only** — drop admission years, university degrees, prior-firm history, languages spoken (capture languages separately under Tone & Voice or as a single team-wide line if relevant), and any other biographical detail. One line per person, max. If the source lists more team members than fit this filter, add a single footnote line at the end of the section: `_Additional team: N more lawyers and support staff (not listed individually)._` Don't invent staff who aren't named anywhere.
- **Contact** — existing public phone number(s), email(s), any other contact channel the business publicises.
- **Policies & pricing** — explicit statements of policy, prices, guarantees, terms. Examples: "$145 initial consult", "no-obligation quotes", "30-day satisfaction guarantee", "we don't bulk-bill", "minimum callout fee $90". Only capture what the source explicitly states — don't infer prices.
- **Tone & voice** — markers from the source copy: formal/casual, warm/efficient, humour cues, signature phrases the **customer themselves** used (in their site copy or in the meeting) — e.g. "g'day", "no worries", "looking after Brisbane families since 2008". Capture these as **texture** — quoted brand phrases + register descriptors (formal/blunt/warm/etc.) — NOT as agent instructions. The agent's voice will be tuned from these at Stage 4 (PROCEDURES layer); the brain-doc just supplies the raw texture.

  **Tone & Voice section — BANNED SUBSECTION HEADINGS.** The Tone & Voice section MUST NOT contain any of the following H3 subsections (or anything substantively equivalent under any other heading):
  - `### Opening line` — what the agent says when the call connects
  - `### Signature phrasings` — agent-side phrasings for confirmations, empathy, sign-offs, etc.
  - `### Hold / "let me check" etiquette` — what the agent does while writing/thinking
  - `### Frustration / empathy triggers` — how the agent recognises and responds to frustration
  - `### Closing ritual` — how the agent ends a call
  - `### Pronunciation guide` — how the agent pronounces initialisms, names, phone numbers
  - `### Caller scenarios per service line` — per-service-line caller-handling playbooks
  - `### Procedures` / `### Behavioural patterns` / `### Call flow` / `### Routing rules` — any agent-behaviour heading by any name

  These are PROCEDURES content, generated at Stage 4 from the brain-doc + example-agents. They do **not** belong in the brain-doc. If you find yourself writing one of those subsection titles, stop and delete it — the content also goes (don't relocate it under a different heading).

  **What the Tone & Voice section MAY contain:**
  - One short paragraph describing the brand's register (e.g. "direct, blunt, Australian, partner-confident; rejects glossy-corporate; sentences are short").
  - Direct quotes of signature brand phrases the **customer** uses on their site or in the meeting (e.g. _"We don't sugarcoat. We don't over-promise. We deliver."_). Quote them; don't transform them into agent instructions.
  - Languages spoken across the team, if relevant.

  Everything else — what the agent should say, when to escalate, how to handle frustration, what to say at the close, how to pronounce the firm's initialisms — is Stage 4's job, not Stage 3's.
- **Notable from meeting** — anything material the customer said in the meeting that doesn't naturally fit the headings above. Examples: a problem they're trying to solve, a previous bad experience with another vendor, a commercial constraint, a stated preference, an unusual operating pattern. Keep this section grounded — only include things that would change how someone designs the agent.

  **No-meeting handling:** if the meeting-transcript input is the placeholder `[NO MEETING TRANSCRIPT — ...]` (operator-flagged forced-broad-scope or website-only run), the entire `## Notable from Meeting` section MUST contain ONLY the literal line `_(no meeting — see operator hints below if any)_` followed (optionally) by the operator-hints paragraph reproduced — **but only after sanitization per the rule directly below**, tagged `[from operator hints]`. Do **not** populate this section with `[inferred]` operational nuances, transfer-routing speculation, urgency-detection guidance, "the agent should..." recommendations, or any other design-of-the-agent prose. Operational nuance and behavioural design belong in the Stage-4 enrichment pass (which writes back into other sections of the brain-doc with proper sourcing) — they do **not** belong in `## Notable from Meeting` synthesised at Stage 3 from a placeholder transcript.

  **Operator-hints sanitization** — when reproducing operator hints inside `## Notable from Meeting`, strip any test-harness or skill-development substrings before pasting. This rule mirrors `prompts/generate-discovery-prompt.md`'s Rule 2 and the two should agree on what counts as test-harness pollution.

  Forbidden substrings (case-insensitive, whole word/phrase): `Stage 1`, `Stage 2`, `Stage 3`, `Stage 4`, `Stage 5`, `Stage 6`, `Stage 7`, `Stage 8`, `Stage 9`, `Stage 10`, `Stage 11`, `Stage 12`, `Stage 13`, `End-to-end test`, `End to end test`, `e2e test`, `stress-test`, `stress test`, `stress-testing`, `forced-broad-scope`, `forced broad scope`, `the pipeline`, `the full pipeline`, `dashboard onboarding`, `test of the skill`, `skill development`, `skill is testing`, `we are testing`, `we're testing`, `test run`.

  **Procedure:**

  1. Read the operator-hints paragraph as it appears in skill state.
  2. Tokenise into sentences. **Sentences containing any forbidden substring are dropped entirely** — don't try to surgical-edit a sentence. Drop the whole sentence.
  3. After stripping, if substantive content remains (e.g. `"Agent name vertical-appropriate for a Melbourne-based law firm"` survives), reproduce that content under `[from operator hints]`. Rephrase lightly only if needed for grammar (e.g. into a clean standalone sentence); keep the substantive guidance intact.
  4. **If nothing substantive remains**, write `_(no operator notes)_` and **omit** the `[from operator hints]` tag entirely (don't tag an empty line).

  **Mechanical check before writing the brain-doc:** grep the assembled brain-doc body for each forbidden substring listed above. Match count must be **zero**. If any match, your sanitization didn't catch it — re-sanitize and re-grep.

  This applies whether the meeting-transcript is the placeholder or a real transcript — operator hints are sanitized either way before they go into `## Notable from Meeting`. The brain-doc is read by the system-prompt assembler (Stage 4) and pasted byte-identical into the agent's runtime prompt; test-harness language poisons that.

---

## Source flagging

Every individual field you capture must end with a tag from this list:

- `[confirmed: site + meeting]` — the same fact appeared in both the website and the meeting transcript. This is the strongest tag.
- `[from site only]` — the fact appears on the website but the meeting didn't touch it. Common for hours, addresses, full service lists.
- `[from meeting only]` — the customer said it in the meeting but it isn't on the site. Common for staff context, current pain points, dream behaviour.
- `[inferred]` — you didn't see this stated explicitly, but you've inferred it from the source material with reasonable confidence. Use sparingly, and only for facts about the business itself (e.g. tone-marker characterisation drawn from site copy). **Do not infer operational nuances or design recommendations into the brain-doc — those belong in Stage 4 enrichment**, where the system-prompt assembler is licensed to elaborate behaviour against sourced facts. If you can't tag a business-fact with one of the first three, prefer leaving it out over inferring.

The tags go at the end of the line or paragraph the field appears in, in square brackets. Examples:

```
- Mon–Fri 8am–6pm, Sat 9am–12pm, closed Sun [confirmed: site + meeting]
- Dr Liu — senior partner, handles complex spinal cases [from meeting only]
- Tone reads warm and family-run, sentences like "looking after Brisbane families since 2008" [from site only]
```

If the website and the meeting disagree on a fact, the **meeting wins** — but flag the conflict explicitly with a parenthetical:

```
- Hours: Mon–Fri 8am–4pm (site says 8am–5pm, customer said in meeting they've been closing at 4 lately) [from meeting only — conflict with site]
```

This conflict-flagging is load-bearing. The discovery-prompt generator uses it to surface the discrepancy back to the customer ("you might want to update the site too") rather than silently going with one or the other.

---

## Output structure

Use exactly these H2 headings, in this order. Every heading appears in every brain-doc — even when the section has no content.

```
## Identity
## Services
## Hours
## Locations & Service Area
## Staff
## Contact
## Policies & Pricing
## Tone & Voice
## Notable from Meeting
## Knowledge Gaps
```

If a section has nothing to capture from any source, write a single italicised line under the heading: `_(no information)_`. Don't omit the heading. Downstream consumers expect every heading present so they can grep for them deterministically.

### `## Knowledge Gaps` — mechanical, last section

This section is a **numbered list of every coverage area the inputs couldn't fill**. The downstream Stage 10 discovery-prompt generator pulls these straight into the customer's to-do list. Don't editorialise; emit gap lines.

**Procedure:**

1. Walk the methodology coverage targets A–F (see `reference-docs/discovery-methodology.md`):
   - **A.** Caller personas + per-persona dream call ending.
   - **B.** Transfer targets (name + role + direct number + trigger) and after-hours / emergency-escalation policy.
   - **C.** Active CRM, calendar, SMS, email, accounting, scheduling tools (specific products + versions) + per-integration dream behaviour.
   - **D.** Voice/brand register, signature phrases, red-line topics, **humour-vs-seriousness register** (does the agent crack jokes when appropriate, or stay strictly professional?).
   - **E.** Industry compliance, call-recording posture + jurisdictional disclosure, known failure modes today.
   - **F.** Business hours, peak times, weekly call volume, agent operating hours (24/7 vs. business-hours vs. after-hours).
2. Also walk the brain-doc's own H2 sections (`## Hours`, `## Staff` transfer-target detail, `## Policies & Pricing`, etc.). Any H2 that is `_(no information)_` or that has only sparse `[from site only]` entries where transfer-routing or operational detail is missing is a gap.
3. For each gap, emit **one short imperative line** in `## Knowledge Gaps`. Cap each line at ~15 words. Format: short reason + `ASK.` or equivalent imperative.

**Example shape:**

```
## Knowledge Gaps

1. Business hours — site does not publish them. ASK.
2. Specific transfer targets and direct numbers — only first names listed on team page. ASK.
3. Pricing — not published. ASK.
4. After-hours / emergency-escalation policy — not published. ASK.
5. Active CRM, calendar, SMS tools — not mentioned anywhere. ASK.
6. Per-integration dream behaviour — not in scope of any source. ASK.
7. Humour-vs-seriousness register — site doesn't reveal this clearly. ASK.
8. Call-recording posture — not stated. ASK.
9. Known failure modes today — not stated. ASK.
10. Call volume + peak times + agent operating hours — not stated. ASK.
```

**Hard rules:**

- Numbered list, 1–N. Not a paragraph.
- One imperative line per gap. ≤15 words.
- No source tags inside this section — gaps are by definition unsourced.
- Empty list only valid if every coverage target A–F is fully sourced from site or meeting; in that case write `_(no gaps — all coverage targets sourced from site or meeting)_`. This will be rare.
- If the meeting transcript is the placeholder `[NO MEETING TRANSCRIPT — ...]`, almost every operational coverage target (B, C, parts of D, E, F) is by definition a gap. Emit them.

---

## Length and density

- **Target total size:** ~3–8 KB. Roughly 500–1300 words.
- If the source material is genuinely sparse — a one-page website plus a 5-minute meeting — your output will be at the low end. That's fine.
- **Never pad.** A 4 KB brain-doc that captures only what the source supports is far more useful than a 12 KB one that invents detail.
- Keep sentences crisp. Bullet lists where the data is naturally a list (services, staff, hours). Short paragraphs where there's narrative (tone, notable from meeting).

---

## What not to do

- **Do not speculate.** If a source doesn't give you a fact, don't invent one. Tag-or-omit.
- **Do not write marketing copy.** This is an operational brief, not a brochure. "Acme Plumbing has been serving Brisbane since 1987 with unwavering dedication to quality" is wrong. "Founded 1987, family-owned, serves Brisbane metro [confirmed: site + meeting]" is right.
- **Do not paraphrase the meeting transcript at length.** Pull out facts and tone markers; don't recap the conversation.
- **Do not include opinions or recommendations.** No "the customer should consider...". The brain-doc is descriptive, not prescriptive.
- **Do not infer operational nuances or design recommendations** into the brain-doc — no "the agent should...", no "transfer routing should consider...", no "urgency cues to detect...", no "natural close should be...". That entire register of advice is the Stage-4 PROCEDURES pass's job, not Stage 3's. When in doubt, leave it out — Stage 4 will add it back, scoped and sourced, against the same brain-doc.
- **Do not include any commentary about how the agent is built, what platform it runs on, or any backend implementation detail.** The brain-doc is purely about the customer's business.
- **Do not include URLs from the scrape** (they're not useful downstream and they bloat the file).

### The brain-doc is FACTS + TONE-AS-TEXTURE — never BEHAVIOUR

State the rule positively, because it has been violated repeatedly: the brain-doc captures (a) **factual** information about the business (services, hours, staff, locations, contact, policies, prices) and (b) **tone-as-texture** — i.e. the customer's own brand voice expressed through quoted phrases the customer themselves used and short register descriptors (formal/blunt/warm/Australian/etc.). That is the entire scope.

The brain-doc does **NOT** capture **behaviour** — i.e. what the agent should do. Behaviour means:

- What the agent says when the call connects (opening line phrasings).
- What the agent says to confirm a name/number/email (signature phrasings, readback rituals).
- What the agent says to acknowledge frustration, distress, urgency.
- What the agent says when a caller asks something out of scope.
- What the agent says to close a call (sign-offs, closing rituals).
- What the agent does while writing or thinking (hold etiquette, dead-air narration).
- How the agent pronounces initialisms, phone numbers, surnames, addresses (pronunciation guide).
- Per-service-line caller-handling playbooks ("Family law caller — typical intent is X, lead with empathy, route to Y").
- Transfer-routing rules, urgency-detection cues, escalation logic, message-taking field lists.

**All of the above belongs in PROCEDURES, generated at Stage 4 from this brain-doc + the example agents in `templates/example-agents/`.** None of it belongs in the brain-doc.

### BANNED SUBSECTIONS — hard list

The following H3 subsection titles (and any substantive equivalent under another title) MUST NOT appear anywhere in the brain-doc, including under `## Tone & Voice`, `## Services`, `## Policies & Pricing`, or any other H2:

- `### Opening line`
- `### Signature phrasings`
- `### Hold / "let me check" etiquette` (or any "Hold etiquette", "dead air", "filler beats" variant)
- `### Frustration / empathy triggers` (or "Empathy register", "Distressed callers", etc.)
- `### Closing ritual` (or "Sign-off", "Wrap-up", "End-of-call")
- `### Pronunciation guide` (or "Pronunciation", "Voice-only reading rules", "How to say…")
- `### Caller scenarios per service line` (or "Caller intake", "Routing logic", "Per-service-line handling")
- `### Procedures`, `### Behavioural patterns`, `### Call flows`, `### Routing rules`, `### Transfer logic`, `### Escalation rules`

If you catch yourself writing one of these subsection titles — or a paragraph whose content matches one of them under a less obvious heading — stop and delete the entire block. Do not relocate it. Do not paraphrase it. Stage 4 will produce that content from scratch using the example agents as the structural model; the brain-doc would only pollute Stage 4 if it leaked behavioural prose.

---

## When sources conflict

- **Meeting beats website** on questions of "what is true today". Hours have changed; staff have left; prices have moved. The meeting is recent reality.
- **Website beats meeting** on questions where the customer might misspeak in conversation but the site is authoritative — e.g. exact business legal name, ABN/registration numbers, full street address. Use judgment.
- **Always flag the conflict** so downstream stages can surface it.

---

## When sources are sparse

If the website is thin (one page, generic copy) and the meeting was short, the brain-doc will be short. Output what you have, tag everything correctly, and use `_(no information)_` for empty sections. The discovery-prompt generator at Stage 10 is responsible for asking the customer to fill the gaps — not the brain-doc.

If the website is rich but the meeting was short, lean on the site for facts and use `[from site only]` tags liberally. Note any tone markers the site provides — they'll inform agent voice tuning later.

If the meeting was rich but the website is thin or out of date, lean on the meeting and use `[from meeting only]` heavily. Common case for businesses that haven't refreshed their site in years.

---

## Sample output structure

Below is the **skeleton** the output should follow. This is a structural example only — replace the stub lines with real, sourced, tagged content from the inputs you have.

```
## Identity

- Legal name: [...] [confirmed: site + meeting]
- Trading name: [...] [from site only]
- One-line pitch: [...] [from site only]

## Services

- [Service 1]: [one-line description] [confirmed: site + meeting]
- [Service 2]: [one-line description] [from site only]
- [Service 3]: [one-line description] [from meeting only]

## Hours

- Mon: [...]
- Tue: [...]
- Wed: [...]
- Thu: [...]
- Fri: [...]
- Sat: [...]
- Sun: [...]
[confirmed: site + meeting]

## Locations & Service Area

- Primary address: [...] [from site only]
- Service area: [...] [from meeting only]

## Staff

- [Name] — [role]; [one-line context] [from meeting only]
- [Name] — [role]; [one-line context] [confirmed: site + meeting]

## Contact

- Phone: [...] [confirmed: site + meeting]
- Email: [...] [from site only]

## Policies & Pricing

- [Policy or price statement] [from site only]
- [Policy or price statement] [from meeting only]

## Tone & Voice

[One short paragraph capturing the tone markers from the site copy and meeting transcript — formality, warmth, signature phrases, things-they-don't-say. Tag the source(s).]

## Notable from Meeting

- [Material thing the customer said that doesn't fit elsewhere]
- [Material thing the customer said that doesn't fit elsewhere]

## Knowledge Gaps

1. [Coverage area that isn't sourced from site or meeting] — [reason in <8 words]. ASK.
2. [Coverage area that isn't sourced from site or meeting] — [reason in <8 words]. ASK.
```

When a section is empty:

```
## Policies & Pricing

_(no information)_
```

---

## Final check before writing

Before you emit the brain-doc, run through this mental checklist:

1. Every H2 heading from the list above is present, in order — including `## Knowledge Gaps` as the final section.
2. Every fact has a source tag.
3. Conflicts between site and meeting are flagged explicitly.
4. Empty sections show `_(no information)_`, not omitted. The exception is `## Knowledge Gaps`, which uses `_(no gaps — all coverage targets sourced from site or meeting)_` if truly empty.
5. `## Knowledge Gaps` mechanically covers every methodology coverage target A–F that the inputs didn't fill. Numbered list, ≤15 words per item, ends imperatively (`ASK.`).
6. Total size is 3–8 KB. Not under 1 KB; not over 12 KB.
7. No speculation, no marketing copy, no implementation detail, no commentary.
8. Reads as an operational brief a downstream stage can grep, parse, and quote from.
9. **No facts borrowed from `templates/example-agents/`.** If you read example prompts for inspiration, double-check that no phone number, staff name, address, price, transfer rule, or other concrete fact from any example accidentally appears in the brain-doc. Examples informed STRUCTURE and DEPTH only.

### Final integrity check — SELF-VALIDATION (run before write, abort on failure)

Before you write the file, scan the draft you've composed against the BANNED SUBSECTIONS list. The check is mechanical:

1. **Pattern scan.** Look for any line that starts with `### ` (H3 heading). For each H3 you find, check it against this banned-pattern list (case-insensitive, substring match, both literal and equivalent phrasings):

   - `Opening line` / `Greeting` / `Call open` / `Salutation`
   - `Signature phrasings` / `Signature phrases` / `Stock phrases` / `Phrasings`
   - `Hold` (any variant — "Hold etiquette", "Hold / let me check", "Dead air", "Filler beats")
   - `Frustration` / `Empathy triggers` / `Distress` / `Upset callers`
   - `Closing ritual` / `Sign-off` / `Wrap-up` / `End of call` / `Call close`
   - `Pronunciation` (any variant — "Pronunciation guide", "How to say", "Voice-only reading")
   - `Caller scenarios` / `Caller intake` / `Routing` / `Transfer rules` / `Escalation rules`
   - `Procedures` / `Behavioural patterns` / `Call flow` / `Behaviours`

2. **Substantive scan.** Independently of headings, scan paragraphs for any passage that reads like an instruction to the agent. Trigger phrases include but aren't limited to:
   - "The agent must…" / "The agent should…" / "The agent opens…" / "The agent closes…"
   - "Said only once…" / "Said exactly once…" / "Use this phrasing…"
   - "Do not say…" / "Never say…" (in the agent's mouth — different from "the firm does not deliver…", which is a fact)
   - "When the caller is frustrated…" / "When the caller asks…" / "When the caller mentions…"
   - "Spell out as letters…" / "Read X as Y…" / "Verbalise Y as Z…"
   - "Confirm next steps…" / "Three beats…" / "Default route is…"
   - Numbered step lists describing call-handling sequences ("1. Ask name. 2. Confirm. 3. Take a message.")

3. **Abort condition.** If **either** scan finds a hit, the draft is polluted with behavioural content and you must NOT write it. Instead:
   - Strip the offending H3 subsection(s) and any orphan agent-instruction prose.
   - Re-check the remainder against the size target (3–8 KB) — the cleaned draft will be significantly smaller, and that's correct.
   - Re-run the integrity check on the cleaned draft.
   - Only when both scans return zero hits may you write the file.

4. **Write only when clean.** A polluted brain-doc that survives this stage poisons Stage 4 (the system-prompt assembler concatenates the brain-doc verbatim into the final agent prompt) and Stage 10 (the discovery generator quotes from the brain-doc as ground truth). Both downstream stages assume the brain-doc is FACTS + TONE-AS-TEXTURE only. If the integrity check is uncertain, err on the side of stripping — Stage 4 will regenerate any genuinely useful behavioural content from the example agents.

Write the file to `{run-dir}/brain-doc.md` and stop.
