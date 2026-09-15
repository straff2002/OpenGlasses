# Plan FE — Agent and Voice Reliability and Feedback

**Status: 📝 Drafted 2026-09-13 — implementation and validation pending.**

Deliver truthful agent results, questions and replies, listener recovery, configurable speech
timing, delivery acknowledgements and speech-reactive visuals.
Keep OpenGlasses branding, bundle IDs, signing, app groups and entitlements unchanged.

## Existing owners and verified gaps

- [N](N-remote-agent-harness.md): `CustomAgentHarness`, `CustomHarnessConfig`, `AgentSessionService`,
  `AgentSummarizer` and existing event/result types. Custom polling currently discards result fields;
  confirmation errors are swallowed before announcing “proceeding”; default input handling can no-op.
- `WakeWordService.startListening` returns on `isListening` alone. A stale `isListening` flag after
  audio disruption is suspected; reproduction remains pending.
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
| Results/status/error narration | Pending |
| Questions/replies, agent selection and legacy configuration migration | Pending |
| Listener recovery and audio ownership | Pending |
| Live timing controls and interruption usability | Pending |
| Playback-aware acknowledgement and reconnect semantics | Pending |
| Visual feedback, stale callbacks and accessibility | Pending |
| Optional assistant name, identity precedence and onboarding/settings | Pending |

Record build/commit, endpoint contract/fixture, hardware/OS where relevant, result and remaining gap.
No fixed product rename or changes to installed/system-facing OpenGlasses branding. P6 permits
user-selected conversational identity and relevant in-app labels only. No personal signing files,
credential scripts or CarPlay entitlement changes are introduced. This planning change adds no
runtime behaviour or dependencies.
