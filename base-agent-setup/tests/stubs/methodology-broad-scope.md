# Test Stub — Broad-Scope (Full Receptionist)

> **Purpose:** Sanity-check the discovery methodology against a customer who wants a full inbound receptionist with multiple personas, transfers, after-hours handling, and several integrations. Every coverage target A–F should apply.

---

## Scrape summary (Stage 3 brain-doc shape)

**Business:** Westbridge Family Dental
**Trading name:** Westbridge Dental
**One-line pitch:** Family-friendly dental practice servicing Brisbane's western suburbs since 2008.

**Services:**
- General dentistry (check-ups, cleans, fillings)
- Cosmetic dentistry (whitening, veneers, Invisalign)
- Children's dentistry (CDBS-eligible, Medicare bulk-billing for kids 2–17)
- Emergency dental (same-day appointments for pain, trauma, lost crowns)
- Sleep dentistry (referral basis, Tuesdays only)

**Hours from website:**
- Mon–Thu: 8:00am – 6:00pm
- Fri: 8:00am – 4:00pm
- Sat: 9:00am – 1:00pm (alternate Saturdays)
- Sun: closed

**Staff named on site:**
- Dr. Anna Pereira (principal dentist, owner)
- Dr. James Liu (associate dentist)
- Dr. Priya Shah (associate dentist, paediatric focus)
- Megan Foster (practice manager)
- Two hygienists, two dental assistants — not named on site

**Locations:** Single clinic at 14 Westbridge Avenue, Kenmore QLD 4069.

**Existing contact:** (07) 3878 4421, reception@westbridgedental.com.au

**Tone markers from site:** Warm, professional, family-oriented. Phrases like "your family's smile is in good hands" and "we look forward to welcoming you." Not overly clinical. Photos show kids in chairs holding stuffed animals.

**Policies/prices visible:** No prices listed. Mentions HICAPS for on-the-spot health-fund claims. Mentions a $99 new-patient check-up-and-clean offer.

---

## Meeting transcript (excerpt — ~15 minutes)

**Leo:** So Anna, walk me through what you want this voice agent to do. Pretend it's a person — what's its job?

**Anna:** Right, so it's basically replacing — well, supporting Megan when she can't keep up. Megan's our practice manager, she does reception when we're short-staffed, but Mondays and after lunch on Tuesdays the phone just doesn't stop. We miss calls. New patients especially — they ring around three or four practices and whoever picks up first wins. So we lose them.

**Leo:** OK so it's an inbound receptionist for everything?

**Anna:** Yeah pretty much. New patients booking in, existing patients moving appointments, people ringing about emergencies because they cracked a tooth at lunch, the occasional sales call from someone trying to sell us teeth-whitening trays. It needs to handle all of that.

**Leo:** What about transfers?

**Anna:** Yes — definitely. If it's a clinical question — like, "the filling Dr Liu did on Tuesday is hurting, is that normal?" — that needs to go to a dentist. James handles his own follow-ups, Priya handles hers, and Anna— sorry, *I* handle mine. Anything Megan-related — accounts, health-fund issues, paperwork — that goes to Megan. Sales calls and supplier stuff, the agent can just take a message.

**Leo:** Direct numbers for the transfers?

**Anna:** I'll send them through. James is on extension 102, Priya 103, Megan 105, mine is 101. They all have direct lines too — let me check and send them in writing. Probably easier.

**Leo:** Good. What about after hours?

**Anna:** OK so this is a thing. We have a genuine emergency — like trauma, knocked-out tooth, swelling, severe pain — those need a dentist call-back the same evening if it's after-hours weekday, or Sunday morning if it's Saturday night. There's a roster. Whoever's on call has the emergency mobile. The agent should give that mobile number — well, ring it and patch through actually — but ONLY for genuine emergencies. Not for someone who wants to know our prices at midnight.

**Leo:** What's a "genuine emergency" in your words?

**Anna:** Trauma — they got hit, they fell off a bike, knocked tooth out. Severe swelling — face swollen, can't open mouth, that kind of thing. Severe pain that's keeping someone awake — we'd rather see them than have them suffer. Lost crown or filling on a front tooth where they've got an event the next morning, sometimes we'll fit them in. Pain on a tooth we worked on that week — that's our problem, we deal with it. NOT: routine pain that's been there a few days, NOT: cosmetic queries, NOT: appointment-rescheduling, NOT: pricing questions.

**Leo:** Got it. Tools you use — walk me through.

**Anna:** Praktika is the practice management system. Bookings, patient files, all of it. It's the source of truth. We also use HICAPS for health-fund claims but the agent doesn't need to touch that. Email goes through Microsoft 365. We do appointment reminders via SMS but they go out from Praktika directly. We use Xero for accounts but that's also Megan-only.

**Leo:** So Praktika is the big one — bookings and patient lookups.

**Anna:** Yes. The dream is the agent looks up the existing patient by phone number, sees their next appointment, can move it, can book a new one if they're new. For new patients it creates the file in Praktika and slots them into a check-up-and-clean.

**Leo:** Brand voice?

**Anna:** Warm. Friendly. Not stiff. We get a lot of nervous patients and we don't want a robot voice making them more nervous. It should sound like Megan — calm, reassuring, "we'll sort you out." Australian. Not American.

**Leo:** Anything the agent should never say?

**Anna:** Don't quote prices. We don't list them on the site for a reason — every mouth's different. If someone asks for a price, the answer is "we'll give you a quote at the consultation, the new-patient consult is $99 and that includes the X-rays." Don't give clinical advice. Don't speculate about whether something is or isn't an emergency — let the dentist judge. Don't compare us to other practices.

**Leo:** Compliance — anything I should know about?

**Anna:** AHPRA registration applies to the dentists, but I don't think the agent says anything that would touch that. Privacy — we handle patient health information so the privacy stuff is real. We disclose recording on calls already, we have a hold message that says it.

**Leo:** Volume?

**Anna:** Mondays are insane — maybe 80 calls between 8 and 1. Tuesday and Wednesday are normal, maybe 30 a day. Thursday picks up again. Friday is half-day. Saturdays we get a lot of emergency-ish calls. Total weekly probably 200–250 calls.

**Leo:** Operating hours for the agent — when should it be answering?

**Anna:** All the time. 24/7. Daytime when Megan's busy it picks up the overflow. After hours and weekends it handles everything until I or one of the team gets to it Monday.

**Leo:** Last question — what's the kind of call that goes wrong today?

**Anna:** Two things. One — Megan puts someone on hold for two minutes and they hang up. Two — we get a call at 9pm Saturday from someone genuinely in pain, and there's no path for them other than leave a voicemail nobody hears till Monday. Both of those need to be solved.

---

## Operator hints

Anna runs the practice with her partner — they own it together. She's the decision-maker. Tech-comfortable but not technical. She specifically said "make this not feel like a robot" three times in the meeting. Worth flagging in the brief that **emotional warmth is the highest-priority brand attribute** — above efficiency, above completeness. She'd rather a slightly slower agent that sounds human than a fast one that sounds canned.

Practice has been growing 15% year-on-year, they've added two chairs this year and the phone genuinely is the bottleneck. This is a high-value customer if we get it right — multi-year contract potential.

Anna will be sending direct phone extensions for the four transfer targets via email after the meeting — those weren't captured live.
