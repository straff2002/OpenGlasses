# OpenGlasses / Field Assist

## Build 378 → Build 421: what's new, and what to check

*Prepared 25 September 2026 for pilot testers · covers TestFlight builds 378 (11 September) to 421 (current)*

Part A is what changed for the user in this range, written the way you would explain it to a technician or a buyer. Part B is the validation plan, in the same order, so every feature in Part A has matching steps in Part B. Everything here was checked against the app as built. Where the team has not yet seen something work on a real phone, real glasses or a real account, it is marked **Owed a device run**. Those are the items pilot testing closes.

---

# Part A · What's new

## 1. Guided job flow and the new Job tab

The biggest change in this range. A field job is now one conversation from the moment the technician says "start a job" to the moment the debrief is sent.

- **Start by voice, number read back.** The technician says the job number when asked and hears it read back. The whole job stays in one chat thread.
- **A new Job tab**, between Chat and Settings, shows the job number (or that it is still owed), time on the job with pause and resume, the units, the tasks, the photos and the actions. It appears when Field Assist is licensed and switched on, or a job is open. The site is shown on an upcoming job's page, not here.
- **Readings and checks by voice**, with corrections handled properly. "Actually that was 45, not 40" is kept as the newer record, so the old value never looks current. "What have I checked?" and "what's next?" answer from what happened. A check the app only recommended is never reported as done.
- **The different-unit check.** Move to a second machine mid-job and the app asks whether the first is finished.
- **Evidence you choose.** Pick which photos go with the job and record a short fault clip from the glasses. Clips are silent, default to 30 seconds and stop at 60. Nothing is attached unless chosen.
- **Customer sign-off** after the job closes. Stored with the job record and printed on the work order PDF. It can be skipped, unless the organisation requires it, or marked declined. It is a record of what was agreed, not a legal e-signature, and the screen says so.
- **Debrief and delivery queue.** Send the job summary by Mail, Messages, WhatsApp, Telegram or the share sheet. Each waits for a tap. "Send all" opens each composer in turn. Anything unsent is listed under **Settings › Tools & Actions › Field Assist › Field Sync** with a Retry. An organisation can set an office endpoint that sends without a composer after the technician says "send it".
- **Job ahead.** Before arriving, the technician gets a brief: the site, the serial history, and the reported fault matched against the vault's fault-code tables and manuals. Directions hand off to Maps or Waze. CarPlay offers **Brief me**, **Directions** and **Debrief**, and can brief the next job when it connects (off by default, under **On the Way to a Job**). A job file sent by Mail opens into the app. The app never sends a job file out.
- **Fixed.** The wake word re-arms properly and a job no longer splits into two chats. Saying "open a new job 108" no longer pops up an unrelated manual page that happened to contain the number. The camera no longer loops on a stream that never delivers a frame.
- **Long visits hold together** on the ChatGPT (Subscription) provider: earlier readings and checks are no longer silently dropped, and the conversation no longer errors as it grows. This was a real field failure and is now fixed for that provider. Gemini Live and OpenAI Realtime are not yet covered.

> **Owed a device run.** No real job has been run start to finish on a phone, in a car or on glasses, and not by an uncoached technician. The earlier long-visit failure has not been reproduced on a real account or real glasses either. Both are what Part B sections 1 and 2 are for.

## 2. Vaults: build your own, receive by link or QR

- **Subscribers can build vaults.** Import a folder of manuals from Files and the phone indexes it, scanned PDFs included. This used to need a team licence.
- **Receive a vault from a publisher.** A manufacturer or dealer builds and signs an archive and hosts it on their own site. The technician pastes the link or scans the QR code. The app shows what it is about to install, name, version, publisher, size and manual titles, and asks before it downloads. Signed installs with one tap and shows **Signed by** the publisher. Unsigned shows a warning, needs a second tick, and is badged **Unverified source** in the list and on every job record that used it. Altered archives, revoked publishers and archives over 250 MB are refused. Medical mode refuses unsigned archives.
- **Nothing is shared from the phone.** There is no share button, no link or QR to show, no upload. A vault export carries the manifest, core files, the technician's edits and procedures, but never the manuals. They stay on the phone that indexed them.
- **Remove one manual** from a vault you imported yourself, without removing the vault. Not offered for manuals in a signed pack.
- **Lapsed subscription** keeps installed vaults readable and removable. It only blocks adding new ones.

## 3. Organisation and multi-technician management

New in this range. A firm can manage a fleet of phones instead of every technician setting up their own.

- **Enrol a phone** by typing or scanning a 16-character activation key or licence code, or from the organisation's enrol link or QR.
- **Provider and model come from the organisation profile.** Those onboarding pages are skipped. The phone still asks for that provider's key or sign-in, unless the technician taps **My administrator will add this**. The profile never carries the key.
- **The organisation's vault pack installs at enrolment.**
- **Technicians see a reduced view**: Voice, Job and Settings. An administrator card QR or the organisation passcode unlocks Administrator Settings.
- **Leases renew**, and a pending vault pack survives a renewal.
- **Offboarding.** The firm is offered its records for delivery before anything is erased. Erasure after a long lapse is something the organisation opts into. A backup taken before erasure can still hold the firm's content.

> **Not built yet.** A one-time enrolment QR generated from a server console. The administrator card unlocks admin settings; it does not enrol a phone. You need a licence or activation key issued by the team to see any of this.

## 4. AI providers and models

- **New providers:** DeepSeek and Mistral AI.
- **Fixed:** the OpenAI provider failed every turn with an error. A saved key now also shows in Edit Model. Saving account-based and optional-key providers works.
- **Web search** falls back to a free search tier when the model cannot search.
- **Memory:** recent memories surface first, the oldest drop first when full, and the app says when something was not actually remembered. Tools respect memory being off.
- **"New topic"** now clears context on Gemini Live, OpenAI Realtime, the gateway and the bridge, as ChatGPT already did.
- **Local models:** sizes shown for downloads are correct (which also fixes the free-space check), and preparation shows named phases instead of sticking at "Downloading 99%".

## 5. Voice and accessibility

- **Legible at the largest text sizes** on the home screen and the read-aloud button.
- **A non-visual walkthrough** at **Settings › Accessibility › Check the Assistant Is Ready** lets a blind wearer check set-up and start a session without looking.
- **The app speaks** when a session starts working, breaks or recovers. VoiceOver no longer reads the launch screen.
- **Blind Assistant can start when the app opens** (Settings › Accessibility › Opening the App).
- **Voice controls:** spoken answers no longer cut off on the loudspeaker. New **Listen for Wake Phrase** switch. Custom or short wake phrases. Rename the assistant, choose the speech pause length and whether speaking interrupts it. Text-to-speech uses a voice in your chosen language.
- **Tidier:** live sessions no longer leave a fake "OpenGlasses Assistant" call in the Phone app's recents. Speech from a remote agent says who sent it. Scan Assist reminds you when scanning from the side.

> **Owed a device run.** Nobody has heard any of this on hardware. A VoiceOver pass on a real phone, ideally with a blind user, is the most directly requested human test in this range.

## 6. Privacy and compliance

- **A real privacy policy** is published and linked from **Settings › About**. Wording that claimed too much was corrected.
- **How Your Requests Are Processed** (Settings › Accessibility, and Glasses & Privacy) shows which provider receives which part of a request.
- **No default browser-streaming relay.** Relay addresses are blank until set in Settings, and streaming refuses to start until then. It looks like a regression. It is intended.
- **Medical Compliance:** every recording file gets file protection that allows writing while the phone is locked and seals it once closed. Recordings are excluded from backup. Audit log and clinical exports keep full protection.
- **Email a problem report** without a GitHub account, from **Settings › Diagnostics & Support**.

## 7. Reliability

- Pressing Stop while the camera is warming up is no longer lost.
- A paused camera stream is waited out instead of restarted, so it no longer sticks after repeated pause and resume.
- The wake word no longer reports the wrong ready state.
- Crash breadcrumbs are kept for diagnosis.
- Field Assist purchase recovery and the startup entitlement check are fixed.
- In live modes, the job state sent to the model and to the Watch was one change behind. Fixed.

## 8. Pricing and licences

| Product | Plans in this build | Notes |
|---|---|---|
| Field Assist (solo) | $129.99 a month, $1,299.99 a year | Auto-renewing App Store subscriptions, no free trial. Includes building your own vaults and adding vaults by link. |
| Field Assist Team / Enterprise | Not sold in the App Store | Signed licence from the team. Adds audited PDF export and organisation configuration. |
| Medical Compliance | $9.99 a month, $99.99 a year | One-week free trial on both. Its paywall now shows only Medical plans. |
| Vault packs | Per-pack App Store product | The mechanism exists, but the catalogue is empty. Nothing to buy yet. |

The paywall shows the live App Store price, not this table, and the figures are not yet final. Report exactly what TestFlight shows, and do not quote a price to a prospect until the team confirms it in writing. The stored licence code can be removed from Field Assist's locked (unlicensed) screen. That is the screen inside Field Assist, not the iOS Lock Screen.

## 9. For selling it

**You can say:** one job, one conversation. Manuals never leave the phone, and the app cannot redistribute them. Publishers can sign vaults, and unsigned ones are flagged on every job. Organisations enrol phones with a code. Sign-off on the work order. No analytics or crash reporting of our own, glasses telemetry blocked, and a published privacy policy that says so. Usable without sight.

**Do not promise yet:** field-proven (that is what the pilot is for), a legal e-signature, zero-touch enrolment, fault clips to the office, vault packs to buy, long-session continuity on providers other than ChatGPT (Subscription), or a price.

**Worth asking prospects:** which of those messages lands first, whether the lack of a Field Assist trial stops a conversation, and which manufacturer or dealer would be the right first signed-pack partner.

---

# Part B · Validation plan

Use the app on a phone and glasses. No code or developer tools. Sections match Part A. Each step has the expected result; record pass, fail or a note.

**Before you start.** iPhone on iOS 26 or later, glasses paired, build 421 from TestFlight (build number under Settings › About). Use **ChatGPT (Subscription)** for sections 1 and 2. Ask the team for: a sandbox Field Assist subscription, a vault folder, a signed and an unsigned vault link, a job file by Mail, and, if you want section 3, a licence or activation key with the administrator card and passcode.

**Reporting.** **Settings › Diagnostics & Support › Email Report**, one per problem, with the build number, the section and step, what you said or did, what you expected, what happened, and the time. A short screen recording of a voice exchange beats a description of it. Send the things that worked but felt wrong too.

## 1. Guided job flow and the Job tab (highest priority)

| # | Do this | Expect |
|---|---|---|
| 1 | Start a Field Assist session and say "start a job". Give the number when asked. | Read back correctly. One chat thread for the whole job. |
| 2 | Open the Job tab. Pause and resume the timer. | Job number, time, unit(s), tasks and photos correct. No site here. |
| 3 | Ask the vault a few questions. Record readings and checks by voice. Later ask "what have I checked?" and "what's next?". | Accurate. A recommended check is never reported as done. |
| 4 | Correct an earlier reading: "actually that was 45, not 40". | Later answers use 45. |
| 5 | Move to a second unit. | The app asks whether the first is finished. |
| 6 | Pick specific photos and record a fault clip. | Only your choices attached. Clip silent, not pre-selected, 60 seconds at most. |
| 7 | Close the job. Take the sign-off. On other jobs, skip it and mark it declined. | Each lands on the right job record and PDF. |
| 8 | Send the debrief by Mail, Messages, WhatsApp and Telegram. Dismiss one composer. | Each waits for your tap. The dismissed one shows Unsent under Field Sync with Retry. |
| 9 | Run two jobs back to back on different equipment. | Nothing from job A appears in job B. |
| 10 | Open an upcoming job and listen to the brief. Try Directions in Maps and Waze. CarPlay Brief me, Directions and Debrief if you have a car. Open the job file from Mail. | Brief covers site, history and fault. Mail offers Open with OpenGlasses. The file does not open while Field Assist is off. |

> **Owed a device run:** all of it, ideally one real job with an uncoached technician, CarPlay on the road, and the job file opened from Mail on a phone.

## 2. Long sessions and continuity

| # | Do this | Expect |
|---|---|---|
| 1 | On ChatGPT (Subscription) with a vault active, run 30 or more exchanges: identify equipment, record readings, correct one, switch procedure part-way. | No error as the conversation grows. |
| 2 | Ask "what have I checked so far?" and "what's next?" several times. | Accurate the whole way through. |
| 3 | Say "I'm now on the second unit". | First-unit evidence is not attributed to the second. |
| 4 | Background the app mid-job and return. Then end the job and start a new one. | Resumes correctly. Nothing leaks into the new job. |
| 5 | Ask for a measurement from early in the session. | Right value, right units. |
| 6 | Optional: a shorter run on Gemini Live or OpenAI Realtime. | Not covered by the fix. Note what happens. |

> **Owed a device run:** this is the pass the earlier failure is waiting on.

## 3. Organisation enrolment (needs an issued licence)

| # | Do this | Expect |
|---|---|---|
| 1 | Enrol by typing the key, then by scanning its code. | Both enrol the phone. |
| 2 | Check provider and model. | Pre-set, onboarding pages skipped, then asked for the provider's key. Try entering it and try **My administrator will add this**. |
| 3 | Check vaults. | The organisation's pack installed. |
| 4 | Check tabs and admin access. | Voice, Job and Settings only. Admin needs the card QR or passcode. |
| 5 | If the team can shorten the lease, wait for renewal. | A pending pack survives it. |
| 6 | **Spare phone only:** offboard. | Records offered before erasure. Erasure only if the organisation opted in. |

## 4. Vaults

| # | Do this | Expect |
|---|---|---|
| 1 | Import the vault folder at **Settings › Tools & Actions › Custom Vaults**. | Indexes and answers like a bundled vault. A lapsed subscription keeps it readable but blocks new imports. |
| 2 | Swipe a vault › Export. Import the export on another phone. | No manual text or PDFs in the export. The import stops and names the manuals to supply. |
| 3 | **Add from Link or QR…**, paste the signed link. | Shows only the site, asks before downloading, review sheet, **Signed by**, one-tap install. |
| 4 | Scan the unsigned QR in the app, then with the iPhone Camera app. Do one on cellular with Wi-Fi off. | Both open the app on that screen. Warning, second tick, then **Unverified source**. |
| 5 | Cancel a download part-way. | Nothing installed. |
| 6 | Look for any share, send or QR option on a vault. | None. Report it if you find one. |
| 7 | **Remove manual…** on a vault you imported. | Only that manual goes. Not offered on a signed pack. |

> **Owed a device run:** receiving a vault by QR over cellular.

## 5. AI providers and models

| # | Do this | Expect |
|---|---|---|
| 1 | Add DeepSeek and Mistral AI keys in Settings › AI Models. | Both save and can be made active. |
| 2 | Ask the OpenAI provider a normal question. Open Edit Model. | Answered, no error. A saved key is shown. |
| 3 | With a model that cannot search, ask something that needs today's information. | Falls back to web search. |
| 4 | Memory off: ask it to remember something. Memory on: add several and fill it. | Off: nothing remembered. On: recent first, and told when something was not saved. |
| 5 | On Gemini Live or OpenAI Realtime, say "new topic", then ask something that needs the old context. | It does not know. |

## 6. Voice and accessibility

| # | Do this | Expect |
|---|---|---|
| 1 | Largest accessibility text size. | Home status card, grid and read-aloud button do not truncate or overlap. |
| 2 | VoiceOver on, without looking: onboarding and a session via **Check the Assistant Is Ready**. | A working session without sight. Note every point you had to look. |
| 3 | Relaunch with VoiceOver on. | Launch screen not announced. |
| 4 | Provoke a break in a live session (Wi-Fi off and on). | You hear it start, break and recover. |
| 5 | Loudspeaker, long answer. Try Listen for Wake Phrase and a custom wake phrase. | No cut-off. Wake phrase behaves as set. |

> **Owed a device run:** the whole section, ideally with a blind user. Please prioritise it.

## 7. Privacy and compliance

| # | Do this | Expect |
|---|---|---|
| 1 | Settings › About › Privacy Policy. | Opens, and does not claim more than the app does. |
| 2 | How Your Requests Are Processed. | A specific answer for your provider. |
| 3 | Email Report. | No GitHub account needed. |
| 4 | Browser streaming with no relay set. | Refuses to start and points to Settings. Intended. Say whether the message was clear. |
| 5 | Medical Compliance trial: record, lock the phone mid-recording, stop. | Saved and listed afterwards. |

## 8. Reliability spot checks

| # | Do this | Expect |
|---|---|---|
| 1 | Start a camera session and press Stop while it is warming up. | No crash, no self-restart. |
| 2 | Lock and unlock the phone several times mid-session. | Stream resumes, does not restart, no stale error banner. |
| 3 | Wake word several times in a row, including interrupting mid-answer. | Never stuck listening or not listening. |
| 4 | Any long session. | Note any crash or freeze and send an Email Report with the time. |

## Priority if time is short

1. Sections 1 and 2: the newest work, and explicitly waiting on a device run.
2. Section 6: a VoiceOver pass on real hardware.
3. Section 4 steps 3 to 5 (vault by QR over cellular).
4. Section 3 if the team issues a licence, then 5, 7 and 8.

## Intentional, not bugs

Blank streaming relay. Job tab hidden unless Field Assist is on or a job is open, and no site on it. No way to share a vault from the phone. Export without manuals. Silent clips. Sign-off is not a legal e-signature. Still asked for the provider's key after enrolling. Prices come from the App Store. Older conversations may still quote a removed manual.

## Questions to answer at the end

1. How long before you trusted the job number read-back, and did you check it on screen?
2. Did the "is the previous unit finished?" question help, or interrupt at the wrong moments?
3. Was the debrief good enough to send without editing?
4. Would a technician rather get vaults by folder, by link or QR, or through their organisation?
5. Which selling point in section A9 would you lead with, and what would a prospect push back on?
