# Transcripts and support reports: using and testing

*OpenGlasses · September 2026 builds from branch `claude/practical-volta-bm5prc` · Plans FO (transcript export), FV (support reports) and FW (live modes, planned)*

This guide is for two readers: whoever runs support for the pilot, and whoever tests the build before it reaches technicians. Part 1 says what the features do and how to use them. Part 2 is a test script with expected results.

> **Build status.** This code was written without a Swift compiler available, so the first build is the one CI runs on the pull request. Treat the first TestFlight build as a test build.

## Part 1 — Using it

### What's new

1. **Transcripts.** Export everything said on a job, or on every job on a day, as a text file.
2. **AI turn records.** For every request to the AI, the phone keeps a record without the words: which model answered, how the speech was transcribed, the parts of the AI's instructions by size, the manual pages and photos that went with it, tools used, timings, and whether it failed. Kept 14 days, on the phone only.
3. **Support reports.** The transcript plus the turn records, the job's own log, the phone and glasses, and the app's event log, with keys and tokens masked. Reviewed on screen, then emailed to support with the file attached.
4. **Send to support after an error.** When an AI request fails, a banner offers to send a report.

Nothing is ever sent automatically. Every route ends with the person reading the file and tapping Send.

### Where to find it

| To do this | Go here |
|---|---|
| Export one job's transcript | **Job** tab → a past job → **Export transcript…** → **Transcript** |
| Send one job to support | **Job** tab → a past job → **Export transcript…** → **Support report with troubleshooting details** |
| Export or report a whole day | **Job** tab → **Past jobs** → **Export a day…** → pick a day → **Transcript** or **Support report…** |
| Report today, from anywhere | **Settings** → **Diagnostics & Support** → **Send Today's Activity** |
| Report straight after a failure | the **That didn't work** banner → **Send to support** |
| Delete the turn records | **Settings** → **Diagnostics & Support** → **Delete AI Turn Records** |

The day list shows the 14 most recent days that have jobs. **Send Today's Activity** works whether or not Field Assist is on.

### The review sheet

Every support report opens on a review sheet before anything leaves the phone:

- **Include conversations outside jobs** (day reports only; on by default). Turn it off to send job conversations only.
- **What's in it:** counts of jobs, conversation lines and AI turns, and how many turns failed.
- **Masked before you saw it:** the kinds of secret the masking pass found, if any.
- **Email to Support:** opens Mail addressed to support, with the report attached and room to add a note. If the phone has no Mail account, the share sheet opens instead and the sheet says where to send it.
- **Share the File…:** Messages, Files, AirDrop, or another app.
- **The file:** the report itself. Long reports show the start; the attachment is always the whole file.

The file on the phone is deleted as soon as the share finishes or is cancelled.

### The error banner

When an AI request fails, a banner appears at the top of whatever tab is open, for example:

> **That didn't work** — 10:42 — the AI service was busy (rate-limited). **Send to support**

**Send to support** opens the review sheet for that day, with everything included. Dismissing the banner (×) keeps it from coming back for 10 minutes, so a run of failures during an outage doesn't keep interrupting.

The reasons shown are plain versions of the error category: no internet connection; the AI service took too long; couldn't be reached; refused the key; was busy (rate-limited); had an error; the AI's reply couldn't be read; the app refused the request. The exact category is in the report.

### Reading a report

Each job starts with its number, the machine if identified, the outcome, the vault and the times. After that, one timeline:

```
09:13  Technician: What's the gas pressure on this one?
09:13  · AI turn answered
           model: anthropic / claude-… · transcribed by onDevice · mic: glasses
           sent: the words above + instructions of 5500 characters (system prompt 4000,
                 field assist: vault, job and manual passages 1500) + a photo
           manual pages: Lennox SLP99 IOM, page 12
           tools: lookup_part (completed)
           timing: first output after 1.2 s, reply complete after 3.4 s,
                   heard 4.1 s after speech ended
09:14  Assistant: 3.5 inches water column.
09:20  [job] task started — Replace the flame sensor
09:30  · AI turn FAILED — rateLimited#429
```

- **Technician / Assistant** lines are the conversation. *[with photo]* marks a message that carried an image.
- **· AI turn** blocks sit under the line they answered. "sent" names what went with the words: each part of the AI's instructions by name and size (not its text), the manual pages by citation, and whether a photo went. *transcribed by* is the speech engine: `onDevice` (on-device SenseVoice) or `appleSpeech`.
- **· Turn handled by the app (no AI request)** is a voice command the app answered itself.
- **[job]** lines come from the job's own log: tasks, parts, identity fields, citations opened, escalations.
- After the jobs: **Outside a job** conversations (day reports, if included), **Other AI turns** that have no saved conversation, **This phone** (app version, iOS, device, language, mode, AI model, transcription preference, glasses), **App events** for the period, and the newest **Debug log** lines.

A line saying *the assistant's replies for this job are no longer on the phone* means the job's conversation was deleted; only the technician's words from the job log remain.

### What a report does not contain

- **Audio.** It is never kept. The transcript is what the speech engine produced.
- **The text of the AI's instructions.** Only their parts by name and size, because the instructions can carry the wearer's saved memories and other personal context.
- **Live voice modes (Gemini Live, OpenAI Realtime).** These modes keep no conversation on the phone. In a job only the technician's words reach the job log; outside a job nothing is kept; the assistant's replies are kept nowhere. There are no turn records for them and no banner. Plan FW proposes an opt-in **Keep live conversations** setting to change this. **Run the pilot in normal (Direct) mode.**
- **Anything when turn recording is off** (Developer panel): no turn records.

### Privacy, in one paragraph

Turn records hold no words and stay on the phone for 14 days (at most 2,000), protected and excluded from backups, and they are deleted when the phone leaves its organisation. A support report contains conversations, so it is only made when someone taps to make one, is shown in full first, has keys and tokens masked, and is only sent by the person sending it. The public privacy page (`privacy.html`) describes both.

## Part 2 — Testing it

### Before you start

- Install the build from this branch on an iPhone. Use normal (**Direct**) mode for everything except test 13.
- Field Assist on, with a vault that has manuals (the Lennox example vault works), and a cloud AI model with a working key. Don't set up an on-device fallback model for tests 4 and 5, or the fallback may answer instead of failing.
- A Mail account on the phone for test 6. Test 6b needs a phone, or a second profile, without one.
- Glasses are optional. Without them, speak to the phone or type in chat.
- Note the phone's time zone. Report times are the phone's local time with the UTC offset in the header.

### Tests

Each test lists steps and the expected result. Record pass/fail, the build number and anything unexpected.

**1. Job transcript.** Start a job, ask two questions that use the manual, close the job. Job tab → the job → Export transcript… → Transcript → save to Files.

*Expected:* header, then the job heading; both questions and answers, stamped HH:mm, as Technician/Assistant; no "AI turn" lines; no "This phone" section.

**2. Job support report.** Same job → Export transcript… → Support report with troubleshooting details.

*Expected:* review sheet shows 1 job, the line count and the AI turn count; the file has an **AI turn answered** block under each question with the model, "transcribed by", instruction parts including *field assist: vault, job and manual passages*, the manual pages cited, and timings; [job] lines for the job's events; This phone and App events at the end.

**3. Day report with outside-job conversations.** Outside a job, ask the assistant something unrelated. Then Settings → Diagnostics & Support → Send Today's Activity.

*Expected:* the file includes **Outside a job: …** with that exchange. Turn **Include conversations outside jobs** off: the sheet rebuilds and the section disappears.

**4. Banner after a failure.** Turn on Airplane Mode (keep Bluetooth if using glasses), ask a question.

*Expected:* the spoken error as before, and the banner *That didn't work — [time] — no internet connection.* Tap Send to support: the day's review sheet, with an **AI turn FAILED — offline…** line and a *[time] An AI turn failed…* note at the top. Turn Airplane Mode off before sending.

**5. Dismiss quiet period.** Force another failure, dismiss the banner with ×, force a third failure within 10 minutes.

*Expected:* no banner for the third. After 10 minutes, a new failure brings it back.

**6. Email to support.** From any review sheet, tap Email to Support.

*Expected:* Mail opens to the support address, subject = report title, the report attached as a .txt, body with the reason (if any) and "Anything else you noticed:". After Send the sheet says *Report sent. Thank you.*; after Cancel it says *Not sent.*

**6b.** On a phone with no Mail account: the share sheet opens and the sheet says where to send it.

**7. Masking.** With an API key configured, type a chat message containing the exact key (or a long part of it), then make today's support report.

*Expected:* the key is replaced by a mask in the file, and **Masked before you saw it** names what was masked. Delete that chat afterwards.

**8. Locked conversations.** Settings → turn on conversation encryption, lock the app (background it), then export a transcript.

*Expected:* Face ID prompt. Cancel it: *Conversations are locked. Unlock them with Face ID to export what was said.*

**9. Deleted conversation.** Delete a past job's conversation in the Chat tab, then export that job's transcript.

*Expected:* the technician's words only, under the note that the assistant's replies are no longer on the phone.

**10. Photo turn.** Ask "take a photo and tell me what this is" (glasses or phone camera).

*Expected:* in the support report, that turn's block says **+ a photo**, and the Technician line starts with *[Photo]* (a photo command) or is marked *[with photo]* (a frame sent with an ordinary question).

**11. Records survive a restart.** Make two turns, force-quit the app, reopen it, make today's support report.

*Expected:* both turns' blocks are present.

**12. Delete AI Turn Records.** Settings → Diagnostics & Support → Delete AI Turn Records; the row shows *Deleted*. Make today's report.

*Expected:* no AI turn blocks for earlier turns; jobs with conversation show the *No AI turn records* note.

**13. Live mode limitation (expected gap).** Switch to Gemini Live, start a job, talk, end the session, make the job's support report.

*Expected, as documented:* the technician's words from the job log only, no assistant replies, no AI turn blocks, and no banner if you force a failure. Record it as a known gap (Plan FW), not a bug.

**14. Nothing sent without a tap.** During all of the above, watch for anything leaving without the Send button.

*Expected:* nothing. Reports only leave through Mail or the share sheet.

### Automated tests

On the pull request, CI runs these suites along with the rest:

- `JobTranscriptExportTests`: transcripts, day selection, turn blocks under their lines, prompt parts, manual pages, tools, timings, failures, job-log events, outside-job conversations, masking, and a turn that never reached the AI.
- `TurnTraceTests`: outcome mapping, dating, model naming, 14-day and 2,000-turn retention, saving and erasing, the recorder hooks, off-turn isolation, the banner's wording.
- `DataStoreRegistryTests`: the new store's protection and backup exclusion match the registry, and the privacy matrix is regenerated.
- `Scripts/check-privacy-logging.sh`: no content in logs.

### Reporting a problem with this feature

Use **Send Today's Activity** and add a note saying which test failed. If the report itself won't build, use **Report a Problem** in the same screen.
