# Plan MX — Whole-Meeting Captions (a summary of the whole meeting, a running summary that stays the same size, a kept session that survives a crash, and captions that do not restart)

**Status:** 🚧 P0–P2 built 2026-11-21 and P4–P6 built 2026-11-23 (headless). P3, the device pass,
is owed: nothing here has run on a phone yet. P0: the caption service keeps every final of the
session in memory and `meeting_summary` reads all of it, handing the model a budgeted excerpt
spread across the whole meeting; the meeting assistant sends the last summary and the new lines
instead of the whole transcript. P1: a kept caption session in progress is checkpointed every 30 s
and recovered after a crash, under **Keep caption sessions** only and never in Medical Compliance
mode. P2: plain captions run on iOS 26's `SpeechAnalyzer` when the locale's model is installed,
with `SFSpeechRecognizer` as the fallback. P4: the meeting's notes (title, overview, decisions,
action items) are written by the model from the whole transcript once the turn that asked for them
is over — never inside it — condensed part by part when it does not fit, checked against the
transcript; the turn itself answers with the phone's keyword lines, as candidates, and the
transcript excerpt. P5: each action item of a saved meeting can be added to Reminders, once. P6:
notes the model cannot write now (an on-device model with the app in the background, a kill or a
stop before the write ends) are owed and written the next time the app is in front, under Keep
caption sessions only. Nineteen build decisions are listed for review below; decision 1 is revised
and decision 10 replaced.
**Track:** Captions and meetings.
**Builds on:** Plan [KP](KP-answers-you-can-act-on.md) P5 (kept caption sessions,
`CaptionSessionStore`); Plan [KT](KT-cards-ready-to-act.md) (`MeetingSummaryFacts`,
`LatestMeetingSummary`); Plan [MO](MO-live-hints.md) §2, §6 and §8 (the analysis sink, the caption
voice gate, session contextual strings); Plan BY (caption compaction); Plan W v2 (presence
suspension); Plan [ET](ET-iso27701-privacy.md) (the data-store registry); the Reminders tool
(`EventKitDayStore`, `ReminderDuePolicy`).

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

### 6 · Notes the model writes (P4)

**Why.** The notes came from keyword extraction (`extractActionItems`): any line with "should",
"will", "need to", "let's" or "check" became an action item, so a chat with no commitments in it
produced a list of them, and the prepared card's meeting follow-up quoted them. The model now
writes the notes; the keyword facts are kept only as the fallback.

**The call.** `MeetingNotesWriter` is pure behind one seam — system and user prompt in, reply out.
The app gives it `LLMService.completeStateless` inside `TurnRecorder.offTurn`: the lecture
assistant's path (the meeting assistant's other caller, a recording's, goes through `sendMessage`,
which writes into the conversation). Both resolve the active model through
`MedicalLLMRoutingPolicy`, so HIPAA mode, Medical Local Only and the active model apply exactly as
they do to the assistant's rounds. Before calling, `MeetingNotesRoutePolicy` reads where the call
would go (`LLMService.statelessModel()`): no model, or none the routing rule allows → the fallback;
a cloud model offline → the fallback; the on-device MLX model with the app in the background →
owed (P6); otherwise write now. Apple's on-device model is asked directly; a refusal is a failure.

**The prompt** (`MeetingNotesPrompt`) asks for JSON only — `title` (3–6 words), `overview` (2–3
sentences), `decisions` [string], `action_items` [{task, owner, due}] — with the rules: a decision
only if people explicitly agreed it; an action item only if someone committed to it ("should" is
not one); many meetings have neither, and then the list is empty; owner and due only if a name or a
time was said; a diarized speaker's name may be the owner; never invent facts, names, numbers or
dates; the transcript is raw speech recognition. The transcript is framed as untrusted data
(`PromptInjectionPolicy.wrap`).

**Reading the reply** (`MeetingNotesParser`): the JSON from the first `{` to the last `}`, fences
and prose ignored; `action_items` or `actionItems`; a string item is its task; a reply cut off
mid-JSON keeps its title and overview; no usable JSON → the reply becomes the overview with empty
lists, so the work is not lost; a blank reply → the fallback. Placeholders a small model copies
from the prompt ("none", "n/a", "na", "unknown", "empty", "-", "null", "tbd", "unspecified", "not
specified", "not mentioned", "who", "when", "what", "owner", "due", "task", "name", "date", and
"…") are taken out as whole values.

**Checking it** (`MeetingNotesVerifier`): an owner or a due whose words are not in the transcript
is dropped and the task kept — case-, diacritic- and width-insensitive, by word, speaker names
counting, a leading "by / before / until / on…" on a due ignored; in a script written without
spaces the value is matched as a substring.

**Length** (`MeetingNotesBudget`). A call may carry half the routed model's window, at most 24,000
tokens, at three characters a token for Latin script (the excerpt's rate), two for other alphabets
and one for scripts without spaces; an unknown window is read as 4,096 tokens. A 4k on-device model
gets 6,144 characters of English; a 200k cloud model 72,000, about an hour and a half of speech in
one call. The other half is the instructions, the frame and the reply — unlike the excerpt, which
sits beside everything else a turn carries (decision 1). A longer meeting is cut into parts at line,
then sentence, ends; each part is condensed to at most twelve short plain lines (topics, what was
agreed, tasks with who and when if said); the notes pass reads the parts' notes. Notes that still
do not fit are condensed again, up to three rounds in all; a round that does not shrink the text
stops, and what is left is cut to the budget at a line end.

**After the turn, never inside it** (decision 10). The summary is a tool call, and its turn waits
on it — but the notes call (`completeStateless`) empties the conversation's history and puts its
snapshot back when it ends, so a call made inside the turn would leave the turn's model without its
history, and a call outliving the turn would put a stale history back over the turn's newer
messages. So `meeting_summary` never calls the model. It answers the turn as it did before P4: the
phone's keyword facts and the transcript excerpt (§2), from which the turn's own model speaks the
summary. While the model's notes are still to come, the keyword lines are shown as candidates —
**POSSIBLE DECISIONS** / **POSSIBLE ACTION ITEMS** in the full summary, "Possible action items,
picked out on the phone by key phrase (some may be things no one committed to)" in the action-items
mode — with one line saying what they are: "(Lines marked POSSIBLE were picked out on the phone by
key phrase and may include things no one committed to; the transcript below is what was said.)"
The tool's closing guidance asks the model to take what was agreed and who will do what from the
transcript, not from those lines alone. With no fuller notes coming (no model, offline, or nothing
may be owed) the lines read as before.

`MeetingNotesService.queue` decides where the notes go without calling the model and, when the
route says write now, queues the meeting: in memory always, and in the owed store (P6, reason
`afterTurn`) exactly when it may be held, so a kill or a background stop before it is written is
recovered as owed notes are. The saved note is written at once with the phone's notes, and then the
write starts: it waits for the turn to be over (`turnInFlight`, the same seam `writeOwed` uses —
`LLMService.isTurnInFlight`), and runs one meeting and one model step at a time. Before every step
— each part and the notes pass — it checks again: a turn that has started meanwhile stops the write
after the step already running, and the meeting stays queued (or owed) to resume from the next
step once the turn is over (`MeetingNotesWriter.Progress`, in memory). A step already running is
never abandoned: its `completeStateless` is always awaited to its end before the service returns or
moves on, so its history snapshot is put back before anything else runs. There is no time limit on
a write; condensing is bounded by its rounds and parts. A stop for a turn is not a failed attempt.

**What it feeds.** When the notes are written they complete the saved note (rebuilt in full from
the transcript, §8), its action items (those already added to Reminders stay added) and
`LatestMeetingSummary` if it is still that meeting — the same `completeNote` path owed notes take.
`MeetingSummaryFacts` keeps its shape: `actionItems` is each item's readable form ("Send the
revised budget (Ana, by Friday)"), `decisions` the model's, and the structured notes and their
source ride alongside (`notes`, `notesSource`). `DraftValidator`'s own-words check holds: a draft
quotes the readable item whole, which is in the trusted text and cut out before the copy check;
copying transcript outside it still fails. The saved note says which notes these are in one
neutral line ("written by the AI model from the meeting's transcript" / "picked out on the phone
from key phrases", with "fuller notes will be written after this reply" when queued, "later" when
owed, and "and added to the saved note" when there is one). Topics stay the phone's word counts and
are shown only with the phone's notes.

### 7 · An action item into Reminders, once (P5)

A saved meeting summary now carries its meeting id, its action items as a value
(`MeetingActionItemsRecord`, one JSON string in the note) and whose notes they are. The meeting's
page in **Meeting Records** lists the items in an **Action items** section, each with **Add to
Reminders**; the Reminders tool's own EventKit owner (`EventKitDayStore`) and permission flow do
the rest, behind the `MeetingReminderSaving` seam. The reminder's title is the task; the owner, the
due as said and the meeting go in its notes. A due becomes the reminder's date only when it reads
as an exact future date and time (`ReminderDuePolicy.parse`) — "Friday" said last week is not one.
The note is read again before anything is created, the item is marked added only once the reminder
is saved, and the flag is written back to the note, so the row shows **Added** after a relaunch and
cannot add twice. When owed notes arrive later, an item already added stays added.

### 8 · Notes owed when the model can't run now (P6)

`MeetingNotesOwedStore` holds a meeting whose notes are owed: its caption lines with their times
and speaker names, the saved note's meeting id, a state (`writing` / `owed`) and a reason. It is
held only where a kept session may be written — **Keep caption sessions** on, never in Medical
Compliance mode — and only for a summary saved as a note, which the notes complete
(`MeetingNotesOwedPolicy`). Every open applies the rule again: with the switch off or the mode on
everything goes, and so does a record seven days after its meeting began, or after three failed
attempts; at most three meetings are held. The switch going off and the mode coming on prune it at
once.

- **Owed:** the on-device model with the app in the background.
- **Queued after the turn** (§6): held as `afterTurn` while it waits for the turn to end, so a kill
  or a stop before it is written leaves it owed.
- **Interrupted:** a write in progress is recorded `writing` first and settled when it ends; a
  `writing` record found when the store opens is a write the app did not live to finish, owed from
  then on.
- **Written later:** `MeetingNotesService.writeOwed` runs when the app becomes active (the scene
  phase's `.active` hook) and after the turn that queued a write. It writes this process's queue
  first, then the store's, one meeting at a time, oldest first, only while the route says write now,
  and never while a turn is in flight (it waits up to ten minutes, then leaves the rest for the next
  foreground), so the write never competes with the wearer's turn for the model; before each model
  step it checks again (§6). The saved note is rebuilt in full from the
  owed transcript (the excerpt again), its action items replaced with the added ones kept, and
  `LatestMeetingSummary` updated if it is still that meeting. A note the wearer deleted stays
  deleted. A record whose reason this build does not know reads as `interrupted`.
- **Meanwhile** the phone's keyword facts are in the saved note, so nothing is lost.

Registered in `DataStoreRegistry` as `owedMeetingNotes` (other people's speech: third-party,
first-unlock, out of backup, walked by the subject erasure — a meeting mentioning the subject goes
whole — with `deleteAll`), not under `captionSessions`: a kept session reaches no model, and these
exist to reach one. The data-lifecycle matrix in Plan ET carries the row. MX §1's "never written
down" still holds for the in-memory buffer: what an owed record holds is the summary's own copy,
under the switch that already writes the same words as a kept session.

## Phases

| Phase | What | Status |
|---|---|---|
| P0 | `MeetingTranscriptBuffer`; `meeting_summary` over the whole session with `MeetingTranscriptExcerpt`; `MeetingAnalysisWindow` and `prompt(for:)` | ✅ Built 2026-11-21 (headless) |
| P1 | `onSessionCheckpoint`, `CaptionCheckpointPolicy`, `CaptionSessionStore.checkpoint` / `recoverCheckpoint`, the erasure and registry | ✅ Built 2026-11-21 (headless) |
| P2 | `CaptionEnginePolicy`, `CaptionAnalyzerAudioFeed`, `SpeechAnalyzerCaptionEngine`, `captionSpeechAnalyzerEnabled` | ✅ Built 2026-11-21 (headless; the live engine is device-only) |
| P3 | Device pass (below) | Owed |
| P4 | Notes the model writes after the turn: `MeetingNotesWriter`, `MeetingNotesPrompt`, `MeetingNotesParser`, `MeetingNotesVerifier`, `MeetingNotesBudget`, `MeetingNotesRoutePolicy`, `MeetingNotesService` (`queue`, then the write once no turn is in flight); they complete the saved note, its action items and `LatestMeetingSummary` | ✅ Built 2026-11-23 (headless) |
| P5 | Action items into Reminders once: `MeetingActionItemsRecord`, `MeetingReminderDraft`, `MeetingActionReminders`; the Action items section of a meeting's page | ✅ Built 2026-11-23 (headless; EventKit is device-only) |
| P6 | Owed notes: `MeetingNotesOwedPolicy`, `MeetingNotesOwedStore` (`owedMeetingNotes` in the registry and the erasure), `writeOwed` on becoming active | ✅ Built 2026-11-23 (headless) |

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
6. **Model notes.** A real meeting with a cloud model and with a 4k on-device model: a title and an
   overview that fit; no owner or date that was not said; empty lists for a chat with no
   commitments in it; a non-English meeting written in its language. An hour-long meeting with the
   on-device model goes through condensing: the reply comes at once from the phone's candidates and
   the excerpt, with "fuller notes will be written after this reply"; time the write after it, and
   check the saved note is completed. Start a new turn while it condenses: the turn's reply and its
   history are intact, and the note is still completed after that turn.
7. **Owed in the background.** Keep caption sessions on, the on-device model selected, the summary
   asked for with the app in the background (phone locked): the phone's notes are saved; bringing
   the app forward completes the saved note. With the switch off, nothing is owed.
8. **Killed mid-write.** Ask for a summary with the on-device model and kill the app while it
   writes; relaunch and bring it forward: the notes are written into the saved note.
9. **Reminders.** On a saved meeting's page, **Add to Reminders**: the first-use permission sheet,
   the reminder's title and notes, **Added** after a relaunch, no second reminder; with access
   denied, the message.
10. **Medical Compliance.** With the mode on, the notes are written on the phone's model only (or
    are the phone's keyword facts), nothing is owed, and turning the mode on deletes what was.

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
- `MeetingNotesPromptTests` — the JSON shape and every rule, the transcript framed as untrusted,
  the condensing prompt's bound.
- `MeetingNotesParserTests` — plain JSON, fences and prose, both key spellings, string items, a
  reply cut off mid-JSON, garbage as the overview, a blank reply, the placeholder filter, the
  condensed lines.
- `MeetingNotesVerifierTests` — an owner or due not said is dropped and the task kept; case and
  diacritics; a diarized name; a script without spaces; placeholder tasks and decisions.
- `MeetingNotesBudgetTests` — the budget by window and script, the script reading, parts by line
  and sentence.
- `MeetingNotesWriterTests` — one call when it fits; condensed part by part; a second round when
  the notes still do not fit; at most three rounds; a model error; a blank reply; asked before every
  step; a stopped write resumes from the step it stopped at; a stop before the notes pass resumes
  with that pass alone.
- `MeetingNotesRouteTests` — no model, offline, the on-device model in the background, where owed
  notes may be held, and a record's disposition.
- `MeetingNotesServiceTests` — unconfigured is the fallback; queueing never calls the model; a
  queued write runs only once the turn is over, completes the note and settles; one that may not be
  held is written from memory; a turn starting mid-write stops further steps and leaves it owed, not
  counted as an attempt, then resumes; a running step is never abandoned; every forbidding gate
  makes no call; a failed write after the turn stays owed; owed in the background; nothing owed
  without the switch, in the mode or unsaved; written later and the note completed; waits for a
  turn; three failed attempts give up.
- `MeetingNotesOwedStoreTests` — a kill's `writing` record is owed at the next open; an unknown
  reason reads as interrupted; the rule; seven days; three meetings; the subject erasure; Delete all
  and the registry; out of backup.
- `MeetingActionRemindersTests` — added once and read back; the reminder's title and notes; an
  exact future due as the date; no access or a failed save marks nothing; notes written later keep
  what was added.
- `MeetingSummaryNotesTests` — the model's notes fill the facts the card reads; no commitments, no
  items; the readable form and `DraftValidator`'s own-words check; the neutral source line (queued,
  owed, unsaved); the keyword lines as candidates only while fuller notes are coming; the tool
  never calls the model, and the notes reach `LatestMeetingSummary` once the turn is over.
- `DataStoreRegistryTests` — the owed file's protection and backup exclusion match the registry.

## Decisions taken in the build (for review)

1. **The excerpt budget** is a quarter of the model's window at three characters a token, 2,000 to
   48,000 characters, 3,000 when the window is unknown. *Revised 2026-11-23 (P4):* the notes are
   now written by the model, from the whole transcript in their own call (§6), and the phone's
   keyword facts are kept only as the fallback. *Why:* keyword extraction over-matched — any
   "should", "will" or "need to" became an action item, so a meeting with no commitments in it
   still had a list, and the prepared card's follow-up quoted it. The excerpt stays as it was: it
   is now evidence beside notes the model wrote, and the quarter still leaves a small model room
   for the turn's prompt and reply.
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
8. **The notes call is `completeStateless`, off the turn's accounting** — the lecture assistant's
   path. The recording assistant's `sendMessage` writes into the conversation, which a summary's
   notes must not. Both resolve the model through the same Medical Compliance rule.
9. **The notes budget is half the window, at most 24,000 tokens**, at 3 / 2 / 1 characters a token
   by script, 4,096 tokens when unknown (§6). *Why:* the call carries nothing but the transcript,
   and the ceiling keeps each step short, so a turn that starts during a write waits less for the
   step running.
10. **The notes are written after the turn, never inside it** (replaces "45 s inside a turn",
    2026-11-23). *Why:* when this was built, the stateless call swapped the shared conversation
    history — it emptied it and put its snapshot back when it ended — so it could not overlap a turn
    or outlive one. A call inside the `meeting_summary` tool did both: the turn waited on it, and past a deadline the
    turn went on with an empty history while the abandoned call, ending later, put a stale history
    back over the turn's newer messages. Now the turn answers from the phone's candidates and the
    excerpt, the write waits for the turn to end and checks again before every step, and a running
    step is always awaited, never abandoned. The cost is that the spoken summary is the turn
    model's reading of the excerpt, and the strict notes reach the saved note a little later.
11. **Owed notes only under Keep caption sessions, never in Medical Compliance mode, and only for a
    saved summary.** The alternative — whenever the note is saved — was refused: the ambient
    captions' disclosure says that with the switch off nothing of a session is written to disk.
12. **Owed notes are their own registry entry** (`owedMeetingNotes`), not part of
    `captionSessions`: a kept session reaches no model, and these exist to reach one.
13. **Offline with a cloud model is the fallback, not owed.** Only "the model can't run now" owes.
14. **A reminder's date only from an exact future date and time** (`ReminderDuePolicy.parse`);
    otherwise the due stays text in the reminder's notes.
15. **The phone's keyword items get Add to Reminders too**, as the wearer sees them; when owed
    notes arrive the items are replaced and any already added stay listed as added.
16. **Owed notes rebuild the saved note in full** (the excerpt again, from the owed transcript)
    whatever mode the summary was asked in; the note's title is unchanged, so it stays listed.
17. **Apple's on-device model is asked even in the background**; a refusal is a failure and the
    fallback, not owed.
18. **Three attempts, three meetings.** A meeting whose notes fail three times keeps the phone's
    notes; at most three are owed at once, the oldest going first.
19. **Topics stay the phone's word counts**, shown only with the phone's notes; the model's title
    takes their place.

## Open questions

- **An erasure while captions run.** The subject erasure removes a checkpoint that mentions the
  person, but the session still in memory is written again at the next checkpoint and at stop, as
  it was before this plan for a finished session. Whether the erasure should also reach the
  session in progress is for the erasure's owner.
- **Analyzer locale reservations.** `AssetInventory` reserves a locale for the app automatically;
  the app never releases one. A wearer who changes caption language often could reach the system's
  limit (`maximumReservedLocales`), after which the analyzer start fails and the session falls
  back. To be watched in the device pass.

- **A wearer turn started while any stateless call is running** — resolved 2026-11-24 by the
  stateless-call fix (PR 1208): `completeStateless` now runs in a history of its own and never
  reads or writes the conversation, so a turn started during a notes step, a lecture round or a talk
  note keeps its history. Decision 10's timing stays for the reply's speed and the model's memory,
  not for safety.

## Not in scope

- Any change to what the screen, the lens or the cursor consumers read: `captionHistory` is
  unchanged.
- Translation and diarized captions, which keep their own engines.
- A setting for the analyzer: the switch has no UI.
- New user-facing strings: none in P0–P2. P5 adds the Action items section's strings, the
  reminder notes' labels and two messages; the catalog sync is a separate PR.
