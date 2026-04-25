# Test Stub — Narrow-Scope (Google Ads Inbound Appointment Setter)

> **Purpose:** Sanity-check the discovery methodology against a customer who has explicitly defined a narrow scope. The methodology must skip transfer questions, skip multi-persona breakdowns, skip brand-voice depth for "general inquiries," and focus tightly on appointment-booking specifics.

---

## Scrape summary (Stage 3 brain-doc shape)

**Business:** Northside Spinal Care
**Trading name:** Northside Spinal
**One-line pitch:** Chiropractic clinic in Brisbane's northern suburbs, specialising in lower-back and sciatic-nerve cases.

**Services:**
- Initial chiropractic consultation (60 min, includes assessment + first adjustment)
- Standard chiropractic adjustment (30 min)
- Massage therapy (separate practitioner, separate booking)
- Postural assessment (90 min, niche service)

**Hours from website:**
- Mon, Wed, Fri: 7:00am – 7:00pm
- Tue, Thu: 9:00am – 5:00pm
- Saturday: 8:00am – 12:00pm
- Sunday: closed

**Staff named on site:**
- Dr. Nathan Chen (chiropractor, owner)
- Lisa Bowen (massage therapist)
- Karen Yip (front desk)

**Locations:** 312 Coronation Drive, Stafford QLD 4053.

**Existing contact:** (07) 3552 1188, hello@northsidespinal.com.au

**Tone markers from site:** Clinical-but-friendly. Lots of educational content about lower back pain, sciatica, posture. Photos of Dr. Chen with patients in adjustment positions.

**Marketing footprint:** Google Ads campaign visible on the site (UTM-tagged landing page for "Brisbane chiropractor" and "lower back pain Brisbane"). Site has a clear "Book new patient consult" CTA with online booking via Cliniko.

---

## Meeting transcript (excerpt — ~10 minutes)

**Leo:** Nathan, what do you want this voice agent to do?

**Nathan:** OK so this is going to be very specific. I don't want a full receptionist. Karen handles all of that during the day and she's great at it. What I want is — we're spending a few thousand a month on Google Ads, sending traffic to a landing page, and a chunk of those leads call instead of using the online booking form. Right now they hit voicemail outside Karen's hours, or they get put on hold, and they ring the next chiro on the list.

**Leo:** So the agent's job is just those Google Ads phone calls?

**Nathan:** Yes. Specifically: someone calls the number on the Google Ads landing page, the agent picks up, qualifies them — make sure they're a real new-patient inquiry not a sales call or an existing patient — and books them in for an initial consultation. That's it. Nothing else. If they're an existing patient ringing about a sore back, the agent should say "let me put you through to our regular line" and end the call. If they're trying to sell us something, take a message.

**Leo:** Just to confirm — you don't want it handling existing patients, you don't want it handling massage bookings, you don't want it doing transfers to staff?

**Nathan:** Correct. None of that. Karen handles all of that on the regular line. This is a separate dedicated number that ONLY runs on the Google Ads landing page. The agent's whole world is "is this a new patient calling about back pain or sciatica or general chiro? If yes, book them in for an initial consult. If no, get them off the line politely."

**Leo:** What hours should it run?

**Nathan:** All the time. The whole point is to catch the calls Karen misses — after hours, weekends, when she's on lunch, when she's on another call. 24/7.

**Leo:** Calendar — Cliniko?

**Nathan:** Yes. Cliniko's the booking system. New patient consult is 60 minutes, I'm the only chiropractor for those. The agent needs to look at my Cliniko diary, find available initial-consult slots, and book one. Cliniko has the API.

**Leo:** What info do you need captured at booking?

**Nathan:** Name, mobile number, email if they have one, what's bothering them — like a one-line "lower back pain" or "neck stiffness" — and where they heard about us. That last one's important because I want to track which Google Ads campaigns are actually converting calls into booked appointments. So like, "did you find us on Google?" and capture the answer in the booking notes.

**Leo:** What about pricing — they're going to ask?

**Nathan:** Initial consult is $145, includes the assessment and first adjustment. The agent can quote that. Subsequent visits start at $75 — but the agent shouldn't quote those because once they're a patient they're out of this agent's scope. Just the initial consult price.

**Leo:** Anything the agent should never say?

**Nathan:** Don't give clinical advice. Don't tell someone whether their condition is or isn't suitable for chiro — that's for me to decide at the consult. Don't compare us to other clinics. Don't speculate on whether their insurance will cover it — direct that to the consult.

**Leo:** Compliance?

**Nathan:** AHPRA stuff for me but doesn't really touch what the agent does. Just the no-clinical-advice line.

**Leo:** Volume?

**Nathan:** Maybe 8–15 calls a week from the Ads landing page. Currently we lose probably half of them to voicemail or to a hold queue. If the agent gets us 5 extra booked initials a week that's a serious ROI.

**Leo:** Brand voice?

**Nathan:** Professional, calm, reassuring. People calling about back pain are often grumpy because they're sore. Don't be peppy. Match their energy — calm and competent.

---

## Operator hints

This is a **narrow scope by design** — Nathan is sophisticated, knows exactly what he wants, and explicitly does NOT want a full receptionist agent. He has Karen for that. The agent runs on a dedicated DID that's only published on the Google Ads landing page.

The methodology should NOT ask Nathan about:
- Transfer targets to other staff (out of scope — only the polite "ring our regular line" handoff)
- After-hours emergency numbers (no clinical emergencies handled here — that's the regular line's job)
- Multiple caller personas (one persona only: a Google-Ads-driven new-patient inquiry)
- Brand voice across multiple call types (one tone, one call type)
- Integrations beyond Cliniko (Cliniko is the only one in scope)

The methodology SHOULD drill deep on:
- Cliniko integration specifics (which calendar, which appointment type, what fields, where the source-attribution note goes)
- Qualifying questions (what makes someone a real new-patient inquiry vs. a sales call vs. an existing patient on the wrong number)
- The exact info captured at booking (name, mobile, email, presenting complaint, source)
- The "off-ramp" behaviour for out-of-scope callers (existing patients, sales calls)
- Initial consult pricing (the only price the agent quotes)

If the discovery prompt comes back asking Nathan about transfer targets or weekend emergency numbers or massage bookings, **the scope-inference rule has failed.** Those are explicit out-of-scope items per the meeting.
