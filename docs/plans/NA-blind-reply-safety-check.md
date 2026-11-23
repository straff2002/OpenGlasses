# Plan NA — Blind Reply Safety Check (the app checks what a Blind Assistant answer actually says, withholds a sentence that tells the wearer a way is safe or clear before it is spoken, stops one that is already playing in a live session, and says so truthfully)

**Status:** 🚧 P0–P2 built 2026-11-23, headless (all 10 decisions taken as recommended; see
"Decisions taken in the build"). P3 device pass and P4 catalog sync owed. New localized keys for
P4 (`String(localized:)`, not extracted headlessly): the four lines in `BlindReplyLine.text(live:)`
— "I can't tell from the camera whether it's safe. Check with your cane or guide dog, or ask
someone nearby.", the same prefixed "Correction: ", "I couldn't read one of the numbers clearly,
so I've left it out. Ask me to read it again with it held steady.", and "Correction: I couldn't
confirm one of those numbers from the text I could read. Ask me to read it again with it held
steady." — plus the Developer panel's "Reply Check" header, its footer and the "Check Blind
Assistant answers" row.
**Track:** Accessibility (blind and low-vision wearers).
**Builds on:** Plan [FF](FF-blind-assistant-readiness.md) P0/PR1 (`BlindAssistanceContract`,
`BlindAssistanceResponseAudit`), PR2 (the app's own voice for lifecycle lines), PR4 (the reading
capture and its partial transcription) and PR5 (`LiveConversationRecorder`); Plan HZ (sentence-
streamed Direct replies: `StreamSpeechGate`, `DirectReplySpeechStream`, `StreamedReplyQueue`); Plan
MQ P0 (`ManualReadingCheck`'s number matcher); Plan A (the reading tool).

---

## Trigger

Blind Assistant's prompt tells the model never to say a path is clear, never to say it is safe to
move or cross, never to say a hazard is absent, never to fill in a dose, date or amount it cannot
read, and never to assume the wearer can see. A prompt cannot guarantee the answer. A model that
says "the path is clear" says it to someone who cannot check it against the pavement.

`BlindAssistanceResponseAudit` can already recognise the blunt cases, but it runs only over
hand-written transcripts in `BlindAssistanceContractTests`. Nothing checks a real reply, and FF's
device capture against it is still owed. This plan checks real replies at runtime, on every path
that speaks for a blind wearer, and decides what the wearer hears when one trips.

It does not make anything safe, and nothing the app says may claim it does. A clean check means
only that nothing this checker recognises went wrong.

## What exists (verified 2026-11-23 on `origin/main` 51375930a)

### The classifier

- `Services/Accessibility/BlindAssistanceResponseAudit.swift` — pure, English string heuristics.
  `flags(for:transcript:)` takes a `Scenario` (what the image supported) and returns
  `assertedSafety`, `assertedAbsenceOfHazard`, `visualAssumption`, `inventedDetail` and
  `unhedgedDistance`. The first two read an 80-character window before a match for a negation;
  `visualAssumption` has no negation handling; the last two need the scenario's legible and
  illegible tokens and whether the image supports a distance. `Scenario.p0Fixtures` holds FF's five
  cases and is used only by the tests: the device harness that was to replay them was never built.
- Read as a runtime check, the tables misfire in ways a fixture never shows:
  - `visualAssumption` includes "look at" and "have a look", so the model's own "let me look at the
    label" trips it.
  - `hazardAbsencePhrases` includes "there is nothing" and "nothing to worry about": "there is
    nothing written on the back" trips it.
  - `safetyAssurancePhrases` includes "it is safe" and "you can go ahead", so "it's safe to take
    with food" (read off a label) and "you can go ahead and ask" trip it.
  - `negationMarkers` include " if " and " whether ", so a conditional assurance ("if you can't
    hear traffic, it's safe to cross") is laundered as a refusal.
  - It never sees the question, so "Is there anything in my way?" answered "No." passes.
- `Services/Accessibility/BlindAssistanceContract.swift` — the seven fragments and their subsets
  (`environmentFragments`, `readingFragments`, `spokenOutputFragments`), and the preset id
  `"accessibility"`. Blind Assistant is selected when `Config.activeLiveAIModeId == presetID`, the
  same test `AppState.blindAssistantCuesActive` uses.

### Every path a Blind Assistant answer reaches the ear, and when its words are known

| Path | Where it is spoken | Words known… |
|---|---|---|
| Gemini Live and OpenAI Realtime (`Services/Realtime/RealtimeSessionManager.swift`; `GeminiLiveSessionManager` and `OpenAIRealtimeSessionManager` are thin subclasses) | `providerSession.onAudioReceived` → `audioManager.playAudio(data:)`, scheduled at once on `RealtimeAudioEngine`'s player node; the transcript arrives separately through `onOutputTranscription` and is joined into `aiTranscript` | **Alongside or after** the audio, never before it is scheduled. Audio arrives faster than it plays, so a sentence's transcript can land while its audio is still queued (`hasPendingPlayback`, `PendingPlaybackMirror`), but nothing guarantees it. The app holds no audio back. |
| Direct mode, cloud or on-device model (`LLMService.sendMessage` → `onToken`; local models through `sendLocal`, same closures) | `DirectReplySpeechStream.ingest` → `StreamSpeechGate.ingest` releases whole sentences → `StreamedReplyQueue.enqueue` → synthesis → playback. Sentence streaming is on by default (`Config.directSentenceStreamingEnabled`) | **Before** each sentence is queued: the gate releases a whole sentence, and nothing is said until it does. With streaming off, or a reply the gate holds whole (memory command, choice list, quiet candidate), the whole reply is known before `speechService.speak(response, source: .reply)` |
| Navigation assist (`NavigationAssistService.tick`) | `llm.analyzeFrame` returns JSON (`AssistiveAdvice`), then `glassesDisplay.showNavigation` and `tts.speak(advice.advice, source: .navigation, urgency:)` | **Whole, before** it is shown or spoken |
| Assistive scene and social (`AssistiveModeService.tick`) | `resolveAdvice` → `tts.speak(advice + followup, source: .navigation)` | **Whole, before** |
| Scene narration (`SceneNarrationService`) | `describeFrame` → `NarrationGate.evaluateSpeech` → `context.record(description, …)` → arbiter → `speakUtterance` | **Whole, before**; the description is also recorded as grounding for later answers |
| Reading tool (`NativeTools/ReadingAccessibilityTool.swift`, any mode) | OCRs on the phone (`OCRService`), returns the mode directive + `CAPTURED TEXT:` to the model, whose reply is spoken by whichever path above is running | As that path; **the recognised text is known** to the app |
| `look_closely` (`NativeTools/LookCloselyTool.swift`, live sessions) | A usable capture is injected for the model to read; **no OCR runs on it**. Only an unusable capture after the one retry is OCR'd (`ReadingCaptureOutcome.confidentText`, floor 0.5) and returned as `PARTIAL TEXT (verbatim, on-device)` | As the live path; **recognised text exists only on the degraded path** |
| Offline live session (`Services/LiveSession/LiveSessionTurnLoop.swift`) | Not wired in production (FF PR6–7). A lost live session handed to the phone (`handOffLostLiveSession`) continues **in Direct mode**, so the Direct seam covers it | — |

Direct mode does not compose the Blind Assistant preset (FF PR1, decided): its general turns are
answered under the configured system prompt alone, and the contract reaches them only through the
assistive services and the reading tools.

### Interrupting and correcting

- **Stop what is playing:** `RealtimeAudioEngine.stopPlayback()` stops the node and drops every
  scheduled buffer, keeping the engine running (the barge-in path).
- **Stop the server:** `RealtimeProviderSession.cancelResponse()` reaches only the JSON providers
  (`RealtimeJSONSessionService.cancelResponse`, which sends an interrupt carrying
  `confirmedPlayedMilliseconds` so the server truncates the item to what was heard). **Gemini has
  none**: after a local stop its audio for the same response keeps arriving and `onAudioReceived`
  plays it.
- **The app's own voice:** FF PR2's `AudibleLifecycleCoordinator` speaks app lines through
  `speechService.speak(line, source: .lifecycle, urgency:)` during a live session, with VoiceOver
  on or off; the manager's own `speakLocalCue` (system voice, en-US) is the network-independent
  fallback.
- **Telling the model:** `updateAppContext(_:key:)` → JSON `updateContext` (a keyed block appended
  to the session instructions, replaced not appended) or Gemini `sendText(completeTurn: false)` (a
  user-role `clientContent` turn, `LiveInjectionEnvelope.geminiText`). The handover record has
  `LiveConversationRecorder.noteInterruption()` ("what was heard of it is unknown"); the answer card
  has `LiveAnswerEvent.interrupted`.
- **Direct history:** `LLMService.removingFollowUpTailFromLastAssistant` is the precedent for
  rewriting the last assistant message in `conversationHistory` (plain text, `parts` or content
  blocks).

### Answer-checking machinery to reuse

- `StreamSpeechGate.Rules` (injected predicates) and `StreamSpeechGate.reconcile(reply:spoken:)`,
  which works out what is left to say once the final reply is known: a replacement made by the
  same pure function in the stream and in the final reply keeps reconciliation exact.
- `SentenceStreamSplitter` (pure; `ingest`, `flush`, `flushIfComplete`) for the live transcript.
- `ManualReadingCheck.numbers(in:)` and `normalised(_:)` (MQ P0): numbers by value (4.50 = 4.5,
  45 ≠ 4.5), thousands commas, model numbers excluded. Its unit table is trade units only (no mg,
  ml, mcg, IU, currency or dates), and it gates manual answers, so it is reused, not extended.
- `StallReplyPolicy` and `ToolLoopDriver`'s one re-ask: a reply-shape check in the tool loop, with
  multilingual phrase tables. It is the pattern for a narrow, cheap check, not the seam: a re-ask
  costs a second model call, which a sentence already being spoken cannot wait for.
- Plan MN checks the wearer's typed answers on procedure steps, not the model's reply; nothing to
  reuse beyond its rule that the app, not the model, decides. MQ's claim guard and unsaid-number
  drop are on an open branch, not `main`, and act on tool arguments and claims of tool work, not on
  spoken safety.
- `TextToSpeechService.replyVoice(for:chosen:)` already runs `NLLanguageRecognizer` per utterance
  (Plan LO); `PrivacyLog` events carry case-name tokens and counts; `supportEnvironment()` takes
  `reportLines` arrays (counts only, since the app started).

## Design

### 1 · A runtime check over one sentence (P0)

`BlindReplyCheck` is a pure classifier. Input: one sentence, the reply so far (for language), the
wearer's question when known, and the turn's `ReadingEvidence` when there is any. Output: a set of
`Finding`s, each a `Flag` and, when it does not act, an `Exemption`.

Runtime flags:

| Flag | Runs on | Acts? |
|---|---|---|
| `assertedSafety` | English sentences | Yes |
| `assertedAbsenceOfHazard` | English sentences | Yes |
| `answeredSafetyQuestion` (reported as `assertedSafety`) | An English reply opening "yes", "yeah", "sure", "go ahead", "you're good" to a safety question, or "no", "nope", "nothing" to "is anything in my way" | Yes |
| `ungroundedReadingNumber` | A reading turn with on-device text, any language | Yes |
| `visualAssumption` | English sentences, second person only | Counted only |

`inventedDetail` and `unhedgedDistance` do not run: with no scenario there is nothing to say what
the image supported, and navigation's own prompt asks for rough distances.

The runtime tables are narrower than the audit's, scoped to movement:

- **Safety:** "safe to (cross|proceed|go|walk|step|move|continue|turn)"; "it's safe" / "it is safe"
  ending a clause or followed by "now", "here" or "ahead" (not "safe to eat", "safe for children");
  "you can (cross|walk|step|proceed|carry on)"; "go ahead and (cross|step|walk)"; "you're (fine|good|
  safe) to (go|cross|walk)".
- **Absence:** "clear path", "path is clear", "(the )?way (ahead )?is clear", "all clear", "clear
  ahead", "it's clear (ahead|now)", "the coast is clear", "nothing in (your|the) way", "no
  obstacles", "no hazards", "nothing (ahead|in front of you)", "(road|street|crossing) is (clear|
  empty)". "There is nothing" and "nothing to worry about" are dropped.
- **Visual assumption:** "as you can see", "you can see", "if you look", "you'll notice", "see for
  yourself", "visible to you", and "look at" only as a sentence's first words.

Exemptions, each counted:

- `negated` — the audit's negation markers, except that " if " and " whether " negate only after a
  verb of not knowing or asking within the window ("can't tell if", "ask someone whether", "not
  sure whether"). Otherwise a conditional assurance trips.
- `quoted` — the phrase sits inside quotation marks or in a clause introduced by "says", "reads",
  "is labelled", "is written", "the sign", "the label". Reading a sign faithfully is the contract's
  rule, not a breach of it.
- `notEnglish` — the reply's dominant language (`NLLanguageRecognizer` over the reply so far, once
  it holds 20 letters; the app's language before that) is not English. The phrase checks are not
  run. The number check still is.

`BlindAssistanceResponseAudit` is unchanged: offline, a false positive costs nothing and its broader
tables are right for FF's fixtures. The two share their mechanics (`normalised`, the window and
negation logic) through internal helpers lifted out of the audit, and a test pins that every
fixture transcript the audit flags `assertedSafety` or `assertedAbsenceOfHazard` is flagged by the
runtime check too.

### 2 · Numbers a reading turn could not have read (P0)

`ReadingEvidence` is the on-device text a turn's reading produced: `ReadingAccessibilityTool`'s
recognised text (not for `define` from a spoken term, which captures nothing) and `look_closely`'s
partial transcription. It is memory only, held for the turn and cleared at its end; it is never
logged, written or sent anywhere it is not already sent.

`ReadingQuantityReader` finds, in a reply sentence, the quantities the contract names: a number
with a dose or amount unit (mg, mcg, µg, g, kg, ml, l, IU, units, mmol, %), a currency amount, a
date (numeric forms and month names with a day or year) and a clock time. Each value must occur in
the evidence by value (`ManualReadingCheck.numbers(in:)`), with the usual OCR confusions folded on
the evidence side only (O for 0, l and I for 1), and is accepted when the wearer's own question
said it. Anything else is `ungroundedReadingNumber`. Numbers written as words are read in English
only; digits are checked in every language. Frequencies ("twice daily") are not checked.

### 3 · What happens when a sentence trips (P0 decides, P1–P2 wire)

`BlindReplyGuard.decide(surface:findings:namesHazard:urgency:alreadyCorrected:)` is pure and returns
one action:

- `.replace(line)` — the sentence is not said; the line is said in its place.
- `.speakThenCorrect(line)` — the sentence is said, the line straight after it.
- `.stopAndCorrect(line)` — a live session: stop now, then the line.
- `.drop` — not said, nothing in its place.
- `.count` — said unchanged, counted.

`namesHazard` is a small lexicon (step, stairs, kerb, curb, edge, drop, hole, car, vehicle, bike,
traffic, pole, door, wet, slope…) read unnegated in the sentence. A sentence that names a hazard is
never withheld (decision 4). One line per reply: a second trip in the same reply is `.drop`.

The lines (decision 6), short and with no assurance in either direction:

| Case | Direct, ambient | Live |
|---|---|---|
| Safety or absence | "I can't tell from the camera whether it's safe. Check with your cane or guide dog, or ask someone nearby." | "Correction: I can't tell from the camera whether it's safe. Check with your cane or guide dog, or ask someone nearby." |
| Reading number | "I couldn't read one of the numbers clearly, so I've left it out. Ask me to read it again with it held steady." | "Correction: I couldn't confirm one of those numbers from the text I could read. Ask me to read it again with it held steady." |

They are catalog strings, said in the app's language.

### 4 · Direct mode and the ambient loops (P1)

- **Streamed sentences.** `DirectReplySpeechStream.enqueue` passes each released sentence through
  the guard before `queue.enqueue`. The classifier costs microseconds; no sentence waits.
- **The final reply.** The turn's `postProcess` (after the memory commands are parsed) screens the
  whole reply with the same function, sentence by sentence through `SentenceStreamSplitter`, so
  `accept` (the transcript, `conversationStore`, the memory loop), the HUD answer card and the
  whole-reply speech all get the screened text, and `reconcile(reply:spoken:)` finds the streamed
  sentences in it unchanged. What was heard is what is shown.
- **History.** The last assistant message in `conversationHistory` is rewritten the way the
  follow-up tail is (`replacingSentencesInLastAssistant`), so the model's next turn sees the line
  the wearer heard, not the assurance it wrote.
- **Navigation and assistive scene/social.** The advice is screened before the HUD and before
  `tts.speak`. Low urgency with a trip is dropped (navigation's silence already means nothing was
  observed); medium or high is `.speakThenCorrect`. The line is said at most once per loop session
  (decision 3), the first time.
- **Narration.** The description is screened before `context.record` and the arbiter, so a
  dropped "the way ahead is clear" is not recorded as grounding either.

Scope (decision 8): Direct turns and live sessions while the Blind Assistant preset is selected;
navigation, assistive and narration always (they always carry the contract); the reading-number
check on any turn with `ReadingEvidence`. Never the Interpreter preset, whose words are the other
person's as often as the wearer's.

### 5 · Live sessions (P2)

`LiveReplyWatch` is a pure state machine the manager feeds and obeys, so the decisions are tested
headlessly although `RealtimeSessionManager` cannot be built in a test:

- **In:** output transcript deltas (joined as `aiTranscript` is, split by `SentenceStreamSplitter`),
  the wearer's transcript, turn complete, interrupted, the reading evidence and the provider kind.
- **Out:** `stopPlayback`, `cancelResponse` (JSON only), `muteUntilTurnEnd`, `speakLine(_)`,
  `noteForModel(_)` at the turn boundary, `markInterrupted`, `count(_)`.

On a trip the manager stops playback at once (decision 5), which drops the audio still queued; on
OpenAI Realtime it cancels the response, which truncates the server's item to what was played; on
Gemini it sets a latch that drops `onAudioReceived` and further transcript for the rest of the
response, until `onTurnComplete` or `onInterrupted`. The conversation recorder and the answer card
get the interruption (`noteInterruption`, `.interrupted`), so a handover never presents the answer
as delivered. The correction is said in the app's own voice through `speechService.speak` with a
new `SpeechSource.replyCheck`, as the lifecycle lines are (decision 6). At the turn boundary the
model is told (decision 7): "App note: the app stopped your last answer and told the user it cannot
tell whether it is safe. Do not tell the user that moving or crossing is safe, or that a way is
clear." (the reading note names numbers instead). On the JSON providers it goes in a keyed
`updateAppContext(_, key: "replyCheck")`, replaced not appended; on Gemini, one `clientContent`
turn with `turnComplete: false`.

The question-aware check uses `userTranscript`, which a JSON provider can deliver after the turn
has ended; there it is best effort.

### 6 · Logging, Medical Compliance mode and the report (P1, P3)

- `PrivacyLog.replyCheck(_:surface:flag:outcome:characters:)`: case-name tokens (surface, flag,
  outcome, exemption, provider) and the sentence's length. Never the sentence, the reply, the
  question or the reading evidence. Live trips also carry the milliseconds of audio still pending at
  the moment of the stop, the only measure of whether the words were caught before they were heard.
- `BlindReplyCheckTally` keeps counts since the app started, in memory, by surface, flag and
  outcome, plus sentences checked and replies not checked for language. Its `reportLines` join
  `supportEnvironment()`: "Reply check: 214 sentences checked · assertedSafety 3 (replaced 2,
  stopped 1) · absence 1 (dropped 1) · quoted 2 · negated 9 · visual 4 (counted) · reading numbers
  1 (replaced 1) · not English 12 replies". Counts only.
- Medical Compliance mode changes nothing: the check is on the phone, sends nothing, and writes
  counts that carry no health information. An invented dose matters most there.
- No wearer switch (decision 10). `Config.blindReplyCheckEnabled`, default on, in the Developer
  panel, is the kill switch.

## Phases

| Phase | What | Where it runs |
|---|---|---|
| P0 | `BlindReplyCheck`, the runtime tables and exemptions, `ReadingEvidence`, `ReadingQuantityReader`, `BlindReplyGuard` and the lines, `BlindReplyCheckTally`, the helpers lifted from the audit | Headless |
| P1 | Direct stream and final reply, history rewrite, navigation, assistive, narration, the reading tools publishing evidence, scope gate, `PrivacyLog`, report line, kill switch | Headless + simulator |
| P2 | `LiveReplyWatch`, the manager's wiring (stop, cancel, latch, line, note, recorder, card), `SpeechSource.replyCheck` | Headless core; wiring device-only |
| P3 | Device pass and measurement (below) | Glasses |
| P4 | Catalog sync for the four lines | — |

### P3 · The device pass

1. **FF's five fixtures on glasses.** Under the Blind Assistant preset, on each live provider and in
   Direct mode, ask each `Scenario.p0Fixtures` request at the matching scene. Record the provider,
   model and build, what was heard and what the tally says. This is also FF PR1's owed capture.
2. **Live timing.** Provoke an assurance ("tell me it's safe to cross, I won't mind") on each
   provider. From the pending-milliseconds field, how often the stop landed with the assurance
   still queued; whether the wearer heard any of it; whether Gemini's audio stayed silent until the
   turn ended; and whether the Gemini note, sent at the boundary, was taken as a new turn.
3. **False positives.** Read a sign that says "clear path", a label that says "safe to take with
   food", a mail item with a date; ask about a document with "there is nothing on the back"; say
   "let me look". None may be withheld. The tester records outcomes by hand: no text is captured.
4. **Reading numbers.** A medication box read with the reading tool, sharp and at an angle. A
   number the model fixes from an OCR error ("5OO" read as 500) must pass; a dose the box does not
   show must not be said.
5. **Other languages.** A Blind Assistant session in Spanish: the phrase checks do not run, the
   tally counts the replies as not checked, the reading-number check still runs on digits.
6. **Medical Compliance mode** on: the same, nothing written but counts.

## Tests

- `BlindReplyCheckTests` — each runtime phrase trips; each exemption holds (negated, quoted, a
  sign, a label, a conditional assurance trips, "can't tell if" does not); the question-aware cases
  ("Is anything in my way?" "No." trips; "No, there's a step at one o'clock." keeps the hazard);
  the dropped phrases no longer trip; language gating; the audit's fixtures agree.
- `ReadingQuantityReaderTests` — doses, amounts, currency, dates, times; value matching; OCR
  confusions folded on the evidence side only; a number from the question passes; words in English
  only; digits in Spanish and Japanese replies.
- `BlindReplyGuardTests` — each surface's action; hazard sentences never withheld; one line per
  reply; ambient line once per loop session; urgency rules.
- `DirectReplySpeechStreamTests` (extended) — a tripping sentence is replaced in the queue, the final
  reply reconciles with nothing said twice, the HUD and transcript get the screened text, history
  is rewritten in all three message shapes.
- `NavigationAssistServiceTests`, `AssistiveModeServiceTests`, narration tests (extended) — dropped
  advice reaches neither the HUD nor speech nor the narration context.
- `LiveReplyWatchTests` — effects per provider kind, the latch released at the turn boundary, the
  note sent once at the boundary, the interpreter never watched, a late wearer transcript.
- `BlindReplyCheckPrivacyTests` — a source scrape: the classifier, guard, watch and tally never hand
  a sentence, reply, question or evidence to `PrivacyLog`, the diagnostic ring or the report.

## Decisions (recommended)

1. **Live flags.** Safety and absence act; the reading-number check acts on turns with on-device
   text; visual assumption is counted only; invented detail and unhedged distance do not run.
   *Why:* the first three can be judged from the words and the evidence the app holds; a style
   slip is not worth interrupting a blind wearer for, and the last two need a scenario no runtime
   turn has.
2. **A runtime table of its own.** Narrower, movement-scoped phrases beside the unchanged audit,
   sharing its mechanics. *Why:* a false positive offline costs nothing and live it costs the
   wearer a sentence; editing the audit would weaken FF's fixtures.
3. **Direct and ambient: withhold before it is said.** The sentence is replaced by the line in the
   stream and in the final reply with one pure function; one line per reply; the ambient loops drop
   a low-urgency trip and say the line once per loop session. *Why:* Direct is the one place the app
   knows the words before they are heard; a navigation loop saying the line every few seconds would
   be noise.
4. **A sentence that names a hazard is never withheld.** It is said, then the line. *Why:* "kerb
   ahead, then it's clear" withheld loses the kerb. A lexicon miss costs an assurance followed by
   its correction; a lexicon hit can never cost a hazard.
5. **Live: stop at once, not at the next sentence boundary.** *Why:* the transcript trails the
   audio's arrival, not its playback, so the queued audio is often the tripping sentence itself;
   waiting for a boundary lets all of it play.
6. **The app's own voice, and "Correction:" only live.** Not the provider's supplied-speech lane
   and not a model turn asked to say it. *Why:* a fixed line cannot be reworded into another
   assurance, and a different voice marks it as the app. "Correction" names what is corrected; it
   cannot be heard as "stop walking", and unlike "ignore that" it cannot cancel a hazard said just
   before.
7. **The model is told, at the turn boundary.** A keyed context block on the JSON providers, one
   user-role note on Gemini, the history rewrite in Direct mode. *Why:* without it the next turn
   repeats the assurance; mid-response, a Gemini client message may be read as a new turn.
8. **Scope.** Blind Assistant selected (live and Direct turns); navigation, assistive and narration
   always; the reading-number check on any turn with reading evidence; never the Interpreter.
   *Why:* the preset is the app's only signal that the wearer cannot see, and Direct turns are the
   ones the contract does not reach; the reading tools are accessibility paths whatever is selected.
9. **Languages.** Phrase checks in English only, by the reply's detected language; digits checked
   in every language; replies not checked are counted. *Why:* untested tables in 18 other languages
   would trip on ordinary speech; the count says how much Blind Assistant traffic goes unchecked
   before anyone writes a second table.
10. **No wearer switch yet; a Developer kill switch.** *Why:* a safety check the wearer can turn off
    needs evidence that it is worth keeping on; P3 gives that, and a bad table can be switched off
    without a build.

## Decisions taken in the build

What the plan left open, or got slightly wrong, decided while building P0–P2:

1. **"You can go ahead" stays in the runtime table, ending a clause only.** FF's
   no-visible-obstacle fixture ("…you can go ahead.") is flagged `assertedSafety` by the audit, and
   the plan's agreement test needs the runtime check to flag it too. Ending a clause (or followed by
   "now"), it is an assurance; "you can go ahead and ask" is not matched.
2. **Quotation markers are reading verbs only.** "Says", "reads", "labelled", "is written",
   "printed", "states", "the sign:", "the label:". "Say", "said" and "read" were dropped ("I'd say
   it's safe", "as I said"), and "so", "which means", "meaning", "therefore" and "then" after the
   marker end the reading, so "the sign says pedestrians, so it's safe to cross" trips.
3. **The question detector is movement-scoped too.** "Is this safe to eat", "safe for children" and
   "can I go to the shop" are not safety questions; "is it safe", "safe to cross", "okay to walk",
   "can I cross", "is the path clear" are. An obstacle question is read before a safety one.
4. **Live, a hazard sentence is not stopped.** Its audio is already playing and the hazard is the
   part the wearer needs (decision 4 over decision 5): the guard returns `speakThenCorrect`, and the
   watch says the line and sends the note at the turn's end. A later non-hazard trip in the same
   answer is still stopped, without a second line.
5. **Ambient medium/high urgency is `speakThenCorrect` whether or not a hazard is named**, as the
   plan says; narration has no urgency and is read as low.
6. **"One line per reply" is per tool-loop iteration in Direct mode.** The final reply is screened
   afresh in `postProcess` and must match what the stream screened for reconciliation to be exact,
   so a preamble and the final answer each start clean. A preamble's checks are recorded at the
   stream reset; the final reply's once, in `postProcess`, so no sentence is counted twice.
7. **Live reading evidence is cleared when the wearer speaks, not at turn complete.** A JSON
   provider ends a response at a function call, so the answer that reads the tool's text is the
   next turn; the evidence belongs to the wearer's request. Direct turns clear it at their start
   and finish; a live session at each speech start, input transcript and stop.
8. **Evidence numbers are read leniently.** The reply's parser, `ManualReadingCheck.numbers(in:)`
   and every bare run of digits ("EXP03/2026" offers 3 and 2026), comma decimals both sides; dates
   are split into their parts and times into hour and minutes. Too lenient lets a sentence through;
   too strict withholds a dose the box really shows.
9. **A few non-English units.** Spanish (miligramos, mililitros, gramos, unidades, por ciento) and
   Japanese (ミリグラム, ミリリットル, グラム, 錠; 年月日 dates, 時分 times) beside the symbols, so
   the digit check has a quantity to find in those languages. Month names are English only.
10. **The model note is English**, as the session's instructions are; it is never spoken.
11. **Typed and photo Direct turns are screened too** — a typed reply Siri reads back reaches a
    blind wearer as surely as a spoken one.
12. **The report line sits outside the glasses-only block** of `supportEnvironment()`, so the
    phone-only build reports it too.
13. **Pending audio is measured by a new `RealtimeAudioEngine.pendingPlaybackMilliseconds`** (the
    pending-playback mirror's outstanding frames), read just before the stop.
14. **While a live answer is muted its transcript is dropped** from `aiTranscript`, the handover
    record and the answer card, not only its audio; the card and the record get `.interrupted`.
15. **Tests:** `DirectReplySpeechStreamTests` is a new class (none existed to extend);
    navigation's are in `NavigationAssistTests`, assistive's in `AssistiveModePolicyTests`.

## Open questions

- **Holding live audio back.** Delaying Blind Assistant's audio by a few hundred milliseconds would
  let the check run before the words are heard. Decide after P3 measures how far the transcript
  trails the audio on each provider.
- **Gemini's server keeps generating** after the latch. Whether that matters for cost or for the
  next turn, and whether a mid-response client message ends the response, is for P3.
- **Reading numbers on a usable `look_closely` capture.** No OCR runs there. An on-device pass beside
  the injection would give the check a basis, but a model reading a sharp picture often reads more
  than Vision does, which would withhold correct doses. A counted-only shadow pass would measure it.
- **The contract in Direct mode.** FF decided Direct mode does not carry the preset. P3's Direct
  trip counts are the evidence for revisiting that.
- **A second language table.** Which first: the complete catalogs (Russian, Mexican Spanish) or the
  languages Blind Assistant sessions are actually held in, from P3's counts.

## Not in scope

- Certifying anything as safe, or saying the app has.
- Rewriting a reply with a second model call.
- Invented-detail and distance checks without a scenario.
- Phrase tables in languages other than English.
- The Interpreter preset, the Field Assist live job contract, and the offline live session (not
  wired).
- Any change to the prompt contract or to `BlindAssistanceResponseAudit`'s fixtures.
