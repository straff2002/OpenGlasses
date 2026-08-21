# Plan CU — Voice Turn Latency & Instrumentation

**Status: 📝 Drafted 2026-08-22** — no PR yet.

Every Direct-mode turn pays a fixed floor of dead air before the model is even asked.
`TranscriptionService` commits a turn on a silence timer whose window is
`SpeechContinuationPolicy.baseWindow` = **2.0 s**, widened to `questionWindow` = 6.0 s when the
assistant's own reply was question-shaped ([CO](CO-identity-budget-turn-taking.md) Item 4). That
window is load-bearing and CO was right to widen it — but it is measuring the wrong thing. It asks
*"has the recognizer been quiet for N seconds"* as a proxy for *"has the wearer finished talking"*,
and the proxy is bad in both directions at once:

- `SFSpeechRecognizer` delivers partials in **bursts with ~1 s gaps while the user is still
  speaking**, so any window short enough to feel responsive fires mid-sentence.
- Every *completed* turn pays the whole window as silence before the backend is touched, so a fast
  cloud model and a slow local one finish about as far apart as their windows — which is to say,
  not very.

CO Item 4 already established the cost asymmetry ("waiting too long is mildly awkward, cutting
someone off mid-thought loses the turn entirely") and resolved it by *lengthening*. **This plan does
not relitigate that.** It changes the *signal* so the trade-off stops being forced: decide
end-of-turn from the **audio**, where the question "did speech stop?" is directly answerable, and
demote the timer to a backstop. Our own code has named this as the intended follow-up since the
on-device ASR work — `TranscriptionService.swift:54-57`: *"VAD-based endpointing + on-device partial
results are the staged follow-up."*

Two paths were considered and are **rejected up front**, because both are cheaper than VAD and both
are known dead ends:

- **Adaptive transcript timing** (shorten the window when partials look settled) — the burst pattern
  above is not distinguishable from a finished sentence at the timing layer.
- **Grammatical completeness** of the partial ("does this parse as a whole sentence?") — *"what's the
  weather"* is both a complete sentence and a prefix of *"what's the weather in London tomorrow"*, so
  a completeness test commits mid-utterance. This is a semantic dead end, not a tuning problem.

Both rejections have since been **corroborated in the field, twice, independently**: two separate
builds of comparable apps shipped a transcript-completeness endpointer (dangling-word and filler
lists shortening the window when the partial "reads finished"), one of them reverted it the same day
for cutting users off, and the surviving path in both cases is acoustic. That is not a reason to
change this plan — it is the reason not to spend a week re-discovering it cheaply first.

## Why instrumentation lands first

We cannot currently verify any latency claim about this app. `Diagnostics/SubsystemTestRunner`
covers cold-start subsystem checks; **nothing measures a live turn**. Perceived slowness is
attributed by feel, and feel is exactly what gets this wrong — a fixed endpointing window is
invisible to intuition because it is identical on every turn and therefore reads as "the app's
speed" rather than as one stage you could remove.

So **P1 is instrumentation and it ships before the fix.** Otherwise P2 is tuned by vibes and P3 is
guesswork. This ordering is the point of the plan, not an accident of it.

## P1 — `TurnTimeline` (pure core, lands first)

A value type holding the timestamps of one voice turn, with derived durations. Pure — no I/O, no
`Date()` inside, stages injected — so every derivation is unit-testable against fixture turns.
Stages are optional throughout: a turn can be abandoned at any point (interrupted, superseded,
error) and a **partial timeline is still worth recording**.

### Stage taxonomy

| Mark | Meaning |
|---|---|
| `heldAt` | utterance parked by `TurnAdmissionPolicy.deferToQueue` (ours) |
| `speechEndAt` | the mic went quiet — end-of-turn decision point |
| `commitAt` | handed to a backend |
| `firstTokenAt` | backend produced first output — *"is the model slow?"* |
| `generationDoneAt` | model finished the reply |
| `ttsRequestedAt` | text handed to the speech engine |
| `firstAudioAt` | **the wearer actually hears something** — perceived latency ends here |
| `hudRenderedAt` | reply mirrored to the lens (ours) |
| `spokeDoneAt` | playback finished |

Plus spans that sit *inside* other stages and must be visible separately: `frameGrabSeconds`,
`toolSeconds`/`toolIterations`, `heldSeconds`. Plus tags: `backend`, `model`, `ttsEngine`,
`micRoute`, `abandoned`, `interrupted`.

**The headline metric is `perceivedLatency` = `speechEndAt` → `firstAudioAt`.** Everything inside it
is dead air from the wearer's point of view, and it is the number this whole plan exists to move.

### Meld or adopt wholesale — decided

The taxonomy above is a well-trodden shape for voice agents and there is nothing to gain by
inventing our own. The decision splits four ways:

1. **Taxonomy and headline metric — adopt wholesale.** speechEnd → commit → firstToken → genDone →
   firstAudio → spokeDone, with perceived latency as the number that matters.
2. **The four derivation invariants — adopt wholesale.** These are the expensive part; each one is a
   correction that costs a bug to learn:
   - **tok/s comes only from the library-reported pair** (`tokenCount`, `generateTime`), both
     *accumulated across generation passes*, never from timeline deltas. Timeline stamps are
     first-wins and get backfilled for non-streaming backends, so a rate derived from them can
     silently cover a different span than the tokens it divides. Two distinct failure modes live
     here: a microsecond window dividing into millions of tok/s, and pass-2's token count paired with
     pass-1's time window. Keep a minimum-window sanity guard; **no rate is better than a fictional
     one.**
   - **TTS lead-in is signed on purpose.** `generationDoneAt` → `firstAudioAt` going *negative* means
     speech started while the model was still generating — the good case, and the entire point of
     sentence-streaming. Clamping negatives to nil (as every other stage does) deletes the metric on
     exactly the turns it exists to characterise.
   - **TTS time-to-first-byte is a distinct metric** from lead-in: `ttsRequestedAt` → `firstAudioAt`.
     On a streamed reply the first sentence reaches the engine long before generation ends, so
     lead-in can be negative while TTFB stays positive. This is the one that answers "how slow is
     synthesis?"
   - **Frame-grab time is held separately.** It happens between commit and first token, so vision
     TTFT *includes* it — comparing vision TTFT against text TTFT without subtracting it blames the
     model for time spent waiting on the glasses' Bluetooth stream.
3. **Stages — meld, because our turn is structurally bigger.** Four additions are not optional
   polish; without them the numbers actively lie on our most common turn shapes:
   - **`toolSeconds` / `toolIterations`.** We have 36+ native tools behind `ToolLoopDriver`, so one
     turn can be several LLM round trips with execution between them. Without this split, a turn
     that spent four seconds in a HomeKit call reports four seconds of "model latency" and we go
     optimise the wrong thing.
   - **`heldSeconds`.** `TurnAdmissionPolicy.deferToQueue` parks an utterance (up to `maxHoldAge`
     = 20 s) and replays it when the running turn finishes. That turn's clock starts before its own
     speech ended; unrecorded, its perceived latency is nonsense.
   - **`micRoute` tag.** `MicRoute` is three-way (phone / glasses / headset). An 8 kHz Bluetooth HFP
     link and the phone's 48 kHz mic are two different populations for every acoustic metric in P2 —
     mixing them produces an average that describes neither.
   - **`ttsEngine` tag over a three-engine chain.** Ours is ElevenLabs → Kokoro → iOS, and the first
     is **network** while the second is **on-device Metal**. Those aren't voices, they're three
     different pipelines: cloud TTFB includes a round trip, and Kokoro synthesising on the GPU
     measurably slows local decode, so tok/s is only comparable *within* one engine.
4. **Code — rebuild, don't port.** It's a ~150-line pure struct; the value is the design decisions
   above, which are now written down here. Porting source would also pull an attribution obligation
   into About for something we can write in an afternoon.
5. **Sinks — skip entirely.** No InfluxDB, no Grafana, no `docker-compose`, no push. It lands in the
   existing Settings → Advanced → Developer diagnostics surface as an on-device ring buffer with a
   debug export. This is not just scope control: **any push sink becomes an egress question** we then
   have to answer for HIPAA mode and for `PrivacyFilterScope`'s "every egress is filtered" rule. An
   on-device ring buffer has no such question, and per-turn latency is a debugging tool for us, not
   a product surface for the wearer.

### Deliverables

- `TurnTimeline` value type + derivations, with fixture-turn tests covering each invariant above
  (including a negative-lead-in turn and a two-pass tool turn, since those are the ones prior art
  got wrong).
- A bounded in-memory `TurnLedger` (ring buffer, count- and byte-capped) and marking calls threaded
  through the existing turn path in `OpenGlassesApp`.
- A Developer-panel view: last N turns, stage breakdown, and the aggregate split by `backend` ×
  `ttsEngine` × `micRoute` (never pooled — see the tagging rules above).

**Deferred out of P1, deliberately:** the two realtime backends are *modelled* (`TurnBackend`
carries them, cohorts keep them apart) but not *produced* — neither session manager has turn
boundaries wired to the recorder, so no realtime turn is recorded and the Direct-vs-realtime
baseline under Non-goals below cannot be read off the panel yet. Wiring those two managers is the
first follow-up, not part of P1's diff. Likewise `ttsLeadIn` is signed and will stay signed, but no
Direct-mode spine can currently produce a negative one: every spine hands the whole reply to the
speech engine after `generationDone`, so a panel full of positive lead-ins means "no streaming
hand-off exists to measure", not "sentence streaming is off".

## P2 — Acoustic end-of-turn

### `EndOfTurnPolicy` (pure core)

Arbitrates the acoustic signal against the existing timer, and it is where the CO Item 4 semantics
get preserved rather than overwritten:

- **Detector unavailable ⇒ byte-for-byte today's behaviour.** The timer path stays exactly as it is.
  Voice input degrading to "as it was before" is acceptable; breaking it is not.
- **Speech observed, then ended ⇒ commit after a short grace.** This is the case that removes the
  2 s floor.
- **Speech never started ⇒ the timer still owns the decision, at the CO Item 4 window.** This is the
  subtle half: `questionWindow` exists for a wearer who is *thinking about their answer*, i.e. has
  not started speaking. Acoustic endpointing has nothing to say about that wearer, so the 6 s window
  survives untouched as a **no-speech** window. Conflating the two would quietly re-break the exact
  case CO shipped to fix.
- **Threshold asymmetry mirrors CO's.** Set the detector's speech threshold *above* the library
  default: the glasses HFP mic is 8 kHz and noisy, and a false "speech" costs a little latency
  whereas a false "silence" cuts the wearer off mid-sentence. Same asymmetry, same direction, one
  layer down.

### `SpeechActivityDetector` (behind a seam)

On-device Silero VAD on the Neural Engine, scoring 16 kHz mono in fixed hops. Soft-fail throughout:
if the model won't load, `isAvailable` stays false, no events are emitted, and `EndOfTurnPolicy`
falls through to the timer.

**Where it taps: nowhere new.** `TranscriptionService` already installs a tap
(`TranscriptionService.swift:164`, `:224`) and accumulates `Float` samples for the on-device ASR
path. The detector is fed from those same buffers. A second tap would be the wrong move on two
counts — `WakeWordService` owns the shared engine (`sharedAudioEngineProvider`), and CJ's tap-format
audit plus AO's audio-session work exist precisely because taps and route changes are where this
subsystem breaks.

Threading rules, all forced by the fact that `feed(_:)` runs on the **Core Audio render thread**
~45×/sec:

- Never block, never allocate unpredictably, never hop to the main actor in `feed`. Convert and
  accumulate under a lock; hand full chunks to an `AsyncStream`; a single consumer task drains it in
  order (streaming VAD state must be threaded sequentially).
- **Drop oldest under backpressure**, don't queue. Stale audio is worthless for a liveness decision,
  and a growing backlog reports speech-end later and later — the failure mode is a slow leak into
  exactly the latency we're removing.
- **Rebuild the converter on route change.** A converter built for the old format emits garbage
  after the route flips, and we flip routes as a matter of course (`MicRoute`, "Hey Meta" stealing
  the route, glasses connect/disconnect). [CW](CW-realtime-audio-rig-recovery.md) P1 makes the same
  format-changed test the trigger for rebuilding the *graph*; same hazard, one layer up, and the two
  should read the format from one place rather than each caching their own idea of it.
- Callbacks reach the main actor only on speech start/end transitions — a few times per turn.

### Rider: cheaper barge-in

`WakeWordService.onBargeIn` currently fires on recognised *text* during TTS. A VAD speech-start
event is the same signal several hundred milliseconds earlier and without a recognition round trip.
Wire it as an additional trigger, not a replacement — the text path also carries the utterance,
which the barge-in handler uses.

### Rider: per-route input gain

Every threshold in this section is calibrated against a signal level, and that level is not
comparable across routes — the phone mic at arm's length reads far quieter than a glasses mic at the
temple, which is the acoustic half of why `micRoute` is a cohort tag in P1 rather than a footnote. A
clamped per-`MicRoute` input gain, applied before the detector sees the samples, is what makes one
threshold pair mean the same thing on both routes. It must land **with** the threshold work, not
after it: tuning a threshold against an un-normalised level and then normalising the level
invalidates the tuning. [CW](CW-realtime-audio-rig-recovery.md) notes the same rider from the rig
side and defers it here on purpose, so it is not tuned twice against two different populations.

### Dependency decision

Silero via a maintained Swift package (Apache-2.0, actively developed) versus vendoring the CoreML
model ourselves. Leaning package, on the CD P3 convention: **pin exactly**, refresh
`ci_scripts/Package.resolved` per `project_xcode_cloud_resolved`, and attribute in About. Vendoring
is the fallback if the package pulls in more than the VAD path.

## P3 — Local-model time-to-first-token (gated on P1's numbers)

Two changes that plausibly halve local TTFT:

- **KV prefix cache across turns** — `LocalLLMService` has no prompt cache today, so our
  `SystemPromptBuilder` prompt (large, and it grows with every tool we add) is prefilled on **every
  turn** instead of once per session.
- **Per-model routing-prompt sizing** — a capable model needs a short instruction; a small model
  needs the fully-worked examples. One prompt for both means either the big model reads an essay or
  the small one guesses.

**Explicitly gated on P1.** Only worth doing if the timeline shows TTFT is the next-largest stage
after endpointing, and there is a real cost on the other side: a retained KV cache holds memory that
`LocalModelBudget` / `MemoryHeadroom` exist to reclaim, and jetsam kills are a documented failure
mode of this subsystem (per `project_local_model_background` and the CK/local-model history). Do not
start this before P1 lands.

## P4 — Front-of-turn: wake-word pre-roll

P2 removes dead air at the **end** of an utterance. There is an equal and separate amount at the
**start**, and it is paid by the wearer in the most annoying currency available: having to say it
again.

Today the wake word opens the turn and everything spoken *in the same breath* after it is lost —
`WakeWordService` detects, we tear down its recognition and stand up the turn's own capture, and the
audio in that gap goes nowhere. So *"Hey Glasses, what time is it"* answers with a listening cue and
waits, and the wearer repeats the question they already asked. The fix is not faster hand-off; the
gap is structural. **Keep the audio.**

### `WakePreRollRing` (pure core)

A bounded ring of PCM16 mono at the capture rate holding the last ~2 s, fed from the **same tap the
recognizer already reads** — a second tap is the wrong move for the reasons P2 gives, and
`WakeWordService` owns the shared engine either way. Pure, allocation-free after construction,
oldest-falls-off, unit-tested against fixture writes.

The non-obvious requirement is that a ring of samples is not enough on its own: we need to know
**where in it the wake phrase ended**, or we replay the wake word itself into the turn and the model
answers a question that begins with its own name. So the ring carries an **audio clock** — an epoch
marked per recognition request — and the wake phrase's end is located from the detecting result's
own segment timing (`segment.timestamp + duration`), not from wall-clock. Wall-clock cannot work
here: detection latency is variable and the ring is written on the audio thread.

Rules that make it safe rather than clever:

- **Not locatable ⇒ replay nothing.** A bare wake word must open the turn and stay silent. Guessing
  an offset is worse than the status quo, because a wrong guess feeds a fragment of the wake word in
  as the user's question.
- **Stale ⇒ discard.** A pre-roll older than a few seconds describes a different moment; hand back
  nil and let the turn start clean.
- **Survives recognizer restarts.** The recognizer is restarted routinely (`WakeWordService` cycles
  it); the ring is fed by the tap, not the recognizer, so a restart re-marks the epoch and keeps the
  audio.

### Wiring

- **Direct mode:** the pre-roll tail is prepended to the turn's transcription input, so the
  utterance the backend sees is the whole breath.
- **Realtime backends:** bring the mic up **before** the socket, buffer frames through the handshake,
  and send the pre-roll as the session's first audio append once connected. The handshake is dead
  time we currently spend deaf; this is the same "keep the audio" move applied to a different gap.
  Note this is *not* the endpointing work the Non-goals below exclude for realtime — those sessions
  endpoint server-side and stay that way; this is about what they are given to start with.

Measured, not asserted: P1 gains a `preRollMilliseconds` span, and the win shows up as
`speechEndAt` → `commitAt` shrinking on wake-initiated turns specifically. If it doesn't, the ring
is mis-located and the guard above should be firing.

## P5 — Device measurement (deferred)

Needs hardware, and gates the shipped defaults:

- Perceived latency before/after, on **both mic routes** (phone and glasses HFP) — reported
  separately, never pooled.
- False-cut rate: how often acoustic endpointing commits mid-sentence at the chosen threshold. This
  is the metric that can veto the feature; a latency win that cuts people off is not a win.
- Detector cost: Neural Engine load, battery, thermal over a long session.
- Route-change behaviour: converter rebuild across a glasses connect/disconnect mid-turn.
- Pre-roll correctness (P4): the wake word never appears in the transcript, and a one-breath
  *"<wake word>, <question>"* is answered without a repeat — on both mic routes.

## Non-goals

- **Gemini Live and OpenAI Realtime endpointing.** Both already endpoint server-side and are fine;
  this is a Direct-mode plan. The *timeline* should still cover realtime turns, because comparing
  Direct-mode against them is the most useful baseline we have.
- **A telemetry service.** No server, no push, no consent surface — see P1 item 5.
- **Reopening CO Item 4.** The question window stays; it changes meaning (no-speech rather than
  post-speech), it does not shrink.

## Open questions

- Should VAD also replace `noSpeechTimeout` (currently a flat 10 s)? Probably, but it's a different
  failure mode — nobody spoke at all — and can follow.
- Does the on-device ASR path (`OnDeviceASREngine`, whole-buffer SenseVoice) want VAD endpointing
  too? Its own comment says yes. It's the natural second consumer of P2 and would let that path stop
  depending on the caller's `stopRecording()`.
- Ring-buffer size and whether the debug export is on by default in Debug builds only.
