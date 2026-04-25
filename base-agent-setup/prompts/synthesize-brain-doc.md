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
- **Staff** — names, roles, and any context that's relevant to a receptionist agent (e.g. "Dr Liu — senior partner, handles complex cases", "Sarah — practice manager, handles invoicing questions"). Don't invent staff who aren't named anywhere.
- **Contact** — existing public phone number(s), email(s), any other contact channel the business publicises.
- **Policies & pricing** — explicit statements of policy, prices, guarantees, terms. Examples: "$145 initial consult", "no-obligation quotes", "30-day satisfaction guarantee", "we don't bulk-bill", "minimum callout fee $90". Only capture what the source explicitly states — don't infer prices.
- **Tone & voice** — markers from the source copy: formal/casual, warm/efficient, humour cues, signature phrases ("g'day", "no worries", "looking after Brisbane families since 2008"). The agent's voice will be tuned from these later.
- **Notable from meeting** — anything material the customer said in the meeting that doesn't naturally fit the headings above. Examples: a problem they're trying to solve, a previous bad experience with another vendor, a commercial constraint, a stated preference, an unusual operating pattern. Keep this section grounded — only include things that would change how someone designs the agent.

---

## Source flagging

Every individual field you capture must end with a tag from this list:

- `[confirmed: site + meeting]` — the same fact appeared in both the website and the meeting transcript. This is the strongest tag.
- `[from site only]` — the fact appears on the website but the meeting didn't touch it. Common for hours, addresses, full service lists.
- `[from meeting only]` — the customer said it in the meeting but it isn't on the site. Common for staff context, current pain points, dream behaviour.
- `[inferred]` — you didn't see this stated explicitly, but you've inferred it from the source material with reasonable confidence. Use sparingly. If you can't tag something with one of the first three, prefer leaving it out over inferring.

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
```

If a section has nothing to capture from any source, write a single italicised line under the heading: `_(no information)_`. Don't omit the heading. Downstream consumers expect every heading present so they can grep for them deterministically.

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
- **Do not include any commentary about how the agent is built, what platform it runs on, or any backend implementation detail.** The brain-doc is purely about the customer's business.
- **Do not include URLs from the scrape** (they're not useful downstream and they bloat the file).

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
```

When a section is empty:

```
## Policies & Pricing

_(no information)_
```

---

## Final check before writing

Before you emit the brain-doc, run through this mental checklist:

1. Every H2 heading from the list above is present, in order.
2. Every fact has a source tag.
3. Conflicts between site and meeting are flagged explicitly.
4. Empty sections show `_(no information)_`, not omitted.
5. Total size is 3–8 KB. Not under 1 KB; not over 12 KB.
6. No speculation, no marketing copy, no implementation detail, no commentary.
7. Reads as an operational brief a downstream stage can grep, parse, and quote from.
8. **No facts borrowed from `templates/example-agents/`.** If you read example prompts for inspiration, double-check that no phone number, staff name, address, price, transfer rule, or other concrete fact from any example accidentally appears in the brain-doc. Examples informed STRUCTURE and DEPTH only.

Write the file to `{run-dir}/brain-doc.md` and stop.
