# Plan MX — Whole-Meeting Captions (a summary of the whole meeting, a running summary that stays the same size, a kept session that survives a crash, and captions that do not restart)

**Status:** 🚧 P0–P2 built 2026-11-21 (headless). P3, the device pass, is owed: nothing here has
run on a phone yet. P0: the caption service keeps every final of the session in memory and
`meeting_summary` reads all of it, handing the model a budgeted excerpt spread across the whole
meeting; the meeting assistant sends the last summary and the new lines instead of the whole
transcript. P1: a kept caption session in progress is checkpointed every 30 s and recovered after
a crash, under **Keep caption sessions** only and never in Medical Compliance mode. P2: plain
captions run on iOS 26's `SpeechAnalyzer` when the locale's model is installed, with
`SFSpeechRecognizer` as the fallback. Seven build decisions were taken in the build and are listed
for review below.
**Track:** Captions and meetings.
**Builds on:** Plan [KP](KP-answers-you-can-act-on.md) P5 (kept caption sessions,
`CaptionSessionStore`); Plan [KT](KT-cards-ready-to-act.md) (`MeetingSummaryFacts`,
`LatestMeetingSummary`); Plan [MO](MO-live-hints.md) §2, §6 and §8 (the analysis sink, the caption
voice gate, session contextual strings); Plan BY (caption compaction); Plan W v2 (presence
suspension); Plan [ET](ET-iso27701-privacy.md) (the data-store registry).

---

## Trigger

After an hour-long meeting, "summarise the meeting" summarised the last few minutes.
`meeting_summary` built everything — duration, word count, action items, decisions, topics, the
saved note and `LatestMeetingSummary` — from `AmbientCaptionService.captionHistory`, which holds 50
entries for the screen. Separately, the meeting assistant pasted its whole, unbounded transcript
into every 60-second prompt, so a long meeting outgrew a small or on-device model; captions
restarted `SFSpeechRecognizer` after every final result and every error, losing the audio of each
restart; and nothing of a session in progress survived the app being killed.

## What existed (verified 2026-11-21 on `origin/main` f04ec646d)

- **The history.** `captionHistory` is newest first, capped at `maxHistory = 50`, kept through
  `stop()` and emptied only by `clearHistory()`. The screen, the lens and every cursor-based
  consumer (`CaptionCursor`) read it.
- **The tool.** `MeetingSummaryTool.summarize` read `captionHistory`, so every number it gave, the
  facts it extracted and the "last 20 segments" transcript it returned were of at most 50 lines.
- **The assistant.** `MeetingAssistantService` kept `fullTranscript` (every line since start) and
  sent all of it every round through `MeetingAnalysisSink.prompt(transcript:recent:)`. Two
  callers: a recording's assistant (`AppState.meetingAssistant`, through the audio and video
  recorders) and a live-hints lecture (`LiveHintsService.lectureAssistant`).
- **Kept sessions.** `CaptionSessionRecorder` collects a session in memory while the switch is on
  (`turnCap` 5,000 lines, about eight hours) and `CaptionSessionStore.keep` writes it at stop. A
  crash lost it.
- **The recogniser.** `startRecognitionSession()` tears down and starts a new
  `SFSpeechAudioBufferRecognitionRequest` after every final result; errors restart after 0.5 s.
  The Speech framework's `SpeechAnalyzer` was not used anywhere.

## Design

### 1 · The whole session, in memory (P0)

`MeetingTranscriptBuffer` is a small value type: every final caption of the session, oldest first,
with what a `CaptionEntry` carries (text, time, speaker id, original words and language). The
caption service appends to it at the same two doors as `captionHistory`: `finalizeCaption`, after
`TranscriptGuard`, and `insertVisualNote`. It is emptied at `start()` and by `clearHistory()`, and
kept through `stop()`, because the summary is usually asked for after captions stop. It is bounded
at `CaptionSessionRecorder.turnCap`; past that the oldest line goes and `dropped` counts it, and
the summary says so.

It is memory only, exactly like `captionHistory`. It has no `Codable`, no file, no log, and it is
not a kept session: `CaptionSessionIsolationTests` still passes untouched, and a scrape
(`AmbientCaptionMeetingTranscriptTests`) holds that nothing but the caption service and the tool
names it.

### 2 · The summary reads all of it (P0)

`meeting_summary` takes a main-actor snapshot of the buffer, with each diarized line named as the
speaker registry names it now, and reads it for the duration, the word and segment counts, the
action items, decisions and topics (`facts(from:)`, unchanged), `LatestMeetingSummary` and the
saved note.

The transcript it hands the model is `MeetingTranscriptExcerpt`, a pure, deterministic selection:

- The whole meeting, when it fits the budget.
- Otherwise the lines the local extraction read an action item or a decision from go first (up to
  half the budget); then the meeting is cut into 12 equal stretches of time and each gets an equal
  share of what is left, taken as a run from the start of the stretch, with what one stretch leaves
  passing to the next.
- The header says what was done: `TRANSCRIPT (412 of 1,980 lines shown, 14:02–15:10; 1,568 lines
  left out to fit, the rest taken from across the whole meeting, every action-item and decision
  line is included):`.

The budget is a quarter of the active model's context window at three characters a token, from
`ModelContextWindow.resolve` (the same resolution the tool exposure uses), between 2,000 and 48,000
characters. An unknown window takes 3,000, which is also what a 4k on-device model gets.

### 3 · The running summary stays the same size (P0)

`MeetingAnalysisWindow` replaces `fullTranscript`: the lines since the last round (the newest kept
within 6,000 characters), a 1,200-character tail of what came before them, and the summary part of
the last reply (1,500 characters). The sink is asked `prompt(for: MeetingAnalysisRound)`.

- A recording's first round sends exactly the prompt it always did. Later rounds send "Running
  summary so far" and "New since the last update" in place of the transcript, and ask for the
  same `SUMMARY:` / `QUESTIONS:` reply, which is posted unchanged.
- A lecture's key point reads the tail and the new lines, as before.
- A round that fails is not completed, so its lines go again next time. A round with nothing new
  is not asked: the old loop re-sent the transcript every 60 s whether anyone had spoken or not.

### 4 · A kept session survives a crash (P1)

Under **Keep caption sessions** and never in Medical Compliance mode — the store refuses both, as
`keep` does — the caption service hands the session so far to `onSessionCheckpoint` every 30 s
(when something new was said), on a presence suspension, on a mode change and when the app goes to
the background. AppState hands it to `CaptionSessionStore.checkpoint`, which writes one
`caption-checkpoint.json` in the CaptionSessions folder, replacing the last, with the same
first-unlock protection and backup exclusion. With the switch off nothing is written; a checkpoint
written earlier is removed when the switch goes off or the mode comes on.

A clean stop keeps the finished session the ordinary way and its checkpoint goes. When the store
opens (at launch), a leftover checkpoint becomes a finished session ending at its last line — or is
deleted if the switch is now off, Medical Compliance mode is on, the session began seven days ago,
it cannot be decoded, or a session with its id is already kept. Nothing is sent to a model. Delete
all removes the folder, the subject erasure reads the checkpoint as it reads a session, and the
`captionSessions` registry entry names the file. The caption service still never names the store:
the checkpoint goes through a closure, as the finished session does.

### 5 · Captions that do not restart (P2)

`CaptionEnginePolicy` decides the plain path (translation and diarization keep their precedence):
`SpeechAnalyzer` with a `SpeechTranscriber` when `Config.captionSpeechAnalyzerEnabled` (new,
default on, no UI) is on, the locale (`SpeechLocaleResolver.current`) is supported and
`AssetInventory.status` says installed. A supported locale whose model is not installed runs
`SFSpeechRecognizer` this session and asks Apple for the model in the background
(`assetInstallationRequest` → `downloadAndInstall`), once per process and locale, so the next
session has it. Any start or stream error falls back to `SFSpeechRecognizer` for the rest of the
captions session, logged through `PrivacyLog` with no words.

`SpeechAnalyzerCaptionEngine` takes the same shared-engine buffer fan-out under the same
assistant-voice gate (`addCaptionAudioConsumer`, now five paths), converts each buffer to the
analyzer's best format with `AVAudioConverter` on the audio thread, and holds up to three seconds
until the analyzer is ready so the first words are kept. Session contextual strings go in as the
analysis context. Volatile results are the live line and the lens; finals go through
`finalizeCaption`, so `TranscriptGuard`, the kept session and the meeting transcript all get them.
There is no restart on a final. Presence suspension, mode changes and `stop()` tear the engine down
and commit its live line. Captions compaction and the silence timer stay on the `SFSpeechRecognizer`
path only (see decision 5).

## Phases

| Phase | What | Status |
|---|---|---|
| P0 | `MeetingTranscriptBuffer`; `meeting_summary` over the whole session with `MeetingTranscriptExcerpt`; `MeetingAnalysisWindow` and `prompt(for:)` | ✅ Built 2026-11-21 (headless) |
| P1 | `onSessionCheckpoint`, `CaptionCheckpointPolicy`, `CaptionSessionStore.checkpoint` / `recoverCheckpoint`, the erasure and registry | ✅ Built 2026-11-21 (headless) |
| P2 | `CaptionEnginePolicy`, `CaptionAnalyzerAudioFeed`, `SpeechAnalyzerCaptionEngine`, `captionSpeechAnalyzerEnabled` | ✅ Built 2026-11-21 (headless; the live engine is device-only) |
| P3 | Device pass (below) | Owed |

### P3 · The device pass

1. **A long meeting with the phone locked.** An hour or more of plain captions, glasses connected,
   phone locked in a pocket. Check the captions keep coming through the lock (the presence gate
   suspends only when the wearer is away), the summary afterwards covers the start, the middle and
   the end, and the excerpt header's counts and times are right. Repeat with a 4k on-device model
   selected: the summary must fit.
2. **SpeechAnalyzer's first run.** On a phone that has never downloaded the model for its locale:
   the first session runs `SFSpeechRecognizer` (`engineSelected` `sfSpeech.notInstalled`), the
   download is asked for (`assetsRequested`, then `assetsInstalled`), and the next session runs the
   analyzer (`engineSelected` `speechAnalyzer`). Check the first words of a session are captioned,
   that long speech is not cut at a minute, and that finals read as natural segments.
3. **Fallback.** A locale the analyzer does not support; the switch off
   (`setCaptionSpeechAnalyzerEnabled(false)`); and a forced error (start captions, then take the
   mic away with a phone call). Each must leave captions running on `SFSpeechRecognizer`.
4. **Gate and lens.** With the assistant speaking on the phone speaker, nothing it says is
   captioned on the analyzer path; the lens shows the live line.
5. **Crash recovery.** With Keep caption sessions on, caption for two minutes, kill the app from the
   app switcher, relaunch: the session is listed, ending at its last line. Repeat with the switch
   turned off before relaunching (the checkpoint is gone, nothing kept), and in Medical Compliance
   mode (nothing written at any point).

## Tests

- `MeetingTranscriptTests` — the buffer's order, bound and reset; the excerpt whole, cut down to
  budget across the whole meeting, keeping action items and decisions, deterministic, by position
  when the times are equal; the budget from the window; number grouping; the duration.
- `AmbientCaptionMeetingTranscriptTests` — visual notes join the transcript, it outlives the capped
  history, the tool summarises all of it, finals reach it only through the guarded doors, and
  nothing but the service and the tool names it.
- `MeetingAnalysisSinkTests` — the first round's prompt is unchanged; the second sends the running
  summary and only the new lines in the same reply format; an hour of talk is still a bounded
  round with the newest kept; a failed round is sent again; lines said during a reply wait; the
  summary part is read from the notification format; the tail is bounded.
- `CaptionSessionStoreTests` — a checkpoint is replaced, not listed, removed by keeping the session
  and by a switched-off stop; never written with the switch off or in the mode; recovered at launch
  ending at its last line, once; deleted with the switch off, in the mode, after seven days, when
  unreadable or already kept; reached by Delete all and the erasure; out of backup; the checkpoint
  policy; the wiring hands it to the store alone.
- `CaptionEnginePolicyTests` — which engine, the asset status, the result mapping, the conversion
  headroom, the audio waiting for the analyzer and converted to its format, and from the source:
  translation and diarization before the analyzer, no restart on an analyzer final, the gate, and
  the teardown committing the live line.
- `CaptionAudioGateTests` — five gated caption paths.

## Decisions taken in the build (for review)

1. **The excerpt budget** is a quarter of the model's window at three characters a token, 2,000 to
   48,000 characters, 3,000 when the window is unknown. *Why:* the excerpt is evidence beside a
   summary already worked out on the phone, not the record; a quarter leaves a small model room for
   its prompt and reply.
2. **Past the cap the oldest line goes**, rather than the transcript stopping as the kept session
   does. *Why:* a summary of "the meeting" after nine hours should include its end; the summary
   says how many lines are no longer held.
3. **Speaker names in the excerpt.** The excerpt and the saved note now carry the speaker's name
   on diarized lines, as `CaptionEntry.labeledText` describes; the facts are read from the plain
   words as before.
4. **No round when nothing was said.** The meeting assistant used to post a notification every
   60 s whether anyone had spoken or not.
5. **No compaction on the analyzer path.** Its finals are already settled segments; debouncing
   them would only delay each caption and merge separate segments into one entry, and the silence
   timer would commit a volatile line the analyzer then finalises again.
6. **A stop does not wait for the analyzer.** `stop()` commits the live line at once and cancels
   (`cancelAndFinishNow`) rather than awaiting `finalizeAndFinishThroughEndOfInput()`, whose
   results would arrive after the session had been handed to the store and so miss it.
7. **A presence suspension and a mode change checkpoint too**, besides the 30 s interval and the
   background: away is when an app is most likely to be killed, and Medical Compliance mode coming
   on must take the checkpoint at once.

## Open questions

- **An erasure while captions run.** The subject erasure removes a checkpoint that mentions the
  person, but the session still in memory is written again at the next checkpoint and at stop, as
  it was before this plan for a finished session. Whether the erasure should also reach the
  session in progress is for the erasure's owner.
- **Analyzer locale reservations.** `AssetInventory` reserves a locale for the app automatically;
  the app never releases one. A wearer who changes caption language often could reach the system's
  limit (`maximumReservedLocales`), after which the analyzer start fails and the session falls
  back. To be watched in the device pass.

## Not in scope

- Any change to what the screen, the lens or the cursor consumers read: `captionHistory` is
  unchanged.
- Translation and diarized captions, which keep their own engines.
- A setting for the analyzer: the switch has no UI.
- New user-facing strings: none were added.
