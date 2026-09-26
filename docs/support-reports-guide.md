# Transcripts and support reports

*OpenGlasses · a guide for support · September 2026*

## What's new

1. **Transcripts.** Save everything said on a job, or on every job in a day, as a text file.
2. **Support reports.** A transcript with extra detail for troubleshooting: which AI answered, how long it took, which manual pages it used, and whether anything went wrong. Passwords and keys are hidden automatically.
3. **Send to support after a problem.** When the assistant fails to answer, the app offers to send a report.

Nothing is ever sent on its own. The person always sees the report first and taps Send.

## Where to find it

| To do this | Go here |
|---|---|
| Save one job's transcript | **Job** tab → tap a past job → **Export transcript…** → **Transcript** |
| Send one job to support | **Job** tab → tap a past job → **Export transcript…** → **Support report with troubleshooting details** |
| Save or send a whole day | **Job** tab → **Past jobs** → **Export a day…** → pick a day → **Transcript** or **Support report** |
| Send today to support, from anywhere | **Settings** → **Diagnostics & Support** → **Send Today's Activity** |
| Send straight after a problem | tap **Send to support** on the **That didn't work** banner |

## The review screen

Every support report opens on a review screen first. It shows:

- how many jobs and conversations are in the report, and how many times the assistant failed;
- anything that was hidden, such as a password;
- the report itself, to scroll through.

Two buttons send it:

- **Email to Support** opens an email to support with the report attached. You can add a note before sending.
- **Share the File…** sends it another way, such as Messages or AirDrop.

For a whole day, a switch lets you include or leave out conversations that weren't part of a job.

## When something goes wrong

If the assistant can't answer, a banner appears at the top of the screen:

> **That didn't work** — 10:42 — no internet connection. **Send to support**

Tap **Send to support** to open the review screen for that day. Tap **×** to dismiss it; it won't appear again for 10 minutes.

## Reading a report

Each job starts with its job number, the machine, and when it started and finished. Then everything that happened, in time order:

```
09:13  Technician: How do I check the flame sensor?
09:13  · AI turn answered
           manual pages: Lennox SLP99 manual, page 12
           timing: reply complete after 3.4 s
09:14  Assistant: Turn the power off, then remove the sensor ...
09:30  · AI turn FAILED — offline
```

- **Technician** and **Assistant** lines are the conversation.
- **AI turn** lines show what happened behind the scenes for the line above: which AI answered, which manual pages it used, whether a photo was sent, and how long it took. **FAILED** marks a problem.
- At the end there are details about the phone and glasses, for the support team.

## What a report doesn't include

- **Recordings.** The app never keeps audio, only the written transcript.
- **The live conversation modes** (Gemini Live and OpenAI Realtime). These don't save conversations yet, so use the normal voice mode for the pilot.

## Privacy

The app keeps a record of each AI request for 14 days, on the phone only. It contains no conversation, just timings, pages used and errors. It can be deleted in **Settings** → **Diagnostics & Support** → **Delete AI Turn Records**. A support report does contain conversations, so it is only made when someone asks for one, and only sent when they send it.

## Demo walkthrough

This takes about 15 minutes and covers everything a technician or office user needs to know. Run it once yourself, then use it to show others.

**Before you start**

- The app is installed, and **Field Assist** is switched on with a vault loaded.
- The phone is online, and the Mail app is set up with an email account.
- The app is in its normal voice mode, not Gemini Live or OpenAI Realtime.

### 1. Do a short job (3 minutes)

1. Open the **Job** tab, type **1001** in **Job number**, and tap **Start job**.
2. Ask the assistant two questions, for example *"How do I check the flame sensor?"* and *"What's the normal gas pressure?"*
3. Tap **Close job** and confirm. When asked for a customer signature, tap **Close without a signature**.

*You should see:* Job 1001 in the **Past jobs** list.

### 2. Save the transcript (2 minutes)

1. In **Past jobs**, tap **Job 1001**.
2. Tap **Export transcript…**, then **Transcript**.
3. Choose **Save to Files** (or AirDrop it to a computer) and open the file.

*You should see:* your two questions and the assistant's two answers, each with the time.

### 3. Send the job to support (3 minutes)

1. Open **Job 1001** again and tap **Export transcript…**.
2. This time tap **Support report with troubleshooting details**.
3. Scroll through the review screen. Point out the **AI turn** lines under each question.
4. Tap **Email to Support**. For the demo you can cancel instead of sending.

*You should see:* an email to support with the report attached.

### 4. Show what happens when something goes wrong (3 minutes)

1. Turn on **Airplane Mode**.
2. Ask the assistant a question.
3. The assistant says it couldn't answer, and the **That didn't work** banner appears.
4. Tap **Send to support**. Show the **FAILED** line in the report.
5. Turn **Airplane Mode** off, then tap **Email to Support**.

*You should see:* the banner, then a report that shows the failure.

### 5. Send today's activity from Settings (1 minute)

1. Go to **Settings** → **Diagnostics & Support**.
2. Tap **Send Today's Activity**.

*You should see:* the same review screen, covering everything from today, including chats outside jobs.

### 6. Points to make while demoing

- Nothing leaves the phone until you tap Send.
- Passwords and keys are hidden automatically.
- If a customer reports a problem, ask the technician to tap **Send Today's Activity**. It takes one minute and gives support the whole picture.

### If something doesn't work as described

Send **Today's Activity** from **Settings** → **Diagnostics & Support**, and write in the email which step didn't work.
