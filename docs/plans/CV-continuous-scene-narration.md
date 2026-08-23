# Plan CV — Continuous Scene Narration

**Status: 🚧 P1–P3 shipped 2026-08-23**, and the ambient-captions interaction is
**resolved and built** (2026-08-23) — the loop is built, wired, and honest about what it can't do.
Only P4 (device measurement, incl. an accessibility review with a wearer who would use it) remains,
and it needs hardware. Extends [A](A-accessibility-tier.md) (A3 assistive modes), which is **free and never an IAP** —
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

## Ambient captions and narration — resolved 2026-08-23

**The question as posed had a false premise, and finding that out changed the answer.** It assumed
two ambient streams competing for one ear. `AmbientCaptionService` **never speaks.** Its two outputs
are the phone overlay and `glassesDisplay.showText` — the in-lens HUD. Captions are an eye stream;
narration is an ear stream. Nothing about the ear was ever in contention.

It follows that the wearer at risk is also not the one we assumed. A deaf-blind wearer can use
neither surface — a lens they can't read, a voice they can't hear — so they are not the person
running both. The realistic wearer of both is **low-vision in a room with more than one talker**:
they can read a large caption line and still need the space described. Designing for the wrong
person is how you optimise the wrong resource, and we nearly did.

Once the ear is off the table, three shared resources are left. Two were being contended already.

### 1. The lens — a live collision, and nobody had decided it

`TextToSpeechService.speak(_:urgency:mirrorToHUD:)` defaults `mirrorToHUD: true`, and `showText`
**replaces** the lens line persistently. Narration's speech seam was wired as `speak(text)` — the
default — so every description already overwrote whatever captions had put on the lens, mid-sentence.

This is worse than the interleaving the question worried about, for the same reason P3 exists: the
wearer **cannot tell it happened**. A spoken stream that gets interrupted is audibly interrupted; a
caption line that is replaced simply isn't there any more, and a deaf wearer reading it loses the
rest of the sentence with no evidence that a sentence was lost. Unexplained silence, in the visual
channel.

And note what produced it: the plan lists *"should the HUD show the current description on the
lens?"* as an **open question**, and a TTS default answered it yes. That is CO's failure mode in a
different costume — an unstated decision becoming behaviour. Narration now passes
`mirrorToHUD: false` for descriptions and notices alike. This does **not** decide the open question;
it removes an accidental yes so the question is still there to be decided, and whatever decides it
inherits the precedence below.

### 2. The microphone — narration writing itself into the wearer's transcript

Narration speaks over the same shared audio engine the caption recognizer listens on, and that path
runs `.playAndRecord`/`.default` with **no voice processing** (`setVoiceProcessingEnabled` is only
ever set on `RealtimeAudioEngine`, a different engine for realtime sessions). So narration's own
synthesized voice is transcribed as if a person in the room had said it, and flows on into meeting
summaries, the Spotlight index and Brain.

This is the worst of the three, because it is **silent corruption of a record** rather than noise,
and `TranscriptGuard` cannot catch it: that filter exists for silence-decode artifacts, and a fluent
English sentence about a kitchen is exactly what it is built to let through.

### 3. Compute — real, and deferred to P4 rather than guessed at

Captions on the on-device translation tier run an ASR model and Apple Translation; narration runs a
VLM and, offline, Kokoro. All of it wants the same silicon, and the duty-cycle floor was set against
narration alone. That is a measurement, not a policy, and it belongs to P4 with the rest.

### The decision

**Separate the channels; don't rank the streams. Narration owns the ear, captions own the lens, and
while a transcript is live narration keeps watching and stops speaking.**

Both switches on is supported, and deliberately so: forcing an either/or between eyes and ears would
be a strange thing for an accessibility feature to do to someone who needs both. What must not
happen — and what the question rightly worried about — is both switches on while one silently loses.
Channel separation is how that is avoided without a modal choice.

Where they genuinely cannot be separated, **captions win, statically**:

- A caption is **another person talking** — time-critical and unrepeatable. A description of a room
  is neither. If the room changes, `FrameGate` notices and describes the new one. **Narration is the
  self-healing half of the pair**, which is what makes it the one that yields.
- The channels are separate; the wearer's language faculty is not. Nobody reads one sentence while
  hearing a different one, and two simultaneous language streams from one device is not a thing a
  person parses.
- It costs narration nothing it was ever guaranteeing. It is already rate-capped to four utterances
  a minute behind a two-slot drop-oldest queue, a duty-cycle floor and a similarity gate — it drops
  descriptions constantly and by design.

**The objection this has to answer: doesn't "captions always win" bury a safety-critical
description?** The prompt does ask for obstacles, so the worry is not imaginary — but narration was
never a warning channel and cannot be made into one by leaving it switched on. Four per minute
behind a drop-oldest queue is not something anyone can be warned with, and the plan already decided
narration drops rather than delays. If a hazard utterance must land, it needs the alert path, which
does not go through the arbiter at all — the same conclusion P3 reached for halt notices.

**Rejected: contextual precedence** ("captions win unless the description is urgent"). It requires
narration to classify its own output, which means asking a VLM whether what it just described is
dangerous — and a model asked to find a hazard will find one. P2 already rejected asking the model
what *changed* for exactly this reason.

**Rejected: a priority field on `AmbientSpeechArbiter`.** A rank between consumers implies a shared
queue, and a shared queue is a way for narration to **hold** an utterance until the floor frees —
i.e. to deliver a stale description late, which `AmbientSpeechRules.narration`'s two-slot queue
exists specifically to prevent. It would also be arbitration machinery whose only job is to order
two things that never contend.

**Rejected: making the switches mutually exclusive.** It answers "should both be on?" by refusing to
answer it, and it takes the choice off a wearer who has a real use for both.

**Rejected: a third arbitration path.** Nothing here needed new arbitration. Yielding the ear is
already `NarrationSessionPolicy.Interruption` — the model P1 built for exactly "something overrides
what the wearer asked for" — and the queue flush the plan requires falls out of it unchanged.

### What it took to build, and the one thing the existing model was missing

`Interruption.ambientCaptions`, `haltsPerception == false`. Watching continues, speech stops, the
queue flushes: no stale description survives the transcript.

The gap was that `Interruption` had **one** axis, and this case needs two. `.userTurn` is a *moment*
the wearer created and hears end; a spoken "narration paused" there would be the app narrating its
own bookkeeping, which is why P3 correctly says nothing for it. Captions running is a **standing
condition** the wearer may have switched on hours ago — it can silence narration for an entire walk
with nothing to attribute the silence to. That is P3's failure exactly, in a case P3's machinery
could not see, because it only ever reported *halts*.

So `Interruption` gained `isStandingCondition` alongside `haltsPerception`, `State` gained
`silenceReason` as `haltReason`'s quieter sibling, and `Transition` gained `silenceBegan` /
`silenceEnded`. `NarrationVoiceNotices` applies its three restraint rules to the new grade
unchanged — only a wearer who asked to be narrated to hears it, never twice, and a resume only if
the silence was announced — with two additions the interaction forced:

- **A halt supersedes an announced silence**, and clears it. The wearer must not be told two
  different stories about one quiet.
- **A halt clearing into a still-live transcript is not a resume.** "Narration is back on" would be
  a lie the wearer then spends the next minute disproving; it says why it is still quiet instead.

Settings shows the same thing in a third status line, with a different symbol on purpose: this is
not something broken, it is two features being polite, and the copy names the switch that undoes it.

**Where the collisions surfaced, and why that is the interesting part:** the ear — the resource the
question was about — needed a rule but was never actually contended. The lens was being overwritten
in shipped code. The transcript was being contaminated in shipped code. Neither was in the open
question, because the question was written from the plan rather than from the wiring.

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

### P2 — The loop ✅ shipped 2026-08-23

`SceneNarrationService` wiring `FrameGate` (`.distinct` only — **ignore `.heartbeat`**, since a
forced re-send of an unchanged scene is exactly what must not produce a fresh announcement) →
`generateVisionTurn` → `NarrationGate` → arbitration → TTS/HUD. Descriptions retained as a bounded
rolling context that Direct-mode questions can ground against. Settings toggle under the
accessibility surface, and voice commands routed through `AssistiveRouter`.

The cores are all P2 has to call: `NarrationGate.noteSceneChange(at:)` on `.distinct` only,
`evaluateGeneration(at:)` before spending an inference, `evaluateSpeech(_:)` on what comes back,
`AmbientSpeechArbiter(rules: .narration)` for the floor, and `NarrationSessionPolicy` deciding
whether any of it should be running at all.

**Landed 2026-08-23.** `SceneNarrationService` is the loop and nothing else — every decision it
makes belongs to a P1 core, so the service is wiring plus the three things the phase actually owed:

- **`NarrationContext`** (`Services/Vision/NarrationContext.swift`) — the rolling grounding context,
  bounded on **three** axes rather than the obvious one: count, rendered characters, and **age**.
  Age is the one that matters and the one a count cap doesn't give you — a description of a room the
  wearer walked out of four minutes ago is not grounding, it is a wrong answer with evidence
  attached. Redundancy is scored with `NarrationGate`'s word overlap rather than a second
  implementation, and deliberately only against the **most recent** observation: a scene the wearer
  walks back into is where they are *now*. The prompt fragment trims from the **oldest** end, so
  under budget pressure the wearer's current surroundings survive and the room they started in is
  what goes.
- **`.firstFrame` is taken alongside `.distinct`.** The plan said "`.distinct` only, ignore
  `.heartbeat`" and the heartbeat exclusion is exactly right, but `.firstFrame` was unstated and
  excluding it would have meant a wearer who turns narration on while standing still is told
  nothing at all until something moves — the failure mode this feature exists to prevent.
- **The speech gate is scored only when the loop may actually speak.** Not an optimisation: scoring
  `evaluateSpeech` during silent watching would move the spoken baseline against something nobody
  heard, and the first description after "start narrating" would then be suppressed as a rephrase
  of a silence. There is a test named for that.
- **Narration gets its own prompt**, not `systemPrompt(for: .scene)` — that one returns JSON advice
  with an urgency field, and JSON scaffolding would be scored as content by `NarrationGate` and
  inflate the similarity between two genuinely different scenes. It also does not ask the model what
  *changed*: a model asked what changed will invent a change to report.
- **Commands** parse in `AssistiveRouter.narrationCommand(in:)` with every "stop" form matched
  before every "start" form, because *"stop narrating"* contains *"narrating"* and a wearer asking
  for quiet getting more speech is the one unacceptable failure in that table. Pinned by a test.
- **Wiring**: local VLM only (no cloud fallback, per the non-goal), `.userTurn` raised around every
  transcription turn, `.backgrounded` raised on scene-phase change, and a two-switch Settings
  control — watching and speaking are separate, so turning the feature on never starts talking.

P2 publishes `haltReason` but does **not** render it aloud; that debt is P3's and is listed there.

**`SceneWatcherService` — resolved by deletion, 2026-08-23.** Found while building P1: a proactive
scene-observation loop already in the tree with **no call sites anywhere** — its two `Config`
accessors were read by nothing and it had no Settings UI — whose `isDuplicate` compared
*characters* rather than words, so any two English sentences scored ~1.0 and one recorded
observation suppressed nearly every one after it. It was the same shape `PrivacyFilterService`'s
own comments call out: a config surface that does nothing.

`SceneNarrationService` **subsumes it**, so it was deleted rather than rebuilt. Rebuilding it on
the P1 cores would have meant writing this phase's loop under a name chosen before the design
existed, and would have left the codebase with two proactive scene loops competing for one camera
and one ear — the thing this plan's non-goals rule out for detectors and arbiters alike. Everything
it reached for, P2 owns and does properly: its `isDuplicate` is `NarrationGate.evaluateSpeech`
(word overlap, fixture-measured), its fixed 15-second tick is the duty-cycle floor plus dwell
driven by `FrameGate.distinct`, its unconditional `onObservation` callback is
`AmbientSpeechArbiter(rules: .narration)`, and its "speak up only when notable" prompt is the
silent-by-default mode split in `NarrationSessionPolicy`.

Deleted with it: `Config.sceneWatcherEnabled` / `Config.sceneWatcherInterval` and their setters.
Kept, renamed: `CameraDependentFeature.sceneWatcher` → `.sceneNarration` — P3 needs exactly this
case for the camera-tier gate, and a case named after a deleted service is worse than one named
after the feature that will use it. The persisted `UserDefaults` keys are left unread rather than
migrated; nothing ever wrote them.

### P3 — Honest limits ✅ shipped 2026-08-23

**On-device MLX cannot run while backgrounded** (`project_local_model_background`), so narration
stops when the phone locks or the app backgrounds. For a wearer who is *relying* on it, silence that
isn't explained is indistinguishable from silence because nothing changed — the worst possible
failure for this feature. It must announce the stop and say why, and Settings must state the
limitation rather than implying continuous coverage.

Same treatment for the camera-tier gate: on glasses without live frames
([CQ](CQ-third-party-glasses-backends.md)'s tiers) narration is unavailable, and must say so with a
reason rather than silently doing nothing.

**Landed 2026-08-23.** `NarrationVoiceNotices` is the new core, and the interesting rules in it are
about **restraint**, not copy — announcing too little is the failure this phase exists to fix, and
announcing too much turns an accessibility feature into one that interrupts the wearer to talk about
itself:

- **Only announce to someone who was being spoken to.** Silence reads as a failure only if the
  wearer expected sound; in `.watching` the loop was silent by design, so a spoken "narration
  paused" would be the app talking to someone who never asked it to. Watching halts surface in
  Settings and nowhere else.
- **Key the rule on the *requested* mode, not on whether speech was live at that instant.** A wearer
  who asked for narration and is momentarily quiet because they asked a question is still relying on
  it, and a halt landing in that gap is still owed an explanation.
- **Only announce a resume if the halt was announced**, or "narration is back on" arrives out of
  nowhere explaining a silence the wearer never noticed. And never announce the same halt twice — a
  phone locking and unlocking repeatedly must not produce a running commentary about it.
- **Notices bypass `AmbientSpeechArbiter` entirely.** The arbiter flushes its queue on precisely the
  transitions these notices explain, so a notice routed through it would be dropped by the very halt
  it was announcing. There is a test for that.

The camera-tier gate uses `CameraDependentFeature.sceneNarration` — the case renamed out of the
deleted `SceneWatcherService`, which is what it was kept for. `.unavailable` refuses the start and
speaks the gate's own reason; `.degraded` is allowed through, since it means the camera works
differently rather than that it can't feed this loop. **A switch that flips itself back explains
nothing, and the wearer most likely to hit that case is the one least able to see the switch.**

Settings copy now states the limitation rather than implying continuous coverage: not continuous,
stops when backgrounded or locked, and needs glasses that stream live video.

One implementation note worth keeping: the notice *decision* is recorded synchronously
(`noticeLog`) while the speech is fired as an unstructured task, because a mode transition must not
block a Settings toggle on TTS. That split is also what makes the rules above testable without
racing the scheduler.

**Correction, 2026-08-23 — two of P3's interruptions were never raised.** Found while wiring the
captions decision above. `.realtimeSession` and `.cameraUnavailable` shipped declared, documented,
tested at the policy layer, and handled in `NarrationVoiceNotices` and the Settings view — and
nothing in the app ever called `noteInterruption` for either. The only ones raised were
`.backgrounded` and `.userTurn`.

So narration could speak into a live duplex session, and — worse, because it is the silent one —
the loop went on ticking against a nil or frozen frame when the camera wasn't streaming,
describing nothing while Settings said *"Watching…"*. That is the unexplained silence this phase
exists to prevent, with the explanation already written and never spoken.

**The tests were green throughout.** The gap was in the wiring, and nothing at the layer under test
could see it — which is the honest lesson: a pure core tested exhaustively tells you the decision
is right, never that anything asks it. Worse, the unit tests call `noteInterruption` *themselves*,
so the seam is exercised identically whether or not the app ever calls it: the coverage actively
disguised the hole.

**`NarrationInterruptionWiringTests` now closes it**, because twice is a pattern rather than bad
luck. It scans `OpenGlasses/Sources` and fails when an `Interruption` case has no raise site,
anchored on `#filePath` so it resolves the same locally and in CI. Exhaustive switches already
force a new case to decide *what the wearer is told*; this is what forces something to actually
tell them. It carries its own guard too — a check that the scan is really reading the app sources,
because a source scan that quietly resolves nothing passes vacuously, and a silently disabled test
is worse than no test: the green tick still reads as a promise. Both are now raised on edges (`removeDuplicates` over the
session and streaming publishers), and the `.cameraUnavailable` condition includes
`isStartingStream`, because a ~20 s cold start otherwise announces a halt and a resume either side
of every stream start.

Wiring `.cameraUnavailable` exposed a real gap in the notice rules rather than just a missing call.
The primary Settings flow is two switches — watch, then speak — so when the halt is *already in
force* nothing **begins** on the second switch, `haltBegan` is nil, and the wearer asked to be
spoken to and heard nothing. `Transition` gained `haltBlockedRequest` for exactly that: the same
debt reached from the opposite direction — the world changed under the wearer, or the wearer walked
into a world that had already changed. Same copy, same once-only restraint, kept as a separate
signal so each can be tested on its own.

What this does **not** decide: narration still never starts the camera. That is a real question —
the camera is the glasses' largest drain, and [CX](CX-live-session-vision-choice.md) is mid-flight
on cold-start UX — and it belongs to a plan rather than to a bug fix. Until it is answered, the
honest behaviour is to say why nothing is happening instead of looking like it is working.

### P4 — Device measurement (deferred)

Gates the thresholds and the defaults, and needs hardware plus a real environment:

- Dwell and duty-cycle values against a walked route, not a desk.
- Speech-gate threshold against real rephrasing families from our own model at our own prompt.
- Sustained thermal and battery over a session long enough to matter (this runs the VLM
  continuously — it is the most expensive thing in the app).
- Measured decode-vs-synthesis contention on our actual chain, to set the duty-cycle floor.
- The same measurement **with live captions running**, since the floor was set against narration
  alone and the on-device caption tier adds an ASR model and Apple Translation to the same silicon.
  Narration yields the ear to captions, but it keeps watching — so the contention is real even
  though the ear collision was not.
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
