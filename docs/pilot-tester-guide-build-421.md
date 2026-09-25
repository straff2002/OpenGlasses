# OpenGlasses Field Assist — Pilot Guide

*TestFlight build 421 · September 2026 · for the pilot lead and sales*

You are the first person outside the team to use this build, and the person who will sell it. This guide is written for both jobs. Part 1 is the product as it stands in build 421: what it does, how it works on a job, and what a buyer gets. Part 2 is what you can say, what not to promise yet, and the pricing. Part 3 is a short pilot checklist, because your run on a real job is also the first time this flow has met a real phone, real glasses and a real technician. Part 4 is how to send us what you find.

---

## Part 1 · The product in build 421

### 1. One job, one conversation

A technician starts a job by voice, gives the job number when asked and hears it read back. From that moment the whole job stays in one conversation: questions to the manuals, readings, checks, photos, the sign-off and the debrief. Nothing from one job bleeds into the next.

**The Job tab.** A new tab between Chat and Settings shows the job number, time on the job with pause and resume, the units worked on, the tasks, the photos and the actions. It appears when Field Assist is licensed and on, or a job is open.

**Readings and checks by voice.** "Compressor discharge is 40 psi." Later, "actually that was 45." The app keeps the correction as the newest record, so the old value never looks current. "What have I checked?" and "what's next?" come back accurate. A check the app only recommended is never reported as done.

**More than one machine.** When the technician moves to a second unit, the app asks whether the first is finished. Evidence and readings stay with the unit they belong to.

**Evidence.** The technician chooses which photos go with the job and can record a short fault clip from the glasses. Clips are silent, default to 30 seconds and stop at 60. Nothing is attached unless chosen.

**Customer sign-off.** After the job closes, the customer signs on the phone. It is stored with the job and printed on the work order PDF. It can be skipped, unless the organisation requires it, or marked as declined. It is a record of what was agreed, not a legal e-signature, and the screen says so.

**Debrief and delivery.** The app writes a job summary. The technician sends it by Mail, Messages, WhatsApp, Telegram or the share sheet. Each channel waits for a tap, and "send all" opens each composer in turn. Anything unsent is listed under Field Sync with a Retry. An organisation can set an office endpoint that sends without the composer after the technician says "send it".

### 2. On the way to a job

Before the technician reaches site, the app briefs them on the upcoming job: the site, the serial history, and the reported fault matched against the vault's fault-code tables and manuals. Directions hand off to Maps or Waze. In the car, CarPlay offers **Brief me**, **Directions** and **Debrief**, and can brief the next job automatically when it connects. A job file sent to the technician by Mail opens straight into the app. The app never sends a job file out.

### 3. Vaults: the manuals, on the phone, staying on the phone

A vault is a folder of OEM manuals, fault codes and safety rules that the assistant searches and cites, page and section, when a technician asks.

**Anyone with a Field Assist subscription can build their own.** Import a folder from Files, and the phone indexes it, including scanned PDFs. The indexed vault answers like a bundled one.

**Publishers can distribute vaults by link or QR.** A manufacturer or dealer builds an archive, signs it and hosts it on their own site. The technician pastes the link or scans the code. The app shows what it is about to install, name, version, publisher, size and manual titles, and asks before it downloads anything. A signed archive shows **Signed by** the publisher and installs with one tap. An unsigned one carries a warning, needs a second confirmation, and is badged **Unverified source** on every job record that used it. Altered archives and revoked publishers are refused outright.

**Manuals never leave the phone.** The app has no share button, no link or QR to show and no upload. A vault export carries the technician's own edits and procedures, never the manuals. This is the line that matters to manufacturers and dealers who are nervous about where their documentation ends up.

**Housekeeping.** A single manual can be removed from a vault the technician imported. A lapsed subscription keeps installed vaults readable and removable and only blocks adding new ones.

### 4. Organisations and teams

An organisation enrols a technician's phone with a 16-character activation key, a licence code, or an enrol link or QR. Enrolment sets the AI provider and model, skips those onboarding pages and installs the organisation's vault pack. The technician sees a reduced view: Voice, Job and Settings. Administrator settings sit behind an administrator card QR or the organisation passcode. Leases renew in the background. When a technician leaves, the firm is offered its records before anything is erased, and erasure after a long lapse is something the organisation opts into.

The technician still enters the provider's API key themselves, or taps **My administrator will add this** and waits. The organisation profile never carries the key.

### 5. Long visits hold together

On the ChatGPT (Subscription) provider, a long visit no longer drops earlier readings and checks and no longer fails as the conversation grows. This was a field failure in an earlier build and is now fixed for that provider. Gemini Live and OpenAI Realtime do not yet have this protection.

### 6. Usable without sight

A blind wearer can check the assistant is ready, start a session, and hear when it starts working, breaks or recovers, all by voice, through a walkthrough at **Settings › Accessibility › Check the Assistant Is Ready**. Blind Assistant can start when the app opens. Text stays legible at the largest iOS text sizes. Wake phrases can be custom or short, the assistant can be renamed, and the speech pause and interruption behaviour are adjustable. This is unusual for a product in this category and nobody outside the team has heard it on hardware yet.

### 7. Choice of AI, including new providers

DeepSeek and Mistral AI join Anthropic, OpenAI, ChatGPT (Subscription), Gemini, Groq, xAI, OpenRouter, Qwen, MiniMax, Z.ai, Apple on-device and local models that run on the phone with no cloud key. When a model cannot search the web, the app falls back to a free search tier. Memory keeps the most recent items first and tells the user when something was not saved. "New topic" clears context on every provider.

### 8. Privacy the buyer can check

A privacy policy is published and linked from **Settings › About**. **How Your Requests Are Processed** shows which provider receives which part of a request. The app has no analytics or crash-reporting service of its own, opts out of the glasses maker's telemetry and blocks it on the phone. Browser streaming has no default relay: it refuses to start until the customer sets their own. Problem reports go by email with no account required.

### 9. Medical Compliance

A separate subscription for clinical use. Every recording file gets file protection that lets it be written while the phone is locked and seals it once closed. Recordings are excluded from backup. Audit logs and clinical exports keep full protection. Unsigned vaults are refused in Medical mode.

---

## Part 2 · Selling it

### What you can say

Every line here matches what build 421 does.

- **One job, one conversation.** Start by voice, work hands-free, close with a sign-off and a debrief, all in one thread.
- **The manuals never leave the phone.** The app can receive a vault but has no way to send one on. A manufacturer's documentation cannot be redistributed from a technician's phone.
- **A publisher can sign a vault.** Signed installs with one tap and shows who signed it. Unsigned is flagged on every job that used it.
- **Organisations enrol phones with a code.** Provider, model and vault pack arrive with enrolment. Technicians get a reduced view.
- **Sign-off on the work order.** Stored with the job, printed on the PDF.
- **Nothing reported home.** No analytics, no crash reporting of our own, glasses telemetry blocked, and the privacy policy says so.
- **Usable without sight.** Check it yourself before you say it to anyone.
- **Long visits hold together** on the ChatGPT (Subscription) provider.

### What not to promise yet

- **Field-proven.** No real job has been run on this flow yet. Until your pilot, it is in pilot, not shipping.
- **A legal e-signature.** The sign-off deliberately is not one. If a prospect needs one, tell us. It decides whether we integrate a signing provider.
- **Zero-touch enrolment.** The technician still enters the provider's key or waits for an administrator. A one-time enrolment QR from a server console is planned.
- **Fault clips to the office.** Clips are silent and stay on the phone.
- **Vault packs to buy.** The store mechanism exists but the catalogue is empty. A launch partner with a signed pack is what fills it.
- **Long sessions on every provider.** Do not promise it for Gemini Live or OpenAI Realtime.
- **Any price** until confirmed. See below.

### Pricing

The paywall shows whatever the App Store carries, and the sandbox may not match the table. Do not quote a price until we have confirmed the App Store figures with you in writing.

| Product | Intended plans | Trial |
|---|---|---|
| Field Assist (solo) | $129.99 a month, $1,299.99 a year | None |
| Field Assist Team / Enterprise | Signed licence from us, not sold in the App Store. Adds audited PDF export and organisation configuration. | Arranged per organisation |
| Medical Compliance | $9.99 a month, $99.99 a year | One week |
| Vault packs | Per-pack App Store product | Nothing listed yet |

Existing owners of the old one-time unlock keep the bundled vaults but do not get vault building. Medical Compliance has a trial and Field Assist, at roughly thirteen times the price, has none. Whether that needs a short trial or a demo vault that works without a subscription is one of the questions below.

### What we want back from prospects

1. At the intended price, who buys Field Assist as a solo technician, and what do they compare it with?
2. Which message lands first: manuals never leave the phone, one job one conversation, or usable without sight?
3. Does the lack of a Field Assist trial stop a conversation? Would a demo vault be enough?
4. Which manufacturer or dealer would be the right first partner for a signed vault pack, and what would they need to see?
5. What did a prospect ask that you could not answer from this guide?
6. Which "not yet" item came up unprompted, and how often?

Collect prospects' questions word for word where you can. They decide what the next build says on the paywall, the website and the sales material.

---

## Part 3 · Pilot checklist

You do not need to test everything. Run one real job end to end, ideally with a technician who has not been coached, and go through the short list below. About three hours in total.

### Before you start

- iPhone on **iOS 26 or later**, Meta glasses paired, build 421 from TestFlight. Note the build number under **Settings › About**.
- **ChatGPT (Subscription)** as the provider for the job run. It is the one the long-visit fix covers.
- A sandbox App Store account. TestFlight purchases are not charged.
- From us, before you start: a sandbox Field Assist subscription, a test vault folder, one signed and one unsigned vault link, and a job file sent to you by Mail. Ask for an organisation licence and administrator card only if you want to see enrolment.

Settings you will use: **Settings › Tools & Actions › Field Assist** (enable, Field Sync, On the Way to a Job) and **Settings › Tools & Actions › Custom Vaults**.

### The job run

| # | Do this | Expect |
|---|---|---|
| 1 | Say "start a job" and give the job number. | Read back correctly. One chat thread throughout. |
| 2 | Ask the vault a few questions, record readings and checks, correct one reading. | Answers cite the manual. "What have I checked?" is accurate. The corrected value is the one used. |
| 3 | Move to a second unit and say so. | The app asks whether the first is finished. |
| 4 | Pick specific photos and record a fault clip. | Only what you chose is attached. The clip is silent and stops at 60 seconds. |
| 5 | Close the job. Take the sign-off. | It lands on the job record and the PDF. |
| 6 | Send the debrief by Mail and one messaging app. Dismiss one composer without sending. | Each waits for your tap. The dismissed one shows as Unsent under Field Sync with Retry. |
| 7 | Read the debrief as if you were the customer. | Would you have sent it unedited? Note what you would change. |
| 8 | Start a second job on different equipment. | Nothing from the first job appears. |
| 9 | Open an upcoming job and listen to the brief. Try Directions. If you have CarPlay, try Brief me. Open the job file we sent by Mail. | The brief covers site, history and fault. Mail offers Open with OpenGlasses. |

### Vaults

| # | Do this | Expect |
|---|---|---|
| 10 | Import the vault folder from Custom Vaults. | It indexes and answers like a bundled vault. |
| 11 | **Add from Link or QR…**, paste the signed link, then scan the unsigned QR. Do one of them on cellular with Wi-Fi off. | Review sheet before download. Signed installs with one tap. Unsigned warns, needs a second tick, then shows Unverified source. |
| 12 | Look for any way to share a vault or manual from the phone. | There is none. If you find one, that is a bug. |

### Voice and accessibility

| # | Do this | Expect |
|---|---|---|
| 13 | With VoiceOver on and without looking, go through **Settings › Accessibility › Check the Assistant Is Ready** and start a session. | You get to a working session without sight. Note every point where you had to look. If you can do this with a blind user, that is the most valuable hour in this plan. |
| 14 | Provoke a break in a live session, for example Wi-Fi off and on. | You hear it break and recover. |

### Purchases

| # | Do this | Expect |
|---|---|---|
| 15 | Open the Field Assist paywall and the Medical Compliance paywall. | Field Assist: monthly and annual only, no trial. Medical: one-week trial. Write down the exact prices shown. |

### Intentional, not bugs

- Browser streaming refuses to start until a relay is set. There is no default.
- The Job tab is hidden unless Field Assist is on or a job is open, and it does not show the site.
- A vault export has no manuals. Importing it elsewhere stops and names the manuals to supply.
- Fault clips are silent. The sign-off is not a legal e-signature. Prices come from the App Store, not this document.
- After enrolling in an organisation you are still asked for the provider's key.

---

## Part 4 · Sending us what you find

Use **Settings › Diagnostics & Support › Email Report**. It attaches the app's diagnostics and needs no account. One report per problem is easier for us than one long one.

Include the build number, the step from Part 3, what you said or did, what you expected, what happened, and the time. A short screen recording of a voice exchange is worth more than a description of it.

Send the things that worked but felt wrong too: a read-back you did not trust, a question that interrupted at a bad moment, a summary you would not have sent. Those are answers to the questions in Part 2 as much as bugs.

**Rate it:** Blocker if you could not continue or lost work. Major if the result was wrong. Minor if it was cosmetic or slow.

**At the end:** phone and iOS version, glasses model, build number, provider used, and your answers to the six questions in Part 2.
