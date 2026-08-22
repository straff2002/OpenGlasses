# Plan CV — Continuous Scene Narration

**Status: 🚧 P1 shipped 2026-08-23** — the three pure cores landed; nothing is wired yet, which is
P2. Extends [A](A-accessibility-tier.md) (A3 assistive modes), which is **free and never an IAP** —
so is this.

Plan A shipped assistive scene and social modes as **on-demand**: the wearer asks, a frame is
captured, the model answers. That is the right shape for *"what am I holding?"* and the wrong shape
for walking through an unfamiliar building. A blind or low-vision wearer moving through a space
doesn't have a question to ask — they need the room described **as it changes**, which requires the
app to notice the change rather than wait to be asked.

We already do exactly this for sound: `AmbientCaptionService` transcribes continuously and surfaces
what it hears. There is no visual counterpart. This plan is that counterpart.

## Most of the machinery already exists

The naive build is a watch loop with a frame-difference threshold and a speech call. Three of those
four pieces are already in the tree, and ours are better than the naive versions:

| Need | Already have | Note |
|---|---|---|
| "Is this a new scene?" | `FrameGate` + `PerceptualHash` (Plan AT) | 64-bit dHash + **adaptive EMA threshold** + heartbeat, and a named `SendReason.distinct` that means precisely "a genuine scene change worth describing". Strictly better than a fixed mean-absolute-difference threshold, and already reused once by `PageTurnDetector`. |
| "Speak only when the floor is free" | `ChatReadbackPolicy.nextItem(at:ttsBusy:)` (Plan CI) | Pull-based arbitration with a rate cap, drop-oldest queue, dedup, TTS-busy hold and realtime suppression. Built for broadcast chat; the shape is general. |
| On-device description | `LocalLLMService.generateVisionTurn` | Local VLM path, already used by the assistive modes. |
| **"Is this description worth saying?"** | — | **Missing. This is the new core.** |

So this plan does **not** add a second scene-change gate, and should not add a third speech
arbiter. It adds the one gate we lack, and generalises the arbiter we have.

### The gate we're missing, and why a frame gate can't be it

A vision model rephrases the same scene endlessly — *"a man at a desk"*, *"a person sitting at a
desk"*, *"someone working at a desk"* — and a scene gate cannot catch this, because from the
camera's point of view **nothing changed and the frame was never re-sent**. The duplication is
generated downstream, by the model, on the heartbeat re-send that `FrameGate` deliberately forces so
context can't go stale.

So the second gate operates on the **text**, against the last *spoken* description (not the last
generated one — otherwise a silent rephrase resets the comparison and the next rephrase gets
spoken). Word-overlap similarity is sufficient and stays pure and testable.

The threshold's asymmetry runs opposite to the frame gate's, and should be set deliberately
permissive: rephrasings of one scene share most content words and score high, a genuinely new
subject shares few. **The cost of a false "same" is one missed announcement; the cost of a false
"new" is chatter — and chatter in someone's ear, continuously, is much worse.** For an assistive
feature that is not a close call.

## Silent by default: perception is context, not narration

The loop's default state is **watching and not speaking**. Descriptions accumulate as grounding
context and surface on screen; the wearer's questions are then answered against a scene the model
has already looked at, which makes *"what's that?"* answerable instantly rather than after a fresh
capture-and-describe round trip.

Speech is a **separate, explicit mode** ("start narrating" / "stop narrating"), because continuous
narration is a specific accessibility need, not a default anyone would want. This also means the
expensive half (speech, and the GPU contention below) is opt-in while the cheap half (grounding)
benefits every wearer in the mode.

## Speech arbitration: narration must never preempt a reply

The hard constraint, and the one most likely to be got wrong: an ambient description must only ever
speak **into silence**. If the wearer asked something, the answer owns the floor — a scene
description cutting into a reply is worse than no description at all.

Note what we *don't* have today: `TextToSpeechService.SpeechUrgency` changes speech rate and adds a
prefix. It is presentation, **not arbitration** — it cannot hold a low-priority utterance until the
floor frees. `ChatReadbackPolicy` is the thing that actually implements the hold, for broadcast
chat.

**Decision: extract, don't duplicate.** Generalise `ChatReadbackPolicy`'s arbitration into a shared
ambient-speech policy with two consumers (chat readback, narration), rather than writing a third
implementation of "wait for the floor, cap the rate, drop the stale". Three independent copies of
this logic is how one of them ends up subtly able to interrupt a reply. A rider on this plan, sized
honestly: CI's policy is tested, and the extraction must preserve its tests unchanged.

`ProactiveAlertService` is a plausible third consumer and should be evaluated during the extraction
— but is not in scope here.

## GPU contention is a design constraint, not a footnote

An on-device VLM decoding and Kokoro synthesising both want Metal. Prior measurement of this exact
pairing shows decode dropping by roughly 40% while synthesis runs. Our TTS chain reaches Kokoro
whenever ElevenLabs is unavailable (no key, offline, quota-exhausted), so on a fully-offline
wearer — precisely the accessibility case this plan serves — **narration is the contention.**

This is why the loop needs a duty-cycle floor and dwell-based triggering rather than free-running
inference: not battery politeness, but keeping the model responsive enough to answer a question
while it is also describing the room.

## Privacy scope — decided, and it is not "filter everything"

[CO](CO-identity-budget-turn-taking.md) Item 0 established the rule: every model-facing **egress** is
blurred by `PrivacyFilterScope`, with face recognition the sole exemption because the blur is
indiscriminate and would break the feature.

Narration on a **local** VLM is not an egress — the frames never leave the device — so it does not
pay the blur cost, on the same reasoning as the face-recognition exemption: an indiscriminate blur
would degrade exactly the descriptions a blind wearer depends on ("someone is standing near the
door" is the *point*). If narration is ever pointed at a cloud model, that path is an egress like
any other and goes through `PrivacyFilterScope` unchanged. This must be stated in the scope type
itself, next to the existing cases, rather than left implicit — CO exists because an unstated scope
decision turned into a toggle that did nothing.

## Phases

### P1 — Pure cores ✅ shipped 2026-08-23

- **`NarrationGate`** (`Services/Vision/NarrationGate.swift`) — the missing text gate, sitting
  beside `FrameGate` because it is its partner. Two decision points: `evaluateGeneration(at:)`
  applies the duty-cycle floor and then dwell, and consumes the pending scene change so a static
  scene is described once rather than on every tick; `evaluateSpeech(_:)` scores word overlap
  against the last *spoken* description and moves that baseline **only** when it says speak.
  - Similarity is the overlap coefficient over content words — stop-worded (including the
    boilerplate a VLM wraps everything in: *"the image shows…"*), generic person references folded
    to one token, crudely de-pluralised — with the denominator floored so a terse description can't
    score 1.0 by being a subset of a verbose one. Overlap rather than Jaccard because two
    descriptions of one scene are routinely different lengths and Jaccard punishes that as if it
    were a change of subject.
  - The fixtures measure the asymmetry rather than asserting it: across a five-way rephrasing
    family every pair scores **≥ 0.6**, and the worst genuine scene change scores **0.2** — a
    0.4-wide gap around the 0.5 threshold, so it sits in a gap and not on a boundary. A test fails
    if that margin ever drops below 0.2.
  - `evaluateSpeech` takes **no** `now`, deliberately: the two time-based rules are on the
    generation side, and "said recently enough not to repeat" is the arbiter's dedup window.
  - **Dwell has a ceiling** (default 8 s), which the draft did not call for and the feature needs:
    a wearer walking a corridor never settles, so an uncapped dwell rule would describe nothing for
    the entire walk — the exact case this plan exists for.
- **Shared ambient-speech arbitration** (`Services/Speech/AmbientSpeechArbiter.swift`) — the rate
  cap, bounded drop-oldest queue, dedup window, TTS-busy hold and suppression-flushes-the-queue
  behaviour, lifted out of `ChatReadbackPolicy` as a generic value type over its payload.
  `ChatReadbackPolicy` keeps its taste (filters, URL stripping, mention matching, "times N", burst
  naming) and delegates the rest; its public surface is unchanged and **`ChatReadbackPolicyTests`
  was not touched and passes as written**, which is what makes this an extraction rather than a
  rewrite. `AmbientSpeechRules.narration` is the second consumer's preset (a deliberately tiny
  queue — a description of a room the wearer has already left is worse than silence).
- **`NarrationSessionPolicy`** (`Services/Accessibility/NarrationSessionPolicy.swift`) — the mode
  state machine. `.start` lands in `.watching`, silent, always; `.stopNarrating` falls back to
  watching rather than off, so the grounding keeps accumulating. Interruptions split in two, and
  the split is the substance: `userTurn` / `realtimeSession` take **the ear only** (watching
  continues, the queue flushes), while `backgrounded` / `cameraUnavailable` halt the loop outright
  and set a `haltReason` the transition reports as owed to the wearer. The requested mode survives
  every interruption, so recovery restores what the wearer asked for; `.stop` beats everything and
  a later recovery does not resurrect the session.
- **Privacy scope** — `PrivacyFilterScope.sceneNarration`, exempt, with the reasoning on the case
  itself. `OutboundFramePrivacyTests` now pins the exemption set as exactly the two non-egress
  consumers rather than "face recognition only", so a third has to be argued for rather than added.

### P2 — The loop

`SceneNarrationService` wiring `FrameGate` (`.distinct` only — **ignore `.heartbeat`**, since a
forced re-send of an unchanged scene is exactly what must not produce a fresh announcement) →
`generateVisionTurn` → `NarrationGate` → arbitration → TTS/HUD. Descriptions retained as a bounded
rolling context that Direct-mode questions can ground against. Settings toggle under the
accessibility surface, and voice commands routed through `AssistiveRouter`.

The cores are all P2 has to call: `NarrationGate.noteSceneChange(at:)` on `.distinct` only,
`evaluateGeneration(at:)` before spending an inference, `evaluateSpeech(_:)` on what comes back,
`AmbientSpeechArbiter(rules: .narration)` for the floor, and `NarrationSessionPolicy` deciding
whether any of it should be running at all.

**Found while building P1, and P2 has to resolve it:** `SceneWatcherService` is a proactive
scene-observation loop already in the tree with **no call sites anywhere** — its two `Config`
accessors are read by nothing and it has no Settings UI — and its `isDuplicate` compares
*characters* rather than words, so it suppresses nearly everything once one observation lands. It
is the same shape `PrivacyFilterService`'s own comments call out. Either `SceneNarrationService`
subsumes it and it is deleted, or it is rebuilt on `NarrationGate`; shipping two proactive scene
loops, one of them broken and dormant, is not an option.

### P3 — Honest limits in the UI

**On-device MLX cannot run while backgrounded** (`project_local_model_background`), so narration
stops when the phone locks or the app backgrounds. For a wearer who is *relying* on it, silence that
isn't explained is indistinguishable from silence because nothing changed — the worst possible
failure for this feature. It must announce the stop and say why, and Settings must state the
limitation rather than implying continuous coverage.

Same treatment for the camera-tier gate: on glasses without live frames
([CQ](CQ-third-party-glasses-backends.md)'s tiers) narration is unavailable, and must say so with a
reason rather than silently doing nothing.

### P4 — Device measurement (deferred)

Gates the thresholds and the defaults, and needs hardware plus a real environment:

- Dwell and duty-cycle values against a walked route, not a desk.
- Speech-gate threshold against real rephrasing families from our own model at our own prompt.
- Sustained thermal and battery over a session long enough to matter (this runs the VLM
  continuously — it is the most expensive thing in the app).
- Measured decode-vs-synthesis contention on our actual chain, to set the duty-cycle floor.
- **Accessibility review with a wearer who would use it.** Chatter tolerance is not a number we can
  derive; it needs someone whose judgement is the actual specification.

## Non-goals

- **A second scene-change detector.** `FrameGate` is it.
- **Narration on cloud models** in v1 — it is defensible (better descriptions) but it turns a
  continuously-running loop into a continuous egress and a continuous bill, and both deserve their
  own decision rather than riding in on an accessibility feature.
- **Replacing on-demand assistive modes.** This is a mode alongside them; "what am I holding?" stays
  a question.
- **Object permanence / tracking across scenes.** Plan AV (Visual State Memory) owns that; narration
  should consume it if it lands, not reimplement it.

## Open questions

- Does narration write to `BrainStore` as ambient memory (per `project_brain_store`, new memory
  features feed it)? Leaning yes for `.distinct` descriptions, no for rephrases — but a continuous
  loop writing continuously is a volume question the store hasn't faced yet.
- Should the HUD show the current description on the lens as well as speaking it? Free for a sighted
  wearer in a noisy room, meaningless for the primary audience — probably a separate toggle.
- Interaction with `AmbientCaptionService`: both running means two ambient streams competing for the
  same ear. The shared arbiter handles the mechanics, but the *policy* (which yields to which) is
  undecided.
