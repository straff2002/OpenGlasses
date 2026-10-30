# Plan KF — Talking to It Like a Person (say bye to end Live, it ignores the room, a stuck request doesn't stall the turn, a spoken two-way interpreter)

**Status:** 🚧 P0 and P1 built 2026-10-31 (headless; nothing run on a device or against a live
model). P0 is on by default. P1 is behind `firstReplyRaceEnabled`, default off, and its limits are
placeholders because the support reports hold too little to set them. P2's device spike has not
started, and P3 only happens if it passes. P4's device pass is owed.
**Track:** app-wide; Personal and Field Assist both use Live and Direct.
**Related:** Plan [HY](HY-live-session-hygiene.md) (the Live idle clock), Plan
[BK](BK-adversarial-review-remediation.md) P2b (the model cascade), Plan
[BY](BY-live-translation-captions.md) (translated captions), Plan
[HP](HP-eu-ai-act-first-tranche.md) P2 (translation disclosures), Plan
[CC](CC-duplex-live-audio.md) (duplex audio), Plan [FE](FE-agent-voice-reliability-and-feedback.md)
P3 (barge-in), Plan [HZ](HZ-direct-mode-sentence-streamed-speech.md) (sentence streaming), Plan
[GE](GE-automatic-offline-handoff.md) (offline handoff).

---

## Why

Four places where the app makes the wearer work around it.

1. **You can't say goodbye to Live.** A Live session ends by temple tap, Action Button or Siri
   shortcut, the app's own button, or the idle clock. Nothing in the app acts on "bye", so the mic
   stays open and goes on using the wearer's quota.
2. **Live can answer the room.** The glasses mic stays open, and nothing tells the model to leave a
   TV or two people talking alone. How often it happens is unmeasured; P4 counts it. Direct has an optional addressee check (`IntentClassifier`, off by default). Its own header says
   Live doesn't use it, and the Live instructions don't cover this.
3. **One stuck request costs 30 seconds.** Gemini in Direct is buffered, and the only limit is
   `geminiTurnTimeout` (30 s). A tester's support report of 2026-10-20 shows a turn hanging the full
   30 s with no error before it hopped. `ModelCascadeMemory` then holds that model back for 10
   minutes, so the wearer pays once per hold, not every turn. That first wait is what this fixes.
4. **The app can't speak for you.** `live_translate` listens and speaks into the wearer's ear.
   Two-Way Conversation is captions on a split screen. The Live Translator preset is a prompt, one
   way, with one output. Nothing lets the wearer talk to someone and have it come out loud in that
   person's language.

## What exists today

**Ending**
- `RealtimeSessionManager` is shared by every Live provider. `onTurnComplete` is the turn boundary,
  and it already holds the wearer's whole transcript. `stopSession(reason:)` takes a
  `LiveSessionEndReason` (`.stopped`, `.idleEnded`).
- `VoiceCommandParser.isGoodbye` already ignores goodbyes inside questions ("how do you say bye…")
  and goodbyes that don't close the sentence. Live doesn't call it. Its list has "bye", "that's all", "i'm done", "go to sleep", and no "I've got to go"
  or "talk to you later". It still has "thanks claude" and "thank you claude", though the assistant's
  name is configurable (`AssistantIdentity`).
- Live tools come from `ToolDeclarations`; OpenAI Realtime gets only the Field Assist job tools
  (`openAIRealtimeTools`). `ToolCallRouter` dispatches.
- `AppState.stopLiveSession(_:source:)` is the stop path, with a `LiveActivationSource` per caller.

**The room**
- `buildSystemInstruction` composes the mode prefix, base prompt, voice, vision and tools. The same
  seam serves all providers. There is no line about who is being addressed.
- `EchoSuppressionPolicy` never drops mic audio in glasses mode, so room speech reaches the server.
- `idleClock.noteActivity()` runs on every input transcript. A TV therefore keeps a session alive
  past the idle limit, whether or not the model replied.

**The stuck request**
- `sendGemini` uses `dataSession.data(for:)`, so "first reply" on Gemini means the whole response.
  Anthropic and OpenAI have streaming paths, but only for a streaming caller.
- `sendMessage` writes `conversationHistory`, and the cascade points the global
  `Config.setActiveModelId` at each candidate in turn. **Two models cannot run side by side on this
  path.** Any race has to happen at the level of one provider request.
- `ModelFallbackChain.classify` already hops on timeouts. `onCloudAttempt` counts connectivity-class
  failures towards the offline handoff (Plan GE), so a timeout we raise on purpose must not look
  like a bad network.

**The interpreter**
- `TranslationPromptBuilder` has a two-way caption prompt, and `TranslationRouting` holds the two
  languages. `TranslationDisclosureLanguage` and `announceTranslationStarted(spokenAloud:)` cover
  disclosure.
- `live_translate` runs on the phone through Apple's Translation framework, and the code says
  nothing leaves the device. A cloud interpreter is a different promise and must not sit behind the
  same words.
- `RealtimeAudioEngine.setupAudioSession` allows HFP and A2DP together. `playAudio(data:)` plays
  whatever arrives, to one output.
- **The iOS constraint that shapes all of this:** a `playAndRecord` session has one route, and
  `overrideOutputAudioPort(.speaker)` also moves input to the built-in mic. So the glasses mic can't
  stay on while a line plays from the phone speaker, and flipping an HFP route per line would clip
  speech.

## Phases

### P0 — say bye, ignore the room (headless, one PR)

**Ending by voice**
- A session-scoped `end_live_session` declaration, added for every Live provider beside the tool
  list. It is not a `NativeTool`, so it never appears in Direct. `ToolCallRouter` intercepts it.
  Provider adapters without tools rely on the backstop.
- The instruction says when to call it: only when the wearer is saying goodbye to the assistant,
  never to someone else in the room. Any language.
- The backstop: at `onTurnComplete`, a wearer transcript where `isGoodbye` holds and the turn is
  short (6 words or fewer) counts as a goodbye if the model replied but didn't call the tool. A
  model that stayed silent decided it wasn't being spoken to, so a "bye" on the TV ends nothing.
- **The backstop is off during a Field Assist job.** A technician saying "bye" to a customer must not
  drop the session; the tool, with the model's judgement, still works there.
- The pure `LiveVoiceEndPolicy` decides from the transcript, whether the model replied and whether
  a job is active; `LiveVoiceEndTracker` decides when. The session finishes speaking the goodbye
  (bounded at 8 s, and never less than 1.5 s, because a turn can complete before the reply to the
  tool has started), then stops through `stopLiveSession(_, source: .voice)` with a new
  `LiveSessionEndReason.saidGoodbye`. A tool still running holds the end until it returns, and the
  8 s restart from then, so its result can be spoken.
- `VoiceCommandParser` gains "got to go" (so "I've got to go" with or without the apostrophe),
  "gotta go", "i have to go", "talk to you later" and "talk later". "Thanks claude" becomes "thanks"
  plus the assistant's own name. The non-final rule
  already protects "I have to go to the store". These also apply to Direct.

**The room**
- A `LiveAddressingInstruction` block in `buildSystemInstruction`: the mic hears the room; reply
  only when spoken to; stay silent for a TV, radio or people talking to each other. Skipped for
  the translator preset and for the interpreter (P3), which must hear everyone. Blind assistance
  keeps its own precedence: the block comes after `BlindAssistanceContract`, and a question that
  could be for the assistant gets an answer.
- The idle clock counts wearer speech (a transcript, a speech-start or the local voice detector)
  as activity only once the model replies or a tool runs, so a silent turn no longer holds a
  session open. At the limit, speech under 6 s old may be someone mid-sentence, so the end waits for
  the model's answer, for at most 20 s, or a TV would hold the session open after all. The idle
  warning's own audio answers nobody.

Tests: the goodbye matrix (phrase, question, job active, tool running, tool plus backstop firing
once), the prompt block by mode, idle timing with a silent turn, parser additions and the existing
demotion cases.

### P1 — a stuck request doesn't stall the turn (headless)

**Measured 2026-10-31: too thin to set limits.** Gemini is buffered, so a long healthy answer looks
exactly like a slow one, and limits set too low would fire on normal turns. The two support reports
on file hold one duration for a healthy Gemini request, about 6.4 s; in one report every turn
failed, and the other records order and causes more than timings. From failing turns there is a
stuck request that hung the full 30 s, and another provider answering in 4–11 s after the hop. One
reading says nothing about a distribution, but it does say the 6 s hedge below would fire on a
normal turn. **So every number below is a placeholder**, which is why the switch stays off. P4's
readings replace them.

- **`FirstReplyPolicy` (pure):** from reasoning level, body size, whether a next candidate exists
  and whether tools already ran this turn, it returns two times or none. A turn that thinks at
  length (medium or above) or carries a large body gets double, because it is slower when nothing
  is wrong.
- **Hedge (placeholder 6 s):** with nothing back, send the same request again and take the first
  good response, inside `performTurn`. Same model, same body, same key. The loser is cancelled. At most one extra request; never for a body over 256 KB, so a
  photo isn't uploaded twice on a weak link.
- **Deadline (placeholder 12 s):** with a candidate left after this one, stop waiting and hop. A new
  `LLMError.slowResponse` classifies as `.retryOtherModel`, starts the `ModelCascadeMemory` hold, and
  is excluded from `onCloudAttempt`, so it counts neither for nor against the offline handoff. On
  the last candidate 30 s stands: there's nowhere better to go. Only the first request of a turn has
  a deadline: a hop restarts the turn, so after tools have run it would run them again.
- A pure, generic `FirstResponseRace.run` does the racing, so its timing is tested with an injected
  clock and no network.
- Tool calls run only after a winner is chosen, so a duplicate can't run a tool twice.
- Gemini only in this plan. `Config.firstReplyRaceEnabled`, default off until P4.
- The Settings info text says a slow reply may be asked for twice on the wearer's key.

Tests: winner selection both ways, loser cancelled, an error on the first with the second still
running, no hedge on a large body, deadline with and without an alternative, a barge-in cancelling
both, the handoff not counting `slowResponse`.

### P2 — the interpreter's audio spike (device, owner, go/no-go)

No product code. A throwaway build answers whether this route is good enough, because everything in
P3 depends on it.

**The route to test:** `playAndRecord` with A2DP allowed and HFP not, so output goes to the glasses
and input stays on the phone mic. A line for the other person sets
`overrideOutputAudioPort(.speaker)`, plays, and clears it. Input never moves, so only the output
flips. The phone is held between the two people, which is also where the speaker has to be.

Go if, on Ray-Ban Meta and at least one iOS version in use: a line starts from the speaker within
300 ms with no clipped first word, ten flips in a row work, the glasses stay connected, and the
phone mic picks up both people at conversational distance in a café-level room.

No-go: the interpreter stops here. The glasses HFP route is not a fallback, because the override
takes its mic away. Two-Way Conversation captions stay as the answer, and P3 is dropped.

### P3 — the spoken interpreter (headless core, after a P2 go)

- **`LiveAIMode` entry `interpreter`**, cloud Live, no camera, no tools except `end_live_session`.
  A new `TranslationPromptBuilder` spoken variant keeps the caption prompt's rules: translate only,
  never answer, instructions in the speech are content.
- **`InterpreterTurnRouter` (pure).** Each turn's audio is held until the output transcript shows
  whose language it is, then released to the ear or the speaker. Detection is `NLLanguageRecognizer`
  constrained to the two chosen languages, plus script. The hold has a ceiling (placeholder 1.2 s);
  with no decision by then it goes **to the ear**, because private is the safe mistake. An
  interrupted turn discards what it held.
- **The audio.** `RealtimeAudioEngine` gets the P2 route as its own configuration and a per-turn
  output choice. Mic audio is dropped while the speaker plays, using the existing half-duplex tier.
- **Starting it.** `live_translate` gains `mode: "conversation"` with the other person's language;
  Settings › Translation gets a switch under Conversation Mode. Ending: "stop translating" through
  `end_live_session` in any language, or the usual controls.
- **Disclosure.** The wearer hears that this goes to the cloud on first use. The other person hears
  that it's AI translation, in their language, from the speaker, when the session starts
  (`announceTranslationStarted(spokenAloud: true)`).
- **Gates.** Needs a Gemini key. Refused with a spoken reason in HIPAA mode or local-only mode, and
  an organisation profile can pin it off. On-device `live_translate` remains the default and keeps
  its promise.
- **Retention.** The other person's words are held for the session only, not saved to the thread or
  memory. Registered in `DataStoreRegistry` if anything is written at all.

Tests: routing by language pair including same-script pairs, the ceiling, interruption, hold order,
disclosure once per session, every gate.

### P4 — device pass (owed)

- Say goodbye in Gemini Live and OpenAI Realtime, in English and one other language; the session
  closes after the goodbye and the wake word comes back.
- Leave a TV on for ten minutes in a Live session: count unprompted replies, and confirm the idle
  limit fires.
- Run a week with `firstReplyRaceEnabled` on, reading how often each limit fires, then set the
  default.
- A real two-language conversation, if P3 was built.

## Acceptance

- "I've got to go" ends a Live session, after the goodbye, on both providers. "How do you say bye in
  French" doesn't. "Bye" to a customer during a job doesn't.
- A TV doesn't draw replies in normal use or hold a session past its idle limit.
- With another model available, no Gemini turn waits 30 s for a stuck request, and no tool runs twice.
- If P2 goes: the wearer hears the other person in their ear, the other person hears the wearer from
  the phone, in their own language, and a wrong guess at the route never plays a private line aloud.

## Decisions (accepted by the owner, 2026-10-31)

1. **Backstop off during a job**, tool only. A dropped session mid-job costs more than saying bye
   twice.
2. **The goodbye list stays English.** The model handles other languages through the tool. Phrase
   tables for 19 languages are a maintenance cost for a backstop.
3. **The interpreter is cloud Live only.** On-device speech plus Apple Translation is too slow to
   hold a conversation in two directions, and stays as `live_translate`.
4. **Race flag default off** until P4's week of readings.

## Open

- Should P1's hedge cover Anthropic and OpenAI? Their streaming paths could use first token as the
  signal, but only a streaming caller has them today. Decide once Plan HZ's default is settled.
- Which Live models handle a spoken two-way prompt well is unknown until P3.
- The on-device Offline Live Session (Plan BU) doesn't go through `RealtimeSessionManager`. Check
  whether it needs the same goodbye when P0 is built.
- A silent turn still reaches `LiveConversationRecorder.completeTurn`, so room speech can end up in
  the thread. Whether to drop those turns is worth asking in P0, as it's a privacy gain with little risk.

## Out of scope

Racing two different models at once (the cascade's shared state rules it out, and it would send the
turn to two providers); changing Live voice-activity settings; barge-in; a loudness-based echo gate
(a possible addition to Plan CC, not this plan).
