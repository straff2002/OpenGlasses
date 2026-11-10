# Plan LA — Quiet After Actions (a short done tone instead of a spoken reply, only when everything really got done)

**Status:** 🚧 Built 2026-11-10 — P0–P3 in one PR, every [decision](#decisions-for-greig-taken-2026-11-10)
taken as recommended. **Owed:** the P4 device pass, and the string-catalog sync for the new UI strings (its
own later PR). What was built and where it differs from the design is in
[As built](#as-built-2026-11-10).
**Track:** Everyday assistant (Direct mode, spoken turns). Off by default.
**Builds on:** `ToolExecutionOutcome`, `ToolEffect` and `ToolExecutionSemantics`, `AttemptToolLedger` and
`HopAfterTools` (Plan [KL](KL-say-why-and-keep-the-tools.md)), `ConversationTurnRunner`, Plan
[HZ](HZ-direct-mode-sentence-streamed-speech.md) (`StreamSpeechGate`, `DirectReplySpeechStream`), Plan
[KJ](KJ-one-answer-asked-for.md) (one answer, said once), Plan [KK](KK-conversation-timeline.md) (the conversation
timeline), Plan [KP](KP-answers-you-can-act-on.md) (`HUDAnswerCard`, `FollowUpTail`), Plan
[FF](FF-blind-assistant-readiness.md) (the lifecycle earcons, "Speak What Each Sound Means", the sound tour),
`MusicCommandResult`.
**Sits beside:** the temple-tap earcons (`TempleEarcon`): those confirm a gesture, an LA tone confirms a finished
request.

---

## Trigger

A lot of what a wearer asks for is an action: "lights off", "timer for ten minutes", "pause the music". Today
every one of them ends with a sentence: "Okay, I've turned off the kitchen lights." Said once it is reassuring.
Said forty times a day it is noise, and on the glasses it talks over whatever the wearer is listening to.
Surveying adjacent wearable-assistant work turned up the same idea: when an action simply worked, a short sound
says so faster than words.

The risk is the opposite failure: a tone that says "done" when it wasn't. A song that only opened Spotify's
search page, directions left in a notification, a message still waiting for "send it". Those must still be
spoken. This plan is mostly about that honesty rule.

## Outcome

- With **Quiet after actions** on (Settings › Voice, off by default):
  - "Turn off the kitchen lights." → the done tone. The phone shows the reply as usual: "Kitchen lights off."
  - "Set a timer for ten minutes and pause the music." → one done tone for both.
  - "Play Bohemian Rhapsody on Spotify." → spoken, because only Spotify's search opened: "I've opened
    Spotify's search for Bohemian Rhapsody; tap the song to play it."
  - "Turn on the porch light." when Home Assistant times out → spoken: "I couldn't reach the porch light."
  - "What's the weather?" → spoken, always. Lookups and questions always speak.
  - "Text Sam I'm running late." → the read-back and "Send it?" are spoken as now.
- "What was that?" or "say it" straight after a quiet turn speaks the reply it would have said.
- The conversation and the timeline keep the turn, with a small mark that it ended with the tone.
- With the setting off, nothing changes.

## What exists, and what doesn't

**Exists (verified against `main` at 900808c64):**
- `NativeTool.execute(args:)` returns a `String` (`Services/NativeTools/NativeTool.swift`). Each tool declares
  `executionSemantics` (`Models/ToolExecutionSemantics.swift`), whose `ToolEffect` is `readOnly`,
  `localMutation`, `externalMutation` or `physicalActuation`. `ToolEffectClassifier.isReadAction(tool:args:)`
  makes a writing tool's read actions (a calendar "today") read-only.
- `ToolExecutionOutcome` (`Models/ToolExecutionOutcome.swift`): `completed(String)`, `rejected(reason:)`
  (refused, blocked, held or declined at the confirmation gate), `failedBeforeExecution(reason:)`,
  `outcomeUnknown(operationID:message:)`. **`completed` only means the tool returned; it does not mean the
  thing the wearer asked for happened.**
- `AttemptToolLedger` (`Services/HopAfterTools.swift`): per turn, each call's tool, arguments, `effect`, whether it
  `ran`, and its result text. `toolsRan` is `.none`, `.readOnly` or `.changedState`. `LLMService` keeps it as
  `turnToolLedger` and enters calls through `ledgerDispatched` / `finished(_:outcome:)`.
- `NativeToolRouter` (`Services/NativeTools/NativeToolRouter.swift`) dispatches native tools, runs the
  confirmation ladder through `ToolConfirmationCoordinator` (`.confirm(summary)`, failing closed with no
  coordinator), and hands the turn's tool names out through `takeTurnToolNames()`.
- `MusicCommandResult` (`Services/Music/MusicTypes.swift`) has an `Outcome` of `done`, `unsupported`, `failed`,
  `needsInput`. **When Spotify is named, `MusicControlEnvironment` opens Spotify's search screen and returns
  `.done(MusicPhraser.openingSpotifySearch(phrase))`** (`MusicControlTool.swift`). Nothing plays until the wearer
  taps, so "done" here is exactly the partial success this plan must not hide. The result reaches the model as a
  string either way.
- The Direct turn: `handleTranscription(_:)` in `App/OpenGlassesApp.swift` runs `ConversationTurnRunner`
  (`Services/Flow/ConversationTurnRunner.swift`) with `send`, `postProcess`, `accept` (appends the reply to
  `ConversationStore` with `toolNames`, feeds `MemoryLoopService`, starts the KK timeline pass) and `speak`.
  `speak` either finishes the streamed reply (`DirectReplySpeechStream.finish(reply:)`, after
  `hudAnswerCard.finishTurn(reply:)`) or calls `speechService.speakReporting(response, source: .reply)`, then
  `noteReplySpoken(_:)`.
- Streamed speech (HZ): `StreamSpeechGate` releases sentences as they arrive, holds a whole reply when
  `Rules.holdWholeReply` says later processing will rewrite it, and at `endIteration()` may release the
  iteration's last sentence: **the preamble said before a tool runs** ("Let me check the forecast.").
- The system prompt's tool rules (`LLMService.buildSystemPrompt`) say "ALWAYS speak a brief verbal
  acknowledgment BEFORE calling any tool". So an action turn usually speaks once before the tool, and again
  after it.
- Tones in `TextToSpeechService`: `playAcknowledgmentTone` / `playEndListeningTone` (`ListeningCuePolicy`),
  `playPhotoTone`, `playConnectTone`, `playDisconnectTone`, `playRecoveryTone`, `playLinkLostTone`
  (`GlassesLinkCuePolicy.lostEarcon`), `playFailureTone`, `playLifecycleEarcon(_:)` for
  `AudibleLifecyclePolicy.Earcon` (`ready`, `lost`, `restored`, `captured`, `failed`), and `playTone(frequency:duration:)`.
  `TempleEarcon` (`Services/Triggers/TempleActionResolver.swift`) has its own tone lists (`accepted` 880 Hz,
  `recordingStarted` 990+990…), played by `AppState.playTempleEarcon`.
- `AccessibilitySettingsView` has "Speak What Each Sound Means" (`blindAssistantSpokenCues`, default on) and a
  sound tour (`audibleLifecycle?.playCueTour()`) that teaches the lifecycle sounds apart.
- `Config.simpleModeEnabled` (default off).
- Siri and Shortcuts: `App/Intents/` (`AskQuestionIntent`, `AskOpenGlassesIntent` and others) answer through the
  intent's own dialog, not through `handleTranscription`.
- The Live modes (Gemini Live, OpenAI Realtime) speak with the provider's own voice; the app does not hold their
  audio back.

**Doesn't exist:**
- Any notion, per call, of "the thing asked for is now true". The only signals are the outcome class and a
  string.
- A quiet ending for a turn, or a done tone.
- A watch haptic. `OpenGlassesWatch` plays none today (no `WKInterfaceDevice` haptic call); the phone talks to the
  watch through `WatchConnectivityManager` and `WatchSurfacePublisher`.

## Design

### 1 · Tools say whether it got done (`ActionCompletion`)

A tool's string is for the model. Whether the action **landed** needs its own answer, from the tool itself,
because only the tool knows that Spotify opened a search page rather than playing.

```
enum ActionCompletion: Equatable, Sendable {
    case done(summary: String)          // "Kitchen lights off", "Timer 10 min"
    case partial(reason: PartialReason) // opened an app or page, left a notification, some items failed
    case awaitingWearer                 // a question, a choice, a confirmation still to come
}
enum PartialReason { case handedToApp, leftNotification, someItemsFailed, unverified }
```

- **How it is reported.** A task-local `ActionCompletionReport` that `NativeToolRouter` opens around each native
  `execute` and reads when it returns. A tool calls `ActionCompletionReport.record(.done(summary: …))`. The
  router stores it beside the outcome in the turn's ledger (`AttemptToolLedger.Call` gains `completion`). The
  model's string is unchanged.
- **No report means not done.** A tool that says nothing is never quiet. So is every MCP tool, gateway call,
  custom HTTP tool and OpenClaw delegation: their behaviour is written elsewhere and cannot vouch for itself.
- **Opting in is per tool and per action, in code review.** A starter set (decision 2): `set_timer`,
  `set_alarm`, `reminder` (add), `flashlight`, `brightness`, `music_control` (transport and Apple Music playback
  that started; **the Spotify search link reports `.partial(.handedToApp)`**, and so does any `open_app`),
  `home_assistant` / `smart_home` (only when the service confirmed the new state; a call that returned without
  confirmation is `.partial(.unverified)`), `save_note`, `save_location`, `pomodoro` (start/stop).
- Never opted in: `phone_call`, `first_aid`, `emergency_info`, anything that reads the camera, `navigate` and
  `get_directions` (they hand the route to Maps or a notification: `.partial`), and every read-only tool.

### 2 · The judge (`QuietTurnJudge`, pure)

Called once, when the turn's model call returns and before anything of the final reply is spoken.

**Input:** `QuietTurnInput`
- the setting, `Config.simpleModeEnabled`, whether VoiceOver is running, the turn's origin (spoken Direct, typed,
  Siri, Live), and its language;
- the wearer's utterance (only to ask "was this a question?");
- the ledger's calls: tool, effect (after `isReadAction`), outcome class, `completion`, and whether it is a
  native tool;
- the final reply text, and whether it had a follow-ups tail (`FollowUpTail`).

**Output:** `.quiet(summary:)` or `.speak(reason:)`. The reason is logged and tested; it is never spoken.

**The rules, in order.** The first that applies decides.

1. Setting off, Simple Mode on, or the origin is not a spoken Direct turn → `.speak(.notApplicable)`.
2. No tool ran → `.speak(.noAction)`. A plain answer is an answer.
3. Any call was `rejected`, `failedBeforeExecution` or `outcomeUnknown` → `.speak(.notAllDone)`.
4. Any call was read-only → `.speak(.lookup)`. Lookups always speak, including a lookup that came with an
   action ("lights off and what's the weather?").
5. Any call is not a native tool, or reported no completion, or reported `.partial` or `.awaitingWearer` →
   `.speak(.notAllDone)`.
6. The wearer asked a question ("did you turn the lights off?", "is the timer set?") → `.speak(.askedQuestion)`.
   A pure `UtteranceQuestionCue` reads a trailing question mark and leading question words, per supported
   language; a language it has no list for reads every utterance as a question (speaks).
7. The reply asks something, offers follow-ups, or carries a caveat → `.speak(.replyHasMore)`. A pure
   `ReplyCaveatCue` looks for a question mark and a short per-language list ("couldn't", "but", "only",
   "instead", "didn't", "unable", "not"). An unsupported language speaks.
8. Otherwise → `.quiet(summary:)`, where the summary joins the calls' `done` summaries ("Kitchen lights off ·
   Timer 10 min").

Rule 7 is a backstop for a model that knows more than the tool reported, such as "the lights are off, but the
hall one didn't respond". It errs towards speaking.

### 3 · Not saying the preamble either

The prompt asks for a sentence before every tool, so a quiet turn would still say "Turning off the lights" and
then play a tone. Two changes, both only while the setting is on:

- **The prompt.** The tool rule gains an exception: for a request that only changes something (lights, timer,
  music, a note), call the tool without an acknowledgement; for anything that looks something up, keep it.
- **The gate.** `StreamSpeechGate.Rules` gains `holdPreamble(forCalls:)`. At `endIteration()`, when every tool
  call the model just made is a native tool on the opted-in list, the preamble is held, not released. If the
  turn ends quiet it is dropped. If it ends spoken, the held preamble is dropped too and only the final reply is
  said (KJ's rule: one answer, said once).

### 4 · Holding the final reply until the judge has spoken

With streamed speech on, the final iteration's sentences would start playing before the judge sees the whole
reply. So when the last tool round's calls all reported `.done` (the only case that can end quiet), the gate
holds the next iteration whole (`holdWholeReply`), as it already does for memory commands. The judge then runs on
the complete reply:

- `.quiet` → the held text is dropped from speech, the done tone plays;
- `.speak` → the held text is spoken whole, as the non-streamed path does.

The cost is a short delay before the spoken reply, only on turns that were candidates for quiet and turned out
not to be. Every other turn streams as now.

### 5 · The tone (`QuietDoneCue`)

- A short, soft two-note figure, about 250 ms, quieter than the reply voice (decision 6 on the notes). It goes
  through `TextToSpeechService` like the other earcons, so it reaches the glasses on the same route as speech
  and waits for a gap if something is already speaking.
- **It must not be mistaken for any other sound.** A test compares its notes with every list the app plays:
  `ListeningCuePolicy.start`/`.end`, `GlassesLinkCuePolicy.lostEarcon`, the connect, disconnect, recovery,
  photo and failure tones, and every `TempleEarcon`. It must differ from each in contour or pitch, by a margin
  the test states.
- It joins the sound tour in `AccessibilitySettingsView`, with the line "Done: what you asked for has
  happened."
- There is no "failed" variant. A failure is always spoken (rules 3 and 5).

### 6 · What still shows, and what is recorded

- **The conversation.** `accept` runs exactly as now, so the reply is stored, Insights counts the tools, and the
  KK timeline pass runs. `ConversationMessage` gains optional `endedQuietly: Bool?` (nil for every ordinary
  reply, so old threads decode unchanged). The bubble shows a small check mark, and VoiceOver reads it as
  "Ended with the done tone".
- **The Display.** The KP answer card shows the reply text silently, as it shows any answer (decision 4). Its
  page-turn and follow-up controls are unchanged.
- **Delivery.** `noteReplySpoken` gets a `.quiet` delivery, so a quiet reply is not counted as unheard and the
  "you missed a reply" logic leaves it alone.
- **The trace.** `TurnRecorder` notes the verdict and its reason ("quiet" or "speak: lookup"), so a tester can see
  why a turn spoke.
- **"What was that?"** For 30 seconds after a quiet turn, "what was that", "say it" or "what did you do" speaks
  the stored reply through the existing `lastResponse`, with no model call.

### 7 · Accessibility and the other surfaces

- **VoiceOver.** A wearer using VoiceOver gets the tone, and, when "Speak What Each Sound Means" is on, the
  word "Done" after it, the way the lifecycle cues already add words (decision 5). The setting's footer says
  this.
- **Simple Mode.** The setting is hidden and treated as off (rule 1). Simple Mode is for a wearer who should
  hear what happened.
- **Apple Watch.** Later (P3): a quiet turn sends a "done" message through `WatchConnectivityManager`, and the
  watch plays `.success`. It does not exist today.
- **Siri and Shortcuts.** Unchanged. The intent's own dialog is what Siri says; the app does not decide that.
- **Typed turns.** Unchanged; nothing is spoken for them anyway unless `speakResponse` is set, and then they
  speak.
- **Live modes.** Out of scope. The provider's voice speaks the reply as it generates it; there is nothing to
  hold back without cutting the provider off.

## Decisions for Greig (taken 2026-11-10)

All eight taken as recommended.

1. **Off by default**, in Settings › Voice, with the footer: "When something you asked for has fully
   happened, play a short tone instead of saying so. Anything partly done, or any question, is still spoken."
2. **The starter set** in §1: timers, alarms, adding reminders, torch, brightness, music transport and Apple
   Music playback, Home Assistant with a confirmed state, notes, saved places, Pomodoro. Others join by code
   review only.
3. **Messages always speak.** A sent message is quiet-capable only if the confirmation read-back was spoken in the
   same turn; recommend keeping `send_message` and `send_via` out of v1 entirely, because "sent" to the wrong
   person is the costliest silent mistake.
4. **The Display shows the reply text** on a quiet turn, silently. It is the only place a glasses wearer can
   check what happened without asking.
5. **VoiceOver users hear "Done" after the tone** when "Speak What Each Sound Means" is on.
6. **The tone's notes**: a soft rising fifth, short, at reply volume less 6 dB, tuned on the device in P4
   against the distinctness test.
7. **"What was that?" works for 30 seconds** after a quiet turn.
8. **Languages without word lists speak.** Rules 6 and 7 err towards speaking until a language's lists exist.

## As built (2026-11-10)

- **P0, the pure core** — `Services/QuietAfterActions/`: `ActionCompletion` and `QuietActionRoster` (the
  reviewed starter set; `neverQuiet` names messages, calls, first aid, emergency information, navigation and
  the gateway), `QuietTurnCall` / `QuietTurnInput` / `QuietTurnVerdict` / `QuietTurnJudge` with the eight
  rules in order, `UtteranceQuestionCue`, `ReplyCaveatCue`, the summary joiner, `QuietDoneCue` (notes, the
  distinctness rule, the VoiceOver rule), `QuietReplayWindow`, `QuietAfterActionsPrompt`.
  `StreamSpeechGate.Rules` gained `holdPreamble` and `holdNextIteration` (both off by default), and
  `HoldReason.quietCandidate`; `endIteration(roundCalls:)` takes the round's calls.
- **P1, tools report** — `ActionCompletionReport`: the router opens a slot around every native tool's
  `execute` (`capture`), and a root call's report reaches the slot the dispatcher opened (`collect`); a
  composed child's is dropped, and nothing outside a native tool's call has a slot. `AttemptToolLedger.Call`
  gained `isNative`, `outcome` and `completion` (kept only for a completed call) and the ledger a reset
  `generation`. All three dispatch sites in `LLMService` (cloud tool loop, Apple on-device, MLX) collect.
  The starter set reports; `open_app` reports `.partial(.handedToApp)`. `ActionCompletionRosterTests` fails
  on a file outside the native tools that reports, or a `.done` from a tool not on the list.
- **P2, wired** — `Config.quietAfterActionsEnabled` (off) with a toggle in Settings › Voice (hidden in Simple
  Mode); the prompt exception after the acknowledgement rule; the stream's preamble and final-reply holds
  for spoken turns; the judge in `handleTranscription` (`AppState+QuietAfterActions.swift`); the done tone
  (`TextToSpeechService.playQuietDoneTone()`); `ConversationMessage.endedQuietly` with a check mark on the
  bubble and "Ended with the done tone" for VoiceOver; `TurnBackgroundTime.ReplyDelivery.quiet`;
  `quietVerdict` on `TurnTimeline`/`TurnTrace` and `PrivacyLog.app(.quietTurnJudged)`; the "what was that?"
  handler (`quiet-replay`, ahead of the bystander filter).
- **P3, accessibility and the watch** — "Done" after the tone with VoiceOver and "Speak What Each Sound
  Means" on; the tone joins the sound tour as `AudibleLifecyclePolicy.Earcon.done`; a quiet turn sends
  `QuietDoneWatchMessage` while the watch app is reachable, and the watch plays `.success`.

**Where it differs from the design, and why**

1. **The judge runs in `accept`, not `speak`.** `accept` stores the reply before `speak` runs, so the verdict is
   taken there (on the final reply, before any of it is said) and the saved message carries `endedQuietly`
   from the start; `speak` acts on it.
2. **A polite request is not a question.** "Can you turn off the lights?" asks for an action, and a recogniser
   writes the question mark either way, so the modal openers ("can/could/would/will you") are read as
   requests even with a trailing "?". "Did you…", "is the…" and every other leading question word still speak.
3. **English only.** Decision 8 names no other language, so only English has word lists; every other language
   speaks.
4. **`lookup_tools` is not a lookup.** The model fetching a tool's definition on demand (Plan IU) is left out
   of the calls the judge reads; a call the IU safety net turned back still counts as not done, and speaks.
5. **A turn that keeps no ledger never ends quiet.** The Hermes agent runs its own tools, and the on-device
   agent did not reset the ledger, so a turn could read the previous turn's calls. The ledger now counts its
   resets; a turn whose ledger was not reset since it began gets no verdict and speaks, and
   `sendViaLocalAgent` now resets the ledger at the start of its turn.
6. **What "confirmed" means per tool.** Home Assistant: done only when the service call's changed-states list
   holds the entity (a light, switch, fan or input boolean) in the state `turn_on`/`turn_off`/`toggle` asks
   for; locks, automations, `converse` and anything unconfirmed are `.partial(.unverified)`. HomeKit: power and
   brightness writes and scenes are done (a write returns once the accessory took it); locks and thermostats
   are `.partial(.unverified)`. Alarm: a clock alarm is done, the notification fallback is
   `.partial(.leftNotification)`. Pomodoro: a start whose end notification could not be scheduled is
   `.partial(.unverified)`. Reminders: adding only. Music: transport on any player and Apple Music
   playback are done; a speaker asked to play something by name, add-to-library and every read report
   nothing; `.needsInput` is `.awaitingWearer`.
7. **The notes.** C6 then G6 (1047 → 1568 Hz, 90 + 140 ms, 250 ms), at 0.35 against the other earcons' 0.7
   (−6 dB). Every rising fifth lower down is already a sound the app makes, so this one sits above them; the
   test's margin is 3 semitones, note for note, between cues of the same length and contour. Tuning on the
   glasses is P4's.
8. **The tone waits and is waited for.** It stops the thinking sound, waits briefly for speech still playing,
   and returns only once it has sounded, so the listening tone as the mic reopens follows it rather than
   landing on it.
9. **Typed turns keep today's stream rules** whatever the setting says (a typed turn's spoken reply can never
   end quiet, so it should not wait on a verdict).
10. **The preamble hold catches the iteration's unreleased end.** A sentence the splitter had already released
   mid-stream has been said; the prompt exception is what keeps it from being written.
11. **The tour's line** is "This sound means what you asked for has happened.", worded like every other
   lesson (the tour's own test holds them to "This sound means…"), rather than "Done: …".
12. **The watch** gets the message only while its app is reachable (a tap delivered later confirms nothing).
   The watch target compiles none of the phone's files, so the two wire strings are spelled out there and a
   test pins them.

## Review follow-up (2026-11-10)

A code review of the merged work found two ways a turn that answered something could still end with the
tone. Status unchanged (🚧, P4 device pass and catalog sync owed); both fixed headlessly:

1. **A question after the action.** `UtteranceQuestionCue` read only the opening words and a trailing "?".
   "Turn off the kitchen lights and what time is it" (no "?" from the recogniser) opened with "turn", and a
   polite opener ("Can you set a timer … and what's 15% of 80?") returned before the "?" was read. It now
   reads every sentence and every clause (after a comma, a dash, "and", "then", "also", "but", "so", "or"):
   a clause that opens with a question word or "tell me" asks, once a polite opener is taken off, and a "?"
   counts unless its sentence opened with a polite request. "Can you turn off the lights?" is still a
   request.
2. **A reply-side guard (rule 7b, `ReplyBeyondSummaryCue`, reason `replyBeyondSummary`).** A quiet ending
   stands in for a confirmation, so the reply must be one: no number (digits or a number word) the tools'
   done summaries don't carry, and no longer than six words per action plus six. "Timer set for 10
   minutes." beside "Timer 10 minutes" stays quiet; "Kitchen lights off. It's 3:45." speaks.

## Phases (one PR each)

### P0 — the pure core (headless)

- `ActionCompletion`, `QuietTurnInput`, `QuietTurnJudge` with its rule order and reasons,
  `UtteranceQuestionCue`, `ReplyCaveatCue` (English plus the languages decision 8 lists), `QuietDoneCue` notes,
  the summary joiner, `StreamSpeechGate.Rules.holdPreamble(forCalls:)`.
- **Exit tests:** every rule with a minimal case; the Spotify search link (`.partial(.handedToApp)`) speaks;
  a timer plus a weather lookup speaks; two done actions are quiet with one summary; an `outcomeUnknown` speaks; an
  MCP tool speaks; "did you set the timer?" speaks; "Done, but the hall light didn't respond." speaks; an
  unsupported language speaks; the tone differs from every other earcon; the gate holds a preamble only when
  every call is opted in.

### P1 — tools report (headless)

- The task-local `ActionCompletionReport`, the router reading it, `AttemptToolLedger.Call.completion`.
- The starter set reports `.done`, `.partial` or `.awaitingWearer`. `MusicControlEnvironment`'s Spotify branch
  reports `.partial(.handedToApp)`; `.needsInput` maps to `.awaitingWearer`.
- A guard test: every tool that records `.done` is on the reviewed list, and nothing outside native tools can.

### P2 — the quiet ending (headless, wired)

- The setting, the prompt exception, the preamble hold, the final-reply hold, the judge in the `speak` closure
  of `handleTranscription`, the tone, `endedQuietly` on `ConversationMessage` and its mark, `.quiet` delivery,
  the trace line, "what was that?".

### P3 — accessibility and the watch (headless, wired)

- The VoiceOver rule, the sound-tour entry, the watch `.success` haptic over `WatchConnectivityManager`.

### P4 — device pass (owed)

- On the glasses: the starter set one by one, a Spotify request, a Home Assistant light that is switched off at
  the wall, a timer plus a question, with music playing and without. Whether the tone is heard over the music
  and never mistaken for the listening tone. A week's use by a tester with the setting on, counting turns that
  were quiet when they should have spoken (target: none).

## Acceptance

- A turn is quiet only when every call was a reviewed native tool that reported `.done`, nothing was looked up,
  nothing was asked, and the reply has no caveat.
- A partial success is always spoken, with what is left for the wearer to do.
- A quiet turn is stored, shown and traced like any other, and can be replayed by voice.
- With the setting off, every turn's speech is byte-for-byte what it is today.

## Risks

- **A tool reports `.done` too eagerly.** The opt-in list and the guard test keep the set small and reviewed;
  rule 7 catches a model that says otherwise.
- **The held final reply adds delay** on action turns that end up spoken. Measured in P4; the hold only applies
  when every last-round call reported done.
- **The prompt exception changes model behaviour** for action turns (no preamble). The gate's hold is the safety
  net if a model ignores it.
- **The tone is missed** in a loud place. The Display line and "what was that?" are the recovery; a wearer who
  finds it too easy to miss turns the setting off.
