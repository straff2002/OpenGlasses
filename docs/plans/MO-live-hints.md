# Plan MO — Live Hints (when someone asks you a question, a short answer from your own documents, on the lens or in your ear)

**Status:** 🚧 P0 built 2026-11-20 (headless): the pure core (`HintTrigger` with `HintQueue`,
`KeywordMatcher`, `HintReply`, `HintPromptBuilder`, `PassageHint`, `HintSpeechPolicy`, constants
in `HintLimits`) and the caption voice gate (`CaptionAudioGate` on all four caption consumers,
wired from the capture router). **P1 built 2026-11-21 (headless):** `LiveHintsService` (start and
stop on the wearer's word, captions owned only if it turned them on, `CaptionCursor`, one hint in
flight, the three modes, a per-session cache, the 2 h limit warned at 1 h 55, a stop when the
`HintSessionAllowance` seam says time is up, latency p50/p95 from `HintLatencyStats`) with every
carrier behind a protocol; the answer path (passage card at once, then `completeStateless` through
the medical routing rule, replacing the card only within 3 s); delivery to the lens
(`HintLensCardBuilder`'s two pages through `presentAnswerCard(_:wearerLed: false)`, hidden after
20 s), the ear (`HintSpeechPolicy` over `TextToSpeechService` without taking the conversation
route, the idle session in a hints shape — phone mic preferred, A2DP only, `.duckOthers`,
`.spokenAudio` — and barge-in from an ungated mic level) and the phone list
(`LiveHintsPhoneList`, last 10, memory only); the session vocabulary through `DictationVocabulary`
into the caption recogniser's `contextualStrings`; lecture mode through `MeetingAssistantService`
behind a `MeetingAnalysisSink` (recordings' notification unchanged, tested); `.liveHints` in
`AIFeatureRegistry`, the capture notice and a once-only first-run sheet; `AppState.startLiveHints`
/ `stopLiveHints`. **Needs a device (P3):** whether `.spokenAudio` with `.duckOthers` on the idle
`.playAndRecord` session activates and ducks only as wanted (it ducks for the whole session as
built), the barge-in thresholds, the soft tick, the lens paging and 20 s hide on a real Display.
**P2 built 2026-11-21 (headless):** a Home card (yielding like the day card, always there
while a session runs) opening one sheet: setup (`LiveHintsSessionChoices`: Conversation / Lecture /
On keyword with "Can't tell voices apart; hints for every question." without diarization, keywords,
the active project's documents or a pick, hint language, lens when a Display is connected else ear,
the phone's mic with the glasses' offered and its caveat, the talk note off by default, the
phone-on-the-table line, a demo), then the session screen (the Listening pill, speaker chips and
**That's me** into `markWearer`, the last 10 hints opening their passage by `documentId` and
`chunkIndex`, Stop, "31 hints"). While a session runs it holds the temple taps and media buttons
(`MediaTriggerService.heldBySession`, the setting on or off; `LiveHintsTapPolicy`: one tap repeats or
skips a playing hint, two skip, three do nothing), and gives them back at stop; the Live Activity
shows repeat, skip and stop (`PendingLiveHintsCommand`, the "Ask Avenkin" control's hand-over).
"Start live hints", "stop hints", "show hints" and "hint me about …" (`LiveHintsVoiceCommand`) sit
in the pre-model command chain. The demo (`LiveHintsDemo`: a two-voice garden-studio conversation
and an invented sample document through `HintCaptionSource`, first question at 4 s, no mic, no
allowance). The talk note (`LiveHintsTalkNote`): the meeting-summary prompt at stop, LQ's acceptance,
kept as a finished conversation with its note (`ConversationStore.saveTalkNote`), never in Medical
Compliance mode or a Private Conversation; the transcript stays **Keep caption sessions**'s. The
session stops by `CaptionPresenceGate`'s rule when the app is away. Remaining: the catalog sync
(P2's strings are English only) and the P3 device pass. Decisions 1–10 have recommendations; P0, P1
and P2 were built on them as recommended.
**Track:** Everyday assistant: conversations. Captions, documents, the lens, speech output.
**Origin:** The owner, 2026-11-20, after surveying adjacent live-assistant products: a session that
listens to a conversation and, when someone asks the wearer a question, puts a short answer from
the wearer's own documents on the lens or in their ear. The same day the owner set free use as an
app-wide daily allowance, so this plan has no meter of its own.
**Builds on:**
- `AmbientCaptionService` (`captionHistory`, `CaptionEntry.speaker`, the diarized path,
  `HUDCaptionBuilder`) and `CaptionCursor`.
- Plan [AQ](speaker-diarization.md): speaker chips (`SpeakerChipModel`) and the bystander-consent
  text in `DiarizationSettingsView`.
- Plans [O](O-document-rag.md) / [P](P-chunk-citations.md): `DocumentStore.query(_:limit:namespace:documentIds:…)`.
- Plan [AN](projects-scoped-contexts.md): `ProjectContextService` and the active project's namespace.
- `MeetingAssistantService` (the 60-second meeting summary).
- `UtteranceQuestionCue` (`QuietAfterActions/QuietTurnJudge.swift`).
- Plans [LC](LC-the-lens-made-ready.md) / [MG](MG-reading-the-conversation-on-the-lens.md):
  `GlassesDisplayService.presentAnswerCard(_:wearerLed:onSelect:)`, the `wearerLed` rule and the
  answer card's pages.
- `AssistantVoiceGating` / `CaptureAudioRouter` / `AudioRecordingService.gatedConsumer(gate:append:)`.
- `MicRoute` / `MicRoutePolicy` (Plan CL P3) and the built-in-mic preference (Plan GU).
- `MediaTriggerService` / `TempleCalibration` (Plans CH / GJ): temple taps as media commands.
- `DictationVocabulary` (the recogniser's custom vocabulary).
- Plan [GE](GE-automatic-offline-handoff.md): `ConnectivityHandoffController`, the held question.
- Plan [LU](LU-private-conversation.md), Plan [KP](KP-answers-you-can-act-on.md) P5
  (`keepCaptionSessions`) and `AIFeatureRegistry`.

**Sits beside:** Plan [JI](JI-apprentice-support.md) §7a (talk-through: hints that follow the
apprentice's narration through a procedure), which shares this plan's hint card, ear policy,
caption voice gate and free-question path; whichever is built first builds them. Plan
[C](C-live-coach-tool.md) (camera-led coaching, unrelated), the [teleprompter](teleprompter.md)
(your own script; it owns the lens while it runs, and so does this) and Plan
[BY](BY-live-translation-captions.md) (translated captions).

---

## Trigger

The loop is one we have every part of and have never joined up. The other person asks a question,
and within a second or two the wearer has a short answer drawn from their own documents: two lines
on the lens, or a few words in their ear. Captions already know what was said, and often by whom.
Document search already finds the passage. The lens already shows answer cards. Speech output
already exists. The nearest thing we have, the meeting assistant, does something different: every
60 seconds it posts a summary and *questions for the wearer to ask* as a lock-screen notification,
it doesn't read the wearer's documents, and it runs only while a recording runs.

Products in this space charge by listening minute because they pay for cloud speech recognition
and their own model per minute. Here recognition can run on the phone and the model is the wearer's
own provider or the phone's, so the session costs us nothing per minute.

---

## What exists (verified 2026-11-20 on `main` @ `0b29829be`)

- **Captions.** `AmbientCaptionService` keeps `captionHistory` (newest first, capped at 50) of
  `CaptionEntry { text, timestamp, seq, speaker: Int?, original, language }`. Consumers track their
  place by `seq` through `CaptionCursor`. Three paths, chosen per session: translated (BY),
  diarized (Deepgram, opt-in, keyed, never in HIPAA mode) and on-device `SFSpeechRecognizer`. Only
  the diarized path sets `speaker`.
- **Captions hear our own voice.** All four `addAudioBufferConsumer(id: "ambient_captions")`
  registrations take raw buffers. `AudioRecordingService` wraps its consumer in
  `gatedConsumer(gate:append:)`, fed by `CaptureAudioRouter`, which silences a buffer while the
  assistant speaks through the phone's own speaker (`AssistantAudioGate.decide`) unless "Include
  Assistant Voice" is on. Captions have no gate, so a reply spoken on the phone speaker is
  transcribed as if a person had said it.
- **Speakers.** `SpeakerRegistry` maps a per-session Deepgram cluster id to a name the wearer typed.
  `AIFeatureRegistry.speakerIdentification` is screened `.none`, not biometric, because "no
  voiceprint, embedding or cross-session voice match exists". This plan keeps that true (§3).
- **Meeting assistant.** `MeetingAssistantService.start(captionService:llm:)` reads captions through
  a `CaptionCursor`, analyses every 60 s or at 100 buffered words, and posts a summary plus 2–3
  follow-up questions as a notification. Only recordings start it. No documents, nothing on the lens.
- **Question detection.** `UtteranceQuestionCue.isQuestion` has words for English only, and for any
  other language returns **true**. It also reads a polite request ("can you tell me about…") as a
  command, which is right for the wearer talking to the assistant and wrong here: "Can you tell me
  about your biggest project?" is exactly the question to hint (§4).
- **Documents.** `DocumentStore.query(_:limit:namespace:documentIds:kinds:alsoWithin:)` is on-device
  and synchronous. `ProjectContextService.shared` resolves the active project.
- **The lens.** `presentAnswerCard(_:wearerLed:onSelect:)`; an answer the wearer didn't ask for
  (`wearerLed: false`) stays off a lens they dismissed.
- **The mic.** `MicRoute` is `phone` / `glasses` / `headset`. On Display glasses the firmware covers
  the lens with its call screen whenever the glasses' hands-free link is the mic, and opening it is
  reported to end Display sessions. On any glasses it drops playback to call quality.
- **Temple taps.** `MediaTriggerService` holds Now Playing and receives the glasses' temple gestures
  as media commands; `TempleCalibration` maps them. Device-unverified while a record-and-play
  session holds the audio.
- **Audio session.** Nothing in the app uses `.spokenAudio` or `.duckOthers` today. Live translation
  allows both `.allowBluetoothHFP` and `.allowBluetoothA2DP`.

---

## Design

### 1. One session, started on purpose

**Live hints** is a session the wearer starts: from a Home card, from the Chat tab, or by voice
("start live hints", "hint me in this meeting"). It never starts itself and never runs in the
background of another session. It turns captions on if they're off (and back off at stop if it
turned them on), shows the capture notice (§10) and runs until stopped. It also stops at the
long-session limit, when the app is backgrounded beyond the presence rule captions already follow,
or when the app-wide daily allowance runs out (that allowance is not this plan's; the session only
obeys it).

It owns the lens while it runs, as the teleprompter does. Captions stay on the lens between hints,
and a hint replaces the caption frame until it is dismissed or times out.

### 2. Three modes

- **Conversation:** a hint when someone who isn't the wearer asks a question (§3–§4).
- **Lecture:** no question gate. Every ~60 s, or at a pause after ~100 words, one key-point line goes
  to the lens. This is `MeetingAssistantService`'s analysis with a lens sink and a shorter prompt;
  the notification sink stays for recordings. A question the speaker asks the room is still hinted.
- **On keyword:** the wearer lists trigger words or names. When one is said, by anyone, the passage
  it hits goes on the lens as a fact card. Whole words, case ignored, each word held for 60 s after
  it fires. No model at all (§5 step 4), so it works fully offline.

**Hint language** is a session setting, separate from the conversation's language, for a meeting in
a language the wearer speaks less well.

### 3. Which voice is the wearer's

- **With diarization on:** the session screen shows the speaker chips; the wearer taps theirs once,
  then **That's me**. The mapping lives in the session's memory and is never written to
  `SpeakerRegistry`. Until the wearer taps, every question gets a hint.
- **Without diarization** (the default, and always in HIPAA mode): every question gets a hint, and
  the mode picker says so ("Can't tell voices apart; hints for every question").
- **Never:** no enrolment phrase, no stored voice sample, no embedding, no cross-session match. A
  test pins `AIFeatureRegistry.speakerIdentification`'s note and asserts live hints write nothing to
  `SpeakerRegistry`.

### 4. When a caption asks for an answer (`HintTrigger`, pure)

Input: a final `CaptionEntry`, the wearer's speaker id if known, the language, the questions already
hinted this session, the time of the last hint and the mode. Output: `.hint(question)`,
`.keyword(word)` or `.none(reason)`.

- **Finals only.** An interim caption is revised; a hint on a half-sentence is worse than none.
- **Asks for an answer** = a question by `UtteranceQuestionCue` **or** an invitation to answer: a
  polite request ("can you tell me…", "could you explain…") or an interview-style opener ("tell me
  about…", "walk me through…", "describe…"). In a language with no cue words, the question mark
  alone, and **never** `UtteranceQuestionCue`'s fallback `true`.
- **Skipped:** the wearer's own speaker; the `[Visual:` notes recordings insert; anything under 4
  words; tag questions ("…, isn't it?"); small talk from a short list per language ("how are you",
  "how was your trip", "how's it going"); and a question that matches one already hinted this
  session (normalised words, high overlap).
- **One in flight.** A new question replaces a pending one. At least 8 s between hints unless a
  different speaker asks.
- **Context:** the question plus the last ~6 finals, so "and the second one?" resolves.

### 5. The answer (`HintComposer`)

1. **Search:** `DocumentStore.query(question, limit: 4, namespace: <session scope>)`. The scope is
   the active project, or documents picked on the session sheet.
2. **Show the passage at once** (step 4's card) while the model works.
3. **Compose:** one model call through `LLMService`'s existing provider rules (HIPAA and Medical
   Local Only apply as for a Direct turn). The model returns JSON `{"hint": "...", "full": "..."}`:
   `hint` at most 8 words and 45 characters, starting with the key word, numbers as digits; `full`
   one or two sentences. An empty `hint` means nothing worth showing (small talk the trigger
   missed). The passages and the room's words are quoted as data and pinned against injection, as
   `TranslationPromptBuilder` does. **Lengths are enforced in code**, cut at a word boundary,
   whatever the model returns. A reply that isn't JSON is read as its first line.
   A better answer replaces the passage card if it arrives within about 3 s; otherwise the passage
   stays.
4. **No model** (keyword mode, no provider reachable, or the phone's model on a locked phone): the
   best passage's sentence that holds the question's or keyword's terms, trimmed to the card, with
   its document name. Offline, a question the phone answered weakly is held for the signal's return
   through GE's held question.
5. **Cache** by the question's normalised text for the session; repeated questions cost nothing.
6. `documentId` and `chunkIndex` go with every card, so a press opens the passage on the phone.

The latency target is measured from the end of the question to the first line on the lens:
**good under 1.5 s, usable under 3 s, broken over 5 s**, reported as p50 and p95, never an average.
`PrivacyLog` keeps timings and lengths only.

### 6. Delivery

- **Lens** (a Display is connected): page 1 is the question in 2–4 words, dimmed, above the `hint`
  in two lines; page 2 is `full` and the source, through MG's paging. `presentAnswerCard(_:wearerLed:
  false)`: a dismissed lens stays dismissed, and "show hints" or a press on the Home card brings it
  back. The next card replaces it; it hides after 20 s (the Display's own dim). A soft tick in the
  ear when a hint lands, because the wearer may not be looking.
- **Ear** (no Display, or the wearer chose ear): the `hint` only, about 5–7 words and under 2 s of
  speech, by the **speak-when-quiet** policy (`HintSpeechPolicy`, pure):
  - speak once nobody has spoken for about 400 ms;
  - stop within about 200 ms when anyone starts speaking, and keep the hint ready to repeat;
  - only the newest hint: a new one replaces a waiting one, and a hint not spoken within 5 s of
    arriving is dropped;
  - **never through the phone speaker**: with no headset or glasses connected, the hint goes to the
    screen only;
  - other audio is ducked, not paused (`.spokenAudio` with `.duckOthers`).
- **Controls with no phone:** a temple tap or any Bluetooth media button repeats the last hint, and
  a tap while it plays skips it, through `MediaTriggerService` (which one the tap means comes from
  `TempleCalibration`). While a hints session runs, these taps belong to it, not to the wake word.
  The Neural Band repeats and skips once Plan JV's band input lands. The Live Activity carries
  repeat, skip and stop.
- **Our own voice is not a caption.** Captions take the assistant-voice gate (`CaptionAudioGate`):
  the router's decision with "Include Assistant Voice" treated as off, because a caption never wants
  the assistant. A spoken hint is never transcribed, re-detected as a question or kept in a talk
  note. This fixes a standing gap for every caption session and ships in P0. The barge-in detector
  for the ear policy reads the **ungated** level, so it still hears a person who talks over a hint.
- **Phone:** the session screen shows the last 10 hints with their passages, in memory only.

### 7. The mic

The phone listens; the glasses show and speak. Glasses microphones are tuned to the wearer's mouth
and hear the other person poorly, and opening one drops playback to call quality.

| Setup | Mic | Why |
|---|---|---|
| Any glasses or earbuds | **phone**, built-in, preferred explicitly (Plan GU's `preferBuiltInMic`) | It hears the other person; the glasses stay on normal playback |
| Ray-Ban Display | phone, or a wired headset | The hands-free mic covers the lens and is reported to end Display sessions |
| Phone only | phone | — |

The session's audio allows `.allowBluetoothA2DP` and **not** `.allowBluetoothHFP`, so iOS cannot
switch the glasses to call mode. The session sheet shows the mic and lets the wearer choose the
glasses' mic, with the caveat beside it. The sheet suggests the phone on the table, not in a pocket.

### 8. The recogniser gets the session's words

For the session, `DictationVocabulary` is filled from the keyword list, the scoped documents'
titles and the names that occur in them, and given to the caption recogniser as `contextualStrings`.
Names are where recognition fails most, and a misheard name is a missed search. Hints want a sentence
finished sooner than captions do, so the hints session uses a shorter end-of-sentence wait than
plain captions.

### 9. What is kept

Nothing by default. Hints and the session's captions live in memory and go at stop.

- **Talk note** (a switch on the session sheet): at stop, the meeting-summary prompt over the
  captions, saved as a conversation note. It follows **Keep caption sessions** for the transcript,
  is never saved in Medical Compliance mode and never in a Private Conversation.
- Hints are not written to `ConversationStore`, `BrainStore` or memory.

### 10. Consent, policy and limits

- **Capture notice** at every start, one line on the phone: *"Live hints listens to everyone near
  you. Tell people you're using it."* On the first start ever, a full sheet says where audio goes
  for each path and what is kept.
- **No covert mode:** no hidden UI, no muted notice. A "Listening" pill and the Live Activity for the
  whole session.
- **Meta's Acceptable Use Policy:** the glasses only show and speak; the phone listens. No
  identification by voice (§3). A hint answers the question asked, from the wearer's documents; it
  never describes the person asking.
- **`AIFeatureRegistry`:** a new `.liveHints` record, screened `.none`, with a disable switch,
  storing `[]` (or the conversation note when the talk note is on).
- **High stakes:** in Medical Compliance mode, and for documents marked legal or medical, the card
  says "suggestion" above the hint.
- **Long sessions:** auto-stop after 2 h with a spoken warning at 1 h 55. Model calls are counted in
  the session footer ("31 hints").

### 11. A demo session

A canned two-voice conversation, played inside the app, that produces a first hint within about
10 s from a bundled sample document. For a first-time wearer, and for App Review, who must see the
feature work without a real conversation.

---

## Phases

**P0 — The pure core, plus the caption voice gate** (headless, one PR)
- `HintTrigger` (§4): finals only; the invitation openers; question mark only in an unsupported
  language; wearer, short, tag, small-talk and already-hinted questions skipped; spacing;
  replace-pending.
- `KeywordMatcher` (§2): whole words, case, hold window, multi-word triggers.
- `HintReply` / `HintPromptBuilder` / `PassageHint` (§5): the JSON reply read and its lengths
  enforced; the prompt with passages and question quoted as data (a caption saying "ignore your
  instructions" comes out quoted); the no-model passage trim.
- `HintSpeechPolicy` (§6): quiet before speaking, stop on speech, newest only, drop after 5 s, never
  the phone speaker.
- `CaptionAudioGate` on every caption consumer (§6), with a test that a gated buffer reaches
  recognition as silence and that the setting can't let the assistant into captions.

**P1 — The session** (one PR)
- `LiveHintsService`: start/stop, owns captions if it started them, `CaptionCursor`, one hint in
  flight, the three modes, the cache, the long-session guard, the allowance stop, `PrivacyLog`.
- Delivery to the lens (two pages, `wearerLed: false`), to the ear (ducking, A2DP only, built-in
  mic), and to the phone list. The session vocabulary (§8).
- Lecture mode moves `MeetingAssistantService`'s prompt behind a sink.
- `.liveHints` in `AIFeatureRegistry`, the capture notice and the first-run sheet.

**P2 — The surfaces** (one PR)
- Home card and session sheet: mode, documents, hint language, delivery, mic, talk note, keywords.
- Session screen: Listening pill, speaker chips with **That's me**, the last 10 hints, stop.
- Temple-tap and media-button repeat/skip; Live Activity buttons.
- Voice: "start live hints", "stop hints", "show hints", "hint me about …" (adds a keyword).
- The demo session (§11).

**P3 — Device pass** (owed, GiPhone)
- Ray-Ban Display with the phone mic: p50/p95 from the end of a question to the first line, filmed
  in slow motion; whether a send wakes a dimmed lens; whether the Display session survives an hour.
- Ray-Ban Meta: spoken hints over A2DP with the phone's mic; the barge-in stop when someone talks
  over a hint; whether open-ear playback leaks into the phone mic despite the gate.
- Temple taps: do they reach the app while a record-and-play session holds the audio.
- A recorded two-person conversation played through a speaker beside the phone, for repeatable runs.

---

## Not doing

- Voice enrolment of any kind, or remembering a voice between sessions.
- Describing, profiling or judging the person who asked.
- A meter of this plan's own: free use is the app-wide daily allowance.
- A browser extension or a web dashboard.
- Joining a phone or video call's audio. iOS doesn't allow it; live hints hears the room.

---

## Decisions (recommendations; P0 proceeds on them)

1. **Name.** *Live hints* (recommended), *Prompter*, or *Whisper* (collides with the speech model of
   that name in our settings).
2. **The wearer's voice.** A per-session **That's me** tap, never stored; without diarization every
   question gets a hint (recommended). Or require diarization for Conversation mode, which makes it
   cloud-only and unavailable in HIPAA mode.
3. **Default delivery.** Lens when a Display is connected, else ear (recommended); or ask at start.
4. **Mic.** The phone for every setup (recommended, §7); or follow the global Microphone setting.
5. **Which documents.** The active project, changeable on the session sheet (recommended); or a
   picker every time.
6. **Answers beyond the documents.** Allowed, marked "general" on the card (recommended); documents
   only; or the wearer's choice per session.
7. **Talk note.** Off by default, a switch on the sheet (recommended); or on when **Keep caption
   sessions** is on.
8. **Positioning.** Meetings, sales calls, appointments, talks and rehearsal, with the capture notice
   every start (recommended). Interviews are where this category's paying users are; if they are
   named, the notice still holds, and interview *practice* (the app asks questions from the wearer's
   CV or a job ad) is the clean way to serve them.
9. **Long-session limit.** 2 h with a warning (recommended); 4 h; or none.
10. **Temple taps during a session.** They repeat and skip hints instead of waking the assistant
    (recommended); or a tap still wakes the assistant and repeat lives on the band and the Live
    Activity only.
