# OpenGlasses Field Assist — Pilot Tester Guide

*TestFlight build 421 · September 2026 · for external pilot testers*

Thank you for testing. This build carries a lot of new Field Assist work, most of which has only been exercised in automated tests so far. Your run on a real phone, real glasses and a real job is the first one, which is why your notes matter more than anything else we can do in the office.

This guide tells you what you need before you start, what to try, what to expect, what is intentional so you do not report it, and how to send us what you find. You do not need any developer tools. Budget about six to eight hours for the whole plan, or use the priority list in section B to pick what fits the time you have.

Because you also carry sales and marketing, section H sets out what this build lets you say to a prospect, what not to promise yet, and the commercial questions we would like your view on once you have used it.

---

## A. Before you start

### What you need

| Item | Notes |
|---|---|
| iPhone on **iOS 26 or later** | Earlier versions cannot install this build. |
| **Meta smart glasses**, paired | Ray-Ban Meta, Oakley Meta or Ray-Ban Display. Most of the plan also works from the phone camera if you are without glasses for a stretch. |
| **TestFlight** with build 421 installed | Check the build number under **Settings › About** before you begin, and put it in every report. |
| An **AI provider account** | For the long-session tests (area 2) use **ChatGPT (Subscription)**. Any other provider works for the rest. |
| **Sandbox App Store account** | TestFlight purchases are sandbox purchases. You will not be charged. |
| Optional: **a car with CarPlay** | For the on-the-way-to-a-job checks in area 1. |
| Optional: **a spare iPhone** | Only for the organisation offboarding test in area 3, which erases data. Do not run it on your main phone. |

### Ask us for these before you start

We can only issue them from our side. Ask early so they are waiting when you reach that area.

1. A **Field Assist subscription in the sandbox**, or confirmation that your sandbox account can buy one (area 1, 4 and 9).
2. A **test organisation licence or activation key**, plus the **administrator card QR** and **organisation passcode** (area 3).
3. **Two test vault links**, one signed and one unsigned, and a **vault folder** you can import from Files (area 4).
4. A **job file** (`.ogjob`) sent to you by Mail (area 1, step 10).
5. Medical Compliance needs nothing from us. Its one-week sandbox trial is enough for area 7.

### Settings paths used in this guide

The paths below are written as you will see them in the app.

- **Settings › Tools & Actions › Field Assist** — enable Field Assist, licence, Field Sync, On the Way to a Job
- **Settings › Tools & Actions › Custom Vaults** — import, receive by link or QR, export, remove a manual
- **Settings › AI Models** — providers and keys
- **Settings › Accessibility** — Check the Assistant Is Ready, Opening the App, How Your Requests Are Processed
- **Settings › Voice** — Listen for Wake Phrase, custom wake phrase, assistant name
- **Settings › About › Privacy Policy**
- **Settings › Diagnostics & Support › Email Report** — how you send us findings

---

## B. Where to spend your time

If you cannot do everything, work down this list.

| Priority | Area | Why | Time |
|---|---|---|---|
| 1 | **Area 1**, guided job flow | The largest change in the build, and never yet run on a device | 2 to 3 hours, ideally on a real job |
| 2 | **Area 2**, long sessions | The fix for an earlier field failure. Your run is what confirms it. | 1 hour |
| 3 | **Area 6**, VoiceOver and accessibility | The one thing we most need a human ear for, ideally with a blind user | 45 minutes |
| 4 | **Area 4** steps 3 to 5, and **area 9** | Receiving a vault by QR over cellular, and the paywall prices | 30 minutes |
| 5 | **Area 3**, organisation enrolment | Only once we have issued you a licence | 45 minutes |
| 6 | **Areas 5, 7 and 8** | Provider, privacy and reliability spot checks | 1 hour |

---

## C. How to report what you find

Use **Settings › Diagnostics & Support › Email Report**. It attaches the app's own diagnostics and needs no GitHub account. One report per problem is easier for us than one long report at the end.

Each report should say:

- **Build number** and the **area and step** from this guide, for example "Area 1, step 4".
- **What you did**, in the words you used if it was by voice.
- **What you expected** and **what happened** instead.
- **Provider and model** in use, and whether you were on glasses or the phone camera.
- A **screenshot or screen recording** where one helps. A short recording of a voice exchange is worth more than a description of it.
- The **time** it happened, so we can match it to the diagnostics.

Please also send the things that worked but felt wrong: a read-back you did not trust, a question that interrupted you at a bad moment, a summary you would not have sent as written. Those go in the feedback questions in section E, or in a report if they were specific.

Rate each problem as you see it:

- **Blocker** — you could not continue, lost work, or the app crashed.
- **Major** — wrong result, wrong data, or a feature that does not do what this guide says.
- **Minor** — cosmetic, awkward wording, a delay that did not stop you.

---

## D. Intentional behaviour, not bugs

These will look like problems. They are by design in this build, so you do not need to report them unless they behave differently from what is described here.

- **Browser streaming refuses to start until you set a relay.** The relay addresses are blank on purpose. There is no default relay any more.
- **The Job tab is hidden** unless Field Assist is licensed and switched on, or a job is open.
- **The Job tab does not show the site.** The site appears only on an upcoming job's page.
- **A vault cannot be shared from the phone.** There is no share button, no link or QR to show, and no upload. Vaults arrive by folder, or by a link or QR code from a publisher. If you find any way to send a vault or a manual from the phone, that is a bug and we want to hear about it.
- **A vault export never contains the manuals.** They stay on the phone that indexed them. Importing the export on another phone stops and names the manuals it needs.
- **Customer sign-off is not a legal e-signature.** The screen says so. It is a record of what was agreed.
- **Fault clips are silent**, default to 30 seconds and stop at 60. A clip is never selected for you, and an organisation's office endpoint does not carry clips.
- **The long-session fix covers ChatGPT (Subscription) only.** Gemini Live and OpenAI Realtime may still drop earlier facts in long conversations. Note what happens on them rather than expecting them to pass.
- **After enrolling in an organisation you are still asked for the provider's key**, unless you tap **My administrator will add this**. The organisation profile never carries the key.
- **There is no one-time enrolment QR from a server console yet.** The administrator card unlocks administrator settings. It does not enrol a phone.
- **Field Assist "locked screen"** in this guide means the screen you see inside Field Assist when you are not licensed. It is not the iOS Lock Screen.
- **Paywall prices come from the App Store**, not from this document. Sandbox prices can differ from what we intend. Write down exactly what you see.
- **Older conversations may still quote a manual you removed.** That is expected.
- **The vault pack store is empty.** The mechanism is there, but there are no packs to buy yet.

---

## E. Test plan

Each area has a short note on what is new, then numbered steps with the expected result. Record pass, fail or a note against each step. Where something has never been tried on a real device, the note says so. Those are the steps we most want you to reach.

### Area 1 · Guided job flow and the Job tab

**What is new.** A job now lives in one conversation from start to finish. You start it by voice, give the job number when asked and hear it read back. A new **Job** tab between Chat and Settings shows the job number, time on the job with pause and resume, the units, tasks, photos and actions. Evidence is chosen per job, with silent fault clips. Moving to another machine mid-job prompts a "is the previous unit finished?" check. After you close the job you are offered a customer sign-off, then a debrief you can send by Mail, Messages, WhatsApp, Telegram or the share sheet, each waiting for your tap. Upcoming jobs get a spoken brief before you arrive, with directions through Maps or Waze and CarPlay actions.

**Never run on a device yet.** The whole flow. Everything below is a first.

| # | Do this | Expect |
|---|---|---|
| 1 | Start a Field Assist session and say "start a job". Give the job number when asked. | The number is read back correctly. Everything that follows stays in one chat thread, not two. |
| 2 | Open the **Job** tab. Pause the timer, then resume it. | Job number, time on the job, unit(s), tasks and photos are shown and correct. The site is not shown here. |
| 3 | Ask a few questions the vault can answer. Record some readings and checks by voice. Later ask "what have I checked?" and "what's next?". | Readings and checks come back as you gave them. A check that was only recommended is never reported as done. |
| 4 | Correct an earlier reading, for example "actually that was 45, not 40". | Later answers use 45. The old value never looks current. |
| 5 | Move to a second unit and say so. | The app asks whether the first unit is finished. |
| 6 | Attach evidence. Pick specific photos, not "all recent", and record a fault clip. | Only the photos you chose are attached. The clip is silent, was not pre-selected, and stops at or before 60 seconds. |
| 7 | Close the job and take the customer sign-off. Then, on another job, skip it. On a third, mark it declined. | Each outcome lands on the right job record and PDF. The sign-off screen says it is not a legal e-signature. |
| 8 | Send the debrief by Mail, Messages, WhatsApp and Telegram. Dismiss one composer without sending. | Each channel waits for your tap. The dismissed one shows the job as **Unsent** and appears under **Settings › Tools & Actions › Field Assist › Field Sync** with a **Retry**. |
| 9 | Run two jobs back to back on different equipment. | Nothing from the first job appears in the second: no readings, no photos, no unit names. |
| 10 | Open an upcoming job and listen to the brief. Try **Directions** in Maps and in Waze. If you have a car, try the CarPlay **Brief me**, **Directions** and **Debrief** actions. Open the `.ogjob` file we sent by Mail. | The brief covers the site, serial history and the reported fault matched to the vault's fault codes. Mail offers **Open with OpenGlasses** for the job file. The file does not open while Field Assist is switched off. |

If you can, run steps 1 to 9 on a real job with a technician who has not been coached on the app. Their reactions are the most valuable data in this plan. Note where they hesitated, what they repeated and what they ignored.

### Area 2 · Long sessions and continuity

**What is new.** On the **ChatGPT (Subscription)** provider, long visits no longer silently drop earlier readings and checks, and the conversation no longer fails as it grows. Corrections are kept as newer records. A check that was only recommended is never reported as done.

**Not yet confirmed on a real account or real glasses.** This is the test that confirms the fix.

| # | Do this | Expect |
|---|---|---|
| 1 | Select **ChatGPT (Subscription)**. With a vault active, run 30 or more exchanges: identify the equipment, record readings, correct one, and switch procedure part-way through. | No errors as the conversation grows. |
| 2 | Ask "what have I checked so far?" and "what's next?" several times during the session. | The answers stay accurate the whole way through. |
| 3 | Say "I'm now on the second unit". | Evidence and readings from the first unit are not attributed to the second. |
| 4 | Send the app to the background mid-job, then return. Then end the job and start a new one. | The job resumes where it was. Nothing from the old job leaks into the new one. |
| 5 | Ask for a measurement you recorded early in the session. | It comes back with the right value and units. |
| 6 | Optional: repeat a shorter version on **Gemini Live** or **OpenAI Realtime**. | These are not covered by the fix. Note what happens rather than expecting a pass. |

### Area 3 · Organisation enrolment

**What is new.** A phone can be enrolled by typing or scanning a 16-character activation key or licence code, or from the organisation's enrol link or QR. The provider and model come from the organisation profile and those onboarding pages are skipped. The organisation's vault pack installs at enrolment. A technician sees a reduced view. Leases renew. Offboarding offers the firm its records before anything is erased.

**Needs a licence from us.** Do not test the one-time server-console QR. It is planned, not built.

| # | Do this | Expect |
|---|---|---|
| 1 | Enrol by typing the key we issued, then again by scanning its code. | Both routes enrol the phone. |
| 2 | Check the provider and model. | They are pre-set from the organisation profile and the onboarding pages for them are skipped. You are then asked for the provider's key. Try entering it, and separately try **My administrator will add this**. |
| 3 | Check the vaults. | The organisation's vault pack has installed. |
| 4 | Look at the tabs and try to open administrator settings. | The technician view shows only **Voice**, **Job** and **Settings**. Administrator Settings need the administrator card QR or the organisation passcode. |
| 5 | If we can shorten your lease for the test, wait for it to renew. | A pending vault pack survives the renewal. |
| 6 | **Spare phone only.** Offboard the phone. | The firm's records are offered for delivery before anything is erased. Erasure happens only if the organisation opted in. |

### Area 4 · Vaults: build, receive by link or QR, remove a manual

**What is new.** A Field Assist subscriber can build vaults of their own. A vault can be received from a publisher's link or QR code, with a review sheet before anything downloads and a signed or unsigned status. One manual can be removed from a vault you imported yourself.

**Not yet confirmed on a device.** Receiving a vault by QR over cellular.

| # | Do this | Expect |
|---|---|---|
| 1 | With a subscription, import the vault folder we gave you from **Settings › Tools & Actions › Custom Vaults**. | It indexes and answers like a bundled vault. If you also hold the old one-time unlock, that alone must not allow this. A lapsed subscription keeps vaults readable and removable but blocks new imports. |
| 2 | Swipe a vault and tap **Export**. Look inside the export. Import it on another phone. | The export contains no manual text or PDFs. The import stops and names the manuals to supply. After you copy them into `documents/`, it installs. |
| 3 | **Custom Vaults › Add from Link or QR…** and paste the test link. | The app shows only the site, never the full address, and asks before it downloads anything. |
| 4 | Same screen, **Scan a QR code**. Then scan the same code with the iPhone Camera app. Do this once on cellular with Wi-Fi off. | Both routes open the app on that screen and download over cellular. |
| 5 | Read the review sheet for the signed link, then for the unsigned one. | It shows name, version, site, size and manual titles. The signed archive shows **Signed by <publisher>** and installs with one tap. The unsigned one shows a highlighted warning, needs a second tick, and is then badged **Unverified source** in the list and in the job record of any session that uses it. |
| 6 | Try to break it: cancel a download part-way, and if we give you an altered or revoked link, try it. | Cancelling leaves nothing installed. An altered archive and a revoked publisher are refused. In Medical mode, unsigned archives are refused. Archives over 250 MB are refused. |
| 7 | Look for any share, send, link or QR option on a vault. | There is none. Report it if you find one. |
| 8 | **Custom Vaults › Remove manual…** on a vault you imported yourself. | Only that manual goes. The option does not appear on a signed pack. |

### Area 5 · AI providers and models

**What is new.** DeepSeek and Mistral AI are new providers. The OpenAI provider no longer fails every turn. Saving account-based and optional-key providers works. Web search falls back to a free tier when the model cannot search. Memory keeps recent items first and tells you when something was not saved. "New topic" clears context on every provider. Downloadable local models show correct sizes and clear preparation phases.

| # | Do this | Expect |
|---|---|---|
| 1 | Add DeepSeek and Mistral AI keys in **Settings › AI Models**. | Both save and can be made active. |
| 2 | Ask the OpenAI provider a normal question. Open **Edit Model**. | The question is answered with no error. Edit Model shows a key is saved. |
| 3 | Save an account-based or optional-key provider set-up. | It saves. |
| 4 | With a model that cannot search, ask something that needs today's information. | It falls back to web search rather than erroring. |
| 5 | Turn memory off and ask the app to remember something. Turn it on, add several memories and fill it up. | With memory off, nothing is remembered and tools respect that. With memory on, recent memories come first, and you are told when something was not saved. |
| 6 | On Gemini Live or OpenAI Realtime, say "new topic", then ask something that only makes sense with the old context. | It does not know. |
| 7 | Optional: download a local model. | The size shown is realistic before the download starts, and preparation shows named phases rather than sitting at "Downloading 99%". |

### Area 6 · Voice and accessibility

**What is new.** Text stays legible at the largest Dynamic Type sizes. A non-visual walkthrough lets a blind wearer check set-up and start a session. The app speaks when a session starts working, breaks or recovers. Blind Assistant can start when the app opens. Spoken answers no longer cut off on the loudspeaker. There is a **Listen for Wake Phrase** switch, custom and short wake phrases, a renamable assistant, and a choice of speech pause length. Text-to-speech uses a voice in your chosen language. Live sessions no longer leave a fake call in the Phone app's recents.

**Never heard on hardware yet.** This is the area where we most need a human, ideally a blind user.

| # | Do this | Expect |
|---|---|---|
| 1 | Set the largest accessibility text size in iOS. | The home status card, the home grid and the read-aloud button do not truncate or overlap. |
| 2 | With VoiceOver on and without looking at the screen, complete onboarding and start a session through **Settings › Accessibility › Check the Assistant Is Ready**. | You can get from a fresh install to a working session without sight. Note every point where you had to look. |
| 3 | Relaunch the app with VoiceOver on. | The launch screen is not announced. |
| 4 | Run a live session and provoke a break, for example by turning Wi-Fi off and on. | You hear when it starts working, when it breaks and when it recovers. |
| 5 | On the phone loudspeaker, ask for a long answer. Try the **Listen for Wake Phrase** switch and set a custom wake phrase. | Long answers do not cut off. The wake phrase behaves as set. |
| 6 | Turn on **Settings › Accessibility › Opening the App › Start Blind Assistant When I Open the App** and relaunch. | Blind Assistant starts on launch. |
| 7 | After a live session, open the Phone app's recents. | There is no "OpenGlasses Assistant" call listed. |

### Area 7 · Privacy and compliance

**What is new.** A privacy policy is published and linked from Settings. "How Your Requests Are Processed" shows which provider receives which part of a request. Problem reports can be emailed without a GitHub account. There is no default browser-streaming relay. Medical Compliance recordings are protected while the phone is locked and excluded from backup.

| # | Do this | Expect |
|---|---|---|
| 1 | **Settings › About › Privacy Policy**. | The link opens. Read it against what you have seen the app do, and tell us if it claims more or less than that. |
| 2 | Open **How Your Requests Are Processed** under **Settings › Accessibility**. | It gives a specific answer for the provider you are using. |
| 3 | Send an **Email Report** from **Settings › Diagnostics & Support**. | It does not ask for a GitHub account. |
| 4 | Start browser streaming with no relay set. | It refuses to start and points you to Settings. This is intended. Tell us whether the message made it clear what to do. |
| 5 | Start the Medical Compliance trial. Make a recording, lock the phone while it is running, then stop it. | The recording is saved and listed afterwards. |

### Area 8 · Reliability spot checks

**What is new.** Pressing Stop while the camera is warming up is no longer lost. A paused stream is waited out rather than restarted. The wake word reports the right ready state. Purchase recovery and the entitlement check at startup are fixed. In live modes, the job state sent to the model and to the Watch is no longer one change behind.

| # | Do this | Expect |
|---|---|---|
| 1 | Start a camera session and press Stop while it is still warming up. | No crash, and it does not restart by itself. |
| 2 | Lock and unlock the phone several times mid-session. | The stream resumes rather than restarting from scratch, and no stale error banner remains. |
| 3 | Use the wake word several times in a row, including interrupting mid-answer. | It does not get stuck listening or not listening, and the ready indicator matches what it is doing. |
| 4 | If you have an Apple Watch, record a job number by voice in a live mode and look at the Watch. | The Watch shows the new job number straight away, not the previous state. |
| 5 | During any long session, watch for a crash or freeze. | If one happens, send an Email Report as soon as you can with the time. |

### Area 9 · Purchases (sandbox)

**What is new.** Field Assist is sold as a monthly or annual subscription with no free trial. The one-time unlock is no longer sold. The Medical Compliance paywall shows only Medical plans, with a one-week trial. Purchase recovery at startup is fixed.

| # | Do this | Expect |
|---|---|---|
| 1 | Open the Field Assist paywall. | Only monthly and annual are shown, with no one-time option and no trial. Write down the exact prices. We expect $129.99 a month and $1,299.99 a year, but the sandbox decides. |
| 2 | Open the Medical Compliance paywall. | Only Medical plans, each with a one-week free trial. We expect $9.99 a month and $99.99 a year. |
| 3 | Buy Field Assist, delete the app, reinstall it, and tap **Restore Purchases**. | Field Assist comes back at startup without a second tap. |
| 4 | On Field Assist's locked screen, tap **Remove Stored Code**. | The stored licence code is cleared. |
| 5 | If your sandbox subscription lapses or you can cancel it, check the vaults. | Installed vaults stay readable and removable. Only adding new ones is blocked. |

---

## F. Feedback questions

Answer these at the end, in the Email Report or by reply. Short honest answers are best.

1. How long did it take before you trusted the job number read-back, and did you ever check it on screen?
2. Did the "different unit, is the previous one finished?" question help, or did it interrupt at the wrong moments?
3. Was the debrief good enough to send without editing? If not, what did you have to change?
4. Would you rather receive vaults as a folder, by link or QR, or through your organisation?
5. Where did the voice assistant misunderstand you, and what did you say the second time that worked?
6. Which single thing would stop you using this on a real job tomorrow?

---

## G. Results sheet

Copy this into your final report.

| Area | Steps passed | Steps failed | Not reached | Blockers found |
|---|---|---|---|---|
| 1 Guided job flow | | | | |
| 2 Long sessions | | | | |
| 3 Organisation enrolment | | | | |
| 4 Vaults | | | | |
| 5 Providers and models | | | | |
| 6 Voice and accessibility | | | | |
| 7 Privacy and compliance | | | | |
| 8 Reliability | | | | |
| 9 Purchases | | | | |

Phone model and iOS version: ______  Glasses model: ______  Build number: ______  Provider used most: ______

---

## H. For sales and marketing

You will be the first person to have used this build who also has to explain it to a buyer. This section is what we can stand behind today, what is still ahead of us, and what we would like you to test on prospects as well as on equipment.

### What you can say about this build

Every claim here matches what the app does in build 421. Say them in your own words.

- **A job is one conversation.** The technician starts a job by voice, works through it hands-free, and closes it with a sign-off and a debrief, all in one thread.
- **The manuals never leave the phone.** The app can receive a vault from a publisher, but it has no way to send a vault or a manual on. A vault export carries the technician's own edits and procedures, never the OEM manuals. Manufacturers and dealers who are nervous about their documentation should hear this early.
- **A publisher can sign a vault.** A signed vault installs with one tap and shows who signed it. An unsigned one is flagged as an unverified source on every job record that used it.
- **Organisations can enrol phones.** A licence code or enrol link sets the provider, model and vault pack, and a technician sees a reduced view. The administrator settings are behind a card or passcode.
- **The customer sign-off is a record on the work order.** It is stored with the job and printed on the PDF.
- **Nothing is reported home.** The app has no analytics or crash-reporting service of its own, opts out of the glasses SDK's telemetry and blocks it, and the privacy policy says so.
- **It is usable without sight.** A blind wearer can check the set-up, start a session and hear the assistant's state change, all by voice. Few products in this category can say that. Please test it before you say it, because nobody has heard it on hardware yet.
- **Long visits hold together** on the ChatGPT (Subscription) provider. Earlier readings, corrections and checks stay correct as the job goes on.

### What not to promise yet

- **Field-proven.** Nothing in the job flow has been through a real job on a real phone. Until your pilot run, describe it as in pilot, not as shipping.
- **A legal e-signature.** The sign-off is deliberately not one. If a prospect needs one, tell us; it decides whether we integrate a signing provider.
- **Zero-touch enrolment.** An enrolled technician still enters the provider's key or waits for an administrator to add it. The one-time enrolment QR from a server console is planned.
- **Fault clips to the office.** Clips are silent and stay on the phone. They do not go through an organisation's office endpoint.
- **Vault packs to buy.** The store mechanism exists, but the catalogue is empty. A launch partner with a signed pack is what would fill it.
- **Long sessions on every provider.** The continuity fix covers ChatGPT (Subscription). Do not promise it for Gemini Live or OpenAI Realtime.
- **Any price.** See below.

### Pricing

The paywall shows whatever the App Store carries, and the sandbox may not match what you see below. Do not quote a price to a prospect until we have confirmed the App Store Connect figures with you in writing.

| Product | Intended plans | Trial |
|---|---|---|
| Field Assist (solo) | Monthly $129.99, annual $1,299.99 | None |
| Field Assist Team / Enterprise | Signed licence from us, not sold in the App Store | Arranged per organisation |
| Medical Compliance | Monthly $9.99, annual $99.99 | One week |
| Vault packs | Per-pack App Store product | None listed yet |

Medical Compliance has a trial and Field Assist, at roughly thirteen times the price, has none. Whether that needs a short trial or a demo vault that works without a subscription is one of the questions below.

### Questions we want your view on

1. At the intended price, who buys Field Assist as a solo technician, and what do they compare it with?
2. Which message lands first with a prospect: manuals never leave the phone, one job one conversation, or the accessibility story?
3. Does the lack of a Field Assist trial stop a conversation? Would a demo vault without a subscription be enough?
4. Which manufacturer or dealer would be the right first partner for a signed vault pack, and what would they need to see?
5. What did a prospect ask that you could not answer from this guide?
6. Which of the "not yet" items above came up unprompted, and how often?

Collect the questions prospects ask you during the pilot, word for word where you can. They are the best guide we have to what the next build should say on the paywall, the website and the sales material.
