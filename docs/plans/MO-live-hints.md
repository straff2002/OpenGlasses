# Plan MO — Live Hints (when the other person asks a question, a short answer from your own documents, on the lens or in your ear)

**Status:** 📝 Drafted 2026-11-20. Nothing is implemented. Decisions 1–9 are owed (§10); each has a
recommendation.
**Track:** Everyday assistant: conversations. Captions, speaker separation, documents, the lens, speech
output.
**Origin:** The owner asked what to bring in from Hinty (hinty.eu), a real-time "voice assistant" that
listens to a conversation and suggests answers. hinty.eu could not be fetched from the cloud session
(the host is outside its network allowlist), so what follows about Hinty comes from search results
quoting its own pages and store listing. Those pages contradict each other on prices and on some
details. See [What Hinty does](#what-hinty-does-as-of-2026-11-20).
**Builds on:**
- `AmbientCaptionService`: `captionHistory`, `CaptionEntry.speaker`, `CaptionCursor`, the
  diarized path (`DeepgramSTTService`), `SpeakerRegistry`, `showOnLens` / `HUDCaptionBuilder`.
- Plan [AQ](speaker-diarization.md): speaker chips and tap to name (`SpeakerChipModel`), and the
  bystander-consent text in `DiarizationSettingsView`.
- Plan [O](O-document-rag.md) / [P](P-chunk-citations.md): `DocumentStore.query(_:limit:namespace:documentIds:)`.
- Plan [AN](projects-scoped-contexts.md) (Projects): `ProjectContextService` and the active project's namespace.
- `MeetingAssistantService` (the 60-second meeting summary) and `AudioRecordingService`, which is the
  only thing that starts it today.
- `UtteranceQuestionCue.isQuestion(_:languageCode:)` (`QuietAfterActions/QuietTurnJudge.swift`).
- Plans [LC](LC-the-lens-made-ready.md) and [MG](MG-reading-the-conversation-on-the-lens.md): `GlassesDisplayService.presentAnswerCard(_:wearerLed:onSelect:)`, the
  `wearerLed` rule, and the answer card's measured page budget.
- `MicRoute` / `MicRoutePolicy` (Plan CL P3), and `AssistantVoiceGating` with
  `AudioRecordingService.gatedConsumer(gate:)`.
- Plan [LU](LU-private-conversation.md) (Private Conversation), Plan [KP](KP-answers-you-can-act-on.md) P5 (`keepCaptionSessions`),
  and `AIFeatureRegistry`.

**Sits beside:** Plan [C](C-live-coach-tool.md) (live coach, camera-led, unrelated), the
[Teleprompter](teleprompter.md) (your own script on the lens; it owns the display while it runs, and
so does this), and Plan [BY](BY-live-translation-captions.md) (translated captions).

---

## Trigger

Hinty's core loop is one we have every part of and have never joined up. The other person asks a
question, and within a second or two the wearer has a short answer drawn from their own documents:
two lines on the lens, or a sentence read into their ear. Our captions already know what was said,
and often by whom. Document search already finds the passage. The lens already shows answer cards.
Speech output already exists. The nearest thing we have, the meeting assistant, does something
different: every 60 seconds it posts a summary and *questions for the wearer to ask* as a lock-screen
notification, it doesn't read the wearer's documents, and it runs only while a recording runs.

---

## What Hinty does (as of 2026-11-20)

From Hinty's own pages ([assistant](https://www.hinty.eu/assistant),
[app features](https://www.hinty.eu/app-features), [features](https://www.hinty.eu/features),
[Chrome extension](https://www.hinty.eu/chrome-extension), [mobile app](https://www.hinty.eu/mobile-app),
[Google Play](https://play.google.com/store/apps/details?id=com.hintyapp&hl=en-US)) and the owner's
screenshot of the iOS app:

- **Core flow:** it listens, transcribes, tells speakers apart and picks out questions. It then shows
  a suggested answer in "about 1–2 seconds", drawn from PDFs the user uploaded.
- **Conversation** (multi-speaker): separates speakers and gives a hint only when the *other* person
  asks a question.
- **Lecture** (single speaker): sums up the key points as one person talks.
- **On keyword** ("On-Command"): stays quiet until a trigger word the user chose comes up, then looks
  up a fact.
- **Talk settings:** language, style, and a "document folder". **Talk note:** a summary after stop.
- **"After start say: 'Hinty, it's me'":** apparently how it learns which voice is the user's.
- **Glasses:** "in testing". With a display it shows two short lines, and on Ray-Ban Meta or earbuds
  it reads the hint aloud. The Meta Ray-Ban Display version is a web app that runs only in Meta's
  Developer Mode.
- **Pricing:** by listening minutes. The free tier is quoted as 5, 10 or 30 minutes a month depending
  on the page, and paid plans run about $7.50–$20 a month.
- **Privacy:** the Chrome extension's free mode transcribes in the browser, and its paid mode sends
  audio to Hinty's servers.
- **Positioning:** mostly job interviews ("AI was whispering the answers during my job interviews").

---

## What exists (verified 2026-11-20 on `origin/main` 727c8a9)

- **Captions.** `AmbientCaptionService` keeps `captionHistory` (newest first, capped at 50) of
  `CaptionEntry { text, timestamp, seq, speaker: Int?, original, language }`. Consumers track their
  place by `seq` through `CaptionCursor`, because the history is capped. The service has three paths,
  chosen per session: translated (BY), diarized (Deepgram, when `Config.isDiarizationConfigured`;
  opt-in, keyed, never in HIPAA mode), and on-device `SFSpeechRecognizer` with `addsPunctuation`.
  Only the diarized path sets `speaker`.
- **Captions hear our own voice.** The caption consumer is added with
  `wakeWordService?.addAudioBufferConsumer(id: "ambient_captions")`, with no assistant-voice gate.
  The service's own comment says synthesized speech is transcribed "as if a person had said it".
  `AudioRecordingService` already wraps its consumer in `gatedConsumer(gate:)`, and captions do not.
- **Speakers.** `SpeakerRegistry` maps a Deepgram per-session cluster id to a name the wearer typed.
  `AIFeatureRegistry.speakerIdentification` is screened `.none`, not biometric, and its note says
  why: "no voiceprint, embedding or cross-session voice match exists." This plan keeps that sentence
  true (§3).
- **Meeting assistant.** `MeetingAssistantService.start(captionService:llm:)` reads captions through a
  `CaptionCursor`. It analyses every 60 s, or early at 100 buffered words, and posts a summary plus
  2–3 follow-up questions as a `UNNotification`. It is started only by `AudioRecordingService` and
  `VideoRecordingService` with `autoTranscribe`. It doesn't search documents, and nothing reaches the
  lens.
- **Question detection.** `UtteranceQuestionCue.isQuestion` knows English leading words, polite
  requests and clause joiners. For a language it has no words for, it returns **true**. That is
  right for its current caller and wrong for a hint trigger, which would then fire on every sentence
  (§4).
- **Documents.** `DocumentStore.query(_:limit:namespace:documentIds:kinds:alsoWithin:)` is on-device
  and synchronous. `ProjectContextService.shared` resolves the active project's namespace and name.
- **The lens.** `presentAnswerCard(_:wearerLed:onSelect:)` takes MG's measured page budget. An answer
  the wearer didn't ask for (`wearerLed: false`) stays off a lens they dismissed. `showCaption` draws
  the caption frame.
- **The mic.** `MicRoute` is `phone` / `glasses` / `headset`. Its own comment says that on Display
  glasses the firmware puts its call screen over the lens whenever the glasses' hands-free link is
  the mic, and the `headset` route exists for that reason. The DAT field reports add that opening
  the glasses mic over HFP can end Display sessions (android #210, ios #342), which we haven't yet
  seen on our hardware.

---

## What we take, and what we don't

| Hinty | Here |
|---|---|
| Hint when the other person asks a question | **Take**: §4–§6, the core of this plan |
| Answers from your document folder | **Take**, as the active project or a picked set of documents (§5) |
| Two lines on the lens / a sentence in the ear | **Take** (§6) |
| Conversation / Lecture / On keyword | **Take** as three modes of one session (§2). Lecture and keyword reuse what exists. |
| Talk note after stop | **Take**, through the existing meeting summary and caption-session switches (§8) |
| "Hinty, it's me" | **Don't take.** A stored voice that identifies the wearer next time is a voiceprint, which Meta's Acceptable Use Policy forbids without a written exception, and which would make `speakerIdentification` biometric. The wearer taps their own chip instead, for this session only (§3). |
| Minutes, free tier, paid plans | **Don't take.** The wearer brings their own provider. A long-session guard is enough (§9). |
| Interview and exam positioning | **Don't take.** It conflicts with the AUP's ban on covert collection of recognisable audio, and with our consent copy. Meetings, sales calls, appointments and talks are the pitch (§9, decision 8). |
| Chrome extension / web dashboard | Out of scope |

---

## Design

### 1. One session, started on purpose

**Live hints** is a session the wearer starts: from a Home card, from the Chat tab, or by voice
("start live hints", "hint me in this meeting"). It never starts itself, and it never runs in the
background of another session. It turns captions on if they're off (and back off at stop if it turned
them on), shows the capture notice (§9) and runs until stopped. It also stops at the long-session
limit, when the app is backgrounded beyond the presence rule captions already follow, or when the
glasses are taken off with the phone mic off.

It owns the lens while it runs, as the teleprompter does. Captions stay on the lens between hints,
and a hint replaces the caption frame until it is dismissed or times out.

### 2. Three modes

- **Conversation:** a hint when a question is asked by someone who isn't the wearer (§3–§4).
- **Lecture:** no question gate. Every ~60 s, or at a pause after ~100 words, one key-point line goes
  to the lens. This is `MeetingAssistantService`'s analysis with a lens sink and a shorter prompt;
  the notification sink stays for recordings. A question the speaker asks the room is still offered
  as a hint.
- **On keyword:** the wearer lists trigger words or names (a product, a price list, a client name).
  When one is said, by anyone, the passage it hits is put on the lens as a fact card. Matching is on
  whole words, ignores case, and holds each word for 60 s after it fires. It needs no model at all:
  the card is the best passage, trimmed (§5). This mode works fully offline.

### 3. Which voice is the wearer's

Conversation mode wants to skip the wearer's own questions. Only the diarized path knows speakers,
and its ids are per session.

- **With diarization on:** the session screen shows the speaker chips. The wearer taps theirs once,
  then **That's me**. The mapping lives in the session's memory and is never written to
  `SpeakerRegistry`, because a cluster id means nothing next session. Until the wearer taps, every
  question gets a hint. A hint to the wearer's own question is a wasted call, not a harm.
- **Without diarization** (the default, and always in HIPAA mode): every question gets a hint, and
  the mode picker says so ("Can't tell voices apart; hints for every question").
- **Never:** no enrolment phrase, no stored voice sample, no embedding, no cross-session match. A
  test pins `AIFeatureRegistry.speakerIdentification`'s screening note and asserts that live hints
  write nothing to `SpeakerRegistry`.

### 4. When a caption is a question (`HintTrigger`, pure)

Input: a final `CaptionEntry`, the wearer's speaker id if known, the language, the time of the last
hint, and the mode. Output: `.hint(question)`, `.keyword(word)` or `.none`, with a reason for the log.

- Only **finals**: an interim caption is revised, and a hint on a half-sentence is worse than none.
- In a language `UtteranceQuestionCue` supports, use it. In one it doesn't, use the question mark
  alone (both caption paths punctuate), and **never** fall back to its `true`.
- Skip the wearer's speaker, and the `[Visual:` notes recordings insert.
- Skip anything under 4 words ("Right?", "You know?") and tag questions ("…, isn't it?").
- At most one hint in flight. A new question replaces a pending one, because the old one is stale
  once the next is asked. Leave at least 8 s between hints unless a new speaker asks.
- Context: the question plus the last ~6 finals, so "and what about the second one?" can be resolved.

### 5. The answer (`HintComposer`)

1. **Search:** `DocumentStore.query(question, limit: 4, namespace: <session scope>)`. The scope is the
   active project's namespace, or documents picked on the session sheet (decision 5).
2. **Compose:** one model call through `LLMService`'s existing provider rules (whatever applies to a
   Direct turn, including HIPAA and Medical Local Only, applies here). The system prompt asks for
   **at most 2 lines / ~22 words**, plain text, no preamble, the wearer's language. It answers from
   the passages first. If they don't hold the answer, it may answer from general knowledge, marked
   (decision 6), or say nothing. The passages are quoted as data and pinned against injection, as
   `TranslationPromptBuilder` does: words spoken in the room must not be able to steer the hint.
3. **Stream:** the first line goes up as soon as it arrives. A latency budget of 2 s from the final
   caption to the first line is logged (`PrivacyLog`, characters and timings only) and shown in
   Developer.
4. **No model:** in keyword mode, or when no provider is reachable, the card is the best passage's
   sentence that holds the question's or keyword's terms, trimmed to the card, with its document name.
   `documentId` and `chunkIndex` go with every card, so a press opens the passage on the phone (Plan P).

### 6. Delivery

- **Lens** (a Display is connected): an answer card through `presentAnswerCard(_:wearerLed: false)`.
  A dismissed lens stays dismissed, so the wearer stays in charge of it, and "show hints" or a press
  on the Home card brings it back. Lifetime 20 s, the same as the Display's own dim after 20 s
  without input. A soft tick on the phone or earbuds when a hint lands, because the wearer may not be
  looking (DAT field notes: whether a new send wakes a dimmed lens is unconfirmed).
- **Ear** (no Display, or the wearer chose ear): the hint is spoken at the wearer's speech rate. It
  waits for a pause of ≥ 0.6 s in captions if one comes within 3 s, then speaks anyway. A newer hint
  cuts an older one off mid-sentence.
- **Our own voice is not a caption.** Captions get the assistant-voice gate (`gatedConsumer(gate:)`)
  for the life of a hints session, so a spoken hint is never transcribed, re-detected as a question or
  kept in a talk note. This fixes a standing gap for every caption session, and it ships in P0
  whether or not the rest does.
- **Phone:** the session screen always shows the last 10 hints with their passages, in memory only.

### 7. The mic

The default comes from the setup, not from a global setting:

| Setup | Mic | Why |
|---|---|---|
| Ray-Ban Display | **phone** (or headset) | The glasses' hands-free mic covers the lens with the call screen and is reported to end Display sessions |
| Ray-Ban Meta / Oakley (no display) | glasses | No lens to lose, and hints are spoken |
| Phone only | phone | — |

The session sheet shows the mic and lets the wearer change it, with the Display caveat beside
**Glasses**.

### 8. What is kept

Nothing by default. Hints and the session's captions live in memory and go at stop.

- **Talk note** (a switch on the session sheet, decision 7): at stop, the existing meeting-summary
  prompt over the captions, saved as a conversation note. It follows **Keep caption sessions** for the
  transcript, is never saved in Medical Compliance mode, and is never saved in a Private Conversation
  (Plan LU).
- Hints are not written to `ConversationStore`, `BrainStore` or memory. A hint is not something the
  wearer said or asked.

### 9. Consent, policy and limits

- **Capture notice:** at start, every time, one line on the phone: *"Live hints listens to everyone
  near you. Tell people you're using it."* It is the diarization bystander copy, shortened. On the
  first start ever, a full sheet explains where audio goes for each path (on device, or the
  transcription provider when speaker separation is on) and what is kept (§8).
- **No covert mode:** no hidden UI, no muted notice, no "stealth" setting. The phone shows a live
  "Listening" pill for the whole session.
- **Meta AUP:** no identification by voice (§3). No analysis of people around the wearer. A hint
  answers the question asked, from the wearer's documents; it never describes the person asking it.
- **`AIFeatureRegistry`:** a new `.liveHints` record, screened `.none`, with a disable switch, stores
  `[]` (or the conversation note when the talk note is on), and a screening note covering §3 and §9.
- **Long sessions:** auto-stop after 2 h with a spoken warning at 1 h 55. Model calls are counted in
  the session footer ("31 hints"), so a cloud bill isn't a surprise.

---

## Phases

**P0 — The pure core, plus the echo fix** (headless, one PR)
- `HintTrigger` (§4) with tests: finals only, unsupported language → question mark only, wearer
  skipped, short and tag questions skipped, spacing, replace-pending.
- `KeywordMatcher` (§2) with tests: whole words, case, hold window, multi-word triggers.
- `HintCard` / `HintComposer.prompt` / the no-model passage trim (§5), with injection tests: a
  caption saying "ignore your instructions" comes out as a quoted question.
- The assistant-voice gate on the caption consumer (§6), with a test that a gated buffer never
  reaches recognition.

**P1 — The session** (one PR)
- `LiveHintsService`: start/stop, owns captions if it started them, `CaptionCursor`, one hint in
  flight, the three modes, the long-session guard, `PrivacyLog` events.
- Delivery to the lens (answer card, `wearerLed: false`), to the ear, and to the phone list.
- Mic defaults by setup (§7).
- Lecture mode moves `MeetingAssistantService`'s prompt behind a sink: notification for recordings,
  lens for hints.
- `.liveHints` in `AIFeatureRegistry`, the capture notice and the first-run sheet.

**P2 — The surfaces** (one PR)
- Home card and session sheet: mode (Conversation / Lecture / On keyword), documents (active project
  or picked), delivery (lens / ear), mic, talk note, keyword list.
- Session screen: Listening pill, speaker chips with **That's me**, the last 10 hints, stop.
- Voice: "start live hints", "stop hints", "show hints", "hint me about …" (adds a keyword).
- Watch: start/stop and the last hint, if Plan CS's surfaces allow it cheaply. Otherwise left out.

**P3 — Device pass** (owed, GiPhone)
- Ray-Ban Display with the phone mic: hint latency (target ≤ 2 s to first line), whether a send wakes
  a dimmed lens, and whether the Display session survives an hour.
- Ray-Ban Meta: spoken hints, and whether open-ear playback leaks into the phone mic despite the gate.
- Two people, diarization on: does **That's me** hold for the session.

---

## Not doing

- Voice enrolment of any kind, or remembering a voice between sessions.
- Describing, profiling or judging the person who asked (AUP; Plan HR's observe-only line still holds
  for Social mode and isn't touched here).
- Meter, minutes or a paywall.
- A browser extension or a web dashboard.
- Joining a phone or video call's audio. Live hints hears the room through the mic, nothing else.

---

## Decisions for Greig

1. **Name.** *Live hints* (recommended), *Prompter*, or *Whisper*. "Whisper" collides with the speech
   model of that name in our own settings.
2. **The wearer's voice.** Per-session **That's me** tap, never stored, and without diarization every
   question gets a hint (recommended). The alternative is to require diarization for Conversation mode,
   which would make it cloud-only and unavailable in HIPAA mode.
3. **Default delivery.** Lens when a Display is connected, else ear (recommended); or always ask at
   start.
4. **Mic on a Ray-Ban Display.** Phone by default (recommended, §7); or follow the global Microphone
   setting.
5. **Which documents.** The active project, changeable on the session sheet (recommended); or a
   per-session picker every time.
6. **Answers beyond the documents.** Allowed, marked "general" on the card (recommended); documents
   only; or the wearer's choice per session.
7. **Talk note.** Off by default, a switch on the session sheet (recommended); or on by default when
   **Keep caption sessions** is on.
8. **Positioning.** Meetings, sales calls, appointments and talks, never interviews or exams, and the
   capture notice every start (recommended). The alternative, to stay silent on use cases, still
   keeps the notice.
9. **Long-session limit.** 2 h with a warning (recommended); 4 h; or none.
