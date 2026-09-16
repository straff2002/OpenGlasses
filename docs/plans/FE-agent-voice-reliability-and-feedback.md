# Plan FE — Agent and Voice Reliability and Feedback

**Status: 🚧 P0–P3 implemented 2026-09-16 (P2 and P3 same day) — P4–P6 unbuilt.**

Deliver truthful agent results, questions and replies, listener recovery, configurable speech
timing, delivery acknowledgements and speech-reactive visuals.
Keep OpenGlasses branding, bundle IDs, signing, app groups and entitlements unchanged.

## Existing owners and verified gaps

- [N](N-remote-agent-harness.md): `CustomAgentHarness`, `CustomHarnessConfig`, `AgentSessionService`,
  `AgentSummarizer` and existing event/result types. Custom polling currently discards result fields;
  confirmation errors are swallowed before announcing “proceeding”; default input handling can no-op.
- `WakeWordService.startListening` returned on `isListening` alone. A stale `isListening` flag after
  audio disruption was suspected; **P2 removed the guard** — the decision now reads the audio graph.
  Field reproduction of the original report remains pending.
- `SpeechContinuationPolicy`, existing endpointing/barge-in policy and settings own timing.
- `TextToSpeechService`, audio lease coordination and `VoiceAmbience` own delivery and feedback.
- [FD](FD-camera-readiness-and-durable-actions.md) supplies broader action/restart acceptance scenarios;
  [EW](EW-session-resource-cleanup.md) owns resource lifetime. Extend those contracts, not their scope.

No wholesale import. The implementation must add tests and address migration, stale-callback and
delivery-semantics issues.

## P0 / PR1 — Truthful custom-agent results and terminal state

Poll status and result together so richer reporting does not double request volume. Map supported
summary/final text, created/modified files, commands, push outcome, PR URL and error fields into the
existing result type. Document the wire contract; retain current endpoint compatibility and add
configurable paths only where the existing custom mapping requires them.

Missing data means unknown, not “no files changed.” Distinguish completed, failed and cancelled;
never render remote cancellation as successful completion. Bound/validate payload fields and use
safe user-facing errors. Treat endpoint narratives as reported results, not independent evidence
of actions; text cannot trigger further tools or gain authority.

Replace indefinite polling-error-as-running behaviour with observable connection/error state,
bounded retry/backoff and cancellation. Network loss must not be reported as confirmed remote task
failure or cancellation. Unknown status values must not create an endless false “working” claim.

**Acceptance:** fixture endpoint tests cover full/partial/status-only results, legacy aliases,
malformed payloads, each terminal status, auth failure, repeated network failure and reconnect.
Drive adapter → session → summarizer and assert the final narration/status and polling count.

**Implemented 2026-09-16.** Wire contract: [agent-harness-wire-contract.md](../agent-harness-wire-contract.md).

- **Results.** Status and result now come from one status GET. `CustomHarnessConfig` gained seven
  optional result dot-paths (summary/final text, files created, files modified, commands, pushed,
  PR URL, error), all defaulting to empty and decoded with per-key defaults so a config saved by an
  older build still decodes — with its token — instead of being erased. `AgentRunResult` carries an
  `AgentResultFields` set recording what was actually reported, and `AgentSummarizer` distinguishes
  "reported no file changes" from "didn't report what changed".
- **Terminal state.** `AgentEvent` gained `.failed(result)` and `.cancelled(result)` beside
  `.completed(result)`; the session maps each to its own status and spoken line, and a remote
  cancellation is never narrated with "Done." The OpenClaw adapter's `aborted` phase, which emitted
  a plain completion while its own `status(for:)` called it cancelled, now emits `.cancelled`.
- **Contact.** `AgentConnectionState` (+ `AgentContactLoss`) and a pure `AgentPollingPolicy`
  (4 s cadence, 4 retries, 2 s backoff doubling to 32 s, 5 unknown-status ticks, injected sleeper)
  replace `(try? status) ?? .running`. Network loss is reported as lost contact with the endpoint —
  the run keeps its last known status — 401/403 stops without retrying, other 4xx stops, an
  unrecognised status is tolerated briefly then reported with the raw label, and "agent status"
  answers with when contact was lost and what was last known.
- **Hygiene.** Every mapped field is control-character-stripped, whitespace-collapsed and capped
  (200 chars an item, 600 for the summary, 100 items a list, 40 for an echoed status label); a PR
  URL must parse as http(s). HTTP errors surface the code only — the body is counted in the privacy
  log, never spoken. `code_agent` joined `PromptInjectionPolicy.untrustedOutputTools`, so endpoint
  narrative reaching the model is framed as data with no authority.

**Evidence.** 97 headless tests across `AgentResultTruthTests` (32, new), `AgentSessionTests` (24),
`AgentCustomHarnessTests` (23) and `AgentSummarizerTests` (18), each driving adapter → session →
summarizer over the shared `URLProtocol` stub and asserting narration, run status, connection state
and the **number of status GETs**: full / partial / status-only results, explicit empty lists,
legacy status aliases, malformed and non-JSON bodies, completed / failed / cancelled, 401, 403, 404,
503, repeated network failure with recorded backoff, reconnect after a transient failure, unknown
status, oversized and control-character payloads, an unusable PR URL, and a literal legacy config
JSON. Three prior assertions changed because they encoded the defect: empty-result narration, the
default cancellation wording, and an HTTP error quoting 160 characters of the endpoint's body.

**Owed:** everything above is fixture-level. A real endpoint has not been run against it, so the
recognised-alias list, the result payload shapes and the retry numbers are still proposals rather
than field-confirmed. `respondToConfirmation` swallowing a transport error before announcing
"Okay, proceeding" was left as-is for P1, which owns reply routing, and is fixed there.

## P1 / PR2 — Questions, answers and explicit backend selection

Surface pending questions once per stable question/revision identity. Repeated identical text can
represent a new question, so text equality alone must not suppress it. Associate responses with
run, question and action identity where applicable; reject stale responses after replacement,
cancellation or expiry.

Separate free-text clarification from action approval in the event/protocol contract. A boolean
does not express “only change the tests”; ordinary speech cannot implicitly authorize an action.
Route replies through the existing user-originated UI/voice confirmation boundary, forwarding
the user's full text when supported. Keep a touch alternative when voice recognition is unavailable.
Clearly report unsupported input handling rather than use the protocol's silent default.

On transport failure retain pending state and offer retry; do not announce success. On uncertain
delivery reconcile or use an idempotent response ID rather than repeat an effect blindly. A locally
declined question must not claim the remote run stopped unless its protocol confirms that outcome.

Support an optional explicit agent field/value for custom endpoints serving more
than one coding agent. This is a configured request value, not automatic persona/wake-word routing.
Validate field collisions with prompt/project/image keys; bind the chosen endpoint/agent config to
the run so later settings changes cannot send its reply or cancellation to another backend.

Extend optional input/ack endpoint settings under existing secure transport, credential and routing
policies. Add explicit backward-compatible decoding defaults for newly introduced nonoptional
fields; test actual saved legacy JSON. Do not let a decoding failure silently erase the custom setup.

**Acceptance:** real dispatch with fake endpoint covers question repetition/revision, two questions
with identical wording, arbitrary text answers, explicit approval/denial, unsupported replies,
failure/retry, stale question, cancellation, endpoint changes, key collisions and config migration.
Verify voice/UI replies reach the adapter; an unused overload is not completed functionality.

**Implemented 2026-09-16.** Wire contract additions:
[agent-harness-wire-contract.md](../agent-harness-wire-contract.md) — "Which agent", "Questions"
and "Answers".

- **Question identity.** `AgentEvent.awaitingInput` now carries an `AgentQuestion`
  (`id`, `revision`, `kind`, `prompt`, `runID`) instead of a bare string, and the session surfaces
  one ask per `(id, revision)`. A polled repeat is silent, a revision bump re-asks, and a new id is
  a new question however familiar its wording. An endpoint that names no question gets a
  deterministic id derived from `(run, wording, arrival order)` — FNV-1a, not a per-process hash, so
  it survives a relaunch — and the contract states plainly that identically-worded questions from
  such an endpoint are distinguished by arrival order alone. An answer naming a replaced, ended or
  differently-revisioned question is refused and never forwarded.
- **Free text vs approval.** `respondToInput(_:approved:)` became a thin wrapper over
  `respondToInput(_:reply:)` taking an `AgentReply` (`.approve` / `.deny` / `.text`) with the
  question's identity and a `replyId` that is stable across retries. Approval still goes through the
  user-distinct consent prompt; a free-text answer goes through the same user-originated boundary —
  the model can propose words, but only what comes back out of the wearer's prompt is sent, edits
  included, and a `.approval` question refuses free text outright. The shared consent card gained a
  text field with Send / Don't send, so both shapes work by touch when voice recognition does not;
  voice yes/no is deliberately inert on a text prompt.
- **Transport truth.** The reply's outcome is what is announced. The protocol's default
  implementation now throws `replyUnsupported` instead of silently succeeding; a failure keeps the
  question pending, holds the reply and offers a retry that re-sends the same `replyId`; a timeout
  after sending is reconciled by **re-polling status**, never by a second POST; and a delivered
  decline says only "I've told the agent not to proceed" — the run's status stays the endpoint's to
  report. An unrelayable decline says so and leaves the status untouched.
- **Backend binding and selection.** Optional `agentField`/`agentValue` put a configured agent name
  in the start body (never persona or wake-word routing). Prompt/project/image/agent keys are
  checked for collisions and the answer field may not take a reserved reply key; a collision is
  named in Settings, disables Save, and makes the request build refuse rather than send a body with
  a field written over. The harness a run was dispatched to is bound to the run, so a mid-run
  Settings change cannot send its reply or cancellation to another backend.
- **Settings.** `inputURLTemplate`, `inputField`, and `questionPrompt/ID/Revision/Kind` paths, under
  the existing `EndpointPolicy` / `MedicalEgressGuard` / `NetworkRouteRegistry` rules (the reply
  rides `CustomAgentHarness`'s existing `.customAgentHarness` route — no new route). Every new key
  decodes with a default.

**Evidence.** 186 headless tests across `AgentQuestionReplyTests` (42, new), `AgentSessionTests`
(24), `AgentResultTruthTests` (32), `AgentCustomHarnessTests` (23), `AgentSummarizerTests` (18),
`RemoteActionConsentTests`, `AgentSafetyTests`, `AgentConfirmationGapTests` and
`AgentHarnessPresetTests`; full `OpenGlassesTests` 5600 green, Release build green. The new class
drives adapter → session → summarizer → `code_agent` tool over the shared `URLProtocol` stub and
asserts the spoken line, the run status, **which URL each request went to** and its body: repeated
identity announced once, revision bump re-asked, two identically-worded questions with different
ids both surfaced in order, derived identity across leave-and-re-enter, text forwarded verbatim with
the question id, an edited answer replacing the proposed one, approve/deny decisions, an approval
question refusing free text, no-answer-address reported honestly with zero requests, 503 keeping the
question pending then a retry carrying the same `replyId`, a timeout reconciled by one status GET
with exactly one POST, a timeout that stays unresolved, stale id and stale revision refused,
cancellation while a question is pending, a reply following the bound endpoint after the registry is
swapped mid-run, every collision case, the preset configs, and a literal legacy config JSON.
Four prior assertions changed because they encoded the defects this phase names: the decline
cancelling the run locally (twice — `AgentSessionTests`, `RemoteActionConsentTests`), the
"Confirmed — the agent will proceed" line spoken regardless of transport, and the generic narrator
announcing every `awaitingInput` event.

**Owed:** fixture-level again. The question/answer shapes, the reserved reply keys and the kind
labels have not been run against a real multi-agent endpoint. The uncertain-delivery signal is a
POST timeout only — a connection dropped mid-flight is treated as a plain failure, which is the
safe reading but not the complete one. The gateway's approval surface (`exec.approval.*`) stays the
gateway plan's to wire; here it is honestly reported as unsupported.

## P2 / PR3 — Recover unhealthy listening without duplicate audio ownership

Replace the single stale-flag guard with a small listener-health decision using existing engine,
recognition and capture ownership state. Engine running alone does not prove recognition works.
Distinguish deliberately paused/shared capture from broken listening before rebuilding.

Coalesce concurrent starts and recheck generation/intent after permission and activation awaits.
Recover through existing cleanup/lease APIs, not a second engine owner. Preserve silent/PTT mode,
explicit stop and other consumers. Cancel obsolete recognition callbacks and remove old taps/tasks.

**Acceptance:** service fakes cover flag true/engine stopped, engine running/recognition ended,
healthy repeated start, interruption recovery, shared capture, simultaneous starts and stop during
permission/activation. Hardware checks reproduce first Start after glasses sleep/route change,
then demonstrate one working listener and no orphaned mic after stop.

**Implemented 2026-09-16.**

- **The decision.** `ListenerHealthPolicy` (`Sources/Services/Audio/`) is a pure function from a
  `ListenerHealthState` — `flagSaysListening`, a `ListenerGraphSnapshot` (`engineRunning`,
  `tapInstalled`, `recognition` ∈ none / running / ended(failed:)), `captureShared`,
  `deliberatelyPaused`, `leaseHeld`, `intent`, `silentMode`, `permission` ∈ granted/denied/unknown,
  and `origin` ∈ explicit/automatic — to one of `healthy`, `pausedDeliberately(reason)`,
  `rebuild(reason)`, `startFresh`, `refuse(reason)`. Rules, in order: silent mode refuses
  (outranking everything, so push-to-talk is never reported as something else); no intent refuses;
  denied permission refuses while `unknown` proceeds (that is the pre-flight pass, before anything
  has been asked); an *automatic* start during a shared-engine pause stands off; flag + engine +
  tap + running recognizer is healthy; then the broken shapes — **engine running beside an ended
  recognizer** (the rule that motivates the whole decision: a running engine does not prove
  recognition works), a task outliving its engine, the flag claiming a listener with no engine, the
  flag claiming one with no task, an engine with no tap; anything else starts fresh. A silence pause
  is recorded but deliberately never blocks: the only signal that ends one is audio arriving, and
  audio only arrives while the listener runs.
- **Coalescing and post-await re-checks.** `startListening()` is the explicit request and the only
  thing that grants intent; the service's own recovery paths (route change, interruption ended,
  recognition restart, `resumeListening`) go through an automatic variant that never does.
  `ListenerStartGeneration` — the camera's `StreamStartGeneration` pattern with intent added —
  issues a token per start, re-presented after the authorization await, after the session
  activation, after each `!pla` re-activation and after each retry sleep. A stop invalidates every
  token *and* withdraws intent; a pause invalidates them and keeps it, which is what makes "an
  explicit stop is not undone by a glasses reconnect" expressible while an interruption still
  recovers. One `inFlightStart` task holds the sequence: a second caller awaits its result instead
  of opening a rival microphone.
- **Recovery through existing APIs.** A rebuild is `cleanupAudioEngine()` then `startRecognition()`
  and nothing else — no session release/re-acquire around it (other consumers coexist on that lease
  and wake word is the baseline owner), no second `AVAudioEngine`, and a superseded start releases
  nothing because it built nothing. Recognizer completion handlers are tagged with the generation
  they were created under, so a cancelled task's final callback can no longer restart, pause or
  barge in on its successor. Silent/PTT mode, explicit stop and the shared-capture consumers are
  preserved; the buffer forwarders survive a rebuild because they are re-published into the new tap.
- **Flag audit.** `isListening` has a single writer and is no longer load-bearing: nothing decides
  anything from it. The seven former writers are now `startListening` (only after a recognizer
  exists), `stopListening`, `deactivateAudioSession`, `pauseRecognition`,
  `pauseRecognitionForSharedEngine` and one `pauseForAudioDisruption` that replaced the three
  hand-rolled `cleanupAudioEngine()` + `isListening = false` pairs in the interruption and
  route-change handlers.

**Evidence.** 55 headless tests: `ListenerHealthPolicyTests` (28, new — the decision table plus the
generation/intent rules) and `WakeWordListenerRecoveryTests` (19, new — the service driven through
injected engine/recognizer/permission/session seams, asserting the call sequence and the state left
behind), with `WakeWordHardeningTests` (8) unchanged and green. The service tests prove: a stale
flag beside a stopped engine rebuilds exactly once and leaves one listener; an ended recognizer
beside a running engine rebuilds with the old tap removed before the new one is installed; a
repeated start on a healthy listener does nothing at all; the errored-recognizer state recovers; a
shared-engine pause is neither rebuilt by an automatic restart nor torn down by the explicit resume;
two simultaneous starts run one sequence and both callers get its result; a stop landing in the
authorization await or in the session activation leaves no listener, no tap and the lease untouched;
an explicit stop blocks automatic restarts until somebody asks again; silent mode refuses without
asking for anything; a rebuild does not re-run the session configuration; an audio disruption voids
a shared-engine pause (the claim was on a running engine) while keeping intent, so the matching
recovery runs; and no teardown path leaves the flag claiming a listener. Neighbouring suites green: `AudioSessionCoordinatorTests`,
`AudioSessionLedgerTests`, `AudioGraphRecoveryTests`, `StreamStartGenerationTests`,
`CameraServiceExitTests`, `PrivacyLogTests` (97). Full `OpenGlassesTests` 5728 green; Release build
green.

**Owed — hardware.** Everything above is fixture-level. Two device checks remain, and neither can be
made in a simulator (no microphone route, no real recognizer): **first Start after the glasses sleep
or the route changes** must now find and rebuild the listener rather than return at a stale flag;
and after a stop there must be **one working listener and no orphaned mic** — no second tap on the
input node, no engine left running with nothing consuming it. The `!pla` retry numbers and the
`SFSpeechRecognitionTask.state` → `ended` mapping are likewise proposals until a device run
confirms them.

## P3 / PR4 — User-adjustable pause and interruption controls

Expose validated speech-silence duration and an option to disable general speech-triggered barge-in
through existing voice settings. Read changes live or inject per-turn settings; never cache mutable
preferences in a `static let`. Define when an in-progress turn adopts a setting change and document
it in UI copy. Bound persisted values, including malformed/non-finite values, and supply defaults.

Retain the current default initially; evaluate a longer-pause preset for dictation rather than
imposing one longer value on everyone. Integrate with question-response windows and other continuation
rules so a user-selected long window is not unexpectedly shortened.

Keep explicit stop immediately available and test short intentional corrections. Do not adopt a
fixed word-count interruption threshold: word count does not reliably distinguish background talk,
speaker echo or deliberate speech, and differs across languages. Preserve existing echo/turn policies.
Explain which modes the controls affect; realtime providers with their own endpointing must not
appear controlled by an unrelated local setting.

**Acceptance:** next-turn settings updates without relaunch, migration/defaults, value bounds,
long dictation pauses, short replies, explicit stop, general barge-in disabled, echo/background
speech and language fixtures. On device compare premature cut-offs and perceived response delay.

### Implemented 2026-09-16

- **Two settings, read live.** `Config.speechPauseWindow` (seconds of silence before the listener
  answers; default 2.0 — the value that shipped) and `Config.speechBargeInEnabled` (default on).
  Neither is captured into a constant at launch: the window is read once per turn in
  `TranscriptionService.startRecording()` through an injectable provider, and the barge-in switch is
  read at the moment a transcript arrives in `WakeWordService`. Changing either takes effect without
  a relaunch.
- **Bounds, and what an unusable value means.** The persisted window is clamped to
  `[SpeechContinuationPolicy.minimumWindow, .maximumWindow]` = [1.0, 10.0]; the presets offered are
  1.5 / 2 / 3 / 4 / 6, with the longest labelled for dictation. NaN, ±infinity, a negative, zero, a
  missing key and a value of the wrong type all resolve to the **default**, not to the nearest
  bound — a 1-second window recovered from a corrupt value would cut people off and a 10-second one
  would leave a hot mic, and neither is a better guess at intent than the value the wearer would
  have had anyway. The setter clamps too, so a bad value cannot reach the store.
- **Adoption: from the next turn.** `SpeechTurnWindowLedger` fixes the window when the turn starts
  and nothing moves it afterwards — not a settings change, not the assistant speaking. Re-arming a
  running timer would mean that asking for a longer pause cut the wearer off once on the way to
  getting it. The Settings footer states the rule.
- **Question window and backstop.** `SpeechContinuationPolicy.silenceWindow(afterSpeaking:userWindow:)`
  returns `max(chosen, questionWindow)`: the question rule may only widen, so a chosen 8 s is never
  cut to 6 because a reply ended in a question. `EndOfTurnPolicy.backstop(forWindow:)` derives the
  stuck-detector hold as `max(8.0, window + 2.0)` and `decide` raises any explicit backstop to it —
  a backstop below the window would commit the turn before the window it exists to outlast, which is
  rule 4 pre-empting rule 3 and would only ever appear for wearers who chose a long pause. For the
  default 2 s window the hold is unchanged at 8 s.
- **Barge-in as a policy.** `BargeInPolicy.decide(transcript:isStopPhrase:matchedWakePhrase:generalBargeInEnabled:)`
  → `.stop` / `.newConversation(phrase:)` / `.interrupt(text:)` / `.ignore`, replacing the inline
  `wordCount >= 2` branch. The explicit stop phrase and the wake phrase interrupt in **both**
  settings — an interruption control that could disable the way out of a long answer would be a
  trap. The word count survives only as a documented noise floor (the least filtering that keeps a
  stray partial from cutting playback off), paired with a character-count fallback so the floor is
  structural rather than a rule a script without word spacing can never satisfy. The policy takes no
  view on echo or on which language it is reading: the assistant's own voice is suppressed upstream
  by the recognition pause around playback and `SpeechActivityGate`, and a second, weaker echo test
  here would mask failures in the real one.
- **Scope, stated in the UI.** Both controls sit in Voice & Triggers under "Pause & Interruptions",
  and the footer names what they reach: wake-word conversations. Gemini Live and OpenAI Realtime
  endpoint on the server and nothing local can move that.

**Evidence.** 125 headless tests on the focused classes: `SpeechPauseSettingsTests` (20, new) and
`BargeInPolicyTests` (15, new), with `EndOfTurnPolicyTests` (11), `TurnAdmissionAndBudgetTests` (15),
`SpeechActivityGateTests` (9), `WakeWordHardeningTests` (8), `WakeWordListenerRecoveryTests` (19) and
`ListenerHealthPolicyTests` (28) unchanged and green. The new suites prove: no stored value behaves
exactly as the app did before; every unusable value resolves to the default and every out-of-range
one to a bound; every offered preset round-trips unchanged; a turn started on 1.5 s keeps 1.5 s while
the setting moves to 6 s and the *next* turn gets 6 s; a 6 s window does not commit at 2.5 s of
silence and does at 6 s; a 1.5 s window commits at 1.5 s; a question never shortens a 7/8/10 s window
but still widens a 1.5 s one; the derived backstop outlasts every allowed window and `decide` uses it
rather than the constant; an explicit stop returns `.stop` and a wake phrase `.newConversation` with
general barge-in both on and off; general speech returns `.interrupt` when on and `.ignore` when off;
empty, whitespace-only and single short tokens are ignored; a sentence in a script without word
spacing still interrupts; and transcripts of the same shape in four languages get identical decisions
in both settings — including an echoed assistant phrase, which is treated as ordinary speech on
purpose. Full `OpenGlassesTests` 5908 green; Debug and Release simulator builds green.

**Owed — device.** The two numbers this ships are proposals until a wearer measures them: the plan's
**premature cut-offs vs perceived response delay** comparison across the presets (with
`TurnRecorder.noteEndOfTurnReason` separating an acoustic commit from a silence-timer one, so "it cut
me off" becomes a count rather than a feeling), and the barge-in noise floor, which is currently the
smallest filter that works rather than a measured one. Neither can be made in a simulator: there is
no microphone route and no real recognizer.

## P4 / PR5 — Acknowledge result delivery accurately

Replace fire-and-forget acknowledgement after `emit` with a defined delivery state tied to the
actual TTS completion outcome. Differentiate queued, playing, completed, interrupted, suppressed
and failed. Completed playback does not prove the wearer heard or understood the result.

Use a stable run/result-revision identity and local dedupe state plus optional endpoint ack.
Define what the endpoint means by ack and whether it suppresses future events; merely POSTing an
ack does not establish reconnect behaviour. Never acknowledge unheard queued/suppressed output as
completed playback. Offer a result/replay surface when audio was unavailable.

Make retry idempotent, bind it to the run's original configuration and do not fail a completed task
because acknowledgement failed. Handle crash after playback but before durable ack honestly:
delivery is ambiguous, not guaranteed exactly-once. Preserve useful results for manual replay.

**Acceptance:** fake audio plus endpoint covers completion, barge-in, muted/no route, failure,
reconnect, duplicate terminal polls, revised results, ack timeout/retry and crash windows. Only the
appropriate result revision is acknowledged. Device-test actual spoken completion and interruption.

## P5 / PR6 — Speech-reactive visual feedback

Add a bounded normalized playback activity signal to the existing visual model. Where audio meters
exist, derive activity from them; for system TTS, word callbacks may drive an explicitly approximate
animation. Do not call word-length pulses measured loudness or clinical/audio diagnostics.

Start metering only after playback begins. Guard all meter/delegate/decay callbacks by playback generation; stop resets to
zero and an older utterance cannot animate a later one. Use one bounded cadence, not an accumulating
task per word. Reuse available realtime audio levels where practical; otherwise retain current
state-based visuals rather than add another audio graph.

Respect Reduce Motion, background visibility and power policy. Do not run 20 Hz metering solely for
a hidden/disabled animation. Keep the visual decorative and avoid VoiceOver activity announcements.

**Acceptance:** playback start delay, silence, finish/error, rapid utterance replacement, stop,
late callbacks, hidden screen and Reduce Motion. Device-check smoothness and overhead on actual
system and supported audio-player paths. Cosmetic work follows reliability fixes.

## P6 / PR7 — Optional assistant name

**User decision added 2026-09-13:** onboarding may ask “What would you like to call your assistant?”
with **OpenGlasses** prefilled. Skip keeps that default; naming never blocks setup. Offer the same
preference in Settings, including reset to OpenGlasses. Existing installations retain OpenGlasses
unless the user chooses otherwise; do not force onboarding to run again.

Store a dedicated `assistantDisplayName` preference, rather than rewriting custom prompts or doing
global string replacement. Trim whitespace, handle blank values with the default, bound length
(proposed 40 user-perceived characters), and reject control characters/multiline input while
supporting international names. Render safely in text and accessibility labels. Treat the value as
untrusted name data, never instructions or a source of tool authority.

Use the name for the default conversational identity, introductions and relevant in-app assistant
labels. The installed app name, permission disclosures, lock-screen/widget product identity,
bundle IDs, signing, app groups and entitlements remain OpenGlasses. A selected persona's explicit
identity takes precedence; a custom prompt's explicit identity remains respected and its contents
are not modified. Audit existing persona/custom-prompt precedence before implementing this rule.
Do not attempt unreliable natural-language parsing to rewrite conflicting identity instructions.

Apply the default identity consistently through existing prompt builders for Direct/cloud, local
and realtime routes. For remote agents, pass a display preference only if their supported contract
allows it; do not imply that naming changes which backend is selected or overrides a remote agent's
own identity. Update future turns/sessions safely; do not reconnect an active call or interrupt
in-flight work merely because the preference changed. Explain any next-session boundary.

Keep wake-phrase selection separate. Setup copy states that changing the assistant name does not
automatically change voice activation. Never register arbitrary names as wake phrases without
existing supported configuration and validation. “Claude” as a name does not select Anthropic,
and “Codex” does not select a coding-agent backend.

**Acceptance:** skipped setup, blank/default/reset, persistence and existing-install migration;
Unicode/length/control-character handling; instruction-like names cannot change prompt authority;
persona/custom-prompt precedence; consistent default identity across supported providers; settings
changes without overwriting prompts, history or wake configuration. UI verification covers keyboard,
VoiceOver, Dynamic Type and localisation. No app-wide branding replacement or new onboarding flow.

## Delivery evidence and exclusions

Implement P0 → P1 → P2 → P3 → P4 → P5 → P6, splitting further only where migration/protocol work warrants
it. Preserve unrelated workspace changes. Each PR records regression evidence at the actual service
boundary and separates headless checks from device validation. Backend acknowledgement/response
contracts require fixture and real-endpoint confirmation before claiming full support.

| Gate | Status |
|---|---|
| Results/status/error narration | 🚧 Fixture-green 2026-09-16 (P0); live endpoint owed |
| Questions/replies, agent selection and legacy configuration migration | 🚧 Fixture-green 2026-09-16 (P1); live endpoint owed |
| Listener recovery and audio ownership | 🚧 Fixture-green 2026-09-16 (P2); device checks owed (first Start after sleep/route change; one listener, no orphaned mic after stop) |
| Live timing controls and interruption usability | 🚧 Fixture-green 2026-09-16 (P3); device comparison owed (premature cut-offs vs perceived delay across the presets; the barge-in noise floor) |
| Playback-aware acknowledgement and reconnect semantics | Pending |
| Visual feedback, stale callbacks and accessibility | Pending |
| Optional assistant name, identity precedence and onboarding/settings | Pending |

Record build/commit, endpoint contract/fixture, hardware/OS where relevant, result and remaining gap.
No fixed product rename or changes to installed/system-facing OpenGlasses branding. P6 permits
user-selected conversational identity and relevant in-app labels only. No personal signing files,
credential scripts or CarPlay entitlement changes are introduced. This planning change adds no
runtime behaviour or dependencies.
